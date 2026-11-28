#!/usr/bin/env python3
"""render_sync_check.py: does the client make the main thread wait for the render thread?

With "Render on a separate thread" (thread model 2) every RenderingServer call that returns something
(`Mesh.surface_get_arrays`, `Texture2D.get_image`, `get_instance_shader_parameter`, a MultiMesh's `buffer` or
`get_instance_*` read, ...) makes the main thread wait for the render thread's whole frame (10-15 ms;
art-src perf-rd-render). Two checks:

  --static (the default; check.py's fast suite): the scripts that had such reads (perf-w3-render, R1) keep
      them behind `--render-reads=old` (or the CPU-copy switches before it) or in load-time-only code marked
      "A renderer read". A new direct read in them fails.
  --run (check.py's godot suite): the mock's busy base on scratch ports, the client headless and muted on
      Godot's editor build (the console exe) with `--render-thread separate`, Alt-mode on, a belt in hand (its
      placement preview), an assembling machine's window with its 3D preview open, and the stutter probe's
      short walk. Godot's editor build prints "Call to <fn> causing RenderingServer synchronizations on every
      frame" when a blocking call repeats over more than 5 frames in a row (server_wrap_mt_common.h): any such
      line, or "can only be called from the render thread", fails. Headless still runs the (dummy) renderer
      on its own thread, so no window is needed. It catches per-frame reads only, not one now and then.
      APPDATA is moved into the run folder (the Zenith pack unpacks there, ~1.9 GB, kept for the next run;
      remove it with tools/safe_delete.py). Only the processes it starts are stopped.

  python tools/render_sync_check.py [--static] [--run [--godot <exe>] [--port 37320] [--keep-going]]
"""
from __future__ import annotations

import argparse
import os
import pathlib
import re
import subprocess
import sys
import time

REPO = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = REPO / "client" / "scripts"

# perf-w3-render's files (perf-rd-render plan R1): each blocking read in them is behind a switch or marked.
FILES = [
    "ui/factorio/model_preview.gd",
    "world/ghosts.gd",
    "world/pipe_covers.gd",
    "world/decoratives.gd",
    "world/sprite_standins.gd",
    "world/model_library.gd",
    "world/terrain_textures.gd",
    "world/chunk_view.gd",
]
BLOCKING = re.compile(
    r"\.get_image\(\)|get_faces\(|get_shader_uniform_list\(|get_instance_shader_parameter\(|"
    r"\.get_instance_(transform|color|custom_data)\(|get_layer_data\(|surface_get_arrays\(|"
    r":= *\w+\.buffer\s*$|multimesh_get_buffer|global_shader_parameter_get|material_get_param\("
)
# A read is allowed when one of these is on its line or the few lines before it: the old way behind
# --render-reads=old (RenderReads.old, ChunkView.lod_no_readback) or --lod-cpu-copy=off, or a load-time read
# marked "A renderer read" with its reason.
GUARDS = ("--render-reads=old", "RenderReads.old", "lod_no_readback", "lod_cpu_copy", "A renderer read")
LOOK_BACK = 8

SYNC_PATTERNS = ("causing RenderingServer synchronizations", "can only be called from the render thread")


def static_scan(files: list[str] | None = None) -> list[str]:
    """[file:line: text] of blocking reads with no guard."""
    bad = []
    for rel in files or FILES:
        path = SCRIPTS / rel
        lines = path.read_text(encoding="utf-8").splitlines()
        for i, line in enumerate(lines):
            code = line.split("#", 1)[0] if not line.lstrip().startswith("##") else ""
            if not BLOCKING.search(code):
                continue
            near = "\n".join(lines[max(0, i - LOOK_BACK):i + 1])
            if not any(g in near for g in GUARDS):
                bad.append(f"{rel}:{i + 1}: {line.strip()}")
    return bad


def free_mb() -> float:
    if os.name != "nt":
        return 1e9
    out = subprocess.run(["powershell", "-NoProfile", "-Command",
                          "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory"],
                         capture_output=True, text=True, creationflags=subprocess.CREATE_NO_WINDOW).stdout.strip()
    try:
        return int(out) / 1024
    except ValueError:
        return 0.0


def run_check(godot: str, port: int, out_dir: pathlib.Path, seconds: int, min_free_mb: float) -> int:
    if free_mb() < min_free_mb:
        print(f"render_sync_check: not run, free RAM {free_mb():.0f} MB under {min_free_mb:.0f}")
        return 0  # (a busy PC is no code fault: not a failure of the suite)
    out_dir.mkdir(parents=True, exist_ok=True)
    appdata = out_dir / "appdata"
    appdata.mkdir(exist_ok=True)
    cfg = out_dir / "settings.cfg"
    if cfg.exists():
        cfg.unlink()  # a fresh copy each run: the client saves Alt-mode and other toggles into it
    flags = (subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS) if os.name == "nt" else 0
    py = sys.executable
    mock_out = open(out_dir / "mock.out", "w")
    mock = subprocess.Popen([py, str(REPO / "tools" / "mock_server.py"), "--busy", "--port", str(port)],
                            stdout=mock_out, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, creationflags=flags,
                            cwd=str(REPO))
    (out_dir / "pids.txt").write_text(f"{mock.pid} mock\n")
    time.sleep(3)
    log = out_dir / "godot.log"
    cmd = [godot, "--headless", "--audio-driver", "Dummy", "--path", str(REPO / "client"), "--log-file", str(log),
           "--render-thread", "separate", "--",
           f"--factorio-port={port}", f"--port={port + 1}", f"--settings-file={cfg}",
           f"--stutter-probe={out_dir / 'probe.json'}@short", "--probe-warmup=12",
           "--alt-mode", "--ui-hold=transport-belt", "--open=assembling-machine-1"]
    env = dict(os.environ, APPDATA=str(appdata))
    out_path = out_dir / "godot.out"
    g_out = open(out_path, "w", encoding="utf-8", errors="replace")
    t0 = time.time()
    g = subprocess.Popen(cmd, stdout=g_out, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env,
                         creationflags=flags)
    with open(out_dir / "pids.txt", "a") as f:
        f.write(f"{g.pid} godot\n")
    stopped = ""
    try:
        while g.poll() is None:
            time.sleep(2)
            if time.time() - t0 > seconds:
                stopped = f"stopped after {seconds} s"
                break
            if free_mb() < 2000:
                stopped = "stopped: free RAM under 2000 MB"
                break
    finally:
        if g.poll() is None:
            g.kill()
        if mock.poll() is None:
            mock.kill()
        g_out.close()
        mock_out.close()
    text = out_path.read_text(encoding="utf-8", errors="replace")
    hits = [ln for ln in text.splitlines() if any(p in ln for p in SYNC_PATTERNS)]
    errors = sum(1 for ln in text.splitlines() if ln.startswith("SCRIPT ERROR"))
    joined = "joined" if "probe" in text.lower() or (out_dir / "probe.json").exists() else "probe output missing"
    print(f"render_sync_check: godot exit {g.returncode}, {time.time() - t0:.0f} s, {joined}, "
          f"{len(hits)} sync warnings, {errors} script errors{', ' + stopped if stopped else ''}")
    for h in hits:
        print("  " + h.strip())
    if not (out_dir / "probe.json").exists():
        print("  the stutter probe wrote nothing: the client didn't get through the walk (see godot.out)")
        return 1
    return 1 if hits else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--static", action="store_true", help="scan the scripts (the default with no --run)")
    ap.add_argument("--run", action="store_true", help="run the client headless with the render thread")
    ap.add_argument("--godot", help="Godot's editor console build (default: check.py's)")
    ap.add_argument("--port", type=int, default=37320)
    ap.add_argument("--seconds", type=int, default=300)
    ap.add_argument("--min-free-mb", type=float, default=4500.0)
    ap.add_argument("--out", help="run folder (default art-src/check-logs/render_sync)")
    args = ap.parse_args()
    rc = 0
    if args.static or not args.run:
        bad = static_scan()
        print(f"render_sync_check --static: {len(FILES)} files, {len(bad)} unguarded renderer reads")
        for b in bad:
            print("  " + b)
        rc = 1 if bad else 0
    if args.run:
        sys.path.insert(0, str(REPO / "tools"))
        from check import godot_path, main_checkout  # noqa: E402
        godot = args.godot or godot_path()
        if not godot:
            print("render_sync_check: Godot not found (--godot or GODOT)")
            return 2
        out = pathlib.Path(args.out) if args.out else main_checkout() / "art-src" / "check-logs" / "render_sync"
        rc = max(rc, run_check(godot, args.port, out.resolve(), args.seconds, args.min_free_mb))
    return rc


if __name__ == "__main__":
    sys.exit(main())
