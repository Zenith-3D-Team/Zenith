#!/usr/bin/env python3
"""Measures what items on belts cost on a running server, with a client that asks for them as the
real one does (hello `z`, `b`, `bl` and, with --bs, `bs`: a client that simulates belts itself; `bfar`
with the High preset's distances), standing where --teleport puts the bridge's character.

    powershell -ExecutionPolicy Bypass -File server\\run-server.ps1 -Save server\\saves\\copy.zip
    python3 tools/belt_bench.py --udp-port 34200 --teleport -272,-16 --seconds 40 --json out.json

It warms up for --warmup seconds (the first updates read every lane in full), then for --seconds:
the bridge's per-module times (/f3d-profile, /f3d-status), the game's UPS, the bytes of every
message type the client got, how far moving items reached (bi fr, tiles), and belt_items.lua's
counts (lanes checked, held, read in full, blind, items read) per update. With --bs: the first load
(how long until the square stopped growing, its bytes and lanes) and then, per update, the lanes sent
in full (sl), their meta (lm), drift checks (pc), dropped (dl), and belt_sim.lua's counts. With
--trace and --log, the bridge's time per tick (average, p99, worst) from /f3d-profile trace lines.
Run it on a copy of a save: it uses /c.
"""

import argparse
import json
import pathlib
import re
import socket
import sys
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import rcon  # noqa: E402

MOD = "__factorio-3d-bridge__"
COUNTS = (f"/c {MOD} local c = package.loaded['__factorio-3d-bridge__/scripts/belt_items.lua'].counts "
          "local b = storage.f3d.bi rcon.print(helpers.table_to_json({c = c, n = b and b.count or 0, tick = game.tick}))")
COUNTS_BS = (f"/c {MOD} local c = package.loaded['__factorio-3d-bridge__/scripts/belt_sim.lua'].counts "
             "local b = storage.f3d.bs local w, wl, lanes, belts = 0, 0, 0, 0 "
             "if b then for u in pairs(b.wset) do w = w + 1 end for _ in pairs(b.lanes) do lanes = lanes + 1 end "
             "for _ in pairs(b.belts) do belts = belts + 1 end end "
             "rcon.print(helpers.table_to_json({c = c, n = b and b.count or 0, tick = game.tick, watched_belts = w, "
             "lanes = lanes, belts = belts, scan = b and b.scan and b.scan.n or 0}))")
TRACE = re.compile(r"f3dtrace (\d+) (\S+) Duration: ([\d.]+) ?ms")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--udp-port", type=int, default=34200)
    parser.add_argument("--rcon-port", type=int, default=rcon.PORT)
    parser.add_argument("--password-file", default=str(rcon.DEFAULT_PASSWORD_FILE))
    parser.add_argument("--teleport", default="-272,-16")
    parser.add_argument("--seconds", type=float, default=40.0)
    parser.add_argument("--warmup", type=float, default=20.0)
    parser.add_argument("--view", type=int, default=5, help="chunks subscribed round the character")
    parser.add_argument("--near", type=int, default=160, help="bfar n: belt item distance")
    parser.add_argument("--cap", type=int, default=6000, help="bfar m: belt updates")
    parser.add_argument("--units", type=int, default=10000000, help="bfar u (Smooth belt items on: 10000000)")
    parser.add_argument("--rate", type=int, default=0, help="rate l: the update rate level the client asks for (Hold 60 UPS sends 1-3)")
    parser.add_argument("--bs", action="store_true", help="say bs in the hello: the client simulates belts (bs messages)")
    parser.add_argument("--trace", type=int, default=0, help="trace this many ticks (/f3d-profile trace) at the start of the "
                        "measured window and read the bridge's time per tick back from --log")
    parser.add_argument("--log", default="", help="the server's factorio-current.log (for --trace)")
    parser.add_argument("--capture", default="", help="write every bi message received (from the start) to this .jsonl, "
                        "for client/tests/belt_stream_replay.tscn")
    parser.add_argument("--json", default="")
    parser.add_argument("--label", default="")
    args = parser.parse_args()
    password = pathlib.Path(args.password_file).read_text().strip()

    def cmd(c):
        return rcon.run(c, port=args.rcon_port, password=password, timeout=60.0)

    cmd("/sc rcon.print(1)")  # the first /sc in a save only warns about achievements
    if args.teleport:
        x, y = args.teleport.split(",")
        cmd(f"/c {MOD} package.loaded['__factorio-3d-bridge__/scripts/puppet.lua'].get()"
            f".teleport({{{x}, {y}}}, game.surfaces.nauvis)")

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 32 * 1024 * 1024)
    sock.bind(("127.0.0.1", 0))
    sock.settimeout(0.05)
    server = ("127.0.0.1", args.udp_port)
    hello = {"t": "hello", "v": 1, "sid": "belt-bench", "w": 1, "z": 1, "b": 1, "bl": 1}
    if args.bs:
        hello["bs"] = 1
    counts_cmd = COUNTS_BS if args.bs else COUNTS
    state = {"pos": None, "stop": False, "count": False}
    reach = []
    capture = open(args.capture, "w", encoding="utf-8") if args.capture else None
    tally = {}
    lock = threading.Lock()

    def send(msg):
        sock.sendto(json.dumps(msg).encode(), server)

    # bs: the first load (from the first bs message until fr stops growing) and what each update
    # carries. {field: [entries, bytes]} per window ("load" before counting starts, "steady" after).
    bs_stats = {"first": None, "fr": [], "load": {}, "steady": {}, "updates": {}}
    BS_WIDTH = {"lm": 12, "pc": 5, "dl": 1, "of": 2, "qu": 2}

    def bs_note(msg):
        now = time.monotonic()
        if bs_stats["first"] is None:
            bs_stats["first"] = now
        if msg.get("part", 1) == 1:
            bs_stats["fr"].append((now, msg.get("fr", 0)))
        window = bs_stats["steady" if state["count"] else "load"]
        upd = bs_stats["updates"].setdefault(msg.get("k"), {"sl": 0, "lm": 0, "pc": 0, "dl": 0, "steady": state["count"]})
        for field in ("lm", "sl", "pc", "dl", "of", "qu"):
            v = msg.get(field)
            if not v:
                continue
            if field == "sl":
                n, i = 0, 0
                while i < len(v):
                    n += 1
                    i += 3 + v[i + 2] * 4
            else:
                n = len(v) // BS_WIDTH[field]
            rec = window.setdefault(field, [0, 0])
            rec[0] += n
            rec[1] += len(json.dumps(v, separators=(",", ":")))
            if field in upd:
                upd[field] += n

    def receive():
        while not state["stop"]:
            try:
                data, _ = sock.recvfrom(1 << 20)
            except (socket.timeout, ConnectionResetError):
                continue
            for line in data.split(b"\n"):
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                t = msg.get("t", "?")
                if t == "bs":
                    with lock:
                        bs_note(msg)
                if capture and t in ("bi", "bs"):
                    capture.write(line.decode("utf-8", "replace") + "\n")
                if t == "me" and "x" in msg:
                    state["pos"] = (msg["x"] / 256, msg["y"] / 256)
                if state["count"] and t in ("bi", "bs") and msg.get("part", 1) == 1 and "fr" in msg:
                    reach.append(msg["fr"])
                if state["count"]:
                    with lock:
                        rec = tally.setdefault(t, [0, 0])
                        rec[0] += 1
                        rec[1] += len(line)

    threading.Thread(target=receive, daemon=True).start()

    def keep_alive(until):
        beat = 0
        while time.monotonic() < until:
            pos = state["pos"]
            # Every second: the hello, the chunks, the distances; four times a second the focus (it
            # follows the character when something walks it: walk.py) and the lanes to send again.
            if beat % 4 == 0:
                send(hello)
                if pos:
                    cx, cy = int(pos[0] // 32), int(pos[1] // 32)
                    send({"t": "sub", "c": [[cx + dx, cy + dy] for dy in range(-args.view, args.view + 1)
                                            for dx in range(-args.view, args.view + 1)]})
                    send({"t": "bfar", "r": args.near, "n": args.near, "m": args.cap, "u": args.units})
                if args.rate:
                    send({"t": "rate", "l": args.rate})
            if pos:
                send({"t": "focus", "x": int(pos[0] * 256), "y": int(pos[1] * 256), "r": 96})
            beat += 1
            time.sleep(0.25)

    keep_alive(time.monotonic() + args.warmup)
    if state["pos"] is None:
        print("no reply from the bridge: is the server running and the UDP port right?")
        sys.exit(1)
    reply = cmd("/f3d-profile")
    if "off" in reply:
        cmd("/f3d-profile")
    before = json.loads(cmd(counts_cmd))
    log_from = pathlib.Path(args.log).stat().st_size if args.log and pathlib.Path(args.log).exists() else 0
    if args.trace:
        cmd(f"/f3d-profile trace {args.trace}")
    t0 = time.perf_counter()
    state["count"] = True
    samples = []

    def sample_ticks():
        while not state["stop"]:
            samples.append((time.perf_counter(), int(cmd("/sc rcon.print(game.tick)").strip())))
            time.sleep(0.5)

    sampler = threading.Thread(target=sample_ticks, daemon=True)
    sampler.start()
    keep_alive(time.monotonic() + args.seconds)
    state["count"] = False
    elapsed = time.perf_counter() - t0
    after = json.loads(cmd(counts_cmd))
    status = cmd("/f3d-status")
    cmd("/f3d-profile")
    state["stop"] = True
    sampler.join(2.0)
    send({"t": "bye"})
    if capture:
        capture.close()

    updates = max(1, after["n"] - before["n"])
    counts = {k: round((after["c"].get(k, 0) - before["c"].get(k, 0)) / updates, 1) for k in after["c"]}
    trace = None
    if args.trace and args.log:
        time.sleep(2.0)
        per = {}
        with open(args.log, "rb") as f:
            f.seek(log_from)
            for raw in f:
                m = TRACE.search(raw.decode("utf-8", "replace"))
                if m:
                    per.setdefault(m.group(2), {})[int(m.group(1))] = float(m.group(3))

        def stats(name):
            v = sorted(per.get(name, {}).values())
            if not v:
                return None
            return {"avg": round(sum(v) / len(v), 3), "p99": round(v[min(len(v) - 1, int(len(v) * 0.99))], 3),
                    "max": round(v[-1], 3), "ticks": len(v)}
        trace = {name: stats(name) for name in ("TOTAL", "belt_items", "belt_lanes", "movers") if per.get(name)}
    bs_result = None
    if args.bs:
        fr = bs_stats["fr"]
        top = max((v for _, v in fr), default=0)
        reached = next((t for t, v in fr if v == top), None)
        steady = [u for u in bs_stats["updates"].values() if u["steady"]]
        n = max(1, len(steady))
        bs_result = {
            "first_load_s": round(reached - bs_stats["first"], 1) if reached and bs_stats["first"] else None,
            "fr_max": top,
            "load": {f: {"entries": v[0], "kb": round(v[1] / 1024, 1)} for f, v in bs_stats["load"].items()},
            "steady_per_update": {f: round(sum(u[f] for u in steady) / n, 1) for f in ("sl", "lm", "pc", "dl")},
            "steady_kb_per_s": {f: round(v[1] / 1024 / elapsed, 1) for f, v in bs_stats["steady"].items()},
            "watched_belts": after.get("watched_belts"), "lanes": after.get("lanes"), "belts": after.get("belts"),
            "scan_belts": after.get("scan"),
        }
    ups = (samples[-1][1] - samples[0][1]) / (samples[-1][0] - samples[0][0]) if len(samples) > 1 else 0
    modules = {}
    for line in status.splitlines():
        m = re.match(r"\[Zenith\]\s*([\w\-./:]+):\s*Duration:\s*([\d.]+)\s*ms", line)
        if m:
            modules[m.group(1)] = float(m.group(2))
    result = {
        "label": args.label,
        "seconds": round(elapsed, 1),
        "ups": round(ups, 2),
        "updates": updates,
        "ticks_between_updates": round((after["tick"] - before["tick"]) / updates, 1),
        "per_update": counts,
        "bs": bs_result,
        "trace_ms": trace,
        "reach": {"mean": round(sum(reach) / len(reach), 1), "min": min(reach), "max": max(reach)} if reach else None,
        "kb_per_s": {t: round(v[1] / 1024 / elapsed, 1) for t, v in sorted(tally.items(), key=lambda kv: -kv[1][1])[:8]},
        "kb_per_s_total": round(sum(v[1] for v in tally.values()) / 1024 / elapsed, 1),
        "modules_ms": modules,
    }
    print(json.dumps(result, indent=1))
    print(status)
    if args.json:
        with open(args.json, "a", encoding="utf-8") as f:
            f.write(json.dumps(dict(result, status=status)) + "\n")


if __name__ == "__main__":
    main()
