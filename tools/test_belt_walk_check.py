#!/usr/bin/env python3
"""tools/belt_walk_check.py on made-up files: the probe's routes read from its script and their reach, the
lane-age buckets, the bridge's item ids named from a capture and a recording, the character's place between
samples, and a two-sample walk scored from a tiny draw dump (a lane in view from the start is steady, one the
view reaches later is "under 1 s"; a phantom; the bounds from the client's own view)."""

import json
import pathlib
import struct
import sys
import tempfile

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import belt_walk_check as w  # noqa: E402

A, B = 1 * 8 + 1, 2 * 8 + 1


def lane(unit, x0, x1, y=0):
    return [unit, "transport-belt", "transport-belt", "straight", 12, 1, 256, [x0 * 256, y], [(x0 + x1) * 128, y], [x1 * 256, y], 8, 1, {}]


def check(cond, what):
    print(("ok   " if cond else "FAIL ") + what)
    return cond


def write_dump(path, jobs):
    """jobs: [(header dict without ni/ng/paths, [(uid, item, lane, x, z)], [gone uids])]."""
    with open(path, "wb") as f:
        for h, items, gone in jobs:
            h = dict(h, ni=len(items), ng=len(gone), paths=0, base=0.0)
            f.write((json.dumps(h) + "\n").encode())
            if items:
                ids = np.zeros((len(items), w.bvc.ID_INTS), np.int64)
                recs = np.zeros((len(items), w.bvc.REC_FLOATS), np.float32)
                for i, (uid, item, key, x, z) in enumerate(items):
                    ids[i, 0], ids[i, 1], ids[i, 3] = uid, item, key
                    recs[i, 0], recs[i, 2] = x, z  # standing: t1 <= t0, so g = 1 and dx = dz = 0
                f.write(ids.tobytes())
                f.write(recs.tobytes())
            if gone:
                f.write(np.array(gone, np.int64).tobytes())


def main():
    ok = True
    wt = pathlib.Path(__file__).resolve().parent.parent
    routes = w.probe_routes(wt)
    ok &= check("fast" in routes and "stand75" in routes and routes["fast"][0] == [4, 5.0], "the probe's routes read from stutter_probe.gd")
    reach, secs = w.route_reach([[4, 2.0], [8, 1.0], [12, 4.0]], 10.0)
    ok &= check(reach == (-20.0, 0.0, 20.0, 10.0) and secs == 7.0, "a route's reach: east 20, south 10, west 40 at 10 tiles a second")
    ok &= check(w.moving_route(routes["fast"]) and not w.moving_route(routes["stand75"]), "a standing route stands")
    ok &= check([w.age_bucket(t) for t in (0, 59, 60, 179, 180, 599, 600, 100000)] ==
                ["under 1 s", "under 1 s", "1-3 s", "1-3 s", "3-10 s", "3-10 s", "10 s and more", "10 s and more"], "age buckets")
    with tempfile.TemporaryDirectory() as td:
        td = pathlib.Path(td)
        truth = {"sample": "60@1", "lanes": [lane(1, 0, 1), lane(2, 40, 41)], "names": ["iron-plate"],
                 "ticks": [[100, 1, 1, 128, 1, 1], [160, 2, 2, 128, 1, 1]],
                 "pos": [[100, 0, 0], [160, 30 * 256, 0]], "near": [60, 40]}
        stream = td / "stream.jsonl"
        stream.write_text(json.dumps({"t": "bs", "k": 1, "p": 6, "sl": [A, 90, 1, 1, 7, 140, 1]}) + "\n" +
                          json.dumps({"t": "bs", "k": 7, "p": 6}) + "\n")
        kinds = w.kinds_from_stream(stream, truth)
        ok &= check(kinds == {7: "iron-plate"}, "the bridge's item 7 is the recording's iron-plate (by the item both have)")
        where = w.char_at(truth)
        ok &= check(where(100) == (0.0, 0.0) and where(130) == (15.0, 0.0) and where(500) == (30.0, 0.0), "the character's place between samples")
        dump = td / "draw.bin"
        hdr = {"ms": 10.0, "recs": 2, "updates": [1], "data": 100, "skipped": False}
        write_dump(dump, [(dict(hdr, n=0, view=[-20.0, -10.0, 40.0, 20.0]), [(1, 7, A, 0.5, 0.0), (3, 7, A, 5.0, 0.0)], []),
                          (dict(hdr, n=1, view=[10.0, -10.0, 40.0, 20.0], data=160), [(2, 7, B, 40.5, 0.0)], [1, 3])])
        apply = pathlib.Path(str(dump) + ".apply.jsonl")
        apply.write_text("\n".join(json.dumps({"n": n, "usec": u, "drawn": d, "fold": d, "margin": 0.0, "done": u, "dump_ms": 0.1})
                                   for n, u, d in ((0, 1000, 95), (1, 2000, 160))) + "\n")
        rep = w.score_walk(truth, dump, apply, "0,85,92.31,ortho", 60.0, kinds)
        ok &= check(rep is not None and rep["samples"] == 2, "both samples scored")
        c = rep["counts"]
        ok &= check(c["game"] == 2 and c["seen"] == 2 and c["drawn"] == 3 and c["phantoms"] == 1, "2 game items seen, 3 drawn, 1 phantom")
        p0, p1 = rep["per_tick"]
        ok &= check(p0["bounds"] == [-20.0, -10.0, 20.0, 10.0] and p1["bounds"] == [10.0, -10.0, 50.0, 10.0], "the bounds are the client's own view at the job on screen")
        ok &= check(p0["lanes"] == 1 and p0["new"] == 0 and p1["lanes"] == 1 and p1["new"] == 1, "lane A steady from the first sample; lane B new when the view reaches it")
        ok &= check(rep["by_age"]["10 s and more"]["game"] == 1 and rep["by_age"]["under 1 s"]["game"] == 1 and rep["by_age"]["under 1 s"]["seen"] == 1, "items by the lane's age")
        ok &= check(abs(rep["share_new"]["within 1 s"] - 50.0) < 1e-9 and abs(rep["share_new"]["within 10 s"] - 50.0) < 1e-9, "half the items on lanes in view under 1 s")
        ok &= check(rep["view_offset"] == [0.0, 0.0], "the view centred on the character")
        # Clipped to what was recorded round the character.
        truth2 = dict(truth, near=[15, 40])
        rep2 = w.score_walk(truth2, dump, apply, "0,85,92.31,ortho", 60.0, kinds)
        ok &= check(rep2["clipped"] == 2 and rep2["per_tick"][0]["bounds"] == [-15.0, -10.0, 15.0, 10.0], "bounds clipped to the recorded rectangle")
        text = w.format_report(rep, {"p_compared": {6: 2}, "p_before": {}, "ld_during": 0, "rate": None, "hold60": "on"},
                               {"at": (0, 0), "route": "test", "moving": True, "sample": 60, "near": [60, 40], "ticks": 120, "seconds": {"recording": 2}})
        ok &= check("visible 100.0%" in text and "under 1 s" in text, "the report reads")
    print("PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
