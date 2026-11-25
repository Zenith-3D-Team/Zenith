# Bridge test slice 07_belt_sim_switches.py (lines 10835-12820 of original test_bridge.py)
# --- the round after the hotfix (bridge.md changes 8-15), each its own switch ---------------------------
# 15. Records by prototype: the same record, natural entities reading their deconstruction mark alone.
rec_ents = [spawn("tree-01", 70.5, 70.5), spawn("iron-ore", 71.5, 70.5, amount=7),
            spawn("cliff", 73.0, 70.5, cliff_orientation="west-to-east"), spawn("assembling-machine-1", 76.5, 70.5, force="player"),
            spawn("transport-belt", 79.5, 70.5, force="player", direction=4), spawn("small-electric-pole", 81.5, 70.5, force="player")]
F.decon_marks[rec_ents[0]] = True
record_of = lua.eval('function(e) return package.loaded["scripts.world"].record(e) end')
recs_on = [to_py(record_of(e)) for e in rec_ents]
set_perf(records_by_prototype=False)
recs_off = [to_py(record_of(e)) for e in rec_ents]
set_perf()
check(recs_on == recs_off and recs_on[0][5] == {"d": 1} and recs_on[1][5] == {"a": 7} and recs_on[2][5] == {"co": "west-to-east"},
      f"records_by_prototype: the same records, a marked tree's mark, ore's amount, a cliff's piece: {recs_on} vs {recs_off}")
for e in rec_ents:
    e.destroy()

# 14. The alerts pass passes over chunks it found none of the force's machines in, until something is built
# there or every tenth pass; and steps once a tick whatever the clients.
alerts_mod = g.package.loaded["scripts.alerts"]


def unplugged_at(msg, x, y):
    for kind, _, shown in msg["l"]:
        if kind == "unplugged" and any(r[0] == fixed(x) and r[1] == fixed(y) for r in shown):
            return True
    return False


def alerts_now(skip_recheck):
    """M.current() on a pass that isn't (or is) one of the tenth that look in empty chunks too."""
    while (alerts_mod.pass_count() + 1) % 10 == 0 if skip_recheck else (alerts_mod.pass_count() + 1) % 10 != 0:
        alerts_mod.current()
    return to_py(alerts_mod.current())


# (From a pass that looked in every chunk: the next nine pass over the empty ones, whatever passes the
# tests before have run.)
while alerts_mod.pass_count() % 10 != 0:
    alerts_mod.current()
alerts_now(True)
empties = int(alerts_mod.empty_chunks())
dark = spawn("assembling-machine-1", 100.5, -90.5, force="player")
dark.status = g.defines.entity_status.no_power
dark.electric_network_id = None
unseen = unplugged_at(alerts_now(True), 100.5, -90.5)
F["raise"]("script_raised_built", lua.table_from({"entity": dark}))
seen_after_build = unplugged_at(alerts_now(True), 100.5, -90.5)
check(empties > 10 and not unseen and seen_after_build,
      f"alerts_quiet: chunks with none of the force's machines are passed over ({empties}) until something is built there: {unseen} {seen_after_build}")
dark.destroy()
set_perf(alerts_quiet=False)
dark2 = spawn("assembling-machine-1", 100.5, -80.5, force="player")
dark2.status = g.defines.entity_status.no_power
dark2.electric_network_id = None
check(unplugged_at(alerts_now(True), 100.5, -80.5), "alerts_quiet off: every chunk every pass, as before")
dark2.destroy()
set_perf()
# alerts_quiet waits PASS_INTERVAL (600 ticks) after a pass finishes before starting the next.
alerts_mod.current()
p_after = int(alerts_mod.pass_count())
alive(300)
p_mid = int(alerts_mod.pass_count())
alive(320)
p_next = int(alerts_mod.pass_count())
check(p_mid == p_after and p_next > p_after,
      f"alerts_quiet: waits PASS_INTERVAL after a pass finishes ({p_after} -> {p_mid} -> {p_next})")

# J5: round the focus the unplugged icon comes from fluids_power's read and the build events, not the pass
# over every surface (10-40 s late on a big base): a machine built out of every pole's reach is listed the
# tick after, gone the tick after a pole reaches it, and a machine that loses its pole without an event is
# listed by the next read (once a second).
j5_start = int(g.game.tick)
j5_focus = to_py(g.storage.f3d.focus)
send({"t": "focus", "x": fixed(40), "y": fixed(40), "r": 32})
alive(130)
while (int(g.game.tick) + 29) % 60 != 1:  # just past the once-a-second `al`: the next one only for a change
    alive(1)
take()
lone = spawn("assembling-machine-1", 45.5, 45.5, force="player")
lone.status = g.defines.entity_status.no_power
lone.electric_network_id = None
F["raise"]("script_raised_built", lua.table_from({"entity": lone}))
alive(8)  # (an `al` for a change waits 6 ticks after the last)
al_built = of_type(take(), "al")
check(len(al_built) >= 1 and unplugged_at(al_built[0], 45.5, 45.5),
      f"J5: a machine built out of every pole's reach round the focus is unplugged in an `al` the tick after: {al_built}")
lone.electric_network_id = 7
lone.status = g.defines.entity_status.working
j5_pole = spawn("small-electric-pole", 47.5, 45.5, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": j5_pole}))
alive(8)
al_pole = of_type(take(), "al")
check(al_pole and not unplugged_at(al_pole[-1], 45.5, 45.5),
      f"J5: and no longer once a pole reaches it, at once: {al_pole}")
lone.electric_network_id = None
lone.status = g.defines.entity_status.no_power
alive(75)
al_read = of_type(take(), "al")
check(al_read and unplugged_at(al_read[-1], 45.5, 45.5), f"J5: a pole gone without an event: the next read lists it: {al_read[-1:]}")
lone.destroy()
j5_pole.destroy()
send({"t": "focus", "x": fixed(j5_focus["x"]), "y": fixed(j5_focus["y"]), "r": int(j5_focus["r"])})
while (int(g.game.tick) - j5_start) % 1200:  # the checks after keep the tick phase they were written at
    alive(1)
take()

# The ninth list's delays (J20-J22, J27, J28): turrets out of ammo, machines out of fuel and drills with nothing to
# mine round the focus come from the once-a-second power read and the reads after building or moving items, not the
# alerts' pass (J5's way); what the character mines is said at once (`mnd`); a belt it puts items on or takes them off
# has its lanes read in the next belt update.
j9_start = int(g.game.tick)
j9_focus = to_py(g.storage.f3d.focus)
j9_pup = g.storage.f3d.puppet
j9_was = to_py(j9_pup.position)
j9_pup.position = lua.table_from({"x": 40, "y": 40})
send({"t": "focus", "x": fixed(40), "y": fixed(40), "r": 32})
near_id = lua.eval("function() return tostring(storage.f3d.al_near) end")


def until_read():
    """Ticks on to the one the once-a-second read (fluids_power, alerts' listener) has just run on."""
    was = near_id()
    for _ in range(130):
        alive(1)
        if near_id() != was:
            return True
    return False


def kinds_in(msgs):
    al = of_type(msgs, "al")
    return {kind: [r[4] for r in shown] for kind, _, shown in al[-1]["l"]} if al else None


until_read()
alive(8)
take()
# J22: a turret built without ammo: in `no_ammo` within the ticks after (it is read again itself), not at the
# next read or pass; ammo put in by Ctrl+click takes it off as soon (the buildings in reach are read 2 ticks on).
j9_tur = spawn("gun-turret", 44.0, 44.0, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": j9_tur}))
alive(8)
k = kinds_in(take())
check(k is not None and j9_tur.unit_number in k.get("no_ammo", []),
      f"J22: a turret built without ammo round the focus is out of ammo in an `al` within 8 ticks: {k}")
until_read()
alive(10)
take()
j9_pup.get_main_inventory().insert(lua.table_from({"name": "firearm-magazine", "count": 10}))  # (insert would take it to the ammo slots)
send(dict(target_of(j9_tur), t="fast", item="firearm-magazine", n=5))
alive(8)
k = kinds_in(take())
check(k is not None and j9_tur.unit_number not in k.get("no_ammo", []),
      f"J22: and off it within 8 ticks after a Ctrl+click puts ammo in (not at the next read): {k}")
# J28: a furnace that runs out of fuel without an event: the next read lists it; fuel put in by Ctrl+click: off
# within a few ticks.
j9_fur = spawn("stone-furnace", 46.0, 40.0, force="player")
j9_fur.status = g.defines.entity_status.no_fuel
until_read()
alive(8)
k = kinds_in(take())
check(k is not None and j9_fur.unit_number in k.get("no_fuel", []), f"J28: a furnace out of fuel round the focus, by the next read: {k}")
alive(10)
take()
j9_fur.status = g.defines.entity_status.working
j9_pup.insert(lua.table_from({"name": "coal", "count": 10}))
send(dict(target_of(j9_fur), t="fast", item="coal", n=5))
alive(8)
k = kinds_in(take())
check(k is not None and j9_fur.unit_number not in k.get("no_fuel", []),
      f"J28: and off it within 8 ticks after a Ctrl+click puts fuel in: {k}")
# J27: a drill with nothing left to mine (no_minable_resources): `depleted`, by the next read.
j9_drill = spawn("burner-mining-drill", 50.0, 44.0, force="player")
j9_drill.status = g.defines.entity_status.no_minable_resources
until_read()
alive(8)
k = kinds_in(take())
check(k is not None and j9_drill.unit_number in k.get("depleted", []),
      f"J27: a drill with nothing left to mine round the focus is `depleted`: {k}")
# status_near off: those kinds from the pass alone, as before (the read lists none of them).
set_perf(status_near=False)
until_read()
off_near = g.storage.f3d.al_near
check(len(list(off_near.d.keys())) == 0 and len(list(off_near.a.keys())) == 0,
      "status_near off: the read lists no depleted drills or turrets out of ammo")
set_perf()
for e in (j9_tur, j9_fur, j9_drill):
    e.destroy()
alive(2)
take()

# L11: a pipeline over Factorio's extent limit (pipeline_overextended): one entity of its segment in `al` `pipeline`
# the tick after a pipe is built round the focus (not at the pass), the segment's entity nearest the line 320 tiles
# in from its far edge (where a pump would split it); its pipes' hinfo says the extent and the status; gone once
# mended; the pass finds it too; pipe_alerts off: none.
l11 = [spawn("pipe", 36.5 + i, 48.5, force="player") for i in range(4)]
l11_box = {"left_top": {"x": 30.2, "y": 48.2}, "right_bottom": {"x": 358.8, "y": 48.8}}
for p_ in l11:
    F.segments[p_] = lua.table_from({"id": 77, "box": l11_box}, recursive=True)
    p_.status = g.defines.entity_status.pipeline_overextended
until_read()
alive(8)
take()
F["raise"]("script_raised_built", lua.table_from({"entity": l11[3]}))
alive(8)
k = kinds_in(take())
check(k is not None and k.get("pipeline") == [l11[2].unit_number],
      f"L11: an overextended pipeline is one `pipeline` alert the ticks after a pipe is built, on its pipe nearest the cut "
      f"(358.8 - 320 = 38.8: the third): {k}")
send({"t": "hinfo", "q": 61, "u": l11[0].unit_number, "p": 0, "x": fixed(l11[0].position.x), "y": fixed(l11[0].position.y)})
tick(2)
hp_ = {m["q"]: m for m in of_type(take(), "hinfo")}.get(61, {})
check(hp_.get("pl") == [329, 320] and hp_.get("ox") == 1 and "el" not in hp_,
      f"L11: a pipe's hinfo: its pipeline's extent over the limit and overextended: {hp_}")
check(any(kind == "pipeline" and shown for kind, _, shown in to_py(alerts_mod.current())["l"]),
      "L11: the alerts' pass lists it too")
for p_ in l11:
    p_.status = g.defines.entity_status.working
F["raise"]("script_raised_built", lua.table_from({"entity": l11[0]}))
alive(8)
k = kinds_in(take())
check(k is not None and "pipeline" not in k, f"L11: mended (a pump split it), it goes at once: {k}")
for p_ in l11:
    p_.status = g.defines.entity_status.pipeline_overextended
set_perf(pipe_alerts=False)
F["raise"]("script_raised_built", lua.table_from({"entity": l11[1]}))
alive(70)
k = kinds_in(take())
check(k is not None and "pipeline" not in k and not any(kind == "pipeline" for kind, _, _ in to_py(alerts_mod.current())["l"]),
      f"pipe_alerts off: no pipeline alert, from the spots or the pass: {k}")
set_perf()
for p_ in l11:
    p_.destroy()
alive(2)
take()

# L6: a resource's hinfo has its amount now; the map's `rpatch` sums the patch under the point (ore within its search
# radius of each other, 3 tiles: a gap of 2 joins, one 5 away doesn't), its tiles as runs a row; an infinite one's
# yields in percent of its normal amount; nothing where there is no charted resource.
l6_ore = [spawn("iron-ore", 60.5 + i, 60.5, amount=100 + i) for i in range(3)]
l6_ore.append(spawn("iron-ore", 65.5, 60.5, amount=1000))  # 3 tiles from the last: joins
l6_far = spawn("iron-ore", 72.5, 60.5, amount=5000)  # 7 tiles on: another patch
l6_oil = [spawn("crude-oil", 60.5, 70.5, amount=150000), spawn("crude-oil", 70.5, 70.5, amount=300000)]
F.charted["1,1"] = True
F.charted["1,2"] = True
F.charted["2,1"] = True
F.charted["2,2"] = True
send({"t": "hinfo", "q": 62, "u": 0, "p": eid["iron-ore"], "x": fixed(60.5), "y": fixed(60.5)})
send({"t": "rpatch", "q": 63, "x": fixed(61.2), "y": fixed(60.7)})
send({"t": "rpatch", "q": 64, "x": fixed(70.0), "y": fixed(71.0)})
send({"t": "rpatch", "q": 65, "x": fixed(10.5), "y": fixed(90.5)})
tick(4)
msgs = take()
hr6 = {m["q"]: m for m in of_type(msgs, "hinfo")}.get(62, {})
rp = {m["q"]: m for m in of_type(msgs, "rpatch")}
check(hr6.get("ra") == 100, f"L6: a resource's hinfo says its amount now: {hr6}")
ore_patch = rp.get(63, {})
check(ore_patch.get("n") == "iron-ore" and ore_patch.get("a") == 100 + 101 + 102 + 1000 and ore_patch.get("c") == 4
      and ore_patch.get("o") == [[60, 60, 3, 65, 1]] and "y" not in ore_patch,
      f"L6: rpatch sums the ore patch under the point, within its search radius, and outlines its tiles: {ore_patch}")
oil_patch = rp.get(64, {})
check(oil_patch.get("n") == "crude-oil" and oil_patch.get("c") == 2 and oil_patch.get("y") == 150
      and oil_patch.get("o") == [[69, 59, 3, 69, 3], [70, 59, 3, 69, 3], [71, 59, 3, 69, 3]],
      f"L6: crude oil wells 10 apart are one field (radius 12), its yields summed (50% + 100%), each well's 3x3 outlined: {oil_patch}")
check(rp.get(65) is not None and set(rp[65]) <= {"t", "q", "k"}, f"L6: no resource there: only q: {rp.get(65)}")
for e in l6_ore + [l6_far] + l6_oil:
    e.destroy()

# J20: mining sends `mnd` the tick it finishes, before the `del` (which waits in the reliable outbox), with what the
# character got, and the inventory at once.
j9_belt = spawn("transport-belt", 41.5, 40.5, force="player", direction=4)
for _ in range(5):
    send(dict(target_of(j9_belt), t="mine"))
    alive(15)
msgs = take()
mnd = [m for m in of_type(msgs, "mnd") if m["u"] == j9_belt.unit_number] if not j9_belt.valid else []
check(not j9_belt.valid and len(mnd) == 1 and mnd[0]["g"] == 1 and ["transport-belt", 1] in mnd[0]["l"]
      and mnd[0]["x"] == fixed(41.5) and mnd[0]["p"] == eid["transport-belt"],
      f"J20: a mined belt is said at once: gone, its place, the belt back in the inventory: {mnd}")
# (`inv` is reliable: stamped when the outbox sends it, the tick after.)
check(bool(mnd) and any(mnd[0]["k"] <= m["k"] <= mnd[0]["k"] + 1 and any(row[0] == "transport-belt" for row in m["l"])
                        for m in of_type(msgs, "inv")),
      f"J20: the inventory goes with it, not at its 30-tick report: {[m['k'] for m in of_type(msgs, 'inv')]} {mnd[:1]}")
j9_ore = spawn("iron-ore", 40.5, 41.5, amount=5)
for _ in range(10):  # (the fake's ore takes 1 s / 0.5: 120 ticks a unit)
    send(dict(target_of(j9_ore), t="mine"))
    alive(15)
ore_mnd = [m for m in of_type(take(), "mnd") if m["p"] == eid["iron-ore"]]
check(ore_mnd and ore_mnd[0]["g"] == 0 and ore_mnd[0]["l"] == [["iron-ore", 1]],
      f"J20: ore mined by hand: a unit at a time, the patch still there: {ore_mnd[:2]}")
j9_ore.destroy()
set_perf(mined_now=False)
j9_belt2 = spawn("transport-belt", 41.5, 40.5, force="player", direction=4)
for _ in range(5):
    send(dict(target_of(j9_belt2), t="mine"))
    alive(15)
check(not j9_belt2.valid and not of_type(take(), "mnd"), "mined_now off: no `mnd`, as before")
set_perf()

# J21: a belt the character puts an item on (Ctrl+click) or drops one on (Z) has its lanes asked for again (read in
# the next belt update, as a client's `bre`), not left to its drift check.
lua.execute("""
F_resent = {}
local bs = package.loaded["scripts.belt_sim"]
F_resend_real = bs.resend
bs.resend = function(cmd)
  for _, k in ipairs(cmd.l) do
    F_resent[#F_resent + 1] = k
  end
  return F_resend_real(cmd)
end
""")
j9_put = spawn("transport-belt", 42.5, 41.5, force="player", direction=4)
j9_pup.insert(lua.table_from({"name": "iron-plate", "count": 10}))
send(dict(target_of(j9_put), t="fast", item="iron-plate", n=1))
alive(1)
lanes = sorted(int(v) for v in g.F_resent.values())
unit8 = int(j9_put.unit_number) * 8
check(lanes == [unit8 + 1, unit8 + 2], f"J21: a Ctrl+click onto a belt asks for its lanes again: {lanes} (unit {j9_put.unit_number})")
lua.execute("F_resent = {}")
send({"t": "drop", "item": "iron-plate", "x": fixed(42.5), "y": fixed(41.5)})
alive(1)
lanes = sorted(int(v) for v in g.F_resent.values())
check(lanes == [unit8 + 1, unit8 + 2], f"J21: so does Z over a belt: {lanes}")
lua.execute("F_resent = {}")
set_perf(put_lanes=False)
send(dict(target_of(j9_put), t="fast", item="iron-plate", n=1))
alive(1)
check(len(list(g.F_resent.values())) == 0, "put_lanes off: nothing asked, as before")
set_perf()

# drop_put: Z onto a belt tells the item at once as a put with no inserter (`ie` kind 6, unit 0: lane, place, id) for a
# client whose hello says `ho`, and wakes the belt's drift checks (quiet_pc); off: the lanes' read alone, as before.
def z_put_records(msgs):
    out = []
    for m in of_type(msgs, "ie"):
        l = list(m["l"])
        if m.get("z") == 1:
            for i in range(9, len(l)):
                l[i] += l[i - 9]
        for i in range(0, len(l), 9):
            if l[i] == 6 and l[i + 1] == 0:
                out.append(l[i:i + 9])
    return out


# (The client's `ie` and `ho` set as its hello would, without a new hello: one resends what a later check counts.)
dz_t0 = int(g.game.tick)
dz_belt = spawn("transport-belt", 43.5, 41.5, force="player", direction=4)
dz_unit = int(dz_belt.unit_number)
g.F_dz_belt = dz_belt
lua.execute("""
local surface = game.surfaces[1]
F_spill_real = surface.spill_item_stack
surface.spill_item_stack = function(p)
  -- (the game's spill with allow_belts: onto the belt under it, with the newest unique id)
  F.next_item_id = (F.next_item_id or 9000) + 1
  F.put_on_belt(F_dz_belt, 1, p.stack.name, 0.4, F.next_item_id)
  return {}
end
""")
alive(70)
while int(g.game.tick) % 100 > 80 or int(g.game.tick) % 100 == 0:
    alive(1)
take()
g.storage.f3d.client.ie, g.storage.f3d.client.ho = True, True
tick(1)
take()
# (A quiet belt's record, as belt_sim.lua keeps it, its next drift check 1800 ticks off: there only while the drop is
# handled, the packet being handled at once.)
def quiet_drop():
    g.storage.f3d.bs.belts[dz_unit] = lua.table_from({"qw": 1800, "ql": g.game.tick})
    send({"t": "drop", "item": "iron-plate", "x": fixed(43.5), "y": fixed(41.5)})
    rec = g.storage.f3d.bs.belts[dz_unit]
    g.storage.f3d.bs.belts[dz_unit] = None
    return rec.qw, rec.ql


qd = quiet_drop()
alive(3)
zp = z_put_records(take())
check(len(zp) >= 1 and zp[0][3] // 8 == dz_unit and zp[0][3] % 8 == 1 and zp[0][5] == int(g.F.next_item_id)
      and zp[0][6] == iid["iron-plate"] and zp[0][7] == 1 and zp[0][8] == dz_unit,
      f"drop_put: Z onto a belt is told at once as a put with no inserter (lane, place, id): {zp[:1]} (unit {dz_unit})")
check(qd == (None, None), f"drop_put: and its quiet belt's drift checks come every turn again: {qd}")
alive(10)
take()  # (each record goes again in the next messages)
set_perf(drop_put=False)
qd = quiet_drop()
alive(3)
check(not z_put_records(take()) and qd[0] == 1800, f"drop_put off: no put told, the belt left quiet, as before: {qd}")
set_perf()
g.storage.f3d.client.ho = None
alive(10)
take()
send({"t": "drop", "item": "iron-plate", "x": fixed(43.5), "y": fixed(41.5)})
alive(3)
check(not z_put_records(take()), "drop_put: none for a hello without `ho`")
lua.execute("game.surfaces[1].spill_item_stack = F_spill_real")
g.storage.f3d.client.ie = None
alive((30 - (int(g.game.tick) - dz_t0) % 30) % 30)  # (the checks below keep the inventory's 30-tick phase)
take()

# Issue #18: F takes the items on belts within the character's item pickup distance too, as Factorio's "Pick up
# items": all in range a tick, nearest first, each said at once (`pku`: where it was, its lane and unique id), the
# lanes taken from asked for again (J21's way); an underground's tunnel and a belt out of reach keep theirs.
pk_was = to_py(j9_pup.position)
j9_pup.position = lua.table_from({"x": 60, "y": 50})
alive(1)
take()
pk_belt = spawn("transport-belt", 60.5, 50.5, force="player", direction=4)
pk_far = spawn("transport-belt", 63.5, 50.5, force="player", direction=4)
pk_under = spawn("underground-belt", 59.5, 49.5, force="player", direction=4, type="input")
# (The fake's lines run east here: line position p is at x + 0.5 - p, lines 1 and 2 0.234 north and south of
# the middle; an underground's lines 3 and 4 run on into the tunnel, x + 0.5 + p.)
F.put_on_belt(pk_belt, 1, "iron-plate", 0.1, 18001)                       # 0.94 off
F.put_on_belt(pk_belt, 1, "iron-gear-wheel", 0.75, 18002, None, None, 3)  # a stack of 3, 0.37 off: first
F.put_on_belt(pk_belt, 2, "copper-plate", 0.75, 18003)                    # 0.78 off
F.put_on_belt(pk_far, 1, "iron-plate", 0.5, 18004)                        # 3.5 off: out of reach
F.put_on_belt(pk_under, 1, "copper-plate", 0.3, 18005)                    # 0.79 off
F.put_on_belt(pk_under, 3, "iron-plate", 0.1, 18006)                      # under the ground, 0.74 off


def pk_uids(e, line):
    return sorted(int(it.unique_id) for it in e.get_transport_line(line).get_detailed_contents().values())


pk_inv = j9_pup.get_main_inventory()
pk_names = ("iron-plate", "iron-gear-wheel", "copper-plate")
pk_before = {n: int(pk_inv.get_item_count(n)) for n in pk_names}
lua.execute("F_resent = {}")
send({"t": "pickup"})
alive(1)
pk_msgs = take()
pku = of_type(pk_msgs, "pku")
pk_l = pku[0]["l"] if len(pku) == 1 else []
pk_unit = {"b": int(pk_belt.unit_number) * 8, "u": int(pk_under.unit_number) * 8}
check([r[5] for r in pk_l] == [18002, 18003, 18005, 18001]
      and [r[4] for r in pk_l] == [pk_unit["b"] + 1, pk_unit["b"] + 2, pk_unit["u"] + 1, pk_unit["b"] + 1]
      and [r[0] for r in pk_l] == ["iron-gear-wheel", "copper-plate", "copper-plate", "iron-plate"]
      and [r[1] for r in pk_l] == [3, 1, 1, 1] and all(r[6] == 0 and r[7] == iid[r[0]] for r in pk_l),
      f"issue #18: F takes every belt item in reach in one tick, nearest first, said at once by lane and id (pku): {pk_l}")
check(pk_l and pk_l[0][2:4] == [fixed(60.25), fixed(50.5 - 0.234)] and pk_l[2][2:4] == [fixed(59.7), fixed(49.5 - 0.234)]
      and pku[0]["k"] == int(g.game.tick),
      f"issue #18: each where the game had it that tick (get_line_item_position), on the tick taken: {[r[2:4] for r in pk_l]}")
check(pk_uids(pk_belt, 1) == [] and pk_uids(pk_belt, 2) == [] and pk_uids(pk_under, 1) == []
      and pk_uids(pk_under, 3) == [18006] and pk_uids(pk_far, 1) == [18004],
      "issue #18: they are off their lanes; an underground's tunnel and a belt out of reach keep theirs")
check([int(pk_inv.get_item_count(n)) - pk_before[n] for n in pk_names] == [1, 3, 2],
      "issue #18: and in the inventory, a stack as its count")
pk_resent = sorted(int(v) for v in g.F_resent.values())
check(pk_resent == sorted([pk_unit["b"] + 1, pk_unit["b"] + 2] + [pk_unit["u"] + i for i in range(1, 5)]),
      f"issue #18: the belts taken from have their lanes asked for again (read in the next belt update): {pk_resent}")
alive(1)  # (the reliable outbox goes out at the start of the next tick)
pk_msgs += take()
check(of_type(pk_msgs, "inv") and of_type(pk_msgs, "slots"), "issue #18: the inventory and slots are sent at once")
# A stack the inventory takes part of: the rest stays on the belt, said (left); then full, said once.
alive(40)
take()
F.inventory_space = 2
F.put_on_belt(pk_belt, 1, "iron-gear-wheel", 0.75, 18010, None, None, 3)
for _ in range(3):
    send({"t": "pickup"})
    alive(9)
pk_msgs = take()
pk_l = [r for m in of_type(pk_msgs, "pku") for r in m["l"]]
pk_left = [it for it in pk_belt.get_transport_line(1).get_detailed_contents().values()]
check(pk_l == [["iron-gear-wheel", 2, fixed(60.25), fixed(50.5 - 0.234), pk_unit["b"] + 1, 18010, 1, iid["iron-gear-wheel"]]]
      and len(pk_left) == 1 and int(pk_left[0].stack.count) == 1
      and len([m for m in of_type(pk_msgs, "msg") if m["text"] == "Inventory full"]) == 1,
      f"issue #18: with room for two of a stack of three, two come off (left 1), then full, said once: {pk_l}")
F.inventory_space = float("inf")
alive(40)
send({"t": "pickup"})
alive(1)
take()
# A game whose belt stack reference doesn't take the item (F.belt_stack_writes false): the lane gives one up by name,
# and what is said is the item the lane gave up, not the one aimed at; nothing is made.
F.belt_stack_writes = False
F.put_on_belt(pk_belt, 1, "iron-plate", 0.75, 18020)  # the nearest
F.put_on_belt(pk_belt, 1, "iron-plate", 0.1, 18021)   # (the fake's lane gives up its last one by name)
plates0 = int(pk_inv.get_item_count("iron-plate"))
send({"t": "pickup"})
alive(1)
pk_l = [r for m in of_type(take(), "pku") for r in m["l"]]
check(pk_l and pk_l[0][5] == 18021 and pk_l[0][2] == fixed(60.9) and pk_uids(pk_belt, 1) == [18020]
      and int(pk_inv.get_item_count("iron-plate")) == plates0 + 1,
      f"issue #18: a reference that takes nothing: the lane's own name removal, said as the item it took, one plate got: {pk_l}")
alive(1)
check(pk_uids(pk_belt, 1) == [] and int(pk_inv.get_item_count("iron-plate")) == plates0 + 2,
      "issue #18: and the next tick the other, no more plates than came off")
F.belt_stack_writes = None
alive(40)
take()
# belt_pickup off: the ground only, as before.
set_perf(belt_pickup=False)
F.put_on_belt(pk_belt, 2, "copper-plate", 0.75, 18030)
pk_ground = spawn("item-on-ground", 60.3, 49.8, stack={"name": "wood", "count": 1})
for _ in range(2):
    send({"t": "pickup"})
    alive(9)
pk_msgs = take()
check(not pk_ground.valid and pk_uids(pk_belt, 2) == [18030] and not of_type(pk_msgs, "pku"),
      "belt_pickup off: F takes the ground's items, not the belt's, and says nothing (as before)")
set_perf()
alive(40)
send({"t": "pickup"})
alive(1)
pk_l = [r for m in of_type(take(), "pku") for r in m["l"]]
check(pk_l and pk_l[0][5] == 18030 and pk_uids(pk_belt, 2) == [], f"belt_pickup back on: the belt's item comes off: {pk_l}")
alive(40)
take()
# pickup_stop (the owner: F picked on for almost a second after it was let go): F let go ends the pickup at once;
# an old client that never sends it keeps picking until HOLD_TICKS (30) after its last `pickup`; switched off, ignored.
send({"t": "pickup"})
alive(1)
take()
send({"t": "pickup_stop"})
alive(1)
F.put_on_belt(pk_belt, 2, "copper-plate", 0.75, 18040)
ps_ground = spawn("item-on-ground", 60.3, 49.8, stack={"name": "wood", "count": 1})
alive(40)
ps_msgs = take()
check(pk_uids(pk_belt, 2) == [18040] and ps_ground.valid and not of_type(ps_msgs, "pku"),
      "pickup_stop: after F is let go nothing more is picked, off a belt or the ground")
send({"t": "pickup"})
alive(10)
ps_l = [r for m in of_type(take(), "pku") for r in m["l"]]
check(ps_l and pk_uids(pk_belt, 2) == [] and not ps_ground.valid,
      f"pickup_stop: held again, both picked: {ps_l}")
F.put_on_belt(pk_belt, 2, "copper-plate", 0.75, 18041)
alive(10)
check(pk_uids(pk_belt, 2) == [], "pickup_stop: an old client (no stop) still picks 20 ticks after its last pickup")
alive(20)
F.put_on_belt(pk_belt, 2, "copper-plate", 0.75, 18042)
alive(5)
check(pk_uids(pk_belt, 2) == [18042], "pickup_stop: and stops once HOLD_TICKS have passed, as before")
send({"t": "pickup"})
alive(1)
take()
set_perf(pickup_stop=False)
send({"t": "pickup"})
alive(1)
send({"t": "pickup_stop"})
alive(1)
F.put_on_belt(pk_belt, 2, "copper-plate", 0.75, 18043)
alive(5)
check(pk_uids(pk_belt, 2) == [], "pickup_stop off: the stop ignored, picking on until HOLD_TICKS, as before")
set_perf()
alive(40)
take()
# pickup_stop, the owner's case measured (belts-pickup-test): the client's own cadence (a `pickup` every 9 ticks
# while F is held, `pickup_stop` on release), the packets a tick or two late, a belt fed an item every tick under the
# character; what the game picks after F is let go, an old client (no stop) against a new one.
PS_UID = [18100]


def ps_run(stop, delay, release, ticks=60):
    """Holds F from client tick 0 to `release`; returns [(ticks after release, items)] for each pku after it."""
    due = {}
    for t in range(0, release, 9):
        due.setdefault(t + delay, []).append({"t": "pickup"})
    if stop:
        due.setdefault(release + delay, []).append({"t": "pickup_stop"})
    after = []
    for t in range(ticks):
        for m in due.get(t, []):
            send(m)
        PS_UID[0] += 1
        F.put_on_belt(pk_belt, 2, "copper-plate", 0.75, PS_UID[0])
        alive(1)
        for m in of_type(take(), "pku"):
            if t >= release:
                after.append((t - release, len(m["l"])))
    return after


ps_res = {}
for ps_delay in (1, 2):
    for ps_rel in (27, 31, 35):  # let go right after a repeat, between two, just before the next
        for ps_stop in (False, True):
            ps_res[(ps_delay, ps_rel, ps_stop)] = ps_run(ps_stop, ps_delay, ps_rel)
            alive(40)
            take()
for k, v in sorted(ps_res.items()):
    print(f"  pickup_stop measured: delay {k[0]}, let go at {k[1]}, stop {k[2]}: last pick "
          f"+{max([a for a, _ in v], default=-1)} ticks, {sum(n for _, n in v)} items after F was let go")
check(all(max([a for a, _ in v], default=-1) <= k[0] for k, v in ps_res.items() if k[2]),
      "pickup_stop measured: with the stop, nothing is picked later than the packet's own delay after F is let go")
check(all(sum(n for _, n in v) <= k[0] for k, v in ps_res.items() if k[2]),
      "pickup_stop measured: with the stop, at most an item a tick of the packet's delay after F is let go")
check(all(max([a for a, _ in v], default=-1) >= 20 for k, v in ps_res.items() if not k[2]),
      "pickup_stop measured: an old client (no stop) picks on 20 ticks and more (as before, for old clients)")
# The inventory of a pick just before the stop still reaches the client (a pick's report waits PICK_REPORT_TICKS).
send({"t": "pickup"})
alive(1)
take()
F.put_on_belt(pk_belt, 2, "copper-plate", 0.75, 18190)
alive(1)
take()
F.put_on_belt(pk_belt, 2, "copper-plate", 0.75, 18191)
alive(1)
ps_m = take()
send({"t": "pickup_stop"})
alive(8)
ps_m += take()
check(of_type(ps_m, "pku") and pk_uids(pk_belt, 2) == [], "pickup_stop: the item picked the tick before the stop is said")
check([m for m in ps_m if m.get("t") in ("inv", "slots")],
      f"pickup_stop: its inventory still sent soon after the stop: {[m.get('t') for m in ps_m]}")
alive(40)
take()
# A stop with no pickup going: quietly nothing.
send({"t": "pickup_stop"})
alive(2)
check(g.storage.f3d.pickup is None and not of_type(take(), "msg"), "pickup_stop with no pickup going: quietly nothing")
# F held with the inventory full: said once; let go and pressed again, once more.
F.inventory_space = 0
for _ in range(3):
    PS_UID[0] += 1
    F.put_on_belt(pk_belt, 2, "copper-plate", 0.75, PS_UID[0])
    send({"t": "pickup"})
    alive(9)
ps_full = [m for m in of_type(take(), "msg") if m["text"] == "Inventory full"]
check(len(ps_full) == 1, f"pickup_stop: F held with the inventory full says so once: {len(ps_full)}")
send({"t": "pickup_stop"})
alive(2)
send({"t": "pickup"})
alive(9)
ps_full = [m for m in of_type(take(), "msg") if m["text"] == "Inventory full"]
check(len(ps_full) == 1, f"pickup_stop: pressed again, said once more: {len(ps_full)}")
send({"t": "pickup_stop"})
F.inventory_space = float("inf")
alive(40)
take()
# Mining held at the same time: the stop leaves the mining alone.
ps_tree = spawn("tree-01", 61.5, 51.5)
send({"t": "mine", "u": 0, "p": eid["tree-01"], "x": fixed(61.5), "y": fixed(51.5)})
send({"t": "pickup"})
alive(1)
ps_mining = g.storage.f3d.mining
send({"t": "pickup_stop"})
send({"t": "mine", "u": 0, "p": eid["tree-01"], "x": fixed(61.5), "y": fixed(51.5)})
alive(1)
check(ps_mining is not None and g.storage.f3d.mining is not None and g.storage.f3d.pickup is None,
      f"pickup_stop: mining held at the same time goes on, the pickup ends ({ps_mining is not None})")
send({"t": "mine_stop"})
alive(2)
if ps_tree.valid:
    ps_tree.destroy()
take()
# Two clients: one's stop leaves the other's pickup going (storage.f3d is swapped per client).
ps_mp = F.multiplayer
F.multiplayer = True  # (in single-player a hello from another port takes the one client's place)
send(hello_now)  # (A heard just now, so B's hello is a second client, not A's restart)
alive(1)
send({"t": "hello", "v": 1, "sid": "ps-b", "w": 0}, port=PORT_B)
alive(3)
take_by_port()
send({"t": "pickup"})
send({"t": "pickup"}, port=PORT_B)
alive(1)
ps_b = g.storage.f3d_extra[PORT_B]
ps_ok = g.storage.f3d.pickup is not None and ps_b.pickup is not None
send({"t": "pickup_stop"}, port=PORT_B)
alive(1)
check(ps_ok and g.storage.f3d.pickup is not None and ps_b.pickup is None,
      "pickup_stop, two clients: B's stop ends B's pickup, A's goes on")
send({"t": "pickup"}, port=PORT_B)
alive(1)
send({"t": "pickup_stop"})
alive(1)
check(g.storage.f3d.pickup is None and ps_b.pickup is not None, "pickup_stop, two clients: A's stop leaves B's going")
send({"t": "pickup_stop"}, port=PORT_B)
send({"t": "bye"}, port=PORT_B)
alive(3)
take_by_port()
F.multiplayer = ps_mp
alive(40)
take()
for e in (pk_belt, pk_far, pk_under):
    e.destroy()
j9_pup.position = lua.table_from({"x": pk_was["x"], "y": pk_was["y"]})
lua.execute('package.loaded["scripts.belt_sim"].resend = F_resend_real')
j9_put.destroy()
j9_pup.position = lua.table_from({"x": j9_was["x"], "y": j9_was["y"]})
send({"t": "focus", "x": fixed(j9_focus["x"]), "y": fixed(j9_focus["y"]), "r": int(j9_focus["r"])})
while (int(g.game.tick) - j9_start) % 1200:  # the checks after keep the tick phase they were written at
    alive(1)
take()

# 9. Moving things from one search: cargo pods, rolling stock and enemy units from the movers' search, not a
# search each of the same square; worms every 300 ticks.
say(b=1)
send({"t": "focus", "x": fixed(20), "y": fixed(20), "r": 64})
alive(2)
take()
os_wall = spawn("stone-wall", 30.5, 26.5, force="player")
os_biter = spawn("small-biter", 31.2, 26.5, force="enemy")
os_biter.commandable.distraction_command = lua.table_from({"type": g.defines.command.attack, "target": os_wall})
os_pod = spawn("cargo-pod", 24.0, 22.0, force="player")
os_loco = spawn("locomotive", 34.0, 30.0, force="player")


def one_search_round():
    F.finds = lua.table_from({})
    got = {"cp": False, "tr": False, "en": False}
    for _ in range(130):
        alive(1)
        for m in take():
            if m.get("t") == "cp" and any(r[0] == os_pod.unit_number for r in m["l"]):
                got["cp"] = True
            if m.get("t") == "tr" and any(os_loco.unit_number in r[6] for r in m["l"]):
                got["tr"] = True
            if m.get("t") == "en" and os_biter.unit_number in m["l"][0::3]:
                got["en"] = True
    finds = to_py(F.finds) or {}
    F.finds = None
    return got, finds


got_on, finds_on = one_search_round()
set_perf(one_search=False)
got_off, finds_off = one_search_round()
set_perf()
own = ("cargo-pod", "locomotive,cargo-wagon", "unit,turret", "spider-unit,spider-vehicle")  # (the types the fake has)
check(all(got_on.values()) and all(got_off.values()),
      f"one_search: cargo pods, trains and attacking enemies are sent either way: {got_on} / {got_off}")
check(not any(finds_on.get(k) for k in own) and finds_on.get("turret", 0) <= 1 and all(finds_off.get(k) for k in own),
      f"one_search: no search of their own for pods, trains and units (worms every 300 ticks): {finds_on} / off {finds_off}")
for e in (os_wall, os_biter, os_pod, os_loco):
    e.destroy()

# 12. The two-call lane check (/f3d-bs two_call, two_call_full default 16): count and front as the record
# has them, unchanged; a front that moved is seen at once; the back moving alone is seen at every 16th check
# (or every 4th with /f3d-bs two_call_full 4).
tc_belt = spawn("transport-belt", 90.5, 90.5, force="player", direction=4)
F.put_on_belt(tc_belt, 1, "iron-plate", 0.25, 9401)
F.put_on_belt(tc_belt, 1, "iron-plate", 0.75, 9402)
tc_line = tc_belt.get_transport_line(1)
tc_rec = lua.table_from([2, fixed(0.25), fixed(0.75), 2])
two_call = bs_mod.two_call_line
tc_rec[15] = 0
seen = [list(two_call(tc_line, tc_rec))]
F.move_on_belt(tc_belt, 1, 9402, 0.625)
seen += [list(two_call(tc_line, tc_rec)) for _ in range(15)]
F.move_on_belt(tc_belt, 1, 9401, 0.125)
seen += [list(two_call(tc_line, tc_rec))]
check(all(seen[k] == [2, 64, 192, 2] for k in range(15)) and seen[15] == [2, 64, 160, 2]
      and seen[16] == [2, 32, 160, 2],
      f"two_call: unchanged by count and front, the back alone seen at every 16th check, a front that moved at once: {seen}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "two_call_full 4"}))
F.move_on_belt(tc_belt, 1, 9401, 0.25)
F.move_on_belt(tc_belt, 1, 9402, 0.75)
tc_rec4 = lua.table_from([2, fixed(0.25), fixed(0.75), 2])
tc_rec4[15] = 0
seen4 = [list(two_call(tc_line, tc_rec4))]
F.move_on_belt(tc_belt, 1, 9402, 0.625)
seen4 += [list(two_call(tc_line, tc_rec4)) for _ in range(3)]
check(seen4[0] == [2, 64, 192, 2] and seen4[1] == [2, 64, 192, 2] and seen4[2] == [2, 64, 192, 2] and seen4[3] == [2, 64, 160, 2],
      f"two_call_full 4: restores checking the back every 4th check: {seen4}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "two_call_full default"}))
tc_belt.destroy()

# 12b. watch_lean (/f3d-bs watch_lean, on): a lane's methods read off the line once (line_fns) and called from there,
# with the same results; off: read off the line at every check, as before. A proxy counts the method reads.
lean_belt = spawn("transport-belt", 92.5, 90.5, force="player", direction=4)
F.put_on_belt(lean_belt, 1, "iron-plate", 0.25, 9411)
F.put_on_belt(lean_belt, 1, "iron-plate", 0.75, 9412)
lean_proxy = lua.execute("""
  local line = ...
  local reads = { n = 0 }
  local proxy = setmetatable({}, {
    __index = function(_, k)
      if type(k) == "string" and k:sub(1, 4) == "get_" then reads.n = reads.n + 1 end
      return line[k]
    end,
    __len = function() return #line end })
  return proxy, reads
""", lean_belt.get_transport_line(1))
lean_line, lean_reads = lean_proxy
def lean_run(n_checks):
    lines = lua.table_from([lean_line])
    lines["len"] = lua.table_from({})
    rec = lua.table_from([2, fixed(0.25), fixed(0.75), 2])
    rec[15] = 0
    r0 = int(lean_reads.n)
    out = []
    for _ in range(n_checks):
        out.append(list(two_call(lean_line, rec, bs_mod.line_fns(lines, 1))))
    return out, int(lean_reads.n) - r0
lean_on, lean_on_reads = lean_run(20)
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "watch_lean off"}))
lean_off, lean_off_reads = lean_run(20)
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "watch_lean default"}))
check(lean_on == lean_off and lean_on_reads <= 3 and lean_off_reads >= 40,
      f"watch_lean: same checks, methods read once ({lean_on_reads}) not every check (off: {lean_off_reads}): {lean_on[:2]}")
lean_belt.destroy()

# 8. Far belts checked in turn (/f3d-bs far_tier, off by default): within far_ring every update, beyond it a
# cursor over the far actors and watched belts, far_units an update; a far inserter that acts still gets its
# belt read, a few updates later.
fx0, fy0 = -60.5, 60.5
ft_belts = [spawn("transport-belt", fx0 + k, fy0, force="player", direction=4) for k in range(12)]
for k in range(11):
    F.link_belts(ft_belts[k], ft_belts[k + 1])
ft_ins = [spawn("inserter", fx0 + k, fy0 + 1, force="player") for k in range(12)]
for k in range(12):
    ft_ins[k].pickup_target = ft_belts[k]
for k in range(12):
    F.put_on_belt(ft_belts[k], 1, "iron-plate", 0.5, 9500 + k)
say(z=1, bl=1, bs=1)
send({"t": "focus", "x": fixed(fx0), "y": fixed(fy0), "r": 64})
send({"t": "bfar", "r": 0, "n": 16, "m": 0})
g.storage.f3d_bs = lua.table_from({"far_tier": True, "far_ring": 4, "far_units": 8})
alive(60)
take()
far_before = int(bs_mod.counts.far_checks or 0)
ft = g.storage.f3d.bs.ft
far_units_list = set(to_py(ft.units)) if ft else set()
check(ft is not None and int(ft_belts[10].unit_number) in far_units_list and int(ft_ins[10].unit_number) in far_units_list
      and int(ft_belts[1].unit_number) not in far_units_list and int(ft_belts[1].unit_number) in set(to_py(ft.near_w)),
      f"far_tier: watched belts and inserters past far_ring go in the far list, nearer ones stay near: {sorted(far_units_list)}")
# The far inserter takes the plate: its belt is read within a few updates (12 actors and belts, a few a time).
F.move_on_belt(ft_belts[10], 1, 9510, None)
F.set_hand(ft_ins[10], fx0 + 10, fy0 + 0.5, "iron-plate")
key10 = int(ft_belts[10].unit_number) * 8 + 1
read_at = None
for upd in range(1, 21):
    alive(6)
    if key10 in bs_of(take())["sl"]:
        read_at = upd
        break
far_after = int(bs_mod.counts.far_checks or 0)
check(read_at is not None and read_at > 1 and far_after > far_before,
      f"far_tier: a far inserter's take is read after a few updates, not at once: update {read_at}, {far_after - far_before} far checks")
# Zero-alloc far_split keeps deterministic ascending unit-number order when two actors share a far belt,
# skips downstream tail catch-up on far belts while keeping near tails, skips far bre read_runs, and orders
# asked bre groups nearest-first.
ft_ins_tie = spawn("inserter", fx0 + 10, fy0 - 1, force="player")
ft_ins_tie.pickup_target = ft_belts[10]
F.set_hand(ft_ins[10], fx0 + 10, fy0 + 0.5, None)
F.set_hand(ft_ins[1], fx0 + 1, fy0 + 0.5, None)
for b_i, base_id in [(0, 9600), (1, 9610), (2, 9620), (9, 9630), (10, 9640), (11, 9650)]:
    F.move_on_belt(ft_belts[b_i], 1, 9500 + b_i, None)
    for s_idx, pos in enumerate((0.1, 0.35, 0.6, 0.85)):
        F.put_on_belt(ft_belts[b_i], 1, "iron-plate", pos, base_id + s_idx)
g.storage.f3d_bs = lua.table_from({"far_tier": True, "far_ring": 4, "far_units": 200})
bs_mod.reset()
alive(60)
take()
ft2 = g.storage.f3d.bs.ft
ft_u = list(to_py(ft2.units)) if ft2 else []
ft_k = list(to_py(ft2.kinds)) if ft2 else []
u10, u_ins10, u_tie = int(ft_belts[10].unit_number), int(ft_ins[10].unit_number), int(ft_ins_tie.unit_number)
p_lo, p_hi, p_b10 = ft_u.index(min(u_ins10, u_tie)), ft_u.index(max(u_ins10, u_tie)), ft_u.index(u10)
check(p_lo < p_hi < p_b10 and ft_k[p_lo] == 7 and ft_k[p_hi] == 7 and ft_k[p_b10] == 3,
      f"far_split tie-break puts both actors ascending before their far belt: {(p_lo, p_hi, p_b10)}")
tail_0 = int(bs_mod.counts.r_tail or 0)
F.move_on_belt(ft_belts[10], 1, 9640, None)
F.set_hand(ft_ins[10], fx0 + 10, fy0 + 0.5, "iron-plate")
alive(6)
take()
tail_far = int(bs_mod.counts.r_tail or 0)
F.move_on_belt(ft_belts[1], 1, 9610, None)
F.set_hand(ft_ins[1], fx0 + 1, fy0 + 0.5, "iron-plate")
alive(6)
take()
tail_near = int(bs_mod.counts.r_tail or 0)
check(tail_far == tail_0 and tail_near > tail_0,
      f"far_tier skips far tail catch-up ({tail_0} -> {tail_far}) while near belts still catch up (-> {tail_near})")
key1 = int(ft_belts[1].unit_number) * 8 + 1
r_run0 = int(bs_mod.counts.r_run or 0)
send({"t": "bre", "l": [key10]})
alive(6)
take()
r_run_far = int(bs_mod.counts.r_run or 0)
send({"t": "bre", "l": [key1]})
alive(6)
take()
r_run_near = int(bs_mod.counts.r_run or 0)
check(r_run_far == r_run0 and r_run_near > r_run0,
      f"far bre skips read_runs ({r_run0} -> {r_run_far}) while near bre runs read_runs (-> {r_run_near})")
while g.storage.f3d.bs.round is not None:
    alive(1)
take()
send({"t": "bre", "l": [key10, key1]})
alive(1)
q_groups = []
rnd = g.storage.f3d.bs.round
if rnd:
    for seg in to_py(rnd.q):
        if seg[0] == 2:
            q_groups = seg[1]
            break
check(len(q_groups) >= 2 and key1 in q_groups[0] and key10 in q_groups[1],
      f"bre groups ordered nearest-first by scan index despite far sent first: {q_groups}")
alive(6)
take()
ft_ins_tie.destroy()
g.storage.f3d_bs = None
for e in ft_belts + ft_ins:
    e.destroy()
say(b=1)
alive(6)
take()

# 13. Decoratives by distance: a client that says how far it draws them (hello dd) gets a chunk's `dec` only
# within dd + 64 tiles of its square's middle; the others once the middle brings them inside.
F.add_decorative(F.surface, "small-rock", 100, 100, 2)
rows7 = [[cy, -3, 7] for cy in range(-3, 4)]
send({"t": "sub", "c": [[0, 0]]})
alive(10)
say(b=1, dc=1, dd=32)
send({"t": "sub", "o": [0, 0], "r": 3, "w": rows7})
alive(120)
dec_first = {(m["cx"], m["cy"]) for m in of_type(take(), "dec")}
check((0, 0) in dec_first and (3, 0) in dec_first and (3, 3) not in dec_first and (-3, -3) not in dec_first,
      f"dec_distance: decoratives only for chunks within dd + 64 tiles of the square's middle: {sorted(dec_first)}")
send({"t": "sub", "o": [2, 2], "r": 3, "w": [[cy, -1, 7] for cy in range(-1, 6)]})
alive(60)
dec_moved = [m for m in of_type(take(), "dec") if (m["cx"], m["cy"]) == (3, 3)]
check(dec_moved and dec_moved[-1]["l"] == [did.get("small-rock"), 4, 4, 2],
      f"dec_distance: a chunk held back gets its decoratives once the middle brings it inside: {dec_moved}")
say(b=1, dc=1)
send({"t": "sub", "o": [0, 0], "r": 3, "w": rows7})
alive(10)
send({"t": "resync", "c": [[-3, -3]]})
alive(60)
check([m for m in of_type(take(), "dec") if (m["cx"], m["cy"]) == (-3, -3)],
      "dec_distance: without dd every chunk's decoratives, as before")
say(b=1)
alive(6)
take()

# 11. Minimap charts sent only when they changed: each chart carries its stamp (st); asked again with the
# stamps the client holds (map h), an unchanged chunk is answered `same` with its live parts, a changed one
# with its picture.
F.charted["0,0"] = True
F.charted["1,0"] = True
chart_pole = spawn("small-electric-pole", 15.5, 15.5, force="player")


def charts_for(h=None):
    msg = {"t": "map", "cx1": 0, "cy1": 0, "cx2": 1, "cy2": 0, "res": 4}
    if h is not None:
        msg["h"] = h
    send(msg)
    alive(12)
    return {(m["cx"], m["cy"]): m for m in of_type(take(), "chart")}


first = charts_for()
stamps = [[cx, cy, m["st"]] for (cx, cy), m in first.items() if "st" in m]
check(len(stamps) == 2 and all(m["n"] == 8 for m in first.values()), f"chart_same: each chart carries its stamp: {stamps}")
same = charts_for(stamps)
check(all("same" in m and "px" not in m for m in same.values()) and len(same) == 2,
      f"chart_same: asked with the stamps it holds, unchanged chunks come back as same: {[sorted(m) for m in same.values()]}")
# (Multiplayer: whether it is `same` comes from storage, not the module-local picture cache, which a peer that
# loaded since hasn't got: without it the chunk uses the overlay-only fast path and skips get_tile completely.)
check(forget(g.package.loaded["scripts.map"].tick, "chart_cache"), "the chart cache can be forgotten")
lua.execute("""
_test_get_tile_calls = 0
_orig_get_tile = game.surfaces[1].get_tile
game.surfaces[1].get_tile = function(...)
  _test_get_tile_calls = _test_get_tile_calls + 1
  return _orig_get_tile(...)
end
""")
same_fresh = charts_for(stamps)
get_tile_calls = lua.eval("""
(function()
  game.surfaces[1].get_tile = _orig_get_tile
  local c = _test_get_tile_calls
  _orig_get_tile, _test_get_tile_calls = nil, nil
  return c
end)()
""")
check(all("same" in m for m in same_fresh.values()) and len(same_fresh) == 2
      and get_tile_calls == 0
      and same_fresh[(0, 0)].get("ov") == first[(0, 0)].get("ov"),
      f"chart_same cold cache: overlay-only fast path preserves ov with 0 get_tile calls (got {get_tile_calls}): {same_fresh}")
changed = spawn("stone-wall", 40.5, 8.5, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": changed}))
alive(1)
take()
again = charts_for(stamps)
check("same" in again.get((0, 0), {}) and "px" in again.get((1, 0), {}) and again[(1, 0)].get("st") not in (None, stamps[0][2], stamps[1][2]),
      f"chart_same: a chunk built in since comes with its new picture and stamp: {[(k, sorted(m)) for k, m in again.items()]}")
set_perf(chart_same=False)
off = charts_for(stamps)
set_perf()
check(all("px" in m and "st" not in m for m in off.values()), "chart_same off: the pictures every time, as before")
changed.destroy()
chart_pole.destroy()

# Periodic chunk refresh (next_refresh, REFRESH_INTERVAL = 300): unchanged subscribed chunks skip
# full re-snapshotting when [si, rev, count] still matches s.sent, while silent script entity changes
# without events are caught and re-sent.
w_mod = g.package.loaded["scripts.world"]
was_count_int = w_mod.count_interval
w_mod.count_interval = 0
send({"t": "sub", "c": [[0, 0]]})
alive(10)
take()
alive(320)
ref_same = of_type(take(), "chunk")
check(not ref_same, f"next_refresh skips unchanged subscribed chunk with matching s.sent: {ref_same}")
silent_chest = spawn("wooden-chest", 16.5, 16.5, force="player")  # no event -> rev unchanged, count changes
alive(320)
ref_changed = [m for m in of_type(take(), "chunk") if (m["cx"], m["cy"]) == (0, 0)]
check(len(ref_changed) == 1 and "tiles" in ref_changed[0],
      f"next_refresh catches silent script entity change and resends chunk: {ref_changed}")
silent_chest.destroy()
w_mod.count_interval = was_count_int

# A Zenith that quits without a goodbye (a crash, killed) and starts again before the bridge's 10 s
# timeout comes back with a new session id, often from another port: it got a second character at
# the spawn. Now it takes the silent client's place and character, where it stood.
PORT_C = PORT_B + 2
was_mp = F.multiplayer
F.multiplayer = True


def keep_first_alive(n):
    """n ticks with the first client saying hello every second, as a live Zenith does."""
    for _ in range(n // 60):
        send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
        tick(60)
    send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
    tick(n % 60)


send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
send({"t": "hello", "v": 1, "sid": "b", "w": 0}, port=PORT_B)
tick(3)
b_char = g.storage.f3d_extra[PORT_B].puppet
b_was = {"x": b_char.position.x, "y": b_char.position.y}
b_char.teleport(lua.table_from({"x": 40.5, "y": -12.5}))
keep_first_alive(120)  # b silent for 2 s: maybe a hitch
take_by_port()
send({"t": "hello", "v": 1, "sid": "b-again", "w": 0}, port=PORT_C)
tick(3)
by = take_by_port()
check(not of_type(by.get(PORT_C, []), "welcome") and g.storage.f3d_extra[PORT_C] is None and g.storage.f3d_extra[PORT_B] is not None,
      f"restart: a new port's hello waits while a client is silent 2 s (neither heard lately nor gone): {sorted(by)}")
keep_first_alive(150)  # b silent past 4 s: gone
send({"t": "hello", "v": 1, "sid": "b-again", "w": 0}, port=PORT_C)
tick(3)
by = take_by_port()
welcome_c = of_type(by.get(PORT_C, []), "welcome")
check(welcome_c and welcome_c[0]["u"] == b_char.unit_number and welcome_c[0]["x"] == fixed(40.5) and welcome_c[0]["y"] == fixed(-12.5)
      and g.storage.f3d_extra[PORT_B] is None and g.storage.f3d_extra[PORT_C] is not None
      and g.storage.f3d_extra[PORT_C].client.sid == "b-again" and g.storage.f3d.client.port == CLIENT_PORT,
      f"restart: a second client's Zenith back on another port gets its own character where it stood, not a new one at the spawn: {welcome_c[:1]}")
send({"t": "bye"}, port=PORT_C)
tick(1)
b_char.teleport(lua.table_from(b_was))
# The first client: its Zenith restarts on another port while the save's character waits for it.
a_char = g.storage.f3d.puppet
a_was = {"x": a_char.position.x, "y": a_char.position.y}
a_char.teleport(lua.table_from({"x": -126.5, "y": -18.5}))
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(250)
take_by_port()
send({"t": "hello", "v": 1, "sid": "s1-again", "w": 0}, port=PORT_C)
tick(3)
by = take_by_port()
welcome_c = of_type(by.get(PORT_C, []), "welcome")
check(welcome_c and welcome_c[0]["u"] == a_char.unit_number and welcome_c[0]["x"] == fixed(-126.5) and welcome_c[0]["y"] == fixed(-18.5)
      and g.storage.f3d.client.port == PORT_C and len(g.storage.f3d_extra) == 0,
      f"restart: the first client's Zenith back on another port takes its place and character, where it stood: {welcome_c[:1]}")
# A client heard within the last second is alive: the new port is another Zenith, with a character of its own.
send({"t": "hello", "v": 1, "sid": "s1-again", "w": 1}, port=PORT_C)
tick(30)
send({"t": "hello", "v": 1, "sid": "d", "w": 0}, port=PORT_B)
tick(3)
by = take_by_port()
welcome_d = of_type(by.get(PORT_B, []), "welcome")
check(welcome_d and welcome_d[0]["u"] != a_char.unit_number and g.storage.f3d.client.port == PORT_C and g.storage.f3d_extra[PORT_B] is not None,
      f"restart: a new port beside a live client is a second client, as before: {welcome_d[:1]}")
send({"t": "bye"}, port=PORT_B)
send({"t": "bye"}, port=PORT_C)
tick(1)
# The debug menu's speed: at 4x a live Zenith's hellos are 240 ticks apart, so 300 ticks silent is still alive.
g.game.speed = 4
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(300)
take_by_port()
send({"t": "hello", "v": 1, "sid": "e", "w": 0}, port=PORT_B)
tick(3)
by = take_by_port()
check(of_type(by.get(PORT_B, []), "welcome") and g.storage.f3d.client.port == CLIENT_PORT and g.storage.f3d_extra[PORT_B] is not None,
      "restart: at 4x speed a client silent 300 ticks (1.25 s) is alive, and the new port a second client")
send({"t": "bye"}, port=PORT_B)
g.game.speed = 1
tick(1)
a_char.teleport(lua.table_from(a_was))
take_by_port()
send(hello_now)
F.multiplayer = was_mp
tick(1)

# --- target_spots (/f3d-bs, on): a drill's or inserter's belt found by its spot -------------------------------
# In 2.1 a drill has no drop_target until it first puts something out, and a replaced target is a dead entity
# until then; belt_sim.lua reads a chunk's targets once and keeps them (bs.bt). So a drill placed before its belt,
# or a belt replaced under a running drill, left the belt unwatched for good: its items reached the client only
# through drift checks and asks. Last, as its ticks would shift the periodic jobs' phases for the checks above.
def drain():
    """What was sent, without take()'s numbering checks: the restart checks above leave a second client's
    reliable messages to this port."""
    out = []
    for item in F.take_sent().values():
        out += protocol.split_datagram(sent_data(item))
    return out


bs_t = lua.eval('package.loaded["scripts.belt_sim"]')
check("target_spots on" in str(bs_t.option_command("")[1]), "/f3d-bs lists target_spots (on)")
watched_of = lua.eval("function(u) local b = storage.f3d.bs; local r = b and b.belts[u]; return (r and r[4]) and true or false end")
actor_of = lua.eval("function(u) local b = storage.f3d.bs; return (b and b.actors[u] ~= nil) and true or false end")
retry_of = lua.eval("function(u) local b = storage.f3d.bs; return (b and b.retry and b.retry[u] ~= nil) and true or false end")
tx, ty = 1500.5, 330.5
tick(2)
drain()
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1, "bs": 1})
send({"t": "focus", "x": fixed(tx), "y": fixed(ty + 10), "r": 48})
send({"t": "bfar", "r": 0, "n": 24, "m": 0})
tick(30)
drain()


ts_hello = {"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1, "bs": 1}


def keep(n):
    """n ticks, the client saying hello every 100 (it would time out)."""
    for _ in range(n):
        if g.game.tick % 100 == 0:
            send(ts_hello)
        tick(1)


def drill_then_belt(y, wait=180, raise_belt=True):
    """A drill (no drop_target, as the game has it) dropping on the tile at (tx, y), its belt (two tiles) laid
    `wait` ticks later. Returns (drill, first belt, second belt)."""
    d = spawn("burner-mining-drill", tx - 1.5, y + 0.5, force="player")
    d.drop_position = lua.table_from({"x": tx - 0.2, "y": y - 0.2})
    F["raise"]("script_raised_built", lua.table_from({"entity": d}))
    keep(wait)
    b1 = spawn("transport-belt", tx, y, force="player", direction=4)
    b2 = spawn("transport-belt", tx + 1, y, force="player", direction=4)
    F.link_belts(b1, b2)
    if raise_belt:
        F["raise"]("script_raised_built", lua.table_from({"entity": b1}))
        F["raise"]("script_raised_built", lua.table_from({"entity": b2}))
    return d, b1, b2


# Off: as before, the drill's belt isn't watched and the drill is no actor.
bs_t.option_command("target_spots off")
d_off, b_off, _ = drill_then_belt(ty)
tick(30)
drain()
check(not watched_of(int(b_off.unit_number)) and not actor_of(int(d_off.unit_number)),
      "target_spots off: a drill placed before its belt (no drop_target yet) leaves the belt unwatched, as before")
bs_t.option_command("target_spots default")
# On: a drill placed, its belt laid 3 s later: the belt on its drop spot is its input spot.
d_on, b_on, b_on2 = drill_then_belt(ty + 4)
tick(30)
on_msgs = bs_of(drain())
check(watched_of(int(b_on.unit_number)) and actor_of(int(d_on.unit_number)) and not watched_of(int(b_on2.unit_number)),
      f"target_spots: a drill placed before its belt (no drop_target yet) has the belt on its drop spot watched: "
      f"{watched_of(int(b_on.unit_number))} {actor_of(int(d_on.unit_number))}")
# Its progress going round wakes the belt, whose new item goes in `sl` on that update.
d_on.mining_progress = 0.5
tick(12)
drain()
d_on.mining_progress = 0.1
F.put_on_belt(b_on, 1, "iron-ore", 0.5, 8601)
tick(12)
woke = bs_of(drain())
check(8601 in [it[0] for it in woke["sl"].get(int(b_on.unit_number) * 8 + 1, (None, []))[1]],
      f"target_spots: the drill's output on its belt is sent at once: {woke['sl'].get(int(b_on.unit_number) * 8 + 1)}")
# drill_tails (on): a drill whose item ran off its drop belt before the drill's check showed it had put out: the belt
# its drop belt feeds is read too (off, as before: only the drop belt, where the item no longer is).
tails_got = {}
for flag, uid in (("off", 8603), ("default", 8602)):
    bs_t.option_command("drill_tails " + flag)
    d_on.mining_progress = 0.6
    keep(12)
    drain()
    d_on.mining_progress = 0.2
    F.put_on_belt(b_on2, 1, "iron-ore", 0.3, uid)
    keep(12)
    got_t = bs_of(drain())
    tails_got[flag] = uid in [it[0] for it in got_t["sl"].get(int(b_on2.unit_number) * 8 + 1, (None, []))[1]]
check(tails_got == {"off": False, "default": True},
      f"drill_tails: a drill's item already past its drop belt at the drill's check is read on the next belt (off: not): {tails_got}")
# A belt replaced under a running drill: the game's drop_target is the old belt, dead until the drill puts again.
d_run = spawn("burner-mining-drill", tx - 1.5, ty + 8.5, force="player")
d_run.drop_position = lua.table_from({"x": tx - 0.2, "y": ty + 7.8})
r1 = spawn("transport-belt", tx, ty + 8, force="player", direction=4)
r2 = spawn("transport-belt", tx + 1, ty + 8, force="player", direction=4)
F.link_belts(r1, r2)
d_run.drop_target = r1
for e in (d_run, r1, r2):
    F["raise"]("script_raised_built", lua.table_from({"entity": e}))
tick(30)
drain()
check(watched_of(int(r1.unit_number)) and actor_of(int(d_run.unit_number)), "target_spots: a running drill's belt is watched")
F["raise"]("script_raised_destroy", lua.table_from({"entity": r1}))
r1.destroy()
r1b = spawn("transport-belt", tx, ty + 8, force="player", direction=4)
F.link_belts(r1b, r2)
F["raise"]("script_raised_built", lua.table_from({"entity": r1b}))
tick(30)
drain()
check(watched_of(int(r1b.unit_number)) and actor_of(int(d_run.unit_number)),
      f"target_spots: a belt replaced under a running drill (its drop_target the dead belt) is watched: {watched_of(int(r1b.unit_number))}")
# A drill with nothing on its drop spot is looked at again; a belt laid there without an event is found.
d_late, b_late, _ = drill_then_belt(ty + 12, wait=30, raise_belt=False)
check(retry_of(int(d_late.unit_number)), "target_spots: a drill with no target and no belt on its spot is listed to look at again")
keep(1300)
drain()
check(watched_of(int(b_late.unit_number)) and actor_of(int(d_late.unit_number)) and not retry_of(int(d_late.unit_number)),
      f"target_spots: a belt laid on a drill's spot without an event is found by the look again: "
      f"{watched_of(int(b_late.unit_number))} {actor_of(int(d_late.unit_number))}")
for e in (d_off, b_off, d_on, b_on, b_on2, d_run, r1b, r2, d_late, b_late):
    if e.valid:
        e.destroy()
send(hello_now)
tick(1)
drain()

# --- J26: mining sweeps -------------------------------------------------------------------------------
# As 2.1.24's own mining does (measured with a player-less character's mining_state and
# update_selected_entity): the target is what is under the cursor; a new one starts from nothing, none
# keeps the progress without mining, the same one again goes on; the character stands while it mines.
# The client says where its cursor is from the character (ox, oy) and the bridge follows that point
# each tick, so walking with the button held along a line of belts mines every belt in turn.
sw = g.storage.f3d
is_same = lua.eval("function(a, b) return a == b end")  # (`same` is a chart check's by now)
sweep_home = puppet.position
sx, sy = 600.0, 600.0
puppet.teleport(lua.table_from({"x": sx, "y": sy}))
send({"t": "mine_stop"})
tick(1)
F.walk_moves = True
line = [spawn("transport-belt", sx + 2.5 + i, sy - 1.5, force="player", direction=4) for i in range(3)]
moved_while_mining = []
mined_by = None
for t in range(400):
    if t % 9 == 0:  # as the client repeats them
        send({"t": "walk", "d": 4})
        send({"t": "mine", "n": 1, "ox": fixed(2.5), "oy": fixed(-1.5)})
    m = sw.mining
    target = m.entity if m is not None and not m.paused else None
    x0 = puppet.position.x
    tick(1)
    if target is not None and sw.mining is not None and is_same(sw.mining.entity, target) and puppet.position.x != x0:
        moved_while_mining.append(t)
    if all(not b.valid for b in line):
        mined_by = t
        break
send({"t": "walk", "d": -1})
send({"t": "mine_stop"})
tick(1)
F.walk_moves = False
check(mined_by is not None and not moved_while_mining,
      f"J26: walking with the button held mines every belt of a line in turn, standing while it mines: "
      f"mined by tick {mined_by}, moved while mining at {moved_while_mining[:5]}")
# A mouse sweep, standing: off the belt the progress waits (and the character may walk), back on it
# it goes on; on another belt it starts again.
puppet.teleport(lua.table_from({"x": sx, "y": sy}))
pa = spawn("transport-belt", sx + 2.5, sy - 1.5, force="player", direction=4)
pb = spawn("transport-belt", sx + 3.5, sy - 1.5, force="player", direction=4)
on_a = {"t": "mine", "u": pa.unit_number, "p": eid["transport-belt"], "x": fixed(sx + 2.5), "y": fixed(sy - 1.5),
        "ox": fixed(2.5), "oy": fixed(-1.5)}
send(on_a)
tick(30)
half = sw.mining.progress
send({"t": "mine", "n": 1, "ox": fixed(2.5), "oy": fixed(3.5)})
send({"t": "walk", "d": 4})
tick(1)
paused = sw.mining is not None and sw.mining.paused and sw.mining.progress == half and puppet.walking_state.walking
tick(8)
send({"t": "walk", "d": -1})
send(on_a)
tick(1)
resumed = sw.mining is not None and is_same(sw.mining.entity, pa) and not sw.mining.paused and sw.mining.progress > half
check(paused and resumed, f"J26: off the target the progress waits and the walk goes on, back on it mining goes on: {half} {paused} {resumed}")
tick(10)
send({"t": "mine", "u": pb.unit_number, "p": eid["transport-belt"], "x": fixed(sx + 3.5), "y": fixed(sy - 1.5),
      "ox": fixed(3.5), "oy": fixed(-1.5)})
tick(1)
check(pa.valid and is_same(sw.mining.entity, pb) and sw.mining.progress < half,
      f"J26: another target under the cursor starts from nothing, the last left as it was: {sw.mining.progress}")
# The client's view is a few ticks behind: a `mine` for the belt just mined (gone) keeps the one the
# point has reached.
send({"t": "mine", "u": 999999, "p": eid["transport-belt"], "x": fixed(sx + 9.5), "y": fixed(sy - 1.5),
      "ox": fixed(3.5), "oy": fixed(-1.5)})
tick(1)
check(sw.mining is not None and is_same(sw.mining.entity, pb), "J26: a `mine` for something gone keeps the sweep's target")
send({"t": "mine_stop"})
tick(1)
check(sw.mining is None and sw.mine_at is None, "J26: letting go ends the sweep")
for e in (pa, pb):
    if e.valid:
        e.destroy()
puppet.teleport(sweep_home)
drain()

# --- K16: built_now (/f3d-bs, on): a belt built, replaced, removed or turned is worked out the next tick ------------
# Before, a new belt waited for the round's start, any scan in progress and a scan of its own, each reading at most
# two chunks a tick whose lists had expired: at a belt item distance of 320 it reached the client up to 200 ticks
# after it was built (640: 550), the line it extended standing in Zenith meanwhile. Every chunk list of the square
# is made to have expired here (as a while after the last scan), and a scan begun, before each build.
bs_k = lua.eval('package.loaded["scripts.belt_sim"]')
check("built_now on" in str(bs_k.option_command("")[1]), "/f3d-bs lists built_now (on)")
kx, ky = 2500.5, 330.5
send(ts_hello)
send({"t": "focus", "x": fixed(kx), "y": fixed(ky + 2), "r": 192})
send({"t": "bfar", "r": 320, "n": 320, "m": 0})
k_line = [spawn("transport-belt", kx + i, ky, force="player", direction=4) for i in range(4)]
for a_, b_ in zip(k_line, k_line[1:]):
    F.link_belts(a_, b_)
for i_, e_ in enumerate(k_line):
    F.put_on_belt(e_, 1, "iron-plate", 0.5, 8700 + i_)
k_in = spawn("underground-belt", kx, ky + 6, force="player", direction=4, type="input")
for e_ in k_line + [k_in]:
    F["raise"]("script_raised_built", lua.table_from({"entity": e_}))
keep(120)
drain()
k_loaded = lua.eval("function(u) local b = storage.f3d.bs; return (b and b.belts[u]) and true or false end")
check(all(k_loaded(int(e_.unit_number)) for e_ in k_line + [k_in]), "K16: the test's belts are loaded")


def k_expire():
    lua.execute("storage.f3d.bs.bc = {}; storage.f3d.bs.rescan = true")
    keep(7)
    drain()


def k_wait(keys, n=300, field="lm"):
    """Ticks until one of `keys` is in a `bs` message's `field`, and what came: (ticks, bs_of of that tick)."""
    t0 = g.game.tick
    for _ in range(n):
        keep(1)
        got = bs_of(drain())
        if any(k_ in (got[field] if field != "dl" else set(got["dl"])) for k_ in keys):
            return g.game.tick - t0, got
    return None, None


k_built = {}
for flag, x_ in (("off", 4), ("default", 5)):
    bs_k.option_command("built_now " + flag)
    k_expire()
    e_ = spawn("transport-belt", kx + x_, ky, force="player", direction=4)
    F.link_belts(k_line[-1], e_)
    k_line.append(e_)
    t_built = g.game.tick
    F["raise"]("script_raised_built", lua.table_from({"entity": e_}))
    u_ = int(e_.unit_number)
    ticks_, got_ = k_wait([u_ * 8 + 1])
    k_built[flag] = (ticks_, got_["sl"].get(u_ * 8 + 1, (None,))[0] - t_built if got_ else None)
    keep(30)
    drain()
check(k_built["default"][0] is not None and k_built["default"][0] <= 7 and k_built["default"][1] in (0, 1)
      and (k_built["off"][0] is None or k_built["off"][0] > 30),
      f"K16 built_now: a belt built comes in the next update, read on its tick (off: after the scans): "
      f"(ticks to its lm, its read's tick after the build) {k_built}")
u_new = int(k_line[-1].unit_number)
gone_new = []
for _ in range(80):
    keep(10)
    gone_new += bs_of(drain())["dl"]
check(k_loaded(u_new) and u_new * 8 + 1 not in gone_new,
      f"K16 built_now: the scans that began before it keep it loaded: {k_loaded(u_new)}, dl {gone_new}")
# A belt replaced (a fast-replace raises nothing for the old one): the old lanes leave as the new come.
k_expire()
old_ = k_line[2]
u_old = int(old_.unit_number)
old_.destroy()
rep_ = spawn("transport-belt", kx + 2, ky, force="player", direction=4)
F.link_belts(k_line[1], rep_)
F.link_belts(rep_, k_line[3])
k_line[2] = rep_
F["raise"]("script_raised_built", lua.table_from({"entity": rep_}))
ticks_, got_ = k_wait([int(rep_.unit_number) * 8 + 1])
check(ticks_ is not None and ticks_ <= 7 and u_old * 8 + 1 in got_["dl"] and u_old * 8 + 2 in got_["dl"],
      f"K16 built_now: a belt replaced: the new one's lanes in the next update, the old one's gone with them: {ticks_} "
      f"{got_['dl'] if got_ else None}")
# A belt removed: its lanes leave in the next update.
k_expire()
rm_ = k_line[-1]
u_rm = int(rm_.unit_number)
F["raise"]("script_raised_destroy", lua.table_from({"entity": rm_}))
rm_.destroy()
k_line.pop()
ticks_, got_ = k_wait([u_rm * 8 + 1], field="dl")
check(ticks_ is not None and ticks_ <= 7, f"K16 built_now: a belt removed leaves (dl) in the next update: {ticks_}")
# A belt turned: read again with its meta in the next update.
k_expire()
k_line[0].direction = 0
F["raise"]("on_player_rotated_entity", lua.table_from({"entity": k_line[0]}))
ticks_, got_ = k_wait([int(k_line[0].unit_number) * 8 + 1])
check(ticks_ is not None and ticks_ <= 7, f"K16 built_now: a belt turned is read again (lm) in the next update: {ticks_}")
# An underground exit built 9 tiles from its entrance (past forget_touched's reach round the exit): the entrance is
# read again with it, its hidden lines going on into the exit's (off: not, as before).
k_pair = {}
for flag, dx_ in (("off", 9), ("default", 9)):
    bs_k.option_command("built_now " + flag)
    k_expire()
    out_ = spawn("underground-belt", kx + dx_, ky + 6, force="player", direction=4, type="output")
    F.pair_undergrounds(k_in, out_)
    F["raise"]("script_raised_built", lua.table_from({"entity": out_}))
    ui_ = int(k_in.unit_number)
    ticks_, got_ = k_wait([ui_ * 8 + 3], n=24)
    k_pair[flag] = (ticks_, (got_["lm"].get(ui_ * 8 + 3) or [0])[-1] == int(out_.unit_number) * 8 + 1 if got_ else None)
    F["raise"]("script_raised_destroy", lua.table_from({"entity": out_}))
    out_.destroy()
    k_in.underground_belt_neighbour = None
    keep(30)
    drain()
check(k_pair["default"][0] is not None and k_pair["default"][0] <= 7 and k_pair["default"][1] and k_pair["off"][0] is None,
      f"K16 built_now: an underground's other end is read again when one is built, its hidden lines going on into the "
      f"exit (off: not): {k_pair}")
# The client's ug_guard keys an entrance's dead end off its hidden lines' next: an exit built for an existing entrance
# and then removed must each send the entrance's hidden lines again with their new next (its meta is cached till the
# belt is loaded again: next_of). Built 9 tiles off (past forget_touched's reach round the exit): next = the exit's
# line 1; removed: next 0 (no exit), not the old exit's key nor minus it.
bs_k.option_command("built_now default")
k_expire()
ue_out = spawn("underground-belt", kx + 9, ky + 6, force="player", direction=4, type="output")
F.pair_undergrounds(k_in, ue_out)
F["raise"]("script_raised_built", lua.table_from({"entity": ue_out}))
ue_u, ue_in = int(ue_out.unit_number), int(k_in.unit_number)
t_b, got_b = k_wait([ue_in * 8 + 3], n=24)
nx_b = (got_b["lm"].get(ue_in * 8 + 3) or [None])[-1] if got_b else None
keep(20)
drain()
F["raise"]("script_raised_destroy", lua.table_from({"entity": ue_out}))
ue_out.destroy()
k_in.underground_belt_neighbour = None
t_r, got_r = k_wait([ue_in * 8 + 3], n=24)
nx_r = (got_r["lm"].get(ue_in * 8 + 3) or [None])[-1] if got_r else None
keep(30)
drain()
check(t_b is not None and nx_b == ue_u * 8 + 1 and t_r is not None and t_r <= 7 and nx_r == 0,
      f"an underground exit built for an entrance sends the entrance's hidden lines with next its line 1 "
      f"({t_b} ticks: {nx_b}, want {ue_u * 8 + 1}), and removed again with next 0 ({t_r} ticks: {nx_r})")
# K22: the character mines a belt with no player (Factorio raises nothing then): its lanes leave in the next update
# (/f3d-perf mined_tell; off: as before, not until a check of it happened to come round).
k22 = {}
k22_home = puppet.position
g.settings["global"]["f3d-act-as-player"]["value"] = False  # (a headless server's character: no player to mine as)
for flag, dy_ in (("off", 12), ("default", 14)):
    F.commands["f3d-perf"](lua.table_from({"name": "f3d-perf", "parameter": "mined_tell " + flag}))
    mb_ = spawn("transport-belt", kx + 3.5, ky + dy_ + 0.5, force="player", direction=4)
    F.put_on_belt(mb_, 1, "iron-plate", 0.5, 8790 + dy_)
    F["raise"]("script_raised_built", lua.table_from({"entity": mb_}))
    keep(30)
    drain()
    um_ = int(mb_.unit_number)
    puppet.teleport(lua.table_from({"x": kx + 1.5, "y": ky + dy_ + 0.5}))
    mine_ = {"t": "mine", "u": um_, "p": eid["transport-belt"], "x": fixed(kx + 3.5), "y": fixed(ky + dy_ + 0.5),
             "ox": fixed(2.0), "oy": fixed(0.0)}
    t_mined = None
    gone_at = None
    for t_ in range(400):
        if t_ % 9 == 0 and mb_.valid:
            send(mine_)
        keep(1)
        if t_mined is None and not mb_.valid:
            t_mined = g.game.tick
        if (um_ * 8 + 1) in bs_of(drain())["dl"]:
            gone_at = g.game.tick
            break
    send({"t": "mine_stop"})
    keep(1)
    k22[flag] = (t_mined is not None, None if gone_at is None or t_mined is None else gone_at - t_mined)
F.commands["f3d-perf"](lua.table_from({"name": "f3d-perf", "parameter": "mined_tell default"}))
g.settings["global"]["f3d-act-as-player"]["value"] = True
puppet.teleport(k22_home)
check(k22["default"][0] and k22["default"][1] is not None and k22["default"][1] <= 7
      and k22["off"][0] and (k22["off"][1] is None or k22["off"][1] > 7),
      f"K22 mined_tell: a belt the character mines leaves the belt simulation (dl) in the next update (off: later): "
      f"(mined, ticks from its mining to its dl) {k22}")
# The owner's FUE5 pipe left open at its end: the character mines the middle of a run of five pipes with no player
# (Factorio raises nothing then): the two pipes beside it are sent again (`upd`) the tick after with their new
# connections, now the run's endings (pc 8 and 2) (/f3d-perf mined_neighbours; off: never, their records kept the side
# to the mined pipe and the client drew them as straights, open at the end in FUE5's kit).
pe = {}
pe_home = puppet.position
# (records go only for subscribed chunks: the pipes' chunk added to what this client has, put back after)
pe_subs = [[int(c) for c in k.split(",")] for k in to_py(lua.eval(
    "function() local o = {} for k in pairs(storage.f3d.subs) do o[#o + 1] = k end return o end")())]
pe_chunk = [int((kx + 1.5) // 32), int((ky + 20.5) // 32)]
send({"t": "sub", "c": pe_subs + [pe_chunk]})
keep(10)
drain()
g.settings["global"]["f3d-act-as-player"]["value"] = False
for flag, dy_ in (("off", 18), ("default", 20)):
    F.commands["f3d-perf"](lua.table_from({"name": "f3d-perf", "parameter": "mined_neighbours " + flag}))
    run_ = []
    for i_ in range(5):
        p_ = spawn("pipe", kx + 1.5 + i_, ky + dy_ + 0.5, force="player")
        F["raise"]("script_raised_built", lua.table_from({"entity": p_}))
        run_.append(p_)
    keep(5)
    drain()
    mid_ = run_[2]
    puppet.teleport(lua.table_from({"x": kx + 3.5, "y": ky + dy_ - 1.5}))
    mine_ = {"t": "mine", "u": int(mid_.unit_number), "p": eid["pipe"], "x": fixed(kx + 3.5), "y": fixed(ky + dy_ + 0.5),
             "ox": fixed(0.0), "oy": fixed(2.0)}
    t_mined, got_ = None, {}
    for t_ in range(300):
        if t_ % 9 == 0 and mid_.valid:
            send(mine_)
        keep(1)
        if t_mined is None and not mid_.valid:
            t_mined = g.game.tick
        for m_ in of_type(drain(), "upd"):
            if t_mined is not None and m_["e"][0] in (run_[1].unit_number, run_[3].unit_number):
                got_[m_["e"][0]] = (m_["e"][5].get("pc"), g.game.tick - t_mined)
        if t_mined is not None and (len(got_) == 2 or g.game.tick - t_mined > 30):
            break
    send({"t": "mine_stop"})
    keep(1)
    pe[flag] = (t_mined is not None, got_.get(run_[1].unit_number), got_.get(run_[3].unit_number))
    for p_ in run_:
        if p_.valid:
            p_.destroy()
    keep(2)
    drain()
# The owner's second picture: a T whose branch was mined stayed a T, its open mouth showing. A T, a cross and a
# corner each lose one arm (the north one) to the character's mining: the pipe in the middle is sent again without it.
pe_shape = {}
for name_, cx_, arms_, want_ in (("T", kx + 10.5, ((1, 0), (-1, 0)), 10), ("cross", kx + 14.5, ((1, 0), (-1, 0), (0, 1)), 14),
                                 ("corner", kx + 18.5, ((1, 0),), 2)):
    cy_ = ky + 20.5
    mid_ = spawn("pipe", cx_, cy_, force="player")
    F["raise"]("script_raised_built", lua.table_from({"entity": mid_}))
    others_ = []
    for ax_, ay_ in arms_ + ((0, -1),):
        p_ = spawn("pipe", cx_ + ax_, cy_ + ay_, force="player")
        F["raise"]("script_raised_built", lua.table_from({"entity": p_}))
        others_.append(p_)
    north_ = others_[-1]
    keep(5)
    drain()
    puppet.teleport(lua.table_from({"x": cx_ - 2.0, "y": cy_ - 1.0}))
    mine_ = {"t": "mine", "u": int(north_.unit_number), "p": eid["pipe"], "x": fixed(cx_), "y": fixed(cy_ - 1.0),
             "ox": fixed(2.0), "oy": fixed(0.0)}
    t_mined, got_ = None, None
    for t_ in range(300):
        if t_ % 9 == 0 and north_.valid:
            send(mine_)
        keep(1)
        if t_mined is None and not north_.valid:
            t_mined = g.game.tick
        for m_ in of_type(drain(), "upd"):
            if t_mined is not None and m_["e"][0] == mid_.unit_number:
                got_ = (m_["e"][5].get("pc"), g.game.tick - t_mined)
        if t_mined is not None and (got_ is not None or g.game.tick - t_mined > 30):
            break
    send({"t": "mine_stop"})
    keep(1)
    pe_shape[name_] = (t_mined is not None, want_, got_)
    for p_ in [mid_] + others_:
        if p_.valid:
            p_.destroy()
    keep(2)
    drain()
check(all(v[0] and v[2] is not None and v[2][0] == v[1] and v[2][1] <= 3 for v in pe_shape.values()),
      f"mined_neighbours: a T, a cross and a corner losing their north arm to the character's mining are sent again "
      f"without it the tick after: (mined, want pc, (pc, ticks)) {pe_shape}")
F.commands["f3d-perf"](lua.table_from({"name": "f3d-perf", "parameter": "mined_neighbours default"}))
g.settings["global"]["f3d-act-as-player"]["value"] = True
puppet.teleport(pe_home)
send({"t": "sub", "c": pe_subs})
keep(5)
drain()
check(pe["default"][0] and pe["default"][1] is not None and pe["default"][1][0] == 8 and pe["default"][1][1] <= 3
      and pe["default"][2] is not None and pe["default"][2][0] == 2 and pe["default"][2][1] <= 3
      and pe["off"][0] and pe["off"][1] is None and pe["off"][2] is None,
      f"mined_neighbours: the pipes beside one the character mines with no player are sent again as endings "
      f"(west 8, east 2) the tick after (off: not at all): (mined, (pc, ticks) west, east) {pe}")
bs_k.option_command("built_now off")
keep(13)
check(g.storage.f3d.bs.fresh is None, "K16 built_now off: nothing kept for it")
bs_k.option_command("built_now default")
for e_ in k_line + [k_in]:
    if e_.valid:
        e_.destroy()
send(hello_now)
tick(1)
drain()

# --- E31: lane_next (/f3d-bs, on): every lane's `lm` next as the game's belt connections, sent again when it changes ---
# The client's copy of the belts stops a lane's front items at its end when its next is 0 and no lane follows (the line
# ends there), and holds them at the bridge's reads when it is negative (it leads out of what is sent). Found at the end
# of the owner's bus: lanes said -1 though the belt they feed was sent, and 0 though it wasn't. A belt loading read its
# feeders' lanes again without their meta (the -1 stayed: first loads chain at most 4 rings out, so a line going
# outwards had every fourth ring loaded before its next, and walking did the same at the square's edge each step); a
# belt leaving had its feeders' -1 sent only with the next round's reload; a reload after a catch-up's read in the same
# tick lost its lm (a curve straightened kept its old shape); a splitter's lanes all said -1 when one half's belt
# wasn't loaded. The view below is the client's: each lane's last lm, dropped with its dl, checked after every update.
bs_n = lua.eval('package.loaded["scripts.belt_sim"]')
check("lane_next on" in str(bs_n.option_command("")[1]), "/f3d-bs lists lane_next (on)")
nx0, ny0 = 3500.5, 330.5
ln_view, ln_kind, ln_bad = {}, {}, []
ln_belts, ln_split = [], {}


def ln_links(e):
    links = F.belt_links[e]
    outs = links and links.outputs
    return [outs[i] for i in range(1, len(outs) + 1) if outs[i].valid] if outs else []


def ln_held(u):
    return any(u * 8 + j in ln_view for j in range(1, 9))


def ln_truth():
    """Lanes the client holds whose next isn't the game's: [(key, next, wanted)]."""
    bad = []
    for e in ln_belts:
        if not e.valid:
            continue
        u = int(e.unit_number)
        outs = ln_links(e)
        for i in range(1, int(e.get_max_transport_line_index()) + 1):
            key = u * 8 + i
            if key not in ln_view:
                continue
            explicit, target, leaves = 0, None, True
            if e.type == "underground-belt" and e.belt_to_ground_type == "input":
                if i <= 2:
                    explicit, leaves = key + 2, False
                elif e.underground_belt_neighbour:
                    target = e.underground_belt_neighbour
                    explicit = int(target.unit_number) * 8 + i - 2
            elif e.type == "splitter":
                leaves = i > 4
                target = ln_split.get((u, i))
            else:
                target = outs[0] if outs else None
            want = explicit
            if leaves and target is not None and not ln_held(int(target.unit_number)):
                want = -explicit if explicit else -1
            if ln_view[key] != want:
                bad.append((key, ln_view[key], want))
    return bad


def ln_run(n, label):
    for _ in range(n):
        keep(1)
        msgs = drain()
        done = False
        for m in of_type(msgs, "bs"):
            lm = m.get("lm", [])
            for i in range(0, len(lm), 12):
                ln_view[lm[i]], ln_kind[lm[i]] = lm[i + 11], lm[i + 1]
            for k_ in m.get("dl", []):
                ln_view.pop(k_, None)
            done = done or m.get("part") == m.get("parts")
        if done:
            bad = ln_truth()
            if bad:
                ln_bad.append((label, g.game.tick, bad))


def ln_add(e):
    ln_belts.append(e)
    F["raise"]("script_raised_built", lua.table_from({"entity": e}))
    return e


def ln_world():
    """A line east across the square's edge (dx 10-21, the square 16), an underground pair across it (dx 14 to 18),
    a line ending inside, a splitter on the edge whose left half's belt is inside and right half's outside."""
    ln_belts.clear()
    ln_split.clear()
    line_ = [ln_add(spawn("transport-belt", nx0 + 10 + k, ny0, force="player", direction=4)) for k in range(12)]
    for a_, b_ in zip(line_, line_[1:]):
        F.link_belts(a_, b_)
    ui_ = ln_add(spawn("underground-belt", nx0 + 14, ny0 + 3, force="player", direction=4, type="input"))
    uo_ = ln_add(spawn("underground-belt", nx0 + 18, ny0 + 3, force="player", direction=4, type="output"))
    F.pair_undergrounds(ui_, uo_)
    ua_ = ln_add(spawn("transport-belt", nx0 + 19, ny0 + 3, force="player", direction=4))
    F.link_belts(uo_, ua_)
    end_ = [ln_add(spawn("transport-belt", nx0 + k, ny0 - 4, force="player", direction=4)) for k in range(3)]
    for a_, b_ in zip(end_, end_[1:]):
        F.link_belts(a_, b_)
    sp_ = ln_add(spawn("splitter", nx0 + 15.5, ny0 + 6, force="player", direction=0, lines=8))
    left_ = ln_add(spawn("transport-belt", nx0 + 15, ny0 + 5, force="player", direction=0))
    right_ = ln_add(spawn("transport-belt", nx0 + 16, ny0 + 5, force="player", direction=0))
    feed_ = ln_add(spawn("transport-belt", nx0 + 15, ny0 + 7, force="player", direction=0))
    F.link_belts(feed_, sp_)
    F.link_belts(sp_, left_)
    F.link_belts(sp_, right_)
    for i in (5, 6, 7, 8):
        ln_split[(int(sp_.unit_number), i)] = left_ if i <= 6 else right_
    return line_, ui_, uo_, end_, sp_


def ln_scenario():
    """Loads, grows, shrinks and walks the square over ln_world(); returns {step: lanes otherwise after it}."""
    ln_view.clear()
    ln_bad.clear()
    send(ts_hello)
    send({"t": "focus", "x": fixed(nx0), "y": fixed(ny0), "r": 48})
    send({"t": "bfar", "r": 0, "n": 16, "m": 0})
    line_, ui_, uo_, end_, sp_ = ln_world()
    out = {}
    ln_run(40, "load")
    out["load"] = ln_truth()
    out["split"] = [ln_view.get(int(sp_.unit_number) * 8 + i) for i in range(5, 9)]
    send({"t": "bfar", "r": 0, "n": 20, "m": 0})
    ln_run(40, "grown")
    out["grown"] = ln_truth()
    out["pair"] = ln_view.get(int(ui_.unit_number) * 8 + 3)
    send({"t": "bfar", "r": 0, "n": 16, "m": 0})
    ln_run(40, "shrunk")
    out["shrunk"] = ln_truth()
    for k_ in list(range(1, 9)) + list(range(7, -1, -1)):
        send({"t": "focus", "x": fixed(nx0 + k_), "y": fixed(ny0), "r": 48})
        ln_run(12, "walk")
    ln_run(40, "walked")
    out["walked"] = ln_truth()
    # Built: a belt inside fed nothing, then one outside it feeds (it leads out), then that one removed (0 again).
    e1_ = ln_add(spawn("transport-belt", nx0 + 15, ny0 + 8, force="player", direction=4))
    ln_run(20, "built")
    e2_ = spawn("transport-belt", nx0 + 16, ny0 + 8, force="player", direction=4)
    F.link_belts(e1_, e2_)
    ln_add(e2_)
    ln_run(20, "built")
    out["built_out"] = (ln_truth(), ln_view.get(int(e1_.unit_number) * 8 + 1))
    F["raise"]("script_raised_destroy", lua.table_from({"entity": e2_}))
    e2_.destroy()
    ln_run(20, "removed")
    out["removed"] = (ln_truth(), ln_view.get(int(e1_.unit_number) * 8 + 1))
    # A curve straightened by a belt built behind it: the new belt's catch-up reads it on the tick its reload sends
    # its new meta.
    cv_ = ln_add(spawn("transport-belt", nx0 + 5, ny0 + 10, force="player", direction=4))
    lua.eval("function(e) F.datas[e].belt_shape = 'left' end")(cv_)
    F["raise"]("script_raised_built", lua.table_from({"entity": cv_}))
    ln_run(30, "curve")
    F.put_on_belt(cv_, 1, "iron-plate", 0.5, 9901)
    ln_run(30, "curve")
    ln_kind.pop(int(cv_.unit_number) * 8 + 1, None)
    bh_ = spawn("transport-belt", nx0 + 4, ny0 + 10, force="player", direction=4)
    F.link_belts(bh_, cv_)
    lua.eval("function(e) F.datas[e].belt_shape = 'straight' end")(cv_)
    ln_add(bh_)
    ln_run(30, "curve")
    out["straightened"] = ln_kind.get(int(cv_.unit_number) * 8 + 1)
    out["updates"] = list(ln_bad)
    for e_ in ln_belts:
        if e_.valid:
            e_.destroy()
    send({"t": "bfar", "r": 0, "n": 24, "m": 0})
    ln_run(30, "cleared")
    return out


fix0 = int(bs_n.counts["next_fix"] or 0)
ln_off = None
for flag in ("off", "default"):
    bs_n.option_command("lane_next " + flag)
    got_n = ln_scenario()
    if flag == "off":
        ln_off = got_n
check(ln_off["load"] and ln_off["grown"] and ln_off["straightened"] is None and ln_off["split"] == [-1, -1, -1, -1],
      f"lane_next off, as before: lanes kept -1 once their next loaded, the curve kept its meta, every splitter lane -1: "
      f"{ln_off['load']} {ln_off['grown']} {ln_off['straightened']} {ln_off['split']}")
check(not got_n["load"] and not got_n["grown"] and not got_n["shrunk"] and not got_n["walked"],
      f"lane_next: every lane's next as the game's connections after the first load, the square grown (its next loaded), "
      f"shrunk (its next gone) and walked over: {[(k_, got_n[k_]) for k_ in ('load', 'grown', 'shrunk', 'walked')]}")
check(not got_n["updates"], f"lane_next: ... at the end of every update, a lane's new next in the update its next came or "
      f"left in: {got_n['updates'][:3]}")
check(got_n["split"] == [0, 0, -1, -1], f"lane_next: a splitter's lanes each by their half's belt: {got_n['split']}")
check(got_n["pair"] is not None and got_n["pair"] > 0,
      f"lane_next: an entrance's hidden lines go on into its exit once it loads (minus its key before): {got_n['pair']}")
check(not got_n["built_out"][0] and got_n["built_out"][1] == -1 and not got_n["removed"][0] and got_n["removed"][1] == 0,
      f"lane_next: a belt built outside the square, fed from inside, makes its feeder lead out; removed, the feeder's "
      f"line ends there (0): {got_n['built_out']} {got_n['removed']}")
check(got_n["straightened"] == 1, f"lane_next: a curve straightened by a belt built behind it is sent again as straight "
      f"(kind 1), the reload's lm no longer lost to the catch-up's read that tick: {got_n['straightened']}")
check(int(bs_n.counts["next_fix"] or 0) == fix0,
      f"lane_next: no lane found told otherwise by the looks (every change sent where it happened): "
      f"{int(bs_n.counts['next_fix'] or 0) - fix0}")
# Multiplayer: what each lane's next was told (storage) goes the same on a peer without the round's payload (one that
# loaded the save mid-round sends nothing of it): the line across the edge, its next loaded with the payload forgotten.
ln_told = lua.eval("""function()
  local b = storage.f3d.bs
  local bad, n = 0, 0
  for key, lr in pairs(b.lanes) do
    local unit, i = math.floor((key - 1) / 8), (key - 1) % 8 + 1
    local r = b.belts[unit]
    local u = r and r[15] and r[15][i]
    if u ~= nil then
      n = n + 1
      if lr[16] ~= (u ~= 0 and b.belts[u] == nil) then
        bad = bad + 1
      end
    end
  end
  return bad, n
end""")
send(ts_hello)
send({"t": "focus", "x": fixed(nx0), "y": fixed(ny0), "r": 48})
send({"t": "bfar", "r": 0, "n": 16, "m": 0})
peer_line = ln_world()[0]
ln_run(40, "peer")
ln_view.clear()
bs_n.load_cap = 20  # (a belt or so a tick: the loads go on over the round's ticks, each without its payload)
send({"t": "bfar", "r": 0, "n": 20, "m": 0})
keep(1)
for _ in range(11):
    check(forget(bs_n.tick, "pays"), "the belt simulation's payloads can be forgotten (a peer that loaded mid-round)")
    keep(1)
ln_run(1, "peer")
bs_n.load_cap = None
told_bad, told_n = ln_told()
ln_loaded = lua.eval("function(u) return storage.f3d.bs.belts[u] ~= nil end")
unsent = [e_ for e_ in peer_line[6:10] if ln_loaded(int(e_.unit_number)) and not ln_held(int(e_.unit_number))]
check(unsent and told_n > 20 and told_bad == 0,
      f"lane_next: each lane's next as told, in storage, follows the belts loading without the payload too "
      f"({len(unsent)} belts loaded unsent): {told_bad} of {told_n} otherwise")
for e_ in ln_belts:
    if e_.valid:
        e_.destroy()
bs_n.option_command("lane_next default")
# --- ins_driven (/f3d-bs, off): an inserter's belts read when its hand takes or puts, not looked at every update -------
# The owner's idea: a belt watched for its inserters alone (a pickup belt, the belt behind it, a drop belt) needs a read
# only when a hand took or put there, which the inserter's own check (every update, its hand's count) shows. A drill's
# drop belt stays watched (drills tell nothing), and off is as before.
bs_i = lua.eval('package.loaded["scripts.belt_sim"]')
check("ins_driven off" in str(bs_i.option_command("")[1]), "/f3d-bs lists ins_driven (off)")
ix, iy = 2700.5, 330.5
i_line = [spawn("transport-belt", ix + i, iy, force="player", direction=4) for i in range(4)]
for a_, b_ in zip(i_line, i_line[1:]):
    F.link_belts(a_, b_)
i_take = spawn("inserter", ix + 2, iy + 1, force="player")
i_take.pickup_target = i_line[2]  # i_line[2] its pickup belt, i_line[1] the belt behind it
i_put_belt = spawn("transport-belt", ix, iy + 4, force="player", direction=4)
i_put = spawn("inserter", ix, iy + 3, force="player")
i_put.drop_target = i_put_belt
F.set_hand(i_put, ix, iy + 3, "iron-plate")
i_drill_belt = spawn("transport-belt", ix + 4, iy + 6, force="player", direction=4)
i_drill = spawn("burner-mining-drill", ix + 2.5, iy + 6.5, force="player")
i_drill.drop_target = i_drill_belt
for e_ in i_line + [i_take, i_put_belt, i_put, i_drill_belt, i_drill]:
    F["raise"]("script_raised_built", lua.table_from({"entity": e_}))
i_hello = dict(ts_hello)


def i_keep(n):
    for _ in range(n):
        if g.game.tick % 100 == 0:
            send(i_hello)
        tick(1)


send(i_hello)
send({"t": "focus", "x": fixed(ix), "y": fixed(iy + 2), "r": 48})
send({"t": "bfar", "r": 0, "n": 24, "m": 0})
i_keep(120)
drain()
i_rec = lua.eval("function(u, k) local b = storage.f3d.bs; local r = b and b.belts[u]; return r and r[k] or false end")
u_pick, u_behind, u_put, u_drill = (int(e_.unit_number) for e_ in (i_line[2], i_line[1], i_put_belt, i_drill_belt))
check(all(i_rec(u_, 4) for u_ in (u_pick, u_behind, u_put, u_drill)),
      "ins_driven: the pickup belt, the belt behind it, the drop belt and the drill's belt are watched")
check(i_rec(u_pick, 16) and i_rec(u_behind, 16) and i_rec(u_put, 16) and not i_rec(u_drill, 16),
      "ins_driven: those an inserter uses are watched for inserters alone, the drill's belt not")


def i_sent_after(keys, n):
    """Ticks until a `sl` of one of `keys` comes, at most n: (ticks or None, the read's tick)."""
    t0 = g.game.tick
    for _ in range(n):
        i_keep(1)
        got = bs_of(drain())["sl"]
        for k_ in keys:
            if k_ in got:
                return g.game.tick - t0, got[k_][0]
    return None, None


# Off, as before: an item coming onto the pickup belt with no hand moving is read at the lane's next look (a lane that
# stood is looked at every spot_quiet_ticks, 60, then in the next update).
I_LOOK = 60 + 13
F.put_on_belt(i_line[2], 1, "iron-plate", 0.5, 8901)
off_seen = i_sent_after([u_pick * 8 + 1], I_LOOK)
check(off_seen[0] is not None, f"ins_driven off: a pickup belt's change is read at its next look, as before: {off_seen}")
watch_off = [int(u_) for u_ in to_py(bs_i.watch_list()) or []]
check(u_pick in watch_off and u_drill in watch_off, "ins_driven off: the pickup belt and the drill's belt in the watch list")
# On: the pickup belt and the belt behind it out of the watch list, the drill's belt in it.
bs_i.option_command("ins_driven on")
i_keep(13)
drain()
watch_on = [int(u_) for u_ in to_py(bs_i.watch_list()) or []]
check(u_pick not in watch_on and u_behind not in watch_on and u_put not in watch_on and u_drill in watch_on,
      f"ins_driven on: the belts watched for inserters alone leave the watch list, the drill's belt stays: "
      f"{[u_ in watch_on for u_ in (u_pick, u_behind, u_put, u_drill)]}")
# An item coming onto the pickup belt with no hand moving: not read, past the look it would have had (the client
# simulates it) ...
F.put_on_belt(i_line[2], 2, "copper-plate", 0.5, 8902)
before_pick = i_sent_after([u_pick * 8 + 1, u_pick * 8 + 2], I_LOOK)
check(before_pick[0] is None, f"ins_driven on: a pickup belt isn't read while no hand takes there: {before_pick}")
# ... until the hand takes one: then the pickup belt and the belt behind it are read in the next update, on a tick
# at or after the take.
F.move_on_belt(i_line[2], 2, 8902, None)
F.set_hand(i_take, ix + 2, iy + 0.5, "copper-plate")
t_take = g.game.tick
t0_ = g.game.tick
got_pick, got_behind = None, None
for _ in range(20):
    i_keep(1)
    sl_ = bs_of(drain())["sl"]
    if got_pick is None and u_pick * 8 + 2 in sl_:
        got_pick = (g.game.tick - t0_, sl_[u_pick * 8 + 2][0] - t_take, len(sl_[u_pick * 8 + 2][1]))
    if got_behind is None and (u_behind * 8 + 1 in sl_ or u_behind * 8 + 2 in sl_):
        got_behind = g.game.tick - t0_
    if got_pick and got_behind:
        break
check(got_pick is not None and got_pick[0] <= 13 and got_pick[1] >= 0 and got_pick[2] == 0 and got_behind is not None,
      f"ins_driven on: a take reads the pickup belt (its lane empty now) and the belt behind it in the next update: "
      f"(ticks, read after the take, items) {got_pick}, the belt behind {got_behind}")
check(int(bs_i.counts.ins_takes or 0) >= 1, "ins_driven on: the take counted")
# After the take the pickup belt is watched as before for its window (ins_window updates, or until it settles): the
# items behind closing up the hole are read as they come ...
F.put_on_belt(i_line[2], 2, "copper-plate", 0.75, 8907)
closing = i_sent_after([u_pick * 8 + 2], 13)
check(closing[0] is not None, f"ins_driven on: a pickup belt is read as it changes in the window after a take: {closing}")
# ... and once the window is over, not any more.
i_keep(6 * int(bs_i.OPTIONS.ins_window) + 13)
drain()
F.put_on_belt(i_line[2], 2, "copper-plate", 0.25, 8908)
after_win = i_sent_after([u_pick * 8 + 2], I_LOOK)
check(after_win[0] is None, f"ins_driven on: and not after its window: {after_win}")
# A put on the drop belt: read in the next update (a client without `ho` isn't told the item itself).
F.set_hand(i_put, ix, iy + 3.5, None)
F.put_on_belt(i_put_belt, 1, "iron-plate", 0.5, 8903)
put_seen = i_sent_after([u_put * 8 + 1], 20)
check(put_seen[0] is not None and put_seen[0] <= 13, f"ins_driven on: a put reads the drop belt in the next update: {put_seen}")
# ins_ho (on): a client taking `ie` and `ho` is told the item itself (PLACED), so the put isn't read.
# (After the window the last put watched the drop belt for: ins_window updates, or until it settled.)
i_hello = dict(ts_hello, ie=1, ho=1)
send(i_hello)
F.set_hand(i_put, ix, iy + 3, "iron-plate")
i_keep(6 * int(bs_i.OPTIONS.ins_window) + 13)
drain()
told0 = int(bs_i.counts.ins_told or 0)
F.set_hand(i_put, ix, iy + 3.5, None)
F.put_on_belt(i_put_belt, 1, "iron-plate", 0.25, 8904)
put_told = i_sent_after([u_put * 8 + 1], 20)
check(put_told[0] is None and int(bs_i.counts.ins_told or 0) == told0 + 1,
      f"ins_ho: a put for a client told the item itself (ie, ho) isn't read: {put_told}, told {int(bs_i.counts.ins_told or 0) - told0}")
i_hello = dict(ts_hello)
send(i_hello)
# The drill's belt stays watched: an item coming onto it (no progress gone round) is read in the next update.
F.put_on_belt(i_drill_belt, 1, "iron-ore", 0.5, 8905)
drill_seen = i_sent_after([u_drill * 8 + 1], I_LOOK)
check(drill_seen[0] is not None,
      f"ins_driven on: a drill's belt is still watched (a change read at its next look): {drill_seen}")
# Off again: the pickup belt is back in the watch list, its change read in the next update.
bs_i.option_command("ins_driven default")
i_keep(7)
drain()
F.put_on_belt(i_line[2], 1, "iron-plate", 0.25, 8906)
back_seen = i_sent_after([u_pick * 8 + 1], I_LOOK)
check(u_pick in [int(u_) for u_ in to_py(bs_i.watch_list()) or []] and back_seen[0] is not None,
      f"ins_driven default: back as before, the pickup belt watched again: {back_seen}")
for e_ in i_line + [i_take, i_put_belt, i_put, i_drill_belt, i_drill]:
    if e_.valid:
        e_.destroy()
send(hello_now)
tick(1)
drain()

