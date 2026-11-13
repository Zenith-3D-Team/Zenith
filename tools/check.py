#!/usr/bin/env python3
"""The fast checks for what changed: picks them from the files changed against a base commit, runs
them, and logs how long each took.

    python tools/check.py                    against where this branch left main, uncommitted work too
    python tools/check.py --base HEAD~3      against another commit
    python tools/check.py --list             say what would run, run nothing
    python tools/check.py --ui _terrain,_belt_paths   and those sections of the UI test
    python tools/check.py --done             the change is finished: the slower checks for it as well
                                             (the whole UI test, model loading, model textures)

Nothing here starts Factorio or opens a window. A check that fails is run once more; passing then,
it is reported as flaky and doesn't fail the run. Godot checks have a time limit and also fail on
a SCRIPT ERROR, which a test's exit code can't show. Each check's time and result go to
art-src/check-log.jsonl in the main checkout (git-ignored, one log for every worktree).

Godot: $GODOT, else `godot` on PATH, else the console build under ~/Tools/Godot, else winget's.
Python: this checkout's .venv, else the main checkout's, else the one running this.
"""
import argparse
import dataclasses
import fnmatch
import glob
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time

REPO = pathlib.Path(__file__).resolve().parents[1]
GODOT_LIMIT = 300  # seconds; the tests' own watchdog (client/tests/test_watchdog.gd) stops them first


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=REPO, capture_output=True, text=True, encoding="utf-8", check=True).stdout.strip()


def main_checkout() -> pathlib.Path:
    """The main checkout, also from a worktree (git's common folder is its .git)."""
    return pathlib.Path(git("rev-parse", "--path-format=absolute", "--git-common-dir")).parent


def python_path() -> str:
    for root in (REPO, main_checkout()):
        for rel in ("Scripts/python.exe", "bin/python"):
            p = root / ".venv" / rel
            if p.exists():
                return str(p)
    return sys.executable


def godot_path() -> str | None:
    found = os.environ.get("GODOT") or shutil.which("godot")
    if found:
        return found
    builds = sorted(glob.glob(os.path.expanduser("~/Tools/Godot/Godot_*_console.exe")))
    if builds:
        return builds[-1]
    winget = glob.glob(os.path.expandvars(r"%LOCALAPPDATA%\Microsoft\WinGet\Packages\GodotEngine*\*console.exe"))
    return winget[-1] if winget else None


def changed_files(base: str) -> list[str]:
    """Committed since `base`, changed in the working tree and new, as paths from the repo's root."""
    files = set(git("diff", "--name-only", base).splitlines())
    files |= set(git("ls-files", "--others", "--exclude-standard").splitlines())
    return sorted(f for f in files if f)


def default_base() -> str:
    for ref in ("main", "origin/main"):
        try:
            return git("merge-base", "HEAD", ref)
        except subprocess.CalledProcessError:
            continue
    raise SystemExit("no main branch to compare with: pass --base <commit>")


@dataclasses.dataclass
class Check:
    name: str
    command: list[str]
    godot: bool = False


def any_match(files: list[str], *patterns: str) -> bool:
    return any(fnmatch.fnmatch(f, p) for f in files for p in patterns)


def godot_scene(name: str, scene: str, *args: str) -> Check:
    return Check(name, ["res://tests/" + scene, *args], godot=True)


def godot_script(name: str, script: str) -> Check:
    return Check(name, ["-s", "res://tests/" + script], godot=True)


def plan(files: list[str], ui: str | None, done: bool) -> tuple[list[Check], list[str]]:
    """The checks for these files, and notes on what isn't checked here."""
    py = python_path()
    checks: list[Check] = []
    notes: list[str] = []

    def add(check: Check) -> None:
        if not any(c.name == check.name for c in checks):
            checks.append(check)

    def tool(script: str) -> Check:
        return Check(pathlib.Path(script).stem, [py, script])

    scripts = [f for f in files if f.endswith(".gd") and (REPO / f).exists()]
    if scripts:
        # One Python start for them all: gdparse takes many files.
        add(Check("gdparse", [py, "-m", "gdtoolkit.parser", *scripts]))

    protocol = any_match(files, "tools/protocol.py", "docs/PROTOCOL.md")
    if any_match(files, "mod/*.lua", "tools/mod_tests/*") or protocol:
        add(tool("tools/mod_tests/test_bridge.py"))
        add(tool("tools/mod_tests/test_fuzz.py"))
    if any_match(files, "mod/*/data*.lua", "mod/*/scripts/gfx_extract.lua", "tools/mod_tests/test_data_stage.py"):
        add(tool("tools/mod_tests/test_data_stage.py"))
    if any_match(files, "tools/mock*.py", "tools/test_mock*.py") or protocol:
        add(tool("tools/test_mock_server.py"))
        add(tool("tools/test_mock_fuzz.py"))

    models = sorted({pathlib.Path(f).name[:-4] for f in files if fnmatch.fnmatch(f, "client/assets/models/*.glb")})
    if models:
        add(Check("models check.py", [py, "tools/models/check.py", *models]))
    elif any_match(files, "tools/models/*.py"):
        add(Check("models check.py", [py, "tools/models/check.py"]))

    if any_match(files, "client/scripts/addons/*", "client/tests/addon*", "addons-src/*", "client/scripts/world/looks.gd"):
        add(godot_scene("addon_test", "addon_test.tscn"))
    if any_match(files, "client/scripts/net/bridge.gd", "client/tests/bridge_fuzz*"):
        add(godot_scene("bridge_fuzz_test", "bridge_fuzz_test.tscn"))
    if any_match(files, "client/scripts/world/decorative*", "client/shaders/decorative*", "client/tests/decor*"):
        add(godot_scene("decor_test", "decor_test.tscn"))
    if any_match(files, "client/scripts/vr/*", "client/tests/vr*"):
        add(godot_scene("vr_test", "vr_test.tscn"))
    if any_match(files, "client/scripts/world/mod_files.gd", "client/scripts/world/mod_graphics.gd",
                 "client/scripts/world/sprite_standins.gd", "client/tests/mod_files*"):
        add(godot_script("mod_files_test", "mod_files_test.gd"))

    client_code = any_match(files, "client/scripts/*", "client/tests/ui_test*", "client/tests/test_*")
    if ui:
        add(godot_scene("ui_test " + ui, "ui_test.tscn", "--", "--only=" + ui))
    elif done and client_code:
        add(godot_scene("ui_test", "ui_test.tscn"))
    elif client_code:
        notes.append("the UI test isn't run: --ui <sections> for the sections you touched, --done for all of it once the change is finished")
    if done and (models or any_match(files, "client/scripts/world/model_*.gd", "client/shaders/factorio_material*")):
        add(godot_script("model_load_test", "model_load_test.gd"))
        add(godot_script("model_textures_test", "model_textures_test.gd"))
    elif models:
        notes.append("model loading isn't run: --done once the change is finished")
    if any_match(files, "client/shaders/*"):
        notes.append("shaders have no automatic check here")
    return checks, notes


def run_once(check: Check, godot: str | None) -> tuple[bool, str]:
    """(passed, why not)."""
    command = check.command
    if check.godot:
        if godot is None:
            return False, "no Godot found: set $GODOT"
        command = [godot, "--headless", "--audio-driver", "Dummy", "--path", str(REPO / "client"), *command]
    try:
        done = subprocess.run(command, cwd=REPO, capture_output=True, text=True, encoding="utf-8", errors="replace",
                              timeout=GODOT_LIMIT if check.godot else 600)
    except subprocess.TimeoutExpired:
        return False, "timed out"
    output = done.stdout + done.stderr
    if done.returncode != 0:
        lines = [l for l in output.splitlines() if l.startswith(("FAIL", "SCRIPT ERROR"))] or output.splitlines()[-15:]
        return False, "\n".join(lines[:40])
    if check.godot and "SCRIPT ERROR" in output:
        return False, "\n".join(l for l in output.splitlines() if "SCRIPT ERROR" in l)[:2000]
    return True, ""


def log_result(check: Check, seconds: float, result: str, base: str, attempts: int) -> None:
    path = main_checkout() / "art-src" / "check-log.jsonl"
    path.parent.mkdir(exist_ok=True)
    entry = {"at": time.strftime("%Y-%m-%dT%H:%M:%S"), "branch": git("rev-parse", "--abbrev-ref", "HEAD"), "base": base[:12],
             "check": check.name, "seconds": round(seconds, 1), "result": result, "attempts": attempts}
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(entry) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", help="commit to compare with (default: where this branch left main)")
    ap.add_argument("--ui", metavar="SECTIONS", help="sections of the UI test, comma separated")
    ap.add_argument("--done", action="store_true", help="the change is finished: the slower checks for it too")
    ap.add_argument("--list", action="store_true", help="say what would run, run nothing")
    args = ap.parse_args()

    base = args.base or default_base()
    files = changed_files(base)
    checks, notes = plan(files, args.ui, args.done)
    print(f"{len(files)} files changed against {base[:12]}; {len(checks)} checks")
    if args.list:
        for c in checks:
            print("  " + c.name)
    for note in notes:
        print("note: " + note)
    if args.list or not checks:
        return 0

    godot = godot_path()
    if any(c.godot for c in checks) and godot and not (REPO / "client" / ".godot").exists():
        print("first Godot run in this checkout: importing")
        subprocess.run([godot, "--headless", "--audio-driver", "Dummy", "--path", str(REPO / "client"), "--import"], capture_output=True, timeout=600)

    failed = 0
    total = time.monotonic()
    for check in checks:
        start = time.monotonic()
        passed, why = run_once(check, godot)
        attempts = 1
        if not passed:
            print(f"{check.name}: failed, running it once more\n{why}")
            passed, why = run_once(check, godot)
            attempts = 2
        seconds = time.monotonic() - start
        result = "failed" if not passed else "flaky" if attempts == 2 else "passed"
        log_result(check, seconds, result, base, attempts)
        print(f"{result:7} {seconds:7.1f}s  {check.name}")
        if not passed:
            failed += 1
            print(why)
    print(f"{len(checks) - failed} of {len(checks)} passed in {time.monotonic() - total:.1f}s")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
