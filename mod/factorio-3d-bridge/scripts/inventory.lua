-- The character's inventories slot by slot, moving stacks between slots (its own, or an open
-- machine screen's), sorting, and a quickbar. Everything Factorio's inventory window needs. The
-- older `inv` message (totals, puppet.lua) is still sent: today's client fills its inventory from
-- it only until the first `slots` arrives (ui_model.gd set_inventory_totals), clients before
-- `slots` have nothing else.
--
-- The quickbar lives in storage and changes only from client commands, so it is deterministic.
-- A player-less character has no quickbar of its own; this one outlives client restarts.

local transport = require("scripts.transport")
local puppet = require("scripts.puppet")
local screens = require("scripts.screens")

local M = {}

local SLOTS_INTERVAL = 10
local QUICKBAR_SIZE = 100 -- 10 pages of 10

-- Character inventories by role, with the defines.inventory name of each.
local ROLES = {
  { "main", "character_main" },
  { "guns", "character_guns" },
  { "ammo", "character_ammo" },
  { "armor", "character_armor" },
  { "trash", "character_trash" },
}

local function character_inventory(c, role)
  if role == "main" then
    return c.get_main_inventory()
  end
  for _, pair in ipairs(ROLES) do
    if pair[1] == role then
      local ok, index = pcall(function() return defines.inventory[pair[2]] end)
      return ok and index and c.get_inventory(index) or nil
    end
  end
  return nil
end

-- N3: "vammo", the ammo of the car or spidertron the character sits in (the tool bar's ammo slots
-- while driving).
local VEHICLE_AMMO = { car = "car_ammo", ["spider-vehicle"] = "spider_ammo" }
local function vehicle_ammo(c)
  local v = puppet.vehicle(c)
  local name = v and v.valid and VEHICLE_AMMO[v.type]
  local ok, inv = pcall(function() return name and v.get_inventory(defines.inventory[name]) end)
  return ok and inv or nil
end

-- A character inventory, the vehicle's ammo, or the open machine screen's inventory with that
-- role (chest, input...).
local function inventory_for(c, role, cmd)
  if role == "vammo" then
    return vehicle_ammo(c)
  end
  return character_inventory(c, role) or screens.inventory(role, cmd)
end

local function quality_of(stack)
  local ok, q = pcall(function() return stack.quality.name end)
  return ok and q or "normal"
end

local function same_item(a, b)
  return a.name == b.name and quality_of(a) == quality_of(b)
end

local function take_from(src, n)
  if n >= src.count then
    src.clear()
  else
    src.count = src.count - n
  end
end

-- Moves up to `n` from one stack into another (as much as fits), keeping the item's own data
-- (ammo, health, spoilage) where the game allows. LuaItemStack::transfer_stack takes an amount
-- in 2.x; if it doesn't, a part is moved by counts.
local function transfer(dst, src, n)
  if n >= src.count then
    dst.transfer_stack(src)
    return
  end
  if pcall(function() dst.transfer_stack(src, n) end) then
    return
  end
  if dst.valid_for_read then
    local room = math.min(n, dst.prototype.stack_size - dst.count)
    if room > 0 then
      dst.count = dst.count + room
      take_from(src, room)
    end
  elseif dst.set_stack({ name = src.name, count = n, quality = quality_of(src) }) then
    take_from(src, n)
  end
end

---------------------------------------------------------------------------------------------
-- State sent to the client

local function signature(lists)
  local parts = {}
  for role, list in pairs(lists) do
    local slots = {}
    for i, slot in ipairs(list) do
      slots[i] = slot == 0 and "" or table.concat(slot, "/")
    end
    parts[#parts + 1] = role .. "=" .. table.concat(slots, ",")
  end
  table.sort(parts)
  return table.concat(parts, ";")
end

-- The main inventory's slot filters (Factorio's middle click): [[slot, item], ...].
local function filter_list(inventory)
  local out = {}
  local ok, supports = pcall(function() return inventory.supports_filters() end)
  if not (ok and supports) then
    return out
  end
  for i = 1, #inventory do
    local f = inventory.get_filter(i)
    local name = type(f) == "table" and f.name or f
    if type(name) == "table" then
      name = name.name
    end
    if type(name) == "string" then
      out[#out + 1] = { i, name }
    end
  end
  return out
end

local PLANNERS = { blueprint = true, ["blueprint-book"] = true, ["deconstruction-planner"] = true, ["upgrade-planner"] = true }

-- The icons the player gave each blueprint, book and planner in the main inventory, which Factorio
-- draws over the item: [[slot, [[type, name], ...]], ...] in their order, and a signature of them.
local function planner_icons(inventory)
  local out, sig = {}, {}
  for i = 1, #inventory do
    local stack = inventory[i]
    if stack.valid_for_read and PLANNERS[stack.name] then
      local ok, icons = pcall(function() return stack.preview_icons end)
      local list = {}
      for _, icon in pairs(ok and icons or {}) do
        local signal = icon.signal or {}
        if signal.name then
          list[#list + 1] = { icon.index or #list + 1, signal.type or "item", signal.name }
        end
      end
      table.sort(list, function(a, b) return a[1] < b[1] end)
      if #list > 0 then
        local pairs_ = {}
        for j, l in ipairs(list) do
          pairs_[j] = { l[2], l[3] }
          sig[#sig + 1] = i .. ":" .. l[2] .. ":" .. l[3]
        end
        out[#out + 1] = { i, pairs_ }
      end
    end
  end
  return out, table.concat(sig, ",")
end

local function send_slots(c, s)
  local lists = {}
  for _, pair in ipairs(ROLES) do
    local inventory = character_inventory(c, pair[1])
    if inventory then
      lists[pair[1]] = screens.slot_list(inventory)
    end
  end
  local main = character_inventory(c, "main")
  local filters = main and filter_list(main) or {}
  local fsig = {}
  for i, f in ipairs(filters) do
    fsig[i] = f[1] .. "=" .. f[2]
  end
  local icons, isig = {}, ""
  if main then
    icons, isig = planner_icons(main)
  end
  local sig = signature(lists) .. "|" .. table.concat(fsig, ",") .. "|" .. isig
  if sig ~= s.slots_sig then
    s.slots_sig = sig
    local msg = { t = "slots", l = lists }
    if #filters > 0 then
      msg.fl = filters
    end
    if #icons > 0 then
      msg.ic = icons
    end
    transport.send_reliable_priority(msg)
  end
end

-- The quickbar: 10 pages of 10. In single-player (hybrid mode) the character's player has a real
-- one, which the Factorio window shows too, so the bridge reads and writes that; for a player-less
-- character the bridge keeps its own in storage. The selected slot is the bridge's either way.
local function quickbar()
  local s = storage.f3d
  s.quickbar = s.quickbar or { page = 1, sel = 0, items = {} }
  return s.quickbar
end

-- The player whose quickbar this is: the one playing the character, or the one the bridge's
-- character stands in for on a server (their quickbar stays with them while they're away).
local function quickbar_player()
  local c = puppet.get()
  return c and (puppet.player_of(c) or puppet.held_for())
end

local function page_and_slot(i)
  return math.ceil(i / 10), (i - 1) % 10 + 1
end

-- The item in the player's slot i, or "" (empty, or something that isn't an item filter).
local function player_slot(p, i)
  local ok, slot = pcall(p.get_quick_bar_slot, page_and_slot(i))
  if not (ok and slot) then
    return ""
  end
  local ok2, name = pcall(function() return slot.filter and slot.filter.name end)
  return ok2 and name or ""
end

local function quickbar_state()
  local qb = quickbar()
  local p = quickbar_player()
  local list = {}
  for i = 1, QUICKBAR_SIZE do
    list[i] = p and player_slot(p, i) or (qb.items[i] or "")
  end
  local page = qb.page
  if p then
    local ok, active = pcall(p.get_active_quick_bar_page, 1)
    page = ok and active or page
  end
  return list, page
end

local function send_quickbar()
  local qb = quickbar()
  local list, page = quickbar_state()
  qb.sig = table.concat(list, ",") .. "|" .. page .. "|" .. qb.sel
  transport.send_reliable_priority({ t = "qb", p = page, sel = qb.sel, held = list[qb.sel] or "", l = list })
end

-- The slots now, if they changed (ui_actions.lua's Ctrl+clicks: the client's hand and its sound
-- follow them, I1, I3).
function M.send_slots_now()
  local c = puppet.get()
  if c then
    send_slots(c, storage.f3d)
  end
end

local sending_from_changed = false

-- And after the character mined something (J20: the hand's count and the quickbar follow at once).
puppet.mined_listeners[#puppet.mined_listeners + 1] = function(c)
  send_slots(c, storage.f3d)
end

-- And after send_inventory_now or screens.take (auto-sort sees slot changes without waiting for SLOTS_INTERVAL).
puppet.inventory_listeners[#puppet.inventory_listeners + 1] = function(c)
  if not sending_from_changed then
    send_slots(c, storage.f3d)
  end
end

screens.take_listeners[#screens.take_listeners + 1] = function(c)
  send_slots(c, storage.f3d)
end

-- Right after a command: the client sees the result on the next tick instead of within half a
-- second.
local function changed()
  local c = puppet.get()
  if c then
    send_slots(c, storage.f3d)
  end
  sending_from_changed = true
  local ok, err = pcall(puppet.send_inventory_now)
  sending_from_changed = false
  if not ok then
    error(err)
  end
  screens.refresh()
end

---------------------------------------------------------------------------------------------
-- Commands

local READ_ONLY = { output = true, burnt = true }

local function belt_lane_of(role)
  if role == "belt_1" then
    return 1
  elseif role == "belt_2" then
    return 2
  end
  return nil
end

local function remove_from_line_stack(line, st, name, q, count, taken)
  local ok, shrunk = pcall(function()
    if taken >= count then
      st.clear()
      return not st.valid_for_read
    end
    st.count = count - taken
    return st.count == count - taken
  end)
  if not (ok and shrunk) then
    pcall(line.remove_item, { name = name, count = taken, quality = q })
  end
end

local function take_from_held_stack(held, before, taken)
  pcall(function()
    if taken >= before then
      held.clear()
    else
      held.count = before - taken
    end
  end)
end

-- Moves the stack in slot `fi` of inventory `from` to slot `ti` of inventory `to`, like clicking
-- in Factorio: into an empty slot or onto the same item (as much as fits), or swapping with a
-- different item. `n` moves only that many (0 or absent: the whole stack). Roles are the
-- character's (main, guns, ammo, armor, trash), the ridden vehicle's ammo (vammo) or the open
-- screen's (chest, input, output, fuel, burnt, modules, hand, belt_1, belt_2), which also need `u`.
function M.move(cmd)
  local c = puppet.get()
  if not c then
    return
  end
  local from_role, to_role = tostring(cmd.from or ""), tostring(cmd.to or "")
  local fi, ti = math.floor(tonumber(cmd.fi) or 0), math.floor(tonumber(cmd.ti) or 0)
  -- A machine's output and burnt-result slots only give: the script API's transfer_stack would
  -- fill a furnace's result slot with anything (an assembler's has a filter from its recipe).
  if READ_ONLY[to_role] then
    return puppet.message("Can't put that there")
  end
  if from_role == "hand" or to_role == "hand" then
    local e = cmd.u and screens.entity(cmd) or nil
    if not (e and e.type == "inserter") then
      return
    end
    local okh, held = pcall(function() return e.held_stack end)
    if not (okh and held) then
      return
    end
    if from_role == "hand" and to_role ~= "hand" then
      local to = inventory_for(c, to_role, cmd)
      if not (to and fi == 1 and ti >= 1 and ti <= #to and held.valid_for_read) then
        return
      end
      local dst = to[ti]
      local before = held.count
      local n = math.floor(tonumber(cmd.n) or 0)
      if n <= 0 or n > before then
        n = before
      end
      local moved = false
      if dst.valid_for_read and not same_item(held, dst) then
        if n == before then
          local oks, swapped = pcall(function() return held.swap_stack(dst) end)
          moved = oks and swapped == true
        end
      elseif not dst.valid_for_read then
        local ok_tr = pcall(transfer, dst, held, n)
        if ok_tr and (not held.valid_for_read or held.count < before) then
          moved = true
        elseif dst.set_stack({ name = held.name, count = n, quality = quality_of(held) }) then
          take_from_held_stack(held, before, n)
          moved = true
        end
      else
        local room = math.min(n, dst.prototype.stack_size - dst.count)
        if room > 0 then
          local ok_tr = pcall(transfer, dst, held, room)
          if ok_tr and (not held.valid_for_read or held.count < before) then
            moved = true
          else
            dst.count = dst.count + room
            take_from_held_stack(held, before, room)
            moved = true
          end
        end
      end
      if not moved then
        puppet.message("Can't put that there")
      end
      changed()
      return
    elseif to_role == "hand" and from_role ~= "hand" then
      local from = inventory_for(c, from_role, cmd)
      if not (from and ti == 1 and fi >= 1 and fi <= #from) then
        return
      end
      local src = from[fi]
      if not src.valid_for_read then
        return
      end
      local moved = false
      if not held.valid_for_read then
        local before = src.count
        local n = math.floor(tonumber(cmd.n) or 0)
        if n <= 0 or n > before then
          n = before
        end
        local ok_tr = pcall(transfer, held, src, n)
        moved = ok_tr and (not src.valid_for_read or src.count < before)
        if not moved then
          local q = quality_of(src)
          if pcall(function() return held.set_stack({ name = src.name, count = n, quality = q }) end) then
            take_from(src, n)
            moved = true
          end
        end
      end
      if not moved then
        puppet.message("Can't put that there")
      end
      changed()
      return
    end
    return
  end
  local from_lane = belt_lane_of(from_role)
  if from_lane then
    local e = cmd.u and screens.entity(cmd) or nil
    local to = inventory_for(c, to_role, cmd)
    if not (e and e.type == "transport-belt" and to and ti >= 1 and ti <= #to) then
      return
    end
    local okl, line = pcall(function() return e.get_transport_line(from_lane) end)
    if not (okl and line) then
      return
    end
    local okn, len = pcall(function() return #line end)
    if not (okn and fi >= 1 and fi <= len) then
      return
    end
    local st = line[fi]
    if not (st and st.valid_for_read) then
      return
    end
    local dst = to[ti]
    local before = st.count
    local n = math.floor(tonumber(cmd.n) or 0)
    if n <= 0 or n > before then
      n = before
    end
    local q = quality_of(st)
    local name = st.name
    local moved = false
    if not dst.valid_for_read then
      if dst.set_stack({ name = name, count = n, quality = q }) then
        remove_from_line_stack(line, st, name, q, before, n)
        moved = true
      end
    elseif dst.name == name and quality_of(dst) == q then
      local room = math.min(n, dst.prototype.stack_size - dst.count)
      if room > 0 then
        dst.count = dst.count + room
        remove_from_line_stack(line, st, name, q, before, room)
        moved = true
      end
    end
    if moved then
      screens.belt_lanes_changed(e)
    else
      puppet.message("Can't put that there")
    end
    changed()
    return
  end
  if belt_lane_of(to_role) then
    puppet.message("Can't put that there")
    return
  end
  local from = inventory_for(c, from_role, cmd)
  local to = inventory_for(c, to_role, cmd)
  if not (from and to and fi >= 1 and fi <= #from and ti >= 1 and ti <= #to) then
    return
  end
  local src, dst = from[fi], to[ti]
  if not src.valid_for_read or (from == to and fi == ti) then
    return
  end
  local before = src.count
  local n = math.floor(tonumber(cmd.n) or 0)
  if n <= 0 or n > before then
    n = before
  end
  local moved
  if dst.valid_for_read and not same_item(src, dst) then
    -- (Not out of an output slot: the other stack would land in it.)
    moved = n == before and not READ_ONLY[tostring(cmd.from or "")] and src.swap_stack(dst)
  else
    transfer(dst, src, n)
    moved = not src.valid_for_read or src.count < before
  end
  if not moved then
    puppet.message("Can't put that there")
  end
  changed()
end

-- Factorio's Shift and Ctrl clicks on a slot (LuaPlayer::stack_transfers' four actions): `k`
-- "stack" (Shift+click: this stack), "half" (Shift+right click: half of it), "all" (Ctrl+click:
-- every stack of the item, or of everything from an empty slot) or "allhalf" (Ctrl+right click:
-- half of each). They go to "the other inventory": from the character to the open screen's entity
-- (wherever the game puts it, like an inserter: fuel to fuel, ingredients to the input), from the
-- screen to the character, or with no screen open between the main inventory and the guns, ammo
-- and armour. With a player playing the character (hybrid mode) the game does it itself.
local XFER_ACTIONS = { stack = "stack_transfer", half = "stack_split", all = "inventory_transfer", allhalf = "inventory_split" }
local TOOLBELT = { gun = "guns", ammo = "ammo", armor = "armor" }

-- What Shift+right and Ctrl+right clicks move of a stack: the smaller half, the bigger one staying
-- (37 moves 18, as 2.1.23's stack_transfers does; the cursor's right click takes the bigger half).
local function half_of(n)
  return math.max(1, math.floor(n / 2))
end

-- Where a stack from the character goes with no screen open: the gun, ammo or armour slots for
-- those, back to the main inventory from them.
local function toolbelt_target(c, role, stack)
  if role ~= "main" then
    return character_inventory(c, "main")
  end
  local ok, kind = pcall(function() return stack.prototype.type end)
  local to = ok and TOOLBELT[kind]
  return to and character_inventory(c, to) or nil
end

function M.xfer(cmd)
  local c = puppet.get()
  local kind = tostring(cmd.k or "")
  local role = tostring(cmd.from or "")
  if not (c and XFER_ACTIONS[kind]) then
    return
  end
  local fi = math.floor(tonumber(cmd.fi) or 0)
  if role == "hand" then
    local e = cmd.u and screens.entity(cmd) or nil
    if not (e and e.type == "inserter" and fi == 1) then
      return
    end
    local okh, held = pcall(function() return e.held_stack end)
    if not (okh and held and held.valid_for_read) then
      return
    end
    local before = held.count
    local n = (kind == "half" or kind == "allhalf") and half_of(before) or before
    local inserted = c.insert({ name = held.name, count = n, quality = quality_of(held) })
    if inserted > 0 then
      take_from_held_stack(held, before, inserted)
    else
      puppet.message("Inventory full")
    end
    changed()
    return
  end
  local lane_idx = belt_lane_of(role)
  if lane_idx then
    local e = cmd.u and screens.entity(cmd) or nil
    if not (e and e.type == "transport-belt") then
      return
    end
    local okl, line = pcall(function() return e.get_transport_line(lane_idx) end)
    if not (okl and line) then
      return
    end
    local okn, len = pcall(function() return #line end)
    local line_len = okn and len or 0
    local moved, had = 0, false
    if kind == "stack" or kind == "half" then
      if fi < 1 or fi > line_len then
        return
      end
      local st = line[fi]
      if not (st and st.valid_for_read) then
        return
      end
      had = true
      local count = st.count
      local n = kind == "half" and half_of(count) or count
      local q = quality_of(st)
      local name = st.name
      local inserted = c.insert({ name = name, count = n, quality = q })
      if inserted > 0 then
        remove_from_line_stack(line, st, name, q, count, inserted)
        moved = inserted
      end
    else
      local target_name, target_q
      if fi >= 1 and fi <= line_len then
        local st = line[fi]
        if st and st.valid_for_read then
          target_name = st.name
          target_q = quality_of(st)
        end
      end
      for _, entry in pairs(line.get_contents()) do
        local eq = entry.quality or "normal"
        if not target_name or (entry.name == target_name and eq == target_q) then
          had = true
          local n = kind == "allhalf" and half_of(entry.count) or entry.count
          local stack = { name = entry.name, count = n, quality = eq }
          local inserted = c.insert(stack)
          if inserted > 0 then
            stack.count = inserted
            line.remove_item(stack)
            moved = moved + inserted
          end
        end
      end
    end
    if moved > 0 then
      screens.belt_lanes_changed(e)
    elseif had then
      puppet.message("Inventory full")
    end
    changed()
    return
  end
  local mine = character_inventory(c, role)
  local from = mine or screens.inventory(role, cmd)
  if not (from and fi >= 1 and fi <= #from) then
    return
  end
  local e = cmd.u and screens.entity(cmd) or nil
  local to_trash = cmd.trash == 1 and role == "main" and not e
  local trash_inv = to_trash and character_inventory(c, "trash") or nil
  if to_trash and not trash_inv then
    return
  end
  if not mine and not e then
    return
  end
  local p = puppet.player_of(c)
  if p then
    local ok, moved = pcall(function()
      return p.stack_transfers({ source_inventory = from, index = fi, target = trash_inv or (mine and e) or p,
        transfer_type = defines.inventory_actions[XFER_ACTIONS[kind]] })
    end)
    if ok then
      changed()
      return
    end
  end
  local first = from[fi]
  local slots = {}
  if kind == "stack" or kind == "half" then
    if first.valid_for_read then
      slots[1] = fi
    end
  else
    for i = 1, #from do
      local st = from[i]
      if st.valid_for_read and (not first.valid_for_read or same_item(st, first)) then
        slots[#slots + 1] = i
      end
    end
  end
  local moved = 0
  for _, i in ipairs(slots) do
    local st = from[i]
    local n = (kind == "half" or kind == "allhalf") and half_of(st.count) or st.count
    local dst = (mine and e) or trash_inv or (not mine and c) or nil
    local inserted = 0
    local before = st.count
    local ok = pcall(function()
      if dst then
        inserted = dst.insert(n == st.count and st or { name = st.name, count = n, quality = quality_of(st) })
      else
        local inv = toolbelt_target(c, role, st)
        inserted = inv and inv.insert(n == st.count and st or { name = st.name, count = n, quality = quality_of(st) }) or 0
      end
    end)
    if ok and inserted > 0 then
      -- Inserting a LuaItemStack itself (to keep its spoilage and the like) already takes the
      -- items out of it in 2.1.23; a table doesn't.
      if st.valid_for_read and st.count == before then
        take_from(st, inserted)
      end
      moved = moved + inserted
    end
  end
  if moved == 0 and #slots > 0 then
    puppet.message(to_trash and "Trash slots full" or (mine and e and "Can't put that in there" or (mine and "Nowhere to put that" or "Inventory full")))
  end
  changed()
end

-- {i, item}: sets the filter of slot i of the character's main inventory ("" clears it), like
-- Factorio's middle click on a slot.
function M.set_filter(cmd)
  local c = puppet.get()
  local main = c and c.get_main_inventory()
  local i = math.floor(tonumber(cmd.i) or 0)
  if not (main and i >= 1 and i <= #main) then
    return
  end
  local item = tostring(cmd.item or "")
  local ok, set = pcall(function()
    if item == "" then
      return main.set_filter(i, nil)
    end
    return main.set_filter(i, item)
  end)
  if not (ok and set ~= false) then
    puppet.message("Can't filter that slot")
  end
  changed()
end

local SORTABLE_ROLES = { main = true, trash = true, chest = true, cargo = true, trunk = true }

-- Sorts and merges an inventory: the character's main/trash, or an open screen's chest/cargo/trunk/trash.
function M.sort(cmd)
  local c = puppet.get()
  local role = tostring(cmd.inv or "main")
  if not (c and SORTABLE_ROLES[role]) then
    return
  end
  local u = tonumber(cmd.u)
  local inventory
  if u and u ~= 0 then
    inventory = screens.inventory(role, cmd)
  else
    inventory = character_inventory(c, role) or screens.inventory(role, cmd)
  end
  if inventory then
    local ok = pcall(function() inventory.sort_and_merge() end)
    if ok then
      if (not u or u == 0) and (role == "main" or role == "trash") then
        storage.f3d.slots_sig = nil
      end
      changed()
    end
  end
end

-- Puts an item in quickbar slot i (1-100), or clears it with "".
function M.qb_set(cmd)
  local qb = quickbar()
  local i = math.floor(tonumber(cmd.i) or 0)
  local item = tostring(cmd.item or "")
  if i < 1 or i > QUICKBAR_SIZE or (item ~= "" and not prototypes.item[item]) then
    return
  end
  local p = quickbar_player()
  if p then
    local page, slot = page_and_slot(i)
    -- The filter is required but may be nil (clears the slot).
    local ok, err = pcall(p.set_quick_bar_slot, page, slot, item ~= "" and item or nil)
    if not ok then
      puppet.message("Can't set the quickbar: " .. tostring(err))
    end
  else
    qb.items[i] = item ~= "" and item or nil
  end
  send_quickbar()
end

-- Selects a quickbar slot (0 for none), kept and sent back in `qb` (sel, held); nothing in the game
-- uses it, and no client sends it since the Factorio-style quickbar (kept for tests).
function M.qb_sel(cmd)
  local qb = quickbar()
  local i = math.floor(tonumber(cmd.i) or 0)
  if i >= 0 and i <= QUICKBAR_SIZE then
    qb.sel = i
    send_quickbar()
  end
end

-- Shows quickbar page p (1-10).
function M.qb_page(cmd)
  local qb = quickbar()
  local p = math.floor(tonumber(cmd.p) or 0)
  if p >= 1 and p <= QUICKBAR_SIZE / 10 then
    qb.page = p
    local player = quickbar_player()
    if player then
      pcall(player.set_active_quick_bar_page, 1, p)
    end
    send_quickbar()
  end
end

---------------------------------------------------------------------------------------------

function M.tick()
  local c = puppet.get()
  if c and game.tick % SLOTS_INTERVAL == 0 then
    send_slots(c, storage.f3d)
    -- In hybrid mode the player can change the quickbar in the Factorio window too.
    if quickbar_player() then
      local list, page = quickbar_state()
      local qb = quickbar()
      if table.concat(list, ",") .. "|" .. page .. "|" .. qb.sel ~= qb.sig then
        send_quickbar()
      end
    end
  end
end

-- After a handshake: everything again for the new client.
function M.send_initial()
  storage.f3d.slots_sig = nil
  local c = puppet.get()
  if c then
    send_slots(c, storage.f3d)
  end
  send_quickbar()
end

return M
