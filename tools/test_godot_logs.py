"""A Godot test run as tools/check.py runs it leaves the player's own Godot logs alone.

Zenith's project logs to user://logs/godot.log and keeps 5 rotated logs (Windows:
%APPDATA%/Godot/app_userdata/Zenith/logs). Godot opens that file at start-up, before any script, and
renames the last one aside, so every test run used to rotate a player's log away (a freeze's log was lost
that way). check.py passes `--log-file <art-src/check-logs/<check>.godot.log>` instead; this runs one
short headless test that way and checks:
- the player's logs folder has the same rotated logs (names and times) and the same number of files,
  and godot.log there holds nothing of this run (a game running beside it may still write its own);
- the run's own log exists and holds the run's output.

    python tools/test_godot_logs.py          # needs Godot (as check.py finds it); skips without one
"""
import os
import pathlib
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import check  # noqa: E402

TEST = check.godot_script("belt_caps_test", "belt_caps_test.gd")  # short, headless, prints a summary line


def player_logs() -> pathlib.Path:
    if sys.platform == "win32":
        base = pathlib.Path(os.environ["APPDATA"]) / "Godot"
    elif sys.platform == "darwin":
        base = pathlib.Path.home() / "Library" / "Application Support" / "Godot"
    else:
        base = pathlib.Path(os.environ.get("XDG_DATA_HOME") or pathlib.Path.home() / ".local" / "share") / "godot"
    return base / "app_userdata" / "Zenith" / "logs"


def snapshot(folder: pathlib.Path) -> dict:
    """The rotated logs by name and time, the file count, godot.log's time; {} when there is no folder."""
    if not folder.is_dir():
        return {}
    files = [p for p in folder.iterdir() if p.is_file()]
    rotated = sorted((p.name, p.stat().st_mtime_ns) for p in files if p.name != "godot.log")
    current = folder / "godot.log"
    return {"count": len(files), "rotated": rotated, "godot.log": current.stat().st_mtime_ns if current.exists() else None}


def main() -> int:
    godot = check.godot_path()
    if godot is None:
        print("SKIP: no Godot found (set $GODOT)")
        return 0
    folder = player_logs()
    before = snapshot(folder)
    with tempfile.TemporaryDirectory() as tmp:
        logs = pathlib.Path(tmp)
        passed, why, output = check.run_once(TEST, godot, logs)
        own = logs / (TEST.name + ".godot.log")
        after = snapshot(folder)
        failures = []
        if not passed:
            failures.append("the test itself failed: " + check.first_line(why))
        if not own.exists():
            failures.append(f"the run's own log {own} was not written")
        else:
            text = own.read_text(encoding="utf-8", errors="replace")
            lines = [l for l in output.splitlines() if l.strip() and "Godot Engine" not in l]
            mark = lines[-1].strip() if lines else ""
            if not mark or mark not in text:
                failures.append(f"the run's own log lacks its output's last line {mark!r}")
            elif before.get("godot.log") != after.get("godot.log") and (folder / "godot.log").exists():
                # Written since: by this run, or by a game running beside it? Only this run prints its last line.
                if mark in (folder / "godot.log").read_text(encoding="utf-8", errors="replace"):
                    failures.append(f"this run wrote the player's {folder / 'godot.log'}")
        if before.get("rotated") != after.get("rotated") or before.get("count") != after.get("count"):
            failures.append(f"the player's logs in {folder} changed: {len(before.get('rotated', []))} rotated logs "
                            f"before, {len(after.get('rotated', []))} after; newest before "
                            f"{(before.get('rotated') or [('none',)])[-1][0]}, after {(after.get('rotated') or [('none',)])[-1][0]}")
    for f in failures:
        print("FAIL " + f)
    if failures:
        return 1
    print(f"PASS: {TEST.name} logged to its own file; {folder} unchanged ({before.get('count', 0)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
