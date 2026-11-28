#!/usr/bin/env python3
"""Summarises a soak (tools/bench/soak/soak.py): per phase and preset frame stats, every slow frame grouped
by phase and cause (from the client's spike log), memory over time per process, UPS and bridge ms/tick,
and the client logs' warnings and errors.

    python tools/bench/soak/analyze.py <out dir>  [--json summary.json] [--md tables.md]
"""

import argparse
import collections
import glob
import json
import os
import re
import statistics

SPIKE = re.compile(r"^t ([0-9.]+)s frame ([0-9.]+) ms: scripts ([0-9.]+), deferred\+frees ([0-9.]+), draw ([0-9.\-]+), rest ([0-9.]+)(.*)$")


def pct(vals, p):
    if not vals:
        return None
    s = sorted(vals)
    return s[min(len(s) - 1, int(len(s) * p))]


def load_jsonl(path):
    out = []
    if not os.path.exists(path):
        return out
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return out


def spike_cause(rest):
    """The biggest named part of a spike line's tail: 'top <name> <ms>' first, else the counts."""
    m = re.search(r"top ([^,;|]+?) ([0-9.]+)", rest)
    top = m.group(1).strip() if m else ""
    return top


def parse_spikes(path):
    out = []
    if not os.path.exists(path):
        return out
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = SPIKE.match(line.strip())
            if not m:
                continue
            t, frame, scripts, deferred, draw, rest_ms, tail = m.groups()
            out.append({"t": float(t), "ms": float(frame), "scripts": float(scripts), "deferred": float(deferred),
                        "draw": None if draw == "-" else float(draw), "rest": float(rest_ms), "tail": tail.strip(),
                        "top": spike_cause(tail)})
    return out


def bucket(sp):
    parts = {"scripts": sp["scripts"], "deferred+frees": sp["deferred"], "draw": sp["draw"] or 0.0, "rest": sp["rest"]}
    return max(parts, key=parts.get)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--json", default="")
    ap.add_argument("--md", default="")
    a = ap.parse_args()
    sessions = sorted(glob.glob(os.path.join(a.out, "sessions", "*")))
    phase_rows = []
    spikes_by = collections.defaultdict(lambda: {"n": 0, "ms": 0.0, "max": 0.0, "examples": []})
    mem_rows = []
    ups_rows = []
    log_rows = []
    for sd in sessions:
        name = os.path.basename(sd)
        _, preset, save = name.split("-", 2)
        frames = load_jsonl(os.path.join(sd, "frames.jsonl"))
        start = next((f for f in frames if f.get("k") == "start"), None)
        joined = next((f for f in frames if f.get("k") == "joined"), None)
        phase_at = []  # (msec, phase)
        for f in frames:
            if f.get("k") == "phase":
                phase_at.append((f["msec"], f["name"]))
            elif f.get("k") == "sum":
                fr = [v / 10.0 for v in f.get("frames", [])]
                phase_rows.append({"session": name, "preset": preset, "save": save, "phase": f["phase"],
                                   "base": f["phase"].split("@")[0], "rep": int(f["phase"].split("@")[1]) if "@" in f["phase"] else 1,
                                   "n": f["frames_n"], "secs": round(f["secs"], 1), "fps": round(f["fps"], 1),
                                   "p50": f["p50"], "p95": f["p95"], "p99": f["p99"], "max": f["max"],
                                   "over25": f["over25"], "over50": f["over50"], "over100": f["over100"], "over250": f["over250"],
                                   "gpu_p50": f["gpu_p50"], "gpu_p95": f["gpu_p95"], "cpu_p50": f["cpu_p50"], "cpu_p95": f["cpu_p95"],
                                   "slow_ms": round(sum(v - 16.7 for v in fr if v > 25.0), 1)})
        # The spike log's lines, each given the phase it fell in. Its t counts from when the log was switched on, not
        # the engine's start: the offset is taken from frames both saw (same length within 3 ms), the median of them.
        sps = parse_spikes(os.path.join(sd, "spikes.log"))
        drv = [(f["msec"] / 1000.0, f["ms"]) for f in frames if f.get("k") == "spike" and f["ms"] > 60]
        offs = []
        for sp in sps:
            if sp["ms"] > 60:
                for at, ms in drv:
                    if abs(ms - sp["ms"]) < 3.0 and 0 <= at - sp["t"] < 600:
                        offs.append(at - sp["t"])
        off = statistics.median(offs) if offs else (start["msec"] / 1000.0 if start else 0.0)
        for sp in sps:
            ph = "boot"
            for msec, p in phase_at:
                if (sp["t"] + off) * 1000.0 >= msec:
                    ph = p
            key = (ph.split("@")[0], bucket(sp), sp["top"] or "-")
            b = spikes_by[key]
            b["n"] += 1
            b["ms"] += sp["ms"]
            b["max"] = max(b["max"], sp["ms"])
            if len(b["examples"]) < 3 or sp["ms"] > min(e["ms"] for e in b["examples"]):
                b["examples"].append({"session": name, "t": sp["t"], "ms": sp["ms"], "tail": sp["tail"][:300]})
                b["examples"] = sorted(b["examples"], key=lambda e: -e["ms"])[:3]
        for r in load_jsonl(os.path.join(sd, "proc.jsonl")):
            g = r.get("godot") or {}
            fz = r.get("factorio") or {}
            gpu = r.get("gpu_mb") or {}
            mem_rows.append({"session": name, "unix": r["unix"], "t": r["t"], "free_gb": r.get("free_gb"),
                             "godot_ws": g.get("ws_mb"), "godot_priv": g.get("priv_mb"),
                             "factorio_ws": fz.get("ws_mb"), "factorio_priv": fz.get("priv_mb"),
                             "godot_gpu": gpu.get(str(r.get("godot_pid"))) if gpu else None})
        mems = [f for f in frames if f.get("k") == "mem"]
        ups = load_jsonl(os.path.join(sd, "ups.jsonl"))
        if ups:
            u = [x["ups"] for x in ups if x.get("ups")]
            tot = [x.get("total", 0) for x in ups]
            mods = collections.defaultdict(list)
            for x in ups:
                for k, v in (x.get("modules") or {}).items():
                    mods[k].append(v)
            ups_rows.append({"session": name, "ups_med": statistics.median(u) if u else None, "ups_min": min(u) if u else None,
                             "bridge_med": round(statistics.median(tot), 3) if tot else None, "bridge_max": round(max(tot), 3) if tot else None,
                             "top_modules": sorted(((k, round(statistics.median(v), 3)) for k, v in mods.items()), key=lambda kv: -kv[1])[:5]})
        logp = os.path.join(sd, "godot.log")
        errs = collections.Counter()
        if os.path.exists(logp):
            with open(logp, encoding="utf-8", errors="replace") as f:
                for line in f:
                    if line.startswith(("ERROR", "WARNING", "SCRIPT ERROR", "USER ERROR", "USER WARNING")) or "SCRIPT ERROR" in line:
                        errs[re.sub(r"[0-9]+", "#", line.strip())[:160]] += 1
        log_rows.append({"session": name, "errors": sum(errs.values()), "top": errs.most_common(8),
                         "join_s": joined["secs"] if joined else None,
                         "client_mem_first": mems[0] if mems else None, "client_mem_last": mems[-1] if mems else None})
    spike_list = sorted(({"phase": k[0], "bucket": k[1], "top": k[2], **v} for k, v in spikes_by.items()), key=lambda r: -r["ms"])
    summary = {"phases": phase_rows, "spikes": spike_list, "memory": mem_rows, "ups": ups_rows, "logs": log_rows}
    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump(summary, f, indent=1)
    lines = ["| session | phase | fps | p50 | p95 | p99 | max | >25 | >50 | >100 | >250 | gpu p50/p95 | rcpu p50/p95 |", "|" + "---|" * 13]
    for r in phase_rows:
        lines.append("| %s | %s | %.0f | %.1f | %.1f | %.1f | %.0f | %d | %d | %d | %d | %.1f/%.1f | %.1f/%.1f |" % (
            r["session"], r["phase"], r["fps"], r["p50"], r["p95"], r["p99"], r["max"], r["over25"], r["over50"], r["over100"],
            r["over250"], r["gpu_p50"], r["gpu_p95"], r["cpu_p50"], r["cpu_p95"]))
    lines += ["", "| phase | bucket | top script | count | total ms | max ms |", "|---|---|---|---|---|---|"]
    for r in spike_list[:60]:
        lines.append("| %s | %s | %s | %d | %.0f | %.0f |" % (r["phase"], r["bucket"], r["top"], r["n"], r["ms"], r["max"]))
    text = "\n".join(lines)
    if a.md:
        with open(a.md, "w", encoding="utf-8") as f:
            f.write(text + "\n")
    else:
        print(text)


if __name__ == "__main__":
    main()
