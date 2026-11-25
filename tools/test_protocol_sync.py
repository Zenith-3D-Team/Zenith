#!/usr/bin/env python3
"""Verify PROTOCOL, WIRE_VERSION, and client command handlers stay synced across mod, client, mock, and protocol.py.

    python tools/test_protocol_sync.py
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import protocol  # noqa: E402

failures: list[str] = []


def check(cond: bool, what: str) -> None:
    if cond:
        print(f"ok   {what}")
    else:
        failures.append(what)
        print(f"FAIL {what}")


def _extract_int(path: pathlib.Path, pattern: str) -> int | None:
    text = path.read_text(encoding="utf-8")
    m = re.search(pattern, text, re.M)
    return int(m.group(1)) if m else None


def _lua_handlers(path: pathlib.Path) -> set[str]:
    text = path.read_text(encoding="utf-8")
    return set(re.findall(r"^\s*(?:function\s+)?handlers\.([a-z0-9_]+)\s*(?:\(|=)", text, re.M))


def main() -> int:
    session_lua = ROOT / "mod" / "factorio-3d-bridge" / "scripts" / "session.lua"
    space_lua = ROOT / "mod" / "factorio-3d-bridge" / "scripts" / "space.lua"
    transport_lua = ROOT / "mod" / "factorio-3d-bridge" / "scripts" / "transport.lua"
    bridge_gd = ROOT / "client" / "scripts" / "net" / "bridge.gd"
    wire_decode_gd = ROOT / "client" / "scripts" / "net" / "wire_decode.gd"
    mock_server_py = ROOT / "tools" / "mock_server.py"

    proto_vals = {
        "session.lua": _extract_int(session_lua, r"M\.PROTOCOL\s*=\s*(\d+)"),
        "bridge.gd": _extract_int(bridge_gd, r"const\s+PROTOCOL\s*:?=\s*(\d+)"),
        "mock_server.py": _extract_int(mock_server_py, r"^PROTOCOL\s*=\s*(\d+)"),
    }
    check(
        all(v is not None for v in proto_vals.values()) and len(set(proto_vals.values())) == 1,
        f"PROTOCOL synced across session.lua, bridge.gd, mock_server.py: {proto_vals}",
    )

    wire_vals = {
        "protocol.py": int(protocol.WIRE_VERSION),
        "transport.lua": _extract_int(transport_lua, r"M\.WIRE_VERSION\s*=\s*(\d+)"),
        "wire_decode.gd": _extract_int(wire_decode_gd, r"const\s+WIRE_VERSION\s*:?=\s*(\d+)"),
    }
    check(
        all(v is not None for v in wire_vals.values()) and len(set(wire_vals.values())) == 1,
        f"WIRE_VERSION synced across protocol.py, transport.lua, wire_decode.gd: {wire_vals}",
    )

    session_handlers = _lua_handlers(session_lua)
    space_handlers = _lua_handlers(space_lua)
    mod_handlers = session_handlers | space_handlers
    py_client = set(protocol.CLIENT)

    extra_in_session = sorted(session_handlers - py_client)
    check(not extra_in_session, f"session.lua handlers.* all present in protocol.CLIENT (extra: {extra_in_session})")

    extra_in_mod = sorted(mod_handlers - py_client)
    missing_in_mod = sorted(py_client - mod_handlers)
    check(
        not extra_in_mod and not missing_in_mod,
        f"mod handlers (session.lua + space.lua) match protocol.CLIENT (extra={extra_in_mod}, missing={missing_in_mod})",
    )

    if failures:
        print(f"{len(failures)} protocol sync check(s) failed")
        return 1
    print(f"all protocol sync checks passed ({len(mod_handlers)} client handlers)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
