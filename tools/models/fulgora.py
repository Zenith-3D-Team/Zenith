"""Fulgora: electromagnetic plant, recycler, lightning rod, lightning collector, tesla turret,
fulgoran ruins, fulgurite, scrap.

Matched to their HR sprites with compare.py like space_platform.py (zs, ys); sprite numbers in
space_sprites.py. Fulgoran machines are slate-blue and cream with copper coils; the ruins are
pale concrete and rusted iron, the ground dark purple-grey rock.
"""

import math

import bmesh
from mathutils import Matrix, Vector, noise

import detail
import kit
import oil
import space_kit
from kit import Part, R, S, T, model
from space_platform import COS_P, SIN_P, ring, ys, zs  # noqa: F401

kit.MATERIALS.update({
    "paint_fulgora_blue": ("4d6680", 0.55, 0.45, None, 0),
    "paint_fulgora_cream": ("c9c0ad", 0.6, 0.3, None, 0),
    "paint_fulgora_olive": ("5f6044", 0.6, 0.35, None, 0),   # the capsules on the plant's east side
    "paint_fulgora_screen": ("6d91a4", 0.3, 0.2, None, 0),   # its panels' pale blue screens
    "glow_green_lens": ("4f9a3a", 0.3, 0.0, "4fff4a", 0.6),
    "copper_coil": ("b0683a", 0.4, 0.9, None, 0),
    "copper_tip": ("c0703a", 0.45, 0.85, None, 0),   # the collector's tip, sampled apart from its coils

    "paint_recycler_green": ("6c7a3e", 0.65, 0.4, None, 0),
    "rust_recycler": ("7a4a2c", 0.8, 0.45, None, 0),
    "lamp_recycler": ("5cff4a", 0.3, 0.0, "40ff30", 2.0),   # its green working lamp
    "insulator_ceramic": ("ddd4c0", 0.35, 0.0, None, 0),
    "insulator_green": ("8e9c7c", 0.35, 0.1, None, 0),
    "glow_cyan": ("7fe8ff", 0.4, 0.0, "40d8ff", 2.0),
    "concrete_ruin": ("8f8a86", 0.95, 0.0, None, 0),
    "concrete_ruin_dark": ("5d5856", 0.95, 0.0, None, 0),
    "rust_ruin": ("6e4430", 0.85, 0.45, None, 0),
    "stone_fulgurite": ("6b5a68", 0.6, 0.1, None, 0),   # glassy fused rock (stone class)
    "glass_fulgurite_core": ("c8486a", 0.5, 0.0, None, 0),  # the pink inside of a broken end
    "stone_fulgora": ("4a4048", 0.95, 0.0, None, 0),
})


# ---------------------------------------------------------------------------------------------
# Electromagnetic plant.

@model("electromagnetic-plant")
def electromagnetic_plant():
    """Factorio's electromagnetic plant (4x4), at true proportions: a round plinth ringed by a fat
    ribbed rusty hose, tanks and corrugated humps on the ring at the back and sides; two thin
    slate-blue arches over an open middle, the west one rising from a boot at the south-west (with
    the copper coil column on it) along a cream strip to the stepped, louvred cream tower with the
    antenna, the east one a broad wedge from the second cream tower (the ribbed dome, the louvred
    white block) out to the east, with a cream and blue control box under it and a brass elbow and
    column below that; a blue pillar at the south-east; a brass drum lying on the ring at the
    front. In the open middle a dark turntable with a four-lobed plate and spindle, a toothed rail
    with cogs at its front edge, a grey C ring standing behind, and the copper wire ball and grey
    pods that spin while it works (anim_spin_arms). Placed from where each part shows in the
    sprite: `at` turns a sprite pixel (at 256 pixels a tile) and a height into a point."""
    p = Part()
    blue, cream = "paint_fulgora_blue", "paint_fulgora_cream"

    def at(col, row, z):
        return ((col - 650) / 256.0, (985 - row - 171.3 * z) / 256.0, z)

    def poly(points, z):
        out = [at(c, r, z)[:2] for c, r in points]
        area = sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(out, out[1:] + out[:1]))
        return out if area > 0 else out[::-1]   # prism wants them counter-clockwise

    def hose(radius, z, a0, a1, r, steps):
        pts = [(ring_c[0] + radius * math.cos(math.radians(a0 + (a1 - a0) * k / steps)),
                ring_c[1] + radius * math.sin(math.radians(a0 + (a1 - a0) * k / steps)), z) for k in range(steps + 1)]
        space_kit.hose(p, pts, r, "rust_brown", segs=8, rib=0.21, depth=0.17, smooth=3)

    ring_c = (0.06, -0.05)
    tt = (-0.04, -0.58)   # the turntable's centre
    # The plinth, and the hose round it: one fat corrugated ring, a second loop at the back.
    p.cyl((*ring_c, 0.05), 1.66, 0.1, "steel_black", segs=40)
    p.cyl((*tt, 0.16), 1.2, 0.12, "steel_dark", segs=32)
    hose(1.62, 0.2, 0, 360, 0.2, 40)
    hose(1.56, 0.5, 15, 75, 0.16, 10)
    for a in (205, 240, 300, 330):
        t = math.radians(a)
        p.box((ring_c[0] + 1.62 * math.cos(t), ring_c[1] + 1.62 * math.sin(t), 0.24), (0.07, 0.46, 0.46), "steel_dark",
              rz=a + 90)
    # Round the ring: the south-west pots and strap, the west brass tanks, the blue ribbed fan,
    # the corrugated hump at the back west, the riser at the back east, the olive capsules east.
    for col, row, r in ((262, 1250, 0.2), (325, 1282, 0.17)):
        x, y, z = at(col, row, 0.52)
        p.cyl((x, y, 0.32), r, 0.5, "rust_brown", segs=14, radius_top=r * 0.9, bevel=0.03)
        p.cyl((x, y, 0.58), r * 0.82, 0.05, "steel", segs=14)
    p.beam(at(290, 1320, 0.42), at(395, 1400, 0.3), 0.1, 0.05, "steel_dark")
    for col, row, z, r in ((282, 815, 0.75, 0.31), (262, 950, 0.55, 0.26)):
        x, y, _ = at(col, row, z)
        p.cyl((x, y, z / 2), r, z, "brass", segs=18, bevel=0.03)
        p.cyl((x, y, z + 0.02), r * 0.8, 0.06, "steel_dark", segs=18)
        detail.gear(p, (x, y), r * 0.55, z + 0.03, z + 0.08, "steel", teeth=10, segs=12)
    fan = Part()
    for k in range(5):
        fan.ring_band((0, 0), 0.1 + 0.085 * k, 0.15 + 0.085 * k, 0.0, 0.1 + 0.02 * k, 90, 180, blue, segs=8)
    p.add_part(fan, T(*at(335, 725, 0.5)))
    hump = Part()
    hump.cyl((0, 0, 0), 0.26, 0.7, "rust_brown", segs=12, axis="X")
    for k in range(8):
        hump.cyl((-0.31 + k * 0.088, 0, 0), 0.28, 0.045, "steel_dark", segs=12, axis="X")
    p.add_part(hump, T(*at(305, 590, 0.36)) @ R("Z", 12))
    p.prism(poly([(215, 620), (235, 545), (390, 510), (410, 580)], 0.1), 0.0, 0.1, "steel_dark")
    x, y, _ = at(1020, 560, 0.45)
    p.cyl((x, y, 0.28), 0.3, 0.56, "steel", segs=14, radius_top=0.14, bevel=0.03)
    p.beam((x, y, 0.5), (x + 0.2, y + 0.05, 0.72), 0.09, 0.09, "steel_dark")
    for row0, row1, r in ((770, 1010, 0.2),):
        a, b = at(1085, row0, 0.32), at(1085, row1, 0.32)
        p.tube(a, b, r, "paint_fulgora_olive", segs=14)
        p.sphere(a, r, "paint_fulgora_olive", segs=12, rings=6)
        p.sphere(b, r, "paint_fulgora_olive", segs=12, rings=6)
        for t in (0.25, 0.75):
            c = tuple(a[i] + (b[i] - a[i]) * t for i in range(3))
            p.cyl(c, r + 0.02, 0.05, "steel_dark", segs=14, axis="Y")
    # The turntable: a cone under a plate with four lobes cut round its hub, the spindle.
    p.cyl((*tt, 0.28), 0.78, 0.14, "steel_black", segs=28)
    p.cyl((*tt, 0.38), 0.62, 0.05, "steel_dark", segs=28)
    for a in (45, 135, 225, 315):
        t = math.radians(a)
        c = (tt[0] + 0.3 * math.cos(t), tt[1] + 0.3 * math.sin(t))
        p.box((*c, 0.42), (0.34, 0.2, 0.04), "steel", rz=a + 90)
        p.cyl((*c, 0.45), 0.09, 0.03, "grime", segs=10)
    detail.gear(p, tt, 0.26, 0.42, 0.48, "steel_dark", teeth=10, segs=16, hub="steel")
    p.cyl((*tt, 1.02), 0.05, 1.1, "steel", segs=10)
    p.cyl((*tt, 1.5), 0.08, 0.08, "steel_light", segs=10)
    # The toothed rail at its front and the cogs on it.
    rail = Part()
    rail.ring_band((0, 0), 0.8, 0.92, 0.46, 0.54, 205, 335, "steel_light", segs=16)
    rail.ring_band((0, 0), 0.92, 1.02, 0.3, 0.42, 200, 340, "steel_dark", segs=16)
    for k in range(10):
        a = math.radians(208 + 124 * k / 9)
        rail.cyl((0.86 * math.cos(a), 0.86 * math.sin(a), 0.55), 0.02, 0.02, "steel_black", segs=6)
    p.add_part(rail, T(*tt, 0))
    for a, r in ((228, 0.13), (252, 0.15), (288, 0.15), (312, 0.13)):
        t = math.radians(a)
        c = (tt[0] + 0.66 * math.cos(t), tt[1] + 0.66 * math.sin(t))
        detail.gear(p, c, r, 0.46, 0.66, "steel", teeth=7, hub="steel_dark", segs=10)
    # The grey C ring behind the spindle, tilted to the camera, its bolts and hinge.
    arch = Part()
    arch.ring_band((0, 0), 0.52, 0.64, -0.05, 0.05, 80, 275, "steel", segs=18)
    arch.ring_band((0, 0), 0.47, 0.52, -0.03, 0.03, 80, 275, "steel_dark", segs=18)
    for k in range(7):
        a = math.radians(92 + 170 * k / 6)
        arch.cyl((0.58 * math.cos(a), 0.58 * math.sin(a), 0.06), 0.025, 0.02, "steel_light", segs=6)
    p.add_part(arch, T(*at(640, 860, 1.05)) @ R("X", 62))
    # West: the boot, its coil column, the arm rising from it, the cream strip along it.
    boot = [(268, 1085), (345, 955), (470, 965), (522, 1115), (415, 1195), (345, 1160)]
    p.prism(poly(boot, 0.85), 0.0, 0.85, blue)
    p.prism(poly([(c + 12, r + 8) for c, r in boot], 0.86), 0.85, 0.87, blue)
    detail.rivet_line(p, at(300, 1090, 0.875), at(360, 985, 0.875), 5, "Z", mat="rust_brown")
    detail.rivet_line(p, at(375, 1165, 0.875), at(495, 1105, 0.875), 6, "Z", mat="rust_brown")
    detail.rivet_line(p, at(365, 975, 0.875), at(465, 982, 0.875), 5, "Z", mat="rust_brown")
    p.slab(*at(462, 1040, 0.875)[:2], 0.87, *(c + 0.05 for c in at(470, 1075, 0.875)[:2]), 0.875, "grime")
    x, y, _ = at(400, 1180, 0.4)
    p.slab(x - 0.17, y - 0.23, 0.0, x + 0.17, y + 0.2, 0.75, blue, bevel=0.03)
    detail.rivet_line(p, (x - 0.13, y - 0.24, 0.65), (x + 0.13, y - 0.24, 0.65), 4, "Y")
    p.slab(x - 0.05, y - 0.25, 0.25, x + 0.05, y - 0.23, 0.5, "grime")
    p.sphere(at(265, 1090, 0.62), 0.18, "steel", segs=12, rings=6)
    colx, coly = at(405, 1000, 1.0)[:2]
    p.cyl((colx, coly, 1.02), 0.17, 0.36, "rust_brown", segs=14, radius_top=0.14, bevel=0.02)
    for z in (0.92, 1.05, 1.18):
        p.cyl((colx, coly, z), 0.185, 0.03, "steel_dark", segs=14)
    p.cyl((colx, coly, 1.45), 0.17, 0.5, blue, segs=14, radius_top=0.07, bevel=0.02)
    p.cyl((colx, coly, 1.74), 0.08, 0.1, "steel_dark", segs=10)
    detail.coil(p, (colx, coly), 0.1, 1.8, 2.08, "copper_coil", wire=0.024)
    p.cyl((colx, coly, 2.14), 0.13, 0.08, "steel_light", segs=12, bevel=0.015)
    wa, wb = at(440, 790, 1.05), at(500, 640, 1.2)
    p.beam(wa, wb, 0.42, 0.34, blue, bevel=0.04)
    p.beam(at(388, 845, 1.05), wa, 0.2, 0.22, blue, bevel=0.03)
    p.cyl(at(430, 715, 1.42), 0.14, 0.18, "steel", segs=12, bevel=0.02)
    p.sphere(at(430, 712, 1.55), 0.1, blue, segs=10, rings=5)
    sa, sb = at(325, 835, 1.15), at(470, 525, 1.5)
    p.beam(sa, sb, 0.13, 0.12, cream, bevel=0.03)
    d_ = Vector(sb) - Vector(sa)
    for k in range(5):
        c = Vector(sa) + d_ * (0.15 + 0.17 * k)
        p.slab(c.x - 0.06, c.y - 0.05, c.z + 0.08, c.x + 0.06, c.y + 0.05, c.z + 0.1, "steel_dark")
    detail.cable(p, [at(345, 690, 1.15), at(312, 738, 1.05), at(332, 775, 1.0)], 0.022, "wire_yellow")
    detail.cable(p, [at(355, 625, 1.25), at(345, 650, 1.1), at(362, 682, 1.1)], 0.018, "wire_red")
    detail.cable(p, [at(450, 545, 1.5), at(455, 590, 1.35), at(470, 605, 1.3)], 0.02, "wire_green")
    # The west tower: cream frame, dark bays, the stack of louvres, the top and antenna.
    tx0, tx1 = (490 - 650) / 256.0, (640 - 650) / 256.0
    ty0, ty1 = 0.72, 1.05
    p.slab(tx0, ty0, 0.3, tx1, ty1, 1.68, "steel_dark")
    p.slab(tx0 - 0.02, ty0 - 0.02, 0.3, tx1 + 0.02, ty1, 0.72, blue, bevel=0.03)
    p.slab(tx0 - 0.03, ty0 - 0.03, 0.72, tx0 + 0.13, ty0 + 0.12, 1.72, cream, bevel=0.02)
    detail.slots(p, (tx0, ty0 + 0.1, 0.8), (tx0, ty1 - 0.04, 1.6), "-x", 5, along=1)
    for z in (0.9, 1.11, 1.32, 1.53):
        p.slab(tx1 - 0.2, ty0 - 0.04, z - 0.08, tx1 + 0.04, ty1, z + 0.07, cream, bevel=0.02)
        p.slab(tx1 - 0.2, ty0 - 0.05, z - 0.12, tx1 + 0.04, ty1, z - 0.08, "steel_dark")
    for z in (0.98, 1.2, 1.42):
        p.cyl((tx0 + 0.26, ty0 - 0.05, z), 0.07, 0.04, "steel_black", segs=10, axis="Y")
    p.slab(tx0 - 0.03, ty0 - 0.03, 1.66, tx1 + 0.04, ty1, 1.74, cream, bevel=0.02)
    p.slab(tx0 + 0.14, ty0 + 0.08, 1.72, tx1 - 0.14, ty1 - 0.06, 1.82, "steel_dark", bevel=0.02)
    ax, ay = (565 - 650) / 256.0, 0.9
    for a, b in (((ax, ay, 1.8), (ax - 0.02, ay, 2.42)), ((ax - 0.02, ay, 2.42), (ax + 0.05, ay, 2.52)),
                 ((ax + 0.05, ay, 2.52), (ax + 0.02, ay, 2.74)), ((ax - 0.04, ay, 2.42), (ax - 0.07, ay, 2.98)),
                 ((ax + 0.07, ay, 2.3), (ax + 0.1, ay, 2.72))):
        p.beam(a, b, 0.032, 0.032, "rust_brown")
    p.beam(at(470, 450, 1.86), at(505, 415, 1.92), 0.08, 0.08, "steel_dark", bevel=0.01)
    # The second tower with its dome, the louvred white block on its east.
    bx0, bx1 = 0.0, 0.46
    p.slab(bx0, 0.66, 0.3, bx1, 0.95, 1.56, cream, bevel=0.03)
    p.slab(bx0 - 0.02, 0.64, 0.3, bx1 + 0.02, 0.95, 0.74, blue, bevel=0.03)
    p.slab(bx0 + 0.14, 0.63, 0.86, bx1 - 0.02, 0.67, 1.4, "grime")
    detail.rivet_line(p, (bx0 + 0.05, 0.655, 0.86), (bx0 + 0.05, 0.655, 1.5), 6, "Y", mat="rust_brown")
    detail.spring(p, at(722, 650, 1.1), at(698, 548, 1.5), 0.05, "wire_yellow", turns=8, wire=0.018)
    dome = (0.28, 0.8, 1.78)
    p.cyl((dome[0], dome[1], 1.58), 0.11, 0.1, "steel_dark", segs=12)
    p.sphere(dome, 0.21, "steel_light", segs=16, rings=8)
    for ax_ in ("Z", "X", "Y"):
        p.cyl(dome, 0.215, 0.025, "steel_dark", segs=16, axis=ax_, caps=False)
    block = Part()
    block.slab(-0.27, -0.2, 0.0, 0.27, 0.2, 0.3, cream, bevel=0.03)
    block.slab(-0.2, -0.13, 0.3, 0.2, 0.13, 0.31, "steel_black")
    for k in range(5):
        block.slab(-0.19 + k * 0.08, -0.12, 0.3, -0.14 + k * 0.08, 0.12, 0.325, "steel")
    p.add_part(block, T(*at(805, 590, 1.25)) @ R("Z", -16) @ R("X", 8))
    # East: the broad wedge, its screen, its back rim and red cable, the motors set into it.
    top = 1.3
    wedge = [(698, 672), (830, 600), (1085, 722), (1065, 815), (1000, 900), (715, 805)]
    p.prism(poly(wedge, top), top - 0.38, top, blue, bevel=0.03)
    p.prism(poly([(835, 605), (1080, 725), (1060, 760), (850, 650)], top + 0.04), top, top + 0.04, "steel_black")
    for c0, r0, c1, r1 in ((885, 695, 985, 745),):
        m = T(*at((c0 + c1) / 2, (r0 + r1) / 2, top + 0.13)) @ R("Z", -24)
        for k, (xc, r_) in enumerate(((-0.18, 0.13), (0.02, 0.11), (0.2, 0.09))):
            p.cyl((xc, 0, 0), r_, 0.2, "steel" if k != 1 else "steel_light", segs=12, axis="X", matrix=m)
    panel = [(800, 700), (915, 755), (890, 790), (795, 735)]
    p.prism(poly(panel, top), top, top + 0.015, "paint_fulgora_screen")
    p.prism(poly([(c - 12, r + 62) for c, r in panel], top), top, top + 0.012, "steel_dark")
    detail.rivet_line(p, at(720, 802, top + 0.005), at(990, 895, top + 0.005), 9, "Z")
    detail.cable(p, [at(810, 633, top + 0.08), at(880, 640, top + 0.1), at(905, 618, top + 0.1), at(1015, 680, top + 0.1)],
                 0.02, "wire_red")
    detail.cable(p, [at(860, 690, top + 0.1), at(910, 740, top + 0.14), at(975, 765, top + 0.1)], 0.018, "wire_yellow")
    # The wedge's east foot, then under it the control box, the brass elbow and column.
    x, y, _ = at(1000, 960, 0.5)
    p.slab(x - 0.2, y - 0.2, 0.0, x + 0.2, y + 0.3, top - 0.3, blue, bevel=0.03)
    box0, box1 = 0.3, 0.96
    p.slab(box0, -0.34, 0.62, box1, 0.14, 1.0, blue, bevel=0.03)
    p.slab(box0 - 0.02, -0.36, 0.84, box0 + 0.34, 0.14, 1.02, cream, bevel=0.02)
    p.slab(box0 + 0.03, -0.37, 0.66, box0 + 0.22, -0.34, 0.8, "grime")
    p.slab(box0 + 0.1, -0.385, 0.68, box0 + 0.15, -0.37, 0.78, "glow_green_lens")
    p.slab(box1 - 0.22, -0.36, 0.78, box1 - 0.08, -0.34, 0.92, cream)
    p.sphere((box1 + 0.14, -0.1, 0.8), 0.17, "steel", segs=12, rings=6)
    cx_, cy_ = (820 - 650) / 256.0, -0.96
    p.cyl((cx_, cy_, 0.32), 0.17, 0.64, "brass", segs=16, radius_top=0.15, bevel=0.02)
    for z in (0.08, 0.66, 0.74):
        p.cyl((cx_, cy_, z), 0.2, 0.05, "steel_dark", segs=16)
    p.cyl((cx_, cy_, 0.78), 0.12, 0.14, "steel", segs=12)
    space_kit.bent(p, [(cx_, cy_, 0.84), (cx_ - 0.02, cy_ + 0.08, 1.02), (cx_ + 0.34, cy_ + 0.1, 1.06),
                       (cx_ + 0.62, cy_ + 0.3, 0.98), (cx_ + 0.68, cy_ + 0.5, 0.82)], 0.13, "brass", segs=12)
    space_kit.bent(p, [(box0 + 0.1, -0.42, 0.66), (box0 + 0.08, -0.6, 0.72), (cx_ - 0.04, cy_ + 0.12, 0.95)], 0.1, "brass",
                   segs=10)
    p.cyl((cx_ + 0.42, cy_ + 0.12, 1.06), 0.16, 0.05, "steel_dark", segs=12, axis="X")
    # South-east: the blue pillar on its plate, its screen, the insulator on top.
    p.prism(poly([(820, 1405), (880, 1362), (1075, 1362), (1085, 1408), (1050, 1445), (850, 1445)], 0.05), 0.0, 0.08,
            "steel_dark")
    p.slab(0.94, -1.72, 0.05, 1.56, -1.14, 0.72, blue, bevel=0.04)
    detail.panel(p, (0.94, -1.72, 0.05), (1.56, -1.14, 0.72), "-y", blue, margin=0.08, rivet="steel_light")
    p.slab(0.98, -1.58, 0.72, 1.5, -1.16, 1.32, blue, bevel=0.04)
    detail.panel(p, (0.98, -1.58, 0.72), (1.5, -1.16, 1.32), "-y", blue, margin=0.08, rivet="steel_light")
    p.slab(1.2, -1.74, 0.2, 1.48, -1.72, 0.5, "steel_black")
    p.slab(1.24, -1.75, 0.24, 1.44, -1.74, 0.46, "paint_fulgora_screen")
    p.slab(0.98, -1.5, 1.32, 1.5, -1.16, 1.38, "steel_dark", bevel=0.01)
    p.cyl((1.15, -1.4, 1.46), 0.15, 0.16, "steel_light", segs=12, bevel=0.02)
    p.cyl((1.15, -1.4, 1.6), 0.1, 0.12, "ceramic", segs=12)
    p.sphere((1.15, -1.4, 1.7), 0.06, "steel_light", segs=8, rings=4)
    # Front: the brass drum lying in the hose ring, banded and capped.
    x, y, z = at(630, 1405, 0.27)
    detail.ribbed_drum(p, (x, y, z), 0.225, 0.84, "brass", "steel_dark", ribs=2)
    for dx in (-0.43, 0.43):
        p.cyl((x + dx, y, z), 0.235, 0.04, "steel_dark", segs=14, axis="X")
    # The wire ball and pods, turning round the spindle.
    cx, cy = tt
    coil = Part("anim_spin_arms", pivot=(cx, cy, 0.0))
    detail.cage(coil, (cx, cy, 1.36), 0.21, "copper_coil", rings=4, segs=12)
    coil.cyl((cx, cy, 1.36), 0.06, 0.26, "copper_coil", segs=10)
    for k in range(3):
        a = 2 * math.pi * k / 3
        ex, ey = cx + 0.36 * math.cos(a), cy + 0.36 * math.sin(a)
        coil.beam((cx, cy, 1.12), (ex, ey, 1.08), 0.05, 0.05, "steel_dark")
        coil.sphere((ex, ey, 1.08), 0.13, "steel", segs=12, rings=6)
    for z in (0.96, 1.16):
        coil.cyl((cx, cy, z), 0.11, 0.04, "steel_dark", segs=12)
    return [p, coil]


# ---------------------------------------------------------------------------------------------
# Recycler.

@model("recycler")
def recycler():
    """Factorio's recycler (2x4): a long rusty frame painted lichen-green with hazard stripes: a
    tall housing down the west side, an open hopper with rollers in the middle under a green
    plate, a motor panel at the back left, a stout column behind the hopper, the funnel (the
    input) rising from a rusty bulb at the back right, a ribbed drum and a domed pot at the
    front. Sizes fitted to the four direction sprites' outlines at once.

    Moving parts, from Factorio's 64-frame loop at speed 4 (0.27 s): the ribbed drum drops to open
    the bin and comes back up (`anim_slide_recycler_drum`), the motor panel at the back jolts up
    and down (`anim_slide_recycler_panel`), the hopper's three toothed rollers turn
    (`anim_roll_recycler`, one turn every four loops) and the green lamp is lit while it works
    (`anim_glow_recycler_lamp`)."""
    p = Part()
    p.slab(-0.94, -1.98, 0.0, 0.95, 2.02, 0.14, "rust_recycler", bevel=0.03)
    # The west housing with its pipe, the east wall with its spring, the hopper between.
    p.slab(-1.02, -1.23, 0.0, -0.54, 1.71, 0.83, "paint_recycler_green", bevel=0.05)
    for face in ("-x", "+x"):
        detail.stripes(p, (-1.02, -1.23, 0.62), (-0.54, 1.71, 0.8), face, 16)
    detail.panel(p, (-1.02, -1.23, 0.0), (-0.54, 1.71, 0.62), "-x", "paint_recycler_green", split=3,
                 rivet="steel_light")
    detail.slots(p, (-1.02, -1.23, 0.0), (-0.54, -0.5, 0.6), "-y", 3)
    p.cyl((-0.79, 0.32, 0.154), 0.088, 2.3, "copper_dull", segs=8, axis="Y")
    p.slab(0.25, -0.89, 0.0, 1.04, 0.54, 0.56, "paint_recycler_green", bevel=0.04)
    detail.panel(p, (0.25, -0.89, 0.0), (1.04, 0.54, 0.56), "+x", "paint_recycler_green", split=2,
                 rivet="steel_light")
    for y in (-0.75, 0.35):   # the east wall's springs
        detail.spring(p, (0.99, y, 0.12), (0.99, y, 0.5), 0.065, "rust_recycler", turns=6)
    p.cyl((0.999, -0.55, 0.088), 0.088, 2.28, "copper_dull", segs=8, axis="Y")
    for k in range(10):
        p.cyl((1.0, -1.6 + k * 0.22, 0.09), 0.1, 0.05, "rust_recycler", segs=8, axis="Y")
    # The open hopper: a green frame round a dark well with shredder rollers and bars, a plate
    # over the drum's end of it.
    p.slab(-0.65, -1.4, 0.43, 0.87, -0.06, 0.6, "soot")
    for y0, y1 in ((-1.4, -1.3), (-0.16, -0.06)):
        p.slab(-0.65, y0, 0.43, 0.87, y1, 1.18, "paint_recycler_green", bevel=0.03)
    for x0, x1 in ((-0.65, -0.55), (0.77, 0.87)):
        p.slab(x0, -1.4, 0.43, x1, -0.06, 1.18, "paint_recycler_green", bevel=0.03)
    rollers = []
    for y in (-1.0, -0.75, -0.5):
        roll = Part("anim_roll_recycler", pivot=(0.1, y, 0.75))
        roll.cyl((0.1, y, 0.75), 0.11, 1.3, "steel_dark", segs=10, axis="X")
        for k in range(4):  # shredder teeth, so the turning shows
            a = k * 90 + (45 if y == -0.75 else 0)
            for x in (-0.35, 0.1, 0.55):
                roll.box((0, 0, 0.12), (0.08, 0.05, 0.05), "steel_light",
                         matrix=T(x, y, 0.75) @ R("X", a))
        rollers.append(roll)
    for y in (-0.62, -0.38):
        p.cyl((0.1, y, 1.1), 0.025, 1.4, "steel_light", segs=6, axis="X")
    p.slab(-0.15, -1.4, 1.06, 0.87, -0.9, 1.2, "paint_recycler_green", bevel=0.03)
    detail.stripes(p, (-0.15, -1.4, 1.06), (0.87, -0.9, 1.2), "-y", 7)
    detail.rivet_line(p, (-0.1, -1.15, 1.205), (0.82, -1.15, 1.205), 6, "Z")
    p.slab(-0.57, -0.41, 0.42, 0.24, 0.02, 0.83, "soot")
    p.slab(-0.36, -0.56, 0.78, -0.14, -0.27, 1.74, "paint_recycler_green", bevel=0.03)
    # Back: the motor panel and its drum, the column behind the hopper, the funnel on its bulb.
    panel = Part("anim_slide_recycler_panel", pivot=(-0.43, 1.5, 1.2))
    panel.slab(-0.88, 1.57, 0.91, 0.02, 1.68, 1.46, "paint_recycler_green", bevel=0.03)
    detail.stripes(panel, (-0.88, 1.57, 1.33), (0.02, 1.68, 1.46), "+y", 7)
    detail.stripes(panel, (-0.88, 1.57, 1.33), (0.02, 1.68, 1.46), "+z", 7)
    panel.cyl((-0.03, 1.29, 1.12), 0.11, 1.08, "steel_dark", segs=10, axis="X")
    p.slab(-0.24, 0.46, 0.15, 0.01, 0.51, 0.96, "rust_recycler")
    # The motor box behind the hopper: a green housing with a roller on top, its windings and
    # the blue and red cables over it.
    p.slab(-0.84, 0.22, 0.4, -0.06, 1.0, 1.42, "paint_recycler_green", bevel=0.04)
    detail.panel(p, (-0.84, 0.22, 0.4), (-0.06, 1.0, 1.42), "-y", "paint_recycler_green", rivet="steel_light")
    detail.slots(p, (-0.84, 0.22, 0.4), (-0.06, 1.0, 1.42), "-x", 4)
    p.cyl((-0.45, 0.62, 1.55), 0.17, 0.74, "steel_dark", segs=12, axis="X")
    for x in (-0.72, -0.18):
        p.cyl((x, 0.62, 1.55), 0.2, 0.06, "rust_recycler", segs=12, axis="X")
    detail.coil(p, (-0.45, 0.62), 0.12, 1.75, 2.0, "copper_coil", turns=3)
    p.cyl((-0.45, 0.62, 1.86), 0.1, 0.4, "steel_dark", segs=8)
    detail.cable(p, [(-0.8, 0.3, 1.43), (-0.6, 0.15, 1.6), (-0.2, 0.2, 1.62), (0.05, 0.4, 1.3)], 0.022, "wire_blue")
    detail.cable(p, [(-0.7, 0.95, 1.43), (-0.4, 1.0, 1.66), (-0.1, 0.9, 1.6), (0.2, 1.05, 1.2)], 0.02, "wire_red")
    detail.cable(p, [(-0.9, 0.0, 0.9), (-0.95, 0.35, 1.2), (-0.8, 0.7, 1.45)], 0.022, "wire_blue")
    # The chain over the hopper's back end: a sprocket each side and the links sagging between.
    for x in (-0.5, 0.72):
        oil.toothed(p, x, 0.08, 1.12, 0.14, "steel_dark")
    for k in range(13):
        t = k / 12
        x = -0.5 + 1.22 * t
        z = 1.0 - 0.28 * math.sin(math.pi * t)
        p.box((x, 0.08, z), (0.06, 0.08, 0.07), "steel", rz=0)

    p.cyl((0.29, 1.21, 0.28), 0.49, 0.56, "rust_recycler", segs=18, radius_top=0.63, bevel=0.03)
    p.cyl((0.25, 1.32, 0.78), 0.635, 0.79, "rust_recycler", segs=18, radius_top=0.3)
    p.cyl((0.53, 1.335, 1.75), 0.24, 1.31, "paint_recycler_green", segs=16, radius_top=0.195)
    for k in range(4):   # straps down the funnel
        a = math.radians(45 + 90 * k)
        p.beam((0.53 + 0.245 * math.cos(a), 1.335 + 0.245 * math.sin(a), 1.12),
               (0.53 + 0.2 * math.cos(a), 1.335 + 0.2 * math.sin(a), 2.3), 0.05, 0.03, "rust_recycler",
               up=(math.cos(a), math.sin(a), 0))
    detail.cable(p, [(0.25, 1.0, 1.3), (0.45, 1.05, 1.45), (0.75, 1.1, 1.4)], 0.02, "wire_blue")
    p.cyl((0.85, 1.05, 1.0), 0.12, 0.04, "grime", segs=12, axis="Y")   # the bulb's round gauge
    ring(p, (0.53, 1.335), 0.12, 0.22, 2.36, 2.44, "brass", segs=16)
    p.cyl((0.53, 1.335, 2.4), 0.12, 0.02, "soot", segs=12)
    lamp = Part("anim_glow_recycler_lamp")  # the green lamp on the bulb's west side
    lamp.sphere((-0.2, 1.25, 1.0), 0.07, "lamp_recycler", segs=8, rings=4)
    # Front: the ribbed drum on its frame and the domed pot.
    drum = Part("anim_slide_recycler_drum", pivot=(0.23, -1.45, 0.72))
    drum.cyl((0.23, -1.45, 0.72), 0.485, 0.78, "steel_platform", segs=20, axis="X", bevel=0.03)
    for k in range(5):
        drum.cyl((-0.1 + k * 0.165, -1.45, 0.72), 0.505, 0.05, "steel_dark", segs=20, axis="X")
    p.slab(0.08, -1.55, 0.0, 0.3, -1.01, 0.35, "rust_recycler")
    p.slab(0.22, -1.86, 0.0, 0.94, -1.51, 0.54, "rust_recycler", bevel=0.03)
    detail.stripes(p, (0.22, -1.86, 0.36), (0.94, -1.51, 0.52), "-y", 6)
    p.cyl((-0.607, -1.463, 0.55), 0.445, 1.1, "rust_recycler", segs=16, radius_top=0.32, bevel=0.03)
    p.sphere((-0.54, -1.51, 1.11), 0.283, "rust_recycler", segs=14, rings=7)
    p.cyl((-0.54, -1.51, 1.4), 0.07, 0.1, "steel_light", segs=8)
    for z in (0.3, 0.75):
        p.cyl((-0.607, -1.463, z), 0.457 - 0.125 * z / 1.1, 0.05, "steel_dark", segs=16)
    p.slab(-0.82, -1.93, 0.25, -0.42, -1.9, 0.55, "grime")   # the pot's label plate
    detail.cable(p, [(-0.3, -1.6, 1.0), (-0.1, -1.7, 0.75), (0.05, -1.55, 0.5)], 0.02, "wire_red")
    return [p, drum, panel, lamp] + rollers



# ---------------------------------------------------------------------------------------------
# Lightning rod and lightning collector.

def insulator_mast(p, x, y, z0, z1, discs, r_disc=0.15, tip=0.9):
    """A thin mast with a stack of ceramic insulator discs and a copper tip on top."""
    p.cyl((x, y, (z0 + z1) / 2), 0.05, z1 - z0, "steel_dark", segs=8)
    for z in discs:
        p.cyl((x, y, z), r_disc, 0.06, "insulator_ceramic", segs=14, bevel=0.02)
        p.cyl((x, y, z - 0.06), r_disc * 0.6, 0.06, "insulator_ceramic", segs=12)
    p.cyl((x, y, z1 + tip / 2), 0.045, tip, "copper_tip", segs=8, radius_top=0.02)


@model("lightning-rod")
def lightning_rod():
    """Factorio's lightning rod (1x1): low boxes of cabling round the foot, a dark drum with a
    green dome on top and a cyan charge gauge in front, a cage of four posts with blue
    insulators and white balls, arms curving up to a collar, then a thin mast wound with a blue
    cable, four ceramic insulator discs and a long copper tip."""
    p = Part()
    p.slab(-0.45, -0.15, 0.0, 0.4, 0.4, 0.12, "steel_dark", bevel=0.02)
    p.slab(-0.5, -0.27, 0.0, -0.08, 0.25, 0.26, "steel_dark", bevel=0.03)
    p.slab(0.12, -0.26, 0.0, 0.3, 0.25, 0.22, "steel_dark", bevel=0.03)
    for x, c in ((-0.38, "copper_coil"), (-0.22, "insulator_ceramic"), (-0.3, "paint_fulgora_blue")):
        p.pipe([(x, -0.2, 0.26), (x + 0.05, -0.28, 0.45), (x + 0.12, -0.22, 0.7)], 0.03, c, segs=6)
    p.pipe([(-0.35, -0.1, 0.3), (-0.62, -0.15, 0.55), (-0.55, -0.2, 0.85), (-0.35, -0.25, 0.95)], 0.04, "insulator_green",
           segs=6)
    p.cyl((-0.03, 0.05, 0.62), 0.42, 0.84, "steel_dark", segs=20, bevel=0.03)
    ring(p, (-0.03, 0.05), 0.34, 0.45, 0.92, 1.08, "steel_light", segs=20)
    p.sphere((0, 0.1, 1.12), 0.2, "insulator_green", segs=12, rings=6)
    p.slab(0.08, -0.47, 0.2, 0.32, -0.3, 1.5, "steel_dark", bevel=0.03)
    p.slab(0.13, -0.49, 0.85, 0.27, -0.47, 1.45, "glow_cyan")
    p.cyl((0.42, -0.1, 1.15), 0.07, 0.4, "paint_fulgora_blue", segs=8)
    # The cage: four posts tied by a ring, arms curving up to the mast's collar.
    posts = [(-0.52, 0.3), (0.42, 0.3), (0.25, -0.3), (-0.35, -0.3)]
    for k, (x, y) in enumerate(posts):
        p.tube((x, y, 1.55), (x, y, 2.18), 0.04, "steel_dark", segs=6)
        p.cyl((x, y, 2.05), 0.065, 0.22, "paint_fulgora_blue", segs=8)
        p.sphere((x, y, 2.25 - 0.12 * (x < -0.5)), 0.075, "insulator_ceramic", segs=8, rings=4)
        nx, ny = posts[(k + 1) % 4]
        p.beam((x, y, 1.82), (nx, ny, 1.82), 0.07, 0.14, "steel_dark")
        p.pipe([(x, y, 1.75), (x * (0.4 if x > 0 else 0.1), y * 0.3, 2.45), (0.0, 0.0, 3.2)], 0.035, "steel_dark", segs=6)
    p.cyl((0, 0, 3.1), 0.07, 3.6, "steel_dark", segs=8)
    p.cyl((0, 0, 3.3), 0.13, 0.18, "insulator_ceramic", segs=12, bevel=0.02)
    p.pipe([(0.08 * math.cos(math.radians(120 * k)) - 0.03, 0.08 * math.sin(math.radians(120 * k)), 3.35 + 0.18 * k)
            for k in range(9)], 0.03, "paint_fulgora_blue", segs=6)
    for z in (4.98, 5.22, 5.46, 5.7):
        p.cyl((0, 0, z), 0.11, 0.07, "insulator_ceramic", segs=14, bevel=0.02)
        p.cyl((0, 0, z - 0.07), 0.07, 0.07, "insulator_ceramic", segs=10)
    p.cyl((0, 0, 6.55), 0.045, 1.5, "copper_coil", segs=8, radius_top=0.03)
    return [p, strike_sparks(0.0, 7.3, (0.82, 0.42), seed=1, tip_arcs=3, base_arcs=3)]


def strike_sparks(x, tip_z, base, seed, tip_arcs=5, base_arcs=6):
    """What a strike lights on a lightning attractor (its charge and discharge sheets: sparks at
    the tip and round the foot, the copper glowing): arcs down from the tip, a ring of short arcs
    about `base` = (height, radius). Shown only after a strike there (anim_lit_strike, anim.gd)."""
    q = Part("anim_lit_strike")
    for k in range(tip_arcs):
        a = math.radians(360 / tip_arcs * k + 20)
        kit.arc(q, (x, 0, tip_z), (x + 0.32 * math.cos(a), 0.32 * math.sin(a), tip_z - 0.9), seed=seed * 100 + k,
                kinks=4, jitter=0.07, width=0.02)
    z, r = base
    for k in range(base_arcs):
        a0, a1 = math.radians(360 / base_arcs * k), math.radians(360 / base_arcs * k + 40)
        kit.arc(q, (x + r * math.cos(a0), r * math.sin(a0), z), (x + r * math.cos(a1), r * math.sin(a1), z + 0.25),
                seed=seed * 100 + 10 + k, kinks=3, jitter=0.06, width=0.02)
    q.cyl((x, 0, tip_z - 0.4), 0.06, 0.8, "arc_blue", segs=8, radius_top=0.035)
    return q


@model("lightning-collector")
def lightning_collector():
    """Factorio's lightning collector (2x2): a round domed cage of dark ribs over blue tanks,
    coils and cables, with a grille and foot pads at the front; a column of struts and cables
    rising from it to a cream capsule with a cyan charge gauge, then a collar, a mast of five
    ceramic insulator discs and a long copper tip."""
    p = Part()
    cx = 0.05
    p.cyl((cx, 0, 0.12), 1.0, 0.24, "steel_dark", segs=24, bevel=0.03)
    # The dome: stacked frustums following the sprite's outline.
    prof = [(0.2, 1.0), (0.7, 0.95), (1.2, 0.84), (1.6, 0.69), (1.9, 0.48), (2.05, 0.3)]
    for (z0, r0), (z1, r1) in zip(prof, prof[1:]):
        # The dome's top is a cream deck, its sides the blue tanks.
        p.cyl((cx, 0, (z0 + z1) / 2), r0, z1 - z0, "paint_fulgora_cream" if z0 >= 1.6 else "paint_fulgora_blue",
              segs=24, radius_top=r1)
    for z, r in ((0.7, 0.98), (1.2, 0.87), (1.6, 0.71)):
        p.cyl((cx, 0, z), r + 0.02, 0.07, "steel_dark", segs=24)
    for a in range(0, 360, 45):
        t = math.radians(a + 22)
        p.pipe([(cx + 1.0 * math.cos(t), 1.0 * math.sin(t), 0.25), (cx + 0.97 * math.cos(t), 0.97 * math.sin(t), 1.0),
                (cx + 0.7 * math.cos(t), 0.7 * math.sin(t), 1.75), (cx + 0.22 * math.cos(t), 0.22 * math.sin(t), 2.1)],
               0.045, "steel_dark", segs=6)
    for a in (210, 250, 300):
        t = math.radians(a)
        p.cyl((cx + 0.82 * math.cos(t), 0.82 * math.sin(t), 0.55), 0.17, 0.5, "copper_coil", segs=10)
    # Front: the grille, a strut and the foot pads.
    p.box((-0.5, -0.85, 0.2), (0.45, 0.12, 0.4), "steel_dark", rz=-25)
    p.slab(-0.15, -1.15, 0.0, 0.15, -0.9, 0.6, "steel_dark", bevel=0.03)
    p.cyl((0.89, -0.96, 0.08), 0.24, 0.16, "steel_dark", segs=14, bevel=0.03)
    p.cyl((-0.86, -0.5, 0.15), 0.2, 0.3, "steel_dark", segs=14, bevel=0.03)
    p.pipe([(0.55, -0.75, 0.1), (0.7, -0.85, 0.45), (0.6, -0.7, 0.9)], 0.07, "rust_brown", segs=8)
    for x, y, z in ((-0.72, 0.1, 2.1), (0.53, 0.2, 2.27)):
        p.tube((x, y, 1.3), (x, y, z - 0.05), 0.03, "steel_dark", segs=6)
        p.sphere((x, y, z), 0.07, "insulator_ceramic", segs=8, rings=4)
    # The column of struts and cables, the capsule, collar, insulators and the copper tip.
    p.cyl((0.06, 0, 2.9), 0.17, 1.8, "steel_dark", segs=12)
    for sx in (-1, 1):
        p.tube((cx + sx * 0.2, 0, 2.05), (cx + sx * 0.15, 0, 3.8), 0.04, "steel_light", segs=6)

    p.cyl((0.03, 0, 4.1), 0.34, 0.8, "paint_fulgora_cream", segs=18, bevel=0.04)
    p.cyl((0.03, 0, 4.68), 0.34, 0.36, "paint_fulgora_cream", segs=18, radius_top=0.14)
    p.slab(-0.08, -0.35, 3.95, 0.16, -0.3, 4.4, "glow_cyan")
    p.slab(0.32, -0.1, 3.45, 0.42, 0.1, 3.65, "steel_dark")
    p.cyl((0.0, 0, 5.1), 0.13, 0.5, "insulator_ceramic", segs=12, bevel=0.02)
    insulator_mast(p, 0.01, 0, 5.3, 6.85, (5.5, 5.78, 6.07, 6.36, 6.65), r_disc=0.11, tip=1.55)
    return [p, strike_sparks(0.01, 8.4, (0.3, 1.05), seed=2)]


# ---------------------------------------------------------------------------------------------
# Tesla turret.

@model("tesla-turret")
def tesla_turret():
    """Factorio's tesla turret (4x4): a round grey plinth crowded with machinery round a tall
    column with a copper coil: a racetrack-shaped coil frame and a big drum on its side on the
    west, two boxes on the east, legs braced down to the front, a box at the front-left corner
    and a vented dome at the front-right. The head on top, a riveted helmet on a neck of black
    tubes with a spike either side, turns towards its target (anim_turret_head). Sizes fitted
    to the sprite's outline."""
    p = Part()
    p.cyl((0, -0.18, 0.1), 2.02, 0.2, "steel_dark", segs=32, radius_top=1.95, bevel=0.03)
    rim = Part()
    rim.ring_band((0, 0), 1.75, 2.0, 0.0, 0.3, 0, 360, "steel_platform", segs=32)
    p.add_part(rim, T(0, -0.18, 0.0))
    # The column, its coil, and the copper-wound skirt round it.
    p.cyl((0, 0, 1.12), 0.651, 1.84, "steel_platform", segs=20, radius_top=0.758, bevel=0.04)
    for z in (1.5, 1.65, 1.8):
        p.cyl((0, 0, z), 0.74, 0.1, "copper_coil", segs=20)
    p.cyl((-0.46, -0.13, 1.3), 1.064, 0.37, "steel_dark", segs=24, radius_top=0.164)
    # West: the coil frame at the back, the drum on its side, a box between.
    p.slab(-2.0, 0.82, 1.04, -0.53, 1.36, 1.41, "steel_dark", bevel=0.12)
    for x in (-1.6, -1.25, -0.9):
        p.cyl((x, 1.09, 1.42), 0.13, 0.3, "copper_coil", segs=10, axis="Y")
    p.cyl((-1.13, -0.06, 0.73), 0.619, 1.6, "steel_platform", segs=18, axis="X", bevel=0.04)
    for x in (-1.75, -1.5, -1.25):
        p.cyl((x, -0.06, 0.73), 0.64, 0.08, "steel_dark", segs=18, axis="X")
    p.cyl((-0.4, -0.06, 0.73), 0.3, 0.2, "copper_coil", segs=14, axis="X")
    p.slab(-1.26, -0.52, 0.21, -0.71, 0.26, 1.42, "steel_dark", bevel=0.05)
    # East: the big louvred box at the back, the motor box in front of it.
    p.slab(0.85, 0.35, 0.71, 1.97, 1.28, 1.77, "steel_platform", bevel=0.1)
    for k in range(5):
        p.slab(1.0 + k * 0.18, 0.5, 1.765, 1.1 + k * 0.18, 1.15, 1.79, "steel_dark")
    p.slab(0.22, -0.75, 0.88, 1.54, 0.59, 1.16, "steel_platform", bevel=0.05)
    p.cyl((1.0, -0.75, 1.0), 0.25, 0.12, "steel_light", segs=14, axis="Y")
    p.slab(0.2, -0.7, 0.0, 1.28, -0.59, 1.22, "steel_dark", bevel=0.03)
    # Front: legs braced down from the column, the corner box and the vented dome.
    for sx in (-1, 1):
        p.beam((sx * 0.45, -0.45, 1.6), (sx * 0.8, -1.95, 0.2), 0.4, 0.3, "steel_platform")
        p.beam((sx * 0.45, -0.45, 1.6), (sx * 0.8, -1.95, 0.2), 0.2, 0.34, "steel_dark")

    p.slab(-0.96, -2.1, 0.0, 1.3, -1.7, 0.7, "steel_dark", bevel=0.04)
    p.slab(-0.3, -2.0, 0.0, 0.3, -1.45, 1.3, "steel_platform", bevel=0.06)
    p.cyl((0.0, -2.02, 0.75), 0.18, 0.1, "steel_dark", segs=12, axis="Y")

    p.slab(-1.9, -2.19, 0.0, -0.56, -1.65, 0.48, "steel_platform", bevel=0.06)
    p.sphere((1.58, -2.0, 0.44), 0.435, "steel_platform", segs=16, rings=8)
    p.cyl((1.58, -2.41, 0.48), 0.15, 0.06, "steel_dark", segs=12, axis="Y")
    p.pipe([(-0.7, -0.6, 1.5), (-0.6, -1.4, 0.9), (0.0, -1.9, 0.6)], 0.08, "steel_black", segs=8)
    p.pipe([(-0.5, 0.6, 2.0), (-0.9, 0.9, 1.4), (-1.1, 1.0, 0.6)], 0.05, "paint_blue_dark", segs=8)
    # The head: a riveted helmet on a neck of black tubes, turning about the column.
    head = Part("anim_turret_head", pivot=(0.0, 0.0, 2.3))
    head.cyl((0, -0.11, 2.87), 0.232, 1.35, "steel_dark", segs=16, radius_top=0.266)
    for sx in (-0.15, -0.05, 0.05, 0.15):
        head.cyl((sx, -0.3, 3.0), 0.05, 1.1, "steel_black", segs=8)
    head.sphere((0, 0.25, 3.91), 0.54, "steel_platform", segs=18, rings=9)
    head.bolts_ring((0, 0.25, 3.91), 0.54, 10, axis="Z")
    head.slab(-0.66, 0.01, 3.59, 0.56, 0.08, 3.9, "steel_dark")
    for sx in (-1, 1):
        head.tube((sx * 0.55, 0.05, 3.75), (sx * 0.75, 0.05, 3.95), 0.03, "steel_light", segs=6)
    return [p, head]


# ---------------------------------------------------------------------------------------------
# Fulgurite: lightning-fused glass in the ground, mauve and knobbly, broken ends pink inside.
# Each limb is a chain of knobs fitted to the sprite's outline in screen tiles (x right, u up from
# the ground origin, r the knob's radius): seen from Factorio's camera a chain of balls and tapered
# tubes shows as the same chain of discs, whatever the depth. Standing limbs get a depth `y`;
# a knob that would end up under the ground (and lying limbs, y None) rests on it instead.

def _knob(x, u, r, y):
    z = r if y is None else zs(u, y)
    if z < r:
        z = r
    return Vector((x, ys(u, z), z))


def _fused(p, limbs, grow=1.03, segs=12):
    """limbs: (y, cut, [(x, u, r), ...]); `cut` ends the limb in the pink broken face."""
    for y, cut, knobs in limbs:
        pts = [_knob(x, u, r, y) for x, u, r in knobs]
        # 12-sided knobs show a little smaller than the round discs they were fitted as.
        rs = [r * grow for _, _, r in knobs]
        for k in range(len(pts)):
            p.sphere(pts[k], rs[k], "stone_fulgurite", segs=segs, rings=segs // 2)
            if k:
                p.tube(pts[k - 1], pts[k], rs[k - 1], "stone_fulgurite", segs=segs, radius_top=rs[k], caps=False)
        if cut:
            # A disc set into the end knob, just proud of its surface; the sprites' breaks are
            # slanted, their pink faces turned up towards the camera.
            d = ((pts[-1] - pts[-2]).normalized() + Vector((0, -0.6, 0.6))).normalized()
            p.tube(pts[-1] + d * (rs[-1] * 0.3), pts[-1] + d * (rs[-1] * 0.36), rs[-1] * 0.94,
                   "glass_fulgurite_core", segs=12)


@model("fulgurite")
def fulgurite():
    """A fulgurite: a crooked tube of fused glass standing up out of the ground, broken off at
    the top and at a stub on its west side, with a twig to the east and glassy roots running out
    across the ground."""
    p = Part()
    _fused(p, FULGURITE)
    return p


@model("fulgurite-small")
def fulgurite_small():
    """A small fulgurite: two broken glass stubs standing up, a third leaning west, and three
    pieces lying in the ground round them, one showing its pink broken end."""
    p = Part()
    _fused(p, FULGURITE_SMALL, grow=1.0, segs=16)





    return p


FULGURITE = [
    (0.1, True, [(-0.29, 0.15, 0.145), (-0.37, 0.31, 0.17), (-0.4, 0.57, 0.144), (-0.51, 0.74, 0.123),
                 (-0.51, 0.72, 0.147), (-0.48, 0.97, 0.167), (-0.47, 1.16, 0.199), (-0.39, 1.43, 0.141),
                 (-0.53, 1.73, 0.173), (-0.51, 1.91, 0.195), (-0.46, 2.07, 0.2), (-0.43, 2.31, 0.218),
                 (-0.42, 2.49, 0.193)]),
    (0.0, True, [(-0.34, 1.7, 0.212), (-0.47, 1.61, 0.158), (-0.69, 1.66, 0.192)]),
    (0.1, False, [(-0.35, 1.47, 0.148), (-0.07, 1.22, 0.126), (0.14, 1.05, 0.16), (0.23, 1.09, 0.109),
                  (0.29, 1, 0.07), (0.34, 0.95, 0.065), (0.39, 0.85, 0.06)]),
    (0.1, False, [(-0.08, 0.65, 0.07), (0.07, 0.84, 0.128), (0.03, 0.74, 0.16), (0.09, 0.48, 0.113),
                  (0.42, 0.08, 0.118), (0.55, 0.07, 0.109), (0.66, 0.11, 0.129), (0.82, -0.07, 0.161),
                  (0.94, -0.15, 0.127)]),
    (None, False, [(0.52, -0.01, 0.207), (0.6, -0.37, 0.134), (0.61, -0.63, 0.122), (0.72, -0.82, 0.15),
                   (0.7, -0.84, 0.146)]),
    (0.1, False, [(-0.18, 0.55, 0.114), (-0.43, 0.44, 0.112), (-0.61, 0.41, 0.072), (-0.76, 0.32, 0.09),
                  (-0.97, 0.14, 0.097)]),
    (None, False, [(-0.27, 0.06, 0.147), (-0.42, -0.13, 0.112), (-0.52, -0.27, 0.093), (-0.82, -0.53, 0.106),
                   (-0.99, -0.68, 0.133), (-1.06, -0.7, 0.07), (-1.04, -1.03, 0.07)]),
    (None, False, [(-0.28, -0.13, 0.084), (-0.2, -0.36, 0.082), (-0.21, -0.5, 0.097), (-0.33, -0.77, 0.103),
                   (-0.25, -1.17, 0.147)]),
]

FULGURITE_SMALL = [
    (0.0, True, [(0.29, 0.14, 0.163), (0.21, 0.245, 0.134), (0.15, 0.425, 0.127), (0.12, 0.685, 0.076),
                 (0.19, 1.045, 0.123)]),
    (0.0, False, [(-0.15, 0.61, 0.129), (0.1, 0.85, 0.143), (0.12, 0.93, 0.142)]),
    (0.1, True, [(0.12, -0.09, 0.071), (-0.2, 0.19, 0.128), (-0.36, 0.37, 0.162), (-0.48, 0.52, 0.133),
                 (-0.51, 0.585, 0.108)]),
    (None, False, [(-0.74, -0.23, 0.105), (-0.57, -0.28, 0.102), (-0.27, -0.25, 0.097), (-0.36, -0.24, 0.152),
                   (-0.25, -0.15, 0.127)]),
    (None, False, [(0.02, -0.36, 0.148), (0.14, -0.22, 0.161), (0.11, -0.12, 0.096), (0.34, -0.07, 0.08),
                   (0.09, -0.28, 0.107), (0.33, -0.13, 0.098), (0.27, -0.07, 0.072)]),
    (None, True, [(0.28, -0.56, 0.082), (0.24, -0.54, 0.102), (0.17, -0.47, 0.114)]),
]


# ---------------------------------------------------------------------------------------------
# Fulgoran ruin attractor: an old lightning tower.

@model("fulgoran-ruin-attractor")
def fulgoran_ruin_attractor():
    """The fulgoran attractor: a weathered round tower on a heap of broken blocks, two bent
    pipes running into it on the west, a banded cap with a hatch, a perforated cone and a ball
    on top, a little dish on a stalk and an aerial on the east. It still draws lightning.
    Pipe and aerial points are read off the sprite in screen tiles (x, u) at a chosen depth."""

    def at(x, u, y):
        return (x, y, zs(u, y))

    p = Part()
    # The heap of broken blocks round the foot.
    p.box((0.57, -0.97, 0.3), (0.82, 0.7, 0.6), "concrete_ruin", bevel=0.06, rz=4)
    p.box((-0.07, -0.66, 0.2), (0.78, 0.7, 0.4), "concrete_ruin", bevel=0.06, rz=-8)
    p.box((-0.75, -0.25, 0.16), (0.62, 0.6, 0.32), "concrete_ruin_dark", bevel=0.05, rz=12)
    p.box((0.3, -0.35, 0.25), (0.7, 0.5, 0.5), "concrete_ruin_dark", bevel=0.05)
    # The tower narrowing under its cap; the cap, cone and ball sit a little east of it.
    p.cyl((0.28, 0.0, 1.85), 0.63, 3.7, "concrete_ruin", segs=20, radius_top=0.55, bevel=0.03)
    for z in (1.2, 2.4):
        p.cyl((0.28, 0.0, z), 0.63 - z * 0.022 + 0.02, 0.1, "rust_ruin", segs=20)
    p.sphere((0.5, 0.0, 4.15), 0.63, "rust_ruin", segs=20, rings=10, scale=(1, 1, 0.6))
    p.slab(0.25, -0.6, 3.85, 0.8, -0.5, 4.3, "concrete_ruin_dark", bevel=0.02)
    p.cyl((0.49, 0.0, 4.9), 0.4, 1.2, "concrete_ruin_dark", segs=16, radius_top=0.26)
    p.sphere((0.55, 0.0, 5.72), 0.375, "concrete_ruin", segs=16, rings=8)    # Two pipes bent into the tower on the west, the outer one with a flange.
    p.pipe([at(-0.9, -0.1, -0.35), at(-0.78, 0.6, -0.35), at(-0.62, 1.2, -0.35), at(-0.45, 1.28, -0.35),
            at(-0.2, 1.12, -0.35)], 0.12, "steel_platform", segs=10)
    p.tube(at(-0.3, 1.14, -0.4), at(-0.05, 1.08, -0.4), 0.16, "steel_platform", segs=10)
    p.pipe([at(-0.52, -0.2, -0.55), at(-0.48, 0.6, -0.55), at(-0.4, 0.92, -0.55), at(-0.2, 0.95, -0.55)], 0.17,
           "steel_platform", segs=10)
    # The dish on its stalk, and the aerial.
    p.tube(at(-0.2, 2.1, -0.45), at(-0.3, 2.92, -0.45), 0.03, "steel_dark", segs=6)
    p.cyl(at(-0.33, 2.93, -0.45), 0.2, 0.06, "steel_platform", segs=14, bevel=0.02)
    p.slab(0.5, -0.62, 0.3, 0.75, -0.5, 2.2, "rust_ruin", bevel=0.03)
    p.tube(at(0.8, 1.3, -0.6), at(1.12, 1.74, -0.6), 0.05, "steel_dark", segs=6)
    p.sphere(at(1.12, 1.74, -0.6), 0.05, "steel_dark", segs=8, rings=4)
    return p
