#!/usr/bin/env python3
"""Memory A/B of the client against a real headless Factorio: which build or switch carries the RAM.

Each variant (a checkout plus client switches) plays a fresh copy of a save on a scratch server
(tools/scratch_server.py, the checkout's own bridge mod) for --minutes, with `--mem-log` on; the real
Godot process's working set and private bytes are sampled every 10 s from outside. Writes
<out>/<n>-<variant>/{rss.tsv,godot.log} and <out>/table.md (RSS at 30 s, 60 s and the end, Godot's
static memory, the renderer's video memory and the pipelines compiled, from the last MEM line).

Headless by default (the dummy renderer: no GPU or driver memory). The renderer's share only shows
with --window, which opens a game window: run that only when nobody is using the PC.

  python tools/bench/mem_ab.py --variant main=. --variant 030=<0.3.0 checkout> --minutes 3
  python tools/bench/mem_ab.py --window --variant main=. --variant noboot=.:--boot-screen=off,--warm-shaders=off

A variant is label=<checkout>[:<switch>,<switch>...]. Windows only (the RSS sampling uses PowerShell).
"""
from __future__ import annotations

import argparse
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

TOOLS = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
import scratch_server  # noqa: E402

GODOT = os.environ.get("GODOT", "godot")
ADDONS = ("immersive-enemies", "immersive-weather", "cinematic-shaders")
MEM_RE = re.compile(r"MEM t=(\d+) static=(\d+) video=(\d+) tex=(\d+) buf=(\d+).*pipes canvas=(\d+) mesh=(\d+) surface=(\d+) draw=(\d+) spec=(\d+)")


def slug(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", text).strip("._")[-60:] or "variant"


def parse_variant(spec: str) -> tuple[str, pathlib.Path, list[str]]:
    label, _, rest = spec.partition("=")
    # A Windows path has a drive colon: the switches start after the last ':' that follows a path part.
    tree, switches = rest, ""
    m = re.match(r"^(.*?):(--.*)$", rest)
    if m:
        tree, switches = m.group(1), m.group(2)
    return label, pathlib.Path(tree).resolve(), [s for s in switches.split(",") if s]


def free_mb() -> int:
    out = subprocess.run(["powershell", "-NoProfile", "-Command",
                          "[int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1KB)"],
                         capture_output=True, text=True).stdout.strip()
    return int(out or 0)


def godot_memory(pid: int) -> tuple[int, int, int]:
    """(pid, working set MB, private MB) of the Godot process under the console wrapper `pid` (or itself)."""
    ps = (f"$c = Get-CimInstance Win32_Process -Filter 'ParentProcessId={pid}' | Where-Object {{ $_.Name -like 'Godot*' }} | Select-Object -First 1; "
          f"$id = if ($c) {{ $c.ProcessId }} else {{ {pid} }}; $p = Get-Process -Id $id -ErrorAction SilentlyContinue; "
          "if ($p) { '{0} {1} {2}' -f $p.Id, [int]($p.WorkingSet64/1MB), [int]($p.PrivateMemorySize64/1MB) }")
    out = subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True, text=True).stdout.split()
    return (int(out[0]), int(out[1]), int(out[2])) if len(out) == 3 else (0, 0, 0)


def run_variant(label, tree, switches, out_dir, args, port) -> dict:
    out_dir.mkdir(parents=True, exist_ok=True)
    if free_mb() < args.min_free_mb:
        raise SystemExit(f"free RAM under {args.min_free_mb} MB: not starting {label}")
    save = pathlib.Path(tempfile.mkdtemp(prefix="mem-ab-")) / "save.zip"
    shutil.copyfile(args.save, save)
    srv = scratch_server.ScratchServer(save_path=save, udp_port=port, game_port=port + 5, rcon_port=port + 6,
                                       mod_dir=tree / "mod" / "factorio-3d-bridge")
    rows, peak = [], 0
    proc = None
    try:
        srv.start(wait_timeout=120)
        addons = ",".join(str(tree / "addons-src" / a) for a in ADDONS if (tree / "addons-src" / a).is_dir())
        cmd = [GODOT, "--audio-driver", "Dummy"] + ([] if args.window else ["--headless"]) + [
            "--path", str(tree / "client"), "--log-file", str((out_dir / "godot.log").resolve()), "--",
            f"--factorio-port={port}", f"--port={port + 1}", f"--settings-file={(out_dir / 'settings.cfg').resolve()}",
            f"--addons={addons}", "--mem-log", f"--quit-probe={args.minutes * 60:.0f}"] + switches
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                creationflags=getattr(subprocess, "BELOW_NORMAL_PRIORITY_CLASS", 0))
        t0 = time.time()
        while proc.poll() is None:
            t = time.time() - t0
            _, ws, priv = godot_memory(proc.pid)
            rows.append((int(t), ws, priv))
            peak = max(peak, ws)
            if free_mb() < args.stop_free_mb or t > args.minutes * 60 + 120:
                print(f"  {label}: stopped (free RAM low or overtime)")
                break
            time.sleep(10)
    finally:
        if proc is not None and proc.poll() is None:
            gpid, _, _ = godot_memory(proc.pid)
            if gpid and gpid != proc.pid:
                subprocess.run(["taskkill", "/PID", str(gpid), "/F"], capture_output=True)
            proc.kill()
        srv.stop()
        srv.cleanup()
        shutil.rmtree(save.parent, ignore_errors=True)
    (out_dir / "rss.tsv").write_text("t_s\tws_mb\tpriv_mb\n" + "".join(f"{a}\t{b}\t{c}\n" for a, b, c in rows))
    mem = None
    log = out_dir / "godot.log"
    if log.exists():
        for line in log.read_text(encoding="utf-8", errors="replace").splitlines():
            m = MEM_RE.search(line)
            if m:
                mem = [int(x) for x in m.groups()]

    def at(sec):
        near = [r for r in rows if r[0] <= sec]
        return near[-1][1] if near else 0

    return {"label": label, "ws30": at(30), "ws60": at(60), "ws_end": rows[-1][1] if rows else 0, "peak": peak,
            "static": mem[1] if mem else None, "video": mem[2] if mem else None,
            "pipes": sum(mem[5:]) if mem else None, "switches": " ".join(switches)}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--variant", action="append", required=True, help="label=<checkout>[:--switch,--switch]")
    ap.add_argument("--minutes", type=float, default=3.0)
    ap.add_argument("--window", action="store_true", help="a real renderer (opens a window)")
    ap.add_argument("--save", default=str(pathlib.Path(os.environ.get("APPDATA", "")) / "Factorio" / "saves" / "Zenith Test.zip"))
    ap.add_argument("--out", default=str(TOOLS.parent / "art-src" / "bench" / "mem-ab"))
    ap.add_argument("--port", type=int, default=36900)
    ap.add_argument("--min-free-mb", type=int, default=8192)
    ap.add_argument("--stop-free-mb", type=int, default=3072)
    args = ap.parse_args()
    out = pathlib.Path(args.out)
    results = []
    for i, spec in enumerate(args.variant):
        label, tree, switches = parse_variant(spec)
        print(f"{label}: {tree} {' '.join(switches)}", flush=True)
        r = run_variant(label, tree, switches, out / f"{i + 1}-{slug(label)}", args, args.port + 10 * i)
        print("  ", r, flush=True)
        results.append(r)
    lines = [f"Client memory ({'window' if args.window else 'headless'}, {args.minutes:g} min, MB)", "",
             "| variant | RSS 30 s | RSS 60 s | RSS end | peak | static | video | pipelines | switches |",
             "|---|---|---|---|---|---|---|---|---|"]
    for r in results:
        lines.append(f"| {r['label']} | {r['ws30']} | {r['ws60']} | {r['ws_end']} | {r['peak']} | {r['static']} | {r['video']} | {r['pipes']} | {r['switches']} |")
    out.mkdir(parents=True, exist_ok=True)
    (out / "table.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
