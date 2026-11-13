"""The same test batch on two builds of Zenith, for a before and after table on every update.

    python tools/bench/compare_builds.py --before v0.1.2 --after v0.1.3
    python tools/bench/compare_builds.py --before v0.1.3 --after .        # this checkout against a release

A build is a release tag (its Windows download is fetched from GitHub with `gh`, from --repo), a download's zip,
an unpacked download, or a checkout (`.`: the editor runs its client, its server script its mod).
Each build plays its own client against its own bridge mod on a headless server.

The batch, run on a fresh copy of the save each time, the builds taking turns (before, after,
before, after...) so a busy moment of the PC lands on both:

  - laps: the windowed client runs laps round the busy belts (the stutter probe's `fast` route),
    the bridge traced for TRACE_TICKS ticks from TRACE_AT seconds in;
  - stand: it stands where it joined (`stand`), traced the same way.

Measured: the client's frames (p50, p99, worst, frames over 16.7 and 33 ms, GPU p50), the bridge
per tick (average, p99, worst, ticks over 16.7 ms), belt items' share, and the game's speed (UPS,
from the trace's ticks against the log's clock). The table gives each figure's median over the
runs. Settings are the client's own (user://settings.cfg), the same for both builds.

Ports: UDP 36146, game 36147, RCON 36148, client 36149 by default (--port moves all four); never
the owner's own games' ports. Only the server this starts is stopped. Results go to
art-src/bench/<before>-vs-<after>/ (results.json, table.md, each run's files).
"""
import argparse
import json
import os
import pathlib
import re
import shutil
import socket
import statistics
import subprocess
import sys
import time
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import rcon  # noqa: E402
from percentile import pct  # noqa: E402

REPO = os.environ.get("ZENITH_RELEASES", "Zenith-3D-Team/Zenith")  # --repo, or this, for a tag's download
GODOT = os.environ.get("GODOT", "godot")  # for a checkout: Godot 4.4+ on PATH, or $GODOT
SAVE = pathlib.Path(os.environ.get("APPDATA", "")) / "Factorio" / "saves" / "Zenith Test.zip"
TRACE_AT = 35.0      # seconds after the client starts: joined, the route under way
TRACE_TICKS = {"laps": 3600, "stand": 1500}
ROUTE = {"laps": "fast", "stand": "stand"}
CLIENT_TIMEOUT = 480
TRACE = ("/c __factorio-3d-bridge__ local p = package.loaded['__factorio-3d-bridge__/scripts/profile.lua'] "
         "or require('scripts.profile') rcon.print(p.trace(%d))")


def log(*a):
    print(*a, flush=True)


# --- builds ---------------------------------------------------------------------------------------

class Build:
    def __init__(self, label, folder):
        self.label = label
        self.folder = folder
        self.exe = next(iter(folder.glob("Zenith.exe")), None)
        self.server_dir = folder / "server"
        self.data = self.server_dir / "data"

    def client_cmd(self, args):
        if self.exe:
            return [str(self.exe), "--audio-driver", "Dummy", "--"] + args
        return [GODOT, "--audio-driver", "Dummy", "--path", str(self.folder / "client"), "--"] + args


def resolve(spec, work, repo):
    """A tag, a zip, a download folder or a checkout -> a Build in a folder of its own."""
    p = pathlib.Path(spec)
    if p.is_dir() and ((p / "Zenith.exe").exists() or (p / "client" / "project.godot").exists()):
        return Build(p.resolve().name if spec != "." else "checkout", p.resolve())
    if p.suffix == ".zip" and p.exists():
        zip_path, label = p, p.stem
    else:
        label = spec
        dl = work / "downloads"
        dl.mkdir(parents=True, exist_ok=True)
        version = spec.lstrip("v")
        zip_path = dl / f"Zenith-{version}-windows.zip"
        if not zip_path.exists():
            log(f"fetching {spec}'s Windows download")
            subprocess.run(["gh", "release", "download", spec, "-R", repo, "-p", zip_path.name, "-D", str(dl), "--clobber"], check=True)
    dest = work / "builds" / label
    if not dest.exists():
        with zipfile.ZipFile(zip_path) as z:
            z.extractall(dest)
    inner = next((d for d in dest.iterdir() if (d / "Zenith.exe").exists()), dest)
    return Build(label, inner)


# --- one run --------------------------------------------------------------------------------------

def port_free(port):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        try:
            s.bind(("127.0.0.1", port))
            return True
        except OSError:
            return False


def stop_server(build, ports):
    """/quit over RCON, then only a factorio.exe whose command line has this build's data folder."""
    try:
        rcon.run("/quit", port=ports[2], password=(build.data / "rcon-password.txt").read_text().strip(), timeout=3)
    except Exception:
        pass
    time.sleep(4)
    marker = str(build.data).replace("'", "''")
    ps = ("Get-CimInstance Win32_Process -Filter \"Name='factorio.exe'\" | "
          f"Where-Object {{ $_.CommandLine -like '*{marker}*' }} | ForEach-Object {{ Stop-Process -Id $_.ProcessId -Force }}")
    subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True)
    time.sleep(2)


def start_server(build, save, ports):
    log_file = build.data / "factorio-current.log"
    if log_file.exists():
        log_file.unlink()
    cmd = ["powershell", "-ExecutionPolicy", "Bypass", "-File", str(build.server_dir / "run-server.ps1"), "-Save", str(save),
           "-UdpPort", str(ports[0]), "-GamePort", str(ports[1]), "-RconPort", str(ports[2])]
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + 180
    while time.time() < deadline:
        if log_file.exists() and "Opening socket" in log_file.read_text(errors="ignore") \
                and "Starting RCON" in log_file.read_text(errors="ignore"):
            time.sleep(3)
            return proc
        time.sleep(2)
    raise RuntimeError(f"{build.label}: the server didn't start (see {log_file})")


def run_once(build, scenario, run_dir, ports):
    run_dir.mkdir(parents=True, exist_ok=True)
    save = run_dir / "save.zip"
    shutil.copyfile(SAVE, save)
    stop_server(build, ports)
    start_server(build, save, ports)
    probe = run_dir / "probe.json"
    args = [f"--factorio-port={ports[0]}", f"--port={ports[3]}", "--gpu-profile", f"--stutter-probe={probe}@{ROUTE[scenario]}"]
    started = time.time()
    with open(run_dir / "client.log", "w", encoding="utf-8", errors="ignore") as out:
        client = subprocess.Popen(build.client_cmd(args), stdout=out, stderr=subprocess.STDOUT)
        time.sleep(TRACE_AT)
        try:
            log("   trace:", rcon.run(TRACE % TRACE_TICKS[scenario], port=ports[2],
                                     password=(build.data / "rcon-password.txt").read_text().strip()).strip())
        except Exception as e:
            log("   trace failed:", e)
        try:
            client.wait(timeout=CLIENT_TIMEOUT)
        except subprocess.TimeoutExpired:
            client.kill()
            log("   the client ran past its time and was stopped")
    # The trace's last ticks are written as they happen (at 50 UPS or better): time for it to end.
    time.sleep(max(0.0, started + TRACE_AT + TRACE_TICKS[scenario] / 50.0 + 5 - time.time()))
    stop_server(build, ports)
    shutil.copyfile(build.data / "factorio-current.log", run_dir / "factorio.log")
    save.unlink()
    return measure(run_dir)


# --- measuring ------------------------------------------------------------------------------------

def measure(run_dir):
    out = {}
    probe = run_dir / "probe.json"
    if probe.exists():
        walk = json.loads(probe.read_text())["summary"]["walk"]
        out.update({"frame_p50": walk["p50"], "frame_p99": walk["p99"], "frame_worst": walk["worst"],
                    "frames_over_16": walk["over16"], "frames_over_33": walk["over33"], "frames": walk["frames"],
                    "gpu_p50": walk["gpu_p50"]})
    ticks, stamps = {}, {}
    for line in (run_dir / "factorio.log").read_text(errors="ignore").splitlines():
        m = re.match(r"\s*([\d.]+) .*f3dtrace (\d+) (\S+) Duration: ([\d.]+) ?ms", line)
        if m:
            t = int(m.group(2))
            ticks.setdefault(t, {})[m.group(3)] = float(m.group(4))
            stamps[t] = float(m.group(1))
    # Only the ticks the client was connected for (the bridge ran its modules).
    served = [t for t, v in ticks.items() if "belt_items" in v or "movers" in v]
    if served:
        bridge = [ticks[t].get("bridge", 0.0) for t in served]
        belts = [ticks[t].get("belt_items", 0.0) for t in served]
        span = stamps[max(served)] - stamps[min(served)]
        out.update({"bridge_avg": statistics.fmean(bridge), "bridge_p99": pct(bridge, 0.99), "bridge_worst": max(bridge),
                    "bridge_over_16": sum(b > 16.7 for b in bridge), "bridge_ticks": len(bridge),
                    "belts_avg": statistics.fmean(belts), "belts_p99": pct(belts, 0.99),
                    "ups": (max(served) - min(served)) / span if span > 0 else None})
    return out


FIGURES = [
    ("frame_p50", "Frame time, middle", "ms", False), ("frame_p99", "Frame time, slowest 1%", "ms", False),
    ("frame_worst", "Worst frame", "ms", False), ("frames_over_16", "Frames over 16.7 ms", "", False),
    ("frames_over_33", "Frames over 33 ms", "", False),
    ("ups", "Game speed", "UPS", True),
    ("bridge_avg", "Zenith's bridge, per tick", "ms", False), ("bridge_p99", "Bridge, slowest 1% of ticks", "ms", False),
    ("bridge_worst", "Bridge, worst tick", "ms", False), ("bridge_over_16", "Bridge ticks over 16.7 ms", "", False),
    ("belts_avg", "Reading belt items, per tick", "ms", False),
]


def table(results, before, after):
    lines = []
    for scenario in results:
        lines += [f"### {'Running laps round the busy belts' if scenario == 'laps' else 'Standing at the busy belts'}", "",
                  f"| | {before} | {after} | Change |", "|---|---:|---:|---:|"]
        for key, name, unit, more_is_better in FIGURES:
            a = [r[key] for r in results[scenario][before] if r.get(key) is not None]
            b = [r[key] for r in results[scenario][after] if r.get(key) is not None]
            if not a or not b:
                continue
            ma, mb = statistics.median(a), statistics.median(b)
            fmt = (lambda v: f"{v:.1f} {unit}".strip()) if unit else (lambda v: f"{v:.0f}")
            if ma == 0:
                change = "the same" if mb == 0 else "new"
            else:
                d = (mb - ma) / ma * 100
                better = d > 0 if more_is_better else d < 0
                change = "the same" if abs(d) < 2 else f"{'**' if abs(d) >= 10 and better else ''}{abs(d):.0f}% {'more' if d > 0 else 'less'}{'**' if abs(d) >= 10 and better else ''}"
            lines.append(f"| {name} | {fmt(ma)} | {fmt(mb)} | {change} |")
        n = len(results[scenario][before])
        lines += ["", f"Median of {n} runs each, the builds taking turns.", ""]
    return "\n".join(lines)


def main():
    global SAVE
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--before", required=True)
    ap.add_argument("--after", required=True)
    ap.add_argument("--runs", type=int, default=2)
    ap.add_argument("--scenarios", default="laps,stand")
    ap.add_argument("--port", type=int, default=36146, help="UDP; the game, RCON and client ports follow it")
    ap.add_argument("--out", default=None)
    ap.add_argument("--repo", default=REPO, help="the GitHub repository a tag's download comes from")
    ap.add_argument("--save", default=str(SAVE), help="the save each run plays a fresh copy of (default: Zenith Test)")
    a = ap.parse_args()
    SAVE = pathlib.Path(a.save)
    ports = (a.port, a.port + 1, a.port + 2, a.port + 3)
    for p in (ports[0], ports[3]):
        if not port_free(p):
            sys.exit(f"port {p} is in use")
    out = pathlib.Path(a.out) if a.out else ROOT / "art-src" / "bench" / f"{a.before}-vs-{a.after}".replace("/", "_")
    out.mkdir(parents=True, exist_ok=True)
    builds = [resolve(a.before, out, a.repo), resolve(a.after, out, a.repo)]
    labels = [a.before, a.after]
    results = {}
    for scenario in a.scenarios.split(","):
        results[scenario] = {labels[0]: [], labels[1]: []}
        for i in range(a.runs):
            for build, label in zip(builds, labels):
                log(f"{scenario} run {i + 1}: {label}")
                r = run_once(build, scenario, out / scenario / f"{label}-{i + 1}".replace("/", "_"), ports)
                log("  ", json.dumps({k: round(v, 2) if isinstance(v, float) else v for k, v in r.items()}))
                results[scenario][label].append(r)
                (out / "results.json").write_text(json.dumps(results, indent=1))
    md = table(results, labels[0], labels[1])
    (out / "table.md").write_text(md, encoding="utf-8")
    print(md)


if __name__ == "__main__":
    main()
