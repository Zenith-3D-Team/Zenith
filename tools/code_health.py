#!/usr/bin/env python3
"""Deterministic code health and tech-debt scorer for Zenith.

Measures the codebase across five weighted pillars (100 points total),
tracks snapshots over time (including historical git revisions via --rev),
compares commits (--compare), and generates an offline HTML trend dashboard
(--html).

    python tools/code_health.py
    python tools/code_health.py --compare f02e08e3
    python tools/code_health.py --rev f02e08e3 --record --label "Baseline"
    python tools/code_health.py --record --html
    python tools/code_health.py --min-score 60

Python 3.9+ standard library only. Public-safe: contains no personal names,
paths, or private strings.
"""
from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import html
import importlib.util
import io
import json
import math
import pathlib
import re
import statistics
import subprocess
import sys
import tarfile
import tempfile
from typing import Any

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(errors="backslashreplace")

SCHEMA_VERSION = 1
RUBRIC_VERSION = "1.0"
REPO = pathlib.Path(__file__).resolve().parents[1]

# Engine/tool passthrough flags that should not require a Zenith switch entry.
PASSTHROUGH_FLAGS = frozenset({
    "--start-server", "--map-gen-settings", "--map-gen-seed", "--map-settings",
    "--server-settings", "--enable-lua-udp", "--rcon-port", "--rcon-bind",
    "--rcon-password", "--bind", "--port", "--mod-directory", "--config",
    "--create", "--headless", "--audio-driver", "--path", "--log-file",
    "--only", "--gd", "--native", "--quit", "--script", "--editor",
    "--export-release", "--export-pack", "--verbose", "--version",
})


def lerp_score(value: float, best: float, worst: float, max_pts: float) -> float:
    """Linearly interpolate a clamped score in [0, max_pts]."""
    if max_pts <= 0:
        return 0.0
    if best == worst:
        return max_pts if value == best else 0.0
    t = (value - worst) / (best - worst)
    t = max(0.0, min(1.0, t))
    return t * max_pts


def grade_for(score: float) -> tuple[str, str]:
    """Return (letter_grade, label) for a 0-100 score."""
    if score >= 90.0:
        return "A", "Exemplary"
    if score >= 80.0:
        return "B", "Healthy"
    if score >= 65.0:
        return "C", "Fair"
    if score >= 45.0:
        return "D", "Strained"
    return "F", "Critical"


def status_for(score: float, max_score: float) -> str:
    """Return 'green', 'amber', or 'red' based on fill ratio."""
    if max_score <= 0:
        return "green"
    ratio = score / max_score
    if ratio >= 0.80:
        return "green"
    if ratio >= 0.45:
        return "amber"
    return "red"


def _run_git(args: list[str], cwd: pathlib.Path, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=cwd,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=check,
    )


def main_checkout(repo: pathlib.Path = REPO) -> pathlib.Path:
    """Resolve the main checkout even when invoked inside a git worktree."""
    try:
        out = _run_git(["rev-parse", "--path-format=absolute", "--git-common-dir"], repo).stdout.strip()
        if out:
            return pathlib.Path(out).parent
    except (OSError, subprocess.CalledProcessError):
        pass
    return repo


def art_src_dir(repo: pathlib.Path = REPO) -> pathlib.Path | None:
    """Return art-src/ in the main checkout if it exists."""
    candidate = main_checkout(repo) / "art-src"
    if candidate.is_dir():
        return candidate
    local = repo / "art-src"
    return local if local.is_dir() else None


def _read_text(path: pathlib.Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def _line_count(path: pathlib.Path) -> int:
    txt = _read_text(path)
    return len(txt.splitlines()) if txt else 0


def _rglob_sorted(base: pathlib.Path, pattern: str) -> list[pathlib.Path]:
    if not base.is_dir():
        return []
    return sorted(p for p in base.rglob(pattern) if p.is_file() and ".godot" not in p.parts)


def _load_py_module(path: pathlib.Path, mod_name: str) -> Any | None:
    if not path.is_file():
        return None
    spec = importlib.util.spec_from_file_location(mod_name, path)
    if spec is None or spec.loader is None:
        return None
    mod = importlib.util.module_from_spec(spec)
    old_reconfig = getattr(sys.stdout, "reconfigure", None)
    try:
        spec.loader.exec_module(mod)
    except Exception:
        return None
    finally:
        if old_reconfig is None and hasattr(sys.stdout, "reconfigure"):
            pass
    return mod


def _make_metric(
    mid: str,
    label: str,
    value: Any,
    display: str,
    target: str,
    score: float,
    max_score: float,
    detail: str = "",
) -> dict[str, Any]:
    s = round(score, 2)
    return {
        "id": mid,
        "label": label,
        "value": value,
        "display": display,
        "target": target,
        "score": s,
        "max_score": round(max_score, 2),
        "status": status_for(s, max_score),
        "detail": detail,
    }


def _make_pillar(pid: str, name: str, weight: float, metrics: list[dict[str, Any]], details: dict[str, Any]) -> dict[str, Any]:
    raw_score = sum(m["score"] for m in metrics)
    score = round(min(weight, max(0.0, raw_score)), 1)
    pct = round((score / weight) * 100.0, 1) if weight > 0 else 100.0
    return {
        "id": pid,
        "name": name,
        "weight": weight,
        "score": score,
        "pct": pct,
        "status": status_for(score, weight),
        "metrics": metrics,
        "details": details,
    }


# ---------------------------------------------------------------------------
# Pillar 1: Tests & Verification (25 pts)
# ---------------------------------------------------------------------------

def _score_tests_pillar(root: pathlib.Path) -> dict[str, Any]:
    check_mod = _load_py_module(root / "tools" / "check.py", f"_zenith_check_{id(root)}")
    if check_mod is not None:
        check_mod.REPO = root
        check_mod.python_path = lambda: "python"

    gd_tests = sorted(p.name for p in _rglob_sorted(root / "client" / "tests", "*_test.gd") if p.parent == root / "client" / "tests")
    py_tests = sorted(p.relative_to(root).as_posix() for p in _rglob_sorted(root / "tools", "test_*.py"))

    all_fast_str = ""
    all_gd_str = ""
    manual_set: set[str] = set()
    check_src = _read_text(root / "tools" / "check.py")

    if check_mod is not None:
        try:
            fast_checks = check_mod.all_checks("fast")
            gd_checks = check_mod.all_checks("godot")
            all_fast_str = " ".join(" ".join(c.command) for c in fast_checks)
            all_gd_str = " ".join(" ".join(c.command) for c in gd_checks)
            manual_val = getattr(check_mod, "MANUAL", None)
            if manual_val:
                manual_set = {str(x) for x in manual_val}
        except Exception:
            pass

    wired_gd = [t for t in gd_tests if (t[:-3] in all_gd_str or t[:-3] in manual_set or t in manual_set)]
    map_only_gd = [t for t in gd_tests if t not in wired_gd and t[:-3] in check_src]
    unwired_gd = [t for t in gd_tests if t not in wired_gd and t not in map_only_gd]

    wired_py = [t for t in py_tests if (t in all_fast_str or t in all_gd_str or t in manual_set)]
    unwired_py = [t for t in py_tests if t not in wired_py]

    total_tests = len(gd_tests) + len(py_tests)
    total_wired = len(wired_gd) + len(wired_py)
    wire_pct = (total_wired / total_tests * 100.0) if total_tests else 100.0
    m_wiring = _make_metric(
        "ci_test_wiring",
        "CI / --all test wiring",
        round(wire_pct, 1),
        f"{total_wired}/{total_tests} ({wire_pct:.0f}%)",
        "100% wired",
        lerp_score(wire_pct, 100.0, 0.0, 6.0),
        6.0,
        f"Unwired GD: {len(unwired_gd)}, map-only GD: {len(map_only_gd)}, unwired PY: {len(unwired_py)}",
    )

    # 2. check.py file-map coverage over runtime code
    runtime_files: list[str] = []
    for sub, pat in [
        ("client/scripts", "*.gd"),
        ("client/native/belt_sim/src", "*.cpp"),
        ("client/native/belt_sim/src", "*.h"),
        ("mod/factorio-3d-bridge", "*.lua"),
        ("client/shaders", "*.gdshader*"),
        ("tools/release", "*.py"),
    ]:
        for p in _rglob_sorted(root / sub, pat):
            rel = p.relative_to(root).as_posix()
            if not rel.endswith("test_package.py"):
                runtime_files.append(rel)

    covered = 0
    uncovered_samples: list[str] = []
    if check_mod is not None and runtime_files:
        for rel in runtime_files:
            try:
                checks, _ = check_mod.plan([rel], None, False)
                if any(c.name != "gdparse" for c in checks):
                    covered += 1
                else:
                    uncovered_samples.append(rel)
            except Exception:
                uncovered_samples.append(rel)
    cov_pct = (covered / len(runtime_files) * 100.0) if runtime_files else 100.0
    m_map = _make_metric(
        "check_map_coverage",
        "check.py changed-file map coverage",
        round(cov_pct, 1),
        f"{covered}/{len(runtime_files)} ({cov_pct:.0f}%)",
        ">= 80% behavioral trigger",
        lerp_score(cov_pct, 80.0, 0.0, 5.0),
        5.0,
        f"{len(uncovered_samples)} runtime files trigger no behavioral test (gdparse/note only)",
    )

    # 3. Critical gates (4.0 pts, 1.0 each)
    def _has_non_gdparse(rel: str) -> bool:
        if not (root / rel).is_file():
            return True
        if check_mod is None:
            return False
        try:
            checks, _ = check_mod.plan([rel], None, False)
            return any(c.name != "gdparse" for c in checks)
        except Exception:
            return False

    gate_wire = _has_non_gdparse("client/scripts/net/wire_decode.gd") and _has_non_gdparse("client/scripts/net/message_decode.gd")
    gate_native = _has_non_gdparse("client/native/belt_sim/src/belt_sim_native.cpp")
    gate_registry = (root / "tools" / "test_check.py").is_file() or bool(re.search(r"^TESTS\s*[:=]\s*\[", check_src, re.M))

    tdir = root / "client" / "tests"
    orphan_uids = [p.name for p in sorted(tdir.glob("*.gd.uid")) if not (tdir / p.name[:-4]).is_file()] if tdir.is_dir() else []
    sceneless_node3d: list[str] = []
    if tdir.is_dir():
        for p in sorted(tdir.glob("*_test.gd")):
            if re.search(r"^extends\s+Node3D\b", _read_text(p), re.M) and not p.with_suffix(".tscn").is_file():
                sceneless_node3d.append(p.name)
    gate_clean_tests = (len(orphan_uids) == 0) and (len(sceneless_node3d) == 0)
    gates_ok = sum([gate_wire, gate_native, gate_registry, gate_clean_tests])
    m_gates = _make_metric(
        "critical_gates",
        "Critical test gates",
        gates_ok,
        f"{gates_ok}/4 gates",
        "4/4 gates",
        float(gates_ok),
        4.0,
        (
            f"wire_decode={'ok' if gate_wire else 'MISSING'}, "
            f"native_cpp={'ok' if gate_native else 'MISSING'}, "
            f"registry={'ok' if gate_registry else 'MISSING'}, "
            f"orphans/sceneless={'ok' if gate_clean_tests else f'{len(orphan_uids)} uids, {len(sceneless_node3d)} sceneless'}"
        ),
    )

    # 4. Test modularity (5.0 pts: max lines 3.0 + giant count 2.0)
    test_files: list[tuple[int, str]] = []
    for p in _rglob_sorted(root / "client" / "tests", "*.gd"):
        test_files.append((_line_count(p), p.relative_to(root).as_posix()))
    for p in _rglob_sorted(root / "tools", "test_*.py"):
        test_files.append((_line_count(p), p.relative_to(root).as_posix()))
    live_chk = root / "tools" / "live_check.py"
    if live_chk.is_file():
        test_files.append((_line_count(live_chk), "tools/live_check.py"))
    test_files.sort(reverse=True)
    max_test_lines = test_files[0][0] if test_files else 0
    max_test_name = test_files[0][1] if test_files else "-"
    giant_tests = [(n, name) for n, name in test_files if n >= 5000]
    mod_score = lerp_score(max_test_lines, 3000, 40000, 3.0) + lerp_score(len(giant_tests), 0, 5, 2.0)
    m_modularity = _make_metric(
        "test_modularity",
        "Test suite modularity",
        max_test_lines,
        f"max {max_test_lines:,} LOC ({len(giant_tests)} >= 5k)",
        "<= 3,000 LOC, 0 >= 5k",
        mod_score,
        5.0,
        f"Largest: {max_test_name} ({max_test_lines:,} lines)",
    )

    # 5. Protocol & runner hygiene (5.0 pts)
    proto_doc_probs: list[str] = []
    proto_mod = _load_py_module(root / "tools" / "protocol.py", f"_zenith_proto_{id(root)}")
    if proto_mod is not None and hasattr(proto_mod, "doc_problems") and (root / "docs" / "PROTOCOL.md").is_file():
        try:
            proto_doc_probs = list(proto_mod.doc_problems(root / "docs" / "PROTOCOL.md"))
        except Exception as exc:
            proto_doc_probs = [str(exc)]
    proto_doc_ok = (proto_mod is not None) and (len(proto_doc_probs) == 0)

    wire_fixture_ok = (root / "client" / "tests" / "fixtures" / "wire_frames.json").is_file() and (
        root / "tools" / "mod_tests" / "test_binary.py"
    ).is_file()

    py39_ok = ("from __future__ import annotations" in check_src) or not bool(
        re.search(r"def\s+\w+\([^)]*\|[^)]*\)|->\s*[^\n]*\|", check_src)
    )

    tb_txt = _read_text(root / "tools" / "mod_tests" / "test_bridge.py")
    bh_txt = _read_text(root / "tools" / "mod_tests" / "bridge_harness.py")
    combined_tb = tb_txt + "\n" + bh_txt
    pass_count_ok = bool(
        re.search(r"print\([^)]*(?:\{[^}]*(?:pass|count)|pass_count|passed_count|\d+\s+.*passed)", combined_tb, re.I)
        or re.search(r"\bpasses\s*\+=\s*1|\bpassed\s*\+=\s*1", combined_tb)
    )

    hyg_pts = (2.0 if proto_doc_ok else 0.0) + (1.0 if wire_fixture_ok else 0.0) + (1.0 if py39_ok else 0.0) + (1.0 if pass_count_ok else 0.0)
    m_runner = _make_metric(
        "protocol_and_runner_hygiene",
        "Protocol doc & runner hygiene",
        round(hyg_pts, 1),
        f"{hyg_pts:.1f}/5.0 checks",
        "5.0/5.0 checks",
        hyg_pts,
        5.0,
        (
            f"doc_problems={'ok' if proto_doc_ok else len(proto_doc_probs)}, "
            f"wire_fixture={'ok' if wire_fixture_ok else 'missing'}, "
            f"py39_check={'ok' if py39_ok else 'FAIL'}, "
            f"bridge_pass_count={'ok' if pass_count_ok else 'missing'}"
        ),
    )

    details = {
        "godot_tests_total": len(gd_tests),
        "python_tests_total": len(py_tests),
        "unwired_godot": unwired_gd,
        "map_only_godot": map_only_gd,
        "unwired_python": unwired_py,
        "orphan_uids": orphan_uids,
        "sceneless_node3d": sceneless_node3d,
        "giant_tests": giant_tests[:8],
        "uncovered_runtime_count": len(uncovered_samples),
        "protocol_doc_problems": proto_doc_probs[:5],
    }
    return _make_pillar("tests", "Tests & Verification", 25.0, [m_wiring, m_map, m_gates, m_modularity, m_runner], details)


# ---------------------------------------------------------------------------
# Pillar 2: Code Architecture & Discipline (25 pts)
# ---------------------------------------------------------------------------

def _count_lua_top_locals(text: str) -> int:
    count = 0
    in_block = False
    block_close = ""
    for line in text.splitlines():
        if in_block:
            idx = line.find(block_close)
            if idx == -1:
                continue
            line = line[idx + len(block_close):]
            in_block = False
            continue
        m_blk = re.match(r"^\s*--\[(=*)\[", line)
        if m_blk:
            close_pat = "]" + m_blk.group(1) + "]"
            rest = line[m_blk.end():]
            if close_pat not in rest:
                in_block = True
                block_close = close_pat
            continue
        m_fn = re.match(r"^local\s+function\s+[A-Za-z_]\w*", line)
        if m_fn:
            count += 1
            continue
        m_var = re.match(r"^local\s+([A-Za-z_][\w,\s]*)", line)
        if m_var:
            lhs = m_var.group(1).split("=")[0].split("--")[0]
            names = [n.strip() for n in lhs.split(",") if n.strip()]
            count += len(names)
    return count


def _find_oversized_functions(root: pathlib.Path, threshold: int = 200) -> list[tuple[int, str, str]]:
    oversized: list[tuple[int, str, str]] = []

    for gd in _rglob_sorted(root / "client" / "scripts", "*.gd"):
        rel = gd.relative_to(root).as_posix()
        lines = _read_text(gd).splitlines()
        cur_name: str | None = None
        cur_start = 0
        cur_indent = -1
        last_code_line = 0
        for idx, line in enumerate(lines, 1):
            stripped = line.lstrip(" \t")
            indent = len(line) - len(stripped)
            m = re.match(r"^(?:static\s+)?func\s+([A-Za-z_]\w*)\b", stripped)
            if m:
                if cur_name is not None and (last_code_line - cur_start + 1) >= threshold:
                    oversized.append((last_code_line - cur_start + 1, rel, cur_name))
                cur_name = m.group(1)
                cur_start = idx
                cur_indent = indent
                last_code_line = idx
                continue
            if cur_name is not None:
                if not stripped or stripped.startswith("#"):
                    continue
                if indent <= cur_indent and not stripped.startswith((")", "]", "}")):
                    if (last_code_line - cur_start + 1) >= threshold:
                        oversized.append((last_code_line - cur_start + 1, rel, cur_name))
                    cur_name = None
                else:
                    last_code_line = idx
        if cur_name is not None and (last_code_line - cur_start + 1) >= threshold:
            oversized.append((last_code_line - cur_start + 1, rel, cur_name))

    for lua in _rglob_sorted(root / "mod" / "factorio-3d-bridge", "*.lua"):
        rel = lua.relative_to(root).as_posix()
        lines = _read_text(lua).splitlines()
        cur_name = None
        cur_start = 0
        for idx, line in enumerate(lines, 1):
            m = re.match(r"^(?:local\s+)?function\s+([A-Za-z_][A-Za-z0-9_.:]*)", line)
            if m and cur_name is None:
                cur_name = m.group(1)
                cur_start = idx
                continue
            if cur_name is not None and re.match(r"^end\b", line):
                length = idx - cur_start + 1
                if length >= threshold:
                    oversized.append((length, rel, cur_name))
                cur_name = None

    oversized.sort(reverse=True)
    return oversized


def _score_architecture_pillar(root: pathlib.Path) -> dict[str, Any]:
    gd_files = _rglob_sorted(root / "client" / "scripts", "*.gd")
    lua_files = _rglob_sorted(root / "mod" / "factorio-3d-bridge", "*.lua")
    cpp_files = _rglob_sorted(root / "client" / "native" / "belt_sim" / "src", "*.cpp") + _rglob_sorted(
        root / "client" / "native" / "belt_sim" / "src", "*.h"
    )

    # 1. AGENTS.md rules
    class_name_hits = 0
    todo_hits = 0
    for p in gd_files:
        txt = _read_text(p)
        if re.search(r"^\s*class_name\b", txt, re.M):
            class_name_hits += 1
        todo_hits += len(re.findall(r"\b(?:TODO|FIXME)\b", txt))

    global_dot_hits = 0
    event_registrations: dict[str, list[str]] = {}
    lua_local_counts: list[tuple[int, str]] = []
    for p in lua_files:
        txt = _read_text(p)
        rel = p.relative_to(root).as_posix()
        todo_hits += len(re.findall(r"\b(?:TODO|FIXME)\b", txt))
        for line in txt.splitlines():
            code_part = line.split("--", 1)[0]
            for m in re.finditer(r"(?<![A-Za-z0-9_.])global\.", code_part):
                prefix = code_part[:m.start()]
                if not prefix.endswith("settings."):
                    global_dot_hits += 1
        for m in re.finditer(r"script\.on_event\s*\(\s*(defines\.events\.[A-Za-z0-9_]+)", txt):
            event_registrations.setdefault(m.group(1), []).append(rel)
        lua_local_counts.append((_count_lua_top_locals(txt), rel))

    dup_events = {ev: locs for ev, locs in event_registrations.items() if len(locs) > 1}
    rules_pts = (
        (1.5 if class_name_hits == 0 else 0.0)
        + (1.5 if global_dot_hits == 0 else 0.0)
        + (1.0 if len(dup_events) == 0 else 0.0)
        + (1.0 if todo_hits <= 5 else 0.0)
    )
    m_rules = _make_metric(
        "agents_rules",
        "AGENTS.md structural rules",
        round(rules_pts, 1),
        f"class_name:{class_name_hits}, global.:{global_dot_hits}, dup_ev:{len(dup_events)}, TODO:{todo_hits}",
        "0 violations, <= 5 TODOs",
        rules_pts,
        5.0,
    )

    # 2. Lua 200-local headroom
    lua_local_counts.sort(reverse=True)
    max_locals, max_lua_file = lua_local_counts[0] if lua_local_counts else (0, "-")
    if max_locals <= 140:
        lua_pts = 5.0
    elif max_locals <= 180:
        lua_pts = 2.5 + lerp_score(max_locals, 140, 180, 2.5)
    elif max_locals < 198:
        lua_pts = lerp_score(max_locals, 180, 198, 2.5)
    else:
        lua_pts = 0.0
    m_lua = _make_metric(
        "lua_local_headroom",
        "Lua 200-local limit headroom",
        max_locals,
        f"{max_locals}/200 ({pathlib.Path(max_lua_file).name})",
        "<= 140 locals",
        lua_pts,
        5.0,
        f"Top Lua locals: {', '.join(f'{pathlib.Path(f).name}:{n}' for n, f in lua_local_counts[:4])}",
    )

    # 3. Monolith containment (>= 2,000 lines)
    shipped = gd_files + lua_files + cpp_files
    file_sizes = sorted([(_line_count(p), p.relative_to(root).as_posix()) for p in shipped], reverse=True)
    total_shipped_loc = sum(n for n, _ in file_sizes)
    monoliths = [(n, name) for n, name in file_sizes if n >= 2000]
    mono_loc = sum(n for n, _ in monoliths)
    mono_pct = (mono_loc / total_shipped_loc * 100.0) if total_shipped_loc else 0.0
    mono_pts = lerp_score(mono_pct, 10.0, 50.0, 2.5) + lerp_score(len(monoliths), 6, 35, 2.5)
    m_mono = _make_metric(
        "monolith_containment",
        "Shipped file monoliths (>=2k LOC)",
        round(mono_pct, 1),
        f"{len(monoliths)} files, {mono_pct:.1f}% of LOC",
        "<= 6 files, <= 10% LOC",
        mono_pts,
        5.0,
        f"Top: {file_sizes[0][1]} ({file_sizes[0][0]:,} LOC)" if file_sizes else "",
    )

    # 4. Function size (>= 200 lines)
    oversized_fns = _find_oversized_functions(root, 200)
    m_fns = _make_metric(
        "function_size",
        "Oversized functions (>=200 LOC)",
        len(oversized_fns),
        f"{len(oversized_fns)} funcs",
        "<= 5 funcs",
        lerp_score(len(oversized_fns), 5, 50, 2.0),
        2.0,
        f"Top: {oversized_fns[0][1]}:{oversized_fns[0][2]} ({oversized_fns[0][0]} LOC)" if oversized_fns else "none",
    )

    # 5. Switch governance
    scatter_files = 0
    scatter_sites = 0
    distinct_flags: set[str] = set()
    for p in gd_files:
        txt = _read_text(p)
        c = txt.count("get_cmdline_user_args")
        if c:
            scatter_files += 1
            scatter_sites += c
        for m in re.finditer(r'["\'](--[a-z][a-z0-9-]+)', txt):
            flag = m.group(1)
            if flag not in PASSTHROUGH_FLAGS and not flag.startswith("--ui-"):
                distinct_flags.add(flag)

    has_switch_registry = (root / "client" / "scripts" / "switches.gd").is_file() or (
        root / "client" / "scripts" / "util" / "switches.gd"
    ).is_file()
    docs_switch_txt = _read_text(root / "docs" / "RUNNING.md") + "\n" + _read_text(root / "docs" / "SWITCHES.md")
    documented_flags = {f for f in distinct_flags if f in docs_switch_txt}
    undocumented_flags = sorted(distinct_flags - documented_flags)
    doc_pct = (len(documented_flags) / len(distinct_flags) * 100.0) if distinct_flags else 100.0
    sw_pts = (
        lerp_score(scatter_files, 5, 120, 1.5)
        + (1.0 if has_switch_registry else 0.0)
        + lerp_score(doc_pct, 98.0, 70.0, 1.5)
    )
    m_switch = _make_metric(
        "switch_governance",
        "CLI switch governance",
        scatter_files,
        f"{scatter_files} files ({scatter_sites} sites), reg={'yes' if has_switch_registry else 'no'}, {doc_pct:.0f}% docs",
        "<= 5 files, registry, >= 98% docs",
        sw_pts,
        4.0,
        f"{len(distinct_flags)} flags, {len(undocumented_flags)} undocumented",
    )

    # 6. DRY & clean shaders
    array_defs = 0
    raw_yaw_sites = 0
    for p in gd_files:
        rel = p.relative_to(root).as_posix()
        txt = _read_text(p)
        array_defs += len(re.findall(r"^\s*(?:static\s+)?func\s+_array\s*\(", txt, re.M))
        if not rel.endswith(("visuals.gd", "util/wire.gd")):
            raw_yaw_sites += len(re.findall(r"/\s*16\.0\s*\*\s*TAU", txt))

    shaders = _rglob_sorted(root / "client" / "shaders", "*.gdshader")
    ref_corpus_paths = (
        gd_files
        + _rglob_sorted(root / "client", "*.tscn")
        + _rglob_sorted(root / "client", "*.tres")
        + _rglob_sorted(root / "client" / "shaders", "*.gdshader*")
        + _rglob_sorted(root / "addons-src", "*.gd")
    )
    ref_corpus = "\n".join(_read_text(p) for p in ref_corpus_paths)
    unref_shaders = [s.name for s in shaders if s.name not in ref_corpus]
    dry_pts = (
        lerp_score(array_defs, 1, 12, 1.0)
        + lerp_score(raw_yaw_sites, 2, 20, 1.0)
        + lerp_score(len(unref_shaders), 0, 5, 2.0)
    )
    m_dry = _make_metric(
        "dry_and_clean_assets",
        "DRY helpers & shader refs",
        array_defs + raw_yaw_sites + len(unref_shaders),
        f"_array:{array_defs}, yaw:{raw_yaw_sites}, unref_sh:{len(unref_shaders)}",
        "_array<=1, yaw<=2, 0 unref shaders",
        dry_pts,
        4.0,
    )

    details = {
        "shipped_files": len(shipped),
        "shipped_loc": total_shipped_loc,
        "monolith_count": len(monoliths),
        "monolith_loc_pct": round(mono_pct, 1),
        "top_monoliths": monoliths[:10],
        "top_lua_locals": lua_local_counts[:5],
        "top_functions": oversized_fns[:5],
        "cmdline_scatter_files": scatter_files,
        "cmdline_scatter_sites": scatter_sites,
        "has_switch_registry": has_switch_registry,
        "distinct_flags": len(distinct_flags),
        "undocumented_flags": undocumented_flags[:15],
        "array_defs": array_defs,
        "raw_yaw_sites": raw_yaw_sites,
        "unreferenced_shaders": unref_shaders,
    }
    return _make_pillar("architecture", "Code Architecture & Discipline", 25.0, [m_rules, m_lua, m_mono, m_fns, m_switch, m_dry], details)


# ---------------------------------------------------------------------------
# Pillar 3: Native Parity, Protocol & Dead Paths (20 pts)
# ---------------------------------------------------------------------------

def _git_last_ts(git_repo: pathlib.Path, rev: str, subpath: str) -> int | None:
    try:
        out = _run_git(["log", "-1", "--format=%ct", rev, "--", subpath], git_repo).stdout.strip()
        return int(out) if out else None
    except (OSError, subprocess.CalledProcessError, ValueError):
        return None


def _score_parity_protocol_pillar(root: pathlib.Path, git_repo: pathlib.Path | None, rev: str | None) -> dict[str, Any]:
    src_dir = root / "client" / "native" / "belt_sim" / "src"
    bin_dir = root / "client" / "native" / "bin"

    # 1. Native DLL freshness
    dll_fresh = True
    dll_detail = "no native dir"
    if src_dir.is_dir():
        if git_repo is not None:
            target = rev or "HEAD"
            src_ts = _git_last_ts(git_repo, target, "client/native/belt_sim/src")
            bin_ts = _git_last_ts(git_repo, target, "client/native/bin")
            dirty_src = False
            dirty_bin = False
            if rev is None:
                try:
                    dirty_src = bool(_run_git(["status", "--porcelain", "--", "client/native/belt_sim/src"], git_repo).stdout.strip())
                    dirty_bin = bool(_run_git(["status", "--porcelain", "--", "client/native/bin"], git_repo).stdout.strip())
                except (OSError, subprocess.CalledProcessError):
                    pass
            if bin_ts is None:
                dll_fresh = False
                dll_detail = "no binary commit"
            elif dirty_src and not dirty_bin:
                dll_fresh = False
                dll_detail = "uncommitted C++ edits without DLL rebuild"
            elif src_ts is not None and bin_ts < src_ts:
                dll_fresh = False
                dll_detail = f"bin commit older than src ({bin_ts} < {src_ts})"
            else:
                dll_fresh = True
                dll_detail = "bin commit >= src commit"
        else:
            bins = list(bin_dir.glob("*")) if bin_dir.is_dir() else []
            srcs = list(src_dir.glob("*"))
            if not bins:
                dll_fresh = False
                dll_detail = "missing native binary"
            else:
                src_m = max((p.stat().st_mtime for p in srcs), default=0.0)
                bin_m = max((p.stat().st_mtime for p in bins), default=0.0)
                dll_fresh = bin_m >= src_m
                dll_detail = "binary mtime >= src mtime" if dll_fresh else "binary older than src"

    m_dll = _make_metric(
        "native_dll_freshness",
        "Native DLL freshness",
        dll_fresh,
        "fresh" if dll_fresh else "STALE",
        "bin >= src",
        4.0 if dll_fresh else 0.0,
        4.0,
        dll_detail,
    )

    # 2. Native parity enforcement
    bs_nat_test = _read_text(root / "client" / "tests" / "belt_sim_native_test.gd")
    win_fail_enforced = bool(
        re.search(r'OS\.get_name\(\)\s*==\s*"Windows"', bs_nat_test)
        or "source_hash" in bs_nat_test
        or (bs_nat_test and "quit(0)" not in bs_nat_test)
    )
    ci_yml = _read_text(root / ".github" / "workflows" / "tests.yml")
    ci_builds_native = bool(re.search(r"\bscons\b|belt_sim\.linux|godot-cpp", ci_yml))
    bi_gd = _read_text(root / "client" / "scripts" / "world" / "belt_items.gd")
    has_method_cnt = len(re.findall(r"\.has_method\s*\(", bi_gd))
    parity_pts = (
        (1.5 if win_fail_enforced else 0.0)
        + (1.5 if ci_builds_native else 0.0)
        + lerp_score(has_method_cnt, 5, 30, 1.0)
    )
    m_parity = _make_metric(
        "native_parity_enforcement",
        "Native parity enforcement",
        round(parity_pts, 1),
        f"win_fail:{'yes' if win_fail_enforced else 'no'}, ci_so:{'yes' if ci_builds_native else 'no'}, has_method:{has_method_cnt}",
        "win_fail, ci_so, <=5 has_method",
        parity_pts,
        4.0,
    )

    # 3. Protocol version sync
    session_lua = _read_text(root / "mod" / "factorio-3d-bridge" / "scripts" / "session.lua")
    bridge_gd = _read_text(root / "client" / "scripts" / "net" / "bridge.gd")
    mock_py = _read_text(root / "tools" / "mock_server.py")
    proto_py_txt = _read_text(root / "tools" / "protocol.py")
    transport_lua = _read_text(root / "mod" / "factorio-3d-bridge" / "scripts" / "transport.lua")
    wire_gd = _read_text(root / "client" / "scripts" / "net" / "wire_decode.gd")

    def _extract_int(pat: str, text: str) -> int | None:
        m = re.search(pat, text, re.M)
        return int(m.group(1)) if m else None

    p_vals = {
        "session.lua": _extract_int(r"M\.PROTOCOL\s*=\s*(\d+)", session_lua),
        "bridge.gd": _extract_int(r"const\s+PROTOCOL\s*:?=\s*(\d+)", bridge_gd),
        "mock_server.py": _extract_int(r"^PROTOCOL\s*=\s*(\d+)", mock_py),
    }
    p_present = [v for v in p_vals.values() if v is not None]
    proto_sync = len(p_present) >= 2 and len(set(p_present)) == 1

    w_vals = {
        "protocol.py": _extract_int(r"^WIRE_VERSION\s*=\s*(\d+)", proto_py_txt),
        "transport.lua": _extract_int(r"M\.WIRE_VERSION\s*=\s*(\d+)", transport_lua),
        "wire_decode.gd": _extract_int(r"const\s+WIRE_VERSION\s*:?=\s*(\d+)", wire_gd),
    }
    w_present = [v for v in w_vals.values() if v is not None]
    wire_sync = (len(w_present) == 0) or (len(w_present) >= 2 and len(set(w_present)) == 1)

    proto_test_corpus = "\n".join(
        _read_text(p) for p in _rglob_sorted(root / "tools", "test_*.py") if p.name != "test_code_health.py"
    )
    has_cross_proto_test = bool(
        re.search(r"handlers\.", proto_test_corpus)
        and re.search(r"protocol\.CLIENT", proto_test_corpus)
        and re.search(r"wire_decode\.gd", proto_test_corpus)
        and re.search(r"WIRE_VERSION", proto_test_corpus)
    )
    sync_pts = (2.0 if proto_sync else 0.0) + (2.0 if wire_sync else 0.0) + (1.0 if has_cross_proto_test else 0.0)
    m_psync = _make_metric(
        "protocol_version_sync",
        "Protocol & wire version sync",
        round(sync_pts, 1),
        f"PROTOCOL={'ok' if proto_sync else 'MISMATCH'}, WIRE={'ok' if wire_sync else 'MISMATCH'}, x_test={'yes' if has_cross_proto_test else 'no'}",
        "synced + automated cross-test",
        sync_pts,
        5.0,
    )

    # 4. Handler & mock coverage
    lua_handlers = set(re.findall(r"^(?:function\s+)?handlers\.([a-z0-9_]+)\s*(?:\(|=)", session_lua, re.M))
    proto_mod = _load_py_module(root / "tools" / "protocol.py", f"_zenith_proto_p3_{id(root)}")
    py_client_cmds: set[str] = set()
    py_mod_types: set[str] = set()
    if proto_mod is not None:
        py_client_cmds = set(getattr(proto_mod, "CLIENT", set()))
        py_mod_types = set(getattr(proto_mod, "RELIABLE", set())) | set(getattr(proto_mod, "IMMEDIATE", set()))

    if lua_handlers or py_client_cmds:
        union_h = lua_handlers | py_client_cmds
        inter_h = lua_handlers & py_client_cmds
        handler_pct = (len(inter_h) / len(union_h) * 100.0) if union_h else 100.0
    else:
        handler_pct = 100.0

    mock_corpus = "\n".join(_read_text(p) for p in _rglob_sorted(root / "tools", "mock*.py"))
    mock_types = set(re.findall(r'["\']t["\']\s*:\s*["\']([a-z0-9_]+)["\']', mock_corpus))
    mock_types |= set(re.findall(r'send_(?:list|parts|now|reliable)\(\s*["\']([a-z0-9_]+)["\']', mock_corpus))
    mock_cov_pct = (len(py_mod_types & mock_types) / len(py_mod_types) * 100.0) if py_mod_types else 100.0
    mock_missing = sorted(py_mod_types - mock_types)
    cov_pts = lerp_score(handler_pct, 100.0, 70.0, 2.0) + lerp_score(mock_cov_pct, 100.0, 60.0, 2.0)
    m_cov = _make_metric(
        "protocol_handler_and_mock",
        "Handler & mock coverage",
        round(mock_cov_pct, 1),
        f"handlers:{handler_pct:.0f}%, mock:{len(py_mod_types & mock_types)}/{len(py_mod_types)} ({mock_cov_pct:.0f}%)",
        "100% handlers & mock",
        cov_pts,
        4.0,
        f"Mock missing ({len(mock_missing)}): {', '.join(mock_missing[:10])}" if mock_missing else "complete",
    )

    # 5. Legacy dead paths (Factorio 2.0 fallbacks + unreachable bi sender)
    info_raw = _read_text(root / "mod" / "factorio-3d-bridge" / "info.json")
    info_data: dict[str, Any] = {}
    try:
        if info_raw:
            info_data = json.loads(info_raw)
    except json.JSONDecodeError:
        pass
    fac_ver = str(info_data.get("factorio_version", ""))
    deps = " ".join(str(x) for x in info_data.get("dependencies", []))
    dep_20_stale = (fac_ver == "2.1") and ("base >= 2.0" in deps)
    dep_pts = 0.0 if dep_20_stale else 0.75

    lua_20_fallbacks = 0
    for p in _rglob_sorted(root / "mod" / "factorio-3d-bridge" / "scripts", "*.lua"):
        for line in _read_text(p).splitlines():
            if re.search(r"\b2\.0(?:'s|\b)", line) and re.search(r"pcall|neighbours|categor|inventor|pollut|defines", line, re.I):
                lua_20_fallbacks += 1
    fb_pts = lerp_score(lua_20_fallbacks, 0, 8, 0.75)

    bi_lua = _read_text(root / "mod" / "factorio-3d-bridge" / "scripts" / "belt_items.lua")
    client_forces_bs = bool(re.search(r'"bs"\s*:\s*1\b', bridge_gd)) and not bool(re.search(r'"bs"\s*:\s*0\b', bridge_gd))
    mod_has_bi_sender = ('send_parts("bi"' in bi_lua or "send_parts('bi'" in bi_lua) and len(bi_lua.splitlines()) > 400
    bi_pts = 0.0 if (client_forces_bs and mod_has_bi_sender) else 1.5

    dead_pts = dep_pts + fb_pts + bi_pts
    m_dead = _make_metric(
        "legacy_dead_paths",
        "Legacy & unreachable paths",
        round(dead_pts, 2),
        f"2.0_dep:{'stale' if dep_20_stale else 'ok'}, 2.0_pcalls:{lua_20_fallbacks}, bi_sender:{'dead' if bi_pts == 0 else 'clean'}",
        "2.1 dep, 0 fallbacks, no dead bi",
        dead_pts,
        3.0,
    )

    details = {
        "dll_fresh": dll_fresh,
        "has_method_count": has_method_cnt,
        "protocol_values": p_vals,
        "wire_values": w_vals,
        "lua_handlers_count": len(lua_handlers),
        "protocol_client_count": len(py_client_cmds),
        "mock_missing_types": mock_missing,
        "lua_20_fallbacks": lua_20_fallbacks,
        "dead_bi_sender": client_forces_bs and mod_has_bi_sender,
    }
    return _make_pillar("parity_protocol", "Native Parity, Protocol & Dead Paths", 20.0, [m_dll, m_parity, m_psync, m_cov, m_dead], details)


# ---------------------------------------------------------------------------
# Pillar 4: Release & Build Readiness (15 pts)
# ---------------------------------------------------------------------------

def _score_release_pillar(root: pathlib.Path, git_repo: pathlib.Path | None, rev: str | None, main_art: pathlib.Path | None) -> dict[str, Any]:
    # 1. License & gitignore
    lic_ok = (root / "LICENSING.md").is_file() and (root / "CREDITS.md").is_file()
    ignored_tracked = 0
    if git_repo is not None and rev is None:
        try:
            out = _run_git(["ls-files", "-ci", "--exclude-standard"], git_repo).stdout.splitlines()
            ignored_tracked = len([l for l in out if l.strip()])
        except (OSError, subprocess.CalledProcessError):
            pass
    lic_pts = (1.5 if lic_ok else 0.0) + (1.5 if ignored_tracked == 0 else 0.0)
    m_lic = _make_metric(
        "license_and_gitignore",
        "Licensing & .gitignore hygiene",
        round(lic_pts, 1),
        f"LIC+CREDITS:{'ok' if lic_ok else 'MISSING'}, ignored_tracked:{ignored_tracked}",
        "both present, 0 ignored tracked",
        lic_pts,
        3.0,
    )

    # 2. Version & manifest alignment
    info_ver = ""
    try:
        info_ver = str(json.loads(_read_text(root / "mod" / "factorio-3d-bridge" / "info.json")).get("version", ""))
    except Exception:
        pass
    proj_txt = _read_text(root / "client" / "project.godot")
    m_pv = re.search(r'^config/version="([^"]+)"', proj_txt, re.M)
    proj_ver = m_pv.group(1) if m_pv else ""
    proj_ok = bool(info_ver) and proj_ver == info_ver

    presets_txt = _read_text(root / "client" / "export_presets.cfg")
    preset_vers = re.findall(r'^application/(?:short_)?version="([^"]+)"', presets_txt, re.M)
    presets_ok = bool(info_ver) and (not preset_vers or all(v == info_ver for v in preset_vers))

    rel_json_path = root / "docs" / "tracker" / "releases.json"
    rel_ok = True
    if rel_json_path.is_file():
        try:
            rdata = json.loads(_read_text(rel_json_path))
            rel_vers = {str(r.get("version", "")) for r in rdata.get("releases", []) if isinstance(r, dict)}
            rel_ok = info_ver in rel_vers
        except Exception:
            rel_ok = False

    status_txt = _read_text(root / "STATUS.md")
    in_flight_block = ""
    m_if = re.search(r"^##\s+In flight\b(.*?)(?=^##\s|\Z)", status_txt, re.M | re.S)
    if m_if:
        in_flight_block = m_if.group(1)
    stale_status_ver = False
    if info_ver and in_flight_block:
        for mv in re.finditer(r"\*\*(0\.\d+\.\d+)\s+release\*\*", in_flight_block):
            if mv.group(1) != info_ver:
                stale_status_ver = True

    ver_pts = (1.5 if proj_ok else 0.0) + (1.0 if presets_ok else 0.0) + (1.0 if rel_ok else 0.0) + (0.5 if not stale_status_ver else 0.0)
    m_ver = _make_metric(
        "version_manifest_alignment",
        "Release version alignment",
        round(ver_pts, 1),
        f"info:{info_ver or '?'}, godot:{proj_ver or '?'}, presets:{set(preset_vers) or {'none'}}, rel_json:{'ok' if rel_ok else 'MISSING'}",
        f"all == {info_ver or 'target'}",
        ver_pts,
        4.0,
        f"STATUS In-flight stale release header: {'yes' if stale_status_ver else 'no'}",
    )

    # 3. Engine & Python toolchain sync
    m_feat = re.search(r'config/features=PackedStringArray\("(\d+\.\d+)"', proj_txt)
    gd_feat = m_feat.group(1) if m_feat else ""
    gdext_txt = _read_text(root / "client" / "native" / "belt_sim.gdextension")
    m_gext = re.search(r'compatibility_minimum\s*=\s*"(\d+\.\d+)', gdext_txt)
    gd_ext = m_gext.group(1) if m_gext else ""
    ci_yml = _read_text(root / ".github" / "workflows" / "tests.yml")
    m_ci = re.search(r'GODOT_VERSION:\s*"?(\d+\.\d+)', ci_yml)
    gd_ci = m_ci.group(1) if m_ci else ""

    godot_vers = [v for v in (gd_feat, gd_ext, gd_ci) if v]
    distinct_godot = len(set(godot_vers))
    if distinct_godot <= 1:
        godot_sync_pts = 2.0
    elif distinct_godot == 2:
        godot_sync_pts = 1.0
    else:
        godot_sync_pts = 0.0

    req_txt = _read_text(root / "requirements-dev.txt") + _read_text(root / "pyproject.toml")
    has_reqs = "lupa" in req_txt and "gdtoolkit" in req_txt
    tool_pts = godot_sync_pts + (1.0 if has_reqs else 0.0)
    m_tool = _make_metric(
        "engine_toolchain_sync",
        "Godot & Python toolchain sync",
        distinct_godot,
        f"Godot: [{gd_feat or '?'}, {gd_ext or '?'}, {gd_ci or '?'}], reqs:{'yes' if has_reqs else 'no'}",
        "1 Godot minor, requirements-dev.txt",
        tool_pts,
        3.0,
    )

    # 4. Packaging reproducibility
    pkg_txt = _read_text(root / "tools" / "release" / "package.py")
    pinned_addons = ("releases/latest" not in pkg_txt) and ("zipball" not in pkg_txt) if pkg_txt else False
    emits_build_json = "BUILD.json" in pkg_txt
    addon_dirs = sorted(p.parent.name for p in _rglob_sorted(root / "addons-src", "addon.json"))
    addons_listed = sum(1 for a in addon_dirs if a in pkg_txt)
    addon_frac = (addons_listed / len(addon_dirs)) if addon_dirs else 1.0
    pkg_pts = (0.75 if pinned_addons else 0.0) + (0.75 if emits_build_json else 0.0) + 1.5 * addon_frac
    m_pkg = _make_metric(
        "packaging_reproducibility",
        "Release packaging reproducibility",
        round(pkg_pts, 2),
        f"pinned:{'yes' if pinned_addons else 'no'}, BUILD.json:{'yes' if emits_build_json else 'no'}, addons:{addons_listed}/{len(addon_dirs)}",
        "pinned, BUILD.json, all addons-src",
        pkg_pts,
        3.0,
    )

    # 5. Leak scan automation
    has_leak_scan = (root / "tools" / "release" / "leak_scan.py").is_file()
    private_prefixes: list[str] = []
    forbidden_extras: list[str] = []
    if main_art is not None:
        pp = main_art / "release" / "private-paths.txt"
        if pp.is_file():
            private_prefixes = [l.strip().replace("\\", "/") for l in _read_text(pp).splitlines() if l.strip() and not l.startswith("#")]
        fs = main_art / "release" / "forbidden-strings.txt"
        if fs.is_file():
            forbidden_extras = [l.strip() for l in _read_text(fs).splitlines() if l.strip() and not l.startswith("#")]

    def _is_private(rel: str) -> bool:
        return any(rel == pref or rel.startswith(pref.rstrip("/") + "/") or rel.startswith(pref) for pref in private_prefixes)

    win_user_re = re.compile(r"[A-Za-z]:[\\/]Users[\\/](?!\.\.\.)[A-Za-z0-9_.-]+")
    leak_hits: list[str] = []
    scan_exts = {".py", ".gd", ".lua", ".md", ".json", ".ps1", ".sh", ".cfg", ".yml", ".yaml", ".txt"}
    for p in _rglob_sorted(root, "*"):
        rel = p.relative_to(root).as_posix()
        if rel.startswith(("art-src/", ".git/", "client/assets/")):
            continue
        if p.suffix.lower() not in scan_exts or _is_private(rel):
            continue
        txt = _read_text(p)
        if win_user_re.search(txt) or any(s in txt for s in forbidden_extras):
            leak_hits.append(rel)

    leak_pts = (1.0 if has_leak_scan else 0.0) + (1.0 if len(leak_hits) == 0 else 0.0)
    m_leak = _make_metric(
        "leak_scan_automation",
        "Privacy & leak-scan guard",
        round(leak_pts, 1),
        f"leak_scan.py:{'yes' if has_leak_scan else 'no'}, public_hits:{len(leak_hits)}",
        "leak_scan.py + 0 public leaks",
        leak_pts,
        2.0,
        f"Hits: {', '.join(leak_hits[:5])}" if leak_hits else "0 Windows user-path hits in public files",
    )

    details = {
        "info_version": info_ver,
        "godot_versions": {"project": gd_feat, "gdextension": gd_ext, "ci": gd_ci},
        "stale_presets": [v for v in set(preset_vers) if v != info_ver],
        "addons_in_src": addon_dirs,
        "addons_listed_in_package": addons_listed,
        "has_leak_scan": has_leak_scan,
        "public_leak_hits": leak_hits[:10],
    }
    return _make_pillar("release", "Release & Build Readiness", 15.0, [m_lic, m_ver, m_tool, m_pkg, m_leak], details)


# ---------------------------------------------------------------------------
# Pillar 5: Docs, Tools & Repo Hygiene (15 pts)
# ---------------------------------------------------------------------------

def _score_hygiene_pillar(root: pathlib.Path) -> dict[str, Any]:
    # 1. STATUS.md budget (~150 lines)
    status_lines = _line_count(root / "STATUS.md")
    m_status = _make_metric(
        "status_budget",
        "STATUS.md line budget",
        status_lines,
        f"{status_lines} lines",
        "<= 160 lines",
        lerp_score(status_lines, 160, 280, 3.0),
        3.0,
    )

    # 2. Core doc conciseness
    running_lines = _line_count(root / "docs" / "RUNNING.md")
    coord_lines = _line_count(root / "COORDINATION.md")
    prog_lines = _line_count(root / "PROGRESS.md")
    docs_pts = (
        lerp_score(running_lines, 1000, 5000, 1.5)
        + lerp_score(coord_lines, 200, 4000, 1.25)
        + lerp_score(prog_lines, 1500, 4500, 1.25)
    )
    m_docs = _make_metric(
        "core_docs_conciseness",
        "Core doc conciseness",
        running_lines + coord_lines + prog_lines,
        f"RUNNING:{running_lines:,}, COORD:{coord_lines:,}, PROG:{prog_lines:,}",
        "<= 1k / 200 / 1.5k",
        docs_pts,
        4.0,
    )

    # 3. No-dates discipline & REPO-MAP directory coverage
    no_date_files = [
        "STATUS.md",
        "PROGRESS.md",
        "docs/progress/done.md",
        "docs/SESSION-LOG.md",
        "docs/tracker/roadmap.json",
        "docs/tracker/models.json",
    ]
    date_hits = 0
    date_hit_files: list[str] = []
    for rel in no_date_files:
        p = root / rel
        if p.is_file():
            n = len(re.findall(r"\b20\d\d-\d\d-\d\d\b", _read_text(p)))
            if n:
                date_hits += n
                date_hit_files.append(f"{rel}({n})")

    repomap_txt = _read_text(root / "docs" / "REPO-MAP.md")
    key_dirs = [
        "addons-src", "client/native", "docs/leads", "docs/release-notes",
        "tools/release", ".agents/plugins", "tools/tracker", "tools/models", "tools/bench", "server",
    ]
    existing_key_dirs = [d for d in key_dirs if (root / d).exists()]
    mapped_dirs = [d for d in existing_key_dirs if d in repomap_txt or d.split("/")[-1] + "/" in repomap_txt]
    map_frac = (len(mapped_dirs) / len(existing_key_dirs)) if existing_key_dirs else 1.0
    missing_dirs = [d for d in existing_key_dirs if d not in mapped_dirs]
    nd_pts = lerp_score(date_hits, 0, 5, 1.5) + 1.5 * map_frac
    m_nd = _make_metric(
        "no_dates_and_repomap",
        "No-dates rule & REPO-MAP coverage",
        date_hits,
        f"dates:{date_hits}, REPO-MAP:{len(mapped_dirs)}/{len(existing_key_dirs)}",
        "0 dates, all key dirs mapped",
        nd_pts,
        3.0,
        f"Missing dirs: {', '.join(missing_dirs)}" if missing_dirs else "all mapped",
    )

    # 4. Add-on API alignment
    loader_txt = _read_text(root / "client" / "scripts" / "addons" / "addon_loader.gd")
    m_api = re.search(r"const\s+API_LEVEL\s*:?=\s*([0-9]+(?:\.[0-9]+)?)", loader_txt)
    api_level = float(m_api.group(1)) if m_api else 0.0
    addons_md = _read_text(root / "docs" / "ADDONS.md")
    api_in_docs = m_api.group(1) in addons_md if m_api else True
    addon_mismatches: list[str] = []
    for p in _rglob_sorted(root / "addons-src", "addon.json"):
        try:
            aj = json.loads(_read_text(p))
            req_api = float(aj.get("api", 0))
            if api_level and req_api > api_level:
                addon_mismatches.append(f"{aj.get('id', p.parent.name)}({req_api}>{api_level})")
        except Exception:
            addon_mismatches.append(p.parent.name)
    api_pts = (1.0 if not addon_mismatches else 0.0) + (1.0 if api_in_docs else 0.0)
    m_api_align = _make_metric(
        "addon_api_alignment",
        "Add-on API & docs alignment",
        api_level,
        f"API {api_level}, docs:{'ok' if api_in_docs else 'stale'}, bad:{len(addon_mismatches)}",
        "all <= API_LEVEL & documented",
        api_pts,
        2.0,
    )

    # 5. Tools sprawl & launcher dedup
    top_tools = sorted(p.name for p in (root / "tools").glob("*.py")) if (root / "tools").is_dir() else []
    has_scratch = (root / "tools" / "scratch_server.py").is_file()
    delete_candidates = [
        "tools/split_progress.py",
        "tools/belt_switch_cost.py",
        "tools/models/fue5_survey.py",
        "tools/models/fue5_anim_survey.py",
        "tools/tracker/export_meshes.py",
        "tools/tracker/export_shots.py",
    ]
    removed_candidates = sum(1 for rel in delete_candidates if not (root / rel).exists())
    tools_pts = (
        lerp_score(len(top_tools), 25, 70, 1.5)
        + (0.75 if has_scratch else 0.0)
        + 0.75 * (removed_candidates / len(delete_candidates))
    )
    m_tools = _make_metric(
        "tools_and_launchers",
        "Tools sprawl & launcher dedup",
        len(top_tools),
        f"{len(top_tools)} top tools/*.py, scratch_server:{'yes' if has_scratch else 'no'}, del:{removed_candidates}/{len(delete_candidates)}",
        "<= 25 tools/*.py, scratch_server, 6/6 pruned",
        tools_pts,
        3.0,
    )

    details = {
        "status_lines": status_lines,
        "running_lines": running_lines,
        "coordination_lines": coord_lines,
        "progress_lines": prog_lines,
        "date_hit_files": date_hit_files,
        "repomap_missing_dirs": missing_dirs,
        "top_level_tools_py": len(top_tools),
        "remaining_delete_candidates": [rel for rel in delete_candidates if (root / rel).exists()],
    }
    return _make_pillar("hygiene", "Docs, Tools & Repo Hygiene", 15.0, [m_status, m_docs, m_nd, m_api_align, m_tools], details)


# ---------------------------------------------------------------------------
# Local Workspace & Runtime Telemetry (kept separate from deterministic score)
# ---------------------------------------------------------------------------

def collect_local_telemetry(git_repo: pathlib.Path, art_dir: pathlib.Path | None) -> dict[str, Any]:
    worktrees = 0
    branches = 0
    merged_branches = 0
    try:
        wt_out = _run_git(["worktree", "list", "--porcelain"], git_repo).stdout
        worktrees = sum(1 for l in wt_out.splitlines() if l.startswith("worktree "))
        br_out = _run_git(["branch", "--format=%(refname:short)"], git_repo).stdout.splitlines()
        branches = len([b for b in br_out if b.strip()])
        mg_out = _run_git(["branch", "--merged", "HEAD", "--format=%(refname:short)"], git_repo).stdout.splitlines()
        merged_branches = max(0, len([b for b in mg_out if b.strip()]) - 1)
    except (OSError, subprocess.CalledProcessError):
        pass

    alt_runs = 0
    log_stats: dict[str, Any] = {"entries": 0}
    if art_dir is not None:
        runs_dir = art_dir / "alt" / "runs"
        if runs_dir.is_dir():
            alt_runs = sum(1 for p in runs_dir.iterdir() if p.is_dir())
        log_path = art_dir / "check-log.jsonl"
        if log_path.is_file():
            rows: list[dict[str, Any]] = []
            for line in _read_text(log_path).splitlines():
                if not line.strip():
                    continue
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
            recent = rows[-1000:]
            n_recent = len(recent)
            fails = sum(1 for r in recent if r.get("result") == "failed")
            flaky = sum(1 for r in recent if r.get("result") == "flaky")
            ui_rows = [r for r in rows if r.get("check") == "ui_test"]
            ui_secs = [float(r.get("seconds", 0.0)) for r in ui_rows if r.get("seconds") is not None]
            by_check: dict[str, list[int]] = {}
            for r in recent:
                name = str(r.get("check", "?"))
                rec = by_check.setdefault(name, [0, 0, 0])  # total, failed, flaky
                rec[0] += 1
                if r.get("result") == "failed":
                    rec[1] += 1
                elif r.get("result") == "flaky":
                    rec[2] += 1
            trouble = sorted(
                [(f + fl, f, fl, tot, name) for name, (tot, f, fl) in by_check.items() if (f + fl) > 0],
                reverse=True,
            )
            log_stats = {
                "entries": len(rows),
                "recent_window": n_recent,
                "recent_fail_pct": round((fails / n_recent * 100.0), 1) if n_recent else 0.0,
                "recent_flaky_pct": round((flaky / n_recent * 100.0), 1) if n_recent else 0.0,
                "ui_test_runs": len(ui_rows),
                "ui_test_fails": sum(1 for r in ui_rows if r.get("result") == "failed"),
                "ui_test_median_s": round(statistics.median(ui_secs), 1) if ui_secs else 0.0,
                "ui_test_max_s": round(max(ui_secs), 1) if ui_secs else 0.0,
                "top_trouble": [
                    {"check": name, "runs": tot, "failed": f, "flaky": fl}
                    for _, f, fl, tot, name in trouble[:5]
                ],
            }

    fail_flaky_pct = float(log_stats.get("recent_fail_pct", 0.0)) + float(log_stats.get("recent_flaky_pct", 0.0))
    ui_max = float(log_stats.get("ui_test_max_s", 0.0))
    ops_score = (
        lerp_score(worktrees, 5, 100, 25.0)
        + lerp_score(branches, 15, 150, 25.0)
        + lerp_score(fail_flaky_pct, 2.0, 25.0, 25.0)
        + lerp_score(ui_max, 120.0, 300.0, 25.0)
    )
    ops_round = round(ops_score, 1)
    ops_grade, _ = grade_for(ops_round)
    return {
        "local_ops_score": ops_round,
        "local_ops_grade": ops_grade,
        "git_worktrees": worktrees,
        "git_branches": branches,
        "git_branches_merged": merged_branches,
        "alt_runs_count": alt_runs,
        "check_log": log_stats,
    }


# ---------------------------------------------------------------------------
# Public Scoring Driver + Git Archive Support
# ---------------------------------------------------------------------------

def analyze_tree(
    root: pathlib.Path,
    *,
    git_repo: pathlib.Path | None = None,
    rev: str | None = None,
    include_local: bool = False,
    label: str = "",
) -> dict[str, Any]:
    """Compute the deterministic 100-point code-health report for `root`."""
    main_art = art_src_dir(git_repo or root)
    pillars = [
        _score_tests_pillar(root),
        _score_architecture_pillar(root),
        _score_parity_protocol_pillar(root, git_repo, rev),
        _score_release_pillar(root, git_repo, rev, main_art),
        _score_hygiene_pillar(root),
    ]
    total = round(sum(p["score"] for p in pillars), 1)
    grade, grade_label = grade_for(total)

    commit = "unknown"
    branch = "unknown"
    dirty = False
    if git_repo is not None:
        target = rev or "HEAD"
        try:
            commit = _run_git(["rev-parse", "--short=8", target], git_repo).stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            pass
        if rev is None:
            try:
                branch = _run_git(["rev-parse", "--abbrev-ref", "HEAD"], git_repo).stdout.strip()
                dirty = bool(_run_git(["status", "--porcelain"], git_repo).stdout.strip())
            except (OSError, subprocess.CalledProcessError):
                pass
        else:
            branch = rev

    report: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "rubric_version": RUBRIC_VERSION,
        "timestamp_utc": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "label": label or (f"rev:{commit}" if rev else branch),
        "commit": commit,
        "branch": branch,
        "dirty": dirty,
        "total": total,
        "grade": grade,
        "grade_label": grade_label,
        "pillars": pillars,
    }
    if include_local and git_repo is not None and rev is None:
        report["local_telemetry"] = collect_local_telemetry(git_repo, main_art)
    return report


def analyze_revision(git_repo: pathlib.Path, rev: str, label: str = "") -> dict[str, Any]:
    """Extract non-asset files for `rev` into a temp directory and score it."""
    top_entries = _run_git(["ls-tree", "--name-only", rev], git_repo).stdout.splitlines()
    archive_paths: list[str] = []
    for entry in top_entries:
        if entry == "client":
            client_entries = _run_git(["ls-tree", "--name-only", f"{rev}:client"], git_repo).stdout.splitlines()
            for ce in client_entries:
                if ce != "assets":
                    archive_paths.append(f"client/{ce}")
        elif entry != "art-src":
            archive_paths.append(entry)

    proc = subprocess.run(
        ["git", "archive", "--format=tar", rev, *archive_paths],
        cwd=git_repo,
        capture_output=True,
        check=True,
    )
    with tempfile.TemporaryDirectory(prefix="zenith-health-rev-") as tmp:
        tmp_path = pathlib.Path(tmp)
        with tarfile.open(fileobj=io.BytesIO(proc.stdout), mode="r:*") as tf:
            if sys.version_info >= (3, 12):
                tf.extractall(tmp_path, filter="data")
            else:
                tf.extractall(tmp_path)
        return analyze_tree(tmp_path, git_repo=git_repo, rev=rev, include_local=False, label=label)


# ---------------------------------------------------------------------------
# History & Reporting
# ---------------------------------------------------------------------------

def default_history_path(repo: pathlib.Path = REPO) -> pathlib.Path:
    art = art_src_dir(repo)
    if art is not None:
        return art / "tracker" / "code_health_history.json"
    return repo / "code_health_history.json"


def default_html_path(repo: pathlib.Path = REPO) -> pathlib.Path:
    art = art_src_dir(repo)
    if art is not None:
        return art / "tracker" / "code_health.html"
    return repo / "code_health.html"


def load_history(path: pathlib.Path) -> list[dict[str, Any]]:
    if not path.is_file():
        return []
    try:
        data = json.loads(_read_text(path))
        if isinstance(data, dict) and isinstance(data.get("snapshots"), list):
            return list(data["snapshots"])
        if isinstance(data, list):
            return list(data)
    except Exception:
        pass
    return []


def record_snapshot(path: pathlib.Path, report: dict[str, Any], append: bool = False) -> list[dict[str, Any]]:
    snapshots = load_history(path)
    if not append and not report.get("dirty", False):
        replaced = False
        for i, snap in enumerate(snapshots):
            if snap.get("commit") == report.get("commit") and not snap.get("dirty", False):
                snapshots[i] = report
                replaced = True
                break
        if not replaced:
            snapshots.append(report)
    else:
        snapshots.append(report)

    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "schema_version": SCHEMA_VERSION,
        "rubric_version": RUBRIC_VERSION,
        "snapshots": snapshots,
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return snapshots


def _ascii_bar(ratio: float, width: int = 20) -> str:
    filled = int(round(max(0.0, min(1.0, ratio)) * width))
    return "#" * filled + "-" * (width - filled)


def print_terminal_report(report: dict[str, Any], baseline: dict[str, Any] | None = None) -> None:
    delta_str = ""
    if baseline is not None:
        d = round(report["total"] - baseline["total"], 1)
        sign = "+" if d > 0 else ""
        delta_str = f"  ({sign}{d:.1f} vs {baseline.get('commit', 'prev')})"
    dirty_tag = " [dirty]" if report.get("dirty") else ""
    print(f"\n=== Zenith Code Health Scorecard (Rubric v{report['rubric_version']}) ===")
    print(f"Target: {report['label']} ({report['commit']}{dirty_tag})  |  Score: {report['total']:.1f} / 100  [Grade {report['grade']} - {report['grade_label']}]{delta_str}\n")

    base_pillars = {p["id"]: p for p in baseline.get("pillars", [])} if baseline else {}
    for p in report["pillars"]:
        ratio = p["score"] / p["weight"] if p["weight"] else 1.0
        p_delta = ""
        if p["id"] in base_pillars:
            pd = round(p["score"] - base_pillars[p["id"]]["score"], 1)
            p_delta = f" ({'+' if pd > 0 else ''}{pd:.1f})" if pd != 0 else " (=)"
        print(f"  {p['name']:<34} [{_ascii_bar(ratio)}] {p['score']:5.1f} / {p['weight']:4.1f} ({p['pct']:4.0f}%){p_delta}")
        base_metrics = {m["id"]: m for m in base_pillars[p["id"]]["metrics"]} if p["id"] in base_pillars else {}
        for m in p["metrics"]:
            md_str = ""
            if m["id"] in base_metrics:
                md = round(m["score"] - base_metrics[m["id"]]["score"], 2)
                if abs(md) >= 0.05:
                    md_str = f" [{'+' if md > 0 else ''}{md:.1f}]"
            tag = "OK " if m["status"] == "green" else "MID" if m["status"] == "amber" else "LOW"
            print(f"    - [{tag}] {m['label']:<32} {m['score']:4.1f}/{m['max_score']:4.1f}  | {m['display']}{md_str}")

    lt = report.get("local_telemetry")
    if lt:
        cl = lt.get("check_log", {})
        print("\n--- Local Workspace & CI History (separate from deterministic score) ---")
        print(
            f"  Ops Health: {lt['local_ops_score']:.1f}/100 (Grade {lt['local_ops_grade']})  |  "
            f"Worktrees: {lt['git_worktrees']}  |  Branches: {lt['git_branches']} ({lt['git_branches_merged']} merged)  |  "
            f"Alt runs: {lt['alt_runs_count']}"
        )
        if cl.get("entries"):
            print(
                f"  check-log ({cl['entries']:,} runs, last {cl['recent_window']}): "
                f"fail {cl['recent_fail_pct']}%, flaky {cl['recent_flaky_pct']}%  |  "
                f"ui_test full: med {cl['ui_test_median_s']}s, max {cl['ui_test_max_s']}s / 300s watchdog"
            )
    print()


def render_html_dashboard(report: dict[str, Any], snapshots: list[dict[str, Any]], out_path: pathlib.Path) -> None:
    """Write a self-contained, zero-CDN HTML trend dashboard to `out_path`."""
    payload = {
        "current": report,
        "snapshots": snapshots if snapshots else [report],
    }
    data_json = json.dumps(payload).replace("</", "<\\/")
    title = f"Zenith Code Health — {report['total']:.1f}/100 ({report['grade']})"
    html_text = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>{html.escape(title)}</title>
<style>
  :root {{
    --bg: #0f141b; --card: #161d27; --border: #273244; --fg: #e6edf3;
    --muted: #8b9bb0; --accent: #4aa3ff; --ok: #2ecc71; --warn: #f1c40f; --bad: #e74c3c;
  }}
  body.light {{
    --bg: #f5f7fa; --card: #ffffff; --border: #dce3ec; --fg: #1b2430;
    --muted: #5a6978; --accent: #0969da; --ok: #1a7f37; --warn: #9a6700; --bad: #cf222e;
  }}
  * {{ box-sizing: border-box; }}
  body {{ margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    background: var(--bg); color: var(--fg); line-height: 1.45; }}
  .wrap {{ max-width: 1180px; margin: 0 auto; padding: 24px; display: grid; gap: 18px; }}
  .card {{ background: var(--card); border: 1px solid var(--border); border-radius: 12px; padding: 18px; }}
  .row {{ display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 12px; }}
  .grid-2 {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(340px, 1fr)); gap: 16px; }}
  .grid-5 {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 12px; }}
  h1, h2, h3 {{ margin: 0 0 8px 0; font-weight: 600; }}
  .muted {{ color: var(--muted); font-size: 13px; }}
  .mono {{ font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }}
  .pill {{ display: inline-block; padding: 2px 9px; border-radius: 999px; font-size: 12px; font-weight: 600;
    border: 1px solid var(--border); }}
  .green {{ color: var(--ok); }} .amber {{ color: var(--warn); }} .red {{ color: var(--bad); }}
  .bar-bg {{ height: 8px; border-radius: 99px; background: var(--border); overflow: hidden; margin-top: 8px; }}
  .bar-fill {{ height: 100%; border-radius: 99px; transition: width 0.3s ease; }}
  table {{ width: 100%; border-collapse: collapse; font-size: 13px; }}
  th, td {{ text-align: left; padding: 7px 8px; border-bottom: 1px solid var(--border); }}
  th {{ color: var(--muted); font-weight: 500; }}
  button {{ background: transparent; color: var(--fg); border: 1px solid var(--border);
    padding: 6px 12px; border-radius: 8px; cursor: pointer; font-size: 13px; }}
  button:hover {{ border-color: var(--accent); }}
  details summary {{ cursor: pointer; font-weight: 600; padding: 4px 0; }}
  .sim-item {{ display: flex; align-items: flex-start; gap: 8px; padding: 5px 0; font-size: 13px; }}
</style>
</head>
<body>
<div class="wrap">
  <div class="card row">
    <div class="row" style="gap: 20px;">
      <svg width="108" height="108" viewBox="0 0 120 120" id="ring-svg"></svg>
      <div>
        <h1 style="font-size: 22px;">Zenith Code Health Scorecard</h1>
        <div class="muted mono" id="meta-line"></div>
        <div style="margin-top: 8px; display: flex; gap: 8px; flex-wrap: wrap;" id="badge-row"></div>
      </div>
    </div>
    <div>
      <button onclick="document.body.classList.toggle('light')">Toggle Light / Dark</button>
    </div>
  </div>

  <div class="grid-5" id="pillar-cards"></div>

  <div class="grid-2">
    <div class="card">
      <h2 style="font-size: 16px;">Score Trend Over Snapshots</h2>
      <div class="muted">Deterministic 100-pt commit score across recorded runs</div>
      <div id="trend-wrap" style="margin-top: 12px;"></div>
    </div>
    <div class="card" id="local-card">
      <h2 style="font-size: 16px;">Local Workspace & CI Reliability</h2>
      <div class="muted">Tracked separately from deterministic commit score</div>
      <div id="local-body" style="margin-top: 10px;"></div>
    </div>
  </div>

  <div class="card">
    <h2 style="font-size: 16px;">Pillar & Sub-Metric Drilldown</h2>
    <div id="drilldown" style="display: grid; gap: 10px; margin-top: 10px;"></div>
  </div>

  <div class="grid-2">
    <div class="card">
      <h2 style="font-size: 16px;">Top Shipped Monoliths & Lua Locals</h2>
      <div id="offenders"></div>
    </div>
    <div class="card">
      <h2 style="font-size: 16px;">Restructure Impact Simulator</h2>
      <div class="muted">Estimated deterministic score boost from Claude R&D steps</div>
      <div id="sim-list" style="margin-top: 10px;"></div>
      <div style="margin-top: 12px; font-weight: 600;" id="sim-total"></div>
    </div>
  </div>
</div>
<script>
const DATA = {data_json};
const cur = DATA.current;
const snaps = DATA.snapshots;

function colorFor(status) {{
  return status === 'green' ? 'var(--ok)' : status === 'amber' ? 'var(--warn)' : 'var(--bad)';
}}

function renderRing() {{
  const r = 46, c = 2 * Math.PI * r, pct = Math.max(0, Math.min(100, cur.total)) / 100;
  const col = cur.total >= 80 ? 'var(--ok)' : cur.total >= 65 ? 'var(--warn)' : 'var(--bad)';
  document.getElementById('ring-svg').innerHTML = `
    <circle cx="60" cy="60" r="${{r}}" fill="none" stroke="var(--border)" stroke-width="10" />
    <circle cx="60" cy="60" r="${{r}}" fill="none" stroke="${{col}}" stroke-width="10"
      stroke-dasharray="${{(c * pct).toFixed(1)}} ${{c.toFixed(1)}}" stroke-linecap="round"
      transform="rotate(-90 60 60)" />
    <text x="60" y="57" text-anchor="middle" fill="var(--fg)" font-size="22" font-weight="700">${{cur.total.toFixed(1)}}</text>
    <text x="60" y="75" text-anchor="middle" fill="var(--muted)" font-size="11">GRADE ${{cur.grade}}</text>
  `;
  document.getElementById('meta-line').textContent =
    `${{cur.label}} | commit ${{cur.commit}}${{cur.dirty ? ' (dirty)' : ''}} | rubric v${{cur.rubric_version}} | ${{cur.timestamp_utc}}`;
  const prev = snaps.length >= 2 ? snaps[snaps.length - 2] : null;
  let deltaHtml = '';
  if (prev && prev.commit !== cur.commit) {{
    const d = cur.total - prev.total;
    const cls = d >= 0 ? 'green' : 'red';
    deltaHtml = `<span class="pill ${{cls}}">${{d >= 0 ? '+' : ''}}${{d.toFixed(1)}} vs ${{prev.commit}}</span>`;
  }}
  document.getElementById('badge-row').innerHTML =
    `<span class="pill">${{cur.grade_label}}</span>` + deltaHtml +
    `<span class="pill">${{snaps.length}} snapshot(s)</span>`;
}}

function renderPillars() {{
  document.getElementById('pillar-cards').innerHTML = cur.pillars.map(p => `
    <div class="card" style="padding: 14px;">
      <div class="muted">${{p.name}}</div>
      <div class="row" style="margin-top: 6px;">
        <strong style="font-size: 20px;">${{p.score.toFixed(1)}}<span class="muted"> / ${{p.weight}}</span></strong>
        <span class="pill ${{p.status}}">${{p.pct.toFixed(0)}}%</span>
      </div>
      <div class="bar-bg"><div class="bar-fill" style="width:${{p.pct}}%; background:${{colorFor(p.status)}}"></div></div>
    </div>
  `).join('');

  document.getElementById('drilldown').innerHTML = cur.pillars.map((p, idx) => `
    <details ${{idx === 0 ? 'open' : ''}}>
      <summary>${{p.name}} — ${{p.score.toFixed(1)}} / ${{p.weight}} (${{p.pct.toFixed(0)}}%)</summary>
      <table>
        <thead><tr><th>Metric</th><th>Measured</th><th>Target</th><th>Score</th></tr></thead>
        <tbody>
          ${{p.metrics.map(m => `
            <tr>
              <td><strong>${{m.label}}</strong><div class="muted">${{m.detail || ''}}</div></td>
              <td class="mono">${{m.display}}</td>
              <td class="muted">${{m.target}}</td>
              <td class="mono ${{m.status}}">${{m.score.toFixed(1)}} / ${{m.max_score.toFixed(1)}}</td>
            </tr>
          `).join('')}}
        </tbody>
      </table>
    </details>
  `).join('');
}}

function renderTrend() {{
  const el = document.getElementById('trend-wrap');
  const W = 500, H = 180, padL = 34, padR = 16, padT = 16, padB = 34;
  const pts = snaps.map((s, i) => {{
    const x = snaps.length === 1 ? W / 2 : padL + (i / (snaps.length - 1)) * (W - padL - padR);
    const y = padT + (1 - s.total / 100) * (H - padT - padB);
    return {{ x, y, s }};
  }});
  const line = pts.map(p => `${{p.x.toFixed(1)}},${{p.y.toFixed(1)}}`).join(' ');
  const grid = [0, 25, 50, 75, 100].map(v => {{
    const y = padT + (1 - v / 100) * (H - padT - padB);
    return `<line x1="${{padL}}" y1="${{y}}" x2="${{W-padR}}" y2="${{y}}" stroke="var(--border)" stroke-dasharray="3 3" />
            <text x="4" y="${{y+4}}" fill="var(--muted)" font-size="10">${{v}}</text>`;
  }}).join('');
  const dots = pts.map(p => `
    <circle cx="${{p.x}}" cy="${{p.y}}" r="5" fill="var(--accent)" />
    <text x="${{p.x}}" y="${{p.y - 9}}" text-anchor="middle" fill="var(--fg)" font-size="11" font-weight="600">${{p.s.total.toFixed(1)}}</text>
    <text x="${{p.x}}" y="${{H - 10}}" text-anchor="middle" fill="var(--muted)" font-size="10">${{p.s.commit}}</text>
  `).join('');
  el.innerHTML = `<svg viewBox="0 0 ${{W}} ${{H}}" style="width:100%; height:auto;">${{grid}}
    ${{pts.length > 1 ? `<polyline fill="none" stroke="var(--accent)" stroke-width="2.5" points="${{line}}" />` : ''}}
    ${{dots}}</svg>`;
}}

function renderLocalAndOffenders() {{
  const lt = cur.local_telemetry;
  const lb = document.getElementById('local-body');
  if (!lt) {{
    lb.innerHTML = '<div class="muted">Not collected (historical --rev or --no-local run).</div>';
  }} else {{
    const cl = lt.check_log || {{}};
    lb.innerHTML = `
      <table>
        <tr><td>Local Ops Score</td><td class="mono"><strong>${{lt.local_ops_score.toFixed(1)}} / 100</strong> (Grade ${{lt.local_ops_grade}})</td></tr>
        <tr><td>Git Worktrees / Branches</td><td class="mono">${{lt.git_worktrees}} worktrees | ${{lt.git_branches}} branches (${{lt.git_branches_merged}} merged)</td></tr>
        <tr><td>Recent check-log (last ${{cl.recent_window || 0}})</td><td class="mono">fail ${{cl.recent_fail_pct || 0}}% | flaky ${{cl.recent_flaky_pct || 0}}%</td></tr>
        <tr><td>ui_test full vs 300s watchdog</td><td class="mono">med ${{cl.ui_test_median_s || 0}}s | max ${{cl.ui_test_max_s || 0}}s / 300s</td></tr>
      </table>`;
  }}

  const arch = cur.pillars.find(p => p.id === 'architecture').details;
  const tests = cur.pillars.find(p => p.id === 'tests').details;
  const monos = (arch.top_monoliths || []).slice(0, 6).map(([n, f]) => `<tr><td class="mono">${{f}}</td><td class="mono">${{n.toLocaleString()}}</td></tr>`).join('');
  const luas = (arch.top_lua_locals || []).slice(0, 4).map(([n, f]) => `<span class="pill mono">${{f.split('/').pop()}}: ${{n}}/200</span>`).join(' ');
  document.getElementById('offenders').innerHTML = `
    <div style="margin: 8px 0;">${{luas}}</div>
    <table><thead><tr><th>Shipped Monolith</th><th>LOC</th></tr></thead><tbody>${{monos}}</tbody></table>
    <div class="muted" style="margin-top:8px;">Unwired GD tests: ${{tests.unwired_godot.length}}, map-only GD: ${{tests.map_only_godot.length}}, unwired PY: ${{tests.unwired_python.length}}</div>
  `;
}}

function renderSim() {{
  const items = [
    {{ id: 'wire', pts: 10.2, label: 'Wire unwired GD/PY tests + wire_decode/C++ rules + orphan/Py3.9/pass-count fixes' }},
    {{ id: 'lua', pts: 5.0, label: 'Split belt_sim.lua writers & options below 140 locals (Code Step 1)' }},
    {{ id: 'rel', pts: 9.1, label: 'Add leak_scan.py, pin add-ons + BUILD.json, align 0.3.0 presets/Godot/reqs' }},
    {{ id: 'nat', pts: 4.0, label: 'Fail belt_sim_native_test on Windows & build Linux .so in CI (Code Steps 2 & 13)' }},
    {{ id: 'split', pts: 8.2, label: 'Split ui_test, test_bridge, world.gd & belt_items.gd monoliths (Post-0.3.0)' }},
    {{ id: 'sw', pts: 9.0, label: 'Central switch registry + shared helpers + drop dead 2.0/bi paths + proto cross-test' }},
    {{ id: 'hyg', pts: 9.0, label: 'Trim STATUS/RUNNING/COORD/PROGRESS, update REPO-MAP, prune tools + scratch_server' }},
  ];
  const el = document.getElementById('sim-list');
  el.innerHTML = items.map(it => `
    <label class="sim-item">
      <input type="checkbox" data-pts="${{it.pts}}" onchange="updateSim()" />
      <span>${{it.label}} <strong class="green">(+${{it.pts.toFixed(1)}} pts)</strong></span>
    </label>
  `).join('');
  window.updateSim = () => {{
    let add = 0;
    el.querySelectorAll('input:checked').forEach(cb => add += parseFloat(cb.dataset.pts));
    const proj = Math.min(100, cur.total + add);
    const g = proj >= 90 ? 'A' : proj >= 80 ? 'B' : proj >= 65 ? 'C' : proj >= 45 ? 'D' : 'F';
    document.getElementById('sim-total').textContent = `Projected Score: ${{proj.toFixed(1)}} / 100 (Grade ${{g}})`;
  }};
  updateSim();
}}

renderRing();
renderPillars();
renderTrend();
renderLocalAndOffenders();
renderSim();
</script>
</body>
</html>
"""
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(html_text, encoding="utf-8")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rev", help="score a git revision instead of the current working tree")
    ap.add_argument("--compare", metavar="REV", help="compare current working tree against a git revision")
    ap.add_argument("--record", action="store_true", help="save snapshot to the history JSON")
    ap.add_argument("--append", action="store_true", help="always append snapshot instead of updating same clean commit")
    ap.add_argument("--label", default="", help="label for recorded snapshot")
    ap.add_argument("--history", type=pathlib.Path, help="history JSON path (default: art-src/tracker/code_health_history.json)")
    ap.add_argument("--html", nargs="?", const="__DEFAULT__", help="write standalone HTML dashboard")
    ap.add_argument("--json", action="store_true", help="print full JSON report to stdout")
    ap.add_argument("--no-local", action="store_true", help="skip local git worktree / check-log telemetry")
    ap.add_argument("--min-score", type=float, help="exit 1 if deterministic score is below this threshold")
    args = ap.parse_args(argv)

    hist_path = args.history or default_history_path(REPO)
    baseline: dict[str, Any] | None = None

    if args.rev:
        report = analyze_revision(REPO, args.rev, label=args.label)
    else:
        report = analyze_tree(REPO, git_repo=REPO, rev=None, include_local=not args.no_local, label=args.label)

    if args.compare:
        baseline = analyze_revision(REPO, args.compare, label=f"base:{args.compare}")
    else:
        hist = load_history(hist_path)
        for snap in reversed(hist):
            if snap.get("commit") != report.get("commit") or report.get("dirty"):
                baseline = snap
                break

    snapshots = load_history(hist_path)
    if args.record:
        snapshots = record_snapshot(hist_path, report, append=args.append)

    if args.html:
        out_html = default_html_path(REPO) if args.html == "__DEFAULT__" else pathlib.Path(args.html)
        render_html_dashboard(report, snapshots, out_html)
        if not args.json:
            print(f"wrote dashboard: {out_html}")

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print_terminal_report(report, baseline)

    if args.min_score is not None and report["total"] < args.min_score:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
