# Commands, Tests, and Native Belt Simulation

Moved from [RUNNING.md](RUNNING.md#tests).

## The native belt simulation (optional)

Zenith runs Factorio's belt simulation client-side (`client/scripts/world/belt_sim.gd`). The native C++ GDExtension in `client/native/belt_sim/src/` (`client/native/belt_sim.gdextension`) accelerates hot simulation, rendering, networking, and terrain loops identically:

- **Registered native classes (`13`):** `BeltSimNative`, `BeltDrawNative`, `BeltItemsNative`, `BeltLatticeNative`, `BeltMvNative`, `MoversNative`, `InserterArmsNative`, `ChunkBuildNative`, `LodMesherNative`, `DecorNative`, `TerrainFieldNative`, `WireDecodeNative`, and `UdpSocketNative`.
- **Fallback safety:** Every path falls back cleanly to GDScript (`--belt-sim-native=off`, `--belt-draw-native=off`, `--native-belt-items=off`, `--belt-mv-native=off`, `--native-movers=off`, `--native-inserters=off`, `--native-decor=off`, `--terrain-native=off`, `--native-decode=off`, `--udp-socket=off`). On platforms without a compiled binary, `native_library.gd` skips loading without editor warnings (`client/native/.gdignore` isolates editor discovery).
- **Prebuilt binaries & CI:** Windows `.dll` (`client/native/bin/`) is committed; Linux `.so` parity is compiled in CI (`.github/workflows/tests.yml`). Both build reproducibly with stripped workspace paths (`/PDBALTPATH:%_PDB%` + `/d1trimfile` on MSVC, `-ffile-prefix-map` on GCC/Linux).

### Rebuilding the C++ extension

Windows (MSVC Build Tools 2022+, Python, `scons`):

```bat
git clone --depth 1 -b 4.5 https://github.com/godotengine/godot-cpp client/native/godot-cpp
python -m pip install scons
client\native\belt_sim\build.bat
client\native\belt_sim\build.bat godot_cpp=E:\other-worktree\client\native\godot-cpp
```

After modifying `belt_sim.gd` or C++ sources, verify exact GDScript-vs-C++ parity:

```bash
godot --headless --audio-driver Dummy --path client --log-file art-src/check-logs/belt_sim_native.log -s res://tests/belt_sim_native_test.gd
godot --headless --audio-driver Dummy --path client --log-file art-src/check-logs/wire_decode_native.log -s res://tests/wire_decode_native_test.gd
godot --headless --audio-driver Dummy --path client --log-file art-src/check-logs/belt_sim_replay.log -s res://tests/belt_sim_replay.gd -- --native
godot --headless --audio-driver Dummy --path client --log-file art-src/check-logs/belt_sim_bench.log -s res://tests/belt_sim_bench.gd -- --native
```

*(Desktop `i5-6600K` benchmark on 12,800 items: `belt_sim.gd` 4.4 ms vs `BeltSimNative` 0.17 ms/tick; 80,000 items: 17.9 ms vs 0.16 ms/tick.)*

---

## Commands for models, releases and the UI reference

```bash
# 3D models (client/assets/models/README.md): rebuild, check, PBR bake, re-import
blender --background --factory-startup --python tools/models/build.py -- [names...]
python3 tools/models/wube.py [names...]
python3 tools/models/fue5.py [names...]
python3 tools/models/check.py [names...]   # empty checks all 811 built-in models
python3 tools/models/fix_pack.py <export> <copy> [--fixes tools/models/fixes/vasillo.json]
python3 tools/models/sprite_projection.py
python3 tools/models/part_colors.py [names...]
python3 tools/models/bake_pbr.py [--entities] [--items] [--jobs N] [--update-pack-json] [--fix-imports] [--verify]
python3 tools/models/review.py [names...]
godot --headless --audio-driver Dummy --path client --log-file art-src/check-logs/import.log --import
blender --background --factory-startup --python tools/models/preview.py -- out.png [names...]

# Releases, repo health & network benchmarks
python3 tools/code_health.py                     # 100-pt tech-debt & health scorecard
python3 tools/release/leak_scan.py .             # ASCII + UTF-16LE privacy/path audit
python3 tools/release/package.py                 # public release zip (--channel dev for a dev build)
python3 tools/release/build_mod_zip.py             # standalone mod zip
python3 tools/net_cost.py [--port 34200]
python3 tools/bench/compare_builds.py --before v0.1.2 --after v0.1.3
powershell tools\bench\run_matrix.ps1 -Build "label=<path>|<args>" -Repeat 3
python3 tools/bench/hybrid_cost.py

# UI reference comparison (art-src/ui_reference/) & Sprite gallery (art-src/compare/)
python3 tools/ui_reference/capture.py [--only names] [--fresh]
python3 tools/ui_reference/ours.py --factorio-port 35310 --port 35311 [names...]
python3 tools/ui_reference/compare.py
python3 tools/models/gallery.py [names...]
```

---

## Tests

Install Python test dependencies once:

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt   # Windows: .venv\Scripts\pip
```

Run the unified CI check runner (`tools/check.py`) from repo root—never run raw GUI Godot without `--headless --audio-driver Dummy --log-file <abs-path>` when working alongside an open desktop session:

```bash
python3 tools/check.py                 # fast checks for files changed vs main (--list to preview)
python3 tools/check.py --ui _sec1,_sec2 # targeted ui_test sections
python3 tools/check.py --done          # + full ui_test, model_load_test, model_textures_test
python3 tools/check.py --all fast      # all fast Python/Lua/gdparse/model/code_health checks (~80s)
python3 tools/check.py --all godot     # headless Godot tests (~2 min)
python3 tools/check.py --all both      # full CI suite
```

`--all` writes full logs to `art-src/check-logs/` (`--logs <dir>`) and exits non-zero on the first failure. Individual suites include:

| Suite | Scope |
|---|---|
| `tools/mod_tests/test_bridge.py` (+ `--binary`) | Bridge Lua 5.2 tests split across `bridge_world/01..09_*.py` vs strict `fake_factorio.lua` |
| `tools/mod_tests/test_{fuzz,binary,data_stage,events}.py` | Packet fuzzing, binary frame parity, mod `gfx` data stage, duplicate event guards |
| `tools/test_{mock_server,mock_fuzz,relay,protocol_sync}.py` | Mock UDP server, fuzzing, TCP relay reconnects, `PROTOCOL.md` table/version sync |
| `tools/test_{check,code_health,safe_delete}.py` + `gdparse` | `check.py` `AREAS` & `SECTION_ORDER` checks, health metrics, junction delete safety, GDScript syntax |
| `tools/models/check.py` + `tools/release/test_package.py` | All 811 `.glb` budgets/origins/footprints; release packaging & dev-block stripping |
| `client/tests/ui_test.tscn` (`16` `ui_area_*.gd` modules) | UI input/layout verification (`-- --only=<section>`) |
| `client/tests/addon_test.tscn` (`4` `addon_area_*.gd` modules) | Add-on API `1.91`, keybinds, camera handback, save storage, mod link |
| `client/tests/switches_test.gd` & `bridge_fuzz_test.tscn` | Centralized `Switches` CLI registry & incoming client packet fuzzer |
| `client/tests/{model_load,mod_files,model_packs,decor,nature_looks,sound_decode,sound_cache,safe_delete,vr,belt_sim_native,wire_decode_native}_test` | Model worker loads, mod indexing, pack overrides, nature shaders, audio locking, native C++ parity |
| `tools/live_check.py` (split under `tools/live/*.py`) & `tools/busy_base.py --big --measure` | Real Factorio 2.1 headless end-to-end verification and UPS script budget (CI `live` / `busy` jobs) |

---

## Not done yet

- **Fluids, heat & power polish:** In-world pipe fluid visualization inside Factorio pipe windows, glowing heat pipes, unplugged-power icons, and live machine internal items.
- **Space Age & trains:** Smoother orbital/planet transitions, rocket launch overhaul, 1:1 train/platform schedules, and custom train-stop colour tinting.
- **Models & foliage:** Electromagnetic plant & electric furnace refinements, pentapod shell models, missing FUE5 animated parts/glows (`roboport` doors, `pump` pistons, `reactor`/`lab`/`beacon` glow), and 3D ground foliage (`C14`).
- **Performance & UI parity:** Forest GPU load at `High`, remaining UI parity differences ([UI-DIFFERENCES.md](UI-DIFFERENCES.md)), Tips & tricks pictures, chest hover contents, and wider hybrid single-player testing.
- **Mod visuals:** Animated modded cards capped at 16 frames without night glow; late `data-final-fixes` sprite overrides after the bridge aren't re-read.
