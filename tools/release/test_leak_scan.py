"""leak_scan.py: private dot-paths match, and the public sources carry no generic worktree path.

    python tools/release/test_leak_scan.py

1. A private-paths.txt entry starting with a dot (`.agents/`, `.claude/launch.json`) skips that
   path, not the dotless one (`lstrip("./")` turned `.agents/` into `agents/`).
2. The two public lines the 0.3.1 scan flagged for the generic worktree path (game_swap.gd's played-here
   check, review.py's comment) no longer carry it.
Exits 0 when all pass.
"""
from __future__ import annotations

import pathlib
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

import leak_scan  # noqa: E402

failures: list[str] = []


def check(cond: bool, what: str) -> None:
    if not cond:
        failures.append(what)
        print("FAIL:", what)


with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    tree = root / "tree"
    for rel in (".agents/notes.txt", "agents/public.txt", ".claude/launch.json", "claude/launch.json", "./plain.txt"):
        p = tree / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("TOKEN-XYZ\n", encoding="utf-8")
    strings = root / "strings.txt"
    strings.write_text("TOKEN-XYZ\n", encoding="utf-8")
    private = root / "private.txt"
    private.write_text(".agents/\n.claude/launch.json\n./plain.txt\n", encoding="utf-8")
    hits = leak_scan.scan_target(tree, strings, private)
    hit_files = sorted({h.split(":", 1)[0] for h in hits})
    check(hit_files == ["agents/public.txt", "claude/launch.json"],
          f"private dot-paths skip the dotted path only, the dotless one is scanned: {hit_files}")

    # The public lines: scanned for the generic pattern the release's forbidden-strings list holds.
    generic = root / "generic.txt"
    worktrees = ".claude/" + "worktrees"  # split, so this file doesn't carry the pattern it checks for
    generic.write_text(worktrees + "\n", encoding="utf-8")
    for rel in ("client/scripts/menu/game_swap.gd", "tools/models/review.py"):
        found = leak_scan.scan_target(ROOT / rel, generic, None)
        check(not found, f"{rel} carries no {worktrees}: {found}")

if failures:
    print(f"{len(failures)} leak_scan check(s) failed")
    raise SystemExit(1)
print("leak_scan checks passed")
