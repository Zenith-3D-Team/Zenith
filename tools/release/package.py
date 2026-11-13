"""Builds the download players get: the client exported with Godot, with the bridge mod and the
server scripts beside it, zipped as dist/Zenith-<version>-<platform>.zip. Uploads nothing.

    python3 tools/release/package.py [--godot <godot exe>] [--channel public|dev]
        [--platform windows|linux|linux-arm64|windows-arm64|macos|supported|unsupported|all]
        [--no-addons] [--addon <add-on folder>[:off]]... [--models <folder>]

Two channels (owner: public downloads carry no testing tools; development builds do). `public`, the
default, is the release on the public repo. `dev` is a development build for testers:
dist/Zenith-<version>-dev-<platform>.zip, exported with the custom feature tag `zenith_dev` (set
on the export preset for that export alone, export_presets.cfg put back after), which
Settings.dev_tools() reads: the main menu's Performance test and --perf-test, the debug menu
(Ctrl+F12) and its overlays are there only then. A dev zip also carries PERFORMANCE-TEST.md and
the docs' dev-build parts (between <!-- dev --> and <!-- /dev --> marks, cut from a public zip's
copies), and START HERE.txt says it is a development build.

Every download carries Zenith's own add-ons (BUNDLED: the Cinematic camera, switched on; Terrain
Elevation, switched off until the player turns it on; the Cinematic shaders, from addons-src, are
added with --addon addons-src/cinematic-shaders, switched on), each fetched from its GitHub repo's latest
release (or its default branch when it has none) into addons/<id>_<version>.zip, with
addons/bundled.json giving each one's first state (addon_loader.gd). --addon <folder>[:off] bundles a
local folder instead of (or besides) them; --no-addons leaves them all out.

--models <folder> puts a modeller's models (the .glb and .gltf files at the folder's top, with any
files a .gltf points at) into the download's models/ folder beside the program. Zenith reads that
folder at start-up and a model there replaces its own of the same name (model_library.gd
custom_models_dir), so the download shows them out of the box; `-- --no-custom-models` leaves them
out. Only for builds whose modeller agreed (releases with Vasillo's models): the
models aren't Zenith's, and the README.txt there says so.

windows and linux are the downloads Zenith supports. linux-arm64 (issue #8), windows-arm64 and
macos (a universal app: Apple Silicon and Intel) are UNSUPPORTED (owner's label): built the same way, never run by
anyone; each zip says so in its name ("-unsupported") and in UNSUPPORTED.txt inside. macOS is
exported from Windows without Apple's signature (ad-hoc only) or notarization.

Needs Godot's export templates for the same version as the editor (Godot: Editor → Manage Export
Templates, or the .tpz from Godot's releases page unpacked into its templates folder). The
exported client finds `mod/` and `server/` next to its own executable (client/scripts/menu/paths.gd),
so the zip unpacks into one folder that runs as it is.

The native belt simulation (client/native/belt_sim.gdextension, docs/RUNNING.md) is exported by Godot
itself: the Windows download gets client/native/bin's DLL beside Zenith.exe when it is there (it is
committed; nothing here builds it). The other platforms have no library and run belt_sim.gd.
"""

import argparse
import io
import json
import urllib.error
import urllib.request
import os
import pathlib
import re
import shutil
import subprocess
import sys
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
# BeltSimNative's library (client/native/belt_sim.gdextension), which Godot exports beside the program.
NATIVE_DLL = "belt_sim.windows.template_release.x86_64.dll"
MOD = ROOT / "mod" / "factorio-3d-bridge"
# platform -> (export preset, the program's name in the folder). macOS's export is a .zip holding
# Zenith.app, whose entries go into the download as they are.
PRESETS = {"windows": ("Windows Desktop", "Zenith.exe"), "linux": ("Linux", "Zenith.x86_64"),
           "linux-arm64": ("Linux ARM64 (unsupported)", "Zenith.arm64"),
           "windows-arm64": ("Windows ARM64 (unsupported)", "Zenith.exe"),
           "macos": ("macOS (unsupported)", "Zenith.zip")}
SUPPORTED = ["windows", "linux"]
UNSUPPORTED_HEAD = """Zenith {version} for {what}: UNSUPPORTED

This build has never been run by anyone, and isn't supported: it is here for players who want to
try it. Please report what happens on the project's issue tracker; there may be no fix.
"""
# Downloads nobody has tried: "-unsupported" in the zip's name and UNSUPPORTED.txt inside.
UNSUPPORTED = {
    "linux-arm64": ("Linux on ARM64 (aarch64)", """
Factorio itself has no Linux ARM64 build. Zenith needs a real Factorio 2.1 running beside it (it
draws Factorio's game, and reads its graphics and sounds from your install), so Factorio has to run
under an x86-64 emulator such as Box64 or FEX-Emu, as a headless server or the full game. Point
Settings -> Factorio install at that Factorio. Expect it to be slow: the emulated Factorio runs the
game, Zenith draws it natively.

The client's textures are packed for desktop graphics (S3TC/BPTC), as the ARM64 desktops' GPUs read
them (Apple, Snapdragon X, NVIDIA and AMD cards); a GPU without them, such as a Raspberry Pi's,
likely can't run it.
"""),
    "windows-arm64": ("Windows on ARM64", """
Zenith runs natively on ARM64 here. Factorio has no Windows ARM64 build: Windows runs Factorio's
x64 build through its own emulation, which Zenith starts like any Factorio. Expect the game itself
to run slower than on an x64 PC. If Factorio isn't found, set it in Settings -> Factorio install.
"""),
    "macos": ("macOS (Apple Silicon and Intel)", """
Zenith.app is a universal app (Apple Silicon and Intel) exported on Windows: it is not signed with
an Apple developer ID (only ad-hoc) and not notarized, so macOS refuses to open it the first time.
Right-click Zenith.app and choose Open, or run in Terminal:
    xattr -dr com.apple.quarantine Zenith.app

Keep the mod and server folders beside Zenith.app: Zenith starts Factorio with the bridge mod from
there. Factorio has a native macOS build; if Zenith doesn't find it, set Settings -> Factorio
install to factorio.app/Contents/MacOS/factorio. The scripts in server/ are for Windows and Linux;
Zenith's menu starts Factorio by itself.
"""),
}
SERVER_FILES = ["server-settings.json", "run-server.ps1", "run-headless.sh", "download-headless.sh", "factorio-with-zenith.ps1"]
# The models from Wube's printable release (CC BY-NC) and from FUE5 (CC BY-NC-SA) ship inside the game:
# their per-model lists and licence terms go beside it, as the licences ask.
DOCS = [("LICENSE", "LICENSE.txt"), ("LICENSING.md", "LICENSING.md"), ("CREDITS.md", "CREDITS.md"), ("docs/USER-GUIDE.md", "USER-GUIDE.md"),
        ("docs/ADDONS.md", "ADDONS.md"), ("docs/MODELLERS.md", "MODELLERS.md"),
        ("client/assets/models/CREDITS.md", "MODEL-CREDITS.md"),
        ("client/assets/models/fue5/README.md", "FUE5-MODELS.md"),
        ("client/assets/branding/README.md", "LOGO-LICENCE.md")]
# The testing tools' own docs, only in a dev build.
DEV_DOCS = [("docs/PERFORMANCE-TEST.md", "PERFORMANCE-TEST.md")]
CHANNELS = ["public", "dev"]
# The feature tag a dev export carries (client/scripts/menu/settings.gd DEV_FEATURE).
DEV_FEATURE = "zenith_dev"
# A doc's dev-build parts: whole lines between marks on lines of their own, or words between marks
# inside a line. A dev zip keeps them without the marks, a public one cuts them.
DEV_BLOCK = re.compile(r"^<!-- dev -->\r?\n(.*?)^<!-- /dev -->\r?\n", re.S | re.M)
DEV_INLINE = re.compile(r"<!-- dev -->(.*?)<!-- /dev -->", re.S)
MODELS_README = """Your own 3D models for Zenith.

Put a .glb file here named after the Factorio entity it draws, and Zenith uses it in place of its
own model of that name the next time it starts. Everything not here keeps Zenith's own model; with
nothing here, Zenith looks as it always does. Settings > Graphics > Your models says how many are
in use and opens this folder.

Names are Factorio's internal names, for example:
  transport-belt.glb, transport-belt-curve-left.glb, transport-belt-curve-right.glb
  inserter.glb, inserter-east.glb, inserter-south.glb, inserter-west.glb (the base, per direction)
  inserter-arm-basic-upper.glb, inserter-arm-basic-hand-open.glb, inserter-arm-basic-hand-closed.glb
  burner-mining-drill.glb, burner-mining-drill-east.glb, -south.glb, -west.glb

1 unit = 1 tile, the origin at the footprint's centre on the ground, facing north (Blender +Y).
MODELLERS.md, beside Zenith, has every name, the moving parts and the materials belts need.

To start Zenith with its own models only, without removing these: start it with
  -- --no-custom-models
after the program's name (a shortcut's Target), or empty this folder.
"""


# Added to the models folder's README.txt when the download comes with models in it (--models).
MODELS_BUNDLED = """
This download comes with {count} models already here, made by a modeller for Zenith and used with
their permission (CREDITS.md beside Zenith says whose). They aren't Zenith's own and aren't under
its GPL licence. Remove them, or start Zenith with -- --no-custom-models, to see Zenith's own.
"""


ADDONS_README = """Zenith add-ons go here: each a .zip as you downloaded it (no need to unpack it), or a folder
with its addon.json (or put them in Zenith's user data folder, which keeps them across updates).
The Add-ons menu (main menu, Esc menu, Settings) lists them, with a switch, settings and keys for
each. ADDONS.md says how to write one.
"""

START_HERE = """Zenith {version}: Factorio in 3D

You need Factorio 2.1 (Space Age optional) installed on this computer. Zenith reads Factorio's
graphics, sounds and fonts from your own copy and never copies them.

1. Start {exe}.
2. Single player -> New game (or Load game for one of your saves). Zenith starts Factorio in the
   background with the bridge mod from the mod folder here, and connects by itself.
3. If Factorio isn't found, set its folder in Settings -> Factorio install.

Your settings, Zenith worlds and server data are kept in Zenith's user folder
(%APPDATA%\\Godot\\app_userdata\\Zenith on Windows), not in this folder, so updating is just
unpacking the new version. Older versions kept worlds in their own server\\saves folder:
unpack this one over such a version to bring them across, or copy them into the user folder's
saves.

Ctrl+F9 opens the same game in Factorio itself; Ctrl+F9 there comes back.
USER-GUIDE.md has the controls and everything else. Bug reports are welcome on the project's
issue tracker.
"""
START_HERE_DEV = """
This is a DEVELOPMENT BUILD, for testers: it has the testing tools the public
downloads leave out, the main menu's Performance test (PERFORMANCE-TEST.md) and the debug menu
(Ctrl+F12 in a game). Please don't pass it on.
"""


def default_godot():
    local = os.environ.get("LOCALAPPDATA", "")
    found = list(pathlib.Path(local, "Microsoft", "WinGet", "Packages").glob(
        "GodotEngine.GodotEngine*/Godot_v*_console.exe")) if local else []
    return str(found[0]) if found else (shutil.which("godot") or "godot")


# Godot's macOS template is a universal binary only, and a universal (or arm64) export needs every
# texture imported in ETC2/ASTC too. That is switched on for the macOS export alone and back off
# after (the project and its .import files as they were), so the other downloads and everyday work
# keep their imports.
ETC2_SETTING = "textures/vram_compression/import_etc2_astc=true"


def export_with_etc2(godot, preset, out_exe):
    client = ROOT / "client"
    project = client / "project.godot"
    before = project.read_bytes()
    # Every .import file as it is now, written back afterwards byte for byte. (Put back with git
    # checkout, they also lost any change made to them before the build: hundreds after an import.)
    imports = {p: p.read_bytes() for p in client.rglob("*.import") if ".godot" not in p.parts}
    text = before.decode("utf-8")
    nl = "\r\n" if "\r\n" in text else "\n"
    project.write_text(text.replace("[rendering]" + nl, "[rendering]" + nl + nl + ETC2_SETTING + nl, 1),
                       encoding="utf-8", newline="")
    try:
        # An import pass first: the export alone stops at the setting it hasn't imported for yet.
        subprocess.run([godot, "--headless", "--path", str(client), "--import"], capture_output=True, text=True)
        export(godot, preset, out_exe)
    finally:
        project.write_bytes(before)
        for p in client.rglob("*.import"):
            if ".godot" in p.parts:
                continue
            if p not in imports:
                p.unlink()  # made by the import pass
            elif p.read_bytes() != imports[p]:
                p.write_bytes(imports[p])


def with_dev_feature(godot, preset, out_exe, export_fn):
    """Exports with DEV_FEATURE added to the preset's custom features, then puts
    export_presets.cfg back byte for byte: the presets stay one list for both channels."""
    presets = ROOT / "client" / "export_presets.cfg"
    before = presets.read_bytes()
    text = before.decode("utf-8")
    line = re.compile(r'(\nname="%s"\r?\n(?:(?!\[preset).*\n)*?custom_features=)"([^"\r\n]*)"' % re.escape(preset))
    found = line.search(text)
    if not found:
        sys.exit(f"export preset {preset} has no custom_features line in {presets}")
    features = ",".join([f for f in found.group(2).split(",") if f] + [DEV_FEATURE])
    presets.write_text(text[:found.start()] + found.group(1) + f'"{features}"' + text[found.end():], encoding="utf-8", newline="")
    try:
        export_fn(godot, preset, out_exe)
    finally:
        presets.write_bytes(before)


def channel_doc(text, channel):
    """A doc as the channel ships it: dev-build parts kept without their marks, or cut."""
    if channel == "dev":
        return DEV_INLINE.sub(r"\1", DEV_BLOCK.sub(r"\1", text))
    return DEV_INLINE.sub("", DEV_BLOCK.sub("", text))


def export(godot, preset, out_exe):
    out_exe.parent.mkdir(parents=True, exist_ok=True)
    cmd = [godot, "--headless", "--path", str(ROOT / "client"), "--export-release", preset, str(out_exe)]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0 or not out_exe.exists():
        log = (result.stdout + result.stderr)[-2000:]
        if "template" in log.lower():
            sys.exit(f"Godot's export templates are missing for {preset}: install them (Editor -> Manage "
                     f"Export Templates) and run this again.\n{log}")
        sys.exit(f"export of {preset} failed:\n{log}")


# Programs and scripts that must be executable once unpacked on Linux or macOS. A zip made on Windows
# carries no Unix permissions unless they are written into each entry.
EXECUTABLE = (".x86_64", ".arm64", ".sh")


# Zenith's own add-ons, in every download: (GitHub repo, on until the player switches it).
BUNDLED = [("unjustodin/Zenith-Cinematic-Camera", True), ("unjustodin/Terrain-Elevation", False)]


def _get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "zenith-package", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def zip_manifest(data):
    """An add-on zip's addon.json (at its root or one folder down), or None."""
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        names = [n for n in z.namelist() if n == "addon.json" or (n.count("/") == 1 and n.endswith("/addon.json"))]
        return json.loads(z.read(sorted(names, key=len)[0])) if names else None


def fetch_addon(repo):
    """The add-on's zip from its repo's latest release (its first .zip), else its default branch."""
    try:
        release = json.loads(_get(f"https://api.github.com/repos/{repo}/releases/latest"))
        assets = [a for a in release.get("assets", []) if a["name"].endswith(".zip")]
        if assets:
            return _get(assets[0]["browser_download_url"]), f"release {release['tag_name']}"
    except urllib.error.HTTPError:
        pass  # no release yet
    return _get(f"https://api.github.com/repos/{repo}/zipball"), "default branch"


def folder_zip(folder):
    """A local add-on folder as zip bytes, its addon.json at the root."""
    folder = pathlib.Path(folder).resolve()
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for p in sorted(folder.rglob("*")):
            rel = p.relative_to(folder)
            if p.is_file() and not any(part.startswith(".") for part in rel.parts):
                z.write(p, rel.as_posix())
    return buf.getvalue()


def gather_addons(args):
    """[(file name, zip bytes, id, on), ...] for the downloads, fetched once."""
    out = []
    if not args.no_addons:
        for repo, on in BUNDLED:
            data, where = fetch_addon(repo)
            m = zip_manifest(data)
            if not m:
                sys.exit(f"{repo} ({where}) has no addon.json")
            print(f"add-on {m['id']} {m['version']} from {repo}, {where}, {'on' if on else 'off'}")
            out.append((f"{m['id']}_{m['version']}.zip", data, m["id"], on))
    for spec in args.addon:
        # Only a trailing :off or :on is the state: a Windows path has its own colon (C:\...).
        folder, state = spec, "on"
        if spec.endswith((":off", ":on")):
            folder, _, state = spec.rpartition(":")
        data = folder_zip(folder)
        m = zip_manifest(data)
        if not m:
            sys.exit(f"--addon {folder}: no addon.json in that folder")
        out = [a for a in out if a[2] != m["id"]]
        out.append((f"{m['id']}_{m['version']}.zip", data, m["id"], state != "off"))
    return out


# Files a modeller's folder can hold for a model: the models themselves, and what a .gltf points at.
MODEL_FILES = (".glb", ".gltf", ".bin", ".png", ".jpg", ".jpeg", ".webp", ".ktx2")


def bundled_models(folder):
    """The model files in a --models folder (its top level only, as Zenith reads it), sorted."""
    folder = pathlib.Path(folder)
    if not folder.is_dir():
        sys.exit(f"--models {folder}: no such folder")
    files = sorted(p for p in folder.iterdir()
                   if p.is_file() and not p.name.startswith(".") and p.suffix.lower() in MODEL_FILES)
    if not any(p.suffix.lower() in (".glb", ".gltf") for p in files):
        sys.exit(f"--models {folder}: no .glb or .gltf files in it")
    return files


def package(godot, platform, version, addons=(), channel="public", models=()):
    preset, exe = PRESETS[platform]
    dev = channel == "dev"
    folder = ROOT / "dist" / f"Zenith-{version}{'-dev' if dev else ''}-{platform}{'-unsupported' if platform in UNSUPPORTED else ''}"
    if folder.exists():
        shutil.rmtree(folder)
    export_fn = export_with_etc2 if platform == "macos" else export
    if dev:
        with_dev_feature(godot, preset, folder / exe, export_fn)
    else:
        export_fn(godot, preset, folder / exe)
    if platform == "windows":
        dll = ROOT / "client" / "native" / "bin" / NATIVE_DLL
        print(f"  native belt simulation: {'in the download' if (folder / NATIVE_DLL).exists() else 'not exported'}"
              f"{'' if dll.exists() else ' (no ' + NATIVE_DLL + ' in client/native/bin: belt_sim.gd only)'}")
    shutil.copytree(MOD, folder / "mod" / "factorio-3d-bridge",
                    ignore=shutil.ignore_patterns("__pycache__", ".DS_Store", "Thumbs.db"))
    (folder / "server").mkdir()
    for name in SERVER_FILES:
        shutil.copy2(ROOT / "server" / name, folder / "server" / name)
    for src, dst in DOCS + (DEV_DOCS if dev else []):
        if src.endswith(".md"):
            text = (ROOT / src).read_bytes().decode("utf-8")  # its own line endings kept
            (folder / dst).write_text(channel_doc(text, channel), encoding="utf-8", newline="")
        else:
            shutil.copy2(ROOT / src, folder / dst)
    shown = "Zenith.app" if platform == "macos" else exe
    start = START_HERE.format(version=version, exe=shown) + (START_HERE_DEV if dev else "")
    (folder / "START HERE.txt").write_text(start, encoding="utf-8")
    if platform in UNSUPPORTED:
        what, body = UNSUPPORTED[platform]
        (folder / "UNSUPPORTED.txt").write_text(UNSUPPORTED_HEAD.format(version=version, what=what) + body, encoding="utf-8")
    (folder / "models").mkdir()
    for p in models:
        shutil.copy2(p, folder / "models" / p.name)
    count = sum(1 for p in models if p.suffix.lower() in (".glb", ".gltf"))
    if count:
        print(f"  {count} model(s) in models/")
    (folder / "models" / "README.txt").write_text(MODELS_README + (MODELS_BUNDLED.format(count=count) if count else ""),
                                                  encoding="utf-8")
    (folder / "addons").mkdir()
    (folder / "addons" / "README.txt").write_text(ADDONS_README, encoding="utf-8")
    for name, data, _, _ in addons:
        (folder / "addons" / name).write_bytes(data)
        print(f"  bundled add-on {name}")
    if addons:
        (folder / "addons" / "bundled.json").write_text(json.dumps({a[2]: a[3] for a in addons}, indent=1), encoding="utf-8")
    out = folder.parent / f"{folder.name}.zip"
    app_zip = folder / exe if platform == "macos" else None
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for p in sorted(folder.rglob("*")):
            if not p.is_file() or p == app_zip:
                continue
            info = zipfile.ZipInfo.from_file(p, f"{folder.name}/{p.relative_to(folder).as_posix()}")
            info.compress_type = zipfile.ZIP_DEFLATED
            if p.name.endswith(EXECUTABLE):
                info.external_attr = (0o100755 << 16)
                info.create_system = 3  # Unix, so unzip on Linux and macOS applies the permissions
            z.writestr(info, p.read_bytes())
        if app_zip:
            # Godot's own zip of Zenith.app, entry by entry with its permissions and links.
            with zipfile.ZipFile(app_zip) as app:
                for info in app.infolist():
                    data = app.read(info)
                    info.filename = f"{folder.name}/{info.filename}"
                    z.writestr(info, data)
    print(f"wrote {out} ({out.stat().st_size // (1024 * 1024)} MB)")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--godot", default=default_godot())
    parser.add_argument("--platform", choices=list(PRESETS) + ["supported", "unsupported", "all"], default="windows")
    parser.add_argument("--channel", choices=CHANNELS, default="public",
                        help="public (the release; no testing tools) or dev (development builds: the performance test and debug menu)")
    parser.add_argument("--addon", action="append", default=[], help="a local add-on folder to bundle, :off for off (repeatable)")
    parser.add_argument("--no-addons", action="store_true", help="bundle no add-ons")
    parser.add_argument("--models", help="a folder of a modeller's models to put in the download's models/ folder")
    args = parser.parse_args()
    version = json.loads((MOD / "info.json").read_text())["version"]
    # The game shows its version from project.godot: a download must say the same as its mod.
    shown = re.search(r'^config/version="([^"]*)"', (ROOT / "client" / "project.godot").read_text(), re.M)
    if not shown or shown.group(1) != version:
        sys.exit(f"client/project.godot config/version ({shown.group(1) if shown else 'missing'}) "
                 f"doesn't match the mod's info.json ({version}): set both to the release's version")
    groups = {"all": list(PRESETS), "supported": SUPPORTED, "unsupported": list(UNSUPPORTED)}
    models = bundled_models(args.models) if args.models else []
    addons = gather_addons(args)
    for platform in groups.get(args.platform, [args.platform]):
        package(args.godot, platform, version, addons, args.channel, models)


if __name__ == "__main__":
    main()
