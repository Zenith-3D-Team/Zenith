-- The logistic network: what logistic chests and roboports show in their screens (mode, requests,
-- a storage chest's filter, the network's robots and contents), the character's own logistic
-- requests (`clog`), the network the character stands in (`ln`) and what robots near the focus
-- carry (`rc`). 2.x keeps requests in logistic sections: the client edits every active section's
-- requests as one list (write_requests), or the sections one by one (set_section).

local registry = require("scripts.registry")
local transport = require("scripts.transport")
local world = require("scripts.world")
local puppet = require("scripts.puppet")
local space = require("scripts.space")
local rate = require("scripts.rate")
local robots = require("scripts.robots")

local M = {}

local NETWORK_INTERVAL = 60
local CHARACTER_INTERVAL = 30
local CARGO_INTERVAL = 10
local MAX_ITEMS = 200       -- network contents listed in a screen
local MAX_ROBOTS = 2000
local NO_MAX = -1

local ROBOT_TYPES = { "logistic-robot", "construction-robot" }

---------------------------------------------------------------------------------------------
-- Requests as plain data: [[item, min, max (-1 for none), quality?], ...]

-- `owner` has sections (LuaLogisticSections or LuaLogisticPoint). A save's requests are often in
-- several sections, and in groups shared between characters and chests ("Main" in the owner's
-- save), so every active section counts, not only section 1.
local function active_sections(owner)
  local ok, sections = pcall(function() return owner.sections end)
  local out = {}
  if ok and sections then
    for _, section in pairs(sections) do
      local ok2, active = pcall(function() return section.active end)
      if not ok2 or active ~= false then
        out[#out + 1] = section
      end
    end
    return out
  end
  -- Older fakes and builds: only get_section.
  local ok3, first = pcall(function() return owner.get_section(1) end)
  if ok3 and first then
    out[1] = first
  end
  return out
end

local function item_filter(f)
  local v = f.value
  return v and v.name and (v.type == nil or v.type == "item") and v or nil
end

local function key_of(name, quality, comparator)
  local q = (quality and quality ~= "") and quality or "normal"
  local cmp = space.normalize_comparator(comparator)
  return name .. "/" .. q .. "/" .. cmp
end

local function requests_of(owner)
  local out = {}
  for _, section in ipairs(active_sections(owner)) do
    for _, f in pairs(section.filters or {}) do
      local v = item_filter(f)
      if v then
        local q = type(v.quality) == "table" and v.quality.name or v.quality
        local cmp = space.normalize_comparator(v.comparator)
        local rec = { v.name, f.min or 0, f.max or NO_MAX }
        if (q and q ~= "normal") or cmp ~= "=" then
          rec[4] = (q and q ~= "") and q or "normal"
          if cmp ~= "=" then
            rec[5] = cmp
          end
        end
        out[#out + 1] = rec
      end
    end
  end
  return out
end

local function filter_of(r)
  local f = {
    value = {
      type = "item",
      name = r[1],
      quality = type(r[4]) == "string" and prototypes.quality[r[4]] and r[4] or "normal",
      comparator = space.normalize_comparator(r[5]),
    },
    min = math.max(0, math.floor(tonumber(r[2]) or 0)),
  }
  local max = math.floor(tonumber(r[3]) or NO_MAX)
  if max >= 0 then
    f.max = math.max(max, f.min)
  end
  return f
end

-- The client sends the whole list it shows (every active section's requests). Each section keeps
-- its own: requests still listed get the new amounts in the section they are in, ones no longer
-- listed leave it, and new ones go into the first section that isn't a shared group (one is made
-- when there is none). Other sections' filters that aren't items (signals) stay as they are.
local function write_requests(owner, list)
  local wanted, order = {}, {}
  for _, r in ipairs(list) do
    if type(r) == "table" and type(r[1]) == "string" and prototypes.item[r[1]] then
      local k = key_of(r[1], r[4], r[5])
      if not wanted[k] then
        order[#order + 1] = k
      end
      wanted[k] = filter_of(r)
    end
  end
  local placed, target = {}, nil
  for _, section in ipairs(active_sections(owner)) do
    local ok_m, is_man = pcall(function() return section.is_manual end)
    if not ok_m or is_man ~= false then
      local filters, changed = {}, false
      for _, f in pairs(section.filters or {}) do
        local v = item_filter(f)
        if v then
          local q = type(v.quality) == "table" and v.quality.name or v.quality
          local k = key_of(v.name, q, v.comparator)
          local w = wanted[k]
          if w and not placed[k] then
            placed[k] = true
            filters[#filters + 1] = w
            changed = changed or w.min ~= (f.min or 0) or w.max ~= f.max
          else
            changed = true
          end
        else
          filters[#filters + 1] = f
        end
      end
      local ok, group = pcall(function() return section.group end)
      if not target and not (ok and group and group ~= "") then
        target = { section = section, filters = filters }
      end
      if changed then
        section.filters = filters
      end
    end
  end
  local new = {}
  for _, k in ipairs(order) do
    if not placed[k] then
      new[#new + 1] = wanted[k]
    end
  end
  if #new == 0 then
    return
  end
  if not target then
    local section = owner.add_section()
    target = { section = section, filters = {} }
  end
  for _, f in ipairs(new) do
    target.filters[#target.filters + 1] = f
  end
  target.section.filters = target.filters
end

---------------------------------------------------------------------------------------------
-- Networks

-- {id, log = [available, all], con = [available, all], items?}: a network's robots and, with
-- items, what is in its storage and provider chests (most first).
local function summary(net, with_items)
  if not (net and net.valid) then
    return nil
  end
  local out = {
    id = net.network_id,
    log = { net.available_logistic_robots, net.all_logistic_robots },
    con = { net.available_construction_robots, net.all_construction_robots },
  }
  if with_items then
    local items = {}
    for _, entry in pairs(net.get_contents()) do
      local rec = { entry.name, entry.count }
      if entry.quality and entry.quality ~= "normal" then
        rec[3] = entry.quality
      end
      items[#items + 1] = rec
    end
    table.sort(items, function(a, b)
      if a[2] ~= b[2] then
        return a[2] > b[2]
      end
      return a[1] < b[1]
    end)
    for i = MAX_ITEMS + 1, #items do
      items[i] = nil
    end
    out.items = items
  end
  return out
end

local function logistic_mode(e)
  local t = e.type == "entity-ghost" and e.ghost_type or e.type
  if t == "roboport" then
    return "roboport"
  end
  if t == "spider-vehicle" then
    return "requester"
  end
  if t ~= "logistic-container" then
    return nil
  end
  local p = e.type == "entity-ghost" and e.ghost_prototype or e.prototype
  local ok, mode = pcall(function() return p.logistic_mode end)
  return ok and mode or nil
end

function M.is_roboport(e)
  return e.type == "roboport"
end

-- For machine screens: {mode, requests?, filter?, filter_q?, cell?, net?} for logistic chests,
-- spidertrons and roboports, else nil.
function M.screen_info(e)
  local mode = logistic_mode(e)
  if not mode then
    return nil
  end
  local info = { mode = mode }
  if mode == "requester" or mode == "buffer" then
    local ok_s, sections = pcall(function() return e.get_logistic_sections() end)
    info.requests = (ok_s and sections) and requests_of(sections) or {}
  elseif mode == "storage" then
    -- 2.1 returns {name = LuaItemPrototype, quality = LuaQualityPrototype}, not names.
    local ok, filter = pcall(function() return e.get_filter(1) end)
    local name = ok and filter and filter.name
    if name and type(name) ~= "string" then
      name = name.name
    end
    info.filter = name or ""
    if ok and filter then
      local ok_q, q = pcall(function()
        local fq = filter.quality
        return type(fq) == "string" and fq or (fq and fq.name) or nil
      end)
      if ok_q and type(q) == "string" and q ~= "" and q ~= "normal" then
        info.filter_q = q
      end
    end
  elseif mode == "roboport" then
    local ok_c, cell = pcall(function() return e.logistic_cell end)
    if ok_c and cell then
      local function cell_num(fn)
        local ok_v, v = pcall(fn)
        return ok_v and type(v) == "number" and v or 0
      end
      info.cell = {
        sl = cell_num(function() return cell.stationed_logistic_robot_count end),
        sc = cell_num(function() return cell.stationed_construction_robot_count end),
        ch = cell_num(function() return cell.charging_robot_count end),
        tc = cell_num(function() return cell.to_charge_robot_count end),
      }
    end
  end
  local ok, net = pcall(function() return e.logistic_network end)
  info.net = ok and summary(net, true) or nil
  return info
end

-- {l: requests}: a requester or buffer chest's requests, every active section's (write_requests).
function M.set_requests(e, cmd)
  local mode = logistic_mode(e)
  if not (mode == "requester" or mode == "buffer") or type(cmd.l) ~= "table" then
    return puppet.message("That chest doesn't take requests")
  end
  local ok, err = pcall(function()
    write_requests(e.get_logistic_sections(), cmd.l)
  end)
  if not ok then
    puppet.message("Can't set the requests: " .. tostring(err))
  end
end

-- {item ("" clears), q?}: what a storage chest takes.
function M.set_storage_filter(e, cmd)
  if logistic_mode(e) ~= "storage" then
    return puppet.message("That isn't a storage chest")
  end
  local item = tostring(cmd.item or "")
  if item == "" then
    pcall(function() e.set_filter(1) end)
  elseif prototypes.item[item] then
    local q = cmd.q
    local ok_q, has_q = pcall(function() return type(q) == "string" and q ~= "" and q ~= "normal" and prototypes.quality[q] ~= nil end)
    if ok_q and has_q then
      pcall(function() e.set_filter(1, { name = item, quality = q }) end)
    else
      pcall(function() e.set_filter(1, item) end)
    end
  end
end

---------------------------------------------------------------------------------------------
-- The character's logistics

-- {on, trash, l, sec, lgs}: whether its requests are active, whether unrequested items go to the
-- trash, its requests (every active section's), its logistic sections one by one (space.lua's
-- form: group, on, multiplier, filters) and the force's logistic group names; nil without a
-- requester point, which a character only has once its force has character_logistic_requests
-- (the logistic robotics research).
local function character_state(c)
  local ok, point = pcall(function() return c.get_requester_point() end)
  if not (ok and point) then
    return nil
  end
  local ok2, sec = pcall(space.sections_list, point)
  local ok3, groups = pcall(function() return c.force.get_logistic_groups() end)
  local del, pick = space.point_transfers(point)
  return { on = point.enabled and 1 or 0, trash = point.trash_not_requested and 1 or 0, l = requests_of(point),
    sec = ok2 and sec or nil, lgs = ok3 and groups or nil, del = del, pick = pick }
end

local function signature(state)
  local parts = { state.on, state.trash }
  for _, r in ipairs(state.l) do
    parts[#parts + 1] = table.concat(r, ":")
  end
  for _, sec in ipairs(state.sec or {}) do
    parts[#parts + 1] = table.concat({ sec.i, sec.g, sec.on, sec.m, sec.man, #sec.f }, "/")
    for _, f in ipairs(sec.f) do
      parts[#parts + 1] = table.concat(f, ":")
    end
  end
  for _, d in ipairs(state.del or {}) do
    parts[#parts + 1] = "d:" .. table.concat(d, ":")
  end
  for _, p in ipairs(state.pick or {}) do
    parts[#parts + 1] = "p:" .. table.concat(p, ":")
  end
  parts[#parts + 1] = table.concat(state.lgs or {}, "|")
  return table.concat(parts, ",")
end

local function send_character(c, force)
  local s = storage.f3d
  local state = c and character_state(c)
  if not state then
    return
  end
  local sig = signature(state)
  if force or sig ~= s.clog_sig then
    s.clog_sig = sig
    local msg = { t = "clog", on = state.on, trash = state.trash, l = state.l, sec = state.sec, lgs = state.lgs }
    if state.del then
      msg.del = state.del
    end
    if state.pick then
      msg.pick = state.pick
    end
    transport.send_reliable(msg)
  end
end

-- set_section with u = 0: the character's own logistic sections (add, delete, group, on/off,
-- multiplier, filters), as the hub's and chests' are edited.
function M.set_char_section(cmd)
  local c = puppet.get()
  local ok, point = pcall(function() return c and c.get_requester_point() end)
  if not (ok and point) then
    return puppet.message("No logistic requests yet (research them first)")
  end
  local ok2, err = pcall(space.write_section, point, cmd)
  if not ok2 then
    puppet.message("Can't change that section: " .. tostring(err))
  end
  send_character(c, false)
end

-- {c = [r, g, b]}: the character's colour, and its player's (and chat colour) when a player
-- plays it.
function M.set_char_color(cmd)
  local c = puppet.get()
  local col = cmd.c
  if not (c and type(col) == "table" and #col >= 3) then
    return
  end
  local color = {}
  for i, k in ipairs({ "r", "g", "b" }) do
    color[k] = math.max(0, math.min(255, tonumber(col[i]) or 0)) / 255
  end
  color.a = 1
  local ok, err = pcall(function() c.color = color end)
  if not ok then
    return puppet.message("Can't set the colour: " .. tostring(err))
  end
  local okp, p = pcall(function() return c.player end)
  if okp and p then
    pcall(function()
      p.color = color
      p.chat_color = color
    end)
  end
  M.send_color(c, true)
end

-- `ccol`: the character's colour as [r, g, b] in 0-255, when it changes.
function M.send_color(c, force)
  if not c then
    return
  end
  local ok, col = pcall(function() return c.color end)
  if not (ok and col) then
    return
  end
  local rgb = { math.floor((col.r or 0) * 255 + 0.5), math.floor((col.g or 0) * 255 + 0.5), math.floor((col.b or 0) * 255 + 0.5) }
  local sig = table.concat(rgb, ",")
  local s = storage.f3d
  if force or sig ~= s.ccol_sig then
    s.ccol_sig = sig
    transport.send_reliable({ t = "ccol", c = rgb })
  end
end

-- {l?, on?, trash?}: the character's requests, whether they are on, and auto-trash.
function M.set_char_requests(cmd)
  local c = puppet.get()
  local ok, point = pcall(function() return c and c.get_requester_point() end)
  if not (ok and point) then
    return puppet.message("No logistic requests yet (research them first)")
  end
  local ok2, err = pcall(function()
    if type(cmd.l) == "table" then
      write_requests(point, cmd.l)
    end
    if cmd.on ~= nil then
      point.enabled = cmd.on == 1 or cmd.on == true
    end
    if cmd.trash ~= nil then
      point.trash_not_requested = cmd.trash == 1 or cmd.trash == true
    end
  end)
  if not ok2 then
    puppet.message("Can't set the requests: " .. tostring(err))
  end
  send_character(c, false)
end

---------------------------------------------------------------------------------------------

-- [unit, item id, count, ...] for robots near the focus that carry something, and how many robots
-- were looked at.
local function get_stack_quality(stack)
  local q = stack.quality
  return q and q.name or nil
end

local function robot_cargo(s, r)
  local flat = {}
  local qualities = {}
  local any_q = false
  local types = {}
  for _, t in ipairs(ROBOT_TYPES) do
    if registry.is_mover(t) then
      types[#types + 1] = t
    end
  end
  if #types == 0 then
    return flat, 0, nil
  end
  local f = s.focus
  local index = defines.inventory.robot_cargo
  local found = world.surface().find_entities_filtered({
    area = { { f.x - r, f.y - r }, { f.x + r, f.y + r } }, type = types, limit = MAX_ROBOTS,
  })
  for _, robot in pairs(found) do
    local inventory = robot.get_inventory(index)
    local stack = inventory and inventory[1]
    if robot.unit_number and stack and stack.valid_for_read then
      flat[#flat + 1] = robot.unit_number
      flat[#flat + 1] = registry.item_id(stack.name)
      flat[#flat + 1] = stack.count
      local okq, q = pcall(get_stack_quality, stack)
      local qn = (okq and type(q) == "string") and q or "normal"
      if qn ~= "normal" then
        any_q = true
        qualities[#qualities + 1] = robot.unit_number
        qualities[#qualities + 1] = qn
      end
    end
  end
  return flat, #found, any_q and qualities or nil
end

function M.tick()
  local s = storage.f3d
  local c = puppet.get()
  if not c then
    return
  end
  local t = game.tick
  if t % CHARACTER_INTERVAL == 0 then
    send_character(c, false)
    M.send_color(c, false)
  end
  if t % NETWORK_INTERVAL == 0 then
    local ok, net = pcall(function() return c.force.find_logistic_network_by_position(c.position, c.surface) end)
    local info = ok and summary(net, false) or nil
    transport.send_now(info and { t = "ln", id = info.id, log = info.log, con = info.con } or { t = "ln", id = 0 })
  end
  if not robots.active() and rate.due("rc", CARGO_INTERVAL) then
    local r = math.min(settings.global["f3d-detail-radius"].value, s.focus.r)
    local flat, read, q = {}, 0, nil
    if r > 0 then
      flat, read, q = robot_cargo(s, r)
      local pkt = { t = "rc", l = flat }
      if q then
        pkt.q = q
      end
      transport.send_now(pkt)
    end
    rate.read("rc", read)
  end
end

---------------------------------------------------------------------------------------------
-- The logistic networks window (L): every network of the force

local LNET_MAX_ITEMS = 400
local LNET_MAX_REQ = 200
local LNET_MAX_TRANSIT = 150
local LNET_MAX_LOCS = 64
local LNET_MAX_MEMBERS = 64

local MEMBER_POINTS = {
  ["logistic-container"] = "logistic_container",
  ["cargo-landing-pad"] = "cargo_landing_pad_requester",
  ["rocket-silo"] = "rocket_silo_requester",
  ["space-platform-hub"] = "space_platform_hub_requester",
  ["character"] = "character_requester",
  ["spider-vehicle"] = "spidertron_requester",
}

local function count(list)
  return list and #list or 0
end

local function proto_name(v)
  if type(v) == "table" or type(v) == "userdata" then
    return v.name
  end
  return v
end

local function find_network_by_id(force, id)
  for surface_name, nets in pairs(force.logistic_networks or {}) do
    for _, net in pairs(nets) do
      if net.valid and net.network_id == id then
        return net, surface_name
      end
    end
  end
  return nil, nil
end

local function entity_point(e)
  local ok, pt = pcall(function() return e.get_requester_point() end)
  if ok and pt then
    return pt
  end
  local key = MEMBER_POINTS[e.type]
  if key then
    local ok2, pt2 = pcall(function()
      local idx = defines.logistic_member_index and defines.logistic_member_index[key]
      return idx and e.get_logistic_point(idx) or nil
    end)
    if ok2 and pt2 then
      return pt2
    end
  end
  return nil
end

local function entity_sections(e, pt)
  local ok, secs = pcall(function() return e.get_logistic_sections() end)
  if ok and secs then
    return secs
  end
  return pt
end

local function sum_entity_requests(e, pt, acc)
  local secs = entity_sections(e, pt)
  if not secs then
    return
  end
  pcall(function()
    local list = secs.sections
    if type(list) ~= "table" then
      return
    end
    for _, sec in pairs(list) do
      local ok_a, active = pcall(function() return sec.active end)
      if not ok_a or active ~= false then
        local ok_m, mult = pcall(function() return sec.multiplier end)
        mult = (ok_m and type(mult) == "number") and mult or 1
        for _, f in pairs(sec.filters or {}) do
          local v = f.value
          if v and v.name and (v.type == nil or v.type == "item") then
            local name = proto_name(v.name)
            if type(name) == "string" and name ~= "" then
              local q = proto_name(v.quality)
              q = (type(q) == "string" and q ~= "") and q or "normal"
              local amt = math.max(0, math.floor((tonumber(f.min) or 0) * mult + 0.5))
              if amt > 0 then
                local key = name .. "/" .. q
                local rec = acc[key]
                if rec then
                  rec[2] = rec[2] + amt
                else
                  acc[key] = { name, amt, q }
                end
              end
            end
          end
        end
      end
    end
  end)
end

local function chest_item_count(e, item, q)
  local ok, inv = pcall(function() return e.get_output_inventory() end)
  if not (ok and inv) then
    local ok2, inv2 = pcall(function() return e.get_inventory(defines.inventory.chest) end)
    inv = ok2 and inv2 or nil
  end
  if not inv then
    return 0
  end
  local ok3, cnt = pcall(function() return inv.get_item_count({ name = item, quality = q }) end)
  return (ok3 and type(cnt) == "number") and cnt or 0
end

local function trim_list(list, cap)
  for i = cap + 1, #list do
    list[i] = nil
  end
end

-- {}: `lnets` with [[id, surface index, surface name, [log available, all], [con available, all],
-- cells, storages, providers, requesters, x, y, name], ...]; x, y is a roboport's position (the
-- first cell's), for looking at it.
function M.networks()
  local c = puppet.get()
  local force = c and c.force or game.forces.player
  local l = {}
  for surface_name, nets in pairs(force.logistic_networks or {}) do
    local surface = game.get_surface(surface_name)
    for _, net in pairs(nets) do
      if net.valid then
        local cells = net.cells
        local x, y = 0, 0
        local owner = cells[1] and cells[1].owner
        if owner and owner.valid then
          x, y = world.fixed(owner.position.x), world.fixed(owner.position.y)
        end
        local ok, name = pcall(function() return net.custom_name end)
        l[#l + 1] = {
          net.network_id, surface and surface.index or 0, surface_name,
          { net.available_logistic_robots, net.all_logistic_robots },
          { net.available_construction_robots, net.all_construction_robots },
          #cells, count(net.storages), count(net.providers), count(net.requesters), x, y, ok and name or "",
        }
      end
    end
  end
  table.sort(l, function(a, b) return a[1] < b[1] end)
  transport.send_now({ t = "lnets", l = l })
end

-- {id}: `lnet` with that network's contents ({id, log, con, items, members, req, transit, ch}), or
-- `found = 0`.
function M.network(cmd)
  local c = puppet.get()
  local force = c and c.force or game.forces.player
  local id = math.floor(tonumber(cmd.id) or 0)
  local net = find_network_by_id(force, id)
  if not net then
    transport.send_now({ t = "lnet", id = id, found = 0 })
    return
  end
  local info = summary(net, false)
  info.t = "lnet"
  info.found = 1

  local contents = {}
  pcall(function() contents = net.get_contents() or {} end)
  local items, have_map = {}, {}
  for _, entry in pairs(contents) do
    local name = proto_name(entry.name)
    local q = proto_name(entry.quality)
    q = (type(q) == "string" and q ~= "") and q or "normal"
    local cnt = math.floor(tonumber(entry.count) or 0)
    if type(name) == "string" and name ~= "" and cnt > 0 then
      local key = name .. "/" .. q
      have_map[key] = (have_map[key] or 0) + cnt
      local rec = { name, cnt }
      if q ~= "normal" then
        rec[3] = q
      end
      items[#items + 1] = rec
    end
  end
  table.sort(items, function(a, b)
    if a[2] ~= b[2] then return a[2] > b[2] end
    if a[1] ~= b[1] then return a[1] < b[1] end
    return (a[3] or "normal") < (b[3] or "normal")
  end)
  trim_list(items, LNET_MAX_ITEMS)
  info.items = items

  local seen_units, seen_refs = {}, {}
  local member_counts = {}
  local function add_member(e)
    if not (e and e.valid) then
      return
    end
    local uid = e.unit_number
    if uid then
      if seen_units[uid] then return end
      seen_units[uid] = true
    else
      if seen_refs[e] then return end
      seen_refs[e] = true
    end
    local name = e.name
    member_counts[name] = (member_counts[name] or 0) + 1
  end

  local ch_cur, ch_wait = 0, 0
  local ok_cells, cells = pcall(function() return net.cells end)
  if ok_cells and type(cells) == "table" then
    for _, cell in pairs(cells) do
      local ok_o, owner = pcall(function() return cell.owner end)
      if ok_o then add_member(owner) end
      local okc, cc = pcall(function() return cell.charging_robot_count end)
      if okc and type(cc) == "number" then
        ch_cur = ch_cur + cc
      else
        local okr, cr = pcall(function() return cell.charging_robots end)
        if okr and type(cr) == "table" then ch_cur = ch_cur + #cr end
      end
      local okw, cw = pcall(function() return cell.to_charge_robot_count end)
      if okw and type(cw) == "number" then
        ch_wait = ch_wait + cw
      else
        local okr, tr = pcall(function() return cell.to_charge_robots end)
        if okr and type(tr) == "table" then ch_wait = ch_wait + #tr end
      end
    end
  end
  for _, field in ipairs({ "storages", "providers", "active_providers", "requesters" }) do
    local ok_l, list = pcall(function() return net[field] end)
    if ok_l and type(list) == "table" then
      for _, e in pairs(list) do
        add_member(e)
      end
    end
  end
  local members = {}
  for name, cnt in pairs(member_counts) do
    members[#members + 1] = { name, cnt }
  end
  table.sort(members, function(a, b)
    if a[2] ~= b[2] then return a[2] > b[2] end
    return a[1] < b[1]
  end)
  trim_list(members, LNET_MAX_MEMBERS)
  info.members = members
  info.ch = { ch_cur, ch_wait }

  local req_acc, transit_acc = {}, {}
  local ok_r, req_list = pcall(function() return net.requesters end)
  if ok_r and type(req_list) == "table" then
    for _, e in pairs(req_list) do
      if e and e.valid then
        local pt = entity_point(e)
        sum_entity_requests(e, pt, req_acc)
        if pt then
          local del = space.point_transfers(pt)
          if del then
            for _, d in ipairs(del) do
              local name = d[1]
              local cnt = d[2]
              local q = d[3] or "normal"
              local key = name .. "/" .. q
              local rec = transit_acc[key]
              if rec then
                rec[2] = rec[2] + cnt
              else
                transit_acc[key] = { name, cnt, q }
              end
            end
          end
        end
      end
    end
  end

  local req = {}
  for key, r in pairs(req_acc) do
    local missing = math.max(0, r[2] - (have_map[key] or 0))
    local rec = { r[1], r[2], missing }
    if r[3] ~= "normal" then
      rec[4] = r[3]
    end
    req[#req + 1] = rec
  end
  table.sort(req, function(a, b)
    local am, bm = a[3] > 0, b[3] > 0
    if am ~= bm then return am end
    if a[2] ~= b[2] then return a[2] > b[2] end
    if a[1] ~= b[1] then return a[1] < b[1] end
    return (a[4] or "normal") < (b[4] or "normal")
  end)
  trim_list(req, LNET_MAX_REQ)
  info.req = req

  local transit = {}
  for _, t in pairs(transit_acc) do
    local rec = { t[1], t[2] }
    if t[3] ~= "normal" then
      rec[3] = t[3]
    end
    transit[#transit + 1] = rec
  end
  table.sort(transit, function(a, b)
    if a[2] ~= b[2] then return a[2] > b[2] end
    if a[1] ~= b[1] then return a[1] < b[1] end
    return (a[3] or "normal") < (b[3] or "normal")
  end)
  trim_list(transit, LNET_MAX_TRANSIT)
  info.transit = transit

  if #items + #req + #transit > 200 then
    local ok_j, json = pcall(helpers.table_to_json, info)
    if ok_j and type(json) == "string" and #json > 58000 then
      local ratio = 56000 / #json
      trim_list(info.items, math.max(50, math.floor(#info.items * ratio)))
      trim_list(info.req, math.max(25, math.floor(#info.req * ratio)))
      trim_list(info.transit, math.max(25, math.floor(#info.transit * ratio)))
    end
  end

  transport.send_now(info)
end

-- {id, name}: renames a logistic network and sends `lnets` right away.
function M.set_network_name(cmd)
  local c = puppet.get()
  local force = c and c.force or game.forces.player
  local id = math.floor(tonumber(cmd.id) or 0)
  local net = find_network_by_id(force, id)
  if not net then
    return
  end
  local name = tostring(cmd.name or ""):sub(1, 200)
  pcall(function() net.custom_name = name end)
  M.networks()
end

-- {id, item?, q?, proto?, role?}: locates matching entities in network `id`, sends `lnet_locs`.
function M.find_in_network(cmd)
  local c = puppet.get()
  local force = c and c.force or game.forces.player
  local id = math.floor(tonumber(cmd.id) or 0)
  local net, surface_name = find_network_by_id(force, id)
  local surface = surface_name and game.get_surface(surface_name) or nil
  local si = surface and surface.index or 0
  if not net then
    transport.send_now({ t = "lnet_locs", id = id, si = si, l = {} })
    return
  end

  local seen_units, seen_refs = {}, {}
  local locs = {}
  local function add_loc(e, cnt)
    if not (e and e.valid) then
      return
    end
    local uid = e.unit_number
    if uid then
      if seen_units[uid] then return end
      seen_units[uid] = true
    else
      if seen_refs[e] then return end
      seen_refs[e] = true
    end
    locs[#locs + 1] = { world.fixed(e.position.x), world.fixed(e.position.y), e.name, cnt }
  end

  local proto = type(cmd.proto) == "string" and cmd.proto ~= "" and cmd.proto or nil
  local item = type(cmd.item) == "string" and cmd.item ~= "" and cmd.item or nil
  local q = (type(cmd.q) == "string" and cmd.q ~= "") and cmd.q or "normal"
  local role = type(cmd.role) == "string" and cmd.role or ""

  if proto then
    local ok_cells, cells = pcall(function() return net.cells end)
    if ok_cells and type(cells) == "table" then
      for _, cell in pairs(cells) do
        local ok_o, owner = pcall(function() return cell.owner end)
        if ok_o and owner and owner.valid and owner.name == proto then
          add_loc(owner, 1)
        end
      end
    end
    for _, field in ipairs({ "storages", "providers", "active_providers", "requesters" }) do
      local ok_l, list = pcall(function() return net[field] end)
      if ok_l and type(list) == "table" then
        for _, e in pairs(list) do
          if e and e.valid and e.name == proto then
            add_loc(e, 1)
          end
        end
      end
    end
  elseif item and role == "req" then
    local key = item .. "/" .. q
    local ok_r, list = pcall(function() return net.requesters end)
    if ok_r and type(list) == "table" then
      for _, e in pairs(list) do
        if e and e.valid then
          local acc = {}
          sum_entity_requests(e, entity_point(e), acc)
          if acc[key] and acc[key][2] > 0 then
            add_loc(e, acc[key][2])
          end
        end
      end
    end
  elseif item and role == "transit" then
    local ok_r, list = pcall(function() return net.requesters end)
    if ok_r and type(list) == "table" then
      for _, e in pairs(list) do
        if e and e.valid then
          local pt = entity_point(e)
          local del = pt and space.point_transfers(pt) or nil
          if del then
            local total = 0
            for _, d in ipairs(del) do
              if d[1] == item and (d[3] or "normal") == q then
                total = total + d[2]
              end
            end
            if total > 0 then
              add_loc(e, total)
            end
          end
        end
      end
    end
  elseif item then
    for _, field in ipairs({ "storages", "providers", "active_providers" }) do
      local ok_l, list = pcall(function() return net[field] end)
      if ok_l and type(list) == "table" then
        for _, e in pairs(list) do
          if e and e.valid then
            local cnt = chest_item_count(e, item, q)
            if cnt > 0 then
              add_loc(e, cnt)
            end
          end
        end
      end
    end
  end

  table.sort(locs, function(a, b)
    if a[4] ~= b[4] then return a[4] > b[4] end
    if a[1] ~= b[1] then return a[1] < b[1] end
    return a[2] < b[2]
  end)
  trim_list(locs, LNET_MAX_LOCS)
  transport.send_now({ t = "lnet_locs", id = id, si = si, l = locs })
end

-- After a handshake: the character's requests again.
function M.send_initial()
  storage.f3d.clog_sig = nil
  send_character(puppet.get(), true)
  M.send_color(puppet.get(), true)
end

return M
