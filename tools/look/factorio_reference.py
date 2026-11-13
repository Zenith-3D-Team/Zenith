"""Factorio's own picture of a scene next to Zenith's, for matching Zenith's look to the game's:

    python tools/look/factorio_reference.py [--looks factorio,classic] [--skip-factorio] [--skip-zenith]

1. Makes a map (seed 123456) and a test mod (tools/look/zenith-look-scene) that builds the same
   small scene beside the spawn.
2. Loads it in a Factorio window, which saves Factorio's picture of the scene at noon and through
   its dusk, daytime 0.30 to 0.45 (game.take_screenshot, 32 px a tile, no clouds), then is closed.
   With `--gleba` Space Age is on and it also pictures Gleba's bare ground at those times.
3. Loads it on a headless server with the bridge, and takes Zenith's picture of the same place in
   Factorio's view (F6), each time of day held (`--sky=nauvis@<daytime>`), once per look (`--look=<id>`).
4. Compares them per time of day: the ground's colour, saturation and contrast, the shadows, a
   lamp's lit patch, and a side-by-side picture.

Steam's Factorio only takes its own --config when started with a steam_appid.txt beside
factorio.exe: the script adds one for the run and removes it after. Ports 36420-36424. Pictures in
the git-ignored art-src/look/ (they show Factorio's graphics: they stay out of the repo).
"""
import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time

import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.append(str(ROOT / "tools"))
import factorio_install  # noqa: E402

EXE = pathlib.Path(factorio_install.exe())
WORK = ROOT / "art-src" / "look"
GODOT = os.environ.get("GODOT", "godot")  # Godot 4.4+ on PATH, or $GODOT
PORTS = (36420, 36421, 36422, 36424)
SIZE = (1600, 900)
# Noon, then Factorio's dusk (control.lua takes the same).
DAYTIMES = (0.0, 0.30, 0.35, 0.40, 0.45)


def tag(daytime):
    """A picture's name for a time of day; noon keeps the plain name it always had."""
    return "" if daytime == 0 else f"-{daytime:.2f}"


def log(*a):
    print(*a, flush=True)


def folder(name, mods, space_age=False):
    h = WORK / name
    if h.exists():
        shutil.rmtree(h)
    (h / "mods").mkdir(parents=True)
    if space_age:
        names = ["base", "elevated-rails", "quality", "space-age"] + [src.name for src in mods]
        (h / "mods" / "mod-list.json").write_text(
            json.dumps({"mods": [{"name": n, "enabled": True} for n in names]}), encoding="ascii")
    (h / "data").mkdir()
    read_data = EXE.parent.parent.parent / "data"
    (h / "config.ini").write_text(f"[path]\nread-data={read_data}\nwrite-data={h / 'data'}\n"
                                  "[graphics]\nfull-screen=false\n", encoding="ascii")
    for src in mods:
        shutil.copytree(src, h / "mods" / src.name)
    return h


def stop(h):
    marker = str(h).replace("'", "''")
    ps = ("Get-CimInstance Win32_Process -Filter \"Name='factorio.exe'\" | "
          f"Where-Object {{ $_.CommandLine -like '*{marker}*' }} | ForEach-Object {{ Stop-Process -Id $_.ProcessId -Force }}")
    subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True)
    time.sleep(2)


def factorio(h, *args, cwd_bin=True, **kw):
    return subprocess.Popen([str(EXE), "--config", str(h / "config.ini"), "--mod-directory", str(h / "mods")] + list(args),
                            cwd=str(EXE.parent), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **kw)


def make_save():
    scene = ROOT / "tools" / "look" / "zenith-look-scene"
    h = folder("create", [scene])
    save = WORK / "scene.zip"
    p = factorio(h, "--create", str(save), "--map-gen-seed", "123456")
    p.wait(timeout=300)
    if not save.exists():
        raise RuntimeError("Factorio made no map (see %s)" % (h / "data" / "factorio-current.log"))
    return save


def factorio_pictures(save, daytimes, gleba):
    scene = ROOT / "tools" / "look" / "zenith-look-scene"
    h = folder("window", [scene], space_age=gleba)
    copy = WORK / "window.zip"
    shutil.copyfile(save, copy)
    folder_out = h / "data" / "script-output" / "zenith-look"
    last = folder_out / f"factorio{tag(DAYTIMES[-1])}.png"  # the mod takes them all, this one last
    p = factorio(h, "--load-game", str(copy))
    deadline = time.time() + 300
    while time.time() < deadline and not last.exists():
        time.sleep(2)
    time.sleep(3)
    stop(h)
    p.wait(timeout=30)
    if not last.exists():
        raise RuntimeError("Factorio's window saved no picture (see %s)" % (h / "data" / "factorio-current.log"))
    refs = {}
    for d in daytimes:
        refs[d] = WORK / f"factorio{tag(d)}.png"
        shutil.copyfile(folder_out / f"factorio{tag(d)}.png", refs[d])
    for g in folder_out.glob("gleba-*.png"):
        shutil.copyfile(g, WORK / g.name)
    return refs


def zenith_pictures(save, looks, daytimes, extra):
    scene = ROOT / "tools" / "look" / "zenith-look-scene"
    h = folder("server", [scene, ROOT / "mod" / "factorio-3d-bridge"])
    copy = WORK / "server.zip"
    shutil.copyfile(save, copy)
    log_file = h / "data" / "factorio-current.log"
    server = factorio(h, "--start-server", str(copy), "--enable-lua-udp", str(PORTS[0]), "--port", str(PORTS[1]),
                      "--rcon-port", str(PORTS[2]), "--rcon-password", "look",
                      "--server-settings", str(ROOT / "server" / "server-settings.json"))  # no auto-pause
    deadline = time.time() + 180
    while time.time() < deadline and not (log_file.exists() and "Opening socket" in log_file.read_text(errors="ignore")):
        time.sleep(2)
    time.sleep(5)
    shots = {}  # (look, daytime) -> picture
    try:
        for look in looks:
            for d in daytimes:
                dest = WORK / f"zenith-{look}{tag(d)}.png"
                if dest.exists():
                    dest.unlink()
                args = [GODOT, "--audio-driver", "Dummy", "--path", str(ROOT / "client"), "--resolution", "%dx%d" % SIZE, "--",
                        f"--factorio-port={PORTS[0]}", f"--port={PORTS[3]}", "--clean-shot", f"--sky=nauvis@{d}",
                        "--camera=factorio", f"--look={look}", f"--screenshot={dest}@45", "--no-custom-models",
                        # Zenith's defaults, not this PC's own settings (brightness, saturation...)
                        f"--settings-file={WORK / 'settings.cfg'}"] + extra
                with open(WORK / f"zenith-{look}{tag(d)}.log", "w", encoding="utf-8", errors="ignore") as out:
                    c = subprocess.Popen(args, stdout=out, stderr=subprocess.STDOUT)
                    deadline = time.time() + 120
                    while time.time() < deadline and c.poll() is None and not dest.exists():
                        time.sleep(1)
                    time.sleep(2)  # the picture written in full
                    if c.poll() is None:
                        c.kill()
                    c.wait(timeout=30)
                if dest.exists():
                    shots[(look, d)] = dest
                else:
                    log(f"  no picture for look {look} at {d} (see zenith-{look}{tag(d)}.log)")
    finally:
        stop(h)
        server.wait(timeout=30)
    return shots


# --- comparing ------------------------------------------------------------------------------------

def srgb(a):
    return np.asarray(a, dtype=np.float64) / 255.0


def lum(rgb):
    return rgb @ np.array([0.2126, 0.7152, 0.0722])


def sat(rgb):
    mx, mn = rgb.max(-1), rgb.min(-1)
    return np.where(mx > 1e-4, (mx - mn) / np.maximum(mx, 1e-4), 0.0)


def ground_mask(img):
    """Pixels of open ground: everything outside the scene's built rectangle (the middle of the frame)."""
    h, w = img.shape[:2]
    m = np.ones((h, w), bool)
    cx, cy = w // 2, h // 2 - int(3.5 * 32)
    m[max(0, cy - 8 * 32):cy + 8 * 32, max(0, cx - 13 * 32):cx + 13 * 32] = False
    return m


def lamp_patch(rgb):
    """The ground round the scene's lamp, three tiles each way: (-3, 6.5) from the scene's middle."""
    h, w = rgb.shape[:2]
    x, y = w // 2 - 3 * 32, h // 2 + 3 * 32
    return rgb[y - 96:y + 96, x - 96:x + 96].reshape(-1, 3)


def stats(img):
    rgb = srgb(img)[..., :3]
    g = ground_mask(img)
    pix = rgb[g]
    L = lum(pix)
    dark = L < np.percentile(L, 5)
    return {
        "ground_rgb": [round(float(v) * 255, 1) for v in pix.mean(0)],
        "ground_luma": round(float(L.mean()), 4),
        "ground_saturation": round(float(sat(pix).mean()), 4),
        "ground_contrast": round(float(L.std() / max(L.mean(), 1e-4)), 4),
        "darkest_5pct_luma": round(float(L[dark].mean()), 4),
        "scene_luma": round(float(lum(rgb).mean()), 4),
        "scene_saturation": round(float(sat(rgb).mean()), 4),
        "scene_contrast": round(float(lum(rgb).std()), 4),
        "lamp_patch_rgb": [round(float(v) * 255, 1) for v in lamp_patch(rgb).mean(0)],
        "lamp_patch_luma": round(float(lum(lamp_patch(rgb)).mean()), 4),
    }


# Zenith's Factorio view (F6) has Factorio's 32 px a tile down the screen but 32 / sin(48°) across
# (camera_rig.gd), so its pictures are narrowed to Factorio's scale and both cropped to the area
# both show.
ZENITH_X = 0.7431


def common(path, zenith):
    im = Image.open(path).convert("RGB").resize(SIZE)
    w, h = SIZE
    cw = int(round(w * ZENITH_X))
    if zenith:
        return im.resize((cw, h), Image.LANCZOS)
    x0 = (w - cw) // 2
    return im.crop((x0, 0, x0 + cw, h))


def side_by_side(ref, shots, suffix=""):
    tiles = [common(ref, False)] + [common(v, True) for v in shots.values()]
    w, h = tiles[0].size
    out = Image.new("RGB", (w * len(tiles), h))
    for i, im in enumerate(tiles):
        out.paste(im, (w * i, 0))
    out.save(WORK / f"side-by-side{suffix}.png")
    # Half and half: Factorio left, each look right.
    for k, v in shots.items():
        a = common(ref, False)
        b = common(v, True)
        split = a.copy()
        split.paste(b.crop((w // 2, 0, w, h)), (w // 2, 0))
        split.save(WORK / f"split-{k}{suffix}.png")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--looks", default="factorio,classic")
    ap.add_argument("--skip-factorio", action="store_true", help="keep the Factorio picture from the last run")
    ap.add_argument("--skip-zenith", action="store_true", help="only compare the pictures already there")
    ap.add_argument("--zenith-arg", action="append", default=[], help="another argument for Zenith (repeatable)")
    ap.add_argument("--daytimes", default=",".join(str(d) for d in DAYTIMES),
                    help="the times of day to compare (any of %s)" % (DAYTIMES,))
    ap.add_argument("--gleba", action="store_true", help="with Space Age on, picture Gleba's ground through its dusk too")
    a = ap.parse_args()
    WORK.mkdir(parents=True, exist_ok=True)
    looks = [s for s in a.looks.split(",") if s]
    daytimes = [float(s) for s in a.daytimes.split(",") if s]
    appid = EXE.parent / "steam_appid.txt"
    added = not appid.exists()
    if added:
        appid.write_text("427520")
    try:
        save = WORK / "scene.zip"
        if not (a.skip_factorio and save.exists()):
            log("making the map")
            save = make_save()
        refs = {d: WORK / f"factorio{tag(d)}.png" for d in daytimes}
        if not (a.skip_factorio and all(r.exists() for r in refs.values())):
            log("Factorio's pictures")
            refs = factorio_pictures(save, daytimes, a.gleba)
        if a.skip_zenith:
            shots = {(k, d): WORK / f"zenith-{k}{tag(d)}.png" for k in looks for d in daytimes
                     if (WORK / f"zenith-{k}{tag(d)}.png").exists()}
        else:
            log("Zenith's pictures:", ", ".join(looks))
            shots = zenith_pictures(save, looks, daytimes, a.zenith_arg)
    finally:
        if added and appid.exists():
            appid.unlink()
    all_stats = {}
    for d in daytimes:
        here = {k: v for (k, t), v in shots.items() if t == d}
        res = {"game": stats(np.asarray(common(refs[d], False)))}
        for k, v in here.items():
            res[k] = stats(np.asarray(common(v, True)))
        all_stats[str(d)] = res
        log(f"\ndaytime {d}")
        log("| | " + " | ".join(res.keys()) + " |")
        log("|---|" + "---:|" * len(res))
        for key in res["game"]:
            log(f"| {key} | " + " | ".join(str(res[n][key]) for n in res) + " |")
        if here:
            side_by_side(refs[d], here, tag(d))
    (WORK / "stats.json").write_text(json.dumps(all_stats, indent=1))
    gleba = sorted(WORK.glob("gleba-*.png"))
    if gleba:
        # Factorio's own Gleba only: how much of its grading each time of day holds (for look_luts.gd).
        log("\nGleba's ground in Factorio")
        for g in gleba:
            rgb = srgb(np.asarray(Image.open(g).convert("RGB")))
            log(f"{g.stem}: rgb {[round(float(v) * 255, 1) for v in rgb.reshape(-1, 3).mean(0)]}")


if __name__ == "__main__":
    main()
