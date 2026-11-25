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

- **Settings tabs:** *Graphics* (presets, Recommended check, AMD FSR 2.2 / FSR 1.0, Distant Horizon, view/belt/decorative distances, shadows, SSAO, contact shading, Factorio Look vs pack PBR), *Sound*, *Controls* (Factorio 2.1 keys by default, toggleable back to `Zenith 0.2.2's keys`), *Interface*, *Other* (server autosaves & window minimize on `Ctrl+F9`), *Mod settings* (bridge settings over RCON), *Camera*, *Factorio install*, and *Add-ons*. See [USER-GUIDE.md](USER-GUIDE.md#settings-worth-knowing) for descriptions and [SWITCHES.md](SWITCHES.md) for CLI `--flag` overrides.
- **Persistence:** All client settings live in `user://settings.cfg` (`%APPDATA%\Godot\app_userdata\Zenith\settings.cfg`). On startup, defaults sync from Factorio's `config.ini` unless disabled in Settings → Factorio install (`--factorio-config` / `--settings-file` override this).
- **Menu launching:** Starting a server from the menu runs Factorio headless on dynamic ports starting at `34500` (configurable in Settings → Factorio install), keeping RCON on `127.0.0.1` (`server/data/rcon-password.txt`), and attaches a crash watchdog so the server stops cleanly if the client dies.
- **In-game console (`` ` `` or `/`):** Runs `/help` chat commands locally, `/cheat` and `/f3d-*` through the bridge (admin-restricted in multiplayer), RCON commands when hosted by the menu, or instructs you to press `Ctrl+F9` for commands that require a real Factorio window (`/editor`, `/screenshot`).

For headless test/screenshot menu automation flags (`--no-menu`, `--menu=...`, `--menu-launch`, etc.), see [SWITCHES.md](SWITCHES.md#menu-backdrop-automation--channels).

### The download

Build distributable zips with `tools/release/package.py` (requires Godot export templates matching the project version):

```bash
python3 tools/release/package.py                    # dist/Zenith-<version>-windows.zip (public)
python3 tools/release/package.py --platform linux   # supported: windows, linux
python3 tools/release/package.py --channel dev      # dev build (keeps debug menu & perf test)
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

## The native belt simulation (optional)

Moved to [COMMANDS-TESTS.md](COMMANDS-TESTS.md#the-native-belt-simulation-optional).

## Commands for models, releases and the UI reference

Moved to [COMMANDS-TESTS.md](COMMANDS-TESTS.md#commands-for-models-releases-and-the-ui-reference).

## Tests

Moved to [COMMANDS-TESTS.md](COMMANDS-TESTS.md#tests).

## Not done yet

Moved to [COMMANDS-TESTS.md](COMMANDS-TESTS.md#not-done-yet).
