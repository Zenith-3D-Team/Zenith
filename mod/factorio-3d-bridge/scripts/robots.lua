-- Worker robots (`logistic-robot`, `construction-robot`) simulated in flight (`rb`):
-- instead of polling every robot's position every 2 ticks (`mv`, which reads all robots even while
-- Factorio 2.0/2.1 sleeps them for 20 ticks), the bridge tracks each robot near the focus and sends
-- its current leg/order state (`robot_order_queue`, `orientation`, `robot_cargo`, roboport charging)
-- only when it changes, on wakeup, or on an infrequent refresh. The client flies each leg smoothly
-- on the GPU (`mover_records.gdshaderinc`).
--
-- Peer determinism (Factorio multiplayer): nothing here is in `storage` except the deterministic
-- `/f3d-perf robot_sim` setting and `s.focus` / `s.client.rb` set from packets. All tracking tables
-- stay module-local per client (weak-keyed by client state `s`).

local registry = require("scripts.registry")
local transport = require("scripts.transport")
local world = require("scripts.world")
local map = require("scripts.map")
local rate = require("scripts.rate")
local budget = require("scripts.budget")
local perf = require("scripts.perf")
local profile = require("scripts.profile")
local puppet = require("scripts.puppet")

local M = {}

local WORKER_TYPES = { "logistic-robot", "construction-robot" }
local WORKER_SET = { ["logistic-robot"] = true, ["construction-robot"] = true }
local FOLLOW_TYPES = { character = true, ["spider-vehicle"] = true, car = true }
local MOBILE_TYPES = { "character", "spider-vehicle" }
local CARGO_INTERVAL = 10

local ROBOTS_PER_PART = 120
local GONE_PER_PART = 200
local RB_STRIDE = 11
local INT32_MAX = 2147483647
local INT32_MIN = -2147483648

local SCAN_STRIPS = 8
local SCAN_STEP_TICKS = 2     -- 1 strip every 2 ticks => full 384x384 focus every 16 ticks (robot_opt off)
local SCAN_STEP_OPT = 4       -- 1 strip every 4 ticks at rate 0, scaled by rate at 1-3
local SCAN_MARGIN = 8
local NEAR_ROBOT_RADIUS = 48
local NEAR_SCAN_TICKS = 4
local NEAR_SCAN_OPT = 8
local SCAN_JUMP = 32
local SCAN_MOVE = 4
local CHARGE_POLL_TICKS = 4
local CHARGE_POLL_OPT = 12
local ROBOPORT_SCAN_TICKS = 120
local ROBOPORT_SCAN_MOVE = 16
local MOD_CACHE_TICKS = 60
local MAX_CHECKS = 250
local MIN_CHECKS = 16
local FREE_BUCKET_CAP = 64
local DRIFT_CHECK = 60
local REFRESH_TICKS = 120
local HEARTBEAT_TICKS = 20
local REPEAT_GONE = 3
local LIMBO_MAX_SLEEP = 23

local ROBOT_CARGO_INV = defines.inventory and defines.inventory.robot_cargo
local EMPTY_ORDERS = {}

-- Module-local counters for tests/probes (never in storage).
M.counts = { rp_scans = 0, strip_scans = 0, near_scans = 0, ch_polls = 0, mod_reads = 0, robot_checks = 0 }

-- State bits (lowest 3 bits of flags) and bit flags matching wire protocol / mover_records.gd.
local STATE_FLY_TARGET = 0
local STATE_FLY_DIR = 1
local STATE_HOVER = 2
local STATE_ORBIT = 3
local STATE_FOLLOW = 4

local FLAG_CARGO = 8
local FLAG_LOW_E = 16
local FLAG_HAS_NEXT = 32
local FLAG_NEXT_CARGO = 64
local FLAG_WORKING = 128
local FLAG_CHARGING = 256
local FLAG_SNAP = 512
local FLAG_RETURNING = 1024

local function strip_snap(f)
  return bit32.band(f, bit32.bnot(FLAG_SNAP))
end

-- defines.robot_order_type work types (construction arms active while hovering at target).
local OT = defines.robot_order_type or {}
local OT_PICKUP = OT.pickup or 0
local OT_PICKUP_ITEMS = OT.pickup_items or 8
local CONSTRUCT_WORK_OT = {
  [OT.repair or 1] = true,
  [OT.construct or 2] = true,
  [OT.deconstruct or 3] = true,
  [OT.upgrade or 5] = true,
  [OT.explode_cliff or 6] = true,
  [OT.deliver_items or 4] = true,
}

-- Per-client tracking state (module-local; weak keys drop old saves/clients cleanly).
local clients = setmetatable({}, { __mode = "k" })

-- Prototype physics cache (prototypes never change mid-game).
local proto_cache = {}
local active_worker_types
local active_mobile_types

-- Module-local property/method getters so pcall never allocates closures in loops.
local function get_proto_speed(p) return p.speed end
local function get_proto_low_mult(p) return p.speed_multiplier_when_out_of_energy end
local function get_proto_epm(p) return p.energy_per_move end
local function get_proto_ept(p) return p.energy_per_tick end
local function get_proto_min_chg(p) return p.min_to_charge end
local function get_proto_max_e(p) return p.max_energy end
local function get_proto_max_energy_q(p, qname) return p.get_max_energy(qname) end
local function get_speed_mod(f) return f.worker_robots_speed_modifier end
local function get_batt_mod(f) return f.worker_robots_battery_modifier end
local function get_logistic_cell(rp) return rp.logistic_cell end
local function get_logistic_network(e) return e.logistic_network end
local function get_cell_mobile(c) return c.mobile end
local function get_cell_owner(c) return c.owner end
local function get_net_con_robots(n) return n.construction_robots end
local function get_net_cells(n) return n.cells end
local function get_charging_robots(cell) return cell.charging_robots end
local function get_to_charge_robots(cell) return cell.to_charge_robots end
local function get_cargo_inv(e) return e.get_inventory(ROBOT_CARGO_INV) end
local function inv_is_empty(inv) return inv.is_empty() end
local function inv_slot1_valid(inv)
  local stack = inv[1]
  return stack ~= nil and stack.valid_for_read == true
end
local function get_stack_quality(stack)
  local q = stack.quality
  return q and q.name or nil
end
local function inv_slot1_detail(inv)
  local stack = inv[1]
  if stack ~= nil and stack.valid_for_read == true then
    local okq, qn = pcall(get_stack_quality, stack)
    return stack.name, stack.count, (okq and type(qn) == "string") and qn or "normal"
  end
  return nil, 0, nil
end
local function get_robot_orders(e) return e.robot_order_queue end
local function get_energy(e) return e.energy end
local function get_quality_name(e) return e.quality and e.quality.name end

local function mobile_types()
  if not active_mobile_types then
    active_mobile_types = {}
    for _, t in ipairs(MOBILE_TYPES) do
      if registry.has_type(t) then
        active_mobile_types[#active_mobile_types + 1] = t
      end
    end
  end
  return active_mobile_types
end

local function clear_map(t)
  for k in pairs(t) do
    t[k] = nil
  end
  return t
end

local function clear_array(t)
  for i = #t, 1, -1 do
    t[i] = nil
  end
  return t
end

local function queue_unit(st, checked_set, due_units, u)
  if st.tracked[u] and not checked_set[u] then
    checked_set[u] = true
    due_units[#due_units + 1] = u
  end
end

local function worker_types()
  if not active_worker_types then
    active_worker_types = {}
    for _, t in ipairs(WORKER_TYPES) do
      if registry.has_type(t) then
        active_worker_types[#active_worker_types + 1] = t
      end
    end
  end
  return active_worker_types
end

local function proto_stats(name, etype)
  local c = proto_cache[name]
  if c then
    return c
  end
  local proto = prototypes and prototypes.entity and prototypes.entity[name]
  local spd = etype == "construction-robot" and 0.06 or 0.05
  local low = 0.2
  local epm = 5000
  local ept = 50
  local min_chg = 0.2
  local base_max_e = etype == "construction-robot" and 3000000 or 1500000
  if proto then
    local ok, v = pcall(get_proto_speed, proto)
    if ok and type(v) == "number" and v > 0 then spd = v end
    ok, v = pcall(get_proto_low_mult, proto)
    if ok and type(v) == "number" and v >= 0 then low = v end
    ok, v = pcall(get_proto_epm, proto)
    if ok and type(v) == "number" and v >= 0 then epm = v end
    ok, v = pcall(get_proto_ept, proto)
    if ok and type(v) == "number" and v >= 0 then ept = v end
    ok, v = pcall(get_proto_min_chg, proto)
    if ok and type(v) == "number" and v >= 0 then min_chg = v end
    ok, v = pcall(get_proto_max_e, proto)
    if ok and type(v) == "number" and v > 0 then base_max_e = v end
  end
  c = {
    spd = spd,
    low = low,
    epm = epm,
    ept = ept,
    min_chg = min_chg,
    base_max_e = base_max_e,
    by_q = {},
  }
  proto_cache[name] = c
  return c
end

local function max_energy_for(stats, proto_name, qname)
  local m = stats.by_q[qname]
  if m then
    return m
  end
  m = stats.base_max_e
  local proto = prototypes and prototypes.entity and prototypes.entity[proto_name]
  if proto then
    local ok, v = pcall(get_proto_max_energy_q, proto, qname)
    if ok and type(v) == "number" and v > 0 then
      m = v
    end
  end
  stats.by_q[qname] = m
  return m
end

local function state_of(s)
  local st = clients[s]
  if not st then
    st = {
      tracked = {},
      order = {},
      order_pos = {},
      buckets = {},
      free_buckets = {},
      roboports = {},
      rp_cells = {},
      mobile_owners = {},
      mo_cells = {},
      personal_owners = {},
      personal_prev = {},
      ch_map = {},
      tc_map = {},
      ch_prev = {},
      tc_prev = {},
      wake_buf = {},
      due_units = {},
      checked_set = {},
      near_u = {},
      outer_u = {},
      out_u = {},
      out_g = {},
      gone = {},
      alt_rc_sent = false,
      strip = 1,
      sweep = 0,
      last_scan_tick = -999,
      last_near_scan_tick = -999,
      last_ch_tick = -999,
      last_rp_scan_tick = nil,
      last_rp_fx = nil,
      last_rp_fy = nil,
      last_rp_fr = nil,
      last_mod_tick = nil,
      cached_sm = nil,
      cached_bm = nil,
      last_fx = nil,
      last_fy = nil,
      last_fr = nil,
      last_si = nil,
      refresh_idx = 1,
      last_send_tick = -999,
      last_sm = nil,
      need_snap = true,
    }
    clients[s] = st
  end
  return st
end

function M.active()
  local s = storage.f3d
  return s ~= nil and s.client ~= nil and s.client.rb == true and perf.on("robot_sim")
end

function M.reset()
  local s = storage.f3d
  if s then
    clients[s] = nil
  end
end

local function force_mods_raw()
  M.counts.mod_reads = M.counts.mod_reads + 1
  local c = puppet.get()
  local f = (c and c.valid and c.force) or (game and game.forces and game.forces.player)
  if not f then
    return 0, 0
  end
  local ok1, sm = pcall(get_speed_mod, f)
  local ok2, bm = pcall(get_batt_mod, f)
  return (ok1 and type(sm) == "number") and sm or 0, (ok2 and type(bm) == "number") and bm or 0
end

local function force_mods(st, tick, opt)
  if not opt then
    return force_mods_raw()
  end
  if not st.last_mod_tick or tick - st.last_mod_tick >= MOD_CACHE_TICKS then
    local sm, bm = force_mods_raw()
    st.cached_sm = sm
    st.cached_bm = bm
    st.last_mod_tick = tick
  end
  return st.cached_sm or 0, st.cached_bm or 0
end

local function schedule(st, r, due, opt)
  if r.due and r.due ~= due then
    local old = st.buckets[r.due]
    if old then
      old[r.unit] = nil
    end
  end
  r.due = due
  local b = st.buckets[due]
  if not b then
    if opt and #st.free_buckets > 0 then
      b = st.free_buckets[#st.free_buckets]
      st.free_buckets[#st.free_buckets] = nil
    else
      b = {}
    end
    st.buckets[due] = b
  end
  b[r.unit] = true
end

local function untrack(st, unit, emit_gone)
  local r = st.tracked[unit]
  if not r then
    return
  end
  if r.due and st.buckets[r.due] then
    st.buckets[r.due][unit] = nil
  end
  local idx = st.order_pos[unit]
  if idx then
    local last_idx = #st.order
    local last_u = st.order[last_idx]
    if idx ~= last_idx then
      st.order[idx] = last_u
      st.order_pos[last_u] = idx
    end
    st.order[last_idx] = nil
    st.order_pos[unit] = nil
    if st.refresh_idx > last_idx - 1 then
      st.refresh_idx = 1
    end
  end
  st.tracked[unit] = nil
  if emit_gone then
    st.gone[unit] = REPEAT_GONE
  end
end

local function near_roboport(st, x, y, max_d)
  local d2_max = max_d * max_d
  for _, rp in ipairs(st.roboports) do
    if rp.valid then
      local p = rp.position
      local dx, dy = p.x - x, p.y - y
      if dx * dx + dy * dy <= d2_max then
        return rp
      end
    end
  end
  return nil
end

local function find_ray_roboport(st, x, y, ori, max_d, max_ang)
  local best, best_d
  local d2_max = max_d * max_d
  for _, rp in ipairs(st.roboports) do
    if rp.valid then
      local p = rp.position
      local dx, dy = p.x - x, p.y - y
      local d2 = dx * dx + dy * dy
      if d2 > 0.25 and d2 <= d2_max then
        local eo = (math.atan2(dx, -dy) / (2 * math.pi)) % 1.0
        local err = math.abs((ori - eo + 0.5) % 1.0 - 0.5)
        if err <= max_ang and (not best_d or d2 < best_d) then
          best, best_d = rp, d2
        end
      end
    end
  end
  return best
end

local function poll_cell_queues(cell, owner, ch_map, tc_map)
  local okc, ch = pcall(get_charging_robots, cell)
  if okc and ch then
    for _, rb in pairs(ch) do
      if rb.valid and rb.unit_number then
        ch_map[rb.unit_number] = owner
      end
    end
  end
  local okt, tc = pcall(get_to_charge_robots, cell)
  if okt and tc then
    for _, rb in pairs(tc) do
      if rb.valid and rb.unit_number then
        tc_map[rb.unit_number] = owner
      end
    end
  end
end

local function refresh_charging(st, opt)
  if opt and #st.roboports == 0 and #st.mobile_owners == 0
      and next(st.ch_map) == nil and next(st.tc_map) == nil and next(st.personal_owners) == nil then
    return nil
  end
  M.counts.ch_polls = M.counts.ch_polls + 1
  local ch_map = opt and clear_map(st.ch_prev) or {}
  local tc_map = opt and clear_map(st.tc_prev) or {}
  local personal_owners = opt and clear_map(st.personal_prev) or {}
  local wake = opt and clear_map(st.wake_buf) or {}
  for i = 1, #st.roboports do
    local rp = st.roboports[i]
    if rp and rp.valid then
      local cell
      if opt then
        cell = st.rp_cells[i]
        if cell == nil or (cell and not cell.valid) then
          local ok, c = pcall(get_logistic_cell, rp)
          cell = (ok and c and c.valid) and c or false
          st.rp_cells[i] = cell
        end
      else
        local ok, c = pcall(get_logistic_cell, rp)
        cell = (ok and c and c.valid) and c or nil
      end
      if cell then
        poll_cell_queues(cell, rp, ch_map, tc_map)
      end
    end
  end
  for i = 1, #st.mobile_owners do
    local mo = st.mobile_owners[i]
    if mo and mo.valid then
      local ok, c = pcall(get_logistic_cell, mo)
      if ok and c and c.valid then
        poll_cell_queues(c, mo, ch_map, tc_map)
      end
      local okn, net = pcall(get_logistic_network, mo)
      if okn and net and net.valid then
        local okr, con = pcall(get_net_con_robots, net)
        if okr and con then
          for _, rb in pairs(con) do
            if rb.valid and rb.unit_number then
              personal_owners[rb.unit_number] = mo
            end
          end
        end
      end
    end
  end
  for u in pairs(ch_map) do
    if st.ch_map[u] ~= ch_map[u] then wake[u] = true end
  end
  for u in pairs(st.ch_map) do
    if not ch_map[u] then wake[u] = true end
  end
  for u in pairs(tc_map) do
    if st.tc_map[u] ~= tc_map[u] then wake[u] = true end
  end
  for u in pairs(st.tc_map) do
    if not tc_map[u] then wake[u] = true end
  end
  for u in pairs(personal_owners) do
    if st.personal_owners[u] ~= personal_owners[u] then wake[u] = true end
  end
  for u in pairs(st.personal_owners) do
    if not personal_owners[u] then wake[u] = true end
  end
  if opt then
    st.ch_prev = st.ch_map
    st.tc_prev = st.tc_map
    st.personal_prev = st.personal_owners
  end
  st.ch_map = ch_map
  st.tc_map = tc_map
  st.personal_owners = personal_owners
  return wake
end

local function scan_roboports(surface, s, st, tick)
  M.counts.rp_scans = M.counts.rp_scans + 1
  local f = s.focus
  local r = f.r + SCAN_MARGIN
  st.roboports = registry.has_type("roboport") and surface.find_entities_filtered({
    area = { { f.x - r, f.y - r }, { f.x + r, f.y + r } },
    type = "roboport",
  }) or {}
  clear_map(st.rp_cells)
  local mtypes = mobile_types()
  st.mobile_owners = #mtypes > 0 and surface.find_entities_filtered({
    area = { { f.x - r, f.y - r }, { f.x + r, f.y + r } },
    type = mtypes,
  }) or {}
  clear_map(st.mo_cells)
  st.last_rp_scan_tick = tick
  st.last_rp_fx, st.last_rp_fy, st.last_rp_fr = f.x, f.y, f.r
end

local function ingest_found(st, found, tick, view, opt)
  for _, e in pairs(found) do
    if e.valid then
      local unit = e.unit_number
      if unit then
        local existing = st.tracked[unit]
        if existing then
          existing.seen_sweep = st.sweep
        else
          local pos = e.position
          if not view or view(pos.x, pos.y) then
            local rec = {
              unit = unit,
              e = e,
              proto_id = registry.entity_id(e.name),
              name = e.name,
              etype = e.type,
              px = pos.x,
              py = pos.y,
              ori = e.orientation or 0,
              energy = e.energy or 0,
              last_move_tick = tick,
              last_check_tick = tick,
              last_sent = -999,
              seen_sweep = st.sweep,
              limbo_locked = false,
              is_new = true,
              sent_state = -1,
              sent_flags = -1,
              sent_t0 = tick,
              sent_sx = pos.x,
              sent_sy = pos.y,
              sent_tx = pos.x,
              sent_ty = pos.y,
              sent_nx = 0,
              sent_ny = 0,
              sent_ori = 0,
            }
            st.tracked[unit] = rec
            local n = #st.order + 1
            st.order[n] = unit
            st.order_pos[unit] = n
            st.gone[unit] = nil
            schedule(st, rec, tick, opt)
          end
        end
      end
    end
  end
end

local function scan_near(surface, s, st, tick, types, view, opt)
  if #types == 0 then
    return
  end
  M.counts.near_scans = M.counts.near_scans + 1
  local f = s.focus
  local nr = math.min(NEAR_ROBOT_RADIUS, f.r + SCAN_MARGIN)
  local found = surface.find_entities_filtered({
    area = { { f.x - nr, f.y - nr }, { f.x + nr, f.y + nr } },
    type = types,
  })
  ingest_found(st, found, tick, view, opt)
end

local function scan_strip(surface, s, st, tick, types, view, opt)
  if #types == 0 then
    return
  end
  M.counts.strip_scans = M.counts.strip_scans + 1
  local f = s.focus
  local r = f.r + SCAN_MARGIN
  local y0 = f.y - r
  local h = (2 * r) / SCAN_STRIPS
  local sy0 = y0 + (st.strip - 1) * h
  local sy1 = st.strip == SCAN_STRIPS and (f.y + r) or (sy0 + h)
  if not opt and st.strip == 1 then
    scan_roboports(surface, s, st, tick)
  end
  local found = surface.find_entities_filtered({
    area = { { f.x - r, sy0 }, { f.x + r, sy1 } },
    type = types,
  })
  ingest_found(st, found, tick, view, opt)
  if st.strip == SCAN_STRIPS then
    st.strip = 1
    st.sweep = st.sweep + 1
    -- Evict robots not seen in the last 2 full sweeps that also lie outside current focus radius.
    local cutoff = st.sweep - 1
    for unit, rec in pairs(st.tracked) do
      if rec.seen_sweep < cutoff then
        if not rec.e.valid then
          untrack(st, unit, true)
        else
          local p = rec.e.position
          if math.abs(p.x - f.x) > f.r + SCAN_MARGIN or math.abs(p.y - f.y) > f.r + SCAN_MARGIN then
            untrack(st, unit, true)
          else
            schedule(st, rec, tick, opt)
          end
        end
      end
    end
  else
    st.strip = st.strip + 1
  end
end

local function read_cargo(e, opt)
  local ok, inv = pcall(get_cargo_inv, e)
  if not ok or not inv then
    return false
  end
  if opt then
    local oke, empty = pcall(inv_is_empty, inv)
    if oke and type(empty) == "boolean" then
      return not empty
    end
  end
  local oks, has = pcall(inv_slot1_valid, inv)
  return oks and has or false
end

local function read_cargo_detail(e)
  local ok, inv = pcall(get_cargo_inv, e)
  if not ok or not inv then
    return nil, 0, nil
  end
  return inv_slot1_detail(inv)
end

local function resolve_personal_owner(st, r, e)
  local owner = st.personal_owners[r.unit]
  if owner and owner.valid then
    return owner
  end
  local ok, net = pcall(get_logistic_network, e)
  if ok and net and net.valid then
    local okc, cells = pcall(get_net_cells, net)
    if okc and cells then
      for _, c in pairs(cells) do
        if c and c.valid then
          local okm, mob = pcall(get_cell_mobile, c)
          if okm and mob then
            local oko, co = pcall(get_cell_owner, c)
            if oko and co and co.valid and FOLLOW_TYPES[co.type] then
              st.personal_owners[r.unit] = co
              return co
            end
          end
        end
      end
    end
  end
  return nil
end

local function read_orders(e)
  local ok, q = pcall(get_robot_orders, e)
  return (ok and type(q) == "table") and q or EMPTY_ORDERS
end

local function read_energy(e)
  local ok, en = pcall(get_energy, e)
  return (ok and type(en) == "number") and en or 1500000
end

local function read_quality(e)
  local ok, q = pcall(get_quality_name, e)
  return (ok and type(q) == "string") and q or "normal"
end

-- Predicted position in tiles from the last sent record at `tick`.
local function predict_sent(rec, tick, v)
  local s_state = rec.sent_state
  local dt = math.max(0, tick - rec.sent_t0)
  if s_state == STATE_HOVER or s_state == STATE_ORBIT or v <= 0 then
    return rec.sent_sx, rec.sent_sy
  end
  local dx1 = rec.sent_tx - rec.sent_sx
  local dy1 = rec.sent_ty - rec.sent_sy
  local d1 = math.sqrt(dx1 * dx1 + dy1 * dy1)
  if d1 < 1e-4 then
    return rec.sent_tx, rec.sent_ty
  end
  local t1 = d1 / v
  if dt <= t1 then
    local f = dt / t1
    return rec.sent_sx + dx1 * f, rec.sent_sy + dy1 * f
  end
  if math.floor(rec.sent_flags / FLAG_HAS_NEXT) % 2 == 1 then
    local dx2 = rec.sent_nx - rec.sent_tx
    local dy2 = rec.sent_ny - rec.sent_ty
    local d2 = math.sqrt(dx2 * dx2 + dy2 * dy2)
    if d2 > 1e-4 then
      local t2 = d2 / v
      local f2 = math.min(1.0, (dt - t1) / t2)
      return rec.sent_tx + dx2 * f2, rec.sent_ty + dy2 * f2
    end
  end
  return rec.sent_tx, rec.sent_ty
end

local function robot_flight_leg(st, r, tick, pos, ori, energy, pos_moved, pstats, v, batt_mod, fast_unlock, e, q, o1, o1_tgt, o1_valid, opt)
  local state = STATE_HOVER
  local sx, sy = pos.x, pos.y
  local tx, ty = pos.x, pos.y
  local nx, ny = 0, 0
  local has_next = false
  local next_cargo = false
  local working = false
  local charging = false
  local returning = false
  local next_due = tick + 15
  local snap = r.is_new or false

  local rp_ch = st.ch_map[r.unit]
  local rp_tc = st.tc_map[r.unit]

  if rp_ch and rp_ch.valid then
    local rpp = rp_ch.position
    local dx, dy = rpp.x - pos.x, rpp.y - pos.y
    local dist_rp = math.sqrt(dx * dx + dy * dy)
    if FOLLOW_TYPES[rp_ch.type] then
      returning = (r.etype == "construction-robot")
      if energy > r.energy + 100 or (not pos_moved and dist_rp <= 1.5) then
        state = STATE_HOVER
        charging = true
        next_due = tick + ((r.is_new and dist_rp > 2.2) and 4 or 10)
      else
        state = STATE_FOLLOW
        charging = true
        tx, ty = rpp.x, rpp.y
        nx, ny = rp_ch.unit_number or 0, 0
        next_due = tick + (r.limbo_locked and 6 or math.min(6, fast_unlock))
      end
    elseif energy > r.energy + 100 or (not pos_moved and dist_rp <= 4.5) then
      state = STATE_HOVER
      charging = true
      next_due = tick + ((r.is_new and dist_rp > 2.2) and 4 or 15)
    else
      -- Approaching charging pad (~4 tiles): use direction projection or roboport center.
      local rad = ori * 2 * math.pi
      local step_d = math.max(1.5, math.min(dist_rp + 1.0, v * 15))
      state = STATE_FLY_DIR
      charging = true
      tx = pos.x + math.sin(rad) * step_d
      ty = pos.y - math.cos(rad) * step_d
      next_due = tick + 4
    end
  elseif rp_tc and rp_tc.valid then
    local rpp = rp_tc.position
    local dx, dy = rpp.x - pos.x, rpp.y - pos.y
    local dist_rp = math.sqrt(dx * dx + dy * dy)
    if FOLLOW_TYPES[rp_tc.type] then
      returning = (r.etype == "construction-robot")
      if dist_rp > 2.5 then
        state = STATE_FOLLOW
        tx, ty = rpp.x, rpp.y
        nx, ny = rp_tc.unit_number or 0, 0
        next_due = tick + (r.limbo_locked and 6 or math.min(6, fast_unlock))
      else
        state = STATE_ORBIT
        tx, ty = rpp.x, rpp.y
        nx, ny = rp_tc.unit_number or 0, 0
        next_due = tick + 10
      end
    elseif dist_rp > 4.5 then
      state = STATE_FLY_TARGET
      tx, ty = rpp.x, rpp.y
      local t_arr = v > 1e-6 and math.floor(dist_rp / v) or 15
      next_due = tick + math.max(2, math.min(t_arr, 15))
    else
      state = STATE_ORBIT
      tx, ty = rpp.x, rpp.y
      next_due = tick + 15
    end
  elseif o1 and o1_valid then
    local p1 = o1_tgt.position
    local dx, dy = p1.x - pos.x, p1.y - pos.y
    local dist1 = math.sqrt(dx * dx + dy * dy)
    local exp_ori = dist1 > 1e-4 and ((math.atan2(dx, -dy) / (2 * math.pi)) % 1.0) or ori
    local ang_err = math.abs((ori - exp_ori + 0.5) % 1.0 - 0.5)
    if dist1 < 0.35 then
      if FOLLOW_TYPES[o1_tgt.type] and r.etype == "construction-robot"
          and resolve_personal_owner(st, r, e) == o1_tgt then
        state = STATE_FOLLOW
        returning = true
        tx, ty = p1.x, p1.y
        nx, ny = o1_tgt.unit_number or 0, 0
        next_due = tick + 6
      else
        state = STATE_HOVER
        if r.etype == "construction-robot" and CONSTRUCT_WORK_OT[o1.type] then
          working = true
        end
        next_due = tick + (r.etype == "construction-robot" and 10 or 4)
      end
    elseif FOLLOW_TYPES[o1_tgt.type] and (ang_err <= 0.035 or pos_moved or not near_roboport(st, pos.x, pos.y, 1.5)) then
      state = STATE_FOLLOW
      tx, ty = p1.x, p1.y
      nx, ny = o1_tgt.unit_number or 0, 0
      if r.etype == "construction-robot" and resolve_personal_owner(st, r, e) == o1_tgt then
        returning = true
      end
      next_due = tick + (returning and 6 or 8)
    elseif ang_err <= 0.035 then
      state = STATE_FLY_TARGET
      tx, ty = p1.x, p1.y
      local o2 = q[2]
      local o2_tgt = o2 and o2.target
      if o2 and o2_tgt and o2_tgt.valid and not FOLLOW_TYPES[o2_tgt.type] then
        has_next = true
        local p2 = o2_tgt.position
        nx, ny = p2.x, p2.y
        next_cargo = (o1.type == OT_PICKUP or o1.type == OT_PICKUP_ITEMS)
      end
      local t_arr = v > 1e-6 and math.ceil(dist1 / v) or 60
      local qname = opt and r.qname
      if not qname then
        qname = read_quality(e)
        if opt then
          r.qname = qname
        end
      end
      local max_e = max_energy_for(pstats, r.name, qname)
      local thresh = max_e * (1 + batt_mod) * pstats.min_chg
      local ep_tick = pstats.ept + v * pstats.epm
      local t_chg = (energy > thresh and ep_tick > 0) and math.floor((energy - thresh) / ep_tick) or DRIFT_CHECK
      if not r.limbo_locked then
        next_due = tick + fast_unlock
      else
        next_due = tick + math.max(1, math.min(t_arr, t_chg + 2, DRIFT_CHECK))
      end
    else
      -- Queue has an order, but orientation disagrees: either inside roboport hatch before liftoff or diverting to charge.
      if not pos_moved and near_roboport(st, pos.x, pos.y, 1.5) then
        state = STATE_HOVER
        next_due = tick + 6
      else
        local ray_rp = find_ray_roboport(st, pos.x, pos.y, ori, 120, 0.006)
        if ray_rp then
          state = STATE_FLY_TARGET
          tx, ty = ray_rp.position.x, ray_rp.position.y
          local rdx, rdy = tx - pos.x, ty - pos.y
          local rd = math.sqrt(rdx * rdx + rdy * rdy)
          local t_arr = v > 1e-6 and math.ceil(rd / v) or 20
          next_due = tick + math.max(2, math.min(t_arr, 20))
        else
          state = STATE_FLY_DIR
          local rad = ori * 2 * math.pi
          local proj = math.max(4.0, v * 40)
          tx = pos.x + math.sin(rad) * proj
          ty = pos.y - math.cos(rad) * proj
          next_due = tick + (not r.limbo_locked and fast_unlock or 15)
        end
      end
    end
  else
    -- Empty queue: returning to roboport / docking.
    local owner = r.etype == "construction-robot" and resolve_personal_owner(st, r, e) or nil
    if owner then
      local op = owner.position
      state = STATE_FOLLOW
      returning = true
      tx, ty = op.x, op.y
      nx, ny = owner.unit_number or 0, 0
      next_due = tick + (r.limbo_locked and 6 or math.min(6, fast_unlock))
    elseif not pos_moved and near_roboport(st, pos.x, pos.y, 1.5) then
      state = STATE_HOVER
      next_due = tick + 10
    else
      local ray_rp = find_ray_roboport(st, pos.x, pos.y, ori, 120, 0.008)
      if ray_rp then
        state = STATE_FLY_TARGET
        tx, ty = ray_rp.position.x, ray_rp.position.y
        local rdx, rdy = tx - pos.x, ty - pos.y
        local rd = math.sqrt(rdx * rdx + rdy * rdy)
        local t_arr = v > 1e-6 and math.ceil(rd / v) or 20
        next_due = tick + math.max(2, math.min(t_arr + 2, 25))
      else
        state = STATE_FLY_DIR
        local rad = ori * 2 * math.pi
        local proj = math.max(4.0, v * 40)
        tx = pos.x + math.sin(rad) * proj
        ty = pos.y - math.cos(rad) * proj
        next_due = tick + (not r.limbo_locked and fast_unlock or 20)
      end
    end
  end
  return state, sx, sy, tx, ty, nx, ny, has_next, next_cargo, working, charging, returning, next_due, snap
end

local function emit_robot_state(r, tick, t0, sx, sy, tx, ty, nx, ny, state, has_next, ori_i, flags, out_u)
  local fixed = world.fixed
  out_u[#out_u + 1] = r.unit
  out_u[#out_u + 1] = r.proto_id
  out_u[#out_u + 1] = t0
  out_u[#out_u + 1] = fixed(sx)
  out_u[#out_u + 1] = fixed(sy)
  out_u[#out_u + 1] = fixed(tx)
  out_u[#out_u + 1] = fixed(ty)
  if state == STATE_FOLLOW or (state == STATE_ORBIT and nx ~= 0) then
    out_u[#out_u + 1] = nx
    out_u[#out_u + 1] = 0
  elseif has_next then
    out_u[#out_u + 1] = fixed(nx)
    out_u[#out_u + 1] = fixed(ny)
  else
    out_u[#out_u + 1] = 0
    out_u[#out_u + 1] = 0
  end
  out_u[#out_u + 1] = ori_i
  out_u[#out_u + 1] = flags

  r.sent_state = state
  r.sent_flags = flags
  r.sent_t0 = t0
  r.sent_sx, r.sent_sy = sx, sy
  r.sent_tx, r.sent_ty = tx, ty
  r.sent_nx, r.sent_ny = nx, ny
  r.sent_ori = ori_i
  r.last_sent = tick
end

local function check_robot(st, r, tick, speed_mod, batt_mod, sm, view, s, out_u, opt)
  local e = r.e
  if not e.valid then
    untrack(st, r.unit, true)
    return
  end
  local f = s.focus
  local pos = e.position
  if math.abs(pos.x - f.x) > f.r + SCAN_MARGIN or math.abs(pos.y - f.y) > f.r + SCAN_MARGIN then
    untrack(st, r.unit, true)
    return
  end
  if view and not view(pos.x, pos.y) then
    untrack(st, r.unit, r.sent_state >= 0)
    return
  end

  local ori = e.orientation or 0
  local energy = read_energy(e)
  local cargo = read_cargo(e, opt)
  local pstats = proto_stats(r.name, r.etype)
  local low_e = energy <= 0
  local v = pstats.spd * (sm / 1000.0) * (low_e and (pstats.low or 0.2) or 1.0)
  local fast_unlock = v > 0.5 and 1 or (v > 0.2 and 2 or 4)

  local pos_moved = math.abs(pos.x - r.px) > 1e-3 or math.abs(pos.y - r.py) > 1e-3
  local ori_diff_prev = math.abs((ori - r.ori + 0.5) % 1.0 - 0.5)
  local ori_changed = ori_diff_prev > 0.004
  local q = read_orders(e)
  local o1 = q[1]
  local o1_tgt = o1 and o1.target
  local o1_valid = o1_tgt ~= nil and o1_tgt.valid
  local o1_sig = o1 and (tostring(o1.type) .. ":" .. tostring(o1_valid and (o1_tgt.unit_number or o1_tgt.name) or "")) or ""
  local q_changed = r.is_new or o1_sig ~= (r.last_o1_sig or "")

  local since_check = math.max(1, tick - r.last_check_tick)
  local was_locked = r.limbo_locked
  if pos_moved then
    r.last_move_tick = tick
  end
  if not r.is_new and (q_changed or ori_changed) and not (pos_moved and since_check <= 2) then
    r.limbo_locked = false
  end
  if not r.is_new and pos_moved and since_check <= 4 then
    r.limbo_locked = true
  end

  local state, sx, sy, tx, ty, nx, ny, has_next, next_cargo, working, charging, returning, next_due, snap =
    robot_flight_leg(st, r, tick, pos, ori, energy, pos_moved, pstats, v, batt_mod, fast_unlock, e, q, o1, o1_tgt, o1_valid, opt)

  local t0 = tick
  local is_flying = (state == STATE_FLY_TARGET or state == STATE_FLY_DIR or state == STATE_FOLLOW)
  if state ~= r.sent_state and not (pos_moved and since_check <= 2) then
    r.limbo_locked = false
    if is_flying then
      next_due = math.min(next_due, tick + fast_unlock)
    end
  end
  local base_flags = state
    + (cargo and FLAG_CARGO or 0)
    + (low_e and FLAG_LOW_E or 0)
    + (has_next and FLAG_HAS_NEXT or 0)
    + (next_cargo and FLAG_NEXT_CARGO or 0)
    + (working and FLAG_WORKING or 0)
    + (charging and FLAG_CHARGING or 0)
    + (returning and FLAG_RETURNING or 0)
  -- Mid-sleep check on an unchanged leg: keep existing anchor so sleeping e.position never snaps backwards.
  local sleeping_same = (not r.is_new) and (not pos_moved) and (not ori_changed) and (not q_changed)
    and is_flying and (r.sent_state == state) and (tick - r.last_move_tick < LIMBO_MAX_SLEEP)
    and (r.sent_flags >= 0 and strip_snap(r.sent_flags) == base_flags)

  if sleeping_same then
    -- Keep sleeping anchor; wake right after expected 20-tick jump if needed.
    local wake_due = r.last_move_tick + 21
    if wake_due > tick and wake_due < next_due then
      next_due = wake_due
    end
    sx, sy, t0 = r.sent_sx, r.sent_sy, r.sent_t0
    if state ~= STATE_FOLLOW then
      tx, ty = r.sent_tx, r.sent_ty
      nx, ny = r.sent_nx, r.sent_ny
    end
  elseif pos_moved and since_check > 1 and since_check <= 6 and not r.is_new then
    -- Refine limbo start tick inside short unlock bracket.
    t0 = math.floor((r.last_check_tick + tick + 1) * 0.5)
    r.last_move_tick = t0
  elseif pos_moved then
    r.last_move_tick = t0
  end

  local flags = base_flags + (snap and FLAG_SNAP or 0)

  local flags_cmp = strip_snap(flags)
  local sent_cmp = r.sent_flags >= 0 and strip_snap(r.sent_flags) or -1
  local target_moved = (math.abs(tx - r.sent_tx) > 0.2 or math.abs(ty - r.sent_ty) > 0.2)
    or (has_next and (math.abs(nx - r.sent_nx) > 0.2 or math.abs(ny - r.sent_ny) > 0.2))

  local drift_err = 0.0
  local limbo_proj = false
  if was_locked and not r.is_new and pos_moved and is_flying then
    if state == r.sent_state and not ori_changed and not q_changed and flags_cmp == sent_cmp and not target_moved
        and (state == STATE_FLY_TARGET or state == STATE_FLY_DIR) then
      local dx1, dy1 = r.sent_tx - r.sent_sx, r.sent_ty - r.sent_sy
      local d1 = math.sqrt(dx1 * dx1 + dy1 * dy1)
      if d1 > 1e-4 and v > 1e-6 then
        local ux, uy = dx1 / d1, dy1 / d1
        local rx, ry = pos.x - r.sent_sx, pos.y - r.sent_sy
        local proj = rx * ux + ry * uy
        local perp = math.abs(rx * (-uy) + ry * ux)
        local lag_ticks = ((tick - r.sent_t0) * v - proj) / v
        if perp < 0.35 and lag_ticks >= -2.0 and lag_ticks <= 21.5 then
          limbo_proj = true
          drift_err = 0.0
          r.last_move_tick = math.floor(r.sent_t0 + proj / v + 0.5)
          sx, sy, t0 = r.sent_sx, r.sent_sy, r.sent_t0
          tx, ty, nx, ny = r.sent_tx, r.sent_ty, r.sent_nx, r.sent_ny
          local wake_due = r.last_move_tick + 21
          if wake_due > tick and wake_due < next_due then
            next_due = wake_due
          end
        end
      end
    end
    if not limbo_proj then
      local px, py = predict_sent(r, t0, v)
      local edx, edy = px - pos.x, py - pos.y
      drift_err = math.sqrt(edx * edx + edy * edy)
    end
  end

  local need_send = r.is_new
    or (not was_locked and r.limbo_locked)
    or state ~= r.sent_state
    or flags_cmp ~= sent_cmp
    or target_moved
    or drift_err > 0.35
    or (tick - r.last_sent >= REFRESH_TICKS and not sleeping_same)

  local ori_i = math.floor(ori * 1000 + 0.5) % 1000
  if state == STATE_ORBIT and not need_send then
    need_send = (tick - r.last_sent >= REFRESH_TICKS)
  end

  r.px, r.py, r.ori, r.energy = pos.x, pos.y, ori, energy
  r.last_check_tick = tick
  r.last_o1_sig = o1_sig
  r.is_new = false
  schedule(st, r, next_due, opt)

  if need_send then
    emit_robot_state(r, tick, t0, sx, sy, tx, ty, nx, ny, state, has_next, ori_i, flags, out_u)
  end
end

local function pack_rb_frame(k, part, parts, period, sm, snap_flag, u_flat, first_u, last_u, g_flat, first_g, last_g)
  local out = { string.pack("<I4I4I4I4I4I4", k, part, parts, period, sm, snap_flag) }
  transport.pack_block(out, u_flat, first_u, last_u)
  transport.pack_block(out, g_flat, first_g, last_g)
  return table.concat(out)
end

local function slice_json(t, first, last)
  if last < first then
    return ""
  end
  local pieces = {}
  for i = first, last do
    pieces[#pieces + 1] = tostring(t[i])
  end
  return table.concat(pieces, ",")
end

local function send_rb(st, out_u, out_g, tick, period, sm, snap_only)
  local bin = transport.binary(4)
  local nu = #out_u / RB_STRIDE
  local ng = #out_g
  local parts = math.max(1, math.ceil(nu / ROBOTS_PER_PART), math.ceil(ng / GONE_PER_PART))
  local snap_val = snap_only and 1 or 0
  for part = 1, parts do
    local p_snap = (part == 1 and snap_val == 1) and 1 or 0
    local u0 = (part - 1) * ROBOTS_PER_PART * RB_STRIDE + 1
    local u1 = math.min(nu, part * ROBOTS_PER_PART) * RB_STRIDE
    local g0 = (part - 1) * GONE_PER_PART + 1
    local g1 = math.min(ng, part * GONE_PER_PART)
    local sent_bin = false
    if bin then
      local ok, body = pcall(pack_rb_frame, tick, part, parts, period, sm, p_snap, out_u, u0, u1, out_g, g0, g1)
      if ok then
        transport.send_frame(transport.KIND_RB, "rb", body)
        sent_bin = true
      end
    end
    if not sent_bin then
      local extra = ',"part":' .. part .. ',"parts":' .. parts .. ',"p":' .. period .. ',"sm":' .. sm
        .. (p_snap == 1 and ',"snap":1' or "")
        .. ',"u":[' .. slice_json(out_u, u0, u1) .. "]"
        .. (g1 >= g0 and ',"g":[' .. slice_json(out_g, g0, g1) .. "]" or "")
      transport.send_text("rb", extra)
    end
  end
  st.need_snap = false
  st.last_send_tick = tick
end

local function send_alt_rc(st, f)
  local dr = settings and settings.global and settings.global["f3d-detail-radius"]
  local r = dr and math.min(dr.value, f.r) or f.r
  if r <= 0 then
    return
  end
  local flat = {}
  local qualities = {}
  local any_q = false
  local read = 0
  for unit, rec in pairs(st.tracked) do
    local e = rec.e
    if e.valid then
      local p = e.position
      if math.abs(p.x - f.x) <= r and math.abs(p.y - f.y) <= r then
        read = read + 1
        local name, count, qn = read_cargo_detail(e)
        if name and count > 0 then
          flat[#flat + 1] = unit
          flat[#flat + 1] = registry.item_id(name)
          flat[#flat + 1] = count
          if qn and qn ~= "normal" then
            any_q = true
            qualities[#qualities + 1] = unit
            qualities[#qualities + 1] = qn
          end
        end
      end
    end
  end
  local pkt = { t = "rc", l = flat }
  if any_q then
    pkt.q = qualities
  end
  transport.send_now(pkt)
  st.alt_rc_sent = true
  rate.read("rc", read)
end

-- Live worker robots in box [x0, y0, x1, y1] of `own` force (map.robots_in when robot_sim is active).
-- Returns nil before the first full strip sweep completes so map.lua falls back to a surface scan.
function M.live_in(surface, own, x0, y0, x1, y1)
  local s = storage.f3d
  local st = s and clients[s]
  if not (st and st.sweep >= 1 and st.last_si == surface.index) then
    return nil
  end
  local f = s.focus
  if x0 < f.x - f.r or x1 > f.x + f.r or y0 < f.y - f.r or y1 > f.y + f.r then
    return nil
  end
  local out = {}
  for _, rec in pairs(st.tracked) do
    local e = rec.e
    if e.valid then
      local p = e.position
      if p.x >= x0 and p.x < x1 and p.y >= y0 and p.y < y1 and e.force.name == own then
        out[#out + 1] = e
      end
    end
  end
  return out
end

function M.tick()
  local s = storage.f3d
  if not s then
    return
  end
  local active = M.active()
  local st = clients[s]
  if not active then
    if st then
      if next(st.tracked) ~= nil or st.last_send_tick > 0 then
        local _, _ = pcall(send_rb, st, {}, {}, game.tick, HEARTBEAT_TICKS, 1000, true)
      end
      clients[s] = nil
    end
    return
  end

  local surface = world.surface()
  if not surface then
    return
  end
  st = state_of(s)
  local tick = game.tick
  local f = s.focus
  local period = rate.period("rb", HEARTBEAT_TICKS)
  local opt = perf.on("robot_opt")

  -- Detect surface change or large focus jump -> clean reset & snap.
  if st.last_si ~= surface.index or st.last_fr ~= f.r
      or (st.last_fx and math.max(math.abs(f.x - st.last_fx), math.abs(f.y - st.last_fy)) >= SCAN_JUMP) then
    st.tracked = {}
    st.order = {}
    st.order_pos = {}
    st.buckets = {}
    st.roboports = {}
    st.rp_cells = {}
    st.mobile_owners = {}
    st.mo_cells = {}
    st.personal_owners = {}
    st.personal_prev = {}
    st.ch_map = {}
    st.tc_map = {}
    st.ch_prev = {}
    st.tc_prev = {}
    st.gone = {}
    st.alt_rc_sent = false
    st.strip = 1
    st.sweep = 0
    st.last_near_scan_tick = -999
    st.last_rp_scan_tick = nil
    st.last_rp_fx, st.last_rp_fy, st.last_rp_fr = nil, nil, nil
    st.last_mod_tick = nil
    st.cached_sm, st.cached_bm = nil, nil
    st.last_si = surface.index
    st.last_fx, st.last_fy, st.last_fr = f.x, f.y, f.r
    st.need_snap = true
  else
    local moved = st.last_fx and math.max(math.abs(f.x - st.last_fx), math.abs(f.y - st.last_fy)) or 0
    if moved >= SCAN_MOVE then
      st.last_fx, st.last_fy = f.x, f.y
      st.strip = 1
    end
  end

  local rate_fac = opt and rate.factor("mv") or 1
  local scan_step = opt and (SCAN_STEP_OPT * rate_fac) or SCAN_STEP_TICKS
  local near_scan = opt and (NEAR_SCAN_OPT * rate_fac) or NEAR_SCAN_TICKS
  local charge_poll = opt and (CHARGE_POLL_OPT * rate_fac) or CHARGE_POLL_TICKS

  local tp = profile.start()
  local types = worker_types()
  local view = map.view_filter()
  if opt then
    local rp_moved = st.last_rp_fx and math.max(math.abs(f.x - st.last_rp_fx), math.abs(f.y - st.last_rp_fy)) or 0
    if not st.last_rp_scan_tick or st.last_rp_fr ~= f.r
        or tick - st.last_rp_scan_tick >= ROBOPORT_SCAN_TICKS
        or rp_moved >= ROBOPORT_SCAN_MOVE then
      scan_roboports(surface, s, st, tick)
    end
  end
  if st.sweep == 0 or tick - st.last_scan_tick >= scan_step then
    st.last_scan_tick = tick
    scan_strip(surface, s, st, tick, types, view, opt)
  end
  if perf.on("near_first") and tick - (st.last_near_scan_tick or -999) >= near_scan then
    st.last_near_scan_tick = tick
    scan_near(surface, s, st, tick, types, view, opt)
  end

  local wake = nil
  if tick - st.last_ch_tick >= charge_poll then
    st.last_ch_tick = tick
    wake = refresh_charging(st, opt)
  end

  local speed_mod, batt_mod = force_mods(st, tick, opt)
  local sm = math.max(1, math.floor((1 + speed_mod) * 1000 + 0.5))
  if st.last_sm ~= nil and st.last_sm ~= sm then
    for _, rec in pairs(st.tracked) do
      rec.limbo_locked = false
      rec.sent_state = -1
      schedule(st, rec, tick, opt)
    end
  end
  st.last_sm = sm

  local max_checks = MAX_CHECKS
  if opt then
    local rate_cap = math.max(32, math.floor(MAX_CHECKS / rate_fac))
    local bud_cap = math.max(MIN_CHECKS, math.floor(math.max(0, budget.left())))
    max_checks = math.min(rate_cap, bud_cap)
  end

  local due_units = opt and clear_array(st.due_units) or {}
  local checked_set = opt and clear_map(st.checked_set) or {}

  -- Pop due buckets up to current tick.
  for bt, bmap in pairs(st.buckets) do
    if bt <= tick then
      for u in pairs(bmap) do
        queue_unit(st, checked_set, due_units, u)
      end
      st.buckets[bt] = nil
      if opt and #st.free_buckets < FREE_BUCKET_CAP then
        clear_map(bmap)
        st.free_buckets[#st.free_buckets + 1] = bmap
      end
    end
  end
  if wake then
    for u in pairs(wake) do
      queue_unit(st, checked_set, due_units, u)
    end
  end
  -- Small round-robin safety refresh slice so stale entries are caught even if unscheduled.
  local n_ord = #st.order
  local rr_budget
  if opt then
    rr_budget = math.min(n_ord, math.max(8, math.ceil(n_ord / (60 * rate_fac))), math.max(8, math.floor(max_checks / 4)))
  else
    rr_budget = math.min(n_ord, math.max(8, math.ceil(n_ord / 60)))
  end
  for _ = 1, rr_budget do
    if st.refresh_idx > #st.order then
      st.refresh_idx = 1
    end
    local u = st.order[st.refresh_idx]
    st.refresh_idx = st.refresh_idx + 1
    local rec = u and st.tracked[u]
    if rec and tick - rec.last_check_tick >= 40 then
      queue_unit(st, checked_set, due_units, u)
    end
  end

  local active_due = due_units
  if perf.on("near_first") and #due_units > max_checks then
    local near_u = opt and clear_array(st.near_u) or {}
    local outer_u = opt and clear_array(st.outer_u) or {}
    for i = 1, #due_units do
      local u = due_units[i]
      local r = st.tracked[u]
      if r and math.max(math.abs(r.px - f.x), math.abs(r.py - f.y)) <= NEAR_ROBOT_RADIUS then
        near_u[#near_u + 1] = u
      else
        outer_u[#outer_u + 1] = u
      end
    end
    for i = 1, #outer_u do
      near_u[#near_u + 1] = outer_u[i]
    end
    active_due = near_u
  end

  local out_u = opt and clear_array(st.out_u) or {}
  local n_done = 0
  for i = 1, #active_due do
    local u = active_due[i]
    local r = st.tracked[u]
    if r then
      if n_done < max_checks then
        n_done = n_done + 1
        M.counts.robot_checks = M.counts.robot_checks + 1
        check_robot(st, r, tick, speed_mod, batt_mod, sm, view, s, out_u, opt)
      else
        schedule(st, r, tick + 1, opt)
      end
    end
  end

  local out_g = opt and clear_array(st.out_g) or {}
  for u, left in pairs(st.gone) do
    out_g[#out_g + 1] = u
    if left <= 1 then
      st.gone[u] = nil
    else
      st.gone[u] = left - 1
    end
  end

  if #out_u > 0 or #out_g > 0 or st.need_snap or (tick - st.last_send_tick >= period) then
    send_rb(st, out_u, out_g, tick, period, sm, st.need_snap)
  end
  if s.altc ~= nil then
    if not st.alt_rc_sent or rate.due("rc", CARGO_INTERVAL) then
      send_alt_rc(st, f)
    end
  elseif st.alt_rc_sent then
    transport.send_now({ t = "rc", l = {} })
    st.alt_rc_sent = false
  end
  profile.stop("rb.tick", tp)
end

return M
