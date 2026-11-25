-- Factorio's alerts for the bridge's force. LuaPlayer.get_alerts needs a player, which the
-- bridge's character hasn't, so the same alerts are worked out here: from events (entity
-- destroyed, under attack, turret firing) and from scans of the force's entities on every
-- surface (turret out of ammo, machines without power or fuel or with their output full, drills with
-- nothing left to mine, ghosts missing material or robots, damaged buildings without repair packs,
-- trains out of fuel or without a path, platform, asteroid collector and rocket silo problems).
--
-- Event alerts live in `storage` (written only from events and on_tick). Scan results only feed
-- the `al` message, so they stay module-local. One kind of scan runs per SCAN_STEP ticks, so a
-- busy base's cost is spread out.
--
-- Machines not connected to any pole (the unplugged icon) round the client's focus don't wait for
-- the pass (J5: the owner saw the icon come and go late, 10-40 s with the pass's interval and its
-- length on a big base): fluids_power.lua's read of every electric machine there, once a second,
-- says which are unplugged, and building or removing a pole or an electric machine has the machines
-- round it read again the next tick. Either sends `al` at once when the list changed. The pass still
-- finds them everywhere else.
--
-- The same goes for the other warnings Factorio draws over a machine (J22, J27, J28: the owner saw the
-- no-ammo and no-fuel icons come and go late too): turrets out of ammo, machines out of fuel and drills
-- with nothing left to mine round the focus come from that once-a-second read (fluids_power.lua reads
-- every electric type's status for `pw` anyway, and the turrets and burners it leaves out besides), a
-- turret or burner built or removed has itself read again the next tick, and items put into or taken out
-- of a building by the character (session.lua: take, put, move, xfer, fast, drop) have the buildings in
-- its reach read again 2 and 20 ticks after (a burner takes its fuel on its next update). `status_near`
-- (perf.lua) off: those kinds from the pass alone, as before.
--
-- Pipelines over Factorio's extent limit (L11, `pipeline`, pipelines.lua): one entity a fluid segment whose
-- status is pipeline_overextended. The pass reads pipes, pipes to ground and storage tanks too (a quarter of
-- a machine's cost each); a pipe-type entity or pump built, removed or turned on the focus surface has the
-- pipelines round it read the tick after (storage.f3d.al_pspots), what they find kept in storage.f3d.al_pipe,
-- and `al` goes at once when that changes. Every listed entity is read again as `al` is made, so a pipeline a
-- pump has split goes then. `pipe_alerts` (perf.lua) off: none.

local transport = require("scripts.transport")
local world = require("scripts.world")
local puppet = require("scripts.puppet")
local tracker = require("scripts.tracker")
local perf = require("scripts.perf")
local rate = require("scripts.rate")
local registry = require("scripts.registry")
local fluids_power = require("scripts.fluids_power")
local pipelines = require("scripts.pipelines")
local profile = require("scripts.profile")

local M = {}

local SEND_INTERVAL = 60
local SCAN_STEP = 40         -- the small scans (repair packs, trains, platforms), one each this often
local PER_KIND = 40          -- entities listed per kind (the count is the full number)
local GHOSTS_MAX = 3000      -- ghosts looked at per pass
local CHUNKS_PER_TICK = 32   -- the entity pass's budget per tick: chunks looked in,
local ENTITIES_PER_TICK = 40 -- and entities checked (a ghost counts 4)
-- A pass starts at most this often (the owner's save: ~0.35 ms a tick for ~7 s; at its belts, Zenith Test,
-- the pass fills the interval, 0.6 ms a tick); under `rate` level 2 and 3 it waits 2 and 4 times as
-- long between passes (rate.lua's `al`: machines without power, output full, turrets out of ammo show
-- 20-40 s late instead of 10), one of the jobs that pay for the belt updates keeping their 6 ticks.
local PASS_INTERVAL = 600
-- How long an event alert stays after its last event (ticks); Factorio's own timings aren't in
-- the API, these are close to what the game shows.
local LIFETIME = { destroyed = 30 * 60, attack = 5 * 60, fire = 5 * 60 }

-- Machines whose status says no power, no fuel, output full or nothing to mine.
local PASS_TYPES = { "ammo-turret", "entity-ghost", "assembling-machine", "furnace", "mining-drill", "lab", "inserter",
  "boiler", "beacon", "radar", "rocket-silo", "asteroid-collector", "agricultural-tower", "burner-generator", "reactor",
  "pump", "roboport" }
local NOT_DESTROYED_ALERT = { ["entity-ghost"] = true, ["tile-ghost"] = true, ["character-corpse"] = true, corpse = true,
  ["item-entity"] = true, projectile = true, ["combat-robot"] = true }

local scans = {}       -- kind -> {entries}, refreshed by the scans
-- entry -> the entity it is about, for the scans' entries: a pass is seconds old by the time it is
-- sent, and an entity mined or destroyed since is left out (owner's G19: icons over empty ground).
-- Weak keys: entries go with the scan results that hold them.
local subjects = setmetatable({}, { __mode = "k" })
local status_names
local present_types    -- filters out types this game hasn't got (find_entities_filtered rejects unknown types)
local repair_items

local function force()
  local c = puppet.get()
  return c and c.force or game.forces.player
end

local function state()
  local s = storage.f3d
  s.al = s.al or { destroyed = {}, attack = {}, fire = {}, hurt = {} }
  s.al.hurt = s.al.hurt or {}
  return s.al
end

-- [x, y, surface index, name (a ghost's: what it will build), unit, subject?]
local function entry(e, extra)
  local p = e.position
  local name = e.type == "entity-ghost" and e.ghost_name or e.name
  local rec = { world.fixed(p.x), world.fixed(p.y), e.surface.index, name, e.unit_number or 0 }
  if extra then
    rec[6] = extra
  end
  subjects[rec] = e
  return rec
end

-- A scan's entries whose entity is still there.
local function still_there(list)
  local out = {}
  for _, rec in ipairs(list) do
    local e = subjects[rec]
    if e == nil or e.valid then
      out[#out + 1] = rec
    end
  end
  return out
end

local function key_of(e)
  if e.unit_number then
    return e.unit_number
  end
  local p = e.position
  return e.surface.index .. ":" .. e.name .. ":" .. p.x .. "," .. p.y
end

local function types(list)
  if not present_types then
    present_types = {}
    for _, proto in pairs(prototypes.entity) do
      present_types[proto.type] = true
    end
  end
  local out = {}
  for _, t in ipairs(list) do
    if present_types[t] then
      out[#out + 1] = t
    end
  end
  return out
end

local function status_name(status)
  if not status_names then
    status_names = {}
    for name, value in pairs(defines.entity_status) do
      status_names[value] = name
    end
  end
  return status and status_names[status] or nil
end

---------------------------------------------------------------------------------------------
-- Events (called from combat.lua, which owns on_entity_damaged and on_entity_died)

-- A big attack on a big base remembers at most this many of each (the cloud session's cap, so
-- storage can't grow without bound between expiries).
local MAX_REMEMBERED = 500

local function remember(list, key, value)
  if list[key] ~= nil or table_size(list) < MAX_REMEMBERED then
    list[key] = value
  end
end

local function ours(e)
  return e.valid and e.force and e.force.name == force().name
end

function M.on_damaged(event)
  local e = event.entity
  if not (storage.f3d.client and e and e.valid) then
    return
  end
  local al = state()
  local by = event.force
  if ours(e) and by and by.name ~= e.force.name then
    local rec = al.attack[key_of(e)] or {}
    rec.t = game.tick
    rec.e = entry(e)
    remember(al.attack, key_of(e), rec)
    if e.unit_number then
      remember(al.hurt, e.unit_number, e)
    end
  end
  local cause = event.cause
  if cause and cause.valid and cause.type:find("turret") and ours(cause) then
    remember(al.fire, key_of(cause), { t = game.tick, e = entry(cause) })
  end
end

function M.on_died(event)
  local e = event.entity
  if not (storage.f3d.client and e and e.valid and ours(e)) or NOT_DESTROYED_ALERT[e.type] then
    return
  end
  local al = state()
  local key = key_of(e)
  remember(al.destroyed, key, { t = game.tick, e = entry(e) })
  al.attack[key] = nil
  if e.unit_number then
    al.hurt[e.unit_number] = nil
  end
end

---------------------------------------------------------------------------------------------
-- Scans

-- Factorio's warnings over machines: unplugged (no pole reaches it), no fuel, output full. No power
-- and low power aren't listed: Factorio has no alert for them, and the client draws the no-power
-- icon from `pw` (fluids_power.lua); 2.1 says no_power for a machine no pole reaches, hence the read.
-- A drill with nothing left to mine is Factorio's resources-depleted icon (J27): no alert in its bar, an icon
-- over the drill.
local STATUS_KINDS = { no_power = "no_power", not_plugged_in_electric_network = "unplugged", no_fuel = "no_fuel",
  full_output = "output_full", full_burnt_result_output = "output_full", no_minable_resources = "depleted" }
local PASS_KINDS = { "no_ammo", "unplugged", "no_fuel", "output_full", "launch", "collector",
  "no_material", "no_robots", "depleted", "pipeline" }
-- A pipe-type entity's share of the pass's per-tick budget (a base has many, and most need one status read).
local PIPE_COST = 0.25

local function networks_at(e)
  local ok, nets = pcall(function() return e.surface.find_logistic_networks_by_construction_area(e.position, e.force) end)
  return ok and nets or {}
end

-- A ghost inside a construction area: missing the item to build it, or no robot free to.
local function check_ghost(g, found)
  local nets = networks_at(g)
  if #nets == 0 then
    return
  end
  local items = g.ghost_prototype.items_to_place_this or {}
  local item = items[1] and (items[1].name or items[1])
  local have, free = false, false
  for _, net in pairs(nets) do
    if item and net.get_item_count(item) > 0 then
      have = true
    end
    if net.available_construction_robots > 0 then
      free = true
    end
  end
  if item and not have then
    table.insert(found.no_material, entry(g, item))
  elseif not free then
    table.insert(found.no_robots, entry(g, item))
  end
end

-- What one entity of the pass adds; returns its cost in the per-tick budget.
local function check_entity(e, found)
  if e.type == "ammo-turret" then
    local inv = e.get_inventory(defines.inventory.turret_ammo)
    if inv and inv.is_empty() then
      table.insert(found.no_ammo, entry(e))
    end
    return 1
  elseif e.type == "entity-ghost" then
    check_ghost(e, found)
    return 4
  end
  local name = status_name(e.status)
  local kind = name and STATUS_KINDS[name]
  if kind == "no_power" then
    kind = not e.electric_network_id and "unplugged" or nil
  end
  if e.type == "rocket-silo" and (name == "waiting_for_space_in_destination" or name == "not_connected_to_hub_or_pad") then
    kind = "launch"
  elseif e.type == "asteroid-collector" and (name == "full_output" or name == "waiting_for_space_in_destination") then
    kind = "collector"
  end
  if kind then
    table.insert(found[kind], entry(e, name))
  end
  return 1
end

-- The entity scans go through every surface chunk by chunk, a few each tick (a busy base has
-- tens of thousands of entities: one scan of them all took 145 ms in the owner's save, 10456
-- chunks), and replace the last results when a pass is complete.
local pass

local next_pass = 0

-- alerts_quiet (perf.lua): most chunks of a surface hold none of the force's machines (0.36 ms on 97% of
-- the owner's ticks went on them). A chunk the pass found none in is looked in again only every
-- EMPTY_EVERY'th pass, or once something is built, mined or changed there (tracker.listeners); a pass
-- passing over one counts it as EMPTY_COST of a chunk. And the pass steps once a tick, not once per
-- client (its results only feed `al`, so module-local is fine), waiting PASS_INTERVAL after a pass
-- finishes so a big base doesn't run passes back-to-back. empty: si -> { cx * 65536 + cy -> true }.
local EMPTY_EVERY = 10
local EMPTY_COST = 0.25
local empty = {}
local passes = 0
local stepped_at = -1

local function chunk_key(cx, cy)
  return cx * 65536 + cy
end

---------------------------------------------------------------------------------------------
-- Warnings over machines round the focus (J5, J22, J27, J28), kept in the client's state from on_tick
-- reads: storage.f3d.al_near = {si, x0, y0, x1, y1 (the square fluids_power read, 1/256 tiles), and per
-- kind its field (NEAR) = {unit -> entity}}; al_spots, [{x, y, t, r}]: where something was built or
-- removed, or the character moved items, since (from events and commands), looked at again once the
-- tick is past t, r tiles round (nil: the widest pole's reach).

-- The kinds read round the focus, by their field in al_near (u: J5's, as saves have it).
local NEAR = { unplugged = "u", no_fuel = "f", no_ammo = "a", depleted = "d" }
-- What their entries say after the entity (as the pass's: its status, or nothing for a turret).
local NEAR_EXTRA = { no_fuel = "no_fuel", depleted = "no_minable_resources" }

-- Spots looked at again a tick, at most (a drag of poles or inserters makes one each).
local SPOTS_PER_TICK = 8
local SPOTS_MAX = 64
-- Burners and turrets built or removed: themselves read again (tiles round them).
local STATUS_SPOT = 2
-- Items moved by the character: the buildings in its reach read again these ticks after, and this much
-- further than its reach (the reach is measured to a building's edge, the read finds it by its box).
local HAND_LOOKS = { 2, 20 }
local HAND_SLACK = 3
-- An `al` sent for a change waits at least this long after the last one.
local CHANGE_GAP = 6
local spot_reach
local spot_types

-- How far round a pole built or removed its supply can have reached a machine: the widest supply
-- area of any pole (a substation's 9 tiles), with room for quality's wider ones and the machine's
-- own half width. From prototypes alone, once.
local function reach()
  if not spot_reach then
    local widest = 9
    for _, proto in pairs(prototypes.entity) do
      if proto.type == "electric-pole" then
        local ok, d = pcall(function() return proto.get_supply_area_distance() end)
        if not (ok and type(d) == "number") then
          ok, d = pcall(function() return proto.supply_area_distance end)
        end
        if ok and type(d) == "number" and d > widest then
          widest = d
        end
      end
    end
    spot_reach = widest + 10
  end
  return spot_reach
end

-- "power" for a pole or an electric machine (the machines round it read again), "status" for a turret
-- or burner no electric type covers (itself read again), nil for anything else.
local function is_spot_type(t)
  if not spot_types then
    spot_types = { ["electric-pole"] = "power" }
    for _, et in pairs(registry.electric_types()) do
      spot_types[et] = "power"
    end
    for _, et in ipairs(fluids_power.status_types()) do
      spot_types[et] = spot_types[et] or "status"
    end
  end
  return spot_types[t]
end

-- Every type a spot reads: the electric ones and the turrets and burners besides (from prototypes).
local look_types
local function spot_look_types()
  if not look_types then
    look_types = {}
    for _, et in pairs(registry.electric_types()) do
      look_types[#look_types + 1] = et
    end
    for _, et in ipairs(fluids_power.status_types()) do
      look_types[#look_types + 1] = et
    end
  end
  return look_types
end

local function inside_near(near, si, x, y)
  return si == near.si and x >= near.x0 and x <= near.x1 and y >= near.y0 and y <= near.y1
end

local function near_on(kind)
  return kind == "unplugged" or perf.on("status_near")
end

local function same_units(a, b)
  for unit in pairs(a) do
    if not b[unit] then
      return false
    end
  end
  for unit in pairs(b) do
    if not a[unit] then
      return false
    end
  end
  return true
end

-- fluids_power's read: the force's warned machines in the focus square, replacing the last.
fluids_power.listeners[#fluids_power.listeners + 1] = function(si, f, r, unplugged, warn)
  local s = storage.f3d
  local fname = force().name
  local old = s.al_near
  local new = { si = si, x0 = world.fixed(f.x - r), y0 = world.fixed(f.y - r), x1 = world.fixed(f.x + r),
    y1 = world.fixed(f.y + r) }
  local changed = not (old ~= nil and old.si == si)
  for kind, field in pairs(NEAR) do
    local set = {}
    local list = kind == "unplugged" and unplugged or (near_on(kind) and warn and warn[kind]) or {}
    for _, e in ipairs(list) do
      if e.valid and e.unit_number and e.force and e.force.name == fname then
        set[e.unit_number] = e
      end
    end
    new[field] = set
    if not changed and not same_units(old[field] or {}, set) then
      changed = true
    end
  end
  s.al_near = new
  if changed then
    s.al_dirty = true
  end
end

local function add_spot(x, y, t, r)
  local s = storage.f3d
  s.al_spots = s.al_spots or {}
  if #s.al_spots < SPOTS_MAX then
    s.al_spots[#s.al_spots + 1] = { x = x, y = y, t = t, r = r }
  end
end

tracker.listeners[#tracker.listeners + 1] = function(entity)
  if not (entity and entity.valid) then
    return
  end
  local p = entity.position
  local es = empty[entity.surface.index]
  if es then
    es[chunk_key(math.floor(p.x / 32), math.floor(p.y / 32))] = nil
  end
  local near = storage.f3d.al_near
  if near and near.si == entity.surface.index and perf.on("pipe_alerts")
      and (pipelines.SET[entity.type] or entity.type == "pump" or entity.type == "offshore-pump") then
    local s = storage.f3d
    s.al_pspots = s.al_pspots or {}
    if #s.al_pspots < SPOTS_MAX then
      s.al_pspots[#s.al_pspots + 1] = { x = p.x, y = p.y, t = game.tick }
    end
  end
  local kind = near and near.si == entity.surface.index and is_spot_type(entity.type)
  if kind == "status" then
    if perf.on("status_near") then
      add_spot(p.x, p.y, game.tick, STATUS_SPOT)
    end
  elseif kind then
    add_spot(p.x, p.y, game.tick)
  end
end

-- The character put items into or took them out of a building (session.lua, after take, put, move, xfer,
-- fast and drop): the turrets' ammo and the burners' fuel in its reach are looked at again soon.
function M.items_moved()
  local s = storage.f3d
  local near = s and s.al_near
  local c = puppet.get()
  if not (near and c and c.valid and c.surface.index == near.si and perf.on("status_near")) then
    return
  end
  local p = c.position
  local r = (c.reach_distance or 10) + HAND_SLACK
  for _, after in ipairs(HAND_LOOKS) do
    add_spot(p.x, p.y, game.tick + after - 1, r)
  end
end

-- Which near kind an entity is now (nil: none). A turret by its ammo inventory, as the pass reads it.
local function near_kind(e)
  if e.type == "ammo-turret" then
    local inv = e.get_inventory(defines.inventory.turret_ammo)
    return (inv and inv.is_empty()) and "no_ammo" or nil
  end
  local status = e.status
  local name = status_name(status)
  if name == "no_fuel" then
    return "no_fuel"
  elseif name == "no_minable_resources" then
    return "depleted"
  elseif fluids_power.power_state(e, status) == 2 then
    return "unplugged"
  end
  return nil
end

-- Reads the machines round the spots again once their tick is past (a machine built out of every
-- pole's reach says so then, one a new pole reaches has its network at once, a burner given fuel
-- loses its icon). Spots not due yet wait; at most SPOTS_PER_TICK are read a tick.
local function look_at_spots()
  local s = storage.f3d
  local spots, near = s.al_spots, s.al_near
  if not spots then
    return
  end
  if not near then
    s.al_spots = nil
    return
  end
  local surface = game.get_surface(near.si)
  local types = spot_look_types()
  if #types == 0 then
    s.al_spots = nil
    return
  end
  for _, field in pairs(NEAR) do
    near[field] = near[field] or {}  -- (a save from J5 has only u)
  end
  local f = force()
  local done, changed = 0, false
  local rest = {}
  for _, spot in ipairs(spots) do
    if done < SPOTS_PER_TICK and spot.t < game.tick then
      done = done + 1
      if surface and surface.valid then
        local d = spot.r or reach()
        local found = surface.find_entities_filtered({ area = { { spot.x - d, spot.y - d }, { spot.x + d, spot.y + d } },
          type = types, force = f })
        for _, e in pairs(found) do
          local p = e.position
          local unit = e.unit_number
          if unit and inside_near(near, near.si, world.fixed(p.x), world.fixed(p.y)) then
            local now = near_kind(e)
            for kind, field in pairs(NEAR) do
              if near_on(kind) then
                local want = now == kind and e or nil
                if (near[field][unit] ~= nil) ~= (want ~= nil) then
                  near[field][unit] = want
                  changed = true
                end
              end
            end
          end
        end
      end
    else
      rest[#rest + 1] = spot
    end
  end
  if done == 0 then
    return
  end
  for _, field in pairs(NEAR) do
    for unit, e in pairs(near[field]) do
      if not e.valid then -- mined or destroyed: its icon goes now
        near[field][unit] = nil
        changed = true
      end
    end
  end
  s.al_spots = #rest > 0 and rest or nil
  if changed then
    s.al_dirty = true
  end
end

-- Pipe spots (L11): the pipelines round a pipe-type entity or pump built, removed or turned are read the tick
-- after (2.1 joins or splits the segments then), at most SPOTS_PER_TICK spots a tick; an overextended
-- segment's entity (pipelines.spot) goes into storage.f3d.al_pipe, unit -> entity, and those listed that a
-- change has mended come out.
local PIPE_SPOT_REACH = 1.5

local function look_at_pipe_spots()
  local s = storage.f3d
  local spots, near = s.al_pspots, s.al_near
  if not spots then
    return
  end
  local surface = near and game.get_surface(near.si)
  if not (surface and surface.valid and perf.on("pipe_alerts")) then
    s.al_pspots = nil
    return
  end
  local types = pipelines.types()
  local f = force()
  local done, changed = 0, false
  local rest = {}
  s.al_pipe = s.al_pipe or {}
  local segs = {}
  for _, spot in ipairs(spots) do
    if done < SPOTS_PER_TICK and spot.t < game.tick then
      done = done + 1
      local d = PIPE_SPOT_REACH
      local found = #types > 0 and surface.find_entities_filtered({ area = { { spot.x - d, spot.y - d }, { spot.x + d, spot.y + d } },
        type = types, force = f }) or {}
      for _, e in pairs(found) do
        if pipelines.overextended(e) then
          local seg = pipelines.segment(e)
          if seg and not segs[seg] then
            segs[seg] = true
            local w = pipelines.spot(e)
            if w.unit_number and s.al_pipe[w.unit_number] == nil then
              s.al_pipe[w.unit_number] = w
              changed = true
            end
          end
        end
      end
    else
      rest[#rest + 1] = spot
    end
  end
  if done == 0 then
    return
  end
  for unit, e in pairs(s.al_pipe) do
    if not (e.valid and pipelines.overextended(e)) then
      s.al_pipe[unit] = nil
      changed = true
    end
  end
  s.al_pspots = #rest > 0 and rest or nil
  if changed then
    s.al_dirty = true
  end
end

-- The overextended pipelines: the pass's and the spots' entities still overextended, one a segment.
local function pipeline_list()
  if not perf.on("pipe_alerts") then
    return {}
  end
  local out, segs = {}, {}
  local function add(e, rec)
    if e and e.valid and pipelines.overextended(e) then
      local seg = pipelines.segment(e)
      if seg and not segs[seg] then
        segs[seg] = true
        out[#out + 1] = rec or entry(e, "pipeline_overextended")
      end
    end
  end
  local s = storage.f3d
  for _, e in pairs(s.al_pipe or {}) do
    add(e)
  end
  for _, rec in ipairs(scans.pipeline or {}) do
    add(subjects[rec], rec)
  end
  return out
end

local function start_pass()
  passes = passes + 1
  next_pass = game.tick + PASS_INTERVAL * rate.factor("al")
  local list = {}
  for _, surface in pairs(game.surfaces) do
    list[#list + 1] = surface.index
  end
  local found = {}
  for _, k in ipairs(PASS_KINDS) do
    found[k] = {}
  end
  local pass_types = types(PASS_TYPES)
  if perf.on("pipe_alerts") then
    for _, t in ipairs(pipelines.types()) do
      pass_types[#pass_types + 1] = t
    end
  end
  pass = { surfaces = list, i = 1, iter = nil, found = found, seen = {}, types = pass_types, ghosts = 0, segs = {} }
end

-- One entity of the pass (not seen yet this pass): what it costs.
local function pass_entity(e, f)
  local key = e.unit_number or key_of(e)
  if pass.seen[key] then
    return 0
  end
  pass.seen[key] = true
  if pipelines.SET[e.type] then
    if pipelines.overextended(e) then
      local seg = pipelines.segment(e)
      if seg and not pass.segs[seg] then
        pass.segs[seg] = true
        table.insert(pass.found.pipeline, entry(pipelines.spot(e), "pipeline_overextended"))
      end
    end
    return PIPE_COST
  elseif e.type == "entity-ghost" then
    pass.ghosts = pass.ghosts + 1
    if pass.ghosts <= GHOSTS_MAX then
      return check_entity(e, pass.found)
    end
    return 0
  end
  return check_entity(e, pass.found)
end

local function step_pass(now)
  if not pass then
    if not now and game.tick < next_pass then
      return
    end
    start_pass()
  end
  local f = force()
  local chunks, cost = 0, 0
  local quiet = perf.on("alerts_quiet")
  local recheck = passes % EMPTY_EVERY == 0
  local inside = perf.on("alerts_topk")
  while chunks < CHUNKS_PER_TICK and cost < ENTITIES_PER_TICK do
    -- (alerts_topk) A chunk's entities left from the last tick first: a chunk dense with machines or pipes was
    -- read whole in one tick (35-50 ms on the megabase).
    local left = pass.left
    if left then
      local surface = game.get_surface(left.si)
      if not (surface and surface.valid) then
        pass.left = nil
      else
        local f_at = left.at
        while f_at <= #left.found and cost < ENTITIES_PER_TICK do
          local e = left.found[f_at]
          f_at = f_at + 1
          if e.valid then
            cost = cost + pass_entity(e, f)
          end
        end
        left.at = f_at
        if f_at > #left.found then
          pass.left = nil
        end
      end
      goto continue
    end
    do
    local si = pass.surfaces[pass.i]
    if not si then
      for k, v in pairs(pass.found) do
        scans[k] = v
      end
      pass = nil
      if quiet then
        next_pass = game.tick + PASS_INTERVAL * rate.factor("al")
      end
      return
    end
    local surface = game.get_surface(si)
    local chunk = nil
    if surface and surface.valid then
      pass.iter = pass.iter or surface.get_chunks()
      chunk = pass.iter()
    end
    local es = quiet and empty[si]
    local ckey = quiet and chunk and chunk_key(chunk.x, chunk.y)
    if not chunk then
      pass.i, pass.iter = pass.i + 1, nil
    elseif ckey and es and es[ckey] and not recheck then
      chunks = chunks + EMPTY_COST
    else
      chunks = chunks + 1
      local found = surface.find_entities_filtered({ area = chunk.area, force = f, type = pass.types })
      if ckey then
        if #found == 0 then
          if not es then
            es = {}
            empty[si] = es
          end
          es[ckey] = true
        elseif es then
          es[ckey] = nil
        end
      end
      if inside then
        pass.left = { si = si, found = found, at = 1 }
      else
        for _, e in pairs(found) do
          cost = cost + pass_entity(e, f)
        end
      end
    end
    end
    ::continue::
  end
end

local function repair_item_names()
  if not repair_items then
    repair_items = {}
    for name, item in pairs(prototypes.item) do
      if item.type == "repair-tool" then
        repair_items[#repair_items + 1] = name
      end
    end
  end
  return repair_items
end

-- Damaged buildings in a construction area with no repair packs anywhere in its networks.
local function scan_repair()
  local al = state()
  local out = {}
  local packs = repair_item_names()
  for unit, e in pairs(al.hurt) do
    if not e.valid or e.get_health_ratio() == nil or e.get_health_ratio() >= 1 then
      al.hurt[unit] = nil
    else
      local nets = networks_at(e)
      local have = #nets == 0
      for _, net in pairs(nets) do
        for _, p in ipairs(packs) do
          if net.get_item_count(p) > 0 then
            have = true
          end
        end
      end
      if not have then
        out[#out + 1] = entry(e)
      end
    end
  end
  scans.no_repair = out
end

local function out_of_fuel(train)
  local any = false
  for _, list in pairs({ train.locomotives.front_movers or {}, train.locomotives.back_movers or {} }) do
    for _, loco in pairs(list) do
      any = true
      local burner = loco.burner
      if not burner then
        return false
      end
      local inv = burner.inventory
      if burner.remaining_burning_fuel > 0 or (inv and not inv.is_empty()) then
        return false
      end
    end
  end
  return any
end

local function check_train(train, fuel, path)
  local front = train.front_stock
  if front and front.valid then
    if not train.manual_mode and out_of_fuel(train) then
      fuel[#fuel + 1] = entry(front, train.id)
    elseif train.state == defines.train_state.no_path then
      path[#path + 1] = entry(front, train.id)
    end
  end
end

local function scan_trains_all()
  local fuel, path = {}, {}
  local trains = game.train_manager.get_trains({ force = force() })
  for _, train in pairs(trains) do
    check_train(train, fuel, path)
  end
  scans.train_fuel = fuel
  scans.train_path = path
end

-- map_trains_slice (perf.lua): the trains' scan takes the list at its turn and reads TRAINS_PER_TICK of them a
-- tick (once a tick for every client, as the pass), the last scan's lists kept until it ends. Module-local, as
-- the other scans: it only feeds `al`.
local TRAINS_PER_TICK = 40
local train_scan = nil
local train_scan_at = -1

local function scan_trains()
  if not perf.on("map_trains_slice") then
    train_scan = nil
    return scan_trains_all()
  end
  if not train_scan then
    train_scan = { list = game.train_manager.get_trains({ force = force() }), i = 1, fuel = {}, path = {} }
  end
end

local function step_train_scan(t)
  local job = train_scan
  if not job or train_scan_at == t then
    return
  end
  train_scan_at = t
  local list, i = job.list, job.i
  local last = math.min(#list, i + TRAINS_PER_TICK - 1)
  while i <= last do
    local train = list[i]
    if train.valid then
      check_train(train, job.fuel, job.path)
    end
    i = i + 1
  end
  job.i = i
  if i > #list then
    scans.train_fuel = job.fuel
    scans.train_path = job.path
    train_scan = nil
  end
end

local function scan_platforms()
  local path, storage_full = {}, {}
  local ok, platforms = pcall(function() return force().platforms end)
  for _, p in pairs(ok and platforms or {}) do
    local hub = p.valid and p.hub
    if hub and hub.valid then
      if p.state == defines.space_platform_state.no_path then
        path[#path + 1] = entry(hub, p.name)
      end
      local inv = hub.get_inventory(defines.inventory.hub_main)
      if inv and inv.is_full() then
        storage_full[#storage_full + 1] = entry(hub, p.name)
      end
    end
  end
  scans.platform_path = path
  scans.platform_storage = storage_full
end

local SCANS = { scan_repair, scan_trains, scan_platforms }
local SCANS_NOW = { scan_repair, scan_trains_all, scan_platforms }

---------------------------------------------------------------------------------------------

-- The order of Factorio's alert bar, then the machine warnings.
local ORDER = { "destroyed", "attack", "fire", "no_ammo", "no_material", "no_robots", "no_repair", "train_fuel", "train_path",
  "platform_path", "platform_storage", "collector", "launch", "pipeline", "unplugged", "no_fuel", "output_full", "depleted" }

local function from_events(al, kind)
  local list = {}
  for key, rec in pairs(al[kind]) do
    if game.tick - rec.t > LIFETIME[kind] then
      al[kind][key] = nil
    else
      list[#list + 1] = rec.e
    end
  end
  return list
end

-- A near kind's machines: the pass's outside the focus square, the last read's inside it.
local function near_list(kind)
  local list = scans[kind] and still_there(scans[kind]) or {}
  local near = storage.f3d.al_near
  if not (near and near_on(kind)) then
    return list
  end
  local out = {}
  for _, rec in ipairs(list) do
    if not inside_near(near, rec[3], rec[1], rec[2]) then
      out[#out + 1] = rec
    end
  end
  for _, e in pairs(near[NEAR[kind]] or {}) do
    if e.valid then
      if kind == "unplugged" then
        out[#out + 1] = entry(e, status_name(e.status))
      else
        out[#out + 1] = entry(e, NEAR_EXTRA[kind])
      end
    end
  end
  return out
end

local function message_sorted()
  local al = state()
  local here = puppet.get()
  local si = here and here.surface.index or 0
  local l = {}
  for _, kind in ipairs(ORDER) do
    local list
    if LIFETIME[kind] then
      list = from_events(al, kind)
    elseif kind == "pipeline" then
      list = pipeline_list()
    elseif NEAR[kind] then
      list = near_list(kind)
    else
      list = scans[kind] and still_there(scans[kind])
    end
    if list and #list > 0 then
      -- The character's surface first, nearest the camera first (only PER_KIND are listed, and
      -- the client draws icons over those).
      local f = storage.f3d.focus
      local fx, fy = world.fixed(f.x), world.fixed(f.y)
      local function d2(e)
        return (e[1] - fx) ^ 2 + (e[2] - fy) ^ 2
      end
      table.sort(list, function(a, b)
        if (a[3] == si) ~= (b[3] == si) then
          return a[3] == si
        end
        local da, db = d2(a), d2(b)
        if da ~= db then
          return da < db
        end
        return a[5] < b[5]
      end)
      local shown = {}
      for i = 1, math.min(#list, PER_KIND) do
        shown[i] = list[i]
      end
      l[#l + 1] = { kind, #list, shown }
    end
  end
  return { t = "al", l = l }
end


-- alerts_topk (perf.lua): a kind's PER_KIND nearest in one pass over its list, with the entries gone left out
-- and counted out, in message_sorted's order (the character's surface first, then nearest the focus, then by unit
-- number). On the megabase the sort of every list, a closure a call, took 51-103 ms once a second.
local function before(on, d, u, on2, d2, u2)
  if on ~= on2 then
    return on < on2
  end
  if d ~= d2 then
    return d < d2
  end
  return u < u2
end

-- {count, shown}: `list`'s entries (still there when `check`; outside `near`'s square when given) counted, the
-- nearest `k` (PER_KIND) of them in order, kept in a sorted array. A scan's list comes chunk by chunk, so on the
-- megabase nearly every entry beat the last kept one in list order (57 ms for 16,301 entries, a k-shift each):
-- the list is visited in a fixed stride order instead (a step coprime with its length), which leaves about
-- k * ln(n / k) entries to insert, and the rest are turned away by an inline comparison. (A heap of closures took
-- 49 ms, table.sort of the distances 34-38 ms, a quickselect 22-45 ms in Factorio's Lua: function calls cost.)
local STRIDES = { 7919, 7907, 7901, 7883, 7877 }

local function stride_for(n)
  for _, p in ipairs(STRIDES) do
    if n % p ~= 0 then
      return p % n
    end
  end
  return 1
end

local function pick(list, si, fx, fy, check, near, k)
  k = k or PER_KIND
  local shown, ons, ds, us = {}, {}, {}, {}
  local n, count = 0, 0
  local len = #list
  local step = len > 0 and stride_for(len) or 1
  if step == 0 then
    step = 1
  end
  local at = 0
  for _ = 1, len do
    local rec = list[at + 1]
    at = (at + step) % len
    local keep = true
    if check then
      local e = subjects[rec]
      keep = e == nil or e.valid
    end
    if keep and near and inside_near(near, rec[3], rec[1], rec[2]) then
      keep = false
    end
    if keep then
      count = count + 1
      local on = rec[3] == si and 0 or 1
      local dx, dy = rec[1] - fx, rec[2] - fy
      local d = dx * dx + dy * dy
      -- (Full: turned away unless it beats the last kept one, compared inline.)
      local last_on = ons[n]
      if n < k or on < last_on or (on == last_on and (d < ds[n] or (d == ds[n] and rec[5] < us[n]))) then
        local u = rec[5]
        local j = n < k and n + 1 or n
        if n < k then
          n = n + 1
        end
        while j > 1 and before(on, d, u, ons[j - 1], ds[j - 1], us[j - 1]) do
          shown[j], ons[j], ds[j], us[j] = shown[j - 1], ons[j - 1], ds[j - 1], us[j - 1]
          j = j - 1
        end
        shown[j], ons[j], ds[j], us[j] = rec, on, d, u
      end
    end
  end
  return count, shown
end

-- pick with `check` for a long list, checking only the nearest: on the megabase `valid` on 16,301 machines was
-- 43 ms of 46. The nearest PER_KIND + SPARE are picked unchecked, then checked; when fewer than PER_KIND of them are
-- there and the list has more, the whole list is checked (pick). The count leaves out the gone it found; others gone
-- since the scan are counted until the next scan replaces the list.
local SPARE = 16

local function pick_lazy(list, si, fx, fy, near)
  local count, cands = pick(list, si, fx, fy, false, near, PER_KIND + SPARE)
  local shown, gone = {}, 0
  for _, rec in ipairs(cands) do
    local e = subjects[rec]
    if e ~= nil and not e.valid then
      gone = gone + 1
    elseif #shown < PER_KIND then
      shown[#shown + 1] = rec
    end
  end
  if #shown < PER_KIND and count - gone > #shown then
    return pick(list, si, fx, fy, true, near)
  end
  return count - gone, shown
end

-- A client's picks of the scans' long lists (client state -> kind -> {list, si, fx, fy, near box, count, shown}),
-- kept while the list (a new one each scan), the focus, the surface and the near square are the same and every
-- shown entity is still there. Weak keys: a client's state that went takes its picks along. Only what is sent.
local picks = setmetatable({}, { __mode = "k" })

local function same_near(a, b)
  if a == nil or b == nil then
    return a == b
  end
  return a.si == b.si and a.x0 == b.x0 and a.y0 == b.y0 and a.x1 == b.x1 and a.y1 == b.y1
end

local function shown_there(shown)
  for _, rec in ipairs(shown) do
    local e = subjects[rec]
    if e ~= nil and not e.valid then
      return false
    end
  end
  return true
end

-- A scan list's {count, shown}, from the cache when it still holds (near: the square to leave out, or nil).
local function pick_cached(kind, list, si, fx, fy, near)
  local s = storage.f3d
  local mine = picks[s]
  if not mine then
    mine = {}
    picks[s] = mine
  end
  local c = mine[kind]
  if c and c.list == list and c.si == si and c.fx == fx and c.fy == fy and same_near(c.near, near)
      and shown_there(c.shown) then
    return c.count, c.shown
  end
  local tp = profile.start()
  local count, shown = pick_lazy(list, si, fx, fy, near)
  profile.stop("alerts.pick", tp)
  local box = near and { si = near.si, x0 = near.x0, y0 = near.y0, x1 = near.x1, y1 = near.y1 } or nil
  mine[kind] = { list = list, si = si, fx = fx, fy = fy, near = box, count = count, shown = shown }
  return count, shown
end

local function message_topk()
  local al = state()
  local here = puppet.get()
  local si = here and here.surface.index or 0
  local f = storage.f3d.focus
  local fx, fy = world.fixed(f.x), world.fixed(f.y)
  local l = {}
  for _, kind in ipairs(ORDER) do
    local count, shown
    if LIFETIME[kind] then
      count, shown = pick(from_events(al, kind), si, fx, fy, false, nil)
    elseif kind == "pipeline" then
      local tp = profile.start()
      count, shown = pick(pipeline_list(), si, fx, fy, false, nil)
      profile.stop("alerts.pipe", tp)
    elseif NEAR[kind] then
      local near = storage.f3d.al_near
      if not (near and near_on(kind)) then
        near = nil
      end
      count, shown = 0, {}
      if scans[kind] then
        count, shown = pick_cached(kind, scans[kind], si, fx, fy, near)
      end
      -- The last read's machines inside the square (a few): with the cached ones, picked again.
      local inside = {}
      for _, e in pairs(near and near[NEAR[kind]] or {}) do
        if e.valid then
          if kind == "unplugged" then
            inside[#inside + 1] = entry(e, status_name(e.status))
          else
            inside[#inside + 1] = entry(e, NEAR_EXTRA[kind])
          end
        end
      end
      if #inside > 0 then
        local both = {}
        for i, rec in ipairs(shown) do
          both[i] = rec
        end
        for _, rec in ipairs(inside) do
          both[#both + 1] = rec
        end
        local _
        _, shown = pick(both, si, fx, fy, false, nil)
        count = count + #inside
      end
    elseif scans[kind] then
      count, shown = pick_cached(kind, scans[kind], si, fx, fy, nil)
    end
    if count and count > 0 then
      l[#l + 1] = { kind, count, shown }
    end
  end
  return { t = "al", l = l }
end

local function message()
  if perf.on("alerts_topk") then
    return message_topk()
  end
  return message_sorted()
end

function M.tick()
  local t = game.tick
  -- (alerts_quiet: one step a tick for every client: its results are the same for all.)
  if not (perf.on("alerts_quiet") and stepped_at == t) then
    stepped_at = t
    local tp = profile.start()
    local ok, err = pcall(step_pass)
    profile.stop("alerts.pass", tp)
    if not ok then
      pass = nil
      log("[factorio-3d-bridge] alert pass: " .. tostring(err))
    end
  end
  local ok, err = pcall(step_train_scan, t)
  if not ok then
    train_scan = nil
    log("[factorio-3d-bridge] alert train scan: " .. tostring(err))
  end
  if t % SCAN_STEP == 0 then
    local i = (t / SCAN_STEP) % #SCANS + 1
    ok, err = pcall(SCANS[i])
    if not ok then
      log("[factorio-3d-bridge] alert scan " .. i .. ": " .. tostring(err))
    end
  end
  ok, err = pcall(look_at_spots)
  if not ok then
    storage.f3d.al_spots = nil
    log("[factorio-3d-bridge] alert spots: " .. tostring(err))
  end
  ok, err = pcall(look_at_pipe_spots)
  if not ok then
    storage.f3d.al_pspots = nil
    log("[factorio-3d-bridge] alert pipe spots: " .. tostring(err))
  end
  -- Its own phase: the bridge's periodic jobs all fell on the same tick once a second (budget.lua);
  -- sooner when the warned machines round the focus changed.
  local s = storage.f3d
  if (t + 29) % SEND_INTERVAL == 0 or (s.al_dirty and t - (s.al_sent_at or -CHANGE_GAP) >= CHANGE_GAP) then
    s.al_dirty = nil
    s.al_sent_at = t
    local tp = profile.start()
    local msg = message()
    profile.stop("alerts.msg", tp)
    transport.send_now(msg)
  end
end

-- What `al` says from the scans as they are now (tests: alerts_topk's picks and their cache).
function M.message_now()
  return message()
end

-- What the next `al` would say (live_check, /c).
function M.current()
  train_scan = nil
  for _, scan in ipairs(SCANS_NOW) do
    scan()
  end
  pass = nil
  repeat
    step_pass(true)
  until not pass
  return message()
end

function M.reset()
  scans = {}
  train_scan = nil
  pass = nil
  next_pass = 0
  empty = {}
  local s = storage.f3d
  if s then
    s.al_near, s.al_spots, s.al_dirty, s.al_sent_at = nil, nil, nil, nil
    s.al_pipe, s.al_pspots = nil, nil
  end
end

-- Passes started since loading (tests: every EMPTY_EVERY'th looks in the empty chunks too).
function M.pass_count()
  return passes
end

-- How many chunks the pass takes as empty (tests).
function M.empty_chunks()
  local n = 0
  for _, es in pairs(empty) do
    for _ in pairs(es) do
      n = n + 1
    end
  end
  return n
end

-- For measuring a pass's cost (/c): one step, and whether the pass just finished.
function M.tick_pass()
  step_pass(true)
end

function M.pass_done()
  return pass == nil
end

return M
