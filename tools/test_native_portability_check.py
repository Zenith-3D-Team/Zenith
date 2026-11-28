#!/usr/bin/env python3
"""tools/native_portability_check.py: each pattern CI's GCC build trips on is found, the portable forms
pass, and the repo's own native sources are clean.

    python tools/test_native_portability_check.py
"""
from __future__ import annotations

import pathlib
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import native_portability_check as npc  # noqa: E402

failures: list[str] = []


def verify(cond: bool, what: str) -> None:
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        failures.append(what)


def lint(src: str, name: str = "a.cpp", extra: dict[str, str] | None = None) -> list[str]:
    with tempfile.TemporaryDirectory() as d:
        p = pathlib.Path(d) / name
        p.write_text(src, encoding="utf-8")
        for n, t in (extra or {}).items():
            (pathlib.Path(d) / n).write_text(t, encoding="utf-8")
        return npc.check_file(p)


def has(found: list[str], needle: str) -> bool:
    return any(needle in f for f in found)


def main() -> int:
    # 0.3.0's CI failure: std::cosf / std::sinf.
    f = lint("#include <cmath>\nfloat a(float t) { return std::cosf(t) + std::sinf(t) + std::sqrtl(1.0L); }\n")
    verify(has(f, "std::cosf") and has(f, "std::sinf") and has(f, "std::sqrtl"), "std::cosf/sinf/sqrtl found")
    f = lint("#include <cmath>\nfloat a(float t) { return std::cos(t) + cosf(t) + std::floor(t); }\n")
    verify(not f, f"std::cos(float) and plain cosf pass ({f})")

    # MSVC-only keywords, guarded and not.
    f = lint("__forceinline int a() { return 1; }\nint b() { void *p = _alloca(4); return 0; }\n")
    verify(has(f, "__forceinline") and has(f, "_alloca"), "__forceinline / _alloca found")
    f = lint("#ifdef _MSC_VER\n#define FI __forceinline\n#include <intrin.h>\nint c() { return __popcnt(3); }\n"
             "#else\nint c() { return __builtin_popcount(3); }\n#endif\n")
    verify(not f, f"MSVC-only code inside #ifdef _MSC_VER passes ({f})")
    f = lint("#ifndef _WIN32\nint c() { return __popcnt(3); }\n#endif\n")
    verify(has(f, "__popcnt"), "MSVC-only code inside #ifndef _WIN32 found")
    f = lint("#include <windows.h>\n")
    verify(has(f, "windows.h"), "unguarded <windows.h> found")
    f = lint("#if defined(_WIN32)\n#include <winsock2.h>\n#else\n#include <sys/socket.h>\n#endif\n")
    verify(not f, f"guarded <winsock2.h> passes ({f})")

    # LLP64 vs LP64.
    f = lint("long a = 0;\nunsigned long b = 1;\n")
    verify(sum("`long`" in x for x in f) == 2, "`long` / `unsigned long` found")
    f = lint("#include <cstdint>\nlong long a = 0;\nlong double b = 1;\nint64_t c = 2;\n// a long comment\n"
             "const char *s = \"long\";\n")
    verify(not f, f"long long / long double / comments / strings pass ({f})")
    f = lint('#include <cstdio>\nvoid p(long long x) { std::printf("%ld %I64d %lld %zu", 1, 2, x, sizeof(x)); }\n')
    verify(has(f, "%ld") and has(f, "%I64d") and not has(f, "`%lld`"), "%ld / %I64d found, %lld passes")

    # Exceptions (godot-cpp: -fno-exceptions on GCC).
    f = lint("void a() { try { } catch (...) { } }\nvoid b() { throw 1; }\n")
    verify(has(f, "try") and has(f, "throw"), "try / throw found")

    # Headers MSVC brings in by itself.
    f = lint("#include <vector>\nvoid a(std::vector<int> &v) { std::sort(v.begin(), v.end()); "
             "std::memcpy(v.data(), v.data(), 0); auto m = std::numeric_limits<int>::max(); uint32_t u = 0; }\n")
    verify(has(f, "std::sort without #include <algorithm>"), "std::sort without <algorithm> found")
    verify(has(f, "std::memcpy without #include <cstring>"), "std::memcpy without <cstring> found")
    verify(has(f, "std::numeric_limits without #include <limits>"), "numeric_limits without <limits> found")
    verify(has(f, "uint32_t without #include <cstdint>"), "uint32_t without <cstdint> found")
    f = lint('#include "mine.h"\n#include <algorithm>\nvoid a(std::vector<int> &v) { std::sort(v.begin(), v.end()); '
             "std::swap(v[0], v[1]); uint32_t u = 0; }\n",
             extra={"mine.h": "#pragma once\n#include <cstdint>\n#include <vector>\n"})
    verify(not f, f"headers from our own header count ({f})")
    f = lint("#include <cstdint>\nstruct S { int64_t a; };\nint b(S s) { return s.int64_t_x; }\n")
    verify(not f, f"members and qualified names that look like C names pass ({f})")

    # #include case and slashes.
    f = lint('#include "Mine.h"\n#include "sub\\\\x.h"\n', extra={"mine.h": "#pragma once\n"})
    verify(has(f, "case differs") or has(f, "no such file"), "#include with the wrong case found")
    verify(has(f, "use /"), "#include with a backslash found")

    # The repo's own native sources (what CI builds) are clean.
    found = []
    for p in npc.native_sources():
        found += npc.check_file(p)
    verify(not found, f"client/native sources clean ({len(found)} finding(s): {found[:5]})")

    print(f"\n{len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
