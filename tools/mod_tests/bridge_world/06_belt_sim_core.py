# Bridge test slice 06_belt_sim_core.py (lines 9377-10834 of original test_bridge.py)
# --- belts for a client that simulates them (`bs` in its hello, belt_sim.lua) ----------------------
def bs_of(msgs):
    """{lm: {key: [11 numbers]}, sl: {key: (tick, [[uid, item, pos, stack], ...])}, pc: {key: [tick, n,
    front, back]}, dl, of, qu, heads: [(k, fx, fy, fr)]} over the bs messages in msgs."""
    out = {"lm": {}, "sl": {}, "pc": {}, "pu": {}, "ew": {}, "sh": {}, "dl": [], "of": [], "qu": [], "sx": [], "heads": []}
    for m in of_type(msgs, "bs"):
        out["heads"].append((m["k"], m["fx"], m["fy"], m["fr"]))
        lm = m.get("lm", [])
        for i in range(0, len(lm), 12):
            out["lm"][lm[i]] = lm[i + 1:i + 12]
        sl, i = m.get("sl", []), 0
        while i < len(sl):
            n = sl[i + 2]
            out["sl"][sl[i]] = (sl[i + 1], [sl[i + 3 + 4 * j:i + 7 + 4 * j] for j in range(n)])
            i += 3 + 4 * n
        pc = m.get("pc", [])
        for i in range(0, len(pc), 5):
            out["pc"][pc[i]] = pc[i + 1:i + 5]
        ew = m.get("ew", [])
        for i in range(0, len(ew), 4):
            out["ew"][ew[i]] = ew[i + 1:i + 4]
        pu = m.get("pu", [])
        for i in range(0, len(pu), 3):
            out["pu"][pu[i]] = pu[i + 1:i + 3]
        sh = m.get("sh", [])
        for i in range(0, len(sh), 2):
            out["sh"][sh[i]] = sh[i + 1]
        out["dl"] += m.get("dl", [])
        out["of"] += m.get("of", [])
        out["qu"] += m.get("qu", [])
        sx = m.get("sx", [])
        out["sx"] += [sx[i:i + 7] for i in range(0, len(sx), 7)]
    return out


bs_mod = lua.eval('package.loaded["scripts.belt_sim"]')
bx, by = 300.5, 300.5
sb1 = spawn("transport-belt", bx, by, force="player", direction=4)
sb2 = spawn("transport-belt", bx + 1, by, force="player", direction=4)
sb3 = spawn("transport-belt", bx + 2, by, force="player", direction=4)
F.link_belts(sb1, sb2)
F.link_belts(sb2, sb3)
s_ins = spawn("inserter", bx + 1, by + 1, force="player")
s_ins.pickup_target = sb2  # sb2 is a pickup belt, sb1 the belt behind it: both watched; sb3 not
s_drop = spawn("inserter", bx + 1, by - 1, force="player")
s_drop.drop_target = sb2  # and a drop belt: s_drop holds a plate till it puts it there
F.set_hand(s_drop, bx + 1, by - 1, "iron-plate")
s_in = spawn("underground-belt", bx + 4, by, force="player", direction=4, type="input")
s_out = spawn("underground-belt", bx + 7, by, force="player", direction=4, type="output")
F.pair_undergrounds(s_in, s_out)
s_wired = spawn("transport-belt", bx, by + 3, force="player", direction=4)
s_lane = spawn("lane-splitter", bx + 3, by + 3, force="player", direction=4)
F.belt_behaviors[s_wired] = lua.table_from({"enabled": True})
# A belt leading out of the square: sx (ring 5) feeds sy, 20 tiles out (the square is 16).
sx = spawn("transport-belt", bx + 5, by + 6, force="player", direction=4)
sy = spawn("transport-belt", bx + 20, by + 6, force="player", direction=4)
F.link_belts(sx, sy)
F.put_on_belt(sx, 1, "iron-plate", 0.5, 8105)
# A belt fed from outside the square: fz, 20 tiles out, feeds fw (ring 9).
fz = spawn("transport-belt", bx + 20, by + 9, force="player", direction=12)
fw = spawn("transport-belt", bx + 5, by + 9, force="player", direction=12)
F.link_belts(fz, fw)
F.put_on_belt(fw, 1, "iron-plate", 0.5, 8120)
# A packed run over three plain belts (four items a lane, a gap apart, from a quarter gap in).
runs = [spawn("transport-belt", bx - 5 + k, by - 5, force="player", direction=4) for k in range(3)]
F.link_belts(runs[0], runs[1])
F.link_belts(runs[1], runs[2])
for k, e in enumerate(runs):
    for j in range(4):
        F.put_on_belt(e, 1, "iron-plate", 0.125 + 0.25 * j, 8130 + 4 * k + j)
F.put_on_belt(s_lane, 1, "iron-plate", 0.25, 8150)  # a lane splitter's input holding an item (sh below)
F.put_on_belt(sb1, 1, "iron-plate", 0.5, 8101)
F.put_on_belt(sb2, 1, "iron-plate", 0.25, 8102)
F.put_on_belt(sb2, 1, "iron-plate", 0.75, 8103, None, "rare")
F.put_on_belt(sb3, 2, "copper-plate", 0.5, 8104)
u1, u2, u3, ui, uo, uw = (int(e.unit_number) for e in (sb1, sb2, sb3, s_in, s_out, s_wired))
ul = int(s_lane.unit_number)
ux, uy = int(sx.unit_number), int(sy.unit_number)
bs_mod.pc_every = 1000
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1, "bs": 1})
send({"t": "focus", "x": fixed(bx), "y": fixed(by), "r": 48})
send({"t": "bfar", "r": 0, "n": 16, "m": 0})
tick(14)
first_msgs = take()
first = bs_of(first_msgs)
keys = {u * 8 + i for u in (u1, u2, u3, uw) for i in (1, 2)} | {u * 8 + i for u in (ui, uo) for i in (1, 2, 3, 4)}
check(not of_type(first_msgs, "bi") and keys <= set(first["lm"]) and keys <= set(first["sl"]),
      f"bs: the first load sends every lane's meta (lm) and items (sl): missing lm {sorted(keys - set(first['lm']))}, sl {sorted(keys - set(first['sl']))}")
check(first["heads"] and first["heads"][-1][1:] == (fixed(bx), fixed(by), 16),
      f"bs: fx, fy, fr: the square every lane of which is loaded: {first['heads']}")
t2, items2 = first["sl"].get(u2 * 8 + 1, (None, []))
check([it[0] for it in items2] == [8102, 8103] and items2[0][1] == iid["iron-plate"] and items2[0][2] == 64 and items2[0][3] == 1
      and isinstance(t2, int) and t2 > 0 and first["qu"] == [8103, "rare"],
      f"bs sl: a lane's items front first, [uid, item, position (1/256), stack], with the tick it was read; qu: {t2} {items2} {first['qu']}")
meta = first["lm"].get(u2 * 8 + 1, [])
check(meta[:3] == [1, 256, 8] and meta[-1] == 0, f"bs lm: kind 1 (straight), length 256, step (1/256 a tick), next 0: {meta}")
# Depth first: sb3 (ring 2) is loaded before sb2 (ring 1) that feeds it, so sb2 never leads out.
check(first["sl"].get(u3 * 8 + 1, (1 << 60,))[0] <= first["sl"].get(u2 * 8 + 1, (0,))[0],
      f"bs: a belt is loaded after the belts it feeds: sb3 at {first['sl'].get(u3 * 8 + 1, (None,))[0]}, sb2 at {first['sl'].get(u2 * 8 + 1, (None,))[0]}")
# A belt feeding one outside the square leads out: its lanes' next is -1.
check(first["lm"].get(ux * 8 + 1, [0] * 11)[-1] == -1 and first["lm"].get(ux * 8 + 2, [0] * 11)[-1] == -1
      and uy * 8 + 1 not in first["lm"],
      f"bs lm: a lane leading out of the square has next -1: {first['lm'].get(ux * 8 + 1)}")
# (The older checks below look at single lanes: the reads round them come back at the end.)
bs_mod.tails = False
bs_mod.settle_around = False
lm_of = lambda k: first["lm"].get(k, [0] * 11)
check(lm_of(ui * 8 + 1)[0] == 3 and lm_of(ui * 8 + 1)[-1] == ui * 8 + 3 and lm_of(ui * 8 + 3)[0] == 4 and lm_of(ui * 8 + 3)[-1] == uo * 8 + 1
      and lm_of(uo * 8 + 3)[0] == 8 and lm_of(uo * 8 + 1)[-1] == 0,
      f"bs lm: an entrance's lines 1-2 go on into its hidden 3-4, those into the exit's 1-2: {[lm_of(k) for k in (ui * 8 + 1, ui * 8 + 3, uo * 8 + 1, uo * 8 + 3)]}")
check([lm_of(ul * 8 + i)[0] for i in (1, 2, 3, 4)] == [5, 5, 6, 6],
      f"bs lm: a lane splitter's lines 1-2 are splitter inputs (5), 3-4 outputs (6): {[lm_of(ul * 8 + i) for i in (1, 2, 3, 4)]}")
# A watched lane that changed is sent again with its read tick; an unwatched one isn't.
F.move_on_belt(sb2, 1, 8102, None)
F.move_on_belt(sb3, 2, 8104, 0.25)
tick(12)
changed = bs_of(take())
check(u2 * 8 + 1 in changed["sl"] and [it[0] for it in changed["sl"][u2 * 8 + 1][1]] == [8103]
      and changed["sl"][u2 * 8 + 1][0] > t2 and u3 * 8 + 2 not in changed["sl"] and u2 * 8 + 1 not in changed["lm"],
      f"bs: a watched lane that changed is sent (sl, its tick, no lm), an unwatched one isn't: {sorted(changed['sl'])}")
# A watched lane whose items all moved on alike, nothing coming or going, isn't sent: the client
# simulates that.
F.move_on_belt(sb1, 1, 8101, 0.375)
tick(6)
flowed = bs_of(take())
check(u1 * 8 + 1 not in flowed["sl"], f"bs: a watched lane that only flowed on isn't sent: {sorted(flowed['sl'])}")
# Drift checks: every unwatched lane's count, front and back about every pc_every updates.
bs_mod.pc_every = 1
tick(12)
drift = bs_of(take())
bs_mod.pc_every = 1000
check(drift["pc"].get(u3 * 8 + 2, [0])[1:] == [1, 64, 64] and drift["pc"].get(u3 * 8 + 1, [0])[1:] == [0, -1, -1],
      f"bs pc: [tick, count, front, back] for lanes not watched (-1, -1 when empty): {drift['pc'].get(u3 * 8 + 2)} {drift['pc'].get(u3 * 8 + 1)}")
check(drift["pu"].get(u3 * 8 + 2) == [8104, 8104] and u3 * 8 + 1 not in drift["pu"],
      f"bs pu: a packed lane's drift check carries its front and back items' ids, an empty one none: {drift['pu']}")
# pc_ids: those ids even when the accuracy extras' share (extra_units) has no room (off: only with room).
bs_mod.pc_every = 1
saved_extra = bs_mod.extra_units
bs_mod.extra_units = 0
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "pc_ids on"}))
tick(12)
drift_on = bs_of(take())
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "pc_ids default"}))
tick(12)
drift_off = bs_of(take())
bs_mod.extra_units = saved_extra
bs_mod.pc_every = 1000
check(drift_on["pu"].get(u3 * 8 + 2) == [8104, 8104] and u3 * 8 + 2 in drift_off["pc"],
      f"bs pc_ids: a packed lane's drift check carries its ids with no extra share left: {drift_on['pu']} {drift_off['pc'].get(u3 * 8 + 2)}")
# drift_watched: a watched belt's lanes get drift checks too (off: none, as before). (quiet_pc off: its checks every
# turn, as these look for one in a window; quiet_pc's own checks follow.)
bs_mod.pc_every = 1
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "quiet_pc off"}))
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "drift_watched on"}))
tick(12)
take()  # (an update's work list is made on the tick after the one before is sent)
tick(12)
dw_on = bs_of(take())
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "drift_watched off"}))
tick(12)
take()
tick(12)
dw_off = bs_of(take())
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "drift_watched default"}))
bs_mod.pc_every = 1000
check(uw * 8 + 1 in dw_on["pc"] and uw * 8 + 1 not in dw_off["pc"] and u3 * 8 + 2 in dw_off["pc"],
      f"bs drift_watched: a watched lane's drift check is sent with it on, not off; an unwatched one's either way: "
      f"{dw_on['pc'].get(uw * 8 + 1)} {dw_off['pc'].get(uw * 8 + 1)}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "quiet_pc default"}))


# quiet_pc (on by default): an unwatched belt whose drift checks keep agreeing has each next one twice as far off, up
# to quiet_pc_max ticks; any touch (a full read of its lanes, a `bre`, a watched belt behind it changing) puts it back
# to every turn. (sb3: unwatched, fed by sb2, a pickup and drop belt; tails are off here, so only the wake reaches it.)
def pc_ticks(ticks, key):
    """The ticks of `key`'s drift checks over `ticks` ticks."""
    got = []
    for j in range(ticks // 6):
        if j % 10 == 0:
            # (The same hello again: the session drops a client it hasn't heard a hello from in 600 ticks.)
            send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1, "bs": 1})
        tick(6)
        for m in of_type(take(), "bs"):
            pc = m.get("pc", [])
            got += [pc[i + 1] for i in range(0, len(pc), 5) if pc[i] == key]
    return got


def gaps(ts):
    return [b - a for a, b in zip(ts, ts[1:])]


q_key = u3 * 8 + 2
bs_mod.pc_every = 1
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "quiet_pc_max 200"}))
take()
q_on = gaps(pc_ticks(600, q_key))
q_rec = lambda f: lua.eval(f"storage.f3d.bs.belts[{u3}].{f}")
check(len(q_on) >= 4 and all(b >= a for a, b in zip(q_on, q_on[1:])) and q_on[-1] > 2 * q_on[0]
      and max(q_on) <= 200 + 6 and q_rec("qw") == 200,
      f"bs quiet_pc: an untouched lane's drift checks come further apart each time, up to quiet_pc_max (200): gaps {q_on}, qw {q_rec('qw')}")
# A `bre` for it: read in full, back to every turn.
send({"t": "bre", "l": [q_key]})
tick(12)
take()
check(q_rec("qw") is None, f"bs quiet_pc: a lane read again for the client (bre) is woken: qw {q_rec('qw')}")
q_after = gaps(pc_ticks(60, q_key))
check(q_after and q_after[0] <= q_on[0] + 6, f"bs quiet_pc: and checked every turn again: gaps {q_after} (first quiet {q_on})")
# A watched belt behind it that changed wakes it (its tails' reach), read or not.
pc_ticks(300, q_key)
qw_before, woken0 = q_rec("qw"), int(bs_mod.counts["woken"] or 0)
F.put_on_belt(sb2, 1, "iron-plate", 0.9, 8199)
tick(66)  # (sb2, quiet, is checked again within spot_quiet_ticks)
take()
qw_now = q_rec("qw")
check(qw_before and qw_before > 48 and int(bs_mod.counts["woken"]) > woken0 and (qw_now is None or qw_now <= 48),
      f"bs quiet_pc: a watched belt behind it (sb2) that changed wakes it (its checks starting over): qw {qw_before} -> {qw_now}")
F.move_on_belt(sb2, 1, 8199, None)
tick(12)
take()
# The cap: never more than quiet_pc_max apart (0: every turn).
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "quiet_pc_max 0"}))
q_zero = gaps(pc_ticks(300, q_key))[-4:]
check(q_zero and max(q_zero) <= 12, f"bs quiet_pc_max 0: every turn: gaps {q_zero}")
# Off: every turn, as before.
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "quiet_pc_max default"}))
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "quiet_pc off"}))
q_off = gaps(pc_ticks(300, q_key))
check(q_off and max(q_off) <= 12, f"bs quiet_pc off: every turn, as before: gaps {q_off}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "quiet_pc default"}))
said_q = str(bs_mod.option_command("")[1])
check("quiet_pc on" in said_q and "quiet_pc_max 3600" in said_q, "/f3d-bs lists quiet_pc (on) and quiet_pc_max (3600: a minute)")
# A splitter set again wakes the belts after it (tracker.configured, from a paste, its window or Zenith's screen).
lua.eval('package.loaded["scripts.tracker"].configured')(s_lane)
# Step 1: full reads counted by cause, watched or not (/f3d-bs reads).
said_reads = str(bs_mod.option_command("reads")[1])
check("bs reads" in said_reads and "asked=" in said_reads and "load=" in said_reads and "pc_quiet=" in said_reads
      and int(bs_mod.counts["ru_asked"] or 0) >= 1,
      f"/f3d-bs reads: full reads by cause (watched/unwatched) and the drift checks skipped: {said_reads}")
bs_mod.pc_every = 1000
take()
# bre: lanes the client has otherwise are read in full (with their meta) in the next update made.
# (Each update's work list is made on the tick after the one before is sent: a change shows the
# update after.)
send({"t": "bre", "l": [u3 * 8 + 2]})
tick(12)
again = bs_of(take())
check([it[0] for it in again["sl"].get(u3 * 8 + 2, (0, []))[1]] == [8104] and u3 * 8 + 2 in again["lm"],
      f"bs bre: a lane asked for again is sent in full with its meta: {again['sl'].get(u3 * 8 + 2)}")
check(again["lm"].get(u3 * 8 + 2) == first["lm"].get(u3 * 8 + 2),
      f"bs bre: the meta sent again (from the lane's kept meta, perfbridge2) is the first load's: {again['lm'].get(u3 * 8 + 2)} vs {first['lm'].get(u3 * 8 + 2)}")
said_counts = bs_mod.option_command("counts")
check("bs counts" in str(said_counts[1]) and "read=" in str(said_counts[1]), f"/f3d-bs counts says what was read and checked: {said_counts[1]}")
check("extra_spread on" in str(bs_mod.option_command("")[1]), "/f3d-bs lists extra_spread (on)")
# A belt switched off by the circuit network (of), and on again.
s_wired.status = g.defines.entity_status.disabled_by_control_behavior
tick(12)
off = bs_of(take())["of"]
s_wired.status = g.defines.entity_status.working
tick(12)
on = bs_of(take())["of"]
check(off == [uw, 1] and on == [uw, 0], f"bs of: a wired belt switched off, then on: {off} {on}")
# A lane leading out is checked on every update's tick and sent when it changed at all, flowing on
# too (the client's front there moves only where the bridge's reads say).
F.move_on_belt(sx, 1, 8105, 0.25)
tick(6)
edge = bs_of(take())
heads = edge["heads"]
check(edge["ew"].get(ux * 8 + 1) == [heads[-1][0] if heads else None, 8105, 64] and ux * 8 + 1 not in edge["sl"],
      f"bs ew: a lane leading out that only flowed sends its wall, read on the update's tick: {edge['ew']} {heads}")
# Something came onto it: read in full (sl).
F.put_on_belt(sx, 1, "copper-plate", 0.75, 8107)
tick(6)
edge2 = bs_of(take())
check([it[0] for it in edge2["sl"].get(ux * 8 + 1, (None, []))[1]] == [8105, 8107],
      f"bs: a lane leading out that something came onto is sent in full: {edge2['sl'].get(ux * 8 + 1)} {edge2['ew']}")
# A lane fed from outside what is sent: checked on every update's tick with no quiet spells, and sent
# whenever it changed, its items only moving on too (what comes in at its back is news to the client).
uz, uf = int(fz.unit_number), int(fw.unit_number)
check(lua.eval(f"storage.f3d.bs.iset[{uf}]") and not lua.eval(f"storage.f3d.bs.iset[{uz}]"),
      "bs: a belt fed by one outside the square is fed from outside")
tick(6 * (bs_mod.quiet_after + 3))
take()
F.move_on_belt(fw, 1, 8120, 0.375)
tick(6)
fed = bs_of(take())
fed_heads = fed["heads"]
check([it[0] for it in fed["sl"].get(uf * 8 + 1, (None, []))[1]] == [8120]
      and fed["sl"][uf * 8 + 1][0] == (fed_heads[-1][0] if fed_heads else None),
      f"bs: a lane fed from outside that only flowed on is sent, read on the update's tick: {fed['sl'].get(uf * 8 + 1)} {fed_heads}")
F.put_on_belt(fw, 1, "copper-plate", 0.875, 8121)
tick(6)
fed2 = bs_of(take())
check([it[0] for it in fed2["sl"].get(uf * 8 + 1, (None, []))[1]] == [8120, 8121],
      f"bs: what came in at the back of a lane fed from outside is sent: {fed2['sl'].get(uf * 8 + 1)}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "feed_edges off"}))
tick(6 * (bs_mod.quiet_after + 3))
take()
F.move_on_belt(fw, 1, 8120, 0.25)
F.move_on_belt(fw, 1, 8121, 0.75)
tick(6)
fed_off = bs_of(take())
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "feed_edges on"}))
check(uf * 8 + 1 not in fed_off["sl"], f"bs: feed_edges off: a quiet lane fed from outside that only flowed isn't sent (as before): {fed_off['sl'].get(uf * 8 + 1)}")
# bre: a lane in a packed run is read with the run's belts, ahead and behind, on the same tick; two
# lanes asked on belts next to each other are read on one tick.
ur = [int(e.unit_number) for e in runs]
send({"t": "bre", "l": [ur[1] * 8 + 1]})
tick(12)
run = bs_of(take())
t_run = run["sl"].get(ur[1] * 8 + 1, (None,))[0]
check(t_run and all(run["sl"].get(u * 8 + 1, (None,))[0] == t_run for u in ur)
      and [it[0] for it in run["sl"][ur[2] * 8 + 1][1]] == [8138, 8139, 8140, 8141],
      f"bs bre: a lane is read with the packed run it belongs to on the same tick: {[run['sl'].get(u * 8 + 1) for u in ur]}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "line_rereads off"}))
send({"t": "bre", "l": [ur[1] * 8 + 1]})
tick(12)
alone = bs_of(take())
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "line_rereads on"}))
check(ur[1] * 8 + 1 in alone["sl"] and ur[0] * 8 + 1 not in alone["sl"] and ur[2] * 8 + 1 not in alone["sl"],
      f"bs: line_rereads off: a bre lane is read alone (as before): {sorted(alone['sl'])}")
bs_mod.run_belts = 0
send({"t": "bre", "l": [ur[0] * 8 + 1, ur[2] * 8 + 1, ur[1] * 8 + 2]})
tick(12)
grouped = bs_of(take())
bs_mod.run_belts = 6
t_g = [grouped["sl"].get(k, (None,))[0] for k in (ur[0] * 8 + 1, ur[2] * 8 + 1, ur[1] * 8 + 2)]
check(t_g[0] and t_g[0] == t_g[1] == t_g[2],
      f"bs bre: lanes asked on belts next to each other are read on one tick: {t_g}")
# bre_cap: at most that many asked lanes an update, the rest in the next.
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "bre_cap 2"}))
bs_mod.run_belts = 0
send({"t": "bre", "l": [ur[0] * 8 + 1, ur[1] * 8 + 1, ur[2] * 8 + 1]})
tick(18)
capped_bre = bs_of(take())
bs_mod.run_belts = 6
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "bre_cap default"}))
t_c = sorted(capped_bre["sl"].get(u * 8 + 1, (None,))[0] or 0 for u in ur)
check(t_c[0] > 0 and t_c[0] == t_c[1] < t_c[2],
      f"bs bre_cap: asked lanes over the cap wait for the next update: {t_c}")
# The client's Belt updates (bfar m, the old cap) don't bound the square: every belt within n is sent.
lua.execute("storage.f3d.bi_cap = 5 storage.f3d.bs.rescan = true")
tick(24)
capped = bs_of(take())
check(capped["heads"] and capped["heads"][-1][3] == 16 and not (keys & set(capped["dl"])),
      f"bs: bfar m doesn't bound the square: {capped['heads'][-1:]} dropped {sorted(keys & set(capped['dl']))}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "full_area off"}))
tick(24)
capped_old = bs_of(take())
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "full_area on"}))
lua.execute("storage.f3d.bi_cap = nil")
tick(24)
take()
check(capped_old["heads"] and capped_old["heads"][-1][3] < 16,
      f"bs: full_area off: the client's cap bounds the square again (as before): {capped_old['heads'][-1:]}")
# The bridge's own bound: over it, the square is cut from the outside (fr says so; the lanes past it
# go, those inside stay); well under it again, it grows back.
bs_mod.bound, bs_mod.bound_min = 1, 4
tick(6 * 12)
cut = bs_of(take())
cut_fr = cut["heads"][-1][3] if cut["heads"] else None
inner = {u * 8 + i for u in (u1, u2, u3) for i in (1, 2)}
check(cut_fr is not None and cut_fr < 16 and uf * 8 + 1 in cut["dl"] and not (inner & set(cut["dl"])),
      f"bs: over the bound the square is cut from the outside: fr {cut_fr}, dropped {sorted(cut['dl'])[:8]}")
bs_mod.bound, bs_mod.bound_min = None, 16
grown_msgs = []
for _ in range(12):  # (with the hello as keep-alive)
    send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1, "bs": 1})
    tick(60)
    grown_msgs += take()
grown = bs_of(grown_msgs)
check(grown["heads"] and grown["heads"][-1][3] == 16 and uf * 8 + 1 in grown["lm"],
      f"bs: under the bound the square grows back: {grown['heads'][-1:]}")
# Tails: an inserter put on its drop belt (its hand holds less): the belt is checked at once though
# quiet, and the belts it feeds are read in the same update (after the input spots' checks).
# (actor_backoff off: the inserter has stood for a while, so it would be checked an update later.)
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "actor_backoff off"}))
bs_mod.tails = True
F.put_on_belt(sb2, 2, "iron-plate", 0.5, 8106)
F.set_hand(s_drop, bx + 1, by - 0.5, None)
tick(12)
tails = bs_of(take())
t_sb2 = tails["sl"].get(u2 * 8 + 2, (None,))[0]
check(t_sb2 and tails["sl"].get(u3 * 8 + 1, (None,))[0] == t_sb2 and tails["sl"].get(u3 * 8 + 2, (None,))[0] == t_sb2,
      f"bs tails: the belt a changed input spot feeds is read on the same tick: {t_sb2} {tails['sl'].get(u3 * 8 + 1)}")
# Settled: a watched lane unchanged for quiet_after checks after it changed is sent once more, and
# the belts round it (sb3 it feeds) with it. With settled_flow_only on (the default), a lane already
# sent by `sl` (`rec[14]`) isn't redundantly re-read when it stands, while one that flowed under
# skip_flow still settles with `settle_around`.
bs_mod.settle_around = True
bs_mod.spot_quiet_ticks = 0
tick(6 * (bs_mod.quiet_after + 2))
check(u2 * 8 + 2 not in bs_of(take())["sl"],
      "bs settled_flow_only: a lane already sent by sl isn't re-read on settle")
F.move_on_belt(sb2, 2, 8106, 0.25)
tick(12)
check(u2 * 8 + 2 not in bs_of(take())["sl"], "bs skip_flow: uniform forward shift isn't read right away")
tick(6 * (bs_mod.quiet_after + 2))
settle = bs_of(take())
t_set = settle["sl"].get(u2 * 8 + 2, (None,))[0]
check(t_set and t_set > t_sb2 and [it[0] for it in settle["sl"][u2 * 8 + 2][1]] == [8106]
      and (settle["sl"].get(u3 * 8 + 1, (None,))[0] or 0) >= t_set,
      f"bs: a watched lane that settled after flow is sent once more, with the belts round it: {settle['sl'].get(u2 * 8 + 2)} {settle['sl'].get(u3 * 8 + 1)}")
tick(6 * (bs_mod.quiet_after + 2))
check(u2 * 8 + 2 not in bs_of(take())["sl"], "bs: a settled lane isn't sent again while it stands")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "settled_flow_only off"}))
F.move_on_belt(sb2, 2, 8106, 0.375)
tick(12)
t_sb2_off = bs_of(take())["sl"].get(u2 * 8 + 2, (None,))[0]
check(t_sb2_off is not None, "bs settled_flow_only off: backward move is read by sl")
tick(6 * (bs_mod.quiet_after + 2))
settle_off = bs_of(take())
check((settle_off["sl"].get(u2 * 8 + 2, (None,))[0] or 0) > t_sb2_off,
      f"bs settled_flow_only off: settled re-read still fires as before: {settle_off['sl'].get(u2 * 8 + 2)}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "settled_flow_only default"}))
bs_mod.spot_quiet_ticks = 60
# actor_backoff: an inserter whose hand stood for a while is checked every other update; when it
# puts on its quiet belt that is still read within two updates.
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "actor_backoff on"}))
F.set_hand(s_drop, bx + 1, by - 1, "iron-plate")
tick(6 * 10)
take()
skipped0 = bs_mod.counts.actors_skipped or 0
tick(6 * 4)
take()
skipped1 = bs_mod.counts.actors_skipped or 0
check(skipped1 - skipped0 >= 2, f"bs actor_backoff: a standing hand is checked less often: {skipped0} -> {skipped1}")
F.put_on_belt(sb2, 2, "iron-plate", 0.75, 8109)
F.set_hand(s_drop, bx + 1, by - 0.5, None)
tick(12)
late = bs_of(take())
check(8109 in [it[0] for it in late["sl"].get(u2 * 8 + 2, (None, []))[1]],
      f"bs actor_backoff: what a standing inserter put on its quiet belt is sent within two updates: {late['sl'].get(u2 * 8 + 2)}")
# (--inserter-handoff) A hello with `ie` and `ho`: a hand that put on a belt is followed by a placed record
# (6: lane key, line position, the item's unique_id, item, stack, belt), the newest item next to the hand;
# without `ho` none.
def placed_records(msgs, who):
    out = []
    for m in of_type(msgs, "ie"):
        l = list(m["l"])
        if m.get("z") == 1:
            for i in range(9, len(l)):
                l[i] += l[i - 9]  # (delta-coded: each number against the record before)
        for i in range(0, len(l), 9):
            if l[i] == 6 and l[i + 1] == who:
                out.append(l[i:i + 9])
    return out


u_sd = int(s_drop.unit_number)
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1, "bs": 1, "ie": 2, "ho": 1})
F.set_hand(s_drop, bx + 1, by - 1, "iron-plate")
tick(30)
take()
F.put_on_belt(sb2, 2, "iron-plate", 0.9, 8112)
F.set_hand(s_drop, bx + 0.6, by + 0.234, None)
tick(12)
pl = placed_records(take(), u_sd)
check(pl and pl[0][3] == u2 * 8 + 2 and pl[0][4] == 230 and pl[0][5] == 8112 and pl[0][6] == iid["iron-plate"] and pl[0][7] == 1
      and pl[0][8] == u2,
      f"ie placed (ho): the item a hand put on its belt, by lane, line position and unique_id: {pl[:1]}")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1, "bs": 1, "ie": 2})
F.set_hand(s_drop, bx + 1, by - 1, "iron-plate")
tick(30)
take()
F.put_on_belt(sb2, 1, "iron-plate", 0.9, 8113)
F.set_hand(s_drop, bx + 0.6, by - 0.234, None)
tick(12)
check(not placed_records(take(), u_sd), "ie placed: none for a hello without `ho`")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1, "bs": 1})
tick(12)
take()
# hold_inputs: a splitter's input found as its last read left it is sent in `sh` with its check's tick
# (an empty one isn't); once it changed it is read (sl) instead; with the switch off, never.
take()
tick(60)
held = bs_of(take())
check(ul * 8 + 1 in held["sh"] and held["sh"][ul * 8 + 1] > first["sl"][ul * 8 + 1][0] and ul * 8 + 2 not in held["sh"]
      and ul * 8 + 3 not in held["sh"] and ul * 8 + 1 not in held["sl"],
      f"bs sh: a lane splitter's input holding what its last read had is sent in sh, its empty input and its outputs not: {held['sh']}")
F.move_on_belt(s_lane, 1, 8150, None)
tick(60)
held2 = bs_of(take())
tick(60)
held2b = bs_of(take())
check(ul * 8 + 1 in held2["sl"] and ul * 8 + 1 not in held2b["sh"],
      f"bs sh: once it changed it is read again instead (and empty, not held): {held2['sh']} {held2b['sh']} {sorted(held2['sl'])}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "hold_inputs off"}))
tick(60)
held3 = bs_of(take())
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "hold_inputs default"}))
check(not held3["sh"], f"bs sh: none with /f3d-bs hold_inputs off: {held3['sh']}")
# Something built near belts: their lanes are sent again with lm and sl.
near = spawn("inserter", bx + 2, by - 1, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": near}))
tick(12)
rebuilt = bs_of(take())
check(u3 * 8 + 1 in rebuilt["lm"] and u3 * 8 + 1 in rebuilt["sl"], f"bs: belts near something built are sent again (lm, sl): {sorted(rebuilt['lm'])}")
# The focus moves away: the lanes leave the square (dl).
send({"t": "focus", "x": fixed(bx + 200), "y": fixed(by), "r": 48})
tick(12)
gone = bs_of(take())
check(keys <= set(gone["dl"]), f"bs dl: lanes out of the square are dropped: missing {sorted(keys - set(gone['dl']))}")
# ld: 1 while the square is still loading (one belt a tick here), then left out; w the steady work.
send({"t": "focus", "x": fixed(bx), "y": fixed(by), "r": 48})
bs_mod.reset()
bs_mod.load_cap = 1
wholes = []
for _ in range(60):
    tick(1)
    if g.storage.f3d.bs is not None:
        wholes.append(bool(g.storage.f3d.bs.whole))
bs_mod.load_cap = None
ld_msgs = take()
lds = [m.get("ld") for m in of_type(ld_msgs, "bs") if m.get("part", 1) == 1]
check(lds and lds[0] == 1 and lds[-1] is None, f"bs ld: 1 while the square is still loading, then left out: {lds}")
# (far_load_cap waits for that: the square marked loaded whole once the update without ld is made, not before.)
check(wholes and not wholes[0] and wholes[-1] and wholes.index(True) > 6,
      f"far_load_cap: the square counts as loaded whole only once an update finds it so: {wholes.count(False)} ticks before")
# crossings game: a splitter's output lanes are checked on every update even while they stand (never
# quiet), so what crossed is sent within an update; with sim (the default) a standing output goes quiet.
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "bs": 1})  # (keep the session alive through the ticks below)
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "crossings game"}))
said_x = lua.eval('package.loaded["scripts.belt_sim"]').option_command("crossings nonsense")
check("game, hints, sim or default" in str(said_x[1]) and "crossings game (set)" in str(said_x[2]),
      f"/f3d-bs crossings takes sim, game or hints and says so: {said_x[1]} / {said_x[2]}")
take()
tick(12)
x0 = bs_mod.counts.crossings or 0
tick(6 * 8)
take()
x1 = bs_mod.counts.crossings or 0
check(x1 - x0 >= 10, f"bs crossings game: the lane splitter's standing outputs are checked every update: {x0} -> {x1}")
F.put_on_belt(s_lane, 3, "iron-plate", 0.3, 8151)  # (as if an input's item crossed into output line 3)
tick(12)
crossed = bs_of(take())
check(8151 in [it[0] for it in crossed["sl"].get(ul * 8 + 3, (None, []))[1]],
      f"bs crossings game: an item that crossed into an output is sent within an update: {crossed['sl'].get(ul * 8 + 3)}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "crossings sim"}))
tick(6)
take()
x2 = bs_mod.counts.crossings or 0
tick(6 * 4)
x3 = bs_mod.counts.crossings or 0
check(x3 == x2, f"bs crossings sim: outputs aren't checked as crossings: {x2} -> {x3}")
# crossings hints (the default, the splitter crossing hints round): outputs are watched as under sim (quiet when
# standing, not checked as crossings), and when a side's outputs changed, unless it is packed with one kind, its hints
# go (sx: [unit, side, tick, out0, out1, in0, in1], a record per pair of output items, back first, the inputs' fronts
# in each), never its inputs read for it.
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "crossings default"}))
check(bs_mod.OPTIONS.crossings == "hints", f"bs crossings: hints is the default: {bs_mod.OPTIONS.crossings}")
tick(6)
take()
h0, hi0, hs0 = bs_mod.counts.crossings or 0, bs_mod.counts.crossing_inputs or 0, bs_mod.counts.sx or 0
tick(6 * 4)
h1 = bs_mod.counts.crossings or 0
standing = bs_of(take())
check(h1 == h0 and not standing["sx"], f"bs crossings hints: a mixed side's standing outputs aren't checked as crossings (they go quiet), no hints: {h0} -> {h1} {standing['sx']}")
F.put_on_belt(s_lane, 4, "copper-plate", 0.4, 8152)  # (as if an item crossed into half 1's output)
F.put_on_belt(s_lane, 2, "iron-plate", 0.2, 8153)  # (half 1's input front)
tick(60)  # (a quiet output is checked again within 48 ticks)
hinted_msgs = take()
hinted = bs_of(hinted_msgs)
hint = [r for r in hinted["sx"] if r[0] == ul]
check(hint and hint[0][1] == 0 and hint[0][2] > 0 and hint[0][3] == 8151 and hint[0][4] == 8152 and hint[0][5] == 0 and hint[0][6] == 8153
      and (bs_mod.counts.crossing_inputs or 0) == hi0 and (bs_mod.counts.sx or 0) > hs0,
      f"bs crossings hints: an output that changed sends the side's hint (outputs' items, inputs' fronts), no input read: {hinted['sx']}")
check(not [p for m in of_type(hinted_msgs, "bs") for p in protocol.problems(m)],
      f"bs sx: valid: {[p for m in of_type(hinted_msgs, 'bs') for p in protocol.problems(m)][:2]}")
# A side packed with one kind of item (four a lane, a gap apart, on every lane with items): no hints, outputs quiet.
for line, uids in ((1, []), (2, [8153]), (3, [8151]), (4, [8152])):
    for u in uids:
        F.move_on_belt(s_lane, line, u, None)
for line in (1, 3):
    for j in range(4):
        F.put_on_belt(s_lane, line, "iron-plate", 0.0625 + 0.25 * j, 8160 + line * 4 + j)
tick(60)
take()
p0, ps0 = bs_mod.counts.crossings or 0, bs_mod.counts.sx or 0
for j in range(4):  # (the output moves on evenly: changed, still packed with one kind)
    F.move_on_belt(s_lane, 3, 8172 + j, 0.03125 + 0.25 * j)
tick(60)
packed = bs_of(take())
check(not [r for r in packed["sx"] if r[0] == ul] and (bs_mod.counts.sx or 0) == ps0 and (bs_mod.counts.crossings or 0) == p0,
      f"bs crossings hints: a side packed with one kind sends no hints: {packed['sx']} ({p0} -> {bs_mod.counts.crossings})")
# A real splitter's lanes (lines = 8): inputs 179 long, outputs 128, so two items fill each (packed_n). Side 0 (lines
# 1, 3 in, 5, 7 out), side 1 (2, 4 in, 6, 8 out).
sp8 = spawn("splitter", bx + 3, by - 3, force="player", direction=4, lines=8)
u8 = int(sp8.unit_number)
lens8 = [fixed(sp8.get_transport_line(i).line_length) for i in (1, 5)]
check(lens8 == [179, 128], f"fake splitter (lines = 8): inputs 179 long, outputs 128: {lens8}")
F["raise"]("script_raised_built", lua.table_from({"entity": sp8}))
# Side 0: its outputs packed with one kind of item, stacked (4 a stack: Space Age's stacked belts), two each.
for line in (5, 7):
    for j in range(2):
        F.put_on_belt(sp8, line, "iron-plate", 0.125 + 0.25 * j, 8200 + line * 4 + j, None, None, 4)
# Side 1: output 6 packed with mixed items, output 8 empty.
F.put_on_belt(sp8, 6, "iron-plate", 0.125, 8230)
F.put_on_belt(sp8, 6, "copper-plate", 0.375, 8231)
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "bs": 1})  # (keep the session alive)
tick(150)
take()
lanes8 = g.storage.f3d.bs.lanes
r5 = lanes8[u8 * 8 + 5]
check(r5 is not None and r5[9] == 128 and r5[1] == 2 and r5[4] == 8 and r5[17],
      f"bs crossings hints: a stacked lane of one kind keeps its kind (rec[17]): {r5 and [r5[1], r5[4], r5[9], r5[17]]}")
s0, i0_, sh0 = bs_mod.counts.sx or 0, bs_mod.counts.hint_ids or 0, bs_mod.counts.hint_shifts or 0
for line in (5, 7):  # (side 0 moves on evenly: still packed end to end with one kind)
    for j in range(2):
        F.move_on_belt(sp8, line, 8200 + line * 4 + j, 0.0625 + 0.25 * j)
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "bs": 1})  # (keep the session alive)
tick(60)
st8 = bs_of(take())
check(not [r for r in st8["sx"] if r[0] == u8 and r[1] == 0],
      f"bs crossings hints: a real splitter's side packed with one stacked kind (2 a lane) sends no hints: {st8['sx']}")
# Side 1's packed mixed output flows a gap on: the front item left, the next took its place, one more came in at the
# back. Count and places are the same: its ids show it, and only its hint goes (no sl of it).
F.move_on_belt(sp8, 6, 8230, None)
F.move_on_belt(sp8, 6, 8231, 0.125)
F.put_on_belt(sp8, 6, "iron-plate", 0.375, 8232)
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "bs": 1})  # (keep the session alive)
tick(60)
fl8 = bs_of(take())
h8 = [r for r in fl8["sx"] if r[0] == u8 and r[1] == 1]
check(h8 and h8[0][3] == 8232 and (bs_mod.counts.hint_shifts or 0) > sh0 and (bs_mod.counts.hint_ids or 0) > i0_
      and u8 * 8 + 6 not in fl8["sl"],
      f"bs crossings hints: a packed mixed output that flowed a gap sends its hint by its ids, no sl: {h8} {sorted(fl8['sl'])}")
# hints_active: none for a binary client below wire version 5 (it can't read them), for JSON and v5+ yes.
cl = g.storage.f3d.client
bin_was = cl.bin
cl.bin = 4
off4 = bs_mod.hints_active()
cl.bin = 5
on5 = bs_mod.hints_active()
cl.bin = None
onj = bs_mod.hints_active()
cl.bin = bin_was
check(off4 is False and on5 is True and onj is True, f"bs hints_active: a v4 binary client gets none, v5 and JSON do: {off4} {on5} {onj}")
# ... and with it off, no hint work at all: no sx, no id checks, even when a mixed output changes.
s1, i1_ = bs_mod.counts.sx or 0, bs_mod.counts.hint_ids or 0
F.put_on_belt(sp8, 8, "copper-plate", 0.25, 8233)
F.move_on_belt(sp8, 6, 8231, None)
F.move_on_belt(sp8, 6, 8232, 0.125)
F.put_on_belt(sp8, 6, "copper-plate", 0.375, 8234)
for _ in range(60):  # (a v4 binary client throughout)
    cl.bin = 4
    tick(1)
cl.bin = bin_was
take()
check((bs_mod.counts.sx or 0) == s1 and (bs_mod.counts.hint_ids or 0) == i1_,
      f"bs crossings hints: a binary client below v5 costs no hint work: sx {s1} -> {bs_mod.counts.sx}, ids {i1_} -> {bs_mod.counts.hint_ids}")
# hint_units: their own share. With extra_units spent (pc_ids, tails first) hints still go; hint_units spent or the
# square cut (bs.cut): hints and their id checks are skipped (sx_skipped), never over the round's share.
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "bs": 1})  # (keep the session alive)
tick(120)
take()
xu_was, hu_was = bs_mod.extra_units, bs_mod.hint_units
bs_mod.extra_units = -1  # (none ever left for the accuracy reads)
s2, k2 = bs_mod.counts.sx or 0, bs_mod.counts.sx_skipped or 0
F.move_on_belt(sp8, 8, 8233, None)
F.put_on_belt(sp8, 8, "iron-plate", 0.3, 8235)
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "bs": 1})  # (keep the session alive)
tick(60)
bs_mod.extra_units = xu_was
nb = bs_of(take())
check((bs_mod.counts.sx or 0) > s2 and [r for r in nb["sx"] if r[0] == u8],
      f"bs crossings hints: with no extra units left, hints still go within hint_units: sx {s2} -> {bs_mod.counts.sx}")
tick(120)
take()
bs_mod.hint_units = 0  # (their share spent)
s3, i3_, k3 = bs_mod.counts.sx or 0, bs_mod.counts.hint_ids or 0, bs_mod.counts.sx_skipped or 0
F.put_on_belt(sp8, 8, "copper-plate", 0.6, 8236)
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "bs": 1})  # (keep the session alive)
tick(60)
bs_mod.hint_units = hu_was
nb = bs_of(take())
check((bs_mod.counts.sx or 0) == s3 and (bs_mod.counts.hint_ids or 0) == i3_ and (bs_mod.counts.sx_skipped or 0) > k3
      and not [r for r in nb["sx"] if r[0] == u8],
      f"bs crossings hints: with hint_units spent, hints are skipped cleanly: sx {s3} -> {bs_mod.counts.sx}, skipped {k3} -> {bs_mod.counts.sx_skipped}")
tick(120)
take()
bsq = g.storage.f3d.bs
bsq.cut = 1000000  # (a cut square: far above any lane, so only hint_left sees it)
s4, i4_, k4 = bs_mod.counts.sx or 0, bs_mod.counts.hint_ids or 0, bs_mod.counts.sx_skipped or 0
F.put_on_belt(sp8, 8, "iron-plate", 0.8, 8237)
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "bs": 1})  # (keep the session alive)
for _ in range(60):  # (held every tick: the round logic would grow a cut back to none)
    bsq.cut = 1000000
    tick(1)
bsq.cut = None
nb = bs_of(take())
check((bs_mod.counts.sx or 0) == s4 and (bs_mod.counts.hint_ids or 0) == i4_ and (bs_mod.counts.sx_skipped or 0) > k4
      and not [r for r in nb["sx"] if r[0] == u8],
      f"bs crossings hints: a cut square (b.cut) sends no hints: sx {s4} -> {bs_mod.counts.sx}, skipped {k4} -> {bs_mod.counts.sx_skipped}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "crossings default"}))


# own_rate: the updates follow their own rate job (`bs`, tier 3, at most 12 ticks), so Hold 60 UPS's
# first levels don't make them stale (every update is a read of every input spot); off, `bi`'s as before.
# period_max (the belt-rate round): the longest period they are stretched to, 6 (never) by default, 0 the job's 12.
def bs_spacing(level, ticks):
    send({"t": "rate", "l": level})
    for _ in range(13):  # past the ease (a slow-down keeps the old ticks 120 more); the client kept alive
        tick(10)
        send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1, "bs": 1})
    take()
    for _ in range(ticks // 10):
        tick(10)
        send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1, "bs": 1})
    heads = [m for m in of_type(take(), "bs") if m.get("part", 1) == 1]
    ks = sorted({m["k"] for m in heads})
    return {b - a for a, b in zip(ks, ks[1:])}, {m.get("p") for m in heads}


bs_mod.pc_every = 1  # (a drift check every update, so a quiet world still sends one)
own = {level: bs_spacing(level, 150) for level in (1, 2, 3)}
check(own[1] == ({6}, {6}) and own[2] == ({6}, {6}) and own[3] == ({6}, {6}),
      f"bs own_rate, period_max 6: updates every 6 ticks at rate 1, 2 and 3, p saying so: {own}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "period_max 0"}))
own = {level: bs_spacing(level, 150) for level in (2, 3)}
check(own[2] == ({6}, {6}) and own[3] == ({12}, {12}),
      f"bs period_max 0: the job's own max, every 6 ticks at rate 2 and every 12 at 3: {own}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "period_max default"}))
tick(4)  # (the two spacings above are 560 ticks: the checks below keep their tick phase, 6 apart)
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "own_rate off"}))
old_rate = {level: bs_spacing(level, 150) for level in (1, 3)}
check(old_rate[1] == ({12}, {12}) and old_rate[3] == ({48}, {48}),
      f"bs own_rate off: the glided belt items' rate, 12 at 1 and 48 at 3, as before: {old_rate}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "own_rate default"}))
bs_mod.pc_every = 1000
send({"t": "rate", "l": 0})


# walk_load: while the square loaded whole reaches less than walk_near tiles of the focus (walking, a
# jump), first loads get at least walk_load units a tick; standing with it all loaded, their share as before.
walk_field = [spawn("transport-belt", 2000.5 + (k % 28) - 14, 2000.5 + k // 28 - 14, force="player", direction=4)
              for k in range(784)]
for k, e in enumerate(walk_field):
    F.put_on_belt(e, 1, "iron-plate", 0.25, 90000 + 2 * k)
    F.put_on_belt(e, 2, "iron-plate", 0.75, 90001 + 2 * k)


def walk_loaded(units, ticks):
    """Belts loaded after each tick from a reset, with walk_load at `units`."""
    F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "walk_load %d" % units}))
    send({"t": "focus", "x": fixed(2000.5), "y": fixed(2000.5), "r": 48})
    bs_mod.reset()
    c0 = bs_mod.counts.loaded
    out = []
    for t in range(ticks):
        tick(1)
        if t % 3 == 2:
            send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1, "bs": 1})
        out.append(bs_mod.counts.loaded - c0)
    take()
    return out


slow = walk_loaded(0, 30)
fast = walk_loaded(20000, 30)
# With load_budget on (default), b.thin walk_load uses full tick budget headroom (6000 vs slow's 3000 share)
# so it finishes significantly sooner (tick 5 vs tick 8) without exceeding the tick's budget limit.
check(fast[5] >= 784 and fast[3] > slow[3],
      f"bs walk_load: first loads get walk_load (budget-capped) units a tick while the view isn't loaded: {slow} / {fast}")
check(not lua.eval("storage.f3d.bs.thin"), "bs walk_load: the square all loaded isn't thin")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "walk_load default"}))


# send_cap: an update's parts are sent over the ticks after its due tick, about send_cap bytes a tick (one
# part at least), each still stamped with the update's tick; 0 sends them all on the due tick, as before.
def spooled_parts(cap, ticks):
    """[(tick, [(k, part, parts, bytes)...])] for every tick with bs parts, from a reset with send_cap at `cap`."""
    F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "send_cap %s" % cap}))
    F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "walk_load 100000"}))
    send({"t": "focus", "x": fixed(2000.5), "y": fixed(2000.5), "r": 48})
    bs_mod.reset()
    take()
    out = []
    for t in range(ticks):
        tick(1)
        rows = [(m["k"], m.get("part", 1), m.get("parts", 1), len(json.dumps(m, separators=(",", ":")))) for m in of_type(take(), "bs")]
        if rows:
            out.append((t, rows))
    F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "walk_load default"}))
    return out


burst = spooled_parts(0, 40)
spread = spooled_parts(20000, 40)
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "send_cap default"}))
big = [rows for _, rows in burst if len(rows) >= 3]
check(big and all(len({k for k, _, _, _ in rows}) == 1 and len(rows) == rows[0][2] for rows in big),
      f"bs send_cap 0: every update's parts go out on its due tick: {[(t, len(r)) for t, r in burst]}")
per_tick = [sum(b for _, _, _, b in rows) for _, rows in spread]
check(spread and max(per_tick) < 20000 + MAX_DATAGRAM / 2,
      f"bs send_cap 20000: a tick sends at most the cap and one part more: {per_tick}")
ks = {}
for t, rows in spread:
    for k, part, parts, _ in rows:
        ks.setdefault(k, {"parts": parts, "got": set(), "ticks": set()})
        ks[k]["got"].add(part)
        ks[k]["ticks"].add(t)
whole = [k for k, v in ks.items() if len(v["got"]) == v["parts"]]
check(len(whole) >= len(ks) - 1 and any(len(v["ticks"]) >= 2 for v in ks.values()),
      f"bs send_cap: every part of an update arrives, over more than one tick, stamped with its update's tick: {[(k, v['parts'], sorted(v['ticks'])) for k, v in ks.items()]}")
order = [k for _, rows in spread for k, _, _, _ in rows]
check(order == sorted(order), "bs send_cap: parts go out oldest update first")
for e in walk_field:
    e.destroy()
send({"t": "focus", "x": fixed(bx), "y": fixed(by), "r": 48})
bs_mod.reset()
tick(12)
take()
# Two simulating clients on one server (multiplayer: storage.f3d is swapped per client): each gets
# the lanes round its own focus. (Both clients' rounds start on the same ticks, and one update being
# built, module-local, was keyed by that tick alone: the first client sent both clients' lanes and the
# second nothing.)
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1, "bs": 1})
tick(12)
take()
was_mp = F.multiplayer
F.multiplayer = True  # (in single-player a hello from another port takes the one client's place)


def sync_r(by):
    """take()'s reliable counter after a take_by_port (which doesn't keep it)."""
    global expected_r
    rs = [m["r"] for m in by.get(CLIENT_PORT, []) if "r" in m]
    if rs:
        expected_r = rs[-1] + 1


ox, oy = 600.5, 600.5
other = [spawn("transport-belt", ox + k, oy, force="player", direction=4) for k in range(3)]
F.link_belts(other[0], other[1])
F.link_belts(other[1], other[2])
F.put_on_belt(other[1], 1, "iron-plate", 0.5, 8201)
other_ins = spawn("inserter", ox + 1, oy + 1, force="player")
other_ins.pickup_target = other[1]  # (watched: a change there is read)
other_keys = {int(e.unit_number) * 8 + i for e in other for i in (1, 2)}
send({"t": "hello", "v": 1, "sid": "b", "w": 0, "z": 1, "bl": 1, "bs": 1}, port=PORT_B)
tick(2)
send({"t": "focus", "x": fixed(ox), "y": fixed(oy), "r": 48}, port=PORT_B)
send({"t": "bfar", "r": 0, "n": 16, "m": 0}, port=PORT_B)
tick(30)
by_port = take_by_port()
sync_r(by_port)
bs_a, bs_b = bs_of(by_port.get(CLIENT_PORT, [])), bs_of(by_port.get(PORT_B, []))
check(other_keys <= set(bs_b["lm"]) and other_keys <= set(bs_b["sl"]) and not (other_keys & set(bs_a["lm"]))
      and not (set(bs_a["lm"]) & set(bs_b["lm"])),
      f"bs: two simulating clients each get the lanes round their own focus: second missing {sorted(other_keys - set(bs_b['lm']))}, first got {sorted(other_keys & set(bs_a['lm']))}")
# And an update after the first loads: a change at the second client's belts reaches it (its
# inserter took, so the input spot is woken; quiet, it is checked only every spot_quiet_ticks).
F.move_on_belt(other[1], 1, 8201, 0.25)
F.put_on_belt(other[1], 2, "copper-plate", 0.5, 8202)
F.set_hand(other_ins, ox + 1, oy + 0.5, "iron-plate")
tick(12)
by_port = take_by_port()
sync_r(by_port)
bs_b2 = bs_of(by_port.get(PORT_B, []))
ko = int(other[1].unit_number) * 8 + 2
check(8202 in [it[0] for it in bs_b2["sl"].get(ko, (None, []))[1]] and bs_b2["heads"],
      f"bs: the second client's updates carry its own changes: {bs_b2['sl'].get(ko)} {bs_b2['heads'][-1:]}")
send({"t": "bye"}, port=PORT_B)
tick(1)
take()
# The same for two clients that don't simulate (`bi`, main's 0.1.4 client with kept lanes): bi's one
# update being built was module-local by tick too, so two such clients' rounds on one tick sent both
# clients both clients' items.
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 0, "bl": 1})
send({"t": "hello", "v": 1, "sid": "b", "w": 0, "z": 0, "bl": 1}, port=PORT_B)
tick(2)
send({"t": "focus", "x": fixed(ox), "y": fixed(oy), "r": 48}, port=PORT_B)
send({"t": "bfar", "r": 0, "n": 16, "m": 0}, port=PORT_B)
tick(30)
by_port = take_by_port()
sync_r(by_port)


def bi_lanes(msgs):
    """The lane keys named by `ln` over the bi messages, and the unique ids of their items."""
    keys, ids = set(), set()
    for m in of_type(msgs, "bi"):
        ln = m.get("ln", [])
        keys |= {ln[i] for i in range(0, len(ln), 2)}
        items = m.get("l", [])
        ids |= {items[i] for i in range(0, len(items), 4)}
    return keys, ids


bi_a, bi_b = bi_lanes(by_port.get(CLIENT_PORT, [])), bi_lanes(by_port.get(PORT_B, []))
check(8201 in bi_b[1] and 8201 not in bi_a[1] and not (other_keys & bi_a[0]) and 8106 in bi_a[1] and 8106 not in bi_b[1],
      f"bi: two kept-lane clients each get the items round their own focus: first {sorted(bi_a[1])[:6]}, second {sorted(bi_b[1])[:6]}")
send({"t": "bye"}, port=PORT_B)
tick(1)
take()
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1, "bs": 1})
tick(12)
take()
F.multiplayer = was_mp
# The actors (inserters and drills using loaded belts) and the chunk caches (bs.bc, bs.bt) follow the
# square: those round belts that left it are forgotten when the scan is taken, and found again when
# it comes back. (They only ever grew as the focus moved, and every actor was checked every update.)
far_belt = spawn("transport-belt", bx + 200, by, force="player", direction=4)
far_ins = spawn("inserter", bx + 200, by + 1, force="player")
far_ins.pickup_target = far_belt
u_far, u_sins, u_sdrop, u_fins = int(far_belt.unit_number), int(s_ins.unit_number), int(s_drop.unit_number), int(far_ins.unit_number)
bs_keys = lua.eval("function(name) local t = {} for k in pairs(storage.f3d.bs[name] or {}) do t[#t + 1] = k end table.sort(t) return t end")
actors_now = lambda: set(to_py(bs_keys("actors")))
chunks_now = lambda name: set(to_py(bs_keys(name)))
check({u_sins, u_sdrop} <= actors_now(), f"bs: the inserters using the loaded belts are actors: {sorted(actors_now())}")
send({"t": "focus", "x": fixed(bx + 200), "y": fixed(by), "r": 48})
tick(30)
take()
far_ck = (int(math.floor((bx + 200) / 32)) + 32768) * 65536 + int(math.floor(by / 32)) + 32768
near_ck = (int(math.floor(bx / 32)) + 32768) * 65536 + int(math.floor(by / 32)) + 32768
check(not ({u_sins, u_sdrop} & actors_now()) and u_fins in actors_now()
      and near_ck not in chunks_now("bc") and near_ck not in chunks_now("bt") and far_ck in chunks_now("bc")
      and u_far in set(to_py(bs_keys("belts"))),
      f"bs: actors and chunk caches round belts that left the square are forgotten: actors {sorted(actors_now())}, bc {sorted(chunks_now('bc'))}, bt {sorted(chunks_now('bt'))}")
send({"t": "focus", "x": fixed(bx), "y": fixed(by), "r": 48})
tick(30)
back = bs_of(take())
alist_now = lambda: set(to_py(lua.eval("function() local t = {} for _, u in ipairs(storage.f3d.bs.alist) do t[#t + 1] = u end return t end")()))
check({u_sins, u_sdrop} <= actors_now() and u_fins not in actors_now() and u2 * 8 + 1 in back["lm"],
      f"bs: back in the square, its belts' actors are found again: {sorted(actors_now())}")
# (And listed again, so they are checked: the list is made again without the forgotten ones, else
# the seen set kept them off it for good.)
check({u_sins, u_sdrop} <= alist_now() and u_fins not in alist_now(),
      f"bs: actors found again are listed again for their checks: {sorted(alist_now())}")
F.set_hand(s_drop, bx + 1, by - 1, "iron-plate")  # (its hand held nothing: a change)
F.put_on_belt(sb2, 2, "iron-plate", 0.9, 8203)  # (behind the lane's items: the fake lists them as put)
tick(18)  # (actor_backoff: a hand that stood is checked every other update, so within two)
woke_back = bs_of(take())
check(8203 in [it[0] for it in woke_back["sl"].get(u2 * 8 + 2, (None, []))[1]],
      f"bs: an actor found again wakes its belt when it acts: {woke_back['sl'].get(u2 * 8 + 2)}")
far_belt.destroy()
far_ins.destroy()
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1})
send({"t": "bfar", "r": 0})
tick(6)
check(of_type(take(), "bi") and lua.eval("storage.f3d.bs") is None, "bs: a client that stops saying bs gets bi again")

# A square `sub` over the wire (what the client sends), after a list one: the chunks it adds come
# nearest its middle first, the ones it keeps aren't sent again, the rest are dropped. Last, so the
# checks above keep their phase of the periodic jobs.
send({"t": "sub", "c": [[0, 0], [1, 0], [9, 9]]})
tick(60)
# (Clear of what sends a subscribed chunk again whatever the client asks, so the check doesn't depend on the
# tick the tests above leave the game at: the 300-tick refresh, and the count of a chunk whose entities the
# tests above changed without an event, which came as a kept chunk sent again.)
world_mod = lua.eval('package.loaded["scripts.world"]')
saved_count_interval = world_mod.count_interval
world_mod.count_interval = 0
while g.game.tick % 300 != 150:  # (the refresh's chunk sent well before, the next one well after)
    tick(1)
take()
send({"t": "sub", "o": [0, 0], "r": 1, "w": [[-1, -1, 3], [0, -1, 3], [1, -1, 3]]})
tick(60)
got = [(m["cx"], m["cy"]) for m in of_type(take(), "chunk")]
check(sorted(got) == sorted({(x, y) for x in (-1, 0, 1) for y in (-1, 0, 1)} - {(0, 0), (1, 0)}) and got[:1] == [(0, -1)]
      and g.storage.f3d.subs["9,9"] is None,
      f"a square `sub` over the wire adds its new chunks nearest first and drops what it leaves out: {got}")
world_mod.count_interval = saved_count_interval

# D6 (last: its ticks would shift the periodic jobs' phase for the checks above): a client that says dq
# gets every datagram numbered: its last line is {"t":"dg","n":N,"k":tick,"b":bytes before it}, N counting
# up without gaps, so the client can count the datagrams the OS dropped. (JSON lines even with --binary: bin 0;
# binary datagrams' dg frame is test_binary.py's.)
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "b": 1, "dq": 1, "bin": 0})
tick(1)
take()
raw = []
for _ in range(6):
    tick(1)
    for item in F.take_sent().values():
        raw.append(item[2])
numbers = []
for data in raw:
    lines = data.split("\n")
    tail = json.loads(lines[-1])
    check(tail.get("t") == "dg" and isinstance(tail.get("n"), int), f"dq: a datagram's last line is its dg number: {lines[-1][:80]}")
    check(tail.get("b") == len(data) - len(lines[-1]) - 1, f"dq: dg.b is the bytes before the dg line: {tail.get('b')} vs {len(data) - len(lines[-1]) - 1}")
    check(len(data) <= MAX_DATAGRAM, f"dq: datagram too large with the dg line: {len(data)} bytes")
    numbers.append(tail.get("n"))
check(len(numbers) >= 6 and numbers == list(range(numbers[0], numbers[0] + len(numbers))), f"dq: datagrams numbered without gaps: {numbers[:12]}")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "b": 1})
tick(1)
take()
tick(3)
for item in F.take_sent().values():
    check('"t":"dg"' not in item[2], "without dq, no dg line")

# --- the 0.2.1 performance hotfix (perf.lua's /f3d-perf switches; belt_sim.lua's housekeeping, /f3d-bs) ----
# Last, as its ticks would shift the periodic jobs' phases for the checks above.
perf_mod = g.package.loaded["scripts.perf"]
world_mod = g.package.loaded["scripts.world"]
transport_mod = g.package.loaded["scripts.transport"]


def set_perf(**switches):
    g.storage.f3d_perf = lua.table_from(switches) if switches else None


hello_now = {"t": "hello", "v": 1, "sid": "s1", "w": 1, "b": 1}


def say(**flags):
    """The hello these checks keep sending (a client unheard for 600 ticks is dropped)."""
    global hello_now
    hello_now = dict({"t": "hello", "v": 1, "sid": "s1", "w": 1}, **flags)
    send(hello_now)


def alive(n=1):
    for _ in range(n):
        if g.game.tick % 100 == 0:
            send(hello_now)
        tick(1)


def no_empty_dicts(v):
    """helpers.table_to_json writes an empty table as {}, the text as []: the client reads both alike."""
    if isinstance(v, dict):
        return {k: no_empty_dicts(x) for k, x in v.items()} if v else []
    if isinstance(v, list):
        return [no_empty_dicts(x) for x in v]
    return v


# 1. Chunk snapshots written as text: the same messages as before, field for field.
odd = spawn("train-stop", 50.0, 20.0, force="player", backer_name='Stop "A" \\ é\n[item=iron-plate]')
F.add_decorative(F.surface, "small-rock", 41, 6, 3)
say(b=1, dc=1)
send({"t": "sub", "c": [[0, 0], [1, 0], [2, 0], [9, 9]]})
alive(40)
take()


def chunk_msgs(text):
    set_perf(chunk_text=text)
    send({"t": "resync", "c": [[0, 0], [1, 0], [2, 0], [9, 9]]})
    alive(40)
    out = {}
    for m in take():
        if m.get("t") in ("chunk", "ents", "dec"):
            m = no_empty_dicts({k: v for k, v in m.items() if k not in ("r", "k")})
            out[(m["t"], m["cx"], m["cy"], m.get("part"))] = m
    return out


as_text, as_tables = chunk_msgs(True), chunk_msgs(False)
set_perf()
check(as_text == as_tables and ("ents", 1, 0, 1) in as_text and ("dec", 1, 0, 1) in as_text and ("chunk", 9, 9, None) in as_text,
      f"chunk_text: chunk, ents and dec written as text are the messages table_to_json wrote: "
      f"{sorted(set(as_text) ^ set(as_tables))} {[k for k in as_text if as_text.get(k) != as_tables.get(k)][:3]}")
stop_rec = [r for r in as_text.get(("ents", 1, 0, 1), {}).get("e", []) if r[0] == odd.unit_number]
check(stop_rec and stop_rec[0][5].get("n") == 'Stop "A" \\ é\n[item=iron-plate]',
      f"chunk_text: a name with quotes, a backslash, a newline and a non-ASCII letter comes through: {stop_rec}")
odd.destroy()
extras = json.loads(lua.eval(r"""function()
  local t = package.loaded["scripts.transport"]
  return t.json_object({ n = 'a"b\\c' .. string.char(1) .. "\t", w = { 3, 1, 2 }, col = { 255, 0, 10 }, d = 1,
    ai = { "item", "iron-plate" }, x = 0.5, big = 2 ^ 40 + 3, neg = -7, e = {}, ok = true })
end""")())
check(extras == {"n": 'a"b\\c\x01\t', "w": [3, 1, 2], "col": [255, 0, 10], "d": 1, "ai": ["item", "iron-plate"], "x": 0.5,
                 "big": 2 ** 40 + 3, "neg": -7, "e": [], "ok": True},
      f"chunk_text: a record's extras key by key, as JSON: {extras}")
check(lua.eval('function() return package.loaded["scripts.world"].record_text({ 5, 2, 256, -512, 4 }) end')() == "[5,2,256,-512,4]",
      "chunk_text: a record without extras is its five numbers")

# 7. The chunk queue: taken from its head (no table.remove shifting it), compacted as it goes; a long
# square queue put in a new order over ticks (requeue_slices), ending in the order it had at once.
queue_check = lua.eval("""function()
  local W = package.loaded["scripts.world"]
  local s = storage.f3d
  local saved = { s.subs, s.queue, s.queued, s.rank, s.order, s.have, s.sub_o, s.sub_r, s.sub_rows, s.sub_n, s.sub_f, s.rq, s.snap }
  local out = {}
  local rows = {}
  for cy = -20, 20 do
    rows[#rows + 1] = { cy, -20, 41 }
  end
  local function fresh()
    s.subs, s.queue, s.queued, s.rank, s.order, s.have = {}, {}, {}, {}, {}, {}
    s.sub_o, s.sub_r, s.sub_rows, s.sub_n, s.sub_f, s.rq, s.snap = nil, nil, nil, nil, nil, nil, nil
  end
  local function from_head()
    local t = {}
    for i = s.queue.h or 1, #s.queue do
      t[#t + 1] = s.queue[i]
    end
    return table.concat(t, " ")
  end
  local function finish()
    local steps = 0
    while s.rq do
      W.requeue_step(s, 1024)
      steps = steps + 1
    end
    return steps
  end
  -- Ordered at once (requeue_slices off) and over ticks with near_first off: the same order.
  storage.f3d_perf = { requeue_slices = false, near_first = false }
  fresh()
  W.subscribe_square({ 0, 0 }, 20, rows, nil, { 256, 0 })
  W.subscribe_square({ 0, 0 }, 20, rows, nil, { 0, 256 })
  local at_once = from_head()
  storage.f3d_perf = { near_first = false }
  fresh()
  W.subscribe_square({ 0, 0 }, 20, rows, nil, { 256, 0 })
  finish()
  local before = from_head()
  W.subscribe_square({ 0, 0 }, 20, rows, nil, { 0, 256 })
  out[#out + 1] = tostring(s.rq ~= nil and from_head() == before)  -- the packet handler only starts the job
  local steps = finish()
  out[#out + 1] = tostring(from_head() == at_once) .. " " .. steps
  -- Chunks taken while the job deals, one queued again meanwhile: the new order less those taken.
  W.subscribe_square({ 0, 0 }, 20, rows, nil, { -256, 0 })
  local taken = {}
  for i = 1, 5 do
    taken[i] = W.take_next()
  end
  W.requeue_step(s, 300)
  W.enqueue(taken[3])
  finish()
  storage.f3d_perf = { requeue_slices = false, near_first = false }
  local got = from_head()
  local s2 = {}
  fresh()
  W.subscribe_square({ 0, 0 }, 20, rows, nil, { -256, 0 })
  local want = {}
  local skip = { [taken[1]] = true, [taken[2]] = true, [taken[4]] = true, [taken[5]] = true }
  for i = s.queue.h or 1, #s.queue do
    if not skip[s.queue[i]] then
      want[#want + 1] = s.queue[i]
    end
  end
  out[#out + 1] = tostring(got == table.concat(want, " "))
  -- With near_first on (default), <=2 near ring sorts immediately ahead of s.rq and survives Phase 1->2 + enqueue.
  storage.f3d_perf = nil
  fresh()
  W.subscribe_square({ 0, 0 }, 20, rows, nil, { 256, 0 })
  finish()
  W.subscribe_square({ 0, 0 }, 20, rows, nil, { 0, 256 })
  local near_25 = {}
  for i = 1, 25 do
    local k = s.queue[(s.queue.h or 1) + i - 1]
    local c = s.subs[k]
    near_25[i] = (c and math.max(math.abs(c[1]), math.abs(c[2])) <= 2) and k or "BAD"
  end
  local near_sorted_at_once = true
  for i = 1, 24 do
    if near_25[i] == "BAD" then near_sorted_at_once = false end
  end
  local pop_near = W.take_next()
  W.requeue_step(s, 300)
  W.enqueue(pop_near)
  -- Walk through Phase 1 -> Phase 2 and verify <=2 chunks stay strictly ahead of outer buckets.
  while s.rq and s.rq.phase == 1 do
    W.requeue_step(s, 512)
  end
  local phase2_head_near = true
  for i = 1, 25 do
    local c = s.subs[s.queue[(s.queue.h or 1) + i - 1]]
    if not (c and math.max(math.abs(c[1]), math.abs(c[2])) <= 2) then
      phase2_head_near = false
    end
  end
  finish()
  local near_prefix_ok = near_sorted_at_once and phase2_head_near and s.queue[s.queue.h or 1] == pop_near
  out[#out + 1] = tostring(near_prefix_ok)
  -- Taken from the head: the list kept until COMPACT_AT have gone, then made again.
  local n0 = W.queued_count()
  for i = 1, 1100 do
    W.take_next()
  end
  out[#out + 1] = tostring(W.queued_count() == n0 - 1100 and (s.queue.h or 1) <= 1024 and #s.queue - (s.queue.h or 1) + 1 == n0 - 1100)
  storage.f3d_perf = nil
  s.subs, s.queue, s.queued, s.rank, s.order, s.have = saved[1], saved[2], saved[3], saved[4], saved[5], saved[6]
  s.sub_o, s.sub_r, s.sub_rows, s.sub_n, s.sub_f, s.rq, s.snap = saved[7], saved[8], saved[9], saved[10], saved[11], saved[12], saved[13]
  return table.concat(out, "|")
end""")().split("|")
check(queue_check[0] == "true", "requeue_slices (near_first off): a new view direction starts the job; the packet handler doesn't order the queue")
check(queue_check[1].startswith("true ") and int(queue_check[1].split()[1]) > 1,
      f"requeue_slices (near_first off): over {queue_check[1].split()[-1]} steps the queue ends in the order it had at once")
check(queue_check[2] == "true", "requeue_slices (near_first off): chunks taken meanwhile are left out, one queued again meanwhile goes in by its rank")
check(queue_check[3] == "true", "requeue_slices (near_first on): <=2 near ring sorts immediately, survives Phase 1->2, and enqueue stays in front")
check(queue_check[4] == "true", "the chunk queue is taken from its head, made again past 1024 taken")

# 4. Wires in strips: each strip a run, every wire within a round (8 x 30 ticks); a wire added between
# two poles updates both.
say(b=1)
send({"t": "focus", "x": fixed(20), "y": fixed(20), "r": 64})
send({"t": "sub", "c": [[0, 0], [1, 0], [0, 1], [1, 1]]})
wa = spawn("small-electric-pole", 24.5, 40.5, force="player")
wb = spawn("small-electric-pole", 27.5, 40.5, force="player")
for e in (wa, wb):
    F["raise"]("script_raised_built", lua.table_from({"entity": e}))
strips_seen = set()
for _ in range(300):
    alive(1)
    strips_seen.add(g.storage.f3d.wire_strip)
take()
check({1, 2, 3, 4, 5, 6, 7, 8} <= strips_seen and g.storage.f3d.wire_sigs[wa.unit_number] is not None,
      f"wire_strips: the square's eight strips in turn, each pole's wires noted: {sorted(x for x in strips_seen if x)}")
F.connect(wa, wb, g.defines.wire_type.copper)
wire_upd = {}
for _ in range(300):
    alive(1)
    wire_upd.update({m["e"][0]: m["e"] for m in of_type(take(), "upd")})
    if wa.unit_number in wire_upd and wb.unit_number in wire_upd:
        break
check(wire_upd.get(wa.unit_number, [0] * 6)[5].get("w") == [wb.unit_number] and wb.unit_number in wire_upd,
      f"wire_strips: a wire added between two poles updates both within a round of strips: {sorted(wire_upd)}")
wa_unit = wa.unit_number
wa.destroy()
wb.destroy()
alive(300)
take()
check(g.storage.f3d.wire_sigs[wa_unit] is None, "wire_strips: a pole gone is forgotten when its strip comes round")
# A wire a script takes away right after building, before the strips' first look at the poles: the
# wires their records were sent with are the last look (tracker.lua note_wires), so the change is
# sent; it was taken as the start and never sent (live_check's poles passed only when their strip
# came round in time).
wc = spawn("small-electric-pole", 24.5, 44.5, force="player")
wd = spawn("small-electric-pole", 27.5, 44.5, force="player")
F.connect(wc, wd, g.defines.wire_type.copper)
for e in (wc, wd):
    F["raise"]("script_raised_built", lua.table_from({"entity": e}))
alive(1)
added = {m["e"][0]: m["e"] for m in of_type(take(), "add")}
wc.get_wire_connector(ids.pole_copper, False).disconnect_from(wd.get_wire_connector(ids.pole_copper, False))
cut = {}
for _ in range(300):
    alive(1)
    cut.update({m["e"][0]: m["e"] for m in of_type(take(), "upd")})
    if wc.unit_number in cut and wd.unit_number in cut:
        break
check(added.get(wc.unit_number, [0] * 6)[5:] == [{"w": [wd.unit_number]}] and wd.unit_number in cut
      and not (cut.get(wc.unit_number, [0] * 6)[5:] or [{}])[0].get("w"),
      f"wire_strips: a wire cut right after building, before the strips' first look, updates both: {added.get(wc.unit_number)} {cut}")
wc_unit = wc.unit_number
F["raise"]("script_raised_destroy", lua.table_from({"entity": wc}))
check(g.storage.f3d.wire_sigs[wc_unit] is None, "a pole removed is forgotten by the wire look at once")
wc.destroy()
wd.destroy()
alive(2)
take()

# 6. Machine states: near ones every round, far ones a strip a round (each every 120 ticks), what was
# sent kept across rounds.
max_focus = g.settings["global"]["f3d-max-focus-radius"]
saved_max_focus = max_focus.value
max_focus.value = 192
send({"t": "focus", "x": fixed(20), "y": fixed(20), "r": 150})
near_m = spawn("assembling-machine-1", 30.5, 20.5, force="player")
far_m = spawn("assembling-machine-1", 120.5, 20.5, force="player")
for e in (near_m, far_m):
    e.status = g.defines.entity_status.working
alive(150)
take()
for e in (near_m, far_m):
    e.status = g.defines.entity_status.no_power
st_first = {}
# Whether the far machine's state is kept between its strip's turns: from its first send, until a round
# reports everything again (every 300 ticks: its strip sends it again later; seen as the near one sent
# again, a tick after), whatever tick the tests before have left the game at.
far_kept = None
far_lost = []
for t in range(1, 151):
    alive(1)
    rows = [v for m in of_type(take(), "st") for v in m["l"]]
    sent_now = dict(zip(rows[0::2], rows[1::2]))
    if near_m.unit_number in sent_now and near_m.unit_number in st_first:
        far_kept = False
        if far_lost and far_lost[-1] == t - 1:
            far_lost.pop()  # (the round's messages go out on the tick after it read)
    for u, v in zip(rows[0::2], rows[1::2]):
        st_first.setdefault(u, (t, v))
    if far_m.unit_number in sent_now:
        far_kept = True
    if far_kept and g.storage.f3d.working[far_m.unit_number] != 0:
        far_lost.append(t)
check(st_first.get(near_m.unit_number, (99, None))[0] <= 31 and st_first.get(near_m.unit_number, (0, 1))[1] == 0,
      f"states_near: a machine within 64 tiles is sent within a round: {st_first.get(near_m.unit_number)}")
check(st_first.get(far_m.unit_number, (999, None))[0] <= 125 and st_first.get(far_m.unit_number, (0, 1))[1] == 0,
      f"states_near: one further out within four rounds: {st_first.get(far_m.unit_number)}")
check(far_kept is not None and not far_lost, f"states_near: what was sent of a far machine is kept between its strip's turns: {far_lost[:3]}")
st_at = g.storage.f3d.st_at
check(st_at is not None and st_at[near_m.unit_number] == 0 and st_at[far_m.unit_number] in (1, 2, 3, 4),
      "states_near: the near machine is read with the near square, the far one with its strip of the rest")
near_m.destroy()
far_m.destroy()
max_focus.value = saved_max_focus
send({"t": "focus", "x": fixed(20), "y": fixed(20), "r": 64})

# 5. Lightning on a planet without it (Nauvis in the fake): looked for every 300 ticks, not 12.
pp = g.storage.f3d.focus
while g.game.tick % 300 != 10:
    alive(1)
take()
g.storage.f3d.planets_busy = lua.table_from({})
nauvis_bolt = spawn("lightning", pp.x + 2.5, pp.y + 2.5 - 25)
lt_ticks = []
for _ in range(299):
    alive(1)
    if of_type(take(), "lt"):
        lt_ticks.append(g.game.tick % 300)
# (Once it found one it looks every 3 ticks for a while, and this bolt stays: sent again as each strike
# is forgotten. The first look is the one that counts.)
check(lt_ticks[:1] in ([5], [6]) and len(lt_ticks) <= 3,
      f"lightning_planets: on a planet without lightning a strike is looked for every 300 ticks: {lt_ticks}")
nauvis_bolt.destroy()
set_perf(lightning_planets=False)
g.storage.f3d.planets_busy = lua.table_from({})
second_bolt = spawn("lightning", pp.x - 2.5, pp.y + 2.5 - 25)
lt_seen = False
for _ in range(13):
    alive(1)
    lt_seen = lt_seen or bool(of_type(take(), "lt"))
check(lt_seen, "lightning_planets off: every 12 ticks on any surface, as before")
second_bolt.destroy()
set_perf()

# 2 and 3. A belt-simulating client: far lanes, the watched belts' order, quiet belts before `valid`, the
# scan's step.
qx, qy = -47.5, -47.5
q_belts = [spawn("transport-belt", qx + k, qy, force="player", direction=4) for k in range(6)]
for k in range(5):
    F.link_belts(q_belts[k], q_belts[k + 1])
q_ins = [spawn("inserter", qx + k, qy + 1, force="player") for k in (1, 3)]
q_ins[0].pickup_target = q_belts[1]
q_ins[1].drop_target = q_belts[3]
q_split = spawn("splitter", qx + 2, qy - 4, force="player", direction=4)
lone = spawn("transport-belt", qx + 20, qy, force="player", direction=4)  # in chunk (-1, -2), 20 tiles out
F.put_on_belt(lone, 1, "iron-plate", 0.5, 9301)
saved_spot_quiet = bs_mod.spot_quiet_ticks
bs_mod.spot_quiet_ticks = 6000
say(z=1, bl=1, bs=1)
send({"t": "focus", "x": fixed(qx), "y": fixed(qy), "r": 64})
send({"t": "sub", "c": [[cx, cy] for cx in range(-3, 1) for cy in range(-3, 1)]})
send({"t": "bfar", "r": 40, "n": 40, "m": 0})
alive(60)
take()
cover = to_py(lua.eval('function() return package.loaded["scripts.belt_sim"].covered() end')())
check(cover and cover[2] == 40, f"far_lanes: once loaded the simulation covers its whole square: {cover}")


def far_round():
    far = g.storage.f3d.far
    far.started, far.cur, far.next = None, None, 1
    far.queue, far.sent = lua.table_from([]), lua.table_from({})
    out = []
    for _ in range(10):
        alive(1)
        out += [(m["cx"], m["cy"]) for m in of_type(take(), "bfar")]
    return out, len(g.storage.f3d.far.queue)


far_on, queued_on = far_round()
set_perf(far_lanes=False)
far_off, queued_off = far_round()
set_perf()
check(far_on == [] and queued_on == 0 and (-1, -2) in far_off and queued_off > 0,
      f"far_lanes: a simulating client whose square reaches the far distance gets no far lanes read (off: {far_off}, {queued_off} chunks)")
# The watched belts' order without a Lua comparator: the same list as the sort's.
order_on = to_py(bs_mod.watch_list())
g.storage.f3d_bs = lua.table_from({"watch_nosort": False})
order_off = to_py(bs_mod.watch_list())
g.storage.f3d_bs = None
spots = {int(q_belts[k].unit_number) for k in (0, 1, 3)}
check(order_on == order_off and len(order_on) >= 4 and set(order_on[:3]) == spots and int(q_split.unit_number) in order_on,
      f"watch_nosort: the watched belts in the sort's order, input spots first: {order_on} vs {order_off}")
# A quiet watched belt is passed over before its `valid` is read: one gone without an event is dropped
# when its check comes up (off: at once).
gone_unit = int(q_belts[1].unit_number)
q_belts[1].destroy()
alive(12)
dl_on = bs_of(take())["dl"]
still = g.storage.f3d.bs.belts[gone_unit] is not None
g.storage.f3d_bs = lua.table_from({"quiet_first": False})
alive(12)
dl_off = bs_of(take())["dl"]
g.storage.f3d_bs = None
check(still and gone_unit * 8 + 1 not in dl_on and gone_unit * 8 + 1 in dl_off,
      f"quiet_first: a quiet watched belt gone without an event waits for its check (off: dropped at once): {dl_on} / {dl_off}")
bs_mod.spot_quiet_ticks = saved_spot_quiet
# First loads of belts past walk_near: LOAD_MIN (400) a tick while the tick's budget is in use (here 250 of
# 300 units), their share when it is idle; off, their share either way. Only once the client's square has
# been loaded whole (b.whole): a join's first load takes its share, busy or not.
bsst, bud = g.storage.f3d.bs, g.storage.f3d.bud
saved_load = (bsst.load_i, bsst.thin, bsst.whole, bud.used, bud.limit)
bsst.load_i, bsst.thin, bsst.whole, bud.limit = 1, None, True, 300
bud.jobs.bsload = 0
g.storage.f3d_bs = lua.table_from({"walk_near": 0})
bud.used = 0
idle_limit = bs_mod.load_limit_now()
bud.used = 250
busy_limit = bs_mod.load_limit_now()
bsst.whole = None
busy_first = bs_mod.load_limit_now()
bsst.whole = True
g.storage.f3d_bs = lua.table_from({"walk_near": 0, "far_load_cap": False})
busy_off = bs_mod.load_limit_now()
g.storage.f3d_bs = None
bsst.load_i, bsst.thin, bsst.whole, bud.used, bud.limit = saved_load
check(idle_limit == 3000 and busy_limit == 400 and busy_off == 1000,
      f"far_load_cap: loads past walk_near take LOAD_MIN unless the budget is idle: idle {idle_limit}, busy {busy_limit}, off {busy_off}")
check(busy_first == 1000,
      f"far_load_cap: not before the client's square was first loaded whole (a join loads at its share): {busy_first}")
# A new scan once the focus moved r / 32 tiles (here 96 / 32 = 3) with scan_step_wide off,
# and max(12, floor(r / 12)) = 12 tiles with scan_step_wide on (default).
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "scan_step_wide off"}))
send({"t": "bfar", "r": 0, "n": 96, "m": 0})
alive(12)
for _ in range(600):
    alive(1)
    if g.storage.f3d.bs.scanning is None:
        break
take()
moved0 = int(bs_mod.counts.scan_moved)
send({"t": "focus", "x": fixed(qx + 2), "y": fixed(qy), "r": 64})
alive(13)
moved1 = int(bs_mod.counts.scan_moved)
send({"t": "focus", "x": fixed(qx + 4), "y": fixed(qy), "r": 64})
for _ in range(90):
    alive(1)
    if int(bs_mod.counts.scan_moved) > moved0:
        break
moved2 = int(bs_mod.counts.scan_moved)
take()
check(moved1 == moved0 and moved2 == moved0 + 1, f"scan_step (wide off): no new scan for 2 tiles at 96, one for 4: {moved0} {moved1} {moved2}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "scan_step_wide default"}))
for _ in range(90):
    alive(1)
    if g.storage.f3d.bs.scanning is None:
        break
take()
moved_w0 = int(bs_mod.counts.scan_moved)
send({"t": "focus", "x": fixed(qx + 10), "y": fixed(qy), "r": 64})
alive(13)
moved_w1 = int(bs_mod.counts.scan_moved)
send({"t": "focus", "x": fixed(qx + 17), "y": fixed(qy), "r": 64})
for _ in range(90):
    alive(1)
    if int(bs_mod.counts.scan_moved) > moved_w0:
        break
moved_w2 = int(bs_mod.counts.scan_moved)
take()
check(moved_w1 == moved_w0 and moved_w2 == moved_w0 + 1,
      f"scan_step_wide (on): no new scan for 6 tiles (qx+4 -> qx+10) at 96, one for 13 (qx+4 -> qx+17): {moved_w0} {moved_w1} {moved_w2}")
send({"t": "bfar", "r": 0})
for e in q_belts + q_ins + [q_split, lone]:
    if e.valid:
        e.destroy()
alive(6)
take()

