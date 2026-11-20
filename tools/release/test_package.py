"""Tests for package.py's model zip (--models / --zenith-zip): a pack folder's top-level models and its
items/ folder go into Zenith.zip under the same names. Builds nothing else and runs no Godot.
    python tools/release/test_package.py
"""
import pathlib
import sys
import tempfile
import zipfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
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


if __name__ == "__main__":
    test_items_folder()
    test_no_items_folder()
    test_only_items()
    print(f"{len(FAILS)} fail(s)")
    sys.exit(1 if FAILS else 0)
