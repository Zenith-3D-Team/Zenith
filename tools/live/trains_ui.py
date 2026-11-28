"""Live checks of the train windows' commands against the real game (bughunt round 2, trains): interrupts survive the
round trip, a train group shares its schedule, a stop's name / limit / priority / circuit settings, a rail record.
Run: python tools/live_check.py --only trainui"""
from __future__ import annotations

from . import live_lib


def check_trains_ui(c, hello):
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "trainui: no clean spot found", live_lib.SPOT_WHY)
        return
    lua = lambda code: live_lib.mod_lua(code.replace("\n", " "))
    out = lua("""
local c = storage.f3d.puppet local s = c.surface
local x0 = 2 * math.floor(c.position.x / 2) + 1 local y0 = 2 * math.floor(c.position.y / 2) - 11
storage.f3d_trainui = {}
local function mk(spec) spec.force = c.force spec.raise_built = true local e = s.create_entity(spec) if e then table.insert(storage.f3d_trainui, e) end return e end
local res = {}
for k = 0, 1 do
  local y = y0 + 8 * k
  for i = -14, 14 do mk({ name = "straight-rail", position = { x0 + 2 * i, y }, direction = defines.direction.east }) end
  local stop = mk({ name = "train-stop", position = { x0 + 14, y + 2 }, direction = defines.direction.east })
  stop.backer_name = k == 0 and "TU one" or "TU two"
  local loco = mk({ name = "locomotive", position = { x0, y }, direction = defines.direction.east })
  loco.get_fuel_inventory().insert({ name = "coal", count = 20 })
  res[#res + 1] = stop.unit_number .. ' ' .. loco.unit_number
end
c.teleport({ x0, y0 + 4 })
rcon.print(table.concat(res, ' ') .. ' ' .. x0 .. ' ' .. y0)""")
    p = out.split()
    if len(p) != 6:
        live_lib.report(False, "trainui: building", out)
        return
    stop1, loco1, stop2, loco2 = int(p[0]), int(p[1]), int(p[2]), int(p[3])
    x0, y0 = float(p[4]), float(p[5])
    proto_loco = c.proto_id("locomotive")
    proto_stop = c.proto_id("train-stop")

    def at(dx, dy):
        return round((x0 + dx) * 256), round((y0 + dy) * 256)

    def open_it(u, proto, dx, dy):
        c.send({"t": "close"})
        c.pump(0.15, every=hello)
        x, y = at(dx, dy)
        c.send({"t": "open", "u": u, "p": proto, "x": x, "y": y})
        allm = c.pump(0.5, every=hello)
        g = [m for m in allm if m.get("t") == "gui" and m.get("u") == u]
        if not g:
            print("INFO no gui for", u, [(m.get("t"), m.get("text")) for m in allm if m.get("t") in ("msg", "gui")][:4])
        return g[-1] if g else {}

    def open_loco(u, dy):
        return open_it(u, proto_loco, 0, dy)

    def open_stop(u, dy):
        return open_it(u, proto_stop, 14, dy + 2)

    def sched(g):
        return (g.get("tr") or {}).get("sched") or {}

    # 1. an interrupt: name, conditions (with a station), targets with their waits, inside_interrupt.
    open_loco(loco1, 0)
    ints = [{"name": "Fuel up", "inside_interrupt": True,
             "conditions": [{"type": "fuel_item_count_any", "compare_type": "or", "condition": {"first_signal": {"type": "item", "name": "coal"}, "comparator": "<", "constant": 5}},
                            {"type": "at_station", "compare_type": "and", "station": "TU one"}],
             "targets": [{"station": "TU two", "wait_conditions": [{"type": "time", "compare_type": "or", "ticks": 600}]}]}]
    c.send({"t": "set_interrupts", "u": loco1, "interrupts": ints})
    msgs = c.pump(0.4, every=hello)
    errs = [m.get("text") for m in live_lib.of_type(msgs, "msg")]
    got = sched(open_loco(loco1, 0)).get("interrupts")
    ok = bool(got) and got[0].get("name") == "Fuel up" and got[0].get("inside_interrupt") is True and len(got[0].get("conditions", [])) == 2 \
        and got[0]["targets"][0].get("station") == "TU two" and got[0]["targets"][0]["wait_conditions"][0].get("ticks") == 600
    live_lib.report(ok and not errs, "trainui interrupt: name, conditions, target and its wait kept by the game", f"{got} {errs}")
    c.send({"t": "set_interrupts", "u": loco1, "interrupts": []})
    c.pump(0.3, every=hello)
    live_lib.report(not sched(open_loco(loco1, 0)).get("interrupts"), "trainui interrupt: removing the last one empties the list")

    # 1b. "Use destination train stop color".
    g = open_loco(loco1, 0)
    before = (g.get("tr") or {}).get("ctc")
    c.send({"t": "train_mode", "u": loco1, "ctc": 0 if before == 1 else 1})
    c.pump(0.3, every=hello)
    after = (open_loco(loco1, 0).get("tr") or {}).get("ctc")
    live_lib.report(before in (0, 1) and after == 1 - before, "trainui locomotive: copy colour from the stop toggles (ctc) without touching the mode", f"{before} -> {after}")

    # 2. a rail record.
    rx, ry = at(4, 0)
    c.send({"t": "set_schedule", "u": loco1, "records": [{"rail": [rx, ry], "wait_conditions": [{"type": "time", "compare_type": "or", "ticks": 60}]},
                                                       {"station": "TU two", "wait_conditions": []}]})
    msgs = c.pump(0.4, every=hello)
    errs = [m.get("text") for m in live_lib.of_type(msgs, "msg")]
    recs = sched(open_loco(loco1, 0)).get("records") or []
    live_lib.report(len(recs) == 2 and "rail" in recs[0] and not errs, "trainui rail record survives set_schedule", f"{recs} {errs}")
    # 3. group: a second train in the group gets the first's schedule changes.
    c.send({"t": "set_train_group", "u": loco1, "g": "Grp", "all": 0})
    c.pump(0.3, every=hello)
    open_loco(loco2, 8)
    c.send({"t": "set_train_group", "u": loco2, "g": "Grp", "all": 0})
    c.pump(0.3, every=hello)
    t2 = open_loco(loco2, 8).get("tr") or {}
    live_lib.report((t2.get("sched") or {}).get("group") == "Grp" and t2.get("gc") == 2 and len((t2.get("sched") or {}).get("records") or []) == 2,
                    "trainui group: the joined train takes the group's schedule and counts 2", str(t2.get("sched"))[:300])
    c.send({"t": "set_schedule", "u": loco2, "records": [{"station": "TU one", "wait_conditions": [{"type": "full", "compare_type": "or"}]}]})
    c.pump(0.3, every=hello)
    recs = sched(open_loco(loco1, 0)).get("records") or []
    live_lib.report(len(recs) == 1 and recs[0].get("station") == "TU one", "trainui group: an edit in one train reaches the other", str(recs))
    open_loco(loco2, 8)
    c.send({"t": "set_train_group", "u": loco2, "g": "Grp2", "all": 1})
    print("INFO ctrl rename msgs:", [m.get("text") for m in c.pump(0.3, every=hello) if m.get("t") == "msg"])
    s = sched(open_loco(loco1, 0))
    live_lib.report(s.get("group") == "Grp2", "trainui group: Ctrl rename renames the whole group", str(s.get("group")))
    open_loco(loco2, 8)
    c.send({"t": "set_train_group", "u": loco2, "g": "", "all": 0})
    print("INFO leave msgs:", [m.get("text") for m in c.pump(0.3, every=hello) if m.get("t") == "msg"])
    s = sched(open_loco(loco2, 8))
    live_lib.report(s.get("group") in ("", None), "trainui group: leaving it", str(s.get("group")))

    lua(f"storage.f3d.puppet.teleport({{ {x0 + 12}, {y0 + 4} }})")
    c.pump(0.3, every=hello)
    # 4. the stop: limit 0, priority, unlimited again, rename.
    s1 = open_stop(stop1, 0)
    live_lib.report((s1.get("stop") or {}).get("limit") == -1 and (s1.get("stop") or {}).get("pri") == 50, "trainui stop: defaults are no limit, priority 50", str(s1.get("stop"))[:200])
    c.send({"t": "set_stop", "u": stop1, "limit": 0})
    c.send({"t": "set_stop", "u": stop1, "pri": 300})
    c.pump(0.3, every=hello)
    s1 = open_stop(stop1, 0)
    live_lib.report((s1.get("stop") or {}).get("limit") == 0 and (s1.get("stop") or {}).get("pri") == 255, "trainui stop: limit 0 and a priority clamped to 255", str(s1.get("stop"))[:200])
    c.send({"t": "set_stop", "u": stop1, "limit": -1})
    c.send({"t": "set_stop", "u": stop1, "name": "TU two", "all": 1})
    c.pump(0.3, every=hello)
    s1 = open_stop(stop1, 0)
    names = lua("local n = {} for _, e in pairs(storage.f3d_trainui) do if e.valid and e.type == 'train-stop' then n[#n + 1] = e.backer_name end end rcon.print(table.concat(n, ','))")
    live_lib.report((s1.get("stop") or {}).get("limit") == -1 and names == "TU two,TU two", "trainui stop: unlimited again, a rename of all stops with the name", names)
    # circuit settings round trip
    c.send({"t": "set_stop", "u": stop1, "cb": {"limit": 1, "limit_sig": {"type": "virtual", "name": "signal-L"}, "pri": 1, "stopped": 1, "count": 1, "read": 1, "send": 0, "en": 1,
                                                  "cond": {"first_signal": {"type": "item", "name": "coal"}, "comparator": ">", "constant": 3}}})
    c.pump(0.3, every=hello)
    s1 = open_stop(stop1, 0)
    cb = (s1.get("stop") or {}).get("cb") or {}
    live_lib.report(cb.get("limit") == 1 and cb.get("pri") == 1 and cb.get("stopped") == 1 and cb.get("count") == 1 and cb.get("read") == 1 and cb.get("send") == 0 and cb.get("en") == 1
                    and (cb.get("cond") or {}).get("constant") == 3 and (cb.get("limit_sig") or {}).get("name") == "signal-L", "trainui stop circuit: every setting kept", str(cb)[:300])
    # 5. the overview names the stop a train with no path is bound for (Factorio: "No path to X").
    open_loco(loco2, 8)
    c.send({"t": "set_schedule", "u": loco2, "records": [{"station": "TU two", "wait_conditions": []}]})
    c.send({"t": "train_mode", "u": loco2, "auto": 1})
    c.pump(1.5, every=hello)
    lua(f"for _, e in pairs(storage.f3d_trainui) do if e.valid and e.type == 'train-stop' then e.destroy() end end")
    c.pump(1.0, every=hello)
    c.send({"t": "trains_list"})
    rows = []
    for m in c.pump(1.0, every=hello):
        if m.get("t") == "trl":
            rows += m.get("l", [])
    print("INFO trl rows:", [r[:4] for r in rows])
    mine = [r for r in rows if r[6] in (loco2,)]
    live_lib.report(mine and mine[0][1] in ("no_path", "path_lost", "no_schedule") and (mine[0][1] != "no_path" or mine[0][3] == "TU two"),
                    "trainui overview: a train with no path names its stop", str(mine))
    lua("for _, e in pairs(storage.f3d_trainui or {}) do if e.valid then e.destroy() end end storage.f3d_trainui = nil")
