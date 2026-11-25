#!/usr/bin/env python3
"""Verify tools/check.py's unified TESTS/MANUAL registry covers every test file and key plan() triggers.

    python tools/test_check.py
"""
from __future__ import annotations

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import check  # noqa: E402

failures: list[str] = []


def verify(cond: bool, what: str) -> None:
    if cond:
        print(f"ok   {what}")
    else:
        failures.append(what)
        print(f"FAIL {what}")


def main() -> int:
    # 1. Registry shape & uniqueness across --all both
    all_both = check.all_checks("both")
    names = [c.name for c in all_both]
    verify(len(names) == len(set(names)), f"unique check names in all_checks('both') ({len(names)} checks)")

    manual_keys = {str(k) for k in check.MANUAL}
    gd_tests = sorted(p.name for p in (ROOT / "client" / "tests").glob("*_test.gd"))
    py_tests = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "tools").rglob("test_*.py"))

    # Every Godot test must be accounted for in TESTS (target stem) or MANUAL.
    godot_targets = {
        pathlib.Path(e.target).stem
        for e in check.TESTS
        if e.suite == "godot" and e.kind in ("godot_script", "godot_scene")
    }
    unaccounted_gd = [
        g for g in gd_tests
        if g[:-3] not in godot_targets and g not in manual_keys and g[:-3] not in manual_keys
    ]
    verify(not unaccounted_gd, f"all {len(gd_tests)} client/tests/*_test.gd accounted for (missing: {unaccounted_gd})")

    # No MANUAL test may leak into all_checks("godot").
    all_gd_cmds = " ".join(" ".join(c.command) for c in check.all_checks("godot"))
    leaked_manual = [m for m in sorted(manual_keys) if m in all_gd_cmds or pathlib.Path(m).stem in all_gd_cmds]
    verify(not leaked_manual, f"no MANUAL test in all_checks('godot') (leaked: {leaked_manual})")

    # Every MANUAL entry must still exist on disk.
    missing_manual = [
        m for m in sorted(manual_keys)
        if not ((ROOT / "client" / "tests" / m).exists() or (ROOT / m).exists())
    ]
    verify(not missing_manual, f"all MANUAL entries exist on disk (missing: {missing_manual})")

    # Every Python test under tools/**/test_*.py must be in TESTS or MANUAL.
    py_targets = {e.target for e in check.TESTS if e.kind == "py"}
    unaccounted_py = [p for p in py_tests if p not in py_targets and p not in manual_keys]
    verify(not unaccounted_py, f"all {len(py_tests)} tools/**/test_*.py accounted for (missing: {unaccounted_py})")

    all_fast_or_gd = {c.name for c in check.all_checks("both")}
    expected_auto_py = {
        e.name for e in check.TESTS
        if e.kind == "py" and e.suite in ("fast", "godot") and (ROOT / e.target).exists()
    }
    verify(expected_auto_py <= all_fast_or_gd, f"all existing Python tests appear in all_checks('both'): missing {sorted(expected_auto_py - all_fast_or_gd)}")

    # 2. Key changed-file triggers in plan()
    def planned(files: list[str], *, done: bool = False) -> set[str]:
        checks, _ = check.plan(files, None, done)
        return {c.name for c in checks}

    wire_plan = planned(["client/scripts/net/wire_decode.gd"])
    verify(
        {"gdparse", "bridge_fuzz_test", "bridge_queue_stress_test", "wire_decode_native_test", "test_protocol_sync"} <= wire_plan,
        f"wire_decode.gd plan: {sorted(wire_plan)}",
    )

    msg_plan = planned(["client/scripts/net/message_decode.gd"])
    verify(
        {"gdparse", "bridge_fuzz_test", "bridge_queue_stress_test"} <= msg_plan,
        f"message_decode.gd plan: {sorted(msg_plan)}",
    )

    native_plan = planned(["client/native/belt_sim/src/belt_sim_native.cpp"])
    verify(
        {
            "belt_sim_native_test",
            "belt_sim_replay split_wait hints on",
            "belt_sim_replay split_wait hints off",
        } <= native_plan,
        f"belt_sim_native.cpp plan: {sorted(native_plan)}",
    )

    session_plan = planned(["mod/factorio-3d-bridge/scripts/session.lua"])
    verify(
        {"test_bridge", "test_bridge --binary", "test_fuzz", "test_binary", "test_protocol_sync"} <= session_plan,
        f"session.lua plan: {sorted(session_plan)}",
    )

    health_plan = planned(["tools/code_health.py"])
    verify("test_code_health" in health_plan, f"tools/code_health.py plan: {sorted(health_plan)}")

    check_plan = planned(["tools/check.py"])
    verify({"test_check", "test_godot_logs"} <= check_plan, f"tools/check.py plan: {sorted(check_plan)}")

    # 3. Repaired tests moved out of MANUAL into --all godot, and AREAS plan() mappings.
    verify(
        manual_keys == {"udp_burst_test.gd", "inserter_events_test.gd"},
        f"MANUAL holds only udp_burst_test.gd and inserter_events_test.gd (got {sorted(manual_keys)})",
    )
    verify(
        {"char_lod_zoom_test", "cliff_fit_test", "profiler_overlay_test"} <= godot_targets,
        f"repaired tests in --all godot: {sorted({'char_lod_zoom_test', 'cliff_fit_test', 'profiler_overlay_test'} & godot_targets)}",
    )
    verify("char_lod_zoom_test" in planned(["client/scripts/world/ao_zoom.gd"]), "ao_zoom.gd -> char_lod_zoom_test")
    verify("cliff_fit_test" in planned(["client/scripts/world/ground_height.gd"]), "ground_height.gd -> cliff_fit_test")
    verify("profiler_overlay_test" in planned(["client/scripts/debug/debug_overlay.gd"]), "debug_overlay.gd -> profiler_overlay_test")

    verify(hasattr(check, "AREAS") and len(check.AREAS) >= 8, f"AREAS mapping defined ({len(getattr(check, 'AREAS', []))} areas)")
    verify("ui_test map" in planned(["client/scripts/ui/factorio/map_view.gd"]), "map_view.gd -> ui_test map")
    verify("ui_test space" in planned(["client/scripts/ui/factorio/space_map.gd"]), "space_map.gd -> ui_test space")
    verify("ui_test planners" in planned(["client/scripts/ui/factorio/planner_ui.gd"]), "planner_ui.gd -> ui_test planners")
    verify("ui_test circuits" in planned(["client/scripts/ui/factorio/circuit_panel.gd"]), "circuit_panel.gd -> ui_test circuits")
    verify("ui_test ui" in planned(["client/scripts/ui/factorio/crafting_panel.gd"]), "crafting_panel.gd -> ui_test ui")
    verify("ui_test ui" in planned(["client/scripts/ui/hud.gd"]), "hud.gd -> ui_test ui")
    verify("ui_test backdrop" in planned(["client/scripts/menu/menu_background.gd"]), "menu_background.gd -> ui_test backdrop")
    verify("ui_test menu" in planned(["client/scripts/menu/front_end.gd"]), "front_end.gd -> ui_test menu")
    verify("ui_test player" in planned(["client/scripts/player/camera_rig.gd"]), "camera_rig.gd -> ui_test player")
    verify("ui_test debug" in planned(["client/scripts/debug/render_stats.gd"]), "render_stats.gd -> ui_test debug")
    verify("ui_test fx" in planned(["client/scripts/fx/lightning.gd"]), "lightning.gd -> ui_test fx")
    verify("ui_test world" in planned(["client/scripts/world/behind_cull.gd"]), "behind_cull.gd -> ui_test world")
    verify("ui_test shaders" in planned(["client/shaders/water.gdshader"]), "water.gdshader -> ui_test shaders")
    verify("ui_test contact" in planned(["client/scripts/world/contact_shade.gd"]), "contact_shade.gd -> ui_test contact")
    verify("belt_sim_native_test" in planned(["client/scripts/native_library.gd"]), "native_library.gd -> belt_sim_native_test")
    verify("ui_test world" not in planned(["client/scripts/world/far_chunks.gd"]), "far_chunks.gd uses dedicated tests without ui_test world fallback")

    import pathlib as _pl
    import re as _re
    ui_test_src = (_pl.Path(__file__).resolve().parent.parent / "client" / "tests" / "ui_test.gd").read_text(encoding="utf-8")
    order_match = _re.search(r"const\s+SECTION_ORDER[^=]*=\s*\[(.*?)\]", ui_test_src, _re.S)
    verify(order_match is not None, "SECTION_ORDER found in client/tests/ui_test.gd")
    if order_match is not None:
        valid_sections = set(_re.findall(r'"([^"]+)"', order_match.group(1)))
        for label, _globs, only, _full in check.AREAS:
            if not label.startswith("ui_test") or not only:
                continue
            for sec in only.split(","):
                verify(sec in valid_sections, f"AREAS {label!r} section {sec!r} in ui_test.gd SECTION_ORDER")

    if failures:
        print(f"{len(failures)} check registry test(s) failed")
        return 1
    print(f"all check registry tests passed ({len(gd_tests)} GD, {len(py_tests)} PY, {len(manual_keys)} MANUAL)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
