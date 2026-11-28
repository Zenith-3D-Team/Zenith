-- Fast-changing state near the client's camera: positions of moving things every few ticks,
-- and which machines are working (for animation) twice a second.

local registry = require("scripts.registry")
local transport = require("scripts.transport")
local world = require("scripts.world")
local map = require("scripts.map")
local rate = require("scripts.rate")
local budget = require("scripts.budget")
local profile = require("scripts.profile")
local perf = require("scripts.perf")
local robots = require("scripts.robots")
local tracker = require("scripts.tracker")

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
local NEAR_MOVER_RADIUS = 48
local NEAR_MOVER_COUNT_CAP = 150
local NEAR_MOVER_PERIOD_CAP = 4
local MOVER_PRICE = 0.5  -- units per mover's position read and sent
local SCAN_MOVE = 4
local SCAN_MOVE_WIDE = 16
local SCAN_MOVE_COOLDOWN = 20
local SCAN_SLACK = 8
local SCAN_JUMP = 32
local SCAN_PRICE = 0.02  -- units per entity found, beside SCAN_BASE for the area searched
local SCAN_BASE = 380  -- ~7.8 ms a search on the owner's save, most of it the area
-- Module-local counters for tests/probes (never in storage).
M.counts = { mv_scans = 0, st_refreshes = 0, splitter_checks = 0, splitter_bs_skips = 0, splitter_throttled = 0,
  gate_reads = 0, gate_scans = 0, st_scans = 0, live_reuses = 0 }
-- The list found, per client (its state table, weak: a state loaded from a save is a new table and
-- searches again): with two clients one list for both gave each the other's movers, or searched
-- again every tick.
local scans = setmetatable({}, { __mode = "k" })
-- (gc_lean) Reusable scratch arrays (the cached animated-entity lists live in storage, s.st_scan).
local animated_set
local mv_live = {}
local found_live = {}
local ST_RESCAN_NEAR = 60
local ST_RESCAN_FAR = 240
local GATE_LOOK_LEAN = 120

local function clear_trailing(t, from)
  for i = #t, from, -1 do
    t[i] = nil
  end
end

local function clear_map(t)
  for k in pairs(t) do
    t[k] = nil
  end
  return t
end

-- Module-local pcall/sort helpers so hot loops allocate zero closures.
local function get_signal_state(e) return e.signal_state end
local function get_chain_signal_state(e) return e.chain_signal_state end
local function get_always_on(e) return e.always_on end
local function get_control_behavior(e) return e.get_control_behavior() end
local function get_cb_color(cb) return cb.use_colors and cb.color or nil end
local function get_entity_color(e) return e.color end
local function color_part(v, scale) return math.max(0, math.min(255, math.floor(v * scale + 0.5))) end
local function cmp_splitter_todo(a, b)
  if a[3] ~= b[3] then
    return a[3] < b[3]
  end
  return a[1] < b[1]
end

local function is_animated_type(t)
  if not animated_set then
    animated_set = {}
    for _, ty in ipairs(registry.animated_types()) do
      animated_set[ty] = true
    end
  end
  return animated_set[t] == true
end

tracker.listeners[#tracker.listeners + 1] = function(entity)
  if not (entity and entity.valid) then
    return
  end
  local t = entity.type
  local si = entity.surface.index
  if t == "gate" then
    local s = storage.f3d
    if s and s.gate_scan then
      s.gate_dirty = true
    end
  end
  if is_animated_type(t) then
    local s = storage.f3d
    local scan = s and s.st_scan
    if scan then
      for _, meta in pairs(scan) do
        if meta.si == si then
          meta.dirty = true
        end
      end
    end
  end
end

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

-- one_search (perf.lua): the cargo pods (planets.lua `cp`), spiders (`legs`), rolling stock (trains.lua `tr`)
-- and enemy units (enemies.lua `en`) the movers' search already finds, by kind, for those jobs instead of a
-- search of the same square each (3-4 ms each on the owner's base, about 40 searches a second in all).
-- How many of each it found goes into storage on the search's tick (mv_scan.kinds), which every peer runs:
-- what the other jobs put in storage (planets_busy, the learnt costs) comes from those counts. The lists
-- themselves are module-local (scans[s].by), as the movers' list is.
local KIND_OF = { ["cargo-pod"] = "cp", ["spider-unit"] = "legs", ["spider-vehicle"] = "legs", locomotive = "tr",
  ["cargo-wagon"] = "tr", ["fluid-wagon"] = "tr", ["artillery-wagon"] = "tr", unit = "en" }

-- The movers found, by kind: {cp = {...}, ...}, and how many of each.
local function by_kind(found)
  local by, n = { cp = {}, legs = {}, tr = {}, en = {} }, { cp = 0, legs = 0, tr = 0, en = 0 }
  for _, e in pairs(found) do
    local k = KIND_OF[e.type]
    if k then
      local l = by[k]
      l[#l + 1] = e
      n[k] = n[k] + 1
    end
  end
  return by, n
end

local function mover_search_types()
  return robots.active() and registry.other_mover_types() or registry.mover_types()
end

local function movers_in_focus(surface, s)
  local f = s.focus
  local m = s.mv_scan
  local t = game.tick
  local factor = rate.factor("mv")
  local want, force = true, true
  local scan = scans[s] or {}
  local sim_on = robots.active()
  -- (every: the ticks between searches, SCAN_TICKS, doubled while searches find the same movers,
  -- up to the f3d-mover-rescan setting: rescan_every.)
  local every = m and m.every or SCAN_TICKS
  if m and m.si == surface.index and m.r == f.r and m.rb == sim_on then
    local moved = math.max(math.abs(f.x - m.x), math.abs(f.y - m.y))
    local age = t - m.tick
    local move_due
    if perf.on("mover_move_scan") then
      move_due = moved >= SCAN_MOVE_WIDE and age >= SCAN_MOVE_COOLDOWN
    else
      move_due = moved >= SCAN_MOVE
    end
    want = age >= every * factor or move_due or moved >= SCAN_JUMP
    force = moved >= SCAN_JUMP or age >= (every + SCAN_SLACK) * factor
  end
  if want and budget.admit("mvscan", SCAN_BASE, force) then
    M.counts.mv_scans = M.counts.mv_scans + 1
    local tp = profile.start()
    local found = surface.find_entities_filtered({ area = focus_area(s), type = mover_search_types() })
    profile.stop("mv.scan", tp)
    scan = { tick = t, list = found, ids = ids_of(found) }
    scans[s] = scan
    local sig = signature(found)
    s.mv_scan = { tick = t, si = surface.index, x = f.x, y = f.y, r = f.r, n = #found, sig = sig,
      every = rescan_every(m, sig, every), rb = sim_on }
    s.mv_near_tick = t
    if perf.on("one_search") then
      scan.by, s.mv_scan.kinds = by_kind(found)
    end
    budget.learn("mvscan", SCAN_BASE + #scan.list * SCAN_PRICE)
    return scan.list
  end
  if scan.tick ~= (s.mv_scan and s.mv_scan.tick) then
    -- This peer has no list for the search storage remembers (loaded since): its own, uncharged,
    -- registering nothing (until the next search its movers without a unit number aren't sent).
    scan = { tick = s.mv_scan and s.mv_scan.tick, list = surface.find_entities_filtered({ area = focus_area(s), type = mover_search_types() }),
      ids = {} }
    if perf.on("one_search") then
      scan.by = by_kind(scan.list)
    end
    scans[s] = scan
  end
  -- near_rate: when the full square scan is backed off past SCAN_TICKS (or stretched by rate),
  -- keep the near box around the focus fresh every SCAN_TICKS and register new near unitless movers deterministically.
  if not want and perf.on("near_rate") and t - (s.mv_near_tick or -999) >= SCAN_TICKS then
    s.mv_near_tick = t
    local nr = math.min(NEAR_MOVER_RADIUS, f.r)
    local near_found = surface.find_entities_filtered({
      area = { { f.x - nr, f.y - nr }, { f.x + nr, f.y + nr } },
      type = mover_search_types(),
    })
    local nids = ids_of(near_found)
    local near_unitless = {}
    for ne, nid in pairs(nids) do
      near_unitless[#near_unitless + 1] = { ne, nid }
    end
    scan.ids = scan.ids or {}
    local seen = {}
    local merged = {}
    for _, e in pairs(scan.list) do
      if e.valid then
        local uid = e.unit_number or scan.ids[e]
        if not uid then
          local nid = nids[e]
          if not nid and #near_unitless > 0 then
            for i = 1, #near_unitless do
              if e == near_unitless[i][1] then
                nid = near_unitless[i][2]
                break
              end
            end
          end
          if nid then
            scan.ids[e] = nid
            uid = nid
          else
            uid = e
          end
        end
        if not seen[uid] then
          seen[uid] = true
          merged[#merged + 1] = e
        end
      end
    end
    for _, e in pairs(near_found) do
      if e.valid then
        local nid = nids[e]
        local uid = e.unit_number or nid or scan.ids[e] or e
        if not seen[uid] then
          seen[uid] = true
          if nid then
            scan.ids[e] = nid
          end
          merged[#merged + 1] = e
        end
      end
    end
    scan.list = merged
    if perf.on("one_search") then
      scan.by = by_kind(scan.list)
    end
  end
  if perf.on("gc_lean") then
    local n = 0
    for _, e in pairs(scan.list) do
      if e.valid then
        n = n + 1
        mv_live[n] = e
      end
    end
    clear_trailing(mv_live, n + 1)
    M.counts.live_reuses = M.counts.live_reuses + 1
    return mv_live
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
  if robots.active() then
    return robots.live_in(surface, own, x0, y0, x1, y1)
  end
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

-- (one_search) The movers of kind `kind` ("cp", "legs", "tr", "en") the last search found, and how many
-- (from storage: what a job puts in storage goes by that count), when that search is of this surface and
-- the focus square as it is now: nil, nil otherwise (the job searches itself, as before). The list is nil
-- on a peer that loaded since the search (it has none): the job searches for its list then, the count
-- still storage's.
function M.found(kind, surface)
  local s = storage.f3d
  local m = s.mv_scan
  if not (m and m.kinds and perf.on("one_search") and m.si == surface.index and m.r == s.focus.r) then
    return nil, nil
  end
  local scan = scans[s]
  local list = scan and scan.tick == m.tick and scan.by and scan.by[kind] or nil
  if list then
    if perf.on("gc_lean") then
      local live = found_live[kind]
      if not live then
        live = {}
        found_live[kind] = live
      end
      local n = 0
      for _, e in pairs(list) do
        if e.valid then
          n = n + 1
          live[n] = e
        end
      end
      clear_trailing(live, n + 1)
      list = live
    else
      local live = {}
      for _, e in pairs(list) do
        if e.valid then
          live[#live + 1] = e
        end
      end
      list = live
    end
  end
  return list, m.kinds[kind] or 0
end

-- (one_search) A cargo pod or a rocket on its way (an event every peer gets): the movers' next search
-- comes at once, so a new pod is found within a tick or two, not after the search's back-off.
function M.wake()
  local s = storage.f3d
  if s and s.mv_scan and perf.on("one_search") then
    s.mv_scan = nil
    s.mv_near_tick = nil
  end
end

-- A new client or world: search again before the next send.
function M.reset()
  if storage.f3d then
    scans[storage.f3d] = nil
    storage.f3d.st_scan = nil
    storage.f3d.mv_scan = nil
    storage.f3d.mv_near_tick = nil
    storage.f3d.gate_scan = nil
    storage.f3d.gate_dirty = nil
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
-- (Binary frames, transport.lua: five numbers a record, -1 for no orientation; parts with a mover
-- past 32 bits, one without a unit number (NO_UNIT_BASE), go as 64-bit numbers.)
local MV_STRIDE = 5
local INT32_MAX = 2147483647
local mv_flat, mv_wide = {}, {}

-- One part's records as JSON text (a binary part that could not be packed).
local function flat_text(flat, first, last)
  local out = {}
  for i = first, last, MV_STRIDE do
    local o = flat[i + 4]
    out[#out + 1] = "[" .. flat[i] .. "," .. flat[i + 1] .. "," .. flat[i + 2] .. "," .. flat[i + 3] .. (o >= 0 and "," .. o or "") .. "]"
  end
  return table.concat(out, ",")
end

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
  local bin = transport.binary()
  local z = not bin and transport.compact()
  local small = transport.small
  local fixed, floor, oriented = world.fixed, math.floor, registry.ORIENTED
  local recs, flat, wide = mv_recs, mv_flat, mv_wide
  local n = 0
  local pu, pe, px, py = 0, 0, 0, 0
  for _, e in pairs(found) do
    local unit = e.unit_number or ids[e]
    if unit and (not robots.active() or (e.type ~= "logistic-robot" and e.type ~= "construction-robot")) then
      local eid = info[e]
      if not eid then
        eid = { registry.entity_id(e.name), oriented[e.type] or false }
        info[e] = eid
      end
      local p = e.position
      local x, y = fixed(p.x), fixed(p.y)
      if bin then
        local at = n * MV_STRIDE
        flat[at + 1], flat[at + 2], flat[at + 3], flat[at + 4] = unit, eid[1], x, y
        flat[at + 5] = eid[2] and floor(e.orientation * 1000 + 0.5) or -1
        n = n + 1
        if unit > INT32_MAX then
          wide[math.ceil(n / MOVERS_PER_MESSAGE)] = true
        end
      else
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
    if bin then
      local first = (part - 1) * MOVERS_PER_MESSAGE * MV_STRIDE + 1
      local last = math.min(n, part * MOVERS_PER_MESSAGE) * MV_STRIDE
      -- (Packed inside pcall: a number string.pack refuses sends that part as JSON text instead.)
      local ok, body = pcall(transport.pack_message, { game.tick, part, parts, every }, flat, first, last, wide[part] and 8 or 4)
      if ok then
        transport.send_frame(transport.KIND_MV, "mv", body)
      else
        transport.send_text("mv", ',"part":' .. part .. ',"parts":' .. parts .. ',"p":' .. every .. ',"l":[' .. flat_text(flat, first, last) .. "]")
      end
      wide[part] = nil
    else
      local first = (part - 1) * MOVERS_PER_MESSAGE + 1
      local body = n > 0 and table.concat(recs, ",", first, math.min(n, part * MOVERS_PER_MESSAGE)) or ""
      transport.send_text("mv", ',"part":' .. part .. ',"parts":' .. parts .. (z and ',"z":1' or "") .. ',"p":' .. every .. ',"l":[' .. body .. "]")
    end
  end
  local used, list = n, recs
  if bin then
    used, list = n * MV_STRIDE, flat
  end
  for k = used + 1, #list do
    list[k] = nil
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
  local ok, sig = pcall(get_signal_state, e)
  local state = ok and states[sig] or nil
  if ok and state == "reserved" then
    return 2
  end
  if e.type == "rail-chain-signal" then
    chain_states = chain_states or names(defines.chain_signal_state)
    local chains = chain_states
    local ok2, csig = pcall(get_chain_signal_state, e)
    local chain = ok2 and chains[csig] or nil
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

-- K20: whether a lamp is set to Always on (LuaEntity.always_on, the checkbox in its window), lit by day
-- as well. Lamps only (other types throw); under pcall in case a version lacks it.
local function lamp_always_on(e)
  local ok, on = pcall(get_always_on, e)
  return ok and on == true
end

-- A lamp is lit (1) while its status is working: by day a plain one is turned_off_during_daytime (0,
-- seen in 2.1.24). One set to Always on should read working by day too; should 2.1 still call it
-- turned_off_during_daytime, its setting is read and it counts as lit (no power, or a circuit
-- switching it off, still reads otherwise and stays 0).
local function lamp_state(e)
  local status = e.status
  if status == defines.entity_status.working then
    return 1
  end
  if status == defines.entity_status.turned_off_during_daytime and lamp_always_on(e) then
    return 1
  end
  return 0
end

local STATE_OF = {
  lamp = lamp_state,
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
local SPLITTER_PER_PASS = 16
local WORKING_SLICES_NEAR = 10
local WORKING_SLICES_FAR = 2

local spl_parts = {}
local spl_todo_buf = {}
local spl_pre_buf = {}
local spl_pick_buf = {}

local function splitter_moving(e, sig)
  M.counts.splitter_checks = M.counts.splitter_checks + 1
  local parts = perf.on("gc_lean") and spl_parts or {}
  local pn = 0
  local front
  for i = 1, e.get_max_transport_line_index() do
    local line = e.get_transport_line(i)
    local n = #line
    if n > 0 then
      pn = pn + 1
      parts[pn] = i .. ":" .. n .. ":" .. line.get_item_position(1) .. ":" .. line.get_item_position(n)
      if not front then
        local items = line.get_detailed_contents()
        front = items[1] and items[1].unique_id
      end
    end
  end
  if pn == 0 then
    sig[e.unit_number] = nil
    return 0
  end
  local now = table.concat(parts, ",", 1, pn) .. "|" .. tostring(front)
  local was = sig[e.unit_number]
  sig[e.unit_number] = now
  return (was ~= nil and was ~= now) and 1 or 0
end

-- Uses belt_sim's already-read lane records when available (0 Factorio API calls): returns 0 if empty
-- or confirmed quiet by belt_sim, 1 if belt_sim saw any lane change, or nil when an API check is needed.
local function bs_splitter_moving(bs, unit, sig, bs_sig)
  local brec = bs and bs.belts and bs.belts[unit]
  if not brec then
    return nil
  end
  local lanes = bs.lanes
  local parts = perf.on("gc_lean") and spl_parts or {}
  local pn = 0
  for i = 1, 8 do
    local lr = lanes[unit * 8 + i]
    if lr and lr[1] > 0 then
      pn = pn + 1
      parts[pn] = i .. ":" .. lr[1] .. ":" .. lr[2] .. ":" .. lr[3] .. ":" .. tostring(lr[10] or 0)
    end
  end
  if pn == 0 then
    sig[unit] = nil
    bs_sig[unit] = nil
    M.counts.splitter_bs_skips = M.counts.splitter_bs_skips + 1
    return 0
  end
  local now = table.concat(parts, ",", 1, pn)
  local was = bs_sig[unit]
  bs_sig[unit] = now
  if was ~= nil and was ~= now then
    sig[unit] = nil
    M.counts.splitter_bs_skips = M.counts.splitter_bs_skips + 1
    return 1
  end
  if brec[13] and game.tick < brec[13] then
    M.counts.splitter_bs_skips = M.counts.splitter_bs_skips + 1
    return 0
  end
  return nil
end

-- Selects up to SPLITTER_PER_PASS splitters from `todo` ({{unit, entity, last_tick}, ...}) deterministically
-- by oldest last-checked tick (`s.st_spl_tick[unit]`) so alternating regions/strips never starve.
local function pick_splitters(s, todo)
  local n = #todo
  local st = s.st_spl_tick or {}
  s.st_spl_tick = st
  local now = game.tick
  if n <= SPLITTER_PER_PASS then
    for i = 1, n do
      st[todo[i][1]] = now
    end
    return nil
  end
  table.sort(todo, cmp_splitter_todo)
  local pick = perf.on("gc_lean") and clear_map(spl_pick_buf) or {}
  for i = 1, SPLITTER_PER_PASS do
    local unit = todo[i][1]
    pick[unit] = true
    st[unit] = now
  end
  return pick
end

-- Collects splitter pre-checks from belt_sim and selects up to SPLITTER_PER_PASS remaining splitters.
local function prepare_splitters(s, found_lists, sig, bs_sig)
  local lean = perf.on("gc_lean")
  local spl_todo = lean and clear_map(spl_todo_buf) or {}
  local spl_pre = lean and clear_map(spl_pre_buf) or {}
  local st = s.st_spl_tick
  local bs = s.bs
  local tn = 0
  for _, found in ipairs(found_lists) do
    for _, e in pairs(found) do
      if e.valid then
        local unit = e.unit_number
        if unit and SPLITTER_TYPES[e.type] and spl_pre[unit] == nil then
          local v = bs_splitter_moving(bs, unit, sig, bs_sig)
          if v ~= nil then
            spl_pre[unit] = v
          else
            spl_pre[unit] = false
            tn = tn + 1
            spl_todo[tn] = { unit, e, st and st[unit] or -1 }
          end
        end
      end
    end
  end
  return spl_pre, pick_splitters(s, spl_todo)
end

local function eval_splitter(e, unit, sig, sig_was, spl_pre, spl_pick, fallback_on, throttle_on)
  if throttle_on then
    local pre = spl_pre[unit]
    if pre ~= false and pre ~= nil then
      return pre, 0
    elseif spl_pick and not spl_pick[unit] then
      if sig_was then
        sig[unit] = sig_was[unit]
      end
      M.counts.splitter_throttled = M.counts.splitter_throttled + 1
      return fallback_on or 0, 0
    end
  end
  if sig_was then
    sig[unit] = sig_was[unit]
  end
  local ok, v = pcall(splitter_moving, e, sig)
  return ok and v or 0, SPLITTER_WEIGHT - 1
end

-- K10: the colour a lit lamp shows, packed 0xRRGGBB, or -1 for white (Factorio's plain lamp light,
-- which the client draws warm). Factorio 2.x colours a lamp from its circuit network's colour
-- signals while "Use colors" is on (LuaLampControlBehavior.color, "the color the lamp is showing"),
-- otherwise from the colour set in its window (LuaEntity.color). Either may be missing or throw in a
-- version that differs: read under pcall, white then.
local function lamp_color(e)
  local c
  local okb, cb = pcall(get_control_behavior, e)
  if okb and cb then
    local okc, v = pcall(get_cb_color, cb)
    c = okc and v or nil
  end
  if type(c) ~= "table" then
    local okc, v = pcall(get_entity_color, e)
    c = okc and v or nil
  end
  if type(c) ~= "table" then
    return -1
  end
  local r, g, b = tonumber(c.r or c[1]) or 1, tonumber(c.g or c[2]) or 1, tonumber(c.b or c[3]) or 1
  -- (A Color is 0-1, or 0-255 when any part is over 1.)
  local scale = (r > 1 or g > 1 or b > 1) and 1 or 255
  local R, G, B = color_part(r, scale), color_part(g, scale), color_part(b, scale)
  if R == 255 and G == 255 and B == 255 then
    return -1
  end
  return R * 65536 + G * 256 + B
end
-- A lit lamp's look counts as this many entities in what the job says it read (its control
-- behaviour, colours and Always on: up to five more reads than its status).
local LAMP_WEIGHT = 4

-- A lamp's colour for `st`'s `lc` ([unit, colour, ...]) and whether it is set to Always on for `ao`
-- ([unit, 0/1, ...], K20). s.lamp_col and s.lamp_ao (storage) hold what the client was last told for
-- each lamp in the square (nil: white, not always on). The client forgets both with each state it gets
-- for a lamp, so a lamp whose state goes out now (`state_sent`) is told them again unless white and not
-- always on; one whose state stays the same, only when they changed. Only lit lamps are read (an unlit
-- one shows nothing): an unlit one is forgotten, as its `st` 0 makes the client do. `ao` lets the client
-- light the lamp by day: it lights the others only when it is dark, so a lamp whose state it no longer
-- hears (out of the focus square) doesn't stay lit into the day.
local function lamp_change(e, unit, on, state_sent, s, lc, ao)
  local lcol, lao = s.lamp_col, s.lamp_ao
  if on ~= 1 then
    lcol[unit], lao[unit] = nil, nil
    return 0
  end
  local ok, col = pcall(lamp_color, e)
  col = ok and col or -1
  if state_sent then
    if col ~= -1 then
      lc[#lc + 1] = unit
      lc[#lc + 1] = col
    end
  elseif (lcol[unit] or -1) ~= col then
    lc[#lc + 1] = unit
    lc[#lc + 1] = col
  end
  lcol[unit] = col ~= -1 and col or nil
  local always = lamp_always_on(e)
  if (state_sent and always) or (not state_sent and (lao[unit] == true) ~= always) then
    ao[#ao + 1] = unit
    ao[#ao + 1] = always and 1 or 0
  end
  lao[unit] = always or nil
  return LAMP_WEIGHT - 1
end

local function send_state_changes(changes, lc, ao, priority)
  if #changes > 0 or #lc > 0 or #ao > 0 then
    if priority ~= nil then
      transport.send_states(changes, lc, ao, priority)
    else
      transport.send_states(changes, lc, ao)
    end
  end
end

-- (gc_lean) The found lists are kept in storage with their scan (s.st_scan[key].lists), so every peer,
-- a joiner included, walks the same list in the same order: storage writes depend only on storage and
-- events. An entity made with no event shows up at the next rescan on every peer alike.
local function cached_animated_lists(surface, s, key, boxes, types, rescan_ticks)
  if not perf.on("gc_lean") then
    s.st_scan = nil
    local lists, read = {}, 0
    for b_i, area in ipairs(boxes) do
      local found = surface.find_entities_filtered({ area = area, type = types })
      lists[b_i] = found
      read = read + #found
      M.counts.st_scans = M.counts.st_scans + 1
    end
    return lists, read, nil
  end
  s.st_scan = s.st_scan or {}
  local f = s.focus
  local meta = s.st_scan[key]
  local factor = (key == 0 and perf.on("near_rate")) and 1 or rate.factor("mv")
  local limit = rescan_ticks * factor
  if meta and not meta.dirty and meta.lists and meta.si == surface.index and meta.r == f.r
      and math.abs(f.x - meta.fx) < SCAN_MOVE and math.abs(f.y - meta.fy) < SCAN_MOVE
      and (game.tick - meta.tick) < limit then
    M.counts.live_reuses = M.counts.live_reuses + 1
    return meta.lists, meta.read, meta
  end
  local lists, read = {}, 0
  for b_i, area in ipairs(boxes) do
    local found = surface.find_entities_filtered({ area = area, type = types })
    lists[b_i] = found
    read = read + #found
    M.counts.st_scans = M.counts.st_scans + 1
  end
  meta = { si = surface.index, fx = f.x, fy = f.y, r = f.r, tick = game.tick, read = read, dirty = false,
    lists = lists }
  s.st_scan[key] = meta
  return lists, read, meta
end

-- Sends only machines whose working state changed since the last report. `strip` (1..STATE_STRIPS,
-- f3d-spread-jobs): only that horizontal strip of the area, the rest on the ticks after; nil: all.
local function send_states(surface, s, strip)
  local slice_on = perf.on("st_working_slice")
  local throttle_on = perf.on("splitter_throttle")
  -- Every few seconds report everything, so machines in freshly loaded chunks catch up.
  if (strip or 1) == 1 then
    if not slice_on then
      if rate.crossed("st", STATE_INTERVAL * 10) then
        s.working = {}
      end
    else
      s.st_refresh_all = ((s.st_refresh_all or -1) + 1) % WORKING_SLICES_NEAR
    end
    s.st_seen, s.st_sig, s.st_read = {}, {}, 0
  end
  local phase = slice_on and (s.st_refresh_all or 0) or nil
  local area = focus_area(s)
  if strip then
    local y0, y1 = area[1][2], area[2][2]
    local h = (y1 - y0) / STATE_STRIPS
    area = { { area[1][1], y0 + (strip - 1) * h }, { area[2][1], strip == STATE_STRIPS and y1 or y0 + strip * h } }
  end
  local found_lists, read, rc = cached_animated_lists(surface, s, 100 + (strip or 0), { area },
    registry.animated_types(), ST_RESCAN_NEAR)
  local found = found_lists[1]
  local working = defines.entity_status.working
  local changes, lc, ao = {}, {}, {}
  local seen = s.st_seen or {}
  local sig_was = s.split_sig or {}
  local sig = s.st_sig or {}
  s.bs_split_sig = s.bs_split_sig or {}
  local bs_sig = s.bs_split_sig
  s.lamp_col, s.lamp_ao = s.lamp_col or {}, s.lamp_ao or {}
  local lcol, lao = s.lamp_col, s.lamp_ao
  local spl_pre, spl_pick
  if throttle_on then
    spl_pre, spl_pick = prepare_splitters(s, found_lists, sig, bs_sig)
  end
  for _, e in pairs(found) do
    -- (N3) An invalid one in the cached list is skipped, not a reason to rescan: storage's dirty
    -- flag is the tracker's alone.
    local unit = e.valid and e.unit_number
    if unit then
      local state_of = STATE_OF[e.type]
      local on
      if SPLITTER_TYPES[e.type] then
        local w
        on, w = eval_splitter(e, unit, sig, sig_was, spl_pre, spl_pick, s.working[unit], throttle_on)
        read = read + w
      elseif state_of then
        local ok, v = pcall(state_of, e)
        on = ok and v or 0
      else
        on = (e.status == working) and 1 or 0
      end
      -- (A machine on a strip's edge is found by both strips: once is enough.)
      if seen[unit] == nil or seen[unit] ~= on then
        local force_refresh = slice_on and (unit % WORKING_SLICES_NEAR == phase)
        local sent = s.working[unit] ~= on or force_refresh
        if sent then
          if force_refresh and s.working[unit] == on then
            M.counts.st_refreshes = M.counts.st_refreshes + 1
          end
          changes[#changes + 1] = unit
          changes[#changes + 1] = on
        end
        if e.type == "lamp" then
          read = read + lamp_change(e, unit, on, sent, s, lc, ao)
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
    -- (A lamp the round no longer found: its state goes again when it comes back, its colour and
    -- Always on with it.)
    for _, t in pairs({ lcol, lao, bs_sig, s.st_spl_tick or {} }) do
      for unit in pairs(t) do
        if seen[unit] == nil then
          t[unit] = nil
        end
      end
    end
    rate.read("st", read)
  end
  send_state_changes(changes, lc, ao)
end

-- states_near (perf.lua): the machines within STATE_NEAR tiles of the focus every round (30 ticks) as
-- before; the rest of the focus square a quarter a round (FAR_STRIPS strips of rows, the near square cut
-- out), so each far machine every 120 ticks and starts or stops its animation up to 2 s late. The whole
-- square was 4 searches of 3.4 ms each twice a second on the owner's base. s.working (unit -> state
-- sent) is kept across rounds, each area's look merged into it: s.st_at (unit -> area: 0 near, 1-4 a
-- strip) and s.st_in (area -> {unit = true}) forget a machine its area no longer finds, so a strip not
-- read isn't sent again. All in storage, from on_tick.
local STATE_NEAR = 64
local FAR_STRIPS = 4

-- The areas of `region` (0: the near square; 1..FAR_STRIPS: that strip of the focus square less the
-- near square), as boxes.
local function region_areas(s, region)
  local f = s.focus
  local n = math.min(STATE_NEAR, f.r)
  if region == 0 then
    return { { { f.x - n, f.y - n }, { f.x + n, f.y + n } } }
  end
  local x0, x1 = f.x - f.r, f.x + f.r
  local h = 2 * f.r / FAR_STRIPS
  local ya = f.y - f.r + (region - 1) * h
  local yb = region == FAR_STRIPS and f.y + f.r or ya + h
  if n >= f.r then
    return {}
  end
  local ny0, ny1 = f.y - n, f.y + n
  if yb <= ny0 or ya >= ny1 then
    return { { { x0, ya }, { x1, yb } } }
  end
  -- (Round the near square: above and below it within the strip, and either side of it.)
  local out = {}
  if ya < ny0 then
    out[#out + 1] = { { x0, ya }, { x1, ny0 } }
  end
  if yb > ny1 then
    out[#out + 1] = { { x0, ny1 }, { x1, yb } }
  end
  local ma, mb = math.max(ya, ny0), math.min(yb, ny1)
  out[#out + 1] = { { x0, ma }, { f.x - n, mb } }
  out[#out + 1] = { { f.x + n, ma }, { x1, mb } }
  return out
end

-- One area's look: states that changed since sent, merged into s.working. Returns the entities read.
local function state_region(surface, s, region)
  local working = defines.entity_status.working
  local types = registry.animated_types()
  local sent = s.working
  local sig = s.split_sig or {}
  s.split_sig = sig
  s.bs_split_sig = s.bs_split_sig or {}
  local bs_sig = s.bs_split_sig
  s.st_at, s.st_in = s.st_at or {}, s.st_in or {}
  s.lamp_col, s.lamp_ao = s.lamp_col or {}, s.lamp_ao or {}
  local at, lcol, lao = s.st_at, s.lamp_col, s.lamp_ao
  local slice_on = perf.on("st_working_slice")
  local throttle_on = perf.on("splitter_throttle")
  local rphase, rmod
  if slice_on then
    s.st_refresh = s.st_refresh or {}
    rmod = region == 0 and WORKING_SLICES_NEAR or WORKING_SLICES_FAR
    rphase = ((s.st_refresh[region] or -1) + 1) % rmod
    s.st_refresh[region] = rphase
  end
  local mine = {}
  local changes, lc, ao = {}, {}, {}
  local boxes = region_areas(s, region)
  local rescan_t = region == 0 and ST_RESCAN_NEAR or ST_RESCAN_FAR
  local found_lists, read, rc = cached_animated_lists(surface, s, region, boxes, types, rescan_t)
  local spl_pre, spl_pick
  if throttle_on then
    spl_pre, spl_pick = prepare_splitters(s, found_lists, sig, bs_sig)
  end
  for _, found in ipairs(found_lists) do
    for _, e in pairs(found) do
      -- (N3) Skipped only: rc.dirty comes from the tracker (storage), not from the list.
      local valid = e.valid
      local unit = valid and e.unit_number
      -- (One on the edge of two boxes is found by both: once is enough.)
      if unit and not mine[unit] then
        mine[unit] = true
        at[unit] = region
        local state_of = STATE_OF[e.type]
        local on
        if SPLITTER_TYPES[e.type] then
          local w
          on, w = eval_splitter(e, unit, sig, nil, spl_pre, spl_pick, sent[unit], throttle_on)
          read = read + w
        elseif state_of then
          local ok, v = pcall(state_of, e)
          on = ok and v or 0
        else
          on = (e.status == working) and 1 or 0
        end
        local was = sent[unit]
        local force_refresh = slice_on and (unit % rmod == rphase)
        if was ~= on or force_refresh then
          if force_refresh and was == on then
            M.counts.st_refreshes = M.counts.st_refreshes + 1
          end
          changes[#changes + 1] = unit
          changes[#changes + 1] = on
          sent[unit] = on
        end
        if e.type == "lamp" then
          read = read + lamp_change(e, unit, on, was ~= on or force_refresh, s, lc, ao)
        end
      end
    end
  end
  local spl_tick = s.st_spl_tick
  -- Gone from this area and not found in another since: forgotten, as a round's replace did.
  for unit in pairs(s.st_in[region] or {}) do
    if not mine[unit] and at[unit] == region then
      at[unit], sent[unit], sig[unit], bs_sig[unit], lcol[unit], lao[unit] = nil, nil, nil, nil, nil, nil
      if spl_tick then
        spl_tick[unit] = nil
      end
    end
  end
  s.st_in[region] = mine
  send_state_changes(changes, lc, ao, region == 0)
  return read
end

-- A round of states_near: the near square on its due tick, the far strip of the round on the next.
-- When near_rate is on, region 0 keeps its base cadence (rate.due_near) while FAR_STRIPS slow
-- independently under rate.due("st", STATE_INTERVAL).
local function states_by_distance(surface, s)
  local slice_on = perf.on("st_working_slice")
  if not perf.on("near_rate") then
    if rate.due("st", STATE_INTERVAL) then
      -- Every few seconds report everything, so machines in freshly loaded chunks catch up.
      if not slice_on and rate.crossed("st", STATE_INTERVAL * 10) then
        s.working = {}
      end
      s.st_read = state_region(surface, s, 0)
      s.st_far = (s.st_far or 0) % FAR_STRIPS + 1
      s.st_next = game.tick + 1
      if not settings.global["f3d-spread-jobs"].value then
        s.st_next = nil
        rate.read("st", s.st_read + state_region(surface, s, s.st_far))
      end
    elseif s.st_next and game.tick >= s.st_next then
      s.st_next = nil
      rate.read("st", (s.st_read or 0) + state_region(surface, s, s.st_far or 1))
    end
    return
  end
  local near_due, far_due
  if rate.due_near then
    near_due = rate.due_near("st", STATE_INTERVAL)
    far_due = rate.due("st", STATE_INTERVAL)
  else
    near_due = rate.due("st", STATE_INTERVAL)
    far_due = near_due
  end
  local spread = settings.global["f3d-spread-jobs"].value
  local nr = 0
  if near_due then
    if not slice_on and rate.crossed(rate.due_near and "st_near" or "st", STATE_INTERVAL * 10) then
      s.working = {}
    end
    nr = state_region(surface, s, 0)
    if not far_due and not (s.st_next and game.tick >= s.st_next) then
      rate.read("st", nr)
    end
  end
  if far_due then
    s.st_far = (s.st_far or 0) % FAR_STRIPS + 1
    if near_due and spread then
      s.st_read = nr
      s.st_next = game.tick + 1
    else
      s.st_next = nil
      rate.read("st", nr + state_region(surface, s, s.st_far))
    end
  elseif s.st_next and game.tick >= s.st_next then
    s.st_next = nil
    rate.read("st", (s.st_read or 0) + nr + state_region(surface, s, s.st_far or 1))
  end
end

-- gate_state (perf.lua): each gate's real state (Factorio opens a gate for whatever comes near, a script's
-- request_to_open too), so the client's doors follow it instead of guessing from the movers it is sent. The
-- gates within GATE_NEAR tiles of the focus are searched for every GATE_LOOK ticks (one search, by type: nothing
-- found, nothing else done) and read every GATE_TICKS ticks; only changes go, as `st` states (0 closed, 1 opening,
-- 2 opened, 3 closing), on the priority lane; every GATE_REFRESH ticks each again, so a client that dropped a chunk
-- gets them back. A gate opens in 15 ticks (opening_speed 0.0667), so a state is at most 3 ticks late.
-- s.gates (the LuaEntity list) and s.gate_sent (unit -> state sent) are storage, from on_tick only.
local GATE_TICKS = 3
local GATE_LOOK = 30
local GATE_REFRESH = 300
local GATE_NEAR = 64

local function gate_state(e)
  if e.is_opening() then
    return 1
  elseif e.is_closing() then
    return 3
  elseif e.is_opened() then
    return 2
  end
  return 0
end

local function send_gates(surface, s)
  if not perf.on("gate_state") then
    s.gates, s.gate_sent, s.gate_scan, s.gate_dirty = nil, nil, nil, nil
    return
  end
  local t = game.tick
  local looked = false
  if perf.on("gc_lean") then
    local f = s.focus
    local n = math.min(GATE_NEAR, f.r)
    local factor = rate.factor("mv")
    local gs = s.gate_scan
    local look_every = (s.gates and #s.gates > 0) and GATE_LOOK_LEAN or GATE_LOOK
    local need_scan = not s.gates or not gs or s.gate_dirty
      or gs.si ~= surface.index or gs.n ~= n
      or math.max(math.abs(f.x - gs.x), math.abs(f.y - gs.y)) >= SCAN_MOVE_WIDE
      or (t - gs.tick) >= look_every * factor
    if need_scan then
      s.gates = surface.find_entities_filtered({ area = { { f.x - n, f.y - n }, { f.x + n, f.y + n } }, type = "gate" })
      M.counts.gate_scans = M.counts.gate_scans + 1
      s.gate_dirty = nil
      local ref = gs and gs.refresh or t
      if not s.gate_sent or t - ref >= GATE_REFRESH then
        s.gate_sent = {}
        ref = t
      end
      s.gate_scan = { si = surface.index, x = f.x, y = f.y, n = n, tick = t, refresh = ref }
      looked = true
    elseif not s.gate_sent or t - (gs.refresh or -GATE_REFRESH) >= GATE_REFRESH then
      s.gate_sent = {}
      gs.refresh = t
    end
  else
    s.gate_scan, s.gate_dirty = nil, nil
    if not s.gates or t % GATE_LOOK == 0 then
      local f = s.focus
      local n = math.min(GATE_NEAR, f.r)
      s.gates = surface.find_entities_filtered({ area = { { f.x - n, f.y - n }, { f.x + n, f.y + n } }, type = "gate" })
      M.counts.gate_scans = M.counts.gate_scans + 1
      looked = true
      if not s.gate_sent or t % GATE_REFRESH == 0 then
        s.gate_sent = {}
      end
    end
  end
  local gates = s.gates
  if #gates == 0 then
    if looked then
      s.gate_sent = {}
    end
    return
  end
  if not looked and t % GATE_TICKS ~= 0 then
    return
  end
  local sent = s.gate_sent
  local now = looked and {} or nil
  local changes = {}
  local lean = perf.on("gc_lean")
  for _, e in pairs(gates) do
    local valid = e.valid
    if not valid and lean then
      s.gate_dirty = true
    end
    local unit = valid and e.unit_number
    if unit then
      local ok, v = pcall(gate_state, e)
      if ok then
        if now then
          now[unit] = true
        end
        if sent[unit] ~= v then
          sent[unit] = v
          changes[#changes + 1] = unit
          changes[#changes + 1] = v
        end
      end
    end
  end
  if now then
    -- (A gate the search no longer finds: forgotten, sent again when it comes back.)
    for unit in pairs(sent) do
      if not now[unit] then
        sent[unit] = nil
      end
    end
  end
  M.counts.gate_reads = M.counts.gate_reads + #gates
  if #changes > 0 then
    transport.send_states(changes, nil, nil, true)
  end
end

function M.tick()
  local s = storage.f3d
  local surface = world.surface()
  local interval = settings.global["f3d-mover-interval"].value
  local mv_cap = (perf.on("near_rate") and (s.mv_scan and s.mv_scan.n or 0) <= NEAR_MOVER_COUNT_CAP)
    and NEAR_MOVER_PERIOD_CAP or nil
  if rate.due("mv", interval, nil, mv_cap) then
    send_movers(surface, s, rate.period("mv", interval, nil, mv_cap))
  end
  if s.focus then
    send_gates(surface, s)
  end
  if perf.on("states_near") then
    s.st_strip = nil
    states_by_distance(surface, s)
    return
  end
  s.st_at, s.st_in, s.st_far, s.st_next = nil, nil, nil, nil
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
