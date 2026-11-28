"""Logistics and mid-game machines: roboport, logistic and construction robots, electric furnace,
beacon, assembling machines 2 and 3, and the crude oil patch.

Each model is matched to Factorio's HR sprite with compare.py (see client/assets/models/README.md,
"Matching a sprite"). Moving parts follow client/assets/models/README.md ("Moving parts"):
`anim_spin_*` turn while the machine works, `anim_glow_*` light up while it works, and the
roboport's `anim_door_n` / `anim_door_s` slide open and `anim_charge` lights up when robots come
close (anim.gd).
"""

import math

from kit import MATERIALS, Part, R, S, T, model, rng
from circuits import cable, coil, vents
import detail  # noqa: F401  (its materials)
import space_kit

MATERIALS.update({
    "paint_robo": ("b6a057", 0.55, 0.45, None, 0),      # roboport's yellow-ochre body bands
    "steel_robo": ("9a9c98", 0.45, 0.8, None, 0),       # roboport's grey sheet steel
    "copper_hose": ("8c5230", 0.6, 0.6, None, 0),       # the beacon's ribbed copper hoses
    "cable_tan": ("a08866", 0.7, 0.1, None, 0),         # the beacon's bundles of thin cables
    "paint_robo_blue": ("3f5f9a", 0.55, 0.45, None, 0),  # roboport's antenna arms
    "brass_rim": ("b08a45", 0.4, 0.9, None, 0),         # roboport hatch rim
    "robot_white": ("d9d3c3", 0.45, 0.4, None, 0),      # robots' shells
    "robot_red": ("a3241b", 0.5, 0.3, None, 0),
    "robot_thruster": ("a3241b", 0.5, 0.3, "ff3a1a", 1.2),  # logistic robot's leg tips, lit in flight
    "lamp_white": ("e8e8e0", 0.4, 0.0, "ffffff", 0.8),
    "robot_cream": ("cfc3a2", 0.5, 0.4, None, 0),
    "paint_efurnace": ("7f8a8e", 0.5, 0.6, None, 0),    # electric furnace's grey-blue steel
    "paint_efurnace_teal": ("3f5654", 0.55, 0.5, None, 0),
    "paint_capacitor": ("c8d3d8", 0.45, 0.5, None, 0),  # the furnace's white-blue cylinders
    "heater": ("ff7a1a", 0.8, 0.0, "ff6010", 2.5),      # glowing heater coils
    "copper_coil": ("9a5a32", 0.45, 0.85, None, 0),     # beacon's coiled cables
    "beacon_light": ("9fd8ff", 0.4, 0.0, "6fc0ff", 2.0),
    "paint_am1": ("585e4c", 0.60, 0.40, None, 0),       # assembler 1: weathered olive-grey steel
    "paint_am2": ("223c58", 0.58, 0.45, None, 0),       # assembler 2: deep weathered slate-steel blue
    "paint_am3": ("4d521a", 0.60, 0.42, None, 0),       # assembler 3: deep weathered olive-moss green
    "rust_machine": ("6c4e32", 0.76, 0.50, None, 0),    # the assemblers' weathered brown/bronze machinery
    "soot_oil": ("1c1915", 0.3, 0.0, None, 0),          # crude oil: glossy black
    "stone_oil": ("3a3129", 0.95, 0.0, None, 0),
    "charge_spark": ("bfd6ff", 0.3, 0.0, "8fb4ff", 3.0),  # roboport charging glow
})


# ---------------------------------------------------------------------------------------------
# Roboport.

def octagon(rx, ry, cut):
    """Corners (counter-clockwise) of a rectangle rx x ry (half sizes) with corners cut by `cut`."""
    return [(rx, -ry + cut), (rx, ry - cut), (rx - cut, ry), (-rx + cut, ry), (-rx, ry - cut),
            (-rx, -ry + cut), (-rx + cut, -ry), (rx - cut, -ry)]


def frustum(p, base, top, z0, z1, mat, cy=0.0, top_cy=None):
    """A solid from polygon `base` at z0 to polygon `top` (same corner count) at z1."""
    k = Part()
    k.prism(base, z0, z1, mat)
    for v in k.bm.verts:
        if v.co.z > (z0 + z1) / 2:
            i = min(range(len(base)), key=lambda i: (v.co.x - base[i][0]) ** 2 + (v.co.y - base[i][1]) ** 2)
            v.co.x, v.co.y = top[i]
    p.add_part(k)


@model("roboport")
def roboport():
    """Factorio's roboport: a heavy octagonal body, grey sheet steel with ochre bands, narrowing
    to a big round hatch on top (its two doors slide apart, `anim_door_n`/`anim_door_s`); a
    front of machinery (boxes, pipes); four blue channel brackets at the corners carrying white
    tube frames, ball joints and antennas, and the charging points (`anim_charge` glows while
    robots are near); a black lattice antenna mast at the back."""
    p = Part()
    # Lower body: octagonal, from the front to near the back edge.
    p.prism(octagon(1.32, 1.5, 0.45), 0.0, 0.12, "steel_dark")
    lower = [(x, y - 0.12) for x, y in octagon(1.22, 1.42, 0.42)]
    p.prism(lower, 0.12, 1.15, "steel_robo")
    # Ochre bands round it at the bottom and just under the shoulder.
    band = [(x * 1.01, y * 1.01 - 0.12) for x, y in octagon(1.22, 1.42, 0.42)]
    p.prism(band, 0.12, 0.3, "paint_robo")
    p.prism(band, 0.95, 1.15, "paint_robo")
    # Shoulder: a frustum up to the hatch collar.
    hatch_y, hatch_z = -0.05, 1.85
    top = [(x * 0.7, y * 0.64 + hatch_y) for x, y in octagon(1.22, 1.32, 0.42)]
    frustum(p, lower, top, 1.15, hatch_z - 0.15, "steel_robo")
    collar = [(x, y) for x, y in top]
    p.prism(collar, hatch_z - 0.15, hatch_z, "paint_robo")
    # The hatch: a brass rim round a dark well, two doors in it.
    rim = Part()
    rim.ring_band((0, 0), 0.62, 0.8, 0.0, 0.12, 0, 360, "brass_rim", segs=28)
    rim.bolts_ring((0, 0, 0.1), 0.67, 20, radius=0.015)
    p.add_part(rim, T(0, hatch_y, hatch_z) @ S(1.0, 0.92, 1.0))
    p.cyl((0, 0, 0), 0.6, 0.5, "steel_black", segs=28, matrix=T(0, hatch_y, hatch_z - 0.25) @ S(1.0, 0.92, 1.0))
    doors = []
    for name, sign in (("anim_door_n", 1), ("anim_door_s", -1)):
        d = Part(name, pivot=(0, hatch_y, hatch_z + 0.03))
        pts = []
        for i in range(13):
            a = math.radians(i * 15) if sign > 0 else math.radians(180 + i * 15)
            pts.append((0.6 * math.cos(a), hatch_y + 0.55 * math.sin(a)))
        d.prism(pts, hatch_z + 0.02, hatch_z + 0.06, "steel_light", bevel=0.01)
        for k in range(3):
            a = math.radians(30 + k * 60) if sign > 0 else math.radians(210 + k * 60)
            d.beam((0, hatch_y, hatch_z + 0.065), (0.55 * math.cos(a), hatch_y + 0.5 * math.sin(a), hatch_z + 0.065),
                   0.03, 0.015, "steel")
        doors.append(d)
    # Grey panels on the shoulder's front, riveted.
    for x in (-0.55, 0.45):
        p.box((x, -1.05, 1.42), (0.5, 0.06, 0.4), "steel", bevel=0.02, matrix=None)
    # Front machinery: a dark box on the west, pipes, a cylinder tank.
    p.slab(-1.2, -1.95, 0.0, -0.55, -1.3, 0.85, "steel_dark", bevel=0.04)
    p.slab(-1.12, -1.97, 0.25, -0.75, -1.94, 0.6, "steel_black")
    for k in range(4):
        p.slab(-1.1, -1.99, 0.3 + k * 0.08, -0.77, -1.97, 0.33 + k * 0.08, "steel")
    p.cyl((-0.15, -1.62, 0.42), 0.38, 0.84, "steel_robo", segs=20, axis="X", bevel=0.04)
    p.cyl((-0.15, -1.62, 0.42), 0.4, 0.1, "paint_robo", segs=20, axis="X")
    for x in (-0.5, -0.35):
        p.pipe([(x, -1.4, 1.2), (x, -1.75, 1.0), (x, -1.9, 0.2)], 0.04, "copper_dull")
    p.pipe([(0.12, -1.3, 1.1), (0.12, -1.55, 1.05), (0.25, -1.55, 0.9)], 0.04, "copper_dull")
    p.pipe([(0.32, -1.3, 1.1), (0.32, -1.55, 1.05), (0.4, -1.55, 0.9)], 0.04, "copper_dull")
    p.pipe([(0.55, -1.9, 0.15), (0.55, -1.75, 0.35), (0.3, -1.7, 0.4)], 0.035, "steel_light")
    # Arms: broad blue channel brackets leaning out from the body's corners, each carrying the
    # sprite's white tube frames: an A-frame over the bracket with a small white ball joint and a
    # thin antenna at its top, a white knob on the bracket's end and a square frame hanging out
    # and down from it (G13: they were thin lattices with a white block).
    from mathutils import Vector
    charge = Part("anim_charge")
    for sx in (-1, 1):
        for y, zt in ((-0.95, 1.2), (0.95, 1.7)):
            root = Vector((sx * 1.12, y, 0.45))
            tip = Vector((sx * 1.58, y + 0.18 * (1 if y > 0 else -1), zt))
            out = Vector((sx, 0, 0))
            along = (tip - root).normalized()
            for dy in (-0.11, 0.11):
                p.beam(root + Vector((0, dy, 0)), tip + Vector((0, dy, 0)), 0.2, 0.04, "paint_robo_blue", up=(0, 1, 0))
            p.beam(root - out * 0.06, tip - out * 0.06, 0.24, 0.04, "paint_robo_blue", up=tuple(out))
            p.beam((sx * 1.15, y, 0.3), (sx * 1.15, y, 1.0), 0.14, 0.1, "steel_dark")
            a_top = tip + out * 0.05 + Vector((0, 0, 0.3))
            p.pipe([tip + Vector((0, -0.13, 0.04)), a_top, tip + Vector((0, 0.13, 0.04))], 0.022, "steel_light", segs=6)
            p.sphere(a_top, 0.05, "steel_light", segs=10, rings=5)
            p.tube(a_top, a_top + Vector((sx * 0.05, 0, 0.18)), 0.012, "steel_light", segs=5)
            p.sphere(tip + out * 0.06 + Vector((0, 0, 0.06)), 0.065, "steel_light", segs=10, rings=5)
            loop = []
            for dy in (-0.14, 0.14):
                hang = [tip + Vector((0, dy, -0.04)), tip + out * 0.3 + Vector((0, dy, -0.16)),
                        tip + out * 0.3 + Vector((0, dy, -0.72))]
                loop += hang if dy < 0 else list(reversed(hang))
            p.pipe(loop, 0.022, "steel_light", segs=6)
            p.beam(tip - along * 0.25 + Vector((0, -0.11, 0)), tip + out * 0.3 + Vector((0, -0.14, -0.4)),
                   0.03, 0.03, "steel_light")
            cable(p, [(sx * 1.2, y + 0.1, 0.7), (sx * 1.45, y + 0.12, 1.3), tuple(tip + Vector((0, 0.06, 0)))],
                  "rubber_red", 0.015)
            charge.sphere(tip + out * 0.12 - Vector((0, 0, 0.12)), 0.07, "charge_spark", segs=8, rings=4)
    # The back and sides, which the sprite hardly shows: riveted grey panels and a ladder.
    for x in (-0.5, 0.5):
        p.slab(x - 0.3, 1.3, 0.35, x + 0.3, 1.34, 0.9, "steel", bevel=0.015)
        for bz in (0.4, 0.85):
            for bx in (-0.25, 0.25):
                p.bolt((x + bx, 1.345, bz), "steel_light", radius=0.015, axis="Y")
    for z in [0.2 + 0.15 * k for k in range(7)]:
        p.beam((0.95, 1.36, z), (1.12, 1.36, z), 0.025, 0.025, "steel_dark")
    for x in (0.95, 1.12):
        p.beam((x, 1.36, 0.1), (x, 1.36, 1.2), 0.03, 0.03, "steel_dark")
    # The antenna mast at the back west: a black lattice tower, four legs drawn in towards a
    # round cap; a grey ribbed box beside it.
    cx, cy = -0.65, 1.12
    legs = [(sx * 0.2, sy * 0.17) for sx in (-1, 1) for sy in (-1, 1)]
    for lx, ly in legs:
        p.beam((cx + lx, cy + ly, 1.6), (cx + lx * 0.45, cy + ly * 0.45, 2.45), 0.04, 0.04, "steel_black")
    for z0, z1 in ((1.6, 1.9), (1.9, 2.2), (2.2, 2.45)):
        f0 = 1.0 - 0.55 * (z0 - 1.6) / 0.85
        f1 = 1.0 - 0.55 * (z1 - 1.6) / 0.85
        for i in range(4):
            ax, ay = legs[i]
            bx, by = legs[(i + 1) % 4] if i % 2 == 0 else legs[(i + 3) % 4]
            p.beam((cx + ax * f0, cy + ay * f0, z0), (cx + bx * f1, cy + by * f1, z1), 0.025, 0.025, "steel_black")
    p.slab(-0.88, 0.92, 1.6, -0.42, 1.32, 1.68, "steel_black", bevel=0.02)
    p.cyl((cx, cy, 2.55), 0.11, 0.22, "steel_black", segs=12, bevel=0.02)
    p.cyl((cx, cy, 2.67), 0.07, 0.04, "steel_dark", segs=10)
    p.slab(-0.35, 1.0, 1.75, 0.05, 1.3, 2.05, "steel_dark", bevel=0.03)
    for k in range(5):
        p.slab(-0.33 + k * 0.08, 1.02, 2.05, -0.29 + k * 0.08, 1.28, 2.09, "steel_light")
    p.cyl((0.35, 1.15, 1.9), 0.12, 0.3, "steel_light", segs=10)
    p.cyl((0.6, 1.15, 1.85), 0.1, 0.25, "steel_light", segs=10)
    return [p, charge] + doors


def grounded(p):
    """Moves a part so its lowest point is on the ground."""
    low = min(v.co.z for v in p.bm.verts)
    return p.transform(T(0, 0, -low))


# ---------------------------------------------------------------------------------------------
# Robots: modelled round their middle, lowest point on the ground; movers.gd flies them.

def grounded_parts(parts, matrix):
    """Transforms the parts of one model (pivots too), then grounds them together."""
    for part in parts:
        part.transform(matrix)
        part.pivot = matrix @ part.pivot
    low = min(v.co.z for part in parts for v in part.bm.verts)
    for part in parts:
        part.transform(T(0, 0, -low))
        part.pivot.z -= low
    return parts


@model("logistic-robot")
def logistic_robot():
    """Factorio's logistic robot facing north: a cream-white dome with a black cross on top,
    a red-tipped tail leg reaching back and two side legs splayed back, an antenna with a ball
    on its west side.

    Moving parts, from its sprite sheet's four rows (idle, in motion, each with and without
    cargo): the legs are its thrusters (`anim_thrusters`, pivot where they meet the body), swung
    back and their red tips lit while it flies; the antenna's ball is red while it carries
    cargo (`anim_lamp_cargo`) and white without (`anim_lamp_empty`). vehicle_anim.gd shows one
    or the other."""
    p = Part()
    zc = 0.32
    p.sphere((0, 0.02, zc), 0.25, "robot_white", segs=16, rings=8, scale=(1.0, 1.05, 0.82))
    p.cyl((0, 0.02, zc - 0.08), 0.25, 0.06, "steel_dark", segs=16)
    # The black cross: bands over the dome, north-south and east-west.
    for rz in (0, 90):
        band = Part()
        band.ring_band((0, 0), 0.245, 0.262, -0.03, 0.03, 0, 180, "steel_black", segs=10)
        p.add_part(band, T(0, 0.02, zc) @ R("Z", rz) @ R("X", 90) @ S(1.0, 0.82, 1.0))
    # Legs: rails down from the body, red caps at their ends (glowing: the thrusters).
    legs = (((0, -0.15, zc - 0.05), (0, -0.3, 0.06)),
            ((-0.18, -0.06, zc - 0.05), (-0.28, -0.2, 0.08)),
            ((0.18, -0.06, zc - 0.05), (0.28, -0.2, 0.08)))
    thrusters = Part("anim_thrusters", pivot=(0.0, -0.08, zc - 0.05))
    for a, b in legs:
        thrusters.tube(a, b, 0.045, "robot_white", segs=8)
        end = tuple(b[i] + (b[i] - a[i]) * 0.2 for i in range(3))
        thrusters.tube(b, end, 0.052, "robot_thruster", segs=8)
    p.slab(-0.03, -0.3, zc + 0.05, 0.03, 0.2, zc + 0.24, "robot_white", bevel=0.02)
    p.tube((-0.12, 0.05, zc + 0.15), (-0.22, 0.1, zc + 0.45), 0.01, "steel_black", segs=4)
    cargo = Part("anim_lamp_cargo", pivot=(-0.22, 0.1, zc + 0.46))
    cargo.sphere((-0.22, 0.1, zc + 0.46), 0.025, "lamp_red", segs=6, rings=3)
    empty = Part("anim_lamp_empty", pivot=(-0.22, 0.1, zc + 0.46))
    empty.sphere((-0.22, 0.1, zc + 0.46), 0.025, "lamp_white", segs=6, rings=3)
    return grounded_parts([p, thrusters, cargo, empty], S(1.25, 1.25, 1.25))


@model("construction-robot")
def construction_robot():
    """Factorio's construction robot facing north: a cream barrel with a fan intake on top
    (dark ring and blades), a dark band round its foot, a nozzle with a red light on its front,
    and two thin jointed arms hanging below.

    Moving parts: the nozzle's light (`anim_lamp_nozzle`) flickers and the arms (`anim_arms`,
    pivot at the shoulders) reach forward while it works (Factorio's two `working` frames at
    0.3 a tick, with its sparks); vehicle_anim.gd decides it works when it hovers in one place."""
    p = Part()
    zc = 0.34
    p.cyl((0, 0, zc), 0.22, 0.3, "robot_cream", segs=18, bevel=0.03)
    p.cyl((0, 0, zc - 0.17), 0.2, 0.06, "steel_dark", segs=18)
    p.cyl((0, 0, zc + 0.16), 0.24, 0.05, "robot_cream", segs=18, bevel=0.015)
    p.cyl((0, 0, zc + 0.17), 0.19, 0.04, "steel_black", segs=18)
    for k in range(12):
        a = 2 * math.pi * k / 12
        p.beam((0.05 * math.cos(a), 0.05 * math.sin(a), zc + 0.185), (0.18 * math.cos(a), 0.18 * math.sin(a), zc + 0.185),
               0.02, 0.01, "steel_dark")
    p.cyl((0, 0, zc + 0.19), 0.06, 0.03, "steel", segs=10)
    # Nozzle on the front (south, towards the camera when flying north) with its red light.
    p.cyl((0, -0.24, zc - 0.02), 0.05, 0.08, "robot_cream", segs=8, axis="Y")
    lamp = Part("anim_lamp_nozzle", pivot=(0, -0.29, zc - 0.1))
    lamp.sphere((0, -0.29, zc - 0.1), 0.03, "lamp_red", segs=6, rings=3)
    # Side lugs and the hanging arms.
    arms = Part("anim_arms", pivot=(0.0, 0.0, zc - 0.2))
    for sx in (-1, 1):
        p.slab(sx * 0.2, -0.05, zc - 0.05, sx * 0.27, 0.05, zc + 0.05, "robot_cream", bevel=0.01)
        arms.pipe([(sx * 0.1, 0.0, zc - 0.2), (sx * 0.16, -0.12, 0.12), (sx * 0.12, -0.2, 0.0)], 0.018, "steel_dark")
    # Flying, it leans forward: the sprite looks down into its fan.
    return grounded_parts([p, lamp, arms], R("X", 22) @ S(1.3, 1.3, 1.3))


# ---------------------------------------------------------------------------------------------
# Electric furnace.

@model("electric-furnace")
def electric_furnace():
    """Factorio's electric furnace: a grey-blue block with a round tank wrapped in cable at its
    back west, two fan housings and an oval vent on top (`anim_spin_fan` turn while it works),
    a grille box at the back east, three white capacitors and pipes down the east side, and a
    teal sloped front with the heater window glowing (`anim_glow_heater`) while it works."""
    p = Part()
    p.slab(-1.4, -1.38, 0.0, 1.38, 1.35, 0.12, "steel_dark", bevel=0.02)
    p.slab(-1.25, -0.55, 0.12, 1.1, 1.28, 1.05, "paint_efurnace", bevel=0.05)
    # The tank at the back west, wrapped round with bands.
    p.cyl((-0.82, 0.6, 0.75), 0.6, 1.5, "paint_efurnace", segs=24, bevel=0.05)
    for z in (0.4, 0.7, 1.0, 1.3):
        p.cyl((-0.82, 0.6, z), 0.62, 0.08, "steel_dark", segs=24)
    # On top of the tank: the oval vent, a fan housing in front of it.
    vent = Part()
    vent.cyl((0, 0, 0), 0.32, 0.18, "steel", segs=20, bevel=0.03)
    vent.cyl((0, 0, 0.09), 0.26, 0.02, "steel_black", segs=20)
    for k in range(5):
        vent.slab(-0.2, -0.16 + k * 0.08, 0.09, 0.2, -0.14 + k * 0.08, 0.12, "steel_dark")
    p.add_part(vent, T(-0.72, 0.85, 1.58) @ S(1.25, 0.8, 1.0))
    fans = []
    for i, (x, y, z, r) in enumerate(((-0.62, 0.15, 1.3, 0.34), (0.05, 0.85, 1.3, 0.3))):
        p.cyl((x, y, z - 0.12), r + 0.04, 0.42, "steel", segs=22, bevel=0.03)
        p.cyl((x, y, z + 0.08), r - 0.03, 0.02, "steel_black", segs=22)
        fan = Part("anim_spin_fan", pivot=(x, y, z + 0.1))
        for k in range(3):
            a = 2 * math.pi * k / 3
            fan.beam((x, y, z + 0.11), (x + (r - 0.06) * math.cos(a), y + (r - 0.06) * math.sin(a), z + 0.11),
                     0.12, 0.02, "steel_light")
        fan.cyl((x, y, z + 0.12), 0.06, 0.04, "steel_dark", segs=10)
        fans.append(fan)
    # Back east: a grille box; then three capacitors stepping down towards the front.
    p.slab(0.4, 0.55, 1.0, 1.28, 1.3, 1.45, "steel", bevel=0.04)
    vents(p, 0.55, 1.15, 0.55, 1.08, 1.38, 5)
    for k, (y, z) in enumerate(((0.3, 1.18), (-0.05, 1.08), (-0.4, 0.98))):
        p.cyl((0.42, y, z), 0.16, 0.62, "paint_capacitor", segs=16, axis="X", bevel=0.03)
        for x in (0.15, 0.68):
            p.cyl((x, y, z), 0.17, 0.05, "steel_dark", segs=16, axis="X")
        p.cyl((0.42, y, z + 0.1), 0.17, 0.04, "rust_orange", segs=16, axis="X")
    # Pipes down the east side and along the front.
    for x in (1.0, 1.18):
        p.pipe([(x, 0.6, 1.2), (x, 0.3, 1.2), (x, -0.3, 0.9), (x, -0.5, 0.2)], 0.06, "steel")
    p.pipe([(-0.9, -0.4, 0.85), (-0.3, -0.45, 0.95), (0.2, -0.45, 0.95), (0.3, -0.1, 0.95)], 0.06, "steel")
    p.pipe([(-1.15, -0.2, 0.9), (-1.2, -0.7, 0.6), (-1.15, -1.1, 0.35)], 0.06, "steel")
    p.slab(-0.18, -0.58, 0.95, 0.12, -0.35, 1.15, "paint_blue", bevel=0.02)
    vents(p, -0.14, 0.08, -0.58, 0.98, 1.12, 3)
    # Front: the teal housing sloping up to the block, the heater window on its slope.
    prof = [(-1.36, 0.0), (-0.5, 0.0), (-0.5, 0.95), (-0.85, 0.95), (-1.36, 0.45)]
    p.side_prism(prof, -0.95, 0.85, "paint_efurnace_teal", bevel=0.03)
    slope = math.degrees(math.atan2(0.95 - 0.45, 1.36 - 0.85))
    frame = Part()
    frame.slab(-0.55, -0.32, -0.03, 0.55, 0.32, 0.03, "steel", bevel=0.03)
    frame.slab(-0.45, -0.24, 0.0, 0.45, 0.24, 0.04, "steel_black")
    for i in range(10):
        x = -0.5 + i * 0.11
        frame.bolt((x, 0.28, 0.035), "steel_light", radius=0.015)
        frame.bolt((x, -0.28, 0.035), "steel_light", radius=0.015)
    m = T(-0.05, -1.08, 0.72) @ R("X", -slope)
    p.add_part(frame, m)
    heater = Part("anim_glow_heater")
    for i in range(4):
        x = -0.3 + i * 0.2
        heater.slab(x - 0.06, -0.2, 0.03, x + 0.06, 0.2, 0.05, "heater")
    heater.transform(m)
    # The back (north), which the sprite never shows: louvres, a cable duct and service pipes,
    # so it reads as the same machine from behind.
    vents(p, 0.1, 0.9, 1.28, 0.25, 0.85, 6, face=1)
    p.slab(-0.2, 1.28, 0.15, 0.02, 1.36, 1.0, "steel_dark", bevel=0.02)
    for x in (0.3, 0.7):
        p.pipe([(x, 1.2, 1.05), (x, 1.38, 0.95), (x, 1.38, 0.15)], 0.05, "steel")
    p.slab(1.1, -0.5, 0.15, 1.16, 1.2, 0.95, "steel_dark")
    for k in range(4):
        p.slab(1.16, -0.4 + k * 0.4, 0.25, 1.19, -0.1 + k * 0.4, 0.85, "paint_efurnace", bevel=0.01)
    # Feet at the front corners and a small box with a dial at the front west.
    p.slab(-1.3, -1.38, 0.0, -1.0, -0.9, 0.3, "steel_dark", bevel=0.03)
    p.cyl((-1.15, -1.15, 0.4), 0.09, 0.2, "steel_light", segs=10)
    p.slab(0.9, -1.36, 0.0, 1.3, -0.6, 0.45, "steel_dark", bevel=0.03)
    for k in range(6):
        p.slab(0.95 + k * 0.06, -1.37, 0.06, 0.97 + k * 0.06, -1.35, 0.4, "steel")
    return [p, heater] + fans


# ---------------------------------------------------------------------------------------------
# Beacon.

@model("beacon")
def beacon():
    """Factorio's beacon: a low octagonal steel frame with bolted corner blocks round a pit full
    of coiled copper cables, and a tall ribbed antenna on a skirt of eight curved fins in the
    middle; the light under the skirt glows while it works (`anim_glow_light`)."""
    p = Part()
    # The sprite's frame is cut more at the back corners than at the front ones.
    w, front, back, cf, cb = 1.44, 1.46, 1.38, 0.3, 0.6
    ring = [(w, -front + cf), (w, back - cb), (w - cb, back), (-w + cb, back), (-w, back - cb),
            (-w, -front + cf), (-w + cf, -front), (w - cf, -front)]
    p.prism(ring, 0.0, 0.08, "steel_dark")
    # The frame: beams along the octagon, raised blocks at the corners.
    for i in range(8):
        a, b = ring[i], ring[(i + 1) % 8]
        inner_a = (a[0] * 0.86, a[1] * 0.86)
        inner_b = (b[0] * 0.86, b[1] * 0.86)
        p.prism([a, b, inner_b, inner_a], 0.0, 0.32, "steel", bevel=0.02)
        bx, by = a[0] * 0.94, a[1] * 0.94
        p.slab(bx - 0.13, by - 0.13, 0.0, bx + 0.13, by + 0.13, 0.42, "steel_robo", bevel=0.04)
        p.bolt((bx, by, 0.43), "steel_dark", radius=0.035)
    # The pit: dark floor with a deep hole at the front west, and what fills it as the sprite
    # draws it: thick ribbed copper hoses swirling out from the collar and over the frame, bundles
    # of thin tan cables, and red cables looping over the rim.
    p.prism([(x * 0.86, y * 0.86) for x, y in ring], 0.0, 0.1, "steel_black")
    p.cyl((-0.42, -0.4, 0.105), 0.36, 0.01, "grime", segs=14)
    r = rng(7)
    for k in range(8):
        a0 = 2 * math.pi * k / 8 + r.uniform(-0.15, 0.15)
        swirl, r1 = r.uniform(0.3, 1.2), r.uniform(0.95, 1.2)
        rad = r.uniform(0.14, 0.18)
        pts = []
        for t in (0.0, 0.3, 0.6, 0.85, 1.0):
            rr = 0.28 + (r1 - 0.28) * t
            a = a0 + swirl * t
            z = 0.3 + 0.3 * math.sin(math.pi * min(t, 0.85) / 0.85) - (0.12 if t == 1.0 else 0.0)
            pts.append((rr * math.cos(a), rr * math.sin(a), max(z, rad + 0.1)))
        space_kit.hose(p, pts, rad, "copper_hose", segs=8, rib=0.12, depth=0.14, smooth=3)
    for k in range(4):   # bundles of thin cables
        a0 = 2 * math.pi * (k + 0.3) / 4
        for j in range(4):
            off = (j - 1.5) * 0.04
            pts = [((0.3 + off) * math.cos(a0 + off), (0.3 + off) * math.sin(a0 + off), 0.45),
                   (0.7 * math.cos(a0 + 0.35 + off), 0.7 * math.sin(a0 + 0.35 + off), 0.5),
                   (1.1 * math.cos(a0 + 0.5 + off), 1.1 * math.sin(a0 + 0.5 + off), 0.25)]
            space_kit.bent(p, pts, 0.018, "cable_tan", segs=4, smooth=3)
    for a0, out in ((2.4, 1.48), (3.6, 1.5), (5.6, 1.42), (0.6, 1.3), (1.6, 1.25)):
        pts = [(0.6 * math.cos(a0), 0.6 * math.sin(a0), 0.4), (1.1 * math.cos(a0 + 0.1), 1.1 * math.sin(a0 + 0.1), 0.55),
               (out * math.cos(a0 + 0.2), out * math.sin(a0 + 0.2), 0.3),
               (out * math.cos(a0 + 0.35), out * math.sin(a0 + 0.35), 0.06)]
        space_kit.bent(p, pts, 0.035, "rubber_red", segs=6, smooth=4)
    # Bolted plates on the frame's beams.
    for i in range(8):
        a, b = ring[i], ring[(i + 1) % 8]
        mx, my = (a[0] + b[0]) / 2 * 0.93, (a[1] + b[1]) / 2 * 0.93
        ang = math.degrees(math.atan2(b[1] - a[1], b[0] - a[0]))
        p.box((mx, my, 0.33), (0.36, 0.14, 0.03), "steel_robo", rz=ang)
        for d in (-0.13, 0.13):
            c, s_ = math.cos(math.radians(ang)), math.sin(math.radians(ang))
            p.bolt((mx + d * c, my + d * s_, 0.35), "steel_dark", radius=0.02)
    # Side boxes on four faces, as the sprite's grey clamps.
    for ang in (0, 90, 180, 270):
        box = Part()
        box.slab(-0.22, -0.1, 0.0, 0.22, 0.1, 0.36, "steel_robo", bevel=0.03)
        box.slab(-0.15, -0.12, 0.08, 0.15, -0.1, 0.28, "steel_dark")
        p.add_part(box, R("Z", ang) @ T(0, -1.3, 0))
    # The antenna: a collar, eight fins hanging out and down, a ribbed mast.
    p.cyl((0, 0, 0.55), 0.22, 0.6, "steel_dark", segs=14)
    p.cyl((0, 0, 0.95), 0.16, 0.2, "steel", segs=14, bevel=0.02)
    for k in range(8):
        a = 2 * math.pi * (k + 0.5) / 8
        c, s = math.cos(a), math.sin(a)
        p.pipe([(0.1 * c, 0.1 * s, 0.98), (0.32 * c, 0.32 * s, 0.9), (0.52 * c, 0.52 * s, 0.6), (0.58 * c, 0.58 * s, 0.32)],
               0.022, "steel_light", segs=4)
        p.beam((0.52 * c, 0.52 * s, 0.6), (0.6 * c, 0.6 * s, 0.25), 0.07, 0.015, "steel_light", up=(c, s, 0))
    top = 2.5
    p.cyl((0, 0, (1.0 + top) / 2), 0.05, top - 1.0, "steel_light", segs=8, radius_top=0.025)
    n = 14
    for k in range(n):
        z = 1.1 + k * (top - 0.3 - 1.1) / n
        rr = 0.13 - 0.07 * k / n
        p.cyl((0, 0, z), rr, 0.035, "steel_light", segs=10)
    cable(p, [(0.08, -0.05, 0.6), (0.12, -0.08, 1.0), (0.06, -0.06, 1.25)], "rubber_red", 0.02)
    glow = Part("anim_glow_light")
    glow.cyl((0, 0, 0.75), 0.24, 0.16, "beacon_light", segs=14)
    return [p, glow]


# ---------------------------------------------------------------------------------------------
# Assembling machines 1, 2, and 3: an open-topped box with battered armor walls in the tier's
# colour (riveted panels on every face, chamfered front corners, rear corner ears, SE gusset
# ladder) packed with heavy machinery matching Factorio's HR sprites and 64-frame animations.

def _loft(p, bottom, top, mat):
    """A closed solid between two 3D outlines with the same corner count (counter-clockwise
    seen from above)."""
    n = len(bottom)
    p.poly(list(reversed(bottom)), mat)
    p.poly(top, mat)
    for i in range(n):
        j = (i + 1) % n
        p.poly([bottom[i], bottom[j], top[j], top[i]], mat)


def _lerp(a, b, t):
    return tuple(a[k] + (b[k] - a[k]) * t for k in range(3))


def _quad_at(q, u, v):
    """A point on quad q = (b_i, b_j, t_j, t_i) at u along the bottom edge, v up the face."""
    return _lerp(_lerp(q[0], q[1], u), _lerp(q[3], q[2], u), v)


def _face_normal(q):
    from mathutils import Vector
    a, b, d = Vector(q[0]), Vector(q[1]), Vector(q[3])
    return (b - a).cross(d - a).normalized()


def _panels(p, q, count, paint, u_pad=0.04, v0=0.12, v1=0.9):
    """Riveted plates standing proud of a wall face."""
    n = _face_normal(q)
    off = n * 0.035
    axis = "X" if abs(n.x) > max(abs(n.y), abs(n.z)) else "Y" if abs(n.y) > abs(n.z) else "Z"
    for k in range(count):
        u0 = u_pad / 2 + k / count
        u1 = (k + 1) / count - u_pad / 2
        pts = [_quad_at(q, u, v) for u, v in ((u0, v0), (u1, v0), (u1, v1), (u0, v1))]
        p.poly([tuple(c + o for c, o in zip(pt, off)) for pt in pts], paint, thick=0.035)
        for u in (u0 + 0.12 * (u1 - u0), u1 - 0.12 * (u1 - u0)):
            for v in (v0 + 0.1, v1 - 0.1):
                c = _quad_at(q, u, v)
                p.cyl(tuple(x + o * 0.06 for x, o in zip(c, n)), 0.022, 0.026, "steel_light", segs=6, axis=axis)


def _gear(p, centre, radius, width, teeth, mat, axis="Z", hub="steel_dark", yaw=0.0, spokes=0):
    """A toothed wheel lying flat (axis "Z") or standing up with its axle east-west ("X"), or
    north-south ("Y"), then turned `yaw` degrees about the vertical."""
    g = Part()
    if spokes > 0 and radius >= 0.16:
        # Spoked wheel: outer rim ring + contrasting dark hub + spokes + deep crisp teeth.
        r_segs = max(12, teeth)
        if axis == "Z":
            g.ring_band((0, 0), radius * 0.66, radius, -width / 2, width / 2, 0, 360, mat, segs=r_segs)
        else:
            ring = Part()
            ring.ring_band((0, 0), radius * 0.66, radius, -width / 2, width / 2, 0, 360, mat, segs=r_segs)
            g.add_part(ring, R("Y", 90) if axis == "X" else R("X", 90))
        g.cyl((0, 0, 0), radius * 0.30, width * 1.45, hub, segs=8, axis=axis)
        for k in range(spokes):
            a = 2 * math.pi * k / spokes
            c, s = math.cos(a) * radius * 0.70, math.sin(a) * radius * 0.70
            if axis == "Z":
                g.beam((0, 0, 0), (c, s, 0), width * 0.56, width * 0.78, hub if k % 2 else mat)
            elif axis == "X":
                g.beam((0, 0, 0), (0, c, s), width * 0.56, width * 0.78, hub if k % 2 else mat, up=(1, 0, 0))
            else:
                g.beam((0, 0, 0), (c, 0, s), width * 0.56, width * 0.78, hub if k % 2 else mat, up=(0, 1, 0))
    else:
        g.cyl((0, 0, 0), radius, width, mat, segs=max(10, teeth), axis=axis, bevel=0.008)
        g.cyl((0, 0, 0), radius * 0.34, width * 1.5, hub, segs=8, axis=axis)
    tooth_l = max(0.055, radius * 0.26)
    tooth_w = max(0.042, 2 * math.pi * radius / max(teeth, 8) * 0.44)
    for k in range(teeth):
        a = 2 * math.pi * k / teeth
        c, s = math.cos(a) * (radius + tooth_l * 0.35), math.sin(a) * (radius + tooth_l * 0.35)
        if axis == "Z":
            g.box((c, s, 0), (tooth_l, tooth_w, width * 0.94), mat, rz=math.degrees(a))
        elif axis == "X":
            g.box((0, 0, 0), (width * 0.94, tooth_w, tooth_l), mat, matrix=T(0, c, s) @ R("X", math.degrees(a)))
        else:
            g.box((0, 0, 0), (tooth_w, width * 0.94, tooth_l), mat, matrix=T(c, 0, s) @ R("Y", -math.degrees(a)))
    p.add_part(g, T(*centre) @ R("Z", yaw))


def _chain_track(p, a, b, width=0.14, mat="steel", link_mat="steel_dark", links=9):
    """Heavy drive chain rail between 3D points a and b with individual cross-links."""
    p.beam(a, b, width, 0.055, mat)
    for k in range(links):
        t = k / max(links - 1, 1)
        x = a[0] + (b[0] - a[0]) * t
        y = a[1] + (b[1] - a[1]) * t
        z = a[2] + (b[2] - a[2]) * t
        dx, dy = b[0] - a[0], b[1] - a[1]
        ang = math.degrees(math.atan2(dy, dx))
        p.box((x, y, z + 0.034), (0.045, width * 1.05, 0.022), link_mat, rz=ang)


def _am_shell(p, paint, tier):
    """Shared battered armor hull, ear-walls, riveted plates, SE ladder strut, dense cast
    bedplate, west copper plumbing, fan bezel, and status lamp housing for AM1, AM2, and AM3."""
    h = 0.98 if tier == 1 else (1.02 if tier == 2 else 1.05)
    ear_h = 1.20 if tier == 1 else (1.32 if tier == 2 else 1.36)
    # Ground outline and rim outline (counter-clockwise from front-right corner).
    bottom = [(1.12, -1.24), (1.32, -1.04), (1.38, -0.70), (1.38, 1.02), (1.14, 1.28),
              (-1.14, 1.28), (-1.38, 1.02), (-1.38, -0.70), (-1.32, -1.04), (-1.12, -1.24)]
    top = [(0.98, -1.08), (1.11, -0.95), (1.15, -0.70), (1.15, 0.84), (0.94, 1.08),
           (-0.94, 1.08), (-1.15, 0.84), (-1.15, -0.70), (-1.11, -0.95), (-0.98, -1.08)]
    # Rear corners step up into Factorio's signature sloped NW & NE corner ears.
    top_z = [h, h, h, ear_h, ear_h, ear_h, ear_h, h, h, h]
    B = [(x, y, 0.12) for x, y in bottom]
    Tp = [(x, y, z) for (x, y), z in zip(top, top_z)]

    # Dark recessed plinth & 6 chunky front feet.
    p.prism(bottom, 0.0, 0.14, "steel_black")
    inner = [(x * 0.87, y * 0.89 + 0.02) for x, y in top]
    n = len(B)
    for i in range(n):
        j = (i + 1) % n
        _loft(p, [B[i], B[j], (inner[j][0], inner[j][1], 0.12), (inner[i][0], inner[i][1], 0.12)],
              [Tp[i], Tp[j], (inner[j][0], inner[j][1], h), (inner[i][0], inner[i][1], h)], paint)
        # Rusty weathered top rim lip.
        p.beam((Tp[i][0], Tp[i][1], Tp[i][2] + 0.015), (Tp[j][0], Tp[j][1], Tp[j][2] + 0.015), 0.075, 0.045, "rust_machine")

    # Riveted exterior armor plates (front 4 plates over 6 feet, chamfer plates, side plates).
    for i in range(n):
        j = (i + 1) % n
        count = 4 if i in (n - 1, 4) else max(1, round(math.dist(B[i][:2], B[j][:2]) / 0.50))
        q = (B[i], B[j], Tp[j], Tp[i])
        if i == n - 1:
            _panels(p, q, count, paint, v0=0.28, v1=0.90)
            n_out = _face_normal(q)
            for k in range(6):
                pts = [_quad_at(q, u, v) for u, v in ((k / 6 + 0.012, 0.0), ((k + 1) / 6 - 0.012, 0.0),
                                                     ((k + 1) / 6 - 0.012, 0.25), (k / 6 + 0.012, 0.25))]
                p.poly([tuple(c + o * 0.045 for c, o in zip(pt, n_out)) for pt in pts], "steel_dark", thick=0.045)
        elif i == 0:
            # SE chamfered corner holds the signature angled ladder/gusset strut instead of a plain plate.
            for t_side in (-0.09, 0.09):
                p.beam((1.22 + t_side * 0.7, -1.14 - t_side * 0.7, 0.08),
                       (1.045 + t_side * 0.7, -1.015 - t_side * 0.7, h + 0.04), 0.055, 0.075, "steel_dark")
            for rz in (0.28, 0.54, 0.80):
                u = (rz - 0.08) / (h - 0.04)
                cx = 1.22 + (1.045 - 1.22) * u
                cy = -1.14 + (-1.015 + 1.14) * u
                p.box((cx, cy, rz), (0.22, 0.06, 0.045), "steel", rz=-42)
        else:
            _panels(p, q, count, paint, v0=0.08, v1=0.88)

    # AM3 front-center green arched rim collar framing the center gear.
    if tier == 3:
        p.slab(-0.34, -1.14, h - 0.03, 0.34, -1.01, h + 0.09, paint, bevel=0.025)
        p.cyl((0.0, -1.075, h + 0.07), 0.20, 0.13, paint, segs=12, axis="Y", bevel=0.015)

    # Multi-level dark cast-iron interior bedplate, ribs, and under-machinery (zero bare floor).
    p.prism([(x * 0.86, y * 0.88 + 0.02) for x, y in top], 0.12, h - 0.34, "steel_black")
    p.slab(-0.92, -0.82, h - 0.34, 0.92, 0.88, h - 0.22, "steel_dark")
    for ry in (-0.52, -0.10, 0.36):
        p.slab(-0.92, ry - 0.04, h - 0.24, 0.92, ry + 0.04, h - 0.12, "rust_machine")
    for rx in (-0.52, 0.05, 0.56):
        p.slab(rx - 0.04, -0.82, h - 0.24, rx + 0.04, 0.84, h - 0.13, "steel_dark")

    # Rear cast-brown gearbox housing & upper manifolds across north edge.
    p.cyl((-0.02, 0.84, h + 0.02), 0.25, 0.90, "rust_machine", segs=12, axis="X", bevel=0.03)
    for rx in (-0.34, -0.10, 0.14, 0.36):
        p.cyl((rx, 0.84, h + 0.02), 0.27, 0.04, "steel_dark", segs=12, axis="X")
        p.cyl((rx, 0.88, h + 0.26), 0.04, 0.07, "steel_light", segs=6)
    p.slab(0.44, 0.56, h - 0.16, 1.00, 1.02, h + 0.10, "steel_dark", bevel=0.025)

    # NW horizontal pressure cylinder & west copper pipe with mounting collars.
    p.cyl((-0.82, 0.58, h + 0.05), 0.145, 0.44, "rust_machine", segs=10, axis="X", bevel=0.025)
    for cx in (-0.96, -0.68):
        p.cyl((cx, 0.58, h + 0.05), 0.155, 0.035, "steel_dark", segs=10, axis="X")
    p.pipe([(-1.02, 0.44, h + 0.02), (-1.04, -0.32, h - 0.02), (-0.94, -0.44, h - 0.16), (-0.80, -0.48, h - 0.16)],
           0.046, "copper_dull", segs=8)
    for py in (0.28, -0.14):
        p.cyl((-1.03, py, h - 0.01), 0.062, 0.04, "steel_dark", segs=8, axis="Y")

    # West circular fan shroud (housing + deep black inner well; bright raised impeller is animated).
    fx, fy, fr = (-0.80, 0.18, 0.22) if tier in (1, 2) else (-0.78, 0.20, 0.25)
    p.cyl((fx, fy, h - 0.04), fr + 0.035, 0.18, "steel_dark", segs=14, bevel=0.015)
    p.ring_band((fx, fy), fr - 0.02, fr + 0.045, h, h + 0.11, 0, 360, "steel_light", segs=16)
    p.cyl((fx, fy, h + 0.02), fr - 0.02, 0.04, "steel_black", segs=14)

    # Diagonal heavy bolted bronze/copper-brown gearbox drum from west fan toward center-front.
    p.pipe([(-0.74, 0.02, h - 0.04), (-0.42, -0.22, h), (-0.12, -0.44, h - 0.10)], 0.21, "rust_machine", segs=10)
    for bx, by in ((-0.62, -0.08), (-0.44, -0.21), (-0.26, -0.34)):
        p.cyl((bx, by, h), 0.23, 0.045, "copper_dull" if bx == -0.44 else "steel_dark", segs=10)
        p.bolts_ring((bx, by, h + 0.17), 0.08, 4, radius=0.018)
    # Central mechanical bay support frame.
    p.slab(-0.42, -0.02, h - 0.22, 0.16, 0.56, h - 0.04, "rust_machine", bevel=0.02)
    p.beam((-0.52, 0.44, h + 0.04), (0.04, 0.44, h + 0.04), 0.08, 0.05, "steel_dark")

    # SW working status lamp bezel (bright dome goes into anim_glow_am_status).
    sx, sy, sz = -0.98, -0.52, h - 0.01
    p.cyl((sx, sy, sz - 0.03), 0.080, 0.09, "steel_dark", segs=10, bevel=0.01)
    p.cyl((sx, sy, sz + 0.01), 0.068, 0.03, "steel_light", segs=10)
    lamp = Part("anim_glow_am_status")
    lamp.sphere((sx, sy, sz + 0.03), 0.052, "lamp_green", segs=10, rings=5, scale=(1.0, 1.0, 0.85))
    return h, (fx, fy, h + 0.075, fr), lamp


@model("assembling-machine-1")
def assembling_machine_1():
    """Factorio's assembling machine 1: weathered olive-grey riveted armor shell with compact
    rear ears, SE ladder strut, prominent dual central horizontal meshing steel gears, east
    vertical steel stamper head, west fan impeller, SW & NE spoked gears, NW rocker arm,
    north drive bar, and working green status light."""
    p = Part()
    h, (fx, fy, fz, fr), lamp = _am_shell(p, "paint_am1", 1)

    # Interior static density: chain beam, SE guide housing, static cradle under east head.
    _chain_track(p, (-0.18, 0.34, h + 0.04), (0.84, 0.62, h + 0.10), width=0.13, links=8)
    p.slab(0.36, -0.78, h - 0.24, 0.94, -0.26, h - 0.02, "rust_machine", bevel=0.025)
    p.cyl((0.52, -0.02, h - 0.18), 0.22, 0.28, "steel_dark", segs=12)
    p.cyl((-0.78, 0.88, h + 0.05), 0.075, 0.30, "steel_dark", segs=8)
    p.cyl((0.18, 0.88, h + 0.12), 0.08, 0.20, "steel_dark", segs=8, axis="X")

    # 1 & 2. Prominent central dual meshing horizontal spoked bright-steel gears (AM1 signature).
    c1_at = (-0.24, 0.18, h + 0.09)
    gear_cw = Part("anim_am1_gear_cw", pivot=c1_at)
    _gear(gear_cw, c1_at, 0.28, 0.09, 12, "steel_light", axis="Z", hub="copper_dull", spokes=5)

    c2_at = (0.14, 0.16, h + 0.09)
    gear_ce = Part("anim_am1_gear_ce", pivot=c2_at)
    _gear(gear_ce, c2_at, 0.22, 0.09, 10, "steel_light", axis="Z", hub="steel_dark", spokes=4)

    # 3. Prominent SW angled spoked drive gear.
    sw_at = (-0.64, -0.58, h - 0.08)
    gear_sw = Part("anim_am1_gear_sw", pivot=sw_at)
    _gear(gear_sw, sw_at, 0.30, 0.13, 14, "steel_light", axis="X", yaw=-35, hub="rust_machine", spokes=5)

    # 4. High-contrast 4-blade west impeller raised clearly inside the dark well.
    fan_at = (fx, fy, fz)
    fan_w = Part("anim_am1_fan_w", pivot=fan_at)
    fan_w.cyl(fan_at, 0.06, 0.06, "copper_dull", segs=8)
    for k in range(4):
        a = k * math.pi / 2.0 + 0.25
        fan_w.beam(fan_at, (fx + (fr - 0.025) * math.cos(a), fy + (fr - 0.025) * math.sin(a), fz),
                   0.068, 0.028, "steel_light")

    # 5. NW bold swinging overhead linkage arm & hammer head.
    nw_piv = (-0.78, 0.88, h + 0.22)
    arm_nw = Part("anim_am1_arm_nw", pivot=nw_piv)
    arm_nw.cyl(nw_piv, 0.08, 0.10, "steel_dark", segs=10)
    arm_nw.beam(nw_piv, (-0.16, 0.60, h + 0.14), 0.11, 0.06, "steel_light", bevel=0.008)
    arm_nw.cyl((-0.16, 0.60, h + 0.14), 0.07, 0.09, "copper_dull", segs=8)

    # 6. East heavy vertical stamping head & brass ram plunging deeply into its cradle.
    px, py = 0.52, -0.02
    press_e = Part("anim_am1_press_e", pivot=(px, py, h + 0.16))
    press_e.cyl((px, py, h + 0.16), 0.20, 0.38, "steel_light", segs=12, bevel=0.02)
    press_e.slab(px + 0.10, py - 0.10, h - 0.02, px + 0.26, py + 0.10, h + 0.28, "paint_am1", bevel=0.015)
    press_e.cyl((px, py, h + 0.37), 0.13, 0.07, "copper_dull", segs=10, bevel=0.01)

    # 7. Prominent NE sprocket wheel.
    ne_at = (0.76, 0.58, h + 0.08)
    gear_ne = Part("anim_am1_gear_ne", pivot=ne_at)
    _gear(gear_ne, ne_at, 0.22, 0.09, 12, "steel_light", axis="X", yaw=-15, hub="rust_machine", spokes=4)

    # 8. North sliding steel crosshead carriage along top rail.
    bar_piv = (0.12, 0.88, h + 0.17)
    bar_n = Part("anim_am1_bar_n", pivot=bar_piv)
    bar_n.tube((-0.20, 0.88, h + 0.17), (0.48, 0.88, h + 0.17), 0.036, "steel_light", segs=8)
    bar_n.box((0.12, 0.88, h + 0.17), (0.18, 0.15, 0.14), "paint_am1", bevel=0.015)
    bar_n.box((0.12, 0.88, h + 0.17), (0.09, 0.17, 0.16), "steel_light", bevel=0.01)

    return [p, lamp, gear_cw, gear_ce, gear_sw, fan_w, arm_nw, press_e, gear_ne, bar_n]


@model("assembling-machine-2")
def assembling_machine_2():
    """Factorio's assembling machine 2: blue riveted armor shell with tall rear corner ears,
    SE ladder strut, dense brown/copper works, prominent blue vertical actuator press, central
    horizontal steel gear, west fan, meshing front gears, SE rocking piston, NW rocker arm,
    NE chain sprocket, north drive bar, and working green status light."""
    p = Part()
    h, (fx, fy, fz, fr), lamp = _am_shell(p, "paint_am2", 2)

    # Interior static density: idler gear, chain beam, SE crank housing, yellow hydraulic cable.
    _gear(p, (-0.12, -0.44, h - 0.16), 0.18, 0.07, 10, "steel_dark")
    _gear(p, (0.34, 0.36, h - 0.06), 0.16, 0.06, 10, "steel_dark", axis="X", yaw=-15)
    _chain_track(p, (-0.16, 0.32, h + 0.07), (0.86, 0.62, h + 0.12), width=0.14, links=9)
    p.slab(0.46, -0.84, h - 0.24, 0.96, -0.36, h - 0.02, "rust_machine", bevel=0.025)
    p.cyl((0.72, -0.58, h - 0.02), 0.12, 0.14, "steel_dark", segs=10)
    p.pipe([(0.54, 0.02, h + 0.08), (0.72, -0.02, h + 0.02), (0.76, -0.26, h - 0.08)], 0.024, "hazard", segs=6)
    p.cyl((-0.78, 0.90, h + 0.06), 0.075, 0.32, "steel_dark", segs=8)
    p.cyl((0.18, 0.90, h + 0.14), 0.08, 0.22, "steel_dark", segs=8, axis="X")
    # Deep static cradle under the blue press so large vertical plunge shows zero gap.
    p.cyl((0.38, -0.10, h - 0.18), 0.22, 0.32, "steel_dark", segs=12)

    # 1 & 2. Front-left meshing angled spoked bright-steel spur gears.
    g1_at = (-0.76, -0.64, h - 0.10)
    gear_sw1 = Part("anim_am2_gear_swa", pivot=g1_at)
    _gear(gear_sw1, g1_at, 0.29, 0.13, 14, "steel_light", axis="X", yaw=-35, hub="rust_machine", spokes=5)
    _gear(p, (-0.64, -0.56, h - 0.16), 0.22, 0.07, 10, "steel_dark", axis="X", yaw=-35)

    g2_at = (-0.36, -0.54, h - 0.08)
    gear_sw2 = Part("anim_am2_gear_swb", pivot=g2_at)
    _gear(gear_sw2, g2_at, 0.24, 0.12, 12, "steel_light", axis="X", yaw=-35, hub="copper_dull", spokes=4)

    # 3. Prominent central horizontal spoked gear in the open bay.
    gc_at = (-0.16, 0.16, h + 0.10)
    gear_c = Part("anim_am2_gear_c", pivot=gc_at)
    _gear(gear_c, gc_at, 0.26, 0.085, 12, "steel_light", axis="Z", hub="copper_dull", spokes=5)

    # 4. West vent 4-blade bright impeller raised cleanly inside shroud.
    fan_at = (fx, fy, fz)
    fan_w = Part("anim_am2_fan_w", pivot=fan_at)
    fan_w.cyl(fan_at, 0.06, 0.06, "copper_dull", segs=8)
    for k in range(4):
        a = k * math.pi / 2.0 + 0.3
        fan_w.beam(fan_at, (fx + (fr - 0.025) * math.cos(a), fy + (fr - 0.025) * math.sin(a), fz),
                   0.068, 0.028, "steel_light")

    # 5. NW slotted rocker arm pivoting boldly.
    nw_piv = (-0.78, 0.90, h + 0.22)
    arm_nw = Part("anim_am2_arm_nw", pivot=nw_piv)
    arm_nw.cyl(nw_piv, 0.08, 0.10, "steel_dark", segs=10)
    arm_nw.beam(nw_piv, (-0.16, 0.60, h + 0.12), 0.11, 0.06, "steel_light", bevel=0.008)
    arm_nw.beam((-0.66, 0.84, h + 0.23), (-0.28, 0.65, h + 0.14), 0.04, 0.07, "steel_black")
    arm_nw.cyl((-0.16, 0.60, h + 0.12), 0.065, 0.08, "copper_dull", segs=8)

    # 6. Blue vertical cylindrical press/actuator unit with tall visible stroke.
    px, py = 0.38, -0.10
    press_e = Part("anim_am2_press_e", pivot=(px, py, h + 0.16))
    press_e.cyl((px, py, h + 0.16), 0.21, 0.38, "paint_am2", segs=14, bevel=0.02)
    press_e.slab(px + 0.12, py - 0.10, h - 0.02, px + 0.27, py + 0.10, h + 0.28, "paint_am2", bevel=0.015)
    press_e.cyl((px, py, h + 0.37), 0.16, 0.08, "steel_light", segs=12, bevel=0.012)
    press_e.cyl((px, py, h + 0.42), 0.09, 0.045, "copper_dull", segs=10)

    # 7. SE diagonal chrome piston rod & clevis swinging boldly beside the press.
    se_piv = (0.74, -0.56, h - 0.02)
    piston_se = Part("anim_am2_piston_se", pivot=se_piv)
    piston_se.cyl(se_piv, 0.07, 0.10, "copper_dull", segs=8)
    piston_se.tube(se_piv, (0.42, -0.18, h + 0.12), 0.04, "steel_light", segs=8)

    # 8. NE chain drive sprocket wheel.
    ne_at = (0.78, 0.58, h + 0.08)
    sprocket_ne = Part("anim_am2_sprocket_ne", pivot=ne_at)
    _gear(sprocket_ne, ne_at, 0.22, 0.085, 12, "steel_light", axis="X", yaw=-15, hub="rust_machine", spokes=4)

    # 9. Upper-north wide reciprocating crosshead carriage.
    bar_piv = (0.14, 0.90, h + 0.19)
    bar_n = Part("anim_am2_bar_n", pivot=bar_piv)
    bar_n.tube((-0.20, 0.90, h + 0.19), (0.48, 0.90, h + 0.19), 0.038, "steel_light", segs=8)
    bar_n.box((0.14, 0.90, h + 0.19), (0.18, 0.15, 0.14), "paint_am2", bevel=0.015)
    bar_n.box((0.14, 0.90, h + 0.19), (0.09, 0.17, 0.16), "steel_light", bevel=0.01)

    return [p, lamp, gear_sw1, gear_sw2, gear_c, fan_w, arm_nw, press_e, piston_se, sprocket_ne, bar_n]


@model("assembling-machine-3")
def assembling_machine_3():
    """Factorio's assembling machine 3: green riveted armor shell with front rim arch and
    tall rear corner ears, SE gantry guide frame + slamming plunger, green actuator turret,
    central horizontal gear, wide 5-blade west impeller, triple front gears, NW & NE crank arms,
    NE sprocket, and working green status light."""
    p = Part()
    h, (fx, fy, fz, fr), lamp = _am_shell(p, "paint_am3", 3)

    # Interior static density: lower idler gears, diagonal chain track, SE tall guide gantry.
    _gear(p, (-0.16, -0.44, h - 0.16), 0.18, 0.07, 10, "steel_dark")
    _gear(p, (0.34, 0.44, h - 0.02), 0.17, 0.06, 10, "steel_dark", axis="X", yaw=-15)
    _chain_track(p, (-0.22, 0.46, h + 0.10), (0.90, 0.72, h + 0.14), width=0.14, links=9)

    # SE twin vertical guide rails, anvil block, & cast housing for vertical stamping crosshead.
    p.slab(0.48, -0.82, h - 0.24, 0.98, -0.22, h - 0.02, "rust_machine", bevel=0.025)
    p.cyl((0.76, -0.34, h - 0.02), 0.14, 0.12, "steel_dark", segs=10)
    for dx in (-0.13, 0.13):
        p.beam((0.76 + dx, -0.34, h - 0.06), (0.76 + dx, -0.34, h + 0.58), 0.06, 0.06, "steel_light")
    p.box((0.76, -0.34, h + 0.60), (0.34, 0.14, 0.075), "paint_am3", bevel=0.012)
    p.cyl((0.42, 0.10, h - 0.18), 0.24, 0.34, "steel_dark", segs=12)
    p.pipe([(0.64, 0.12, h + 0.06), (0.82, 0.08, h + 0.00), (0.82, -0.14, h - 0.06)], 0.024, "hazard", segs=6)
    p.cyl((-0.78, 0.88, h + 0.06), 0.075, 0.32, "steel_dark", segs=8)
    p.cyl((0.86, 0.92, h + 0.08), 0.075, 0.34, "steel_dark", segs=8)

    # 1 & 2. Front-left twin-row heavy angled spoked gears.
    g1_at = (-0.82, -0.64, h - 0.09)
    gear_sw1 = Part("anim_am3_gear_swa", pivot=g1_at)
    _gear(gear_sw1, g1_at, 0.28, 0.12, 14, "steel_light", axis="X", yaw=-35, hub="rust_machine", spokes=5)
    _gear(gear_sw1, (-0.70, -0.56, h - 0.11), 0.23, 0.09, 10, "steel", axis="X", yaw=-35)

    g2_at = (-0.46, -0.52, h - 0.07)
    gear_sw2 = Part("anim_am3_gear_swb", pivot=g2_at)
    _gear(gear_sw2, g2_at, 0.25, 0.12, 12, "steel_light", axis="X", yaw=-35, hub="copper_dull", spokes=4)

    # 3. Prominent front-center upright spur gear peeking over the green arched rim.
    sc_at = (0.02, -0.82, h - 0.06)
    gear_sc = Part("anim_am3_gear_sc", pivot=sc_at)
    _gear(gear_sc, sc_at, 0.24, 0.09, 12, "steel_light", axis="Y", hub="copper_dull", spokes=4)

    # 4. Central horizontal spoked gear in the middle bay.
    gc_at = (-0.16, 0.18, h + 0.12)
    gear_c = Part("anim_am3_gear_c", pivot=gc_at)
    _gear(gear_c, gc_at, 0.26, 0.085, 12, "steel_light", axis="Z", hub="copper_dull", spokes=5)

    # 5. Larger 5-blade bright impeller inside the wide west bezel.
    fan_at = (fx, fy, fz)
    fan_w = Part("anim_am3_fan_w", pivot=fan_at)
    fan_w.cyl(fan_at, 0.065, 0.065, "copper_dull", segs=10)
    for k in range(5):
        a = 2 * math.pi * k / 5 + 0.2
        fan_w.beam(fan_at, (fx + (fr - 0.025) * math.cos(a), fy + (fr - 0.025) * math.sin(a), fz),
                   0.062, 0.028, "steel_light")

    # 6. Sculpted green vertical motor/press turret (bold stroke into deep cradle).
    px, py = 0.42, 0.10
    press_e = Part("anim_am3_press_e", pivot=(px, py, h + 0.20))
    press_e.cyl((px, py, h + 0.20), 0.23, 0.42, "paint_am3", segs=14, bevel=0.025)
    press_e.slab(px + 0.14, py - 0.14, h + 0.02, px + 0.30, py + 0.14, h + 0.34, "paint_am3", bevel=0.02)
    press_e.cyl((px, py, h + 0.42), 0.18, 0.085, "steel_light", segs=12, bevel=0.015)
    press_e.cyl((px, py, h + 0.47), 0.095, 0.045, "copper_dull", segs=10)
    press_e.cyl((px + 0.22, py, h + 0.18), 0.10, 0.16, "steel_dark", segs=10, axis="X")

    # 7. SE high-stroke vertical stamping crosshead & plunger sliding between twin rails.
    st_at = (0.76, -0.34, h + 0.34)
    stamp_se = Part("anim_am3_stamp_se", pivot=st_at)
    stamp_se.box(st_at, (0.30, 0.16, 0.16), "steel_light", bevel=0.015)
    stamp_se.box(st_at, (0.20, 0.18, 0.10), "paint_am3", bevel=0.01)
    stamp_se.cyl((0.76, -0.34, h + 0.16), 0.065, 0.32, "copper_dull", segs=10)

    # 8. NW slotted linkage arm.
    nw_piv = (-0.78, 0.88, h + 0.24)
    arm_nw = Part("anim_am3_arm_nw", pivot=nw_piv)
    arm_nw.cyl(nw_piv, 0.08, 0.10, "steel_dark", segs=10)
    arm_nw.beam(nw_piv, (-0.16, 0.62, h + 0.14), 0.11, 0.06, "steel_light", bevel=0.008)
    arm_nw.beam((-0.66, 0.83, h + 0.25), (-0.28, 0.67, h + 0.16), 0.04, 0.07, "steel_black")
    arm_nw.cyl((-0.16, 0.62, h + 0.14), 0.065, 0.08, "copper_dull", segs=8)

    # 9. NE heavy top crank arm with roller hub.
    ne_arm_piv = (0.86, 0.92, h + 0.28)
    arm_ne = Part("anim_am3_arm_ne", pivot=ne_arm_piv)
    arm_ne.cyl(ne_arm_piv, 0.085, 0.10, "steel_dark", segs=10)
    arm_ne.beam(ne_arm_piv, (0.26, 0.80, h + 0.20), 0.115, 0.065, "steel_light", bevel=0.008)
    arm_ne.cyl((0.26, 0.80, h + 0.20), 0.075, 0.10, "copper_dull", segs=10)

    # 10. NE diagonal drive chain sprocket wheel.
    ne_at = (0.82, 0.72, h + 0.11)
    sprocket_ne = Part("anim_am3_sprocket_ne", pivot=ne_at)
    _gear(sprocket_ne, ne_at, 0.22, 0.085, 12, "steel_light", axis="X", yaw=-15, hub="rust_machine", spokes=5)

    return [p, lamp, gear_sw1, gear_sw2, gear_sc, gear_c, fan_w, press_e, stamp_se, arm_nw, arm_ne, sprocket_ne]


# ---------------------------------------------------------------------------------------------

@model("crude-oil")
def crude_oil():
    """Factorio's crude oil patch: a glossy black stain soaked into the ground, broken ground
    and a few dark stones round its edge."""
    p = Part()
    r = rng(11)
    n = 28
    pts = []
    for i in range(n):
        a = 2 * math.pi * i / n
        rad = 0.8 + 0.15 * math.sin(3 * a + 0.5) + r.uniform(-0.08, 0.08)
        pts.append((rad * math.cos(a) * 1.05, rad * math.sin(a) * 0.95))
    p.prism(pts, 0.0, 0.004, "stone_oil")
    p.prism([(x * 0.82, y * 0.8) for x, y in pts], 0.0, 0.02, "soot_oil")
    p.prism([(x * 0.45 + 0.1, y * 0.4) for x, y in pts], 0.0, 0.026, "soot_oil")
    for k in range(9):
        a = r.uniform(0, 2 * math.pi)
        d = r.uniform(0.6, 0.92)
        s = r.uniform(0.05, 0.11)
        p.sphere((d * math.cos(a), d * math.sin(a) * 0.9, s * 0.3), s, "stone_oil", segs=7, rings=4,
                 scale=(1.0, r.uniform(0.7, 1.0), 0.6))
    return p
