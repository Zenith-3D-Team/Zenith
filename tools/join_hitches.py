#!/usr/bin/env python3
"""The join's hitches from a --stutter-probe run (route `join`): frame-time percentiles, the frames
over 25 and 50 ms, and what each hitch was spent on, from the probe's per-frame counters.

    python3 tools/join_hitches.py probe.json [probe2.json ...] [--over 25] [--md] [--frames 12]

A frame's hitch is attributed to the biggest of: each script subtree's _process (the probe's markers:
World itself, BeltItems, Animator...), refined by world.gd's parts (w_build, w_terrain_finish, w_bi_upload:
the belt records' upload...) when the subtree is World itself or BeltItems; the renderer's draw on the
main thread (with the GPU pipelines compiled that frame: shader and pipeline compiles happen there);
deferred calls and freed nodes between _process and the draw (flush); presenting and waiting for the GPU
(present); physics. Several runs are pooled for the table, and reported one by one for the percentiles.
"""
import argparse
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from percentile import pct  # noqa: E402

# Frame columns (stutter_probe.gd _frames).
MS, MODEL, LODS, REBUILD, TERRAIN, HANDLE, RCPU, GPU, MADE, X, Y, TICK, PROCESS, PHYSICS, SEGS, PIPES, DRAWS, PRIMS, ALIVE, PHASES = range(20)

WORLD_PARTS = {"w_build": "chunk entity rebuild (world.gd build)", "w_pending": "chunk MultiMeshes added (pending)",
               "w_terrain_finish": "terrain meshes put in", "w_terrain_start": "terrain jobs started", "w_terrain_poll": "terrain polled",
               "w_models_poll": "models made on workers finished (models_poll)", "w_subscribe": "chunk subscribe", "w_shadows": "shadow tiers",
               "w_unload_free": "chunks freed", "w_changed_signal": "chunk changed signals", "w_far": "far chunks merged",
               "w_bi_upload": "belt records upload (Texture2DArray)", "w_bi_records": "belt kinds' MultiMesh put_records",
               "w_bi_lattice": "belt lattice upload", "w_bi_prepare": "belt kinds prepared (new item kinds)",
               "w_bi_handover": "belt far-lane hand-over", "w_bi_paths": "belt paths texture",
               "w_ic_look": "item kinds' look (model or icon lookup)", "w_ic_icons_prepare": "icon index and mods scanned (first icon)",
               "w_ic_dress": "item kinds' materials", "c_us_build_recs": "chunk build: records to models",
               "c_us_build_wants": "chunk build: MultiMesh wants", "c_us_build_apply": "chunk build: MultiMeshes made (apply)",
               "c_us_build_finish": "chunk build: lists, shadows, far chunks"}


def load(path, keep_shots=False):
    """(the run's JSON, its frames): without keep_shots the frames in which the harness saved a
    --screenshot (phases `shot`: the GPU read-back and PNG encode, half a second each) are left out."""
    d = json.load(open(path, encoding="utf-8"))
    frames = d.get("frames") or []
    if not frames and d.get("load_frames"):
        frames = d["load_frames"]
    if not keep_shots:
        kept = [f for f in frames if not (len(f) > PHASES and isinstance(f[PHASES], dict) and f[PHASES].get("shot"))]
        d["shots_dropped"] = len(frames) - len(kept)
        frames = kept
    return d, frames


def attribute(f):
    """(source, ms of it) for one frame."""
    cands = []
    segs = f[SEGS] if len(f) > SEGS and isinstance(f[SEGS], dict) else {}
    phases = f[PHASES] if len(f) > PHASES and isinstance(f[PHASES], dict) else {}
    for k, v in segs.items():
        cands.append((k, float(v)))
    for k in ("flush", "draw", "present"):
        if k in phases:
            cands.append((k, float(phases[k])))
    if len(f) > PHYSICS:
        cands.append(("physics", float(f[PHYSICS])))
    if not cands:
        return "unknown", 0.0
    name, ms = max(cands, key=lambda c: c[1])
    if name in ("World itself", "World", "BeltItems", "GroundItems", "before"):
        parts = [(k, float(v)) for k, v in phases.items() if k.startswith("w_") and (name != "BeltItems" or k.startswith("w_bi_"))
                 and (name != "GroundItems" or k.startswith("w_ic_"))]
        # chunk_view.gd's build phases, counted in microseconds (c_us_*)
        parts += [(k, float(v) / 1000.0) for k, v in phases.items() if k.startswith("c_us_")]
        if name == "World itself" or name == "World":
            # models made on the main thread and message handling are counted inside their nodes
            if f[MODEL] > 0.5:
                parts.append(("models made on the main thread", float(f[MODEL])))
            if f[LODS] > 0.5:
                parts.append(("level-of-detail work", float(f[LODS])))
        if parts:
            pk, pv = max(parts, key=lambda c: c[1])
            if pv > 0.3 * ms:
                return "%s: %s" % (name, WORLD_PARTS.get(pk, pk)), ms
        return name, ms
    if name == "draw":
        pipes = int(f[PIPES]) if len(f) > PIPES else 0
        if pipes > 0:
            return "renderer draw with pipeline compiles", ms
        return "renderer draw (main thread)", ms
    if name == "present":
        return "present / GPU wait", ms
    if name == "flush":
        return "deferred calls, freed nodes (flush)", ms
    return name, ms


def summarize(frames, over):
    ms = [float(f[MS]) for f in frames]
    out = {"frames": len(frames), "seconds": round(sum(ms) / 1000.0, 1),
           "p50": pct(ms, 0.5), "p95": pct(ms, 0.95), "p99": pct(ms, 0.99), "max": max(ms) if ms else 0.0,
           "over": sum(1 for m in ms if m > over),
           "over25": sum(1 for m in ms if m > 25.0), "over50": sum(1 for m in ms if m > 50.0),
           "over100": sum(1 for m in ms if m > 100.0), "over_ms": sum(max(0.0, m - 16.7) for m in ms if m > over),
           "pipelines": sum(int(f[PIPES]) for f in frames if len(f) > PIPES)}
    return out


def table(frames, over):
    by = {}
    for f in frames:
        if float(f[MS]) <= over:
            continue
        src, part = attribute(f)
        e = by.setdefault(src, [0, 0.0, 0.0, 0.0])
        e[0] += 1
        e[1] += float(f[MS]) - 16.7  # excess over a 60 Hz frame
        e[2] = max(e[2], float(f[MS]))
        e[3] += part
    rows = sorted(by.items(), key=lambda kv: -kv[1][1])
    return rows


def windows(frames, seconds=5.0):
    """Per window: [start s, frames, p50, max, over25, pipelines, top source]."""
    out = []
    t = 0.0
    w = []
    start = 0.0
    for f in frames:
        w.append(f)
        t += float(f[MS]) / 1000.0
        if t - start >= seconds:
            out.append(_window(start, w))
            w = []
            start = t
    if w:
        out.append(_window(start, w))
    return out


def _window(start, w):
    ms = [float(f[MS]) for f in w]
    rows = table(w, 25.0)
    top = rows[0][0] if rows else "-"
    return [round(start, 1), len(w), pct(ms, 0.5), max(ms), sum(1 for m in ms if m > 25.0), sum(int(f[PIPES]) for f in w), top]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="+")
    ap.add_argument("--over", type=float, default=25.0)
    ap.add_argument("--md", action="store_true")
    ap.add_argument("--frames", type=int, default=12, help="the worst frames to list")
    ap.add_argument("--windows", action="store_true")
    ap.add_argument("--keep-shots", action="store_true", help="keep the frames in which the harness saved a screenshot")
    a = ap.parse_args()
    pooled = []
    for r in a.runs:
        d, frames = load(r, a.keep_shots)
        pooled.extend(frames)
        s = summarize(frames, a.over)
        join = d.get("join", {})
        print("%s: %d frames over %.1f s | p50 %.1f p95 %.1f p99 %.1f max %.1f ms | over 25 ms %d, over %g ms %d, over 50 ms %d, "
              "over 100 ms %d | pipelines compiled %d | settled %.1f s, belt load done %.1f s, fully drawn %.1f s | "
              "screenshot frames left out %d" % (
                  r, s["frames"], s["seconds"], s["p50"], s["p95"], s["p99"], s["max"], s["over25"], a.over, s["over"], s["over50"],
                  s["over100"], s["pipelines"], join.get("settled_s", -1), join.get("belt_load_done_s", -1), join.get("drawn_s", -1),
                  d.get("shots_dropped", 0)))
        if a.windows:
            for w in windows(frames):
                print("   %5.1f s: %3d frames p50 %5.1f max %6.1f over25 %2d pipes %3d | %s" % tuple(w))
    rows = table(pooled, a.over)
    total = sum(e[1] for _, e in rows) or 1.0
    print()
    if a.md:
        print("| Source (biggest part of the frame) | Frames over %.0f ms | Excess ms over 16.7 | Share | Worst frame ms |" % a.over)
        print("|---|---|---|---|---|")
        for src, e in rows:
            print("| %s | %d | %.0f | %.0f%% | %.0f |" % (src, e[0], e[1], 100.0 * e[1] / total, e[2]))
    else:
        print("%-62s %6s %10s %6s %8s" % ("source (biggest part of the frame)", "frames", "excess ms", "share", "worst"))
        for src, e in rows:
            print("%-62s %6d %10.0f %5.0f%% %8.0f" % (src, e[0], e[1], 100.0 * e[1] / total, e[2]))
    worst = sorted(pooled, key=lambda f: -float(f[MS]))[:a.frames]
    print()
    print("worst frames: ms | source | segments | pipelines | models made | w_ parts over 1 ms")
    for f in worst:
        src, _ = attribute(f)
        phases = f[PHASES] if len(f) > PHASES and isinstance(f[PHASES], dict) else {}
        parts = {k: v for k, v in phases.items() if (k.startswith("w_") and float(v) >= 1.0) or k in ("flush", "draw", "present")}
        print("  %7.1f | %s | %s | pipes %d | made %d | %s" % (float(f[MS]), src, json.dumps(f[SEGS]) if len(f) > SEGS else "", int(f[PIPES]) if len(f) > PIPES else 0,
                                                              int(f[MADE]), json.dumps(parts)))


if __name__ == "__main__":
    main()
