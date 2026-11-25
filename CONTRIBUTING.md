# Contributing

Zenith is a personal open-source project (`GPL-3.0`): I do not accept pull requests or feature requests, though bug reports in the issue tracker are welcome. You are free to fork and build on it, provided derived code stays GPL-3.0 ([LICENSING.md](LICENSING.md)) and asset licences are respected ([CREDITS.md](CREDITS.md); brand logo/icon remain David's unless agreed).

## Working on a fork

Factorio 2.1 stays the simulation; `mod/factorio-3d-bridge/` streams state over localhost UDP (`--enable-lua-udp 34200`) and the Godot 4.7+ client draws it. See [ARCHITECTURE.md](ARCHITECTURE.md) for design and [docs/RUNNING.md](docs/RUNNING.md) for setup.

- **No Factorio needed for client UI/world work:** Run `python3 tools/mock_server.py` to stream a synthetic world speaking the full protocol.
- **Setup & checks:** Create `.venv` and run `pip install -r requirements-dev.txt` (`lupa`, `gdtoolkit`, `numpy`). Run `python3 tools/check.py` after edits (`--all fast`, `--all godot`, or `--all both` for full suites), `python3 tools/release/leak_scan.py .` to guard privacy paths, `python3 tools/code_health.py` to track repo health, and `python3 tools/live_check.py` against real Factorio before relying on bridge changes. See [docs/COMMANDS-TESTS.md](docs/COMMANDS-TESTS.md).
- **Protocol & native twins in lockstep:** Protocol changes must update `mod/`, `client/`, `tools/mock_server.py`, `tools/protocol.py`, and [docs/PROTOCOL.md](docs/PROTOCOL.md) together. Changes to belt rules or wire/chunk decoding must also keep C++ sources in `client/native/belt_sim/src/` in sync with GDScript.

## Add-ons (extending Zenith without forking)

Client add-ons are GDScript modules (`addon.json` + entry script) using versioned **API `1.91`**: camera, custom keys (`Settings → Controls`), settings UI, read-only world queries, events, shaders, weather, terrain, sound, creatures, screenshots/video helpers, per-save storage, and companion Factorio mod messaging (`api.game`).

- **Docs & examples:** Read [docs/ADDONS.md](docs/ADDONS.md). Inspect in-repo examples under `addons-src/` (`cinematic-shaders`, `immersive-weather`, `immersive-enemies`, `sprint`) or [Zenith-Cinematic-Camera](https://github.com/unjustodin/Zenith-Cinematic-Camera).
- **Develop & share:** Launch with `--addons=<folder>`, or zip the folder into `%APPDATA%\Godot\app_userdata\Zenith\addons\` (no unpacking needed). Add-ons stay in their own repositories under any licence you choose. Missing API hooks can be requested via bug reports or added in a fork.

## Other Factorio mods

Enable Factorio mods from the menu's **Mods** window. Entities render automatically from extracted mod graphics (`gfx`: sprite cards, real item icons, terrain, decoratives, step sounds); custom `.glb` models drop into `models/` or `--models=<dir>` ([docs/MODELLERS.md](docs/MODELLERS.md), [MODDING.md](MODDING.md)). Bug reports naming which mod breaks are always helpful.

## Art & copyright

Models must read as Factorio: convert Wube's 3D printables where available, otherwise match Factorio's HR sprites closely ([docs/MODELLERS.md](docs/MODELLERS.md)).

**Never commit Factorio install files** (graphics, sounds, fonts, extracted sprites, reference renders). Keep scratch references in git-ignored `art-src/`.
