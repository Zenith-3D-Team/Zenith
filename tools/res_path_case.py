#!/usr/bin/env python3
"""Every res:// path (and relative preload/load path) in the client spelled as the file on disk.

    python tools/res_path_case.py            # client/**/*.gd, .tscn, .tres, .gdshader(inc), project.godot, ...
    python tools/res_path_case.py FILE...    # just these

Windows and macOS find `res://Scripts/Foo.gd` for scripts/foo.gd; Linux (CI's ui job, the Linux zip) doesn't, and
a preload with the wrong case is a parse error there. A path whose file exists only with other letter case is a
finding; a path that names no file at all is left alone (built at run time, optional, a user:// copy, ...).
Exit code 0 when clean, 1 with one line per finding (file:line: path -> on disk).
"""
from __future__ import annotations

import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
CLIENT = ROOT / "client"
EXTS = {".gd", ".tscn", ".tres", ".gdshader", ".gdshaderinc", ".godot", ".gdextension", ".cfg", ".import"}
SKIP_DIRS = {".godot", ".import", "native"}  # Godot's cache; native/ holds C++ (its .gdextension is checked)

RES = re.compile(r"res://[^\"'\s)\]}>,;]+")
REL_LOAD = re.compile(r"\b(?:pre)?load\(\s*\"((?!res://|user://|uid://)[^\"%{}]+)\"\s*\)")


class DiskIndex:
    """Case-insensitive lookup of the real spelling of each path under client/."""

    def __init__(self, root: pathlib.Path) -> None:
        self.root = root
        self._dirs: dict[pathlib.Path, dict[str, str]] = {}

    def _names(self, d: pathlib.Path) -> dict[str, str]:
        if d not in self._dirs:
            try:
                self._dirs[d] = {n.lower(): n for n in os.listdir(d)}
            except OSError:
                self._dirs[d] = {}
        return self._dirs[d]

    def real(self, rel: str) -> str | None:
        """The on-disk spelling of `rel` (posix, under root), or None when no file matches in any case."""
        cur = self.root
        out: list[str] = []
        for part in rel.split("/"):
            if part in ("", "."):
                continue
            if part == "..":
                cur = cur.parent
                out.append("..")
                continue
            got = self._names(cur).get(part.lower())
            if got is None:
                return None
            out.append(got)
            cur = cur / got
        return "/".join(out)


def _clean(path: str) -> str | None:
    """The file part of a res:// string, or None when it is built at run time (format, concatenation, dir)."""
    p = path[len("res://"):]
    p = p.split("::", 1)[0]  # sub-resource ids
    if not p or p.endswith("/") or any(c in p for c in "%{}*+\\$"):
        return None
    return p.rstrip(".")


def check_file(path: pathlib.Path, index: DiskIndex | None = None) -> list[str]:
    index = index or DiskIndex(CLIENT)
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    try:
        rel = path.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        rel = path.as_posix()
    found: list[str] = []
    for no, line in enumerate(text.split("\n"), 1):
        for m in RES.finditer(line):
            p = _clean(m.group(0))
            if p is None:
                continue
            real = index.real(p)
            if real is not None and real != p:
                found.append(f"{rel}:{no}: res://{p} -> res://{real} on disk (Linux is case-sensitive)")
        if path.suffix == ".gd":
            for m in REL_LOAD.finditer(line):
                p = m.group(1)
                try:
                    base = path.resolve().parent.relative_to(CLIENT.resolve()).as_posix()
                except ValueError:
                    continue
                joined = os.path.normpath(os.path.join(base, p)).replace("\\", "/")
                real = index.real(joined)
                if real is not None and real != joined:
                    found.append(f"{rel}:{no}: \"{p}\" -> res://{real} on disk (Linux is case-sensitive)")
    return found


def client_files() -> list[pathlib.Path]:
    out = []
    for dirpath, dirnames, filenames in os.walk(CLIENT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for f in filenames:
            if pathlib.Path(f).suffix in EXTS:
                out.append(pathlib.Path(dirpath) / f)
    for g in CLIENT.glob("native/*.gdextension"):
        out.append(g)
    return sorted(out)


def main(argv: list[str]) -> int:
    files = [pathlib.Path(a) for a in argv] if argv else client_files()
    index = DiskIndex(CLIENT)
    found: list[str] = []
    for f in files:
        found += check_file(f, index)
    for line in found:
        print(line)
    print(f"res_path_case: {len(files)} files, {len(found)} finding(s)")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
