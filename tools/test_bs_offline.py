#!/usr/bin/env python3
"""tools/bs_offline.py on a made-up recording: three belts in a row heading east, items moving along
them for 60 ticks, a world worked out from the recording alone. Checks that the bridge's first load
sends every lane (lm) with the recording's items (sl: ids, positions) read on the tick it names, and
that the harness's world gives the lanes the recorded geometry and links.

    python tools/test_bs_offline.py
"""

import json
import pathlib
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import bs_offline  # noqa: E402

failures = []


def check(cond, what):
    if not cond:
        failures.append(what)
        print("FAIL:", what)


def made_up():
    # Belts at x 0.5, 1.5, 2.5 (y 0.5) heading east: a line's position 0 is its exit (east) edge.
    lanes = []
    for b in range(3):
        x0 = b * 256
        for i, dy in ((1, -60), (2, 60)):
            lanes.append([1000 + b, "transport-belt", "transport-belt", "straight", 4, i, 256,
                          [x0 + 256, 128 + dy], [x0 + 128, 128 + dy], [x0 + 1, 128 + dy], 8, 1, {}])
    ticks = []
    for t in range(60):
        row = [5000 + t]
        # Item 7 on belt 1000's line 1 moving 8/256 a tick (it starts at the back, 248).
        pos = 248 - 8 * t
        if pos >= 0:
            row += [1, 7, pos, 1, 1]
        # Item 9 standing on belt 1002's line 2.
        row += [6, 9, 64, 2, 2]
        ticks.append(row)
    return {"lanes": lanes, "names": ["iron-plate", "copper-plate"], "ticks": ticks}


def main():
    rec = made_up()
    world = bs_offline.world_from_truth(rec)
    links = {b["u"]: (b["i"], b["o"]) for b in world["belts"]}
    check(links[1000][1] == [1001] and links[1001] == ([1000], [1002]) and links[1002][0] == [1001],
          "the world from the recording links each belt to the next one east: %s" % links)
    with tempfile.TemporaryDirectory() as d:
        truth = pathlib.Path(d) / "truth.json"
        truth.write_text(json.dumps(rec))
        out = pathlib.Path(d) / "stream.jsonl"
        summary, ups = bs_offline.main(["--mod", str(ROOT / "mod" / "factorio-3d-bridge"), "--truth", str(truth), "--out", str(out),
                                        "--focus", "1.5,0.5", "--radius", "16", "--cap", "6000", "--quiet"])
        msgs = [json.loads(l) for l in out.read_text().splitlines() if l.strip()]
    check(msgs and all(m["t"] == "bs" for m in msgs), "the stream holds bs messages only")
    lm, sl = {}, {}
    for m in msgs:
        a = m.get("lm", [])
        for i in range(0, len(a), 12):
            lm[a[i]] = a[i + 1:i + 12]
        a, i = m.get("sl", []), 0
        while i < len(a):
            n = a[i + 2]
            sl.setdefault(a[i], []).append((a[i + 1], [a[i + 3 + 4 * j:i + 7 + 4 * j] for j in range(n)]))
            i += 3 + 4 * n
    keys = {u * 8 + i for u in (1000, 1001, 1002) for i in (1, 2)}
    check(keys <= set(lm) and keys <= set(sl), "every lane is loaded: lm %s, sl %s" % (sorted(lm), sorted(sl)))
    meta = lm.get(1000 * 8 + 1, [])
    check(meta[:3] == [1, 256, 8] and meta[3:9] == [256, 68, 128, 68, 1, 68],
          "a lane's meta is the recording's: kind, length, speed, its three points: %s" % meta)
    first = sl.get(1000 * 8 + 1, [(None, [])])[0]
    t_read, items = first
    check(items and items[0][0] == 7 and items[0][2] == 248 - 8 * (t_read - 5000) and items[0][1] > 0,
          "items are the recording's on the tick the bridge read them: %s" % (first,))
    stood = sl.get(1002 * 8 + 2, [(None, [])])[0][1]
    check(stood and stood[0][0] == 9 and stood[0][2] == 64 and stood[0][3] == 2, "stack sizes come through: %s" % stood)
    check(summary["updates"] > 0 and summary["ticks"] == 60, "the summary counts the ticks and updates: %s" % summary)
    if failures:
        print("%d check(s) failed" % len(failures))
        sys.exit(1)
    print("all bs_offline checks passed")


if __name__ == "__main__":
    main()
