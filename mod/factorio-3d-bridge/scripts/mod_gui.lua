-- Mods' windows, for the client to draw (`mgui`). Everything a mod builds lives in the player's GUI
-- (player.gui.top, left, center, screen and relative), which scripts can read, unlike Factorio's own
-- windows (the client draws those itself). Only with a real player: hybrid single-player, or the
-- player the bridge plays on a server while they're connected; a player-less character has no GUI.
--
-- Every INTERVAL ticks each of the player's top-level mod elements is read into a tree of plain
-- values; one whose tree changed since it was last sent goes at once, all of them every RESEND
-- ticks (sent unreliably, like `pl`). A mod only hears a real click, which no script can make
-- (on_gui_click can't be raised), so the client clicks Factorio's window for most mods' buttons
-- (hybrid, Windows). For mods with a remote interface the bridge presses their buttons itself
-- (PRESSERS below: what the mod's own click handler does), wherever the player plays: those
-- elements carry `ck`, and the client sends `mpress` with the element's index instead.
--
-- A client not drawing them (its hello says `mg` 0: Settings > Interface > Show mods' windows, off
-- by default) costs nothing here: its player's windows aren't read at all.

local transport = require("scripts.transport")
local puppet = require("scripts.puppet")

local M = {}

local INTERVAL = 30
local RESEND = 300
-- A mod's window bigger than this is cut there (the client says so): a huge table of signals
-- would otherwise cost a busy tick.
local MAX_ELEMENTS = 1500
local MAX_DEPTH = 24
local ROOTS = { "top", "left", "center", "screen", "relative" }

-- Made in the main chunk, unconditionally, so every peer makes the same ids in the same order on
-- each load (link.lua does the same). A script can't raise Factorio's own on_gui_text_changed and
-- the like (LuaBootstrap.raise_event takes custom events only), so what the player did in Zenith's
-- copy of a mod's window is raised as these, with the same field names Factorio's events have;
-- a mod that wants to hear it asks for the ids: remote.call("zenith", "gui_events").
local GUI_EVENTS = {
  on_gui_text_changed = script.generate_event_name(),
  on_gui_checked_state_changed = script.generate_event_name(),
  on_gui_selection_state_changed = script.generate_event_name(),
  on_gui_value_changed = script.generate_event_name(),
  on_gui_switch_state_changed = script.generate_event_name(),
  on_gui_elem_changed = script.generate_event_name(),
}
-- A textfield's text sent is cut to this many bytes (a datagram holds about 64 KB; the client cuts too).
local MAX_TEXT = 4000

-- {event name -> id}, a copy (the zenith remote interface).
function M.events()
  local copy = {}
  for name, id in pairs(GUI_EVENTS) do
    copy[name] = id
  end
  return copy
end

local function get(obj, key)
  local ok, v = pcall(function() return obj[key] end)
  if ok then
    return v
  end
  return nil
end

-- defines.relative_gui_type / relative_gui_position values -> their names, for the client.
local relative_names
local function relative_name(kind, value)
  if not relative_names then
    relative_names = {}
    for _, d in ipairs({ "relative_gui_type", "relative_gui_position" }) do
      relative_names[d] = {}
      for name, v in pairs(defines[d] or {}) do
        relative_names[d][v] = name
      end
    end
  end
  return relative_names[kind][value]
end

-- The values each element type carries that the client draws (any other key throws on that type).
local BY_TYPE = {
  label = {}, button = { "sprite" }, ["sprite-button"] = { "sprite", "number", "toggled" },
  checkbox = { "state" }, radiobutton = { "state" }, textfield = { "text" }, ["text-box"] = { "text" },
  progressbar = { "value" }, slider = { "slider_value" }, sprite = { "sprite" },
  ["drop-down"] = { "items", "selected_index" }, ["list-box"] = { "items", "selected_index" },
  table = { "column_count" }, flow = { "direction" }, frame = { "direction" }, line = { "direction" },
  ["tabbed-pane"] = { "selected_tab_index" }, ["choose-elem-button"] = { "elem_type", "elem_value" },
  ["switch"] = { "switch_state", "left_label_caption", "right_label_caption" },
}
local SHORT = {
  sprite = "sp", number = "nu", toggled = "tg", state = "s", text = "tx", value = "v", slider_value = "v",
  items = "it", selected_index = "si", column_count = "cc", direction = "d", selected_tab_index = "si",
  elem_type = "et", elem_value = "ev", switch_state = "s", left_label_caption = "lc", right_label_caption = "rc",
}

-- {t type, n name, c caption, tt tooltip, st style, vis false when hidden, en false when disabled,
-- dr true for a drag handle, a children, plus the type's values (SHORT)}. `count` is shared across one top-level element.
-- The bridge's own elements (its Zenith button, the launcher help): Zenith draws its own.
local function own(e)
  local name = get(e, "name")
  return type(name) == "string" and name:sub(1, 4) == "f3d-"
end

-- Whether a tree holds anything but frames and flows (mod-gui's button area holding only the
-- bridge's button is left out).
local function has_content(tree)
  if tree.t ~= "frame" and tree.t ~= "flow" then
    return true
  end
  for _, child in ipairs(tree.a or {}) do
    if has_content(child) then
      return true
    end
  end
  return false
end

local SIZE_KEYS = { "minimal_width", "maximal_width", "minimal_height", "maximal_height" }
local pressable
local function read(e, depth, count)
  count.n = count.n + 1
  local ty = get(e, "type")
  local r = { t = ty, n = get(e, "name"), ix = get(e, "index") }
  local caption = get(e, "caption")
  if caption ~= nil and caption ~= "" then
    r.c = caption
  end
  local tooltip = get(e, "tooltip")
  if tooltip ~= nil and tooltip ~= "" then
    r.tt = tooltip
  end
  local style = get(e, "style")
  local style_name = style and get(style, "name")
  if style_name then
    r.st = style_name
  end
  -- The style's size limits (pixels at UI scale 1, 0 for none) and stretching, as Factorio lays the
  -- window out by them: Informatron's window is 800 high with its panes stretched to fill it.
  if style then
    local sz, any = {}, false
    for i, key in ipairs(SIZE_KEYS) do
      local v = get(style, key)
      sz[i] = (type(v) == "number" and v > 0 and v < 10000) and math.floor(v) or 0
      any = any or sz[i] > 0
    end
    if any then
      r.sz = sz
    end
    if get(style, "horizontally_stretchable") == true then
      r.hs = true
    end
    if get(style, "vertically_stretchable") == true then
      r.vs = true
    end
  end
  -- A label Factorio wraps: single_line false, at its maximal width (pixels at UI scale 1).
  if ty == "label" and style and get(style, "single_line") == false then
    r.ml = true
    local w = get(style, "maximal_width")
    if type(w) == "number" and w > 0 and w < 10000 then
      r.mw = w
    end
  end
  if (ty == "button" or ty == "sprite-button") and pressable(e) then
    r.ck = true
  end
  -- Clicks go through it (Space Exploration's watermark: a frame the size of the screen holding its
  -- version in the bottom-right corner); `fs` when its style covers the player's screen.
  if get(e, "ignored_by_interaction") then
    r.ig = true
    local p = depth == 0 and get(e, "gui") and get(get(e, "gui"), "player")
    local res, scale = p and get(p, "display_resolution"), p and get(p, "display_scale")
    local w, h = style and get(style, "minimal_width"), style and get(style, "minimal_height")
    if res and scale and type(w) == "number" and type(h) == "number"
        and w >= res.width / scale - 1 and h >= res.height / scale - 1 then
      r.fs = true
    end
  end
  if get(e, "visible") == false then
    r.vis = false
  end
  if get(e, "enabled") == false then
    r.en = false
  end
  -- A title bar the mod made draggable (drag_target set): the client drags the window by it.
  if get(e, "drag_target") then
    r.dr = true
  end
  for _, key in ipairs(BY_TYPE[ty] or {}) do
    local v = get(e, key)
    if v ~= nil and v ~= "" then
      if key == "elem_value" and type(v) == "table" then
        -- A signal's value is {type, name}: the type tells an item from a fluid or a virtual signal.
        if type(v.type) == "string" then
          r.evt = v.type
        end
        v = v.name or v[1]
      end
      r[SHORT[key]] = v
    end
  end
  if ty == "slider" then
    -- The range the slider's handle moves in (the client draws the value in it).
    local ok_min, lo = pcall(function() return e.get_slider_minimum() end)
    local ok_max, hi = pcall(function() return e.get_slider_maximum() end)
    if ok_min and type(lo) == "number" then
      r.mn = lo
    end
    if ok_max and type(hi) == "number" then
      r.mx = hi
    end
    local ok_step, step = pcall(function() return e.get_slider_value_step() end)
    if ok_step and type(step) == "number" and step > 0 then
      r.stp = step
    end
  end
  if ty == "tabbed-pane" then
    -- Tabs and their contents are pairs: the client needs which goes with which.
    local tabs = {}
    for _, pair in ipairs(get(e, "tabs") or {}) do
      if count.n < MAX_ELEMENTS then
        tabs[#tabs + 1] = { read(pair.tab, depth + 1, count), read(pair.content, depth + 1, count) }
      end
    end
    r.tb = tabs
    return r
  end
  if depth < MAX_DEPTH then
    local kids = get(e, "children") or {}
    if #kids > 0 then
      local a = {}
      for _, child in ipairs(kids) do
        if count.n >= MAX_ELEMENTS then
          r.cut = true
          break
        end
        if not own(child) then
          a[#a + 1] = read(child, depth + 1, count)
        end
      end
      r.a = a
    end
  end
  return r
end

-- Buttons the bridge presses for the client, per mod: `can(e, tags)` says it can press this one,
-- `press(player, e, tags)` does what the mod's own on_gui_click handler would, through its remote
-- interface (only what the mod offers there).
local PRESSERS = {
  -- Informatron 0.5 (scripts/informatron.lua): menu buttons are tagged {root = "informatron",
  -- interface, page_name} and display that page; the close button has action "close-gui"; the
  -- overhead button "informatron_overhead" toggles the window. Its window is player.opened, and
  -- Informatron closes it on on_gui_closed.
  informatron = {
    can = function(e, tags)
      if get(e, "name") == "informatron_overhead" then
        return true
      end
      return tags and tags.root == "informatron" and (tags.action == "close-gui" or (tags.interface and tags.page_name)) and true or false
    end,
    press = function(p, e, tags)
      local window = p.gui.screen["informatron"]
      local function close()
        if window and window.valid and p.opened == window then
          p.opened = nil
        end
      end
      if not remote.interfaces["informatron"] then
        return false
      end
      if get(e, "name") == "informatron_overhead" then
        if window then
          close()
        else
          remote.call("informatron", "informatron_open_to_page", { player_index = p.index, interface = "informatron", page_name = "informatron" })
        end
      elseif tags.action == "close-gui" then
        close()
      else
        remote.call("informatron", "informatron_open_to_page", { player_index = p.index, interface = tags.interface, page_name = tags.page_name })
      end
      return true
    end,
  },
}

local function owner_mod(e)
  local ok, mod = pcall(function() return e.get_mod() end)
  return ok and mod or nil
end

pressable = function(e)
  local presser = PRESSERS[owner_mod(e) or ""]
  return presser ~= nil and presser.can(e, get(e, "tags")) or false
end

-- The player whose GUI is read: the one the bridge plays, connected, with a character.
local function the_player()
  local p = puppet.owner()
  if not (p and get(p, "valid") and get(p, "connected")) then
    return nil
  end
  local c = puppet.get()
  if not (c and c.valid and get(p, "character") == c) then
    return nil
  end
  return p
end

-- What was sent last, per top-level element: only decides what to send (never touches `storage`),
-- so it may differ between peers; after a load it is empty and everything goes again.
local sent, sent_all = {}, 0
-- One element's message is cut to this (a datagram holds about 64 KB).
local MAX_BYTES = 48000

-- A press changed a window: read again on the next tick rather than at the next round.
local soon = false

function M.reset()
  sent, sent_all = {}, 0
end

local function find(e, index, depth)
  if get(e, "index") == index then
    return e
  end
  if depth >= MAX_DEPTH then
    return nil
  end
  for _, child in ipairs(get(e, "children") or {}) do
    local found = find(child, index, depth + 1)
    if found then
      return found
    end
  end
  return nil
end

-- `mpress` {ix}: the client pressed a button marked `ck`; the bridge presses it as its mod would.
function M.press(cmd)
  local p = the_player()
  local index = tonumber(cmd.ix)
  if not (p and index) then
    return
  end
  local e
  for _, root in ipairs(ROOTS) do
    e = find(p.gui[root], index, 0)
    if e then
      break
    end
  end
  local presser = e and PRESSERS[owner_mod(e) or ""]
  local tags = e and get(e, "tags")
  if presser and presser.can(e, tags) then
    local ok, done = pcall(presser.press, p, e, tags)
    if not (ok and done) then
      transport.send_now({ t = "msg", text = "That button didn't work from Zenith: use it in Factorio (Ctrl+F9)" })
    end
    soon = true
  end
end

-- What the player may change in a mod's window from Zenith, by element type: each sets the value
-- the way a click would have, fills in the event's own fields and returns the event's name, or
-- nil to refuse (the wrong kind of value, out of range). The mod finds the new value on the
-- element (e.text, e.state, e.selected_index, e.slider_value) whenever it reads it, and hears
-- GUI_EVENTS where it listens.
local function set_text(e, v, data)
  if type(v) ~= "string" then
    return nil
  end
  if #v > MAX_TEXT then
    v = v:sub(1, MAX_TEXT)
  end
  e.text = v
  data.text = get(e, "text") or v
  return "on_gui_text_changed"
end

local function set_checked(e, v, data)
  if type(v) ~= "boolean" then
    return nil
  end
  -- A radio button is switched on by a click, never off (its mod switches the others off).
  if get(e, "type") == "radiobutton" and not v then
    return nil
  end
  e.state = v
  data.state = get(e, "state")
  return "on_gui_checked_state_changed"
end

local function set_selected(e, v, data)
  v = tonumber(v)
  local items = get(e, "items")
  if not v or v % 1 ~= 0 or type(items) ~= "table" or v < 1 or v > #items then
    return nil
  end
  e.selected_index = v
  data.selected_index = get(e, "selected_index")
  return "on_gui_selection_state_changed"
end

local function set_slider(e, v, data)
  v = tonumber(v)
  if not v or v ~= v then
    return nil
  end
  local _, lo = pcall(function() return e.get_slider_minimum() end)
  local _, hi = pcall(function() return e.get_slider_maximum() end)
  local _, step = pcall(function() return e.get_slider_value_step() end)
  lo = type(lo) == "number" and lo or 0
  hi = type(hi) == "number" and hi or lo
  if type(step) == "number" and step > 0 then
    v = lo + math.floor((v - lo) / step + 0.5) * step
  end
  v = math.max(lo, math.min(hi, v))
  e.slider_value = v
  data.value = get(e, "slider_value")
  return "on_gui_value_changed"
end

local function set_switch(e, v, data)
  if v ~= "left" and v ~= "right" and not (v == "none" and get(e, "allow_none_state") == true) then
    return nil
  end
  e.switch_state = v
  data.switch_state = get(e, "switch_state")
  return "on_gui_switch_state_changed"
end

-- The value a choose-elem-button's picker gave: a name (item, fluid, entity...), {type, name} for a
-- signal, false to clear it. Factorio refuses what the element can't hold (its elem_filters, a name
-- that isn't one), and so does the assignment.
local function set_elem(e, v, data)
  if v ~= false and type(v) ~= "string" and not (type(v) == "table" and type(v.name) == "string" and type(v.type) == "string") then
    return nil
  end
  if v == false then
    v = nil
  elseif type(v) == "table" then
    v = { type = v.type, name = v.name }
  end
  if not pcall(function() e.elem_value = v end) then
    return nil
  end
  local now = get(e, "elem_value")
  if type(now) == "table" then
    now = { type = now.type, name = now.name }
  end
  data.element_value = now
  return "on_gui_elem_changed"
end

local SETTERS = {
  ["choose-elem-button"] = set_elem,
  ["switch"] = set_switch,
  textfield = set_text, ["text-box"] = set_text,
  checkbox = set_checked, radiobutton = set_checked,
  ["drop-down"] = set_selected, ["list-box"] = set_selected,
  slider = set_slider,
}

-- `mset` {ix, v}: the player changed the value of a textfield, checkbox, drop-down, list-box or
-- slider in the copy of a mod's window; set it on the element and raise the event for the mod.
function M.set(cmd)
  local p = the_player()
  local index = tonumber(cmd.ix)
  if not (p and index) then
    return
  end
  local e
  for _, root in ipairs(ROOTS) do
    e = find(p.gui[root], index, 0)
    if e then
      break
    end
  end
  local setter = e and SETTERS[get(e, "type") or ""]
  -- Not what the player can't use in Factorio either: a disabled element, one ignoring interaction.
  if not setter or get(e, "enabled") == false or get(e, "ignored_by_interaction") or own(e) then
    return
  end
  local data = { element = e, player_index = p.index }
  local name = setter(e, cmd.v, data)
  if name then
    pcall(script.raise_event, GUI_EVENTS[name], data)
    soon = true
  end
end

function M.tick()
  if (game.tick + 17) % INTERVAL ~= 0 and not soon then
    return
  end
  soon = false
  local client = storage.f3d.client
  local p = not (client and client.mg == false) and the_player()
  if not p then
    if next(sent) then
      sent = {}
      transport.send_now({ t = "mgui", ids = {}, l = {} })
    end
    return
  end
  local resend = game.tick - sent_all >= RESEND
  -- Factorio's window and UI scale: where its elements are, for the client to click them there.
  local res, scale = get(p, "display_resolution"), get(p, "display_scale")
  local ds = res and { res.width or res[1], res.height or res[2], scale or 1 } or nil
  local ids, changed, seen = {}, {}, {}
  for _, root in ipairs(ROOTS) do
    local gui = get(p.gui, root)
    for _, e in ipairs(gui and get(gui, "children") or {}) do
      local index = get(e, "index")
      local tree = index and not own(e) and read(e, 0, { n = 0 })
      if tree and not has_content(tree) and tostring(tree.n or ""):sub(1, 8) == "mod_gui_" then
        tree = nil
      end
      if tree then
        local entry = { i = index, r = root, e = tree }
        if root == "screen" then
          local loc = get(e, "location")
          entry.at = loc and { loc.x or loc[1], loc.y or loc[2] } or nil
        elseif root == "relative" then
          local anchor = get(e, "anchor")
          if anchor then
            entry.an = { relative_name("relative_gui_type", anchor.gui), relative_name("relative_gui_position", anchor.position), anchor.name }
          end
        end
        local sig = helpers.table_to_json(entry)
        if #sig > MAX_BYTES then
          entry.e = { t = "frame", n = tree.n, c = tree.c, cut = true }
          sig = helpers.table_to_json(entry)
        end
        ids[#ids + 1] = index
        seen[index] = sig
        if resend or sent[index] ~= sig then
          changed[#changed + 1] = entry
        end
      end
    end
  end
  local gone = false
  for index in pairs(sent) do
    if not seen[index] then
      gone = true
    end
  end
  sent = seen
  if resend then
    sent_all = game.tick
  end
  -- One message per window (a big one fills a datagram); each says which windows there are.
  if #changed == 0 and gone then
    transport.send_now({ t = "mgui", ids = ids, l = {}, ds = ds })
  end
  for _, entry in ipairs(changed) do
    transport.send_now({ t = "mgui", ids = ids, l = { entry }, ds = ds })
  end
end

return M
