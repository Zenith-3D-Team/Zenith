"""The bridge's belt cost per switch setting, in place: one stand-in client (belt_bench.py --bs) at a spot on the
kept server (35400-35402), the settings taken in turn (round robin), /f3d-status's 600-tick windows read after a
settle, with belt_sim's counters (actors checked, skipped, lanes read) over the same span.
python tools/belt_switch_cost.py -62,-26 out.jsonl [rounds]   (the kept server up and profiling on: /f3d-profile)"""
import json, re, subprocess, sys, time, pathlib
sys.path.insert(0, "tools")
import rcon

WT = pathlib.Path(".").resolve()
PW = (WT / "server" / "data" / "rcon-password.txt").read_text().strip()
BS = 'package.loaded["__factorio-3d-bridge__/scripts/belt_sim.lua"]'
CONFIGS = [("base", "on", "off", True), ("ins", "on", "on", True), ("ins_noeager", "on", "on", False), ("lnoff", "off", "off", True)]
KEYS = ["belt_items", "bs.watch", "bs.actor", "bs.drift", "bs.emit", "bs.edge", "bs.feed", "bs.scan", "bs.queue", "inserters", "bridge"]


def rc(cmd, t=30):
    for _ in range(3):
        try:
            return rcon.run(cmd, port=35402, password=PW, timeout=t)
        except (OSError, ValueError):
            time.sleep(2)
    return ""


def counts():
    s = rc("/sc __factorio-3d-bridge__ local c=%s.counts or {}; local t={}; for k,v in pairs(c) do t[#t+1]=k..'='..tostring(v) end;"
           " rcon.print(game.tick..' '..table.concat(t,' '))" % BS)
    parts = s.split()
    if not parts:
        return None
    d = {"tick": int(parts[0])}
    for p in parts[1:]:
        k, _, v = p.partition("=")
        try:
            d[k] = float(v)
        except ValueError:
            pass
    return d


def prof(text):
    d = {}
    for line in text.splitlines():
        m = re.match(r"\[Zenith\] (\S+): Duration: ([\d.]+)ms", line)
        if m and m.group(1) in KEYS:
            d[m.group(1)] = float(m.group(2))
    return d


def main():
    at, out, rounds = sys.argv[1], pathlib.Path(sys.argv[2]), int(sys.argv[3]) if len(sys.argv) > 3 else 3
    bench = subprocess.Popen([sys.executable, "tools/belt_bench.py", "--udp-port", "35400", "--rcon-port", "35402",
                              "--password-file", str(WT / "server" / "data" / "rcon-password.txt"), "--bs",
                              "--teleport=" + at, "--warmup", "100000", "--seconds", "1", "--cap", "6000", "--near", "160"],
                             stdout=open(out.with_suffix(".bench.out"), "w"), stderr=subprocess.STDOUT)
    try:
        t0 = time.time()
        while "client on port" not in rc("/f3d-status") and time.time() - t0 < 120:
            time.sleep(3)
        time.sleep(60)
        with open(out, "a") as f:
            for r in range(rounds):
                for name, ln, ins, eager in CONFIGS:
                    rc("/f3d-bs lane_next " + ln)
                    rc("/f3d-bs ins_driven " + ins)
                    rc("/sc __factorio-3d-bridge__ %s.ins_eager=%s" % (BS, "true" if eager else "false"))
                    time.sleep(25)
                    c0, w0 = counts(), time.time()
                    samples = []
                    for _ in range(3):
                        time.sleep(10.5)
                        samples.append(prof(rc("/f3d-status")))
                    c1, w1 = counts(), time.time()
                    row = {"at": at, "round": r, "cfg": name, "samples": samples}
                    if c0 and c1:
                        row["ups"] = (c1["tick"] - c0["tick"]) / (w1 - w0)
                        row["d"] = {k: c1[k] - c0.get(k, 0) for k in c1 if k != "tick"}
                        row["ticks"] = c1["tick"] - c0["tick"]
                    f.write(json.dumps(row) + "\n")
                    f.flush()
                    print(name, r, {k: round(sum(s.get(k, 0) for s in samples) / 3, 3) for k in ("belt_items", "bs.watch", "bs.actor")}, flush=True)
    finally:
        rc("/f3d-bs lane_next on")
        rc("/f3d-bs ins_driven off")
        rc("/sc __factorio-3d-bridge__ %s.ins_eager=true" % BS)
        bench.kill()


if __name__ == "__main__":
    main()
