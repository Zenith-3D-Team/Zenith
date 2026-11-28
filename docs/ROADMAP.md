# Zenith: Roadmap

Where Zenith is going. Priorities adapt as real saves are play-tested and bugs are reported. Published builds are on [Releases](https://github.com/unjustodin/Zenith/releases), and open bugs are in [Issues](https://github.com/unjustodin/Zenith/issues).

## Six parallel goals to 1.0

Zenith progresses across all six goals in parallel. Priority order decides what wins when work competes for time; **`1.0`** means everything playable in Factorio works smoothly in Zenith.

| Priority | Goal | Focus |
|---|---|---|
| 1 | [Stability](#1-stability) | Real saves, multi-client play, Linux parity, zero crashes/freezes |
| 2 | [Performance](#2-performance) | Steady 60 UPS/FPS on megabases, forests, and long view distances |
| 3 | [Interface](#3-interface) | Last 1:1 Factorio UI, camera views, and controls parity |
| 4 | [Models and animation](#4-models-and-animation) | Model accuracy vs sprites, restored FUE5 parts/glows, lighting, 3D foliage |
| 5 | [Space Age](#5-space-age) | Smooth planet transitions, silo launches, platforms, Space Age enemies |
| 6 | [Mods and add-ons](#6-mods-and-add-ons) | Mod-bundled model packs, overhaul testing, richer add-on hooks |

## Version numbering

Versions use `state.release.hotfix` (`0` while pre-1.0, second digit for feature releases, third for hotfixes). Bridge mod and client always share one version; add-ons keep their own versions.

## The goals

### 1. Stability

- Player bug reports first.
- Long play-test sessions on large saves, Linux release/CI parity, and elevated rail / train stop polish.
- Multi-client server sessions, `Ctrl+F9` window switching freeze hardening, and hybrid single-player testing.

### 2. Performance

- Reducing forest leaf & long-distance GPU cost (`E15`) and eliminating main-thread/camera-pan spikes while running (`E14`).
- Cheaper far tree/chunk stand-ins while keeping Distant Horizon transitions seamless.
- Sustaining 60 UPS on very big bases with minimal visual holdbacks.

### 3. Interface

- Closing remaining UI parity gaps ([UI-DIFFERENCES.md](UI-DIFFERENCES.md)), train/platform schedules, and chest hover contents.
- Tips & tricks imagery/workarounds and finishing camera polish across angled, F6, first-person, and map remote views.

### 4. Models and animation

- Refining models that still trail their sprites ([ASSET-INVENTORY.md](ASSET-INVENTORY.md)) and collaborating with 3D modellers ([MODELLERS.md](MODELLERS.md)).
- Restoring missing FUE5 animations/glows (e.g., roboport doors, refinery/reactor/beacon glow, pump/pumpjack motion).
- 3D foliage (`C14`), wind in plants/trees, improved character run cycle, and cheaper indirect lighting/shadows.

### 5. Space Age

- Smoothing rocket silo launches and orbital planet approach/flyby visuals.
- Platform schedules/hub UX and polishing Vulcanus, Fulgora, Gleba, and Aquilo creatures & environments.

### 6. Mods and add-ons

- Mod-declared model packs, animated modded buildings polish, and testing large overhaul mods.
- Expanding add-on API hooks (`docs/ADDONS.md`, currently `1.91`) as community add-ons need them.

## Released

### 0.1: First release

Real Factorio 2.1 (base + Space Age) playable in 3D: model coverage for base + Space Age entities, Factorio UI & hotkeys, save import, space platforms, and first add-on API (`0.1.1` / `0.1.2` hotfixes improved megabase speed and stability).

### 0.2 / 0.2.1: Client belt simulation & visual upgrades

Client-side Factorio-accurate belt simulation, Vasillo's textured logistics & drill pack (`Zenith.zip`), Cinematic shaders, contact shading, 3D grass, 8K screenshots, creature hull models, LAN TCP relay (`server/relay.py`), and mod graphics (`gfx`).

### 0.3 (dev-channel pre-release): Horizon, weather, FSR 2.2 & C++ speedup

Bundled **Immersive Weather**, **Distant Horizon** (`512`-chunk 2.5D terrain & factory silhouettes), **AMD FSR 2.2**, redone card-based Graphics settings, per-pack PBR shading (`108`-model Vasillo PBR support + FUE5/Wube3DP PBR), **Binary Wire `v1–5`** with `nack` ring & `rb` robot sim, **13-class C++ GDExtension**, cargo wagon Alt-mode, and Factorio 2.1 default key bindings.
