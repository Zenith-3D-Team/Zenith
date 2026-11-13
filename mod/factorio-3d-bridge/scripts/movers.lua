-- Fast-changing state near the client's camera: positions of moving things every few ticks,
-- and which machines are working (for animation) twice a second.

local registry = require("scripts.registry")
local transport = require("scripts.transport")
local world = require("scripts.world")
local map = require("scripts.map")
local rate = require("scripts.rate")
local budget = require("scripts.budget")
local profile = require("scripts.profile")

local M = {}

local MOVERS_PER_MESSAGE = 200
local STATE_INTERVAL = 30
-- With f3d-spread-jobs the states' search (every animated machine within the focus radius: 20-66 ms
-- on one tick on the owner's save, twice a second) is done in this many horizontal strips of the
-- area, one a tick (s.st_strip, in storage), each strip's changes sent as they are found.
local STATE_STRIPS = 4

local function focus_area(s)
  local f = s.focus
  return { { f.x - f.r, f.y - f.r }, { f.x + f.r, f.y + f.r } }
end

-- Ids for movers Factorio gives no unit number (a rocket waiting in its silo, 2.1.23): the object's
-- registration number, the same every time it is asked for, above any unit number.
--
-- Registering is game state (the registration stays, and numbers are handed out in turn), so it is
-- done only for what the movers' search found, which every peer finds on the same tick (ids_of),
-- never for the list sent: that is module-local, and filtered by the remote view's cached view.
local NO_UNIT_BASE = 2 ^ 40

-- {entity -> id} for the movers in `list` without a unit number, registering them.
local function ids_of(list)
  local ids = {}
  for _, e in pairs(list) do
    if not e.unit_number then
      local ok, reg = pcall(script.register_on_object_destroyed, e)
      if ok and reg then
        ids[e] = NO_UNIT_BASE + reg
      end
    end
  end
  return ids
end

-- Searching the focus area (384 tiles across by default) is most of what movers cost on a big
-- base: 4.6 ms for 20 movers among 25,000 entities in 2.1.23, every other tick. So the movers found
-- are kept and only their positions read in between; the area is searched again every SCAN_TICKS,
-- or at once when the focus, its radius or the surface changes. A mover that appears meanwhile (a
-- robot leaving its roboport) shows up to SCAN_TICKS late (times the `rate` factor while slowed
-- down). While the focus moves (the character running) the area is searched again once it moved
-- SCAN_MOVE tiles, and through the work budget (budget.admit): a search waits up to SCAN_SLACK ticks
-- for a tick with room (on the owner's save a search is 5-30 ms, and it landed on the same ticks
-- as belt items' and the wire check's); it goes at once when the surface or radius changes, the
-- focus jumps, or the list is older than SCAN_TICKS + SCAN_SLACK. When to search is decided from
-- storage alone (it charges the budget); the list found is module-local and only what is sent
-- depends on it. What sending them is charged (budget.commit) comes from storage too: how many the
-- search found (mv_scan.n), not this peer's list, which after a load is its own, found later.
local SCAN_TICKS = 8
local MOVER_PRICE = 0.5  -- units per mover's position read and sent
local SCAN_MOVE = 4
local SCAN_SLACK = 8
local SCAN_JUMP = 32
local SCAN_PRICE = 0.02  -- units per entity found, beside SCAN_BASE for the area searched
local SCAN_BASE = 380  -- ~7.8 ms a search on the owner's save, most of it the area
-- The list found, per client (its state table, weak: a state loaded from a save is a new table and
-- searches again): with two clients one list for both gave each the other's movers, or searched
-- again every tick.
local scans = setmetatable({}, { __mode = "k" })

-- The search is most of what movers cost (6-12 ms every 8 ticks at -62,-26, where it finds the same
-- few movers each time: the perfbridge2 round). While two searches running find the same movers (by
-- count and the sum of their unit numbers: the same on every peer, found on the same tick) the ticks
-- between searches double, up to the f3d-mover-rescan setting (default 32; 8: every search 8 ticks
-- apart, as before); a search that finds anything else puts them back to SCAN_TICKS. A mover that
-- appears while nothing else changed (a robot leaving its roboport) shows up to that many ticks late.
local function signature(found)
  local sum = 0
  for _, e in pairs(found) do
    sum = sum + (e.unit_number or 0)
  end
  return #found .. ":" .. sum
end

local function rescan_every(m, sig, every)
  local most = settings.global["f3d-mover-rescan"] and settings.global["f3d-mover-rescan"].value or SCAN_TICKS
  if m and m.sig == sig and most > SCAN_TICKS then
    return math.min(most, every * 2)
  end
  return SCAN_TICKS
end

local function movers_in_focus(surface, s)
  local f = s.focus
  local m = s.mv_scan
  local t = game.tick
  local factor = rate.factor("mv")
  local want, force = true, true
  local scan = scans[s] or {}
  -- (every: the ticks between searches, SCAN_TICKS, doubled while searches find the same movers,
  -- up to the f3d-mover-rescan setting: rescan_every.)
  local every = m and m.every or SCAN_TICKS
  if m and m.si == surface.index and m.r == f.r then
    local moved = math.max(math.abs(f.x - m.x), math.abs(f.y - m.y))
    local age = t - m.tick
    want = age >= every * factor or moved >= SCAN_MOVE
    force = moved >= SCAN_JUMP or age >= (every + SCAN_SLACK) * factor
  end
  if want and budget.admit("mvscan", SCAN_BASE, force) then
    local tp = profile.start()
    local found = surface.find_entities_filtered({ area = focus_area(s), type = registry.mover_types() })
    profile.stop("mv.scan", tp)
    scan = { tick = t, list = found, ids = ids_of(found) }
    scans[s] = scan
    local sig = signature(found)
    s.mv_scan = { tick = t, si = surface.index, x = f.x, y = f.y, r = f.r, n = #found, sig = sig,
      every = rescan_every(m, sig, every) }
    budget.learn("mvscan", SCAN_BASE + #scan.list * SCAN_PRICE)
    return scan.list
  end
  if scan.tick ~= (s.mv_scan and s.mv_scan.tick) then
    -- This peer has no list for the search storage remembers (loaded since): its own, uncharged,
    -- registering nothing (until the next search its movers without a unit number aren't sent).
    scan = { tick = s.mv_scan and s.mv_scan.tick, list = surface.find_entities_filtered({ area = focus_area(s), type = registry.mover_types() }),
      ids = {} }
    scans[s] = scan
  end
  local list = {}
  for _, e in pairs(scan.list) do
    if e.valid then
      list[#list + 1] = e
    end
  end
  return list
end

-- The robots of `own` within a box, from this client's last search when it covered the box (its
-- area is storage's mv_scan, its list module-local: only the map's overlay depends on it), else nil.
local ROBOT = {}
for _, t in ipairs(map.ROBOT_TYPES) do
  ROBOT[t] = true
end
map.robots_in = function(surface, own, x0, y0, x1, y1)
  local s = storage.f3d
  local m = s and s.mv_scan
  local scan = s and scans[s]
  if not (m and scan and scan.tick == m.tick and m.si == surface.index) then
    return nil
  end
  if x0 < m.x - m.r or x1 > m.x + m.r or y0 < m.y - m.r or y1 > m.y + m.r then
    return nil
  end
  local out = {}
  for _, e in pairs(scan.list) do
    if e.valid and ROBOT[e.type] then
      local p = e.position
      if p.x >= x0 and p.x < x1 and p.y >= y0 and p.y < y1 and e.force.name == own then
        out[#out + 1] = e
      end
    end
  end
  return out
end

-- A new client or world: search again before the next send.
function M.reset()
  if storage.f3d then
    scans[storage.f3d] = nil
    storage.f3d.mv_scan = nil
  end
end

-- Sends the full list of movers in range, split into parts that share the same tick `k`.
-- The client drops a mover after it has been missing from a few frames in a row.
--
-- The list's text is written here (the perfbridge2 round): as transport.send_records wrote it
-- (records of unit, prototype id, x, y, orientation for the oriented; a `z` client's first four
-- numbers delta-coded within a part), but without a table a record and helpers.table_to_json, and
-- with each mover's prototype id and whether it is oriented read once per search (sc.info), not
-- per send: a send of ~150 movers cost 6.6 ms at -62,-26, most of what movers cost there.
local mv_recs = {}
local function send_movers(surface, s, every)
  local found = map.view_only(movers_in_focus(surface, s))
  local tp = profile.start()
  local sc = scans[s]
  local ids = sc and sc.ids or {}
  local info = sc and sc.info
  if not info then
    info = {}
    if sc then
      sc.info = info
    end
  end
  local z = transport.compact()
  local small = transport.small
  local fixed, floor, oriented = world.fixed, math.floor, registry.ORIENTED
  local recs = mv_recs
  local n = 0
  local pu, pe, px, py = 0, 0, 0, 0
  for _, e in pairs(found) do
    local unit = e.unit_number or ids[e]
    if unit then
      local eid = info[e]
      if not eid then
        eid = { registry.entity_id(e.name), oriented[e.type] or false }
        info[e] = eid
      end
      local p = e.position
      local x, y = fixed(p.x), fixed(p.y)
      local tail = ""
      if eid[2] then
        tail = "," .. floor(e.orientation * 1000 + 0.5)
      end
      local a, b, c, d = unit, eid[1], x, y
      -- (A part's first record is written whole, the rest as differences from the one before.)
      if z and n % MOVERS_PER_MESSAGE ~= 0 then
        a, b, c, d = a - pu, b - pe, c - px, d - py
      end
      pu, pe, px, py = unit, eid[1], x, y
      n = n + 1
      recs[n] = "[" .. (small[a] or a) .. "," .. (small[b] or b) .. "," .. (small[c] or c) .. "," .. (small[d] or d) .. tail .. "]"
    end
  end
  -- What reading them cost (budget.commit): the periodic jobs that may wait (budget.admit) see it
  -- in this tick's load. By the search's count in storage: this list (module-local, and filtered by
  -- the remote view's cached view) may differ between peers, and the commit decides which periodic
  -- jobs run this tick. (Belt items' share was committed before any module ran.)
  local m = s.mv_scan
  budget.commit((m and m.n or 0) * MOVER_PRICE, "mv")
  -- p: the ticks between updates at the client's `rate` level, so it draws movers that far behind
  -- (just after a slow-down they still come at the old rate for a moment while it eases in).
  -- (An empty list is still sent, as one empty part.)
  local parts = math.max(1, math.ceil(n / MOVERS_PER_MESSAGE))
  for part = 1, parts do
    local first = (part - 1) * MOVERS_PER_MESSAGE + 1
    local body = n > 0 and table.concat(recs, ",", first, math.min(n, part * MOVERS_PER_MESSAGE)) or ""
    transport.send_text("mv", ',"part":' .. part .. ',"parts":' .. parts .. (z and ',"z":1' or "") .. ',"p":' .. every .. ',"l":[' .. body .. "]")
  end
  for k = n + 1, #recs do
    recs[k] = nil
  end
  profile.stop("mv.send", tp)
end

-- A defines table's value -> its name, so states are compared by name (2.0 and 2.1 may number
-- them differently).
local function names(t)
  local out = {}
  for k, v in pairs(t or {}) do
    out[v] = k
  end
  return out
end

-- Entities that report more than working or not (PROTOCOL.md, `st`). Signals: 1 green, 2 yellow,
-- 3 red, 4 blue (a chain signal with some exits open). Accumulators: 1 charging, 2 discharging.
-- Power switches: 1 on.
local signal_states, chain_states  -- from defines, on first use

local function signal_colour(e)
  signal_states = signal_states or names(defines.signal_state)
  local states = signal_states
  local ok, state = pcall(function() return states[e.signal_state] end)
  if ok and state == "reserved" then
    return 2
  end
  if e.type == "rail-chain-signal" then
    chain_states = chain_states or names(defines.chain_signal_state)
    local chains = chain_states
    local ok2, chain = pcall(function() return chains[e.chain_signal_state] end)
    if ok2 and chain == "partially_open" then
      return 4
    elseif ok2 and chain == "none_open" then
      return 3
    end
  end
  if ok and (state == "closed" or state == "reserved_by_circuit_network") then
    return 3
  end
  return 1
end

-- A rocket silo: where its rocket is, so the client can open the doors and raise it as Factorio
-- does. 2 the lights blink and the doors open, 3 the rocket rises, 4 up (ready, launching, flying),
-- 5 the doors close; otherwise 1 while it builds a rocket, 0 not, as other machines.
local SILO_PHASES = {
  lights_blinking_open = 2, doors_opening = 2, doors_opened = 3, rocket_rising = 3, arms_advance = 4,
  rocket_ready = 4, launch_starting = 4, launch_started = 4, engine_starting = 4, arms_retract = 4,
  rocket_flying = 4, lights_blinking_close = 5, doors_closing = 5,
}
local silo_phase_of  -- defines.rocket_silo_status value -> phase

local function silo_phase(e)
  if not silo_phase_of then
    silo_phase_of = {}
    for name, value in pairs(defines.rocket_silo_status) do
      silo_phase_of[value] = SILO_PHASES[name]
    end
  end
  return silo_phase_of[e.rocket_silo_status] or (e.status == defines.entity_status.working and 1 or 0)
end

local STATE_OF = {
  ["rail-signal"] = signal_colour,
  ["rail-chain-signal"] = signal_colour,
  accumulator = function(e)
    local status = e.status
    if status == defines.entity_status.charging then
      return 1
    elseif status == defines.entity_status.discharging then
      return 2
    end
    return 0
  end,
  ["power-switch"] = function(e)
    return e.power_switch_state and 1 or 0
  end,
  ["rocket-silo"] = silo_phase,
}

-- A splitter counts as working (its model's rollers turn) while items pass through it: what its
-- lanes hold (each lane's count and its front and back items' places) or its first lane's front
-- item changed since the last check. A full lane flowing can move on by whole gaps between two
-- checks and look the same by places, so the front item's id is read as well. Kept per splitter in
-- `sig` (storage), so every peer decides the same.
local SPLITTER_TYPES = { splitter = true, ["lane-splitter"] = true }
-- A splitter's check reads up to 8 lanes (about 2 us each, the first with items 11 us more, as
-- belt_items measured), near 2 work units against an ordinary machine's 0.28: it counts as this
-- many entities in what the job says it read.
local SPLITTER_WEIGHT = 7

local function splitter_moving(e, sig)
  local parts = {}
  local front
  for i = 1, e.get_max_transport_line_index() do
    local line = e.get_transport_line(i)
    local n = #line
    if n > 0 then
      parts[#parts + 1] = i .. ":" .. n .. ":" .. line.get_item_position(1) .. ":" .. line.get_item_position(n)
      if not front then
        local items = line.get_detailed_contents()
        front = items[1] and items[1].unique_id
      end
    end
  end
  if #parts == 0 then
    sig[e.unit_number] = nil
    return 0
  end
  local now = table.concat(parts, ",") .. "|" .. tostring(front)
  local was = sig[e.unit_number]
  sig[e.unit_number] = now
  return (was ~= nil and was ~= now) and 1 or 0
end

-- Sends only machines whose working state changed since the last report. `strip` (1..STATE_STRIPS,
-- f3d-spread-jobs): only that horizontal strip of the area, the rest on the ticks after; nil: all.
local function send_states(surface, s, strip)
  -- Every few seconds report everything, so machines in freshly loaded chunks catch up.
  if (strip or 1) == 1 then
    if rate.crossed("st", STATE_INTERVAL * 10) then
      s.working = {}
    end
    s.st_seen, s.st_sig, s.st_read = {}, {}, 0
  end
  local area = focus_area(s)
  if strip then
    local y0, y1 = area[1][2], area[2][2]
    local h = (y1 - y0) / STATE_STRIPS
    area = { { area[1][1], y0 + (strip - 1) * h }, { area[2][1], strip == STATE_STRIPS and y1 or y0 + strip * h } }
  end
  local found = surface.find_entities_filtered({ area = area, type = registry.animated_types() })
  local read = #found
  local working = defines.entity_status.working
  local changes = {}
  local seen = s.st_seen or {}
  local sig_was = s.split_sig or {}
  local sig = s.st_sig or {}
  for _, e in pairs(found) do
    local unit = e.unit_number
    if unit then
      local state_of = STATE_OF[e.type]
      local on
      if SPLITTER_TYPES[e.type] then
        read = read + SPLITTER_WEIGHT - 1
        sig[unit] = sig_was[unit]
        local ok, v = pcall(splitter_moving, e, sig)
        on = ok and v or 0
      elseif state_of then
        local ok, v = pcall(state_of, e)
        on = ok and v or 0
      else
        on = (e.status == working) and 1 or 0
      end
      -- (A machine on a strip's edge is found by both strips: once is enough.)
      if seen[unit] == nil or seen[unit] ~= on then
        if s.working[unit] ~= on then
          changes[#changes + 1] = unit
          changes[#changes + 1] = on
        end
        seen[unit] = on
      end
    end
  end
  read = read + (s.st_read or 0)
  if strip and strip < STATE_STRIPS then
    s.st_seen, s.st_sig, s.st_read = seen, sig, read
  else
    s.working = seen
    s.split_sig = sig
    s.st_seen, s.st_sig, s.st_read = nil, nil, nil
    rate.read("st", read)
  end
  if #changes > 0 then
    transport.send_reliable({ t = "st", l = changes })
  end
end

function M.tick()
  local s = storage.f3d
  local surface = world.surface()
  local interval = settings.global["f3d-mover-interval"].value
  if rate.due("mv", interval) then
    send_movers(surface, s, rate.period("mv", interval))
  end
  if settings.global["f3d-spread-jobs"].value then
    -- (The strips on the ticks after the due one; a new due run starts over.)
    if rate.due("st", STATE_INTERVAL) then
      s.st_strip = 1
    end
    if s.st_strip then
      send_states(surface, s, s.st_strip)
      s.st_strip = s.st_strip < STATE_STRIPS and s.st_strip + 1 or nil
    end
  else
    s.st_strip = nil
    if rate.due("st", STATE_INTERVAL) then
      send_states(surface, s)
    end
  end
end

return M
