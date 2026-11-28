#!/usr/bin/env python3
"""Long stress soak: the real client in a window (muted) against real headless Factorio, phase after phase,
for hours, recording every frame, memory and the server's UPS (Windows only; test tool, no game code).

    python tools/bench/soak/soak.py --out <dir> --hours 4 --addons <folder of add-on zips>
        [--plan default:main,low:main,...] [--save main=<zip> --save ep16=<zip>] [--godot <console exe>]
        [--dry-run]

Each session copies its save into <out>/saves, starts server/run-server.ps1 on it (own ports), the client
with the soak driver add-on (tools/bench/soak/driver) playing the phases written by steps_for() and
--spike-log=25 (user://debug/spikes.log: what each slow frame did), tools/profile_log.py for UPS and the
bridge's per-module ms, and samples the Godot and Factorio processes' memory every 30 s (working set,
private bytes; dedicated GPU memory every 60 s). Free RAM is checked every 5 s: under --ram-stop GB the
session is stopped at once; a session starts only with --ram-start GB free. Stops only what it started.
Results: <out>/sessions/<n>-<preset>-<save>/{frames.jsonl, proc.jsonl, ups.jsonl, godot.log, spikes.log}
and <out>/soak.jsonl (one line per session). tools/bench/soak/analyze.py writes the summary.
"""

import argparse
import ctypes
import ctypes.wintypes as wt
import json
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
TOOLS = os.path.join(REPO, "tools")
SERVER_LOG = os.path.join(REPO, "server", "data", "factorio-current.log")

PRESET_KEYS = {  # client/scripts/menu/settings.gd PRESETS (0.3.0)
    "low": {"shadows": '"low"', "ssao": "false", "lod_quality": '"low"', "view_radius": "5", "entity_radius": "96",
            "belt_updates": "2000", "belt_distance": "64", "decorative_distance": "96", "decorative_density": "0.5",
            "grass_3d": '"off"', "clouds": "false", "contact_shading": "true", "god_rays": "0.0"},
    "medium": {"shadows": '"medium"', "ssao": "false", "lod_quality": '"medium"', "view_radius": "7", "entity_radius": "128",
               "belt_updates": "4000", "belt_distance": "96", "decorative_distance": "128", "decorative_density": "0.75",
               "grass_3d": '"short"', "clouds": "true", "contact_shading": "true", "god_rays": "0.25"},
    "high": {"shadows": '"high"', "ssao": "true", "lod_quality": '"medium"', "view_radius": "4", "entity_radius": "128",
             "belt_updates": "-1", "belt_distance": "128", "decorative_distance": "192", "decorative_density": "1.0",
             "grass_3d": '"normal"', "clouds": "true", "contact_shading": "true", "god_rays": "0.5"},
    "ultra": {"shadows": '"ultra"', "ssao": "true", "lod_quality": '"high"', "view_radius": "14", "entity_radius": "256",
              "belt_updates": "-1", "belt_distance": "320", "decorative_distance": "256", "decorative_density": "1.0",
              "grass_3d": '"far"', "clouds": "true", "contact_shading": "true", "god_rays": "0.5"},
}

# ---- Windows process helpers (no psutil) ----
k32 = ctypes.WinDLL("kernel32", use_last_error=True)
psapi = ctypes.WinDLL("psapi", use_last_error=True)


class MEMSTAT(ctypes.Structure):
    _fields_ = [("dwLength", wt.DWORD), ("dwMemoryLoad", wt.DWORD), ("ullTotalPhys", ctypes.c_ulonglong),
                ("ullAvailPhys", ctypes.c_ulonglong), ("ullTotalPageFile", ctypes.c_ulonglong),
                ("ullAvailPageFile", ctypes.c_ulonglong), ("ullTotalVirtual", ctypes.c_ulonglong),
                ("ullAvailVirtual", ctypes.c_ulonglong), ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]


class PMC(ctypes.Structure):
    _fields_ = [("cb", wt.DWORD), ("PageFaultCount", wt.DWORD), ("PeakWorkingSetSize", ctypes.c_size_t),
                ("WorkingSetSize", ctypes.c_size_t), ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPagedPoolUsage", ctypes.c_size_t), ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                ("QuotaNonPagedPoolUsage", ctypes.c_size_t), ("PagefileUsage", ctypes.c_size_t),
                ("PeakPagefileUsage", ctypes.c_size_t), ("PrivateUsage", ctypes.c_size_t)]


class PE32(ctypes.Structure):
    _fields_ = [("dwSize", wt.DWORD), ("cntUsage", wt.DWORD), ("th32ProcessID", wt.DWORD),
                ("th32DefaultHeapID", ctypes.c_void_p), ("th32ModuleID", wt.DWORD), ("cntThreads", wt.DWORD),
                ("th32ParentProcessID", wt.DWORD), ("pcPriClassBase", ctypes.c_long), ("dwFlags", wt.DWORD),
                ("szExeFile", ctypes.c_wchar * 260)]


k32.OpenProcess.restype = wt.HANDLE
k32.CreateToolhelp32Snapshot.restype = wt.HANDLE


def free_gb():
    m = MEMSTAT()
    m.dwLength = ctypes.sizeof(MEMSTAT)
    k32.GlobalMemoryStatusEx(ctypes.byref(m))
    return m.ullAvailPhys / 2 ** 30


def processes():
    """[(pid, parent, exe)]"""
    snap = k32.CreateToolhelp32Snapshot(2, 0)
    out = []
    e = PE32()
    e.dwSize = ctypes.sizeof(PE32)
    ok = k32.Process32FirstW(snap, ctypes.byref(e))
    while ok:
        out.append((e.th32ProcessID, e.th32ParentProcessID, e.szExeFile))
        ok = k32.Process32NextW(snap, ctypes.byref(e))
    k32.CloseHandle(snap)
    return out


def descendants(pid):
    procs = processes()
    found, todo = [], [pid]
    while todo:
        p = todo.pop()
        for c, parent, exe in procs:
            if parent == p and c not in [f[0] for f in found]:
                found.append((c, exe))
                todo.append(c)
    return found


def mem_of(pid):
    h = k32.OpenProcess(0x1000, False, pid)
    if not h:
        return None
    c = PMC()
    c.cb = ctypes.sizeof(PMC)
    ok = psapi.GetProcessMemoryInfo(h, ctypes.byref(c), c.cb)
    k32.CloseHandle(h)
    if not ok:
        return None
    return {"ws_mb": round(c.WorkingSetSize / 2 ** 20, 1), "priv_mb": round(c.PrivateUsage / 2 ** 20, 1),
            "peak_ws_mb": round(c.PeakWorkingSetSize / 2 ** 20, 1)}


def gpu_mem(pids):
    """Dedicated GPU memory (MB) per pid from Windows' GPU Process Memory counters."""
    if not pids:
        return {}
    paths = ",".join("'\\GPU Process Memory(pid_%d_*)\\Dedicated Usage'" % p for p in pids)
    cmd = ("$r=@{}; try { (Get-Counter -Counter @(%s) -ErrorAction SilentlyContinue).CounterSamples | %% { "
           "if ($_.InstanceName -match 'pid_(\\d+)_') { $k=$matches[1]; $r[$k] = [double]$r[$k] + $_.CookedValue } } } catch {}; "
           "$r.GetEnumerator() | %% { '{0} {1}' -f $_.Key, [math]::Round($_.Value/1MB,1) }") % paths
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-Command", cmd], capture_output=True, text=True, timeout=40).stdout
    except subprocess.TimeoutExpired:
        return {}
    res = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2:
            res[int(parts[0])] = float(parts[1])
    return res


def kill_tree(pid):
    if pid:
        subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True)


def read_shared(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


# ---- Steps ----
def steps_for(n, idle_min, first_in_save, scale=1.0, reps=1):
    """The phases of one session (the driver's step list); `scale` shortens the waits (a trial run)."""
    s = [{"do": "wait_game", "timeout": 300, "chunks": 9, "settle": 25}]

    rep_tag = [""]

    def phase(name):
        s.append({"do": "phase", "name": name + rep_tag[0]})

    def wait(t):
        s.append({"do": "wait", "s": round(t * scale, 2)})

    for rep in range(1, reps + 1):
        rep_tag[0] = "@%d" % rep if reps > 1 else ""
        phase("stand")
        s.append({"do": "camera", "dist": 30})
        wait(120)
        phase("pan")
        for _ in range(3):
            s.append({"do": "spin", "deg": 120, "s": 3.0})
            wait(1)
        for k in ["D", "S", "A", "W", "D", "A"]:
            s.append({"do": "key", "key": k, "hold": 6.0})
        wait(3)
        phase("zoom")
        for _ in range(3):
            s.append({"do": "zoom", "dist": "max", "hold": 6})
            s.append({"do": "zoom", "dist": 20, "hold": 5})
        s.append({"do": "camera", "dist": 30})
        wait(3)
        phase("map")
        for _ in range(4):
            s.append({"do": "key", "key": "M"})
            wait(5)
            s.append({"do": "key", "key": "M"})
            wait(3)
        phase("alt")
        for _ in range(6):
            s.append({"do": "key", "key": "Alt"})
            wait(5)
        phase("views")
        for k in ["F5", "F5", "F6", "F6", "F7", "F7"]:
            s.append({"do": "key", "key": k})
            wait(12)
        phase("ui")
        for k in ["E", "T", "P"]:
            s.append({"do": "key", "key": k})
            wait(6)
            s.append({"do": "key", "key": "Escape"})
            wait(3)
        phase("drive")
        s.append({"do": "lua", "code": "local p=storage.f3d and storage.f3d.puppet; if p and p.valid then "
                  "storage.soak_home=p.position; local c=p.surface.find_entities_filtered{type='car',position=p.position,radius=3000,limit=1}[1]; "
                  "if c then p.teleport(c.position); c.set_driver(p); rcon.print('car') else rcon.print('no car') end end"})
        wait(3)
        for k in ["W", "D", "W", "S"]:
            s.append({"do": "key", "key": k, "hold": 4.0})
        s.append({"do": "lua", "code": "local p=storage.f3d.puppet; if p.vehicle then p.vehicle.set_driver(nil) end; "
                  "if storage.soak_home then p.teleport(storage.soak_home) end"})
        wait(8)
        phase("combat")
        # Each session plays a fresh copy of the save: the defended wall (which also makes the character
        # indestructible) is built in every one, and the wave's leftovers cleared after it, else enemies left
        # at the spawn kill the character again and again (a new welcome every respawn).
        if rep == 1:
            s.append({"do": "py", "args": ["attack_wave.py", "--rcon-port", "{RCON}", "--build"]})
            wait(15)
        s.append({"do": "py", "args": ["attack_wave.py", "--rcon-port", "{RCON}", "--wave", "60", "--wait", "50"]})
        wait(60)
        s.append({"do": "py", "args": ["attack_wave.py", "--rcon-port", "{RCON}", "--clear"]})
        wait(10)
        phase("weather")
        for w, t in [("thunderstorm", 35), ("heavy_downpour", 30), ("fair", 25)]:
            s.append({"do": "weather", "id": w})
            wait(t)
        phase("daynight")
        for dt in [0.5, 0.75, 0.25, 0.0]:
            s.append({"do": "lua", "code": "for _,sf in pairs(game.surfaces) do sf.daytime=%s end" % dt})
            wait(15)
        phase("surface")
        s.append({"do": "lua", "code": "local p=storage.f3d.puppet; local out={}; for _,sf in pairs(game.surfaces) do "
                  "if sf.index~=p.surface.index then out[#out+1]=sf.index..':'..sf.name end end; rcon.print(table.concat(out,','))"})
        s.append({"do": "eval", "label": "view other surface", "expr": 'Bridge.send({"t": "view", "si": {SI}, "x": 0, "y": 0})'})
        wait(30)
        s.append({"do": "eval", "label": "back", "expr": 'Bridge.send({"t": "view", "si": 0})'})
        wait(20)
        phase("save")
        s.append({"do": "rcon", "cmd": "/server-save"})
        wait(30)
        phase("reconnect")
        s.append({"do": "eval", "label": "reconnect",
                  "expr": "Bridge.connect_to(Bridge.factorio_host, Bridge.factorio_port, Bridge.listen_port)"})
        wait(60)
    rep_tag[0] = ""
    phase("idle")
    s.append({"do": "camera", "dist": 30})
    for _ in range(max(1, int(idle_min * 2))):
        wait(30)
    s.append({"do": "quit"})
    return s


def write_settings(path, preset, extra):
    g = {"window_mode": '"borderless"', "minimize_on_focus_loss": "false"}
    if preset != "default":
        g.update(PRESET_KEYS[preset])
    g.update(extra)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("[meta]\n\nmigrated=true\n\n[graphics]\n\n")
        for k, v in g.items():
            f.write("%s=%s\n" % (k, v))
        f.write("\n[interface]\n\nshow_help=false\n\n[sound]\n\nmaster=0.0\n\n")


class Session:
    def __init__(self, a, idx, preset, save_name, save_path, idle_min, first_in_save, reps=1):
        self.a, self.idx, self.preset, self.save_name, self.reps = a, idx, preset, save_name, reps
        self.save_path, self.idle_min, self.first = save_path, idle_min, first_in_save
        self.dir = os.path.join(a.out, "sessions", "%02d-%s-%s" % (idx, preset, save_name))
        os.makedirs(self.dir, exist_ok=True)
        self.pids = {}
        self.result = {"session": idx, "preset": preset, "save": save_name, "dir": self.dir, "idle_min": idle_min, "reps": reps}

    def log(self, msg):
        line = "[%s] s%02d %s" % (time.strftime("%H:%M:%S"), self.idx, msg)
        print(line, flush=True)
        with open(os.path.join(self.a.out, "soak.log"), "a", encoding="utf-8") as f:
            f.write(line + "\n")

    def record_pid(self, name, pid):
        self.pids[name] = pid
        with open(os.path.join(self.a.out, "pids.txt"), "a", encoding="utf-8") as f:
            f.write("%d %s s%02d %s\n" % (pid, name, self.idx, time.strftime("%H:%M:%S")))

    def start_server(self):
        a = self.a
        copy = os.path.join(a.out, "saves", "soak-%s.zip" % self.save_name)
        os.makedirs(os.path.dirname(copy), exist_ok=True)
        shutil.copyfile(self.save_path, copy)
        self.copy = copy
        before = read_shared(SERVER_LOG)
        t0 = time.time()
        p = subprocess.Popen(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                              os.path.join(REPO, "server", "run-server.ps1"), "-Save", copy, "-UdpPort", str(a.udp),
                              "-GamePort", str(a.game_port), "-RconPort", str(a.rcon)] + (["-Factorio", a.factorio] if a.factorio else []),
                             stdout=open(os.path.join(self.dir, "server.out.log"), "w"), stderr=subprocess.STDOUT,
                             creationflags=subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS)
        self.server = p
        self.record_pid("server-launcher", p.pid)
        while time.time() - t0 < 300:
            text = read_shared(SERVER_LOG)
            if text != before and "Starting RCON" in text and "Opening socket" in text:
                break
            if p.poll() not in (None, 0):
                raise RuntimeError("server launcher exited %s" % p.returncode)
            time.sleep(2)
        else:
            raise RuntimeError("server did not open RCON in 300 s")
        time.sleep(3)
        # factorio.exe is a windowed program: the launcher's `&` doesn't wait, so it may be gone already;
        # its child keeps the launcher's pid as parent.
        for pid, parent, exe in processes():
            if parent == p.pid and exe.lower().startswith("factorio"):
                self.record_pid("factorio", pid)
        self.result["server_start_s"] = round(time.time() - t0, 1)
        self.log("server up in %.0f s (factorio pid %s)" % (time.time() - t0, self.pids.get("factorio")))

    def run(self):
        a = self.a
        self.log("start preset=%s save=%s idle=%s min, free RAM %.1f GB" % (self.preset, self.save_name, self.idle_min, free_gb()))
        self.start_server()
        si = self.other_surface()
        steps = steps_for(self.idx, self.idle_min, self.first, self.a.time_scale, self.reps)
        text = json.dumps(steps).replace('"{RCON}"', '"%d"' % a.rcon).replace("{SI}", str(si))
        steps_path = os.path.join(self.dir, "steps.json")
        with open(steps_path, "w", encoding="utf-8") as f:
            f.write(text)
        settings = os.path.join(self.dir, "settings.cfg")
        write_settings(settings, self.preset, {})
        frames = os.path.join(self.dir, "frames.jsonl")
        ups = subprocess.Popen([a.python, os.path.join(TOOLS, "profile_log.py"), os.path.join(self.dir, "ups.jsonl"),
                                "--port", str(a.rcon), "--minutes", "600"], cwd=REPO,
                               stdout=open(os.path.join(self.dir, "ups.out.log"), "w"), stderr=subprocess.STDOUT,
                               creationflags=subprocess.CREATE_NO_WINDOW)
        self.record_pid("profile_log", ups.pid)
        env = dict(os.environ)
        env["APPDATA"] = os.path.join(a.out, "appdata")
        user = os.path.join(env["APPDATA"], "Godot", "app_userdata", "Zenith")
        os.makedirs(os.path.join(user, "logs"), exist_ok=True)
        spikes = os.path.join(user, "debug", "spikes.log")
        if os.path.exists(spikes):
            os.remove(spikes)
        cmd = [a.godot, "--path", os.path.join(REPO, "client"), "--audio-driver", "Dummy"] + a.godot_arg + [
               "--log-file", os.path.join(self.dir, "godot.log"), "--",
               "--settings-file=" + settings, "--factorio-port=%d" % a.udp, "--port=%d" % a.client_port,
               "--addons=" + ",".join(x for x in [a.addons, os.path.join(HERE, "driver")] if x), "--spike-log=25",
               "--soak=" + steps_path, "--soak-out=" + frames, "--soak-py=" + a.python, "--soak-tools=" + TOOLS,
               "--soak-rcon=%d" % a.rcon] + a.client_arg
        t0 = time.time()
        client = subprocess.Popen(cmd, cwd=REPO, env=env, stdout=open(os.path.join(self.dir, "client.out.log"), "w"),
                                  stderr=subprocess.STDOUT)
        self.record_pid("godot-console", client.pid)
        limit = (10 + 20 * self.reps + self.idle_min) * 60
        last_mem = last_gpu = 0.0
        proc_log = open(os.path.join(self.dir, "proc.jsonl"), "a", encoding="utf-8")
        status = "ok"
        min_free = 99.0
        while True:
            code = client.poll()
            if code is not None:
                self.result["client_exit"] = code
                break
            now = time.time()
            fg = free_gb()
            min_free = min(min_free, fg)
            if fg < a.ram_stop:
                status = "ram-stop (free %.1f GB)" % fg
                self.log("FREE RAM %.1f GB < %.1f: stopping the session now" % (fg, a.ram_stop))
                break
            if now - t0 > limit:
                status = "timeout"
                self.log("client still running after %d s: stopping" % limit)
                break
            if os.path.exists(os.path.join(a.out, "STOP")):
                status = "stop-file"
                break
            if now - last_mem >= (2 if now - t0 < 150 else 30):
                last_mem = now
                gd = [pid for pid, exe in descendants(client.pid) if exe.lower().startswith("godot")]
                rec = {"unix": now, "t": round(now - t0, 1), "free_gb": round(fg, 2)}
                for pid in gd:
                    rec["godot"] = mem_of(pid)
                    rec["godot_pid"] = pid
                fpid = self.pids.get("factorio")
                if fpid:
                    rec["factorio"] = mem_of(fpid)
                if now - last_gpu >= 60 and now - t0 >= 150:
                    last_gpu = now
                    g = gpu_mem(gd + ([fpid] if fpid else []))
                    rec["gpu_mb"] = {str(k): v for k, v in g.items()}
                proc_log.write(json.dumps(rec) + "\n")
                proc_log.flush()
            time.sleep(1 if now - t0 < 150 else 5)
        proc_log.close()
        self.result.update({"status": status, "secs": round(time.time() - t0, 1), "min_free_gb": round(min_free, 2)})
        kill_tree(client.pid)
        kill_tree(ups.pid)
        self.stop_server()
        if os.path.exists(spikes):
            shutil.move(spikes, os.path.join(self.dir, "spikes.log"))
        try:
            os.remove(self.copy)
        except OSError:
            pass
        self.log("end: %s after %.0f s" % (status, time.time() - t0))
        return self.result

    def other_surface(self):
        """The index of another surface than the character's (a planet or platform), or 0."""
        a = self.a
        out = subprocess.run([a.python, os.path.join(TOOLS, "rcon.py"), "--port", str(a.rcon),
                              "/c __factorio-3d-bridge__ local p=storage.f3d and storage.f3d.puppet; local s=(p and p.valid) and p.surface.index or 1; "
                              "local best=0; for _,sf in pairs(game.surfaces) do if sf.index~=s and best==0 and "
                              "(sf.platform or sf.planet) then best=sf.index end end; rcon.print(best)"],
                             capture_output=True, text=True, timeout=30, cwd=REPO)
        txt = (out.stdout or "").strip()
        self.log("other surface: %r" % txt)
        try:
            return int(txt.split()[-1])
        except (ValueError, IndexError):
            return 0

    def stop_server(self):
        try:
            subprocess.run([self.a.python, os.path.join(TOOLS, "rcon.py"), "--port", str(self.a.rcon), "/quit"],
                           capture_output=True, timeout=20, cwd=REPO)
            fpid = self.pids.get("factorio")
            for _ in range(60):
                if not fpid or fpid not in [q[0] for q in processes()]:
                    break
                time.sleep(1)
        except Exception:
            pass
        fpid = self.pids.get("factorio")
        if fpid and any(q[0] == fpid and q[2].lower().startswith("factorio") for q in processes()):
            kill_tree(fpid)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True)
    ap.add_argument("--hours", type=float, default=4.0)
    ap.add_argument("--plan", default="default:main,low:main,medium:main,high:main,ultra:main,default:ep16",
                    help="preset:save[:reps] ... (reps: the phase set repeated in one client run)")
    ap.add_argument("--save", action="append", default=[], help="name=path")
    ap.add_argument("--idle", type=float, default=4.0, help="minutes of idle per session")
    ap.add_argument("--long-idle", type=float, default=35.0, help="minutes of idle for the session that starts past --long-idle-after")
    ap.add_argument("--long-idle-after", type=float, default=0.5, help="fraction of --hours")
    ap.add_argument("--addons", default="", help="a folder of add-ons (the release's zips) to run with the driver")
    ap.add_argument("--godot", default="", help="Godot's console exe (default: tools/check.py's lookup: GODOT, PATH, ~/Tools/Godot)")
    ap.add_argument("--python", default=sys.executable)
    ap.add_argument("--factorio", default="", help="factorio.exe (run-server.ps1 looks for it when not given)")
    ap.add_argument("--port-base", type=int, default=36500)
    ap.add_argument("--ram-start", type=float, default=8.0)
    ap.add_argument("--ram-stop", type=float, default=3.0)
    ap.add_argument("--max-sessions", type=int, default=99)
    ap.add_argument("--first-index", type=int, default=1, help="the first session's number (a soak continued)")
    ap.add_argument("--time-scale", type=float, default=1.0, help="waits shortened by this factor (a trial run)")
    ap.add_argument("--client-arg", action="append", default=[], help="another client switch (repeatable)")
    ap.add_argument("--godot-arg", action="append", default=[], help="an engine argument before -- (e.g. --rendering-driver=d3d12)")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    a.udp, a.game_port, a.rcon, a.client_port = a.port_base, a.port_base + 1, a.port_base + 2, a.port_base + 3
    if not a.godot:
        sys.path.insert(0, TOOLS)
        import check  # noqa: E402  (the repo's Godot lookup)
        a.godot = check.godot_path() or ""
        if not a.godot and not a.dry_run:
            sys.exit("Godot not found: pass --godot <console exe>")
    saves = dict(s.split("=", 1) for s in a.save)
    plan = [tuple(p.split(":")) for p in a.plan.split(",")]
    os.makedirs(a.out, exist_ok=True)
    if a.dry_run:
        print(json.dumps(steps_for(1, a.idle, True), indent=1)[:3000])
        return
    deadline = time.time() + a.hours * 3600
    start = time.time()
    seen = set()
    idx = a.first_index - 1
    long_done = False
    while time.time() < deadline - 15 * 60 and idx - a.first_index + 1 < a.max_sessions:
        entry = plan[(idx - a.first_index + 1) % len(plan)]
        preset, save = entry[0], entry[1]
        reps = int(entry[2]) if len(entry) > 2 else 1
        idx += 1
        waited = 0
        while free_gb() < a.ram_start and waited < 1800:
            print("free RAM %.1f GB < %.1f: waiting" % (free_gb(), a.ram_start), flush=True)
            time.sleep(60)
            waited += 60
        if free_gb() < a.ram_start:
            print("free RAM never reached %.1f GB: ending" % a.ram_start)
            break
        idle = a.idle
        left_min = (deadline - time.time()) / 60
        if not long_done and time.time() - start > a.long_idle_after * a.hours * 3600 and left_min > a.long_idle + 30:
            idle, long_done = a.long_idle, True
        s = Session(a, idx, preset, save, saves[save], idle, save not in seen, reps)
        seen.add(save)
        try:
            res = s.run()
        except Exception as e:  # noqa: BLE001
            s.log("FAILED: %s" % e)
            res = dict(s.result, status="failed: %s" % e)
            for name in ("godot-console", "profile_log"):
                kill_tree(s.pids.get(name))
            if hasattr(s, "server"):
                s.stop_server()
        with open(os.path.join(a.out, "soak.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(res) + "\n")
        if os.path.exists(os.path.join(a.out, "STOP")):
            break
        time.sleep(10)
    print("soak done", flush=True)


if __name__ == "__main__":
    main()
