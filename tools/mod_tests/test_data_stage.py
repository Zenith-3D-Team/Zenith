"""Runs the bridge's data-final-fixes.lua against a small fake data.raw (base-style prototypes and
odd modded ones) and checks the graphics list it makes (scripts/gfx_extract.lua).

    python3 tools/mod_tests/test_data_stage.py

Lupa embeds Lua 5.2, as Factorio's data stage uses.
"""

import json
import pathlib
import sys

from lupa import lua52

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import protocol  # noqa: E402

# A FAIL line can hold any character: on Windows, output to a file or pipe is in the system's code page,
# and one character it lacks stopped the run with UnicodeEncodeError.
sys.stdout.reconfigure(errors="backslashreplace")

MOD = ROOT / "mod" / "factorio-3d-bridge"

failures = []


def check(cond, what):
    if not cond:
        failures.append(what)
        print("FAIL:", what)


# A data.raw as Factorio has it once every mod has run: base-style prototypes and a mod's.
RAW = r"""
local raw = {
  item = {
    ["iron-plate"] = { type = "item", name = "iron-plate", icon = "__base__/graphics/icons/iron-plate.png", stack_size = 100 },
    ["gizmo"] = { type = "item", name = "gizmo", icon = "__my-mod__/graphics/icons/gizmo.png", icon_size = 32, stack_size = 50 },
    ["barrelled"] = { type = "item", name = "barrelled", stack_size = 10, icons = {
      { icon = "__base__/graphics/icons/fluid/barreling/empty-barrel.png" },
      { icon = "__base__/graphics/icons/fluid/barreling/barrel-side-mask.png", tint = { r = 255, g = 128, b = 0, a = 191 } },
      { icon = "__my-mod__/graphics/icons/small.png", icon_size = 32, scale = 0.25, shift = { 4, -4 } },
    } },
    ["box"] = { type = "item", name = "box", icon = "__my-mod__/graphics/icons/box.png", stack_size = 50 },
    ["broken"] = { type = "item", name = "broken", icons = "not a table", stack_size = 1 },
  },
  ["gun-ish-modded-item"] = {
    ["laser-pointer"] = { type = "gun-ish-modded-item", name = "laser-pointer", icon = "__my-mod__/graphics/icons/laser.png", stack_size = 1 },
  },
  fluid = {
    ["goo"] = { type = "fluid", name = "goo", icon = "__my-mod__/graphics/icons/goo.png" },
  },
  recipe = {
    ["gizmo"] = { type = "recipe", name = "gizmo", results = { { type = "item", name = "gizmo", amount = 1 } } },
    ["gizmo-fast"] = { type = "recipe", name = "gizmo-fast", results = { { type = "item", name = "gizmo", amount = 2 } } },
    ["goo-making"] = { type = "recipe", name = "goo-making", results = { { type = "fluid", name = "goo", amount = 10 } } },
    ["two-things"] = { type = "recipe", name = "two-things", main_product = "box", results = {
      { type = "item", name = "box", amount = 1 }, { type = "item", name = "gizmo", amount = 1 } } },
    ["own-icon"] = { type = "recipe", name = "own-icon", icon = "__my-mod__/graphics/icons/own.png", results = {} },
  },
  technology = {
    ["gizmos"] = { type = "technology", name = "gizmos", icon = "__my-mod__/graphics/technology/gizmos.png", icon_size = 256 },
  },
  ["virtual-signal"] = {
    ["signal-gizmo"] = { type = "virtual-signal", name = "signal-gizmo", icon = "__my-mod__/graphics/icons/signal.png" },
  },
  ["item-group"] = {
    ["gizmos"] = { type = "item-group", name = "gizmos", icon = "__my-mod__/graphics/item-group/gizmos.png", icon_size = 128 },
  },
  ["battery-equipment"] = {
    ["big-battery"] = { type = "battery-equipment", name = "big-battery", icon = "__my-mod__/graphics/equipment/battery.png" },
  },
  container = {
    ["box"] = { type = "container", name = "box", icon = "__my-mod__/graphics/icons/box.png" },
    ["box-ruin"] = { type = "container", name = "box-ruin", icon = "__my-mod__/graphics/icons/ruin.png" },
  },
  tile = {
    ["my-floor"] = { type = "tile", name = "my-floor", layer = 70, layer_group = "ground-artificial",
      collision_mask = { layers = { ground_tile = true } }, map_color = { 100, 50, 25 },
      variants = { material_background = { picture = "__my-mod__/graphics/terrain/floor.png", count = 4, scale = 0.5 } } },
    ["my-grass"] = { type = "tile", name = "my-grass", layer = 20, map_color = { r = 0.2, g = 0.5, b = 0.1 },
      collision_mask = { layers = { ground_tile = true } },
      variants = { main = {
        { picture = "__my-mod__/graphics/terrain/grass.png", count = 16, size = 1, line_length = 16, scale = 0.5,
          weights = { 0.1, 0.2 } },
        { picture = "__my-mod__/graphics/terrain/grass.png", count = 8, size = 2, y = 128, probability = 0.5, scale = 0.5 },
      } } },
    ["my-swamp"] = { type = "tile", name = "my-swamp", layer = 4, layer_group = "water-overlay", effect = "my-swamp-fx",
      collision_mask = { layers = { water_tile = true, floor = true } }, map_color = { 10, 40, 10 },
      variants = { main = { { picture = "__my-mod__/graphics/terrain/swamp.png", count = 1, size = 1 } } } },
    ["my-void"] = { type = "tile", name = "my-void", layer_group = "zero", map_color = { 0, 0, 0 },
      collision_mask = { layers = { ground_tile = true, water_tile = true, empty_space = true, floor = true, object = true } },
      variants = { main = { { picture = "__my-mod__/graphics/terrain/void.png", count = 1, size = 1 } } } },
    ["my-lava"] = { type = "tile", name = "my-lava", map_color = { 200, 60, 0 },
      collision_mask = { layers = { water_tile = true, lava_tile = true, item = true } },
      variants = { main = { { picture = "__my-mod__/graphics/terrain/lava.png", count = 1, size = 1 } } } },
    ["no-pictures"] = { type = "tile", name = "no-pictures", variants = {} },
  },
  ["tile-effect"] = {
    ["my-swamp-fx"] = { type = "tile-effect", name = "my-swamp-fx", shader = "water", water = {
      shader_variation = "wetland-water", image_textures = { { filename = "__my-mod__/graphics/terrain/swamp-shader.png" } } } },
  },
  sprite = {
    ["my-gui-sprite"] = { type = "sprite", name = "my-gui-sprite", filename = "__my-mod__/graphics/gui/icons.png", width = 32, height = 32, x = 64, y = 0, scale = 0.5 },
    ["my-layered-sprite"] = { type = "sprite", name = "my-layered-sprite", layers = {
      { filename = "__my-mod__/graphics/gui/back.png", size = 64, position = { 0, 64 } },
      { filename = "__my-mod__/graphics/gui/front.png", size = 64 } } },
  },
  ["optimized-decorative"] = {
    ["pebbles"] = { type = "optimized-decorative", name = "pebbles", render_layer = "decals",
      collision_box = { { -1, -0.5 }, { 1, 0.5 } },
      pictures = { sheet = { filename = "__my-mod__/graphics/decorative/pebbles.png", width = 64, height = 32,
        variation_count = 12, line_length = 4, scale = 0.5, shift = { 0, -0.25 } } } },
    ["flowers"] = { type = "optimized-decorative", name = "flowers",
      pictures = { { filename = "__my-mod__/graphics/decorative/flower-1.png", size = 32 },
                   { layers = { { filename = "__my-mod__/graphics/decorative/flower-2.png", width = 40, height = 20 } } } } },
    ["nothing"] = { type = "optimized-decorative", name = "nothing", pictures = {} },
  },
  ["mod-data"] = {},
  furnace = {
    ["my-smelter"] = { type = "furnace", name = "my-smelter", collision_box = { { -1.4, -1.4 }, { 1.4, 1.4 } },
      graphics_set = { animation = { layers = {
        { filename = "__my-mod__/graphics/entity/smelter.png", width = 200, height = 220, shift = { 0, -0.25 }, scale = 0.5, frame_count = 8, line_length = 4 },
        { filename = "__my-mod__/graphics/entity/smelter-shadow.png", width = 260, height = 120, scale = 0.5, draw_as_shadow = true },
        { filename = "__my-mod__/graphics/entity/smelter-light.png", width = 50, height = 50, draw_as_light = true },
      } },
      working_visualisations = {
        { animation = { filename = "__my-mod__/graphics/entity/smelter-fire.png", width = 40, height = 40, frame_count = 3,
          frame_sequence = { 1, 2, 3, 2 }, animation_speed = 0.5 } },
        { light = { intensity = 1 }, animation = { filename = "__my-mod__/graphics/entity/lamp.png", size = 8 } },
      } } },
  },
  ["assembling-machine"] = {
    ["my-anim"] = { type = "assembling-machine", name = "my-anim", collision_box = { { -1, -1 }, { 1, 1 } },
      graphics_set = { animation = { filenames = { "__my-mod__/a-1.png", "__my-mod__/a-2.png" }, lines_per_file = 2,
        width = 100, height = 100, frame_count = 16, line_length = 4, run_mode = "forward-then-backward" } } },
    ["my-striped"] = { type = "assembling-machine", name = "my-striped", collision_box = { { -1, -1 }, { 1, 1 } },
      graphics_set = { animation = { width = 50, height = 50, frame_count = 16,
        stripes = { { filename = "__my-mod__/s-1.png", width_in_frames = 4, height_in_frames = 2 },
                    { filename = "__my-mod__/s-2.png", width_in_frames = 4, height_in_frames = 2 } } } } },
  },
  ["mining-drill"] = {
    ["my-drill"] = { type = "mining-drill", name = "my-drill", collision_box = { { -1, -1 }, { 1, 1 } },
      graphics_set = { animation = {
        north = { filename = "__my-mod__/graphics/entity/drill-N.png", size = 128, scale = 0.5 },
        east = { filename = "__my-mod__/graphics/entity/drill-E.png", size = 128, scale = 0.5 },
        south = { filename = "__my-mod__/graphics/entity/drill-N.png", size = 128, scale = 0.5 },
        west = { filename = "__my-mod__/graphics/entity/drill-W.png", size = 128, scale = 0.5, tint = { 255, 0, 0 } },
      } } },
  },
  ["storage-tank"] = {
    ["my-tank"] = { type = "storage-tank", name = "my-tank", collision_box = { { -1, -1 }, { 1, 1 } },
      pictures = {
        flow_sprite = { filename = "__base__/graphics/entity/pipe/fluid-flow-low-temperature.png", width = 160, height = 20 },
        picture = { sheets = { { filename = "__my-mod__/graphics/entity/tank.png", size = 220, frames = 2 } } },
      } },
  },
  ["radar"] = {
    ["my-sender"] = { type = "radar", name = "my-sender", collision_box = { { -1, -1 }, { 1, 1 } },
      base = { filename = "__my-mod__/blank.png", size = 1 },
      base_animation = { filename = "__my-mod__/graphics/entity/sender.png", width = 120, height = 140 } },
  },
  ["ammo-turret"] = {
    ["my-turret"] = { type = "ammo-turret", name = "my-turret", collision_box = { { -1, -1 }, { 1, 1 } },
      folded_animation = { filename = "__my-mod__/graphics/entity/turret.png", width = 100, height = 80, direction_count = 8, line_length = 4 } },
    ["my-gun"] = { type = "ammo-turret", name = "my-gun", collision_box = { { -1, -1 }, { 1, 1 } },
      graphics_set = { base_visualisation = { animation = { filename = "__my-mod__/gun-base.png", width = 150, height = 118, scale = 0.5 } } },
      folded_animation = { filename = "__my-mod__/gun-head.png", width = 130, height = 130, direction_count = 8, line_length = 4, scale = 0.5 } },
  },
  ["lab"] = {
    ["my-miner"] = { type = "lab", name = "my-miner", collision_box = { { -1, -1 }, { 1, 1 } },
      integration_patch = { north = { filename = "__my-mod__/patch.png", width = 200, height = 200, scale = 0.5 } },
      graphics_set = {
        animation = { layers = {
          { filename = "__my-mod__/miner.png", width = 190, height = 208, frame_count = 4, line_length = 4, scale = 0.5 },
          { filename = "__my-mod__/miner-shadow.png", width = 220, height = 150, draw_as_shadow = true, scale = 0.5 },
          { filename = "__my-mod__/miner-glow.png", width = 40, height = 40, draw_as_glow = true, scale = 0.5 },
          { filename = "__my-mod__/miner-light.png", width = 100, height = 100, blend_mode = "additive", scale = 0.5 } } },
        working_visualisations = {
          { always_draw = true, north_animation = { filename = "__my-mod__/miner-front.png", width = 136, height = 148, scale = 0.5 } },
          { always_draw = true, apply_tint = "status", north_animation = { filename = "__my-mod__/lamp.png", width = 32, height = 32, scale = 0.5 } },
          { animation = { filename = "__my-mod__/miner-fire.png", width = 40, height = 100, frame_count = 8, scale = 0.5 } } } } },
  },
  tree = {
    ["my-tree"] = { type = "tree", name = "my-tree", collision_box = { { -0.4, -0.4 }, { 0.4, 0.4 } },
      variations = { { trunk = { filename = "__my-mod__/graphics/entity/trunk.png", width = 60, height = 120, scale = 0.5 },
                       leaves = { filename = "__my-mod__/graphics/entity/leaves.png", width = 90, height = 100, frame_count = 3, scale = 0.5 } } } },
  },
  explosion = {
    ["my-boom"] = { type = "explosion", name = "my-boom", collision_box = { { 0, 0 }, { 0, 0 } },
      animations = { filename = "__my-mod__/boom.png", size = 64 } },
  },
}
return raw
"""

HARNESS = r"""
local raw = ...
data = { raw = raw, extended = {} }
function data:extend(list)
  for _, p in ipairs(list) do
    self.raw[p.type] = self.raw[p.type] or {}
    self.raw[p.type][p.name] = p
    self.extended[#self.extended + 1] = p
  end
end
logged = {}
function log(s) logged[#logged + 1] = s end
"""


def run(raw_lua, extra=""):
    lua = lua52.LuaRuntime(unpack_returned_tuples=True)
    g = lua.globals()
    g.package.path = str(MOD / "?.lua") + ";" + g.package.path
    raw = lua.execute(raw_lua)
    lua.execute(extra)
    lua.execute(HARNESS, raw)
    lua.execute((MOD / "data-final-fixes.lua").read_text())
    return lua, g


lua, g = run(RAW)
proto = g.data.raw["mod-data"]["zenith-graphics"]
check(proto is not None, "the list is a mod-data prototype")
data = proto.data
check(proto.data_type == "zenith-graphics", "its data_type names it")
n = int(data.n)
parts = [data["p%d" % i] for i in range(1, n + 1)]
check(all(isinstance(p, str) for p in parts), "parts are JSON text")
merged = {}
for p in parts:
    obj = json.loads(p)
    for sec, v in obj.items():
        merged.setdefault(sec, {})
        if sec == "icons":
            for kind, names in v.items():
                merged[sec].setdefault(kind, {}).update(names)
        else:
            merged[sec].update(v)
check(int(data.b) == sum(len(p) for p in parts), "b is the bytes of all parts")
check(len(str(data.fp)) == 16, "a 16-digit fingerprint")
print("list:", n, "parts,", int(data.b), "bytes")
icons = merged.get("icons", {})
item = icons.get("item", {})
check(item.get("iron-plate") == [["__base__/graphics/icons/iron-plate.png", 64, None, None, None]],
      "a plain icon: its file, size 64 by default: %r" % item.get("iron-plate"))
check(item.get("gizmo", [[None, 0]])[0][1] == 32, "icon_size kept")
bar = item.get("barrelled") or []
check(len(bar) == 3, "three layers")
if len(bar) == 3:
    t = bar[1][2]
    check(t and abs(t[0] - 1) < 1e-4 and abs(t[1] - 128 / 255) < 1e-3 and abs(t[3] - 191 / 255) < 1e-3,
          "a 0-255 tint becomes 0-1: %r" % (t,))
    check(bar[2][3] == 0.25 and bar[2][4] == [4, -4], "scale and shift kept: %r" % (bar[2],))
check("broken" not in item, "an item whose icons aren't a table is left out")
check("laser-pointer" in item, "any type with stack_size is an item")
check("goo" in icons.get("fluid", {}), "fluids")
rec = icons.get("recipe", {})
check("gizmo" not in rec, "a recipe showing its item of the same name is left out")
check(rec.get("gizmo-fast") == item.get("gizmo"), "a recipe without an icon shows its only product's")
check(rec.get("goo-making") == icons["fluid"]["goo"], "... or its fluid's")
check(rec.get("two-things") == item.get("box"), "... or its main product's")
check("own-icon" in rec, "a recipe's own icon")
check(icons.get("technology", {}).get("gizmos", [[0, 0]])[0][1] == 256, "technologies, 256 px")
check("signal-gizmo" in icons.get("virtual-signal", {}), "virtual signals")
check("gizmos" in icons.get("item-group", {}), "item groups (crafting tabs)")
check("big-battery" in icons.get("equipment", {}), "equipment")
ent = icons.get("entity", {})
check("box" not in ent and "box-ruin" in ent, "entities only when no item has their name")
tiles = merged.get("tiles", {})
floor = tiles.get("my-floor", {})
check(floor.get("mat") == ["__my-mod__/graphics/terrain/floor.png", 4, 0.5], "material background: %r" % floor)
check(floor.get("layer") == 70 and floor.get("group") == "ground-artificial" and floor.get("water") == 0, "layer, group")
check(floor.get("map") and abs(floor["map"][0] - 100 / 255) < 1e-3, "map colour 0-1")
grass = tiles.get("my-grass", {})
main = grass.get("main") or []
check(len(main) == 2 and main[0][:6] == ["__my-mod__/graphics/terrain/grass.png", 16, 1, 0, 0, 16]
      and main[0][7] == [0.1, 0.2] and main[0][8] == 0.5 and main[1][2] == 2 and main[1][4] == 128 and main[1][6] == 0.5 and main[1][7] is None,
      "main variants: %r" % main)
check(grass.get("group") == "ground-natural", "the default layer group")
swamp = tiles.get("my-swamp", {})
check(swamp.get("water") == 1 and swamp.get("fx") == "__my-mod__/graphics/terrain/swamp-shader.png", "water and its wetland picture: %r" % swamp)
check(tiles.get("my-void", {}).get("water") == 0 and tiles.get("my-lava", {}).get("water") == 0,
      "empty space and lava carry water_tile too, but aren't water: %r %r" % (tiles.get("my-void"), tiles.get("my-lava")))
check("no-pictures" not in tiles, "a tile without pictures is left out")
spr = merged.get("sprites", {})
check(spr.get("my-gui-sprite") == [["__my-mod__/graphics/gui/icons.png", 64, 0, 32, 32, 0.5, 0, 0]], "a sprite prototype: its file, place and size: %r" % spr.get("my-gui-sprite"))
check(spr.get("my-layered-sprite") == [["__my-mod__/graphics/gui/back.png", 0, 64, 64, 64, 1, 0, 0], ["__my-mod__/graphics/gui/front.png", 0, 0, 64, 64, 1, 0, 0]],
      "a layered sprite, bottom first, position read: %r" % spr.get("my-layered-sprite"))
decor = merged.get("decor", {})
peb = decor.get("pebbles", {})
check(len(peb.get("pics", [])) == 8, "a sheet's variations, at most 8")
if peb.get("pics"):
    check(peb["pics"][5] == ["__my-mod__/graphics/decorative/pebbles.png", 64, 32, 64, 32, 0.5, 0, -0.25],
          "variation 6 of a 4-wide sheet: %r" % peb["pics"][5])
check(peb.get("layer") == "decals" and peb.get("box") == [-1, -0.5, 1, 0.5], "layer and box")
fl = decor.get("flowers", {})
check(len(fl.get("pics", [])) == 2 and fl["pics"][0][3:5] == [32, 32] and fl["pics"][1][0].endswith("flower-2.png"),
      "a list of pictures, with size and layers: %r" % fl)
check(fl.get("layer") == "decorative", "the default render layer")
check("nothing" not in decor, "a decorative without pictures is left out")
check(any("graphics list:" in str(s) for s in g.logged.values()), "the log says what was made")
ents = merged.get("ents", {})
sm = ents.get("my-smelter", {})
check(sm.get("n") == [["__my-mod__/graphics/entity/smelter.png", 0, 0, 200, 220, 0.5, 0, -0.25, None,
                         {"f": 8, "l": 4, "s": 1, "x": 0, "y": 0}]] and set(sm) == {"n", "kn"},
      "a machine's first frame and how its 8 frames run, shadow and light left out, one direction: %r" % sm)
check(sm.get("kn", [[0]])[0][0].endswith("smelter-fire.png") and sm["kn"][0][9].get("q") == [1, 2, 3, 2]
      and sm["kn"][0][9].get("s") == 0.5 and len(sm["kn"]) == 1,
      "what it adds while working (its working visualisation), frame order and speed; a light left out: %r" % sm.get("kn"))
an = ents.get("my-anim", {}).get("n", [[0] * 10])[0]
check(len(an) == 10 and an[9].get("fs") == ["__my-mod__/a-1.png", "__my-mod__/a-2.png"] and an[9].get("p") == 2
      and an[9].get("m") == "forward-then-backward", "a sheet over several files, lines a file, the run mode: %r" % an)
sp = ents.get("my-striped", {}).get("n", [[0] * 10])[0]
check(len(sp) == 10 and sp[9].get("st") == [["__my-mod__/s-1.png", 4, 2, 0, 0], ["__my-mod__/s-2.png", 4, 2, 0, 0]],
      "a striped animation's stripes: %r" % sp)
tu2 = ents.get("my-turret", {})
check("o" not in tu2.get("n", [[0] * 9])[0][-1] if len(tu2.get("n", [[0] * 9])[0]) == 10 else True,
      "a rotated sprite without frames has no animation")
dr = ents.get("my-drill", {})
check(dr.get("n", [[0]])[0][0].endswith("drill-N.png") and dr.get("e", [[0]])[0][0].endswith("drill-E.png") and "s" not in dr
      and dr.get("w", [[0] * 9])[0][8] == [1, 0, 0, 1], "four directions, only those unlike north, tint kept: %r" % dr)
tu = ents.get("my-turret", {})
check(tu.get("n", [[0, 0, 0]])[0][1:3] == [0, 0] and tu.get("e", [[0, 0, 0]])[0][1:3] == [200, 0]
      and tu.get("s", [[0, 0, 0]])[0][1:3] == [0, 80], "a rotated sprite's frames by direction: %r" % tu)
tk = ents.get("my-tank", {})
check(tk.get("n", [[""]])[0][0].endswith("tank.png"), "a storage tank's own picture, not its fluid flow's: %r" % tk)
se = ents.get("my-sender", {})
check(se.get("n", [[""]])[0][0].endswith("sender.png"), "a blank 1x1 base is passed over for base_animation: %r" % se)
tr = ents.get("my-tree", {})
check(len(tr.get("n", [])) == 2 and tr["n"][1][0].endswith("leaves.png"), "a tree's trunk and leaves: %r" % tr)
check("my-boom" not in ents, "effects aren't listed")
mi = ents.get("my-miner", {})
check([l[0].rsplit("/", 1)[-1] for l in mi.get("n", [])] == ["patch.png", "miner.png", "miner-glow.png", "miner-front.png"]
      and [l[0].rsplit("/", 1)[-1] for l in mi.get("kn", [])] == ["miner-fire.png"],
      "every layer Factorio draws at rest in its order (patch, picture, glow, always-drawn front), no shadow, additive or status lamp: %r" % mi)
gu = ents.get("my-gun", {})
check([l[0].rsplit("/", 1)[-1] for l in gu.get("n", [])] == ["gun-base.png", "gun-head.png"], "a turret's folded head over its base: %r" % gu)

# The client's validator accepts the parts as `gfx` messages.
for i, p in enumerate(parts):
    msg = {"t": "gfx", "k": 1, "fp": str(data.fp), "part": i + 1, "parts": n, "d": json.loads(p)}
    probs = protocol.problems(msg)
    check(not probs, "gfx part %d validates: %s" % (i + 1, probs))

# Small parts: every entry in exactly one part, each part valid JSON.
ex = lua.eval('require("scripts.gfx_extract")')
entries = ex.entries(g.data.raw)
small = ex.parts(entries, 400)
names = []
for i in range(1, len(small) + 1):
    obj = json.loads(small[i])
    for sec, v in obj.items():
        if sec == "icons":
            for kind, d in v.items():
                names += ["%s/%s/%s" % (sec, kind, k) for k in d]
        else:
            names += ["%s/%s" % (sec, k) for k in v]
check(len(small) > 3, "a small limit gives several parts (%d)" % len(small))
check(len(names) == len(set(names)) == len(entries), "each entry once: %d of %d" % (len(set(names)), len(entries)))

# The same prototypes in another order make the same text and fingerprint.
reordered = RAW.replace('["iron-plate"] = {', '["zz"] = { type = "item", name = "zz", icon = "__my-mod__/zz.png", stack_size = 1 }, ["iron-plate"] = {')
_, g2 = run(reordered, "")
_, g3 = run(RAW)
check(str(g3.data.raw["mod-data"]["zenith-graphics"].data.fp) == str(data.fp), "the same data, the same fingerprint")
check(str(g2.data.raw["mod-data"]["zenith-graphics"].data.fp) != str(data.fp), "other data, another fingerprint")
# The format is in the fingerprint (no separate version field the client would have to read):
# FORMAT 1's fingerprints stay as they were, a later format makes clients fetch the list again.
texts = lua.table_from(["{}", "{\"a\": 1}"])
check(data.v is None and ex.FORMAT == 3 and ex.fingerprint(texts, 1) == ex.fingerprint(texts)
      and ex.fingerprint(texts, 2) != ex.fingerprint(texts) and ex.fingerprint(texts, 3) != ex.fingerprint(texts, 2), "the format goes into the fingerprint, not a field")

# A data.raw the extractor can't read only costs the list.
_, g4 = run("return { item = setmetatable({}, { __pairs = function() error('boom') end }) }")
check(g4.data.raw["mod-data"] is None or g4.data.raw["mod-data"]["zenith-graphics"] is None, "no list after an error")
check(any("not made" in str(s) for s in g4.logged.values()), "the error is logged")

# JSON: escapes, numbers, nulls.
enc = ex.encode
check(enc(lua.eval('{ "a\\"b\\\\c", 1, 0.5, -0.0, 1e-7 }')) == '["a\\"b\\\\c",1,0.5,0,1e-07]', "encoding: %s" % enc(lua.eval('{ "a\\"b\\\\c", 1, 0.5, -0.0, 1e-7 }')))

# The planets with lightning (the 0.2.1 hotfix: planets.lua looks for lightning often only on those).
_, g5 = run("""return { planet = {
  fulgora = { type = "planet", name = "fulgora", lightning_properties = { search_radius = 10 } },
  nauvis = { type = "planet", name = "nauvis" },
  aaa = { type = "planet", name = "aaa", lightning_properties = {} },
} }""")
pl = g5.data.raw["mod-data"]["zenith-planets"] if g5.data.raw["mod-data"] else None
check(pl is not None and pl.data_type == "zenith-planets" and list(pl.data.lightning.values()) == ["aaa", "fulgora"],
      "zenith-planets lists the planets whose prototype has lightning, sorted: %r" % (list(pl.data.lightning.values()) if pl else None))
_, g6 = run("return {}")
pl = g6.data.raw["mod-data"] and g6.data.raw["mod-data"]["zenith-planets"]
check(pl is not None and len(list(pl.data.lightning.values())) == 0, "and an empty list without planets")

# J11: each minable entity's own mining_sound, as the file of its first variation without its number:
# a Sound with variations, one with a filename, and a bare list (sound_variations); none for those
# without (a tree) or that can't be mined.
_, g7 = run("""return {
  ["simple-entity"] = {
    ["huge-rock"] = { type = "simple-entity", name = "huge-rock", minable = { mining_time = 2 },
      mining_sound = { variations = { { filename = "__base__/sound/axe-mining-stone-1.ogg", volume = 0.5 },
                                      { filename = "__base__/sound/axe-mining-stone-2.ogg", volume = 0.5 } } } },
    ["fake-rock"] = { type = "simple-entity", name = "fake-rock", mining_sound = { filename = "__base__/sound/x.ogg" } },
  },
  resource = { stone = { type = "resource", name = "stone", minable = { mining_time = 1 },
    mining_sound = { filename = "__core__/sound/axe-mining-stone.ogg" } } },
  plant = { ["yumako-tree"] = { type = "plant", name = "yumako-tree", minable = { mining_time = 0.5 },
    mining_sound = { { filename = "__space-age__/sound/mining/axe-mining-yumako-tree-1.ogg", volume = 0.6 } } } },
  tree = { ["tree-01"] = { type = "tree", name = "tree-01", minable = { mining_time = 0.5 } } },
  wall = { ["stone-wall"] = { type = "wall", name = "stone-wall", minable = { mining_time = 0.2 },
    repair_sound = { { filename = "__base__/sound/manual-repair-simple-1.ogg", volume = 0.5 },
                     { filename = "__base__/sound/manual-repair-simple-2.ogg", volume = 0.5 } } } },
  ["assembling-machine"] = { ["assembling-machine-1"] = { type = "assembling-machine", name = "assembling-machine-1" } },
}""")
md = g7.data.raw["mod-data"] and g7.data.raw["mod-data"]["zenith-mining-sounds"]
ms = {k: v for k, v in md.data.ms.items()} if md is not None else None
check(ms == {"huge-rock": "base/sound/axe-mining-stone", "stone": "core/sound/axe-mining-stone",
             "yumako-tree": "space-age/sound/mining/axe-mining-yumako-tree"},
      "J11: zenith-mining-sounds has each minable entity's own mining sound: %r" % ms)
# K13: and each entity's own repair_sound the same way (a wall's hammering); none for one without.
rs = {k: v for k, v in md.data.rs.items()} if md is not None and md.data.rs is not None else None
check(rs == {"stone-wall": "base/sound/manual-repair-simple"},
      "K13: zenith-mining-sounds has each entity's own repair sound: %r" % rs)

# Step 5 task 3a: the steps' sounds (zenith-step-sounds): tiles, rails, resources, decoratives, armours and
# the two utility sounds, each sound once, a mod's oddly named files as a list, and a broken walking_sound
# (a string, or a file outside any mod) costing only its own entry: left out, so the client plays its
# table there, not silence (silent, 0, only for no walking_sound at all).
STEP_RAW = """
local function vars(prefix, n, volume)
  local out = {}
  for i = 1, n do out[i] = { filename = prefix .. "-" .. i .. ".ogg", volume = volume } end
  return out
end
return {
  tile = {
    ["grass-1"] = { type = "tile", name = "grass-1", walking_sound = { variations = vars("__base__/sound/walking/grass", 10, 0.8) } },
    ["grass-2"] = { type = "tile", name = "grass-2", walking_sound = { variations = vars("__base__/sound/walking/grass", 10, 0.8) } },
    ["dirt-1"] = { type = "tile", name = "dirt-1", walking_sound = vars("__base__/sound/walking/sand", 9, 0.8) },
    ["lab-white"] = { type = "tile", name = "lab-white", walking_sound = { filename = "__base__/sound/walking/concrete-1.ogg", volume = 0.5 } },
    ["one-file"] = { type = "tile", name = "one-file", walking_sound = { filename = "__my-mod__/sound/thud.ogg" } },
    ["odd-floor"] = { type = "tile", name = "odd-floor", walking_sound = { variations = {
      { filename = "__my-mod__/sound/floor/clank_a.ogg", min_volume = 0.4, max_volume = 0.6 },
      { filename = "__my-mod__/sound/floor/clank_b.ogg", min_volume = 0.4, max_volume = 0.6 } } } },
    ["deepwater"] = { type = "tile", name = "deepwater" },
    ["broken-tile"] = { type = "tile", name = "broken-tile", walking_sound = "__base__/sound/walking/grass-1.ogg" },
    ["no-mod-tile"] = { type = "tile", name = "no-mod-tile", walking_sound = { filename = "sound/walking/odd.ogg" } },
  },
  ["straight-rail"] = { ["straight-rail"] = { type = "straight-rail", name = "straight-rail",
    walking_sound = { variations = vars("__base__/sound/walking/rails/rails", 12, 0.6) } } },
  ["curved-rail-a"] = { ["curved-rail-a"] = { type = "curved-rail-a", name = "curved-rail-a",
    walking_sound = { variations = vars("__base__/sound/walking/rails/rails", 12, 0.6) } } },
  resource = {
    ["crude-oil"] = { type = "resource", name = "crude-oil", walking_sound = { variations = vars("__base__/sound/walking/resources/oil", 7, 0.7) } },
    ["iron-ore"] = { type = "resource", name = "iron-ore" },
    ["odd-ore"] = { type = "resource", name = "odd-ore", walking_sound = { filename = 7 } },
  },
  ["optimized-decorative"] = {
    ["brown-asterisk"] = { type = "optimized-decorative", name = "brown-asterisk",
      walking_sound = { variations = vars("__base__/sound/walking/plant/plant", 5, 0.4) } },
    ["small-rock"] = { type = "optimized-decorative", name = "small-rock" },
  },
  armor = {
    ["mech-armor"] = { type = "armor", name = "mech-armor",
      steps_sound = { variations = vars("__space-age__/sound/entity/mech-armor/mech-armor-steps-metallic", 5, 0.2) },
      moving_sound = { variations = vars("__space-age__/sound/entity/mech-armor/mech-armor-moves", 10, 0.4) } },
    ["power-armor"] = { type = "armor", name = "power-armor" },
  },
  unit = { ["small-biter"] = { type = "unit", name = "small-biter", walking_sound = { filename = "__base__/sound/x.ogg" } } },
  ["night-vision-equipment"] = { ["night-vision-equipment"] = { type = "night-vision-equipment", name = "night-vision-equipment",
    activate_sound = { filename = "__base__/sound/nightvision-on.ogg", volume = 0.5 },
    deactivate_sound = { filename = "__base__/sound/nightvision-off.ogg", volume = 0.5 } } },
  ["utility-sounds"] = { default = { type = "utility-sounds", name = "default",
    metal_walking_sound = vars("__core__/sound/walking/transport-belt", 9, 0.6),
    heat_pipe_walking_sound = vars("__core__/sound/walking/heat-pipe", 5, 0.7) } },
}
"""
_, g8 = run(STEP_RAW)
sd = g8.data.raw["mod-data"] and g8.data.raw["mod-data"]["zenith-step-sounds"]


def py(v):
    if lupa_type(v) == "table":
        items = list(v.items())
        if items and all(isinstance(k, int) for k, _ in items) and sorted(k for k, _ in items) == list(range(1, len(items) + 1)):
            return [py(v[i]) for i in range(1, len(items) + 1)]
        return {k: py(x) for k, x in items}
    return v


lupa_type = lua52.lua_type
step = py(sd.data) if sd is not None else {}
snd = step.get("s", [])


def sound(i):
    return snd[i - 1] if i else None


tile = step.get("tile", {})
check(sd is not None and sd.data_type == "zenith-step-sounds", "zenith-step-sounds is a mod-data prototype")
check(sound(tile.get("grass-1")) == ["base/sound/walking/grass", 80, 10] and tile.get("grass-1") == tile.get("grass-2"),
      f"steps: a tile's variations as their prefix, volume and count, the same sound listed once: {sound(tile.get('grass-1'))}")
check(sound(tile.get("dirt-1")) == ["base/sound/walking/sand", 80, 9],
      f"steps: a bare list of variations (sound_variations), dirt-1's sand as Factorio has it: {sound(tile.get('dirt-1'))}")
check(sound(tile.get("lab-white")) == ["base/sound/walking/concrete", 50, 1] and sound(tile.get("one-file")) == ["my-mod/sound/thud", 100, 1],
      f"steps: a bare filename, numbered or not, volume 1 when none is given: {sound(tile.get('lab-white'))} {sound(tile.get('one-file'))}")
check(sound(tile.get("odd-floor")) == [["my-mod/sound/floor/clank_a.ogg", "my-mod/sound/floor/clank_b.ogg"], 50, 2],
      f"steps: a mod's oddly named files as their list, min and max volume's middle: {sound(tile.get('odd-floor'))}")
check(tile.get("deepwater") == 0 and len(tile) == 7,
      f"steps: a tile without a sound listed silent (0), the others still there: {tile}")
check("broken-tile" not in tile and "no-mod-tile" not in tile,
      f"steps: a tile whose sound can't be read left out (the client's table), not silent: {tile}")
ent = step.get("entity", {})
check(sound(ent.get("straight-rail")) == ["base/sound/walking/rails/rails", 60, 12] and ent.get("curved-rail-a") == ent.get("straight-rail")
      and sound(ent.get("crude-oil")) == ["base/sound/walking/resources/oil", 70, 7] and set(ent) == {"straight-rail", "curved-rail-a", "crude-oil"},
      f"steps: rails and resources with a walking sound; not a biter's, nor ore without one or with one that can't be read: {ent}")
dec = step.get("decorative", {})
check(sound(dec.get("brown-asterisk")) == ["base/sound/walking/plant/plant", 40, 5] and set(dec) == {"brown-asterisk"},
      f"steps: a decorative's rustle: {dec}")
arm = step.get("armor", {})
check([sound(i) for i in arm.get("mech-armor", [])] == [["space-age/sound/entity/mech-armor/mech-armor-steps-metallic", 20, 5],
      ["space-age/sound/entity/mech-armor/mech-armor-moves", 40, 10]] and "power-armor" not in arm,
      f"steps: an armour's steps and moving sounds: {arm}")
check([sound(i) for i in step.get("u", [])] == [["core/sound/walking/transport-belt", 60, 9], ["core/sound/walking/heat-pipe", 70, 5]],
      f"steps: the utility sounds, metal (belts) and heat pipes: {step.get('u')}")
check([sound(i) for i in step.get("nv", [])] == [["base/sound/nightvision-on", 50, 1], ["base/sound/nightvision-off", 50, 1]],
      f"steps: the night vision equipment's activate and deactivate sounds: {step.get('nv')}")
check(len({json.dumps(x) for x in snd}) == len(snd), "steps: each sound once")

# One sound listing more files than a part holds keeps those that fit, with a log line.
fit_mod = lua52.LuaRuntime(unpack_returned_tuples=True)
fit_mod.globals().package.path = str(MOD / "?.lua") + ";" + fit_mod.globals().package.path
fit_mod.execute("fit_log = {}; function log(s) fit_log[#fit_log + 1] = s end")
fitter = fit_mod.execute('return require("scripts.step_sounds")')
big = fit_mod.execute("""
local files = {}
for i = 1, 200 do files[i] = "a-mod/sound/walking/a-rather-long-and-unnumbered-step-file-name_" .. i .. ".ogg" end
return { files, 70, 200 }""")
fitted = py(fitter.fit(big, 3))
fitted_size = len(json.dumps({"t": "steps", "part": 1, "parts": 1, "s": [fitted]}, separators=(",", ":")))
check(0 < fitted[2] == len(fitted[0]) < 200 and fitted[0] == py(big)[0][:fitted[2]] and fitted_size < 4096
      and len(list(fit_mod.globals().fit_log.values())) == 1,
      f"steps: a sound with too many files for a part cut to fit ({fitted[2]} of 200, {fitted_size} bytes), logged once")
small = fit_mod.execute('return { "base/sound/walking/grass", 80, 10 }')
check(fit_mod.eval("function(m, s) return m.fit(s, 1) == s end")(fitter, small), "steps: a sound that fits is left as it is")

# Without the utility sounds or any tile, and with nothing at all, a list is still made.
_, g9 = run("return {}")
sd9 = g9.data.raw["mod-data"] and g9.data.raw["mod-data"]["zenith-step-sounds"]
check(sd9 is not None and py(sd9.data.u) == [0, 0], "steps: an empty list without prototypes")

# The runtime side: the messages from the list, in parts under PART_BYTES, the sounds first; none without a list.
rt = lua52.LuaRuntime(unpack_returned_tuples=True)
rt.globals().package.path = str(MOD / "?.lua") + ";" + rt.globals().package.path
steps_mod = rt.execute('return require("scripts.step_sounds")')
rt.execute("prototypes = { mod_data = {} }")
reg = rt.eval("{ tile_id = function(n) return 1 end, entity_id = function(n) return 1 end, decorative_id = function(n) return 1 end, item_id = function(n) return 1 end }")
check(len(list(steps_mod.messages(reg).values())) == 0, "steps: no message when the data stage made no list (the client keeps its table)")
rt2 = lua52.LuaRuntime(unpack_returned_tuples=True)
rt2.globals().package.path = str(MOD / "?.lua") + ";" + rt2.globals().package.path
steps_mod2 = rt2.execute('return require("scripts.step_sounds")')
rt2.execute("""
local s, tile = {}, {}
for i = 1, 300 do s[i] = { "a-mod/sound/walking/ground-number-" .. i, 70, 6 }; tile["t" .. i] = i end
tile.missing = 5
prototypes = { mod_data = { ["zenith-step-sounds"] = { get = function(k)
  return ({ s = s, tile = tile, entity = {}, decorative = {}, armor = {}, u = { 1, 0 } })[k] end } } }
ids = {}
for i = 1, 300 do ids["t" .. i] = i end
""")
reg2 = rt2.eval("{ tile_id = function(n) return ids[n] or 0 end, entity_id = function() return 0 end, decorative_id = function() return 0 end, item_id = function() return 0 end }")
msgs2 = [py(m) for m in steps_mod2.messages(reg2).values()]
sizes = [len(json.dumps(m, separators=(",", ":"))) for m in msgs2]
all_s = [e for m in msgs2 for e in m.get("s", [])]
all_tl = [e for m in msgs2 for e in m.get("tl", [])]
check(len(msgs2) >= 4 and all(sz < 4096 for sz in sizes) and [m["part"] for m in msgs2] == list(range(1, len(msgs2) + 1))
      and all(m["parts"] == len(msgs2) for m in msgs2) and len(all_s) == 300 and len(all_tl) == 300
      and msgs2[0]["u"] == [1, 0] and all("u" not in m for m in msgs2[1:]),
      f"steps: a long list in parts each under the smallest byte budget, every entry once, an unknown name left out: {sizes}")
first_tl = next(i for i, m in enumerate(msgs2) if "tl" in m)
check(all("s" not in m for m in msgs2[first_tl + 1:]), "steps: the sounds come before the names that point at them")
for m in msgs2:
    m.update({"k": 1, "r": 1, "t": "steps"})
    for problem in protocol.problems(m):
        check(False, f"steps: protocol: {problem}")

print("DATA STAGE FAILS: %d" % len(failures))
sys.exit(1 if failures else 0)
