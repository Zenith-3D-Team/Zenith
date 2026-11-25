"""Tests for package.py's model zip (--models / --zenith-zip): a pack folder's top-level models and its
items/ folder go into Zenith.zip under the same names. Builds nothing else and runs no Godot.
    python tools/release/test_package.py
"""
import io
import pathlib
import sys
import tempfile
import zipfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import leak_scan  # noqa: E402
import package  # noqa: E402

FAILS = []


def check(cond, what):
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        FAILS.append(what)


def names_in(folder):
    with tempfile.TemporaryDirectory() as out:
        zip_path = pathlib.Path(out) / "Zenith.zip"
        count = package.default_zip(package.bundled_models(folder), zip_path)
        with zipfile.ZipFile(zip_path) as z:
            return count, sorted(z.namelist())


def test_items_folder():
    with tempfile.TemporaryDirectory() as tmp:
        pack = pathlib.Path(tmp)
        (pack / "b.glb").write_bytes(b"glb b")
        (pack / "c.gltf").write_text("{}")
        (pack / "c.bin").write_bytes(b"bin")
        (pack / "notes.txt").write_text("not a model")
        (pack / ".hidden.glb").write_bytes(b"hidden")
        (pack / "items").mkdir()
        (pack / "items" / "a.glb").write_bytes(b"glb a")
        (pack / "items" / "readme.md").write_text("not a model")
        (pack / "other").mkdir()
        (pack / "other" / "x.glb").write_bytes(b"glb x")
        count, names = names_in(pack)
        gear = package.DEFAULT_PACK["icon_image"]
        check("items/a.glb" in names, "items/a.glb is in the zip as items/a.glb")
        check("a.glb" not in names, "the item is not also at the zip's top")
        top = sorted(n for n in names if "/" not in n)
        check(top == sorted(["README.txt", "b.glb", "c.bin", "c.gltf", gear, "pack.json"]),
            f"the zip's top level is unchanged ({top})")
        check(not any(n.startswith("other/") for n in names), "other sub-folders stay out")
        check(count == 3, f"three models counted (b.glb, c.gltf, items/a.glb): {count}")


def test_no_items_folder():
    with tempfile.TemporaryDirectory() as tmp:
        pack = pathlib.Path(tmp)
        (pack / "b.glb").write_bytes(b"glb b")
        count, names = names_in(pack)
        check(not any("/" in n for n in names) and "b.glb" in names and count == 1,
            f"a pack without items/ zips as before ({names})")


def test_only_items():
    # A folder whose only models are items is still a model folder.
    with tempfile.TemporaryDirectory() as tmp:
        pack = pathlib.Path(tmp)
        (pack / "items").mkdir()
        (pack / "items" / "a.glb").write_bytes(b"glb a")
        count, names = names_in(pack)
        check(count == 1 and "items/a.glb" in names, "a pack of items alone zips them")


def test_leak_scan_clean_and_hits():
    planted = "C:\\" + "Users\\" + "alice\\secret"
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        clean_dir = root / "clean"
        clean_dir.mkdir()
        (clean_dir / "readme.txt").write_text("C:\\Users\\...\\Zenith\n", encoding="utf-8")
        (clean_dir / "fake.pck").write_bytes(b"GDPC\x01\x00\x00\x00clean-binary")
        check(leak_scan.main([str(clean_dir)]) == 0, "leak_scan passes on a clean tree")

        ascii_dir = root / "ascii"
        ascii_dir.mkdir()
        (ascii_dir / "notes.txt").write_text(f"path={planted}\n", encoding="utf-8")
        check(leak_scan.main([str(ascii_dir)]) == 1, "leak_scan fails on planted ASCII hit")

        pck_dir = root / "pck"
        pck_dir.mkdir()
        (pck_dir / "Zenith.pck").write_bytes(b"GDPC\x00" + planted.encode("utf-16-le") + b"\x00\x00")
        pck_hits = leak_scan.scan_target(pck_dir)
        check(len(pck_hits) == 1 and "UTF-16-LE" in pck_hits[0] and leak_scan.main([str(pck_dir)]) == 1,
              "leak_scan fails on UTF-16-LE hit inside a fake .pck")

        inner_buf = io.BytesIO()
        with zipfile.ZipFile(inner_buf, "w") as inner_zip:
            inner_zip.writestr("leak.txt", f"leaked={planted}")
        outer_zip_path = root / "outer.zip"
        with zipfile.ZipFile(outer_zip_path, "w") as outer_zip:
            outer_zip.writestr("nested/inner.zip", inner_buf.getvalue())
        zip_hits = leak_scan.scan_target(outer_zip_path)
        check(len(zip_hits) == 1 and "inner.zip!/leak.txt" in zip_hits[0] and leak_scan.main([str(outer_zip_path)]) == 1,
              "leak_scan fails on planted hit inside a nested .zip")

        fwd_dir = root / "fwd"
        fwd_dir.mkdir()
        fwd_planted = planted.replace("\\", "/")
        (fwd_dir / "BUILD.json").write_text(f'{{"source": "local:{fwd_planted}"}}\n', encoding="utf-8")
        (fwd_dir / "fwd.pck").write_bytes(b"GDPC\x00" + fwd_planted.encode("utf-16-le") + b"\x00\x00")
        fwd_hits = leak_scan.scan_target(fwd_dir)
        check(len(fwd_hits) == 2 and leak_scan.main([str(fwd_dir)]) == 1,
              f"leak_scan catches forward-slash C:/Users/... paths in UTF-8 and UTF-16-LE ({fwd_hits})")


def test_build_manifest_and_version_validation():
    manifest = package.build_manifest(
        "0.3.0",
        "public",
        [{"id": "cinematic-shaders", "version": "1.0.0", "source": "local:addons-src/cinematic-shaders", "on": True}],
    )
    check(
        manifest["version"] == "0.3.0"
        and manifest["channel"] == "public"
        and len(manifest["addons"]) == 1
        and manifest["addons"][0]["id"] == "cinematic-shaders"
        and manifest["addons"][0]["source"] == "local:addons-src/cinematic-shaders"
        and manifest["addons"][0]["on"] is True,
        "build_manifest records version, channel, and bundled add-on metadata",
    )

    # External --addon directory never leaks C:/Users/... into BUILD.json source, and dev channel skips untagged BUNDLED
    with tempfile.TemporaryDirectory() as tmp:
        ext = pathlib.Path(tmp) / "my-addon"
        ext.mkdir()
        (ext / "addon.json").write_text('{"id": "my-addon", "version": "1.2.3", "api": 1.8, "entry": "main.gd"}', encoding="utf-8")
        (ext / "main.gd").write_text("extends Node\n", encoding="utf-8")
        ns = type("Args", (), {"no_addons": False, "channel": "dev", "addon": [f"{ext}:off"]})()
        gathered = package.gather_addons(ns)
        check(len(gathered) == 1 and gathered[0]["source"] == "local:my-addon" and gathered[0]["on"] is False,
              f"gather_addons on dev channel skips untagged BUNDLED and sanitizes external path ({gathered})")

        ns_pub = type("Args", (), {"no_addons": False, "channel": "public", "addon": []})()
        pub_failed = False
        try:
            package.gather_addons(ns_pub)
        except SystemExit:
            pub_failed = True
        check(pub_failed, "gather_addons on public channel refuses untagged BUNDLED entries")

    with tempfile.TemporaryDirectory() as tmp:
        d = pathlib.Path(tmp)
        proj = d / "project.godot"
        presets = d / "export_presets.cfg"
        proj.write_text('config/version="0.3.0"\n', encoding="utf-8")
        presets.write_text('application/short_version="0.3.0"\napplication/version="0.3.0"\n', encoding="utf-8")
        package.validate_versions("0.3.0", proj, presets)
        check(True, "validate_versions passes when project.godot and export_presets.cfg match")

        presets.write_text('application/short_version="0.2.1"\napplication/version="0.3.0"\n', encoding="utf-8")
        failed = False
        try:
            package.validate_versions("0.3.0", proj, presets)
        except ValueError:
            failed = True
        check(failed, "validate_versions rejects mismatched export_presets.cfg version")


if __name__ == "__main__":
    test_items_folder()
    test_no_items_folder()
    test_only_items()
    test_leak_scan_clean_and_hits()
    test_build_manifest_and_version_validation()
    print(f"{len(FAILS)} fail(s)")
    sys.exit(1 if FAILS else 0)
