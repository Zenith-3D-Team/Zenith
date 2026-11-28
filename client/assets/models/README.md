# 3D models

The models that come with Zenith are three built-in model packs in `packs/`, each with its
`pack.json`:

- `packs/placeholders/` ("Placeholders", 348 files): Zenith's own, built by the scripts in
  `tools/models/` from Factorio's sprites, with the belt pieces, curves and underground ends. It is
  the last resort under every other pack, always on, so every entity keeps a model.
- `packs/wube3dp/` ("Wube3DP (Adapted)", 94): Wube's printable models as `tools/models/wube.py` converts them,
  and the poses made from them; its `CREDITS.md` lists them.
- `packs/fue5/` ("FUE5 (Adapted)", 39): FUE5's textured models, CC BY-NC-SA 3.0; its README says where each
  came from.

`items/` (models of items on belts, "Items" below) isn't a pack.

A model is named after the Factorio prototype it draws, for example `transport-belt.glb` or
`assembling-machine-1.glb`. The client uses it for every entity of that prototype and falls back to
a coloured placeholder box for anything no pack has a model for. Which pack's model is drawn is the
packs' order ("Model packs" below). The model tools find and write models through
`tools/models/packs.py`: a model of ours is in placeholders or wube3dp, a rebuild writes over it where
it is, and a new one goes into placeholders.

Conventions (see `docs/PLAN.md` §4):

- glTF 2.0 (`.glb` or `.gltf`), exported from Blender with +Y up.
- 1 unit = 1 tile. The origin is the centre of the entity's footprint, at ground level.
- The model faces **north**: Blender +Y, Godot -Z. The client rotates it for other directions.
  Entities that can't rotate (chests, furnaces, labs) keep their front to the south, towards
  the default camera, like Factorio's sprites.
- The footprint matches the entity's selection box, with a small inset so neighbours read as
  separate (belts and walls run edge to edge so lines of them join up).
- Models are flattened into a single mesh for instanced drawing, so glTF skeletons and
  animations are ignored. Parts that move are separate nodes named `anim_*` with their pivot
  as the node origin; the client draws and moves them itself (see "Moving parts" below).
  Creatures and the character bend in the vertex shader instead (see "Creatures").

## Textures

A model may bring its own pictures: give a glTF material a base colour texture (and optionally a
metallic-roughness one, glTF's green = roughness, blue = metallic), embedded in the `.glb` (PNG or
JPEG) and read through the material's first UV map. The client mipmaps them when it reads the model
(`model_textures.gd`) and the model shader draws the base colour texture in place of the part
colour, times the material's base colour factor (keep it white), with the usual light weathering
on top; normal maps are ignored (the merged meshes carry no tangents). The picture's roughness is
used as it is; its metal is drawn at the look's `texture_metal` share (0.1 by default, as part
colours' metal is), so it takes the sun, the shadows and the look's fill as paint does;
`--texture-metal=full` draws it in full (docs/RUNNING.md). Far merged chunks
(`far_chunks.gd`) colour each vertex from a small copy of the texture. One material with one atlas
per model is cheapest (`tools/models/fue5.py` bakes FUE5's textures that way). Models without
textures are drawn as before.

Occlusion: a glTF occlusion texture (its red channel, usually packed as the red of the
metallic-roughness picture) is read and darkens the colour and the light, as the baked per-vertex
occlusion does. Without one (or with one that is all white), bake it per vertex instead, without
Blender: `python tools/models/bake_glb.py <file or folder> --out <scratch folder>` writes baked copies
(COLOR_0 alpha, and a `TEXCOORD_1` of (0, 0.5) if the file has none, which tells the client the
vertex colours are Zenith's data); look at them with `-- --models=<scratch folder> --models-first`,
then `--in-place` on the originals. On a textured model the occlusion only shades: its own pictures
keep their wear, with none of Zenith's crevice grime added. FUE5's models are baked this way
(`fue5.py` runs it after each conversion).

Nauvis's trees and rocks are dressed from Factorio's own pictures at runtime, without any of them
in the repo (`client/scripts/world/nature_looks.gd`): a tree's leaf cards (materials `leafcard-*`)
wear patches of its leaves picture, its bark (`bark-01`..`bark-09`) and the rocks' stone (`rock`,
`sand-rock`) the grain of their pictures; each tree grows in one of Factorio's variations and leaf
colours. A tree model is still variation a's shape: the client scales it to the others and lays the
fallen ones down (`client/data/nature_looks.json`, from `tools/models/nature/tree_looks.py`; run it
again after changing a tree's height or its materials' names). `tools/models/nature/raster.py`
draws one beside its sprite without Blender, `score.py` scores its silhouette against the sprite,
and `build_plain.py` builds the nature models without Blender (then part_colors.py, as after any
build). Crowns are clumps of leaf cards round small dark cores (`leaf-shadow-*`); solid leaves
(`leaf-*`, tree-06's strands) are drawn with the leaf cards' shader too, so pollution takes them.
Their UV tells them apart where model_library.gd merges them into one surface: cards 0-1, cores
(-1, -1), solid leaves (-2, -2). A tree's shadow stand-in casts its crown from a surface of its own
that drops what pollution took (model_lods.gd `crown_arrays`, shadow_stand_in_leaf.gdshader).

Models under their own licence are a pack of their own, its licence in its `pack.json` and a README
beside them, as FUE5's are (`packs/fue5/`, CC BY-NC-SA 3.0).

## Model packs

Every model the client draws comes from a model pack (`client/scripts/world/model_packs.gd`), found
by file name (`<prototype-name>.glb` or `.gltf`). Besides the three built in, the `models` folder
beside Zenith (the checkout's root, or beside `Zenith.exe`) holds any number of them, loaded at
runtime without importing them into the project:

- the `.glb` and `.gltf` files at its top: one pack, "Loose models";
- each folder in it: a pack, its models anywhere inside, in any layout (in one pack the model nearest
  its top wins, then `.glb` over `.gltf`);
- each `.zip` in it: a pack the same way, read without unpacking it by hand. Zenith unpacks it once
  into `user://model-packs/<zip name>-<size>-<modified>/`, on a worker thread at start-up (models
  wait for it; play doesn't), again only when the zip changes, and removes the copies of zips changed
  or gone, so a `.gltf`'s own `.bin` and textures beside it work as from a folder. A download's
  `models/Zenith.zip` is one: Vasillo's models, "Zenith" (`tools/release/package.py --models`; an old
  `Default.zip`, its name before, is read as it, and left out when a `Zenith.zip` is beside it).

One order decides which pack's model is drawn: the higher pack wins when two have a model of the
same name. It is kept in settings.cfg's `[model_packs]` (`order` and `off`, by id: `builtin:<folder>`,
`loose`, `dir:<folder>`, `zip:<file>`). A new pack of the models folder goes on top, on; a built-in one
not saved yet goes under the folder's, so by default, from the top (the owner's order): Default (when
there is one), FUE5 (Adapted), Wube3DP (Adapted), Placeholders, Factorio. Built-in `assembling-machine-1..3`
prefer Placeholders' rebuilt PBR/animated versions by default (`--assembler-models=old` restores pure pack order).
Every pack moves and switches off, Placeholders too.

**Factorio** (`builtin:factorio`, `ModelPacks.FACTORIO_ID`) is a built-in pack with no files: its content
is the player's install, read at run time (nothing of Wube's is committed or shipped). Its picture is the
install's `data/core/graphics/factorio-icon.png`, its credit "© Wube Software · from your install". It
offers each entity's resting picture on a card facing Factorio's camera, a "cardboard cutout"
(`client/scripts/world/sprite_standins.gd`: in a game the bridge's graphics list, `mod_graphics.gd`, which
has every entity's, mods' too; without one `client/data/sprite_projection.json`'s frames of the base and
Space Age entities, cut from the install's sheets), each item's icon card (`item_cards.gd`) and the
install's icons. Characters, vehicles and creatures (pictures round the turn) keep their models. Where it
is above the pack that has a family's model (or is chosen for it, or is a building's own pack in the
model chooser), the family is drawn as its card (`ModelPacks.sprite_wins`, `ModelLibrary.draws_sprite`);
an item as its icon card; an icon as the install's. Under every pack in use (the default, and where an
order saved before it puts it) it keeps its old roles: the icons below every pack, the cards for entities
no pack has. An entity no pack in use has a model for is its card with Factorio on, else Zenith's box in
its map colour. Without an install (and no game's list) it is listed greyed with the reason and gives
nothing. For the Model packs window's preview: `ModelPacks.is_sprite_pack(pack or id)`,
`ModelPacks.sprite_names()`, `SpriteStandins.picture(name, direction)` (the card's Mesh, texture, centre,
pixels a tile and size; `{}` while composed, ask again after `SpriteStandins.poll()`),
`SpriteStandins.has_picture(name)`, `SpriteStandins.item_card(item)` and `item_picture(item)`.

The Model packs window (`client/scripts/menu/model_packs_window.gd`: the main menu, the in-game Esc
menu) lays the packs out as Minecraft does its resource packs: Available (off) and
Selected (on, the top one winning) side by side, ▶ on a pack's row adding it on top of Selected, ◀
taking it out, ▲ ▼ ordering it (Placeholders and Factorio too). A row has the pack's picture, name, model
count, where it is and its `pack.json` lines. A click on a pack lists its models by family, with a
search box; a click on one shows it turning (`client/scripts/ui/factorio/model_preview.gd`, a
SubViewport with the client's own model loading and materials), whose version is in use, and a
button per pack in use with a version of it to look at. Everything applies at once
(`ModelLibrary.apply_packs`, `apply_choices`; in a game `world.gd` `models_changed` builds the chunks
drawing those models again); trains, robots, creatures and inserter arms keep their models until a
restart, and the window says so.

A model's **family** (`ModelPacks.family`) is a prototype's model with its variants: directions
(`-east`, `-south`, `-west`), curves, line end pieces, `-input` and `-output`, pipe and wall shapes,
`-rich` and `-sparse` ores, cliff pieces, the `-attack` and `-corpse` poses; a cargo bay's edge
pieces are `cargo-bay`'s, an inserter arm's parts `inserter-arm-<kind>`'s. The window's "Use
<pack>'s" takes a family from that pack whatever the order (settings.cfg `[model_packs]` `choices`,
family -> pack id): each variant the pack has, a tier it has only the base of (`fast-transport-belt`
from `transport-belt`) as the base recoloured, and a variant it lacks from the order. "By the order"
gives one back, "Reset choices" all of them.

**One building:** a building window's Model button, in its title bar beside the circuit buttons,
opens the model chooser (`client/scripts/ui/factorio/model_chooser.gd`): a card for every pack in use
with a model of that building (its own variant: a curved belt's curve, the way it faces), each
turning in its preview. "This one" draws that building alone with the pack's model, kept per save and
unit number in `user://building_models.cfg` (`client/scripts/world/building_models.gd`) and
forgotten when the game says it was mined or destroyed; "Every one" sets the family's choice, as the
window does. "Usual model" and "Every one by the order" undo them. The building moves to that model's
MultiMesh in its chunk at once. Client only: nothing goes to the game. An inserter's arm
(`inserter_arms.gd`) and the building window's own picture of the entity keep the usual model.

An optional `pack.json` at a pack's top (or one folder down; a built-in pack's at its top) names it
in the window:

```json
{"name": "Vasillo's belts", "version": "1.2", "author": "Vasillo", "licence": "CC BY-NC 4.0",
 "description": "Textured belts, splitters and undergrounds.", "icon": "transport-belt"}
```

`shading` (optional): `"pbr"` draws the pack's materials (pictured or plain colours), and its pictured items, as
their files say (glTF's PBR as Godot's own material draws it, metal in full reflecting a neutral surrounding lit as
the moment is, with the look's fill on top; model_packs.gd
`shading()`), `"factorio"` or none with Zenith's Factorio-style balance. Zenith's own packs are always
`"factorio"`. The Model packs window's card shows it; Settings > Graphics > Advanced > Packs' own shading
(Factorio's everywhere) and `--pack-shading=factorio` turn it off for every pack (docs/RUNNING.md).

`aliases` (optional): `{"coal-ore": "coal", "stone-ore": "stone"}`, the pack's own names for Factorio's (model_packs.gd
`alias_name`): its `coal-ore-1.glb` is read as `coal-1`, `coal-ore-rich.glb` as `coal-rich`, `items/`, `icons/`
(`icons/item/coal-ore.png`) and `tiles/` (`tiles/coal-ore.png`) the same way; a file the pack also has under Factorio's own name keeps it.

**Variants**, one rule for every entity model, item model (`items/`) and icon (model_packs.gd `variant_base`,
`variants_in`): `<name>-1.glb`, `<name>-2.glb`, ... (numbered from 1) and `<name>.glb` are the variants of `<name>`,
with or without the plain one. The Model packs window lists them as one entry (`Sulfur (3)`), in the Models, Items
and Icons tabs. Each placed entity, rock or ground item draws one at random, the same on every load and in every
view: a hash of its position (`variant_seed`; the record's client-only `extra.zv`, world.gd). An icon has no place:
its name picks one, the same everywhere. A name that is a prototype of its own in Factorio (`assembling-machine-2`,
`speed-module-3`, `tree-04`, `uranium-235`: data/icons.json) is never a variant. Ores are as before: their numbered
models are the scattered rocks (`ore_rocks`), their tiles' stage models aren't picked. Items on belts and in hands
show the first variant. `--model-variants=off`: always the plain model (docs/RUNNING.md).

`short_name` (optional) is the name in lines like "Use FUE5's" and "FUE5's models" where the full one
reads badly: the two built-in packs of other people's models are "FUE5 (Adapted)" and "Wube3DP
(Adapted)", short "FUE5" and "Wube3DP". `icon` names the model drawn, still, as the pack's picture; a `pack.png` (or `icon.png`) at the pack's
top comes before it, and without either the pack's first model is drawn. `icon_image` (optional)
comes before all of them: a PNG, JPEG or WebP picture in the pack, its path from the pack's top or
from the folder its `pack.json` is in (`"icon_image": "logo.png"`), or `"factorio:<path>"` for one
read from the player's Factorio install, its path from the install's folder
(`"factorio:data/core/graphics/wube-logo.png"`, Wube3DP's: Wube's pictures are never committed or
shipped, so a pack points at the install's copy). A picture that isn't there, or isn't one, leaves
the pack its model picture. The download's Default pack carries Zenith's gear (`zenith.png`,
`client/icon.png`, put in by `tools/release/package.py`); FUE5 keeps its locomotive (FUE5's repo has
no logo file of its own, `packs/fue5/README.md`).

A pack that isn't built in is a modeller's to Zenith wherever its models lie: their vertex colours
are Blender's own unless they carry Zenith's baked layout. In any pack, one model of a direction
entity is turned to every direction unless the same pack has all four. The start-up log says how many
models come from which packs, which are off or left out and which models a higher pack covers; the
debug menu's Tests > Model packs lists every model's pack.

A pack may also carry icons that replace Factorio's wherever Zenith's UI draws one (every icon goes
through `item_icons.gd`, which asks `model_packs.gd` `icon_file()` first): an `icons/` folder at the
pack's top or one folder down (in a folder, a zip or a built-in pack alike; the models folder's own
top `icons/` is the loose pack's), `icons/<name>.png` for the prototype of that name whatever its
kind, `icons/<kind>/<name>.png` for one kind (`item`, `entity`, `fluid`, `recipe`, `technology`,
`virtual-signal` or `signal`, `space-location`, `item-group`), the kind's file first. Square PNGs of
any size (one that isn't square is cut to its middle), mipmapped. They go by the packs' order, the
replacing packs before those that fill in; the Icons tab's choice for one is kept in settings.cfg
`[model_packs]` `choices` as `"icon:<name>": <pack id>`. Below every pack, the install's icon (or
nothing without one, as before). The icon caches are dropped when the order, a switch or an icon
choice changes (`ModelPacks.icons_version`). No built-in pack ships icons (Factorio's are Wube's,
read from the install). A pack of icons alone is a pack.

A pack may carry sounds too, file for file in place of Factorio's (`sound_bank.gd` `locate()` asks
`model_packs.gd` `sound_file()` before the install): a `sounds/` folder at the pack's top or one folder
down (the models folder's own top `sounds/` is the loose pack's), under it the file's Factorio path:
`sounds/core/sound/gui-click.ogg`, `sounds/base/sound/walking/grass-3.ogg`,
`sounds/space-age/sound/walking/snow-1.ogg`, `sounds/<mod-name>/...` for a mod's. Ogg Vorbis only (an
Opus file is skipped, with a warning, for the next place's). The rules (volume, variations, pitch,
aggregation) stay Factorio's prototypes'. Same order and switches as the icons; a choice kept as
`"sound:<path>": <pack id>` (no picker yet). A pack below the Factorio pack gives only what Factorio
(the install and the game's mods) hasn't. The decoded sounds are dropped when the order, a switch, a
sound choice or Settings > Sound's "Sounds from model packs" changes (`ModelPacks.sounds_version`);
`--pack-sounds=off` leaves every pack's sounds out. Packs carry their authors' own sounds, never
Factorio's; no built-in pack ships any. A pack of sounds alone is a pack.

A pack may carry ground textures too, in place of Factorio's terrain (`terrain_textures.gd` asks
`model_packs.gd` `tile_source()` before reading the install): a `tiles/` folder at the pack's top or
one folder down (the models folder's own top `tiles/` is the loose pack's), holding `.png`, `.webp`,
`.jpg`, or `.jpeg` images. Put each tile at `tiles/<tile-name>.png` (e.g. `tiles/grass-1.png` or in a
subfolder like `tiles/nauvis/grass-1.png` — Factorio tile suffixes like `-1` and `-2` stay part of the
name), or put numbered variants inside a folder named after the tile (`tiles/grass-1/1.png`,
`2.png`, ...). Companion PBR maps (`-normal`, `-height`/`-bump`, `-roughness` or `_normal`,
`_height`, `_bump`, `_roughness`, or `<tile>/normal.png` etc.) in the same format can sit beside a
pack's own albedo or on their own (PBR-only) to layer tangent normals, height parallax/AO, and
per-pixel roughness onto Factorio's terrain (`--pack-tile-pbr=off` disables companion maps; albedo-only
packs above never mix with a lower pack's PBR maps). `terrain_textures.gd` accepts a full
Factorio-size tile sheet (`>= 2048x1024`), a horizontal strip (`width = height * count`, with `"count"`
set in `"tiles"`), or one or more seamless images (scaled to `64` px per `1x1` cell across the tile
atlas). Optional `pack.json` `"tiles"` entries (supporting `*` wildcards such as `"grass-*"`:
`{"grass-1": {"size": 1, "count": 4, "roughness": 0.9, "specular": 0.08, "normal_strength": 1.0,
"height_strength": 1.0, "normal_flip_x": false, "normal_flip_y": false}}`) override `size` (`n` for
`nxn` or `[w, h]`), `count`, `roughness`, `specular`, or PBR map scale/orientation. Same pack order and
switches as icons and sounds; the Tiles tab saves a choice as `"tile:<name>": <pack id>`, a pack below
Factorio gives only tiles Factorio hasn't, and changing the order, choice, or Settings > Graphics >
"Ground textures from model packs" (`[graphics] pack_tiles`, `--pack-tiles=off`) reloads the ground
live (`ModelPacks.tiles_version`). A pack of tiles or companion maps alone is a pack.

A pack may also carry 3D models (`.glb`, `.gltf`) or 2D images (`.png`, `.webp`, `.jpg`, `.jpeg`) for
decoratives and grass (`decoratives.gd` reads `model_packs.gd` `decor_source()` before reading the
install): a `decoratives/` folder at the pack's top or one folder down (the models folder's own top
`decoratives/` is the loose pack's). Put each decorative at `decoratives/<name>.glb` or `.png` (e.g.
`decoratives/green-hairy-grass.glb` or `decoratives/small-rock.png`), or group numbered variants
(`-1`, `-2`, ... or inside `decoratives/<name>/1.glb`, `2.glb`, ...). The built-in `Placeholders`
pack ships 3D placeholder `.glb` models for all 48 raised decoratives (23 grass/bush/carpet types and
25 upright `"object"` plants, corals, fungi, icebergs, and stumps), and 2D pack images automatically
drive flat decals, upright cards, and 3D raised grass shaders. Optional `pack.json` `"decoratives"`
entries (supporting `*` wildcards) override `scale`, `size` (`[w, h]` or `n`), `shift` (`[x, y]`),
`layer` (`"decals"`, `"decorative"`, `"object"`, etc.), `grass` (force 3D grass on/off), `grass_height`,
`grass_style` (`"tuft"`, `"bush"`, `"carpet"`), or `hide` (`true` suppresses that decorative). The
**Decoratives** tab previews 3D models or 2D swatches beside Factorio's and saves per-decorative choices
as `"decor:<name>": <pack id>`; changing the order, choice, Settings > Graphics > **Decoratives from
model packs** (`[graphics] pack_decoratives`, `--pack-decoratives=off`), or Settings > Graphics > **3D
decorative models** (`[graphics] decor_models`, `--decor-models=off`) rebuilds decoratives live
(`ModelPacks.decor_version`). A pack of decoratives or `"decoratives"` hide rules alone is a pack.

A pack holding a copy of any file of the player's Factorio install (byte for byte, over 1 KB: a sound,
a picture, anything) is not loaded at all, none of its models, items, icons, tiles, decoratives or sounds, and its card in
the Model packs window is red with the copies listed (`pack_check.gd`, the owner's rule; every pack is
checked but the Factorio pack and Wube3DP, and there is no switch: it is a bound, not a look).

`-- --models=/path/to/folder` adds one more pack, on top for that run, which only fills in entities no
other pack has a model for; add `--models-first` for it to win over every pack (a modeller trying a
new version). `-- --no-custom-models` leaves the models folder's packs out; the built-in ones stay.

## Moving parts

`model_library.gd` leaves every node named `anim_<kind>` (and everything under it) out of the
static mesh and keeps it as its own mesh, in model space at rest. `chunk_view.gd` draws each
such part as one MultiMesh per chunk next to the static one. The model shader turns, slides and
lights the parts (`factorio_material.gdshaderinc` `anim_vertex`) from each instance's state, which
`client/scripts/world/anim.gd` writes only when it changes (the machine starts or stops, a robot
comes near), so every loaded chunk animates at no script cost; turret heads, the asteroid
collector's arm and worms are still moved by script, near the camera. A part is drawn at
`entity * pivot * rotation(axis, angle) * inverse(pivot)`, where `pivot` is the node's transform,
so put the node's origin on the axis it turns about. The weathering stays painted on the part as
it turns.

| Node name | Turns about | When | Models using it |
|---|---|---|---|
| `anim_spin_drill` | node's Y (up) | while the machine works (`st`), clockwise from above | electric and burner mining drill |
| `anim_spin_arms` | node's Y | while working | custom pack assembling machines |
| `anim_gear_am1_*`, `anim_arm_am1_nw`, `anim_head_am1_e`, `anim_fan_am1_w` | `CYCLES` | while working | assembling machine 1 (wube3dp) |
| `anim_am2_*`, `anim_am3_*` | `CYCLES` | while working | assembling machines 2 & 3 (placeholders) |
| `anim_spin_flywheel` | node's X (east-west) | while working | steam engine |
| `anim_turret_head` | node's Y | where the mod says the turret aims (`ts`, `turrets.gd`: turning, raising and folding at the prototype's speeds); barrels point north at rest | every turret, the car, tank and artillery wagon |
| `anim_spin_crane` | node's Y | while working, slowly (`SPIN_SPEEDS_EXTRA`) | agricultural tower (its crane) |
| `anim_glow_*` | doesn't move | glows (its colour as emission) while working, dark when idle; `<style>` picks its look (below) | lab, beacon, electric furnace, nuclear reactor, thruster, Space Age machines... |
| `anim_upright_still` | doesn't move | always faces north, whatever way the entity faces | pumpjack frame |
| `anim_upright_rock_beam` | node's Z (north-south) | rocks +-0.2 rad in step with the model's `spin_crank` | pumpjack beam |
| `anim_upright_spin_crank` | node's Z | while working | pumpjack cranks |
| `anim_spin_fan` | node's Y | while working | electric furnace (its two fans) |
| `anim_door_n`, `anim_door_s` | slide (`SLIDE_KINDS` in `model_library.gd`): apart and down into the body | open while a robot flies within 3 tiles (a client-side guess) | roboport hatch |
| `anim_charge` | doesn't move | its emissive material lights while a robot is within 3 tiles | roboport charging points |
| `anim_gate_door` | slides 1.27 tiles down (`SLIDE_KINDS`) | sinks into the ground while the character is within 2.5 tiles or a friendly vehicle within 4 (a client-side guess), at Factorio's gate speed (a quarter second) | gate |
| `anim_spin_rotor` | node's Y | while working | centrifuge (three rotors) |
| `anim_lit_green`, `_yellow`, `_red`, `_blue` | doesn't move | hidden, then shown and lit while the signal's reported colour (`st`) is that one | rail signal (three lenses), chain signal (its glass) |
| `anim_lit_charge`, `anim_lit_discharge` | doesn't move | shown, flickering, while the accumulator charges / discharges (`st` 1 / 2) | accumulator (glow on the cells, arcs round the frame, `kit.arc`) |
| `anim_lit_strike` | doesn't move | shown after a lightning strike lands on it (`lt`), fading over a few seconds | lightning rod and collector (sparks) |
| `anim_bob_a`, `anim_bob_b` | slide (`MODEL_SLIDES`) and back | while working, half a cycle apart, at the sprite's loop | pump and offshore pump (pistons in their windows) |
| `anim_switch` | slides (`SLIDE_KINDS`) | in while the power switch is on (`st` 1), in half a second | power switch (its contact) |
| `anim_hatch_e`, `anim_hatch_w` | slide apart (`SLIDE_KINDS`) | open while a robot is within 1.2 tiles (a client-side guess) | logistic chests (Wube's; the hatch's halves, from a `wube_recipes.py` paint rule) |
| `anim_spin_gear` | node's Y | always (the belt always runs) | splitter and lane splitter (gear wheels on the lid) |
| `anim_crank_split_wa`/`_wb`/`_ea`/`_eb` | node's Z (north-south), `CYCLES` | always: each pair lifts its inner ends 55 degrees and lays them down once per 0.76 s loop, the east pair half a loop behind | splitter and lane splitter (oval cranks, pivoted at their outer ends) |
| `anim_slide_split_rack` | slides 0.9 tiles west and back (`CYCLES`) | always, once a loop | splitter and lane splitter (rack housing on the front rod) |

`anim_upright_*` parts keep facing north (their part colours come from the model's `<name>.upright`
sprite entry; Factorio draws the pumpjack's beam, post and gearbox as one layer for every direction; only its
ground pipes turn). The electric mining drill (Wube's model) spins only its auger.

Cycling parts and hatches are listed by kind in `model_library.gd` (kind names are global, so they
carry their model's name):

| Table | Moves | When |
|---|---|---|
| `CYCLES` | `slide` (model space) out and back, or `angle` radians about `axis` (the node's frame) either way (`wave` "swing"), out and back ("out") or round ("spin"), once per `period` seconds: Factorio's loop, frame_count / animation_speed / 60 | while working, easing up and down like spinning parts |
| `HATCHES` | `slide` (model space) open | while a mover of `types` (a cargo pod, the silo's rocket) is within `reach` tiles, taking `time` seconds (a client-side guess) |

`anim_glow_<style>` picks its look from `GLOW_STYLES`: `fire` flickers (`glow_flicker`), others pulse
(`glow_pulse` deep, `glow_rate` a second); no entry is steady. Emissive materials named `fire`, `flame`
or `molten` flicker as `fire` wherever they are.

Spinning parts ease up to speed in about a third of a second and coast to a stop in about a
second. Speeds are `SPIN_SPEEDS` / `MODEL_SPEEDS` in `anim.gd` (turns per second, picked to look
like Factorio's animation loops). Emissive materials (the stone furnace's `fire`) behave like
`anim_glow_*`: lit while the machine works, dark when it's idle. Entities the mod doesn't report
states for (turrets, chests) count as always working for glows, but inserters, whose glow (a burner
inserter's lit burner) follows their hand: lit while it moves, as Factorio's burner burns fuel only then
(anim.gd `ARM_STATE_TYPES`, `-- --inserter-glow=always` as before). Blender names like
`anim_spin_drill.001` and Godot's `anim_spin_drill2` work too (the number is dropped).

Belts move in the shader: the `belt_surface` material's slats scroll the way items travel at the
tier's speed (1.875 tiles/s for yellow, 3.75 fast, 5.625 express, 7.5 turbo), round the arc on
`-curve-left` / `-curve-right`, continuing from tile to tile. The shader also paints Factorio's
chevron on every other slat in the tier's colour (yellow, red, blue, green: `BELT_CHEVRONS` in
`model_library.gd`), moving with them, so a model needs no chevron geometry. Anything on top of
the surface that isn't `belt_surface` stays still, so a belt model should give everything that
moves with the belt the `belt_surface` material. A transport belt's frame (`tier_paint`) is bare
steel on every tier, as Factorio's belt sheets have it (`STEEL_FRAMES`); undergrounds, splitters
and loaders take the tier's paint.

The return run: a textured `belt_surface` (a modeller's) is drawn coming back under the rollers too,
seen through an open frame and round a line's end pieces (`client/scripts/world/belt_return.gd`).
Model the return as part of the surface, as Vasillo's belts have it: a strip just above the ground
(0.006 tiles), under the rollers, facing down, its UVs running the other way round the loop. Models
are drawn one side to a face, so Zenith adds that strip's inner side, facing up at the rollers, shaded
as in the belt's shadow. A surface with only its top run gets the top mirrored under itself, its lowest
point at 0.006, its UVs mirrored along the belt; the same scroll runs either backwards at the tier's
speed. Faces count as the top run when they look up, as the model's own return when they look down
from at least 0.1 tiles under it. Line end pieces (`-start`, `-end`) get none (their surface is the
wrap round the roller), nor do Zenith's own belts (drawn slats on a closed frame). It is only drawn at
full detail, not in the shadows or far away; `-- --belt-return=off` leaves it out to compare.

## Variants

Some entities are drawn with a variant model picked from their entity record
(`model_library.gd`, `model_name`). If the variant is missing the client falls back to the
plain prototype model.

| Entity | Record | Model |
|---|---|---|
| Transport belt | `extra.s` = `s` / `l` / `r` | `<name>.glb`, `<name>-curve-left.glb`, `<name>-curve-right.glb` |
| Underground belt | `extra.u` = `i` / `o` | `<name>-input.glb` (entrance), `<name>-output.glb` (exit) |
| Rail pieces (`straight-rail`, `half-diagonal-rail`, `curved-rail-a`, `curved-rail-b`, and `elevated-` ones) | the direction: 0, 2, ... 14 | `<name>.glb` for direction 0 and `<name>-ne.glb` for 2, both turned by the rest in quarter turns (`turn_dir`) |
| Wall | `extra.wc` = connection bits like pipes, to walls and to gates running the same way, plus 16 when the walls east, south and south-east make a 2x2 block (set by `world.gd`) | `stone-wall-<sides>.glb` named by the sides it joins (`pylon`, `n`, `ew`, `es`, `nesw`, ...), `-fill` adds the block that fills a 2x2 group's middle |
| Pipe | `extra.pc` = connection bits, north 1, east 2, south 4, west 8 (set by the client, `world.gd`) | `pipe-<shape>.glb`, one per Factorio pipe picture: `straight-vertical`, `corner-up-right`, `t-left`, `ending-down`, `cross`, `straight-vertical-single`, ... |
| Heat pipe | `extra.pc`, as pipes, from neighbouring heat pipes only (`world.gd`) | `heat-pipe-<shape>.glb`, the same 16 shape names (`tools/models/nuclear.py`) |
| Entities in `FACING_MODELS` (boiler, steam engine, offshore pump, pipe-to-ground, valves, inserters, burner drill, pumpjack, chemical plant) | the direction | `<name>.glb` for north, `<name>-east`, `-south`, `-west.glb`, drawn unturned (Factorio rendered their four pictures apart) |
| Cargo bay | `extra.cb`: a neighbour mask for each of its four 2x2 cells, from the tiles hubs, bays and landing pads cover (set by `world.gd`) | `cargo-bay.glb` plus, on each cell, the edge pieces Factorio's connection tileset puts there (`cargo_pieces`): `cargo-bay-wall-n`/`-e`/`-s`/`-w` on a side facing no cargo area, `cargo-bay-corner-nw`... where two such sides meet, `cargo-bay-inner-nw`... where two joined sides leave the cell between them empty; drawn unturned (`chunk_view.gd`), none where a bay meets the hub or another bay |
| Biter and spitter corpses | the direction the unit faced when it died | `<name>-corpse.glb` and `-corpse-1` to `-3`: Factorio's four falls, taking turns round the 16 directions |

Curves face their output direction like straight belts: `-curve-left` takes items in from the
west edge and sends them out of the north edge (items turn left), `-curve-right` from the east
edge. Both underground ends are modelled as their Factorio sprite for "north" looks: the hood's
mouth opens south. For the entrance that is the way items travel (in from the south). The exit
model faces back at its entrance (chevrons pointing south), but in Factorio 2.x an exit's
`direction` is the way its items travel, like its entrance's (checked in 2.1.23), so the client
turns exits half way round (`ModelLibrary.turn_dir`) and scrolls the exit's belt south in model
space.

Pipes connect to neighbouring pipes, and to a pipe-to-ground whose above-ground end faces them.
The client doesn't know machines' fluid connections, so a pipe ending at a machine shows an end
cap. "up" in the shape names is north, as in Factorio's sprite names.

Higher belt tiers without their own model (`fast-`, `express-`, `turbo-` belts, undergrounds
and splitters) use the yellow model with its `tier_paint` material recoloured
(`TIER_TINTS` in `model_library.gd`).
Fast, express and turbo loaders use `loader.glb` the same way.

Belt line ends: a modeller's `transport-belt-start.glb` and `transport-belt-end.glb` (and the tiers'
own, `fast-transport-belt-start.glb`...; a tier without them wears the yellow ones recoloured) are
drawn where a line of belts begins and ends, so the belt rolls over a roller there. They are modelled
with the belt running east (start to the west, end to the east, the belt's tile between) and turned
onto the belt. The client works out the line ends from the neighbours (`world.gd` `_connect_belt`):
a start where nothing feeds the tile from behind, an end where nothing in front carries the line on
(`belt_continues`): a belt, splitter, loader or underground entrance going the same way does, and a
curve the belt makes (fed from its side by it, `extra.s`); one head-on doesn't, nor does a belt facing
into the side of a straight belt, of a curve fed from its other side or of an underground: that is
side-loading, where Factorio draws the feeding belt's ending sprite. They go on straight belts (curves at their
end only), on each half of a splitter on its own (a lone splitter gets four: both halves' back and
front, each on its half's tile), and on an underground's open end: an entrance's back, an exit's
front (facing the way items travel, though the exit's model is turned round). Splitters and
undergrounds wear the belt pieces of their tier (`fast-splitter`: `fast-transport-belt-start`).
No shift is needed on them: their belt surfaces end on the tile's edge as a belt's does. A piece's
moving part that the model already has in the same place is left out on that model (a splitter's
rollers at its back: the start piece's roller would turn inside it). Nothing is drawn without the
pieces: Zenith's own belts have none.

Movers (vehicles, robots, the rocket) are drawn by `movers.gd`. Their moving parts are moved by
`vehicle_anim.gd` (the spidertron's legs and shell, robots' thrusters and lights, cargo pods'
panels, the tank's treads) and `turrets.gd` (the tank's, car's and spidertron's guns, the
artillery wagon's cannon, aimed where the mod reports).

## Space Age models

`space_platform.py` (hub, cargo bay, thruster, asteroid collector, crusher, asteroids),
`vulcanus.py` (foundry, big mining drill, demolishers, ashland lichen trees), `fulgora.py`
(electromagnetic plant, recycler, lightning rod and collector, tesla turret, fulgurite, the ruin
attractor) and `space_nature.py` (volcanic rocks, chimneys, fulgoran ruins, the sulfuric acid
geyser, scrap). Their sprite numbers are in `space_sprites.py`, which `sprite_projection.py` and
`gallery.py` both read. Rocks, chimneys and ruins are fitted to their sprites' silhouettes
(`space_profiles.py`, measured numbers only; see `space_nature.py`).

- **Hanging parts:** the thruster's bell and the asteroid collector's chute hang off the deck's
  edge below ground level (`sink` in `specs.py`); nothing is drawn under a platform's edge.
- **Demolishers** are a head, a train of segments and a tail, each its own prototype at its own
  scale (`big-demolisher-segment-x1_36`). They share `demolisher-head`, `-segment` and `-tail`,
  made at the big demolisher's scale; `model_library.gd` `mover_model` picks the model and scale
  from the name; `demolishers.gd` draws each part at its scale, gliding after the head.
- **Asteroids** are movers centred on their position, one model per size and kind.
- The thruster reports its working state (`thruster` in the mod's animated types), so its exhaust
  glows only while it fires.

## Converting Wube's printable models

Where Wube released an official 3D-printable model (Friday Facts #447), we convert that instead
of modelling it ourselves. `tools/models/wube.py` turns the print files into client models;
`tools/models/wube_recipes.py` says how each model is put together.

1. Download each model set from https://www.printables.com/@WubeSoftware/models ("Download all
   model files"). Printables doesn't allow scripted downloads, so this is by hand. Check the
   licence on each page (listed as CC BY-NC).
2. Put the zips (or the extracted folders, any layout) under `art-src/wube/`. That folder is
   git-ignored: the print files are never committed.
3. Convert, check and import:

```bash
pip install numpy scipy trimesh fast-simplification   # once (plain Python, no Blender)
python tools/models/wube.py --list      # which recipes have their source files
python tools/models/wube.py             # converts everything it can find, or name models
python tools/models/check.py
godot --headless --path client --import
```

Converted models go into `packs/wube3dp/`, which is above Placeholders in the order, so they replace
the procedural ones with the same name. `build.py` without names then leaves them alone (it reads the
generator tag in the `.glb`); name a model to rebuild it procedurally (it is written over the
conversion, where it is). `packs/wube3dp/CREDITS.md` lists every converted model and its source files.
A pose (`creature_pose.py`) goes beside its source, the worm, built from its sprites, into
placeholders.

What the converter does: millimetres to tiles (25 mm, the print grid's pitch); z-up to y-up;
picks parts off print plates and cuts away grid pegs and joining tabs; stands up parts printed
lying down; stacks parts that print separately (belt surface in its frame, hood on an
underground, lid on a logistic chest); turns the model to face north; colours each part from
the `kit.py` palette (the belt frame is `tier_paint`, so faster tiers get recoloured), or by
face where one print part has several colours (`paint`: a logistic chest's coloured lid and
panels, the pole's wood, steel and insulators); scales each model to its Factorio sprite
(`scale`, `untaper`, `shift`: Wube's prints are stylised, chests drafted narrower at the top,
belts twice as tall as Factorio's; the numbers come from fitting the silhouette from Factorio's
camera); and decimates to the budget in `specs.py`, in Blender when it's installed (its collapse
decimator keeps dense prints like the assembler recognisable where the plain-Python one leaves
shards). `--raw DIR` converts every source file on its own,
unassembled, to look at when writing a recipe.

Recipes so far: the stone wall (16 connection pieces and the fill-in block), transport belt and both curves, underground entrance and exit, all eight chests
(the one-piece "Closed" files), assembling machine 1, stone furnace, steel furnace (with its
three pipes), the electric mining drill, the inserter platform ("Base Single", coloured per tier
for all six inserters, a model per direction; the client draws the arm), the small electric pole
(two half-shells back to back, standing in its cast foot), and the creatures below. `CREDITS.md`
has the full list.

Inserter arms (`inserter-arm-<family>-upper`, `-hand-open`, `-hand-closed`, families `basic`,
`long`, `bulk`, `stack`) come from the inserters set's arm prints, which lie flat on the plate. Each
piece is exported with the joint it turns about at the origin (recipe option `pivot`, plate
millimetres) and pointing north, and plate pieces are picked by where they lie (`pick_box`).
`inserter_arms.gd` draws them: the upper arm from the shoulder on the base to the elbow, the hand
from the elbow to the wrist (closed while it holds an item), stretched to the inserter's reach and
painted in its colour (the `tier_paint` material). Burner, yellow and fast inserters share the
basic arm.

Wube models without a recipe yet:

- **Splitter:** its top is the belts and mechanism laid flat for printing; it needs taking apart.
  The procedural splitter stays until then.
- **Worm:** Wube's printed worm is a slim column in a ring of spikes, unlike Factorio's sprite, so
  the worm is built from the sprites instead (`tools/models/worm.py`).
- **Belt items:** made from the icons instead (see "Items" below).

## Converting FUE5's models

At the owner's choice, 39 base-game entities are drawn with the textured models of FUE5
(https://github.com/FUE5BASE/FUE5, a fan remake of Factorio in Unreal Engine 5 by Hurricane and
Nuke, CC BY-NC-SA 3.0). They are the FUE5 pack, `packs/fue5/`, with their own README (licence,
credit, and which FBX file each came from); ours stay in their packs and recipes. By default FUE5 is
above Wube3DP and Placeholders, so all 39 are drawn in place of ours, the 7 Wube3DP has too (electric
mining drill, small electric pole, stone and steel furnace, wooden, iron and steel chest) included;
Wube's stay in their pack, drawn when the player puts Wube3DP higher or chooses it for them in the
Model packs window. Deleting a file in `packs/fue5/` brings ours back.

1. Put FUE5's `Content/MyStuff/ENTITIES/STRUCTURES` and `VEHICLES` folders (each model's FBX files
   and the .jpg textures beside them) under the git-ignored `art-src/fue5/raw/`.
2. Convert (needs Blender: `fue5_blender.py` runs inside it), check, import:

```bash
python tools/models/fue5.py [names...]          # recipes in fue5.py RECIPES
python tools/models/fue5.py --score [names...]  # silhouette overlap with the sprite, ours and FUE5's
python tools/models/check.py
godot --headless --path client --import
python tools/models/fue5.py --fix-imports       # keeps the textures embedded after the import
```

A conversion scales FUE5's units (2 to a tile) into tiles, fits the footprint, turns the model to
face north (a recipe's `yaw`, found by scoring each quarter turn), cuts it at the ground, drops
ground decals, decimates to the budget in `specs.py` and bakes every texture into one atlas per
model. Moving parts come from FUE5's animated FBX files: meshes are split by bone into `anim_*`
nodes (the electric furnace's fans, the radar's dish, the centrifuge's rotors, the wagons' wheels).
Boiler, chemical plant, pumpjack and steam engine, which ours draw with a model per direction
(`FACING_MODELS`), are one model in FUE5: `fue5.py` (`FACINGS`) writes the north one, fitted to all
our directions, and the client turns it, as the pack has no direction models of its own
(`model_library.gd` `single_model`).

## Materials: Factorio's colours, its sprites and the weathered fallback

Every model surface is drawn with one material, `client/shaders/factorio_material.gdshader`
(`factorio_material_alpha.gdshader` for see-through glass). `model_library.gd` builds it from the
imported material: base colour, roughness, metallic and emission carry over.

With Settings → Graphics → Merged materials on, the client draws a model as one surface per shader
(solid, see-through, leaf cards; a textured material keeps its own), not one per glTF material,
since every surface is a draw of its own: when it loads a model it merges the
surfaces and gives the result one material whose table has a row per glTF material
(`material_rows.gd`), each vertex's row in `CUSTOM2` (made at load, not stored in the file). So use
as many materials as the look needs: then they cost nothing at draw time. Up to 24 per shader share a
surface.

Models are drawn in **Factorio colours**: each part in its own colour sampled from Factorio's
sprite when the model was built (below), with the weathering on top. `-- --model-look=palette`
(for comparing) shows the palette colours the models were built with instead. The old look that
projected the sprite itself onto the model (Settings → Graphics → Model look, "Factorio sprite
projected") is gone, and with it the depth maps it needed.

0. **Part colours** (`tools/models/part_colors.py`, stored in the `.glb` as `TEXCOORD_4` and `_5`,
   the shader's `CUSTOM1`). The model is cut into patches (one material's triangles joined across
   edges that bend less than 35 degrees: each face of a box, each panel of a converted model) and
   rasterised from Factorio's camera into each of its sprite pictures, the way the client projects
   them (nudged up to 5 px to fit the sprite's silhouette best). Each patch's pixels, eroded so
   outlines don't bleed in, are divided by the light painted into the sprite (a key light from the
   west, 50 degrees up, and ambient, fitted over ~6000 patches of every model) and reduced to their
   densest colour (CIELAB; lit pixels count for more than crevices and painted shadows). For a
   model built by hand from the sprite (kit, nature, Space Age), whose parts rarely sit exactly
   where the sprite has them, each material first gets the sprite's colour nearest its palette
   colour (or the colour most of the pixels under its parts agree on), and a patch keeps its own
   colour only when it is close to that; Wube's conversions, which are the sprites' own geometry,
   keep each patch's own. A small solve over the patch graph then fills patches the camera doesn't
   see from their neighbours (of the same material and tilt first: a box's hidden east face takes
   its south face's colour, not its lid's) and their material. The shader balances them against
   Godot's sun (`part_light`), so a top face shows its colour about as Factorio's view does. Higher belt and inserter tiers and
   the smaller creature tiers, which recolour a material, keep their tint on it. Models without a
   sprite entry keep the palette (pose variants take their family's colours per material).
1. **Procedural weathering**, on every model: baked ambient occlusion, grime in crevices and up from the
   ground, chipped bright edges, rust patches and streaks, dust on top, greyed colours. How much
   of each depends on the **material class**, picked from the glTF material's name
   (`MATERIAL_CLASSES` in `model_library.gd`, first match wins):

| Class | Material names containing | Weathering |
|---|---|---|
| `glass` | `glass` | dust, a little grime |
| `organic` | `flesh` (Gleba flesh and plants) | grime, a little dust, soft pale edges, no rust |
| `ice` | `ice` (Aquilo icebergs, vents) | light grime and dust, bright edges |
| `foliage` | `leaf` | its occlusion only, lighter |
| `dark` | `rubber`, `belt_surface`, `hazard_black`, `soot`, `steel_black` | dust, light grime |
| `wood` | `bark`, `wood` | grime, lighter worn edges, no rust |
| `stone` | `rock`, `stone`, `concrete`, `ceramic`, `-dust` | dirt, pale chipped edges, no rust |
| `ore` | `-chunk` (ore chunks) | keeps its colour: light grime only |
| `copper` | `copper`, `brass`, `bronze` | grime, bright copper edges, no rust |
| `rusty` | `rust` | more grime and darker rust |
| `steel` | `steel`, `iron` | most rust and streaks, bright bare-metal edges |
| `paint` | anything else (`paint_*`, `tier_paint`, `hazard`, `olive_*`, ...) | rust, streaks, edges chipped to bare metal |
| `emissive` | any emissive material | none |

Name new materials so they land in the right class (`CLASS_PARAMS` holds the numbers).
Everything varies per part (the baked random) and per instance (a hash of its position), and works
with MultiMesh: the weathering is in model space.

### Vertex data

`tools/models/bake.py` bakes this into every model; `kit.py`, `nature/build_nature.py` and
`wube.py` all call it, and new converters should too:

| glTF attribute | Godot | Contents |
|---|---|---|
| `COLOR_0` | `COLOR` | rgb: albedo multiplier (1, or the nature models' own shading; on a worm's or spawner's skinned material its mask's shade and cover, creature_skin.py); a: ambient occlusion (1 open, 0 enclosed; rays through a voxel copy of the model and the ground) |
| `TEXCOORD_0` | `UV` | planar UVs in tiles (not used by the shader) |
| `TEXCOORD_1` | `UV2` | x: worn edge (1 on narrow faces at convex edges: bevels, rims, bolts); y: random value per connected part |
| `TEXCOORD_2` | `CUSTOM0.xy` | how much Factorio's camera sees of the vertex with the model facing north, east |
| `TEXCOORD_3` | `CUSTOM0.zw` | ... facing south, west (0 where another part hides it or the face looks away) |
| `TEXCOORD_4` | `CUSTOM1.xy` | part colour red, green, linear / 4 (normalised 16-bit; `part_colors.py`, `PART_COLORS.md`) |
| `TEXCOORD_5` | `CUSTOM1.zw` | part colour blue / 4; how much of it comes from the sprite × 0.25 (0: the palette's) |
| (none) | `CUSTOM2.x` | the vertex's material row, added by the client when it merges the surfaces (leave `TEXCOORD_6` and `_7` free) |

A model without some of this still draws: missing occlusion means open, missing visibility
means "use the face's angle to the camera only".

### Sprite projection data

`client/data/sprite_projection.json` is written by `python tools/models/sprite_projection.py`
(numbers copied from `data/base/prototypes/entity/*.lua`; trees, rocks and ores parsed from the
install). The model tools (part colours, the scorers, the gallery) read it to find each model's
sprite, and the client's blueprint window draws its previews from it. One entry per model name:

```json
"boiler": {"anchor": 0.3, "mode": "direction", "cells": [
  [{"file": "base/graphics/entity/boiler/boiler-N-idle.png", "frame": [269, 221], "line": 0,
    "index": 0, "shift": [-1.25, 5.25], "scale": 0.5}],
  [...east...], [...south...], [...west...]]}
```

- `anchor`: tiles above the ground that the entity's position marks: 0.3 for buildings (as
  `compare.py`), 0 for trees, rocks and ores (as `nature/compare.py`).
- `stretch` (optional): north-south ground distances are scaled by this before projecting
  (pipes and the offshore pump, 1.346).
- `mode`: absent for one cell; `"direction"`: four cells, north, east, south, west, picked by
  the way the instance faces; `"variation"`: up to 8 cells, one picked per instance by a hash of
  its position (ore tiles); `"rotation"` (vehicles): up to 64 cells evenly round the turn,
  clockwise from north, the one nearest the instance's facing projected after turning the model
  to that frame (movers.gd turns cars and trains to their orientation). Their frames go in a grid
  atlas; optional `atlas_scale` shrinks it (0.5 for the trains' big frames).
- `cells`: each a list of layers stacked bottom first (a turret's base and head, a tree's trunk
  and leaves). A layer: `file` relative to Factorio's `data` folder, `frame` [width, height] in
  pixels, `line` frames per row of the sheet (0: as many as fit), `index` of the frame
  (row-major), `shift` in `util.by_pixel` units (1/32 tile), `scale` as in the prototype
  (0.5 for HR sheets), optional `tint` [r, g, b] multiplied in (tree leaves). `xy` [x, y] gives
  the frame's pixel position instead of `index` (rail sheets aren't a grid).
- `projection`: `"top"` projects straight down onto top faces, heights ignored (rails, whose
  sprites are drawn flat). `across` (rails, 0.72): the sprite keeps the track's centre line where
  the game has it but squashes distances across it north-south, as Factorio's rail sprites do; the
  models store their centre line's x, y in UV (`rails.py`, `centre_uvs`).
- `deferred`: rails (their sheets are 4096x8192). `atlas_scale` works for any mode.

## Building the procedural models

Zenith's own models (Placeholders) are generated by Blender Python scripts in `tools/models/`, no
`.blend` files:

| File | What |
|---|---|
| `kit.py` | Shared kit: materials (sRGB palette, roughness, metallic), bevelled boxes, cylinders, prisms, bolts, hazard stripes, the `Part` builder, export |
| `belts.py`, `chests.py`, `machines.py`, `power.py`, `defence.py`, `fluids.py`, `electric.py`, `oil.py`, `vehicles.py`, `circuits.py`, `logistics.py`, `rails.py`, `railway.py`, `crash_site.py`, `fish.py`, `military.py`, `nuclear.py`, `rocket.py`, `placeholders.py` (and the Space Age modules below; `MODULES` in `build.py` lists them all) | One function per model, registered with `@model("<name>")` (rails.py: the track pieces; railway.py: supports, ramp, signals, train stop, gate) |
| `specs.py` | Expected footprint and triangle budget per model (plain Python) |
| `build.py` | Builds and exports models to their pack (over the file where it is, a new one into `packs/placeholders/`) |
| `check.py` | Validates the exported `.glb` files, every pack's without names (plain Python, no Blender) |
| `packs.py` | Where the built-in packs are: `model_path`, `out_path`, `resolve` (`<name>` or `<pack>/<name>`) for every tool (plain Python) |
| `preview.py` | Renders models side by side to a PNG, without the client |
| `compare.py` | Renders one model from Factorio's camera next to a frame of its sprite, with an outline overlay |
| `bake.py` | Bakes the per-vertex weathering data (below) for kit, nature and Wube models (plain numpy) |
| `sprite_projection.py` | Writes `client/data/sprite_projection.json` from Factorio's prototype files (below) |
| `part_colors.py` | Samples each part's colour from the model's sprite into the `.glb` (Materials, 0.; needs a Factorio install; plain numpy, scipy, pillow) |

```bash
# rebuild everything (or name models after the --)
blender --background --factory-startup --python tools/models/build.py -- [names...]
# check names, footprint, origin, rotation and triangle budget (<name> or <pack>/<name>, as
# fue5/stone-furnace; none: all 481 of the three packs)
python tools/models/check.py [names...]
# each part's colour from the sprite, after any rebuild (wube.py runs it itself; --debug DIR
# writes sprite / sampled colour pictures to look at, never into the repo)
python tools/models/part_colors.py [names...]
# re-import into the Godot project (commit the .glb.import files too)
godot --headless --path client --import
# optional: look at them (views: game, north, top, factorio)
blender --background --factory-startup --python tools/models/preview.py -- out.png [names...] --view=game
# match a model to its sprite (write the output to a scratch folder, never into the repo)
blender --background --factory-startup --python tools/models/compare.py -- /tmp/lab.png lab     --sprite="<Factorio>/data/base/graphics/entity/lab/lab.png" --frame=194x174 --line=11 --shift=0,1.5
```

On Windows Blender is `C:\Program Files\Blender Foundation\Blender 5.2\blender.exe`. Rebuilding
unchanged scripts gives the same geometry; the glTF exporter occasionally writes a primitive's
triangles in a different order, so commit only the models you meant to change.

### Matching a sprite

Factorio's sprites are drawn by an orthographic camera looking north and down at about 48°
(horizontal circles show 0.75 as tall as wide), 64 px per tile in the HR sheets, and the
entity's position marks a point about 0.3 tiles above the ground. `compare.py` uses that camera:
copy `--frame`, `--line`, `--shift` (and `--scale`) from the prototype in
`<Factorio>/data/base/prototypes/entity/*.lua`, pick a frame with `--index`, turn the model with
`--rot` (directional sprites) or the turret head with `--head`, and stack sprite layers (a turret
head on its base) with `--layer`. It prints a silhouette overlap and the average colours.
Some sprites draw their tiles square on screen, longer north-south than this camera gives (the
pipe kit, the offshore pump): model them to their real length and give their projection entry a
`stretch` (north-south ground scale, 1.346 = 1 / sin 48 degrees; `compare.py --stretch`), which
the client's projection applies too. The trains' north and south frames fit best unstretched. Some
sheets aren't one consistent 3D render: the boiler's east/west frames are stretched
north-south and the burner drill's four directions move parts around, so match the north
(or most common) view and keep the pipe connections on the real tiles.

To add a model: write a function in the right family module (or a new module listed in
`MODULES` in `build.py`), add its footprint and budget to `specs.py`, build, check, import, and
look at it in the client.

### Space Age: Gleba and Aquilo

`tools/models/gleba.py` and `aquilo.py` (helpers and the extra palette in `space_kit.py`: lathed
shapes, swept and ribbed hoses, lumpy blobs, craggy rocks). Each is matched to its sprite with
`gallery.py` like the base game's. Notes:

- `sprite_load` adds a prototype's own `shift` to the sheet's `.lua` shift (the rocket turret's
  -20 px); the numbers in `sprite_projection.py` and `gallery.py` are the sums.
- Gleba plants are drawn at 0.33 x their scale multiplier (`gleba_tree_variations`), variation 1.
- Pentapods (`small/medium/big-` wriggler, strafer, stomper): the strafer's and stomper's five
  legs are separate parts that `vehicle_anim.gd` stands where the mod's spider-leg entities are
  (Factorio's leg tables per tier); the wriggler walks on the vertex shader's limb rig. Their
  colours come from `space_skin.py` (below, "Space Age creatures measured from their sprites"),
  which `part_colors.py` leaves alone.
- The capture robot is modelled on its origin and lifted by the client like other robots; its
  projection `anchor` is negative so its high-drawn sprite lands on it.

## Creatures (biters, spitters, worms, spawners, the character)

Converted from Wube's printable models (`wube_recipes.py`, "Creatures"; CC BY-NC, listed in
`CREDITS.md`) and rigged by `tools/models/wube_rig.py`; the worm is built from its sprites
(`tools/models/worm.py`). One model per family at the big tier's size: `big-biter`,
`big-spitter`, `big-worm-turret`, `biter-spawner`, `character`, with pose variants `-attack`,
`-corpse` (four for biters and spitters, `-corpse-1` to `-3`, posed by
`tools/models/creature_pose.py`) and `character-gun` (shooting). The character also has armour
looks on the same skeleton (`character-armor-2`, `-3`, `tools/models/armour_looks.py`) and the
mech armour (`character-mech-armor`). The other
tiers are the same model scaled (`creature_models.gd`, `ALIASES`, from Factorio's
enemy-constants.lua) and coloured by their own tints (below); `spitter-spawner` is the biter spawner
under its red tint, as in the game.

Skins (`tools/models/creature_skin.py`): the biter, spitter, worm and spawner and their pose models
are coloured per vertex from Factorio's own pictures, not one colour per part: every run frame in
its 16 directions with the model posed as the client poses it at that frame, the worm standing in
its 16 attack directions, the corpses from their last dying frame in their fall's directions. Each
picture is lined up on the model's silhouette, Factorio's painted-in light divided out, and each
triangle keeps the mean of its samples less the furthest third. The carapace is stored the way
Factorio draws a tier, as its mask layers, which each tier's own tints (from its prototype, in
`client/data/creature_skins.json`) colour in the shader (`skin_mode`): for biters and spitters the
two masks' shades and the second's cover in the part colours, for worms and spawners the colour
under the one mask in the part colours and the mask's shade and cover in `COLOR_0` (red
sqrt(shade / 4), green cover). Only numbers are stored. `part_colors.py` leaves these models to
`creature_skin.py` (a run over every model would flatten them again), and `wube.py` runs it after
converting a creature. Run it again after anything rewrites a creature's `.glb`:

```bash
python tools/models/creature_gait.py          # knees and the walk's bend, fitted to the run sheets
python tools/models/creature_pose.py --table  # the poses' legs and body moves for the client
python tools/models/creature_skin.py          # the skins (--check --debug DIR: pictures, out of the repo)
```

Limbs move in the vertex shader, not as `anim_*` nodes: every vertex carries its limb number and
how much it follows it in `TEXCOORD_0` (x: 1-12, 0 for the body; y: 0 at the joint to 1), and
`client/data/creature_rigs.json` has each limb's joint, swing and lift axes and gait. The
material (`rig_*` uniforms) turns the limbs: walking ones (`mode: walk`) by the phase and strength
in `INSTANCE_CUSTOM.rg` that `creatures.gd` (units) and `avatar.gd` (the character) set from the
distance walked; idle ones (worms swaying, spawners breathing) by the clock. So a screen full of
biters is one MultiMesh per model and pose, and the joints bend without tearing.

Walking legs also fold at a knee (`knee`, `reach` and `bend` per limb in creature_rigs.json,
`tools/models/creature_gait.py`): the outer part of the leg turns about the lift axis, as
creature_pose.py folds it for the poses, and the walk has a rest bend per pair of legs and a flex
while a leg is lifted, with the body standing on them (`body`), all fitted to Factorio's 16 run
frames in their 16 directions (silhouette overlap: biter 0.593 -> 0.606, spitter 0.605 -> 0.725).
The walking model carries its attack and corpse poses' legs too (`rig_pose`, from
creature_poses.json's `legs`): a biting, spitting or dying creature is the walking model with its
legs blended into the pose in the shader (the instance's custom data `a`: 2 + slot + amount) and
its body turned on the CPU the way the pose's body moved, so it reaches the corpse model exactly
(to about a hundredth of a tile above the ground) and the swap doesn't show, and attackers share
the walkers' MultiMeshes.

| Family | Limbs | Client |
|---|---|---|
| Biter | six legs, picked by hand-placed hips and seeds (recipe `hips`, `seeds`), two alternating tripods, knees | walks by distance; attacks what the mod says it attacks (`en`): rears into its `-attack` pose and back once per cooldown over Factorio's 11 frames (the pose at frame 5); dies: falls into one of its four corpses, its legs folding into the corpse's, which lies 15 minutes in Factorio's blood puddle |
| Spitter | twelve short legs found automatically (`core`), knees | as the biter; rises into its `-attack` stance and back over the 14 frames forward and back, spitting at the top |
| Worm | neck sways and breathes | folds (its horns closing over the mouth), rises (opening them) and lunges at its target from `en`, at Factorio's state speeds; on a fifth of its idle loops Factorio's alternative idle (head thrown back, horns spread) |
| Spawner | dome breathes | always, on Factorio's idle loop |
| Wriggler (Gleba) | five tentacle legs (gleba.py), knees | as the biter: rears into its `-attack` pose (frame 3 of 19, front legs up) and back by frame 12, squeezed into its 26-tick cooldown; dies into its corpse, which lies Factorio's minute (no Nauvis blood) |
| Gleba spawner | egg sacs swell | always, on Factorio's idle loop (16 frames forward and back at 0.1 a tick: 5 s) |
| Character | bones posed in the shader (`mode: pose`, `character_anim.gd`) | runs by distance at Factorio's cycle length, `character-gun` while firing, mining; the look follows the armour worn |

## Items (on belts, on the ground, in inserter hands)

Item models are part of the model packs: a folder called `items` in a pack holds `<item>.glb` (or
`.gltf`), apart from its entity models (model_packs.gd `item_model_path`, `items`); they go by the
packs' order, switches and per-item choices (settings.cfg `[model_packs]` `choices`, keyed
`item:<name>`). Zenith's own are the Placeholders pack's, `packs/placeholders/items/<item>.glb`
(they were `assets/models/items/`), so every item modelled keeps one. A modeller's item is drawn
the same way, by its vertex colours (a surface without them takes its material's base colour).

`packs/placeholders/items/<item>.glb` are small models for items, made by `tools/models/items.py` (plain Python:
numpy, pillow, scipy; no Blender) from the low-poly parts in `tools/models/item_kit.py`. Thousands
can be in view on a busy bus, so each is a few dozen triangles (about 55 on average, at most 220)
with its colours in the vertices (`COLOR_0`), about a quarter tile across, resting on y = 0 and
centred. Shapes follow Factorio's item icons (a plate is a bevelled slab, a science pack its flask,
a building's item its entity in miniature, as the icons draw them); colours are picked once from
the icon in the player's install (the median of the right part of it: `Icon.pick`), and only the
numbers end up in the `.glb`. Ores sample their belt pictures (`iron-ore-1.png`), not the icon.

```bash
python tools/models/items.py                   # every item with a recipe (--list names them)
python tools/models/items.py iron-plate coal   # just these
python tools/models/items.py --preview out.png iron-plate   # icon | model sheet, out of the repo
godot --headless --path client --import        # commit the .glb.import files too
```

`check.py` doesn't look at `items/` (items.py checks size and triangles itself). In the client
(`item_models.gd`, `item_cards.gd`) every item type is one MultiMesh with one shared material
(`shaders/item.gdshader`); each item gets a slight turn by its id; items without a model keep
their icon card. Settings > Graphics > Items on belts switches between models and icons. These
are blockouts from the icons; the building items in particular are boxes in the building's
colours.

## Experiment: shapes and poses from Factorio's rotation sheets (turntable)

`tools/models/turntable.py` treats an entity's 64 rotation frames (car, tank, gun turret head,
spidertron body) as a photo turntable: each frame's alpha carves a voxel grid (visual hull),
which is meshed, smoothed, decimated and given per-part colours sampled from the frames. It
fits the camera's north-south scale too, and confirms the vehicles' frames were rendered by a
true orthographic camera at about 48 degrees (b = 0.71-0.73 against sin 48 = 0.74), which is
the client's `rotation` projection. `compare` renders the hull and our model next to the
sprites and prints the silhouette overlap (IoU) per direction.

`tools/models/turntable_anim.py` fits our rigged models' joint angles (the biter's legs on the
shader rig, the character's skeleton, the turret head's height) to each frame of an animation
across all its directions, by silhouette overlap, and writes keyframes plus a contact sheet.

Everything both write is derived from Factorio's sprites and stays in the git-ignored
`art-src/turntable/`; no hull or fitted animation is used by the client. The scores were used
as a measuring stick for our own models instead: the car's and tank's bodies and turrets and
the gun turret's head were resized and moved part by part until their silhouettes overlapped
the rotation sheets better (car turret 0.47 -> 0.70, tank turret 0.39 -> 0.89, gun turret head
0.62 -> 0.84, tank body 0.77 -> 0.87, car body 0.85 -> 0.87); the big biter got long legs
(`long_legs` in wube_rig.py) and the character a smaller backpack and a retuned run
(character_anim.gd), checked the same way against the running sprites.

```bash
python tools/models/turntable.py hull car tank gun-turret --fit
python tools/models/turntable.py compare car tank gun-turret
python tools/models/turntable_anim.py big-biter character gun-turret
```

## Space Age creatures measured from their sprites (creature_hull.py)

Demolishers, pentapods and Gleba spawners have no printable model, and their sprites are
organic shapes no box kit fits. `tools/models/creature_hull.py` measures them instead, and the
Blender models are built from the numbers (`tools/models/creature_profiles.py`, numbers only,
like `plant_skeletons.py`):

- Parts drawn from every side (the demolisher's head, segment and tail, 128 directions; the
  stomper's and strafer's torsos, 64): the visual hull of all the frames, measured as rings across
  the part (a polar outline round each slice's middle) with the sprite's colour class at each
  ring point. `space_kit.profile_loft` lofts through them (vulcanus.py, gleba.py), each class its
  own material (rock, lava, bone).
- Parts with one picture (the Gleba spawners and the spawner's corpse): east-west columns, each a
  half-ellipse across a round footprint whose top shows where the picture's outline is, the green
  egg sacs set into it; the corpse's splash is every stretch of its outline laid on the ground.
- Pentapod legs, the wriggler and the spawners' sacs are built by hand to the leg sprites' widths
  and the prototypes' leg tables, and rigged for the client (legs: vehicle_anim.gd; the wriggler
  and the sacs: the vertex shader's limb rig, wube_rig's table).

`python tools/models/creature_score.py --space` scores them against their sprites in every
direction (torsos without their legs, lined up by their centres since they bob).

```bash
python tools/models/creature_hull.py [names...]     # remeasure (needs Factorio's sprites)
blender --background --factory-startup --python tools/models/build.py -- demolisher-head ...
python tools/models/creature_score.py --space
```

Their skins (`tools/models/space_skin.py`), as `creature_skin.py`'s for Nauvis: every triangle
coloured from the pixels that land on it in every picture Factorio draws it with (32 of the
demolishers' 128 directions, 32 of a torso's 64 with its legs left out and lined up by its middle,
the wriggler's run frames posed as the client poses it, the small spawner's, the spawner corpse's
and the shells' one picture unturned, the shells at their true length), Factorio's light divided
out. Not the big Gleba spawner: its sacs don't lie where the picture's do, so its pixels darkened
the heap with the cracks between them; it keeps `part_colors.py`'s colour per patch. Factorio tints
these with `tint_as_overlay` (an overlay blend, not a multiply): a near-grey on the main picture,
the tier's colour on a mask layer half or more see-through. A pentapod's and a shell's tiers are
models of their own, so their tints are blended in as Factorio blends them; the wriggler is one
model for its tiers, so it keeps the mask (skin_mode 2: the colour under it as part colours, its
shade and cover in `COLOR_0`) and each tier's tint, fitted to what the overlay gives over the
mask's pixels, goes to `client/data/creature_skins.json` (the others there as `colour`, so
`part_colors.py` leaves them to it). A pentapod's legs are pictures stretched along each part
(thigh, knee, shin, foot, 32 of each for the ways Factorio lights them): each vertex takes its
picture's row at its place along the part, the row's middle averaged over every lighting.

The wriggler walks with knees and a bend fitted to its run (`creature_gait.py`), and strikes and
dies on the walking model like a biter: `big-wriggler-pentapod-attack` (rearing, front legs up,
frame 3 of 19) and `-corpse` (on its belly, legs flung out, the last dying frame) are posed by
`creature_pose.py` and their legs blended in the shader. Run after rebuilding any of these:

```bash
python tools/models/creature_gait.py big-wriggler-pentapod                # its knees and walk
python tools/models/creature_pose.py big-wriggler-pentapod-attack big-wriggler-pentapod-corpse
python tools/models/space_skin.py              # the skins (--score: colours against the sprites;
                                               # --shots DIR --before DIR2: pictures, out of the repo)
```
