# Zenith

<p align="center"><img src="client/assets/branding/logo.png" alt="Zenith" width="640"></p>

Play your real Factorio game in 3D, with an angled camera close to your character and a 3D model for every entity.

This isn't a remake. Factorio 2.1 still runs the game, unchanged, as a headless server with no window. A bridge mod streams live game state to a separate Godot 4.7+ 3D client, which renders the world and sends your input back. Saves, research, belts, trains, biters, mods, and Space Age all run natively inside real Factorio.

You need your own copy of Factorio 2.1. Space Age is supported but not required.

## Download

Get a release from the [Releases page](../../releases/latest):

- **`Zenith-<version>-windows.zip`** or **`Zenith-<version>-linux.zip`**: The full client, bundled with the bridge mod and server scripts (`START HERE.txt` inside covers first launch). *(Pre-release `Zenith-0.3.0-dev` builds also include the debug menu and performance benchmark.)*
- **`factorio-3d-bridge_<version>.zip`**: Standalone bridge mod for dedicated servers or single-player hybrid mode.
- **Bundled add-ons & packs:** Releases ship with **Cinematic shaders**, **Cinematic camera** ([repo](https://github.com/unjustodin/Zenith-Cinematic-Camera)), **Immersive Weather** (dynamic sky, rain, puddles, lightning), **Immersive Enemies** (ragdolls, gore, acid), and **Terrain Elevation** ([repo](https://github.com/unjustodin/Terrain-Elevation)), all on by default. Builds can also bundle Vasillo's textured PBR **Zenith** model pack (`models/Zenith.zip`).
- **Vendor upscalers (Windows, `vendor/` beside `Zenith.exe`):** AMD FSR 4.1 / 3.1's libraries come in downloads that include them. **NVIDIA DLSS** files are never shipped: you download `nvngx_dlss.dll` yourself from NVIDIA's [DLSS repository](https://github.com/NVIDIA/DLSS) and put it in `vendor/nvidia/`. DLSS stays off until you say yes in Settings > Graphics > Upscaling, because NVIDIA's graphics driver runs its own updater when DLSS starts ([USER-GUIDE](docs/USER-GUIDE.md)).

## What works today

- **Your own saves:** Load any save from the menu; Zenith copies it, starts headless Factorio, and takes over your save's character with its inventory, armour, quickbar, and logistic requests without modifying your original save.
- **Factorio's interface in 3D:** Inventory, crafting, machine screens, research, map and minimap, blueprints and planners, circuit networks, train schedules, logistics, Factoriopedia, alerts, and tooltips—drawn with Factorio's own UI art and fonts from your install, matching Factorio 2.1 bindings.
- **Full 3D entity & item coverage:** Over **800 `.glb` files** across built-in **FUE5 (Adapted)**, **Wube3DP (Adapted)**, and **Placeholders** packs (plus 198 3D item meshes, optional Vasillo PBR packs, and Factorio 2D sprite cutouts).
- **Megabase simulation & scaling:** Client-side belt and worker-robot simulation accelerated by a native C++ GDExtension (`client/native/belt_sim/`), compact binary wire frames (`v1–5`), **Distant Horizon** 2.5D terrain/factory rendering out to 512 chunks, **AMD FSR 2.2**, per-pack PBR shading, and automatic **Hold 60 UPS** throttling.
- **Space Age & multiplayer:** Space platforms, rocket rides, Vulcanus, Fulgora, Gleba, Aquilo, quality, spoilage, local multi-client (`1–8` players), regular Factorio `Ctrl+F9` window handoff, and LAN play via `server/relay.py`.

Press **F6** at any time to snap to Factorio's 2D camera angle for comparison, or **F5** for first-person mode.

## What still needs work

- Some built-in models still differ from Factorio's sprites in shape or colour ([docs/ASSET-INVENTORY.md](docs/ASSET-INVENTORY.md)), and FUE5 models are missing a few moving parts and glow effects. Model refiners can follow [docs/MODELLERS.md](docs/MODELLERS.md).
- Dense forests and extreme view distances remain the heaviest GPU cost; 3D ground clutter (`C14`) and last UI parity details are open.
- Single-player **hybrid mode** (attaching directly to a windowed Factorio instance) works, but has had less testing than headless server mode.
- Field-tested on Windows 11 with Factorio 2.1.23 / 2.1.24; the Linux client export has not been play-tested extensively yet.

Detailed tracking lives in [STATUS.md](STATUS.md) and [PROGRESS.md](PROGRESS.md).

## Quick start

- **Players:** [Download a release](../../releases/latest), unzip it, and launch Zenith. See [docs/USER-GUIDE.md](docs/USER-GUIDE.md).
- **Developers from source:** Import assets once (`godot --headless --audio-driver Dummy --path client --import`), then run `godot --path client` (or press `F5` in Godot 4.7+). Without Factorio, run `python3 tools/mock_server.py` first. See [docs/RUNNING.md](docs/RUNNING.md).

## Why I made this

I'm a software developer, and I like building things that push at what should be possible.
The idea came from the Factorio fan remake in Unreal Engine 5 and from mods that give other games
a new camera. I wanted that feel with the real Factorio underneath, so it would be the real game
and not a lookalike.

I thought it would be a renderer. Instead it became most of a game client: Factorio can't
draw 3D and mods can't touch its renderer, so every menu, every hotkey, every screen and every
interaction had to be rebuilt from scratch. On top of that, every entity needed a 3D model.

## How it was made, including AI

I want to be upfront about this, because I know AI use is a sore point for a lot of people.

**Most of the code and models were written by AI coding agents that I directed.** The main
one was Anthropic's Claude, through Claude Code. OpenAI's ChatGPT did a pass on model detail
and animations, and Google's Gemini (through the Antigravity CLI) built one UI feature.

My part:
- the idea, the architecture decisions and the art direction;
- deciding what to build, in what order, and what "done" means;
- playing it on my own saves and writing up what was wrong, then checking the fixes;
- reviewing the models against Factorio's sprites.

None of it is generated blind and shipped. Every feature has to pass:
- tests of the mod against a strict fake of Factorio's API;
- a mock server and protocol validator that check every message;
- a UI test that clicks through the interface (about 2,500 checks);
- a checker for every model's scale, origin and triangle budget;
- a live check against a real Factorio 2.1 server (402 checks on the last full run).

All of these run on every push.

The art has one rule: **it should look like Factorio, not like AI art.** The models are built
from code in Blender (the scripts are in `tools/models/`), not generated by image-to-3D, and
each one is compared side by side with Factorio's own sprite. Where Wube released a
real 3D model, that comes first. The FUE5 models are the work of that project's own modellers,
Hurricane and Nuke, converted to Zenith's scale and kept under their licence.

## Where it's going

- **Open source, single maintainer:** Code is GPL-3.0. Forks are welcome ([CONTRIBUTING.md](CONTRIBUTING.md)), though Zenith does not accept pull requests or feature requests; bug reports are welcome.
- **Custom models & packs:** Built-in packs (**FUE5**, **Wube3DP**, **Placeholders**, **Factorio**) layer cleanly with custom `.zip`/folder packs (`models/` or `--models=<dir>`). Per-pack PBR shading, custom ground tiles, 3D decoratives, and sound overrides are supported.
- **Add-ons (API 1.91):** GDScript add-ons hook the camera, keys, shaders, weather, terrain, sound, creatures, read-only world state, custom UI, per-save storage, and optional companion Factorio mods (`api.game`). See [docs/ADDONS.md](docs/ADDONS.md) and `addons-src/`.
- **Other Factorio mods:** Mods enabled in the Mods window run in real Factorio. Zenith reads mod graphics, icons, terrain tiles, and step sounds via `gfx` so modded items/buildings appear automatically even before custom 3D models exist. See [MODDING.md](MODDING.md).
- **Roadmap:** Six parallel priority tracks toward `1.0`: Stability, Performance, Interface, Models & Animation, Space Age, and Mods & Add-ons ([docs/ROADMAP.md](docs/ROADMAP.md)).

## Docs

- **Players:** [USER-GUIDE.md](docs/USER-GUIDE.md) (setup, controls, settings, packs) · [RUNNING.md](docs/RUNNING.md) (headless, hybrid, relay) · [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
- **Architecture & reference:** [ARCHITECTURE.md](ARCHITECTURE.md) · [PROTOCOL.md](docs/PROTOCOL.md) · [SWITCHES.md](docs/SWITCHES.md) · [COMMANDS-TESTS.md](docs/COMMANDS-TESTS.md) · [REPO-MAP.md](docs/REPO-MAP.md)
- **Modding & art:** [MODDING.md](MODDING.md) · [ADDONS.md](docs/ADDONS.md) · [MODELLERS.md](docs/MODELLERS.md) · [ASSET-INVENTORY.md](docs/ASSET-INVENTORY.md)
- **Planning & contributor notes:** [ROADMAP.md](docs/ROADMAP.md) · [PLAN.md](docs/PLAN.md) · [CONTRIBUTING.md](CONTRIBUTING.md)

```text
mod/factorio-3d-bridge/   Factorio 2.1 mod: state streaming, mod graphics (gfx), character control
client/                   Godot 4.7+ client (GDScript + native C++ GDExtension in client/native/)
addons-src/               Bundled client add-ons (cinematic shaders, weather, enemies, sprint)
server/                   Headless Factorio launchers (.ps1 / .sh) and LAN TCP relay (relay.py)
tools/                    Unified test runner (check.py), mock server, live checks, model & release tools
docs/                     Player guides, protocol spec, switches, asset inventory, plans & trackers
```

## Licence

Code is GPL-3.0 ([LICENSE](LICENSE)); add-ons may use any licence ([LICENSING.md](LICENSING.md)); `0.1.0` remains MIT. Requires your own Factorio 2.1 install—no Wube graphics, sounds, or fonts are committed. Wube printable conversions, FUE5 models, and logo artwork keep their respective licences ([CREDITS.md](CREDITS.md)).

This is an unofficial fan project. "Factorio" is a trademark of Wube Software; Zenith is not made, endorsed, or supported by Wube.
