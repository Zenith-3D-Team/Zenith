# Making models for Zenith

A guide for 3D modellers. Zenith draws every Factorio entity with a 3D model; this page says what a
model needs so the game can use it. The full technical reference, with every table, is
[client/assets/models/README.md](../client/assets/models/README.md).

## The look

Models should look like Factorio. Match Factorio's own sprites in shape, proportions, colour and
wear: the high-resolution sprite sheets are in your Factorio install under
`data/base/graphics/entity/` (and `data/space-age/...`). Look at the sprite from Factorio's camera
angle (about 45 degrees down, from the south) and make the model read the same from there. Don't
redistribute Factorio's pictures: look at them, don't put them in your files.

## Every model

- **File:** one glTF file per entity, `.glb`, named after Factorio's internal name for it:
  `assembling-machine-2.glb`, `storage-tank.glb`. The names are the ones in Factorio's prototypes
  (the same as in `/c` commands and on the wiki's "internal name" line).
- **Scale and origin:** 1 unit = 1 tile. The origin is the centre of the entity's footprint, on
  the ground. A 3x3 machine fills about 3 x 3 units, with a small inset so neighbours read as
  separate (belts and walls go edge to edge so lines join up).
- **Facing:** the model faces north: Blender +Y (export with +Y up), Godot -Z. The game turns it
  for other directions. Things that can't turn (chests, furnaces, labs) keep their front to the
  south, towards the camera, as Factorio's sprites do.
- **Triangles:** keep within the budget `tools/models/check.py` reports: around 10,000 for a typical
  machine, less for small things, up to 16,000-20,000 for the biggest. The game draws thousands of
  buildings at once, so fewer is better.
- **Materials and textures:** a base colour texture (and optionally a roughness/metal one: glTF's
  green = roughness, blue = metal), embedded in the `.glb`, read through the first UV map. The metal
  is drawn mostly as paint (a tenth of it), as Factorio's sprites and every other model's metal are:
  Zenith has no bright surroundings for metal to reflect, so full metal read dark and blue. Expect
  your metal parts to look about as bright as their base colour, as in Blender's Material Preview,
  with less shine (players can choose Full, as before, in Settings). Say `"shading": "pbr"` in your pack's
  `pack.json` (below) and your textured models are drawn as their files say, as Godot's own material
  draws glTF: top faces as lit as the sides (without it they're held to 0.6 of your base colour, a
  balance made for Factorio's sprite colours), Godot's specular, your roughness and metal pictures, an
  occlusion picture (glTF occlusionTexture, red) as ambient occlusion only, and the normal map. Its
  metal is drawn in full, reflecting a neutral surrounding lit as the moment is (no longer the blue sky),
  so a rough metal part is about as bright as paint of its colour; materials without a picture follow
  their factors the same way. Your
  items with a picture are drawn the same way. Without the key a pack keeps Factorio's balance; players
  can turn it off for every pack in Settings. One
  material with one texture atlas per model is cheapest. Keep the material's base colour white.
  Texture filtering follows the file: set Blender's Image Texture node to **Closest** and Zenith
  draws that texture crisp, texel by texel (still mipmapped far away, so it doesn't shimmer); Linear
  (the default) draws it smooth. Transparency follows the material's Blend Mode: **Alpha Clip**
  cuts away every pixel whose alpha (the base colour texture's, times the material's) is under its
  Clip Threshold and draws the rest solid, both sides, with matching shadows: for fences, grilles,
  leaves and decals. (In a pack whose pack.json says `"shading": "pbr"`, an Alpha Clip material with
  Backface Culling on, glTF's doubleSided false, is drawn from the front only, as Godot draws it.) **Alpha Blend** draws the material see-through by that alpha: for glass. Keep
  Opaque for everything else, as see-through costs more to draw. Opaque and Alpha Blend faces are
  drawn from the front only, whatever the file's double-sided flag says: turn on Backface Culling in
  Blender's material settings to see what Zenith draws, and give anything you can look into (an open
  pipe end) an inside, with a Solidify modifier or a modelled inner wall; point each face's front the way
  it is seen from (a pipe cap's plate faces out of the pipe, or only its bolts show). A **normal map** (glTF
  normalTexture, OpenGL style as Blender exports it) is drawn, at its Strength. **Emission:** an
  emission texture says which parts glow and in what colour, times the Emission Strength; they
  glow only while the machine works. Without an emission texture the whole material glows.
  Vertex colours from Blender are ignored (Zenith keeps its own baked data in them). A model without textures is coloured from its materials'
  colours.
- **One mesh:** the game flattens each model into one mesh for speed. Anything that moves is either
  a separate object (below) or a baked animation:
- **Baked animation:** one skinned mesh on an armature, with one action exported (Blender's glTF
  export: Animation on, the action's frame range set; up to 4 bones a vertex). The game plays the
  action on a loop while the machine works, easing it up when the machine starts and coasting to a
  stop when it stops, at the action's own speed. Triangles only on bones that never move stay part
  of the still model. An action one frame long (Blender exporting only the current frame) has
  nothing to play.
  The game samples the action at its own key rate, up to 60 frames a second (Blender's default
  of 24 or 30 is fine), and a bone that turns more than about 30 degrees from one frame to the next
  jumps from frame to frame instead of turning smoothly. So **keep anything that spins under about
  5 turns a second** (at 60 frames a second that is 30 degrees a frame): faster, it flickers or
  seems to turn backwards, in Blender's own playback too. And **make the loop close**: over the
  action every spinning part should end where it began, a whole number of turns (a gear that
  makes 1.5 turns jumps half a turn each time the loop starts again).
  An object animated on its own (a roller) is played the same way, and in glTF its rotation keys
  replace its whole rotation: **key the turn it stands at, not only its spin**. A roller laid across
  the belt by a quarter turn whose keys hold only the spin about its axle lies along the belt as soon
  as the action plays, in any glTF viewer (import the exported .glb back into Blender and play it to
  check).

## Moving parts

A part that moves is a separate object named `anim_<kind>`, with its origin at the point it turns
about. The game moves it from the game's state (working, aiming, a robot nearby...). Some kinds:

| Name | What the game does with it |
|---|---|
| `anim_spin_fan`, `anim_spin_rotor`, `anim_spin_drill` | spins about its own up axis while the machine works |
| `anim_spin_flywheel` | spins about its east-west axis while working |
| `anim_turret_head` | turns and aims where the turret aims; barrels point north at rest |
| `anim_glow_<style>` | glows while working, dark when idle (`fire` flickers, others pulse) |
| `anim_door_n`, `anim_door_s`, `anim_hatch_e`, `anim_hatch_w` | slide open (roboport doors, logistic chest hatches) |
| `anim_lit_green` / `_yellow` / `_red` | shown and lit by a signal's colour |

The full list, with axes and timings, is in the models README ("Moving parts"). If a model needs a
kind of movement that isn't there, ask: new kinds are added in the game's code.

## Entities built from several models

Some entities are drawn from a set of pieces the game picks between. Deliver every piece, named
exactly:

| Entity | Files | Notes |
|---|---|---|
| Transport belt | `transport-belt.glb`, `transport-belt-curve-left.glb`, `transport-belt-curve-right.glb` | Everything that moves with the belt (the slats) uses a material whose name contains `belt_surface` (any case): the game scrolls it at each tier's speed. Untextured, it paints Factorio's slats and chevrons on it; with your own texture, it scrolls that texture the way its UVs run along the belt (curves too), and leaves it as it is. To wrap the belt round its ends, model the wrap (apply modifiers and geometry nodes before exporting). The frame uses `tier_paint`, which the game recolours for fast, express and turbo. Curves face their output: `-curve-left` takes items in from the west edge and out of the north edge. Items ride on the belt's top surface, so its height shows. |
| Underground belt | `underground-belt-input.glb` (entrance), `underground-belt-output.glb` (exit) | Both modelled as Factorio's picture for "north": the hood's mouth opens south. The game turns the exit round. |
| Splitter | `splitter.glb` | Two tiles wide (east-west). Its belts use `belt_surface`; gears and cranks are `anim_` parts. Baked gears move only while items pass, as Factorio's do; objects with `Roller` in their name run all the time, as belts do. |
| Pipe | 16 files, `pipe-<shape>.glb`, one per Factorio pipe picture: `straight-vertical`, `straight-horizontal`, `corner-up-right`, `t-left`, `cross`, `ending-down`, `straight-vertical-single`, ... | The game picks one by which neighbours connect. "up" is north, as in Factorio's sprite names. Heat pipes are the same 16 shapes, `heat-pipe-<shape>.glb`. |
| Stone wall | `stone-wall-<sides>.glb` named by the sides it joins (`pylon`, `n`, `ew`, `es`, `nesw`, ...) and `stone-wall-fill.glb` | The fill block sits in the middle of a 2x2 group of walls. |
| Rails | `straight-rail`, `half-diagonal-rail`, `curved-rail-a`, `curved-rail-b` and their `elevated-` versions, each as `<name>.glb` (direction north) and `<name>-ne.glb` (north-east) | The game turns them in quarter turns for the other directions. |
| Inserters | the base: `<name>.glb` alone (turned), or with `-east`, `-south`, `-west`; the arm: `inserter-arm-<family>-upper`, `-hand-open`, `-hand-closed` | The game stretches the arm pieces from the base's shoulder to the inserter's reach. Families: `basic`, `long`, `bulk`, `stack`. |
| Boiler, steam engine, offshore pump, pipe-to-ground, valves, burner drill, pumpjack, chemical plant, crusher | `<name>.glb` alone, facing north; or all four: `<name>.glb` (north), `<name>-east`, `-south`, `-west.glb` | One model is turned to each direction, like any other. Zenith's own have a model per direction, drawn unturned, because Factorio drew each direction separately; put all four in one pack to do the same. |
| Cargo bay | `cargo-bay.glb` plus edge pieces (`cargo-bay-wall-n`, `cargo-bay-corner-nw`, `cargo-bay-inner-nw`, ...) | Bays join each other and the hub like Factorio's tileset; see the models README. |
| Biter and spitter corpses | `<name>-corpse.glb` and `-corpse-1` to `-3` | Factorio's four falls. |
| Pipe windows | `pipe-straight-vertical-window.glb`, `pipe-straight-horizontal-window.glb` (Factorio's picture names) | Drawn instead of the straight on every second straight pipe, as Factorio does: where the pipe's floored x plus floored y is even. Only when the pack that draws the pipe's straight has the window model too; never on a corner, T or end. `--pipe-windows=off` turns them off. |
| Ore as rocks | `<ore>-1.glb`, `-2`, ... (`iron-ore-1`, `copper-ore-1`, `coal-1`, `stone-1`, `uranium-ore-1`, any number of them), or one plain `<ore>.glb` under 0.6 tiles on its larger side | Single rocks are scattered by Factorio's eight richness stages: each ore tile gets 3 rocks under 150 ore, then 5, 6, 7, 8, 10, 12 and 14 from 150, 400, 1300, 2900, 5500, 9500 and 15000 (uranium's lower: 100, 270, 870, 1930, 3670, 6330, 10000), bigger on richer tiles (1.1 to 1.9 times a size of 0.8 to 1.2), so a rock about 0.36 tiles across covers the ground about as Factorio's ore does; each a variant, place, turn and size worked out from the tile, the same every time. `--ore-density=classic` gives 0.2.2's first 2, 4 or 6 rocks (from 400 and 2900) at the plain size. Far away a tile shows one rock. A plain `<ore>.glb` that covers the tile (with `-rich` and `-sparse`) is drawn once a tile, as before. `"ore_scatter": false` in the pack's pack.json keeps its numbered files as they are; `--ore-scatter=off` draws one model a tile everywhere, `on` scatters any plain ore model too. |
| Mining drill's fluid part | `<drill>-wet.glb` (`electric-mining-drill-wet.glb`, Factorio's word for its wet pictures) | Only the fluid input's parts (pipe connections, the box between them), modelled over the dry drill at the same origin and facing north. Drawn on top of the drill while the resource under it needs fluid to mine (uranium ore's sulfuric acid), if the pack that draws the drill has it. `--drill-wet=off` turns it off. |
| Pipe cover | `pipe-cover.glb` (Factorio's `pipe_covers`) | Closes a machine's fluid connection while nothing is connected to it: modelled for a connection facing north, origin at the centre of the connection's own tile (the machine's edge tile), the cover at that tile's north edge. Drawn at every open connection of the machines your pack draws (a drill's only while it takes fluid). Without it, a pack with a pipe kit gives the cap of its `pipe-ending-down` (what it has more than `pipe-straight-vertical`). `--pipe-covers=off` turns them off. |

**Variants of anything:** give a model, an item model or an icon numbered copies, `<name>-1.glb`,
`<name>-2.glb`, `<name>-3.glb` (with or without the plain `<name>.glb`; `items/sulfur-1.glb`,
`icons/item/coal-2.png`), and each one placed in the world picks one of them at random: the same one every
time you load the save, and in every view. The Model packs window shows them as one entry ("Rock big (4)").
Number them from 1. Names that are already Factorio's with a number (`assembling-machine-2`,
`speed-module-3`, `tree-04`) stay their own prototype. Ores keep their own rule (scattered rocks, above).
Items riding belts or held by inserters show the first one; an icon picks one by its name, the same
everywhere.

**Electric poles:** wires attach at Factorio's own connection points, so the insulators must sit
there (the points are listed in `client/scripts/world/wires.gd`).

**Creatures and the character** are rigged on the game's own skeleton and bend in the shader. Talk
to the maintainer before starting one.

## Trying a model in the game

1. Put your `.glb` files in the `models` folder beside Zenith (`Zenith.exe` on Windows), named as
   above: loose at its top, in a folder of their own, or as a `.zip` (each folder or zip is a model
   pack; players don't unpack a zip). At its next start Zenith puts a new pack on top of the others,
   so your models are drawn in place of every other pack's of the same name, and the other packs'
   for everything else. Zenith's own are packs too, under yours, by default in this order: FUE5
   (Adapted), Wube3DP (Adapted) (Wube's printable models), Placeholders (Zenith's own) and Factorio (the
   player's install: each entity's own picture on a card, each item its icon). Every pack moves and switches off;
   an entity no pack in use has a model of is drawn as Factorio's picture, else as a box.
2. The **Model packs** window (the main menu, the Esc menu) has Available and Selected side
   by side: ▶ adds a pack on top of Selected, ◀ takes it out, ▲ ▼ order them (the higher wins when two
   have a model of one name), and Open folder opens the models folder. Click a pack to list its models
   by family (a model with its directions, curves, pieces and poses), click one to see it turning, and
   look at every pack's version of it; **Use <pack>'s** draws that family from that pack whatever the
   order (with its tiers recoloured from the base, if the pack has only the base). In a game, a
   building's window has a **Model** button for that one building, or every one of its kind. All of it
   applies at once (trains, robots, creatures and inserter arms at the next start).
3. Give a pack a `pack.json` at its top (or one folder down), and the window shows it:

   ```json
   {"name": "Vasillo's belts", "version": "1.2", "author": "Vasillo", "licence": "CC BY-NC 4.0",
    "description": "Textured belts, splitters and undergrounds.", "icon": "transport-belt"}
   ```

   `icon` is the model drawn as the pack's picture; a `pack.png` (or `icon.png`) at the pack's top is
   used before it, and without either the pack's first model is drawn. To show a picture of your own
   instead (a logo), add `"icon_image": "logo.png"`: a PNG, JPEG or WebP file in the pack, its path
   from the pack's top or from the folder the `pack.json` is in. `"icon_image": "factorio:<path>"`
   reads one from the player's Factorio install instead (`factorio:data/core/graphics/wube-logo.png`),
   for pictures of Wube's, which a pack mustn't carry. If the picture isn't there the model picture
   is shown. `"belt_item_height": 0.25` is the top of your belt surface (tiles) that items rest on, their lowest points on it (Zenith: the belt model's top plus 0.02 when absent), `"belt_lane_offset": 0.21` says how far from the belt's middle its items ride, in tiles (Factorio's 0.234 when absent; the inside of your rails minus the widest an item turned reaches sideways), and `"aliases": {"coal-ore": "coal"}` reads files named your way as Factorio's names
   (`coal-ore-2.glb` as `coal-2`, Factorio calls the ore `coal`). `"shading": "pbr"` draws the pack's models, pictured or plain colours, as their files say ("Materials and
   textures" above); `"factorio"`, or no key, with Factorio's balance. The window's card says which. To mix them, `"shading_models": {"transport-belt": "factorio", "iron-ore-*": "pbr"}` sets single models (prototype names, `*` wildcards; numbered variants follow their base) over `"shading"`.
   More in client/assets/models/README.md, "Model packs".
4. Another folder works too: start Zenith with `--models=<that folder>`, after a `--` (Godot passes the
   game only what follows it). Alone it fills in only entities no pack has a model for; with
   `--models-first` it wins over every pack for that run: on Windows a shortcut whose target is
   `"C:\Games\Zenith\Zenith.exe" -- --models="D:\My models" --models-first`. Start Zenith with
   `-- --no-custom-models` to see the built-in packs alone without moving yours.
5. Look at it from the default view and from Factorio's view (F6), beside the real entities.
6. A pack can carry icons too, which Zenith's UI draws in place of Factorio's (slots, tooltips,
   Factoriopedia, alerts, the Model packs window): an `icons/` folder at the pack's top (or one folder
   down), `icons/<name>.png` for the prototype of that name (`icons/iron-plate.png`), or
   `icons/<kind>/<name>.png` for one kind only when two share a name (`item`, `entity`, `fluid`,
   `recipe`, `technology`, `signal`, `space-location`, `item-group`). Square PNGs, any size (64 or 128
   pixels reads well). They follow the packs' order and switches as models do, a choice per icon in
   the window's Icons tab; a name no pack has keeps Factorio's icon. A pack may be icons alone. Draw
   your own: Factorio's icons are Wube's and a pack mustn't carry copies of them.
   A pack can carry sounds the same way, file for file in place of Factorio's: a `sounds/` folder at
   the pack's top (or one folder down), under it the file's Factorio path, `sounds/core/sound/gui-click.ogg`,
   `sounds/base/sound/walking/grass-3.ogg` (each variation its own file, numbered as Factorio's),
   `sounds/<mod-name>/...` for a mod's. Ogg Vorbis only. The sound's volume, variations and pitch stay
   Factorio's; same order and switches as icons; a file no pack has keeps Factorio's. A pack may be
   sounds alone. Record or make your own: Factorio's sounds are Wube's and a pack must never carry
   copies of them.
   **A pack holding a copy of any file of the player's Factorio install (a sound, a picture, anything)
   isn't loaded at all** (the owner's rule): Zenith compares a pack's files over 1 KB with the install's
   and, on a match, uses nothing of the pack and shows its card red in the Model packs window with the
   files it found. Zenith reads Factorio's own files from the player's install; a pack carries only yours.
   The check compares with the player's own install only: a copy of a Space Age file isn't caught on a PC
   without Space Age, and a re-encoded copy isn't caught at all. The rule holds either way.
7. A pack can carry item models too (items on belts, on the ground, in inserter hands): put them in a
   folder called `items` in the pack, named after the item (`items/iron-plate.glb`, `items/coal.glb`).
   They are kept apart from the pack's entity models, so `items/accumulator.glb` (the item) and
   `accumulator.glb` (the building) don't clash; loose models use the models folder's own `items/`.
   Items follow the same order, switches and choices as entities (an item's choice is saved as
   `item:<name>`), and Placeholders has one for every item Zenith models, so the rest keep theirs.
   Keep them small (about a quarter tile across, resting on y = 0, centred, a few dozen triangles:
   thousands can be in view). Colour them with vertex colours (`COLOR_0`; a surface without them takes
   its material's base colour), or with a base-colour picture (`baseColorTexture`, and UVs): an item
   whose surfaces all have the same picture is drawn with it, by one material of its own shared by
   every copy, on belts, on the ground, in hands and in the Model packs preview. One picture per item
   model: surfaces with different pictures (or some without) are drawn by their colours alone, and
   other maps (metal, roughness, normals, glow) aren't read, unless the pack says `"shading": "pbr"`:
   then its metal, roughness and normal pictures are drawn too, lit as its buildings are. `--item-pictures=off` draws them by their
   colours alone.

With the source code, `python3 tools/models/check.py <name>` (or `<pack>/<name>`, as
`fue5/stone-furnace`) checks the name, footprint, origin, facing and triangle budget, and
`tools/models/review.py <name>` takes screenshots in the game.

An export that doesn't follow these rules yet can still be used: `python3 tools/models/fix_pack.py
<export folder> <copy folder>` writes a fixed copy, leaving the export untouched. The fixes are a list
kept per modeller (`tools/models/fixes/<name>.json`, Vasillo's is `vasillo.json`), so the same list
fixes the next export too: a file renamed to Factorio's name, an item moved into `items/`, the origin
moved to the footprint centre (or a small model centred on its own box), a pipe piece written once per
pipe shape it serves (turned to each), a shape built from two pieces (a pipe ending is the straight plus
the cap at its closed end), and see-through materials made Alpha Clip. Its `materials` rules cover every
model: an emission picture wired with no emission strength is unwired (it would otherwise glow, or
vanish when idle), and an Alpha Blend material is made opaque when its picture's alpha is full on every
pixel, or Alpha Clip when under 5% of it is below full; real glass stays blended. Its `recolour` rules,
per material name, rewrite a base colour picture so its mean over the part the model uses reaches a
target colour or brightness (each channel scaled in linear light, alpha kept; a picture shared by several
files worked out once), and set the material's metallic and roughness (Vasillo's list has none: his
pictures stay as he made them). Its `keep_rest_turn` rule, per file, puts the turn an animated object stands at back
before its rotation keys, for an export whose keys hold only the spin (Vasillo's splitter rollers). Its
`inside` rule, on a file or on one part added to it, draws every triangle from both sides (Vasillo's
pipe-to-ground, and his pipe cap wherever it is added). Mostly only the
glTF's own data changes; meshes and textures are copied as they are (a file built from two pieces, or
with a picture unwired, has its binary rebuilt from the parts it uses, nothing re-encoded; a recoloured
picture is written anew as a PNG). It is a
stopgap: the fix belongs in the model in the end, so the maintainer sends the list's notes back.

## Improving the models over time

Zenith's models are a starting point, not the final word. Most were built quickly to cover every
entity, so some read differently from Factorio's sprites, and the FUE5 models follow older Factorio
designs in places. The plan is to work with 3D modellers to improve them over time, a few at a time,
worst first.

How that works:

1. **Pick what to work on.** Start with the models that look most wrong in the game. The asset
   inventory ([ASSET-INVENTORY.md](ASSET-INVENTORY.md)) says how far each family is along and
   what's short; agree the list with the maintainer so two people don't redo the same model.
2. **Start from what's there or from scratch.** The current `.glb` files are a fine base to
   refine, or replace one entirely, as long as the result follows this guide.
3. **Try it in the game** by putting it in the `models` folder (above), from the default
   view and Factorio's view (F6), beside the real entities.
4. **Send the files** (the `.glb`, any textures inside it, and a line on what changed). The
   maintainer checks them (`check.py`: name, size, origin, facing, triangles), looks at them in the
   game, and adds them to the next release, with the modeller credited in
   [CREDITS.md](../CREDITS.md).
5. **Releases bring them to players.** Each new release ships the models finished since the last
   one, so the game looks better release by release; nothing changes in players' saves.

A model that replaces one with its own licence (a FUE5 model, say) replaces it for good once it's
in: the old one stays in the project's history.

## Licence

Zenith is open source (GPL-3.0). Before you send models, agree with the maintainer how they're
licensed: under the GPL with the rest, or under a licence of your own as a pack of their own with a
`pack.json`, a README and a credit, as FUE5's models are (`client/assets/models/packs/fue5/`, CC
BY-NC-SA 3.0), or Vasillo's, used with his permission (a download's `models/Zenith.zip`).
Everyone credited is listed in [CREDITS.md](../CREDITS.md).
