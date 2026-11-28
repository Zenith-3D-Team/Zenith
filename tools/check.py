#!/usr/bin/env python3
"""The fast checks for what changed: picks them from the files changed against a base commit, runs
them, and logs how long each took.

    python tools/check.py                    against where this branch left main, uncommitted work too
    python tools/check.py --base HEAD~3      against another commit
    python tools/check.py --list             say what would run, run nothing
    python tools/check.py --ui _terrain,_belt_paths   and those sections of the UI test
    python tools/check.py --done             the change is finished: the slower checks for it as well
                                             (the whole UI test, model loading, model textures)
    python tools/check.py --all              every fast suite, whatever changed, then a pass/fail table:
                                             the Lua suites, the mock's, gdparse, the models' check
    python tools/check.py --all godot        the headless Godot tests CI's ui job runs (UI test, fuzz,
                                             decoratives, mods' files, add-ons, VR, model loading)
    python tools/check.py --all both         both, fast ones first

Nothing here starts Factorio or opens a window. In the default mode a check that fails is run once
more; passing then, it is reported as flaky and doesn't fail the run. --all runs each once: a
failure is a failure (CI runs it so), and each check's whole output goes to --logs (default
art-src/check-logs/ in the main checkout). Godot checks have a time limit and also fail on a
SCRIPT ERROR, which a test's exit code can't show. Each check's time and result go to
art-src/check-log.jsonl in the main checkout (git-ignored, one log for every worktree). On GitHub
Actions the table also goes to the job's summary ($GITHUB_STEP_SUMMARY), and each failure is an
error annotation naming the check.

Each Godot run writes its own log, art-src/check-logs/<check>.godot.log (`--log-file`), never the
Zenith project's user://logs/ (%APPDATA%/Godot/app_userdata/Zenith/logs), which keeps the player's own logs.

Godot: $GODOT, else `godot` on PATH, else the console build under ~/Tools/Godot, else winget's.
Python: this checkout's .venv, else the main checkout's, else the one running this.
"""
from __future__ import annotations

import argparse
import fnmatch
import glob
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time

# A FAIL line can hold any character: on Windows, output to a file or pipe is in the system's code page,
# and one character it lacks stopped the run with UnicodeEncodeError.
sys.stdout.reconfigure(errors="backslashreplace")

REPO = pathlib.Path(__file__).resolve().parents[1]
# Seconds; the tests' own watchdog (client/tests/test_watchdog.gd, 300 s) stops them first and says so.
GODOT_LIMIT = 360
# Every check's output read as UTF-8 (a FAIL line can hold any character), and printed as it comes.
CHILD_ENV = {**os.environ, "PYTHONIOENCODING": "utf-8", "PYTHONUNBUFFERED": "1"}


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


def godot_log(name: str, logs: pathlib.Path | None = None) -> list[str]:
    """`--log-file` for one Godot run: Godot opens its log before any script runs, so only the command line
    keeps a test's log out of the project's user://logs/, where it would rotate the player's own logs away.
    Absolute: Godot reads a relative --log-file from the user folder."""
    folder = (logs or main_checkout() / "art-src" / "check-logs").resolve()  # a relative path is user://'s
    folder.mkdir(parents=True, exist_ok=True)
    return ["--log-file", str(folder / (name.replace(" ", "_") + ".godot.log"))]


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


class Check:
    """A single runnable check command."""

    def __init__(self, name: str, command: list[str], godot: bool = False) -> None:
        self.name = name
        self.command = command
        self.godot = godot

    def __repr__(self) -> str:
        return f"Check(name={self.name!r}, command={self.command!r}, godot={self.godot!r})"

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Check):
            return NotImplemented
        return (self.name, self.command, self.godot) == (other.name, other.command, other.godot)


class TestEntry:
    """One test or suite in the unified registry driving both plan() and all_checks()."""

    def __init__(
        self,
        name: str,
        kind: str,
        target: str = "",
        args: tuple[str, ...] = (),
        suite: str = "fast",
        triggers: tuple[str, ...] = (),
        done_only: bool = False,
        if_exists: bool = False,
    ) -> None:
        self.name = name
        self.kind = kind
        self.target = target
        self.args = args
        self.suite = suite
        self.triggers = triggers
        self.done_only = done_only
        self.if_exists = if_exists

    def to_check(self, py: str, extra_args: tuple[str, ...] = ()) -> Check:
        if self.kind == "godot_scene":
            return godot_scene(self.name, self.target, *self.args, *extra_args)
        if self.kind == "godot_script":
            return godot_script(self.name, self.target, *self.args, *extra_args)
        if self.kind == "gdparse":
            return Check(self.name, [py, "-m", "gdtoolkit.parser", *(extra_args or all_scripts())])
        if self.kind == "models_check":
            return Check(self.name, [py, self.target, *extra_args])
        return Check(self.name, [py, self.target, *self.args, *extra_args])


def any_match(files: list[str], *patterns: str) -> bool:
    return any(fnmatch.fnmatch(f, p) for f in files for p in patterns)


def godot_scene(name: str, scene: str, *args: str) -> Check:
    return Check(name, ["res://tests/" + scene, *args], godot=True)


def godot_script(name: str, script: str, *args: str) -> Check:
    return Check(name, ["-s", "res://tests/" + script, *args], godot=True)


# The splitter crossing hints (BeltSim.split_hints) on their lab fixture, belt_sim.gd's: the one-tick wait the game made
# is reproduced from the bridge's hints (nothing off), missed without them (client/tests/belt_sim_replay.gd's header).
_SPLIT_WAIT = ("--", "res://tests/data/belt_sim_split_wait.json", "--gd", "--split-wake=off")
SPLIT_HINTS_ON = godot_script("belt_sim_replay split_wait hints on", "belt_sim_replay.gd", *_SPLIT_WAIT, "--split-hints=6", "--max-off=0")
SPLIT_HINTS_OFF = godot_script("belt_sim_replay split_wait hints off", "belt_sim_replay.gd", *_SPLIT_WAIT, "--min-off=1")


# Issue #26's switch for one run: factorio_keys_test checks --keys-defaults=old on its own command line.
FACTORIO_KEYS_OLD = godot_script("factorio_keys_test --keys-defaults=old", "factorio_keys_test.gd", "--", "--keys-defaults=old")


_MOD_LUA_TRIGGERS = ("mod/*.lua", "tools/mod_tests/*", "tools/protocol.py", "docs/PROTOCOL.md")
_MOCK_TRIGGERS = ("tools/mock*.py", "tools/test_mock*.py", "tools/protocol.py", "docs/PROTOCOL.md")
_MODEL_DONE_TRIGGERS = ("client/scripts/world/model_*.gd", "client/shaders/factorio_material*")
_UI_TRIGGERS = ("client/scripts/*", "client/tests/ui_test*", "client/tests/test_*")

# Tests intentionally excluded from --all godot (live-server probes or tests blocked by a client bug).
MANUAL: dict[str, str] = {
    "udp_burst_test.gd": "interactive UDP listener waiting on an external burst sender (--port/--timeout=30)",
    "inserter_events_test.gd": "blocked by client bug in client/scripts/world/inserter_arms.gd:1229-1230 (skips BASIC fallback and live[unit] while arm pieces load, failing K12)",
}

# Area rules mapping runtime files (including UI, menu, player, debug, fx, world, shaders) to
# targeted ui_test --only=<sections> checks when --ui and --done are not passed.
# Tuple: (check_name, patterns, ui_sections, always_run). Narrower areas come before broad ones;
# always_run=False rules only apply to files not already matched by a dedicated test or earlier area.
AREAS: list[tuple[str, tuple[str, ...], str, bool]] = [
    ("ui_test contact", ("client/scripts/world/contact_shade.gd", "client/shaders/contact_shade.gdshader*",
                         "client/scripts/world/chunk_view.gd", "client/scripts/world/model_library.gd"),
     "_contact_shade,_contact_drills,_contact_chunk", True),
    ("ui_test map", ("client/scripts/ui/factorio/map_*.gd", "client/scripts/ui/factorio/minimap.gd",
                     "client/scripts/ui/factorio/alert*.gd", "client/scripts/ui/factorio/remote_frame.gd",
                     "client/scripts/world/player_tags.gd"),
     "_map,_map_layers_cache,_minimap_alerts,_map_title", False),
    ("ui_test space", ("client/scripts/ui/factorio/space_*.gd", "client/scripts/ui/factorio/planet_*.gd",
                       "client/scripts/ui/factorio/platform_*.gd", "client/scripts/world/planet_spin.gd",
                       "client/scripts/world/rockets.gd", "client/scripts/world/rocket_vfx.gd",
                       "client/scripts/world/collectors.gd", "client/shaders/space_sky*",
                       "client/shaders/planet_sky*", "client/shaders/rocket_*", "client/shaders/silo_shaft*"),
     "_space,_modded_planets,_asteroid_chunks,_rocket_launch_vfx", False),
    ("ui_test planners", ("client/scripts/ui/factorio/bp_*.gd", "client/scripts/ui/factorio/blueprint_*.gd",
                          "client/scripts/ui/factorio/book_window.gd", "client/scripts/ui/factorio/planner_*.gd",
                          "client/scripts/ui/factorio/library_window.gd", "client/scripts/player/blueprint_preview.gd",
                          "client/scripts/player/tile_brush.gd", "client/scripts/player/rail_planner.gd"),
     "_planners,_blueprint_preview", False),
    ("ui_test circuits", ("client/scripts/ui/factorio/circuit_*.gd", "client/scripts/ui/factorio/logic_*.gd",
                          "client/scripts/ui/factorio/switch.gd", "client/scripts/player/wire_tool.gd",
                          "client/scripts/world/wires.gd", "client/shaders/wire*"),
     "_parity,_wires", False),
    ("ui_test ui", ("client/scripts/ui/factorio/*.gd", "client/scripts/ui/*.gd"),
     "_hud,_play,_parity,_info,_gear,_layout,_help,_icons,_esc_tooltip", False),
    ("ui_test backdrop", ("client/scripts/menu/backdrop_*.gd", "client/scripts/menu/menu_background.gd"),
     "_menu_backdrop,_menu_backdrop_cases,_menu_backdrop_list,_menu_backdrop_ground", False),
    ("ui_test menu", ("client/scripts/menu/*.gd",),
     "_menus,_load_mods,_mod_windows,_window_bounds,_model_packs_window,_perf_test", False),
    ("ui_test player", ("client/scripts/player/*.gd",),
     "_play,_build_tools,_wall_drag,_wires,_planners,_mine_reach,_first_person_aim,_center_aim", False),
    ("ui_test debug", ("client/scripts/debug/*.gd",),
     "_debug_menu,_debug_sim_switches,_debug_light_sliders,_debug_live_sliders,_dev_tools,_update_overlays", False),
    ("ui_test fx", ("client/scripts/fx/*.gd", "client/shaders/fx_*", "client/shaders/lightning*",
                    "client/shaders/smog*", "client/shaders/pollution*"),
     "_fx_movers,_lightning,_weapons,_acid_aim", False),
    ("ui_test world", ("client/scripts/world/*.gd", "client/scripts/net/game_pause.gd"),
     "_terrain,_lamps,_signal_lights,_states_sliced,_predictions,_pipe_covers,_underground_clear,_working_near,_view_priority,_gpu_anim,_gate_open,_creature_motion,_tree_crowns", False),
    ("ui_test shaders", ("client/shaders/*.gdshader", "client/shaders/*.gdshaderinc"),
     "_terrain,_pbr_look,_pack_shading_look,_predictions,_lamps", False),
]

TESTS: list[TestEntry] = [
    # --- Fast Python / static suites (CI's tests job) ---
    TestEntry("test_bridge", "py", "tools/mod_tests/test_bridge.py", suite="fast", triggers=_MOD_LUA_TRIGGERS),
    # (Every check again with every hello asking for binary frames: mv, bs and bfar through protocol.py.)
    TestEntry("test_bridge --binary", "py", "tools/mod_tests/test_bridge.py", args=("--binary",), suite="fast", triggers=_MOD_LUA_TRIGGERS),
    TestEntry("test_data_stage", "py", "tools/mod_tests/test_data_stage.py", suite="fast",
              triggers=("mod/*/data*.lua", "mod/*/scripts/gfx_extract.lua", "tools/mod_tests/test_data_stage.py")),
    TestEntry("test_mock_server", "py", "tools/test_mock_server.py", suite="fast", triggers=_MOCK_TRIGGERS),
    # One Python start for them all: gdparse takes many files (~270 paths, ~10 KB of command line).
    TestEntry("gdparse", "gdparse", suite="fast"),
    TestEntry("models check.py", "models_check", "tools/models/check.py", suite="fast", triggers=("tools/models/*.py",)),
    TestEntry("test_fix_pack", "py", "tools/models/test_fix_pack.py", suite="fast",
              triggers=("tools/models/fix_pack.py", "tools/models/fixes/*", "tools/models/test_fix_pack.py",
                        "tools/models/check.py", "tools/models/specs.py")),
    TestEntry("test_fuzz", "py", "tools/mod_tests/test_fuzz.py", suite="fast", triggers=_MOD_LUA_TRIGGERS),
    # Binary frames (transport.lua) decode as their JSON does.
    TestEntry("test_binary", "py", "tools/mod_tests/test_binary.py", suite="fast", triggers=_MOD_LUA_TRIGGERS),
    TestEntry("test_events", "py", "tools/mod_tests/test_events.py", suite="fast",
              triggers=(*_MOD_LUA_TRIGGERS, "tools/mod_tests/test_events.py")),
    TestEntry("test_mock_fuzz", "py", "tools/test_mock_fuzz.py", suite="fast", triggers=_MOCK_TRIGGERS),
    # The relay for a server on another PC, and the mock behind it losing packets.
    TestEntry("test_relay", "py", "tools/test_relay.py", suite="fast",
              triggers=("server/relay.py", "tools/relay_check.py", "tools/test_relay.py")),
    # package.py's Zenith.zip: a pack's items/ folder goes in.
    TestEntry("test_package", "py", "tools/release/test_package.py", suite="fast",
              triggers=("tools/release/*.py",)),
    # leak_scan.py: private dot-paths match, public lines carry no generic worktree path.
    TestEntry("test_leak_scan", "py", "tools/release/test_leak_scan.py", suite="fast",
              triggers=("tools/release/leak_scan.py", "tools/release/test_leak_scan.py",
                        "client/scripts/menu/game_swap.gd", "tools/models/review.py")),
    # Deleting a folder that holds a junction (a linked mod) never empties the junction's target.
    TestEntry("test_safe_delete", "py", "tools/test_safe_delete.py", suite="fast",
              triggers=("tools/safe_delete.py", "tools/test_safe_delete.py", "tools/belt_view_check.py",
                        "tools/bench/hybrid_cost.py", "tools/look/factorio_reference.py")),
    TestEntry("test_code_health", "py", "tools/test_code_health.py", suite="fast",
              triggers=("tools/code_health.py", "tools/test_code_health.py")),
    # CI's Linux (GCC) build of belt_sim: MSVC-only C++ found by pattern (0.3.0's std::cosf), plus the lint's own test.
    TestEntry("test_native_portability_check", "py", "tools/test_native_portability_check.py", suite="fast",
              triggers=("client/native/belt_sim/src/*", "tools/native_portability_check.py",
                        "tools/test_native_portability_check.py")),
    # Linux is case-sensitive: every res:// path in the client's scripts, scenes and resources as on disk. (Not
    # triggered by .gd files: that would mark every script covered and skip the UI test's areas; --all fast has it.)
    TestEntry("test_res_path_case", "py", "tools/test_res_path_case.py", suite="fast",
              triggers=("client/*.tscn", "client/*.tres", "client/project.godot", "tools/res_path_case.py",
                        "tools/test_res_path_case.py")),
    TestEntry("test_check", "py", "tools/test_check.py", suite="fast",
              triggers=("tools/check.py", "tools/test_check.py", "client/tests/*_test.gd", "tools/*test_*.py")),
    TestEntry("test_protocol_sync", "py", "tools/test_protocol_sync.py", suite="fast",
              triggers=("tools/protocol.py", "docs/PROTOCOL.md", "mod/factorio-3d-bridge/scripts/session.lua",
                        "mod/factorio-3d-bridge/scripts/space.lua", "mod/factorio-3d-bridge/scripts/transport.lua",
                        "client/scripts/net/bridge.gd", "client/scripts/net/wire_decode.gd",
                        "tools/mock_server.py", "tools/test_protocol_sync.py")),
    TestEntry("test_belt_view_check", "py", "tools/test_belt_view_check.py", suite="fast",
              triggers=("tools/belt_view_check.py", "tools/test_belt_view_check.py")),
    TestEntry("test_belt_walk_check", "py", "tools/test_belt_walk_check.py", suite="fast",
              triggers=("tools/belt_walk_check.py", "tools/test_belt_walk_check.py", "client/scripts/debug/stutter_probe.gd")),
    TestEntry("test_bs_offline", "py", "tools/test_bs_offline.py", suite="fast",
              triggers=("tools/bs_offline.py", "tools/test_bs_offline.py", "mod/factorio-3d-bridge/scripts/belt_sim*.lua")),
    # Private tracker suites: left out of the release tree, so only where present.
    TestEntry("test_agents_merge", "py", "tools/tracker/test_agents_merge.py", suite="fast", if_exists=True,
              triggers=("tools/tracker/agents_merge.py", "tools/tracker/test_agents_merge.py")),
    TestEntry("test_releases", "py", "tools/tracker/test_releases.py", suite="fast", if_exists=True,
              triggers=("tools/tracker/releases.py", "tools/tracker/test_releases.py")),
    TestEntry("test_usage", "py", "tools/tracker/test_usage.py", suite="fast", if_exists=True,
              triggers=("tools/tracker/usage.py", "tools/tracker/test_usage.py")),
    TestEntry("test_refresh_dashboard", "py", "tools/tracker/test_refresh_dashboard.py", suite="fast", if_exists=True,
              triggers=("tools/tracker/refresh_dashboard.py", "tools/tracker/test_refresh_dashboard.py")),

    # --- Headless Godot tests (CI's ui job) ---
    TestEntry("ui_test", "godot_scene", "ui_test.tscn", suite="godot", triggers=_UI_TRIGGERS, done_only=True),
    TestEntry("bridge_fuzz_test", "godot_scene", "bridge_fuzz_test.tscn", suite="godot",
              triggers=("client/scripts/net/bridge.gd", "client/scripts/net/wire_decode.gd",
                        "client/scripts/net/message_decode.gd", "client/tests/bridge_fuzz*")),
    TestEntry("bridge_queue_stress_test", "godot_scene", "bridge_queue_stress_test.tscn", suite="godot",
              triggers=("client/scripts/net/bridge.gd", "client/scripts/net/wire_decode.gd",
                        "client/scripts/net/message_decode.gd", "client/scripts/world/world.gd",
                        "client/tests/bridge_queue_stress*")),
    TestEntry("megabase_prio_test", "godot_scene", "megabase_prio_test.tscn", suite="godot",
              triggers=("client/scripts/net/bridge.gd", "client/scripts/player/player_input.gd",
                        "client/scripts/world/quality_marks.gd", "client/scripts/world/inserter_arms.gd",
                        "client/scripts/world/movers.gd", "client/scripts/world/fluids_power.gd",
                        "client/scripts/ui/factorio/alt_overlay.gd", "client/scripts/fx/fx.gd",
                        "client/tests/megabase_prio_test*")),
    TestEntry("chunk_streaming_test", "godot_scene", "chunk_streaming_test.tscn", suite="godot",
              triggers=("client/scripts/world/world.gd", "client/scripts/world/chunk_view.gd",
                        "client/scripts/world/far_chunks.gd", "client/scripts/world/frame_budget.gd",
                        "client/scripts/world/ups_governor.gd", "client/scripts/world/chunk_disk_cache.gd",
                        "client/tests/chunk_streaming*")),
    TestEntry("decor_test", "godot_scene", "decor_test.tscn", suite="godot",
              triggers=("client/scripts/world/decorative*", "client/shaders/decorative*", "client/tests/decor*")),
    TestEntry("mover_skip_still_test", "godot_script", "mover_skip_still_test.gd", suite="godot",
              triggers=("client/scripts/world/movers.gd", "client/tests/mover_skip_still_test*")),
    TestEntry("rail_height_native_test", "godot_script", "rail_height_native_test.gd", suite="godot",
              triggers=("client/scripts/world/movers.gd", "client/native/belt_sim/src/movers_native*",
                        "client/tests/rail_height_native_test*")),
    TestEntry("movers_native_test", "godot_script", "movers_native_test.gd", suite="godot",
              triggers=("client/scripts/world/movers.gd", "client/scripts/world/robot_swarm.gd",
                        "client/scripts/world/mover_records.gd", "client/native/belt_sim/src/movers_native*",
                        "client/tests/movers_native_test*")),
    TestEntry("fluids_burner_scan_test", "godot_script", "fluids_burner_scan_test.gd", suite="godot",
              triggers=("client/scripts/world/fluids_power.gd", "client/scripts/fx/burner_fx.gd",
                        "client/scripts/fx/fx.gd", "client/tests/fluids_burner_scan_test*")),
    TestEntry("decor_native_test", "godot_script", "decor_native_test.gd", suite="godot",
              triggers=("client/scripts/world/decorative*", "client/shaders/decorative*",
                        "client/native/belt_sim/src/decor_native*", "client/tests/decor*")),
    TestEntry("alt_icons_native_test", "godot_scene", "alt_icons_native_test.tscn", suite="godot",
              triggers=("client/scripts/ui/factorio/alt_overlay.gd",
                        "client/native/belt_sim/src/alt_icons_native*", "client/tests/alt_icons_native*")),
    TestEntry("upscalers_test", "godot_script", "upscalers_test.gd", suite="godot",
              triggers=("client/scripts/menu/upscalers.gd", "client/scripts/menu/settings.gd",
                        "client/scripts/menu/settings_window.gd", "client/native/upscalers*",
                        "client/tests/upscalers_test*")),
    TestEntry("terrain_decor_opt_test", "godot_script", "terrain_decor_opt_test.gd", suite="godot",
              triggers=("client/scripts/world/terrain_mesher.gd", "client/scripts/world/chunk_view.gd",
                        "client/scripts/world/visuals.gd", "client/scripts/world/decoratives.gd",
                        "client/shaders/terrain*", "client/shaders/decorative*", "client/tests/terrain_decor_opt*")),
    TestEntry("mod_files_test", "godot_script", "mod_files_test.gd", suite="godot",
              triggers=("client/scripts/world/mod_files.gd", "client/scripts/world/mod_graphics.gd",
                        "client/scripts/world/sprite_standins.gd", "client/tests/mod_files*")),
    TestEntry("model_packs_test", "godot_script", "model_packs_test.gd", suite="godot",
              triggers=("client/scripts/world/model_packs.gd", "client/scripts/world/model_library.gd",
                        "client/scripts/world/mod_files.gd", "client/scripts/world/pack_check.gd",
                        "client/tests/model_packs*")),
    TestEntry("sound_files_test", "godot_script", "sound_files_test.gd", suite="godot",
              triggers=("client/scripts/fx/sound_bank.gd", "client/scripts/world/model_packs.gd",
                        "client/scripts/world/mod_files.gd", "client/tests/sound_f*")),
    TestEntry("model_preview_test", "godot_script", "model_preview_test.gd", suite="godot",
              triggers=("client/scripts/ui/factorio/model_preview.gd", "client/scripts/world/model_library.gd",
                        "client/scripts/world/ground_height.gd", "client/tests/model_preview*")),
    TestEntry("belt_caps_test", "godot_script", "belt_caps_test.gd", suite="godot",
              triggers=("client/scripts/world/belt_caps.gd", "client/scripts/world/model_library.gd",
                        "client/tests/belt_caps*")),
    TestEntry("belt_cover_test", "godot_script", "belt_cover_test.gd", suite="godot",
              triggers=("client/scripts/world/belt_return.gd", "client/shaders/factorio_material.gdshaderinc",
                        "client/tests/belt_cover*")),
    TestEntry("night_vision_test", "godot_script", "night_vision_test.gd", suite="godot",
              triggers=("client/scripts/ui/night_vision_overlay.gd", "client/scripts/ui/factorio/night_vision_icon.gd",
                        "client/scripts/fx/step_sounds.gd", "client/tests/night_vision*")),
    TestEntry("belt_lane_inset_test", "godot_script", "belt_lane_inset_test.gd", suite="godot",
              triggers=("client/scripts/world/belt_lane_inset.gd", "client/scripts/world/belt_items.gd",
                        "client/tests/belt_lane_inset*", "client/scripts/world/model_packs.gd")),
    TestEntry("contact_belt_under_test", "godot_script", "contact_belt_under_test.gd", suite="godot",
              triggers=("client/scripts/world/contact_shade.gd", "client/scripts/world/belt_return.gd",
                        "client/tests/contact_belt_under*")),
    TestEntry("belt_sim_replay split_wait hints on", "godot_script", "belt_sim_replay.gd",
              args=(*_SPLIT_WAIT, "--split-hints=6", "--max-off=0"), suite="godot",
              triggers=("client/scripts/world/belt_sim.gd", "client/native/belt_sim/**",
                        "client/tests/belt_sim_replay*", "client/tests/data/belt_sim_split_wait*")),
    TestEntry("belt_sim_replay split_wait hints off", "godot_script", "belt_sim_replay.gd",
              args=(*_SPLIT_WAIT, "--min-off=1"), suite="godot",
              triggers=("client/scripts/world/belt_sim.gd", "client/native/belt_sim/**",
                        "client/tests/belt_sim_replay*", "client/tests/data/belt_sim_split_wait*")),
    TestEntry("belt_sim_native_test", "godot_script", "belt_sim_native_test.gd", suite="godot",
              triggers=("client/scripts/world/belt_sim.gd", "client/native/belt_sim/**",
                        "client/scripts/native_library.gd",
                        "client/tests/belt_sim_native*", "client/tests/data/belt_sim_*")),
    TestEntry("belt_sim_walls_test", "godot_script", "belt_sim_walls_test.gd", suite="godot",
              triggers=("client/scripts/world/belt_sim.gd", "client/native/belt_sim/src/belt_sim_native*",
                        "client/tests/belt_sim_walls*")),
    TestEntry("belt_items_native_test", "godot_script", "belt_items_native_test.gd", suite="godot",
              triggers=("client/scripts/world/item_cards.gd", "client/scripts/world/belt_items.gd",
                        "client/native/belt_sim/**", "client/tests/belt_items_native*")),
    TestEntry("chunk_build_native_test", "godot_script", "chunk_build_native_test.gd", suite="godot",
              triggers=("client/scripts/world/chunk_view.gd", "client/native/belt_sim/src/chunk_build_native*",
                        "client/native/belt_sim/src/belt_native_common*", "client/tests/chunk_build_native*")),
    TestEntry("wire_decode_native_test", "godot_script", "wire_decode_native_test.gd", suite="godot",
              triggers=("client/scripts/net/wire_decode.gd", "client/native/belt_sim/src/wire_decode_native*",
                        "client/tests/wire_decode_native*")),
    TestEntry("lod_decode_native_test", "godot_script", "lod_decode_native_test.gd", suite="godot",
              triggers=("client/scripts/world/lod_data.gd", "client/scripts/net/message_decode.gd",
                        "client/native/belt_sim/src/wire_decode_native*", "client/tests/lod_decode_native*")),
    TestEntry("nature_looks_test", "godot_script", "nature_looks_test.gd", suite="godot",
              triggers=("client/scripts/world/nature_looks.gd", "client/data/nature_looks.json",
                        "client/tests/nature_looks*", "client/shaders/factorio_material*",
                        "client/scripts/world/material_rows.gd")),
    TestEntry("factorio_keys_test", "godot_script", "factorio_keys_test.gd", suite="godot",
              triggers=("client/scripts/player/factorio_keys.gd", "client/scripts/menu/settings.gd",
                        "client/tests/factorio_keys*", "client/scripts/player/controls.gd",
                        "client/scripts/player/player_input.gd", "client/scripts/menu/settings_window.gd",
                        "client/scripts/menu/paths.gd", "client/scripts/main.gd")),
    TestEntry("factorio_keys_test --keys-defaults=old", "godot_script", "factorio_keys_test.gd",
              args=("--", "--keys-defaults=old"), suite="godot",
              triggers=("client/scripts/player/factorio_keys.gd", "client/scripts/menu/settings.gd",
                        "client/tests/factorio_keys*", "client/scripts/player/controls.gd",
                        "client/scripts/player/player_input.gd", "client/scripts/menu/settings_window.gd",
                        "client/scripts/menu/paths.gd", "client/scripts/main.gd")),
    TestEntry("icons_later_test", "godot_script", "icons_later_test.gd", suite="godot",
              triggers=("client/scripts/world/item_icons.gd", "client/scripts/ui/factorio/kit.gd",
                        "client/scripts/ui/factorio/entity_info.gd", "client/tests/icons_later*")),
    TestEntry("settings_wind_test", "godot_script", "settings_wind_test.gd", suite="godot",
              triggers=("client/scripts/menu/settings.gd", "client/tests/settings_wind*")),
    TestEntry("sound_decode_test", "godot_script", "sound_decode_test.gd", suite="godot",
              triggers=("client/scripts/fx/sound_bank.gd", "client/tests/sound_decode*")),
    TestEntry("sound_cache_test", "godot_script", "sound_cache_test.gd", suite="godot",
              triggers=("client/scripts/fx/sound_bank.gd", "client/tests/sound_cache*")),
    TestEntry("sound_pool_test", "godot_script", "sound_pool_test.gd", suite="godot",
              triggers=("client/scripts/fx/sfx.gd", "client/scripts/fx/sound_bank.gd", "client/tests/sound_pool*")),
    TestEntry("combat_sound_test", "godot_script", "combat_sound_test.gd", suite="godot",
              triggers=("client/scripts/fx/sfx.gd", "client/scripts/fx/sound_bank.gd", "client/tests/combat_sound*")),
    TestEntry("combat_shadows_test", "godot_script", "combat_shadows_test.gd", suite="godot",
              triggers=("client/scripts/fx/combat_lights.gd", "client/scripts/fx/weapon_fx.gd",
                        "client/scripts/world/turrets.gd", "client/tests/combat_shadows*")),
    TestEntry("safe_delete_test", "godot_script", "safe_delete_test.gd", suite="godot",
              triggers=("client/scripts/safe_delete.gd", "client/scripts/addons/addon_loader.gd",
                        "client/scripts/world/model_packs.gd", "client/tests/safe_delete*")),
    TestEntry("shader_refresh_test", "godot_script", "shader_refresh_test.gd", suite="godot",
              triggers=("client/scripts/menu/shader_refresh.gd", "client/scripts/safe_delete.gd",
                        "client/addons/zenith_export/shader_hash_export.gd", "client/tests/shader_refresh*")),
    TestEntry("shader_warmup_staged_test", "godot_script", "shader_warmup_staged_test.gd", suite="godot",
              triggers=("client/scripts/world/shader_warmup.gd", "client/scripts/world/render_warm.gd",
                        "client/tests/shader_warmup_staged*")),
    TestEntry("boot_screen_test", "godot_script", "boot_screen_test.gd", suite="godot",
              triggers=("client/scenes/boot.tscn", "client/scripts/menu/boot.gd",
                        "client/scripts/main.gd", "client/tests/boot_screen*")),
    TestEntry("boot_skip_real_test", "godot_script", "boot_skip_real_test.gd", suite="godot",
              triggers=("client/scenes/boot.tscn", "client/scripts/menu/boot.gd",
                        "client/scripts/world/shader_warmup.gd", "client/tests/boot_skip_real*")),
    TestEntry("item_materials_test", "godot_script", "item_materials_test.gd", suite="godot",
              triggers=("client/scripts/world/item_models.gd", "client/scripts/world/model_textures.gd",
                        "client/shaders/item*", "client/tests/item_materials*")),
    TestEntry("item_3d_perf_test", "godot_scene", "item_3d_perf_test.tscn", suite="godot",
              triggers=("client/scripts/world/item_models.gd", "client/scripts/world/item_cards.gd",
                        "client/scripts/world/belt_lanes.gd", "client/scripts/world/belt_items.gd",
                        "client/shaders/item*", "client/shaders/belt_lane_model*", "client/tests/item_3d_perf*")),
    TestEntry("debug_menu_tools_test", "godot_scene", "debug_menu_tools_test.tscn", suite="godot",
              triggers=("client/scripts/ui/factorio/debug_menu.gd", "client/scripts/debug/debug_overlay.gd",
                        "client/scripts/world/belt_items.gd", "client/scripts/world/belt_lanes.gd",
                        "client/scripts/world/item_cards.gd", "client/tests/debug_menu_tools*")),
    TestEntry("item_contact_test", "godot_script", "item_contact_test.gd", suite="godot",
              triggers=("client/scripts/world/item_cards.gd", "client/shaders/item_contact*", "client/tests/item_contact*")),
    TestEntry("temporal_mv_test", "godot_script", "temporal_mv_test.gd", suite="godot",
              triggers=("client/scripts/world/belt_mv.gd", "client/scripts/world/belt_items.gd",
                        "client/scripts/world/item_cards.gd", "client/scripts/world/mover_records.gd",
                        "client/scripts/world/robot_swarm.gd", "client/scripts/world/creatures.gd",
                        "client/scripts/world/belt_blur.gd", "client/scripts/menu/settings.gd",
                        "client/scripts/world/model_library.gd", "client/scripts/world/model_lods.gd",
                        "client/shaders/belt_reactive*", "client/shaders/robot_shadow*",
                        "client/shaders/item*", "client/shaders/factorio_material*",
                        "client/tests/temporal_mv*")),
    TestEntry("alt_perf_test", "godot_scene", "alt_perf_test.tscn", suite="godot",
              triggers=("client/scripts/ui/factorio/alt_overlay.gd", "client/scripts/world/alt_arrows.gd",
                        "client/scripts/world/quality_marks.gd", "client/tests/alt_perf*")),
    TestEntry("addon_test", "godot_scene", "addon_test.tscn", suite="godot",
              triggers=("client/scripts/addons/*", "client/tests/addon*", "addons-src/*",
                        "client/scripts/world/looks.gd")),
    TestEntry("vr_test", "godot_scene", "vr_test.tscn", suite="godot",
              triggers=("client/scripts/vr/*", "client/tests/vr*")),
    TestEntry("lod_data_test", "godot_script", "lod_data_test.gd", suite="godot",
              triggers=("client/scripts/world/lod_*.gd", "client/scripts/world/distant_horizon.gd",
                        "client/shaders/lod_*", "client/tests/lod_*")),
    TestEntry("lod_mesher_test", "godot_script", "lod_mesher_test.gd", suite="godot",
              triggers=("client/scripts/world/lod_*.gd", "client/scripts/world/distant_horizon.gd",
                        "client/shaders/lod_*", "client/tests/lod_*")),
    TestEntry("dh_sample_worker_test", "godot_script", "dh_sample_worker_test.gd", suite="godot",
              triggers=("client/scripts/world/lod_mesher.gd", "client/scripts/world/distant_horizon.gd",
                        "client/tests/dh_sample_worker_test.gd")),
    TestEntry("dh_sections_test", "godot_script", "dh_sections_test.gd", suite="godot",
              triggers=("client/scripts/world/distant_horizon.gd", "client/tests/dh_sections_test.gd")),
    TestEntry("lod_mesher_native_test", "godot_script", "lod_mesher_native_test.gd", suite="godot",
              triggers=("client/scripts/world/lod_mesher.gd", "client/scripts/world/far_chunks.gd",
                        "client/native/belt_sim/src/lod_mesher_native*", "client/tests/lod_mesher_native*")),
    TestEntry("acid_goo_native_test", "godot_script", "acid_goo_native_test.gd", suite="godot",
              triggers=("addons-src/immersive-enemies/**", "client/native/belt_sim/src/acid_goo_native*",
                        "client/scripts/native_library.gd", "client/tests/acid_goo_native*")),
    TestEntry("biter_gore_native_test", "godot_script", "biter_gore_native_test.gd", suite="godot",
              triggers=("addons-src/immersive-enemies/**", "client/native/belt_sim/src/biter_gore_native*",
                        "client/scripts/native_library.gd", "client/tests/biter_gore_native*")),
    TestEntry("biter_ragdoll_native_test", "godot_script", "biter_ragdoll_native_test.gd", suite="godot",
              triggers=("addons-src/immersive-enemies/**", "client/native/belt_sim/src/biter_ragdoll_native*",
                        "client/scripts/native_library.gd", "client/tests/biter_ragdoll_native*")),
    TestEntry("update_check_test", "godot_script", "update_check_test.gd", suite="godot",
              triggers=("client/scripts/menu/update_check.gd", "client/tests/update_check*")),
    TestEntry("far_nature_merge_test", "godot_script", "far_nature_merge_test.gd", suite="godot",
              triggers=("client/scripts/world/far_chunks.gd", "client/tests/far_nature_merge*")),
    TestEntry("cliff_low_shadow_test", "godot_script", "cliff_low_shadow_test.gd", suite="godot",
              triggers=("client/scripts/world/model_lods.gd", "client/scripts/world/far_chunks.gd",
                        "client/shaders/shadow_stand_in*", "client/shaders/far_merged*",
                        "client/tests/cliff_low_shadow*", "client/shaders/ground_height*",
                        "client/shaders/lod_common*", "client/shaders/terrain_common*")),
    TestEntry("cliff_wall_test", "godot_script", "cliff_wall_test.gd", suite="godot",
              triggers=("client/scripts/world/cliff_wall.gd", "client/scripts/world/chunk_view.gd",
                        "client/tests/cliff_wall*")),
    TestEntry("inserter_arms_native_test", "godot_script", "inserter_arms_native_test.gd", suite="godot",
              triggers=("client/scripts/world/inserter_arms.gd", "client/scripts/world/model_rig.gd",
                        "client/native/belt_sim/src/inserter_arms_native*", "client/tests/inserter_arms_native*")),
    TestEntry("mm_buffer_writes_test", "godot_script", "mm_buffer_writes_test.gd", suite="godot",
              triggers=("client/scripts/world/chunk_view.gd", "client/scripts/world/robot_swarm.gd",
                        "client/tests/mm_buffer_writes*")),
    TestEntry("inserter_buffer_test", "godot_script", "inserter_buffer_test.gd", suite="godot",
              triggers=("client/scripts/world/inserter_arms.gd", "client/scripts/world/model_library.gd",
                        "client/tests/inserter_buffer*")),
    TestEntry("inserter_rest_index_test", "godot_script", "inserter_rest_index_test.gd", suite="godot",
              triggers=("client/scripts/world/inserter_arms.gd", "client/tests/inserter_rest_index*")),
    TestEntry("inserter_rest_look_test", "godot_script", "inserter_rest_look_test.gd", suite="godot",
              triggers=("client/scripts/world/inserter_arms.gd", "client/tests/inserter_rest_look*")),
    TestEntry("inserter_swing_test", "godot_script", "inserter_swing_test.gd", suite="godot",
              triggers=("client/scripts/world/inserter_swing.gd", "client/tests/inserter_swing*")),
    TestEntry("inserter_swing_native_test", "godot_script", "inserter_swing_native_test.gd", suite="godot",
              triggers=("client/scripts/world/inserter_swing.gd", "client/native/belt_sim/src/inserter_swing*",
                        "client/tests/inserter_swing_native*")),
    TestEntry("inserter_pose_native_test", "godot_script", "inserter_pose_native_test.gd", suite="godot",
              triggers=("client/scripts/world/inserter_arms.gd", "client/scripts/world/inserter_swing.gd",
                        "client/native/belt_sim/src/inserter_swing*", "client/native/belt_sim/src/inserter_pose*",
                        "client/tests/inserter_pose_native*")),
    TestEntry("inserter_loop_native_test", "godot_script", "inserter_loop_native_test.gd", suite="godot",
              triggers=("client/scripts/world/inserter_arms.gd", "client/native/belt_sim/src/inserter_pose*",
                        "client/native/belt_sim/src/inserter_arms_native*", "client/tests/inserter_loop_native*")),
    TestEntry("inserter_ingest_native_test", "godot_script", "inserter_ingest_native_test.gd", suite="godot",
              triggers=("client/scripts/world/inserter_arms.gd", "client/native/belt_sim/src/inserter_ingest*",
                        "client/native/belt_sim/src/inserter_pose*", "client/tests/inserter_ingest_native*")),
    TestEntry("inserter_hand_stack_test", "godot_script", "inserter_hand_stack_test.gd", suite="godot",
              triggers=("client/scripts/world/inserter_arms.gd", "client/native/belt_sim/src/inserter_pose*",
                        "client/tests/inserter_hand_stack*")),
    TestEntry("inserter_bind_stamp_test", "godot_script", "inserter_bind_stamp_test.gd", suite="godot",
              triggers=("client/scripts/world/inserter_arms.gd", "client/scripts/world/model_library.gd",
                        "client/native/belt_sim/src/inserter_ingest*", "client/tests/inserter_bind_stamp*")),
    TestEntry("inserter_model_watch_test", "godot_script", "inserter_model_watch_test.gd", suite="godot",
              triggers=("client/scripts/world/inserter_arms.gd", "client/native/belt_sim/src/inserter_pose*",
                        "client/tests/inserter_model_watch*")),
    TestEntry("wheel_roll_test", "godot_script", "wheel_roll_test.gd", suite="godot",
              triggers=("client/scripts/world/vehicle_anim.gd", "client/scripts/world/vehicle_lights.gd",
                        "client/scripts/world/movers.gd", "client/scripts/world/turrets.gd",
                        "client/scripts/fx/fx.gd", "client/scripts/fx/weapon_fx.gd",
                        "client/scripts/ui/factorio/preview_anim.gd", "client/scripts/world/anim.gd",
                        "client/assets/models/packs/placeholders/car.glb",
                        "client/assets/models/packs/placeholders/tank.glb",
                        "client/tests/wheel_roll*", "client/tests/vehicle_anim*")),
    TestEntry("vehicle_anim_test", "godot_script", "vehicle_anim_test.gd", suite="godot",
              triggers=("client/scripts/world/vehicle_anim.gd", "client/scripts/world/vehicle_lights.gd",
                        "client/scripts/world/movers.gd", "client/scripts/world/turrets.gd",
                        "client/scripts/fx/fx.gd", "client/scripts/fx/weapon_fx.gd",
                        "client/scripts/ui/factorio/preview_anim.gd", "client/scripts/world/anim.gd",
                        "client/assets/models/packs/placeholders/car.glb",
                        "client/assets/models/packs/placeholders/tank.glb",
                        "client/tests/wheel_roll*", "client/tests/vehicle_anim*")),
    TestEntry("vehicle_brake_hold_test", "godot_script", "vehicle_brake_hold_test.gd", suite="godot",
              triggers=("client/scripts/player/player_input.gd", "client/scripts/menu/settings.gd",
                        "client/tests/vehicle_brake_hold*")),
    TestEntry("spikes_b_test", "godot_script", "spikes_b_test.gd", suite="godot",
              triggers=("client/scripts/world/frame_budget.gd", "client/scripts/world/item_models.gd",
                        "client/tests/spikes_b*")),
    TestEntry("stall_watchdog_test", "godot_script", "stall_watchdog_test.gd",
              args=("--", "--stall-watchdog=1"), suite="godot",
              triggers=("client/scripts/debug/stall_watchdog.gd", "client/scripts/debug/stall_crumb.gd",
                        "client/tests/stall_watchdog*")),
    TestEntry("switches_test", "godot_script", "switches_test.gd", suite="godot",
              triggers=("client/scripts/switches.gd", "client/scripts/main.gd", "client/tests/switches_test*")),
    TestEntry("model_pictures_test", "godot_script", "model_pictures_test.gd", suite="godot",
              triggers=("client/scripts/world/model_textures.gd", "client/scripts/world/model_library.gd",
                        "client/scripts/world/model_skin.gd", "client/tests/model_pictures_test*")),
    TestEntry("model_load_test", "godot_script", "model_load_test.gd", suite="godot",
              triggers=_MODEL_DONE_TRIGGERS, done_only=True),
    TestEntry("model_textures_test", "godot_script", "model_textures_test.gd", suite="godot",
              triggers=_MODEL_DONE_TRIGGERS, done_only=True),
    TestEntry("char_lod_zoom_test", "godot_script", "char_lod_zoom_test.gd", suite="godot",
              triggers=("client/scripts/world/view_priority.gd", "client/scripts/world/belt_lods.gd",
                        "client/scripts/world/far_chunks.gd", "client/scripts/world/ao_zoom.gd",
                        "client/scripts/world/model_lods.gd", "client/scripts/world/world.gd",
                        "client/tests/char_lod_zoom*")),
    TestEntry("cut_lods_test", "godot_script", "cut_lods_test.gd", suite="godot",
              triggers=("client/scripts/world/view_ahead.gd", "client/scripts/world/world.gd",
                        "client/scripts/world/far_chunks.gd", "client/scripts/world/cliff_wall.gd",
                        "client/scripts/world/chunk_view.gd", "client/scripts/addons/addon_world.gd",
                        "client/tests/cut_lods*")),
    TestEntry("cliff_fit_test", "godot_script", "cliff_fit_test.gd", suite="godot",
              triggers=("client/scripts/world/ground_height.gd", "client/shaders/ground_height*",
                        "client/scripts/addons/addon_terrain.gd", "client/tests/cliff_fit*")),
    TestEntry("profiler_overlay_test", "godot_script", "profiler_overlay_test.gd", suite="godot",
              triggers=("client/scripts/debug/debug_overlay.gd", "client/scripts/debug/probing.gd",
                        "client/tests/profiler_overlay*")),
    TestEntry("tree_lod_perf_test", "godot_script", "tree_lod_perf_test.gd", suite="godot",
              triggers=("client/scripts/world/model_lods.gd", "client/shaders/shadow_stand_in_leaf.gdshader",
                        "client/tests/tree_lod_perf_test.gd")),
    TestEntry("weapon_fx_perf_test", "godot_script", "weapon_fx_perf_test.gd", suite="godot",
              triggers=("client/scripts/fx/sprite_fx.gd", "client/scripts/fx/weapon_fx.gd",
                        "client/tests/weapon_fx_perf_test.gd")),
    TestEntry("anim_sweep_perf_test", "godot_script", "anim_sweep_perf_test.gd", suite="godot",
              triggers=("client/scripts/world/anim.gd", "client/scripts/world/signal_lights.gd",
                        "client/tests/anim_sweep_perf_test.gd")),
    TestEntry("render_cleanup_perf_test", "godot_script", "render_cleanup_perf_test.gd", suite="godot",
              triggers=("client/scripts/world/signal_lights.gd", "client/scripts/world/frame_budget.gd",
                        "client/scripts/world/item_cards.gd", "client/scripts/world/robot_swarm.gd",
                        "client/scripts/world/creatures.gd", "client/scripts/menu/settings.gd",
                        "client/scripts/player/player_input.gd", "client/tests/render_cleanup_perf_test.gd")),
    TestEntry("belt_mid_lod_test", "godot_script", "belt_mid_lod_test.gd", suite="godot",
              triggers=("client/scripts/world/belt_lods.gd", "client/scripts/world/chunk_view.gd",
                        "client/tests/belt_mid_lod_test.gd")),
    TestEntry("texture_compress_native_test", "godot_script", "texture_compress_native_test.gd", suite="godot",
              triggers=("client/native/belt_sim/src/texture_compress_native.h",
                        "client/native/belt_sim/src/texture_compress_native.cpp",
                        "client/native/belt_sim/src/register_types.cpp",
                        "client/scripts/world/terrain_textures.gd",
                        "client/scripts/world/decoratives.gd",
                        "client/scripts/world/decor_sheet_baker.gd",
                        "client/tests/texture_compress_native_test.gd")),
    TestEntry("mv_shader_perf_test", "godot_script", "mv_shader_perf_test.gd", suite="godot",
              triggers=("client/scripts/world/belt_mv.gd", "client/shaders/ghost_card.gdshader",
                        "client/shaders/sprite_card.gdshaderinc", "client/shaders/factorio_material.gdshaderinc",
                        "addons-src/cinematic-shaders/shaders/cinematic_grade.gdshader",
                        "addons-src/cinematic-shaders/main.gd", "client/tests/mv_shader_perf_test.gd")),
    # perf-w3-render (R1): no direct renderer read in the scripts that had them (static, fast), and the client
    # headless on the editor build with the render thread: no per-frame main-thread wait (starts its own Godot).
    TestEntry("render_sync_check --static", "py", "tools/render_sync_check.py", args=("--static",), suite="fast",
              triggers=("client/scripts/ui/factorio/model_preview.gd", "client/scripts/world/ghosts.gd",
                        "client/scripts/world/pipe_covers.gd", "client/scripts/world/decoratives.gd",
                        "client/scripts/world/sprite_standins.gd", "client/scripts/world/model_library.gd",
                        "client/scripts/world/terrain_textures.gd", "client/scripts/world/chunk_view.gd",
                        "client/scripts/world/render_reads.gd", "tools/render_sync_check.py")),
    TestEntry("render_sync_check --run", "py", "tools/render_sync_check.py", args=("--run",), suite="godot",
              triggers=("tools/render_sync_check.py",)),
    TestEntry("render_reads_test", "godot_script", "render_reads_test.gd", suite="godot",
              triggers=("client/scripts/world/render_reads.gd", "client/tests/render_reads_test.gd")),
    # Starts one Godot test itself, as above: the player's own Godot logs left alone.
    TestEntry("test_godot_logs", "py", "tools/test_godot_logs.py", suite="godot",
              triggers=("tools/check.py", "tools/test_godot_logs.py")),
]


def _changed_models(files: list[str]) -> list[str]:
    """The packs' models (tools/models/packs.py) as check.py names them: FUE5's share names with ours.
    Not their items/ (item models, which items.py checks; fnmatch's * crosses folders), nor files deleted
    since the base (the removed placeholder decoratives were each a 'missing' FAIL)."""
    return sorted({
        (f if "/decoratives/" in f else ("fue5/" if f.startswith("client/assets/models/packs/fue5/") else "") + pathlib.Path(f).name[:-4])
        for f in files
        if fnmatch.fnmatch(f, "client/assets/models/packs/*/*.glb") and "/items/" not in f and (REPO / f).exists()
    })


def plan(files: list[str], ui: str | None, done: bool) -> tuple[list[Check], list[str]]:
    """The checks for these files, and notes on what isn't checked here."""
    py = python_path()
    checks: list[Check] = []
    notes: list[str] = []

    def add(check: Check) -> None:
        if not any(c.name == check.name for c in checks):
            checks.append(check)

    scripts = [f for f in files if f.endswith(".gd") and (REPO / f).exists()]
    models = _changed_models(files)
    client_code = any_match(files, *_UI_TRIGGERS)
    covered_by_tests: set[str] = set()
    ui_area_added = False

    for entry in TESTS:
        if entry.kind == "gdparse":
            if scripts:
                add(entry.to_check(py, tuple(scripts)))
            continue
        if entry.kind == "models_check":
            if models:
                add(entry.to_check(py, tuple(models)))
            elif any_match(files, *entry.triggers):
                covered_by_tests.update(f for f in files if any_match([f], *entry.triggers))
                add(entry.to_check(py))
            continue
        if entry.target == "ui_test.tscn":
            if ui:
                add(godot_scene("ui_test " + ui, "ui_test.tscn", "--", "--only=" + ui))
            elif done and client_code:
                add(entry.to_check(py))
            continue
        if entry.done_only:
            if done and (any_match(files, *entry.triggers) or (models and entry.triggers == _MODEL_DONE_TRIGGERS)):
                add(entry.to_check(py))
            continue
        if entry.triggers and any_match(files, *entry.triggers):
            covered_by_tests.update(f for f in files if any_match([f], *entry.triggers))
            add(entry.to_check(py))

    if not ui and not done:
        unmatched = [f for f in files if f not in covered_by_tests]
        covered_by_area: set[str] = set()
        for area_name, patterns, sections, always_run in AREAS:
            pool = files if always_run else [f for f in unmatched if f not in covered_by_area]
            hits = [f for f in pool if any_match([f], *patterns)]
            if hits:
                add(godot_scene(area_name, "ui_test.tscn", "--", "--only=" + sections))
                ui_area_added = True
                if not always_run:
                    covered_by_area.update(hits)
        if client_code and not ui_area_added:
            notes.append("the UI test isn't run: --ui <sections> for the sections you touched, --done for all of it once the change is finished")

    if models and not done:
        notes.append("model loading isn't run: --done once the change is finished")
    if any_match(files, "client/shaders/*") and not ui_area_added and not ui and not done:
        notes.append("shaders have no automatic check here")
    return checks, notes


def all_scripts() -> list[str]:
    """Every GDScript file of the client, as paths from the repo's root (not Godot's .godot cache)."""
    return sorted(p.relative_to(REPO).as_posix() for p in (REPO / "client").rglob("*.gd") if ".godot" not in p.parts)


def all_checks(which: str) -> list[Check]:
    """--all: the fast suites (CI's tests job) or the headless Godot tests (CI's ui job), in registry order."""
    py = python_path()
    wanted: set[str] = set()
    if which in ("fast", "both"):
        wanted.add("fast")
    if which in ("godot", "both"):
        wanted.add("godot")
    checks: list[Check] = []
    for entry in TESTS:
        if entry.suite not in wanted:
            continue
        if entry.if_exists and not (REPO / entry.target).exists():
            continue
        checks.append(entry.to_check(py))
    return checks


def no_factorio_env(logs: pathlib.Path) -> None:
    """--no-factorio: the children's environment as on a CI runner (paths.gd no_factorio). A fresh home and
    APPDATA (so Godot's user:// starts empty, as on a runner, and no %APPDATA%/Factorio or ~/.factorio is found)."""
    # A home of this run's own (two runs at once never share or delete each other's), removed at exit
    # through safe_delete (the junction rule: links inside go as links, never their targets).
    import atexit
    import tempfile
    sys.path.insert(0, str(REPO / "tools"))
    import safe_delete
    logs.mkdir(parents=True, exist_ok=True)
    home = pathlib.Path(tempfile.mkdtemp(prefix="no-factorio-home-", dir=logs)).resolve()
    atexit.register(safe_delete.remove_tree, home)
    (home / "AppData" / "Roaming").mkdir(parents=True)
    # Godot found before the home moves (the ~/Tools/Godot lookup would miss it after), handed to the children
    # that look for it themselves (render_sync_check --run), as $GODOT is on CI.
    godot = godot_path()
    if godot and not CHILD_ENV.get("GODOT"):
        CHILD_ENV["GODOT"] = godot
    CHILD_ENV["ZENITH_NO_FACTORIO"] = "1"
    CHILD_ENV["HOME"] = str(home)
    CHILD_ENV["USERPROFILE"] = str(home)
    CHILD_ENV["APPDATA"] = str(home / "AppData" / "Roaming")
    CHILD_ENV["XDG_DATA_HOME"] = str(home / ".local" / "share")
    CHILD_ENV["XDG_CONFIG_HOME"] = str(home / ".config")
    print(f"--no-factorio: ZENITH_NO_FACTORIO=1, home {home}", flush=True)


def run_once(check: Check, godot: str | None, logs: pathlib.Path | None = None) -> tuple[bool, str, str]:
    """(passed, why not, the whole output)."""
    command = check.command
    if check.godot:
        if godot is None:
            return False, "no Godot found: set $GODOT", ""
        command = [godot, "--headless", "--audio-driver", "Dummy", "--path", str(REPO / "client"),
                   *godot_log(check.name, logs), *command]
    limit = GODOT_LIMIT if check.godot else 600
    try:
        done = subprocess.run(command, cwd=REPO, capture_output=True, text=True, encoding="utf-8", errors="replace",
                              timeout=limit, env=CHILD_ENV)
    except subprocess.TimeoutExpired as e:
        partial = e.stdout.decode("utf-8", "replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        return False, f"timed out after {limit} s", partial
    output = done.stdout + done.stderr
    if done.returncode != 0:
        lines = [l for l in output.splitlines() if l.startswith(("FAIL", "SCRIPT ERROR"))] or output.splitlines()[-15:]
        return False, "\n".join(lines[:40]), output
    if check.godot and "SCRIPT ERROR" in output:
        return False, "\n".join(l for l in output.splitlines() if "SCRIPT ERROR" in l)[:2000], output
    return True, "", output


def log_result(check: Check, seconds: float, result: str, base: str, attempts: int) -> None:
    path = main_checkout() / "art-src" / "check-log.jsonl"
    path.parent.mkdir(exist_ok=True)
    entry = {"at": time.strftime("%Y-%m-%dT%H:%M:%S"), "branch": git("rev-parse", "--abbrev-ref", "HEAD"), "base": base[:12],
             "check": check.name, "seconds": round(seconds, 1), "result": result, "attempts": attempts}
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(entry) + "\n")


def first_line(why: str) -> str:
    return next((l.strip() for l in why.splitlines() if l.strip()), "")[:300]


def report_all(which: str, results: list, seconds: float) -> None:
    """--all's table: on the console, and on GitHub Actions in the job's summary and as annotations."""
    failed = [r for r in results if r[1] != "passed"]
    width = max(len(c.name) for c, *_ in results)
    print(f"\n{'check':<{width}}  result  seconds")
    for check, result, secs, why in results:
        print(f"{check.name:<{width}}  {result:6}  {secs:7.1f}" + (f"  {first_line(why)}" if result != "passed" else ""))
    headline = (f"{len(results) - len(failed)} of {len(results)} passed in {seconds:.0f} s"
                + (": failed " + ", ".join(c.name for c, *_ in failed) if failed else ""))
    print(headline)
    if os.environ.get("GITHUB_ACTIONS"):
        for check, result, _, why in failed:
            # One line each: GitHub lists these on the run's page with the check's name.
            print(f"::error title={check.name} {result}::{first_line(why) or result}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write(f"### check.py --all {which}: {headline}\n\n| check | result | seconds | first failure |\n|---|---|---|---|\n")
            for check, result, secs, why in results:
                cell = first_line(why).replace("|", "\\|") if result != "passed" else ""
                f.write(f"| {check.name} | {result} | {secs:.1f} | {cell} |\n")
            f.write("\n")


def run_all(which: str, logs: pathlib.Path) -> int:
    checks = all_checks(which)
    godot = godot_path()
    if any(c.godot for c in checks) and godot and not (REPO / "client" / ".godot").exists():
        print("first Godot run in this checkout: importing")
        subprocess.run([godot, "--headless", "--audio-driver", "Dummy", "--path", str(REPO / "client"),
                        *godot_log("import", logs), "--import"], capture_output=True, timeout=900)
    logs.mkdir(parents=True, exist_ok=True)
    print(f"{len(checks)} checks; each one's whole output in {logs}", flush=True)
    results = []
    total = time.monotonic()
    for check in checks:
        start = time.monotonic()
        passed, why, output = run_once(check, godot, logs)
        secs = time.monotonic() - start
        result = "passed" if passed else "failed"
        (logs / (check.name.replace(" ", "_") + ".log")).write_text(output, encoding="utf-8")
        log_result(check, secs, result, "all-" + which, 1)
        print(f"{result:7} {secs:7.1f}s  {check.name}", flush=True)
        if not passed:
            print("        " + why.replace("\n", "\n        ")[:3000], flush=True)
        results.append((check, result, secs, why))
    report_all(which, results, time.monotonic() - total)
    return 1 if any(r[1] != "passed" for r in results) else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", help="commit to compare with (default: where this branch left main)")
    ap.add_argument("--ui", metavar="SECTIONS", help="sections of the UI test, comma separated")
    ap.add_argument("--done", action="store_true", help="the change is finished: the slower checks for it too")
    ap.add_argument("--list", action="store_true", help="say what would run, run nothing")
    ap.add_argument("--all", nargs="?", const="fast", choices=["fast", "godot", "both"],
                    help="every suite of that kind, whatever changed, each run once, then a table")
    ap.add_argument("--logs", type=pathlib.Path, help="with --all: where each check's whole output goes")
    ap.add_argument("--no-factorio", action="store_true",
                    help="run the tests as CI's runners see this PC: no Factorio install, Steam library or "
                         "Factorio folders found (ZENITH_NO_FACTORIO=1) and a fresh home/APPDATA for each run")
    args = ap.parse_args()
    if args.no_factorio:
        no_factorio_env(args.logs or main_checkout() / "art-src" / "check-logs")

    if args.all:
        if args.list:
            for c in all_checks(args.all):
                print("  " + c.name)
            return 0
        return run_all(args.all, args.logs or main_checkout() / "art-src" / "check-logs")

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
        subprocess.run([godot, "--headless", "--audio-driver", "Dummy", "--path", str(REPO / "client"), *godot_log("import"),
                        "--import"], capture_output=True, timeout=600)

    failed = 0
    total = time.monotonic()
    for check in checks:
        start = time.monotonic()
        passed, why, _ = run_once(check, godot)
        attempts = 1
        if not passed:
            print(f"{check.name}: failed, running it once more\n{why}")
            passed, why, _ = run_once(check, godot)
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
