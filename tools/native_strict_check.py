#!/usr/bin/env python3
"""Compile belt_sim's C++ the strict way on Windows, as a stand-in for CI's GCC build (Windows only, manual).

    python tools/native_strict_check.py --godot-cpp <godot-cpp folder> [--logs <dir>]

MSVC by default accepts code GCC and Clang reject. Without a Linux compiler on the PC, two strict passes
come close, with nothing to download (both ship with Visual Studio's C++ workload):

1. cl /Zs /permissive- /Zc:__cplusplus /Zc:preprocessor: MSVC's standard-conforming mode (two-phase name
   lookup, no temporaries bound to non-const references, no extra qualification, ...).
2. clang-tidy (Visual Studio's LLVM tools, a full Clang front end) with -fno-ms-compatibility
   -fno-delayed-template-parsing and every Microsoft-extension diagnostic an error.

Neither sees libstdc++'s headers or Linux's 64-bit `long`: tools/native_portability_check.py (fast suite)
covers those by pattern. Exit code 0 when both passes are clean (or skipped: tool not found).
"""
from __future__ import annotations

import argparse
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
LIB = ROOT / "client" / "native" / "belt_sim"


def _vs_root() -> pathlib.Path | None:
    vswhere = pathlib.Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")) / \
        "Microsoft Visual Studio" / "Installer" / "vswhere.exe"
    if vswhere.is_file():
        out = subprocess.run([str(vswhere), "-latest", "-products", "*", "-property", "installationPath"],
                             capture_output=True, text=True).stdout.strip()
        if out:
            return pathlib.Path(out)
    base = pathlib.Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Microsoft Visual Studio"
    for vs in sorted(base.glob("*/*"), reverse=True):
        if (vs / "VC" / "Auxiliary" / "Build" / "vcvars64.bat").is_file():
            return vs
    return None


def _run_bat(lines: list[str], log: pathlib.Path) -> int:
    with tempfile.NamedTemporaryFile("w", suffix=".bat", delete=False) as f:
        f.write("@echo off\r\n" + "\r\n".join(lines) + "\r\n")
        bat = f.name
    try:
        with log.open("w", encoding="utf-8", errors="replace") as out:
            return subprocess.run(["cmd", "/c", bat], stdout=out, stderr=subprocess.STDOUT).returncode
    finally:
        os.unlink(bat)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--godot-cpp", required=True, help="godot-cpp folder (built or not: only its headers)")
    ap.add_argument("--logs", default=str(ROOT / "art-src" / "check-logs"), help="where the two logs go")
    a = ap.parse_args()
    if os.name != "nt":
        print("native_strict_check: Windows only (skipped)")
        return 0
    vs = _vs_root()
    if vs is None:
        print("native_strict_check: no Visual Studio with C++ found (skipped)")
        return 0
    g = pathlib.Path(a.godot_cpp).resolve()
    if not (g / "gen" / "include").is_dir():
        print(f"native_strict_check: {g} has no gen/include (build godot-cpp once first)")
        return 2
    logs = pathlib.Path(a.logs)
    logs.mkdir(parents=True, exist_ok=True)
    vcvars = vs / "VC" / "Auxiliary" / "Build" / "vcvars64.bat"
    inc = f'/I src /I "{g / "include"}" /I "{g / "gen" / "include"}" /I "{g / "gdextension"}"'
    cinc = f'-I src -I "{g / "include"}" -I "{g / "gen" / "include"}" -I "{g / "gdextension"}"'
    head = [f'call "{vcvars}" >nul 2>nul', f'cd /d "{LIB}"']
    sources = sorted(p.name for p in (LIB / "src").glob("*.cpp"))
    bad = 0

    msvc_log = logs / "native_strict_msvc.log"
    _run_bat(head + ["cl /nologo /Zs /permissive- /Zc:__cplusplus /Zc:preprocessor /std:c++17 /W1 "
                     f"/D_HAS_EXCEPTIONS=0 /DNOMINMAX /DTYPED_METHOD_BIND {inc} src\\*.cpp"], msvc_log)
    errs = [ln for ln in msvc_log.read_text(encoding="utf-8", errors="replace").splitlines() if ": error" in ln
            or "fatal error" in ln]
    print(f"cl /permissive-: {len(sources)} files, {len(errs)} error line(s) ({msvc_log})")
    for ln in errs[:40]:
        print("  " + ln)
    bad += bool(errs)

    tidy = vs / "VC" / "Tools" / "Llvm" / "x64" / "bin" / "clang-tidy.exe"
    if not tidy.is_file():
        print("clang-tidy: not installed with Visual Studio (C++ Clang tools), skipped")
    else:
        clang_log = logs / "native_strict_clang.log"
        flags = ("--target=x86_64-pc-windows-msvc -std=c++17 -fno-ms-compatibility -fno-delayed-template-parsing "
                 "-fno-exceptions -ferror-limit=0 -Wno-everything -Wmicrosoft -Werror=microsoft "
                 # godot-cpp casts member pointers between classes (method_bind.hpp): one representation.
                 "-Xclang -fms-memptr-rep=virtual -D_HAS_EXCEPTIONS=0 -DNOMINMAX -DTYPED_METHOD_BIND")
        lines = [f'"{tidy}" --checks=-*,bugprone-undelegated-constructor --quiet src\\{s} -- {flags} {cinc}'
                 for s in sources]
        _run_bat(head + lines, clang_log)
        errs = [ln for ln in clang_log.read_text(encoding="utf-8", errors="replace").splitlines()
                if "error:" in ln]
        print(f"clang (no MS compatibility): {len(sources)} files, {len(errs)} error line(s) ({clang_log})")
        for ln in errs[:40]:
            print("  " + ln)
        bad += bool(errs)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
