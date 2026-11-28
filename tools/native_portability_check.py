#!/usr/bin/env python3
"""Lint client/native's C++ for what MSVC accepts and GCC/Clang (CI's Linux build) reject.

    python tools/native_portability_check.py            # the C++ CI builds on Linux (belt_sim/src)
    python tools/native_portability_check.py FILE...    # just these

There is no Linux compiler on the owner's PC, so a construct only MSVC takes stays hidden until CI's `ui`
job builds the .so (0.3.0: GCC 13 stopped on `std::cosf`). This catches the known ones by pattern:

- `std::cosf` / `std::sqrtf` / ... (C++17 names libstdc++ before GCC 14 doesn't declare): use `std::cos`
  with a float argument (the float overload: on MSVC it calls cosf, so the result is the same bits).
- MSVC-only keywords, intrinsics, headers and `_s` functions outside an `#ifdef _WIN32` / `_MSC_VER` block.
- `long` as a type (32 bits on Windows, 64 on Linux): use int32_t / int64_t.
- `%ld` / `%lu` / `%I64d` in format strings (the same LLP64 / LP64 split).
- exceptions (`try`, `throw`, `catch`): godot-cpp builds with -fno-exceptions on GCC, which rejects them.
- a standard name without its header in the file (or a header of ours it includes): MSVC's headers pull in
  each other far more than libstdc++'s (<vector> alone gives no std::sort there).
- `#include "..."` whose case differs from the file on disk, or with a backslash (Linux is case-sensitive).

Exit code 0 when clean, 1 with one line per finding (file:line: what).
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
NATIVE = ROOT / "client" / "native"
EXTS = (".cpp", ".h", ".hpp", ".cc", ".inl")

# <cmath> functions with an f/l suffix: C++17 puts std::cosf etc. in <cmath>, libstdc++ only from GCC 14.
_MATH = ("cos sin tan acos asin atan atan2 cosh sinh tanh sqrt cbrt floor ceil round trunc fabs pow exp exp2 "
         "expm1 log log2 log10 log1p fmod remainder hypot lround llround lrint llrint rint nearbyint fmin fmax "
         "fdim copysign modf ldexp frexp scalbn")
SUFFIXED_MATH = re.compile(r"\bstd::(" + "|".join(_MATH.split()) + r")[fl]\s*\(")

# MSVC-only: allowed inside a block guarded by _WIN32 / _MSC_VER.
MSVC_ONLY = re.compile(
    r"\b(__forceinline|__declspec|__int8|__int16|__int32|__int64|_alloca|__assume|__restrict|__cpuid|__cpuidex|"
    r"_BitScanForward64|_BitScanReverse64|_BitScanForward|_BitScanReverse|__popcnt64|__popcnt|__lzcnt64|__lzcnt|"
    r"_byteswap_ushort|_byteswap_ulong|_byteswap_uint64|_rotl64|_rotr64|_rotl|_rotr|_aligned_malloc|_aligned_free|"
    r"sprintf_s|snprintf_s|swprintf_s|strcpy_s|strncpy_s|strcat_s|memcpy_s|memmove_s|fopen_s|sscanf_s|_snprintf|"
    r"_stricmp|_strnicmp|_strdup|_countof|__FUNCSIG__|_InterlockedIncrement|_InterlockedDecrement|"
    r"_InterlockedExchange|_InterlockedCompareExchange|InterlockedIncrement|InterlockedDecrement)\b")
MSVC_HEADERS = re.compile(r"#\s*include\s*<(intrin\.h|windows\.h|winsock2?\.h|ws2tcpip\.h|malloc\.h|io\.h|"
                          r"direct\.h|process\.h|conio\.h|tchar\.h)>", re.I)
LONG_TYPE = re.compile(r"\blong\b")
LONG_FORMAT = re.compile(r"%[-+ #0-9.*]*(l[diuxXo]|I64[diuxX]|I32[diuxX])")
EXCEPTIONS = re.compile(r"\b(try\s*\{|throw\b|catch\s*\()")

# std::name -> the headers any of which declares it.
_HEADERS: dict[str, tuple[str, ...]] = {}


def _add(header: str, names: str, *alt: str) -> None:
    for n in names.split():
        _HEADERS[n] = (header, *alt)


_add("algorithm", "sort stable_sort partial_sort nth_element min max minmax clamp min_element max_element "
     "minmax_element fill fill_n copy copy_n copy_if copy_backward find find_if find_if_not count count_if "
     "lower_bound upper_bound equal_range binary_search reverse rotate unique remove remove_if replace replace_if "
     "any_of all_of none_of for_each transform equal mismatch merge inplace_merge swap_ranges "
     "set_union set_intersection set_difference includes is_sorted shuffle generate search push_heap pop_heap "
     "make_heap sort_heap")
_add("cmath", "sqrt cbrt cos sin tan acos asin atan atan2 cosh sinh tanh floor ceil round trunc fabs pow exp exp2 "
     "expm1 log log2 log10 log1p fmod remainder hypot lround llround lrint llrint rint nearbyint isnan isinf "
     "isfinite isnormal signbit fmin fmax fdim copysign modf ldexp frexp scalbn fma", "math.h")
_add("cmath", "abs", "cstdlib", "math.h", "stdlib.h")
_add("cstdlib", "labs llabs malloc calloc realloc free strtol strtoll strtoul strtoull strtod strtof atoi atol "
     "atof qsort bsearch div getenv", "stdlib.h")
_add("cstring", "memcpy memset memcmp memmove memchr strlen strcmp strncmp strchr strrchr strstr strcpy strncpy "
     "strcat", "string.h")
_add("cstdio", "printf fprintf snprintf sprintf fopen fclose fread fwrite fputs puts", "stdio.h")
_add("utility", "pair make_pair forward exchange declval index_sequence make_index_sequence", "map", "unordered_map")
# std::swap / std::move live in <utility>; every container and <algorithm> gives them too.
_SWAP_HDRS = ("utility", "algorithm", "vector", "array", "deque", "map", "unordered_map", "unordered_set", "set",
              "string", "memory", "tuple")
_add("utility", "swap move", *_SWAP_HDRS[1:])
_add("vector", "vector")
_add("array", "array")
_add("deque", "deque")
_add("list", "list")
_add("map", "map multimap")
_add("set", "set multiset")
_add("unordered_map", "unordered_map unordered_multimap")
_add("unordered_set", "unordered_set unordered_multiset")
_add("string", "string wstring to_string stoi stol stoll stod stof")
_add("string_view", "string_view")
_add("memory", "unique_ptr shared_ptr weak_ptr make_unique make_shared")
_add("functional", "function less greater equal_to plus bind ref cref")
_add("functional", "hash", "unordered_map", "unordered_set", "string", "memory")
_add("thread", "thread this_thread")
_add("atomic", "atomic atomic_thread_fence memory_order memory_order_relaxed memory_order_acquire "
     "memory_order_release memory_order_acq_rel memory_order_seq_cst")
_add("mutex", "mutex recursive_mutex lock_guard unique_lock scoped_lock call_once once_flag")
_add("condition_variable", "condition_variable")
_add("chrono", "chrono")
_add("limits", "numeric_limits")
_add("numeric", "accumulate iota gcd lcm inner_product partial_sum adjacent_difference reduce")
_add("tuple", "tuple make_tuple tie")
_add("optional", "optional nullopt make_optional")
_add("type_traits", "is_same is_same_v enable_if enable_if_t decay decay_t is_integral is_floating_point "
     "is_trivially_copyable remove_reference conditional")
_add("iterator", "back_inserter distance advance next prev iterator_traits")
_add("cstdint", "int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t intptr_t uintptr_t "
     "int_fast32_t uint_fast32_t", "stdint.h")
_add("bitset", "bitset")
_add("random", "mt19937 mt19937_64 uniform_int_distribution uniform_real_distribution random_device")
_add("initializer_list", "initializer_list", "vector", "array", "map", "unordered_map", "set", "unordered_set",
     "string", "algorithm", "utility")

# Unqualified names from C headers (godot-cpp happens to bring some in, but only on its own terms).
_C_NAMES: dict[str, tuple[str, ...]] = {}
for _n in ("int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t intptr_t uintptr_t "
           "INT8_MAX INT16_MAX INT32_MAX INT32_MIN INT64_MAX INT64_MIN UINT8_MAX UINT16_MAX UINT32_MAX "
           "UINT64_MAX SIZE_MAX").split():
    _C_NAMES[_n] = ("cstdint", "stdint.h")
for _n in "INT_MAX INT_MIN UINT_MAX LLONG_MAX LLONG_MIN CHAR_BIT SHRT_MAX".split():
    _C_NAMES[_n] = ("climits", "limits.h")
for _n in "FLT_MAX FLT_MIN FLT_EPSILON DBL_MAX DBL_MIN DBL_EPSILON".split():
    _C_NAMES[_n] = ("cfloat", "float.h")
for _n in "memcpy memset memcmp memmove strlen strcmp strncmp".split():
    _C_NAMES[_n] = ("cstring", "string.h")
for _n in ("sqrtf cosf sinf tanf acosf asinf atanf atan2f floorf ceilf roundf truncf fabsf powf expf logf fmodf "
           "hypotf lroundf fminf fmaxf").split():
    _C_NAMES[_n] = ("cmath", "math.h")

STD_NAME = re.compile(r"\bstd::(\w+)")
C_NAME = re.compile(r"(?<![\w:.>])(" + "|".join(sorted(_C_NAMES, key=len, reverse=True)) + r")\b")
INCLUDE = re.compile(r'^\s*#\s*include\s*([<"])([^>"]+)[>"]', re.M)


def strip_code(text: str) -> tuple[str, str]:
    """(code with comments and string/char literals blanked, code with only comments blanked); lines kept."""
    out_code: list[str] = []
    out_str: list[str] = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out_code.append(" " * (j - i))
            out_str.append(" " * (j - i))
            i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            blank = re.sub(r"[^\n]", " ", text[i:j])
            out_code.append(blank)
            out_str.append(blank)
            i = j
        elif text.startswith('R"', i) and (i == 0 or not (text[i - 1].isalnum() or text[i - 1] == "_")):
            m = re.match(r'R"([^(\s]*)\(', text[i:])
            if not m:
                out_code.append(c)
                out_str.append(c)
                i += 1
                continue
            end = text.find(")" + m.group(1) + '"', i)
            j = n if end < 0 else end + len(m.group(1)) + 2
            out_code.append(re.sub(r"[^\n]", " ", text[i:j]))
            out_str.append(text[i:j])
            i = j
        elif c in "\"'":
            # A digit separator (1'000) is not a char literal.
            if c == "'" and i > 0 and text[i - 1].isalnum() and i + 1 < n and text[i + 1].isalnum():
                out_code.append(c)
                out_str.append(c)
                i += 1
                continue
            j = i + 1
            while j < n and text[j] != c and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            j = min(j + 1, n)
            out_code.append(c + " " * (j - i - 2) + (c if j - i >= 2 else ""))
            out_str.append(text[i:j])
            i = j
        else:
            out_code.append(c)
            out_str.append(c)
            i += 1
    return "".join(out_code), "".join(out_str)


_WIN_COND = re.compile(r"\b(_WIN32|_WIN64|_MSC_VER|WIN32|__MINGW32__)\b")


def windows_only_lines(code: str) -> set[int]:
    """1-based line numbers inside an #if branch that only a Windows / MSVC build compiles."""
    stack: list[list[bool]] = []  # [branch is windows-only, the #if named windows, negated]
    inside: set[int] = set()
    for no, line in enumerate(code.split("\n"), 1):
        s = line.strip()
        m = re.match(r"#\s*(ifdef|ifndef|if|elif|else|endif)\b(.*)", s)
        if m:
            kw, rest = m.group(1), m.group(2)
            if kw in ("ifdef", "ifndef", "if"):
                win = bool(_WIN_COND.search(rest))
                neg = kw == "ifndef" or bool(re.match(r"\s*!", rest))
                stack.append([win and not neg, win, neg])
            elif kw in ("elif", "else") and stack:
                top = stack[-1]
                # The #else of `#ifdef _WIN32` is the other platforms; of `#ifndef _WIN32` it is Windows.
                top[0] = top[1] and top[2] if kw == "else" else bool(_WIN_COND.search(rest))
            elif kw == "endif" and stack:
                stack.pop()
            continue
        if any(e[0] for e in stack):
            inside.add(no)
    return inside


def _includes(path: pathlib.Path, text: str) -> list[tuple[str, str, int]]:
    out = []
    for m in INCLUDE.finditer(text):
        out.append((m.group(1), m.group(2), text.count("\n", 0, m.start()) + 1))
    return out


def _local_headers(path: pathlib.Path, seen: set[pathlib.Path] | None = None) -> set[str]:
    """System headers included by `path` or (transitively) by our own "..." headers next to it."""
    seen = set() if seen is None else seen
    if path in seen or not path.is_file():
        return set()
    seen.add(path)
    got: set[str] = set()
    text = path.read_text(encoding="utf-8", errors="replace")
    for kind, name, _ in _includes(path, text):
        if kind == "<":
            got.add(name.strip())
        else:
            got |= _local_headers((path.parent / name).resolve(), seen)
    return got


def _disk_case_ok(base: pathlib.Path, rel: str) -> bool:
    """Each part of `rel` (from `base`) spelled exactly as on disk."""
    cur = base
    for part in pathlib.PurePosixPath(rel).parts:
        if part in (".", ".."):
            cur = cur / part
            continue
        if not cur.is_dir():
            return False
        names = {p.name for p in cur.iterdir()}
        if part not in names:
            return False
        cur = cur / part
    return True


def check_file(path: pathlib.Path, text: str | None = None) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="replace") if text is None else text
    try:
        rel = path.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        rel = path.as_posix()
    code, with_strings = strip_code(text)
    win = windows_only_lines(code)
    lines = code.split("\n")
    slines = with_strings.split("\n")
    found: list[str] = []

    def hit(no: int, what: str) -> None:
        found.append(f"{rel}:{no}: {what}")

    for no, line in enumerate(lines, 1):
        if line.lstrip().startswith("#"):
            m = MSVC_HEADERS.search(line)
            if m and no not in win:
                hit(no, f"<{m.group(1)}> is Windows-only: guard it with #ifdef _WIN32")
            continue
        for m in SUFFIXED_MATH.finditer(line):
            hit(no, f"std::{m.group(1)}{line[m.end(1)]} is not in GCC 13's <cmath>: use std::{m.group(1)} "
                    "with a float argument (same bits on MSVC)")
        m = MSVC_ONLY.search(line)
        if m and no not in win:
            hit(no, f"{m.group(1)} is MSVC-only: use a portable form or guard it with #ifdef _MSC_VER")
        for lm in LONG_TYPE.finditer(line):
            before = line[:lm.start()].rstrip()
            after = line[lm.end():].lstrip()
            if before.endswith("long") or after.startswith(("long", "double")):
                continue  # long long, long double
            hit(no, "`long` is 32 bits on Windows and 64 on Linux: use int32_t / int64_t")
            break
        m = EXCEPTIONS.search(line)
        if m:
            hit(no, f"`{m.group(1).split()[0].rstrip('{(')}`: godot-cpp builds with -fno-exceptions on GCC/Clang")
    for no, line in enumerate(slines, 1):
        for sm in re.finditer(r'"(?:[^"\\\n]|\\.)*"', line):
            for fm in LONG_FORMAT.finditer(sm.group(0)):
                if no in win:
                    break
                hit(no, f"format `{fm.group(0)}` differs between Windows and Linux: use PRId64 or a cast "
                        "to long long with %lld")

    # Includes: case on disk, backslashes.
    for kind, name, no in _includes(path, text):
        if "\\" in name:
            hit(no, f'#include "{name}": use / (Linux reads \\ as part of the name)')
        elif kind == '"' and (path.parent / name).exists() and not _disk_case_ok(path.parent, name):
            hit(no, f'#include "{name}": case differs from the file on disk (Linux is case-sensitive)')
        elif kind == '"' and not (path.parent / name).exists():
            # Our own sources include only files next to them; a name not there is a typo or wrong case.
            if not name.startswith(("godot_cpp/", "gdextension")):
                hit(no, f'#include "{name}": no such file next to this one')

    # Standard names without their header.
    have = {h.strip() for h in _local_headers(path.resolve())}
    missing: dict[str, int] = {}
    for no, line in enumerate(lines, 1):
        if line.lstrip().startswith("#") or no in win:
            continue
        for m in STD_NAME.finditer(line):
            hdrs = _HEADERS.get(m.group(1))
            if hdrs and not any(h in have for h in hdrs) and m.group(1) not in missing:
                missing[m.group(1)] = no
        for m in C_NAME.finditer(line):
            hdrs = _C_NAMES[m.group(1)]
            if not any(h in have for h in hdrs) and m.group(1) not in missing:
                missing[m.group(1)] = no
    for name, no in sorted(missing.items(), key=lambda kv: kv[1]):
        hdrs = _HEADERS.get(name) or _C_NAMES[name]
        qual = name if name in _C_NAMES and name not in _HEADERS else "std::" + name
        hit(no, f"{qual} without #include <{hdrs[0]}> (MSVC's headers bring it in, libstdc++'s may not)")
    return found


# The native libraries CI builds for Linux (.github/workflows/tests.yml, job ui). client/native/upscalers is
# Windows-only (D3D12, AMD's and NVIDIA's DLLs; its .gdextension lists Windows alone), so it is left out.
LINUX_LIBS = ("belt_sim",)


def native_sources() -> list[pathlib.Path]:
    out = []
    for lib in LINUX_LIBS:
        for p in sorted((NATIVE / lib / "src").rglob("*")):
            if p.suffix in EXTS and p.is_file():
                out.append(p)
    return out


def main(argv: list[str]) -> int:
    files = [pathlib.Path(a) for a in argv] if argv else native_sources()
    found: list[str] = []
    for f in files:
        found += check_file(f)
    for line in found:
        print(line)
    print(f"native_portability_check: {len(files)} files, {len(found)} finding(s)")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
