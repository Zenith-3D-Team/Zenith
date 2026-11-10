"""What playing through your own Factorio window (hybrid single-player) costs, against a headless
server, with the same test on the same build (this checkout):

    python tools/bench/hybrid_cost.py [--runs 2] [--scenario stand|laps]

Three ways, taking turns, each on a fresh copy of the save:
  - server:    a headless server, as Zenith's menu starts one;
  - hybrid:    single-player in a Factorio window (its own config and mods folder: only the bridge
               and Factorio's own mods), Zenith connected to it, Factorio's window left open;
  - minimised: the same with Factorio's window minimised, as Ctrl+F9 leaves it.

Measured as compare_builds.py does: Zenith's frames, the game's speed (from the frames' server
ticks), and the bridge's time per tick (the stutter probe asks for /f3d-profile trace through the
bridge's console, so single-player needs no RCON).

Steam's Factorio only takes its own --config when started with a steam_appid.txt beside
factorio.exe: the script adds one for the run and removes it after (FACTORIO=<install folder> for another
install). Ports 36130-36131 (hybrid) and 36146-36149 (server). Results in art-src/bench/hybrid/.
"""
import argparse
import json
import os
import pathlib
import shutil
import statistics
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import compare_builds as cb  # noqa: E402

sys.path.append(str(ROOT / "tools"))
import factorio_install  # noqa: E402

FACTORIO_EXE = pathlib.Path(factorio_install.exe())
TRACE = {"stand": 1500, "laps": 3600}
MINIMISE = ("Add-Type -Name W -Namespace Z -MemberDefinition '[DllImport(\"user32.dll\")] public static extern bool "
            "ShowWindow(System.IntPtr h, int c);'; Get-Process factorio -ErrorAction SilentlyContinue | "
            "Where-Object { $_.Id -eq %d -and $_.MainWindowHandle -ne 0 } | "
            "ForEach-Object { [Z.W]::ShowWindow($_.MainWindowHandle, 6) | Out-Null }")


def client(args, out):
    godot = os.environ.get("GODOT", "godot")
    return subprocess.Popen([godot, "--audio-driver", "Dummy", "--path", str(ROOT / "client"), "--"] + args,
                            stdout=out, stderr=subprocess.STDOUT)


def hybrid_folder(work):
    """Factorio's own config, mods (the bridge and the mod list the server uses) and write-data."""
    h = work / "factorio"
    (h / "mods").mkdir(parents=True, exist_ok=True)
    (h / "data").mkdir(exist_ok=True)
    read_data = FACTORIO_EXE.parent.parent.parent / "data"
    (h / "config.ini").write_text(f"[path]\nread-data={read_data}\nwrite-data={h / 'data'}\n[graphics]\nfull-screen=false\n", encoding="ascii")
    bridge = h / "mods" / "factorio-3d-bridge"
    if bridge.exists():
        shutil.rmtree(bridge)
    shutil.copytree(ROOT / "mod" / "factorio-3d-bridge", bridge)
    for f in ("mod-list.json", "mod-settings.dat"):
        src = ROOT / "server" / "data" / "mods" / f
        if src.exists():
            shutil.copyfile(src, h / "mods" / f)
    return h


def stop_factorio(h):
    marker = str(h).replace("'", "''")
    ps = ("Get-CimInstance Win32_Process -Filter \"Name='factorio.exe'\" | "
          f"Where-Object {{ $_.CommandLine -like '*{marker}*' }} | ForEach-Object {{ Stop-Process -Id $_.ProcessId -Force }}")
    subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True)
    time.sleep(3)


def run_hybrid(h, scenario, run_dir, minimise):
    run_dir.mkdir(parents=True, exist_ok=True)
    save = run_dir / "save.zip"
    shutil.copyfile(cb.SAVE, save)
    stop_factorio(h)
    log = h / "data" / "factorio-current.log"
    if log.exists():
        log.unlink()
    game = subprocess.Popen([str(FACTORIO_EXE), "--config", str(h / "config.ini"), "--mod-directory", str(h / "mods"),
                             "--load-game", str(save), "--enable-lua-udp", "36130"],
                            cwd=str(FACTORIO_EXE.parent))  # from its bin folder, or Steam's ignores --config
    deadline = time.time() + 240
    while time.time() < deadline and not (log.exists() and "Opening socket" in log.read_text(errors="ignore")):
        time.sleep(2)
    time.sleep(40)  # the map loading in the window
    probe = run_dir / "probe.json"
    args = ["--factorio-port=36130", "--port=36131", "--gpu-profile", f"--stutter-probe={probe}@{cb.ROUTE[scenario]}",
            f"--probe-trace={TRACE[scenario]}"]
    with open(run_dir / "client.log", "w", encoding="utf-8", errors="ignore") as out:
        c = client(args, out)
        if minimise:
            time.sleep(20)
            subprocess.run(["powershell", "-NoProfile", "-Command", MINIMISE % game.pid], capture_output=True)
        try:
            c.wait(timeout=cb.CLIENT_TIMEOUT)
        except subprocess.TimeoutExpired:
            c.kill()
    time.sleep(5)
    stop_factorio(h)
    game.wait(timeout=30)
    if not log.exists():
        raise RuntimeError(f"Factorio wrote no log in {log.parent}: it didn't start with this config")
    shutil.copyfile(log, run_dir / "factorio.log")
    save.unlink()
    return measure(run_dir)


def measure(run_dir):
    out = cb.measure(run_dir)
    probe = run_dir / "probe.json"
    if probe.exists():
        frames = json.loads(probe.read_text())["frames"]
        ticks = [r[11] for r in frames if len(r) > 11 and r[11]]
        secs = sum(r[0] for r in frames) / 1000.0
        if len(ticks) > 1 and secs > 0:
            out["ups_client"] = (ticks[-1] - ticks[0]) / secs
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--runs", type=int, default=2)
    ap.add_argument("--scenario", default="stand", choices=["stand", "laps"])
    a = ap.parse_args()
    work = ROOT / "art-src" / "bench" / "hybrid"
    work.mkdir(parents=True, exist_ok=True)
    appid = FACTORIO_EXE.parent / "steam_appid.txt"
    added = not appid.exists()
    if added:
        appid.write_text("427520")
    results = {"server": [], "hybrid": [], "minimised": []}
    try:
        h = hybrid_folder(work)
        server = cb.Build("checkout", ROOT)
        for i in range(a.runs):
            for way in results:
                cb.log(f"{a.scenario} run {i + 1}: {way}")
                d = work / a.scenario / f"{way}-{i + 1}"
                if way == "server":
                    r = cb.run_once(server, a.scenario, d, (36146, 36147, 36148, 36149))
                    r.update({k: v for k, v in measure(d).items() if k == "ups_client"})
                else:
                    r = run_hybrid(h, a.scenario, d, way == "minimised")
                cb.log("  ", json.dumps({k: round(v, 2) if isinstance(v, float) else v for k, v in r.items()}))
                results[way].append(r)
                (work / f"results-{a.scenario}.json").write_text(json.dumps(results, indent=1))
    finally:
        if added and appid.exists():
            appid.unlink()
            cb.log("steam_appid.txt removed")
    rows = [("frame_p50", "Frame time, middle (ms)"), ("frame_p99", "Frame time, slowest 1% (ms)"),
            ("frames_over_16", "Frames over 16.7 ms"), ("gpu_p50", "GPU per frame, middle (ms)"),
            ("ups_client", "Game speed (UPS)"), ("bridge_avg", "Bridge per tick (ms)"), ("bridge_p99", "Bridge, slowest 1% (ms)")]
    lines = [f"| {a.scenario} | Server | Hybrid | Hybrid, Factorio minimised |", "|---|---:|---:|---:|"]
    for key, name in rows:
        cells = []
        for way in results:
            v = [r[key] for r in results[way] if r.get(key) is not None]
            cells.append(f"{statistics.median(v):.1f}" if v else "-")
        lines.append(f"| {name} | " + " | ".join(cells) + " |")
    md = "\n".join(lines)
    (work / f"table-{a.scenario}.md").write_text(md, encoding="utf-8")
    print(md)


if __name__ == "__main__":
    main()
