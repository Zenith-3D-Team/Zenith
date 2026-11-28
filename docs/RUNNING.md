# Running Zenith

Three pieces work together:

1. **Factorio 2.1** (usually headless with no window) runs the simulation.
2. **`factorio-3d-bridge`** (`mod/factorio-3d-bridge/`) streams state over localhost UDP and controls a character for the client.
3. **The Godot client** (`client/`) renders the 3D world and UI and sends input back.

Requires **Godot 4.7+** and **Factorio 2.1** (the mod declares `"factorio_version": "2.1"`). Python 3.9+ (`pip install -r requirements-dev.txt` in `.venv`) is only needed for the mock server, model tools, and automated tests.

On a fresh checkout, import assets once before opening or running headless tests:

```bash
godot --headless --audio-driver Dummy --path client --import
```

---

## Start here: the client's menu

Run `godot --path client` (or press **F5** in Godot). The main menu sits over a live 3D scene (`client/data/menu_world.json`, recorded from a vanilla Space Age factory; see `tools/make_menu_backdrop.py`).

### Main menu modes

- **Continue:** Loads the last played server save.
- **Single player → New game:** Full Factorio map generator (presets, resources, terrain, enemies, advanced, map preview via `--generate-map-preview`). Creates the map with `factorio --create` and connects automatically.
- **Single player → Load game:** Lists `server/saves/*.zip` plus your Factorio saves (`%APPDATA%\Factorio\saves` on Windows). Loading a Factorio save copies it first so the original is untouched.
- **Single player → Single-player (hybrid):** Connects to your own windowed Factorio launched with `--enable-lua-udp 34200`.
- **Multiplayer → Host new / Host saved game:** Starts Factorio bound to `34197` (or custom port) so friends can join with standard Factorio while Zenith drives the bridge's character. RCON and UDP bridge stay on `127.0.0.1`.
- **Multiplayer → Connect to address:** Joins a running bridge (`127.0.0.1:34200`) or a LAN relay (`<host>:34200`).
- **Mods / Model packs / Menu backdrop / Add-ons / Settings / About:** Toggle server mods, reorder model packs (`FUE5`, `Wube3DP`, `Placeholders`, `Factorio`, plus `models/` packs), manage saved menu backdrops in `user://backdrops/`, enable add-ons (`addons/`), and configure settings.

> [!CAUTION]
> **Windows directory junctions:** `server/data/mods/factorio-3d-bridge` is a Windows junction pointing to `mod/factorio-3d-bridge`. Never run `Remove-Item -Recurse` or unguarded recursive deletes on `server/data`, or Windows will delete the repo's mod files. Unlink first with `cmd /c rmdir <link>` or delete via `tools/safe_delete.py`.

### Settings, persistence & in-game console

- **Settings tabs:** *Graphics* (presets, Recommended check, Renderer on Windows (Direct3D 12 by default, Vulkan as before 0.3.1; `--rendering-driver vulkan` for one start), AMD FSR 2.2 / FSR 1.0, Distant Horizon, view/belt/decorative distances, shadows, SSAO, contact shading, Factorio Look vs pack PBR), *Sound*, *Controls* (Factorio 2.1 keys by default, toggleable back to `Zenith 0.2.2's keys`), *Interface*, *Other* (server autosaves & window minimize on `Ctrl+F9`), *Mod settings* (bridge settings over RCON), *Camera*, *Factorio install*, and *Add-ons*. See [USER-GUIDE.md](USER-GUIDE.md#settings-worth-knowing) for descriptions and [SWITCHES.md](SWITCHES.md) for CLI `--flag` overrides.
- **Persistence:** All client settings live in `user://settings.cfg` (`%APPDATA%\Godot\app_userdata\Zenith\settings.cfg`). On startup, defaults sync from Factorio's `config.ini` unless disabled in Settings → Factorio install (`--factorio-config` / `--settings-file` override this).
- **Menu launching:** Starting a server from the menu runs Factorio headless on dynamic ports starting at `34500` (configurable in Settings → Factorio install), keeping RCON on `127.0.0.1` (`server/data/rcon-password.txt`), and attaches a crash watchdog so the server stops cleanly if the client dies.
- **In-game console (`` ` `` or `/`):** Runs `/help` chat commands locally, `/cheat` and `/f3d-*` through the bridge (admin-restricted in multiplayer), RCON commands when hosted by the menu, or instructs you to press `Ctrl+F9` for commands that require a real Factorio window (`/editor`, `/screenshot`).

For headless test/screenshot menu automation flags (`--no-menu`, `--menu=...`, `--menu-launch`, etc.), see [SWITCHES.md](SWITCHES.md#menu-backdrop-automation--channels).

### The download

Build distributable zips with `tools/release/package.py` (requires Godot export templates matching the project version):

```bash
python3 tools/release/package.py                    # dist/Zenith-<version>-windows.zip (public)
python3 tools/release/package.py --platform linux   # supported: windows, linux
python3 tools/release/package.py --channel dev      # the testing build (keeps debug menu & perf test)
python3 tools/release/build_mod_zip.py              # dist/factorio-3d-bridge_<version>.zip only
```

- **Packaging channels:** `--channel public` strips `Settings.dev_tools()` UI (Debug menu `Ctrl+F12`, Performance test) and `<!-- dev -->` doc blocks; `--channel dev` injects the `zenith_dev` export feature tag. Unsupported targets (`linux-arm64`, `windows-arm64`, `macos`) append `-unsupported.zip` with `UNSUPPORTED.txt`.
- **Modeller packs (`Zenith.zip`):** Pass `--models <dir>` to `package.py` (or `--zenith-zip <out.zip>`) to bundle a modeller's pack into `models/Zenith.zip` (loaded above built-in packs by default).
- Exported zips store server saves and settings under the OS user-data directory rather than the install folder, migrating prior `server/saves` and `server/data/mods` on first launch.

---

## Quick start without Factorio (mock server)

Work on the client or preview content without a Factorio install:

```bash
python3 tools/mock_server.py
godot --path client -- --factorio-port=34200
```

Useful mock flags include `--day-length 1200` (20 s day cycle), `--start <x,y>`, `--belt-field 24x16`, `--item-showcase`, `--turrets`, `--planet vulcanus|fulgora|gleba|aquilo`, `--platform`, and `--auto-launch`. All mock and paired client preview flags are listed in [SWITCHES.md](SWITCHES.md#factorio-server-relay--mock-server). Note that Windows UDP socket buffers cap mock burst sizes (~64 KB / ~3,000 items).

---

## Headless Factorio (the main setup)

### Launching manually

**Linux** (downloads Factorio's free headless build once):

```bash
server/download-headless.sh
server/run-headless.sh                  # new save in server/saves/world.zip
server/run-headless.sh ~/my-base.zip    # existing save
```

**Windows** (uses your local Factorio install headlessly):

```powershell
powershell -ExecutionPolicy Bypass -File server\run-server.ps1
powershell -ExecutionPolicy Bypass -File server\run-server.ps1 -Save C:\path\to\my-base.zip
```

Pass `-Factorio <path>` if Steam/default discovery misses `factorio.exe`. Stop background servers cleanly with `python tools/rcon.py /quit`. Both launchers isolate data in `server/data/`, link `mod/factorio-3d-bridge`, bind UDP `34200`, bind game `34197` / RCON `34198` on `127.0.0.1`, and disable `auto_pause`.

### Characters, corpses & joining from Factorio

- **Save character takeover:** On a server with no human player online, `takeover.lua` spawns a stand-in character at your last player's location (or `/f3d-player <name>`, `f3d-player` map setting) with their inventory, armor, guns, logistics, crafting queue, and quickbar. When that player joins in normal Factorio, everything transfers back seamlessly.
- **Corpses:** Dead character items stay in a mineable `character-corpse` with a map/minimap skull marker (`f3d-character-corpses` toggles this).
- **Chunk copies on disk:** Zenith keeps chunks it has drawn in `user://chunk-cache/` and asks the bridge whether each is still current by its change count. The bridge raises a chunk's count to the tick of the change (map setting `f3d-rev-ticks`, on), so reloading a save and playing it differently can't bring back another play's copy (a removed pole standing on as a stick by an inserter). Off: counted by one, as before. Caches from before this (format 1) are dropped once.
- **Zenith-made worlds & freeplay:** Worlds started in Zenith suppress Factorio's freeplay crash-site intro (`set_disable_crashsite`) so joining later with Factorio won't drop a burning ship on your spawn. Pressing `Ctrl+F9` sends your Factorio account username (`pn` from `player-data.json`, override with `--factorio-player`) so Factorio hands over Zenith's character to you.

### Your own dedicated server (`factorio --start-server <save>`)

Factorio's bridge processes packets inside `on_tick`, so a paused dedicated server ignores `hello` packets ("No answer from the bridge"):

1. Enable `factorio-3d-bridge` in the server's `mods/`.
2. Launch Factorio with `--enable-lua-udp 34200`.
3. In `server-settings.json`, set `"auto_pause": false` (and `"auto_pause_when_players_connect": false`).

Check state from RCON in the mod's own Lua context (plain `/c` runs in the level script, not the bridge):

```bash
python3 tools/rcon.py "/c __factorio-3d-bridge__ rcon.print(tostring(game.tick_paused))"
python3 tools/rcon.py /f3d-status
python3 tools/live_check.py    # close Godot client first; supports --only <section>
```

### Space platforms (Space Age)

Build a rocket silo, load a rocket, open the silo (or press `Enter`), and click **Ride** by an orbiting platform—Zenith tracks the full ascent, cargo pod landing, hub occupancy (WASD pans, ghost building works), and **Drop to a planet**. From the **Space map** (top of the remote view's Surfaces panel) you can inspect routes, hazards, and create new platforms.

RCON shortcuts for testing Space Age without building a silo:

```bash
python3 tools/rcon.py /f3d-platform new        # create orbiting starter platform
python3 tools/rcon.py /f3d-platform board 1    # teleport to platform 1
python3 tools/rcon.py /f3d-platform leave      # return to surface
python3 tools/rcon.py /f3d-platform            # list platforms
```

Mock testing flags (`--planet`, `--platform`, `--plat-board`, `--ride`, `--land`, `--auto-launch`) are in [SWITCHES.md](SWITCHES.md#factorio-server-relay--mock-server).

### Watching with the normal game

- **Join with Factorio:** Connect a standard Factorio client to `127.0.0.1:34197` (or the menu-assigned port ~`34501`).
- **`Ctrl+F9` handoff:** In Zenith, `Ctrl+F9` brings up (or launches via `--mp-connect`) your Factorio window attached to the same server. Inside Factorio, `Ctrl+F9` ("Show in Zenith") switches back and minimizes Factorio (Factorio keeps running at 60 UPS while minimized).
- **Starting Zenith from Steam/Factorio:** Set Factorio's Steam launch options to the line copied from **Settings → Other → Copy launch options**:
  ```
  powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\ProgramData\Zenith\factorio-with-zenith.ps1" %command%
  ```
  Open Zenith once first so it installs the wrapper script into `C:\ProgramData\Zenith`.
- **Modded saves:** Loading a save from the menu links Factorio mods into `server/data/mods`, runs `factorio --sync-mods <save>`, and layers mods enabled in Zenith's Mods window on top (tick **Sync mods with save** or pass `--load-mods=save` to keep strictly the save's mods).

### Several 3D clients on one server

Launch another Zenith client on the same machine and connect to the same bridge port; it automatically binds the next free client port (`34202`–`34208`, up to 8 clients) and receives its own character. A crashed client's character is held for 10 s and reclaimed by a reconnecting client on a new port once the old port goes silent for `>= 4` s.

---

## Server on another PC

Factorio's `--enable-lua-udp` only listens on `127.0.0.1`, so `server/relay.py` (standard-library Python 3.8+) bridges LAN TCP (`34200`) to local UDP sockets on the server host—avoiding UDP fragmentation/drop issues on large `60 KB` bridge datagrams.

1. **On the server PC**, start headless Factorio (`server/run-headless.sh` or `server\run-server.ps1`).
2. **On the same PC**, start the relay:
   ```bash
   python3 server/relay.py                    # LAN/local subnets on TCP 34200
   python3 server/relay.py --rcon-port 34198  # optional: forward RCON for pause/save
   ```
3. **Allow TCP `34200` on your local subnet firewall only** (Windows: `New-NetFirewallRule -DisplayName "Zenith relay" -Direction Inbound -Protocol TCP -LocalPort 34200 -RemoteAddress LocalSubnet -Action Allow`; Linux ufw: `sudo ufw allow from 192.168.1.0/24 to any port 34200 proto tcp`).
4. **On your playing PC**, choose **Multiplayer → Connect to address → `<server-ip>:34200`**, or start Zenith with `-- --factorio-host=<server-ip>` (use `--relay` to test relay framing on `127.0.0.1`). Verify connectivity with `python3 tools/relay_check.py --relay <server-ip>:34200 --reconnect`.

> [!WARNING]
> **Security:** The relay accepts clients without a password (`--allow` restricts to private LAN subnets by default) and grants admin-tier `/cheat` and `/f3d-*` console commands over the relay. **Never** forward TCP `34200` to the public internet or pass `--allow any` on an exposed host.

Note: Your playing PC still needs a matching Factorio install for textures/sounds and local copies of any active mods (`%APPDATA%\Factorio\mods` or `--factorio-mods=<dir>`). On Linux relay hosts with busy bases, raise the UDP buffer cap if warned: `sudo sysctl -w net.core.rmem_max=8388608`. Relay CLI options (`--port`, `--host`, `--bridge-port`, `--allow`, `--rcon-port`, `--max-clients`, `--timeout`, `--keep`, `--max-buffer`, `--log`, `-v`) are detailed in [SWITCHES.md](SWITCHES.md#factorio-server-relay--mock-server).

---

## Single-player (hybrid mode)

Run Zenith directly alongside your normal Factorio window (played on Windows with Factorio 2.1.24; less battle-tested than headless server mode):

1. Copy or link `mod/factorio-3d-bridge` into `%APPDATA%\Factorio\mods` (Windows) or `~/.factorio/mods` (Linux).
2. Add `--enable-lua-udp 34200` to Factorio's launch options.
3. Load a save in Factorio, then start Zenith → **Single player → Single-player (hybrid) → Connect** (`127.0.0.1:34200`).

Factorio's own UI and Zenith's 3D screens/quickbar share your character. Run `/f3d-selftest` in Factorio's console (`~`) to verify permissions, aim, quickbar, and UDP replies.

---

### What the bridge costs

Moved to [SWITCHES.md](SWITCHES.md#what-the-bridge-costs) (includes `/f3d-perf` and `/f3d-bs` switch tables).

## Client controls

Moved to [SWITCHES.md](SWITCHES.md#client-controls).

## Add-ons

Moved to [SWITCHES.md](SWITCHES.md#add-ons).

## VR (experimental)

Moved to [SWITCHES.md](SWITCHES.md#vr-experimental).

## Sky and clouds

Moved to [SWITCHES.md](SWITCHES.md#sky-and-clouds).

## Looks

Moved to [SWITCHES.md](SWITCHES.md#looks).

## Decoratives

Moved to [SWITCHES.md](SWITCHES.md#decoratives).

## Trees and rocks

Moved to [SWITCHES.md](SWITCHES.md#trees-and-rocks).

## Creatures' skins

Moved to [SWITCHES.md](SWITCHES.md#creatures-skins).

## Chunk streaming: the view's direction, the area cache

Moved to [SWITCHES.md](SWITCHES.md#chunk-streaming-the-views-direction-the-area-cache).

## Mod settings

Moved to [SWITCHES.md](SWITCHES.md#mod-settings).

## Troubleshooting

Moved to [TROUBLESHOOTING.md](TROUBLESHOOTING.md#troubleshooting).

## Upscaling

Settings > Graphics > Upscaling (`graphics.upscaler`, `--upscaler=` for one run): Bilinear, FSR 1.0 and FSR 2.2
(Temporal, the default) as before, plus **AMD FSR 4.1** (`fsr4`, aliases `fsr4.x`, `amd`; Radeon RX 6000 or newer), **AMD FSR 3.1** (`fsr3`, alias
`fsr3.x`; any GPU), **NVIDIA DLSS** (`dlss`) and **Automatic** (`auto`: DLSS on an RTX card on Direct3D 12 once the
player has said yes to NVIDIA's updater, below, else FSR 4.1 on a supported Radeon, else FSR 3.1, else FSR 2.2).
The vendor entries need a Zenith build with the engine hook (Windows exported with our patched template,
below) and the vendors' runtime in `vendor/` beside
`Zenith.exe` (AMD: `vendor/amd/amd_fidelityfx_loader_dx12.dll`, `amd_fidelityfx_upscaler_dx12.dll`, AMD's `license.md`);
without them they are greyed out with the reason ("Not in this build", "Needs Direct3D
12 (Graphics > Renderer)", "Needs an NVIDIA RTX graphics card", "Needs an AMD Radeon RX 6000 or newer"), and a saved
`fsr4`/`fsr3`/`dlss` that can't run draws with FSR 2.2 for the run (a saved `fsr4` or `dlss` draws with FSR 3.1 when
that can run) without changing the saved choice (the log says so once; with `--upscaler=` the start's log also says
which upscaler draws). **Upscaling quality** (Native AA 100%, Quality 67%, Balanced 59%, Performance 50%, Ultra
Performance 33%, Custom) sets Game render scaling for the vendor entries; it saves nothing of its own.

**AMD FSR 4.1 / 3.1** draw through the engine hook with AMD's own runtime (FSR SDK 2.4.0, `ZenithFsrUpscaler`,
`client/scripts/menu/fsr_host.gd`): the window goes to the hook's custom scaling mode, AMD's context is made on Godot's
Direct3D 12 device and its dispatch recorded into Godot's command list (colour, depth, motion vectors, jitter, reset,
camera, frame time; AMD's own exposure; Upscaler sharpness as AMD's sharpness). If AMD's context can't be made or
nothing is drawn in the first frames, the log says why and FSR 2.2 draws for the rest of the run. Switches:

| Switch | Effect |
| --- | --- |
| `--vendor-dir=<dir>` | the folder holding `amd/` (as a download's `vendor/`); `none`: no vendor upscalers. Default: `vendor/` beside the program, else (a project run, not an export) the main checkout's git-ignored `art-src/vendor-runtimes` (`tools/release/fetch_vendor_runtimes.py`) |
| `--fsr-driver-version=on` | let AMD's driver supply a newer FSR than `vendor/amd`'s; off (default): pinned to the shipped FSR 4.1.2 / 3.1.6 (the log says which version runs, once) |
| `--fsr-debug` | AMD's input checks on (its messages go to the log) |
| `--fsr-barriers=direct` | Direct3D 12 with enhanced barriers: hand Godot's texture layouts to AMD as states, instead of moving them through COMMON around AMD's dispatch (the default); a fallback for the window test |
| `--upscaler-mv=raw` | AMD FSR 3.1/4.1 and NVIDIA DLSS get Godot's velocity buffer as it is (before `alt/upscaler-fix`). Default: the pixels Godot's motion pass leaves at (-1, -1), everything that didn't move, are first derived from depth and the camera's reprojection in a small compute pass, as Godot's own FSR 2.2 does in its shaders (`client/native/upscalers/src/motion_fill.*`); without it most of the screen blurs and flickers |

The capability checks can come from an optional GDExtension, `client/native/upscalers/` (`ZenithUpscalerCaps`,
its own `upscalers.windows.template_release.x86_64.dll` in `client/native/bin/`, never part of belt_sim). Build it
with `client/native/upscalers/build.bat` (MSVC and godot-cpp as for belt_sim; `godot_cpp=<dir>` for a godot-cpp
elsewhere); no DLL is committed. `tools/release/package.py` puts `upscalers.gdextension` and the DLL beside
`Zenith.exe` in the Windows download when the DLL is in `client/native/bin/` (it prints "upscalers library: in the
download" or "not in it"), and stops with an error when `--windows-template` or `--vendor-runtimes` is given without
it; the download's `BUILD.json` records `template` (`official` or `our build: <BUILD.txt's first line>`) and `vendor`
(`none`, `amd`, `amd+nvidia`). AMD FSR needs AMD FSR SDK 2.4.0's API headers (MIT) at build time, as AMD lays
them out (`Kits/FidelityFX/api/include`, `Kits/FidelityFX/upscalers/include`): `ffx_sdk=<dir>`, by default
`art-src/vendor-runtimes/amd/fsr-sdk-2.4.0` in this checkout or a folder above it (git-ignored, never committed;
fetched from AMD's GitHub at tag `v2.4.0`). Without them the library still builds and `ZenithFsrUpscaler` says it was
built without AMD's SDK; AMD's DLLs are loaded at run time (`LoadLibrary`), never linked. Without it `client/scripts/menu/upscalers.gd` asks the same things itself and
Zenith runs the same. The engine hook is "yes" only on Godot built with Zenith's patches
([tools/godot-patches/4.7.2](../tools/godot-patches/4.7.2/README.md): `ViewportUpscaler`,
`RenderingDevice.native_callback_add`, `RenderData.get_upscale_inputs`), "no" on stock Godot; the library's
`ZenithHookUpscaler` is a do-nothing upscaler (a plain D3D12 copy) that proves the hook in
`tools/godot/hook_window_test.ps1` and isn't used by Zenith itself; `tools/godot/fsr_window_test.ps1` does the same for
AMD FSR (`-Version 3.1|4.1`, `-FsrDebug`, `-DirectBarriers`, `-HeadlessOnly`; a window under the D3D12 debug layer, run
only when nobody is at the PC). Test: `client/tests/upscalers_test.gd` (in `tools/check.py`).

### NVIDIA DLSS (step 7)

**NVIDIA DLSS** draws through the engine hook with Zenith's own build of NVIDIA Streamline (MIT source, v2.14.16,
patched so Streamline itself never starts NVIDIA's updater or loads downloaded plugins: [tools/dlss](../tools/dlss/README.md))
and NVIDIA's own `nvngx_dlss.dll`, which Zenith never downloads, ships or updates. **Not merged:** NVIDIA's driver NGX
runtime starts its own `nvngx_update.exe -api update ... -bootstrap` (seen connecting out on port 443) the moment
DLSS asks NGX anything, whatever Streamline does (`tools/dlss/sl_init_probe.ps1` shows it); the owner chose to
ask the player first (below). It runs when all of these hold: our
patched Godot on Direct3D 12, an NVIDIA RTX card, the upscalers DLL built with Streamline's headers (`build.bat`
finds the git-ignored `art-src/vendor-runtimes/streamline/v2.14.16`, or `sl_sdk=<dir>`), and in `vendor/nvidia/`
beside `Zenith.exe` (or `<dir>/nvidia` for `--vendor-dir=<dir>`; `--vendor-dir=none` turns vendor upscalers off; a
project run also looks in the main checkout's `art-src/vendor-runtimes/nvidia`):
`sl.interposer.dll`, `sl.common.dll`, `sl.dlss.dll` and `zenith-sl-manifest.txt` from
`tools/dlss/build_streamline.ps1`, and `nvngx_dlss.dll` from github.com/NVIDIA/DLSS (release v310.9.16,
`lib/Windows_x86_64/rel/`). Zenith loads our three DLLs only when their SHA-256s match the manifest and NVIDIA's
DLL only when NVIDIA signed it; otherwise the entry is greyed "NVIDIA's DLSS files aren't installed (vendor/nvidia/)"
(reasons in order: not in this build, needs an RTX card, files, needs Direct3D 12) and a saved `dlss` draws with
FSR 2.2. If DLSS fails at run time (Streamline can't start, nothing drawn in 120 frames) the run goes back to FSR 2.2
and the log says why. Upscaling quality picks the DLSS mode (Native AA = DLAA, Quality, Balanced, Performance, Ultra
Performance; Custom by the scale); Upscaler sharpness is greyed (DLSS has no sharpening). Switches for the window
test: `--dlss-jitter=flip|flip-y` (jitter sign), `--dlss-barriers=direct` (hand Godot's enhanced-barrier layouts over
as states instead of the COMMON bridge), `--upscaler-mv=raw` (above). DLSS draws at its mode's own render size:
Streamline makes DLSS's feature at the mode's optimal size and DLSS drew black while upscaling (perhaps for a larger
render size: unconfirmed until a window test), so a preset's scale is fitted to DLSS's optimal size on both axes as
Godot draws it (Quality's 0.67 becomes DLSS's 2/3), never above it; a Custom scale may go up to the maximum of DLSS's
range when DLSS reports one above its optimal, and Settings shows "NVIDIA DLSS draws n%" beside Game render scaling
when that isn't the slider's. Frames above DLSS's range are skipped at most 60 in a row, then drawn anyway; below its
minimum they are only logged. The log says "NVIDIA DLSS: mode .., WxH -> WxH (DLSS's optimal .., range ..)" and
Streamline's own warnings as "NVIDIA DLSS (Streamline) warning: ..."; `--dlss-fit=off` draws at the scale as asked
(before `alt/upscaler-fix`). Native side: `ZenithDlssUpscaler` (`client/native/upscalers/src/dlss_*`);
GDScript: `client/scripts/menu/dlss_host.gd`. Window test (not run yet, RTX card): `tools/godot/dlss_window_test.ps1`.

**The player's OK first (`alt/dlss-s7c`, the owner's decision: no hidden traffic).** Because NVIDIA's driver starts its
updater whenever DLSS starts and Zenith can't turn it off, DLSS stays off until the player says yes. Picking NVIDIA
DLSS (or Automatic where it would pick DLSS) opens a prompt that says so in plain words ("Use DLSS" / "Cancel";
Cancel and Esc keep the previous choice). The answer is saved as `[graphics] dlss_consent` (default `false`); a row
"NVIDIA updater: allowed" with **Withdraw** under Upscaling clears it and turns DLSS off at once. Before the OK
nothing of Streamline or NVIDIA's is loaded or asked anything: the capability check only looks whether the files are
in `vendor/nvidia/` and at Godot's adapter name/vendor (`upscalers.gd`, `dlss_host.gd`; the log says "NVIDIA DLSS waits
for the player's OK ..."); a saved `dlss` or `--upscaler=dlss` draws with FSR 3.1 / 2.2, the entry's reason "Needs your
OK for NVIDIA's updater" (after the build, card, files and renderer reasons); Automatic skips DLSS.

| Switch | Effect |
| --- | --- |
| `--dlss-consent=yes` | the player's OK for this run only, nothing saved (tests, scripted runs; also needed with `--upscaler=dlss` on a settings file without the OK) |
| `--dlss-consent=no` | no OK for this run, whatever the settings file says |

Proof (headless, our build): `tools/dlss/consent_proof.ps1 -Godot <our godot.exe>` starts Zenith twice with
`--vendor-dir` and `--upscaler=dlss` on a settings file of its own, watching the process's modules and every
`nvngx_update.exe`: without the OK no `sl.*.dll` / `nvngx*.dll` and no updater; with `--dlss-consent=yes`
`sl.interposer.dll` loads (headless has no device, so no `slInit`). Tests: `upscalers_test.gd` (consent, Automatic,
fallbacks, withdraw, `ZenithDlssUpscaler.ngx_modules_loaded` empty before the OK), `ui_test --only=_antialiasing_look`
(the prompt, Cancel, Use DLSS, Withdraw).

## The native belt simulation (optional)

Moved to [COMMANDS-TESTS.md](COMMANDS-TESTS.md#the-native-belt-simulation-optional).

## Commands for models, releases and the UI reference

Moved to [COMMANDS-TESTS.md](COMMANDS-TESTS.md#commands-for-models-releases-and-the-ui-reference).

## Building Godot's Windows template (optional)

Zenith's Windows download can be exported with a Godot 4.7.2 release template built from Godot's source
(with Zenith's upscaler hook patches, the base for FSR 4 / DLSS) instead of the official one. Nothing changes
unless you ask for it:

```powershell
powershell -ExecutionPolicy Bypass -File tools\godot\build_template.ps1   # MSVC + .venv scons, into art-src\godot-build\
python tools\release\package.py --windows-template "art-src\godot-build\out\4.7.2\windows_release_x86_64.exe"
```

The script checks the pinned tag's commit, applies `tools/godot-patches/4.7.2/*.patch`, builds with D3D12 and
Vulkan at below-normal priority leaving 8 GB RAM free, and trims source paths from the binary.
`--windows-template` sets the Windows preset's `custom_template/release` for that export alone
(`export_presets.cfg` put back after, so no build path is committed); without it the official template is
used as before. Detail: [tools/godot/README.md](../tools/godot/README.md).

### Vendor runtimes (AMD FSR) in the Windows download

AMD's signed FSR runtime libraries are not in git. A release carries them in `vendor/amd/` only when you ask:

```powershell
python tools\release\fetch_vendor_runtimes.py     # AMD FSR SDK 2.4.0 from AMD's GitHub release (~250 MB), SHA-256 checked, into art-src\vendor-runtimes\amd\ (git-ignored); offline when already there; --check only reports
python tools\release\package.py --vendor-runtimes art-src\vendor-runtimes   # default none
```

The Windows x86_64 zip then gets `vendor/amd/` (`amd_fidelityfx_loader_dx12.dll`, `amd_fidelityfx_upscaler_dx12.dll` and AMD's
`license.md`); other platforms and source archives never do, and `leak_scan.py` fails any zip that breaks that, that holds AMD's
DLLs without `license.md` (or the reverse), or that holds `vendor/nvidia/` without `--ship-nvidia` (below).
Turning it on for a release is the owner's choice: add `--vendor-runtimes art-src\vendor-runtimes` to that release's `package.py` command.

`--ship-nvidia` (default off, needs `--vendor-runtimes <dir>`) also copies Zenith's own Streamline build from
`<dir>/streamline-built/` (`tools/dlss/build_streamline.ps1`: `sl.interposer.dll`, `sl.common.dll`, `sl.dlss.dll`,
`zenith-sl-manifest.txt`; each DLL's SHA-256 checked against the manifest) into the Windows x86_64 zip's
`vendor/nvidia/`, and its `BUILD.json` says `"vendor": "amd+nvidia"`. `leak_scan.py` lets `vendor/nvidia/` through only
in a Windows x86_64 zip whose top `BUILD.json` says so AND when the scan is run with `--allow-nvidia` (the yes at
scan time; `package.py`'s own check passes its `--ship-nvidia`), and then exactly those four files; NVIDIA's own `nvngx_dlss.dll`
is never shipped (the player downloads it) and fails the scan. Without the flag, no NVIDIA file, as before. Shipping
NVIDIA's is the owner's decision (licensing and NVIDIA's terms, not yet settled).

## Tests

Moved to [COMMANDS-TESTS.md](COMMANDS-TESTS.md#tests). The long stress soak (`tools/bench/soak/soak.py`, Windows: the real client
in a window, muted, against a copy of a save on headless Factorio, phase after phase for hours; every frame, the client's spike
log, both processes' memory and the server's UPS; stops at 3 GB free RAM) and its summary (`analyze.py`) are listed there too.

## Not done yet

Moved to [COMMANDS-TESTS.md](COMMANDS-TESTS.md#not-done-yet).
