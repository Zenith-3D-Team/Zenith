# Bridge test slice 09_robots_resp_ups.py (lines 13466-15499 of original test_bridge.py)
# --- simulated worker robots (rb, /f3d-perf robot_sim) ---------------------------------------------
F.take_sent()  # drain anything pending from on_config test
send({"t": "bye"}, port=PORT_B)
tick(1)
F.take_sent()
rb_ox, rb_oy = 220, 220
rb_chest_a = spawn("wooden-chest", rb_ox + 5.5, rb_oy + 0.5, force="player")
rb_chest_b = spawn("wooden-chest", rb_ox + 20.5, rb_oy + 0.5, force="player")
rb_rp = spawn("roboport", rb_ox - 1.5, rb_oy - 1.5, force="player")
rb_car = spawn("car", rb_ox + 2.5, rb_oy + 2.5, force="player")
rb_char = spawn("character", rb_ox + 10.5, rb_oy + 5.5, force="player")
OT = g.defines.robot_order_type
rb_log = spawn("logistic-robot", rb_ox - 4.5, rb_oy + 0.5, force="player")
rb_log.orientation = 0.25  # east toward chest A
rb_log.energy = 1500000
rb_log.robot_order_queue = lua.table_from([
    lua.table_from({"type": OT.pickup, "target": rb_chest_a}),
    lua.table_from({"type": OT.deliver, "target": rb_chest_b}),
])
rb_con = spawn("construction-robot", rb_ox - 1.2, rb_oy - 1.5, force="player")  # inside roboport hatch (<1.5 tiles)
rb_con.orientation = 0.75  # west: disagrees with east direction to chest B -> hatch HOVER
rb_con.robot_order_queue = lua.table_from([lua.table_from({"type": OT.construct, "target": rb_chest_b})])

send({"t": "hello", "v": 1, "sid": "rb1", "w": 0, "b": 1, "rb": 1})
send({"t": "focus", "x": rb_ox * 256, "y": rb_oy * 256, "r": 64})
tick(18)
msgs = take()


def rb_recs(ms):
    by_u = {}
    for m in of_type(ms, "rb"):
        u = m.get("u") or []
        for i in range(0, len(u) - 10, 11):
            by_u[u[i]] = u[i:i + 11]
    return by_u


def mv_units_of(ms):
    units = set()
    for m in of_type(ms, "mv"):
        prev = 0
        for rec in (m.get("l") or []):
            u = prev + rec[0] if m.get("z") == 1 else rec[0]
            prev = u
            units.add(u)
    return units


recs = rb_recs(msgs)
mv_units = mv_units_of(msgs)
check(rb_car.unit_number in mv_units
      and rb_log.unit_number not in mv_units and rb_con.unit_number not in mv_units,
      f"rb: worker robots excluded from mv while car stays: mv={sorted(mv_units)}")
check(not of_type(msgs, "rc"), "rb: rc skipped while rb is active")

log_r = recs.get(rb_log.unit_number)
check(log_r is not None and (log_r[10] & 7) == 0 and (log_r[10] & 32) and (log_r[10] & 64)
      and abs(log_r[5] / 256.0 - (rb_ox + 5.5)) < 0.05 and abs(log_r[7] / 256.0 - (rb_ox + 20.5)) < 0.05,
      f"rb: logistic robot FLY_TARGET + HAS_NEXT + NEXT_CARGO: {log_r}")

con_r = recs.get(rb_con.unit_number)
check(con_r is not None and (con_r[10] & 7) == 2 and (con_r[10] & 128) == 0,
      f"rb: construction robot in hatch pause stays HOVER without WORKING: {con_r}")

# Move construction robot onto build target -> HOVER | WORKING.
rb_con.position = lua.table_from({"x": rb_ox + 20.4, "y": rb_oy + 0.5})
rb_con.orientation = 0.25
tick(12)
con_work = rb_recs(take()).get(rb_con.unit_number)
check(con_work is not None and (con_work[10] & 7) == 2 and (con_work[10] & 128) != 0,
      f"rb: construction robot at target emits HOVER | WORKING: {con_work}")

# First jump locks limbo phase cleanly; subsequent mid-limbo step along leg preserves locked anchor.
rb_log.position = lua.table_from({"x": rb_ox - 3.5, "y": rb_oy + 0.5})
tick(4)
locked_r = rb_recs(take()).get(rb_log.unit_number)
check(locked_r is not None, f"rb: first limbo jump emits locked phase anchor: {locked_r}")
rb_log.position = lua.table_from({"x": rb_ox - 2.5, "y": rb_oy + 0.5})
tick(10)
limbo_up = rb_recs(take()).get(rb_log.unit_number)
check(limbo_up is None or (locked_r is not None and limbo_up[2] == locked_r[2] and limbo_up[3] == locked_r[3]),
      f"rb: mid-limbo step along flight leg keeps locked anchor: {limbo_up} vs {locked_r}")

# Low energy triggers LOW_ENERGY flag (bit 16) when next checked by bucket / safety refresh.
rb_log.energy = 0
tick(42)
log_low = rb_recs(take()).get(rb_log.unit_number)
check(log_low is not None and (log_low[10] & 16) != 0,
      f"rb: energy=0 emits LOW_ENERGY flag: {log_low}")

# Charging & orbiting roboport.
rb_log.energy = 1500000
rb_log.position = lua.table_from({"x": rb_ox - 1.3, "y": rb_oy - 1.5})
rb_rp.logistic_cell.charging_robots[1] = rb_log
tick(12)  # first wake sees pad approach (FLY_DIR|CHARGING), +4t settled at pad -> HOVER|CHARGING
log_chg = rb_recs(take()).get(rb_log.unit_number)
check(log_chg is not None and (log_chg[10] & 7) == 2 and (log_chg[10] & 256) != 0,
      f"rb: charging_robots -> HOVER | CHARGING: {log_chg}")

rb_rp.logistic_cell.charging_robots[1] = None
rb_rp.logistic_cell.to_charge_robots[1] = rb_log
rb_log.position = lua.table_from({"x": rb_ox + 0.5, "y": rb_oy - 0.5})
tick(13)  # CHARGE_POLL_OPT = 12 with robot_opt on
log_orb = rb_recs(take()).get(rb_log.unit_number)
check(log_orb is not None and (log_orb[10] & 7) == 3,
      f"rb: to_charge_robots within 4.5 tiles -> ORBIT: {log_orb}")

# Charging diversion: order queue still points east, orientation points north -> FLY_DIR, NOT target.
rb_rp.logistic_cell.to_charge_robots[1] = None
rb_log.position = lua.table_from({"x": rb_ox + 2.0, "y": rb_oy + 2.0})
rb_log.orientation = 0.0
tick(13)  # CHARGE_POLL_OPT = 12 with robot_opt on
log_div = rb_recs(take()).get(rb_log.unit_number)
check(log_div is not None and (log_div[10] & 7) == 1,
      f"rb: queue/orientation mismatch outside hatch -> FLY_DIR diversion: {log_div}")

# FOLLOW target (character): orientation toward character -> state 4, nx = char.unit_number.
rb_log.robot_order_queue = lua.table_from([lua.table_from({"type": OT.deliver, "target": rb_char})])
rb_log.position = lua.table_from({"x": rb_ox + 5.5, "y": rb_oy + 5.5})
rb_log.orientation = 0.25
tick(20)
log_fol = rb_recs(take()).get(rb_log.unit_number)
check(log_fol is not None and (log_fol[10] & 7) == 4 and log_fol[7] == rb_char.unit_number,
      f"rb: FOLLOW character target sets nx=unit_number: {log_fol}")

# map.robots_in uses robots.live_in after strip sweep completes.
live_units = lua.eval("""function(ox, oy)
  local m = package.loaded["scripts.map"]
  local list = m.robots_in(game.surfaces[1], "player", ox - 10, oy - 10, ox + 30, oy + 15)
  local out = {}
  for _, e in ipairs(list) do out[e.unit_number] = true end
  return out
end""")(rb_ox, rb_oy)
check(live_units[rb_log.unit_number] and live_units[rb_con.unit_number],
      "rb: map.robots_in returns live tracked worker robots via robots.live_in")

# gone when robot is destroyed.
dead_u = rb_log.unit_number
rb_log.destroy()
tick(6)
msgs_gone = take()
gone_seen = {u for m in of_type(msgs_gone, "rb") for u in (m.get("g") or [])}
check(dead_u in gone_seen, f"rb: destroyed robot emitted in gone list: {gone_seen}")

# Personal roboport return (STATE_FOLLOW | FLAG_RETURNING), logistic FOLLOW without returning,
# stationary roboport FLY_TARGET without returning, and Alt-mode rc during rb (with quality + clear).
p_cell = F.make_cell(rb_char, 0, 30)
p_net = F.make_network(99, lua.table_from([0, 0, 1, 1]), lua.table_from([]), lua.table_from([p_cell]))
rb_char.logistic_cell = p_cell
rb_char.logistic_network = p_net
rb_pcon = spawn("construction-robot", rb_ox + 2.5, rb_oy + 5.5, force="player")
rb_pcon.logistic_network = p_net
p_net.construction_robots[1] = rb_pcon
rb_pcon.orientation = 0.0  # intentionally turned away from character to test orientation independence
rb_pcon.robot_order_queue = lua.table_from([])
rb_pcon.get_inventory(g.defines.inventory.robot_cargo)[1].set_stack(
    lua.table_from({"name": "iron-plate", "count": 4, "quality": "rare"}))

rb_log2 = spawn("logistic-robot", rb_ox + 4.5, rb_oy + 5.5, force="player")
rb_log2.orientation = 0.25
rb_log2.robot_order_queue = lua.table_from([lua.table_from({"type": OT.deliver, "target": rb_char})])

rb_con.position = lua.table_from({"x": rb_ox + 8.5, "y": rb_oy - 1.5})
rb_con.orientation = 0.75  # west directly toward rb_rp at (rb_ox - 1.5, rb_oy - 1.5)
rb_con.robot_order_queue = lua.table_from([])

tick(18)
msgs_prs = take()
recs_prs = rb_recs(msgs_prs)
pcon_r = recs_prs.get(rb_pcon.unit_number)
log2_r = recs_prs.get(rb_log2.unit_number)
scon_r = recs_prs.get(rb_con.unit_number)
check(pcon_r is not None and (pcon_r[10] & 7) == 4 and (pcon_r[10] & 1024) != 0 and pcon_r[7] == rb_char.unit_number,
      f"rb: personal construction robot empty-queue emits FOLLOW | FLAG_RETURNING (1024): {pcon_r}")
check(log2_r is not None and (log2_r[10] & 7) == 4 and (log2_r[10] & 1024) == 0 and log2_r[7] == rb_char.unit_number,
      f"rb: logistic delivery FOLLOW does NOT set FLAG_RETURNING: {log2_r}")
check(scon_r is not None and (scon_r[10] & 7) == 0 and (scon_r[10] & 1024) == 0,
      f"rb: stationary construction robot empty-queue returns FLY_TARGET without FLAG_RETURNING: {scon_r}")
check(not of_type(msgs_prs, "rc"), "rb: rc stays suppressed while altc is off even when robot carries cargo")

# Turn Alt-mode on -> rc emitted with rare quality; turn Alt-mode off -> single empty clear, then silent.
send({"t": "altc", "on": 1, "g": 1})
tick(12)
rc_on = of_type(take(), "rc")
rc_hit = next((m for m in rc_on if rb_pcon.unit_number in (m.get("l") or [])), None)
check(rc_hit is not None and rc_hit.get("l") and rc_hit.get("q") and rb_pcon.unit_number in rc_hit["q"] and "rare" in rc_hit["q"],
      f"rb + altc on: emits rc with carried item and non-normal quality q: {rc_on}")
send({"t": "altc", "on": 0})
tick(4)
rc_clr = of_type(take(), "rc")
check(len(rc_clr) == 1 and rc_clr[0].get("l") == [],
      f"rb + altc off: emits single empty rc clear: {rc_clr}")
tick(12)
check(not of_type(take(), "rc"), "rb + altc off: emits no further rc after clear")

rb_pcon.destroy()
rb_log2.destroy()
rb_char.logistic_cell = None
rb_char.logistic_network = None
tick(4)
take()

# /f3d-perf robot_sim off sends snap=1 empty u and restores construction-robot to mv + rc.
F.commands["f3d-perf"](lua.table_from({"name": "f3d-perf", "parameter": "robot_sim off"}))
tick(10)
msgs_off = take()
snap_off = [m for m in of_type(msgs_off, "rb") if m.get("snap") == 1 and not (m.get("u") or [])]
mv_off = mv_units_of(msgs_off)
check(bool(snap_off) and rb_con.unit_number in mv_off,
      f"rb: /f3d-perf robot_sim off sends snap=1 reset and returns robots to mv: snap={len(snap_off)}, mv_con={rb_con.unit_number in mv_off}")
F.commands["f3d-perf"](lua.table_from({"name": "f3d-perf", "parameter": "robot_sim default"}))

# Priority queues (/f3d-perf prio_queue): interaction replies (`inv`, `slots`, `qb`, `add`, `upd`, `del`)
# flush ahead of saturated bulk chunk/ents backlog with strictly monotonic `r`, unless their own chunk still
# has a snapshot waiting in the bulk outbox; movement (`walk`) emits `me` on the same tick even on odd ticks.
send({"t": "bye"})
tick(1)
send({"t": "hello", "v": 1, "sid": "prio-test", "w": 0, "z": 1, "b": 1})
tick(10)
take()
lua.execute("""
settings.global["f3d-bytes-per-tick"].value = 32768
local tr = package.loaded["scripts.transport"]
local big_tiles = {}
for j = 1, 1024 do
  big_tiles[j] = (j % 2 == 1) and 1 or 2
end
for i = 1, 20 do
  tr.send_reliable({ t = "chunk", cx = 2, cy = 2, tiles = big_tiles, parts = 1, rs = 1, rv = i, n = 0 }, "2,2")
end
tr.send_reliable_priority({ t = "add", e = { 99001, 1, 512, 512, 0 } }, 2, 2)
tr.send_reliable_priority({ t = "add", e = { 99002, 1, 0, 0, 0 } }, 0, 0)
tr.send_reliable_priority({ t = "inv", l = { { "iron-plate", 5 } } })
""")
tick(1)
pq_t1 = take()
pq_types_t1 = [m["t"] for m in pq_t1]
pq_first_chunk = pq_types_t1.index("chunk") if "chunk" in pq_types_t1 else -1
pq_prio_prefix = pq_t1[:pq_first_chunk] if pq_first_chunk > 0 else []
pq_add_idx = next((i for i, m in enumerate(pq_prio_prefix)
                   if m.get("t") == "add" and (m.get("e") or [None])[0] == 99002), -1)
pq_inv_idx = next((i for i, m in enumerate(pq_prio_prefix) if m.get("t") == "inv"), -1)
check(pq_first_chunk > 0 and 0 <= pq_add_idx < pq_inv_idx,
      f"prio_queue: unblocked priority add(99002) & inv flush ahead of saturated chunk backlog: {pq_types_t1}")
check(not any(m.get("t") == "add" and m.get("e", [None])[0] == 99001 for m in pq_t1),
      f"prio_queue: add on chunk (2,2) waits while chunk (2,2) still has snapshots queued: {pq_t1}")
pq_found_deferred = -1
pq_last_chunk_r = -1
for m in pq_t1:
    if m.get("t") == "chunk" and m.get("cx") == 2 and m.get("cy") == 2:
        pq_last_chunk_r = m["r"]
while g.storage.f3d.outbox_head <= g.storage.f3d.outbox_tail:
    tick(1)
    pq_rest = take()
    for m in pq_rest:
        if m.get("t") == "add" and m.get("e", [None])[0] == 99001:
            pq_found_deferred = m["r"]
        elif m.get("t") == "chunk" and m.get("cx") == 2 and m.get("cy") == 2:
            pq_last_chunk_r = m["r"]
check(pq_found_deferred > pq_last_chunk_r > 0,
      f"prio_queue: chunk-scoped add flushed strictly after its chunk snapshots ({pq_found_deferred} > {pq_last_chunk_r})")
lua.execute('settings.global["f3d-bytes-per-tick"].value = 131072')

# Deferred decoratives + 400-entity binary packing: snapshot `chunk` + `ents` drain ahead of `dec`
# when chunks wait in queue, and binary v3 sends up to 400 entities per `ents` message vs 120 in JSON.
send({"t": "bye"})
tick(1)
dense_ents = []
for i in range(180):
    dense_ents.append(spawn("wooden-chest", -96 + (i % 20) * 1.0 + 0.5, -96 + (i // 20) * 1.0 + 0.5, force="player"))
F.add_decorative(F.surface, "small-rock", -90, -90, 1)
F.add_decorative(F.surface, "small-rock", -58, -90, 1)
send({"t": "hello", "v": 1, "sid": "stream-pack", "w": 0, "z": 1, "b": 1, "dc": 1, **({"bin": 3} if BINARY else {})})
tick(10)
take()
send({"t": "sub", "c": [[-3, -3], [-2, -3]]})
order_types = []
ents_parts = []
for _ in range(40):
    tick(1)
    for m in take():
        order_types.append(m.get("t"))
        if m.get("t") == "ents" and m.get("cx") == -3 and m.get("cy") == -3:
            ents_parts.append((m.get("part"), m.get("parts"), len(m.get("e") or [])))
    if order_types.count("dec") >= 2:
        break
if BINARY:
    check(ents_parts == [(1, 1, 180)], f"bin_ents_pack: 180 entities pack into 1 binary ents message: {ents_parts}")
else:
    check(ents_parts == [(1, 2, 120), (2, 2, 60)], f"json_ents_pack: 180 entities split at 120 in JSON: {ents_parts}")
first_dec = order_types.index("dec") if "dec" in order_types else -1
last_chunk = max((i for i, t in enumerate(order_types) if t in ("chunk", "ents")), default=-1)
check(0 <= last_chunk < first_dec,
      f"dec_deferred: chunk snapshots ({last_chunk}) complete before queued dec ({first_dec}): {order_types}")
for de in dense_ents:
    de.destroy()
send({"t": "hello", "v": 1, "sid": "prio-hs", "w": 0, "z": 1, "b": 1})
tick(5)
take()

# Handshake barrier: welcome -> protos -> ready must flush strictly before queued priority replies.
send({"t": "bye"})
tick(1)
send({"t": "hello", "v": 1, "sid": "prio-hs", "w": 0, "z": 1, "b": 1})
lua.execute("""
local tr = package.loaded["scripts.transport"]
tr.send_reliable_priority({ t = "inv", l = { { "coal", 1 } } })
""")
hs_msgs = []
for _ in range(10):
    tick(1)
    hs_msgs.extend(take())
hs_types = [m["t"] for m in hs_msgs]
check("ready" in hs_types and "inv" in hs_types and hs_types.index("inv") > hs_types.index("ready"),
      f"prio_queue: handshake ready completes before outbox_prio drains: {hs_types}")

# Movement immediate `me`: changing walk on an odd tick emits `me` on that very tick; off restores cadence.
if int(g.game.tick) % 2 == 1:
    tick(1)
take()
send({"t": "walk", "d": 0})
tick(1)
odd_tick = int(g.game.tick)
check(odd_tick % 2 == 1 and any(m.get("t") == "me" and m.get("k") == odd_tick for m in take()),
      f"prio_queue: walk emits `me` immediately on odd tick {odd_tick}")
set_perf(prio_queue=False)
if int(g.game.tick) % 2 == 1:
    tick(1)
take()
send({"t": "walk", "d": 4})
tick(1)
off_tick = int(g.game.tick)
check(off_tick % 2 == 1 and not of_type(take(), "me"),
      f"prio_queue off: restores STATE_INTERVAL=2 cadence on odd tick {off_tick}")
set_perf()

# --- Bridge Responsiveness Regression Suite (flush_end, PRIO_BYTES, chunk_wait, near_first, near_rate, near_spool, nack_ring) ---

# A. flush_end (STEPS_FAST + end-of-serve flush_priority) vs OFF (STEPS + next-tick flush):
send({"t": "bye"})
tick(1)
send({"t": "hello", "v": 1, "sid": "resp-flush", "w": 0, "z": 1, "b": 1, **({"bin": protocol.WIRE_VERSION} if BINARY else {})})
tick(10)
take()
resp_puppet = g.storage.f3d.puppet or g.game.players[1].character
# Align to inventory tick (tick % 30 == 0) FIRST, then queue 2 bulk chunks so one remains queued.
while (int(g.game.tick) + 1) % 30 != 0:
    tick(1)
take()
lua.execute("""
local tr = package.loaded["scripts.transport"]
local big_tiles = {}
for j = 1, 512 do
  big_tiles[#big_tiles + 1] = (j % 2 == 1) and 1 or 2
  big_tiles[#big_tiles + 1] = 2
end
settings.global["f3d-bytes-per-tick"].value = 512
tr.send_reliable({ t = "chunk", cx = 3, cy = 3, tiles = big_tiles, parts = 1, rs = 1, rv = 1, n = 0 }, "3,3")
tr.send_reliable({ t = "chunk", cx = 4, cy = 4, tiles = big_tiles, parts = 1, rs = 1, rv = 2, n = 0 }, "4,4")
""")
resp_puppet.get_main_inventory().insert(lua.table_from({"name": "iron-plate", "count": 5}))
tick(1)
fe_on_msgs = take()
check(any(m.get("t") == "inv" for m in fe_on_msgs) and g.storage.f3d.outbox_prio_tail == 0
      and g.storage.f3d.outbox_head <= g.storage.f3d.outbox_tail,
      f"flush_end on: in-serve `inv` flushes on same tick via flush_priority while remaining bulk outbox waits: {[m['t'] for m in fe_on_msgs]}")
while g.storage.f3d.outbox_head <= g.storage.f3d.outbox_tail:
    tick(1)
    take()
set_perf(flush_end=False)
while (int(g.game.tick) + 1) % 30 != 0:
    tick(1)
take()
resp_puppet.get_main_inventory().insert(lua.table_from({"name": "iron-plate", "count": 5}))
tick(1)
fe_off_t1 = take()
tick(1)
fe_off_t2 = take()
check(not any(m.get("t") == "inv" for m in fe_off_t1) and any(m.get("t") == "inv" for m in fe_off_t2),
      f"flush_end off: in-serve `inv` waits for index-1 flush on next tick: t1={[m['t'] for m in fe_off_t1]}, t2={[m['t'] for m in fe_off_t2]}")
set_perf()
lua.execute('settings.global["f3d-bytes-per-tick"].value = 131072')

# Verify STEPS_FAST puts world..inserters ahead of map..collectors when flush_end is on:
step_order_check = lua.eval("""function()
  local tick_fn = F.handlers[defines.events.on_tick]
  local function find_up(fn, name, depth)
    depth = depth or 4
    for i = 1, 255 do
      local n, v = debug.getupvalue(fn, i)
      if not n then return nil end
      if n == name then return v end
      if type(v) == "function" and depth > 0 then
        local got = find_up(v, name, depth - 1)
        if got ~= nil then return got end
      end
    end
    return nil
  end
  local fast = find_up(tick_fn, "STEPS_FAST")
  local orig = find_up(tick_fn, "STEPS")
  local function idx_map(tbl)
    local out = {}
    for i, s in ipairs(tbl or {}) do out[s[1]] = i end
    return out
  end
  local fi, oi = idx_map(fast), idx_map(orig)
  return tostring(fi["transport"] == 1 and fi["world"] < fi["map"] and fi["inserters"] < fi["map"] and oi["map"] < oi["world"])
end""")()
check(step_order_check == "true",
      f"flush_end STEPS_FAST: world..inserters ordered ahead of map while STEPS keeps map ahead of world ({step_order_check})")

# A2. prio_cap (review should-fix 3): M.flush and the end-of-serve M.flush_priority together send at most the
# priority budget's bytes in one tick; off, flush_priority starts its own full budget (up to ~64 KB a tick).
def prio_cap_sent(on):
    set_perf(prio_cap=on)
    while g.storage.f3d.outbox_head <= g.storage.f3d.outbox_tail or g.storage.f3d.outbox_prio_head <= g.storage.f3d.outbox_prio_tail:
        tick(1)
    take()
    return lua.eval("""function()
  local tr = package.loaded["scripts.transport"]
  local s = storage.f3d
  settings.global["f3d-bytes-per-tick"].value = 512
  local l = {}
  for j = 1, 120 do l[#l + 1] = { "iron-plate", j } end
  for idx = 1, 120 do tr.send_reliable_priority({ t = "inv", l = l }) end
  local h0 = s.outbox_prio_head
  tr.flush()
  local h1 = s.outbox_prio_head
  tr.flush_priority()
  local h2 = s.outbox_prio_head
  settings.global["f3d-bytes-per-tick"].value = 131072
  return h1 - h0, h2 - h1
end""")()
pc_on = prio_cap_sent(True)
pc_off = prio_cap_sent(False)
check(pc_on[0] > 0 and pc_on[1] == 0 and pc_off[1] > 0,
      f"prio_cap: flush_priority sends nothing more once flush spent the tick's priority budget (on {pc_on}, off {pc_off})")
while g.storage.f3d.outbox_head <= g.storage.f3d.outbox_tail or g.storage.f3d.outbox_prio_head <= g.storage.f3d.outbox_prio_tail:
    tick(1)
take()
set_perf()

# B. PRIO_BYTES=32768 + outbox_chunk_wait[ckey] promotion + priority callers (tiles, aiu, cmdr, world.tiles_changed, st near):
lua.execute("""
settings.global["f3d-bytes-per-tick"].value = 512
local tr = package.loaded["scripts.transport"]
local big_tiles = {}
for j = 1, 512 do
  big_tiles[#big_tiles + 1] = (j % 3) + 1
  big_tiles[#big_tiles + 1] = 2
end
-- Queue chunk (0,0) (1 msg), chunk (1,1) (2 msgs: chunk+ents), chunk (2,2) (1 msg).
tr.send_reliable({ t = "chunk", cx = 0, cy = 0, tiles = big_tiles, parts = 1, rs = 1, rv = 1, n = 0 }, "0,0")
tr.send_reliable({ t = "chunk", cx = 1, cy = 1, tiles = big_tiles, parts = 1, rs = 1, rv = 1, n = 1 }, "1,1")
tr.send_reliable({ t = "ents", cx = 1, cy = 1, part = 1, parts = 1, e = { { 98000, 1, 33 * 256, 33 * 256, 0 } } }, "1,1")
tr.send_reliable({ t = "chunk", cx = 2, cy = 2, tiles = big_tiles, parts = 1, rs = 1, rv = 1, n = 0 }, "2,2")
-- Queue two chunk-scoped priority deltas on (1,1) and >512 bytes of unblocked priority replies (PRIO_BYTES=32768).
tr.send_reliable_priority({ t = "add", e = { 98001, 1, 33 * 256, 33 * 256, 0 } }, 1, 1)
tr.send_reliable_priority({ t = "upd", e = { 98001, 1, 33 * 256, 33 * 256, 4 } }, 1, 1)
for idx = 1, 10 do
  tr.send_reliable_priority({ t = "inv", l = { { "iron-plate", idx }, { "copper-plate", idx }, { "coal", idx }, { "stone", idx } } })
end
""")
check(len(g.storage.f3d.outbox_chunk_wait["1,1"]) == 2
      and int(g.package.loaded["scripts.transport"].backlog()) >= 16,
      f"outbox_chunk_wait: buffers (1,1) deltas while (1,1) has 2 snapshot msgs in outbox; backlog={g.package.loaded['scripts.transport'].backlog()}")
tick(1)
pb_t1 = take()
pb_inv_count = sum(1 for m in pb_t1 if m.get("t") == "inv")
check(pb_inv_count == 10 and not any(m.get("t") in ("add", "upd") for m in pb_t1),
      f"PRIO_BYTES: all 10 prio inv (>512B budget) drain on tick 1 while (1,1) deltas stay deferred: inv={pb_inv_count}, types={[m['t'] for m in pb_t1]}")
pb_all = list(pb_t1)
while g.storage.f3d.outbox_head <= g.storage.f3d.outbox_tail or g.storage.f3d.outbox_prio_head <= g.storage.f3d.outbox_prio_tail:
    tick(1)
    pb_all.extend(take())
lua.execute('settings.global["f3d-bytes-per-tick"].value = 131072')
r_of = {}
for m in pb_all:
    if m.get("t") == "chunk":
        r_of[f"c_{m['cx']}_{m['cy']}"] = m["r"]
    elif m.get("t") == "ents" and m.get("cx") == 1 and m.get("cy") == 1:
        r_of["e_1_1"] = m["r"]
    elif m.get("t") in ("add", "upd") and (m.get("e") or [None])[0] == 98001:
        r_of[m["t"]] = m["r"]
check(r_of.get("c_0_0", 0) < r_of.get("c_1_1", 0) < r_of.get("e_1_1", 0) < r_of.get("add", 0) < r_of.get("upd", 0) < r_of.get("c_2_2", 0),
      f"outbox_chunk_wait promotion: (1,1) deltas promote strictly after (1,1) snapshot and ahead of (2,2): {r_of}")

# Priority callers: tiles.lua (tile-ghost mine -> del), alt_mode.lua (aiu), console.lua (cmdr), world.tiles_changed (tiles), movers (region 0 st).
send({"t": "sub", "c": [[0, 0]]})
tick(4)
take()
lua.execute("""
settings.global["f3d-bytes-per-tick"].value = 512
local tr = package.loaded["scripts.transport"]
local big_tiles = {}
for j = 1, 512 do
  big_tiles[#big_tiles + 1] = 1
  big_tiles[#big_tiles + 1] = 2
end
for i = 1, 5 do
  tr.send_reliable({ t = "chunk", cx = 5, cy = i, tiles = big_tiles, parts = 1, rs = 1, rv = i, n = 0 }, "5," .. i)
end
""")
tg_prio = spawn("tile-ghost", 4.5, 4.5, force="player", inner_name="stone-path")
send({"t": "tile_mine", "x": fixed(4.5), "y": fixed(4.5)})
am_prio = spawn("assembling-machine-1", 6.5, 6.5, force="player")
am_prio.set_recipe("iron-gear-wheel")
g.package.loaded["scripts.alt_mode"].check(am_prio, None)
send({"t": "cmd", "id": 77, "text": "/f3d-status"})
g.package.loaded["scripts.world"].tiles_changed(F.surface, lua.table_from([lua.table_from({"x": 3, "y": 3})]))
tick(1)
caller_msgs = take()
caller_types = [m.get("t") for m in caller_msgs]
check(all(tp in caller_types for tp in ("del", "aiu", "cmdr", "tiles")),
      f"priority callers (tile_mine del, alt_mode aiu, console cmdr, world.tiles_changed tiles) jump bulk backlog: {caller_types}")
am_prio.destroy()
while g.storage.f3d.outbox_head <= g.storage.f3d.outbox_tail:
    tick(1)
    take()
lua.execute('settings.global["f3d-bytes-per-tick"].value = 131072')

# send_dirty_decoratives with prio_queue ON queues into dec_queue instead of uncapped immediate send:
say(b=1, dc=1)
send({"t": "sub", "c": [[0, 0], [1, 0]]})
tick(10)
take()
F.add_decorative(F.surface, "small-rock", 5, 5, 1)
F.add_decorative(F.surface, "small-rock", 37, 5, 1)
while int(g.game.tick) % 30 != 29:
    tick(1)
    take()
lua.execute("""
local s = storage.f3d
s.dec_dirty = { ["0,0"] = true, ["1,0"] = true }
package.loaded["scripts.world"].enqueue("0,0")
""")
tick(1)
dec_wait_msgs = take()
check(len(g.storage.f3d.dec_queue or {}) == 2 and not of_type(dec_wait_msgs, "dec"),
      f"dec_dirty with prio_queue: dirty decoratives defer into dec_queue while chunk snapshots drain: dec_q={len(g.storage.f3d.dec_queue or {})}, msgs={[m['t'] for m in dec_wait_msgs]}")
tick(6)
dec_after = take()
dec_after_types = [m.get("t") for m in dec_after]
check("chunk" in dec_after_types and "dec" in dec_after_types and dec_after_types.index("chunk") < dec_after_types.index("dec"),
      f"dec_dirty with prio_queue: queued decoratives drain after chunk snapshots finish: {dec_after_types}")

# C. near_first (inserters <= 12 tiles, robots <= 48 tiles + NEAR_SCAN_TICKS = 4):
send({"t": "bye"})
tick(1)
send({"t": "hello", "v": 1, "sid": "resp-near", "w": 0, "z": 0, "b": 1, "ie": 1, "rb": 1, **({"bin": protocol.WIRE_VERSION} if BINARY else {})})
tick(10)
take()
g.settings["global"]["f3d-max-focus-radius"] = lua.table_from({"value": 128})
g.settings["global"]["f3d-detail-radius"] = lua.table_from({"value": 24})
send({"t": "focus", "x": 0, "y": 0, "r": 128})
tick(1)
take()

ins_mod = g.package.loaded["scripts.inserters"]
ins_near, ins_outer = [], []
# Put 55 outer inserters inside detail-radius=24 (>12) in chunk (-1, -1) so look_over discovers them BEFORE near inserters in (0, 0).
for idx in range(55):
    e = spawn("inserter", -22.5 + (idx % 9), -22.5 + (idx // 9), force="player")
    ins_outer.append(e)
for idx in range(10):
    e = spawn("inserter", 1.5 + idx, 1.5, force="player")
    ins_near.append(e)
ins_near_ids = {int(e.unit_number) for e in ins_near}
def run_inserter_budget_race(nf_on):
    # Align so look_over runs on an even tick and due[now] fires on the next (odd) ie tick.
    while int(g.game.tick) % 2 != 1:
        tick(1)
    take()
    set_perf(near_first=nf_on)
    ins_mod.reset()
    ins_mod.counts.carried = 0
    tick(1)  # look_over scans (-1,-1) then (0,0), scheduling all 65 for now+1 (odd tick)
    take()
    tick(1)  # due[now] runs all 65 against O.budget=48 and emits ie on this odd tick
    msgs_due = take()
    return {
        row[1]
        for m in of_type(msgs_due, "ie")
        for row in ([m["l"][i:i + 9] for i in range(0, len(m["l"]), 9)])
    }
ie_near_on = run_inserter_budget_race(True)
carried_on = int(ins_mod.counts.carried)
ie_near_off = run_inserter_budget_race(False)
check(ins_near_ids <= ie_near_on and carried_on > 0,
      f"near_first inserters (on): all {len(ins_near_ids)} near inserters checked on tick 1 despite budget carryover (got {len(ins_near_ids & ie_near_on)}, carried={carried_on})")
check(len(ie_near_off & ins_near_ids) == 0,
      f"near_first inserters (off): outer inserters ahead in due[] starve near inserters ({len(ins_near_ids & ie_near_off)}/{len(ins_near_ids)})")
set_perf()
for e in ins_outer + ins_near:
    e.destroy()
ins_mod.reset()
tick(1)
take()

# robots.lua near_first: > MAX_CHECKS (250) due robots prioritize <=48 ahead of outer, and NEAR_SCAN_TICKS catches new near robot.
rb_outer, rb_near = [], []
for idx in range(260):
    rb_outer.append(spawn("construction-robot", 60.0 + (idx % 20) * 2.0, 60.0 + (idx // 20) * 2.0, force="player"))
for idx in range(15):
    rb_near.append(spawn("construction-robot", 2.0 + (idx % 5) * 2.0, 2.0 + (idx // 5) * 2.0, force="player"))
rb_near_ids = {int(e.unit_number) for e in rb_near}
rb_mod = g.package.loaded["scripts.robots"]
rb_mod.reset()
set_perf(near_first=True)
# Run full 8-strip sweep so all 275 robots are tracked (16 ticks), then reach 60-tick mod cache boundary.
tick(60)
take()
# Force all 275 robots due at once by changing worker_robots_speed_modifier!
g.game.forces["player"].worker_robots_speed_modifier = 0.25
tick(1)
rb_t1_on = of_type(take(), "rb")
rb_on_units = {m["u"][i] for m in rb_t1_on for i in range(0, len(m.get("u", [])), 11)}
check(rb_near_ids <= rb_on_units,
      f"near_first robots (on): all {len(rb_near_ids)} near robots checked & sent ahead of >250 outer backlog (got {len(rb_near_ids & rb_on_units)})")
tick(2)
take()
set_perf(near_first=False, robot_opt=False)
g.game.forces["player"].worker_robots_speed_modifier = 0.50
tick(1)
rb_t1_off = of_type(take(), "rb")
rb_off_units = {m["u"][i] for m in rb_t1_off for i in range(0, len(m.get("u", [])), 11)}
check(len(rb_off_units) == 250 and len(rb_near_ids & rb_off_units) < len(rb_near_ids),
      f"near_first robots (off): runs unprioritized MAX_CHECKS=250 loop (got {len(rb_off_units)}, near={len(rb_near_ids & rb_off_units)})")
# NEAR_SCAN_OPT=8 (robot_opt on): detects new <=48 near robot within 8-9 ticks (vs 32t full sweep).
set_perf(near_first=True)
rb_mod.reset()
tick(18)
take()
rb_fresh = spawn("construction-robot", 4.5, 4.5, force="player")
fresh_seen = False
for _ in range(9):
    tick(1)
    for m in of_type(take(), "rb"):
        u = m.get("u", [])
        if any(u[i] == int(rb_fresh.unit_number) for i in range(0, len(u), 11)):
            fresh_seen = True
check(fresh_seen, "near_first robots: NEAR_SCAN_OPT=8 detects new <=48 near robot within 8-9 ticks")
rb_fresh.destroy()
# NEAR_SCAN_TICKS=4 (robot_opt off): detects new <=48 near robot within 4-5 ticks.
set_perf(near_first=True, robot_opt=False)
rb_mod.reset()
tick(18)
take()
rb_fresh_off = spawn("construction-robot", 4.5, 4.5, force="player")
fresh_seen_off = False
for _ in range(5):
    tick(1)
    for m in of_type(take(), "rb"):
        u = m.get("u", [])
        if any(u[i] == int(rb_fresh_off.unit_number) for i in range(0, len(u), 11)):
            fresh_seen_off = True
check(fresh_seen_off, "near_first robots (robot_opt off): NEAR_SCAN_TICKS=4 detects new <=48 near robot within 4-5 ticks")
rb_fresh_off.destroy()
for e in rb_outer + rb_near:
    e.destroy()
g.game.forces["player"].worker_robots_speed_modifier = 0.0
rb_mod.reset()
set_perf()
tick(2)
take()

# D. near_rate (budget.can floor, rate.due_near/period_near, states_near region 0, movers near scan, inserters ie, world chunk floor):
budget_mod = g.package.loaded["scripts.budget"]
rate_mod = g.package.loaded["scripts.rate"]
budget_mod.begin()
g.storage.f3d_budget = g.storage.f3d_budget
lua.execute("""
local b = storage.f3d
-- Force budget.limit to 60 via budget packet then spend 30 on chunks.
""")
send({"t": "budget", "u": 60})
tick(1)
take()
budget_check = lua.eval("""function()
  local B = package.loaded["scripts.budget"]
  B.begin()
  B.spend(30, "chunks")
  storage.f3d_perf = { near_rate = true }
  local on_can = B.can(40, "chunks", 0.5, 150)
  local used_after = storage.f3d.bud.used
  storage.f3d_perf = { near_rate = false }
  local off_can = B.can(40, "chunks", 0.5, 150)
  storage.f3d_perf = nil
  return { on_can, off_can, used_after }
end""")()
check(budget_check[1] is True and budget_check[2] is False and budget_check[3] == 30,
      f"near_rate budget.can floor: on={budget_check[1]}, off={budget_check[2]}, used_unchanged={budget_check[3]}")

g.storage.f3d.rate = 3
set_perf(near_rate=True)
check(rate_mod.period_near("st", 30) == 30 and rate_mod.period("st", 30) == 120
      and rate_mod.crossed("nonexistent_job", 300) is False,
      f"near_rate rate.period_near keeps level-0 cadence ({rate_mod.period_near('st', 30)}) while period slows ({rate_mod.period('st', 30)})")
set_perf(near_rate=False)
check(rate_mod.period_near("st", 30) == 120,
      f"near_rate off: period_near falls back to slowed period ({rate_mod.period_near('st', 30)})")
set_perf()
g.storage.f3d.rate = None

# states_near region 0 stays at 30t while FAR_STRIPS slow to 120t independently, + movers NEAR_MOVER_RADIUS=48 near scan + mv_scan.n>150 uncapping + inserters ie cadence:
send({"t": "focus", "x": 0, "y": 0, "r": 128})
send({"t": "rate", "l": 3})
near_am = spawn("assembling-machine-1", 4.5, 4.5, force="player")
far_am = spawn("assembling-machine-1", 100.5, 4.5, force="player")
st_near_n, st_far_n = 0, 0
for step_i in range(125):
    near_am.status = g.defines.entity_status.working if (step_i // 10) % 2 == 0 else g.defines.entity_status.no_power
    far_am.status = g.defines.entity_status.working if (step_i // 10) % 2 == 0 else g.defines.entity_status.no_power
    tick(1)
    for m in of_type(take(), "st"):
        lst = m.get("l", [])
        for j in range(0, len(lst), 2):
            if lst[j] == int(near_am.unit_number):
                st_near_n += 1
            elif lst[j] == int(far_am.unit_number):
                st_far_n += 1
check(st_near_n >= 3 and st_far_n <= 2,
      f"near_rate states_near: near st fires ~every 30t ({st_near_n}) while far strip slows to ~120t ({st_far_n})")
near_am.destroy()
far_am.destroy()

# movers near scan: with f3d-mover-rescan=32 and rate=3 (256t full scan backoff), new <=48 unitless mover is found within SCAN_TICKS=8.
g.settings["global"]["f3d-mover-rescan"] = lua.table_from({"value": 32})
g.storage.f3d.mv_scan = None
tick(10)
take()
rk_near = spawn("rocket-silo-rocket", 6.5, 6.5, force="player")
rk_found_early = False
for _ in range(10):
    tick(1)
    for m in of_type(take(), "mv"):
        if any(rec[0] > 2 ** 40 for rec in m.get("l", [])):
            rk_found_early = True
check(rk_found_early and F.registered[rk_near] is not None,
      f"near_rate movers: NEAR_MOVER_RADIUS=48 scan finds & registers unitless mover within 10 ticks during full-scan backoff (reg={F.registered[rk_near]})")
# Regression: post-load scan recovery (scan.ids = {}) followed by near_rate merge must not duplicate unitless movers,
# and must refresh module-local scan.by when one_search is on without mutating storage.f3d.mv_scan.kinds.
cp_near_os = spawn("cargo-pod", 5.5, 5.5, force="player")
g.storage.f3d.mv_scan = None
for _ in range(8):
    tick(1)
    take()
    if g.storage.f3d.mv_scan is not None:
        break
check(g.storage.f3d.mv_scan is not None, "near_rate movers post-load setup: full scan populated mv_scan")
kinds_cp_before = int(lua.eval('storage.f3d.mv_scan.kinds and storage.f3d.mv_scan.kinds.cp or 0'))
movers_mod = g.package.loaded["scripts.movers"]
movers_scans_tbl = lua.eval("""(function()
  local function find_uv(fn, name, depth)
    for i = 1, 255 do
      local n, v = debug.getupvalue(fn, i)
      if not n then return nil end
      if n == name and type(v) == "table" then return v end
      if type(v) == "function" and depth > 0 then
        local r = find_uv(v, name, depth - 1)
        if r then return r end
      end
    end
    return nil
  end
  return find_uv(package.loaded["scripts.movers"].tick, "scans", 4)
end)()""")
check(movers_scans_tbl is not None, "near_rate movers post-load: module-local scans table found")
if movers_scans_tbl is not None:
    lua.eval("function(t) for k in pairs(t) do t[k] = nil end end")(movers_scans_tbl)
for _ in range(6):
    tick(1)
    take()
    if movers_scans_tbl[g.storage.f3d] is not None:
        break
check(movers_scans_tbl[g.storage.f3d] is not None, "near_rate movers post-load: rebuilt post-load scan with empty ids")
cp_near_new = spawn("cargo-pod", 4.5, 4.5, force="player")
rk_uid = 2 ** 40 + int(F.registered[rk_near])
rk_mv_ids = []
for _ in range(12):
    tick(1)
    mvs = of_type(take(), "mv")
    if mvs and int(g.game.tick) - int(g.storage.f3d.mv_scan.tick) >= 8:
        for m in mvs:
            for rec in m.get("l", []):
                if rec[0] == rk_uid:
                    rk_mv_ids.append(rec[0])
        break
scan_rk_count = int(lua.eval("""(function(scans, rk)
  local sc = scans[storage.f3d]
  local c = 0
  for _, e in pairs(sc and sc.list or {}) do
    if e == rk then c = c + 1 end
  end
  return c
end)""")(movers_scans_tbl, rk_near))
found_cp_list, _ = movers_mod.found("cp", g.game.surfaces[1])
found_cp_units = {int(e.unit_number) for e in found_cp_list.values()} if found_cp_list else set()
kinds_cp_after = int(lua.eval('storage.f3d.mv_scan.kinds and storage.f3d.mv_scan.kinds.cp or 0'))
check(scan_rk_count == 1 and len(rk_mv_ids) == 1,
      f"near_rate movers post-load: unitless mover is not duplicated in scan.list ({scan_rk_count}) or mv ({len(rk_mv_ids)})")
check(int(cp_near_new.unit_number) in found_cp_units and kinds_cp_after == kinds_cp_before,
      f"near_rate movers post-load: refreshes module-local scan.by for one_search ({found_cp_units}) without mutating storage kinds ({kinds_cp_before}->{kinds_cp_after})")
cp_near_os.destroy()
cp_near_new.destroy()
rk_near.destroy()
g.settings["global"]["f3d-mover-rescan"] = lua.table_from({"value": 8})

# movers >150 count uncaps mv period at rate=3:
tick(170)
take()
if g.storage.f3d.mv_scan:
    g.storage.f3d.mv_scan.n = 200
    g.storage.f3d.mv_scan.tick = int(g.game.tick)
tick(40)
big_mv_ps = {m.get("p") for m in of_type(take(), "mv")}
check(big_mv_ps == {16}, f"near_rate movers >150: mv_cap lifts so rate 3 uses p=16 (got {big_mv_ps})")

# inserters ie under rate=3: every 2 ticks when near_rate=True vs 4 when False (window=8 via O.repeat=4).
ie_rate_ins = spawn("inserter", 3.5, 3.5, force="player")
F.commands["f3d-ih"](lua.table_from({"name": "f3d-ih", "parameter": "repeat 4"}))
def ie_cadence(nr_on):
    set_perf(near_rate=nr_on)
    ins_mod.reset()
    ks_ie = []
    for _ in range(10):
        tick(1)
        for m in of_type(take(), "ie"):
            if m.get("l"):
                ks_ie.append(m["k"])
    ks_ie = sorted(set(ks_ie))
    return {b - a for a, b in zip(ks_ie, ks_ie[1:])}
ie_gaps_on = ie_cadence(True)
ie_gaps_off = ie_cadence(False)
check(ie_gaps_on == {2} and ie_gaps_off == {4},
      f"near_rate inserters ie: rate=3 keeps O.every=2 ({ie_gaps_on}) when on vs slowed ({ie_gaps_off}) when off")
F.commands["f3d-ih"](lua.table_from({"name": "f3d-ih", "parameter": "repeat default"}))
ie_rate_ins.destroy()
ins_mod.reset()
set_perf()
send({"t": "rate", "l": 0})
send({"t": "budget", "u": 2000})
g.settings["global"]["f3d-max-focus-radius"] = lua.table_from({"value": 64})
tick(5)
take()

# world.lua near chunk floor: under budget=60, near chunk (0,0) with entities advances faster with near_rate=True than False.
def near_chunk_ticks(nr_on):
    set_perf(near_rate=nr_on)
    send({"t": "bye"})
    tick(1)
    send({"t": "hello", "v": 1, "sid": f"nr-ch-{nr_on}", "w": 0, "z": 1, "b": 1, **({"bin": protocol.WIRE_VERSION} if BINARY else {})})
    tick(8)
    take()
    send({"t": "budget", "u": 60})
    send({"t": "sub", "c": [[0, 0]]})
    for t_c in range(1, 30):
        tick(1)
        if any(m.get("t") == "chunk" and m.get("cx") == 0 for m in take()):
            return t_c
    return 999
nr_chests = [spawn("wooden-chest", 1.5 + (i % 10), 1.5 + (i // 10), force="player") for i in range(40)]
# Force budget tight enough that strips/records slice cleanly:
lua.execute('package.loaded["scripts.budget"].spend(0, "chunks")')
t_nr_on = near_chunk_ticks(True)
t_nr_off = near_chunk_ticks(False)
check(t_nr_on <= t_nr_off and t_nr_on < 30,
      f"near_rate world chunk floor: near chunk (0,0) under budget=60 completes in {t_nr_on}t (on) vs {t_nr_off}t (off)")
for ch_e in nr_chests:
    ch_e.destroy()
set_perf()
send({"t": "budget", "u": 2000})
tick(2)
take()

# E. belt_sim near_spool (on & off, + multi-part near-first packing):
bs_mod = g.package.loaded["scripts.belt_sim"]
send({"t": "bye"})
tick(1)
g.settings["global"]["f3d-max-focus-radius"] = lua.table_from({"value": 160})
g.settings["global"]["f3d-detail-radius"] = lua.table_from({"value": 160})
send({"t": "hello", "v": 1, "sid": "resp-bs", "w": 0, "z": 0, "b": 1, "bs": 1, **({"bin": protocol.WIRE_VERSION} if BINARY else {})})
tick(8)
take()
send({"t": "focus", "x": 0, "y": 0, "r": 160})
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "send_cap 200"}))
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "walk_load 100000"}))
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "near_spool on"}))
bs_outer_belts = []
for idx in range(65):
    b_e = spawn("transport-belt", 105.5 + (idx % 32), 4.5 + (idx // 32) * 2.0, force="player", direction=4)
    F.put_on_belt(b_e, 1, "iron-plate", 0.3, 95000 + idx)
    bs_outer_belts.append(b_e)
bs_near_belt = spawn("transport-belt", 2.5, 2.5, force="player", direction=4)
F.put_on_belt(bs_near_belt, 1, "copper-plate", 0.4, 96000)
bs_mod.reset()
# Wait for first multi-part `bs` where part 1 packs near belt ahead of outer belts:
multi_bs = []
for _ in range(30):
    tick(1)
    for m in of_type(take(), "bs"):
        multi_bs.append(m)
    if any(m.get("parts", 1) >= 2 and int(bs_near_belt.unit_number) * 8 + 1 in m.get("lm", []) for m in multi_bs):
        break
near_in_p1 = any(m.get("part") == 1 and m.get("parts", 1) >= 2
                 and int(bs_near_belt.unit_number) * 8 + 1 in m.get("lm", []) for m in multi_bs)
check(near_in_p1, f"near_spool multi-part emit: packs near belt into part 1 ahead of outer parts ({len(multi_bs)} msgs)")

# Ensure spool has >=2 parts of an in-progress multi-part update (head part > 1) queued on a non-due tick:
for _ in range(40):
    if bs_mod.spooled() >= 2 and int(g.game.tick + 1) % 6 != 1:
        break
    if bs_mod.spooled() == 0 and int(g.game.tick + 1) % 6 != 1:
        bs_mod.reset()
    tick(1)
    take()
check(bs_mod.spooled() >= 2 and int(g.game.tick + 1) % 6 != 1,
      f"near_spool setup: spool={bs_mod.spooled()}, next_tick_mod6={(int(g.game.tick) + 1) % 6}")
head_k, head_part, head_parts = lua.eval("""(function()
  local bs = package.loaded["scripts.belt_sim"]
  for i = 1, 255 do
    local n, v = debug.getupvalue(bs.spooled, i)
    if not n then break end
    if n == "spool" and v[1] then
      return v[1][4], v[1][2], v[1][5][1]
    end
  end
  return 0, 0, 0
end)()""")
check(int(head_part) > 1 and int(head_parts) >= 2,
      f"near_spool in-progress setup: spool[1] has part={head_part}/{head_parts} for k={head_k}")
# Queue a synthetic unstarted multi-part update behind the in-progress head so we verify live delta
# inserts strictly between the in-progress head and any later unstarted update:
lua.execute("""
  local bs = package.loaded["scripts.belt_sim"]
  for i = 1, 255 do
    local n, v = debug.getupvalue(bs.spooled, i)
    if not n then break end
    if n == "spool" then
      local tail = v[#v]
      local fk = tail[4] + 100
      for p = 1, 2 do
        v[#v + 1] = { ',"parts":2,"p":6,"w":0,"fx":0,"fy":0,"fr":160', p, { lm = {}, sl = {}, qu = {}, pc = {}, pu = {}, dl = {}, of = {}, ew = {}, sh = {}, sx = {} }, fk, { 2, 6, 0, 0, 0, 160, 0 } }
      end
      break
    end
  end
""")
bs_near_belt.direction = 8
F["raise"]("on_player_rotated_entity", lua.table_from({"entity": bs_near_belt, "previous_direction": 4}))
near_k_expected = int(g.game.tick) + 1
bs_seq = []
for _ in range(15):
    tick(1)
    bs_seq.extend(of_type(take(), "bs"))
    if any(int(bs_near_belt.unit_number) * 8 + 1 in m.get("lm", []) for m in bs_seq):
        break
k0_parts = [m.get("part", 1) for m in bs_seq if m.get("k") == int(head_k)]
# Check contiguity of head_k's remaining parts before near_k_expected (and before fk = head_k + 100):
seq_ks = [m.get("k") for m in bs_seq]
last_k0_idx = max(idx for idx, k in enumerate(seq_ks) if k == int(head_k))
first_live_idx = next(idx for idx, m in enumerate(bs_seq) if int(bs_near_belt.unit_number) * 8 + 1 in m.get("lm", []))
has_fk_before_live = any(m.get("k") == int(head_k) + 100 for m in bs_seq[:first_live_idx])
check(k0_parts == list(range(int(head_part), int(head_parts) + 1))
      and first_live_idx > last_k0_idx
      and not has_fk_before_live
      and bs_seq[first_live_idx].get("k") == near_k_expected,
      f"near_spool on (in-progress head): completes k={head_k} parts {k0_parts} contiguously before live k={near_k_expected} and sends live ahead of queued unstarted update (order={seq_ks})")

# When spool head is an unstarted update (part == 1), non-due built_now jumps to spool[1] and sends on the same tick:
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "send_cap 30000"}))
tick(12)
take()
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "send_cap 200"}))
while int(g.game.tick + 1) % 6 == 1:
    tick(1)
    take()
lua.execute("""
  local bs = package.loaded["scripts.belt_sim"]
  for i = 1, 255 do
    local n, v = debug.getupvalue(bs.spooled, i)
    if not n then break end
    if n == "spool" then
      local fk = game.tick + 200
      for p = 1, 2 do
        v[#v + 1] = { ',"parts":2,"p":6,"w":0,"fx":0,"fy":0,"fr":160', p, { lm = {}, sl = {}, qu = {}, pc = {}, pu = {}, dl = {}, of = {}, ew = {}, sh = {}, sx = {} }, fk, { 2, 6, 0, 0, 0, 160, 0 } }
      end
      break
    end
  end
""")
bs_near_belt.direction = 12
F["raise"]("on_player_rotated_entity", lua.table_from({"entity": bs_near_belt, "previous_direction": 8}))
tick(1)
bs_unstarted_t1 = of_type(take(), "bs")
check(any(int(bs_near_belt.unit_number) * 8 + 1 in m.get("lm", []) for m in bs_unstarted_t1),
      f"near_spool on (unstarted head part=1): non-due built_now jumps ahead of spool and sends on same tick ({[m.get('k') for m in bs_unstarted_t1]})")

# Regression: non-due built_now preserves fr_now = loaded_edge(b) without clamping to sc_now.near under area=trace:
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "send_cap 30000"}))
tick(12)
take()
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "area trace"}))
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "trace_near 16"}))
bs_mod.reset()
for _ in range(15):
    tick(1)
    take()
    if int(g.game.tick + 1) % 6 != 1 and bs_mod.spooled() == 0:
        loaded_ok = lua.eval("""(function()
          local bs = storage.f3d and storage.f3d.bs
          return bs and bs.scan and bs.scan.near == 16 and bs.scan.r > 16 and bs.belts and next(bs.belts) ~= nil
        end)()""")
        if loaded_ok:
            break
expected_fr = int(lua.eval("storage.f3d.bs.scan.r"))
bs_near_belt.direction = 4
F["raise"]("on_player_rotated_entity", lua.table_from({"entity": bs_near_belt, "previous_direction": 12}))
tick(1)
bs_trace_t1 = of_type(take(), "bs")
live_trace = [m for m in bs_trace_t1 if int(bs_near_belt.unit_number) * 8 + 1 in m.get("lm", [])]
check(bool(live_trace) and expected_fr > 16 and live_trace[0].get("fr") == expected_fr,
      f"near_spool fr_now: preserves true loaded_edge(b)={expected_fr} under area=trace without clamping to sc.near=16: {live_trace}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "area default"}))
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "trace_near default"}))

# Drain spool then reset so spool fills with >=2 outer parts, and repeat with near_spool=off:
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "send_cap 30000"}))
tick(12)
take()
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "send_cap 200"}))
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "near_spool off"}))
bs_mod.reset()
for _ in range(40):
    if bs_mod.spooled() >= 2 and int(g.game.tick + 1) % 6 != 1:
        break
    tick(1)
    take()
bs_near_belt.direction = 0
F["raise"]("on_player_rotated_entity", lua.table_from({"entity": bs_near_belt, "previous_direction": 4}))
tick(1)
bs_off_t1 = of_type(take(), "bs")
has_near_lm_off = any(int(bs_near_belt.unit_number) * 8 + 1 in m.get("lm", []) for m in bs_off_t1)
check(not has_near_lm_off,
      f"near_spool off: non-due belt edit does not jump ahead of spool ({len(bs_off_t1)} parts)")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "near_spool default"}))
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "send_cap default"}))
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "walk_load default"}))
for b_e in bs_outer_belts:
    b_e.destroy()
bs_near_belt.destroy()
bs_mod.reset()
g.settings["global"]["f3d-detail-radius"] = lua.table_from({"value": 24})
g.settings["global"]["f3d-max-focus-radius"] = lua.table_from({"value": 64})
tick(2)
take()

# F. nack_ring (hit preserving r & storage determinism, binary frame hit, cold/aged-out miss determinism + resync recovery, nack_ring=false fallback):
def take_raw():
    g.package.loaded["scripts.transport"].end_tick()
    out_raw = []
    for item in F.take_sent().values():
        data = sent_data(item)
        out_raw.extend(protocol.split_datagram(data))
    return out_raw

nack_storage_fp = lua.eval("""function()
  local out = {}
  local function walk(v, seen)
    if type(v) ~= "table" then
      out[#out + 1] = type(v) .. ":" .. tostring(v)
      return
    end
    if seen[v] then
      out[#out + 1] = "ref:" .. seen[v]
      return
    end
    seen.n = (seen.n or 0) + 1
    seen[v] = seen.n
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return type(a) .. tostring(a) < type(b) .. tostring(b) end)
    out[#out + 1] = "{"
    for _, k in ipairs(keys) do
      walk(k, seen)
      out[#out + 1] = "="
      walk(v[k], seen)
    end
    out[#out + 1] = "}"
  end
  walk(storage, {})
  return table.concat(out, ",")
end""")

send({"t": "bye"})
tick(1)
send({"t": "hello", "v": 1, "sid": "resp-nack", "w": 0, "z": 1, "b": 1, **({"bin": protocol.WIRE_VERSION} if BINARY else {})})
tick(10)
take()
send({"t": "sub", "c": [[0, 0]]})
tick(5)
sub_nack_msgs = take()
chunk_r = next((int(m["r"]) for m in sub_nack_msgs if m.get("t") == "chunk" and m.get("cx") == 0 and m.get("cy") == 0), None)
lua.execute("""
local tr = package.loaded["scripts.transport"]
for idx = 1, 10 do
  tr.send_reliable({ t = "inv", l = { { "iron-plate", 500 + idx } } })
end
""")
tick(1)
nack_batch = take()
inv_batch = [m for m in nack_batch if m.get("t") == "inv" and m.get("l") == [["iron-plate", 505]]]
check(bool(inv_batch) and chunk_r is not None, f"nack_ring setup sent target reliable inv & chunk: {inv_batch}, chunk_r={chunk_r}")
target_r = int(inv_batch[0]["r"])
rseq_before = int(g.storage.f3d.rseq)
queued_before = int(g.package.loaded["scripts.world"].queued_count())
set_perf(nack_ring=True)
fp_before_nack = nack_storage_fp()
nack_req = [target_r] + ([chunk_r] if BINARY and chunk_r is not None else [])
send({"t": "nack", "r": nack_req, "c": [[0, 0]]})
fp_warm_nack = nack_storage_fp()
replay_msgs = take_raw()
check(any(m.get("r") == target_r and m.get("l") == [["iron-plate", 505]] for m in replay_msgs)
      and (not BINARY or any(m.get("r") == chunk_r and m.get("t") == "chunk" for m in replay_msgs))
      and int(g.storage.f3d.rseq) == rseq_before
      and int(g.package.loaded["scripts.world"].queued_count()) == queued_before
      and fp_warm_nack == fp_before_nack,
      f"nack_ring hit: replayed exact r={nack_req} without advancing rseq ({rseq_before}->{g.storage.f3d.rseq}), resending chunks, or altering storage: {replay_msgs}")

# Multiplayer determinism: clearing module-local ring simulates a cold peer after save/load.
# handlers.nack must keep storage identical between warm (hit) and cold (miss) peers, never calling world.resend on miss.
forgot_ring = lua.eval("""function()
  local tr = package.loaded["scripts.transport"]
  for i = 1, 255 do
    local n, v = debug.getupvalue(tr.retransmit, i)
    if not n then return false end
    if n == "nack_rings" and type(v) == "table" then
      for k in pairs(v) do v[k] = nil end
      return true
    end
  end
  return false
end""")()
check(forgot_ring, "nack_ring: module-local nack_rings table can be cleared (save/load peer simulation)")
send({"t": "nack", "r": [target_r], "c": [[0, 0]]})
fp_cold_nack = nack_storage_fp()
cold_peer_raw = take_raw()
tick(4)
cold_peer_chunks = take()
check(not cold_peer_raw
      and fp_cold_nack == fp_warm_nack
      and int(g.package.loaded["scripts.world"].queued_count()) == queued_before
      and not any(m.get("t") == "chunk" and m.get("cx") == 0 and m.get("cy") == 0 for m in cold_peer_chunks),
      f"nack_ring cold peer determinism: empty ring matches populated ring storage snapshot without calling world.resend([0,0]): raw={cold_peer_raw}, chunks={[m['t'] for m in cold_peer_chunks]}")

# Aged-out miss (>256 frames pushed later) with nack_ring on does not replay and does not mutate storage;
# client timeout resync recovers the chunk deterministically:
lua.execute("""
local tr = package.loaded["scripts.transport"]
for idx = 1, 270 do
  tr.send_reliable({ t = "inv", l = { { "copper-plate", idx } } })
end
""")
for _ in range(15):
    tick(1)
    aged_msgs = take()
    if g.storage.f3d.outbox_head > g.storage.f3d.outbox_tail:
        break
recent_r = int(g.storage.f3d.rseq) - 2
fp_before_aged = nack_storage_fp()
send({"t": "nack", "r": [target_r], "c": [[0, 0]]})
fp_after_aged = nack_storage_fp()
aged_raw = take_raw()
tick(4)
aged_chunks = take()
check(not any(m.get("r") == target_r for m in aged_raw)
      and fp_after_aged == fp_before_aged
      and not any(m.get("t") == "chunk" and m.get("cx") == 0 and m.get("cy") == 0 for m in aged_chunks),
      f"nack_ring aged-out miss (>256): does not replay r={target_r} and keeps storage deterministic (no world.resend from nack)")
send({"t": "resync", "c": [[0, 0]]})
tick(4)
resync_chunks = take()
check(any(m.get("t") == "chunk" and m.get("cx") == 0 and m.get("cy") == 0 for m in resync_chunks),
      f"nack_ring aged-out recovery: client resync deterministically resends chunk (0,0)")

# nack_ring=false fallback: even recent r inside ring skips replay and falls back to world.resend(c).
set_perf(nack_ring=False)
send({"t": "nack", "r": [recent_r], "c": [[0, 0]]})
off_raw = take_raw()
tick(4)
off_chunks = take()
check(not any(m.get("r") == recent_r for m in off_raw)
      and any(m.get("t") == "chunk" and m.get("cx") == 0 and m.get("cy") == 0 for m in off_chunks),
      f"nack_ring off: recent r={recent_r} skips ring and triggers world.resend([0,0])")
set_perf()

# --- Main-bus UPS round (/f3d-bs & /f3d-perf switches) ----------------------------------------
# Re-bind module handles in the current LuaRuntime (fresh_world() at L12242 created a new VM)
# and connect a client with belt simulation (bs=1) enabled.
ups_perf_mod = g.package.loaded["scripts.perf"]
lua.execute("""
function F_ups_forget(fn, name, depth)
  depth = depth or 4
  for i = 1, 255 do
    local n, v = debug.getupvalue(fn, i)
    if not n then return false end
    if n == name then
      debug.setupvalue(fn, i, type(v) == "table" and {} or nil)
      return true
    end
    if type(v) == "function" and depth > 0 and F_ups_forget(v, name, depth - 1) then
      return true
    end
  end
  return false
end
""")
send({"t": "bye"})
tick(1)
say(bs=1, ie=1, b=1)
tick(2)
take()

# Verify all new switches appear in command listings (default ON) and can be toggled cleanly.
ups_perf_cmd = str(ups_perf_mod.command("")[1])
for sw in ("mover_move_scan", "st_working_slice", "splitter_throttle",
           "inserter_look_budget", "fluids_budget", "alt_cadence", "robot_opt"):
    check(f"{sw} on" in ups_perf_cmd, f"/f3d-perf lists {sw} on by default: {ups_perf_cmd}")
F.commands["f3d-perf"](lua.table_from({"name": "f3d-perf", "parameter": "alt_cadence off"}))
check("alt_cadence off (set)" in str(ups_perf_mod.command("")[1]), "/f3d-perf toggles alt_cadence off")
F.commands["f3d-perf"](lua.table_from({"name": "f3d-perf", "parameter": "alt_cadence default"}))
check("alt_cadence on" in str(ups_perf_mod.command("")[1]) and "(set)" not in str(ups_perf_mod.command("")[1]).split("alt_cadence on")[1][:10],
      "/f3d-perf restores alt_cadence default")

ups_bs_cmd = str(bs_mod.option_command("")[1])
for sw in ("scan_step_wide on", "scan_step_min 12", "drop_margin 16", "take_slice on", "load_budget on", "edge_budget on"):
    check(sw in ups_bs_cmd, f"/f3d-bs lists {sw}: {ups_bs_cmd}")

ups_cleanup = []
saved_ups_focus = (int(g.storage.f3d.focus.x), int(g.storage.f3d.focus.y), int(g.storage.f3d.focus.r))
saved_ups_bud_limit = int(g.storage.f3d.bud.limit)
saved_ups_rescan = int(g.settings["global"]["f3d-mover-rescan"].value)
saved_ups_mv_interval = int(g.settings["global"]["f3d-mover-interval"].value)
saved_ups_detail_r = int(g.settings["global"]["f3d-detail-radius"].value)
saved_ups_max_r = int(g.settings["global"]["f3d-max-focus-radius"].value)
g.settings["global"]["f3d-max-focus-radius"] = lua.table_from({"value": 128})
bs_mod.reset()
send({"t": "rate", "level": 0})
alive(2)
take()

# 1a. belt_sim scan_step_min + small bound_r clamping (min(max(1, bound_r/2), max(scan_step_min, r/12))):
bx0, by0 = 2400.5, 2400.5
ups_cleanup.extend([spawn("transport-belt", bx0, by0, force="player", direction=4),
                    spawn("transport-belt", bx0 + 1.0, by0, force="player", direction=4)])
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "scan_step_min 20"}))
send({"t": "focus", "x": fixed(bx0), "y": fixed(by0), "r": 64})
send({"t": "bfar", "r": 0, "n": 16, "m": 0})
# (Until the scan at this focus is taken: scan_incremental's flatten takes a tick or more of its own.)
for _ in range(120):
    alive(1)
    _bs = g.storage.f3d.bs
    if _bs and _bs.scanning is None and _bs.scan is not None and abs(float(_bs.scan.fx) - bx0) < 1:
        break
take()
sm0 = int(bs_mod.counts.scan_moved)
send({"t": "focus", "x": fixed(bx0 + 6), "y": fixed(by0), "r": 64})
alive(12)
sm1 = int(bs_mod.counts.scan_moved)
send({"t": "focus", "x": fixed(bx0 + 9), "y": fixed(by0), "r": 64})
for _ in range(30):
    alive(1)
    if int(bs_mod.counts.scan_moved) > sm0:
        break
sm2 = int(bs_mod.counts.scan_moved)
take()
check(sm1 == sm0 and sm2 == sm0 + 1,
      f"scan_step_min=20 clamped by bound_r/2=8 at r=16 (6t no scan, 9t scans): {sm0} {sm1} {sm2}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "scan_step_min default"}))

# 1b. scan_incremental (/f3d-bs, on): the square's scan flattened over ticks, into the arrays of the scan before last
# (b.spare), taken the tick after: the same belts in the same order and rings as the one-tick flatten (off), for a
# first scan and for one that reused a spare.
si_x, si_y = 2600.5, 2600.5
for k in range(40):
    ups_cleanup.append(spawn("transport-belt", si_x - 20 + k, si_y + (k % 7) - 3, force="player", direction=4))
def si_scan(x):
    send({"t": "focus", "x": fixed(x), "y": fixed(si_y), "r": 64})
    for _ in range(200):
        alive(1)
        _b = g.storage.f3d.bs
        if _b and _b.scanning is None and _b.scan is not None and abs(float(_b.scan.fx) - x) < 1:
            break
    take()
    sc = g.storage.f3d.bs.scan
    n = int(sc.n)
    return [(int(sc.units[j]), int(sc.rings[j])) for j in range(1, n + 1)], int(sc.idx[sc.units[1]]) if n else 0
bs_mod.reset()
si_on_a, _ = si_scan(si_x)
si_units_a = g.storage.f3d.bs.scan.units
si_on_b, si_idx_b = si_scan(si_x + 8)
si_on_c, _ = si_scan(si_x)
si_reused = bool(lua.eval("rawequal")(si_units_a, g.storage.f3d.bs.scan.units))
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "scan_incremental off"}))
bs_mod.reset()
si_off_a, _ = si_scan(si_x)
bs_mod.reset()
si_off_b, _ = si_scan(si_x + 8)
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "scan_incremental default"}))
check(len(si_on_a) >= 20 and len(si_on_b) >= 20 and si_on_a == si_off_a and si_on_b == si_off_b and si_idx_b == 1
      and si_on_c == si_off_a and si_reused,
      f"scan_incremental: same scan as the one-tick flatten, first and reusing a spare ({len(si_on_a)}, {len(si_on_b)} "
      f"belts; same {si_on_a == si_off_a}, {si_on_b == si_off_b}, {si_on_c == si_off_a}; spare reused {si_reused})")

# 1b. belt_sim drop_margin & take_slice (on vs off):
inner_belts = [spawn("transport-belt", bx0 + i, by0, force="player", direction=4) for i in range(10)]
outer_belts = [spawn("transport-belt", bx0 - 30.0, by0 - 10.0 + i, force="player", direction=4) for i in range(40)]
ups_cleanup.extend(inner_belts + outer_belts)
bs_mod.reset()
send({"t": "focus", "x": fixed(bx0), "y": fixed(by0), "r": 64})
send({"t": "bfar", "r": 0, "n": 32, "m": 0})
for _ in range(200):
    alive(1)
    if g.storage.f3d.bs.scanning is None and len(g.storage.f3d.bs.belts) >= 50:
        break
take()
outer_ids = {int(e.unit_number) for e in outer_belts}
loaded_ids = {int(u) for u in g.storage.f3d.bs.belts}
check(outer_ids <= loaded_ids, f"drop_margin setup: all 40 outer belts loaded ({len(outer_ids & loaded_ids)}/40)")

# Shift +14 tiles: outer belts are at dx=44 (>= sc.r=32, < sc.r + drop_margin=48) -> kept in margin ring.
send({"t": "focus", "x": fixed(bx0 + 14), "y": fixed(by0), "r": 64})
for _ in range(60):
    alive(1)
    if g.storage.f3d.bs.scanning is None and int(bs_mod.counts.scan_moved) > sm2:
        break
alive(6)
take()
kept_in_margin = outer_ids & {int(u) for u in g.storage.f3d.bs.belts}
check(len(kept_in_margin) == 40, f"drop_margin (on): belts at r..r+16 kept without dropping ({len(kept_in_margin)}/40)")

# Return to (bx0, by0), settle scan, then shift +18 tiles -> dx=48 >= 32+16 -> outer belts drop.
sc_ret0 = int(bs_mod.counts.scans)
send({"t": "focus", "x": fixed(bx0), "y": fixed(by0), "r": 64})
for _ in range(60):
    alive(1)
    if int(bs_mod.counts.scans) > sc_ret0 and g.storage.f3d.bs.scanning is None:
        break
take()
sc_drop0 = int(bs_mod.counts.scans)
send({"t": "focus", "x": fixed(bx0 + 18), "y": fixed(by0), "r": 64})
for _ in range(100):
    alive(1)
    if int(bs_mod.counts.scans) > sc_drop0 and g.storage.f3d.bs.scanning is None and g.storage.f3d.bs.drop_q is None:
        break
take()
after_margin_drop = outer_ids & {int(u) for u in g.storage.f3d.bs.belts}
check(len(after_margin_drop) == 0, f"drop_margin (on): belts >= r+16 drop cleanly ({len(after_margin_drop)} left)")

# Reload all 50 at (bx0, by0), add 1 entering belt at (bx0 + 38, by0), test take_slice ON vs OFF:
enter_belt = spawn("transport-belt", bx0 + 38.0, by0, force="player", direction=4)
ups_cleanup.append(enter_belt)
send({"t": "focus", "x": fixed(bx0), "y": fixed(by0), "r": 64})
for _ in range(160):
    alive(1)
    if g.storage.f3d.bs.scanning is None and g.storage.f3d.bs.drop_q is None and len(g.storage.f3d.bs.belts) >= 50:
        break
take()
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "drop_margin 0"}))
bs_mod.drop_slice = 8
bs_mod.load_cap = 0
ts0 = int(bs_mod.counts.take_slices or 0)
sc0 = int(bs_mod.counts.scans)
send({"t": "focus", "x": fixed(bx0 + 16), "y": fixed(by0), "r": 64})
for _ in range(60):
    alive(1)
    if int(bs_mod.counts.scans) > sc0:
        break
load_i_on = int(g.storage.f3d.bs.load_i)
drop_q_mid = g.storage.f3d.bs.drop_q is not None
bs_mod.load_cap = None
for _ in range(40):
    alive(1)
    if g.storage.f3d.bs.drop_q is None and g.storage.f3d.bs.prune is None:
        break
take()
ts_delta_on = int(bs_mod.counts.take_slices or 0) - ts0
check(load_i_on > 10 and drop_q_mid and ts_delta_on >= 4 and len(outer_ids & {int(u) for u in g.storage.f3d.bs.belts}) == 0,
      f"take_slice (on): load_i skips inner loaded belts ({load_i_on}>10), drops sliced ({ts_delta_on}>=4 ticks)")

# take_slice OFF: reload at (bx0, by0), move +16 -> drops synchronously in 1 tick and resets load_i = 1:
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "take_slice off"}))
send({"t": "focus", "x": fixed(bx0), "y": fixed(by0), "r": 64})
for _ in range(160):
    alive(1)
    if g.storage.f3d.bs.scanning is None and len(g.storage.f3d.bs.belts) >= 50:
        break
take()
bs_mod.load_cap = 0
ts1 = int(bs_mod.counts.take_slices or 0)
sc1 = int(bs_mod.counts.scans)
send({"t": "focus", "x": fixed(bx0 + 16), "y": fixed(by0), "r": 64})
for _ in range(60):
    alive(1)
    if int(bs_mod.counts.scans) > sc1:
        break
load_i_off = int(g.storage.f3d.bs.load_i)
drop_q_off = g.storage.f3d.bs.drop_q
bs_mod.load_cap = None
take()
ts_delta_off = int(bs_mod.counts.take_slices or 0) - ts1
check(load_i_off == 1 and drop_q_off is None and ts_delta_off == 0 and len(outer_ids & {int(u) for u in g.storage.f3d.bs.belts}) == 0,
      f"take_slice (off): synchronous drop ({ts_delta_off} slices) and load_i reset ({load_i_off})")
bs_mod.drop_slice = None
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "drop_margin default"}))
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "take_slice default"}))

# 1b-2. belt_sim H.prune_step: actor re-entered via b.bt before sliced pr.ac runs is NOT dropped:
prune_ins = spawn("inserter", bx0, by0 + 1.0, force="player", direction=0)
prune_ins.pickup_target = inner_belts[0]
prune_ins.pickup_position = inner_belts[0].position
ups_cleanup.append(prune_ins)
prune_u = int(prune_ins.unit_number)
bs_mod.reset()
send({"t": "focus", "x": fixed(bx0), "y": fixed(by0), "r": 64})
for _ in range(120):
    alive(1)
    if g.storage.f3d.bs and g.storage.f3d.bs.actors and g.storage.f3d.bs.actors[prune_u] is not None:
        break
take()
check(g.storage.f3d.bs.actors[prune_u] is not None, "prune_step actor race setup: actor tracked")
lua.execute(f"""
local bs = storage.f3d.bs
local dummy = {{}}
for i = 1, 70 do dummy[i] = 900000 + i end
bs.bt = bs.bt or {{}}
bs.bt[999999] = {{ tick = game.tick, a = {{ {prune_u} }} }}
bs.prune = {{ bc = dummy, bci = 1, ac = {{ {prune_u} }}, aci = 1 }}
""")
alive(1)
take()
mid_prune = g.storage.f3d.bs.prune is not None
alive(3)
take()
kept_actor = g.storage.f3d.bs.actors[prune_u] is not None
kept_alist = prune_u in {int(v) for v in g.storage.f3d.bs.alist.values()}
lua.execute("if storage.f3d.bs and storage.f3d.bs.bt then storage.f3d.bs.bt[999999] = nil end")
check(mid_prune and kept_actor and kept_alist,
      f"prune_step actor race: pr.ac paused across slices (mid={mid_prune}) preserves actor referenced by b.bt (actor={kept_actor}, alist={kept_alist})")

# 1c. belt_sim load_budget (on vs off):
bsst, bud = g.storage.f3d.bs, g.storage.f3d.bud
saved_lb = (bsst.load_i, bsst.thin, bsst.whole, bud.used, bud.limit)
bsst.load_i, bsst.whole, bud.limit = 1, True, 300
bud.jobs.bsload = 0
bsst.thin = True
bud.used = 300
lb_thin_0 = int(bs_mod.load_limit_now())
bud.used = 280
lb_thin_20 = int(bs_mod.load_limit_now())
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "load_budget off"}))
bud.used = 300
lb_thin_off = int(bs_mod.load_limit_now())
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "load_budget default"}))
bsst.thin = None
g.storage.f3d_bs = lua.table_from({"walk_near": 0})
bud.used = 300
lb_far_on = int(bs_mod.load_limit_now())
g.storage.f3d_bs = lua.table_from({"walk_near": 0, "load_budget": False})
lb_far_off = int(bs_mod.load_limit_now())
g.storage.f3d_bs = None
bsst.load_i, bsst.thin, bsst.whole, bud.used, bud.limit = saved_lb
check(lb_thin_0 == 200 and lb_thin_20 == 400 and lb_thin_off == 1200 and lb_far_on == 0 and lb_far_off == 400,
      f"load_budget (on/off): thin(0/20/off)={lb_thin_0}/{lb_thin_20}/{lb_thin_off}, far(on/off)={lb_far_on}/{lb_far_off}")

# 1d. belt_sim edge_budget (on vs off):
ex0, ey0 = 2400.5, 2460.5
edge_belts = []
for i in range(15):
    eb_out = spawn("transport-belt", ex0 - 6.0 + i, ey0 + 15.0, force="player", direction=8)
    eb_ext = spawn("transport-belt", ex0 - 6.0 + i, ey0 + 16.0, force="player", direction=8)
    eb_feed = spawn("transport-belt", ex0 - 6.0 + i, ey0 - 16.0, force="player", direction=8)
    eb_in = spawn("transport-belt", ex0 - 6.0 + i, ey0 - 15.0, force="player", direction=8)
    F.link_belts(eb_out, eb_ext)
    F.link_belts(eb_feed, eb_in)
    F.put_on_belt(eb_out, 1, "iron-plate", 0.5, 8100 + i)
    F.put_on_belt(eb_feed, 1, "iron-plate", 0.5, 8200 + i)
    F.put_on_belt(eb_in, 1, "iron-plate", 0.5, 8300 + i)
    edge_belts.extend([eb_out, eb_ext, eb_feed, eb_in])
ups_cleanup.extend(edge_belts)
bs_mod.reset()
send({"t": "focus", "x": fixed(ex0), "y": fixed(ey0), "r": 64})
send({"t": "bfar", "r": 0, "n": 16, "m": 0})
for _ in range(160):
    alive(1)
    if g.storage.f3d.bs.scanning is None and g.storage.f3d.bs.edge_q is None and len(g.storage.f3d.bs.belts) >= 30:
        break
take()
bs_mod.edge_cap = 1
bs_mod.counts.edge_slices = 0
alive(12)
take()
es_on = int(bs_mod.counts.edge_slices or 0)
for _ in range(60):
    if g.storage.f3d.bs.edge_q is None:
        break
    alive(1)
    take()
check(es_on > 0 and g.storage.f3d.bs.edge_q is None,
      f"edge_budget (on): dense edge crossings sliced ({es_on} slices) and drained cleanly")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "edge_budget off"}))
bs_mod.counts.edge_slices = 0
alive(12)
take()
es_off = int(bs_mod.counts.edge_slices or 0)
check(es_off == 0, f"edge_budget (off): runs unbudgeted in 1 tick ({es_off} slices)")
bs_mod.edge_cap = None
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "edge_budget default"}))
send({"t": "bfar", "r": 0})

# 2a. movers.lua mover_move_scan (on vs off):
mx0, my0 = 2480.5, 2480.5
g.settings["global"]["f3d-mover-rescan"] = lua.table_from({"value": 64})
send({"t": "focus", "x": fixed(mx0), "y": fixed(my0), "r": 64})
for _ in range(25):
    alive(8)
    take()
    if g.storage.f3d.mv_scan and int(g.storage.f3d.mv_scan.every) >= 32:
        break
for _ in range(70):
    alive(1)
    take()
    if g.storage.f3d.mv_scan and int(g.storage.f3d.mv_scan.tick) == int(g.game.tick):
        break
mv0 = int(movers_mod.counts.mv_scans)
send({"t": "focus", "x": fixed(mx0 + 8), "y": fixed(my0), "r": 64})
alive(10)
take()
mv_8t = int(movers_mod.counts.mv_scans)
send({"t": "focus", "x": fixed(mx0 + 16), "y": fixed(my0), "r": 64})
alive(5)
take()
mv_16t_early = int(movers_mod.counts.mv_scans)
alive(10)
take()
mv_16t_due = int(movers_mod.counts.mv_scans)
send({"t": "focus", "x": fixed(mx0 + 52), "y": fixed(my0), "r": 64})
alive(8)
take()
mv_jump = int(movers_mod.counts.mv_scans)
check(mv_8t == mv0 and mv_16t_early == mv0 and mv_16t_due == mv0 + 1 and mv_jump == mv_16t_due + 1,
      f"mover_move_scan (on): 8t={mv_8t - mv0}, 16t@15={mv_16t_early - mv0}, 16t@25={mv_16t_due - mv0}, jump={mv_jump - mv_16t_due}")

set_perf(mover_move_scan=False)
for _ in range(25):
    alive(8)
    take()
    if g.storage.f3d.mv_scan and int(g.storage.f3d.mv_scan.every) >= 32:
        break
for _ in range(70):
    alive(1)
    take()
    if g.storage.f3d.mv_scan and int(g.storage.f3d.mv_scan.tick) == int(g.game.tick):
        break
mv_off0 = int(movers_mod.counts.mv_scans)
send({"t": "focus", "x": fixed(mx0 + 57), "y": fixed(my0), "r": 64})
alive(8)
take()
mv_off1 = int(movers_mod.counts.mv_scans)
check(mv_off1 == mv_off0 + 1, f"mover_move_scan (off): 5 tiles triggers immediate rescan ({mv_off0} -> {mv_off1})")
set_perf()

# 2b. movers.lua st_working_slice (on vs off):
sx0, sy0 = 2580.5, 2580.5
st_ams = [spawn("assembling-machine-1", sx0 + (i % 5) * 4.0, sy0 + (i // 5) * 4.0, force="player") for i in range(20)]
ups_cleanup.extend(st_ams)
send({"t": "focus", "x": fixed(sx0 + 8), "y": fixed(sy0 + 6), "r": 64})
alive(35)
take()
st_ids = {int(e.unit_number) for e in st_ams}
ref0 = int(movers_mod.counts.st_refreshes)
max_st_on = 0
min_working_on = len(st_ids)
for _ in range(340):
    alive(1)
    for m in of_type(take(), "st"):
        hits = [u for u in m["l"][::2] if int(u) in st_ids]
        max_st_on = max(max_st_on, len(hits))
    kept = len(st_ids & {int(u) for u in g.storage.f3d.working})
    min_working_on = min(min_working_on, kept)
ref_on_delta = int(movers_mod.counts.st_refreshes) - ref0
check(ref_on_delta > 0 and max_st_on < 20 and min_working_on == 20,
      f"st_working_slice (on): slices refreshed ({ref_on_delta}), max st burst {max_st_on}/20, min working kept {min_working_on}/20")

set_perf(st_working_slice=False)
ref_off0 = int(movers_mod.counts.st_refreshes)
max_st_off = 0
for _ in range(340):
    alive(1)
    for m in of_type(take(), "st"):
        hits = [u for u in m["l"][::2] if int(u) in st_ids]
        max_st_off = max(max_st_off, len(hits))
ref_off_delta = int(movers_mod.counts.st_refreshes) - ref_off0
check(ref_off_delta == 0 and max_st_off == 20,
      f"st_working_slice (off): full tick-300 wipe burst ({max_st_off}/20 in one st, refreshes {ref_off_delta})")
set_perf()

# 2c. movers.lua splitter_throttle (on vs off):
spx0, spy0 = 2660.5, 2660.5
spls = [spawn("splitter", spx0 + (i % 6) * 3.0, spy0 + (i // 6) * 2.0, force="player") for i in range(22)]
ups_cleanup.extend(spls)
send({"t": "focus", "x": fixed(spx0 + 8), "y": fixed(spy0 + 4), "r": 64})
send({"t": "bfar", "r": 0, "n": 64, "m": 0})
for _ in range(160):
    alive(1)
    if g.storage.f3d.bs.scanning is None and len(g.storage.f3d.bs.belts) >= 22:
        break
take()
movers_mod.counts.splitter_bs_skips = 0
alive(35)
take()
bs_skips = int(movers_mod.counts.splitter_bs_skips)
check(bs_skips > 0, f"splitter_throttle: empty/quiet splitters skip API check via belt_sim ({bs_skips} skips)")

# Force all 22 splitters into spl_todo (disable bfar) to test SPLITTER_PER_PASS = 16 rotating cap:
send({"t": "bfar", "r": 0, "n": 0})
alive(5)
take()
for _ in range(50):
    c_prev = int(movers_mod.counts.splitter_checks)
    alive(1)
    take()
    if int(movers_mod.counts.splitter_checks) > c_prev:
        break
movers_mod.counts.splitter_checks = 0
movers_mod.counts.splitter_throttled = 0
for _ in range(50):
    alive(1)
    take()
    if int(movers_mod.counts.splitter_checks) > 0:
        break
checks_1pass = int(movers_mod.counts.splitter_checks)
throt_1pass = int(movers_mod.counts.splitter_throttled)
check(0 < checks_1pass <= 16 and throt_1pass >= 6,
      f"splitter_throttle (on): caps to <=16 checks per pass ({checks_1pass} checks, {throt_1pass} throttled)")

set_perf(splitter_throttle=False)
movers_mod.counts.splitter_checks = 0
movers_mod.counts.splitter_throttled = 0
movers_mod.counts.splitter_bs_skips = 0
for _ in range(50):
    alive(1)
    take()
    if int(movers_mod.counts.splitter_checks) > 0:
        break
check(int(movers_mod.counts.splitter_checks) >= 22 and int(movers_mod.counts.splitter_throttled) == 0 and int(movers_mod.counts.splitter_bs_skips) == 0,
      f"splitter_throttle (off): checks all {int(movers_mod.counts.splitter_checks)} splitters unconditionally")
set_perf()

# 2c-2. Two equal-size alternating regions (32 near in region 0, 32 far in strip 1) both check every splitter within ceil(32/16) = 2 passes:
near_extra = [spawn("splitter", spx0 + (i % 6) * 3.0, spy0 + 10.0 + (i // 6) * 2.0, force="player") for i in range(10)]
far_spls = [spawn("splitter", spx0 + (i % 8) * 3.0, spy0 - 80.0 - (i // 8) * 2.0, force="player") for i in range(32)]
ups_cleanup.extend(near_extra + far_spls)
near32_ids = {int(e.unit_number) for e in spls + near_extra}
far32_ids = {int(e.unit_number) for e in far_spls}
send({"t": "bfar", "r": 0, "n": 0})
send({"t": "focus", "x": fixed(spx0 + 8), "y": fixed(spy0 + 4), "r": 128})
alive(2)
take()
g.storage.f3d.st_spl_tick = None
far_passes = 0
far_pass1_cnt = 0
prev_far_set = set()
for _ in range(300):
    alive(1)
    take()
    st_ticks = g.storage.f3d.st_spl_tick
    cur_far = ({int(u) for u in st_ticks if int(u) in far32_ids} if st_ticks else set())
    if cur_far != prev_far_set:
        far_passes += 1
        if far_passes == 1:
            far_pass1_cnt = len(cur_far)
        prev_far_set = cur_far
        if len(cur_far) == 32:
            break
cur_near = ({int(u) for u in g.storage.f3d.st_spl_tick if int(u) in near32_ids} if g.storage.f3d.st_spl_tick else set())
check(far_pass1_cnt == 16 and far_passes <= 2 and len(prev_far_set) == 32 and len(cur_near) == 32,
      f"splitter_throttle fairness: alternating 32+32 regions checked {len(cur_near)}/32 near and {len(prev_far_set)}/32 far in {far_passes} far pass(es) (pass1={far_pass1_cnt})")

# 3. inserters.lua inserter_look_budget (on vs off + read-only budget + determinism):
ix0, iy0 = 2800.5, 2800.5
ins_coords = [(ix0, iy0), (ix0 + 1, iy0), (ix0 + 32, iy0), (ix0 - 32, iy0),
              (ix0, iy0 + 32), (ix0, iy0 - 32), (ix0 + 48, iy0 + 48), (ix0 - 48, iy0 - 48)]
ins_list = [spawn("inserter", x, y, force="player") for x, y in ins_coords]
ups_cleanup.extend(ins_list)
send({"t": "focus", "x": fixed(ix0), "y": fixed(iy0), "r": 64})
alive(2)
take()
bud.limit = 1
ins_mod.reset()
ls0 = int(ins_mod.counts.look_slices)
alive(1)
take()
ls1 = int(ins_mod.counts.look_slices)
# Nearest chunk (ix0, iy0) searched first; storage.f3d.bud.jobs never acquires an inserter_look charge:
check(ls1 == ls0 + 1 and "inserter_look" not in to_py(bud.jobs),
      f"inserter_look_budget (on): slices under tight budget ({ls0}->{ls1}) without mutating budget")
for _ in range(35):
    alive(1)
    take()
ls_done = int(ins_mod.counts.look_slices)
check(ls_done - ls0 >= 4, f"inserter_look_budget (on): completes multi-chunk scan across slices ({ls_done - ls0})")
check(g.F_ups_forget(ins_mod.tick, "look_job") and g.F_ups_forget(ins_mod.tick, "chunks"),
      "inserter_look_budget: module-local look_job/chunks forgettable for determinism")

set_perf(inserter_look_budget=False)
bud.limit = 1
ins_mod.reset()
ls_off0 = int(ins_mod.counts.look_slices)
alive(1)
take()
ls_off1 = int(ins_mod.counts.look_slices)
check(ls_off1 == ls_off0, f"inserter_look_budget (off): scans all chunks synchronously in 1 tick ({ls_off1 - ls_off0} slices)")
bud.limit = saved_ups_bud_limit
set_perf()

# 4. fluids_power.lua fluids_budget (on vs off):
fx0, fy0 = 3000.5, 3000.5
g.settings["global"]["f3d-detail-radius"] = lua.table_from({"value": 64})
fp_ents = [
    spawn("storage-tank", fx0, fy0 - 20.0, force="player"),
    spawn("storage-tank", fx0, fy0 + 20.0, force="player"),
    spawn("assembling-machine-1", fx0 + 5.0, fy0 - 10.0, force="player"),
    spawn("gun-turret", fx0 - 5.0, fy0 + 10.0, force="player"),
]
ups_cleanup.extend(fp_ents)
send({"t": "focus", "x": fixed(fx0), "y": fixed(fy0), "r": 64})
alive(1)
take()
fp_mod = g.package.loaded["scripts.fluids_power"]
g.storage.f3d.fp_job = None
rate_mod.reset()
bud.limit = 1
runs0, slices0 = int(fp_mod.counts.runs), int(fp_mod.counts.slices)
fp_msgs = []
for _ in range(70):
    alive(1)
    fp_msgs.extend(take())
    if int(fp_mod.counts.runs) > runs0:
        break
runs1, slices1 = int(fp_mod.counts.runs), int(fp_mod.counts.slices)
check(runs1 == runs0 + 1 and slices1 - slices0 >= 4
      and any(m.get("t") == "fl" for m in fp_msgs)
      and any(m.get("t") == "ht" for m in fp_msgs)
      and any(m.get("t") == "pw" for m in fp_msgs),
      f"fluids_budget (on): runs={runs1 - runs0}, slices={slices1 - slices0}, emitted fl/ht/pw")

set_perf(fluids_budget=False)
g.storage.f3d.fp_job = None
rate_mod.reset()
bud.limit = 1
runs_off0, slices_off0 = int(fp_mod.counts.runs), int(fp_mod.counts.slices)
for _ in range(70):
    alive(1)
    take()
    if int(fp_mod.counts.runs) > runs_off0:
        break
check(int(fp_mod.counts.runs) == runs_off0 + 1 and int(fp_mod.counts.slices) == slices_off0,
      f"fluids_budget (off): completes full run synchronously in 1 tick (slices={int(fp_mod.counts.slices) - slices_off0})")
bud.limit = saved_ups_bud_limit
set_perf()

# 5. alt_mode.lua alt_cadence (on vs off):
ax0, ay0 = 3200.5, 3200.5
alt_mod = g.package.loaded["scripts.alt_mode"]
ups_cleanup.extend([
    spawn("wooden-chest", ax0, ay0 - 4.0, force="player"),
    spawn("wooden-chest", ax0, ay0 + 4.0, force="player"),
    spawn("assembling-machine-1", ax0 + 6.0, ay0, force="player"),
])
send({"t": "focus", "x": fixed(ax0), "y": fixed(ay0), "r": 128})
bud.limit = 1000
send({"t": "altc", "on": 1, "g": 42, "lf": 0})
ac0 = int(alt_mod.counts.container_scans)
am0 = int(alt_mod.counts.machine_scans)
ar0 = int(alt_mod.counts.rounds)
same_tick_double = False
prev_c, prev_m = ac0, am0
for i in range(15):
    if i == 1:
        send({"t": "altc", "on": 1, "g": 42, "lf": 0})  # duplicate g/lf preserved
    alive(1)
    take()
    cur_c, cur_m = int(alt_mod.counts.container_scans), int(alt_mod.counts.machine_scans)
    if cur_c > prev_c and cur_m > prev_m:
        same_tick_double = True
    prev_c, prev_m = cur_c, cur_m
    if int(alt_mod.counts.rounds) > ar0:
        break
stat_due = int(g.storage.f3d.altc.due) - int(g.game.tick)
check(not same_tick_double and prev_c - ac0 >= 2 and prev_m - am0 >= 2 and int(alt_mod.counts.rounds) == ar0 + 1,
      f"alt_cadence (on): staggered strips (c={prev_c - ac0}, m={prev_m - am0}, double={same_tick_double})")

# Moving 8 tiles (< r=128) stretches next round cooldown from 60 to 120:
send({"t": "focus", "x": fixed(ax0 + 8), "y": fixed(ay0), "r": 128})
g.storage.f3d.altc.due = g.game.tick
for _ in range(15):
    alive(1)
    take()
    if int(alt_mod.counts.rounds) > ar0 + 1:
        break
move_due = int(g.storage.f3d.altc.due) - int(g.game.tick)
check(move_due >= 100 and move_due > stat_due,
      f"alt_cadence (on): moving extends cooldown ({stat_due} -> {move_due})")

set_perf(alt_cadence=False)
g.storage.f3d.altc.due = g.game.tick
prev_c, prev_m = int(alt_mod.counts.container_scans), int(alt_mod.counts.machine_scans)
alive(1)
take()
check(int(alt_mod.counts.container_scans) > prev_c and int(alt_mod.counts.machine_scans) > prev_m,
      f"alt_cadence (off): double-scans containers and machines on the same tick")
send({"t": "altc", "on": 0})

# gc_pace (/f3d-perf gc_pace, on): the automatic collector stopped and stepped once a tick (gc_pace.lua); off: Lua's
# own collector running again, as before.
gc_mod = g.package.loaded["scripts.gc_pace"]
set_perf()
alive(3)
gc_ticks0 = int(gc_mod.counts.ticks)
alive(3)
gc_on_running = bool(lua.eval('collectgarbage("isrunning")'))
gc_ticks1 = int(gc_mod.counts.ticks)
set_perf(gc_pace=False)
alive(2)
gc_off_running = bool(lua.eval('collectgarbage("isrunning")'))
gc_ticks2 = int(gc_mod.counts.ticks)
alive(2)
gc_ticks3 = int(gc_mod.counts.ticks)
set_perf()
alive(2)
gc_back = not bool(lua.eval('collectgarbage("isrunning")'))
check(not gc_on_running and gc_ticks1 == gc_ticks0 + 3 and gc_off_running and gc_ticks3 == gc_ticks2 and gc_back,
      f"gc_pace: collector stopped and paced each tick ({gc_ticks0} -> {gc_ticks1}), off: running again, untouched "
      f"({gc_on_running}, {gc_off_running}, back {gc_back})")
set_perf()

# gc_pace's ceiling: a heap above it restarts the collector (from a tick and from between ticks), the next tick stops it
# and paces again.
alive(2)
gc_stopped0 = not bool(lua.eval('collectgarbage("isrunning")'))
gc_resc0 = int(gc_mod.counts.rescues)
gc_base_ceiling = float(gc_mod.ceiling())
lua.execute('gc_ceiling_saved = package.loaded["scripts.gc_pace"].ceiling; '
            'package.loaded["scripts.gc_pace"].ceiling = function() return 1 end')
gc_guard = bool(lua.eval('package.loaded["scripts.gc_pace"].guard()'))
gc_after_guard = bool(lua.eval('collectgarbage("isrunning")'))
lua.execute('package.loaded["scripts.gc_pace"].ceiling = gc_ceiling_saved')
alive(1)
gc_resumed = not bool(lua.eval('collectgarbage("isrunning")'))
lua.execute('package.loaded["scripts.gc_pace"].ceiling = function() return 1 end')
alive(1)  # the tick itself sees the heap over the ceiling
gc_tick_rescue = bool(lua.eval('collectgarbage("isrunning")'))
lua.execute('package.loaded["scripts.gc_pace"].ceiling = gc_ceiling_saved')
alive(2)
gc_resumed2 = not bool(lua.eval('collectgarbage("isrunning")'))
gc_resc1 = int(gc_mod.counts.rescues)
check(gc_stopped0 and gc_guard and gc_after_guard and gc_resumed and gc_tick_rescue and gc_resumed2
      and gc_resc1 == gc_resc0 + 2 and 0 < gc_base_ceiling <= 512 * 1024
      and "rescues" in str(gc_mod.status()),
      f"gc_pace ceiling: over it the collector restarts (guard {gc_guard}, tick {gc_tick_rescue}), the next tick paces "
      f"again ({gc_resumed}, {gc_resumed2}), rescues {gc_resc0} -> {gc_resc1}, ceiling {gc_base_ceiling:.0f} KB")
set_perf()

# Restore clean state:
set_perf()
g.storage.f3d_bs = None
g.storage.f3d.bud.limit = saved_ups_bud_limit
g.settings["global"]["f3d-mover-rescan"] = lua.table_from({"value": saved_ups_rescan})
g.settings["global"]["f3d-mover-interval"] = lua.table_from({"value": saved_ups_mv_interval})
g.settings["global"]["f3d-detail-radius"] = lua.table_from({"value": saved_ups_detail_r})
g.settings["global"]["f3d-max-focus-radius"] = lua.table_from({"value": saved_ups_max_r})
send({"t": "focus", "x": fixed(saved_ups_focus[0]), "y": fixed(saved_ups_focus[1]), "r": saved_ups_focus[2]})
send({"t": "bfar", "r": 0})
for e in ups_cleanup:
    if e.valid:
        e.destroy()
alive(3)
take()

# Bridge UPS plan steps 3 and 5 (the whole-base jobs): at the end, as they move the clock on.
px, py = g.storage.f3d.puppet.position.x, g.storage.f3d.puppet.position.y
# Bridge UPS plan step 3 (map_trains_slice, on by default): an `mtr` ask only starts a pass; map.tick reads the
# carriages a few at a time (what is left of the work budget, read only, up to 30% of it, at least 24 units a tick)
# and sends `mtr` when it ends, the same carriages as the read at once (switch off), which a megabase paid for in
# one 63-110 ms tick. The pass is module-local and spends nothing (what a carriage costs depends on module-local
# caches): nothing of it in storage.
ups_locos = [spawn("locomotive", px + 8 + (i % 16) * 5, py - 30 + (i // 16) * 2.5, force="player") for i in range(400)]
ups_map = lua.eval('package.loaded["scripts.map"]')
ups_budget0 = int(g.storage.f3d.bud.limit)
ups_perf0 = g.storage.f3d_perf


def mtr_pass(on, u):
    send({"t": "budget", "u": u})
    g.storage.f3d_perf = None if on else lua.table_from({"map_trains_slice": False})
    alive(25)
    take()
    send({"t": "mtr"})
    n, got = 0, []
    while n < 80 and not (got and got[-1]["part"] >= got[-1]["parts"]):
        alive(1)
        n += 1
        got += of_type(take(), "mtr")
        if n == 1 and on and not got:
            job = ups_map.trains_job()
            mtr_pass.in_storage = any("mtr" in str(k) and k != "mtr_ask" for k in g.storage.f3d.keys())
            # (asked again mid-pass: the pass under way answers it, nothing restarts)
            alive(20)
            n += 20
            got += of_type(take(), "mtr")
            send({"t": "mtr"})
            job2 = ups_map.trains_job()
            mtr_pass.same_job = job is not None and job2 is not None and job.id == job2.id
    g.storage.f3d_perf = None
    cars = sorted(tuple(m["l"][i:i + 6]) for m in got for i in range(0, len(m["l"]), 6))
    mtr_pass.parts = [m["part"] for m in got]
    return n, cars, 0


n_off, cars_off, _ = mtr_pass(False, 50)
n_on, cars_on, _ = mtr_pass(True, 50)
check(n_off == 1 and n_on > 1 and cars_on == cars_off and len(cars_off) >= 400,
      f"map_trains_slice: the pass spans ticks ({n_on}) and sends the carriages read at once ({len(cars_on)} vs {len(cars_off)})")
check(getattr(mtr_pass, "same_job", False) and not getattr(mtr_pass, "in_storage", True),
      f"map_trains_slice: an ask mid-pass waits for it, and nothing of the pass is in storage ({getattr(mtr_pass, 'same_job', None)}, {[str(k) for k in g.storage.f3d.keys() if 'mtr' in str(k)]})")
check(mtr_pass.parts == list(range(1, len(mtr_pass.parts) + 1)), f"map_trains_slice: the parts in order: {mtr_pass.parts}")
n_big, cars_big, _ = mtr_pass(True, 20000)
check(n_big == len(mtr_pass.parts) and cars_big == cars_off,
      f"map_trains_slice: with budget to spare the pass ends in the ask's tick, then a part a tick ({n_big}, {mtr_pass.parts})")
for lo in ups_locos:
    lo.destroy()
send({"t": "budget", "u": ups_budget0})
alive(25)
take()

# Bridge UPS plan step 5 (events_enqueue, on by default): a game event about a watched entity only queues it
# (storage.f3d.evq); its record goes from on_tick, nearest the focus first, under the work budget. An entity
# removed while queued has its record sent before its `del`, and nothing of it after.
ups_tracker = lua.eval('package.loaded["scripts.tracker"]')
ev_chests = [spawn("wooden-chest", px + 2.5 + (i % 25), py + 4.5 + (i // 25) * 3, force="player") for i in range(100)]
ev_cx, ev_cy = math.floor(px / 32), math.floor(py / 32)
send({"t": "sub", "c": [[ev_cx + dx, ev_cy + dy] for dx in (-1, 0, 1) for dy in (-1, 0, 1, 2)]})
alive(30)
send({"t": "budget", "u": 50})
alive(3)
take()


def mark_all(chests):
    for c in chests:
        F.decon_marks[c] = True
        F["raise"]("on_marked_for_deconstruction", lua.table_from({"entity": c}))


fx, fy = g.storage.f3d.focus.x, g.storage.f3d.focus.y
dist = {c.unit_number: (c.position.x - fx) ** 2 + (c.position.y - fy) ** 2 for c in ev_chests}
mark_all(ev_chests)
queued = ups_tracker.event_queue_length()
alive(1)
first = [m["e"][0] for m in of_type(take(), "upd") if m["e"][0] in dist]
rest = []
for _ in range(40):
    alive(1)
    rest += [m["e"][0] for m in of_type(take(), "upd") if m["e"][0] in dist]
check(queued == 100 and 0 < len(first) < 100 and sorted(first + rest) == sorted(dist),
      f"events_enqueue: 100 marks queued ({queued}), sent over ticks ({len(first)} in the first), each once ({len(first + rest)})")
check(first and rest and max(dist[u] for u in first) <= min(dist[u] for u in rest),
      "events_enqueue: the nearest the focus first")
# Marked again and cancelled in the same tick: one record (deduplicated by unit number).
mark_all(ev_chests[:5])
for c in ev_chests[:5]:
    F.decon_marks[c] = None
    F["raise"]("on_cancelled_deconstruction", lua.table_from({"entity": c}))
check(ups_tracker.event_queue_length() == 5, f"events_enqueue: one queued an entity ({ups_tracker.event_queue_length()})")
alive(2)
ups5 = [m["e"][0] for m in of_type(take(), "upd")]
check(sorted(ups5) == sorted(c.unit_number for c in ev_chests[:5]), f"events_enqueue: one record each: {ups5}")
# Mined while queued: its record, then its `del`, in the same tick; nothing of it later.
gone = ev_chests[-1]
gone_u = gone.unit_number
mark_all([gone])
F["raise"]("on_player_mined_entity", lua.table_from({"entity": gone}))
gone.destroy()
check(ups_tracker.event_queue_length() == 0, "events_enqueue: a removed entity leaves the queue")
alive(1)
seq = [(m["t"]) for m in take() if (m["t"] in ("upd", "add") and m["e"][0] == gone_u) or (m["t"] == "del" and m.get("u") == gone_u)]
alive(3)
later = [m for m in take() if m["t"] in ("upd", "add") and m["e"][0] == gone_u]
check(seq == ["upd", "del"] and not later, f"events_enqueue: a queued entity's record goes before its del ({seq}, later {len(later)})")
# Built while marks are queued: still its `add` (a later mark doesn't make it `upd`).
new_chest = spawn("wooden-chest", px + 2.5, py + 30.5, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": new_chest}))
mark_all([new_chest])
alive(2)
kinds = [m["t"] for m in take() if m["t"] in ("add", "upd") and m["e"][0] == new_chest.unit_number]
check(kinds == ["add"], f"events_enqueue: built then marked before the drain goes as one add: {kinds}")
# A direct call (the client's own action) sends at once and takes the entity off the queue.
mark_all(ev_chests[:3])
ups_tracker.changed(ev_chests[0])
check(ups_tracker.event_queue_length() == 2, "events_enqueue: a direct change takes its entity off the queue")
alive(2)
take()
# A sorted queue (> 32) shrinks q.list as it drains, and stays nearest first once it is down to 32 or fewer.
alive(3)
take()
mark_all(ev_chests[:90])
ev_lens, ev_order = [], []
for _ in range(60):
    alive(1)
    ev_order += [m["e"][0] for m in of_type(take(), "upd") if m["e"][0] in dist]
    ev_q = g.storage.f3d.evq
    ev_lens.append(len(ev_q.list) if ev_q else 0)
ev_dists = [dist[u] for u in ev_order]
check(len(ev_order) == 90 and ev_lens[-1] == 0, f"events_enqueue: a sorted queue drains to an empty list ({len(ev_order)} sent, list {ev_lens[-1]})")
check(any(n > 32 for n in ev_lens) and any(0 < n <= 32 for n in ev_lens), f"events_enqueue: the drain crosses 32 ({ev_lens[:12]})")
check(all(a >= b for a, b in zip(ev_lens, ev_lens[1:])) and len(set(ev_lens)) > 3, f"events_enqueue: q.list shrinks as it drains ({ev_lens[:12]})")
check(ev_dists == sorted(ev_dists), "events_enqueue: nearest first all the way down, also under 32 left")
# Off: every mark's record in the event, nothing queued.
g.storage.f3d_perf = lua.table_from({"events_enqueue": False})
mark_all(ev_chests[:50])
check(ups_tracker.event_queue_length() == 0, "events_enqueue off: nothing queued")
alive(1)
off_ups = [m["e"][0] for m in of_type(take(), "upd") if m["e"][0] in dist]
check(len(off_ups) == 50, f"events_enqueue off: all 50 records in the next flush ({len(off_ups)})")
# alerts_topk (on by default): `al`'s nearest PER_KIND of each kind picked in one pass, the same as the sort of the
# whole list (switch off), and kept until the list or the focus changes; a shown one gone makes it again.
ups_alerts = lua.eval('package.loaded["scripts.alerts"]')
ups_asms = [spawn("assembling-machine-1", px - 30 - (i % 10) * 4, py - 30 - (i // 10) * 4, force="player") for i in range(90)]
for a in ups_asms:
    a.status = g.defines.entity_status.full_output
ups_alerts.reset()  # (the pass takes chunks it found nothing in as empty; these were spawned without an event)
g.storage.f3d_perf = lua.table_from({"alerts_topk": False})
al_off = to_py(ups_alerts.current())
g.storage.f3d_perf = None
al_on = to_py(ups_alerts.message_now())
kinds_on = {k[0]: k for k in al_on["l"]}
check(al_on == al_off and kinds_on.get("output_full", [0, 0])[1] >= 90 and len(kinds_on["output_full"][2]) == 40,
      f"alerts_topk: the same `al` as the whole sort ({kinds_on.get('output_full', [0, 0])[1]} output full)")
# (alerts_topk) The pass reads a chunk's entities ENTITIES_PER_TICK a tick, not a dense chunk whole in one tick.
dense = [spawn("assembling-machine-1", px + 33.5 + (i % 10) * 3, py + 3.5 + (i // 10) * 3, force="player") for i in range(100)]
for a in dense:
    a.status = g.defines.entity_status.full_output


def pass_steps(on):
    g.storage.f3d_perf = None if on else lua.table_from({"alerts_topk": False})
    ups_alerts.reset()
    ups_alerts.tick_pass()
    n = 1
    while not ups_alerts.pass_done() and n < 100000:
        ups_alerts.tick_pass()
        n += 1
    g.storage.f3d_perf = None
    return n, {k[0]: k[1] for k in to_py(ups_alerts.message_now())["l"]}.get("output_full")


steps_off, full_off = pass_steps(False)
steps_on, full_on = pass_steps(True)
check(steps_on > steps_off and full_on == full_off and full_on >= 190,
      f"alerts_topk: a dense chunk read over more steps ({steps_off} -> {steps_on}), the same alerts ({full_off} / {full_on})")
for a in dense:
    a.destroy()
nearest = kinds_on["output_full"][2][0][4]
again = to_py(ups_alerts.message_now())
next(a for a in ups_asms if a.unit_number == nearest).destroy()
after = to_py(ups_alerts.message_now())
shown_after = [r[4] for r in {k[0]: k for k in after["l"]}["output_full"][2]]
check(again == al_on and nearest not in shown_after and len(shown_after) == 40,
      f"alerts_topk: kept while nothing changed, made again when a shown one is gone")
for a in ups_asms:
    if a.valid:
        a.destroy()
# map_trains_slice: the alerts' train scan reads TRAINS_PER_TICK trains a tick from the list its turn took, and its
# lists (no path, out of fuel) are the read of every train at once.
ups_tp = [spawn("locomotive", px + 60 + (i % 10) * 6, py + 60 + (i // 10) * 6, force="player") for i in range(100)]
for lo in ups_tp:
    F.train_data[lo.train].state = g.defines.train_state.no_path
alive(130)
sliced = {k[0]: k[1] for k in to_py(ups_alerts.message_now())["l"]}
full = {k[0]: k[1] for k in to_py(ups_alerts.current())["l"]}
check(sliced.get("train_path", 0) >= 100 and sliced.get("train_path") == full.get("train_path"),
      f"map_trains_slice: the alerts' sliced train scan finds every train without a path ({sliced.get('train_path')} vs {full.get('train_path')})")
for lo in ups_tp:
    lo.destroy()
g.storage.f3d_perf = None
for c in ev_chests[:-1]:
    F["raise"]("script_raised_destroy", lua.table_from({"entity": c}))
    c.destroy()
new_chest.destroy()
send({"t": "sub", "c": []})
send({"t": "budget", "u": ups_budget0})
alive(3)
take()

# --- Worker Track 1: robot_opt (force_mods cache, roboport scan throttle, logistic_cell cache, is_empty(), rate scaling, budget cap) ---
ro_mod = g.package.loaded["scripts.robots"]
ro_ox, ro_oy = 4200, 4200
ro_hello = {"t": "hello", "v": 1, "sid": "rb-opt", "w": 0, "b": 1, "rb": 1}
ro_keepalive = {"t": "hello", "v": 1, "sid": "rb-opt", "w": 1, "b": 1, "rb": 1}


def ro_tick(n=1):
    for _ in range(n):
        if int(g.game.tick) % 200 == 0:
            send(ro_keepalive)
        tick(1)


send({"t": "bye"})
tick(1)
send(ro_hello)
send({"t": "focus", "x": ro_ox * 256, "y": ro_oy * 256, "r": 64})
send({"t": "rate", "l": 0})
ro_tick(10)
take()

ro_chest_a = spawn("wooden-chest", ro_ox + 6.5, ro_oy + 0.5, force="player")
ro_chest_b = spawn("wooden-chest", ro_ox + 22.5, ro_oy + 0.5, force="player")
ro_rp = spawn("roboport", ro_ox - 2.5, ro_oy - 2.5, force="player")
ro_log = spawn("logistic-robot", ro_ox - 4.5, ro_oy + 0.5, force="player")
ro_log.orientation = 0.25
ro_log.energy = 1500000
ro_log.robot_order_queue = lua.table_from([
    lua.table_from({"type": OT.pickup, "target": ro_chest_a}),
    lua.table_from({"type": OT.deliver, "target": ro_chest_b}),
])
ro_log.get_inventory(g.defines.inventory.robot_cargo).insert(lua.table_from({"name": "iron-plate", "count": 1}))
ro_con = spawn("construction-robot", ro_ox + 22.4, ro_oy + 0.5, force="player")
ro_con.orientation = 0.25
ro_con.robot_order_queue = lua.table_from([lua.table_from({"type": OT.construct, "target": ro_chest_b})])


def ro_snapshot(opt_on):
    set_perf(robot_opt=opt_on)
    ro_mod.reset()
    ro_tick(18)
    recs = rb_recs(take())
    out = {}
    for u in (ro_log.unit_number, ro_con.unit_number):
        r = recs.get(u)
        if r is not None:
            # Ignore tick timestamp r[2] since sweep duration differs slightly; compare everything else.
            out[u] = [r[0], r[1]] + list(r[3:])
    return out


ro_snap_on = ro_snapshot(True)
ro_snap_off = ro_snapshot(False)
check(ro_log.unit_number in ro_snap_on and ro_con.unit_number in ro_snap_on and ro_snap_on == ro_snap_off,
      f"robot_opt on vs off parity: identical rb leg records (on={ro_snap_on}, off={ro_snap_off})")
check((ro_snap_on[ro_log.unit_number][-1] & 8) != 0 and (ro_snap_on[ro_con.unit_number][-1] & 128) != 0,
      f"robot_opt parity: FLAG_CARGO and FLAG_WORKING preserved: {ro_snap_on}")

# is_empty() cargo read & pcall fallback:
set_perf(robot_opt=True)
# Bind ro_log's real robot_cargo inventory to spy on is_empty() vs inv[1] without mutating LuaEntity.
lua.eval("""function(robot)
  F_ro_is_empty_calls = 0
  F_ro_slot1_reads = 0
  F_ro_throw_is_empty = false
  local real_inv = robot.get_inventory(defines.inventory.robot_cargo)
  F_ro_real_inv = real_inv
  F_ro_orig_is_empty = real_inv.is_empty
  F_ro_inv_orig_mt = getmetatable(real_inv)
  real_inv.is_empty = function()
    if F_ro_throw_is_empty then error("is_empty missing") end
    F_ro_is_empty_calls = F_ro_is_empty_calls + 1
    return F_ro_orig_is_empty()
  end
  setmetatable(real_inv, {
    __index = function(t, k)
      if k == 1 then F_ro_slot1_reads = F_ro_slot1_reads + 1 end
      return F_ro_inv_orig_mt.__index(t, k)
    end,
    __len = F_ro_inv_orig_mt.__len,
  })
end""")(ro_log)
ro_mod.reset()
ro_tick(18)
recs_cargo = rb_recs(take())
check(int(g.F_ro_is_empty_calls) > 0 and int(g.F_ro_slot1_reads) == 0
      and (recs_cargo[ro_log.unit_number][10] & 8) != 0,
      f"robot_opt is_empty(): uses inv.is_empty() ({g.F_ro_is_empty_calls} calls) without inv[1] ({g.F_ro_slot1_reads} reads)")
ro_log.get_inventory(g.defines.inventory.robot_cargo).remove(lua.table_from({"name": "iron-plate", "count": 1}))
ro_tick(65)
recs_empty = rb_recs(take())
check(recs_empty.get(ro_log.unit_number) is not None and (recs_empty[ro_log.unit_number][10] & 8) == 0,
      f"robot_opt is_empty(): clears FLAG_CARGO when cargo removed: {recs_empty.get(ro_log.unit_number)}")
# Fallback when is_empty throws:
ro_log.get_inventory(g.defines.inventory.robot_cargo).insert(lua.table_from({"name": "iron-plate", "count": 1}))
g.F_ro_throw_is_empty = True
ro_tick(65)
recs_fb = rb_recs(take())
check(int(g.F_ro_slot1_reads) > 0 and recs_fb.get(ro_log.unit_number) is not None
      and (recs_fb[ro_log.unit_number][10] & 8) != 0,
      f"robot_opt is_empty() fallback: pcall falls back to inv[1] ({g.F_ro_slot1_reads} reads) and sets FLAG_CARGO")
lua.execute("""
F_ro_real_inv.is_empty = F_ro_orig_is_empty
setmetatable(F_ro_real_inv, F_ro_inv_orig_mt)
""")

# force_mods 60-tick caching & reset invalidation:
set_perf(robot_opt=True)
ro_mod.reset()
ro_tick(1)
take()
m0 = int(ro_mod.counts.mod_reads)
ro_tick(58)
m1 = int(ro_mod.counts.mod_reads)
check(m1 == m0, f"robot_opt force_mods cache: 0 extra mod reads over 58 ticks ({m0} -> {m1})")
ro_tick(2)
m2 = int(ro_mod.counts.mod_reads)
check(m2 == m0 + 1, f"robot_opt force_mods cache: refreshes at 60 ticks ({m1} -> {m2})")
ro_mod.reset()
ro_tick(1)
m3 = int(ro_mod.counts.mod_reads)
check(m3 == m2 + 1, f"robot_opt force_mods cache: reset() invalidates cache ({m2} -> {m3})")
send({"t": "focus", "x": (ro_ox + 40) * 256, "y": ro_oy * 256, "r": 64})
ro_tick(1)
m4 = int(ro_mod.counts.mod_reads)
check(m4 == m3 + 1, f"robot_opt force_mods cache: focus jump invalidates cache ({m3} -> {m4})")
set_perf(robot_opt=False)
m_off0 = int(ro_mod.counts.mod_reads)
ro_tick(10)
m_off1 = int(ro_mod.counts.mod_reads)
check(m_off1 == m_off0 + 10, f"robot_opt off force_mods: reads every tick ({m_off1 - m_off0}/10)")

# Roboport scan throttling (120t / >= 16-tile move) + logistic_cell handle caching + empty-roboport skip:
set_perf(robot_opt=True)
send({"t": "focus", "x": ro_ox * 256, "y": ro_oy * 256, "r": 64})
ro_mod.reset()
ro_tick(1)
take()
rp0 = int(ro_mod.counts.rp_scans)
ro_tick(100)
rp1 = int(ro_mod.counts.rp_scans)
check(rp1 == rp0, f"robot_opt roboport throttle: 0 extra scans standing still for 100 ticks ({rp0} -> {rp1})")
send({"t": "focus", "x": (ro_ox + 8) * 256, "y": ro_oy * 256, "r": 64})
ro_tick(1)
rp2 = int(ro_mod.counts.rp_scans)
check(rp2 == rp0, f"robot_opt roboport throttle: moving 8 tiles (<16) does not rescan ({rp0} -> {rp2})")
send({"t": "focus", "x": (ro_ox + 17) * 256, "y": ro_oy * 256, "r": 64})
ro_tick(1)
rp3 = int(ro_mod.counts.rp_scans)
check(rp3 == rp0 + 1, f"robot_opt roboport throttle: moving 17 tiles (>=16) rescans immediately ({rp0} -> {rp3})")
ro_tick(120)
rp4 = int(ro_mod.counts.rp_scans)
check(rp4 == rp3 + 1, f"robot_opt roboport throttle: rescans at 120-tick interval ({rp3} -> {rp4})")
set_perf(robot_opt=False)
rp_off0 = int(ro_mod.counts.rp_scans)
ro_tick(64)
rp_off1 = int(ro_mod.counts.rp_scans)
check(rp_off1 - rp_off0 >= 3, f"robot_opt off roboport: rescans every 16t strip-1 sweep ({rp_off1 - rp_off0} scans in 64t)")

# logistic_cell handle caching & .valid revalidation:
set_perf(robot_opt=True)
send({"t": "focus", "x": ro_ox * 256, "y": ro_oy * 256, "r": 64})
lua.eval("""function(rp)
  F_ro_rp = rp
  F_ro_rp_orig_mt = getmetatable(rp)
  F_ro_orig_cell = rp.logistic_cell
  F_ro_cell_override = nil
  F_ro_cell_gets = 0
  setmetatable(rp, {
    __index = function(t, k)
      if k == "logistic_cell" then
        F_ro_cell_gets = F_ro_cell_gets + 1
        if F_ro_cell_override then return F_ro_cell_override end
      end
      return F_ro_rp_orig_mt.__index(t, k)
    end,
    __newindex = F_ro_rp_orig_mt.__newindex,
  })
end""")(ro_rp)
ro_mod.reset()
ro_tick(1)
take()
cg1 = int(g.F_ro_cell_gets)
ro_tick(36)  # 3 more 12-tick charge polls
cg2 = int(g.F_ro_cell_gets)
check(cg1 == 1 and cg2 == 1, f"robot_opt logistic_cell cache: fetched once and reused across polls ({cg1} -> {cg2})")
lua.execute("""
F_ro_orig_cell.valid = false
F_ro_cell_override = { valid = true, object_name = "LuaLogisticCell", charging_robots = {}, to_charge_robots = {} }
""")
ro_tick(13)
cg3 = int(g.F_ro_cell_gets)
check(cg3 == 2, f"robot_opt logistic_cell cache: revalidates when cached cell.valid becomes false ({cg2} -> {cg3})")
lua.execute("""
F_ro_orig_cell.valid = true
setmetatable(F_ro_rp, F_ro_rp_orig_mt)
""")

# Empty roboport fast-skip:
send({"t": "focus", "x": 6200 * 256, "y": 6200 * 256, "r": 64})
ro_mod.reset()
ro_tick(1)
take()
ch_empty0 = int(ro_mod.counts.ch_polls)
ro_tick(30)
ch_empty1 = int(ro_mod.counts.ch_polls)
check(ch_empty1 == ch_empty0, f"robot_opt empty roboport skip: 0 charge polls when roboports is empty ({ch_empty0} -> {ch_empty1})")
set_perf(robot_opt=False)
ch_off_e0 = int(ro_mod.counts.ch_polls)
ro_tick(16)
ch_off_e1 = int(ro_mod.counts.ch_polls)
check(ch_off_e1 - ch_off_e0 == 4, f"robot_opt off empty roboport: still polls every 4t ({ch_off_e1 - ch_off_e0} in 16t)")

# Rate scaling (rate 0 -> 1 -> 2 -> 3):
set_perf(robot_opt=True)
send({"t": "focus", "x": ro_ox * 256, "y": ro_oy * 256, "r": 64})
ro_mod.reset()
ro_tick(10)
take()


def measure_rate_counts(lvl, ticks=96):
    send({"t": "rate", "l": lvl})
    ro_tick(1)
    s0 = int(ro_mod.counts.strip_scans)
    n0 = int(ro_mod.counts.near_scans)
    c0 = int(ro_mod.counts.ch_polls)
    ro_tick(ticks)
    take()
    return (int(ro_mod.counts.strip_scans) - s0,
            int(ro_mod.counts.near_scans) - n0,
            int(ro_mod.counts.ch_polls) - c0)


r0_c = measure_rate_counts(0)
r1_c = measure_rate_counts(1)
r2_c = measure_rate_counts(2)
r3_c = measure_rate_counts(3)
check(r0_c[0] > r1_c[0] > r2_c[0] > r3_c[0]
      and r0_c[1] > r1_c[1] > r2_c[1] >= r3_c[1]
      and r0_c[2] > r1_c[2] > r2_c[2] >= r3_c[2]
      and r0_c == (24, 12, 8) and r1_c == (12, 6, 4) and r2_c == (6, 3, 2) and r3_c[0] == 3,
      f"robot_opt rate scaling: r0={r0_c}, r1={r1_c}, r2={r2_c}, r3={r3_c}")
set_perf(robot_opt=False)
r2_off = measure_rate_counts(2, 32)
check(r2_off == (16, 8, 8), f"robot_opt off ignores rate scaling at rate 2: {r2_off}")
send({"t": "rate", "l": 0})

# Budget & rate capping of robot_checks and rr_budget:
set_perf(robot_opt=True)
ro_bx, ro_by = 6400, 6400
send({"t": "focus", "x": ro_bx * 256, "y": ro_by * 256, "r": 64})
ro_swarm = [spawn("construction-robot", ro_bx - 20 + (i % 12) * 3, ro_by - 20 + (i // 12) * 3, force="player") for i in range(120)]
ro_mod.reset()
send({"t": "budget", "u": 300})
ro_tick(60)  # complete sweep and hit 60-tick mod cache boundary
take()
send({"t": "budget", "u": 50})
g.game.forces["player"].worker_robots_speed_modifier = 0.25
rc0 = int(ro_mod.counts.robot_checks)
ro_tick(1)
rc1 = int(ro_mod.counts.robot_checks)
check((rc1 - rc0) == 50,
      f"robot_opt budget cap: 120 due robots capped to 50 under budget=50 (got {rc1 - rc0})")
ro_tick(4)
take()
send({"t": "budget", "u": 300})
send({"t": "rate", "l": 2})
ro_mod.reset()
ro_tick(60)
take()
g.game.forces["player"].worker_robots_speed_modifier = 0.50
rc2 = int(ro_mod.counts.robot_checks)
ro_tick(1)
rc3 = int(ro_mod.counts.robot_checks)
check((rc3 - rc2) == 62,
      f"robot_opt rate=2 cap: 120 due robots capped to 62 (MAX_CHECKS/4) (got {rc3 - rc2})")
set_perf(robot_opt=False)
send({"t": "budget", "u": 50})
send({"t": "rate", "l": 0})
g.game.forces["player"].worker_robots_speed_modifier = 0.75
rc_off0 = int(ro_mod.counts.robot_checks)
ro_tick(1)
rc_off1 = int(ro_mod.counts.robot_checks)
check((rc_off1 - rc_off0) == 120,
      f"robot_opt off ignores budget=50 cap: checked all 120 in 1 tick (got {rc_off1 - rc_off0})")

# Cleanup robot_opt tests:
for e in [ro_chest_a, ro_chest_b, ro_rp, ro_log, ro_con] + ro_swarm:
    if e.valid:
        e.destroy()
g.game.forces["player"].worker_robots_speed_modifier = 0.0
send({"t": "rate", "l": 0})
send({"t": "budget", "u": ups_budget0})
send({"t": "focus", "x": fixed(saved_ups_focus[0]), "y": fixed(saved_ups_focus[1]), "r": saved_ups_focus[2]})
set_perf()
ro_mod.reset()
ro_tick(3)
take()



# Renaming a train stop with all = 1 (Ctrl while submitting, Factorio's "rename all stops with this name")
# renames every stop of that name; without it only the one. (Last, so no unit numbers shift under the others.)
rn_a = spawn("train-stop", 3, 3, force="player", backer_name="Rn")
rn_b = spawn("train-stop", 5, 3, force="player", backer_name="Rn")
send(open_cmd(rn_a))
tick(2)
send({"t": "set_stop", "u": rn_a.unit_number, "name": "Rn2"})
tick(2)
check(rn_a.backer_name == "Rn2" and rn_b.backer_name == "Rn", "set_stop renames only that stop without all")
rn_a.backer_name = "Rn"
send({"t": "set_stop", "u": rn_a.unit_number, "name": "Rn3", "all": 1})
tick(2)
check(rn_a.backer_name == "Rn3" and rn_b.backer_name == "Rn3", "set_stop with all: 1 renames every stop with that name (Ctrl while submitting)")
take()

# Editing a train's schedule keeps it heading for the record it was going to (the game's set_records sends
# it back to the first one).
rn_loco = spawn("locomotive", 9, 9, force="player")
send(open_cmd(rn_loco))
tick(2)
rn_w = [{"type": "time", "compare_type": "or", "ticks": 600}]
send({"t": "set_schedule", "u": rn_loco.unit_number, "records": [{"station": "A", "wait_conditions": rn_w}, {"station": "B", "wait_conditions": rn_w}, {"station": "C", "wait_conditions": rn_w}]})
send({"t": "train_go", "u": rn_loco.unit_number, "i": 3})
tick(2)
rn_sched = rn_loco.train.get_schedule()
check(rn_sched.current == 3, f"train_go sets the record the train heads for: {rn_sched.current}")
send({"t": "set_schedule", "u": rn_loco.unit_number, "records": [{"station": "A", "wait_conditions": rn_w}, {"station": "B", "wait_conditions": rn_w}, {"station": "C", "wait_conditions": [{"type": "time", "compare_type": "or", "ticks": 1200}]}]})
tick(2)
check(rn_sched.current == 3, f"set_schedule (a wait condition changed) keeps the train heading for record 3: {rn_sched.current}")
rn_loco.train.manual_mode = True
send({"t": "set_schedule", "u": rn_loco.unit_number, "records": [{"station": "A", "wait_conditions": rn_w}, {"station": "B", "wait_conditions": rn_w}, {"station": "C", "wait_conditions": rn_w}]})
tick(2)
check(rn_sched.current == 3 and rn_loco.train.manual_mode is True, f"a manual train stays manual when its schedule is edited: {rn_sched.current}")
send({"t": "set_schedule", "u": rn_loco.unit_number, "records": [{"station": "A", "wait_conditions": rn_w}]})
tick(2)
check(rn_sched.current == 1, f"and a shorter schedule clamps it: {rn_sched.current}")
take()

# A stop's "Trains on the way" counts a train standing at it too (path_end_stop is nil once it has arrived).
F.train_data[rn_loco.train].station = rn_a
F.stop_trains[rn_a] = lua.table_from({rn_loco.train})
send(open_cmd(rn_a))
tick(2)
rn_gui = [m for m in take() if m.get("t") == "gui" and m.get("u") == rn_a.unit_number]
rn_trs = rn_gui[-1]["stop"]["trs"] if rn_gui else None
check(rn_trs and rn_trs[0][2] == 1, f"a train standing at the stop is counted as heading there in the stop's trs: {rn_trs}")
# Clean up, so the stops and the train don't count in the scans of the tests after this one.
F.stop_trains[rn_a] = None
F.train_data[rn_loco.train].station = None
for e in (rn_a, rn_b, rn_loco):
    if e.valid:
        e.destroy()
tick(2)
take()
