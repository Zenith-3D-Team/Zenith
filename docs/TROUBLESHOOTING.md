# Troubleshooting

Common fixes for setup, connection, and performance problems. Deep measurement probes, GPU/CPU tuning history, and flag-by-flag optimization notes now live in [PROFILING-NOTES.md](PROFILING-NOTES.md); every `--flag` switch is indexed in [SWITCHES.md](SWITCHES.md).

## Troubleshooting

- **"Waiting for Factorio on 127.0.0.1:34200":** Factorio is not running with `--enable-lua-udp 34200`, or the `factorio-3d-bridge` mod is disabled. Inspect `server/data/factorio-current.log` for `factorio-3d-bridge` or `"UDP is unavailable"`.
- **"No answer from the bridge" on a dedicated server:** Factorio pauses an empty server when `"auto_pause": true` (blocking `on_tick`). Set `"auto_pause": false` and `"auto_pause_when_players_connect": false` in `server-settings.json`, pass `--enable-lua-udp 34200`, and verify via `/c __factorio-3d-bridge__ rcon.print(tostring(game.tick_paused))`.
- **"Can't open UDP port 34201":** Ports `34201–34208` are all bound by running Zenith instances or mock tests; close extra clients.
- **"Incompatible Factorio version":** The mod targets Factorio `2.1` (`info.json`: `"factorio_version": "2.1"`); Factorio `2.0` cannot load it.
- **Server exits with `Can't bind socket: Error code 10013` (Windows):** Another process holds the UDP/RCON/game port (`Get-NetTCPConnection -LocalPort 34198` / `Get-NetUDPEndpoint`).
- **No relay answers at `<host>:34200`:** Ensure `python3 server/relay.py` is running on the server PC, TCP `34200` is allowed on the local subnet firewall, and your client IP matches `--allow`. See [RUNNING.md](RUNNING.md#server-on-another-pc).
- **No item icons, flat-coloured terrain, or silence:** Zenith couldn't locate your Factorio install. Set it in **Settings → Factorio install** or pass `-- --factorio-data=<Factorio>/data`.
- **Slow UPS on megabases:** Enable **Settings → Graphics → Hold the game at 60 UPS** (default on; automatically throttles bridge `rate`, distances, and FPS cap below ~57 UPS). Otherwise profile bridge modules via `/f3d-profile` then `/f3d-status`, or lower **View distance**, **Entity distance**, **Moving belt items**, and **Belt item distance** (see [PROFILING-NOTES.md](PROFILING-NOTES.md)).
- **Low FPS on busy bases or forests:** Click **Settings → Graphics → Recommended** or drop **Preset** (`Low`–`Ultra`). Ambient Occlusion (`SSAO`) is enabled in `High`/`Ultra` (~0.7 ms GPU up close and fades out with distance); **Distant horizon**, dense forests, and high **Render scaling** dominate GPU cost.
- **Hybrid single-player fails to connect:** Start Factorio with `--enable-lua-udp 34200`, load into a save first, confirm the mod is active in Factorio's mods folder, and run `/f3d-selftest` in Factorio's console (`~`).
- **Black screen, crash at start, or drawing glitches since 0.3.1 (Windows):** Zenith draws with Direct3D 12 by default. Go back to Vulkan (as before 0.3.1) in **Settings → Graphics → Renderer → Vulkan** and restart, or start once with `--rendering-driver vulkan` before `--` (e.g. `Zenith.exe --rendering-driver vulkan`). If Direct3D 12 can't start at all, Godot falls back to Vulkan by itself. To reset by hand, delete the `rendering_device/driver.windows` line from `%APPDATA%\Godot\app_userdata\Zenith\engine.cfg`.
- **Crash, quit hang, or flicker with "Render on a separate thread":** Untick **Settings → Graphics → Render on a separate thread** and restart, or launch once with `--render-thread safe` before `--`.

### Test runs' Godot logs (not the player's)

Godot rotates `user://logs/godot.log` (`%APPDATA%\Godot\app_userdata\Zenith\logs\`, keeping 5 logs) before scripts run. Automated tools (`tools/check.py`, benches, probes, `package.py`) pass `--log-file <absolute path>` into `art-src/check-logs/` or run temp dirs so player crash/freeze logs aren't evicted. When launching Godot manually for tests, pass `--log-file "<abs-log>"` before `--`; `python tools/test_godot_logs.py` enforces this.

### The debug menu (Ctrl+F12)

Available only in testing builds (`--channel dev`, or a public download started with `--dev-tools`) and source runs (`Settings.dev_tools()`, stripped from public releases along with its keybinding). Opens on its own layer over gameplay, add-on cameras (`F8`), and hidden HUD (`F11`):

- **Time & Pause:** Jump daytime, freeze sun, scale speed (`0.05–16x`), or pause/resume via RCON (admin-restricted in multiplayer).
- **Benchmarks (`bench_runner.gd`):** In-save standing, lap, flyover, and zoom runs comparing p50/p99 frame time, GPU/render CPU, draw calls, UPS, and bridge costs (`user://benchmarks/`).
- **Tests, Lighting & Render:** Run `/f3d-selftest` / `/f3d-status`, toggle profiler HUD, spike log, chunk borders, live lighting sliders, wireframe/overdraw views, forced 3D item LOD tiers, and teleports.
- **Bridge & Updates:** One-click `/f3d-profile`, `/f3d-perf`, `/f3d-bs`, rate locks, PerfLog viewer, clipboard debug snapshot, and live ground flash overlays showing incoming chunks/deltas/belts.
- **Simulation:** Toggle belt-simulation debug switches (`BeltSim` / `BeltSimNative`) live between belt jobs.

### The performance test (main menu)

Available only in testing builds (`--channel dev`, or `--dev-tools`) and source runs (`-- --perf-test[=quick|default|extensive]`, [PERFORMANCE-TEST.md](PERFORMANCE-TEST.md)). Spawns an isolated headless Factorio map + child Zenith (`user://perf-tests/`), builds a 2,603-entity benchmark factory over RCON, measures standing/lap performance across presets/looks via `--stutter-probe`, and writes `user://perf-tests/Zenith-perf-<version>-<mode>.txt` without modifying player saves or settings.

### Profiling probes & deep optimization notes

CLI diagnostic probes (`--stutter-probe`, `--spike-log`, `--stall-watchdog`, `--shader-refresh`, `--ups-probe`, `--ao-probe`) and the full optimization log are preserved in [PROFILING-NOTES.md](PROFILING-NOTES.md). See [SWITCHES.md](SWITCHES.md) for every `--flag` option.
