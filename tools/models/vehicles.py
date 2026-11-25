"""Vehicles: car, locomotive, cargo wagon, fluid wagon. Modelled facing north (orientation 0).

Each model is matched to Factorio's HR sprite with compare.py (see client/assets/models/README.md,
"Matching a sprite").
"""

import math

from mathutils import Matrix, Vector

import detail
import kit
from kit import Part, R, S, T, model
import space_kit


def own_materials(part, suffix):
    """Renames the part's materials to `<name>_<suffix>` (same look as the originals), so the
    part colours (tools/models/part_colors.py) sample turrets, cannons and legs on their own
    instead of snapping them to the hull's paint. Glass and lamps keep theirs. The client picks
    the weathering by substring, so `steel_dark_turret` still weathers as steel."""
    names = []
    for name in part.mats:
        hex_colour, rough, metal, emit, strength = kit.MATERIALS[name]
        if emit or name in kit.ALPHA:
            names.append(name)
            continue
        new = "%s_%s" % (name, suffix)
        kit.MATERIALS.setdefault(new, (hex_colour, rough, metal, emit, strength))
        names.append(new)
    part.mats = names
    return part



def along_y(p, profile, y0, y1, mat, bevel=0.0):
    """A cross-section in the x-z plane (list of (x, z), counter-clockwise seen from +y)
    extruded along y from y0 to y1: the long hoods and tanks of the rolling stock."""
    return p.prism(profile, -y1, -y0, mat, bevel, matrix=R("X", 90))


def mirrored(half):
    """A symmetric cross-section from its right half [(x, z), ...] listed bottom to top, x > 0."""
    return half + [(-x, z) for x, z in reversed(half)]


def bogie(p, y):
    """A two-axle bogie under rolling stock, centred on y. Factorio draws its own (the
    `train-wheel` sprite, turned with the rails), so this is only seen with the fallback
    material; sized like that sprite: wheels on the rails (x = +-0.75), a tall side frame with
    its springs, a bolster up to the body. Each axle with its wheels is a part of its own
    (`anim_wheel_rail`, turning about its axle), returned for the model's list: the client rolls
    them with the train's speed."""
    axles = []
    for dy in (-0.5, 0.5):
        axle = Part("anim_wheel_rail", pivot=(0.0, y + dy, 0.36))
        for sx in (-1, 1):
            axle.cyl((sx * 0.72, y + dy, 0.36), 0.36, 0.12, "steel_black", segs=16, axis="X", bevel=0.02)
            axle.cyl((sx * 0.8, y + dy, 0.36), 0.14, 0.06, "steel", segs=8, axis="X")
            # A spoke, so the turning shows.
            axle.slab(sx * 0.79 - 0.02, y + dy - 0.03, 0.08, sx * 0.79 + 0.02, y + dy + 0.03, 0.64, "steel")
        axle.cyl((0, y + dy, 0.36), 0.06, 1.5, "steel", segs=8, axis="X")
        axles.append(axle)
    for sx in (-1, 1):
        p.side_prism([(y - 0.85, 0.3), (y + 0.85, 0.3), (y + 0.75, 0.62), (y + 0.3, 0.8), (y - 0.3, 0.8),
                      (y - 0.75, 0.62)], sx * 0.84 - 0.06, sx * 0.84 + 0.06, "rust_brown", bevel=0.03)
        p.cyl((sx * 0.84, y, 0.88), 0.12, 0.2, "steel_light", segs=8)
    p.slab(-0.95, y - 0.28, 0.8, 0.95, y + 0.28, 1.05, "rust_brown", bevel=0.04)
    return axles


def tyre(p, x, y, r, w, segs=16):
    """A fat off-road tyre on a deep-dish rim, axle along X, hub cap outside (sign of x).
    12 symmetric tread lugs touch outer radius r at 90° and 270° so lowest point is
    z = 0.0 and vertical midpoint equals pivot z = r (wheel_roll_test.gd)."""
    sx = 1 if x > 0 else -1
    p.cyl((x, y, r), r - 0.006, w, "rubber", segs=segs, axis="X", bevel=0.05)
    # 12 symmetric lugs: 3*90° = multiples of 30° hit exact top (90°) and bottom (270°).
    lug_len = 0.054
    lug_h = 0.012
    for k in range(12):
        a = k * 2 * math.pi / 12
        ca, sa = math.cos(a), math.sin(a)
        m = T(x, y + ca * (r - lug_h * 0.5), r + sa * (r - lug_h * 0.5)) @ R("X", math.degrees(a) - 90.0)
        p.box((0, 0, 0), (w * 0.86, lug_len, lug_h), "rubber", matrix=m)
    # Deep-dish steel rim, dark recessed inner dish, 3 spokes, center hub and 6 lug bolts.
    out_x = x + sx * (w * 0.5 - 0.01)
    p.cyl((out_x, y, r), r * 0.62, 0.032, "steel_dark", segs=12, axis="X")
    p.cyl((out_x + sx * 0.012, y, r), r * 0.52, 0.02, "steel_black", segs=12, axis="X")
    p.cyl((out_x + sx * 0.030, y, r), r * 0.25, 0.045, "steel", segs=10, axis="X", bevel=0.01)
    for k in range(3):
        a = k * 2 * math.pi / 3
        m = T(out_x + sx * 0.024, y, r) @ R("X", math.degrees(a))
        p.box((0, r * 0.27, 0), (0.026, r * 0.42, 0.052), "steel", matrix=m)
    for k in range(6):
        a = k * 2 * math.pi / 6 + 0.26
        p.cyl((out_x + sx * 0.042, y + math.cos(a) * r * 0.42, r + math.sin(a) * r * 0.42),
              0.022, 0.020, "steel_light", segs=6, axis="X")


def cycle_fender(p, x, y, z, r_in, r_out, w, a0_deg=32.0, a1_deg=148.0, segs=8, mat="paint_cream"):
    """Curved wheel mudguard arch hugging (x, y, z), spanning angles a0..a1 in (y, z) from +Y (front)."""
    outer = []
    inner = []
    for k in range(segs + 1):
        a = math.radians(a0_deg + (a1_deg - a0_deg) * k / segs)
        ca, sa = math.cos(a), math.sin(a)
        outer.append((y + r_out * ca, z + r_out * sa))
        inner.append((y + r_in * ca, z + r_in * sa))
    p.side_prism(outer + list(reversed(inner)), x - w * 0.5, x + w * 0.5, mat)
    liner = []
    for k in range(segs + 1):
        a = math.radians(a0_deg + (a1_deg - a0_deg) * k / segs)
        ca, sa = math.cos(a), math.sin(a)
        liner.append((y + (r_in - 0.01) * ca, z + (r_in - 0.01) * sa))
    p.side_prism(inner + list(reversed(liner)), x - w * 0.46, x + w * 0.46, "steel_dark")


def striped_hose(p, points, radius, segs=8, pitch=0.068, smooth=4):
    """Corrugated yellow-and-black hazard hose along a smooth spline."""
    pts = space_kit.resample(space_kit.catmull(points, smooth), pitch)
    for k in range(len(pts) - 1):
        a, b = pts[k], pts[k + 1]
        mat = "hazard" if k % 2 == 0 else "hazard_black"
        r = radius if k % 2 == 0 else radius * 0.84
        p.tube(tuple(a), tuple(b), r, mat, segs=segs, caps=(k == 0 or k == len(pts) - 2))


@model("car")
def car():
    """Factorio's car: an armored desert buggy. Four chunky treaded tyres on exposed wishbone
    and coil-over suspension under tight curved cream cycle fenders (`anim_steer_front` on the
    front pair); a compact riveted cabin with raised door frames and recessed windows; a sloped
    dark radiator grille with rusty louver slats between cream hood rails, twin round headlights
    (`anim_headlight`) and tubular steel bull-bars; an exposed rear V-engine under a tubular
    roll-cage with spinning cooling fan (`anim_engine_fan`), compact exhaust loop and thick
    yellow-and-black striped hoses; and a low-slung roof machine gun (`anim_turret_head` +
    `anim_turret_barrel`)."""
    p = Part()
    wheels = []
    front_fenders = []

    # 4 wheel stations: rear tyres larger than front, seated cleanly to Factorio's rotation sheets.
    stations = ((0.985, 0.358, 0.320, True), (-0.655, 0.410, 0.365, False))
    for y, r, w, is_front in stations:
        for sx in (-1, 1):
            wx = sx * 0.745
            wheel = Part("anim_wheel_front" if is_front else "anim_wheel_rear", pivot=(wx, y, r))
            tyre(wheel, wx, y, r, w)
            wheels.append(wheel)

            # Exposed wishbone A-arms and tall coil-over shock tower from chassis to hub upright.
            p.slab(sx * 0.57, y - 0.05, r - 0.04, sx * 0.65, y + 0.05, r + 0.14, "steel_dark", bevel=0.015)
            for dy in (-0.12, 0.12):
                p.tube((sx * 0.40, y + dy * 1.4, 0.34), (sx * 0.60, y + dy * 0.35, r - 0.02), 0.028, "steel_dark", segs=6)
                p.tube((sx * 0.42, y + dy * 1.1, 0.56), (sx * 0.60, y + dy * 0.30, r + 0.09), 0.024, "steel_dark", segs=6)
            bot = (sx * 0.56, y, r + 0.06)
            top = (sx * 0.45, y, r + 0.47)
            p.tube(bot, top, 0.026, "steel_dark", segs=6)
            detail.spring(p, (sx * 0.54, y, r + 0.12), (sx * 0.47, y, r + 0.42), 0.052, "steel_light", turns=6, wire=0.015)
            p.box((sx * 0.45, y, r + 0.48), (0.08, 0.09, 0.06), "steel_dark", bevel=0.01)

            # Tight cycle fenders hugging each wheel closely.
            if is_front:
                fender = Part("anim_steer_front", pivot=(wx, y, r))
                cycle_fender(fender, wx, y, r, r + 0.012, r + 0.044, 0.330, a0_deg=42.0, a1_deg=148.0)
                fender.tube((sx * 0.62, y - 0.07, r + 0.08), (sx * 0.62, y - 0.20, r + 0.26), 0.018, "steel_dark", segs=6)
                fender.tube((sx * 0.62, y + 0.07, r + 0.08), (sx * 0.62, y + 0.18, r + 0.26), 0.018, "steel_dark", segs=6)
                front_fenders.append(fender)
            else:
                cycle_fender(p, wx, y, r, r + 0.012, r + 0.046, 0.372, a0_deg=36.0, a1_deg=150.0)
                p.tube((sx * 0.62, y - 0.08, r + 0.08), (sx * 0.62, y - 0.23, r + 0.30), 0.020, "steel_dark", segs=6)
                p.tube((sx * 0.62, y + 0.08, r + 0.08), (sx * 0.62, y + 0.22, r + 0.30), 0.020, "steel_dark", segs=6)

    # Lower armored chassis tub & rear axle differential.
    p.slab(-0.44, -1.08, 0.24, 0.44, 1.28, 0.48, "steel_dark", bevel=0.04)
    p.slab(-0.47, -0.32, 0.38, 0.47, 0.40, 0.56, "paint_cream", bevel=0.04)
    p.cyl((0.0, -0.655, 0.410), 0.050, 1.20, "steel_dark", segs=8, axis="X")
    p.sphere((0.0, -0.655, 0.410), 0.12, "steel_black", segs=8, rings=4)

    # Front hood & sloped radiator grille (y in 0.28..1.35).
    hood_cheek = [(0.28, 0.48), (1.18, 0.48), (1.18, 0.61), (0.38, 0.94), (0.28, 0.94)]
    for sx in (-1, 1):
        x0, x1 = sorted((sx * 0.31, sx * 0.44))
        p.side_prism(hood_cheek, x0, x1, "paint_cream", bevel=0.022)
        detail.rivet_line(p, (sx * 0.375, 0.42, 0.93), (sx * 0.375, 1.12, 0.64), 6, "Z")
    p.side_prism([(0.34, 0.44), (1.16, 0.44), (1.16, 0.56), (0.38, 0.89), (0.34, 0.89)], -0.32, 0.32, "soot")
    p.beam((0.0, 0.38, 0.91), (0.0, 1.16, 0.58), 0.042, 0.036, "steel_dark", up=(0, 0.4, 1))
    for k in range(11):
        t = (k + 0.5) / 11
        gy = 0.40 + 0.74 * t
        gz = 0.91 - 0.31 * t
        p.beam((-0.31, gy, gz), (0.31, gy, gz), 0.048, 0.030, "rust_brown", up=(0, 0.38, 1))

    # Rounded nose cowling, front inspection plate, bull-bar bumper & headlights.
    p.side_prism([(1.10, 0.38), (1.35, 0.38), (1.35, 0.56), (1.25, 0.65), (1.10, 0.65)],
                 -0.42, 0.42, "paint_cream", bevel=0.03)
    p.slab(-0.24, 1.25, 0.43, 0.24, 1.37, 0.58, "steel_dark", bevel=0.02)
    detail.rivet_line(p, (-0.20, 1.372, 0.54), (0.20, 1.372, 0.54), 5, "Y")
    # Front tubular bull-bar bumper.
    p.cyl((0.0, 1.40, 0.40), 0.038, 1.06, "steel", segs=8, axis="X", bevel=0.01)
    for sx in (-1, 1):
        p.tube((sx * 0.51, 1.40, 0.40), (sx * 0.40, 1.26, 0.40), 0.032, "steel_dark", segs=6)
        p.tube((sx * 0.30, 1.40, 0.40), (sx * 0.30, 1.28, 0.51), 0.026, "steel_dark", segs=6)
        p.cyl((sx * 0.36, 1.28, 0.63), 0.080, 0.12, "steel_light", segs=12, axis="Y", bevel=0.015)
        p.cyl((sx * 0.36, 1.33, 0.63), 0.068, 0.028, "steel_dark", segs=12, axis="Y")

    # Glowing headlight lenses (lit at night while driven via movers._light_vehicles).
    headlight = Part("anim_headlight", pivot=(0.0, 1.345, 0.63))
    for sx in (-1, 1):
        headlight.cyl((sx * 0.36, 1.348, 0.63), 0.060, 0.015, "lamp_headlight", segs=10, axis="Y")

    # Armored cabin (y in -0.32..0.34, z in 0.44..0.97).
    cab_sec = mirrored([(0.46, 0.46), (0.46, 0.82), (0.38, 0.97)])
    along_y(p, cab_sec, -0.32, 0.34, "paint_cream", bevel=0.03)
    for sx in (-1, 1):
        lo, hi = (min(sx * 0.45, sx * 0.51), -0.24, 0.46), (max(sx * 0.45, sx * 0.51), 0.26, 0.84)
        p.slab(*lo, *hi, "paint_cream", bevel=0.018)
        p.slab(min(sx * 0.49, sx * 0.525), -0.15, 0.60, max(sx * 0.49, sx * 0.525), 0.16, 0.78, "steel_dark", bevel=0.01)
        p.slab(min(sx * 0.515, sx * 0.535), -0.11, 0.63, max(sx * 0.515, sx * 0.535), 0.12, 0.75, "soot")
        p.slab(min(sx * 0.52, sx * 0.54), -0.10, 0.64, max(sx * 0.52, sx * 0.54), 0.11, 0.74, "glass")
        p.box((sx * 0.515, -0.18, 0.55), (0.025, 0.07, 0.025), "steel_light")
        for zy in ((-0.20, 0.50), (0.22, 0.50), (-0.20, 0.80), (0.22, 0.80)):
            p.bolt((sx * 0.512, zy[0], zy[1]), "steel_light", radius=0.016, axis="X")
        p.slab(min(sx * 0.38, sx * 0.49), -0.52, 0.48, max(sx * 0.38, sx * 0.49), -0.31, 0.75, "steel_dark", bevel=0.02)

    # Cab roof plate & bolted turret collar ring.
    p.slab(-0.39, -0.30, 0.94, 0.39, 0.32, 0.99, "steel_dark", bevel=0.02)
    p.ring_band((0.0, 0.0), 0.19, 0.29, 0.97, 1.03, 0, 360, "steel", segs=14, bevel=0.01)
    p.bolts_ring((0.0, 0.0, 1.035), 0.24, 8, "steel_light", radius=0.015)

    # Exposed rear engine bay, open tubular roll-cage, cooling fan, compact exhaust & striped hoses.
    for sx in (-1, 1):
        p.pipe([(sx * 0.37, -0.28, 0.95), (sx * 0.39, -0.72, 0.90), (sx * 0.42, -1.04, 0.55),
                (sx * 0.50, -1.09, 0.40)], 0.028, "steel_dark", segs=6)
        p.tube((sx * 0.39, -0.72, 0.90), (sx * 0.42, -0.62, 0.46), 0.024, "steel_dark", segs=6)
    p.cyl((0.0, -0.72, 0.90), 0.026, 0.78, "steel_dark", segs=6, axis="X")

    p.slab(-0.22, -0.88, 0.44, 0.22, -0.33, 0.79, "steel_black", bevel=0.025)
    p.slab(-0.16, -0.82, 0.77, 0.16, -0.37, 0.88, "steel_dark", bevel=0.02)
    for sx in (-1, 1):
        m_bank = T(sx * 0.19, -0.60, 0.70) @ R("Y", sx * -28.0)
        p.box((0, 0, 0), (0.14, 0.40, 0.14), "steel", bevel=0.018, matrix=m_bank)
        for k in range(3):
            p.box((0, -0.12 + k * 0.12, 0.075), (0.16, 0.042, 0.025), "steel_light", matrix=m_bank)
    p.pipe([(0.14, -0.68, 0.85), (0.16, -0.84, 0.95), (0.14, -0.99, 1.04), (0.04, -1.01, 0.95)],
           0.032, "steel", segs=6)
    p.cyl((0.02, -1.01, 0.94), 0.022, 0.02, "soot", segs=6, axis="X")

    # Rear cooling fan shroud + spinning fan (`anim_engine_fan`).
    fan_shroud = Part()
    fan_shroud.ring_band((0.0, 0.0), 0.195, 0.245, -0.04, 0.04, 0, 360, "steel", segs=14, bevel=0.01)
    p.add_part(fan_shroud, T(0.0, -0.96, 0.70) @ R("X", 90))
    p.cyl((0.0, -0.91, 0.70), 0.195, 0.03, "soot", segs=12, axis="Y")

    engine_fan = Part("anim_engine_fan", pivot=(0.0, -0.96, 0.70))
    engine_fan.cyl((0.0, -0.96, 0.70), 0.056, 0.06, "steel_dark", segs=8, axis="Y")
    for k in range(6):
        m_blade = T(0.0, -0.96, 0.70) @ R("Y", k * 60.0) @ R("Z", 25.0)
        engine_fan.box((0.105, 0.0, 0.0), (0.14, 0.014, 0.048), "steel_light", matrix=m_blade)

    # Rear tubular bumper.
    p.cyl((0.0, -1.11, 0.40), 0.038, 1.08, "steel", segs=8, axis="X", bevel=0.01)
    for sx in (-1, 1):
        p.tube((sx * 0.51, -1.11, 0.40), (sx * 0.40, -1.00, 0.40), 0.032, "steel_dark", segs=6)

    # Signature yellow-and-black striped hoses arcing over the rear engine & tucked beside front wheel wells.
    for sx in (-1, 1):
        striped_hose(p, [
            (sx * 0.18, -0.30, 0.95),
            (sx * 0.36, -0.52, 1.04),
            (sx * 0.38, -0.78, 0.96),
            (sx * 0.26, -0.96, 0.75),
        ], 0.048, segs=6, pitch=0.068)
        striped_hose(p, [
            (sx * 0.44, 0.30, 0.52),
            (sx * 0.50, 0.48, 0.48),
            (sx * 0.42, 0.68, 0.48),
        ], 0.034, segs=6, pitch=0.058)

    # Roof machine gun turret (low-slung on the collar): `anim_turret_head` + `anim_turret_barrel`.
    tz = 0.99
    turret = Part("anim_turret_head", pivot=(0.0, 0.0, tz))
    turret.cyl((0.0, 0.0, tz + 0.09), 0.095, 0.14, "steel_dark", segs=10)
    turret.slab(-0.12, -0.05, tz + 0.15, 0.12, 0.07, tz + 0.25, "steel_dark", bevel=0.018)
    turret.slab(-0.10, -0.32, tz + 0.21, 0.08, 0.15, tz + 0.42, "steel", bevel=0.02)
    turret.slab(-0.07, -0.27, tz + 0.41, 0.05, 0.09, tz + 0.46, "steel_dark", bevel=0.012)
    turret.slab(-0.09, -0.39, tz + 0.26, 0.07, -0.31, tz + 0.38, "steel_black", bevel=0.012)
    turret.slab(-0.21, -0.15, tz + 0.15, -0.09, 0.08, tz + 0.37, "brass", bevel=0.018)
    turret.slab(-0.215, -0.155, tz + 0.32, -0.085, 0.085, tz + 0.375, "steel_dark")
    loop = Part()
    loop.ring_band((0, 0), 0.078, 0.130, -0.025, 0.025, 0, 360, "brass", segs=12)
    turret.add_part(loop, T(0.02, -0.27, tz + 0.32) @ R("Y", 90))

    barrel = Part("anim_turret_barrel", pivot=(0.0, 0.0, tz))
    barrel.cyl((-0.01, 0.26, tz + 0.35), 0.046, 0.25, "steel_dark", segs=10, axis="Y", bevel=0.01)
    for y in (0.19, 0.26, 0.33):
        barrel.cyl((-0.01, y, tz + 0.35), 0.050, 0.026, "soot", segs=8, axis="Y")
    barrel.cyl((-0.01, 0.46, tz + 0.35), 0.026, 0.17, "steel", segs=8, axis="Y")
    barrel.cyl((-0.01, 0.56, tz + 0.35), 0.036, 0.06, "steel_black", segs=8, axis="Y", bevel=0.01)
    barrel.cyl((-0.01, 0.595, tz + 0.35), 0.018, 0.01, "soot", segs=6, axis="Y")

    return [
        p,
        own_materials(turret, "turret"),
        own_materials(barrel, "turret"),
        engine_fan,
        headlight,
    ] + wheels + front_fenders



@model("locomotive")
def locomotive():
    """Factorio's locomotive, front north, from its 256 rotation frames (front and side views):
    a long riveted underframe on two bogies (+-2 tiles, joint_distance 4) carrying, from the back,
    a rear platform with the coupler, handrail and coiled brass hoses; a dark rear box with a
    grilled window each side; a rusty ribbed dome; the long light hood with its round hatch,
    seams and rivet rows, a ribbed tank down its west side and a louvred box down its east;
    the taller front machinery (a stack of small boxes and a long pipe west, a slatted grille,
    a radiator and two upright tanks with looping pipes east); the riveted nose with its
    whistle and headlights; and the V plough down to the rails."""
    p = Part()
    axles = []
    for y in (-2.0, 2.0):
        axles += bogie(p, y)
    # Underframe: riveted sills the full length, equipment hung between the bogies.
    p.slab(-0.96, -3.3, 0.95, 0.96, 3.3, 1.22, "steel_dark", bevel=0.04)
    for sx in (-1, 1):
        detail.rivet_line(p, (sx * 0.965, -3.3, 1.15), (sx * 0.965, 3.15, 1.15), 27, "X")
        p.cyl((sx * 0.62, -0.05, 0.74), 0.22, 1.9, "steel", segs=12, axis="Y", bevel=0.02)
        for y in (-0.7, 0.0, 0.7):
            p.cyl((sx * 0.62, y - 0.05, 0.74), 0.235, 0.06, "steel_dark", segs=12, axis="Y")
    p.pipe([(0.25, -1.1, 0.95), (0.25, -0.9, 0.55), (0.25, 0.9, 0.55), (0.25, 1.1, 0.95)], 0.07, "steel_black", segs=8)
    p.slab(-0.35, -0.6, 0.5, 0.05, 0.6, 0.95, "steel_black", bevel=0.04)

    # Rear platform: deck, coupler, handrail loop and the coiled hoses at the corners.
    # (Cars couple 7 tiles apart, so nothing reaches past 3.5 tiles from the middle.)
    p.slab(-0.9, -3.45, 1.12, 0.9, -3.1, 1.24, "steel_dark", bevel=0.03)
    p.slab(-0.2, -3.5, 0.5, 0.2, -3.25, 0.8, "steel_black", bevel=0.03)
    p.pipe([(-0.72, -3.2, 1.24), (-0.72, -3.45, 0.95), (0.72, -3.45, 0.95), (0.72, -3.2, 1.24)], 0.035, "steel_light",
           segs=6)
    for sx in (-1, 1):
        detail.spring(p, (sx * 0.62, -3.08, 1.85), (sx * 0.7, -3.42, 1.3), 0.06, "brass", turns=10, wire=0.018)
        p.cyl((sx * 0.62, -3.35, 1.0), 0.07, 0.2, "steel_black", segs=8, axis="Y")

    # Rear box: rounded top edges, a grilled window each side, a door panel on the back.
    rear = mirrored([(0.97, 1.22), (0.97, 1.75), (0.8, 2.05), (0.45, 2.18)])
    along_y(p, rear, -3.1, -1.55, "steel_dark", bevel=0.04)
    for sx in (-1, 1):
        lo, hi = (min(sx * 0.95, sx * 0.99), -2.95, 1.38), (max(sx * 0.95, sx * 0.99), -1.85, 1.82)
        p.slab(*lo, *hi, "steel_black")
        detail.slots(p, lo, hi, "+x" if sx > 0 else "-x", 5, mat="grime", depth=0.015)
        detail.rivet_line(p, (sx * 0.975, -3.0, 1.7), (sx * 0.975, -1.65, 1.7), 9, "X")
    detail.panel(p, (-0.8, -3.12, 1.3), (0.8, -3.1, 1.95), "-y", "steel", margin=0.08, rivet="steel_light")
    p.slab(-0.3, -2.95, 2.12, 0.3, -2.45, 2.33, "rust", bevel=0.05)
    detail.rivet_line(p, (-0.25, -2.7, 2.335), (0.25, -2.7, 2.335), 4, "Z")
    p.pipe([(-0.98, -3.0, 1.3), (-0.98, -2.8, 1.85), (-0.98, -2.0, 1.85), (-0.9, -1.75, 1.6)], 0.06, "steel_light", segs=8)

    # The rusty ribbed dome between the rear box and the hood, a brass hose down its west side.
    dome = mirrored([(0.45, 1.9), (0.45, 2.25), (0.33, 2.43), (0.12, 2.48)])
    along_y(p, dome, -1.85, -1.0, "rust", bevel=0.03)
    end_taper(p, dome, -1.85, -2.0, "rust", 1.9, 0.55)
    ribs = mirrored([(0.47, 1.95), (0.47, 2.27), (0.35, 2.45), (0.13, 2.5)])
    for y in (-1.7, -1.48, -1.26, -1.06):
        along_y(p, ribs, y - 0.025, y + 0.025, "steel_dark")
    detail.spring(p, (-0.48, -1.2, 2.25), (-0.62, -1.75, 1.55), 0.055, "brass", turns=10, wire=0.017)
    p.cyl((0.3, -1.95, 2.2), 0.09, 0.3, "steel_light", segs=8)

    # The long hood: light steel, rounded, with seams, rivet rows, a raised plate and the hatch.
    hood = mirrored([(0.66, 1.22), (0.66, 1.95), (0.55, 2.22), (0.3, 2.36)])
    along_y(p, hood, -1.55, 1.3, "steel", bevel=0.03)
    seam = mirrored([(0.675, 1.5), (0.675, 1.96), (0.56, 2.235), (0.305, 2.375)])
    for y in (-0.75, 0.62):
        along_y(p, seam, y - 0.02, y + 0.02, "steel_dark")
    for sx in (-1, 1):
        detail.rivet_line(p, (sx * 0.6, -1.45, 2.1), (sx * 0.6, 1.2, 2.1), 14, "Z")
        detail.rivet_line(p, (sx * 0.665, -1.45, 1.75), (sx * 0.665, 1.2, 1.75), 14, "X")
    p.cyl((0, 0.0, 2.37), 0.26, 0.06, "steel_dark", segs=20)
    p.cyl((0, 0.0, 2.41), 0.2, 0.06, "steel_light", segs=20, bevel=0.02)
    p.cyl((0, 0.0, 2.45), 0.05, 0.04, "steel_dark", segs=8)
    p.slab(-0.2, 0.42, 2.3, 0.2, 0.82, 2.4, "steel_dark", bevel=0.03)
    detail.rivet_line(p, (-0.15, 0.62, 2.405), (0.15, 0.62, 2.405), 3, "Z")
    # West side: a ribbed tank along the hood; east side: a louvred box.
    detail.ribbed_drum(p, (-0.8, -0.15, 1.5), 0.2, 2.3, "steel_dark", "steel", axis="Y", ribs=6, segs=12)
    p.slab(-0.97, -1.45, 1.22, -0.66, 1.25, 1.32, "steel_dark")
    lo, hi = (0.66, -1.35, 1.22), (0.95, 1.05, 1.88)
    p.slab(*lo, *hi, "steel_dark", bevel=0.03)
    detail.slots(p, lo, hi, "+x", 12, mat="grime", along=1, depth=0.015)
    detail.slots(p, lo, hi, "+z", 12, mat="grime", along=1, depth=0.012)

    # Front machinery, taller than the hood.
    p.slab(-0.97, 1.3, 1.22, 0.97, 2.95, 1.75, "steel_dark", bevel=0.04)
    p.slab(-0.5, 1.3, 1.75, 0.5, 2.95, 2.34, "steel", bevel=0.08)
    detail.panel(p, (-0.5, 1.3, 1.75), (0.5, 2.95, 2.34), "+z", "steel", margin=0.1, split=2)
    detail.rivet_line(p, (-0.42, 1.38, 2.36), (-0.42, 2.87, 2.36), 9, "Z")
    detail.rivet_line(p, (0.42, 1.38, 2.36), (0.42, 2.87, 2.36), 9, "Z")
    for k, y in enumerate((1.45, 1.8, 2.15, 2.5)):
        p.slab(-0.95, y, 1.75, -0.6, y + 0.28, 2.1 + 0.05 * (k % 2), "steel_black", bevel=0.03)
    p.pipe([(-0.97, 0.95, 1.4), (-0.97, 1.15, 1.95), (-0.97, 2.75, 1.95), (-0.9, 2.9, 1.6)], 0.06, "steel_light", segs=8)
    lo, hi = (-0.6, 2.05, 1.75), (-0.32, 2.6, 2.3)
    p.slab(*lo, *hi, "steel_dark", bevel=0.02)
    detail.slots(p, lo, hi, "+z", 5, mat="grime", along=0, depth=0.012)
    for y in (1.5, 2.65):
        p.cyl((0.72, y, 2.02), 0.21, 0.54, "steel", segs=14, bevel=0.03)
        p.sphere((0.72, y, 2.29), 0.21, "steel", segs=14, rings=4, hemisphere=True, scale=(1, 1, 0.45))
        p.cyl((0.72, y, 1.95), 0.225, 0.05, "steel_dark", segs=14)
    lo, hi = (0.48, 1.8, 1.75), (0.96, 2.35, 2.3)
    p.slab(*lo, *hi, "steel_dark", bevel=0.03)
    detail.slots(p, lo, hi, "+z", 5, mat="grime", along=0, depth=0.012)
    detail.slots(p, lo, hi, "+x", 5, mat="grime", along=0, depth=0.012)
    p.pipe([(0.55, 2.7, 2.35), (0.35, 2.55, 2.42), (0.35, 1.75, 2.42), (0.55, 1.55, 2.3)], 0.055, "steel_light", segs=8)
    p.pipe([(0.95, 1.3, 1.7), (0.98, 1.0, 1.4)], 0.05, "steel_light", segs=6)

    # Nose: a riveted cap narrowing forward, its top sloping down, the whistle on top.
    nose = Part()
    outline = [(-0.97, 2.95), (0.97, 2.95), (0.97, 3.15), (0.6, 3.45), (-0.6, 3.45), (-0.97, 3.15)]
    nose.prism(outline, 1.22, 2.34, "steel_dark", bevel=0.04)
    nose.warp(lambda co: (co.x * (1.0 - 0.55 * max(0.0, co.z - 1.9) / 0.44), co.y,
                           co.z if co.z < 1.5 or co.y < 3.0 else co.z - (co.y - 3.0) * 1.5))
    p.add_part(nose)
    detail.rivet_line(p, (-0.85, 3.0, 2.35), (0.85, 3.0, 2.35), 9, "Z")
    detail.rivet_line(p, (-0.5, 3.4, 1.7), (0.5, 3.4, 1.7), 6, "Z")
    p.cyl((0, 3.1, 2.3), 0.06, 0.12, "steel", segs=10)
    p.sphere((0, 3.1, 2.36), 0.06, "steel_light", segs=10, rings=4)
    for sx in (-1, 1):
        p.cyl((sx * 0.6, 3.36, 1.68), 0.1, 0.1, "steel_light", segs=10, axis="Y")
        p.cyl((sx * 0.6, 3.41, 1.68), 0.075, 0.02, "glass", segs=10, axis="Y")
    # The dark slatted grille across the nose's foot, between and under the headlights.
    lo, hi = (-0.45, 3.42, 1.24), (0.45, 3.47, 1.6)
    p.slab(*lo, *hi, "steel_black")
    detail.slots(p, lo, hi, "+y", 7, mat="grime", along=1, depth=0.012)
    # V plough down to the rails, ribbed.
    plough = Part()
    plough.side_prism([(3.25, 0.12), (3.66, 0.12), (3.48, 1.22), (3.25, 1.22)], -0.95, 0.95, "steel_black", bevel=0.03)
    plough.warp(lambda co: (co.x, co.y - abs(co.x) * 0.36 if co.y > 3.3 else co.y, co.z))
    p.add_part(plough)
    for sx in (-1, 1):
        for k in range(3):
            x = sx * (0.2 + 0.3 * k)
            p.beam((x, 3.63 - abs(x) * 0.36, 0.2), (x, 3.46 - abs(x) * 0.36, 1.15), 0.05, 0.03, "steel",
                   up=(0, 1, 0.2))
    return [p] + axles


def end_taper(p, section, y0, y1, mat, z_pivot, keep):
    """An end piece of a long body: `section` extruded from y0 to y1, its far end squashed
    towards z_pivot by `keep` (0..1), so the roof slopes down to the buffer beam."""
    piece = Part()
    along_y(piece, section, min(y0, y1), max(y0, y1), mat)
    piece.warp(lambda co: (co.x, co.y, co.z if abs(co.y - y0) < 1e-4 else z_pivot + (co.z - z_pivot) * keep))
    p.add_part(piece)


def buffers(p, y_end):
    """Coupler box and buffer beam at one end (y_end is the outer face, sign gives the end)."""
    sy = 1 if y_end > 0 else -1
    p.slab(-0.85, y_end - sy * 0.25, 0.75, 0.85, y_end - sy * 0.02, 1.0, "steel_dark", bevel=0.03)
    p.slab(-0.22, y_end - sy * 0.3, 0.55, 0.22, y_end + sy * 0.05, 0.85, "steel_black", bevel=0.03)


def planks(p, a, b, y0, y1, count, mat, out=0.025, gap=0.025):
    """`count` planks running along y from y0 to y1, laid side by side across the face from
    a to b (two (x, z) points of a cross-section), standing `out` proud of it."""
    ax, az = a
    dx, dz = b[0] - ax, b[1] - az
    length = math.hypot(dx, dz)
    nx, nz = dz / length, -dx / length
    if nx * (ax + dx / 2) + nz * (az + dz / 2) < 0:   # the normal points away from the axis
        nx, nz = -nx, -nz
    w = length / count
    for k in range(count):
        t = (k + 0.5) / count
        cx, cz = ax + dx * t + nx * out / 2, az + dz * t + nz * out / 2
        p.beam((cx, y0, cz), (cx, y1, cz), w - gap, out, mat, up=(nx, 0, nz))


CARGO_SECTION = mirrored([(1.0, 1.1), (1.0, 1.45), (0.42, 2.15)])
CARGO_BAND = mirrored([(1.03, 1.08), (1.03, 1.47), (0.44, 2.19)])


@model("cargo-wagon")
def cargo_wagon():
    """Factorio's cargo wagon: a long box van in three bays, centred on the vehicle's position
    (its sprite is, though the selection box is off centre). Each bay is planked: planks run
    along the wagon on the narrow roof, the steep chamfers and the vertical sides, held by two
    straps round the bay; riveted steel frames stand between the bays and at the ends, a rail
    runs along each side where the chamfer meets it, and a lamp shines at each corner of the
    roof. The roof slopes down at both ends to the buffer beams, a small box on each end; the
    floor hangs lower between the bogies (at +-2)."""
    p = Part()
    axles = []
    for y in (-2.0, 2.0):
        axles += bogie(p, y)
    # The dark carcass the planks lie on, so the gaps between them read dark.
    along_y(p, CARGO_SECTION, -3.0, 3.0, "steel_dark", bevel=0.02)
    for sy in (-1, 1):
        end_taper(p, CARGO_SECTION, sy * 3.0, sy * 3.38, "steel", 1.15, 0.45)
        buffers(p, sy * 3.42)
        # The end door: a riveted box standing out of the sloping end.
        lo, hi = (-0.34, min(sy * 3.0, sy * 3.42), 1.12), (0.34, max(sy * 3.0, sy * 3.42), 1.8)
        p.slab(*lo, *hi, "steel_dark", bevel=0.04)
        detail.panel(p, lo, hi, "+y" if sy > 0 else "-y", "steel", margin=0.07, rivet="steel_light")
        detail.panel(p, lo, hi, "+z", "steel", margin=0.06)
    along_y(p, mirrored([(0.92, 0.82), (0.96, 0.98)]), -1.05, 1.05, "steel_dark", bevel=0.03)
    # Three planked bays.
    for k in range(3):
        y0, y1 = -2.96 + k * 2.0, -1.08 + k * 2.0
        planks(p, (0.4, 2.15), (-0.4, 2.15), y0, y1, 5, "paint_grey")
        for sx in (-1, 1):
            planks(p, (sx * 1.0, 1.47), (sx * 0.43, 2.14), y0, y1, 4, "paint_grey")
            planks(p, (sx * 1.0, 1.12), (sx * 1.0, 1.43), y0, y1, 2, "paint_grey")
        for y in (y0 + 0.42, y1 - 0.42):
            along_y(p, CARGO_BAND, y - 0.035, y + 0.035, "steel_dark")
    # Riveted frames between the bays and at the ends, rails along the sides.
    frame = mirrored([(1.05, 1.02), (1.05, 1.49), (0.45, 2.21)])
    for y in (-3.0, -1.02, 1.02, 3.0):
        along_y(p, frame, y - 0.05, y + 0.05, "steel")
        for sx in (-1, 1):
            detail.rivet_line(p, (sx * 1.055, y, 1.12), (sx * 1.055, y, 1.42), 2, "X")
            detail.rivet_line(p, (sx * 0.98, y, 1.62), (sx * 0.62, y, 2.06), 3, "Z")
    for sx in (-1, 1):
        p.beam((sx * 1.04, -3.0, 1.45), (sx * 1.04, 3.0, 1.45), 0.07, 0.06, "steel", up=(sx, 0, 0))
        p.beam((sx * 1.03, -3.0, 1.08), (sx * 1.03, 3.0, 1.08), 0.07, 0.05, "steel", up=(sx, 0, 0))
        detail.rivet_line(p, (sx * 1.065, -2.9, 1.08), (sx * 1.065, 2.9, 1.08), 24, "X")
        for sy in (-1, 1):
            p.sphere((sx * 0.42, sy * 3.0, 2.2), 0.05, "ceramic", segs=8, rings=4)
    return [p] + axles


@model("infinity-cargo-wagon")
def infinity_cargo_wagon():
    """Factorio's infinity cargo wagon (an editor wagon that refills itself): the cargo wagon,
    its picture tinted (0.5, 0.5, 1) as the prototype does, which turns the grey van violet
    blue. Its own materials, so the part colours sample the tinted sprite."""
    parts = cargo_wagon()
    for part in parts:
        tinted(part, "infinity", (0.5, 0.5, 1.0))
    return parts


def tinted(part, suffix, tint):
    """Renames the part's materials to `<name>_<suffix>`, their colours multiplied by `tint`
    (Factorio's layer tint, sRGB), emission left as it is."""
    names = []
    for name in part.mats:
        hex_colour, rough, metal, emit, strength = kit.MATERIALS[name]
        rgb = [int(hex_colour[i:i + 2], 16) * tint[i // 2] for i in (0, 2, 4)]
        new = "%s_%s" % (name, suffix)
        kit.MATERIALS.setdefault(new, ("%02x%02x%02x" % tuple(round(c) for c in rgb), rough, metal, emit, strength))
        names.append(new)
    part.mats = names
    return part


@model("fluid-wagon")
def fluid_wagon():
    """Factorio's fluid wagon: three squat round tanks with domed tops, riveted round the dome's
    foot and seamed down their sides, each with a bolted hatch strapped to the cage; they stand
    on a flat underframe inside a rusty cage whose two top rails run over the tanks, a waist rail
    along each side, posts with V braces between the tanks and splayed end frames; pipes and
    valves run between the tanks under the cage. Centred on the vehicle's position like its
    sprite, bogies at +-2."""
    p = Part()
    axles = []
    for y in (-2.0, 2.0):
        axles += bogie(p, y)
    # Underframe sills, with the pipe run and pumps hanging lower in the middle.
    p.slab(-0.95, -3.05, 0.85, 0.95, 3.05, 1.05, "steel_dark", bevel=0.03)
    for sx in (-1, 1):
        detail.rivet_line(p, (sx * 0.955, -2.95, 0.95), (sx * 0.955, 2.95, 0.95), 24, "X")
    # Valves and pipework filling the gaps between the tanks.
    for y in (-0.98, 0.98):
        p.slab(-0.72, y - 0.2, 1.0, 0.72, y + 0.2, 1.75, "steel_dark", bevel=0.04)
        for sx in (-1, 1):
            p.cyl((sx * 0.55, y, 1.35), 0.14, 0.7, "steel", segs=8, axis="Y")
            p.cyl((sx * 0.55, y, 1.35), 0.17, 0.08, "steel_dark", segs=8, axis="Y")
            p.cyl((sx * 0.72, y, 1.2), 0.07, 0.12, "rust_brown", segs=8, axis="X")
    p.cyl((0, 0, 0.75), 0.12, 4.2, "steel", segs=10, axis="Y")
    for y in (-1.0, 1.0):
        p.cyl((0, y, 0.82), 0.24, 0.5, "steel_dark", segs=10)
    for sy in (-1, 1):
        buffers(p, sy * 3.18)
    # The tanks: squat round drums with domed top and bottom, nearly touching, a flange round
    # the waist, rivets round the dome's foot and across it, seams down the sides, a hatch on top.
    for y in (-1.97, 0.0, 1.97):
        p.cyl((0, y, 1.4), 0.92, 0.7, "tank_white", segs=24)
        p.sphere((0, y, 1.75), 0.92, "tank_white", segs=24, rings=8, hemisphere=True, scale=(1, 1, 0.56))
        p.sphere((0, y, 1.05), 0.92, "tank_white", segs=24, rings=8, hemisphere=True, scale=(1, 1, -0.5))
        p.cyl((0, y, 1.42), 0.95, 0.06, "steel_dark", segs=24)
        p.cyl((0, y, 1.76), 0.935, 0.04, "steel", segs=24)
        for k in range(18):
            a = 2 * math.pi * (k + 0.5) / 18
            p.bolt((0.93 * math.cos(a), y + 0.93 * math.sin(a), 1.8), "steel_light", radius=0.024, axis="Z")
        for k in range(12):
            a = 2 * math.pi * (k + 0.5) / 12
            p.bolt((0.6 * math.cos(a), y + 0.6 * math.sin(a), 2.15), "steel_light", radius=0.022, axis="Z")
        for k in range(6):
            a = 2 * math.pi * k / 6 + 0.3
            p.beam((0.925 * math.cos(a), y + 0.925 * math.sin(a), 1.08), (0.925 * math.cos(a), y + 0.925 * math.sin(a), 1.74),
                   0.025, 0.015, "steel", up=(math.cos(a), math.sin(a), 0))
        # Hatch: a flange, the bolted lid, its boss and a lever strapped out to the cage.
        p.cyl((0, y, 2.27), 0.3, 0.06, "steel_dark", segs=16, bevel=0.02)
        p.cyl((0, y, 2.32), 0.21, 0.08, "steel", segs=16, bevel=0.02)
        p.bolts_ring((0, y, 2.36), 0.16, 8, "steel_light", radius=0.02)
        p.cyl((0, y, 2.38), 0.08, 0.08, "steel_dark", segs=10)
        p.cyl((0, y, 2.42), 0.045, 0.04, "steel_light", segs=8)
        p.beam((0.18, y + 0.1, 2.33), (0.5, y + 0.28, 2.2), 0.08, 0.035, "rust_brown")
        p.beam((-0.25, y - 0.12, 2.3), (-0.72, y - 0.12, 2.32), 0.07, 0.03, "rust_brown")
    # Cage: top rails over the tanks, a waist rail along each side, posts with V braces between
    # the tanks, splayed end frames with a cross beam.
    for sx in (-1, 1):
        p.beam((sx * 0.72, -3.0, 2.34), (sx * 0.72, 3.0, 2.34), 0.08, 0.08, "rust_brown", bevel=0.01)
        p.beam((sx * 0.96, -3.08, 1.55), (sx * 0.96, 3.08, 1.55), 0.07, 0.06, "rust_brown")
        for y in (-0.98, 0.98):
            p.beam((sx * 0.96, y, 1.0), (sx * 0.96, y, 1.6), 0.08, 0.08, "rust_brown", up=(0, 1, 0))
            p.beam((sx * 0.96, y, 1.58), (sx * 0.72, y, 2.36), 0.08, 0.07, "rust_brown", up=(0, 1, 0))
            for sy in (-1, 1):
                p.beam((sx * 0.96, y, 1.55), (sx * 0.72, y + sy * 0.42, 2.34), 0.05, 0.05, "rust_brown", up=(0, 1, 0))
        for sy in (-1, 1):
            y = sy * 3.06
            p.beam((sx * 0.96, y, 1.0), (sx * 0.96, y, 1.6), 0.08, 0.08, "rust_brown", up=(0, 1, 0))
            p.beam((sx * 0.96, y, 1.58), (sx * 0.72, sy * 3.0, 2.36), 0.08, 0.07, "rust_brown", up=(0, 1, 0))
            p.beam((sx * 0.3, y, 1.05), (sx * 0.72, sy * 3.0, 2.3), 0.06, 0.06, "rust_brown", up=(0, 1, 0))
    for sy in (-1, 1):
        p.beam((-0.76, sy * 3.0, 2.34), (0.76, sy * 3.0, 2.34), 0.08, 0.08, "rust_brown", bevel=0.01)
        p.beam((-0.96, sy * 3.06, 1.55), (0.96, sy * 3.06, 1.55), 0.07, 0.06, "rust_brown")
    return [p] + axles
