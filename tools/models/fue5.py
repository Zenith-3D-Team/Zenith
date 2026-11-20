#!/usr/bin/env python3
"""Converts the FUE5 fan project's models (https://github.com/FUE5BASE/FUE5, by Hurricane and
Nuke, CC BY-NC-SA 3.0) into client models in client/assets/models/packs/fue5/ (FUE5's pack, packs.py).

    python tools/models/fue5.py [names...] [--out DIR] [--yaw DEG]   # build (Blender)
    python tools/models/fue5.py --score [names...] [--glb-dir DIR]     # overlap, ours and theirs

Source files: FUE5's FBX files and the .jpg textures beside them, from
Content/MyStuff/ENTITIES/STRUCTURES and VEHICLES of its repository, in the git-ignored
art-src/fue5/raw/<STRUCTURES|VEHICLES>/<model>/ (never committed). A conversion (fue5_blender.py)
scales them to tiles (2 units a tile), turns them to face north, drops ground decals, decimates to
the triangle budget in specs.py and bakes every texture into one atlas; moving parts named in a
recipe become `anim_*` nodes, and bake_glb.py bakes ambient occlusion into COLOR_0. Scoring uses fit.py's silhouette overlap against Factorio's sprites.
"""

import argparse
import json
import math
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

import packs  # noqa: E402
import specs  # noqa: E402

ART = os.path.normpath(os.path.join(REPO.split(os.sep + ".claude" + os.sep)[0], "art-src", "fue5"))
RAW = os.path.join(ART, "raw")
OUT_DIR = packs.FUE5_DIR
BLENDER = os.environ.get("BLENDER", r"C:\Program Files\Blender Foundation\Blender 5.2\blender.exe")
GENERATOR = "Zenith tools/models/fue5.py"

# Prototype -> recipe. `fbx` relative to RAW; `yaw` turns the model clockwise (seen from above) so
# its front faces north, found by scoring every quarter turn against the sprite.
RECIPES = {
    # Its two fans from the animated file's bones.
    "electric-furnace": {"fbx": ["STRUCTURES/electric-furnace/static.fbx", "STRUCTURES/electric-furnace/animated1.fbx"],
                         "yaw": 0, "bones": {"anim_spin_fan": ["spin"], "anim_spin_fan.001": ["spin_1"]}},
    "rocket-silo": {"fbx": ["STRUCTURES/rocket-silo/static.fbx"], "yaw": 90, "centre": "bbox",
                    # FUE5 sinks the hatch 1.1 tiles into a hole in its ground; ours has none, so the
                    # hatch's plate, cut to the ring's opening as the two doors, is raised to just over
                    # the ground, over a dark pit floor as ours has (the rocket waits below it).
                    "hatch": {"mats": ["mat1"], "clear": "door", "zmax": -0.6, "radius": 2.6, "lift_to": 0.03,
                              "west": "anim_door_silo_w", "east": "anim_door_silo_e"},
                    "pit": {"radius": 2.62, "z": 0.015},
                    # Its south-west corner holds a pointed pod on its side that Factorio's silo
                    # doesn't have (the owner's "side pod with rocket").
                    "drop": ["corner"],
                    # Round: matching ours (a little deeper than wide) would make its ring oval.
                    "match": False},
    # Its four wheel sets roll (movers.gd) about their middles.
    "locomotive": {"fbx": ["VEHICLES/locomotive/static.fbx"], "yaw": 270, "match_all": True,
                   "anim": {"anim_wheel_rail": ["wheel"], "anim_wheel_rail.001": ["wheel_2"],
                            "anim_wheel_rail.002": ["wheel_Instance"], "anim_wheel_rail.003": ["wheel_Instance_2"]},
                   "pivot": {"anim_wheel_rail": "bbox", "anim_wheel_rail.001": "bbox",
                             "anim_wheel_rail.002": "bbox", "anim_wheel_rail.003": "bbox"}},
    "oil-refinery": {"fbx": ["STRUCTURES/oil-refinery/static.fbx"], "yaw": 270},
}


def _static(folder, yaw=0, **more):
    return dict({"fbx": ["STRUCTURES/%s/static.fbx" % folder], "yaw": yaw}, **more)


RECIPES.update({
    "wooden-chest": _static("wooden-chest"),
    "iron-chest": _static("iron-chest"),
    "steel-chest": _static("steel-chest"),
    "small-lamp": _static("small-lamp"),
    "solar-panel": _static("solar-panel", 270),
    "stone-furnace": _static("stone-furnace"),
    "steel-furnace": _static("steel-furnace"),
    "lab": _static("lab"),
    "storage-tank": _static("storage-tank"),
    "programmable-speaker": _static("programmable-speaker", 180),
    "arithmetic-combinator": _static("arithmetic-combinator"),
    "decider-combinator": _static("decider-combinator"),
    "constant-combinator": _static("constant-combinator"),
    "accumulator": _static("accumulator"),
    "beacon": _static("beacon"),
})

WHEELS = {"anim_wheel_rail": ["wheel"], "anim_wheel_rail.001": ["wheel_2"],
          "anim_wheel_rail.002": ["wheel_Instance"], "anim_wheel_rail.003": ["wheel_Instance_2"]}
WHEEL_PIVOTS = {k: "bbox" for k in WHEELS}
# Wheel sets moved to ours (1.5 and 2.5 tiles either side of the middle, as Factorio's bogies), so
# they line up with the track and with our wagons' coupling.
WHEEL_PLACES = [{"groups": ["wheel_Instance"], "to": [0.0, None, 2.5]}, {"groups": ["wheel"], "to": [0.0, None, 1.5]},
                {"groups": ["wheel_Instance_2"], "to": [0.0, None, -1.5]}, {"groups": ["wheel_2"], "to": [0.0, None, -2.5]}]
RECIPES["locomotive"]["place"] = WHEEL_PLACES
RECIPES.update({
    # Poles: their insulators where Factorio's wires attach (wires.gd POLE_POINTS: tops for the
    # small pole, middles for the rest), not matched to our poles' size. The small pole's three
    # nearly sit at Factorio's spacing: the pole moves 0.18 north and grows to their height.
    "small-electric-pole": _static("small-electric-pole", match=False, shift=[0.035, 0.18, 0], scale=[0.9, 1, 1.07], place=[
        {"groups": ["Null_1", "Cloner_3"], "to": [0.02, 3.98, -0.18], "anchor": "top"},
        {"groups": ["Null_2_2", "Cloner_4"], "to": [0.46, 3.98, -0.18], "anchor": "top"},
        {"groups": ["Null_0", "Cloner_2"], "to": [-0.38, 3.98, -0.18], "anchor": "top"}]),
    "medium-electric-pole": _static("medium-electric-pole", match=False, scale=[0.72, 1.0, 1.0], place=[
        {"groups": ["Null_1", "Cloner_3"], "to": [0.234, 4.947, 0.0]},
        {"groups": ["Null_2_2", "Cloner_4"], "to": [0.672, 4.48, 0.0]},
        {"groups": ["Null_0", "Cloner_2"], "to": [-0.234, 4.62, 0.0]}]),
    # The big pole and substation have one insulator: it goes on the copper point, and copies of
    # it on the red and green ones. FUE5's substation is modelled 3.5 tiles wide: shrunk into its
    # 2x2 it is also stretched up 1.26x, so its tower reaches the wire points.
    "big-electric-pole": _static("big-electric-pole", match=False, place=[
        {"groups": ["Cloner"], "to": [0.0, 5.784, 0.0]},
        {"groups": ["Cloner"], "to": [0.906, 4.967, 0.0], "copy": True},
        {"groups": ["Cloner"], "to": [-0.906, 4.967, 0.0], "copy": True}]),
    "substation": _static("substation", match=False, scale=[1, 1, 1.26], place=[
        {"groups": ["Cloner_6", "Null_7"], "to": [0.0, 4.316, 0.0]},
        {"groups": ["Cloner_6", "Null_7"], "to": [0.688, 4.083, 0.0], "copy": True},
        {"groups": ["Cloner_6", "Null_7"], "to": [-0.656, 4.13, 0.0], "copy": True}]),
    "roboport": _static("roboport"),
    "train-stop": _static("train-stop", fit="width"),
    "pump": _static("pump"),
    "nuclear-reactor": _static("nuclear-reactor", 90),
    # The dish (its own file) turns on the radar's middle.
    "radar": {"fbx": ["STRUCTURES/radar/static1.fbx", "STRUCTURES/radar/static2.fbx"], "yaw": 0,
              "file_parts": {"1": "anim_spin_radar"}, "pivot": {"anim_spin_radar": "axis"}},
    # The head (its own file) turns where the mod says the turret aims.
    "gun-turret": {"fbx": ["STRUCTURES/gun-turret/static1.fbx", "STRUCTURES/gun-turret/static2.fbx"], "yaw": 0,
                   "file_parts": {"1": "anim_turret_head"}, "pivot": {"anim_turret_head": "axis"}},
    # Rotors from the animated file's bones; its arm and crane stay still.
    "centrifuge": {"fbx": ["STRUCTURES/centrifuge/static.fbx", "STRUCTURES/centrifuge/animated1.fbx"], "yaw": 0,
                   "bones": {"anim_spin_rotor": ["rotation1"], "anim_spin_rotor.001": ["updown2", "rotation2"]}},
    "steam-turbine": {"fbx": ["STRUCTURES/steam-turbine/static.fbx", "STRUCTURES/steam-turbine/animated1.fbx"],
                      "yaw": 90, "bones": {"anim_spin_turbine_fan": ["spin1"]}},
    # FUE5's rocket is 5.9 tiles tall, Factorio's (and ours) 16.9: stretched to our height, and
    # to our width separately (a uniform 2.9x would be 9 tiles wide, past the silo's opening).
    # Its base (FUE5 z 0.8) on the origin, as rockets.gd expects.
    "rocket-silo-rocket": {"fbx": ["VEHICLES/rocket/static.fbx"], "yaw": 0, "match": False,
                           "scale": [1.40, 1.40, 2.887], "shift": [0, 0, -0.796 * 0.5 * 2.887]},
    "cargo-wagon": {"fbx": ["VEHICLES/cargo-wagon/static.fbx"], "yaw": 270, "anim": WHEELS, "pivot": WHEEL_PIVOTS,
                    "match_all": True, "place": WHEEL_PLACES},
    "fluid-wagon": {"fbx": ["VEHICLES/fluid-wagon/static.fbx"], "yaw": 270, "anim": WHEELS, "pivot": WHEEL_PIVOTS,
                    "match_all": True, "place": WHEEL_PLACES},
    "electric-mining-drill": {"fbx": ["STRUCTURES/electric-mining-drill/static.fbx",
                                      "STRUCTURES/electric-mining-drill/animated1.fbx",
                                      "STRUCTURES/electric-mining-drill/animated2.fbx"], "yaw": 180,
                              "bones": {"anim_spin_drill": ["drill"]}},
})

# Entities Zenith's own models draw with a model per direction (model_library.gd FACING_MODELS): FUE5
# has one model, so only the north one is written and the client turns it (model_library.gd
# single_model). Every direction of ours is still measured, so it fits them all.
FACINGS = {
    "boiler": ({"fbx": ["STRUCTURES/boiler/static.fbx"], "yaw": 0}, ["", "-east", "-south", "-west"]),
    "chemical-plant": ({"fbx": ["STRUCTURES/chemical-plant/static.fbx"], "yaw": 0}, ["", "-east", "-south", "-west"]),
    # FUE5's pumpjack is the mirror image of Factorio's: tools/models/fue5_pumpjack.py, after this, puts
    # its outlet where Factorio's output is (no yaw can).
    "pumpjack": ({"fbx": ["STRUCTURES/pumpjack/static.fbx", "STRUCTURES/pumpjack/animated1.fbx"], "yaw": 0},
                 ["", "-east", "-south", "-west"]),
    # Then fue5_steam_engine.py: matched to ours it is 5.83 tiles long, past its 5-tile box at both ends.
    "steam-engine": ({"fbx": ["STRUCTURES/steam-engine/static.fbx", "STRUCTURES/steam-engine/animated1.fbx",
                              "STRUCTURES/steam-engine/animated2.fbx"], "yaw": 90,
                      # Its wheels turning about FUE5's Y, across the engine: east-west once turned.
                      "bones": {"anim_spin_flywheel": ["rotate3"], "anim_spin_flywheel.001": ["rotate2"],
                                "anim_spin_flywheel.002": ["rotate4"], "anim_spin_flywheel.003": ["rotate6"],
                                "anim_spin_flywheel.004": ["rotate7"]}}, ["", "-east"]),
}


def _facings():
    for base, (recipe, sfxs) in FACINGS.items():
        for k, sfx in enumerate(sfxs[:1]):
            r = dict(recipe, yaw=recipe["yaw"] + 90 * k, spec=base)
            if k % 2 and "bones" in recipe:
                r["bones"] = {name.replace("anim_spin_flywheel", "anim_spin_flywheel_ns"): b
                              for name, b in recipe["bones"].items()}
            # Every direction is matched to the same size (our directions' median, turned with it),
            # so they stay one model turned.
            r["match_turns"] = (base, sfxs, k)
            RECIPES[base + sfx] = r


def _facing_size(base, sfxs, k):
    sizes = []
    for i, sfx in enumerate(sfxs):
        d = our_size(base + sfx)
        if d:
            sizes.append([d[1], d[0], d[2]] if i % 2 else d)
    if not sizes:
        return None
    mid = [sorted(s[a] for s in sizes)[len(sizes) // 2] for a in range(3)]
    return [mid[1], mid[0], mid[2]] if k % 2 else mid


_facings()

# Logistic chests (one group): FUE5 has one mesh for all five; its per-chest colours were Unreal
# material instances, not downloaded, and the four textures beside it are the shared grey ones
# (the FBX names them logistic-chest-storage_mat1..5; the file mat2 is the side panels' mat5). The
# paints are each chest's sprite colours (frame 0 of data/base/graphics/entity/logistic-chest/
# <name>.png, its saturated pixels, in linear light) with the sprite's light taken off, given as a
# multiplier on each grey texture's mean: the lid (mat1) its lid's colour over the light on the lid
# (FUE5's hatch texture, mat3, against the sprite's cream hatch: x0.544); the side panels (mat5)
# and the dark olive frame and body (mat4, the same for all five) the front's colours over the
# light on the front as well (Zenith's sprite camera lights a front 0.428 of a top, so x1.27).
# Two of the four textures carry a repeated "Adobe Stock" watermark (seen with a contrast boost):
# mat4, the frame and body, and the file mat2, the side panels. A stock watermark is someone's
# licensed photo, not FUE5's work, so neither ships: those two materials are flat colours (`flat`),
# each its paint times the mean of the texture it replaces in linear light (mat4 0.1527, mat2
# 0.1973), so the chests' colours stay as they were and the baked occlusion carries the shading.
# The lid (mat1) and hatch (mat3) textures are clean and kept.
_LC = "STRUCTURES/logistic-chests/"
_LC_IMAGES = {"mat1": _LC + "logistic-chest_mat1_diffuse1.jpg", "mat3": _LC + "logistic-chest_mat3_diffuse1.jpg"}
_LC_MEAN = {"mat4": 0.1527, "mat5": 0.1973}  # the marked textures' mean, linear
_LC_BODY = [0.177, 0.177, 0.124]
_LC_PAINT = {  # chest: (lid paint over mat1's grey, panel paint over mat5's grey)
    "active-provider-chest": ([0.527, 0.178, 0.826], [0.253, 0.046, 0.448]),
    "passive-provider-chest": ([1.087, 0.207, 0.164], [0.666, 0.044, 0.032]),
    "storage-chest": ([0.884, 0.560, 0.123], [0.519, 0.330, 0.022]),
    "buffer-chest": ([0.207, 0.899, 0.270], [0.067, 0.550, 0.118]),
    "requester-chest": ([0.214, 0.609, 0.857], [0.074, 0.331, 0.463]),
}
for _name, (_lid, _panel) in _LC_PAINT.items():
    RECIPES[_name] = {"fbx": [_LC + "static.fbx"], "yaw": 0, "images": _LC_IMAGES, "tint": {"mat1": _lid},
                      "flat": {"mat4": [c * _LC_MEAN["mat4"] for c in _LC_BODY],
                               "mat5": [c * _LC_MEAN["mat5"] for c in _panel]}}

# --- Group: stone wall -------------------------------------------------------------------------
# FUE5 has one straight wall piece (a tapered panel with a buttress in its middle, on a plate);
# Zenith draws a piece per connection shape (model_library.gd WALL_SHAPES, Wube3DP's 21 files), so
# fue5_blender.py's `wall` cuts every shape from it: a hub with the buttress, an arm to each side the
# wall joins, the 2x2 gap's fill on -fill pieces. Height raised to Factorio's (Wube's walls, 1.32
# tiles, fitted to the sprites; FUE5's is 1.12). A lone pillar narrows to its top on a wider foot, as wall-single.png.
WALL_HEIGHT = 1.32 / 1.118


def _wall(arms, fill=False):
    hub = "ns" if arms and not set(arms) & set("ew") else "ew"
    return _static("stone-wall", match=False, scale=[1, 1, WALL_HEIGHT],
                   wall=dict({"arms": arms, "hub": hub, "fill": fill, "hub_half": 0.272,
                              "post": ["Cube", "Cube_1"], "plate": ["Cube_3"]},
                             **({} if arms else PYLON)))


PYLON = {"hub_half": 0.3, "taper": 0.15, "foot": 1.15}


for _shape in ("pylon", "n", "e", "s", "w", "ns", "ew", "ne", "nw", "es", "sw", "new", "nes", "esw", "nsw", "nesw"):
    RECIPES["stone-wall-" + _shape] = _wall("" if _shape == "pylon" else _shape)
for _shape in ("es", "nes", "esw", "nesw"):
    RECIPES["stone-wall-%s-fill" % _shape] = _wall(_shape, fill=True)
RECIPES["stone-wall"] = _wall("")


# Group: heat pipe. FUE5's one straight piece cut and bent into the 17 files of Zenith's heat pipe kit
# (named after Factorio's pictures, as nuclear.py's: the client picks one by its neighbours) by
# fue5_heat_pipe_blender.py. Its copper glows with FUE5's glow picture graded to Factorio's heated
# colours (heat_glow_picture), which the client lights only while the pipe is hot (anim.gd STATE_HEAT).
HEAT_PIPE_KIT = {"": "NS", "-straight-vertical-single": "", "-straight-vertical": "NS", "-straight-horizontal": "EW",
                 "-corner-up-right": "NE", "-corner-up-left": "NW", "-corner-down-right": "SE",
                 "-corner-down-left": "SW", "-t-up": "NEW", "-t-down": "SEW", "-t-left": "NSW", "-t-right": "NES",
                 "-cross": "NESW", "-ending-up": "N", "-ending-down": "S", "-ending-left": "W", "-ending-right": "E"}
RECIPES.update({"heat-pipe" + sfx: {"fbx": ["STRUCTURES/heat-pipe/static.fbx"], "kit": "heat-pipe", "conns": conns}
                for sfx, conns in HEAT_PIPE_KIT.items()})


# Rail signals (FUE5's are Factorio 2.0's design, at about half the sprite's size). Only the
# structure Factorio's rail-signal.png draws is kept: the cables and rail clamps (Factorio's
# separate metals layer, drawn towards whichever rail the signal guards) are dropped. FUE5 exported
# no material for the bodies, so they are painted in the colours of Zenith's own model (sampled
# from the sprite). Each lens becomes a dark lens in the body and a lit copy per colour
# (`anim_lit_*`, which anim.gd shows by the bridge's `st`), and the lamps sit where Zenith's own
# model has them, which the client's PLACEMENT_OFFSETS were fitted to.
STEEL, STEEL_LIGHT, STEEL_DARK = [0.254, 0.262, 0.270], [0.456, 0.462, 0.445], [0.068, 0.072, 0.078]
SIGNAL_RED, GLASS_AMBER = [0.254, 0.042, 0.023], [0.687, 0.181, 0.023]
LIT = {"anim_lit_green": [[0.107, 1.0, 0.068], [0.051, 1.0, 0.030]],
       "anim_lit_yellow": [[1.0, 0.434, 0.042], [1.0, 0.216, 0.0]],
       "anim_lit_red": [[1.0, 0.068, 0.042], [1.0, 0.0, 0.0]],
       "anim_lit_blue": [[0.254, 0.323, 1.0], [0.133, 0.133, 1.0]]}
RECIPES.update({
    "rail-signal": _static(
        "rail-signal", drop=["Cloner", "Null_4", "Null_1_5", "Sweep_7$", "Cube_4$"],
        paint={"default": STEEL, "Cube": STEEL_LIGHT, "Cube_2": STEEL_LIGHT, "Cube_3": STEEL_LIGHT,
               "Null_1": STEEL_DARK, "Null_1_2": STEEL_DARK, "Null_1_3": STEEL_DARK},
        lamps=[{"groups": ["Cylinder_3"], "off": [0.0137, 0.0423, 0.0116], "parts": {"anim_lit_green": LIT["anim_lit_green"]}},
               {"groups": ["Cylinder_2"], "off": [0.068, 0.047, 0.008], "parts": {"anim_lit_yellow": LIT["anim_lit_yellow"]}},
               {"groups": ["Cylinder"], "off": [0.068, 0.0103, 0.007], "parts": {"anim_lit_red": LIT["anim_lit_red"]}}],
        # Scaled to the sprite's 16 frames (fit_cells.py): about Zenith's own model's length and
        # width, four fifths of its height (0.37 tiles; FUE5's is 0.43 at half the width).
        match_to=[0.719, 1.193, 0.368], match_all=True,
        align={"groups": ["Cylinder", "Cylinder_2", "Cylinder_3"], "to": [0.18, -0.02]}),
    # FUE5's chain signal is Factorio 2.0's lantern (grid of glass cells, four colours) without the
    # red cabinet beside it that 2.0's sprite has: the cabinet, its base plate and cable are Zenith's
    # own (`borrow`), and the lantern at FUE5's own scale stands where Zenith's own model has it.
    "rail-chain-signal": _static(
        "rail-chain-signal", drop=["Cloner", "Null_4", "Null_1_2", "Sweep$", "Cube$"],
        paint={"default": SIGNAL_RED},
        lamps=[{"groups": ["Cube_4"], "off": GLASS_AMBER, "grow": 1.02, "parts": LIT}],
        match=False, align={"groups": ["Cube_4"], "to": [-0.19, -0.026]},
        borrow={"glb": "rail-chain-signal", "min_x": -0.01}),
})

# Group: pipe and pipe-to-ground. FUE5 has one straight pipe and one pipe-to-ground; Zenith draws a
# pipe as one of Factorio's 16 pictures by its connections (model_library.gd PIPE_SHAPES), so
# fue5_pipes_blender.py sweeps FUE5's straight pipe's body, flanges and bolts into each, and fits its
# pipe-to-ground's elbow to them (one model, which Zenith turns to each direction: model_library.gd
# single_model). No atlas: every piece wears the same FUE5 picture (pipe_job: not the watermarked one).
PIPE_SHAPES = ["straight-vertical-single", "ending-up", "ending-right", "corner-up-right", "ending-down",
               "straight-vertical", "corner-down-right", "t-right", "ending-left", "corner-up-left",
               "straight-horizontal", "t-up", "corner-down-left", "t-left", "t-down", "cross"]
for _n in ["pipe", "pipe-to-ground"] + ["pipe-" + _s for _s in PIPE_SHAPES]:
    RECIPES[_n] = {"fbx": ["STRUCTURES/pipes/" + ("pipe-to-ground.fbx" if _n == "pipe-to-ground" else "pipe-I.fbx")],
                   "kit": "pipes"}

# --- Group: construction robot and logistic robot ----------------------------------------------
# Robots fly in robot_swarm.gd, one MultiMesh per kind and part, moved by the robot shader: the logistic
# robot's legs are `anim_thrusters` (swung back and their red tips lit while it flies), its antenna's
# bulb the cargo (red) and empty (white) lamps; the construction robot's claws are `anim_arms`
# (reaching forward while it works) and its red light `anim_lamp_nozzle`. FUE5 models them centred
# in the air, their fronts east: turned to face north, grounded (movers.gd flies them), and kept far
# under the budget (robots come by the thousand). Sized by their silhouettes against the sprites'
# north, east, south and west frames: best at x1.12 and x1.16 of FUE5's own, the construction robot
# upright (leaned 22 degrees as ours is, it scored 0.65 against 0.76). FUE5's fan stays still:
# Factorio's sprite has one frame a direction.
# Several of their pictures carry stock-photo watermarks (Adobe Stock, dreamstime) or are someone else's
# photo (the logistic robot's mat4, a coin's lettering): none of those ships. Their materials are painted
# flat (`flat`) in colours of Factorio's robot sprites (k-means over their opaque pixels), the baked
# occlusion shading them; only the unmarked pictures (the construction robot's mat2 and mat4, the
# logistic robot's mat5) are baked into the atlas.


def _srgb(r, g, b):
    """A sprite's sRGB 0-255 colour in linear light, as `flat` takes it."""
    return [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in (r / 255.0, g / 255.0, b / 255.0)]


RECIPES.update({
    "logistic-robot": {"fbx": ["VEHICLES/logistic-robot/static.fbx"], "yaw": 270, "match": False, "ground": True,
                       "scale": [1.12, 1.12, 1.12], "centre": "bbox",
                       "budget": 1200, "anim": {"anim_thrusters": ["Cloner"]}, "pivot": {"anim_thrusters": "axis_top"},
                       "lamp_parts": {"anim_lamp_cargo": {"objects": ["Sphere"], "color": [1.0, 0.08, 0.04]},
                                      "anim_lamp_empty": {"objects": ["Sphere"], "color": [1.0, 1.0, 1.0]}},
                       "glow_mats": {"mat5": [1.0, 0.23, 0.1, 1.2]},
                       # shell and legs, the antenna and core, the cross bands, the top cap
                       "flat": {"mat1": _srgb(131, 121, 106), "mat2": _srgb(58, 40, 33), "mat3": _srgb(220, 214, 200),
                                "mat4": _srgb(89, 83, 70)}},
    "construction-robot": {"fbx": ["VEHICLES/construction-robot/static.fbx"], "yaw": 270, "match": False,
                           "ground": True, "scale": [1.16, 1.16, 1.16], "centre": "bbox", "budget": 1200,
                           "anim": {"anim_arms": ["arm", "claw", "Cube", "Cube_1"]}, "pivot": {"anim_arms": "axis_top"},
                           "lamp_parts": {"anim_lamp_nozzle": {"objects": ["Sphere"], "color": [1.0, 0.08, 0.04]}},
                           # the cream body and arms, the dark rings round it
                           "flat": {"mat1": _srgb(188, 170, 138), "mat3": _srgb(94, 83, 67)}},
})

# --- Group: inserters -------------------------------------------------------------------------
# FUE5's inserter: the platform (static.fbx) and its skinned arm (animated1.fbx: bones arm1, arm2
# and socket_target at the wrist). The arm stays a rig the client drives (fue5_blender.py `rig`,
# client/scripts/world/model_rig.gd): its two fingers become the pincers, and it stands folded over
# the platform at rest, so the file keeps to its tile. Turned half round so its one back leg points
# north, as Wube's inserter and Factorio's platform. Only the north file: the client turns it
# (model_library.gd single_model). The long-handed inserter's arm is 1.6 times as long (Wube's long
# arm pieces are 1.45 and 1.6 times its basic ones), its hand as the others'.
# Colours: FUE5's paint, steel and plate pictures (inserter_mat1, mat3, mat4) carry a stock photo's
# watermark, so none of them is used (only mat2, its small plain red lamp): every material is flat,
# from Factorio's sprites, the baked occlusion shading it. The paint (mat1: the platform's legs, and
# the arm's mat1.001) is each tier's arm paint as inserter_arms.gd ARM_TINTS has it (the hand's, from
# <name>-hand-open.png), the stack inserter's grey platform its platform sprite's median (x1.3 for its
# light); the steel (mat3) and the plate round the turntable (mat4) the inserter platform sprite's
# grey and beige pixels' medians. All in linear light.
_INS = "STRUCTURES/inserter/"
_INS_RIG = {"lower": "arm1", "upper": "arm2", "wrist": "socket_target", "fold": [95, -80], "budget": 520}
_INS_STEEL = [0.468, 0.366, 0.279]
_INS_PLATE = [0.456, 0.266, 0.138]
_INS_PAINT = {  # prototype: (platform paint, arm paint)
    "inserter": ([0.597, 0.162, 0.0], [0.597, 0.162, 0.0]),
    "burner-inserter": ([0.109, 0.06, 0.044], [0.109, 0.06, 0.044]),
    "long-handed-inserter": ([0.644, 0.056, 0.014], [0.644, 0.056, 0.014]),
    "fast-inserter": ([0.091, 0.22, 0.503], [0.091, 0.22, 0.503]),
    "bulk-inserter": ([0.122, 0.242, 0.021], [0.122, 0.242, 0.021]),
    "stack-inserter": ([0.281, 0.213, 0.16], [0.515, 0.275, 0.0]),
}
for _name, (_plat, _arm) in _INS_PAINT.items():
    RECIPES[_name] = {"fbx": [_INS + "static.fbx", _INS + "animated1.fbx"], "yaw": 180, "match": False,
                      "budget": 1500,
                      "rig": dict(_INS_RIG, stretch=1.6 if _name == "long-handed-inserter" else 1.0),
                      "flat": {"mat1": _plat, "mat1.001": _arm, "mat3": _INS_STEEL, "mat3.001": _INS_STEEL,
                               "mat4": _INS_PLATE}}

# --- Group: transport belts, all four tiers -----------------------------------------------------
# FUE5 has the yellow belt only: a slab (belt-I.fbx) and its curve (belt-L.fbx), the top a picture of
# Factorio's chevron-shaped slats, four a tile with a yellow chevron on each, the sides a steel frame
# picture. fue5_belt_blender.py keeps the top as its own scrolling surface (`fue5_belt_surface`, FUE5's
# UVs) instead of an atlas. Each tier's surface is FUE5's picture recoloured (_belt_surface): the
# chevrons take the tier's paint (model_library.gd BELT_CHEVRONS, the median of each tier's own
# sheet) and, as Factorio's sheets space them, stay on every other slat for yellow (one each half
# tile) and on one slat a tile for the faster tiers, the rest painted as plain slats. Factorio's turbo
# belt has one every second tile; one picture a tile can't, so it has one a tile as fast and express.
# The frame stays FUE5's steel on every tier (STEEL_FRAMES). FUE5 has no line-end pieces: short noses
# of the frame are made for -start and -end. FUE5's own Unreal animation (media/normal/, 10 frames of
# the slats moving, three slats a frame) isn't used: the client scrolls the one picture.
BELTS = "STRUCTURES/belts/"
BELT_TIERS = {"": (0.929, 0.675, 0.016), "fast-": (0.886, 0.078, 0.0), "express-": (0.0, 0.643, 0.867),
              "turbo-": (0.569, 0.769, 0.180)}  # sRGB, BELT_CHEVRONS
# The picture's slats keeping a chevron, by the chevron's middle column (of 665: one every 166.25).
BELT_KEEP = {"": (185, 517), "fast-": (185,), "express-": (185,), "turbo-": (185,)}
BELT_PIECES = {"": ("straight", "belt-I.fbx"), "-curve-left": ("curve-left", "belt-L.fbx"),
               "-curve-right": ("curve-right", "belt-L.fbx"), "-start": ("start", None), "-end": ("end", None)}
BELT_RUBBER = (1.26, 0.94, 0.85)  # the sprite's slat hue over its luminance (Rec. 601 weights)
BELT_NOSE = [0.07, 0.228]  # tiles past the tile edge, and the slab's height
for _tier in BELT_TIERS:
    for _sfx, (_piece, _fbx) in BELT_PIECES.items():
        RECIPES[_tier + "transport-belt" + _sfx] = {"fbx": [BELTS + _fbx] if _fbx else [], "belt": _piece,
                                                     "tier": _tier, "spec": "transport-belt"}


def _belt_surface(tier, out):
    """FUE5's slat picture with the tier's chevrons (BELT_TIERS, BELT_KEEP), written to `out`."""
    import numpy as np
    from PIL import Image
    a = np.asarray(Image.open(os.path.join(RAW, *(BELTS + "belt-I_mat1_diffuse1.jpg").split("/"))).convert("RGB"),
                   dtype=np.float64) / 255.0
    mx, mn = a.max(-1), a.min(-1)
    sat = (mx - mn) / np.maximum(mx, 1e-3)
    lum = a @ np.array([0.299, 0.587, 0.114])
    paint = (sat > 0.45) & (a[..., 0] > 0.3) & (a[..., 2] < a[..., 1])
    # How much of a pixel is chevron: all of it on the paint, fading over its anti-aliased rim.
    w = np.clip((sat - 0.2) / 0.3, 0.0, 1.0) * (a[..., 2] < a[..., 1])
    shade = (lum / lum[paint].mean())[..., None]  # the paint's own light and wear, 1 on average
    grey = a[(sat < 0.15) & (mx > 0.2)].mean(0)  # the slats' grey
    cols = np.arange(a.shape[1])
    period = a.shape[1] / 4.0
    keep = np.zeros(a.shape[1], bool)
    for c in BELT_KEEP[tier]:
        keep |= np.abs((cols - c + period / 2) % a.shape[1] - period / 2) < period / 2
    new = np.where(keep[None, :, None], np.array(BELT_TIERS[tier]) * shade, grey * shade)
    rgb = a * (1.0 - w[..., None]) + new * w[..., None]
    # FUE5's slats are a neutral grey, Factorio's a brownish rubber: their hue taken from the sprite's
    # slats (frame 0 of transport-belt.png going north, linear mean 0.131, 0.098, 0.088), FUE5's
    # brightness kept.
    lin = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    paint_w = (w * keep[None, :])[..., None]  # the chevrons kept; the rest is rubber
    lin = lin * (1.0 - paint_w) * BELT_RUBBER + lin * paint_w
    rgb = np.where(lin <= 0.0031308, lin * 12.92, 1.055 * np.maximum(lin, 0) ** (1 / 2.4) - 0.055)
    Image.fromarray((np.clip(rgb, 0, 1) * 255 + 0.5).astype(np.uint8)).save(out, quality=92)


# --- Group: splitters, all four tiers -----------------------------------------------------------
# FUE5's splitter (STRUCTURES/splitter/static.fbx) is the structure alone: four flat gears with oval plates
# on them, the two yellow chevron plates (mat1), the rack and its cable; in Unreal it stood over belts of
# its own. Its chevrons face north as splitter-north.png's, but its cable trails off the west end where the
# sprite's coils at the east: mirrored east-west (fue5_splitter_blender.py `mirror`). It goes over two of FUE5's
# straight belt pieces of the same tier, one under each half (fue5_splitter_blender.py): their surface is
# the belts' own (`fue5_belt_surface`, _belt_surface's tier picture) and scrolls as a belt's does, so a
# splitter's halves run as the belts beside them. The four gears turn (`anim_spin_gear*`, about their
# middles; the outer two are one mirrored mesh in FUE5, cut by side), their oval plates stay still. Each
# tier's chevron plates are FUE5's yellow picture's light and wear (its luminance over its mean) times that
# tier's paint, the median of the saturated pixels of frame 0 of <tier>splitter-north.png (sRGB); the steel
# (mat2) and the plates' blue steel (mat3) are FUE5's on every tier, as Factorio's sprites keep them.
SPLITTER = "STRUCTURES/splitter/"
SPLITTER_PAINT = {"": (230, 177, 80), "fast-": (220, 73, 64), "express-": (92, 176, 211), "turbo-": (166, 187, 80)}
SPLITTER_HALVES = [-0.5, 0.5]  # the belts' centres, tiles east of the middle
for _tier in SPLITTER_PAINT:
    RECIPES[_tier + "splitter"] = {
        "fbx": [SPLITTER + "static.fbx"], "yaw": 0, "spec": "splitter", "splitter": _tier, "mirror": True,
        # Its outer gears' teeth stood 0.1 tile past the footprint each side and its chevron plates 0.08 past
        # its north edge: narrowed to 0.915, fitted into the footprint (x0.884), then our splitter's width and
        # depth (1.985 x 1.0) at FUE5's own height (0.55 tiles; stretched to ours, 0.765, it scored lower
        # against the sprite: 0.730 / 0.812 against 0.762 / 0.826, min / mean overlap).
        "scale": [0.915, 1.0, 1.0], "match_to": [1.985, 1.0, 0.55],
        # The outer gears' inner toothed rings (4,864 triangles, a quarter of the model) lie under their
        # oval plates and outer rings, and the cable's 40 ribs (960) are a corrugation a few pixels wide
        # over its hose: left out. The rest within the budget (less the two belts' 24 triangles): flat
        # faces merged, then collapsed together (fue5_blender.py `planar`, `together`).
        "drop": ["Null_1_7", "Cloner$"], "planar": 5, "together": True, "budget": 2976,
        "anim": {"anim_spin_gear": ["Cylinder_2", "Cloner_2", "Null_1_3", "Null_5_2"],
                 "anim_spin_gear.001": ["Cylinder_3", "Cloner_3", "Null_1_5", "Null_6_3"]},
        "side_parts": {"anim_spin_gear.002": [["Cylinder_5", "Cloner_5", "Null_1_7", "Null_7_4"], 1],
                       "anim_spin_gear.003": [["Cylinder_5", "Cloner_5", "Null_1_7", "Null_7_4"], -1]},
        "pivot": {"anim_spin_gear": "bbox", "anim_spin_gear.001": "bbox", "anim_spin_gear.002": "bbox",
                  "anim_spin_gear.003": "bbox"}}


def _splitter_paint(tier, out):
    """FUE5's yellow plate picture in the tier's paint (SPLITTER_PAINT), written to `out`."""
    import numpy as np
    from PIL import Image
    a = np.asarray(Image.open(os.path.join(RAW, *(SPLITTER + "splitter_mat1_diffuse1.jpg").split("/"))).convert("RGB"),
                   dtype=np.float64) / 255.0
    lum = a @ np.array([0.299, 0.587, 0.114])
    shade = (lum / lum.mean())[..., None]
    rgb = np.array(SPLITTER_PAINT[tier]) / 255.0 * shade
    Image.fromarray((np.clip(rgb, 0, 1) * 255 + 0.5).astype(np.uint8)).save(out, quality=92)

# --- Group: underground belts, all four tiers ----------------------------------------------------
# FUE5 has the yellow underground only (STRUCTURES/underground-belt/static.fbx): a quarter-round hood, its
# mouth as tall as the hood, two bolted rims and a cheek each side, no belt. fue5_underground_blender.py
# turns its mouth to the south (Zenith's entrance faces north, items coming in from the south), lays FUE5's
# own belt slab under it with the tier's scrolling surface (the belts' _belt_surface), and writes one file
# that is both ends: the exit is the entrance turned round in the world (model_library.gd turn_dir), its
# belt scrolled backwards (_setup_belt), so -input and -output are the same model.
# The hood's yellow picture with its grey chevrons (ubelt1_mat1_diffuse1.jpg) and its shine
# (ubelt1_mat1_specular1.jpg) carry a stamped "ALCOA ALUMINUM ... TRADE MARK" logo, a company's trademark
# in the photo: neither ships. The chevrons are drawn afresh (_underground_paint) from FUE5's clean normal
# map of the same cover (its stripes' edges are its relief), in each tier's paint and stripe grey from the
# tier's own structure sprite (frame 0's saturated and grey pixels, medians, sRGB), worn by FUE5's clean
# plain steel picture (mat2). The rims (mat2, mat3) take the sprite's rusty rim hue (its median 117, 95, 85
# over its grey), their brightness kept; the cheeks keep FUE5's darker steel (mat4).
# Sized by fit.py's silhouette overlap against the structure sprite's four directions (a grid search over
# the hood's width, length, height and place, the belt slab fixed): 0.99 across, 0.92 long and 0.49 tall
# (FUE5's is 1.12 x 1.02 x 0.76; Wube's printable one 0.99 x 0.90 x 0.56), standing 0.07 tiles north of the
# middle, its mouth 0.11 in from the tile's open edge, its back 0.03 past the far one (check.py's overhang),
# as Factorio's structure sits at the back of its tile. The belt is FUE5's 0.228-tile slab (0.45 either
# side, between the cheeks) from the open edge, which Zenith's -start/-end noses join.
UG = "STRUCTURES/underground-belt/"
UG_TIERS = {  # tier: (hood paint, chevron grey), sRGB, from <tier>-underground-belt-structure.png
    "": ((186, 146, 74), (117, 118, 116)), "fast-": ((179, 60, 56), (118, 117, 117)),
    "express-": ((94, 168, 206), (114, 114, 114)), "turbo-": ((136, 149, 70), (132, 119, 122))}
UG_RIM = (117, 95, 85)
UG_SCALE = [0.885, 0.846, 0.629]
UG_HOOD_NORTH = 0.07
UG_SLAB_END = 0.25
for _tier in UG_TIERS:
    for _end in ("-input", "-output"):
        RECIPES[_tier + "underground-belt" + _end] = {"fbx": [UG + "static.fbx"], "underground": _tier,
                                                       "spec": "underground-belt" + _end}


def _lin(c):
    import numpy as np
    c = np.asarray(c, dtype=np.float64)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def _srgb_of(lin):
    import numpy as np
    return np.where(lin <= 0.0031308, lin * 12.92, 1.055 * np.maximum(lin, 0) ** (1 / 2.4) - 0.055)


def _underground_paint(tier, out):
    """The hood's cover: the tier's paint with grey chevrons where FUE5's normal map has its stripes."""
    import numpy as np
    from PIL import Image, ImageFilter
    raw = os.path.join(RAW, *UG.split("/"))
    g = np.asarray(Image.open(os.path.join(raw, "ubelt1_mat1_normal1.jpg")).convert("RGB"), dtype=np.float64)[..., 1]
    # A stripe's upper edge leans its normal one way (green low), its lower edge the other (green high):
    # down each column, inside a stripe from the one to the other, wrapping round (the picture tiles).
    up, down = g < 90, g > 165
    stripe = np.zeros(g.shape, bool)
    for x in range(g.shape[1]):
        ups, downs = np.nonzero(up[:, x])[0], np.nonzero(down[:, x])[0]
        inside = bool(ups.size) and (not downs.size or ups[-1] > downs[-1])
        for y in range(g.shape[0]):
            if up[y, x]:
                inside = True
            elif down[y, x]:
                inside = False
            stripe[y, x] = inside
    w = np.asarray(Image.fromarray((stripe * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.2)),
                   dtype=np.float64)[..., None] / 255.0
    steel = np.asarray(Image.open(os.path.join(raw, "ubelt1_mat2_diffuse1.jpg")).convert("L").resize(g.shape[::-1]),
                       dtype=np.float64)
    shade = (0.75 + 0.25 * steel / steel.mean())[..., None]  # FUE5's wear, 1 on average
    paint, grey = (_lin(np.array(c) / 255.0) for c in UG_TIERS[tier])
    lin = (paint * (1.0 - w) + grey * w) * shade
    Image.fromarray((np.clip(_srgb_of(lin), 0, 1) * 255 + 0.5).astype(np.uint8)).save(out, quality=92)


def _underground_pictures(tmp):
    """FUE5's clean steel pictures for the hood: the rims' two rusted to the sprite's hue, at 512."""
    import numpy as np
    from PIL import Image
    raw = os.path.join(RAW, *UG.split("/"))
    rim = _lin(np.array(UG_RIM) / 255.0)
    hue = rim / rim.mean()
    out = {}
    for key, f, rust in (("steel", "ubelt1_mat2_diffuse1.jpg", True), ("rim", "ubelt1_mat3_diffuse1.jpg", True),
                         ("side", "ubelt1_mat4_diffuse1.jpg", False)):
        im = Image.open(os.path.join(raw, f)).convert("RGB")
        im = im.resize((min(im.width, 512), min(im.height, 512)))
        if rust:
            lin = _lin(np.asarray(im, dtype=np.float64) / 255.0) * hue
            im = Image.fromarray((np.clip(_srgb_of(lin), 0, 1) * 255 + 0.5).astype(np.uint8))
        out[key] = os.path.join(tmp, key + ".jpg")
        im.save(out[key], quality=92)
    return out


def _underground_job(recipe, out, tmp):
    paint = os.path.join(tmp, "paint.jpg")
    _underground_paint(recipe["underground"], paint)
    surface = os.path.join(tmp, "surface.jpg")
    _belt_surface(recipe["underground"], surface)
    spec = specs.SPECS.get(recipe["spec"], {})
    return {"fbx": os.path.join(RAW, *recipe["fbx"][0].split("/")), "belt_fbx": os.path.join(RAW, *(BELTS + "belt-I.fbx").split("/")),
            "out": out, "paint": paint, "pictures": _underground_pictures(tmp), "surface": surface,
            "frame": os.path.join(RAW, *(BELTS + "belt-I_mat2_diffuse1.jpg").split("/")),
            "scale": UG_SCALE, "slab_end": UG_SLAB_END, "slab_half": 0.45, "hood_north": UG_HOOD_NORTH, "inner": [0.012, 0.011, 0.010],
            "budget": spec.get("budget", 1500)}


# FUE5 models the owner keeps ours for: never converted, even when named.
EXCLUDED = {
    # FUE5's assembler is the green tier 1 (STRUCTURES/assembling-machine): ours, Wube's print with
    # its moving gears, stays.
    "assembling-machine-1": "owner: Zenith's own model",
}


def our_size(name):
    """Our model's size (east-west, north-south, height in tiles), which FUE5's is matched to, or
    None without one."""
    path = packs.model_path(name)
    if not os.path.exists(path):
        return None
    import trimesh
    lo, hi = trimesh.load(path, force="scene").bounds
    d = hi - lo
    return [float(d[0]), float(d[2]), float(d[1])]


def job_for(name, recipe, out, yaw=None):
    spec = specs.SPECS.get(name) or specs.SPECS.get(recipe.get("spec", name), {})
    size = spec.get("size", (3, 3))
    return {
        "fbx": [os.path.join(RAW, *p.split("/")) for p in recipe["fbx"]],
        "out": out,
        "yaw": recipe.get("yaw", 0) if yaw is None else yaw,
        "budget": recipe.get("budget", spec.get("budget", 10000)),
        "tex": recipe.get("tex", 2048 if max(size) >= 3 else 1024 if max(size) == 2 else 512),
        "drop": recipe.get("drop", []),
        "anim": recipe.get("anim", {}),
        "bones": recipe.get("bones", {}),
        "file_parts": recipe.get("file_parts", {}),
        "fit": recipe.get("fit"),
        "overhang": spec.get("overhang", 0.0),
        "hatch": recipe.get("hatch"),
        "pit": recipe.get("pit"),
        "match": (None if not recipe.get("match", True) else recipe["match_to"] if "match_to" in recipe else
                  _facing_size(*recipe["match_turns"]) if "match_turns" in recipe else our_size(name)),
        "match_all": recipe.get("match_all", False),
        "place": recipe.get("place", []),
        "pivot": recipe.get("pivot", {}),
        "centre": recipe.get("centre"),
        "shift": recipe.get("shift", [0, 0, 0]),
        "scale": recipe.get("scale", [1, 1, 1]),
        "name": "fue5_" + name,
        "size": list(size),
        "sink": spec.get("sink", 0.0),
        "images": {m: os.path.join(RAW, *f.split("/")) for m, f in recipe.get("images", {}).items()},
        "tint": recipe.get("tint", {}),
        "wall": recipe.get("wall"),
        "paint": recipe.get("paint"),
        "lamps": recipe.get("lamps", []),
        "align": recipe.get("align"),
        "borrow": dict(recipe["borrow"], glb=os.path.join(packs.PLACEHOLDERS_DIR, recipe["borrow"]["glb"] + ".glb"))
        if recipe.get("borrow") else None,
        "ground": recipe.get("ground", False),
        "lamp_parts": recipe.get("lamp_parts", {}),
        "glow_mats": recipe.get("glow_mats", {}),
        "rig": recipe.get("rig"),
        "flat": recipe.get("flat", {}),
        "side_parts": recipe.get("side_parts", {}),
        "planar": recipe.get("planar"),
        "together": recipe.get("together", False),
    }


def pipe_job(name, out):
    # FUE5's pipe picture (pipe-I_mat1_diffuse1.jpg, and its metallic map) carries a stock photo's
    # watermark ("dreamstime"), so it isn't FUE5's own to pass on: the pipes wear FUE5's other pipe
    # picture, its window's plain metal (mat2, unmarked), its even right-hand middle (the left is darker,
    # the edges a dark frame) stretched over every piece.
    pipes = os.path.join(RAW, "STRUCTURES", "pipes")
    return {"out": out, "shape": name, "pipe_fbx": os.path.join(pipes, "pipe-I.fbx"),
            "ptg_fbx": os.path.join(pipes, "pipe-to-ground.fbx"),
            "texture": os.path.join(pipes, "pipe-I_mat2_diffuse1.jpg"), "uv_box": [0.4, 0.15, 0.9, 0.85]}


def heat_glow_picture(src, out):
    """FUE5's heat pipe glow picture (a dim red floor with a brighter stripe along the pipes' tops)
    graded to Factorio's heated heat pipe (heated-*.png): orange at its floor, the pale yellow of the
    pictures' hottest middle at its stripe."""
    import numpy as np
    from PIL import Image
    e = np.asarray(Image.open(src).convert("RGB")).astype(float)
    lum = e @ np.array([0.3, 0.55, 0.15])
    t = np.clip((lum - np.percentile(lum, 20)) / max(1e-3, lum.max() - np.percentile(lum, 20)), 0, 1)[..., None]
    edge, hot = np.array([214.0, 92.0, 34.0]), np.array([246.0, 204.0, 150.0])
    Image.fromarray((edge * 0.55 * (1 - t) + hot * t).clip(0, 255).astype(np.uint8)).save(out, quality=92)


def kit_job(name, recipe, out):
    if recipe["kit"] == "pipes":
        return pipe_job(name, out)
    fbx = os.path.join(RAW, *recipe["fbx"][0].split("/"))
    glow = os.path.join(tempfile.gettempdir(), "fue5_heat_pipe_glow.jpg")
    heat_glow_picture(os.path.join(os.path.dirname(fbx), "heat-pipe_mat1_emission1.jpg"), glow)
    return {"fbx": fbx, "out": out, "conns": recipe["conns"], "emission": glow, "textures": os.path.dirname(fbx)}


def _belt_job(recipe, out, tmp):
    """fue5_belt_blender.py's job for a belt piece, its tier's surface picture written into `tmp`."""
    surface = os.path.join(tmp, "surface.jpg")
    _belt_surface(recipe["tier"], surface)
    return {"fbx": os.path.join(RAW, *recipe["fbx"][0].split("/")) if recipe["fbx"] else None, "out": out,
            "piece": recipe["belt"], "surface": surface, "nose": BELT_NOSE,
            "frame": os.path.join(RAW, *(BELTS + "belt-I_mat2_diffuse1.jpg").split("/"))}


def build(name, out_dir, yaw=None):
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, name + ".glb")
    recipe = RECIPES[name]
    if "splitter" in recipe:
        run = _build_splitter(name, recipe, out, yaw)
    elif "belt" in recipe or "underground" in recipe:
        tmp = tempfile.mkdtemp()
        jf = os.path.join(tmp, "job.json")
        with open(jf, "w") as f:
            json.dump(_belt_job(recipe, out, tmp) if "belt" in recipe else _underground_job(recipe, out, tmp), f)
        script = "fue5_belt_blender.py" if "belt" in recipe else "fue5_underground_blender.py"
        # A Blender script error still exits 0 and could leave an older file to be baked: none is left.
        if os.path.exists(out):
            os.remove(out)
        run = subprocess.run([BLENDER, "--background", "--factory-startup", "--python",
                              os.path.join(HERE, script), "--", jf], capture_output=True, text=True)
        if "Traceback" in run.stderr + run.stdout:
            print(run.stdout[-3000:], run.stderr[-3000:])
            raise SystemExit("%s: Blender script error" % name)
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)
    else:
        run = _build_blender(name, recipe, out, yaw)
    for line in run.stdout.splitlines():
        if line.startswith("FUE5") or "Error" in line:
            print(" ", line)
    if run.returncode != 0 or not os.path.exists(out):
        print(run.stdout[-3000:], run.stderr[-3000:])
        raise SystemExit("%s: Blender failed" % name)
    # Ambient occlusion per vertex (COLOR_0 alpha), which FUE5's textures don't carry: the client
    # darkens corners and gaps by it as it does our own models (bake_glb.py).
    import bake_glb
    tris, mean = bake_glb.bake_file(out)
    print("  occlusion baked: %d triangles, mean %.2f" % (tris, mean))
    return out


def _build_blender(name, recipe, out, yaw):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(kit_job(name, recipe, out) if "kit" in recipe else job_for(name, recipe, out, yaw), f)
    script = "fue5_%s_blender.py" % recipe["kit"].replace("-", "_") if "kit" in recipe else "fue5_blender.py"
    run = subprocess.run([BLENDER, "--background", "--factory-startup", "--python",
                          os.path.join(HERE, script), "--", f.name],
                         capture_output=True, text=True)
    os.unlink(f.name)
    return run


def _build_splitter(name, recipe, out, yaw):
    """A splitter: its body (fue5_blender.py, the chevron plates in the tier's paint), the tier's straight
    belt (fue5_belt_blender.py), joined by fue5_splitter_blender.py. Each step's file is checked, since
    Blender exits 0 after a script error."""
    import shutil
    tmp = tempfile.mkdtemp()
    if os.path.exists(out):
        os.remove(out)
    try:
        paint = os.path.join(tmp, "paint.jpg")
        _splitter_paint(recipe["splitter"], paint)
        body = os.path.join(tmp, "body.glb")
        job = job_for(name, recipe, body, yaw)
        job["images"] = {"mat1": paint}
        if recipe.get("match", True) and "match_to" not in recipe:  # every tier to our (yellow) splitter's size
            job["match"] = our_size("splitter")
        jf = os.path.join(tmp, "body.json")
        with open(jf, "w") as f:
            json.dump(job, f)
        runs = [subprocess.run([BLENDER, "--background", "--factory-startup", "--python",
                                os.path.join(HERE, "fue5_blender.py"), "--", jf], capture_output=True, text=True)]
        belt = os.path.join(tmp, "belt.glb")
        bjob = _belt_job({"fbx": [BELTS + "belt-I.fbx"], "belt": "straight", "tier": recipe["splitter"]}, belt, tmp)
        jf = os.path.join(tmp, "belt.json")
        with open(jf, "w") as f:
            json.dump(bjob, f)
        runs.append(subprocess.run([BLENDER, "--background", "--factory-startup", "--python",
                                    os.path.join(HERE, "fue5_belt_blender.py"), "--", jf], capture_output=True, text=True))
        for step, path in (("body", body), ("belt", belt)):
            if not os.path.exists(path):
                print(runs[-1 if step == "belt" else 0].stdout[-3000:], runs[-1 if step == "belt" else 0].stderr[-3000:])
                raise SystemExit("%s: Blender failed making its %s" % (name, step))
        jf = os.path.join(tmp, "join.json")
        with open(jf, "w") as f:
            json.dump({"body": body, "belt": belt, "out": out, "halves": SPLITTER_HALVES,
                       "mirror": recipe.get("mirror", False)}, f)
        run = subprocess.run([BLENDER, "--background", "--factory-startup", "--python",
                              os.path.join(HERE, "fue5_splitter_blender.py"), "--", jf], capture_output=True, text=True)
        run.stdout = "\n".join(r.stdout for r in runs) + "\n" + run.stdout
        return run
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def score(name, glb, raw, turns=(0,)):
    """fit.py's overlap per direction, with the model turned by each of `turns` quarter turns."""
    import numpy as np
    import fit
    jobs, (v, faces) = fit.prepare(name, raw, glb)
    out = {}
    for q in turns:
        a = math.radians(90 * q)
        c, s = math.cos(a), math.sin(a)
        # Clockwise from above in glTF (x east, z south).
        vt = v.copy()
        vt[:, 0], vt[:, 2] = c * v[:, 0] - s * v[:, 2], s * v[:, 0] + c * v[:, 2]
        res = {}
        for dn, opts, mask, centre, ppt, own in jobs:
            m = fit.model_mask(vt, faces, opts, mask.shape, centre, ppt)
            res[dn] = (mask & m).sum() / max(1, (mask | m).sum())
        out[q * 90] = res
    return out, len(faces)


def render(name, glb, raw, out_dir):
    """compare.py's sprite | model | overlay for ours (top, from our packs) and FUE5's (below), per
    direction."""
    import score_proto
    from PIL import Image
    os.makedirs(out_dir, exist_ok=True)
    for dn, args in score_proto.jobs_for(name, raw):
        rows = []
        for who, path in (("ours", packs.model_path(score_proto.model_of(name, dn))), ("fue5", glb)):
            png = os.path.join(out_dir, "%s-%s-%s.png" % (name, dn, who))
            cmd = [BLENDER, "--background", "--factory-startup", "--python", os.path.join(HERE, "compare.py"), "--",
                   png, name, "--glb=" + path] + score_proto.camera_args(name) + args
            if who == "fue5":
                cmd.append("--palette=1")
            subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
            if os.path.exists(png):
                rows.append(Image.open(png).convert("RGB"))
        if rows:
            w = max(r.width for r in rows)
            sheet = Image.new("RGB", (w, sum(r.height for r in rows)), (30, 30, 30))
            y = 0
            for r in rows:
                sheet.paste(r, (0, y))
                y += r.height
            sheet.save(os.path.join(out_dir, "%s-%s.png" % (name, dn)))


def fix_imports(out_dir=OUT_DIR):
    """After `godot --import`: Godot's glTF importer extracts embedded pictures as files beside the
    model by default; the client reads the .glb itself, so they are kept embedded instead."""
    for f in sorted(os.listdir(out_dir)):
        path = os.path.join(out_dir, f)
        if f.endswith(".glb.import"):
            text = open(path, encoding="utf-8").read()
            if "gltf/embedded_image_handling=1" in text:
                open(path, "w", encoding="utf-8", newline="\n").write(
                    text.replace("gltf/embedded_image_handling=1", "gltf/embedded_image_handling=3"))
                print("embedded:", f)
        elif "_atlas." in f or (f.startswith(("heat-pipe", "pipe")) and ".jpg" in f) or (
                f.lower().endswith((".jpg", ".png", ".jpg.import", ".png.import"))
                and "_" in f and os.path.exists(os.path.join(out_dir, f.split("_")[0] + ".glb"))):
            # A picture the importer extracted (`<model>_<image>`): the atlas, a belt's surface and
            # frame; the pipe kits' own pictures.
            os.remove(path)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("names", nargs="*")
    ap.add_argument("--out", default=OUT_DIR)
    ap.add_argument("--yaw", type=float)
    ap.add_argument("--score", action="store_true")
    ap.add_argument("--turns", action="store_true", help="score every quarter turn")
    ap.add_argument("--glb-dir", default=OUT_DIR)
    ap.add_argument("--dump", default=os.path.join(ART, "..", "anim-vehicles", "data-raw-dump.json"))
    ap.add_argument("--render", help="side-by-side pictures into this folder (git-ignored places only)")
    ap.add_argument("--fix-imports", action="store_true", help="after godot --import: keep pictures embedded")
    a = ap.parse_args(argv)
    names = [n for n in (a.names or list(RECIPES)) if n not in EXCLUDED]
    for n in a.names:
        if n in EXCLUDED:
            print("%s: not converted (%s)" % (n, EXCLUDED[n]))
    if a.fix_imports:
        fix_imports()
        return 0
    if a.render:
        raw = json.load(open(a.dump, encoding="utf-8"))
        for n in names:
            render(n, os.path.join(a.glb_dir, n + ".glb"), raw, a.render)
        return 0
    if a.score:
        raw = json.load(open(a.dump, encoding="utf-8"))
        for n in names:
            # Ours are in two packs (placeholders, wube3dp), FUE5's in --glb-dir.
            for who, p in (("ours", packs.model_path(n)), ("fue5", os.path.join(a.glb_dir, n + ".glb"))):
                if not os.path.exists(p):
                    continue
                r, tri = score(n, p, raw, range(4) if (a.turns and who == "fue5") else (0,))
                for yaw, res in r.items():
                    vals = list(res.values())
                    print("%-22s %-4s yaw %3d  min %.3f mean %.3f  tris %6d  %s" % (
                        n, who, yaw, min(vals), sum(vals) / len(vals), tri,
                        " ".join("%s %.2f" % kv for kv in res.items())))
        return 0
    for n in names:
        print(n)
        build(n, a.out, a.yaw)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
