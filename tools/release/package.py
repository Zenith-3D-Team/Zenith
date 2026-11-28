"""Builds the download players get: the client exported with Godot, with the bridge mod and the
server scripts beside it, zipped as dist/Zenith-<version>-<platform>.zip. Uploads nothing.

    python3 tools/release/package.py [--godot <godot exe>] [--channel public|dev]
        [--platform windows|linux|linux-arm64|windows-arm64|macos|supported|unsupported|all]
        [--no-addons] [--addon <add-on folder>[:off]]... [--models <folder>]
    python3 tools/release/package.py --models <folder> --zenith-zip <out.zip>   # the zip alone

Two channels (owner: public downloads carry no testing tools; dev builds do). `public`, the
default, is the release on the public repo. `dev` is for testers' builds:
dist/Zenith-<version>-dev-<platform>.zip, exported with the custom feature tag `zenith_dev` (set
on the export preset for that export alone, export_presets.cfg put back after), which
Settings.dev_tools() reads: the main menu's Performance test and --perf-test, the debug menu
(Ctrl+F12) and its overlays are there only then. A dev zip also carries PERFORMANCE-TEST.md and
the docs' dev-build parts (between <!-- dev --> and <!-- /dev --> marks, cut from a public zip's
copies), and START HERE.txt says it is a development build.

Every download can carry Zenith's own add-ons (BUNDLED: the Cinematic camera, switched on; Terrain
Elevation, switched off until the player turns it on; and any local add-ons from addons-src/ such
as cinematic-shaders, immersive-enemies, immersive-weather, or sprint via --addon), each fetched
from a pinned GitHub release tag in BUNDLED (never floating on an unpinned branch) into
addons/<id>_<version>.zip, with addons/bundled.json giving each one's first state
(addon_loader.gd) and BUILD.json recording the build's version, channel, and bundled add-ons.
--addon <folder>[:off] bundles a local folder instead of (or besides) them; --no-addons leaves them all out.

--models <folder> zips a modeller's models (the .glb and .gltf files at the folder's top and in its
items/ folder, with any files a .gltf points at) into the download's models/Zenith.zip beside the program, with a pack.json
(name "Zenith", author Vasillo, his permission) and a README.txt. Zenith reads that folder at
start-up and the zip is a model pack (model_packs.gd), on top of the built-in ones (FUE5, Wube3DP,
Placeholders) the first time, so the download shows them out of the box; the Model packs window
moves it or turns it off, and `-- --no-custom-models` leaves it out. Only for builds whose modeller
agreed (the dev builds with Vasillo's models): the models aren't Zenith's, and the zip and
the models folder's README.txt say so. --zenith-zip <out.zip> (or its old name
--default-zip) writes that zip alone (a source build's models/Zenith.zip) and builds nothing else.

windows and linux are the downloads Zenith supports. linux-arm64 (issue #8), windows-arm64 and
macos (a universal app: Apple Silicon and Intel) are UNSUPPORTED (owner's label): built the same way, never run by
anyone; each zip says so in its name ("-unsupported") and in UNSUPPORTED.txt inside. macOS is
exported from Windows without Apple's signature (ad-hoc only) or notarization.

Needs Godot's export templates for the same version as the editor (Godot: Editor → Manage Export
Templates, or the .tpz from Godot's releases page unpacked into its templates folder). The
exported client finds `mod/` and `server/` next to its own executable (client/scripts/menu/paths.gd),
so the zip unpacks into one folder that runs as it is.

The native belt simulation (client/native/belt_sim.gdextension, docs/RUNNING.md) is copied here, not
exported by Godot: client/native/ is hidden from Godot's editor (client/scripts/native_library.gd loads
it, so platforms without it log no errors). The Windows download gets the .gdextension and
client/native/bin's DLL beside Zenith.exe when the DLL is there (it is committed; nothing here builds
it). The other platforms have no library and run belt_sim.gd. The upscalers library
(client/native/upscalers.gdextension and its git-ignored DLL, client/native/upscalers/build.bat; AMD FSR
3.1/4.1 and NVIDIA DLSS's capability checks and drawing, client/scripts/menu/upscalers.gd) goes beside
Zenith.exe the same way when the DLL is there; --windows-template or --vendor-runtimes without it is an
error (those builds are for the vendor upscalers, which would be greyed out without the library).

--windows-template <exe> exports the Windows download with a self-built Godot template
(tools/godot/build_template.ps1) instead of the official one: the Windows preset's
custom_template/release is set to it for that export alone and export_presets.cfg put back byte
for byte after, as with the dev feature, so no build path is ever committed. Without it nothing
changes: Godot's official template, as before.

--vendor-runtimes <dir>|none puts AMD's FSR runtime libraries into the Windows x86_64 download's
vendor/amd/ (the two signed DLLs and AMD's license.md, from <dir>/amd/, which
tools/release/fetch_vendor_runtimes.py fills). Default none: no vendor files, so a release only
carries them when the owner turns it on. No other platform, and no source archive, ever gets them
(tools/release/leak_scan.py checks that on every zip).

--ship-nvidia (default off; needs --vendor-runtimes <dir>) also puts Zenith's own Streamline build, from
<dir>/streamline-built/ (tools/dlss/build_streamline.ps1: sl.interposer.dll, sl.common.dll, sl.dlss.dll and
zenith-sl-manifest.txt, whose SHA-256s are checked against the manifest), into the Windows x86_64 download's
vendor/nvidia/, and BUILD.json then says "vendor": "amd+nvidia", the one case leak_scan.py lets vendor/nvidia/
through. NVIDIA's own nvngx_dlss.dll is never shipped: the player downloads it. Without the flag, no NVIDIA file.
"""

import argparse
import hashlib
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

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import fetch_vendor_runtimes  # noqa: E402
import leak_scan  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[2]
# BeltSimNative's library and its .gdextension, put beside the program for native_library.gd to load.
NATIVE_CONFIG = ROOT / "client" / "native" / "belt_sim.gdextension"
NATIVE_DLL = "belt_sim.windows.template_release.x86_64.dll"
# The upscalers library (ZenithUpscalerCaps and the vendor upscalers, upscalers.gd), git-ignored: built by
# client/native/upscalers/build.bat, put beside Zenith.exe when it is there.
UPSCALERS_CONFIG = ROOT / "client" / "native" / "upscalers.gdextension"
UPSCALERS_DLL = "upscalers.windows.template_release.x86_64.dll"
NATIVE_BIN = ROOT / "client" / "native" / "bin"
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
# relay.py: the user guide's "The server on another PC" runs it from the download's server folder.
SERVER_FILES = ["server-settings.json", "run-server.ps1", "run-headless.sh", "download-headless.sh", "factorio-with-zenith.ps1",
                "relay.py"]
# The models from Wube's printable release (CC BY-NC) and from FUE5 (CC BY-NC-SA) ship inside the game:
# their per-model lists and licence terms go beside it, as the licences ask.
DOCS = [("LICENSE", "LICENSE.txt"), ("LICENSING.md", "LICENSING.md"), ("CREDITS.md", "CREDITS.md"), ("docs/USER-GUIDE.md", "USER-GUIDE.md"),
        ("docs/ADDONS.md", "ADDONS.md"), ("docs/MODELLERS.md", "MODELLERS.md"),
        ("client/assets/models/packs/wube3dp/CREDITS.md", "MODEL-CREDITS.md"),
        ("client/assets/models/packs/fue5/README.md", "FUE5-MODELS.md"),
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
nothing here, Zenith looks as it always does.

Model packs go here too, like texture packs: a .zip as you downloaded it (no need to unpack it) or a
folder, its models anywhere inside. The loose .glb files here count as one pack. The Model packs
window (the main menu, the Esc menu, Settings) lists them beside Zenith's own (FUE5, Wube3DP and
Placeholders, built in), with how many models each has: move them between Available and Selected,
order them (when two packs have a model of the same name, the higher one wins), and pick a pack for
any one model with its preview. It also opens this folder.

Names are Factorio's internal names, for example:
  transport-belt.glb, transport-belt-curve-left.glb, transport-belt-curve-right.glb
  inserter.glb, inserter-east.glb, inserter-south.glb, inserter-west.glb (the base, per direction)
  inserter-arm-basic-upper.glb, inserter-arm-basic-hand-open.glb, inserter-arm-basic-hand-closed.glb
  burner-mining-drill.glb, burner-mining-drill-east.glb, -south.glb, -west.glb

1 unit = 1 tile, the origin at the footprint's centre on the ground, facing north (Blender +Y).
MODELLERS.md, beside Zenith, has every name, the moving parts and the materials belts need.

To start Zenith with its own models only, without removing these: move the packs to Available in
the Model packs window, or start it with
  -- --no-custom-models
after the program's name (a shortcut's Target), or empty this folder.
"""


# Added to the models folder's README.txt when the download comes with models in it (--models).
MODELS_BUNDLED = """
This download comes with Zenith.zip here: {count} models made by Vasillo for Zenith and used with
his permission (CREDITS.md beside Zenith). They aren't Zenith's own and aren't under its GPL
licence. Move Zenith to Available in the Model packs window, remove the zip, or start Zenith with
-- --no-custom-models, to see Zenith's own.
"""
# The bundled models' pack (--models): models/Zenith.zip's pack.json and README.txt (it was Default.zip, "Default":
# Zenith reads an old one as this pack).
BUNDLED_ZIP = "Zenith.zip"
DEFAULT_PACK = {
    "name": "Zenith",
    "author": "Vasillo",
    "licence": "\u00a9 David (Vasillo), used in Zenith with his permission; not under Zenith's GPL licence",
    # The Model packs window's line over the preview (pack.json "credit", used as it is).
    "credit": "© Vasillo · used with permission",
    "description": "Vasillo's textured models made for Zenith: transport belts of every tier with curves, start and end pieces, underground belts, splitters, inserters, mining drills, pipes, stone walls, gate, ores, and item models (including science packs, engines, ammo, rockets, and grenades).",
    "icon": "transport-belt-curve-left",
    # Zenith's gear (Vasillo's too, client/assets/branding/README.md), put in the zip by default_zip.
    "icon_image": "zenith.png",
    # His textures drawn as their files say (pack.json "shading", model_packs.gd shading()).
    "shading": "pbr",
    # Item lane offset from each belt's centre line tuned for Vasillo's belt rails and PBR geometry
    # (pack.json "belt_lane_offset", belt_lane_inset.gd).
    "belt_lane_offset": 0.16,
    # His belt surface (the Belt_Surface mesh of transport-belt, curves, undergrounds, ends and splitter alike)
    # tops out at 0.25: the items' lowest points rest on it, not 0.02 above it (belt_lane_inset.gd item_height).
    "belt_item_height": 0.25,
}
DEFAULT_ICON = ROOT / "client" / "icon.png"
DEFAULT_README = """Zenith: Vasillo's models for Zenith.

These models were made by David (Vasillo) for Zenith and are used in it with his permission. They
aren't Zenith's own and aren't under its GPL licence: don't pass them on apart from Zenith.
Zenith reads this zip as it is (no need to unpack it); the Model packs window orders it among the
other packs or turns it off.
"""


ADDONS_README = """Zenith add-ons go here: each a .zip as you downloaded it (no need to unpack it), or a folder
with its addon.json (or put them in Zenith's user data folder, which keeps them across updates).
The Add-ons menu (main menu, Esc menu, Settings) lists them, with a switch, settings and keys for
each. An add-on is a program running with your rights, so one you add is off until you switch it on
there: switch on only add-ons from people you trust. ADDONS.md says how to write one.
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
        subprocess.run([godot, "--headless", "--path", str(client), *godot_log("import " + preset), "--import"], capture_output=True, text=True)
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


def set_preset_option(text, preset, key, value):
    """export_presets.cfg text with `key` in the options of the preset named `preset` set to `value`."""
    lines = text.splitlines(keepends=True)
    section, number, found = None, None, False
    for i, raw in enumerate(lines):
        line = raw.rstrip("\r\n")
        if line.startswith("["):
            section = line
            continue
        if number is None and line == f'name="{preset}"' and re.fullmatch(r"\[preset\.\d+\]", section or ""):
            number = section[len("[preset."):-1]
        elif number is not None and section == f"[preset.{number}.options]" and line.startswith(key + "="):
            quoted = value.replace("\\", "/").replace('"', '\\"')
            lines[i] = f'{key}="{quoted}"' + raw[len(line):]
            found = True
            break
    if number is None:
        raise ValueError(f"no export preset named {preset}")
    if not found:
        raise ValueError(f"export preset {preset} has no {key} line")
    return "".join(lines)


def with_windows_template(template, export_fn):
    """export_fn with the preset's custom_template/release set to `template` for that one export,
    export_presets.cfg put back byte for byte after (no build path committed)."""
    def run(godot, preset, out_exe):
        presets = ROOT / "client" / "export_presets.cfg"
        before = presets.read_bytes()
        presets.write_text(set_preset_option(before.decode("utf-8"), preset, "custom_template/release", template),
                           encoding="utf-8", newline="")
        try:
            export_fn(godot, preset, out_exe)
        finally:
            presets.write_bytes(before)
    return run


def channel_doc(text, channel):
    """A doc as the channel ships it: dev-build parts kept without their marks, or cut."""
    if channel == "dev":
        return DEV_INLINE.sub(r"\1", DEV_BLOCK.sub(r"\1", text))
    return DEV_INLINE.sub("", DEV_BLOCK.sub("", text))


def godot_log(name):
    """`--log-file` for a build's Godot run: its log in art-src/release-logs/ (git-ignored), not the
    project's user://logs/, where it would rotate the player's own logs away."""
    folder = ROOT.resolve() / "art-src" / "release-logs"  # absolute: a relative one is user://'s
    folder.mkdir(parents=True, exist_ok=True)
    return ["--log-file", str(folder / (re.sub(r"[^\w.-]+", "_", name) + ".godot.log"))]


def export(godot, preset, out_exe):
    out_exe.parent.mkdir(parents=True, exist_ok=True)
    cmd = [godot, "--headless", "--path", str(ROOT / "client"), *godot_log("export " + preset), "--export-release", preset, str(out_exe)]
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


# In-repo add-ons under addons-src/ (each can be bundled locally with --addon addons-src/<name>).
IN_REPO_ADDONS = {
    "cinematic-shaders": {"path": "addons-src/cinematic-shaders", "default_on": True},
    "immersive-enemies": {"path": "addons-src/immersive-enemies", "default_on": True},
    "immersive-weather": {"path": "addons-src/immersive-weather", "default_on": True},
    "sprint": {"path": "addons-src/sprint", "default_on": False},
}

# Zenith's own external add-ons, in every download unless --no-addons is passed.
# Each entry pins a GitHub repo and release tag (e.g. "v0.3.0"); an empty tag requires
# setting the pinned tag here when cutting a release or passing --no-addons with --addon <folder>.
BUNDLED = [
    {"repo": "unjustodin/Zenith-Cinematic-Camera", "tag": "", "on": True},
    {"repo": "unjustodin/Terrain-Elevation", "tag": "", "on": True},
]


def _get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "zenith-package", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def zip_manifest(data):
    """An add-on zip's addon.json (at its root or one folder down), or None."""
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        names = [n for n in z.namelist() if n == "addon.json" or (n.count("/") == 1 and n.endswith("/addon.json"))]
        return json.loads(z.read(sorted(names, key=len)[0])) if names else None


def fetch_addon(repo, tag):
    """Fetch an add-on's zip from a pinned GitHub release tag (its first .zip asset, else tag archive)."""
    if not tag:
        sys.exit(f"{repo} has no pinned release tag in BUNDLED: set 'tag' in package.py or pass --no-addons / --addon <folder>")
    try:
        release = json.loads(_get(f"https://api.github.com/repos/{repo}/releases/tags/{tag}"))
        assets = [a for a in release.get("assets", []) if a["name"].endswith(".zip")]
        if assets:
            return _get(assets[0]["browser_download_url"]), f"github:{repo}@{tag}"
    except urllib.error.HTTPError:
        pass  # fall back to the pinned tag archive
    return _get(f"https://github.com/{repo}/archive/refs/tags/{tag}.zip"), f"github:{repo}@{tag}"


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


def _safe_local_source(folder):
    """Repo-relative POSIX path when inside ROOT, else folder basename only (never leak user paths)."""
    resolved = pathlib.Path(folder).resolve()
    try:
        return f"local:{resolved.relative_to(ROOT).as_posix()}"
    except ValueError:
        return f"local:{resolved.name}"


def gather_addons(args):
    """List of dicts {filename, data, id, version, source, on} for the downloads, fetched once."""
    local_addons = []
    override_ids = set()
    for spec in getattr(args, "addon", ()):
        # Only a trailing :off or :on is the state: a Windows path has its own colon (C:\...).
        folder, state = spec, "on"
        if spec.endswith((":off", ":on")):
            folder, _, state = spec.rpartition(":")
        data = folder_zip(folder)
        m = zip_manifest(data)
        if not m:
            sys.exit(f"--addon {folder}: no addon.json in that folder")
        override_ids.add(m["id"])
        local_addons.append({
            "filename": f"{m['id']}_{m['version']}.zip",
            "data": data,
            "id": m["id"],
            "version": str(m["version"]),
            "source": _safe_local_source(folder),
            "on": state != "off",
        })

    out = []
    channel = getattr(args, "channel", "public")
    if not getattr(args, "no_addons", False):
        for entry in BUNDLED:
            repo = entry["repo"]
            tag = entry["tag"]
            on = entry["on"]
            hint_id = repo.rsplit("/", 1)[-1].removeprefix("Zenith-").lower()
            if hint_id in override_ids:
                continue
            if not tag and channel == "dev":
                print(f"note: skipping untagged bundled add-on {repo} on dev channel (pass --addon <folder> to bundle locally)")
                continue
            data, where = fetch_addon(repo, tag)
            m = zip_manifest(data)
            if not m:
                sys.exit(f"{repo} ({where}) has no addon.json")
            if m["id"] in override_ids:
                continue
            print(f"add-on {m['id']} {m['version']} from {repo}, {where}, {'on' if on else 'off'}")
            out.append({
                "filename": f"{m['id']}_{m['version']}.zip",
                "data": data,
                "id": m["id"],
                "version": str(m["version"]),
                "source": where,
                "on": on,
            })

    for a in local_addons:
        out = [x for x in out if x["id"] != a["id"]]
        out.append(a)
    return out


# Files a modeller's folder can hold for a model: the models themselves, and what a .gltf points at.
MODEL_FILES = (".glb", ".gltf", ".bin", ".png", ".jpg", ".jpeg", ".webp", ".ktx2")


def bundled_models(folder):
    """The model files in a --models folder, sorted, as (file, its name in the zip): the folder's top
    level, then its items/ folder (a pack's item models, which Zenith finds only there) as items/<name>."""
    folder = pathlib.Path(folder)
    if not folder.is_dir():
        sys.exit(f"--models {folder}: no such folder")

    def model_files(where):
        return sorted(p for p in where.iterdir()
                      if p.is_file() and not p.name.startswith(".") and p.suffix.lower() in MODEL_FILES)

    files = model_files(folder)
    if (folder / "items").is_dir():
        files += model_files(folder / "items")
    if not any(p.suffix.lower() in (".glb", ".gltf") for p in files):
        sys.exit(f"--models {folder}: no .glb or .gltf files in it")
    return [(p, p.relative_to(folder).as_posix()) for p in files]


def default_zip(models, out):
    """models/Zenith.zip from a modeller's model files (bundled_models): them at its top (items/ for a pack's items), with
    DEFAULT_PACK as its pack.json, DEFAULT_README and Zenith's gear as the pack's picture. The models
    are stored, not deflated: .glb files hardly shrink, and Zenith unpacks the zip once (model_packs.gd) faster so."""
    out = pathlib.Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
        z.writestr("pack.json", json.dumps(DEFAULT_PACK, indent=1, ensure_ascii=False) + "\n")
        z.writestr("README.txt", DEFAULT_README)
        z.write(DEFAULT_ICON, DEFAULT_PACK["icon_image"])
        for p, name in models:
            z.write(p, name)
    return sum(1 for p, _ in models if p.suffix.lower() in (".glb", ".gltf"))


def template_label(template):
    """BUILD.json's "template": "official", or "our build: <its BUILD.txt's first line>" (beside the exe,
    tools/godot/build_template.ps1 writes it), or "our build: <exe name>" without one."""
    if not template:
        return "official"
    build_txt = pathlib.Path(template).parent / "BUILD.txt"
    first = ""
    if build_txt.is_file():
        lines = build_txt.read_text(encoding="utf-8-sig", errors="replace").splitlines()
        first = lines[0].strip() if lines else ""
    return "our build: " + (first or pathlib.Path(template).name)


def vendor_label(vendor_runtimes, ship_nvidia=False):
    """BUILD.json's "vendor": none, amd, or amd+nvidia (NVIDIA's are only with --ship-nvidia)."""
    parts = (["amd"] if vendor_runtimes else []) + (["nvidia"] if ship_nvidia else [])
    return "+".join(parts) or "none"


def copy_native_libraries(folder, bin_dir=None):
    """belt_sim's and the upscalers' .gdextension + DLL beside Zenith.exe, each when its DLL is there.
    Returns {"belt_sim": bool, "upscalers": bool} and prints a line for each."""
    bin_dir = pathlib.Path(bin_dir) if bin_dir else NATIVE_BIN
    got = {}
    for key, config, name, without in (
            ("belt_sim", NATIVE_CONFIG, NATIVE_DLL, "belt_sim.gd only"),
            ("upscalers", UPSCALERS_CONFIG, UPSCALERS_DLL, "AMD FSR 3.1/4.1 and DLSS greyed out")):
        dll = bin_dir / name
        got[key] = dll.exists()
        if got[key]:
            shutil.copy2(config, folder / config.name)
            shutil.copy2(dll, folder / name)
    print(f"  native belt simulation: {'in the download' if got['belt_sim'] else 'not in it'}"
          f"{'' if got['belt_sim'] else ' (no ' + NATIVE_DLL + ' in client/native/bin: belt_sim.gd only)'}")
    print(f"  upscalers library: {'in the download' if got['upscalers'] else 'not in it'}"
          f"{'' if got['upscalers'] else ' (no ' + UPSCALERS_DLL + ' in client/native/bin: AMD FSR 3.1/4.1 and DLSS greyed out)'}")
    return got


def require_upscalers(windows_template, vendor_runtimes, bin_dir=None):
    """Stop when a build meant for the vendor upscalers (--windows-template, --vendor-runtimes) has no upscalers DLL."""
    bin_dir = pathlib.Path(bin_dir) if bin_dir else NATIVE_BIN
    asked = [f for f, v in (("--windows-template", windows_template), ("--vendor-runtimes", vendor_runtimes)) if v]
    if asked and not (bin_dir / UPSCALERS_DLL).is_file():
        raise SystemExit(f"{' and '.join(asked)} need the upscalers library, but client/native/bin has no {UPSCALERS_DLL}: "
                         "build it with client/native/upscalers/build.bat (or copy the main checkout's)")


def build_manifest(version, channel, addons, template="official", vendor="none"):
    """Return the BUILD.json payload recording Zenith version, channel, Godot template, vendor runtimes, and bundled add-ons."""
    return {
        "version": version,
        "channel": channel,
        "template": template,
        "vendor": vendor,
        "addons": [
            {
                "id": a["id"],
                "version": a["version"],
                "source": a["source"],
                "on": a["on"],
            }
            for a in addons
        ],
    }


def validate_versions(version, project_path=None, presets_path=None):
    """Verify project.godot config/version and export_presets.cfg version strings match info.json."""
    project_path = pathlib.Path(project_path) if project_path else ROOT / "client" / "project.godot"
    presets_path = pathlib.Path(presets_path) if presets_path else ROOT / "client" / "export_presets.cfg"
    shown = re.search(r'^config/version="([^"]*)"', project_path.read_text(encoding="utf-8"), re.M)
    if not shown or shown.group(1) != version:
        raise ValueError(
            f"{project_path} config/version ({shown.group(1) if shown else 'missing'}) "
            f"doesn't match the mod's info.json ({version}): set both to the release's version"
        )
    presets_txt = presets_path.read_text(encoding="utf-8")
    for m in re.finditer(r'^(application/(?:short_)?version)="([^"]*)"', presets_txt, re.M):
        if m.group(2) != version:
            raise ValueError(
                f"{presets_path} {m.group(1)} ({m.group(2)}) "
                f"doesn't match the mod's info.json ({version}): set all preset versions to {version}"
            )


NVIDIA_FILES = leak_scan.VENDOR_NVIDIA_FILES
NVIDIA_MANIFEST = "zenith-sl-manifest.txt"


def copy_nvidia_runtimes(src, folder):
    """Copy <src>/streamline-built/ (Zenith's Streamline build: three DLLs + zenith-sl-manifest.txt) to
    <folder>/vendor/nvidia/, all four or an error, each DLL's SHA-256 matching the manifest. Never nvngx_dlss.dll."""
    built = pathlib.Path(src) / "streamline-built"
    missing = [n for n in NVIDIA_FILES if not (built / n).is_file()]
    if missing:
        raise SystemExit(f"--ship-nvidia: {built} lacks {', '.join(missing)} (tools/dlss/build_streamline.ps1)")
    pins = {}
    for line in (built / NVIDIA_MANIFEST).read_text(encoding="utf-8-sig", errors="replace").splitlines():
        parts = line.split()
        if len(parts) == 2 and not line.lstrip().startswith("#"):
            pins[parts[1]] = parts[0].lower()
    for n in NVIDIA_FILES:
        if n == NVIDIA_MANIFEST:
            continue
        got = hashlib.sha256((built / n).read_bytes()).hexdigest()
        if pins.get(n) != got:
            raise SystemExit(f"--ship-nvidia: {n}'s SHA-256 doesn't match {NVIDIA_MANIFEST} (rebuild with tools/dlss/build_streamline.ps1)")
    (folder / "vendor" / "nvidia").mkdir(parents=True)
    for n in NVIDIA_FILES:
        shutil.copy2(built / n, folder / "vendor" / "nvidia" / n)
    print(f"  vendor/nvidia: {', '.join(NVIDIA_FILES)} (Zenith's Streamline build; no nvngx_dlss.dll)")


def copy_vendor_runtimes(src, folder):
    """Copy <src>/amd/ (AMD's two signed DLLs and license.md) to <folder>/vendor/amd/. All three or an error."""
    amd = pathlib.Path(src) / "amd"
    names = list(fetch_vendor_runtimes.AMD_DLLS) + [fetch_vendor_runtimes.AMD_LICENSE]
    missing = [n for n in names if not (amd / n).is_file()]
    if missing:
        raise SystemExit(f"--vendor-runtimes: {amd} lacks {', '.join(missing)} "
                         "(python tools/release/fetch_vendor_runtimes.py)")
    (folder / "vendor" / "amd").mkdir(parents=True)
    for n in names:
        shutil.copy2(amd / n, folder / "vendor" / "amd" / n)
    print(f"  vendor/amd: {', '.join(names)}")


def package(godot, platform, version, addons=(), channel="public", models=(), windows_template=None,
            vendor_runtimes=None, ship_nvidia=False):
    preset, exe = PRESETS[platform]
    dev = channel == "dev"
    folder = ROOT / "dist" / f"Zenith-{version}{'-dev' if dev else ''}-{platform}{'-unsupported' if platform in UNSUPPORTED else ''}"
    if folder.exists():
        shutil.rmtree(folder)
    export_fn = export_with_etc2 if platform == "macos" else export
    if windows_template and platform == "windows":
        export_fn = with_windows_template(windows_template, export_fn)
        print(f"  Godot template: self-built ({pathlib.Path(windows_template).name})")
    if dev:
        with_dev_feature(godot, preset, folder / exe, export_fn)
    else:
        export_fn(godot, preset, folder / exe)
    if platform == "windows":
        copy_native_libraries(folder)
        if vendor_runtimes:
            copy_vendor_runtimes(vendor_runtimes, folder)
        if vendor_runtimes and ship_nvidia:
            copy_nvidia_runtimes(vendor_runtimes, folder)
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
    count = default_zip(models, folder / "models" / BUNDLED_ZIP) if models else 0
    if count:
        print(f"  {count} model(s) in models/{BUNDLED_ZIP}")
    (folder / "models" / "README.txt").write_text(MODELS_README + (MODELS_BUNDLED.format(count=count) if count else ""),
                                                  encoding="utf-8")
    (folder / "addons").mkdir()
    (folder / "addons" / "README.txt").write_text(ADDONS_README, encoding="utf-8")
    for a in addons:
        (folder / "addons" / a["filename"]).write_bytes(a["data"])
        print(f"  bundled add-on {a['filename']}")
    if addons:
        (folder / "addons" / "bundled.json").write_text(json.dumps({a["id"]: a["on"] for a in addons}, indent=1), encoding="utf-8")
    windows = platform == "windows"
    manifest = build_manifest(version, channel, addons, template_label(windows_template if windows else None),
                              vendor_label(vendor_runtimes if windows else None,
                                           bool(windows and vendor_runtimes and ship_nvidia)))
    (folder / "BUILD.json").write_text(json.dumps(manifest, indent=1) + "\n", encoding="utf-8")
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
    with zipfile.ZipFile(out) as zf:
        # (The scan's yes is this run's own --ship-nvidia, never the zip's BUILD.json alone.)
        problems = leak_scan.vendor_problems(out.name, [i.filename for i in zf.infolist()],
                                             bool(ship_nvidia) and leak_scan.zip_ships_nvidia(zf))
    if problems:
        out.unlink()
        raise SystemExit("vendor files in the wrong place, zip removed: " + "; ".join(problems))
    print(f"wrote {out} ({out.stat().st_size // (1024 * 1024)} MB)")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--godot", default=default_godot())
    parser.add_argument("--platform", choices=list(PRESETS) + ["supported", "unsupported", "all"], default="windows")
    parser.add_argument("--channel", choices=CHANNELS, default="public",
                        help="public (the release; no testing tools) or dev (the performance test and debug menu)")
    parser.add_argument("--addon", action="append", default=[], help="a local add-on folder to bundle, :off for off (repeatable)")
    parser.add_argument("--no-addons", action="store_true", help="bundle no add-ons")
    parser.add_argument("--models", help="a folder of a modeller's models to put in the download's models/" + BUNDLED_ZIP)
    parser.add_argument("--zenith-zip", "--default-zip", dest="zenith_zip", metavar="OUT",
                        help="with --models: write that " + BUNDLED_ZIP + " to OUT and nothing else (--default-zip: its old name)")
    parser.add_argument("--windows-template", metavar="EXE",
                        help="a self-built Godot Windows release template (tools/godot/build_template.ps1) "
                             "for the Windows export, instead of the official one")
    parser.add_argument("--vendor-runtimes", default="none", metavar="DIR|none",
                        help="a folder holding amd/ (tools/release/fetch_vendor_runtimes.py) to put in the Windows "
                             "x86_64 download's vendor/amd/; none (default): no vendor files")
    parser.add_argument("--ship-nvidia", action="store_true",
                        help="with --vendor-runtimes: also put Zenith's Streamline build (<dir>/streamline-built/) in the "
                             "Windows x86_64 download's vendor/nvidia/ (never nvngx_dlss.dll); default off")
    args = parser.parse_args()
    vendor = None
    if args.vendor_runtimes.lower() != "none":
        vendor = pathlib.Path(args.vendor_runtimes).resolve()
        if not vendor.is_dir():
            sys.exit(f"--vendor-runtimes: no such folder {vendor}")
    template = None
    if args.windows_template:
        template = pathlib.Path(args.windows_template).resolve()
        if not template.is_file():
            sys.exit(f"--windows-template: no such file {template}")
        template = str(template)
    try:
        require_upscalers(template, vendor)
    except SystemExit as exc:
        sys.exit(str(exc))
    if args.ship_nvidia and not vendor:
        sys.exit("--ship-nvidia needs --vendor-runtimes <dir> (its streamline-built/ folder)")
    if args.zenith_zip:
        if not args.models:
            sys.exit("--zenith-zip needs --models <folder>")
        count = default_zip(bundled_models(args.models), args.zenith_zip)
        print(f"wrote {args.zenith_zip}: {count} model(s), pack.json, README.txt and zenith.png")
        return
    version = json.loads((MOD / "info.json").read_text())["version"]
    try:
        validate_versions(version)
    except ValueError as exc:
        sys.exit(str(exc))
    groups = {"all": list(PRESETS), "supported": SUPPORTED, "unsupported": list(UNSUPPORTED)}
    models = bundled_models(args.models) if args.models else []
    addons = gather_addons(args)
    for platform in groups.get(args.platform, [args.platform]):
        package(args.godot, platform, version, addons, args.channel, models, template,
                vendor if platform == "windows" else None, args.ship_nvidia)


if __name__ == "__main__":
    main()
