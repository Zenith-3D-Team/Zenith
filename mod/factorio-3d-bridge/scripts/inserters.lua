-- Inserter hands near the client's camera: what each hand does, sent as it happens (`ie`: picked,
-- dropped, status, a position now and then), or where each hand is every few ticks (`ih`, the
-- older samples). The client plays Factorio's swing between the events (inserter_arms.gd).
--
-- The inserters in the focus square are kept in a cache by chunk (searched once, again every
-- CHUNK_REFRESH ticks or when something is built or removed there: tracker.listeners), never a
-- search a tick. Each one is checked (its held count and status, two cheap reads) when something
-- can have happened: a hand on its way is checked at the tick the prototype's speeds say it
-- arrives (so the pickup and drop ticks come out exact), a hand chasing or waiting at a belt every
-- O.chase ticks (items come any tick), a hand waiting at a chest or machine less and less often
-- (up to O.idle ticks; a change wakes it), one without power or disabled every SLOW_TICKS with its
-- position (the client then draws it as sampled). A tick checks at most O.budget hands; the rest
-- wait for the next tick (the event then says how uncertain its tick is). Every hand's position
-- goes once in a while (O.resync) and once or twice mid-swing (the sweep's side, which the ends
-- can't tell), so a client that missed events is right again soon.
--
-- Multiplayer and save/load: nothing here is in `storage`. The cache, each hand's state and the
-- pending events are module-local: they only decide what is read (reads change nothing) and what
-- is sent to the UDP client, never the game's state, so peers whose tables differ don't desync
-- (as belt_sim.lua's line_cache and every module's counts). After a load (or on a peer that joins)
-- the tables are empty: the square is searched again on the next tick and every hand is sent a
-- position (sync), from which the client goes on. The debug trace (/f3d-ih trace) is the one thing
-- in storage (storage.f3d.ih_trace: an admin's command, so the same on every peer).

local registry = require("scripts.registry")
local transport = require("scripts.transport")
local world = require("scripts.world")
local map = require("scripts.map")
local rate = require("scripts.rate")
local perf = require("scripts.perf")
local tracker = require("scripts.tracker")
local belt_sim = require("scripts.belt_sim")
local budget = require("scripts.budget")

local M = {}

local HANDS_PER_MESSAGE = 300
local EVENTS_PER_MESSAGE = 400
local NEAR_INSERTER_RADIUS = 12
-- Numbers an `ie` record holds (docs/PROTOCOL.md).
local EVENT_WIDTH = 9
-- A chunk's inserters are searched for again after this many ticks (something built without an
-- event), as belt_sim.lua's chunks; the square itself is looked over every SQUARE_TICKS.
local CHUNK_REFRESH = 600
local SQUARE_TICKS = 30
-- Checks of a hand without power, out of fuel, frozen or disabled (each sends its position).
local SLOW_TICKS = 6
-- Checks of a full hand held at the pickup (its destination full), until it leaves.
local HELD_TICKS = 2
-- How many legs a hand's position is read mid-swing for (the sweep's side), then once every
-- PROBE_EVERY legs (a hand taking from a chest or machine sweeps the other side each cycle, seen
-- in the owner's save; the client counts cycles from the last probe, so one every few keeps it right).
local PROBES_FIRST = 2
local PROBE_EVERY = 8
-- An empty `ie` at most this often when nothing happened (the client's own clock for the arms).
local HEARTBEAT = 30

-- The debug trace's file in script-output, and its longest run (ticks: ten minutes).
M.TRACE_FILE = "f3d-ih-trace.jsonl"
local TRACE_MAX = 36000
local TRACE_RADIUS = 12

-- Event kinds (`ie` records: [kind, unit, tick, a, b, c, hand x, hand y, belt]). PLACED (for a client
-- whose hello says `ho`): an item a hand put on a belt, found on the belt at the drop's check:
-- [6, unit, tick, lane key (belt unit * 8 + line index), line position (1/256), the item's unique_id,
-- item id, stack, belt unit]; the client's belt simulation puts it on as the hand lets go.
local PICKED, DROPPED, STATUS, SYNC, GONE, PLACED = 1, 2, 3, 4, 5, 6
-- (PLACED) An item put is looked for this far (tiles) from the hand.
local PLACE_NEAR = 0.6

-- Status codes the client gets (a `defines.entity_status` name -> code; others are OTHER).
local CODE_WORKING, CODE_SOURCE, CODE_SPACE, CODE_MORE, CODE_LOW, CODE_NO_POWER, CODE_FROZEN, CODE_DISABLED, CODE_WAIT, CODE_OTHER =
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9
local STATUS_CODES = {
  working = CODE_WORKING, normal = CODE_WORKING,
  waiting_for_source_items = CODE_SOURCE, waiting_for_space_in_destination = CODE_SPACE,
  waiting_for_more_items = CODE_MORE, low_power = CODE_LOW,
  no_power = CODE_NO_POWER, no_fuel = CODE_NO_POWER, not_plugged_in_electric_network = CODE_NO_POWER,
  frozen = CODE_FROZEN,
  disabled = CODE_DISABLED, disabled_by_control_behavior = CODE_DISABLED, disabled_by_script = CODE_DISABLED,
  marked_for_deconstruction = CODE_DISABLED,
  waiting_for_target_to_be_built = CODE_WAIT, waiting_for_train = CODE_WAIT, no_filter = CODE_WAIT,
}
-- A hand that doesn't move as its speeds say: drawn from its positions.
local SLOW = { [CODE_LOW] = true, [CODE_NO_POWER] = true, [CODE_FROZEN] = true, [CODE_DISABLED] = true }

-- Run-time switches (/f3d-ih <name> <value>): module-local (they only change what is sent).
-- events: on | off | auto (auto: for a client whose hello says `ie`); samples: on | off | auto
-- (auto: unless events are sent); chase: ticks between checks of a hand at a belt; idle: the most
-- ticks between checks of a hand waiting at a chest or machine; budget: checks a tick at most;
-- resync: ticks between a hand's positions; every: ticks between `ie` messages; repeat: how many
-- messages each event goes in (lost datagrams).
local O = { events = "auto", samples = "auto", chase = 2, idle = 30, budget = 48, resync = 300, every = 2, ["repeat"] = 3 }
local DEFAULTS = {}
for k, v in pairs(O) do
  DEFAULTS[k] = v
end
M.options = O

-- What has been read and sent since loading: /f3d-ih says, and tests read them.
M.counts = { checks = 0, ticks = 0, events = 0, sends = 0, bytes = 0, searches = 0, syncs = 0, probes = 0, carried = 0,
  look_slices = 0, line_gets = 0, look_skips = 0 }

-- --- module state (see the top: nothing in storage) ----------------------------------------------

local S = {}            -- unit -> the hand's state (below)
local chunks = {}       -- surface index .. ":" .. chunk key -> {tick, list = {{entity, unit, x, y}, ...}}
local dirty = {}        -- chunk keys to search again (something built or removed there)
local due = {}          -- tick -> units to check then
local events = {}       -- pending {tick, record} (sent O.repeat times over O.every-tick messages)
local inside = {}       -- unit -> true: in the focus square now
local order = {}        -- the units inside, by chunk (the `ih` samples' order)
local square            -- {fx, fy, r, si, tick}: the square last looked over
local look_job          -- active sliced look_over scan when inserter_look_budget is on
local client_seen       -- storage.f3d.client the state was made for
local events_were = false
local last_heartbeat = 0
local status_codes      -- defines.entity_status value -> code
-- (gc_lean) Cached drop belt LuaTransportLine handles and reusable scratch arrays.
local belt_lines = {}   -- belt unit -> { e = belt, lines = { line1, ... } }
local ih_flat = {}
local placed_found = {}

local function clear_trailing(t, from)
  for i = #t, from, -1 do
    t[i] = nil
  end
end

local function code_of(status)
  if not status_codes then
    status_codes = {}
    for name, value in pairs(defines.entity_status) do
      status_codes[value] = STATUS_CODES[name] or CODE_OTHER
    end
  end
  return status_codes[status] or CODE_WORKING
end

local function reset()
  S, chunks, dirty, due, events, inside, order, square, look_job = {}, {}, {}, {}, {}, {}, {}, nil, nil
  belt_lines = {}
end
M.reset = reset

local BELTISH = { ["transport-belt"] = true, ["underground-belt"] = true, ["splitter"] = true, ["lane-splitter"] = true,
  ["loader"] = true, ["loader-1x1"] = true, ["linked-belt"] = true }

-- Ticks a hand takes to turn `turns` and change its reach by `dr` tiles at `rs` turns and `es`
-- tiles a tick, both at once, the slower deciding; a part that ends at its target snaps its last
-- step when within one of it: ceil(way / speed - 1), the game's cycle counts (35 for a basic
-- inserter's half turn, 12 for a fast one's). At least 1 for any way.
local function part_ticks(way, speed)
  if way <= 1e-9 or speed <= 0 then
    return 0
  end
  return math.max(1, math.ceil(way / speed - 1 - 1e-6))
end
local function travel(turns, dr, rs, es)
  return math.max(part_ticks(math.abs(turns), rs), part_ticks(math.abs(dr), es))
end
local function turns_of(dx, dy)
  return math.atan2(dy, dx) / (2 * math.pi)
end
local function wrap_turns(t)
  t = t - math.floor(t + 0.5)
  return t
end

-- The leg from the hand at (hx, hy) (map position) to the end (ea turns, er tiles) of hand `st`,
-- in ticks: the short way round (a half circle either way).
local function leg_ticks(st, hx, hy, ea, er)
  local dx, dy = hx - st.x, hy - st.y
  local a = turns_of(dx, dy)
  local r = math.sqrt(dx * dx + dy * dy)
  return travel(wrap_turns(ea - a), er - r, st.rs, st.es)
end

-- --- the cache: inserters by chunk, the focus square ---------------------------------------------

local function chunk_key(x, y)
  return (math.floor(x / 32) + 32768) * 65536 + (math.floor(y / 32) + 32768)
end

local function chunk_list(surface, cx, cy, now)
  local key = surface.index .. ":" .. chunk_key(cx * 32, cy * 32)
  local c = chunks[key]
  if c and not dirty[key] and now - c.tick < CHUNK_REFRESH then
    return c.list
  end
  dirty[key] = nil
  local found = surface.find_entities_filtered({
    area = { { cx * 32, cy * 32 }, { cx * 32 + 32, cy * 32 + 32 } },
    type = "inserter",
  })
  M.counts.searches = M.counts.searches + 1
  local list = {}
  for _, e in pairs(found) do
    local u = e.unit_number
    if u then
      local p = e.position
      list[#list + 1] = { e, u, p.x, p.y }
    end
  end
  chunks[key] = { tick = now, list = list }
  return list
end

local schedule

-- tracker.listeners: an inserter or belt built or removed (the listener runs while it is still valid):
-- its chunk is searched again, and nearby inserters recheck targets immediately when a belt changes.
local function touched(entity)
  if not (entity and entity.valid) then
    return
  end
  if entity.type == "inserter" then
    local p = entity.position
    dirty[entity.surface.index .. ":" .. chunk_key(p.x, p.y)] = true
    local u = entity.unit_number
    if u and S[u] then
      S[u].recheck = true
    end
  elseif BELTISH[entity.type] then
    local p = entity.position
    local si = entity.surface.index
    local px, py = p.x, p.y
    local cx0, cy0 = math.floor((px - 3) / 32), math.floor((py - 3) / 32)
    local cx1, cy1 = math.floor((px + 3) / 32), math.floor((py + 3) / 32)
    local now = game and game.tick or 0
    for cy = cy0, cy1 do
      for cx = cx0, cx1 do
        local c = chunks[si .. ":" .. chunk_key(cx * 32, cy * 32)]
        if c then
          for _, entry in ipairs(c.list) do
            local st = S[entry[2]]
            if st and math.abs(entry[3] - px) <= 3.5 and math.abs(entry[4] - py) <= 3.5 then
              st.recheck = true
              st.target_dirty = true
              if st.next and st.next > now + 1 then
                schedule(st, now + 1)
              end
            end
          end
        end
      end
    end
  end
end
tracker.listeners[#tracker.listeners + 1] = touched

schedule = function(st, tick)
  local now = game.tick
  if tick <= now then
    tick = now + 1
  end
  if st.sync_at and st.sync_at > now and st.sync_at < tick then
    tick = st.sync_at
  end
  if st.probe and st.probe > now and st.probe < tick then
    tick = st.probe
  end
  st.next = tick
  local list = due[tick]
  if not list then
    list = {}
    due[tick] = list
  end
  list[#list + 1] = st.u
end

local function belt_unit(target)
  if target and target.valid and BELTISH[target.type] then
    return target.unit_number or 0, true
  end
  return 0, false
end

-- Module-local pcall/sort helpers so describe()/look_over()/placed_on() allocate zero closures.
local function read_positions(e, st)
  local pp, dp = e.pickup_position, e.drop_position
  st.pa, st.pr = turns_of(pp.x - st.x, pp.y - st.y), math.sqrt((pp.x - st.x) ^ 2 + (pp.y - st.y) ^ 2)
  st.da, st.dr = turns_of(dp.x - st.x, dp.y - st.y), math.sqrt((dp.x - st.x) ^ 2 + (dp.y - st.y) ^ 2)
  st.ppx, st.ppy, st.dpx, st.dpy = pp.x, pp.y, dp.x, dp.y
end

local function get_entity_quality(e)
  return e.quality
end

local function read_speeds(e, st)
  local proto = e.prototype
  local okq, q = pcall(get_entity_quality, e)
  if not okq then
    q = nil
  end
  st.rs = proto.get_inserter_rotation_speed(q)
  st.es = proto.get_inserter_extension_speed(q)
end

local function read_targets(e, st)
  local pu, du
  if not st.target_dirty then
    pu, du = belt_sim.actor_belts(st.u)
  end
  st.target_dirty = nil
  if pu == nil then
    pu = belt_unit(e.pickup_target)
    local dt = e.drop_target
    du = belt_unit(dt)
    if perf.on("gc_lean") and dt and dt.valid and BELTISH[dt.type] then
      st.drop_ent = dt
    else
      st.drop_ent = nil
    end
  elseif perf.on("gc_lean") and du and du ~= 0 then
    local dt = e.drop_target
    st.drop_ent = (dt and dt.valid and BELTISH[dt.type]) and dt or nil
  else
    st.drop_ent = nil
  end
  st.pu, st.du = pu or 0, du or 0
end

local function read_pickup_cap(e)
  return e.inserter_target_pickup_count
end

local function cmp_chunk_dist(a, b)
  if a[3] ~= b[3] then return a[3] < b[3] end
  if a[2] ~= b[2] then return a[2] < b[2] end
  return a[1] < b[1]
end

local function cmp_placed_desc(a, b)
  return a[1] > b[1]
end

-- What a hand reaches for: its ends (from pickup_position / drop_position), speeds at its quality,
-- whether each end is a belt (belt_sim's actors know their belts; else the targets are read) and
-- its hand's size. Read once when the hand is found and again at each resync (a belt built later).
local function describe(st)
  local e = st.e
  -- (Each read on its own: a modded inserter without one still gets the others; a failed one
  -- keeps the base inserter's numbers.)
  pcall(read_positions, e, st)
  pcall(read_speeds, e, st)
  pcall(read_targets, e, st)
  local okc, cap = pcall(read_pickup_cap, e)
  if okc then
    st.cap = cap
  end
  if not st.rs or st.rs <= 0 or not st.es or st.es <= 0 then
    st.rs, st.es = 0.014, 0.035
  end
  if not st.pa then
    st.pa, st.pr, st.da, st.dr = -0.25, 1, 0.25, 1.2
  end
  st.pu, st.du, st.cap = st.pu or 0, st.du or 0, st.cap or 1
  -- The ticks between the ends (nominal), each way.
  st.t_pd = travel(wrap_turns(st.da - st.pa), st.dr - st.pr, st.rs, st.es)
  st.t_dp = st.t_pd
end

local function found(entry, now)
  local u = entry[2]
  local st = { e = entry[1], u = u, x = entry[3], y = entry[4], cnt = -1, st = -1, item = 0, last = now,
    mode = "new", probes = PROBES_FIRST, legs = 0, idle_gap = 2 }
  describe(st)
  st.sync_at = now + 1
  S[u] = st
  schedule(st, now + 1)
  return st
end

-- Looks the focus square over: the inserters in it now (found ones get their first check next
-- tick), those gone from it said so. Every SQUARE_TICKS, when the focus moved, and when a chunk
-- is dirty. With inserter_look_budget, chunks order nearest-first and fresh searches + describe()
-- slice across ticks using read-only budget.left() (module-local state never mutates storage).
local LOOK_CHUNK_COST = 15
local LOOK_ENTRY_COST = 1
local LOOK_CACHED_COST = 0.05
local LOOK_MIN_UNITS = 40
local LOOK_MAX_UNITS = 200
local LOOK_MAX_SEARCHES = 4

local function finish_look(now_inside, new_order, visited, now)
  for u in pairs(inside) do
    if not now_inside[u] and S[u] then
      S[u] = nil
      events[#events + 1] = { now, { GONE, u, now, 0, 0, 0, 0, 0, 0 } }
    end
  end
  -- (Dirty chunks outside the square: searched afresh when they come in.)
  for key in pairs(dirty) do
    if not visited or not visited[key] then
      chunks[key] = nil
      dirty[key] = nil
    end
  end
  inside, order = now_inside, new_order
end

local function look_due(surface, fx, fy, r, now)
  if not square or square.si ~= surface.index or square.r ~= r or next(dirty) then
    return true
  end
  local dx, dy = math.abs(square.fx - fx), math.abs(square.fy - fy)
  if perf.on("gc_lean") then
    if dx < 0.5 and dy < 0.5 then
      if now - square.tick < CHUNK_REFRESH then
        M.counts.look_skips = M.counts.look_skips + 1
        return false
      end
      return true
    end
    if dx < 4 and dy < 4 and now - square.tick < SQUARE_TICKS then
      M.counts.look_skips = M.counts.look_skips + 1
      return false
    end
    return true
  end
  local moved = dx >= 0.5 or dy >= 0.5
  return moved or now - square.tick >= SQUARE_TICKS
end

local function look_over(surface, f, r, now)
  local fx, fy = f.x, f.y
  if not perf.on("inserter_look_budget") then
    look_job = nil
    if not look_due(surface, fx, fy, r, now) then
      return
    end
    square = { fx = fx, fy = fy, r = r, si = surface.index, tick = now }
    local seen = map.view_filter()
    local now_inside, new_order = {}, {}
    for cy = math.floor((fy - r) / 32), math.floor((fy + r) / 32) do
      for cx = math.floor((fx - r) / 32), math.floor((fx + r) / 32) do
        for _, entry in ipairs(chunk_list(surface, cx, cy, now)) do
          local x, y = entry[3], entry[4]
          if math.abs(x - fx) <= r and math.abs(y - fy) <= r and (not seen or seen(x, y)) and entry[1].valid then
            local u = entry[2]
            now_inside[u] = true
            new_order[#new_order + 1] = u
            if not S[u] then
              found(entry, now)
            end
          end
        end
      end
    end
    finish_look(now_inside, new_order, nil, now)
    return
  end

  if look_job then
    local j = look_job
    if j.si ~= surface.index or j.r ~= r
        or math.abs(j.fx - fx) >= math.max(8, r / 2)
        or math.abs(j.fy - fy) >= math.max(8, r / 2) then
      look_job = nil
    end
  end
  if not look_job then
    if not look_due(surface, fx, fy, r, now) then
      return
    end
    local clist = {}
    for cy = math.floor((fy - r) / 32), math.floor((fy + r) / 32) do
      for cx = math.floor((fx - r) / 32), math.floor((fx + r) / 32) do
        local dist = math.max(math.abs(cx * 32 + 16 - fx), math.abs(cy * 32 + 16 - fy))
        clist[#clist + 1] = { cx, cy, dist }
      end
    end
    table.sort(clist, cmp_chunk_dist)
    look_job = { fx = fx, fy = fy, r = r, si = surface.index, list = clist, ci = 1, ei = 1,
      now_inside = {}, new_order = {}, seen_u = {}, visited = {} }
  end

  local job = look_job
  local seen = map.view_filter()
  local left = budget.left()
  local unit_cap = math.max(LOOK_MIN_UNITS, math.min(LOOK_MAX_UNITS, math.floor(math.max(0, left))))
  local search_cap = left <= 0 and 1 or LOOK_MAX_SEARCHES
  local spent, searches = 0, 0
  while job.ci <= #job.list and spent < unit_cap do
    if not job.cur then
      local c = job.list[job.ci]
      local key = surface.index .. ":" .. chunk_key(c[1] * 32, c[2] * 32)
      local cached = chunks[key]
      local needs_search = not cached or dirty[key] or now - cached.tick >= CHUNK_REFRESH
      if needs_search and searches > 0 and (searches >= search_cap or spent + LOOK_CHUNK_COST > unit_cap) then
        break
      end
      if needs_search then
        searches = searches + 1
        spent = spent + LOOK_CHUNK_COST
      end
      job.visited[key] = true
      job.cur = chunk_list(surface, c[1], c[2], now)
      job.ei = 1
    end
    local cur = job.cur
    while job.ei <= #cur do
      local entry = cur[job.ei]
      local u = entry[2]
      if not S[u] and spent > 0 and spent + LOOK_ENTRY_COST > unit_cap then
        break
      end
      job.ei = job.ei + 1
      local x, y = entry[3], entry[4]
      if math.abs(x - job.fx) <= job.r and math.abs(y - job.fy) <= job.r and (not seen or seen(x, y)) and entry[1].valid then
        if not job.seen_u[u] then
          job.seen_u[u] = true
          job.now_inside[u] = true
          job.new_order[#job.new_order + 1] = u
          if not S[u] then
            found(entry, now)
            spent = spent + LOOK_ENTRY_COST
          else
            spent = spent + LOOK_CACHED_COST
          end
        end
      else
        spent = spent + LOOK_CACHED_COST
      end
      if spent >= unit_cap and job.ei <= #cur then
        break
      end
    end
    if job.ei > #cur then
      job.cur = nil
      job.ci = job.ci + 1
    else
      break
    end
  end
  if job.ci <= #job.list then
    M.counts.look_slices = M.counts.look_slices + 1
    return
  end
  square = { fx = job.fx, fy = job.fy, r = job.r, si = job.si, tick = now }
  finish_look(job.now_inside, job.new_order, job.visited, now)
  look_job = nil
end

-- --- the checks ----------------------------------------------------------------------------------

local function hand_fixed(e)
  local p = e.held_stack_position
  return world.fixed(p.x), world.fixed(p.y), p.x, p.y
end

local function emit(st, kind, now, a, b, c, hx, hy, belt)
  events[#events + 1] = { now, { kind, st.u, now, a, b, c, hx or 0, hy or 0, belt or 0 } }
  M.counts.events = M.counts.events + 1
  local tr = storage.f3d.ih_trace
  if tr then
    tr.ev = tr.ev or {}
    tr.ev[#tr.ev + 1] = { kind, st.u, now, a, b, c, hx or 0, hy or 0, belt or 0 }
  end
end

-- (PLACED) The items hand `st` put on its drop belt between its last check and this one (`n` of them,
-- counting stacks), found on the belt now: those nearest the hand at (px, py) with the newest ids (an
-- item gets its unique_id when it comes onto a belt: the one just dropped is the newest there), within
-- PLACE_NEAR. A few reads of the drop belt's lines a drop: only for a client that asked (`ho`).
local function belt_line_handles(belt, unit)
  if not perf.on("gc_lean") then
    belt_lines = {}
    local lines = {}
    for i = 1, belt.get_max_transport_line_index() do
      lines[i] = belt.get_transport_line(i)
      M.counts.line_gets = M.counts.line_gets + 1
    end
    return lines
  end
  local c = belt_lines[unit]
  if c and c.e == belt and belt.valid then
    return c.lines
  end
  if game.tick % 300 == 0 and next(belt_lines) ~= nil then
    for u, entry in pairs(belt_lines) do
      if not (entry.e and entry.e.valid) then
        belt_lines[u] = nil
      end
    end
  end
  local lines = {}
  for i = 1, belt.get_max_transport_line_index() do
    lines[i] = belt.get_transport_line(i)
    M.counts.line_gets = M.counts.line_gets + 1
  end
  belt_lines[unit] = { e = belt, lines = lines }
  return lines
end

local function placed_on(belt, st, now, px, py, n)
  if not (belt and belt.valid and BELTISH[belt.type]) then
    return 0
  end
  local unit = belt.unit_number
  if not unit then
    return 0
  end
  local lean = perf.on("gc_lean")
  local found = lean and placed_found or {}
  local fn = 0
  local lines = belt_line_handles(belt, unit)
  for i, line in ipairs(lines) do
    if line and line.valid then
      for _, it in pairs(line.get_detailed_contents()) do
        local g = line.get_line_item_position(it.position)
        if g and math.abs(g.x - px) <= PLACE_NEAR and math.abs(g.y - py) <= PLACE_NEAR then
          fn = fn + 1
          found[fn] = { it.unique_id, i, it.position, it.stack }
        end
      end
    end
  end
  if lean then
    clear_trailing(found, fn + 1)
  end
  table.sort(found, cmp_placed_desc)
  local got = 0
  for _, f in ipairs(found) do
    if got >= n then
      break
    end
    local stack = f[4]
    local valid_stack = stack ~= nil and stack.valid_for_read
    local cnt = valid_stack and stack.count or 1
    -- (The record's hand x, y carry the item and its stack.)
    emit(st, PLACED, now, unit * 8 + f[2], world.fixed(f[3]), f[1], valid_stack and registry.item_id(stack.name) or 0,
      cnt, unit)
    got = got + math.max(cnt, 1)
  end
  return got
end

local function placed(st, now, px, py, n)
  if perf.on("gc_lean") then
    local dt = st.drop_ent
    if not (dt and dt.valid) then
      dt = st.e.drop_target
      st.drop_ent = (dt and dt.valid and BELTISH[dt.type]) and dt or nil
    end
    placed_on(dt, st, now, px, py, n)
  else
    placed_on(st.e.drop_target, st, now, px, py, n)
  end
end

-- The hand set off for an end: checked when it should arrive (the drop end, holding; the pickup,
-- empty), from where it is now; its position read once mid-way while the sweep's side is wanted.
local function set_off(st, now, hx, hy)
  local to_drop = st.cnt > 0
  local ticks
  if hx then
    ticks = to_drop and leg_ticks(st, hx, hy, st.da, st.dr) or leg_ticks(st, hx, hy, st.pa, st.pr)
  else
    ticks = to_drop and st.t_pd or st.t_dp
  end
  st.mode = to_drop and "to_drop" or "to_pick"
  st.pred = now + ticks
  st.legs = st.legs + 1
  st.probe = nil
  st.fx, st.fy, st.held = hx, hy, nil
  if st.probes > 0 and ticks >= 4 then
    st.probes = st.probes - 1
    st.probe = now + math.floor(ticks / 2)
  elseif st.legs % PROBE_EVERY == 0 and ticks >= 4 then
    st.probe = now + math.floor(ticks / 2)
  end
  schedule(st, st.pred)
end

-- Waiting at an end: at a belt, checked every O.chase ticks (an item or room comes any tick; one
-- that has waited BELT_LONG ticks a tick less often, capped at 3 ticks to match TAKE_LEAD); elsewhere
-- less and less often, up to O.idle.
local BELT_LONG = 120
local function wait(st, now, at_pick)
  st.mode = at_pick and "pick_wait" or "drop_wait"
  st.pred = nil
  local belt = at_pick and st.pu ~= 0 or not at_pick and st.du ~= 0
  st.since = st.since or now
  if belt then
    local waited = now - st.since
    st.idle_gap = math.min(3, O.chase + (waited >= 2 * BELT_LONG and 2 or waited >= BELT_LONG and 1 or 0))
  else
    st.idle_gap = math.min(O.idle, math.max(2, st.idle_gap * 2))
  end
  schedule(st, now + st.idle_gap)
end

local function check_sync_or_slow(st, now, e, cnt, item, code, sync, probe, hx, hy, px, py)
  if not (sync or probe or (SLOW[code] and not hx)) then
    return hx, hy, px, py
  end
  if not hx then
    hx, hy, px, py = hand_fixed(e)
  end
  if sync then
    emit(st, SYNC, now, cnt, item, code, hx, hy, 0)
    M.counts.syncs = M.counts.syncs + 1
    st.sync_at = now + O.resync + st.u % 60
    describe(st)
  elseif probe then
    emit(st, SYNC, now, cnt, item, code, hx, hy, 1)  -- (belt 1: a mid-swing probe)
    M.counts.probes = M.counts.probes + 1
    -- (A probe that found the hand still at an end (it waited there before setting off) says
    -- nothing of the side: another on the next leg.)
    local near_end = st.ppx and (math.abs(px - st.ppx) + math.abs(py - st.ppy) < 0.5 or math.abs(px - st.dpx) + math.abs(py - st.dpy) < 0.5)
    if near_end then
      st.probes = st.probes + 1
    end
  elseif hx ~= st.slow_x or hy ~= st.slow_y then
    -- (Slow: its position whenever it moved since the last; one standing still is checked less
    -- and less often, up to O.idle, a change waking it.)
    emit(st, SYNC, now, cnt, item, code, hx, hy, 0)
    M.counts.syncs = M.counts.syncs + 1
  end
  return hx, hy, px, py
end

local function check_idle_leg(st, now, e, cnt, item, code, was_code, hx, hy, px, py)
  local mode = st.mode
  if mode == "collect" then
    if code == CODE_MORE then
      -- (A stack inserter waiting for a full hand: items come any tick.)
      st.collect_from = now
      schedule(st, now + O.chase)
    elseif now - st.collect_from >= math.max(2, math.floor(st.t_pd / 2)) then
      -- (Left with what it had: it set off at its last pick.)
      local from = st.collect_from
      st.mode = "to_drop"
      st.pred = from + leg_ticks(st, st.hx or st.x, st.hy or st.y, st.da, st.dr)
      st.legs = st.legs + 1
      schedule(st, math.max(now + 1, st.pred))
    else
      schedule(st, now + O.chase)
    end
    return
  end
  if mode == "to_drop" or mode == "to_pick" then
    if st.pred and now < st.pred then
      -- (A probe or a sync mid-way.)
      schedule(st, st.pred)
      return
    end
    -- Nothing happened by the tick it should have arrived. Where is it? At the end it is bound for:
    -- it waits there (a belt: items or room come any tick; a chest or machine: less and less
    -- often). Still at the end it set off from (a full hand held at the pickup, its destination
    -- full, with the status saying nothing): looked at every HELD_TICKS until it leaves. On its way
    -- (it left later than its pick or drop): a sync says where it is (belt 2: on its way), and it
    -- is checked when it should arrive from there.
    if not px then
      hx, hy, px, py = hand_fixed(e)
    end
    local to_pick = mode == "to_pick"
    local tx, ty = to_pick and st.ppx or st.dpx, to_pick and st.ppy or st.dpy
    local at_target = not tx or math.abs(px - tx) + math.abs(py - ty) < (to_pick and 0.9 or 0.6)
    if not at_target and st.fx and math.abs(px - st.fx) + math.abs(py - st.fy) < 0.4 then
      st.held = (st.held or 0) + 1
      schedule(st, now + (st.held > 30 and 2 * HELD_TICKS or HELD_TICKS))
      return
    end
    if not at_target then
      emit(st, SYNC, now, cnt, item, code, hx, hy, 2)
      M.counts.syncs = M.counts.syncs + 1
      local ticks = to_pick and leg_ticks(st, px, py, st.pa, st.pr) or leg_ticks(st, px, py, st.da, st.dr)
      st.pred = now + math.max(1, ticks)
      st.fx, st.fy, st.held = nil, nil, nil
      if st.probes > 0 and ticks >= 4 then
        st.probes = st.probes - 1
        st.probe = now + math.floor(ticks / 2)
      end
      schedule(st, st.pred)
      return
    end
    st.idle_gap = 1
    wait(st, now, to_pick)
    return
  end
  if mode == "pick_wait" or mode == "drop_wait" then
    if code ~= was_code and code == CODE_WORKING then
      -- (Something to do: at a belt it chases the item; checked every O.chase ticks.)
      st.idle_gap = O.chase
      schedule(st, now + O.chase)
      return
    end
    wait(st, now, mode == "pick_wait")
    return
  end
  -- (Back from slow: its phase from what it holds, from where it is.)
  if not px then
    hx, hy, px, py = hand_fixed(e)
  end
  set_off(st, now, px, py)
end

local function check(st, now)
  local e = st.e
  if not e.valid then
    S[st.u] = nil
    inside[st.u] = nil
    emit(st, GONE, now, 0, 0, 0)
    return
  end
  M.counts.checks = M.counts.checks + 1
  local stack = e.held_stack
  local cnt = stack.valid_for_read and stack.count or 0
  local item = st.item
  if cnt > 0 and (st.cnt <= 0 or cnt ~= st.cnt) then
    item = registry.item_id(stack.name)
  elseif cnt == 0 then
    item = 0
  end
  local code = code_of(e.status)
  local was, was_code, was_item = st.cnt, st.st, st.item
  local unc = (st.pred == now or now - st.last <= 1) and 0 or now - st.last - 1
  if st.recheck then
    st.recheck = nil
    describe(st)
  end
  local sync = st.sync_at and now >= st.sync_at
  local probe = st.probe and now >= st.probe
  if probe then
    st.probe = nil
  end
  st.cnt, st.st, st.item, st.last = cnt, code, item, now
  local hx, hy, px, py
  if was < 0 then
    -- First seen: its position, what it holds and its status: the client's starting point.
    hx, hy, px, py = hand_fixed(e)
    emit(st, SYNC, now, cnt, item, code, hx, hy, 0)
    M.counts.syncs = M.counts.syncs + 1
    st.sync_at = now + O.resync + st.u % 60
    sync = false
  elseif cnt > was then
    hx, hy, px, py = hand_fixed(e)
    local emit_hx, emit_hy = hx, hy
    if st.ppx and st.ppy then
      local dx, dy = px - st.ppx, py - st.ppy
      if unc > 0 or dx * dx + dy * dy > 0.25 then
        emit_hx, emit_hy = world.fixed(st.ppx), world.fixed(st.ppy)
      end
    end
    emit(st, PICKED, now, cnt, item, unc, emit_hx, emit_hy, st.pu)
  elseif cnt < was then
    hx, hy, px, py = hand_fixed(e)
    emit(st, DROPPED, now, cnt, was_item, unc, hx, hy, st.du)
    local client = storage.f3d.client
    if st.du ~= 0 and client and client.ho then
      pcall(placed, st, now, px, py, was - cnt)
    end
  end
  if code ~= was_code and was >= 0 then
    -- (With a pick or drop too: a hand that took but waits where it is, its destination full, says
    -- so, and the client holds it there until the status says it works.)
    if not hx then
      hx, hy, px, py = hand_fixed(e)
    end
    emit(st, STATUS, now, cnt, item, code, hx, hy, 0)
  end
  hx, hy, px, py = check_sync_or_slow(st, now, e, cnt, item, code, sync, probe, hx, hy, px, py)
  -- What next.
  if SLOW[code] then
    if st.mode == "slow" and hx == st.slow_x and hy == st.slow_y then
      st.slow_gap = math.min(O.idle, (st.slow_gap or SLOW_TICKS) * 2)
    else
      st.slow_gap = SLOW_TICKS
    end
    st.slow_x, st.slow_y = hx, hy
    st.mode = "slow"
    st.pred = nil
    schedule(st, now + st.slow_gap)
    return
  end
  st.slow_x, st.slow_y = nil, nil
  if cnt ~= was or code ~= was_code then
    st.since = nil  -- (something happened: the wait at a belt starts over)
  end
  if was < 0 then
    -- (Its hand's phase isn't known yet: holding, it is on its way to the drop or waiting there;
    -- empty, the other way. Checked as if it just set off: when it arrives nothing has changed
    -- and it waits, or something changed before.)
    set_off(st, now, px, py)
    if cnt > 0 and st.cap > 1 then
      st.mode = "collect"
      st.pred = nil
      st.collect_from = now
      st.hx, st.hy = px, py
      schedule(st, now + O.chase)
    end
    return
  end
  if cnt > was then
    if st.cap > 1 and cnt < st.cap and st.mode ~= "to_drop" then
      -- A hand that takes several (bulk, stack): more may come before it leaves, so it is checked
      -- every O.chase ticks until half a leg has passed with no more, then as one set off.
      st.mode = "collect"
      st.pred = nil
      st.collect_from = now
      st.hx, st.hy = px, py
      schedule(st, now + O.chase)
    else
      set_off(st, now, px, py)
    end
    return
  end
  if cnt < was then
    if cnt == 0 then
      set_off(st, now, px, py)
    else
      -- Dropping one a tick onto a belt (or part of a hand into a nearly full machine).
      st.mode = "drop_wait"
      st.pred = nil
      schedule(st, now + O.chase)
    end
    return
  end
  check_idle_leg(st, now, e, cnt, item, code, was_code, hx, hy, px, py)
end

-- --- the sends -----------------------------------------------------------------------------------

-- `ih`: every hand inside the square, its position and held item (the older clients' samples).
local function collect()
  local lean = perf.on("gc_lean")
  local flat = lean and ih_flat or {}
  local n = 0
  for _, u in ipairs(order) do
    local st = S[u]
    if st and st.e.valid then
      local p = st.e.held_stack_position
      local stack = st.e.held_stack
      flat[n + 1] = u
      flat[n + 2] = world.fixed(p.x)
      flat[n + 3] = world.fixed(p.y)
      flat[n + 4] = stack.valid_for_read and registry.item_id(stack.name) or 0
      n = n + 4
    end
  end
  if lean then
    clear_trailing(flat, n + 1)
  end
  return flat
end

-- `ie`: the events of the last O.every * O.repeat ticks (each goes O.repeat times, in as many
-- messages, so a lost datagram loses none), by tick.
-- `ih` for a wire version 3 client: each part a kind 22 frame (k, part, parts, p, then the hands as one block,
-- whole: not delta-coded). Every part is made before any is sent; nil when string.pack refuses a number (the
-- caller sends JSON), else the bytes.
local function hands_frames(flat, period)
  local n = HANDS_PER_MESSAGE * 4
  local parts = math.max(1, math.ceil(#flat / n))
  local frames = {}
  for part = 1, parts do
    local out = { string.pack("<I4I4I4I4", game.tick, part, parts, period) }
    transport.pack_block(out, flat, (part - 1) * n + 1, math.min(part * n, #flat))
    frames[part] = table.concat(out)
  end
  return frames
end

local function send_hands_bin(flat, period)
  local ok, frames = pcall(hands_frames, flat, period)
  if not ok then
    return nil
  end
  local bytes = 0
  for _, body in ipairs(frames) do
    transport.send_frame(transport.KIND_IH, "ih", body)
    bytes = bytes + #body
  end
  return bytes
end

local function send_events(now, window)
  local keep = {}
  local flat = {}
  for _, ev in ipairs(events) do
    if ev[1] > now - window then
      keep[#keep + 1] = ev
      local rec = ev[2]
      for i = 1, EVENT_WIDTH do
        flat[#flat + 1] = rec[i]
      end
    end
  end
  events = keep
  if #flat == 0 and now - last_heartbeat < HEARTBEAT then
    return 0
  end
  last_heartbeat = now
  local bytes = transport.send_groups("ie", flat, EVENT_WIDTH, EVENTS_PER_MESSAGE, ',"n":' .. window .. ',"p":' .. O.every) or 0
  M.counts.sends = M.counts.sends + 1
  M.counts.bytes = M.counts.bytes + bytes
  return bytes
end

-- Whether events / samples go to this client (O.events, O.samples; auto: the hello's `ie`: 1 events
-- instead of samples, 2 both).
local function wants()
  local client = storage.f3d.client
  local ev = O.events == "on" or (O.events == "auto" and client ~= nil and client.ie == true)
  local sm = O.samples == "on" or (O.samples == "auto" and (not ev or (client ~= nil and client.ih_too == true)))
  return ev, sm
end
M.wants = wants

-- (PLACED with no inserter, `/f3d-perf drop_put`) The item the character just dropped on `belt` with Zenith's Z at
-- (x, y) (tiles; ui_actions.lua), told at once as a hand's put is, with unit 0: its lane, place and id, so the
-- client's belt simulation has it now instead of at the lane's next read. For a client whose hello says `ho` and
-- that gets the events. Returns how many were told (0 or 1).
local DROP_HAND = { u = 0 }
function M.put_by_hand(belt, x, y)
  local s = storage.f3d
  local client = s and s.client
  if not (client and client.ho and wants()) then
    return 0
  end
  if not (belt and belt.valid) then
    return 0
  end
  local now = game.tick
  local ok, got = pcall(placed_on, belt, DROP_HAND, now, x, y, 1)
  if not (ok and got and got > 0) then
    return 0
  end
  -- Flush `ie` immediately so hand-dropped items don't wait for the periodic timer flush.
  local window = O.every * O["repeat"]
  local n = #events
  local ok_send, bytes = pcall(send_events, now, window)
  local tr = s and s.ih_trace
  if tr and ok_send and bytes and bytes > 0 then
    tr.ie_sends = (tr.ie_sends or 0) + 1
    tr.ie_events = (tr.ie_events or 0) + n
    tr.ie_bytes = (tr.ie_bytes or 0) + bytes
  end
  return got
end

-- --- the debug trace (tools/inserter_check.py) ---------------------------------------------------
--
-- /f3d-ih trace [ticks] [radius]: for `ticks` ticks (default 1200) every inserter within `radius`
-- tiles of the focus (default 12) is written each tick to script-output/f3d-ih-trace.jsonl: the
-- ground truth the client's drawn arms are measured against. Lines:
--   {"u": unit, "n": name, "x", "y": its position, "d": direction, "pp": [x, y] pickup_position,
--    "dp": [x, y] drop_position, "rs": rotation speed (turns a tick, at its quality), "es": extension
--    speed (tiles a tick), "q": quality, "m": mirroring (0/1), "pt": pickup target type or "", "dt":
--    drop target type or ""}: an inserter the first tick it is seen;
--   [tick, unit, hand x, hand y (1/256 tile), held count, held item id, status, ...]: a tick's hands;
--   {"ev": [kind, unit, tick, a, b, c, hand x, hand y, belt]}: an `ie` event as it was made;
--   {"end": tick, "ticks": n, "ih_sends": n, "ih_hands": n, "ih_bytes": n, "ie_sends", "ie_events",
--    "ie_bytes", "checks": the hands checked meanwhile}: the last line.
-- /f3d-ih off stops it; /f3d-ih says whether it runs.

local function num(v)
  return math.floor((v or 0) * 1000 + 0.5) / 1000
end

local function get_mirroring(e)
  return e.mirroring
end

local function read_proto_speeds(proto, q)
  return proto.get_inserter_rotation_speed(q), proto.get_inserter_extension_speed(q)
end

local function build_trace_desc(e)
  local proto = e.prototype
  local pp, dp = e.pickup_position, e.drop_position
  local q = e.quality
  local pt, dt = e.pickup_target, e.drop_target
  local okm, mirror = pcall(get_mirroring, e)
  if not okm then
    mirror = false
  end
  local oks, rs, es = pcall(read_proto_speeds, proto, q)
  if not oks then
    rs, es = 0, 0
  end
  return {
    u = e.unit_number, n = e.name, x = num(e.position.x), y = num(e.position.y), d = e.direction,
    pp = { num(pp.x), num(pp.y) }, dp = { num(dp.x), num(dp.y) }, rs = rs, es = es,
    q = q and q.name or "normal", m = mirror and 1 or 0,
    pt = pt and pt.valid and pt.type or "", dt = dt and dt.valid and dt.type or "",
  }
end

local function describe_trace(e)
  local ok, rec = pcall(build_trace_desc, e)
  if not ok then
    return { u = e.unit_number, n = e.name, x = num(e.position.x), y = num(e.position.y), d = e.direction, err = tostring(rec) }
  end
  return rec
end

-- The inserters within the trace's radius are looked for every TRACE_SEARCH ticks (the search is
-- most of a tick's cost); the lines are written every TRACE_FLUSH ticks.
local TRACE_SEARCH = 60
local TRACE_FLUSH = 10

local function trace_tick(tr)
  if not helpers.write_file then
    return
  end
  local found_list = tr.found
  if not found_list or game.tick - (tr.found_tick or 0) >= TRACE_SEARCH then
    local f = storage.f3d.focus
    local r = tr.r
    found_list = map.view_only(world.surface().find_entities_filtered({
      area = { { f.x - r, f.y - r }, { f.x + r, f.y + r } },
      type = "inserter",
    }))
    tr.found, tr.found_tick = found_list, game.tick
  end
  local lines = tr.buf or {}
  local row = { game.tick }
  for _, e in pairs(found_list) do
    local unit = e.valid and e.unit_number
    if unit then
      if not tr.seen[unit] then
        tr.seen[unit] = true
        lines[#lines + 1] = helpers.table_to_json(describe_trace(e))
      end
      local p = e.held_stack_position
      local stack = e.held_stack
      local n = #row
      row[n + 1] = unit
      row[n + 2] = world.fixed(p.x)
      row[n + 3] = world.fixed(p.y)
      if stack.valid_for_read then
        row[n + 4] = stack.count
        row[n + 5] = registry.item_id(stack.name)
      else
        row[n + 4] = 0
        row[n + 5] = 0
      end
      row[n + 6] = e.status or 0
    end
  end
  lines[#lines + 1] = "[" .. table.concat(row, ",") .. "]"
  if tr.ev then
    for _, ev in ipairs(tr.ev) do
      lines[#lines + 1] = '{"ev":[' .. table.concat(ev, ",") .. "]}"
    end
    tr.ev = nil
  end
  tr.ticks = tr.ticks + 1
  local ending = game.tick >= tr.until_tick
  if ending then
    lines[#lines + 1] = helpers.table_to_json({ ["end"] = game.tick, ticks = tr.ticks, ih_sends = tr.sends,
      ih_hands = tr.hands, ih_bytes = tr.bytes, ie_sends = tr.ie_sends, ie_events = tr.ie_events, ie_bytes = tr.ie_bytes,
      checks = tr.checks })
    storage.f3d.ih_trace = nil
  end
  if ending or tr.ticks % TRACE_FLUSH == 0 then
    helpers.write_file(M.TRACE_FILE, table.concat(lines, "\n") .. "\n", true)
    tr.buf = nil
  else
    tr.buf = lines
  end
end

local function status_text()
  local ev, sm = wants()
  local n, modes = 0, {}
  for _, st in pairs(S) do
    n = n + 1
    modes[st.mode] = (modes[st.mode] or 0) + 1
  end
  local parts = {}
  for mode, k in pairs(modes) do
    parts[#parts + 1] = mode .. " " .. k
  end
  table.sort(parts)
  local c = M.counts
  local opts = {}
  for _, k in ipairs({ "events", "samples", "chase", "idle", "budget", "resync", "every", "repeat" }) do
    opts[#opts + 1] = k .. " " .. tostring(O[k]) .. (O[k] == DEFAULTS[k] and "" or " (set)")
  end
  return string.format("[Zenith] inserters: %d in the square (%s); sending %s%s; %.2f checks a tick, %d events, %d syncs, %d probes, %d searches; %s",
    n, table.concat(parts, ", "), ev and "events" or "", sm and (ev and " and samples" or "samples") or (ev and "" or "nothing"),
    c.checks / math.max(1, c.ticks), c.events, c.syncs, c.probes, c.searches, table.concat(opts, ", "))
end

-- /f3d-ih [trace [ticks] [radius] | off | <option> <value|default> | reset]
function M.command(param)
  local s = storage.f3d
  local words = {}
  for w in tostring(param or ""):gmatch("%S+") do
    words[#words + 1] = w
  end
  if words[1] == "trace" then
    local ticks = math.max(1, math.min(TRACE_MAX, math.floor(tonumber(words[2]) or 1200)))
    local r = math.max(1, math.min(64, tonumber(words[3]) or TRACE_RADIUS))
    -- (The command's own tick has had its step: the trace covers the next `ticks`.)
    s.ih_trace = { until_tick = game.tick + ticks, r = r, seen = {}, ticks = 0, sends = 0, hands = 0, bytes = 0,
      ie_sends = 0, ie_events = 0, ie_bytes = 0, checks = 0 }
    if helpers.write_file then
      helpers.write_file(M.TRACE_FILE, "", false)  -- a fresh file
    end
    return { string.format("[Zenith] tracing inserter hands within %d tiles of the focus for %d ticks from %d into script-output/%s",
      r, ticks, game.tick, M.TRACE_FILE) }
  elseif words[1] == "off" then
    if s.ih_trace and s.ih_trace.buf and helpers.write_file then
      helpers.write_file(M.TRACE_FILE, table.concat(s.ih_trace.buf, "\n") .. "\n", true)
    end
    s.ih_trace = nil
    return { "[Zenith] inserter hand trace off" }
  elseif words[1] == "reset" then
    reset()
    return { "[Zenith] inserters: the cache and every hand's state forgotten (found again next tick)" }
  elseif words[1] and DEFAULTS[words[1]] ~= nil then
    local k, v = words[1], words[2]
    if v == nil then
      return { "[Zenith] /f3d-ih " .. k .. " is " .. tostring(O[k]) }
    elseif v == "default" then
      O[k] = DEFAULTS[k]
    elseif type(DEFAULTS[k]) == "number" then
      local n = tonumber(v)
      if not n or n < 1 then
        return { "[Zenith] /f3d-ih " .. k .. " takes a number from 1" }
      end
      O[k] = math.floor(n)
    elseif v == "on" or v == "off" or v == "auto" then
      O[k] = v
    else
      return { "[Zenith] /f3d-ih " .. k .. " takes on, off, auto or default" }
    end
    reset()
    return { "[Zenith] /f3d-ih " .. k .. " " .. tostring(O[k]) }
  end
  local tr = s.ih_trace
  return { tr and string.format("[Zenith] inserter hand trace running until tick %d (radius %d)", tr.until_tick, tr.r)
    or "[Zenith] inserter hand trace off: /f3d-ih trace [ticks] [radius] starts one", status_text() }
end

-- How far round the focus hands are live (`ih`/`ie`, moving arms): the map setting f3d-detail-radius
-- raised to the client's `ir` (focus: its camera's visible ground, --live-inserter-radius), never past
-- the focus radius; 0 turns them off. A client that sends no `ir` (before 0.3.1's view radius) keeps
-- 0.3.1's 64-tile floor (Bug #5: arms past 24 tiles moved, not resting); `ir` 0 is the setting alone.
local DEFAULT_LIVE_FLOOR = 64

function M.live_radius()
  local s = storage.f3d
  local r_detail = settings.global["f3d-detail-radius"].value
  if r_detail <= 0 then
    return 0
  end
  local ir = s.focus.ir or DEFAULT_LIVE_FLOOR
  return math.min(s.focus.r, math.max(r_detail, ir))
end

function M.tick()
  local s = storage.f3d
  local tr = s.ih_trace
  if tr then
    trace_tick(tr)
  end
  local r = M.live_radius()
  if r <= 0 then
    if next(S) then
      reset()
    end
    return
  end
  -- (A new client, or the surface changed: everything found again and synced.)
  local surface = world.surface()
  if s.client ~= client_seen or (square and square.si ~= surface.index) then
    reset()
    client_seen = s.client
  end
  local now = game.tick
  M.counts.ticks = M.counts.ticks + 1
  local ev, sm = wants()
  -- (Events just turned on: the hands' schedules are stale, so they are found again.)
  if ev and not events_were then
    reset()
  end
  events_were = ev
  look_over(surface, s.focus, r, now)
  -- The hands due this tick (and those carried over from a full tick), up to the budget; none
  -- without events (the samples need no checks).
  local list = ev and due[now] or nil
  due[now] = nil
  local checks = 0
  if list then
    local budget = O.budget
    if perf.on("near_first") and #list > budget then
      local f = s.focus
      local near_list, outer_list = {}, {}
      for _, u in ipairs(list) do
        local st = S[u]
        if st and math.max(math.abs(st.x - f.x), math.abs(st.y - f.y)) <= NEAR_INSERTER_RADIUS then
          near_list[#near_list + 1] = u
        else
          outer_list[#outer_list + 1] = u
        end
      end
      for _, u in ipairs(outer_list) do
        near_list[#near_list + 1] = u
      end
      list = near_list
    end
    for i, u in ipairs(list) do
      local st = S[u]
      if st and st.next == now then
        if checks < budget then
          checks = checks + 1
          -- (One hand's failing read mustn't stop the others: it is forgotten, found again by the
          -- next look over the square, and said once a minute.)
          local ok, err = pcall(check, st, now)
          if not ok then
            S[u] = nil
            inside[u] = nil
            M.counts.errors = (M.counts.errors or 0) + 1
            if now - (M.counts.error_said or -3600) >= 3600 then
              M.counts.error_said = now
              log("[Zenith] inserters: a hand's check failed (" .. tostring(err) .. "): forgotten")
            end
          end
        else
          -- (Carried to the next tick: the event's uncertainty says so.)
          M.counts.carried = M.counts.carried + 1
          schedule(st, now + 1)
        end
      end
    end
  end
  if tr and s.ih_trace then
    tr.checks = (tr.checks or 0) + checks
  end
  local interval = settings.global["f3d-detail-interval"].value
  local ie_due = false
  if ev then
    if perf.on("near_rate") and rate.due_near then
      ie_due = rate.due_near("ih", O.every)
    else
      ie_due = rate.due("ih", O.every)
    end
  end
  if ie_due then
    local window = O.every * O["repeat"]
    local n = #events
    local bytes = send_events(now, window)
    if tr and s.ih_trace and bytes > 0 then
      tr.ie_sends = (tr.ie_sends or 0) + 1
      tr.ie_events = (tr.ie_events or 0) + n
      tr.ie_bytes = (tr.ie_bytes or 0) + bytes
    end
  elseif not ev then
    events = {}
  end
  if sm and rate.due("ih", interval) then
    -- Like `mv`, every update is the full list, split into parts that share the tick `k`; `p`, the
    -- ticks between updates.
    local flat = collect()
    local period = rate.period("ih", interval)
    local bytes = transport.binary(3) and send_hands_bin(flat, period)
      or transport.send_groups("ih", flat, 4, HANDS_PER_MESSAGE, ',"p":' .. period)
    if tr and s.ih_trace then
      tr.sends = tr.sends + 1
      tr.hands = tr.hands + #flat / 4
      tr.bytes = tr.bytes + (bytes or 0)
    end
  end
end

return M
