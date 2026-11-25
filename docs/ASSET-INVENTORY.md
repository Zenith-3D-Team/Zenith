# Asset Inventory: 2D Sprites → 3D Models

Every visible Factorio entity that needs a 3D model, grouped into **families** so tier variants share meshes where possible. Prototypes come from **Factorio 2.1.23** (base game, Space Age, Elevated Rails). Authoritative tracker status lives in [docs/tracker/models.json](tracker/models.json).

For conventions and the Blender/glTF pipeline, see [PLAN.md §6](PLAN.md#6-converting-the-2d-sprites-into-3d-models), [MODELLERS.md](MODELLERS.md), and `client/assets/models/README.md`.

## Built-in pack counts

| Pack | Role & Source | `.glb` Files | Notes |
|---|---|---:|---|
| **FUE5 (Adapted)** | Textured PBR models converted from FUE5 (`CC BY-NC-SA 3.0`, `fue5.py` + `bake_fue5_pbr.py`) | **142** | Highest default priority among built-ins; covers 39+ base machines, belts, pipes, walls, rail signals, inserters & robots |
| **Wube3DP (Adapted)** | Scaled, sprite-matched models from Wube printables (`CC BY-NC`, `wube.py` + `bake_pbr.py`) | **94** | Character, biters, spitters, assembler-1, chests, drill, furnaces, belts, inserters, walls |
| **Placeholders** | Sprite-matched procedural Blender models covering every base & Space Age family | **575** | `377` entity/variant `.glb`s + `198` `items/` meshes (`3D` items on belts/ground) |
| **Total built-in** | Shipped across `client/assets/models/packs/` | **811** | Plus **Factorio** runtime 2D sprite pack & optional Vasillo **Zenith.zip** PBR pack |

Every family has a dedicated model except `crude-oil` (still an unchecked blockout). Motion uses either separate shader-driven `anim_*` objects, single-action baked glTF skeletal animations, shader vertex rigs (creatures/character), or mod-driven aims/positions (`turrets.gd`, `collectors.gd`, `inserter_arms.gd`).

**Stage summary (`73` tracker families):** `42` In the client · `21` Animated · `8` Textured · `2` Modelled.

| Tier | Meaning | Families |
|---|---|---:|
| P0 | First hour on Nauvis | 27 |
| P1 | Mid-game base | 12 |
| P2 | Late base game | 6 |
| ER | Elevated Rails | 1 |
| P3 | Space Age | 27 |

---

## P0: First hour

| Family | Prototypes | Models | Animation / Drawing Technique | Status |
|---|---|---|---|---|
| Character | `character` | 1 rig + gun, corpse | Wube printable rig: idle, run (4.77 tiles/loop), mine, shoot, flashlight | animated |
| Transport belt | `transport-belt`, `fast-`, `express-` | Straight, L/R curves | Shader-scrolling `belt_surface` slats/chevrons + tier paint (FUE5 adapted pack also covered) | in-client *(FUE5 unverified in-window)* |
| Underground belt | `underground-belt`, `fast-`, `express-` | Entrance, exit | Inner belt scrolls + tier paint (Wube3DP + FUE5 adapted) | in-client |
| Splitter | `splitter`, `fast-`, `express-` | 1 (+ FUE5 4 tiers) | Scrolling belts + 32-frame gear/crank animation (`fue5.py` adapted overlap 0.76–0.87; ours 0.79–0.92) | in-client |
| Inserters | `burner-`, `inserter`, `long-handed-`, `fast-`, `bulk-inserter` | Direction bases + arm kits | Arm stretches between shoulder and mod hand target (`FUE5` uses rigged arm pack, watermarked textures) | animated *(FUE5 blockout)* |
| Chests | `wooden-chest`, `iron-chest`, `steel-chest` | 3 | Static (`FUE5` default, `Wube3DP` 0.95–0.97 fallback) | in-client |
| Mining drills | `burner-mining-drill`, `electric-mining-drill` | 2 (direction variants + `-wet`) | Auger spin, burner rocker gears/rod/fire (`FUE5` electric drill default, `Wube3DP` fallback) | modelled |
| Furnaces | `stone-furnace`, `steel-furnace` | 2 | Animated burner fire glow (`FUE5` default, `Wube3DP` fallback) | in-client |
| Assemblers | `assembling-machine-1`, `-2`, `-3` | 3 | Moving gears/arms while crafting (`1` Wube3DP, `2–3` sprite-matched) | animated |
| Steam power | `offshore-pump`, `boiler`, `steam-engine` | 3 (direction bases) | Boiler fire, flywheel spin, pump pistons (`FUE5` boiler & steam engine default) | in-client |
| Electric poles | `small-`, `medium-`, `big-electric-pole`, `substation` | 4 | Catenary wires attached to prototype insulators (`FUE5` default, `Wube3DP` small pole fallback) | modelled *(FUE5 wire pins unverified)* |
| Pipes | `pipe`, `pipe-to-ground` | 16 shapes (+ windows) + 4 dirs | Connection bitmask (`extra.pc`) selects shape & window/cover (`Wube3DP` + `FUE5` 17-piece kit) | in-client |
| Lab | `lab` | 1 | Activity pulse (`FUE5` default; glow restoration pending) | in-client |
| Gun turret | `gun-turret` | 1 | Aims toward mod turret target, folds/recoils, muzzle flash (`FUE5` default) | textured |
| Wall & gate | `stone-wall`, `gate` | Neighbor shapes + fill + gate | Bitmask wall joins + proximity-opening gate (`Wube3DP` + `FUE5` 21-piece kit) | in-client |
| Car | `car` | 1 | Orientation + turret gun tracks aim (`vehicles.py`) | textured |
| Ores | `iron-ore`, `copper-ore`, `coal`, `stone` | 4 rock sets (3 richness stages) | Scattered/tiered instances by tile ore count | in-client |
| Trees | `tree-01` … `tree-09` (+ colour variants) | 9 | Shader leaf-card crowns (`tree_looks.json` tints/grain) | in-client |
| Dead trees | `dead-dry-hairy-tree`, `dead-grey-trunk`, `dead-tree-desert`, `dry-hairy-tree`, `dry-tree` | 5 | Static trunk/branch meshes | textured |
| Rocks | `big-rock`, `huge-rock`, `big-sand-rock` | 3 | Static meshes | in-client |
| Cliffs | `cliff` (+ `vulcanus`, `gleba`, `fulgora`) | 5 piece families (with variants) | Oriented block-wall system (`cliff_wall.gd`; planet variants blockout) | textured |
| Fish | `fish` | 1 | Subtle tail sway | in-client |
| Biters | `small-`, `medium-`, `big-`, `behemoth-biter` | Rigged body + attack + 4 corpses | Wube3DP mesh scaled/tinted per tier; shader limb walk + corpse poses | animated |
| Spitters | `small-`, `medium-`, `big-`, `behemoth-spitter` | Rigged body + attack + 4 corpses | As biters | animated |
| Spawners | `biter-spawner`, `spitter-spawner` | 1 + corpse | 0.9 Hz idle pulse | animated |
| Worms | `small-`, `medium-`, `big-`, `behemoth-worm-turret` | 1 + corpse | Folds, rises, and lunges at prototype attack speeds | animated |
| Crash site | `crash-site-spaceship`, wrecks (`big`, `medium`, `small`), chests | 14 | Static meshes | textured |

---

## P1: Mid-game base

| Family | Prototypes | Models | Animation / Drawing Technique | Status |
|---|---|---|---|---|
| Oil | `pumpjack`, `oil-refinery`, `chemical-plant`, `storage-tank`, `pump`, `crude-oil` | 6 (direction bases) | Pumpjack rocks (FUE5 animated in 0.3.0), refinery flare, pump pistons; `crude-oil` unchecked procedural | 5 animated (`FUE5`), 1 blockout (`crude-oil`) |
| Electric | `solar-panel`, `accumulator`, `electric-furnace`, `small-lamp` | 4 | Furnace fans, lamp light, accumulator glow (`FUE5` default; accumulator arc pending) | animated |
| Logistic network | `roboport`, `logistic-robot`, `construction-robot` | 3 | Client `rb` robot sim + GPU multi-mesh thrusters/cargo lamp (`FUE5` overlap 0.72–0.75; roboport doors pending) | animated |
| Logistic chests | `active-`, `passive-provider`, `storage`, `buffer`, `requester` | 1 + 5 colours | Hatches slide open near robots (`Wube3DP`; `FUE5` hatch animation pending) | in-client |
| Circuit network | `arithmetic-`, `decider-`, `selector-`, `constant-combinator`, `power-switch`, `programmable-speaker`, `display-panel` | 7 | Status indicators & power-switch contact (`FUE5` combinators/speaker) | in-client |
| Valves | `one-way-valve`, `overflow-valve`, `top-up-valve` | 1 per direction | Static | in-client |
| Rails | `straight-rail`, `half-diagonal-rail`, `curved-rail-a`, `curved-rail-b` | Piece + `-ne` diagonals | Quarter-turn orientation | in-client |
| Rail props | `rail-signal`, `rail-chain-signal`, `train-stop` | 3 | Directional lamp colour from bridge (`FUE5` signals/stop) | animated |
| Trains | `locomotive`, `cargo-wagon`, `fluid-wagon` (+ `infinity-cargo-wagon`) | 4 | Orientation, rolling wheels, night headlights (`FUE5` rolling stock) | textured |
| Defence | `laser-turret`, `flamethrower-turret`, `land-mine`, `tank` | 4 | Turret tracking/retracting/nozzle slide + tank tread scroll & turret aim | in-client |
| Combat robots | `defender`, `distractor`, `destroyer` | 3 | Hover offset | in-client |
| Radar & beacon | `radar`, `beacon` | 2 | Radar dish rotation (`FUE5` default; beacon glow pending) | in-client |

---

## P2: Late base game

| Family | Prototypes | Models | Animation / Drawing Technique | Status |
|---|---|---|---|---|
| Nuclear | `nuclear-reactor`, `heat-pipe`, `heat-exchanger`, `steam-turbine`, `centrifuge`, `uranium-ore` | 4 + 17 heat-pipe shapes + ore stages | 350°C+ copper glow (`FUE5` pipes/reactor/centrifuge/turbine), rotor spin (`reactor` glow pending) | animated |
| Rocket | `rocket-silo`, `rocket-silo-rocket`, `cargo-pod`, `cargo-landing-pad` | 4 | Silo doors (`FUE5` split doors) + rocket ascent & cargo pod docking | in-client |
| Artillery | `artillery-turret`, `artillery-wagon` | 2 | Barrel rotation, recoil, muzzle flash | in-client |
| Spidertron | `spidertron` | Body + 2-part legs | Procedural IK legs between hip, knee & mod foot targets | animated |
| Armour looks | `character` in light/heavy, modular, power armour | 2 plate sets | Shared character rig animations | animated |
| Misc | `market`, `lane-splitter`, `loader`, `fast-`, `express-loader`, `loader-1x1` | 4 | Loader belt scroll | in-client |

---

## ER: Elevated Rails

| Family | Prototypes | Models | Animation / Drawing Technique | Status |
|---|---|---|---|---|
| Elevated rails | `elevated-straight-rail`, `-half-diagonal-rail`, `-curved-rail-a`, `-curved-rail-b`, `rail-ramp`, `rail-support` | Deck pieces + `-ne`, ramp, support | Height-offset chunk placement (`world.gd`) | in-client |

---

## P3: Space Age

| Family | Prototypes | Models | Animation / Drawing Technique | Status |
|---|---|---|---|---|
| Machines | `foundry`, `electromagnetic-plant`, `cryogenic-plant`, `biochamber`, `crusher`, `recycler`, `big-mining-drill`, `agricultural-tower`, `heating-tower`, `captive-biter-spawner`, `biolab`, `fusion-reactor`, `fusion-generator` | 13 | Prototype-timed spinning, sliding, glow & ag-tower crane | `foundry`, `big-mining-drill` animated; 11 in-client |
| Logistics tier | `turbo-transport-belt`, `-underground-belt`, `-splitter`, `-loader`, `stack-inserter` | 1 (`stack-inserter` 4 dirs; rest paint variants) | Tier colour + shared inserter IK | animated (`stack-inserter`) |
| Space platform | `space-platform-hub`, `cargo-bay`, `thruster`, `asteroid-collector` | 4 (+ bay edge pieces) | Thruster plume, pod hatches, collector arms (`collectors.gd`) | in-client |
| Turrets | `railgun-turret`, `rocket-turret`, `tesla-turret` | 3 | Live target tracking, rising tesla head, opening rocket pods | `tesla-turret` animated; 2 in-client |
| Lightning | `lightning-rod`, `lightning-collector` | 2 | Post-strike electrical arc sparks | in-client |
| Capture robot | `capture-robot` | 1 | Hover + swaying cables | in-client |
| Mech armour look | `character` in mech armour | 1 | Shared character rig (flight pose pending) | animated |
| Vulcanus | `small/medium/big-demolisher`, volcanic rocks (`-hot`), chimneys, `ashland-lichen-tree` (`-flaming`), `tungsten-ore`, `calcite`, `sulfuric-acid-geyser` | Segmented worm + rocks + chimneys + vents + ores | Trailing demolisher segments (`demolishers.gd`); hot/flaming emission | demolishers animated *(mock)*; rest in-client |
| Fulgora | `fulgoran-ruin-*` (11), `fulgora-sunk-ruin-*` (2), `fulgurite` (2), `scrap` | 14 | Static meshes | in-client |
| Gleba flora | `yumako-tree`, `jellystem`, `boompuff`, `cuttlepop`, `funneltrunk`, `hairyclubnub`, `lickmaw`, `slipstack`, `stingfrond`, `sunnycomb`, `teflilly`, `water-cane`, `copper/iron-stromatolite` | 14 | Static meshes (wind shader pending) | textured |
| Gleba enemies | `wriggler-`, `strafer-`, `stomper-pentapod`, `stomper-shell`, `gleba-spawner` (`-small`) | Wriggler, 3 strafers, 3 stompers, shells, 2 spawners + corpse | IK walking legs, shader wriggle, swelling spawners | animated *(mock)* |
| Aquilo | `lithium-iceberg-big/huge`, `lithium-brine`, `fluorine-vent` | 4 | Static meshes | in-client |
| Asteroids | `small/medium/big/huge` × `metallic/carbonic/oxide/promethium-asteroid` | 16 | Tumble rotation | textured |

---

## Not models (handled by the client)

| Element | How the client draws it |
|---|---|
| Terrain & player floors | Factorio install tile textures (`stone-path`, `concrete`, space foundation) + coastal/water shaders (or pack `tiles/` overrides) |
| Decoratives & grass | Factorio sprite-sheet MultiMesh batches (`decoratives.gd`), or pack-provided 3D `.glb`/2D `decoratives/` overrides |
| Items on belts/ground/hands | **198** 3D item meshes in `Placeholders` (`items/`) + Factorio icon cards for everything else / distant belts |
| Projectiles, fire, smoke & particles | Factorio sprite sheets animated on camera-facing cards (`weapon_fx.gd`, `sprite_fx.gd`) |
| Remnants | Base entity model flattened, shattered, and rusted by shader |

## Skipped (editor, test or hidden)

`bottomless-chest`, `infinity-chest`, `linked-chest`, `electric-energy-interface`, `heat-interface`, `simple-entity-with-force`, `simple-entity-with-owner`, `factorio-logo-*`, `wube-logo-space-platform`, `dummy-*`, and `parameter-*` use fallback selection-box colouring. Aliased via existing meshes: `infinity-cargo-wagon`, `infinity-pipe`, `burner-generator`, and `linked-belt`.
