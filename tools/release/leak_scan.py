"""Scan a source tree, directory, or release .zip for privacy leaks.

Checks for Windows user paths and optional forbidden strings in both ASCII/UTF-8
and UTF-16-LE, recursing into nested .zip archives and scanning .pck binaries.
Exits 0 if clean, 1 if any hits are found.
"""

from __future__ import annotations

import argparse
import io
import json
import pathlib
import re
import subprocess
import sys
import zipfile

# Matches C:\Users\<name> or C:/Users/<name> while ignoring placeholders like C:\Users\... and GitHub's
# build-machine account `runneradmin` (that exact name only, owner's choice): Godot's prebuilt AccessKit
# library, linked into our own Godot template build (tools/godot/build_template.ps1), carries
# C:\Users\runneradmin\.cargo\... paths. Every other user name still stops the scan.
WIN_USER_UTF8_RE = re.compile(rb"[A-Za-z]:[\\/]Users[\\/](?!\.\.\.)(?!runneradmin[\\/])[A-Za-z0-9_.-]+")
WIN_USER_UTF16_RE = re.compile(
    rb"[A-Za-z]\x00:\x00(?:\\\x00|/\x00)U\x00s\x00e\x00r\x00s\x00(?:\\\x00|/\x00)"
    rb"(?!\.\x00\.\x00\.\x00)(?!r\x00u\x00n\x00n\x00e\x00r\x00a\x00d\x00m\x00i\x00n\x00(?:\\\x00|/\x00))"
    rb"(?:[A-Za-z0-9_.-]\x00)+"
)

DEFAULT_SKIP_PREFIXES = (".git/", "art-src/", ".venv/", "client/.godot/")


def main_checkout(repo: pathlib.Path) -> pathlib.Path:
    """Resolve the main checkout even when invoked inside a git worktree."""
    try:
        proc = subprocess.run(
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
            cwd=repo,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=True,
        )
        out = proc.stdout.strip()
        if out:
            return pathlib.Path(out).parent
    except (OSError, subprocess.CalledProcessError):
        pass
    return repo


def _load_lines(path: pathlib.Path | None) -> list[str]:
    if path is None or not path.is_file():
        return []
    lines: list[str] = []
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if line and not line.startswith("#"):
            lines.append(line)
    return lines


def _is_private(rel: str, private_prefixes: list[str]) -> bool:
    for pref in private_prefixes:
        if rel == pref or rel.startswith(pref.rstrip("/") + "/") or rel.startswith(pref):
            return True
    return False


def _scan_bytes(data: bytes, location: str, forbidden: list[tuple[str, bytes, bytes]], hits: list[str]) -> None:
    m8 = WIN_USER_UTF8_RE.search(data)
    if m8:
        hits.append(f"{location}: Windows user path (UTF-8/ASCII): {m8.group(0).decode('utf-8', errors='replace')}")
    m16 = WIN_USER_UTF16_RE.search(data)
    if m16:
        hits.append(f"{location}: Windows user path (UTF-16-LE): {m16.group(0).decode('utf-16-le', errors='replace')}")
    for label, b8, b16 in forbidden:
        if b8 and b8 in data:
            hits.append(f"{location}: forbidden string (UTF-8/ASCII): {label}")
        if b16 and b16 in data:
            hits.append(f"{location}: forbidden string (UTF-16-LE): {label}")


# Vendor runtime libraries (docs/RUNNING.md, tools/release/fetch_vendor_runtimes.py): only a Windows
# x86_64 zip (Zenith-<version>[-dev]-windows.zip) may hold vendor/amd/, AMD's license.md exactly when it
# holds AMD's DLLs. No other platform's zip and no source archive gets any vendor file. vendor/nvidia/
# is allowed only in a Windows x86_64 zip whose BUILD.json says its "vendor" includes nvidia
# (package.py --ship-nvidia) AND when the scan itself is told yes (--allow-nvidia; package.py passes its
# own --ship-nvidia): a zip's own word is never enough on its own. Then only Zenith's own Streamline build: exactly VENDOR_NVIDIA_FILES, all
# four. NVIDIA's own nvngx_dlss.dll (the player's download) and anything else there always fail.
VENDOR_AMD_DLLS = ("amd_fidelityfx_loader_dx12.dll", "amd_fidelityfx_upscaler_dx12.dll")
VENDOR_AMD_LICENSE = "license.md"
VENDOR_NVIDIA_FILES = ("sl.interposer.dll", "sl.common.dll", "sl.dlss.dll", "zenith-sl-manifest.txt")
_WINDOWS_ZIP_RE = re.compile(r"-windows\.zip$", re.IGNORECASE)


def build_ships_nvidia(build_json: bytes | str | None) -> bool:
    """True when a download's BUILD.json says its vendor runtimes include nvidia ("vendor": "amd+nvidia")."""
    if not build_json:
        return False
    try:
        data = json.loads(build_json)
    except (ValueError, UnicodeDecodeError):
        return False
    vendor = data.get("vendor") if isinstance(data, dict) else None
    return isinstance(vendor, str) and "nvidia" in vendor.split("+")


def zip_ships_nvidia(zf: zipfile.ZipFile) -> bool:
    """build_ships_nvidia for the BUILD.json at a download zip's top (Zenith-x/BUILD.json, or BUILD.json)."""
    for info in zf.infolist():
        parts = info.filename.replace("\\", "/").split("/")
        if parts[-1] == "BUILD.json" and len(parts) <= 2:
            return build_ships_nvidia(zf.read(info))
    return False


def vendor_problems(zip_name: str, entries: list[str], nvidia_ok: bool = False) -> list[str]:
    """Problems with the vendor/ files in one zip, given its file name and its entry names. nvidia_ok: its
    BUILD.json says it ships NVIDIA's (Zenith's Streamline build, VENDOR_NVIDIA_FILES)."""
    problems: list[str] = []
    vendor = []
    for e in entries:
        parts = e.replace("\\", "/").split("/")
        # Zenith-x/vendor/<vendor>/<file> in a download; vendor/... only if a zip has no top folder.
        if "vendor" in parts[:2] and parts[-1]:
            tail = parts[parts.index("vendor") + 1:]
            if len(tail) >= 2:
                vendor.append((tail[0], "/".join(tail[1:])))
    if not vendor:
        return problems
    if not _WINDOWS_ZIP_RE.search(zip_name):
        problems.append(f"{zip_name}: vendor files in a zip that is not a Windows x86_64 download ({len(vendor)} file(s))")
        return problems
    for v, rest in vendor:
        if v == "nvidia" and nvidia_ok:
            if rest not in VENDOR_NVIDIA_FILES:
                problems.append(f"{zip_name}: vendor/nvidia/{rest} is never shipped (only Zenith's Streamline build: "
                                f"{', '.join(VENDOR_NVIDIA_FILES)})")
        elif v == "nvidia":
            problems.append(f"{zip_name}: vendor/nvidia/{rest} without both the build's BUILD.json saying nvidia "
                            f"(--ship-nvidia) and the scan's --allow-nvidia")
        elif v != "amd":
            problems.append(f"{zip_name}: vendor/{v}/{rest} is never shipped (only vendor/amd/)")
    nvidia = {rest for v, rest in vendor if v == "nvidia"}
    if nvidia_ok and nvidia and not all(f in nvidia for f in VENDOR_NVIDIA_FILES):
        problems.append(f"{zip_name}: only part of Zenith's Streamline build in vendor/nvidia/ "
                        f"(missing {', '.join(f for f in VENDOR_NVIDIA_FILES if f not in nvidia)})")
    amd = {rest for v, rest in vendor if v == "amd"}
    has_dll = any(d in amd for d in VENDOR_AMD_DLLS)
    has_license = VENDOR_AMD_LICENSE in amd
    if has_dll and not has_license:
        problems.append(f"{zip_name}: AMD's DLLs without AMD's license.md")
    if has_license and not has_dll:
        problems.append(f"{zip_name}: AMD's license.md without AMD's DLLs")
    if has_dll and not all(d in amd for d in VENDOR_AMD_DLLS):
        problems.append(f"{zip_name}: only one of AMD's two DLLs")
    return problems


def _scan_zip_bytes(data: bytes, location: str, forbidden: list[tuple[str, bytes, bytes]], hits: list[str],
                    allow_nvidia: bool = False) -> None:
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            for problem in vendor_problems(pathlib.PurePosixPath(location.replace("\\", "/").split("!/")[-1]).name,
                                           [i.filename for i in zf.infolist() if not i.is_dir()],
                                           allow_nvidia and zip_ships_nvidia(zf)):
                hits.append(f"{location}: {problem}")
            for info in zf.infolist():
                if info.is_dir():
                    continue
                entry_loc = f"{location}!/{info.filename}"
                entry_data = zf.read(info)
                if info.filename.lower().endswith(".zip"):
                    _scan_zip_bytes(entry_data, entry_loc, forbidden, hits, allow_nvidia)
                else:
                    _scan_bytes(entry_data, entry_loc, forbidden, hits)
    except zipfile.BadZipFile as exc:
        hits.append(f"{location}: unreadable zip archive ({exc})")


def scan_target(
    target: pathlib.Path,
    strings_file: pathlib.Path | None = None,
    private_paths_file: pathlib.Path | None = None,
    allow_nvidia: bool = False,
) -> list[str]:
    """Scan a directory or .zip archive and return a list of leak hit descriptions. allow_nvidia: the
    scan's own yes (--allow-nvidia) to Zenith's Streamline build in a zip whose BUILD.json ships it."""
    raw_strings = _load_lines(strings_file)
    forbidden = [(s, s.encode("utf-8"), s.encode("utf-16-le")) for s in raw_strings]
    private_prefixes = [p.replace("\\", "/").removeprefix("./") for p in _load_lines(private_paths_file)]

    hits: list[str] = []
    if target.is_file():
        if target.suffix.lower() == ".zip":
            _scan_zip_bytes(target.read_bytes(), str(target), forbidden, hits, allow_nvidia)
        else:
            _scan_bytes(target.read_bytes(), str(target), forbidden, hits)
        return hits

    if not target.is_dir():
        raise FileNotFoundError(f"Target does not exist: {target}")

    for path in sorted(target.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(target).as_posix()
        if rel.startswith(DEFAULT_SKIP_PREFIXES) or "__pycache__" in path.relative_to(target).parts or _is_private(rel, private_prefixes):
            continue
        data = path.read_bytes()
        if path.suffix.lower() == ".zip":
            _scan_zip_bytes(data, rel, forbidden, hits, allow_nvidia)
        else:
            _scan_bytes(data, rel, forbidden, hits)
    return hits


def _resolve_default_release_file(repo_root: pathlib.Path, filename: str) -> pathlib.Path | None:
    candidate = main_checkout(repo_root) / "art-src" / "release" / filename
    if candidate.is_file():
        return candidate
    local = repo_root / "art-src" / "release" / filename
    return local if local.is_file() else None


def main(argv: list[str] | None = None) -> int:
    repo_root = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description="Scan a directory or .zip archive for privacy leaks.")
    parser.add_argument("target", nargs="?", default=".", help="Directory or .zip file to scan (default: .)")
    parser.add_argument(
        "--strings",
        default=None,
        help="Path to forbidden strings file (default: <main_checkout>/art-src/release/forbidden-strings.txt if present)",
    )
    parser.add_argument(
        "--private-paths",
        default=None,
        help="Path to private paths file (default: <main_checkout>/art-src/release/private-paths.txt if present)",
    )
    parser.add_argument(
        "--allow-nvidia",
        action="store_true",
        help="let Zenith's Streamline build (vendor/nvidia/) through in a Windows zip whose BUILD.json ships it "
             "(package.py --ship-nvidia); without it any NVIDIA file is a hit, whatever the zip says",
    )
    args = parser.parse_args(argv)

    strings_path: pathlib.Path | None
    if args.strings is not None:
        strings_path = pathlib.Path(args.strings)
        if not strings_path.is_file():
            print(f"error: --strings file not found: {strings_path}", file=sys.stderr)
            return 2
    else:
        strings_path = _resolve_default_release_file(repo_root, "forbidden-strings.txt")

    private_path: pathlib.Path | None
    if args.private_paths is not None:
        private_path = pathlib.Path(args.private_paths)
        if not private_path.is_file():
            print(f"error: --private-paths file not found: {private_path}", file=sys.stderr)
            return 2
    else:
        private_path = _resolve_default_release_file(repo_root, "private-paths.txt")

    target = pathlib.Path(args.target)
    try:
        hits = scan_target(target, strings_path, private_path, args.allow_nvidia)
    except FileNotFoundError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if hits:
        for hit in hits:
            print(f"LEAK: {hit}")
        print(f"{len(hits)} leak(s) found.", file=sys.stderr)
        return 1

    print(f"clean: {target} (0 leaks)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
