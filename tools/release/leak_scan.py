"""Scan a source tree, directory, or release .zip for privacy leaks.

Checks for Windows user paths and optional forbidden strings in both ASCII/UTF-8
and UTF-16-LE, recursing into nested .zip archives and scanning .pck binaries.
Exits 0 if clean, 1 if any hits are found.
"""

from __future__ import annotations

import argparse
import io
import pathlib
import re
import subprocess
import sys
import zipfile

# Matches C:\Users\<name> or C:/Users/<name> while ignoring placeholders like C:\Users\...
WIN_USER_UTF8_RE = re.compile(rb"[A-Za-z]:[\\/]Users[\\/](?!\.\.\.)[A-Za-z0-9_.-]+")
WIN_USER_UTF16_RE = re.compile(
    rb"[A-Za-z]\x00:\x00(?:\\\x00|/\x00)U\x00s\x00e\x00r\x00s\x00(?:\\\x00|/\x00)"
    rb"(?!\.\x00\.\x00\.\x00)(?:[A-Za-z0-9_.-]\x00)+"
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


def _scan_zip_bytes(data: bytes, location: str, forbidden: list[tuple[str, bytes, bytes]], hits: list[str]) -> None:
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            for info in zf.infolist():
                if info.is_dir():
                    continue
                entry_loc = f"{location}!/{info.filename}"
                entry_data = zf.read(info)
                if info.filename.lower().endswith(".zip"):
                    _scan_zip_bytes(entry_data, entry_loc, forbidden, hits)
                else:
                    _scan_bytes(entry_data, entry_loc, forbidden, hits)
    except zipfile.BadZipFile as exc:
        hits.append(f"{location}: unreadable zip archive ({exc})")


def scan_target(
    target: pathlib.Path,
    strings_file: pathlib.Path | None = None,
    private_paths_file: pathlib.Path | None = None,
) -> list[str]:
    """Scan a directory or .zip archive and return a list of leak hit descriptions."""
    raw_strings = _load_lines(strings_file)
    forbidden = [(s, s.encode("utf-8"), s.encode("utf-16-le")) for s in raw_strings]
    private_prefixes = [p.replace("\\", "/").lstrip("./") for p in _load_lines(private_paths_file)]

    hits: list[str] = []
    if target.is_file():
        if target.suffix.lower() == ".zip":
            _scan_zip_bytes(target.read_bytes(), str(target), forbidden, hits)
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
            _scan_zip_bytes(data, rel, forbidden, hits)
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
        hits = scan_target(target, strings_path, private_path)
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
