# tools/godot — Zenith's own Godot export template

Zenith's Windows x86_64 download can be exported with a Godot release template built here from Godot's
source, instead of the official one. Step 1 of the vendor-upscaler plan (AMD FSR 4, later DLSS) needs this:
the upscaler hook is a small engine patch, so Windows needs a template we build ourselves. Linux, macOS and
ARM keep the official templates.

```powershell
powershell -ExecutionPolicy Bypass -File tools\godot\build_template.ps1            # build (or rebuild)
python tools\release\package.py --windows-template "<build dir>\out\4.7.2\windows_release_x86_64.exe"
powershell -ExecutionPolicy Bypass -File tools\godot\hook_window_test.ps1 -Godot <editor exe>   # the hook, in a window
powershell -ExecutionPolicy Bypass -File tools\godot\fsr_window_test.ps1 -Godot <editor exe>    # AMD FSR 3.1, in a window
```

- **Pinned source:** Godot `4.7.2-stable`, commit `ed1daf0bf001b61586d9930840f2f1394092c079`, checked
  before every build; the script refuses to build anything else. Godot's licence is MIT.
- **Where:** `art-src\godot-build\` of the main checkout (git-ignored; `-BuildDir` to move it): `godot-4.7.2\`
  (the source and its build objects), `deps\` (Godot's own install scripts' downloads: Mesa NIR, the
  DirectX 12 Agility SDK and PIX for Direct3D 12, AccessKit, ANGLE), `out\4.7.2\` (the template,
  `_console.exe`, `BUILD.txt`) and the build log. Nothing of it is committed.
- **Patches:** every `*.patch` in [`tools/godot-patches/4.7.2/`](../godot-patches/4.7.2/README.md), applied
  in name order after the source is put back to the tag: the upscaler hook (custom scaling mode backport,
  native command-list callbacks, upscaler inputs; step 2). The stock template of step 1 is kept in
  `out\4.7.2-stock\` for comparisons.
- **Build:** MSVC (Visual Studio's `vcvars64.bat`, found with `vswhere`), SCons from the repo's `.venv`,
  `platform=windows target=template_release arch=x86_64 production=yes d3d12=yes vulkan=yes`,
  `BUILD_NAME=zenith` (so `--version` says `4.7.2.stable.zenith.ed1daf0bf`).
- **No user paths in the binary:** `/d1trimfile` cuts the source and dependency folders off `__FILE__`, as
  `client/native/belt_sim` does (passed through `CL` and SCons' `import_env_vars`).
- **Kind to the PC:** below-normal priority; jobs = cores - 4, fewer if that would leave less than 8 GB RAM
  available (`-Jobs`, `-MinFreeGB`, `-GBPerJob`); it refuses to start when even one job would. Stopping a
  build part-way is safe: the next run carries on from the objects already built.
- **Needs:** Visual Studio with the C++ workload, git, Python with `scons` (`.venv`), about 3.5 GB of disk
  (source and objects 2.0 GB, dependencies 1.3 GB). A full build took about 37 minutes of compiling with
  1-2 jobs.
- **Known difference from the official template:** Godot's prebuilt AccessKit library for MSVC carries
  a `C:\Users\` path of GitHub's Windows build machine (`runneradmin`, not a person) in its panic messages, and
  `tools/release/leak_scan.py` flags it; the official template's AccessKit (built on Linux) has `/home/runner/...`
  instead. Until that is settled, a release zip exported with this template fails the leak scan.

## The upscaler hook's window test

`hook_window_test.ps1` exports `hook_test/` (a tiny project, not Zenith) with the patched template and the
upscalers DLL, and runs it on Direct3D 12 with the debug layer (`--gpu-validation`), muted, with its own log:
Bilinear at scale 1.0 as the reference, then `ZenithHookUpscaler` (a plain native copy through the hook) at 1.0
(must match the reference) and 0.5 (the output's top-left quarter gets the picture), then back. It passes
with zero debug-layer errors, pictures that aren't black, and the callback's figures (`result.json`). It opens
a window for about half a minute: only when nobody is using the PC. `-HeadlessOnly` checks just that the
export starts and the hook is in the build. Needs Windows' optional feature "Graphics Tools" for the debug
layer.
