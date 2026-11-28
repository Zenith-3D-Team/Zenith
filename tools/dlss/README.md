# NVIDIA DLSS: Zenith's own Streamline build

Zenith draws NVIDIA DLSS Super Resolution through NVIDIA Streamline (MIT, github.com/NVIDIA-RTX/Streamline), built
here from its source **with the updater taken out**. NVIDIA's own signed Streamline DLLs start NVIDIA's updater
(`nvngx_update.exe -api update`) at every `slInit` on a PC with an NVIDIA card, whatever the OTA flags say (Streamline
v2.14.16, `pluginManager.cpp` `loadPlugins()`), so Zenith doesn't use them. The NVIDIA DLSS model itself,
`nvngx_dlss.dll`, stays NVIDIA's: the player downloads it from NVIDIA and Zenith only loads it when it carries
NVIDIA's signature.

Nothing here is committed but our script, patches and this file: no Streamline binaries, no NGX or NVAPI files, no
NVIDIA DLLs. The built DLLs link NVIDIA's closed NGX SDK and NVAPI static libraries (Streamline's `external/` folder),
so they fall under NVIDIA's terms, not the GPL; they are for local testing until the owner decides about shipping.

## Finding: NVIDIA's driver starts its own updater anyway

Our build does what it should: Streamline starts nothing and loads nothing downloaded (`sl_init_probe.ps1`, below).
But on an RTX 5080 with NVIDIA driver 32.0.16.2101, as soon as Streamline's DLSS plugin starts, Streamline asks NGX
for DLSS's requirements (`NVSDK_NGX_D3D12_GetFeatureRequirements`, NVIDIA's closed NGX library linked into
`sl.common.dll`), which loads the driver's NGX runtime, and **the driver's runtime starts
`nvngx_update.exe -api update -cmsid <n> -feature dlss|dlssd|dlssg -bootstrap -gpuarch 352`** (from the driver's
DriverStore folder) about 15 times, with our process as the parent; one run caught one of them connected to port 443
of an outside address. With the DLSS plugin refused, nothing starts. The command line is the driver's, not
Streamline's (Streamline's own was `-feature sl_sdk_2 -type zip`), there is no such string in our DLLs or the NGX
library, and NGX's published headers have no switch to turn it off. Any DLSS through NGX (Streamline or raw NGX)
has to initialise NGX, so this can't be patched out here.

**The owner's decision (`alt/dlss-s7c`): ask the player first.** DLSS is off until the player says yes to a prompt
that names NVIDIA's updater (Settings > Graphics > Upscaling; `[graphics] dlss_consent`, Withdraw under Upscaling,
`--dlss-consent=yes|no` for one run). Before that Zenith loads none of these DLLs and asks NGX nothing: only the
files' presence is checked. `consent_proof.ps1 -Godot <our godot.exe>` proves it headless: a Zenith start with
`--upscaler=dlss` and no OK has no `sl.*.dll` / `nvngx*.dll` loaded and starts no `nvngx_update.exe`; the same start
with `--dlss-consent=yes` loads `sl.interposer.dll` (results in `art-src/dlss-consent-proof/result.json`). Zenith never
blocks, renames or patches NVIDIA's updater or driver.

## Build

```powershell
powershell -ExecutionPolicy Bypass -File tools\dlss\build_streamline.ps1            # -Jobs 4, -OutDir <dir>
```

1. Clones Streamline at tag `v2.14.16`, checks the commit (`625db07d4bca5abc67d781c42af7e7fb0761f1b6`) and its Git
   LFS libraries (Git LFS is needed), into the main checkout's git-ignored `art-src/streamline-build/src`.
2. Applies `patches/*.patch` in order:
   - `0001-no-ota-no-updater.patch`: `loadPlugins()` no longer calls `readServerManifest()` / `checkForOTA()` (the
     update check that starts `nvngx_update.exe`); the block that loads downloaded (OTA) plugins is compiled out
     (also the driver's "OTA override" key path); `OTA::invokeNGXUpdater()` never starts a process; NGX's
     `NVSDK_NGX_UpdateFeature` is never called. The script then greps the source to check no such call is left.
   - `0002-zenith-sha256-manifest.patch`: Streamline loads its plugins through `security::loadLibrary()`, which in
     production builds wants NVIDIA's signature. Ours aren't signed, so it loads a module only when its SHA-256 and
     file name are in `zenith-sl-manifest.txt` beside it (the file is held open without write sharing from hashing
     to loading). `include/sl_security.h` is untouched. Its `verifyEmbeddedSignature` can't check NVIDIA's
     `nvngx_dlss.dll` (it wants a second signature made with Streamline's own key, which only Streamline's DLLs
     carry), so Zenith checks that file with Windows' Authenticode check (no network) and a signer organisation of
     NVIDIA Corporation.
   - `0003-build-paths-with-spaces.patch`: quotes the paths in `premake.lua`'s custom build steps (build only).
3. Fetches the three build tools these DLLs need with Streamline's own packman, at the versions pinned in its
   `project.xml`: premake `5.0.0-beta1+nv1`, Vulkan SDK `1.3.231.1-ext` (headers), slang `0.27.21` (shader
   compiler). Packman itself comes from NVIDIA's bootstrap host (its Python 3.7, 7-Zip). The cache stays in
   `art-src/streamline-build/packman-repo`; `PM_PACKAGES_ROOT` is set for the run only, so packman doesn't `setx` it.
4. Generates the Visual Studio solution (`premake5 vs2022 --with-nvllvk=no`: no closed Vulkan Reflex library) and
   builds `sl.interposer`, `sl.common`, `sl.dlss` in Streamline's Production configuration with the installed MSVC
   (toolset v145 on VS 2026, v143 on VS 2022), at below-normal priority, keeping `-MinFreeGB` (8) of RAM free and
   stopping its own build if free RAM falls under `-AbortFreeGB` (3).
5. Copies the three DLLs to `art-src/vendor-runtimes/streamline-built/` with `zenith-sl-manifest.txt` (their
   SHA-256s) and `BUILD.txt` (commit, patches' SHA-256s, MSVC, packages).

The DLLs need the Microsoft Visual C++ 2015-2022 runtime (`MSVCP140.dll`, `VCRUNTIME140*.dll`), as most games do.

Packman makes three directory junctions in the source folder (`external\vulkan`, `external\slang`,
`tools\premake5`) into `packman-repo`. To delete the build folder, remove those as links first
(`cmd /c rmdir <link>` without `/s`, or `tools/safe_delete.py`), never `Remove-Item -Recurse` on the folder.

## Install (for a test, or a player)

Into Zenith's `vendor\nvidia\` beside the program (or the folder `--vendor-dir=<dir>` names, `<dir>\nvidia`; a project
run also looks in the main checkout's `art-src\vendor-runtimes\nvidia`):

| File | From |
| --- | --- |
| `sl.interposer.dll`, `sl.common.dll`, `sl.dlss.dll`, `zenith-sl-manifest.txt` | this build (`art-src\vendor-runtimes\streamline-built\`) |
| `nvngx_dlss.dll` | NVIDIA: github.com/NVIDIA/DLSS, release **v310.9.16** (released with Streamline v2.14.16), file `lib/Windows_x86_64/rel/nvngx_dlss.dll` (58,956,912 bytes, signed by NVIDIA) |

Zenith checks each of our three DLLs against the manifest, checks `nvngx_dlss.dll`'s NVIDIA signature, and only then
loads `sl.interposer.dll`. `slInit` gets `eUseManualHooking | eDisableCLStateTracking` only (never `eAllowOTA` or
`eLoadDownloadedPlugins`), engine type custom with Zenith's own project id, no NVIDIA application id, no log file.

## Test

`tools/godot/dlss_window_test.ps1` (needs an RTX card and a window; see its header): our Godot build, DLSS at DLAA,
Quality and Performance, the D3D12 debug layer, non-black pictures, and a watcher for network connections and child
processes (no `nvngx_update.exe`). Headless checks: `client/tests/upscalers_test.gd`.
