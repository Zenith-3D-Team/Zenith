-- Fluids, heat and power near the client's camera, for drawing: what is in each pipe, tank and
-- machine fluid box (`fl`), how hot heat pipes and reactors are (`ht`), and which machines are
-- short of electricity or not connected to it (`pw`). Wires between poles ride in the entity
-- records (world.lua). All change slowly, so once a second is enough.
--
-- Read-only: nothing here touches `storage`, so it is safe in multiplayer. (Its listener in
-- alerts.lua keeps the machines found unplugged, out of fuel, out of ammo or with nothing left to mine in
-- the client's state, from on_tick: the read of every machine's status here gives those for free.)

local registry = require("scripts.registry")
local transport = require("scripts.transport")
local world = require("scripts.world")
local rate = require("scripts.rate")
local budget = require("scripts.budget")
local perf = require("scripts.perf")
local tracker = require("scripts.tracker")

local M = {}

local INTERVAL = 60
local read_n = 0  -- entities read this run (rate.read)
local BOXES_PER_MESSAGE = 200
local SLICE_PRICE = 40
local MAX_SLICES_PER_TICK = 2
local FP_RESCAN_TICKS = 240
local FP_MOVE_THRESH = 4
-- Module-local counters for tests/probes (never in storage).
M.counts = { runs = 0, slices = 0, searches = 0, inv_gets = 0, empty_skips = 0 }

-- (gc_lean) Module-local entity/inventory handle caches & pcall helpers (never in storage).
local inv_cache = {}
local heat_set

local function get_temperature(e) return e.temperature end
local function get_unplugged(st) return st.not_plugged_in_electric_network end
local function get_no_ore() return defines.entity_status.no_minable_resources end
local function get_entity_inv(e, inv_id) return e.get_inventory(inv_id) end
local function inv_is_empty(inv) return inv.is_empty() end

local function is_heat_type(t)
  if not heat_set then
    heat_set = {}
    for _, ht in ipairs(registry.heat_types()) do
      heat_set[ht] = true
    end
  end
  return heat_set[t] == true
end

tracker.listeners[#tracker.listeners + 1] = function(entity)
  if not (entity and entity.valid) then
    return
  end
  local si = entity.surface.index
  local t = entity.type
  local fl_dirty = registry.is_fluid(t)
  local ht_dirty = is_heat_type(t)
  if not (fl_dirty or ht_dirty) then
    return
  end
  local s = storage.f3d
  local fm = s and s.fp_meta
  if fm and fm.si == si then
    if fl_dirty and fm.fl then
      for _, entry in pairs(fm.fl) do
        entry.dirty = true
      end
    end
    if ht_dirty and fm.ht then
      for _, entry in pairs(fm.ht) do
        entry.dirty = true
      end
    end
  end
end

local function prune_inv_cache()
  if next(inv_cache) ~= nil then
    for unit, c in pairs(inv_cache) do
      if not (c.e and c.e.valid and c.inv and c.inv.valid) then
        inv_cache[unit] = nil
      end
    end
  end
end

local function cached_inv(e, inv_id)
  if not perf.on("gc_lean") then
    inv_cache = {}
    M.counts.inv_gets = M.counts.inv_gets + 1
    local ok, inv = pcall(get_entity_inv, e, inv_id)
    return ok and inv or nil
  end
  local unit = e.unit_number
  if unit then
    local c = inv_cache[unit]
    if c and c.e == e and e.valid and c.inv and c.inv.valid then
      return c.inv
    end
    M.counts.inv_gets = M.counts.inv_gets + 1
    local ok, inv = pcall(get_entity_inv, e, inv_id)
    if ok and inv and inv.valid then
      inv_cache[unit] = { e = e, inv = inv }
      return inv
    end
    inv_cache[unit] = nil
    return ok and inv or nil
  end
  M.counts.inv_gets = M.counts.inv_gets + 1
  local ok, inv = pcall(get_entity_inv, e, inv_id)
  return ok and inv or nil
end

-- (gc_lean) The storage bucket for this focus (s.fp_meta.fl / .ht): each search's found list is kept in
-- it (m.list), so every peer, a joiner included, walks the same list and storage writes depend only on
-- storage and events.
local function fp_cache_for(s, surface, fx, fy, dr)
  if not perf.on("gc_lean") then
    s.fp_meta = nil
    return nil
  end
  local fm = s.fp_meta
  if not fm or fm.si ~= surface.index or fm.dr ~= dr or fm.client ~= s.client
      or math.abs(fx - fm.fx) >= FP_MOVE_THRESH or math.abs(fy - fm.fy) >= FP_MOVE_THRESH then
    if fm and (fm.si ~= surface.index or fm.client ~= s.client) then
      inv_cache = {}
    end
    fm = { si = surface.index, fx = fx, fy = fy, dr = dr, client = s.client, fl = {}, ht = {} }
    s.fp_meta = fm
  end
  return fm
end

local function cached_area_search(meta_bucket, key, surface, box, types, skip_if_empty)
  if not meta_bucket then
    M.counts.searches = M.counts.searches + 1
    local found = surface.find_entities_filtered({ area = box, type = types })
    return found, nil, #found
  end
  local m = meta_bucket[key]
  local limit = FP_RESCAN_TICKS * rate.factor("fp")
  if m and not m.dirty and m.list and (not skip_if_empty or m.count > 0) and (game.tick - m.tick) < limit then
    return m.list, m, m.count
  end
  M.counts.searches = M.counts.searches + 1
  local found = surface.find_entities_filtered({ area = box, type = types })
  m = { tick = game.tick, count = #found, dirty = false, list = found }
  meta_bucket[key] = m
  return found, m, #found
end

function M.reset()
  inv_cache = {}
  if storage.f3d then
    storage.f3d.fp_meta = nil
  end
end

local function area(f, r)
  return { { f.x - r, f.y - r }, { f.x + r, f.y + r } }
end

local function strip_area(fx, fy, r, strip, strips)
  if strips <= 1 then
    return { { fx - r, fy - r }, { fx + r, fy + r } }
  end
  local y0, y1 = fy - r, fy + r
  local h = (y1 - y0) / strips
  return { { fx - r, y0 + (strip - 1) * h }, { fx + r, strip == strips and y1 or y0 + strip * h } }
end

local function send_parts(t, flat, width)
  local per = BOXES_PER_MESSAGE * width
  local parts = math.max(1, math.ceil(#flat / per))
  for part = 1, parts do
    local slice = {}
    for i = (part - 1) * per + 1, math.min(part * per, #flat) do
      slice[#slice + 1] = flat[i]
    end
    transport.send_now({ t = t, part = part, parts = parts, l = slice })
  end
end

-- The entity's fluid storages, by index: fluid (nil when empty) and capacity. 2.1 has no
-- LuaEntity.fluidbox; storages are read one by one up to fluids_count.
function M.storages(e)
  local out = {}
  for i = 1, e.fluids_count do
    out[i] = { fluid = e.get_fluid(i), capacity = e.get_fluid_capacity(i) }
  end
  return out
end

-- [unit, box, fluid id, amount, capacity, temperature, ...] for every box with fluid in it.
local function collect_fluids_area(surface, box, flat, seen, meta_bucket, cache_key)
  local types = registry.fluid_types()
  if #types == 0 then
    return 0
  end
  local found, entry, rn = cached_area_search(meta_bucket, cache_key, surface, box, types, true)
  local lean = perf.on("gc_lean")
  for _, e in pairs(found) do
    -- (N3) Skipped only: entry.dirty comes from the tracker (storage), not from the list.
    local valid = e.valid
    local unit = valid and e.unit_number
    if unit and (not seen or not seen[unit]) then
      if seen then
        seen[unit] = true
      end
      if lean then
        for i = 1, e.fluids_count do
          local fluid = e.get_fluid(i)
          if fluid then
            flat[#flat + 1] = unit
            flat[#flat + 1] = i
            flat[#flat + 1] = registry.fluid_id(fluid.name)
            flat[#flat + 1] = math.floor(fluid.amount + 0.5)
            flat[#flat + 1] = math.floor(e.get_fluid_capacity(i) + 0.5)
            flat[#flat + 1] = math.floor((fluid.temperature or 0) + 0.5)
          end
        end
      else
        for i, b in ipairs(M.storages(e)) do
          local fluid = b.fluid
          if fluid then
            flat[#flat + 1] = unit
            flat[#flat + 1] = i
            flat[#flat + 1] = registry.fluid_id(fluid.name)
            flat[#flat + 1] = math.floor(fluid.amount + 0.5)
            flat[#flat + 1] = math.floor(b.capacity + 0.5)
            flat[#flat + 1] = math.floor((fluid.temperature or 0) + 0.5)
          end
        end
      end
    end
  end
  return rn
end

-- [unit, temperature (whole degrees), ...] for every entity with a heat buffer.
local function collect_heat_area(surface, box, flat, seen, meta_bucket, cache_key)
  local types = registry.heat_types()
  if #types == 0 then
    return 0
  end
  local found, entry, rn = cached_area_search(meta_bucket, cache_key, surface, box, types, true)
  for _, e in pairs(found) do
    -- (N3) Skipped only: entry.dirty comes from the tracker (storage), not from the list.
    local valid = e.valid
    local unit = valid and e.unit_number
    if unit and (not seen or not seen[unit]) then
      if seen then
        seen[unit] = true
      end
      local ok, temperature = pcall(get_temperature, e)
      if ok and temperature then
        flat[#flat + 1] = unit
        flat[#flat + 1] = math.floor(temperature + 0.5)
      end
    end
  end
  return rn
end

-- entity_status -> what `pw` says: 0 no power, 1 low power, 2 not connected to any pole.
local POWER_STATES
local function power_states()
  if not POWER_STATES then
    local st = defines.entity_status
    POWER_STATES = { [st.no_power] = 0, [st.low_power] = 1 }
    local ok, unplugged = pcall(get_unplugged, st)
    if ok and unplugged then
      POWER_STATES[unplugged] = 2
    end
  end
  return POWER_STATES
end

-- What `pw` says of one machine: 0 no power, 1 low power, 2 not connected to any pole, nil when it
-- has enough. 2.1 gives a consumer out of reach of every pole no_power too (not_plugged_in_electric_network
-- is only for generators), so no_power without an electric network id also counts as 2. `status`: its
-- e.status when the caller has read it already.
function M.power_state(e, status)
  if status == nil then
    status = e.status
  end
  local state = power_states()[status]
  if state == 0 and e.electric_network_id == nil then
    state = 2
  end
  return state
end

-- The statuses alerts.lua wants from the same read (J22, J27, J28): no_fuel, and no_minable_resources
-- (a drill with nothing left to mine; read in a pcall, as the 2.0 defines may lack it).
local NO_FUEL, NO_ORE
local function statuses()
  if NO_FUEL == nil then
    NO_FUEL = defines.entity_status.no_fuel
    local ok, v = pcall(get_no_ore)
    NO_ORE = ok and v or false
  end
  return NO_FUEL, NO_ORE
end

-- Types whose warnings alerts.lua shows that the electric types don't cover: turrets out of ammo, and
-- the burners no electric machine is (boilers, burner generators, reactors such as Aquilo's heating
-- tower). Those of them this game has, from prototypes alone.
local EXTRA_TYPES = { "ammo-turret", "boiler", "burner-generator", "reactor" }
local extra_types
function M.status_types()
  if not extra_types then
    extra_types = {}
    for _, t in ipairs(EXTRA_TYPES) do
      if registry.has_type(t) then
        extra_types[#extra_types + 1] = t
      end
    end
  end
  return extra_types
end

-- Called after each read of the machines round the focus with (surface index, focus, radius, the
-- machines found not connected, {no_fuel = [...], no_ammo = [...], depleted = [...]}): alerts.lua's
-- warnings over those machines there come from this read, not from its slow pass over every surface
-- (J5, J22, J27, J28). A listener may return how many more entities it read (rate.read).
M.listeners = {}

-- [unit, state, ...] (M.power_state) for every machine short of power round the focus; machines
-- with enough power are left out. Also those found unplugged, and {no_fuel, no_ammo, depleted}: the
-- same read's machines out of fuel and drills with nothing to mine, and a read of the turrets and
-- burners the electric types leave out (turrets by their ammo inventory, as the alerts' pass).
local function collect_power_area(surface, box, flat, unplugged, warn, seen)
  local rn = 0
  local types = registry.electric_types()
  local no_fuel, no_ore = statuses()
  if #types > 0 then
    M.counts.searches = M.counts.searches + 1
    local found = surface.find_entities_filtered({ area = box, type = types })
    rn = rn + #found
    for _, e in pairs(found) do
      local unit = e.unit_number
      if not (unit and seen and seen[unit]) then
        if unit and seen then
          seen[unit] = true
        end
        local status = e.status
        local state = M.power_state(e, status)
        if unit and state then
          flat[#flat + 1] = unit
          flat[#flat + 1] = state
          if state == 2 then
            unplugged[#unplugged + 1] = e
          end
        elseif status == no_fuel then
          warn.no_fuel[#warn.no_fuel + 1] = e
        elseif no_ore and status == no_ore then
          warn.depleted[#warn.depleted + 1] = e
        end
      end
    end
  end
  local extra = M.status_types()
  if #extra > 0 then
    M.counts.searches = M.counts.searches + 1
    local more = surface.find_entities_filtered({ area = box, type = extra })
    rn = rn + #more
    local ammo = defines.inventory.turret_ammo
    for _, e in pairs(more) do
      local unit = e.unit_number
      if not (unit and seen and seen[unit]) then
        if unit and seen then
          seen[unit] = true
        end
        if e.type == "ammo-turret" then
          local inv = cached_inv(e, ammo)
          if inv then
            local ok, empty = pcall(inv_is_empty, inv)
            if (ok and empty) or (not ok and inv.is_empty()) then
              if ok then
                M.counts.empty_skips = M.counts.empty_skips + 1
              end
              warn.no_ammo[#warn.no_ammo + 1] = e
            end
          end
        elseif e.status == no_fuel then
          warn.no_fuel[#warn.no_fuel + 1] = e
        end
      end
    end
  end
  return rn
end

local function fluid_radius(s, base_dr)
  if base_dr <= 0 then
    return 0
  end
  if perf.on("alt_fluid_range") ~= false and (s.altc ~= nil or s.alt == true) then
    return s.focus.r
  end
  return math.min(base_dr, s.focus.r)
end

local function make_job(surface, f, dr, fl_r)
  local steps = {}
  local fl_rad = fl_r or dr
  if fl_rad > 0 then
    local fl_strips = (#registry.fluid_types() > 0 and fl_rad > 32) and (fl_rad > 64 and 4 or 2) or 1
    for k = 1, fl_strips do
      steps[#steps + 1] = { "fl", k, fl_strips }
    end
  end
  if dr > 0 then
    steps[#steps + 1] = { "ht", 1, 1 }
  end
  local pw_strips = f.r > 32 and 4 or 2
  for k = 1, pw_strips do
    steps[#steps + 1] = { "pw", k, pw_strips }
  end
  return {
    si = surface.index,
    fx = f.x,
    fy = f.y,
    r = f.r,
    dr = dr,
    fl_r = fl_rad,
    steps = steps,
    i = 1,
    read_n = 0,
    fl = {},
    ht = {},
    pw = {},
    unplugged = {},
    warn = { no_fuel = {}, no_ammo = {}, depleted = {} },
    seen_fl = {},
    seen_ht = {},
    seen_pw = {},
  }
end

local function run_job_step(surface, s, job)
  local step = job.steps[job.i]
  local kind, strip, strips = step[1], step[2], step[3]
  local rn = 0
  if kind == "fl" then
    local fm = fp_cache_for(s, surface, job.fx, job.fy, job.fl_r)
    rn = collect_fluids_area(surface, strip_area(job.fx, job.fy, job.fl_r, strip, strips), job.fl, job.seen_fl,
      fm and fm.fl, strips * 10 + strip)
    if strip == strips then
      send_parts("fl", job.fl, 6)
    end
  elseif kind == "ht" then
    local fm = fp_cache_for(s, surface, job.fx, job.fy, job.fl_r)
    rn = collect_heat_area(surface, strip_area(job.fx, job.fy, job.dr, strip, strips), job.ht, job.seen_ht,
      fm and fm.ht, 1)
    if strip == strips then
      send_parts("ht", job.ht, 2)
    end
  elseif kind == "pw" then
    rn = collect_power_area(surface, strip_area(job.fx, job.fy, job.r, strip, strips),
      job.pw, job.unplugged, job.warn, job.seen_pw)
  end
  job.read_n = job.read_n + rn
  job.i = job.i + 1
  M.counts.slices = M.counts.slices + 1
  return rn
end

function M.tick()
  local s = storage.f3d
  local surface = world.surface()
  if not perf.on("fluids_budget") then
    s.fp_job = nil
    if not rate.due("fp", INTERVAL) then
      return
    end
    local base_dr = settings.global["f3d-detail-radius"].value
    local r = math.min(base_dr, s.focus.r)
    local fl_r = fluid_radius(s, base_dr)
    local fm = fp_cache_for(s, surface, s.focus.x, s.focus.y, fl_r)
    prune_inv_cache()
    read_n = 0
    if fl_r > 0 then
      local fl = {}
      read_n = read_n + collect_fluids_area(surface, area(s.focus, fl_r), fl, nil, fm and fm.fl, 0)
      send_parts("fl", fl, 6)
    end
    if r > 0 then
      local ht = {}
      read_n = read_n + collect_heat_area(surface, area(s.focus, r), ht, nil, fm and fm.ht, 0)
      send_parts("ht", ht, 2)
    end
    local flat, unplugged, warn = {}, {}, { no_fuel = {}, no_ammo = {}, depleted = {} }
    read_n = read_n + collect_power_area(surface, area(s.focus, s.focus.r), flat, unplugged, warn, nil)
    send_parts("pw", flat, 2)
    for _, fn in ipairs(M.listeners) do
      read_n = read_n + (fn(surface.index, s.focus, s.focus.r, unplugged, warn) or 0)
    end
    rate.read("fp", read_n)
    M.counts.runs = M.counts.runs + 1
    return
  end

  local job = s.fp_job
  if job and job.si ~= surface.index then
    job, s.fp_job = nil, nil
  end
  local started_now = false
  if not job then
    if not rate.due("fp", INTERVAL) then
      return
    end
    local base_dr = settings.global["f3d-detail-radius"].value
    local dr = math.min(base_dr, s.focus.r)
    local fl_r = fluid_radius(s, base_dr)
    prune_inv_cache()
    job = make_job(surface, s.focus, dr, fl_r)
    s.fp_job = job
    started_now = true
  end

  local did = 0
  while job.i <= #job.steps do
    local rn = run_job_step(surface, s, job)
    did = did + 1
    if not started_now and rn > 0 then
      budget.spend(math.max(1, math.floor(rn * 0.14)), "fp")
    end
    if job.i > #job.steps or did >= MAX_SLICES_PER_TICK then
      break
    end
    if rn > 0 and not budget.can(SLICE_PRICE, "fp", 0.25) then
      break
    end
  end

  if job.i <= #job.steps then
    return
  end
  send_parts("pw", job.pw, 2)
  local total_read = job.read_n
  local f = { x = job.fx, y = job.fy }
  for _, fn in ipairs(M.listeners) do
    total_read = total_read + (fn(surface.index, f, job.r, job.unplugged, job.warn) or 0)
  end
  rate.read("fp", total_read)
  s.fp_job = nil
  M.counts.runs = M.counts.runs + 1
end

return M
