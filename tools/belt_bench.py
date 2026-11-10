#!/usr/bin/env python3
"""Measures what items on belts cost on a running server, with a client that asks for them as the
real one does (hello `z`, `b`, `bl` and, with --groups, `bg`, with --runs, `br`; `bfar` with the High
preset's distances), standing where --teleport puts the bridge's character.

    powershell -ExecutionPolicy Bypass -File server\\run-server.ps1 -Save server\\saves\\copy.zip
    python3 tools/belt_bench.py --udp-port 34200 --teleport -272,-16 --seconds 40 --json out.json

It warms up for --warmup seconds (the first updates read every lane in full), then for --seconds:
the bridge's per-module times (/f3d-profile, /f3d-status), the game's UPS, the bytes of every
message type the client got, how far moving items reached (bi fr, tiles), and belt_items.lua's
counts (lanes checked, held, read in full, blind, held as groups, plain lanes not checked, items
read) per update. Run it on a copy of a save: it uses /c.
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
    parser.add_argument("--groups", action="store_true", help="say bg in the hello: lanes flowing full come as groups")
    parser.add_argument("--runs", action="store_true", help="say br in the hello: plain lanes of straight runs are moved by the client")
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
    if args.groups:
        hello["bg"] = 1
    if args.runs:
        hello["br"] = 1
    state = {"pos": None, "stop": False, "count": False}
    reach = []
    capture = open(args.capture, "w", encoding="utf-8") if args.capture else None
    tally = {}
    lock = threading.Lock()

    def send(msg):
        sock.sendto(json.dumps(msg).encode(), server)

    # Straight runs (--runs): what the real client asks for again (`bre`), roughly: a plain lane whose
    # drift check (`pc`) has another count than the lane's last full read. (The real client compares
    # with the items it moved there; this one moves nothing, so it asks a little more often.)
    runs = args.runs
    plain, counts, ask = set(), {}, set()

    def drift(msg):
        pl = msg.get("pl", [])
        for i in range(0, len(pl), 8):
            plain.add(pl[i])
        ln = msg.get("ln", [])
        seen = {}
        for i in range(0, len(ln) - 1, 2):
            seen[ln[i]] = seen.get(ln[i], 0) + ln[i + 1]
        counts.update(seen)
        for key in msg.get("dl", []):
            plain.discard(key)
            counts.pop(key, None)
        pc = msg.get("pc", [])
        for i in range(0, len(pc) - 4, 5):
            key = pc[i]
            if key in plain and counts.get(key) != pc[i + 1]:
                with lock:
                    ask.add(key)

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
                if t == "bi" and runs:
                    drift(msg)
                if capture and t == "bi":
                    capture.write(line.decode("utf-8", "replace") + "\n")
                if t == "me" and "x" in msg:
                    state["pos"] = (msg["x"] / 256, msg["y"] / 256)
                if state["count"] and t == "bi" and msg.get("part", 1) == 1 and "fr" in msg:
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
            with lock:
                again = sorted(ask)[:256]
                ask.difference_update(again)
            if again:
                send({"t": "bre", "l": again})
                state["asked"] = state.get("asked", 0) + len(again)
            beat += 1
            time.sleep(0.25)

    keep_alive(time.monotonic() + args.warmup)
    if state["pos"] is None:
        print("no reply from the bridge: is the server running and the UDP port right?")
        sys.exit(1)
    reply = cmd("/f3d-profile")
    if "off" in reply:
        cmd("/f3d-profile")
    before = json.loads(cmd(COUNTS))
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
    after = json.loads(cmd(COUNTS))
    status = cmd("/f3d-status")
    cmd("/f3d-profile")
    state["stop"] = True
    sampler.join(2.0)
    send({"t": "bye"})
    if capture:
        capture.close()

    updates = max(1, after["n"] - before["n"])
    counts = {k: round((after["c"].get(k, 0) - before["c"].get(k, 0)) / updates, 1) for k in after["c"]}
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
        "asked_again": state.get("asked", 0),
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
