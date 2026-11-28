"""Fetch the vendors' own runtime libraries that a Windows download can carry in its vendor/ folder.

    python tools/release/fetch_vendor_runtimes.py [--dest art-src/vendor-runtimes] [--check]

Today that is AMD's FSR SDK 2.4.0: the signed `amd_fidelityfx_loader_dx12.dll` and
`amd_fidelityfx_upscaler_dx12.dll` and AMD's `license.md`, taken from AMD's own GitHub release
(GPUOpen-LibrariesAndSDKs/FidelityFX-SDK, tag v2.4.0; the release's one download is the tag's source
archive, about 250 MB, which holds the signed DLLs). Nothing else is read from it. NVIDIA's DLSS files
are never fetched or shipped: the player puts them in vendor/nvidia/ themselves.

The archive's SHA-256 and each extracted file's SHA-256 are pinned below and checked; a mismatch stops
with nothing written. The files go to a git-ignored folder (default art-src/vendor-runtimes/amd/),
never into git. Idempotent: when all files are already there with the right hashes nothing is
downloaded (works offline). --check only reports that and never downloads.

package.py --vendor-runtimes=<dest> then copies <dest>/amd/ into the Windows x86_64 zip.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import pathlib
import sys
import tempfile
import urllib.request
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_DEST = ROOT / "art-src" / "vendor-runtimes"

AMD_VERSION = "2.4.0"
AMD_URL = "https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/archive/refs/tags/v2.4.0.zip"
AMD_ARCHIVE_SHA256 = "27120e3bbe0d0b30213825ad40f19077563f04f04572e252109a392d5fb522cb"
AMD_PREFIX = "FidelityFX-SDK-2.4.0/"
# archive path (below AMD_PREFIX) -> (file name in vendor/amd/, SHA-256 of that file)
AMD_FILES = {
    "Kits/FidelityFX/signedbin/amd_fidelityfx_loader_dx12.dll": (
        "amd_fidelityfx_loader_dx12.dll", "e2191d3c0828be45eb8affd4e3ec0378f2293adc345b772a7170edcf3b021ecb"),
    "Kits/FidelityFX/signedbin/amd_fidelityfx_upscaler_dx12.dll": (
        "amd_fidelityfx_upscaler_dx12.dll", "aad4fccccb29084a655f9a4f9f613bd22c8c03fb4a0f8840148cc6543b4ccace"),
    "Kits/FidelityFX/docs/license.md": (
        "license.md", "32357259b965d6a8001e9e508ba60eda6034027c5923a7d226ffbaff813c2bfb"),
}
# the names package.py and the leak scan rely on
AMD_DLLS = ("amd_fidelityfx_loader_dx12.dll", "amd_fidelityfx_upscaler_dx12.dll")
AMD_LICENSE = "license.md"


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def amd_present(dest: pathlib.Path) -> bool:
    """True when every AMD file is in <dest>/amd/ with its pinned SHA-256."""
    folder = dest / "amd"
    for name, digest in AMD_FILES.values():
        p = folder / name
        if not p.is_file() or sha256_file(p) != digest:
            return False
    return True


def download(url: str, out: pathlib.Path) -> str:
    """Stream url to out and return its SHA-256. Only AMD's GitHub is ever asked."""
    if not url.startswith("https://github.com/GPUOpen-LibrariesAndSDKs/"):
        raise ValueError(f"refusing to fetch from {url}")
    h = hashlib.sha256()
    req = urllib.request.Request(url, headers={"User-Agent": "zenith-fetch-vendor-runtimes"})
    with urllib.request.urlopen(req, timeout=120) as r, open(out, "wb") as f:
        while True:
            block = r.read(1 << 20)
            if not block:
                break
            h.update(block)
            f.write(block)
    return h.hexdigest()


def extract_amd(archive: pathlib.Path, dest: pathlib.Path) -> None:
    """Check archive and files against the pins, then write the AMD files. Nothing is written on a mismatch."""
    if sha256_file(archive) != AMD_ARCHIVE_SHA256:
        raise ValueError("AMD archive SHA-256 differs from the pinned one")
    blobs = {}
    with zipfile.ZipFile(archive) as z:
        for member, (name, digest) in AMD_FILES.items():
            data = z.read(AMD_PREFIX + member)
            if hashlib.sha256(data).hexdigest() != digest:
                raise ValueError(f"{name}: SHA-256 differs from the pinned one")
            blobs[name] = data
    folder = dest / "amd"
    folder.mkdir(parents=True, exist_ok=True)
    for name, data in blobs.items():
        (folder / name).write_bytes(data)


def fetch_amd(dest: pathlib.Path, url: str = AMD_URL) -> str:
    if amd_present(dest):
        return "present"
    with tempfile.TemporaryDirectory() as tmp:
        archive = pathlib.Path(tmp) / "fsr-sdk.zip"
        print(f"downloading AMD FSR SDK {AMD_VERSION} from {url} ...")
        got = download(url, archive)
        if got != AMD_ARCHIVE_SHA256:
            raise ValueError(f"AMD archive SHA-256 {got} differs from the pinned {AMD_ARCHIVE_SHA256}")
        extract_amd(archive, dest)
    return "fetched"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--dest", default=str(DEFAULT_DEST), help="folder for amd/ (default art-src/vendor-runtimes)")
    ap.add_argument("--check", action="store_true", help="only report whether the files are present and match; no download")
    args = ap.parse_args(argv)
    dest = pathlib.Path(args.dest)
    if args.check:
        ok = amd_present(dest)
        print(f"AMD FSR SDK {AMD_VERSION}: {'present, checksums match' if ok else 'missing or different'} ({dest / 'amd'})")
        return 0 if ok else 1
    try:
        state = fetch_amd(dest)
    except (ValueError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(f"AMD FSR SDK {AMD_VERSION}: {state} in {dest / 'amd'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
