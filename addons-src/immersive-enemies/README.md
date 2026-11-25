# Immersive Enemies

Physics-driven biter, spitter, worm & nest ragdolls, whole-body explosive splitting, damage-scaled dismemberment, burning corpses that char and burn to ash, progressive live & corpse wounds, pooled blood/gore effects, reworked enemy models, and reworked tier-weighted animations for Zenith (requires Add-on API `1.9`).

## Included features (version 0.1.2 — Nauvis biters, spitters, worms & nests)

- **Biter, Spitter, Worm & Nest Ragdolls, Dismemberment & Burning Corpses (Phase 1):**
  - Lightweight 3D rigid-body simulation for all 4 biter tiers (`small-biter`..`behemoth-biter`, 6-leg springs), all 4 spitter tiers (`small-spitter`..`behemoth-spitter`, 12-leg springs), all 4 worm tiers (`small-worm-turret`..`behemoth-worm-turret`, heavy topple/tumble), and Nauvis nests (`biter-spawner`, `spitter-spawner`) with weapon-scaled launch impulses weighted inversely by tier mass, high ground friction (`8.2`), low bounce restitution (`0.16`), and grounded stabilization.
  - Collides with terrain height and slope normals, bounces horizontally off solid walls and buildings, separates gently from other active ragdolls, and drives dynamic damped-spring legs on walking enemies.
  - **Grenade / explosive / overkill body splitting:** explosion, grenade, rocket, artillery, cannon, or overkill (`dmg >= 850`) kills split biters, spitters, and worms (vertical Y-axis worm slicing) into 3 solid meat-capped body chunks (`head`, `thorax`, `abdomen`) plus severed legs on biters (3–5) and spitters (4–6).
  - **Destructible Nests (`biter-spawner`, `spitter-spawner`):** leaves a grounded ruined corpse base in the crater (inheriting wounds, organic decay, and burning-to-ash if recently hit by fire/flamethrower) and on heavy/explosive/overkill kills also blasts 3 meat-capped nest chunks outward alongside radial ichor splatters and heavy gib shards.
  - **Damage-scaled dismemberment:** heavy kills (`impact`, `shotgun`, `dmg >= 450`) detach 2–3 biter legs or 2–4 spitter legs; medium kills (`dmg >= 200` or `hits >= 4`) detach 1–2 legs; light or `fire`/`poison`/`laser` kills stay intact.
  - **Burning corpses & burn-to-ash:** any supported enemy (biter, spitter, worm, or nest) killed by fire/flamethrowers—or dying within 6s of recent fire damage—spawns on fire, skipping wet blood puddles, emitting rising flames, dark smoke, and drifting grey ash from the pooled particle mesh, charring with glowing ember cracks via `set_ragdoll_burn`, and eroding cleanly to ash over ~10s.
  - Settled non-burning corpses, split chunks, and severed legs place Factorio blood puddles underneath and decay organically into the ground with all intact legs curling cleanly. When the active pool is full, excess deaths fall back cleanly to Zenith's default death animation.
- **Blood, Bullet Holes & Gore (Phase 2):**
  - **Progressive live & ragdoll wounds:** living biters, spitters, worms, and nests accumulate glossy purple-violet bloodiness and bullet holes as they take damage (clearing cleanly on death or when `blood_amount`/gore is toggled off), and ragdolls/corpses/split chunks inherit impact-facing bullet holes plus a final lethal wound.
  - Rendered with five pooled `MultiMeshInstance3D` batches (zero per-particle nodes): directional ichor droplets (also reused for buoyant burning-corpse flames, smoke, and ash), terrain-aligned ground splatter decals and skid/bounce smears, plus three sculpted procedural 3D gib pools on explosive, heavy, and nest kills — curved jagged chitin armor shards, lumpy glossy organic meat chunks with vertex-baked crevice AO (leaving first-impact blood smears), and curved tapered horn/fang splinters.
- **Slimy Swamp-Green Acid Goo (Phase 4):**
  - Replaces spitter and worm acid spit projectiles and flat ground puddles with five pooled `MultiMeshInstance3D` effects: sculpted 3D wobbling mucus globs flying along parabolic trajectories and shedding trailing slime droplets, radial splash droplets & corrugated liquid splash crowns on impact, rising murky green vapor wisps, and terrain-aligned custom-shader swamp-green ground pools with viscous domain-warped oozing flow, swelling/popping animated bubbles, wet clearcoat shine, and bubble-pop micro-droplets (`acid_goo` toggle).
- **Reworked Biter & Spitter Animations (Phase 3):**
  - Tier-weighted gait cadence (`small` frantic `1.25x` biter / `1.30x` spitter down to `behemoth` `0.80x` / `0.86x`), smooth yaw-rate turn banking (`roll`), acceleration and lunge `pitch`, sharper attack boost, and damage-scaled directional hit-flinch jolts away from incoming damage.
  - Throttled cleanly and does zero work when toggled off.
- **Reworked Enemy Models:**
  - Optional transient runtime pack overrides (`builtin:placeholders` for `big-biter`, `big-spitter`, and `biter-spawner`) enabling Zenith's watertight Placeholders models without overwriting explicit user pack choices.

## Settings overview

Find these under **Settings -> Add-ons -> Immersive Enemies**:

- **Ragdolls:** Enemy ragdolls on/off, launch force (`0.5..2.0`), max active ragdolls (`8..64`).
- **Blood & Gore:** Blood & splatter on/off, explosive gibs & dismemberment on/off, gore level (`Low`, `Standard`, `High`), blood amount (`0.0..2.0`).
- **Acid & Fluids:** Slimy acid goo streams, splash crowns, and bubbling swamp-green pools on/off (default on; setting ID `acid_goo`).
- **Animations:** Reworked biter & spitter animations on/off.
- **Fast native simulation:** on by default (setting ID `use_native`, `--enemies-native=off`): the per-frame work runs in Zenith's C++ library when it has it (API 1.93, `api.native_class`), the same look.
- **Spread death effects over frames:** on by default (setting ID `spread_deaths`, `--enemies-burst=old`): when many enemies die in one frame (explosives into a horde) the first two are drawn at once and the rest over the next few frames, nearest and biggest first, with whole bodies and half the gore for a big crowd; hits past the eighth in a frame spray from the same queue (none for one that dies in it); decals go to the GPU once a frame; tiers seen alive get their legs and parts cut on a worker thread (`api.creatures.precut`). Off: everything at once, as in 0.1.1.
- **Models:** Reworked enemy models on/off (default on; setting ID `use_reworked_biters`).

## Running in development

```bash
godot --path client -- --addons=addons-src/immersive-enemies
```
