#!/usr/bin/env python3
"""tools/belt_view_check.py's report on a tiny made-up recording: three lanes in a row (A feeds B feeds C),
the client simulating B and C only; two lanes on their own (D, E) for items kept lane by lane; and the
run's pace read from a made-up capture, status and settings file; the join on the first `bs` line, the
lock, the pinned camera's ground, the lane map, record.py's --sample."""

import pathlib
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import belt_view_check as bvc  # noqa: E402


def lane(unit, x0, x1, y=0):
    # [unit, name, type, shape, dir, line, length, exit p0, middle, entry p1, ...]: items move west
    return [unit, "transport-belt", "transport-belt", "straight", 12, 1, 256, [x0, y], [(x0 + x1) // 2, y], [x1, y], 8, 1, {}]


TRUTH = {"lanes": [lane(1, 512, 768), lane(2, 256, 511), lane(3, 0, 255)]}
A, B, C = 9, 17, 25  # keys: unit * 8 + line
TRUTH2 = {"lanes": [lane(4, 0, 255, 1024), lane(5, 0, 255, 2048)]}
D, E = 33, 41


def view(tick, game, sim, lanes=(B, C)):
    return {"tick": tick, "lanes": list(lanes), "game": game, "sim": sim}


def check(cond, what):
    print(("ok   " if cond else "FAIL ") + what)
    return cond


def main():
    ok = True
    lanes = bvc.lane_meta(TRUTH)
    feeders = bvc.feeders_of(lanes)
    ok &= check(feeders[B] == [A] and feeders[C] == [B] and feeders[A] == [], "feeders follow exit to entry")
    ok &= check(bvc.depth(B, feeders, {B, C}) == 0 and bvc.depth(C, feeders, {B, C}) == 1, "depth back to an unsimulated feeder")
    ok &= check(bvc.depth(C, feeders, {A, B, C}) == 99, "no outside feeder")
    # Game: one item on each lane. Simulation: B's item 0.1 tile off (right), C's on lane B (other lane).
    game = {"1": [A, 100], "2": [B, 100], "3": [C, 100]}
    sim = {"2": [B, 120], "3": [B, 200], "4": [C, 50]}
    v = view(10, game, sim)
    c = bvc.by_id(v, lanes)
    ok &= check(c["right"] == 1 and c["other lane"] == 1 and c["missing"] == 0, "by id: right, other lane")
    ok &= check(c["simulated, not in the game"] == 1, "a simulated item the game hasn't")
    h = bvc.headline(v)
    ok &= check(h == [3, 1, 1, 1, 0], "headline: 3 game items, 1 by place, 1 on a lane not simulated, 1 by id (%s)" % h)
    rep = bvc.analyze(TRUTH, [v, view(20, game, sim)], {"drawn": {"other lane": 2, "stood v0": 3}, "dc": [4, 1, 1]}, (0.0, 0.0))
    ok &= check(rep["coverage"]["total"] == [3, 2], "coverage 2 of 3 lanes")
    ok &= check(not rep["pass"] and rep["drawn_other_lane"] == 2 and rep["drawn_standing_while_moving"] == 3, "FAIL with drawn kinds")
    ok &= check(any(r.startswith("drawn on another lane (records vs simulation, every tick): 2 item-frames") for r in rep["reasons"]),
                "drawn on another lane is its own gate, labelled records vs simulation")
    ok &= check(not any(r.startswith("by id") for r in rep["reasons"]) and bvc.by_id_pct(rep["by_id"]["last"], "other lane") == 50.0,
                "by id, other lane is a diagnostic, not a gate")
    rep_u = bvc.analyze(TRUTH, [v, view(20, game, sim)], {"drawn": {"other lane": 2}, "dc": [4, 1, 1]}, (0.0, 0.0), every_tick=False)
    ok &= check(not any(r.startswith("drawn on another lane") for r in rep_u["reasons"]),
                "a job an update (--replay update): drawn kinds not gated")
    good = view(10, game, {"1": [A, 100], "2": [B, 100], "3": [C, 110]}, lanes=(A, B, C))
    rep = bvc.analyze(TRUTH, [good], {"drawn": {}, "dc": [3, 0, 0]}, (0.0, 0.0))
    ok &= check(rep["pass"] and rep["headline_id_pct"] == 100.0, "PASS when everything is simulated and in place")
    ok &= check("6. PASS" in bvc.format_report(rep), "the report says PASS")

    # A packed lane with its items' ids swapped: right by place, wrong by id.
    packed = {"5": [A, 0], "6": [A, 64], "7": [B, 0], "8": [B, 64], "9": [C, 0], "10": [C, 64]}
    swapped = {"5": [A, 64], "6": [A, 0], "7": [B, 64], "8": [B, 0], "9": [C, 64], "10": [C, 0]}
    sw = view(10, packed, swapped, lanes=(A, B, C))
    h = bvc.headline(sw)
    ok &= check(h == [6, 6, 0, 0, 6], "packed, ids swapped: 6 by place, 0 by id, 6 by place only (%s)" % h)
    rep = bvc.analyze(TRUTH, [sw], {"drawn": {}, "dc": [6, 0, 0]}, (0.0, 0.0))
    ok &= check(rep["pass"] and rep["headline_place_pct"] == 100.0 and rep["headline_id_pct"] == 0.0 and rep["visible_pct"] == 100.0,
                "PASS although 0% by id: ids swapped on a packed lane of one kind look the same")
    # Visible: missing items, one of 50 a lane (2%) ...
    many = {str(100 + i): [B, 100 * i] for i in range(50)}
    for gone, fails in ((1, False), (2, True)):
        s = {u: e for u, e in many.items() if int(u) >= 100 + gone}
        rep = bvc.analyze(TRUTH, [view(10, many, s, lanes=(A, B, C))] * 2, {"drawn": {}, "dc": [50, 0, 0]}, (0.0, 0.0))
        ok &= check(any(r.startswith("visible") for r in rep["reasons"]) == fails and rep["visible"].get("holes", 0) == 2 * (gone >= 2),
                    "visible, %d of 50 missing %s (holes %d)" % (gone, "fails" if fails else "passes", rep["visible"].get("holes", 0)))

    # Visible, by item: the same lane and kind within 0.15 tile matches; the right lane with another
    # item there is a miss (and the simulated one a phantom); another lane is a miss; one to one.
    names = ["iron-plate", "copper-plate"]
    shows = bvc.visible_lanes(TRUTH)
    g = {"1": [B, 100, 1], "2": [B, 300, 1], "3": [C, 100, 1]}
    sm = {"11": [B, 120, "iron-plate"], "12": [B, 300, "copper-plate"], "13": [B, 100, "iron-plate"]}
    c = bvc.visible(view(10, g, sm, lanes=(A, B, C)), shows, names)
    ok &= check(c["game"] == 3 and c["seen"] == 1 and c["wrong kind"] == 1 and c["sim"] == 3 and c["phantoms"] == 2,
                "visible: same lane same kind seen; another kind on the right lane missed; one to one (%s)" % dict(c))
    # One to one: two game items 0.1 tile apart, one simulated item between them: one seen, one missed.
    c = bvc.visible(view(10, {"1": [B, 100, 1], "2": [B, 126, 1]}, {"9": [B, 113, "iron-plate"]}, lanes=(B,)), shows, names)
    ok &= check(c["seen"] == 1 and c["phantoms"] == 0 and c["holes"] == 0, "visible: one simulated item covers one game item (%s)" % dict(c))
    # Matching takes the most: game 100, 170; simulated 135 (in reach of both), 205 (of 170 only).
    c = bvc.visible(view(10, {"1": [B, 100, 1], "2": [B, 170, 1]}, {"8": [B, 135, -1], "9": [B, 205, -1]}, lanes=(B,)), shows, names)
    ok &= check(c["seen"] == 2, "visible: the most matches (%s)" % dict(c))
    # The bridge's ids learned from the items both have; minus an index is the recording's.
    vv = [view(10, {"1": [B, 100, 2], "2": [B, 200, 1]}, {"1": [B, 100, 141], "2": [B, 200, 143], "5": [B, 300, -2]})]
    kinds = bvc.kind_map(vv, names)
    ok &= check(kinds == {141: "copper-plate", 143: "iron-plate"} and bvc.item_name([B, 0, -2], names, kinds) == "copper-plate"
                and bvc.item_name([B, 0, 999], names, kinds) == "?999", "kind map: the bridge's ids by the items both have (%s)" % kinds)
    # An underground entrance's hidden lines (3-4) don't show: their items aren't counted.
    ug = {"lanes": [lane(1, 512, 768), [7, "underground-belt", "underground-belt", "input", 12, 3, 128, [0, 0], [64, 0], [128, 0], 8, 1, {}]]}
    sh = bvc.visible_lanes(ug)
    c = bvc.visible(view(10, {"1": [7 * 8 + 3, 10, 1], "2": [A, 10, 1]}, {}, lanes=(A, 7 * 8 + 3)), sh, names)
    ok &= check(sh == {A} and c["game"] == 1, "visible: an underground's hidden lane doesn't show")
    # Phantoms: simulated items the game hasn't (3 of 50 = 6% fails).
    s = dict(many)
    s.update({str(900 + i): [C, 100 * i] for i in range(3)})
    rep = bvc.analyze(TRUTH, [view(10, many, s, lanes=(A, B, C))], {"drawn": {}, "dc": [50, 0, 0]}, (0.0, 0.0))
    ok &= check(any(r.startswith("phantoms 5.7%") for r in rep["reasons"]) and rep["visible_pct"] == 100.0,
                "phantoms gate (%s)" % rep["reasons"])
    ok &= check("0. Visible" in bvc.format_report(rep), "the report leads with what is visible")
    # By id on packed lanes is reported only, unless --gate-by-id on: a packed lane of one kind looks the
    # same whichever of its items is where.
    live = {"counts": {"game": 100, "seen": 99, "drawn": 100, "phantoms": 1, "packed": 50, "packed right": 20},
            "visible_pct": 99.0, "phantom_pct": 1.0, "strict_pct": 40.0}
    good = view(10, many, dict(many), lanes=(A, B, C))
    rep = bvc.analyze(TRUTH, [good], {"drawn": {}, "dc": [50, 0, 0]}, (0.0, 0.0), live=live)
    ok &= check(not any("by id on packed" in r for r in rep["reasons"]) and not rep["gate_by_id"],
                "by id on packed lanes isn't a gate by default (%s)" % rep["reasons"])
    rep = bvc.analyze(TRUTH, [good], {"drawn": {}, "dc": [50, 0, 0]}, (0.0, 0.0), live=live, gate_by_id=True)
    ok &= check(any(r.startswith("live by id on packed lanes 40.0%") for r in rep["reasons"]),
                "--gate-by-id on gates it (%s)" % rep["reasons"])

    # Kept lane by lane: D's 30 items doubled on D don't make up for E's 30 gone.
    gd = {str(200 + i): [D, 8 * i] for i in range(30)}
    ge = {str(300 + i): [E, 8 * i] for i in range(30)}
    sd = dict(gd)
    sd.update({str(400 + i): [D, 8 * i + 4] for i in range(30)})
    v2 = view(10, {**gd, **ge}, sd, lanes=(D, E))
    l2 = bvc.lane_meta(TRUTH2)
    rows = bvc.depth_table(v2, l2, bvc.feeders_of(l2))
    r = rows["no outside feeder"]
    ok &= check(r[:3] == [2, 60, 60] and bvc.kept_pct(r) == 50.0, "kept lane by lane: 60 for 60 by count, 50%% kept (%s)" % r)
    rep = bvc.analyze(TRUTH2, [v2], {"drawn": {}, "dc": [60, 0, 0]}, (0.0, 0.0))
    ok &= check(any(x.startswith("deep lanes (4+ back to an unsimulated feeder, or none) keep 50.0%") for x in rep["reasons"]),
                "FAIL on the hole the pile hid (%s)" % rep["reasons"])

    # The run's pace: `ld`, `p`, the rate level, Hold 60 UPS.
    with tempfile.TemporaryDirectory() as td:
        st = pathlib.Path(td) / "stream.jsonl"
        st.write_text('{"t":"bs","k":1,"p":6,"ld":1,"part":1}\n{"t":"bs","k":1,"p":6,"ld":1,"part":2}\n'
                      '{"t":"bs","k":7,"p":6,"part":1}\n{"t":"bs","k":13,"p":48}\n{"t":"bs","k":61,"p":48,"sl":[1,')
        ok &= check(bvc.stream_updates(st) == [(1, 6, True), (7, 6, False), (13, 48, False)], "updates' k, p, ld (a cut-off line skipped)")
        ok &= check(bvc.stream_loading(st) is False, "first load done: the last whole update has no ld")
        ok &= check(bvc.stream_loading(st, tail=60) is False, "the same from the file's tail only")
        ok &= check(bvc.stream_last_k(st) == 13 and bvc.stream_last_k(st, tail=60) == 13
                    and bvc.stream_last_k(pathlib.Path(td) / "none") is None, "the capture's last whole update's k")
        rec = pathlib.Path(td) / "rec.json"
        rec.write_text('{"lanes": [], "ticks": [[5, 1, 2, 3, 4, 1], [11]]}')
        ok &= check(bvc.truth_last_tick(rec) == 11 and bvc.truth_last_tick(pathlib.Path(td) / "none") is None,
                    "the recording's last tick")
        st.write_text('{"t":"bs","k":1,"p":6}\n{"t":"bs","k":7,"p":6,"ld":1}\n')
        ok &= check(bvc.stream_loading(st) is True, "still loading: the last update has ld")
        st.write_text("")
        ok &= check(bvc.stream_loading(st) is None and bvc.stream_loading(pathlib.Path(td) / "none") is None, "no update yet")
        st.write_text('{"t":"bs","k":1,"p":6,"ld":1}\n{"t":"bs","k":7,"p":6}\n{"t":"bs","k":13,"p":48}\n{"t":"bs","k":61,"p":48}\n')
        status = pathlib.Path(td) / "status.txt"
        status.write_text("[Zenith] client on port 1, last seen 3 ticks ago\n[Zenith] character at 0, 0\n"
                          "[Zenith] client on port 1, last seen 9 ticks ago\n[Zenith] slowed down to rate level 3 (the client's `rate`)\n")
        cfg = pathlib.Path(td) / "settings.cfg"
        bvc.settings_file(cfg, "automatic", "off")
        ok &= check("hold_ups=false" in cfg.read_text() and "belt_updates=-1" in cfg.read_text(), "--hold60 off writes hold_ups=false")
        run = bvc.run_info(st, status, cfg, (13, 61))
        ok &= check(run["p_compared"] == {48: 2} and run["p_before"] == {6: 2} and run["ld_last_before"] == 1
                    and run["ld_during"] == 0 and run["rate"] == [0, 3] and run["hold60"] == "off", "run info (%s)" % run)
        rep = bvc.analyze(TRUTH, [good], {"drawn": {}, "dc": [3, 0, 0]}, (0.0, 0.0), run)
        text = bvc.format_report(rep)
        ok &= check("while compared: 48 x2; before: 6 x2" in text and "start and end: 0, 3; Hold 60 UPS: off" in text,
                    "the report's head shows p, the rate level and Hold 60 UPS")
        bvc.settings_file(cfg, "unlimited", "on")
        ok &= check(bvc.hold60_of(cfg.read_text()) == "on" and bvc.hold60_of("[graphics]\n") == "on", "--hold60 on; unset is on")
        bvc.settings_file(cfg, "automatic")
        ok &= check("hold_ups=true" in cfg.read_text(), "Hold 60 UPS on by default")
        run["hold60"] = "on"
        run.update(client="Zenith", server="reused", recorder="updates, 100 rows")
        text = bvc.format_report(bvc.analyze(TRUTH, [good], {"drawn": {}, "dc": [3, 0, 0]}, (0.0, 0.0), run))
        ok &= check("Hold 60 UPS: on (the default)" in text and "server: reused" in text and "updates, 100 rows" in text,
                    "the report says Hold 60 UPS is the default, the server reused, how the recorder sampled")
        # The game's pace, polled: ticks over wall time between the rows, the rate levels seen.
        rows = [{"t": 0.0, "tick": 1000, "rate": 0}, {"t": 2.0, "tick": 1120, "rate": None}, {"t": 4.0, "tick": 1200, "rate": 3},
                {"t": 6.0, "tick": None, "rate": None}, {"t": 8.0, "tick": 1440, "rate": 3}, {"t": 10.0, "tick": 1500, "rate": 2}]
        pace = bvc.pace_of(rows, 0.0, 10.0)
        ok &= check(pace == {"ups": 60.0, "p10": 30.0, "min": 30.0, "n": 4, "levels": [0, 3, 2]}, "polled pace: median, p10, min, levels (%s)" % pace)
        ok &= check(bvc.pace_of(rows, 0.0, 1.0) is None and bvc.pace_text(None) == "unknown", "no pace from one tick")
        run["pace"] = {"settling": bvc.pace_of(rows, 0.0, 4.0), "scored": pace, "settled": bvc.pace_of(rows, 6.0, 10.0)}
        text = bvc.format_report(bvc.analyze(TRUTH, [good], {"drawn": {}, "dc": [3, 0, 0]}, (0.0, 0.0), run))
        ok &= check("game UPS (polled): settling (join, first load, settle) 60.0 median (p10 40.0, min 40.0, 2 readings), rate level 0->3; "
                    "while scored 60.0 median (p10 30.0, min 30.0, 4 readings), rate level 0->3->2; settled, the 20 s before the recording: "
                    "30.0 median (p10 30.0, min 30.0, 1 readings), rate level 3->2" in text, "the report shows the polled pace")

        # Joined: the first `bs` line.
        ok &= check(not bvc.first_bs(pathlib.Path(td) / "none") and bvc.first_bs(st), "joined on the capture's first bs line")
        # The lock: waits for the file (polled), held time counted.
        lk = pathlib.Path(td) / "perf.lock"
        lk.write_text("someone")
        import threading
        threading.Timer(0.3, lk.unlink).start()
        lock = bvc.Lock(str(lk), "me", poll=0.1)
        t = bvc.time.time()
        lock.acquire()
        ok &= check(lock.held and lk.read_text() == "me" and bvc.time.time() - t < 2, "the lock waits for the file, polled")
        lock.release()
        ok &= check(not lk.exists() and lock.held_s >= 0, "the lock released")

    # The pinned camera and the ground its screenshots show.
    cam = bvc.camera_arg("top", 64)
    ok &= check(cam == "0,85,98.46,ortho" and bvc.camera_arg("free", 64) is None and bvc.camera_arg("10,40,20", 64) == "10,40,20",
                "--camera top, free, as given (%s)" % cam)
    (x0, y0, x1, y1), exact = bvc.view_bounds(cam, (10.0, -20.0), 64, (1600, 900))
    ok &= check(exact and abs((y1 - y0) - 64 / bvc.math.sin(bvc.math.radians(85))) < 0.05 and abs((x1 - x0) - 64 * 16 / 9) < 0.05
                and abs((x0 + x1) / 2 - 10) < 1e-6 and abs((y0 + y1) / 2 + 20) < 1e-6, "top: 64 tiles high, 16:9 wide, centred")
    sq, exact = bvc.view_bounds("10,40,20", (0.0, 0.0), 64)
    ok &= check(not exact and sq[1::2] == (-32.0, 32.0) and abs(sq[2] - sq[0] - 64 * 16 / 9) < 1e-6,
                "a perspective camera: the recorded square, widened to the picture's shape (%s)" % (sq,))

    # Lane states at an update and the map.
    lanes = bvc.lane_meta(TRUTH)
    st = bvc.lane_states(view(10, {"1": [A, 100], "2": [B, 100], "3": [C, 100]}, {"2": [B, 100], "3": [B, 50]}), lanes)
    ok &= check(st == {A: "unsimulated", B: "right", C: "other lane"}, "lane states: unsimulated, right, other lane (%s)" % st)
    st = bvc.lane_states(view(10, {"2": [B, 100], "3": [B, 0]}, {"2": [B, 200]}), lanes)
    ok &= check(st[B] == "hole (missing)" and st[C] == "right, empty", "lane states: a hole wins over off; an empty lane")
    with tempfile.TemporaryDirectory() as td:
        png = pathlib.Path(td) / "map.png"
        counts = bvc.lane_map(TRUTH, view(10, {"2": [B, 100]}, {"2": [B, 100]}), (0.0, 0.0), 8, bvc.camera_arg("top", 8), png, (1600, 900))
        if counts is None:
            print("skip the lane map (no Pillow)")
        else:
            from PIL import Image
            with Image.open(png) as im:
                size, mid = im.size, im.getpixel((800 + round(1.5 * 1600 / (8 * 16 / 9)), 450))  # B's middle, 1.5 tiles east
            ok &= check(size == (1600, 900) and counts == {"unsimulated": 1, "right": 1, "right, empty": 1}, "the lane map's size and counts (%s)" % counts)
            ok &= check(mid == bvc.LANE_COLOURS["right"], "lane B drawn right, where it lies (%s)" % (mid,))

    # record.py's --sample.
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "belt_sim"))
    import record  # noqa: E402
    ok &= check([record.parse_sample(v) for v in ("tick", "updates", "6", "6@3", "1")]
                == [("tick", 1, 0), ("updates", 1, 0), ("every", 6, 1), ("every", 6, 3), ("tick", 1, 0)], "record.py --sample")
    lua = record.LUA % dict(x0=0, y0=0, x1=1, y1=1, ticks=10, file="f.json", surface="nauvis", build="local feed = nil",
                            mode="every", every=6, phase=1, sample="6")
    ok &= check("t % every == phase % every" in lua and '"sample":"6"' in lua, "record.py's Lua: every N'th tick, the sample written")
    print("all passed" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
