#!/usr/bin/env python3
"""Replay bench for the world's chunk streaming (perf-rd-world task 1; task 2's parity check).

Records the mock's busy base (`mock_server.py --busy`: about 20,000 entities) as the `protos`, `chunk` and
`ents` messages a client would read, in-process (no sockets, no server), into a JSON-lines file; then
replays it through world.gd `handle` and the chunk builds with no server
(`client/tests/world_stream_bench.gd`), headless and muted, once per switch setting, and prints
microseconds per entity for add, collect (first build, a build for the view alone, a build for a
change), apply and the far gather, with a hash of every chunk's wants and far groups. The hashes must
match between `--collect-cache` on and off.

    python tools/bench/world_stream.py                   # record + replay with --collect-cache on and off
    python tools/bench/world_stream.py --godot <exe>     # (else as tools/check.py finds it)
    python tools/bench/world_stream.py --record-only     # just the recording
    python tools/bench/world_stream.py --loops 5

Logs and files: art-src/check-logs/world_stream/ (git-ignored).
"""
import argparse
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "art-src", "check-logs", "world_stream")
KINDS = ("protos", "tprotos", "iprotos", "fprotos", "chunk", "ents")
CHUNK = 32


def record(path, seed=1):
    sys.path.insert(0, os.path.join(ROOT, "tools"))
    import mock_server  # noqa: E402 (the mock's own world, made in-process)

    game = mock_server.MockGame(seed, 0.0, 1200, (0.0, 0.0))
    game.build_starter_base()
    x0, y0, cols, rows = -150, 40, 60, 40
    game.build_busy_base(cols=cols, rows=rows, x0=x0, y0=y0)
    game.client = {}
    game.rseq, game.outbox = 0, []
    recs = []
    for name, etype, w, h, color in mock_server.ENTITY_PROTOS:
        recs.append([mock_server.EID[name], name, etype, -w / 2, -h / 2, w / 2, h / 2, *color, -(-w // 1), -(-h // 1)])
    game.send_parts("protos", recs)
    game.send_parts("tprotos", [[mock_server.TID[n], n, *c] for n, c in mock_server.TILE_PROTOS])
    cx0, cx1 = (x0 - 8) // CHUNK, (x0 + cols * 5 + 8) // CHUNK
    cy0, cy1 = (y0 - 8) // CHUNK, (y0 + rows * 6 + 8) // CHUNK
    for cy in range(cy0, cy1 + 1):
        for cx in range(cx0, cx1 + 1):
            game.snapshot(cx, cy)
    n_ents = 0
    with open(path, "w", encoding="utf-8") as f:
        for msg in game.outbox:
            if msg.get("t") in KINDS:
                msg.pop("r", None)
                if msg["t"] == "ents":
                    n_ents += len(msg.get("e", []))
                f.write(json.dumps(msg, separators=(",", ":")) + "\n")
    print(f"recorded {n_ents} entities in {(cx1 - cx0 + 1) * (cy1 - cy0 + 1)} chunks -> {os.path.relpath(path, ROOT)}")


def find_godot(given):
    if given:
        return given
    sys.path.insert(0, os.path.join(ROOT, "tools"))
    import check  # noqa: E402 ($GODOT, PATH, ~/Tools/Godot, winget's: as tools/check.py finds it)
    g = check.godot_path()
    if g:
        return g
    sys.exit("godot not found: pass --godot <exe> or set GODOT")


def replay(godot, path, cache_on, loops, n, dump=False, extra=(), tag=None):
    tag = tag or ("on" if cache_on else "off")
    log = os.path.join(OUT, f"godot-{tag}-{n}.log")
    out_json = os.path.join(OUT, f"result-{tag}-{n}.json")
    args = [godot, "--headless", "--audio-driver", "Dummy", "--path", os.path.join(ROOT, "client"), "--log-file", log,
            "-s", "res://tests/world_stream_bench.gd", "--", f"--input={path}", f"--json={out_json}", f"--loops={loops}"]
    if not cache_on:
        args.append("--collect-cache=off")
    args.extend(extra)
    if dump:
        args.append("--dump=" + os.path.join(OUT, "dump-" + tag))
    p = subprocess.run(args, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=900)
    ok = re.search(r"WORLD_STREAM_BENCH (PASS|FAIL)", p.stdout or "")
    if not os.path.exists(out_json) or not ok:
        print((p.stdout or "")[-3000:])
        sys.exit(f"replay ({tag}) failed: exit {p.returncode}, log {os.path.relpath(log, ROOT)}")
    with open(out_json, encoding="utf-8") as f:
        return json.load(f)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--godot")
    ap.add_argument("--loops", type=int, default=3)
    ap.add_argument("--record-only", action="store_true")
    ap.add_argument("--dump", action="store_true", help="each hash's rows to art-src/check-logs/world_stream/dump-on|off/")
    ap.add_argument("--only", choices=("on", "off"), help="replay with one setting only")
    ap.add_argument("--against", action="append", default=[], metavar="SWITCH",
                    help="instead of --collect-cache on/off: --collect-cache on as it is ('new') against it with these "
                         "switches added ('old'), e.g. --against=--resolve-memo=off --against=--native-collect=off")
    a = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, "busy.jsonl")
    record(path)
    if a.record_only:
        return 0
    godot = find_godot(a.godot)
    res = {}
    if a.against:
        res["old"] = replay(godot, path, True, a.loops, 0, a.dump, a.against, "old")
        res["new"] = replay(godot, path, True, a.loops, 1, a.dump, (), "new")
    for i, on in enumerate((False, True) if not a.against else ()):
        if a.only and a.only != ("on" if on else "off"):
            continue
        res["on" if on else "off"] = replay(godot, path, on, a.loops, i, a.dump)
    keys = ["add", "collect_first", "collect_view", "collect_change", "apply", "far_gather", "collect_first_far",
            "far_first_total"]
    print(f"{'us/entity':<16}" + "".join(f"{k:>10}" for k in res))
    for k in keys:
        print(f"{k:<16}" + "".join(f"{float(r['us_per_entity'].get(k, 0)):>10.3f}" for r in res.values()))
    print(f"{'ms per pass':<16}" + "".join(f"{k:>10}" for k in res))
    for k in keys:
        print(f"{k:<16}" + "".join(f"{float(r['ms'].get(k, 0)):>10.2f}" for r in res.values()))
    if len(res) == 2:
        x, y = list(res.values())
        bad = [k for k in x["hashes"] if x["hashes"][k] != y["hashes"].get(k)]
        if bad:
            print("PARITY FAIL: " + ", ".join(bad))
            return 1
        what = " ".join(a.against) + " on and off" if a.against else "--collect-cache on and off"
        print(f"parity: {len(x['hashes'])} hashes equal with {what}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
