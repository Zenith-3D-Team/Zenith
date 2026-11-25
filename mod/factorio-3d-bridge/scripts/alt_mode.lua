-- Alt-mode's icons (issue #9): what each machine is set to make or let through, an assembler's or
-- furnace's recipe, an inserter's, loader's, splitter's, storage chest's or drill's filters, a
-- requester or buffer chest's first four requests.
--
-- They ride on the entity records (`extra.ai`, world.lua), so every building the client has loaded
-- has its icon from the moment it arrives, with no scanning and no limit. What changes them:
--   * with an event: building (a new record), Shift+paste and the bridge's own settings (tracker
--     sends `upd`), a player closing the entity's window in the real game (on_gui_closed), the
--     screen the client has open (screens.lua checks its entity twice a second);
--   * without one: a furnace picks its recipe from what is put in, and a circuit network can set
--     an assembler's recipe or an inserter's, loader's or splitter's filters. Those entities (a
--     furnace, or one with a red or green wire) are watched: each record of one puts it in
--     storage.f3d.altw, and a few of them a tick are read again under the work budget, `aiu`
--     carrying what changed. Scripts changing the rest are seen when the chunk is next sent.
--
-- Everything here runs from events and on_tick, and what it keeps (storage.f3d.altw) only from
-- the records the client is sent, so it stays the same on every peer.
--
-- Also the chests' contents (J6, at the end): Factorio's Alt-mode draws over a container what is in
-- it. Nothing tells a mod when that changes, so they are read in rounds, only while the client has
-- Alt-mode on. The same rounds read the modules in machines and the science packs in labs (K1, K2),
-- which robots and inserters change without an event too.

local transport = require("scripts.transport")
local budget = require("scripts.budget")
local rate = require("scripts.rate")
local perf = require("scripts.perf")

local M = {}

local CHUNK = 32
-- Read again per tick at most (the work budget may allow fewer): with a few thousand watched
-- machines each is looked at every few seconds.
local WATCH_PER_TICK = 24
-- A watched machine's look costs about as much as a record (budget.lua's units).
local WATCH_PRICE = 2
-- A round over the watched machines starts at most this often.
local ROUND_TICKS = 120

local TYPES = {
  ["assembling-machine"] = true, furnace = true, ["rocket-silo"] = true, inserter = true, loader = true,
  ["loader-1x1"] = true, splitter = true, ["lane-splitter"] = true, ["logistic-container"] = true,
  ["mining-drill"] = true,
}
M.TYPES = TYPES
-- Their recipe or filters can change with no event if the circuit network sets them.
local CIRCUIT_SET = {
  ["assembling-machine"] = true, inserter = true, loader = true, ["loader-1x1"] = true, splitter = true,
  ["lane-splitter"] = true, ["mining-drill"] = true, ["logistic-container"] = true,
}

local function signal_name(f)
  if type(f) ~= "table" then
    return nil
  end
  local name = f.name
  if type(name) ~= "string" and name ~= nil then -- a prototype (LuaObjects aren't tables)
    local ok, n = pcall(function() return name.name end)
    name = ok and n or nil
  end
  return type(name) == "string" and name or nil
end

-- Every filter set on the entity, in slot order: Alt-mode shows them all, shrunk to fit.
local function filter_names(e)
  local names = {}
  local ok, n = pcall(function() return e.filter_slot_count end)
  for i = 1, ok and n or 0 do
    local ok_f, f = pcall(function() return e.get_filter(i) end)
    local name = ok_f and signal_name(f)
    if name then
      names[#names + 1] = name
    end
  end
  return names
end

-- A requester or buffer chest's requested items, the first `n` different ones in the order of its
-- active sections (owner: a mixed chest shows its first four, each a quarter of the icon). (Read
-- here, not through logistics.lua: world.lua requires this file, and logistics.lua world.lua.)
local function requested_names(e, n)
  local names, seen = {}, {}
  -- A chest's LuaLogisticSections (logistics.lua reads chests the same way).
  local ok, point = pcall(function() return e.get_logistic_sections() end)
  if not (ok and point) then
    return names
  end
  local ok2, sections = pcall(function() return point.sections end)
  for _, section in pairs(ok2 and sections or {}) do
    local ok3, active = pcall(function() return section.active end)
    if not ok3 or active ~= false then
      for _, f in pairs(section.filters or {}) do
        local v = f.value
        local name = v and (v.type == nil or v.type == "item") and v.name
        if name and not seen[name] then
          seen[name] = true
          names[#names + 1] = name
          if #names >= n then
            return names
          end
        end
      end
    end
  end
  return names
end

-- The recipe a crafting machine shows: its own, or for a furnace with none (it picks its recipe from
-- what is put in, and drops it whenever the input runs out between crafts) the last one it made.
-- Factorio's Alt-mode keeps that icon until the furnace takes another recipe (owner's J2; its
-- changelog: "Fixed that furnace alt-mode didn't show the last recipe, same as map view "Recipe
-- Icons" option"). 2.x: previous_recipe is {name, quality}, each a prototype or its name.
local function shown_recipe(e)
  local ok, recipe = pcall(function() return e.get_recipe() end)
  if ok and recipe then
    return recipe
  end
  if e.type ~= "furnace" then
    return nil
  end
  local ok_p, prev = pcall(function() return e.previous_recipe end)
  if not (ok_p and type(prev) == "table") then
    return nil
  end
  local name = prev.name
  if type(name) ~= "string" then
    local ok_n, n = pcall(function() return name.name end)
    name = ok_n and n or nil
  end
  if type(name) ~= "string" then
    return nil
  end
  local ok_r, r = pcall(function() return e.force.recipes[name] end)
  return ok_r and r or nil
end
M.shown_recipe = shown_recipe

-- [icon type, name, more?] for an entity's Alt-mode icon (more: the other filters' item names),
-- or nil.
function M.icon(e)
  local t = e.type
  if t == "assembling-machine" or t == "furnace" or t == "rocket-silo" then
    local recipe = shown_recipe(e)
    if recipe then
      return { "recipe", recipe.name }
    end
  elseif t == "inserter" or t == "loader" or t == "loader-1x1" then
    local names = filter_names(e)
    if #names > 0 then
      local first = table.remove(names, 1)
      return { "item", first, #names > 0 and names or nil }
    end
  elseif t == "splitter" or t == "lane-splitter" then
    local ok, f = pcall(function() return e.splitter_filter end)
    local name = ok and signal_name(f)
    if name then
      return { "item", name }
    end
  elseif t == "logistic-container" or t == "mining-drill" then
    local ok, f = pcall(function() return e.filter_slot_count > 0 and e.get_filter(1) end)
    local name = ok and signal_name(f)
    if name then
      return { "item", name }
    end
    if t == "logistic-container" then
      local names = requested_names(e, 4)
      if #names > 0 then
        local first = table.remove(names, 1)
        return { "item", first, #names > 0 and names or nil }
      end
    end
  end
  return nil
end

-- Alt-mode's machine arrows (issue #9 part 2, Factorio's "Show machine arrows in Alt-mode"): the
-- client draws them at the prototype's fluid connections (`eprops` fb). A crafting machine shows
-- only those its recipe uses, as Factorio does (checked in 2.1.23: with any fluid ingredient every
-- input connection, with any fluid product every output one), so its record carries `fa`, a mask:
-- 1 the recipe takes fluid, 2 it makes fluid. 2.1 has no LuaEntity.fluidbox, so it comes from the
-- recipe. Other machines (boilers, pumps) show all their connections and need nothing here.
local CRAFTERS = { ["assembling-machine"] = true, furnace = true }
M.CRAFTERS = CRAFTERS

-- A mining drill takes fluid in while it has a fluid box (uranium ore's sulfuric acid; Factorio draws the electric
-- drill's three fluid connectors with its `wet_mining_graphics_set`): `fa` 1, as a crafter whose recipe takes fluid,
-- so the client draws its `-wet` model (model_library.gd wet_model). Read from the drill's own box, as the game keeps
-- it (2.1.24: `fluids_count` 1 over uranium, kept when the ore runs out and with one uranium tile in an iron drill's
-- area; 0 over iron alone), not guessed from what it mines.
local function drill_arrows(e)
  local ok, count = pcall(function() return e.fluids_count end)
  if ok and type(count) == "number" and count > 0 then
    return 1
  end
  return nil
end

function M.arrows(e)
  if e.type == "mining-drill" then
    return drill_arrows(e)
  end
  if not CRAFTERS[e.type] then
    return nil
  end
  local recipe = shown_recipe(e)
  if not recipe then
    return nil
  end
  local mask = 0
  for _, i in pairs(recipe.ingredients) do
    if i.type == "fluid" then
      mask = 1
      break
    end
  end
  for _, p in pairs(recipe.products) do
    if p.type == "fluid" then
      mask = mask + 2
      break
    end
  end
  return mask > 0 and mask or nil
end

-- Which fluid goes in or out at each of a crafting machine's connections (L10: the owner couldn't tell
-- an oil refinery's). Factorio draws each connection's arrow and its fluid's icon while the machine is
-- selected or in Alt-mode (PipeConnectionDefinition::hide_connection_info). 2.1 makes a crafting
-- machine's fluid storages from its recipe (an oil refinery on basic oil processing has two, read in
-- 2.1.24), each filtered to its fluid, so they are read from the entity, turned and mirrored as it
-- stands: [[dx, dy, way, flow, fluid], ...] for its ordinary connections, (dx, dy) the connection's
-- tile from the entity's centre (tiles), way the direction its pipe leaves by (0, 4, 8, 12), flow "i",
-- "o" or "b", fluid its name ("" when nothing says). nil when it has none or `fluid_icons` is off.
local FLOW_LETTER = { input = "i", output = "o", ["input-output"] = "b" }

local function hundredths(v)
  return math.floor(v * 100 + 0.5) / 100
end

function M.connections(e)
  if not perf.on("fluid_icons") then
    return nil
  end
  local ok, n = pcall(function() return e.fluids_count end)
  if not (ok and type(n) == "number") then
    return nil
  end
  local p = e.position
  local out = {}
  for i = 1, n do
    local okf, filter = pcall(function() return e.get_fluid_filter(i) end)
    local name = okf and filter and filter.name or nil
    if not name then
      local okg, fluid = pcall(function() return e.get_fluid(i) end)
      name = okg and fluid and fluid.name or nil
    end
    local okc, conns = pcall(function() return e.get_fluid_box_pipe_connections(i) end)
    for _, c in pairs(okc and conns or {}) do
      local at, to = c.position, c.target_position
      if c.connection_type == "normal" and at and to then
        local dx, dy = to.x - at.x, to.y - at.y
        local way
        if math.abs(dx) > math.abs(dy) then
          way = dx > 0 and 4 or 12
        else
          way = dy > 0 and 8 or 0
        end
        out[#out + 1] = { hundredths(at.x - p.x), hundredths(at.y - p.y), way, FLOW_LETTER[c.flow_direction] or "b", name or "" }
      end
    end
  end
  return #out > 0 and out or nil
end

-- The icon as one string, to see whether it changed ("" for none).
function M.signature(icon, arrows)
  local s = ""
  if icon then
    s = icon[1] .. ":" .. icon[2]
    if icon[3] then
      s = s .. ":" .. table.concat(icon[3], ",")
    end
  end
  if arrows then
    s = s .. "|" .. arrows
  end
  return s
end

-- What Alt-mode shows over the entity: its icon and its arrows (either may be nil), and their signature.
function M.state(e)
  local icon = TYPES[e.type] and M.icon(e) or nil
  local arrows = (CRAFTERS[e.type] or e.type == "mining-drill") and M.arrows(e) or nil
  return icon, arrows, M.signature(icon, arrows)
end

local function chunk_key(p)
  return math.floor(p.x / CHUNK) .. "," .. math.floor(p.y / CHUNK)
end

-- world.record calls this for each record it makes of an Alt-mode type, with its icon and extra
-- (wires in r / g): a furnace, or one a circuit network may set, is watched from then on. Only
-- for a client's own records (storage.f3d has its subscriptions).
function M.recorded(e, icon, extra, arrows)
  local s = storage.f3d
  local unit = e.unit_number
  if not (s and s.subs and unit) then
    return
  end
  if e.type == "furnace" or (CIRCUIT_SET[e.type] and extra and (extra.r or extra.g)) then
    s.altw = s.altw or {}
    s.altw[unit] = { e = e, v = M.signature(icon, arrows), k = chunk_key(e.position) }
  elseif s.altw and s.altw[unit] then
    s.altw[unit] = nil -- its wires went: an event or the chunk's next sending tells the rest
  end
end

-- An `aiu` fa row: [unit, fluid mask, connections?] (M.connections, only with a mask).
function M.fa_row(e, arrows)
  local conns = arrows and M.connections(e) or nil
  if conns then
    return { e.unit_number, arrows, conns }
  end
  return { e.unit_number, arrows or 0 }
end

local function row(unit, icon)
  if not icon then
    return { unit, "" }
  end
  return { unit, icon[1], icon[2], icon[3] }
end

-- The entity's icon now, sent if it differs from what the client was last told (an event that may
-- have changed it: a window closed in the real game, the open screen's commands). `known` is the
-- signature the caller kept, or nil to send it whatever it was.
function M.check(e, known)
  local s = storage.f3d
  if not (s and s.client and e and e.valid and e.unit_number and TYPES[e.type]) then
    return known
  end
  -- world.is_subscribed, here: world requires this module, and `require` at run time stops the game.
  if e.surface.index ~= s.surface_index or not s.subs[chunk_key(e.position)] then
    return known
  end
  local icon, arrows, v = M.state(e)
  local w = s.altw and s.altw[e.unit_number]
  if w then
    w.v = v
  end
  if v ~= known then
    local p = e.position
    transport.send_reliable_priority({ t = "aiu", l = { row(e.unit_number, icon) }, fa = { M.fa_row(e, arrows) } },
      math.floor(p.x / CHUNK), math.floor(p.y / CHUNK))
  end
  return v
end

---------------------------------------------------------------------------------------------
-- Where Alt-mode puts a prototype's icons (K1, K2), for `eprops` (ui_actions.lua): Factorio 2.1
-- draws an entity's own icon by its icon_draw_specification (a shift from its centre and a scale),
-- and the contents of some of its inventories as rows of small icons by its icons_positioning, one
-- IconSequencePositioning per inventory: the modules in a machine, a drill, a lab or a beacon, and
-- the science packs in a lab. A machine with module slots and no icons_positioning gets Factorio's
-- documented defaults for its modules (shift {0, 0.7}, scale 0.5, separation 1.1, first row of
-- several -0.1, up to its selection box's width / 0.75 icons a row and width / 1.5 rows).
-- An ammo turret's ammo and a locomotive's fuel are drawn the same way (K1's leftover): 2.1's gun
-- turret lists its turret_ammo inventory ({0, -0.25}) and its locomotive its fuel ({0, 0.3}, three a
-- row), the only two in 2.1's data; one without an entry gets the defaults, as a machine's modules do
-- (the old AmmoTurretPrototype::entity_info_icon_shift drew every ammo turret's ammo).
-- Prototypes only, so the module-level caches are the same on every peer.

local SEQUENCE_TYPES = { ["assembling-machine"] = true, furnace = true, ["rocket-silo"] = true,
  ["mining-drill"] = true, lab = true, beacon = true }
M.SEQUENCE_TYPES = SEQUENCE_TYPES
-- The types whose other inventory Alt-mode shows (`/f3d-perf alt_ammo_fuel`): the kind its row has in
-- `isq` and the inventory's defines.inventory name.
-- A cargo wagon's load (kind "c", `/f3d-perf alt_ammo_fuel` too) shows its most-stacked kinds in one row.
local STOCK_TYPES = { ["ammo-turret"] = { "a", "turret_ammo" }, locomotive = { "f", "fuel" },
  ["cargo-wagon"] = { "c", "cargo_wagon" } }
local WAGON_SHOWN = 4
-- The module inventory's defines.inventory name by type: crafter_modules is 2.1's, the rest 2.0's.
local MODULE_INVENTORIES = {
  ["assembling-machine"] = { "crafter_modules", "assembling_machine_modules" },
  furnace = { "crafter_modules", "furnace_modules" },
  ["rocket-silo"] = { "crafter_modules", "rocket_silo_modules", "assembling_machine_modules" },
  ["mining-drill"] = { "mining_drill_modules" },
  lab = { "lab_modules" },
  beacon = { "beacon_modules" },
}

local function define_of(name)
  local ok, v = pcall(function() return defines.inventory[name] end)
  return ok and v or nil
end

local function num(v, default)
  return type(v) == "number" and v or default
end

local function thousandths(v)
  return math.floor(v * 1000 + 0.5) / 1000
end

-- A Vector ({x, y} or {x =, y =}) as two numbers, 0, 0 when it isn't one.
local function vec_xy(v)
  if type(v) ~= "table" then
    return 0, 0
  end
  return num(v.x or v[1], 0), num(v.y or v[2], 0)
end

local function box_width(proto)
  local ok, b = pcall(function() return proto.selection_box end)
  if not (ok and type(b) == "table") then
    return 0
  end
  local lt, rb = b.left_top or b[1], b.right_bottom or b[2]
  if type(lt) ~= "table" or type(rb) ~= "table" then
    return 0
  end
  return num(rb.x or rb[1], 0) - num(lt.x or lt[1], 0)
end

-- Those whose own Alt-mode icon the client draws (TYPES, containers' contents, machines'), the
-- only ones whose icon_draw_specification it needs.
local SPEC_TYPES = { container = true, ["infinity-container"] = true, ["linked-container"] = true }
for t in pairs(TYPES) do
  SPEC_TYPES[t] = true
end
for t in pairs(SEQUENCE_TYPES) do
  SPEC_TYPES[t] = true
end

-- [shift x, shift y, scale] of the prototype's icon_draw_specification, nil when it is the default
-- ({0, 0}, 1) or the client draws no icon of its own over it.
function M.draw_spec(proto)
  if not SPEC_TYPES[proto.type] then
    return nil
  end
  local ok, s = pcall(function() return proto.icon_draw_specification end)
  if not (ok and type(s) == "table") then
    return nil
  end
  local sx, sy = vec_xy(s.shift)
  local scale = num(s.scale, 1)
  if sx == 0 and sy == 0 and scale == 1 then
    return nil
  end
  return { thousandths(sx), thousandths(sy), thousandths(scale) }
end

local sequences_cache = {}

-- One `isq` row from an IconSequencePositioning (`p`; {} for Factorio's defaults).
local function sequence_entry(kind, p, width)
  local sx, sy = 0, 0.7
  if p.shift ~= nil then
    sx, sy = vec_xy(p.shift)
  end
  return { kind, thousandths(sx), thousandths(sy), thousandths(num(p.scale, 0.5)),
    math.max(1, math.floor(num(p.max_icons_per_row, width / 0.75) + 1e-6)),
    math.max(1, math.floor(num(p.max_icon_rows, width / 1.5) + 1e-6)),
    thousandths(num(p.separation_multiplier, 1.1)), thousandths(num(p.multi_row_initial_height_modifier, -0.1)) }
end

-- An ammo turret's or a locomotive's one row: its icons_positioning entry for that inventory, else
-- the defaults.
local function stock_sequences(proto, stock)
  if stock[1] == "c" then -- no icons_positioning of its own: a row along the wagon, over its middle
    return { sequence_entry("c", { shift = { 0, 0 }, scale = 0.5, max_icons_per_row = WAGON_SHOWN, max_icon_rows = 1 },
      box_width(proto)) }
  end
  local index = define_of(stock[2])
  local ok, list = pcall(function() return proto.icons_positioning end)
  if index and ok and type(list) == "table" then
    for _, p in ipairs(list) do
      if type(p) == "table" and p.inventory_index == index then
        return { sequence_entry(stock[1], p, box_width(proto)) }
      end
    end
  end
  return { sequence_entry(stock[1], {}, box_width(proto)) }
end

-- [[kind, shift x, shift y, scale, icons a row, rows, separation, first row's lift], ...]: kind "m"
-- the modules, "l" a lab's science packs, "a" a turret's ammo, "f" a locomotive's fuel; nil when
-- Alt-mode shows none of them.
local function sequences(proto)
  local t = proto.type
  if STOCK_TYPES[t] then
    return stock_sequences(proto, STOCK_TYPES[t])
  end
  if not SEQUENCE_TYPES[t] then
    return nil
  end
  local ok_m, slots = pcall(function() return proto.module_inventory_size end)
  local has_modules = ok_m and type(slots) == "number" and slots > 0
  if not has_modules and t ~= "lab" then
    return nil
  end
  local modules = {}
  for _, n in ipairs(MODULE_INVENTORIES[t]) do
    local d = define_of(n)
    if d then
      modules[d] = true
    end
  end
  local lab_input = t == "lab" and define_of("lab_input") or nil
  local width = box_width(proto)
  local function entry(kind, p)
    return sequence_entry(kind, p, width)
  end
  local out = {}
  local ok, list = pcall(function() return proto.icons_positioning end)
  if ok and type(list) == "table" then
    for _, p in ipairs(list) do
      local index = type(p) == "table" and p.inventory_index or nil
      if has_modules and index and modules[index] then
        out[#out + 1] = entry("m", p)
      elseif lab_input and index == lab_input then
        out[#out + 1] = entry("l", p)
      end
    end
  elseif has_modules then
    out[1] = entry("m", {})
  end
  return #out > 0 and out or nil
end

function M.sequences(proto)
  local v = sequences_cache[proto.name]
  if v == nil then
    v = sequences(proto) or false
    sequences_cache[proto.name] = v
  end
  return v or nil
end

-- The items an inventory shows in Alt-mode, slot by slot (Factorio draws one icon a module, one a
-- lab's pack slot, no counts): a name, or {name, quality} when not normal. `each`: one per item of
-- a stack (a module slot holds one in the game). Up to 32.
local function shown_items(inv, each)
  local out = {}
  if not inv or inv.is_empty() then
    return out
  end
  for i = 1, #inv do
    local stack = inv[i]
    if stack.valid_for_read then
      local q = stack.quality
      q = type(q) == "string" and q or (q and q.name)
      local item = (q and q ~= "normal") and { stack.name, q } or stack.name
      for _ = 1, each and math.min(stack.count, 32) or 1 do
        out[#out + 1] = item
      end
      if #out >= 32 then
        break
      end
    end
  end
  return out
end

-- What Alt-mode shows in a machine (K1, K2): its modules and its other inventory (a lab's science
-- packs, a turret's ammo, a locomotive's fuel: one icon a filled slot), each a list as shown_items
-- makes it (empty for none), or nil, nil for an entity without such icons.
function M.machine_icons(e)
  local seq = M.sequences(e.prototype)
  if not seq then
    return nil, nil
  end
  local stock = STOCK_TYPES[e.type]
  if stock then
    local ok, held = pcall(function()
      local inv = e.get_inventory(defines.inventory[stock[2]])
      if stock[1] == "c" then
        return M.top_names(inv, WAGON_SHOWN) or {}
      end
      return shown_items(inv, false)
    end)
    return {}, ok and held or {}
  end
  local want_m, want_l
  for _, s in ipairs(seq) do
    want_m = want_m or s[1] == "m"
    want_l = want_l or s[1] == "l"
  end
  local ok, m, l = pcall(function()
    local mods = want_m and shown_items(e.get_module_inventory(), true) or {}
    local packs = want_l and shown_items(e.get_inventory(defines.inventory.lab_input), false) or {}
    return mods, packs
  end)
  if not ok then
    return {}, {}
  end
  return m, l
end

local function items_sig(list)
  local parts = {}
  for i, it in ipairs(list) do
    parts[i] = type(it) == "table" and (it[1] .. "@" .. it[2]) or it
  end
  return table.concat(parts, ",")
end

---------------------------------------------------------------------------------------------
-- Chests' contents (J6). Factorio's Alt-mode shows "additional information about built entities
-- such as recipes in assembling machines and container contents" (its show-info control's words):
-- over a chest the icons of what is in it, up to four kinds in the one icon's room. Here the kinds
-- it holds most of, most first; no counts, as Factorio draws none.
--
-- While the client says Alt-mode is on (`altc` {on 1, g}), the chests in its focus square are read
-- in rounds under the work budget, a round at most every CONTENTS_ROUND ticks (stretched by the
-- update rate, rate.lua's `ac`), and `ac` {g, l} carries the chests whose icons changed: [unit,
-- item, more items?], or [unit] when it shows none now (emptied, gone, out of the square or of the
-- client's chunks). storage.f3d.altc = {g, sent = {unit -> the names sent}, msent = {unit -> the
-- machine's icons sent}, due, round}; nil while off. Set from the client's command and on_tick,
-- like `focus`.
--
-- The machines (K1, K2; `/f3d-perf alt_machines`): those in the focus square whose prototype has
-- module slots, and labs, are read in the same rounds, `am` {g, l} carrying those whose icons
-- changed: [unit, modules, packs?] (each a list of items, a name or [name, quality]; modules 0
-- when there are none but packs), or [unit] when it shows none now. Ammo turrets and locomotives
-- too (`/f3d-perf alt_ammo_fuel`): their ammo or fuel where a lab's packs go, a locomotive read
-- where it is now (only when the client asks with `lf`: locomotive fuel icons are off by default); cargo wagons
-- likewise, their four most-stacked kinds.

local CONTAINER_TYPES = { "container", "logistic-container", "infinity-container", "linked-container" }
local CONTAINER_SET = {}
for _, t in ipairs(CONTAINER_TYPES) do
  CONTAINER_SET[t] = true
end
local CONTENTS_SHOWN = 4
local CONTENTS_PER_TICK = 32
-- A chest's read: its inventory's contents, about a record's worth (budget.lua's units).
local CONTENTS_PRICE = 2
-- A machine's: its module inventory slot by slot, a lab's packs too.
local MACHINE_PRICE = 3
-- The search of the focus square for chests (and for machines), at the start of a round.
local CONTENTS_FIND_PRICE = 20
local CONTENTS_ROUND = 60
local CONTENTS_ROUND_MOVE = 120
local MOVE_CADENCE_TILES = 4
-- Module-local counters for tests/probes (never in storage).
M.counts = { container_scans = 0, machine_scans = 0, rounds = 0 }
local container_types
local machine_names

local function present_container_types()
  if not container_types then
    local present = {}
    for _, proto in pairs(prototypes.entity) do
      present[proto.type] = true
    end
    container_types = {}
    for _, t in ipairs(CONTAINER_TYPES) do
      if present[t] then
        container_types[#container_types + 1] = t
      end
    end
  end
  return container_types
end

-- The names of the prototypes whose Alt-mode shows modules or science packs, and (`stock`, with
-- /f3d-perf alt_ammo_fuel) the ammo turrets and locomotives after them.
local function present_machine_names(stock, loco)
  if not machine_names then
    -- [1] machines and labs, [2] and the ammo turrets and cargo wagons, [3] and the locomotives too (the client's
    -- `lf`: locomotives' fuel icons are off unless it asks).
    machine_names = { {}, {}, {} }
    for name, proto in pairs(prototypes.entity) do
      if SEQUENCE_TYPES[proto.type] and M.sequences(proto) then
        for i = 1, 3 do
          machine_names[i][#machine_names[i] + 1] = name
        end
      elseif STOCK_TYPES[proto.type] then
        machine_names[3][#machine_names[3] + 1] = name
        if proto.type ~= "locomotive" then
          machine_names[2][#machine_names[2] + 1] = name
        end
      end
    end
    for i = 1, 3 do
      table.sort(machine_names[i])
    end
  end
  return machine_names[stock and (loco and 3 or 2) or 1]
end

-- The names of the kinds the chest holds most of (qualities together), most first, ties by name;
-- nil when it is empty.
function M.contents(e)
  local ok, inv = pcall(function() return e.get_inventory(defines.inventory.chest) end)
  return ok and M.top_names(inv, CONTENTS_SHOWN) or nil
end

-- The `n` kinds an inventory holds most of, most first (the chests' and the cargo wagons' icons).
function M.top_names(inv, n)
  if not inv then
    return nil
  end
  local ok_c, list = pcall(function() return inv.get_contents() end)
  if not (ok_c and type(list) == "table") then
    return nil
  end
  local counts, names = {}, {}
  for _, it in pairs(list) do
    local name = it.name
    if type(name) ~= "string" then
      local ok_n, n = pcall(function() return name.name end)
      name = ok_n and n or nil
    end
    if type(name) == "string" and (it.count or 0) > 0 then
      if not counts[name] then
        names[#names + 1] = name
        counts[name] = 0
      end
      counts[name] = counts[name] + it.count
    end
  end
  if #names == 0 then
    return nil
  end
  table.sort(names, function(a, b)
    if counts[a] ~= counts[b] then
      return counts[a] > counts[b]
    end
    return a < b
  end)
  for i = #names, n + 1, -1 do
    names[i] = nil
  end
  return names
end

-- {on, g}: the client's Alt-mode on (1) or off (0); g, its count of turnings on, comes back in each
-- `ac` so it can tell a late answer to an earlier one. On again starts over: every chest is sent.
function M.contents_cmd(cmd)
  local s = storage.f3d
  if tonumber(cmd.on) == 1 then
    local g = math.floor(tonumber(cmd.g) or 0)
    local lf = tonumber(cmd.lf) == 1
    if perf.on("alt_cadence") and s.altc and s.altc.g == g and s.altc.lf == lf then
      return
    end
    s.altc = { g = g, sent = {}, msent = {}, due = game.tick, lf = lf }
  else
    s.altc = nil
  end
end

-- The client's world was dropped (a resync, another surface): everything is sent again.
function M.contents_forget()
  local c = storage.f3d.altc
  if c then
    c.sent, c.msent, c.round, c.due, c.last_fx, c.last_fy = {}, {}, nil, game.tick, nil, nil
  end
end

local function machine_row(unit, modules, packs)
  if #modules == 0 and #packs == 0 then
    return { unit }
  end
  local row = { unit, #modules > 0 and modules or 0 }
  if #packs > 0 then
    row[3] = packs
  end
  return row
end

local function contents_row(unit, names)
  if not names then
    return { unit }
  end
  local row = { unit, names[1] }
  if #names > 1 then
    local more = {}
    for i = 2, #names do
      more[#more + 1] = names[i]
    end
    row[3] = more
  end
  return row
end

local function area_strips(f)
  local r = f.r
  if r <= 64 then
    return { { { f.x - r, f.y - r }, { f.x + r, f.y + r } } }, CONTENTS_FIND_PRICE
  end
  return {
    { { f.x - r, f.y - r }, { f.x + r, f.y } },
    { { f.x - r, f.y }, { f.x + r, f.y + r } },
  }, math.floor(CONTENTS_FIND_PRICE / 2)
end

local function append_unique(round, found)
  local added = round.added
  local list = round.list
  for _, e in ipairs(found) do
    local u = e.unit_number
    if not u or not added[u] then
      if u then
        added[u] = true
      end
      list[#list + 1] = e
    end
  end
end

local function contents_tick()
  local s = storage.f3d
  local c = s.altc
  if not c then
    return
  end
  local cadence = perf.on("alt_cadence")
  local round = c.round
  if not cadence and round and round.searches then
    c.round, round = nil, nil
  end
  if not round then
    if game.tick < (c.due or 0) then
      return
    end
    local surface = game.get_surface(s.surface_index)
    local types = present_container_types()
    if not (surface and surface.valid and #types > 0 and s.focus) then
      return
    end
    local machines = perf.on("alt_machines") and present_machine_names(perf.on("alt_ammo_fuel"), c.lf) or {}
    local f = s.focus
    if not cadence then
      local price = CONTENTS_FIND_PRICE * (#machines > 0 and 2 or 1)
      if not budget.can(price, "altc", 0.1) then
        return
      end
      budget.spend(price, "altc")
      local area = { { f.x - f.r, f.y - f.r }, { f.x + f.r, f.y + f.r } }
      round = { i = 1, seen = {}, list = surface.find_entities_filtered({ area = area, type = types }) }
      M.counts.container_scans = M.counts.container_scans + 1
      if #machines > 0 then
        -- After the chests, in the same round.
        for _, e in ipairs(surface.find_entities_filtered({ area = area, name = machines })) do
          round.list[#round.list + 1] = e
        end
        M.counts.machine_scans = M.counts.machine_scans + 1
      end
      c.round = round
    else
      local strips, find_price = area_strips(f)
      if not budget.can(find_price, "altc", 0.1) then
        return
      end
      budget.spend(find_price, "altc")
      local moved = c.last_fx and math.max(math.abs(f.x - c.last_fx), math.abs(f.y - c.last_fy)) or 0
      c.last_fx, c.last_fy = f.x, f.y
      local searches = {}
      for _, box in ipairs(strips) do
        searches[#searches + 1] = { "container", box }
      end
      if #machines > 0 then
        for _, box in ipairs(strips) do
          searches[#searches + 1] = { "machine", box }
        end
      end
      round = { i = 1, seen = {}, list = {}, added = {}, searches = searches, si = 2, find_tick = game.tick,
        find_price = find_price, moved = moved, r = f.r }
      append_unique(round, surface.find_entities_filtered({ area = searches[1][2], type = types }))
      M.counts.container_scans = M.counts.container_scans + 1
      c.round = round
    end
  elseif cadence and round.si and round.si <= #round.searches and game.tick > (round.find_tick or -1) then
    local surface = game.get_surface(s.surface_index)
    local step = round.searches[round.si]
    local find_price = round.find_price or CONTENTS_FIND_PRICE
    if surface and surface.valid and budget.can(find_price, "altc", 0.1) then
      budget.spend(find_price, "altc")
      round.si = round.si + 1
      round.find_tick = game.tick
      if step[1] == "container" then
        local types = present_container_types()
        if #types > 0 then
          append_unique(round, surface.find_entities_filtered({ area = step[2], type = types }))
          M.counts.container_scans = M.counts.container_scans + 1
        end
      else
        local machines = perf.on("alt_machines") and present_machine_names(perf.on("alt_ammo_fuel"), c.lf) or {}
        if #machines > 0 then
          append_unique(round, surface.find_entities_filtered({ area = step[2], name = machines }))
          M.counts.machine_scans = M.counts.machine_scans + 1
        end
      end
    end
  end
  c.msent = c.msent or {}
  local searches_done = not round.searches or round.si > #round.searches
  local out, mout
  for _ = 1, CONTENTS_PER_TICK do
    local e = round.list[round.i]
    if e == nil then
      if not searches_done then
        break
      end
      -- The round is over: chests and machines not in it any more lose their icons.
      for unit in pairs(c.sent) do
        if not round.seen[unit] then
          c.sent[unit] = nil
          out = out or {}
          out[#out + 1] = { unit }
        end
      end
      for unit in pairs(c.msent) do
        if not round.seen[unit] then
          c.msent[unit] = nil
          mout = mout or {}
          mout[#mout + 1] = { unit }
        end
      end
      local interval = CONTENTS_ROUND
      if cadence and (round.moved or 0) >= MOVE_CADENCE_TILES and (round.moved or 0) < (round.r or math.huge) then
        interval = CONTENTS_ROUND_MOVE
      end
      c.round = nil
      c.due = game.tick + interval * rate.factor("ac")
      M.counts.rounds = M.counts.rounds + 1
      break
    end
    local chest = not e.valid or CONTAINER_SET[e.type]
    local price = chest and CONTENTS_PRICE or MACHINE_PRICE
    if not budget.can(price, "altc", 0.1) then
      break
    end
    budget.spend(price, "altc")
    round.i = round.i + 1
    local unit = e.valid and e.unit_number
    if unit and s.subs[chunk_key(e.position)] then
      if chest then
        local names = M.contents(e)
        local sig = names and table.concat(names, ",") or nil
        if sig then
          round.seen[unit] = true
        end
        if sig ~= c.sent[unit] then
          c.sent[unit] = sig
          out = out or {}
          out[#out + 1] = contents_row(unit, names)
        end
      else
        local modules, packs = M.machine_icons(e)
        local sig
        if modules and (#modules > 0 or #packs > 0) then
          sig = items_sig(modules) .. "|" .. items_sig(packs)
          round.seen[unit] = true
        end
        if sig ~= c.msent[unit] then
          c.msent[unit] = sig
          mout = mout or {}
          mout[#mout + 1] = machine_row(unit, modules or {}, packs or {})
        end
      end
    end
  end
  if out then
    transport.send_reliable({ t = "ac", g = c.g, l = out })
  end
  if mout then
    transport.send_reliable({ t = "am", g = c.g, l = mout })
  end
end

-- A few watched machines a tick, a round at most every ROUND_TICKS: those whose icon changed are
-- sent in one `aiu`. Entries gone or no longer streamed are dropped when the round ends (clearing
-- keys behind the cursor while it walks would break `next`).
function M.tick()
  contents_tick()
  local s = storage.f3d
  local w = s.altw
  if not w or game.tick < (s.altw_due or 0) then
    return
  end
  if s.altw_cursor ~= nil and not w[s.altw_cursor] then
    s.altw_cursor = nil -- its entry went (M.recorded): start the round again
  end
  local out, fa
  for _ = 1, WATCH_PER_TICK do
    if not budget.can(WATCH_PRICE, "alt", 0.1) then
      break
    end
    local unit, entry = next(w, s.altw_cursor)
    if unit == nil then
      s.altw_cursor = nil
      for _, u in ipairs(s.altw_dead or {}) do
        w[u] = nil
      end
      s.altw_dead = nil
      s.altw_due = game.tick + ROUND_TICKS
      break
    end
    s.altw_cursor = unit
    budget.spend(WATCH_PRICE, "alt")
    local e = entry.e
    if not (e.valid and s.subs[entry.k]) then
      s.altw_dead = s.altw_dead or {}
      s.altw_dead[#s.altw_dead + 1] = unit
    else
      local icon, arrows, v = M.state(e)
      if v ~= entry.v then
        entry.v = v
        out = out or {}
        out[#out + 1] = row(unit, icon)
        fa = fa or {}
        fa[#fa + 1] = M.fa_row(e, arrows)
      end
    end
  end
  if out then
    transport.send_reliable({ t = "aiu", l = out, fa = fa })
  end
end

return M
