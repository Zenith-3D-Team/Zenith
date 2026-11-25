"""Unit and smoke tests for tools/code_health.py."""
from __future__ import annotations

import pathlib
import sys
import tempfile

TOOLS = pathlib.Path(__file__).resolve().parent
REPO = TOOLS.parent
sys.path.insert(0, str(TOOLS))
import code_health  # noqa: E402

failures: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    print(("ok   " if ok else "FAIL ") + name + (f": {detail}" if detail and not ok else ""), flush=True)
    if not ok:
        failures.append(name)


def _write(path: pathlib.Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _build_synthetic_repo(root: pathlib.Path, *, healthy: bool) -> None:
    # Minimal tools/check.py + tools/protocol.py
    _write(root / "tools" / "protocol.py", '''
RELIABLE = {"welcome", "chunk"}
IMMEDIATE = {"mv", "bs"}
CLIENT = {"hello", "move"}
WIRE_VERSION = 5

def doc_problems(path=None):
    return [] if path and path.exists() else ["missing"]
''')
    extra_check = 'Check("test_extra", [py, "tools/test_extra.py"]),\n' if healthy else ""
    registry = "TESTS = []\n" if healthy else ""
    py39_hdr = "from __future__ import annotations\n" if healthy else ""
    gd_test_in_all = 'godot_script("sample_test", "sample_test.gd"),\n' if healthy else ""
    _write(root / "tools" / "check.py", f'''{py39_hdr}import pathlib
from dataclasses import dataclass
REPO = pathlib.Path(__file__).resolve().parents[1]
{registry}
@dataclass
class Check:
    name: str
    command: list
    godot: bool = False

def python_path():
    return "python"

def plan(files, ui=None, done=False):
    checks = []
    if any(f.endswith(".gd") for f in files):
        checks.append(Check("gdparse", ["python", "-m", "gdtoolkit.parser"]))
    if any("wire_decode.gd" in f or "message_decode.gd" in f for f in files):
        if {"True" if healthy else "False"}:
            checks.append(Check("bridge_fuzz_test", ["-s", "res://tests/bridge_fuzz_test.gd"], godot=True))
    if any("belt_sim_native.cpp" in f for f in files):
        if {"True" if healthy else "False"}:
            checks.append(Check("belt_sim_native_test", ["-s", "res://tests/belt_sim_native_test.gd"], godot=True))
    return checks, []

def all_checks(which):
    py = python_path()
    if which == "fast":
        return [{extra_check}Check("test_bridge", [py, "tools/mod_tests/test_bridge.py"])]
    if which == "godot":
        return [{gd_test_in_all}godot_script("belt_sim_native_test", "belt_sim_native_test.gd")]
    return []

def godot_script(name, script):
    return Check(name, ["-s", "res://tests/" + script], godot=True)
''')
    if healthy:
        _write(root / "tools" / "test_check.py", "# self test\n")
        _write(root / "tools" / "test_extra.py", "# extra test\n")
        _write(root / "tools" / "scratch_server.py", "# shared\n")
        _write(root / "tools" / "release" / "leak_scan.py", "# scan\n")
        _write(root / "requirements-dev.txt", "lupa==2.0\ngdtoolkit==4.0\n")
    else:
        _write(root / "tools" / "test_extra.py", "# unwired\n")
        for i in range(45):
            _write(root / "tools" / f"probe_{i}.py", "# probe\n")
        _write(root / "tools" / "split_progress.py", "# old\n")
        _write(root / "client" / "tests" / "ghost.gd.uid", "uid://dead\n")

    # Tests
    _write(root / "client" / "tests" / "sample_test.gd", "extends SceneTree\nfunc _init():\n\tquit(0)\n")
    _write(root / "client" / "tests" / "belt_sim_native_test.gd",
           'extends SceneTree\nfunc _init():\n\tif OS.get_name() == "Windows":\n\t\tquit(1)\n' if healthy
           else 'extends SceneTree\nfunc _init():\n\tquit(0)\n')
    _write(root / "client" / "tests" / "fixtures" / "wire_frames.json", "{}")
    _write(root / "tools" / "mod_tests" / "test_binary.py", "# binary\n")
    _write(root / "tools" / "mod_tests" / "test_bridge.py",
           'print(f"{passes} passed")\n' if healthy else 'print("all passed")\n')
    if healthy:
        _write(root / "tools" / "test_proto_sync.py",
               "# checks handlers. in session.lua against protocol.CLIENT and WIRE_VERSION in wire_decode.gd\n")

    # Mock & protocol docs
    _write(root / "docs" / "PROTOCOL.md", "## Mod → client\n")
    _write(root / "tools" / "mock_server.py",
           'PROTOCOL = 1\nms = [{"t": "welcome"}, {"t": "chunk"}, {"t": "mv"}, {"t": "bs"}]\n' if healthy
           else 'PROTOCOL = 1\nms = [{"t": "welcome"}]\n')

    # Mod & client code
    dep = '"base >= 2.1.0"' if healthy else '"base >= 2.0.59"'
    _write(root / "mod" / "factorio-3d-bridge" / "info.json",
           f'{{"version": "0.3.0", "factorio_version": "2.1", "dependencies": [{dep}]}}')
    _write(root / "mod" / "factorio-3d-bridge" / "scripts" / "session.lua",
           "local M = {}\nM.PROTOCOL = 1\nlocal handlers = {}\nfunction handlers.hello() end\nhandlers.move = function() end\n")
    _write(root / "mod" / "factorio-3d-bridge" / "scripts" / "transport.lua", "local M = {}\nM.WIRE_VERSION = 5\n")
    lua_locals = "\n".join(f"local v_{i} = {i}" for i in range(15 if healthy else 199))
    _write(root / "mod" / "factorio-3d-bridge" / "scripts" / "belt_sim.lua", lua_locals + "\n")
    _write(root / "mod" / "factorio-3d-bridge" / "scripts" / "belt_items.lua",
           "-- clean\n" if healthy else ('-- bi\n' * 410 + 'transport.send_parts("bi", 1)\n'))

    _write(root / "client" / "scripts" / "net" / "bridge.gd",
           'const PROTOCOL := 1\nvar h := {"bs": 1}\n' if healthy else 'const PROTOCOL := 1\nvar h := {"bs": 1}\n')
    _write(root / "client" / "scripts" / "net" / "wire_decode.gd", "const WIRE_VERSION := 5\n")
    _write(root / "client" / "scripts" / "net" / "message_decode.gd", "extends RefCounted\n")
    _write(root / "client" / "native" / "belt_sim" / "src" / "belt_sim_native.cpp", "// cpp\n")
    _write(root / "client" / "native" / "bin" / "belt_sim.dll", "dll")
    # Ensure bin mtime >= src mtime on healthy, < on unhealthy
    if not healthy:
        (_write(root / "client" / "native" / "belt_sim" / "src" / "belt_sim_native.cpp", "// newer cpp\n"))
        import os, time
        old = time.time() - 3600
        os.utime(root / "client" / "native" / "bin" / "belt_sim.dll", (old, old))

    if healthy:
        _write(root / "client" / "scripts" / "switches.gd", "# registry\n")
        _write(root / "client" / "scripts" / "main.gd", 'var a = OS.get_cmdline_user_args()\nvar f = "--my-flag"\n')
    else:
        for i in range(15):
            _write(root / "client" / "scripts" / f"m_{i}.gd",
                   f'class_name Bad{i}\nvar a = OS.get_cmdline_user_args()\nvar f = "--undoc-{i}"\nfunc _array(v):\n\treturn []\n')

    # Release & docs
    _write(root / "LICENSING.md", "GPL-3.0\n")
    _write(root / "CREDITS.md", "Credits\n")
    gd_ver = "4.7" if healthy else "4.4"
    gd_ext = "4.7" if healthy else "4.5"
    _write(root / "client" / "project.godot",
           f'[application]\nconfig/version="0.3.0"\nconfig/features=PackedStringArray("{gd_ver}", "Forward Plus")\n')
    _write(root / "client" / "native" / "belt_sim.gdextension", f'compatibility_minimum = "{gd_ext}"\n')
    _write(root / "client" / "export_presets.cfg",
           'application/version="0.3.0"\n' if healthy else 'application/version="0.2.1"\n')
    _write(root / ".github" / "workflows" / "tests.yml",
           'GODOT_VERSION: "4.7.2"\nrun: scons\n' if healthy else 'GODOT_VERSION: "4.7.2"\n')
    _write(root / "docs" / "tracker" / "releases.json",
           '{"releases": [{"version": "0.3.0"}]}' if healthy else '{"releases": [{"version": "0.2.1"}]}')
    _write(root / "addons-src" / "cam" / "addon.json", '{"id": "cam", "api": 1.8}')
    _write(root / "client" / "scripts" / "addons" / "addon_loader.gd", "const API_LEVEL := 1.91\n")
    _write(root / "docs" / "ADDONS.md", "API 1.91\n")
    _write(root / "tools" / "release" / "package.py",
           'ADDONS = ["cam"]\n# BUILD.json\n' if healthy else 'URL = "releases/latest"\n')
    _write(root / "STATUS.md", "## In flight\n- 0.3.0 work\n" if healthy else "## In flight\n**0.2.2 release**\n" + "\n" * 260)
    _write(root / "docs" / "RUNNING.md", "--my-flag\n" + ("\n" * (50 if healthy else 4800)))
    _write(root / "COORDINATION.md", "active\n" + ("\n" * (20 if healthy else 3800)))
    _write(root / "PROGRESS.md", "clean\n" if healthy else "2026-11-15 note\n" + ("\n" * 4200))
    _write(root / "docs" / "REPO-MAP.md", "addons-src client/native tools/release server\n" if healthy else "minimal\n")


def main() -> int:
    # 1. Interpolation & grade checks
    check("lerp_score ascending clamp",
          code_health.lerp_score(100, 100, 0, 10.0) == 10.0
          and code_health.lerp_score(150, 100, 0, 10.0) == 10.0
          and code_health.lerp_score(-5, 100, 0, 10.0) == 0.0)
    check("lerp_score descending",
          abs(code_health.lerp_score(15, 10, 20, 4.0) - 2.0) < 1e-9
          and code_health.lerp_score(5, 10, 20, 4.0) == 4.0
          and code_health.lerp_score(25, 10, 20, 4.0) == 0.0)
    check("grade_for thresholds",
          code_health.grade_for(92)[0] == "A"
          and code_health.grade_for(82)[0] == "B"
          and code_health.grade_for(68)[0] == "C"
          and code_health.grade_for(50)[0] == "D"
          and code_health.grade_for(30)[0] == "F")

    # 2. Lua top-level local counter
    lua_sample = """--[[
local ignored_in_block = 1
]]
local a, b, c = 1, 2, 3
local function helper()
  local indented_ignored = 99
end
local d -- trailing comment with , comma
-- local commented_out = 1
"""
    got_locals = code_health._count_lua_top_locals(lua_sample)
    check("lua top-level locals parser", got_locals == 5, f"got {got_locals}, expected 5")

    # 3. Oversized function detector
    with tempfile.TemporaryDirectory(prefix="zenith-fn-test-") as tmp:
        r = pathlib.Path(tmp)
        big_gd = "func short():\n\tpass\n\nfunc giant():\n" + ("\tvar x := 1\n" * 205) + "\nfunc ok():\n\tpass\n"
        big_lua = "local function small()\nend\nlocal function huge()\n" + ("  local x = 1\n" * 205) + "end\n"
        _write(r / "client" / "scripts" / "a.gd", big_gd)
        _write(r / "mod" / "factorio-3d-bridge" / "scripts" / "b.lua", big_lua)
        fns = code_health._find_oversized_functions(r, 200)
        names = {(rel, fn) for _, rel, fn in fns}
        check("oversized function detector",
              len(fns) == 2 and ("client/scripts/a.gd", "giant") in names and ("mod/factorio-3d-bridge/scripts/b.lua", "huge") in names,
              f"got {fns}")

    # 4. Synthetic healthy vs debt-heavy repos
    with tempfile.TemporaryDirectory(prefix="zenith-health-synth-") as tmp:
        base = pathlib.Path(tmp)
        good = base / "good"
        bad = base / "bad"
        _build_synthetic_repo(good, healthy=True)
        _build_synthetic_repo(bad, healthy=False)
        rep_good = code_health.analyze_tree(good)
        rep_bad = code_health.analyze_tree(bad)
        check("healthy total > debt-heavy total",
              rep_good["total"] > rep_bad["total"],
              f"good={rep_good['total']} vs bad={rep_bad['total']}")
        all_higher = all(
            pg["score"] > pb["score"]
            for pg, pb in zip(rep_good["pillars"], rep_bad["pillars"])
        )
        check("healthy beats debt-heavy on all 5 pillars",
              all_higher,
              f"good={[p['score'] for p in rep_good['pillars']]} bad={[p['score'] for p in rep_bad['pillars']]}")

        # 5. History dedup + HTML output + privacy guard
        hist_path = base / "hist.json"
        rep_a = dict(rep_good, commit="aaaa1111", dirty=False)
        rep_b = dict(rep_good, commit="aaaa1111", dirty=False, total=91.0)
        rep_c = dict(rep_bad, commit="bbbb2222", dirty=False)
        code_health.record_snapshot(hist_path, rep_a)
        snaps = code_health.record_snapshot(hist_path, rep_b)
        check("history deduplicates clean same-commit snapshot", len(snaps) == 1 and snaps[0]["total"] == 91.0)
        snaps = code_health.record_snapshot(hist_path, rep_c)
        check("history appends distinct commit snapshot", len(snaps) == 2)

        html_out = base / "dashboard.html"
        code_health.render_html_dashboard(rep_good, snaps, html_out)
        htxt = html_out.read_text(encoding="utf-8")
        check("html dashboard valid & no C:\\Users leak",
              "<svg" in htxt and f"{rep_good['total']:.1f}" in htxt and ":\\Users\\" not in htxt)

    # 6. Live repo smoke test
    live = code_health.analyze_tree(REPO, git_repo=REPO, include_local=False)
    pillar_weights = sum(p["weight"] for p in live["pillars"])
    pillar_scores = sum(p["score"] for p in live["pillars"])
    check("pillar weights sum to 100.0", abs(pillar_weights - 100.0) < 1e-6, str(pillar_weights))
    check("live repo score in [0, 100] & reconciles",
          len(live["pillars"]) == 5 and 0.0 <= live["total"] <= 100.0 and abs(pillar_scores - live["total"]) <= 0.2,
          f"total={live['total']}, sum={pillar_scores}")

    if failures:
        print(f"\n{len(failures)} check(s) failed")
        return 1
    print("\nall code_health checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
