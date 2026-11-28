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
import fetch_vendor_runtimes  # noqa: E402
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

        runner = "C:\\" + "Users\\" + "runneradmin\\.cargo\\registry\\accesskit"
        runner_dir = root / "runner"
        runner_dir.mkdir()
        (runner_dir / "Zenith.exe").write_bytes(b"MZ" + runner.encode() + b"\x00" + runner.encode("utf-16-le"))
        check(leak_scan.main([str(runner_dir)]) == 0, "leak_scan allows GitHub's runneradmin build path")
        (runner_dir / "Zenith.exe").write_bytes(b"MZ" + runner.encode() + b"\x00" + planted.encode("utf-16-le"))
        check(leak_scan.main([str(runner_dir)]) == 1, "leak_scan still fails on a real user beside runneradmin")
        (runner_dir / "Zenith.exe").write_bytes(b"MZ" + ("C:\\" + "Users\\" + "runneradmin2\\x").encode())
        check(leak_scan.main([str(runner_dir)]) == 1, "leak_scan allows only the exact runneradmin name")

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


def test_windows_template_option():
    real = (package.ROOT / "client" / "export_presets.cfg").read_text(encoding="utf-8")
    for nl in ("\n", "\r\n"):
        text = real.replace("\r\n", "\n").replace("\n", nl)
        out = package.set_preset_option(text, "Windows Desktop", "custom_template/release", r"I:\x y\t.exe")
        changed = [(a, b) for a, b in zip(text.split(nl), out.split(nl)) if a != b]
        check(len(changed) == 1 and changed[0][1] == 'custom_template/release="I:/x y/t.exe"'
              and out.count(nl) == text.count(nl),
              "set_preset_option changes only the Windows preset's custom_template/release line (%r)" % nl)
    # Windows ARM64 also has a custom_template/release: only the named preset's line changes
    arm = package.set_preset_option(real, "Windows ARM64 (unsupported)", "custom_template/release", "a.exe")
    check(arm.count('custom_template/release="a.exe"') == 1 and arm.index('custom_template/release="a.exe"') > real.index('name="Windows ARM64'),
          "set_preset_option picks the named preset's own options section")
    for preset, key in (("No such", "custom_template/release"), ("Windows Desktop", "no/such_key")):
        try:
            package.set_preset_option(real, preset, key, "x")
            check(False, "set_preset_option raises for %s / %s" % (preset, key))
        except ValueError:
            check(True, "set_preset_option raises for %s / %s" % (preset, key))
    # the wrapper puts export_presets.cfg back byte for byte, even when the export fails
    presets = package.ROOT / "client" / "export_presets.cfg"
    before = presets.read_bytes()
    seen = []

    def fake_export(godot, preset, out_exe):
        seen.append('custom_template/release="C:/t/w.exe"' in presets.read_text(encoding="utf-8"))
        raise RuntimeError("export failed")
    try:
        package.with_windows_template(r"C:\t\w.exe", fake_export)("godot", "Windows Desktop", pathlib.Path("x"))
    except RuntimeError:
        pass
    check(seen == [True] and presets.read_bytes() == before,
          "with_windows_template sets the template for the export and restores export_presets.cfg after")


def _mk_zip(path, names):
    with zipfile.ZipFile(path, "w") as z:
        for n in names:
            z.writestr(n, b"x")


AMD_FILES = ["vendor/amd/amd_fidelityfx_loader_dx12.dll", "vendor/amd/amd_fidelityfx_upscaler_dx12.dll",
             "vendor/amd/license.md"]


def test_vendor_rules():
    top = "Zenith-1.0.0-windows/"
    vp = leak_scan.vendor_problems
    check(vp("Zenith-1.0.0-windows.zip", [top + n for n in AMD_FILES] + [top + "Zenith.exe"]) == [],
          "a Windows zip with AMD's DLLs and license.md is fine")
    check(vp("Zenith-1.0.0-dev-windows.zip", [top + n for n in AMD_FILES]) == [], "the dev channel's Windows zip too")
    check(vp("Zenith-1.0.0-windows.zip", [top + "Zenith.exe", top + "mod/x.lua"]) == [], "a Windows zip with no vendor/ is fine")
    check(len(vp("Zenith-1.0.0-windows.zip", [top + n for n in AMD_FILES[:2]])) == 1, "AMD's DLLs without license.md fail")
    check(len(vp("Zenith-1.0.0-windows.zip", [top + AMD_FILES[2]])) == 1, "license.md without AMD's DLLs fails")
    check(len(vp("Zenith-1.0.0-windows.zip", [top + AMD_FILES[0], top + AMD_FILES[2]])) == 1, "one DLL of two fails")
    check(len(vp("Zenith-1.0.0-windows.zip", [top + n for n in AMD_FILES] + [top + "vendor/nvidia/nvngx_dlss.dll"])) == 1,
          "an NVIDIA file is never shipped")
    for name in ("Zenith-1.0.0-linux.zip", "Zenith-1.0.0-macos-unsupported.zip", "Zenith-1.0.0-windows-arm64-unsupported.zip",
                 "Zenith-1.0.0-source.zip", "Zenith-1.0.0-linux-arm64-unsupported.zip"):
        check(len(vp(name, ["Zenith-1.0.0/" + n for n in AMD_FILES])) == 1, f"{name} may not hold vendor files")
    check(vp("Zenith-1.0.0-linux.zip", ["Zenith-1.0.0/Zenith.x86_64", "Zenith-1.0.0/docs/vendor.md"]) == [],
          "a file only named vendor.md is not a vendor file")
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        bad = tmp / "Zenith-1.0.0-linux.zip"
        _mk_zip(bad, ["Zenith-1.0.0-linux/" + n for n in AMD_FILES])
        check(leak_scan.main([str(bad)]) == 1, "leak_scan fails a Linux zip with vendor files")
        good = tmp / "good" / "Zenith-1.0.0-windows.zip"
        good.parent.mkdir()
        _mk_zip(good, ["Zenith-1.0.0-windows/" + n for n in AMD_FILES])
        check(leak_scan.main([str(good)]) == 0, "leak_scan passes a Windows zip with the AMD set")
        nested = tmp / "nest"
        nested.mkdir()
        _mk_zip(nested / "Zenith-1.0.0-linux.zip", ["Zenith-1.0.0-linux/" + AMD_FILES[2]])
        check(leak_scan.main([str(nested)]) == 1, "leak_scan fails a zip found in a folder scan too")


def test_copy_vendor_runtimes():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        src, out = tmp / "src", tmp / "out"
        (src / "amd").mkdir(parents=True)
        out.mkdir()
        for n in list(fetch_vendor_runtimes.AMD_DLLS)[:1]:
            (src / "amd" / n).write_bytes(b"dll")
        try:
            package.copy_vendor_runtimes(src, out)
            check(False, "copy_vendor_runtimes stops when a file is missing")
        except SystemExit as e:
            check("lacks" in str(e) and not (out / "vendor").exists(), "copy_vendor_runtimes stops when a file is missing, copies nothing")
        for n in list(fetch_vendor_runtimes.AMD_DLLS) + [fetch_vendor_runtimes.AMD_LICENSE]:
            (src / "amd" / n).write_bytes(b"x")
        package.copy_vendor_runtimes(src, out)
        got = sorted(p.name for p in (out / "vendor" / "amd").iterdir())
        check(got == sorted(list(fetch_vendor_runtimes.AMD_DLLS) + ["license.md"]), f"the three AMD files are copied ({got})")
        check(not (out / "vendor" / "nvidia").exists(), "no nvidia folder")
    check(package.PRESETS["windows"][1] == "Zenith.exe", "windows preset unchanged")


def test_native_libraries():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        bin_dir, out = tmp / "bin", tmp / "out"
        bin_dir.mkdir()
        out.mkdir()
        got = package.copy_native_libraries(out, bin_dir)
        check(got == {"belt_sim": False, "upscalers": False} and not any(out.iterdir()),
              "no DLLs: nothing copied beside the program (as before)")
        (bin_dir / package.UPSCALERS_DLL).write_bytes(b"dll")
        got = package.copy_native_libraries(out, bin_dir)
        check(got == {"belt_sim": False, "upscalers": True}
              and sorted(p.name for p in out.iterdir()) == sorted(["upscalers.gdextension", package.UPSCALERS_DLL]),
              "the upscalers DLL and its .gdextension go beside the program")
        (bin_dir / package.NATIVE_DLL).write_bytes(b"dll")
        got = package.copy_native_libraries(out, bin_dir)
        check(got == {"belt_sim": True, "upscalers": True} and (out / "belt_sim.gdextension").is_file()
              and (out / package.NATIVE_DLL).is_file(), "belt_sim's too, both lines")
        check("upscalers.windows.template_release.x86_64.dll" in package.UPSCALERS_CONFIG.read_text(encoding="utf-8"),
              "upscalers.gdextension names the DLL package.py copies")
        empty = tmp / "empty"
        empty.mkdir()
        for template, vendor, should_fail in (("t.exe", None, True), (None, "v", True), ("t.exe", "v", True), (None, None, False)):
            failed = False
            try:
                package.require_upscalers(template, vendor, empty)
            except SystemExit as e:
                failed = "upscalers" in str(e)
            check(failed == should_fail, f"require_upscalers without the DLL: template={template} vendor={vendor} -> "
                  f"{'error' if should_fail else 'fine'}")
        package.require_upscalers("t.exe", "v", bin_dir)
        check(True, "require_upscalers with the DLL is fine")
        check(package.template_label(None) == "official", "BUILD.json template: official without --windows-template")
        tdir = tmp / "tpl"
        tdir.mkdir()
        exe = tdir / "windows_release_x86_64.exe"
        exe.write_bytes(b"x")
        check(package.template_label(str(exe)) == "our build: windows_release_x86_64.exe", "our build without BUILD.txt: its name")
        (tdir / "BUILD.txt").write_text("﻿Godot 4.7.2-stable (abc), BUILD_NAME zenith\nplatform=windows\n", encoding="utf-8")
        check(package.template_label(str(exe)) == "our build: Godot 4.7.2-stable (abc), BUILD_NAME zenith",
              f"our build: BUILD.txt's first line ({package.template_label(str(exe))})")
        check([package.vendor_label(None), package.vendor_label("v"), package.vendor_label("v", True)] == ["none", "amd", "amd+nvidia"],
              "BUILD.json vendor: none / amd / amd+nvidia")
        m = package.build_manifest("0.3.1", "public", [], "official", "amd")
        check(m["template"] == "official" and m["vendor"] == "amd" and list(m)[:4] == ["version", "channel", "template", "vendor"],
              "build_manifest records template and vendor")
        check(package.build_manifest("0.3.1", "public", [])["vendor"] == "none", "build_manifest defaults: vendor none")


NVIDIA_FILES = ["vendor/nvidia/" + n for n in ("sl.interposer.dll", "sl.common.dll", "sl.dlss.dll", "zenith-sl-manifest.txt")]


def test_nvidia_vendor_rules():
    top = "Zenith-1.0.0-windows/"
    vp = leak_scan.vendor_problems
    sl = [top + n for n in NVIDIA_FILES]
    check(len(vp("Zenith-1.0.0-windows.zip", [top + n for n in AMD_FILES] + sl)) == 4,
          "Streamline's files fail without BUILD.json saying nvidia (one problem a file)")
    check(vp("Zenith-1.0.0-windows.zip", [top + n for n in AMD_FILES] + sl, True) == [],
          "exactly Zenith's Streamline build passes when BUILD.json ships nvidia")
    check(len(vp("Zenith-1.0.0-windows.zip", sl + [top + "vendor/nvidia/nvngx_dlss.dll"], True)) == 1,
          "nvngx_dlss.dll never passes, even with nvidia shipped")
    check(len(vp("Zenith-1.0.0-windows.zip", sl + [top + "vendor/nvidia/sub/x.dll"], True)) == 1, "nor any other nvidia file")
    check(len(vp("Zenith-1.0.0-windows.zip", sl[:3], True)) == 1, "part of the Streamline build fails")
    check(len(vp("Zenith-1.0.0-linux.zip", ["Zenith-1.0.0/" + n for n in NVIDIA_FILES], True)) == 1,
          "a Linux zip may not hold them, whatever BUILD.json says")
    check([leak_scan.build_ships_nvidia(b) for b in (None, b"", b"{", b'{"vendor": "amd"}', b'{"vendor": "none"}',
                                                     b'{"vendor": "amd+nvidia"}', b'{"vendor": "nvidia"}', b'[1]')]
          == [False, False, False, False, False, True, True, False], "build_ships_nvidia reads BUILD.json's vendor")
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        for label, build, want in (("amd+nvidia", b'{"vendor": "amd+nvidia"}', 0), ("amd", b'{"vendor": "amd"}', 1),
                                   ("no BUILD.json", None, 1)):
            z = tmp / label / "Zenith-1.0.0-windows.zip"
            z.parent.mkdir()
            with zipfile.ZipFile(z, "w") as zf:
                for n in AMD_FILES + NVIDIA_FILES:
                    zf.writestr("Zenith-1.0.0-windows/" + n, b"x")
                if build is not None:
                    zf.writestr("Zenith-1.0.0-windows/BUILD.json", build)
            check(leak_scan.main([str(z), "--allow-nvidia"]) == want, f"leak_scan --allow-nvidia on a Windows zip with "
                  f"Streamline, BUILD.json {label}: {'clean' if want == 0 else 'fails'}")
            # (rel-031-fix3, Should 4) The zip's own word is never enough: without the scan's yes it fails.
            check(leak_scan.main([str(z)]) == 1, f"leak_scan without --allow-nvidia fails a Windows zip with "
                  f"Streamline, BUILD.json {label}")
        # a BUILD.json deeper in (an add-on's) doesn't count
        z = tmp / "deep" / "Zenith-1.0.0-windows.zip"
        z.parent.mkdir()
        with zipfile.ZipFile(z, "w") as zf:
            for n in NVIDIA_FILES:
                zf.writestr("Zenith-1.0.0-windows/" + n, b"x")
            zf.writestr("Zenith-1.0.0-windows/addons/BUILD.json", b'{"vendor": "amd+nvidia"}')
        check(leak_scan.main([str(z), "--allow-nvidia"]) == 1, "only the download's own top BUILD.json counts")


def test_copy_nvidia_runtimes():
    import hashlib
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        src, out = tmp / "src", tmp / "out"
        built = src / "streamline-built"
        built.mkdir(parents=True)
        out.mkdir()
        try:
            package.copy_nvidia_runtimes(src, out)
            check(False, "copy_nvidia_runtimes stops when files are missing")
        except SystemExit as e:
            check("lacks" in str(e) and not (out / "vendor").exists(), "copy_nvidia_runtimes stops when files are missing")
        dlls = ("sl.interposer.dll", "sl.common.dll", "sl.dlss.dll")
        for n in dlls:
            (built / n).write_bytes(n.encode())
        (built / "nvngx_dlss.dll").write_bytes(b"nvidia's own")
        (built / "BUILD.txt").write_text("build notes", encoding="utf-8")
        lines = ["# Zenith's self-built Streamline. sha256  file"]
        lines += [f"{hashlib.sha256(n.encode()).hexdigest()}  {n}" for n in dlls]
        (built / "zenith-sl-manifest.txt").write_text("\n".join(lines[:-1]) + "\n0000  sl.dlss.dll\n", encoding="ascii")
        try:
            package.copy_nvidia_runtimes(src, out)
            check(False, "a DLL not matching the manifest stops the copy")
        except SystemExit as e:
            check("SHA-256" in str(e) and not (out / "vendor").exists(), "a DLL not matching the manifest stops the copy")
        (built / "zenith-sl-manifest.txt").write_text("\n".join(lines) + "\n", encoding="ascii")
        package.copy_nvidia_runtimes(src, out)
        got = sorted(p.name for p in (out / "vendor" / "nvidia").iterdir())
        check(got == sorted(list(dlls) + ["zenith-sl-manifest.txt"]),
              f"the Streamline build's four files are copied, not nvngx_dlss.dll or BUILD.txt ({got})")
    check(package.vendor_label("v", False) == "amd", "without --ship-nvidia BUILD.json says amd")


def test_default_pack_matches_owner_zip():
    """DEFAULT_PACK is the pack.json of the models/Zenith.zip the owner uses (when this checkout has one; git-ignored)."""
    import json
    desc = package.DEFAULT_PACK["description"]
    check("stone walls, gate" in desc and "science packs" in desc, "DEFAULT_PACK's description lists walls, gate and item kinds (0.3.1)")
    owner = package.ROOT / "models" / package.BUNDLED_ZIP
    if not owner.is_file():
        print("skip DEFAULT_PACK against models/Zenith.zip (none in this checkout)")
        return
    with zipfile.ZipFile(owner) as z:
        theirs = json.loads(z.read("pack.json").decode("utf-8"))
    check(theirs == package.DEFAULT_PACK, "DEFAULT_PACK equals models/Zenith.zip's pack.json"
          + ("" if theirs == package.DEFAULT_PACK else f" (differs: {sorted(k for k in set(theirs) | set(package.DEFAULT_PACK) if theirs.get(k) != package.DEFAULT_PACK.get(k))})"))


def test_fetch_vendor_runtimes():
    f = fetch_vendor_runtimes
    check(all(len(d) == 64 for _, d in f.AMD_FILES.values()) and len(f.AMD_ARCHIVE_SHA256) == 64, "pinned SHA-256s are 64 hex")
    check(sorted(n for n, _ in f.AMD_FILES.values()) == sorted(list(f.AMD_DLLS) + [f.AMD_LICENSE]),
          "fetch names match the names package.py and the leak scan expect")
    check(f.AMD_URL.startswith("https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/"), "downloads only from AMD's GitHub")
    try:
        f.download("https://example.com/x.zip", pathlib.Path("never"))
        check(False, "download refuses other hosts")
    except ValueError:
        check(True, "download refuses other hosts")
    # Fake archive with fake pins: checked, extracted, idempotent offline.
    import hashlib
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        blobs = {m: (b"data-" + n.encode()) for m, (n, _) in f.AMD_FILES.items()}
        arc = tmp / "a.zip"
        with zipfile.ZipFile(arc, "w") as z:
            for m, b in blobs.items():
                z.writestr(f.AMD_PREFIX + m, b)
        old = (dict(f.AMD_FILES), f.AMD_ARCHIVE_SHA256)
        try:
            f.AMD_FILES = {m: (n, hashlib.sha256(blobs[m]).hexdigest()) for m, (n, _) in old[0].items()}
            f.AMD_ARCHIVE_SHA256 = f.sha256_file(arc)
            dest = tmp / "dest"
            check(not f.amd_present(dest), "nothing present before")
            f.extract_amd(arc, dest)
            check(f.amd_present(dest), "extract writes the three files and the checksums match")
            check(f.fetch_amd(dest, url="https://invalid.invalid/never") == "present", "fetch is a no-op (no network) when present")
            (dest / "amd" / "license.md").write_bytes(b"changed")
            check(not f.amd_present(dest), "a changed file is not 'present'")
            f.AMD_FILES = {m: (n, "0" * 64) for m, (n, _) in old[0].items()}
            d2 = tmp / "d2"
            try:
                f.extract_amd(arc, d2)
                check(False, "a wrong file hash stops extraction")
            except ValueError:
                check(not (d2 / "amd").exists(), "a wrong file hash stops extraction, nothing written")
        finally:
            f.AMD_FILES, f.AMD_ARCHIVE_SHA256 = old


if __name__ == "__main__":
    test_items_folder()
    test_no_items_folder()
    test_only_items()
    test_leak_scan_clean_and_hits()
    test_build_manifest_and_version_validation()
    test_windows_template_option()
    test_vendor_rules()
    test_copy_vendor_runtimes()
    test_fetch_vendor_runtimes()
    test_native_libraries()
    test_nvidia_vendor_rules()
    test_copy_nvidia_runtimes()
    test_default_pack_matches_owner_zip()
    print(f"{len(FAILS)} fail(s)")
    sys.exit(1 if FAILS else 0)
