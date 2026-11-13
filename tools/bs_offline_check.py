#!/usr/bin/env python3
"""The belt view check offline: a bridge's belt_sim.lua played against a recording (tools/bs_offline.py),
its `bs` stream replayed through a client build's belt_items.gd (client/tests/belt_bs_replay.gd
--view-dump), and tools/belt_view_check.py's report on it. A change to the bridge checked in a minute or
two instead of a live run.

    python tools/bs_offline_check.py --mod <worktree>/mod/factorio-3d-bridge --truth rec.json --world world.json
        [--client <worktree>] [--out <dir>] [--live <live stream.jsonl>] [--json <report.json>]
        [bs_offline.py's options: --toggles, --focus, --radius, --cap, --rate, --budget, ...]

--live: a live capture of the same recording, compared update by update with the offline stream (the
square fr, lanes sent with meta lm and items sl, items, walls ew, drift checks pc, lanes dropped dl).
Exit code 1 when the report FAILs, as belt_view_check.py's.
"""

import argparse
import json
import os
import pathlib
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import belt_view_check as bvc  # noqa: E402
import bs_offline  # noqa: E402


def stream_table(path):
    """{tick: {fr, p, w, lm, sl, items, ew, pc, dl}} per update of a bs stream."""
    ups = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                m = json.loads(line)
            except ValueError:
                continue
            if not isinstance(m, dict) or m.get("t") != "bs":
                continue
            k = int(m["k"])
            u = ups.get(k)
            if u is None:
                u = ups[k] = {"fr": m.get("fr"), "p": m.get("p"), "w": m.get("w"), "lm": 0, "sl": 0, "items": 0, "ew": 0, "pc": 0, "dl": 0,
                              "keys": set()}
            u["lm"] += len(m.get("lm", [])) // 12
            sl, i = m.get("sl", []), 0
            while i < len(sl):
                n = int(sl[i + 2])
                u["sl"] += 1
                u["items"] += n
                u["keys"].add(int(sl[i]))
                i += 3 + 4 * n
            u["ew"] += len(m.get("ew", [])) // 4
            u["pc"] += len(m.get("pc", [])) // 5
            u["dl"] += len(m.get("dl", []))
    return ups


def compare_streams(live, off, lo, hi):
    """Lines comparing two streams' updates within ticks lo..hi, and their totals."""
    a, b = stream_table(live), stream_table(off)
    ticks = sorted(t for t in set(a) | set(b) if lo <= t <= hi)
    out = ["  tick      fr live/off   lm live/off    sl live/off   items live/off   ew live/off  pc live/off   dl live/off  same sl lanes"]
    tot = {"a": {}, "b": {}}
    for t in ticks:
        x, y = a.get(t), b.get(t)
        def g(u, k):
            return u[k] if u else "-"
        same = len(x["keys"] & y["keys"]) if x and y else "-"
        out.append("  %d  %4s/%-4s  %5s/%-5s  %5s/%-5s  %6s/%-6s  %4s/%-4s  %4s/%-4s  %5s/%-5s  %s" % (
            t, g(x, "fr"), g(y, "fr"), g(x, "lm"), g(y, "lm"), g(x, "sl"), g(y, "sl"), g(x, "items"), g(y, "items"),
            g(x, "ew"), g(y, "ew"), g(x, "pc"), g(y, "pc"), g(x, "dl"), g(y, "dl"), same))
        for side, u in (("a", x), ("b", y)):
            if u:
                for k in ("lm", "sl", "items", "ew", "pc", "dl"):
                    tot[side][k] = tot[side].get(k, 0) + u[k]
                tot[side]["updates"] = tot[side].get("updates", 0) + 1
    out.append("  totals: live %s" % tot["a"])
    out.append("          offline %s" % tot["b"])
    keys_a = set().union(*(a[t]["keys"] for t in ticks if t in a)) if any(t in a for t in ticks) else set()
    keys_b = set().union(*(b[t]["keys"] for t in ticks if t in b)) if any(t in b for t in ticks) else set()
    out.append("  lanes sent (sl) in these updates: live %d, offline %d, both %d" % (len(keys_a), len(keys_b), len(keys_a & keys_b)))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--client", default=str(ROOT), help="the worktree whose belt_items.gd replays the stream")
    ap.add_argument("--out", default="", help="where the stream, view dump and logs go (default: a temp folder)")
    ap.add_argument("--live", default="")
    ap.add_argument("--json", default="")
    ap.add_argument("--godot", default="")
    a, rest = ap.parse_known_args()
    out = pathlib.Path(a.out) if a.out else pathlib.Path(os.environ.get("TEMP", ".")) / ("bs_offline_%d" % int(time.time()))
    out.mkdir(parents=True, exist_ok=True)
    stream = out / "stream.jsonl"
    t0 = time.time()
    summary, ups = bs_offline.main(rest + ["--out", str(stream), "--stats", str(out / "offline.json")])
    t_off = time.time() - t0
    truth_path = rest[rest.index("--truth") + 1] if "--truth" in rest else None
    if truth_path is None:
        truth_path = next(x.split("=", 1)[1] for x in rest if x.startswith("--truth="))
    views_path = out / "view.jsonl"
    t1 = time.time()
    bvc.replay(bvc.godot_exe(a.godot), a.client, str(stream), truth_path, str(views_path), str(out / "replay.out"))
    t_replay = time.time() - t1
    views, drawn = bvc.read_views(views_path)
    if not views:
        raise SystemExit("no update of the stream falls in the recording: see %s" % (out / "replay.out"))
    with open(truth_path, encoding="utf-8") as f:
        rec = json.load(f)
    at = None
    with open(stream, encoding="utf-8") as f:
        for line in f:
            m = json.loads(line)
            if m.get("t") == "bs" and "fx" in m and (m["fx"] or m["fy"]):
                at = (m["fx"] / 256.0, m["fy"] / 256.0)
                break
    rep = bvc.analyze(rec, views, drawn, at or (0.0, 0.0), bvc.run_info(str(stream), None, None, (views[0]["tick"], views[-1]["tick"])))
    rep["seconds"] = {"offline": round(t_off, 1), "replay": round(t_replay, 1), "all": round(time.time() - t0, 1)}
    rep["offline"] = summary
    print()
    print(bvc.format_report(rep))
    print("(offline bridge %.0f s, replay %.0f s, all %.0f s; files in %s)" % (t_off, t_replay, time.time() - t0, out))
    print("bridge per simulated tick: %.2f ms on average (p99 %.2f, max %.1f), %.0f work units (bs w) a tick: an indication only"
          % (summary["ms_per_tick"]["mean"], summary["ms_per_tick"]["p99"], summary["ms_per_tick"]["max"], summary["work_per_tick"]))
    if a.live:
        print()
        print("Live capture against the offline stream, updates within the recording:")
        for line in compare_streams(a.live, str(stream), views[0]["tick"] - 60, views[-1]["tick"]):
            print(line)
    if a.json:
        pathlib.Path(a.json).write_text(json.dumps(rep, indent=1, default=lambda o: sorted(o) if isinstance(o, set) else dict(o) if isinstance(o, dict) else str(o)))
    sys.exit(0 if rep["pass"] else 1)


if __name__ == "__main__":
    main()
