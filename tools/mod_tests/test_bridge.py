"""Runs the bridge mod's control.lua against fake_factorio.lua and checks what it sends.

    pip install lupa
    python3 tools/mod_tests/test_bridge.py [--binary]

Lupa embeds Lua 5.2, the version Factorio uses. The fake API raises on unknown keys like the
real one, so wrong property reads show up here instead of as an in-game crash.
"""
from __future__ import annotations

import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import bridge_harness  # noqa: E402


def main() -> int:
    ns = vars(bridge_harness)
    slices = sorted((HERE / "bridge_world").glob("[0-9][0-9]_*.py"))
    if not slices:
        raise RuntimeError("no bridge_world slices found")
    for path in slices:
        src = path.read_text(encoding="utf-8")
        exec(compile(src, str(path), "exec"), ns)

    if bridge_harness.BINARY:
        bridge_harness.check(
            {
                bridge_harness.protocol.KIND_MV,
                bridge_harness.protocol.KIND_BS,
                bridge_harness.protocol.KIND_BFAR,
                bridge_harness.protocol.KIND_RB,
            } <= bridge_harness.binary_kinds,
            f"--binary: mv, bs, bfar and rb came as binary frames: kinds {sorted(bridge_harness.binary_kinds)}",
        )

    if bridge_harness.failures:
        print(f"\n{len(bridge_harness.failures)} check(s) failed")
        return 1
    passes = bridge_harness.passes
    print(f"{passes} bridge checks passed" + (" (binary frames)" if bridge_harness.BINARY else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
