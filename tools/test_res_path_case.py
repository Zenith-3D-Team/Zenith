#!/usr/bin/env python3
"""tools/res_path_case.py: a res:// or relative preload path with the wrong letter case is found, right ones and
run-time-built ones pass, and the client itself is clean.

    python tools/test_res_path_case.py
"""
from __future__ import annotations

import pathlib
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import res_path_case as rpc  # noqa: E402

failures: list[str] = []


def verify(cond: bool, what: str) -> None:
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        failures.append(what)


def main() -> int:
    with tempfile.TemporaryDirectory() as d:
        client = pathlib.Path(d) / "client"
        (client / "scripts" / "world").mkdir(parents=True)
        (client / "scripts" / "world" / "belt_sim.gd").write_text("extends RefCounted\n", encoding="utf-8")
        (client / "scripts" / "world" / "Odd_Name.gd").write_text("extends RefCounted\n", encoding="utf-8")
        user = client / "scripts" / "main.gd"
        user.write_text(
            'const A := preload("res://scripts/world/belt_sim.gd")\n'          # right
            'const B := preload("res://Scripts/world/belt_sim.gd")\n'          # folder case
            'const C := preload("res://scripts/world/Belt_Sim.gd")\n'          # file case
            'const D := preload("res://scripts/world/Odd_Name.gd")\n'          # right, mixed case on disk
            'const E := preload("res://scripts/world/odd_name.gd")\n'          # wrong
            'const F := preload("world/BELT_SIM.gd")\n'                        # relative, wrong
            'const G := preload("world/belt_sim.gd")\n'                        # relative, right
            'var h = load("res://scripts/world/%s.gd" % name)\n'               # built at run time
            'var i = load("res://Not/There.gd")\n'                             # no such file in any case
            '# res://scripts/World/belt_sim.gd in a comment still counts\n',
            encoding="utf-8")
        scene = client / "s.tscn"
        scene.write_text('[ext_resource type="Script" path="res://scripts/MAIN.gd" id="1"]\n', encoding="utf-8")
        old = rpc.CLIENT
        rpc.CLIENT = client
        try:
            index = rpc.DiskIndex(client)
            found = rpc.check_file(user, index)
            found_scene = rpc.check_file(scene, index)
        finally:
            rpc.CLIENT = old
    nos = sorted(int(f.split(": ", 1)[0].rsplit(":", 1)[1]) for f in found)
    verify(nos == [2, 3, 5, 6, 10], f"wrong-case lines 2, 3, 5, 6, 10 found, nothing else ({nos}: {found})")
    verify(len(found_scene) == 1 and "res://scripts/main.gd" in found_scene[0], f"a .tscn path found ({found_scene})")

    found = []
    index = rpc.DiskIndex(rpc.CLIENT)
    for p in rpc.client_files():
        found += rpc.check_file(p, index)
    verify(not found, f"the client's own paths are clean ({len(found)}: {found[:5]})")
    print(f"\n{len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
