#!/usr/bin/env python3
"""Scan all mod/factorio-3d-bridge/**/*.lua files for duplicate Factorio event registrations.

Factorio's `script.on_event(event_id, handler)` silently overwrites any earlier handler
for the same `defines.events.<name>`, so accidental duplicate registrations across modules
break one of the handlers without warning.

    python3 tools/mod_tests/test_events.py
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
MOD_DIR = ROOT / "mod" / "factorio-3d-bridge"

_ON_EVENT_RE = re.compile(
    r"script\.on_event\s*\(\s*(\{[^}]*\}|defines\.events\.[A-Za-z0-9_]+)",
    re.S,
)
_DEFINE_EVENT_RE = re.compile(r"defines\.events\.([A-Za-z0-9_]+)")


def _strip_lua_comments_preserve_lines(text: str) -> str:
    """Replace Lua line and long-bracket comments with spaces while keeping newlines intact."""
    out: list[str] = []
    i = 0
    n = len(text)
    in_str: str | None = None
    while i < n:
        ch = text[i]
        if in_str is not None:
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if ch == in_str:
                in_str = None
            i += 1
            continue
        if ch in ('"', "'"):
            in_str = ch
            out.append(ch)
            i += 1
            continue
        if ch == "-" and i + 1 < n and text[i + 1] == "-":
            # Check for long-bracket block comment `--[=*[`
            m_blk = re.match(r"--\[(=*)\[", text[i:])
            if m_blk:
                close_pat = "]" + m_blk.group(1) + "]"
                end_idx = text.find(close_pat, i + len(m_blk.group(0)))
                seg = text[i:] if end_idx == -1 else text[i : end_idx + len(close_pat)]
                out.append("".join("\n" if c == "\n" else " " for c in seg))
                i += len(seg)
                continue
            # Line comment up to newline
            nl = text.find("\n", i)
            end = n if nl == -1 else nl
            out.append(" " * (end - i))
            i = end
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def find_event_registrations(mod_dir: pathlib.Path) -> dict[str, list[tuple[str, int]]]:
    """Return {event_name: [(relative_path, 1_based_line), ...]} for all defines.events.* registrations."""
    registrations: dict[str, list[tuple[str, int]]] = {}
    for lua_path in sorted(mod_dir.rglob("*.lua")):
        if not lua_path.is_file():
            continue
        rel = lua_path.relative_to(ROOT).as_posix()
        raw = lua_path.read_text(encoding="utf-8", errors="replace")
        cleaned = _strip_lua_comments_preserve_lines(raw)
        for m in _ON_EVENT_RE.finditer(cleaned):
            arg_text = m.group(1)
            arg_start = m.start(1)
            for ev_m in _DEFINE_EVENT_RE.finditer(arg_text):
                ev_name = ev_m.group(1)
                abs_pos = arg_start + ev_m.start()
                line_no = cleaned.count("\n", 0, abs_pos) + 1
                registrations.setdefault(ev_name, []).append((rel, line_no))
    return registrations


def main() -> int:
    if not MOD_DIR.is_dir():
        print(f"FAIL: mod directory not found: {MOD_DIR}")
        return 1
    registrations = find_event_registrations(MOD_DIR)
    duplicates = {ev: locs for ev, locs in sorted(registrations.items()) if len(locs) > 1}
    if duplicates:
        for ev, locs in duplicates.items():
            where = ", ".join(f"{path}:{line}" for path, line in locs)
            print(f"FAIL: duplicate script.on_event for defines.events.{ev}: {where}")
        return 1
    print(f"event registration check passed ({len(registrations)} unique defines.events.* handlers, 0 duplicates)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
