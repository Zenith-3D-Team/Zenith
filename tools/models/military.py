"""Military, Nauvis mid and late game: laser, flamethrower and artillery turrets, land mine, tank,
spidertron, artillery wagon and the three combat robots.

Each model is matched to Factorio's HR sprite with compare.py (client/assets/models/README.md,
"Matching a sprite"). Turret heads and the tank's turret are `anim_turret_head` parts, pivot on
their axis, barrels north at rest, as on the gun turret.
"""

import math

from mathutils import Vector

import detail
import kit
from kit import Part, R, S, T, model
import space_kit
from vehicles import along_y, bogie, buffers, mirrored, own_materials

# Colours picked against the sprites of the models below.
kit.MATERIALS.update({
    "paint_white": ("d6d3c9", 0.55, 0.3, None, 0),       # laser turret head, defender dome
    "rust_dark": ("4c3426", 0.85, 0.4, None, 0),         # tank hull, flamethrower plates
    "steel_spider": ("9a9d9c", 0.45, 0.75, None, 0),     # spidertron shell, destroyer dome
    "paint_green_pale": ("9db88e", 0.5, 0.3, None, 0),  # laser turret capacitor
    "paint_ochre": ("c39a4a", 0.6, 0.35, None, 0),       # laser turret middle
    "lamp_cyan": ("6ff0e8", 0.4, 0.0, "40e0ff", 1.2),    # robot leg lights
    "lamp_orange": ("ffb040", 0.4, 0.0, "ff9a20", 1.5),  # flamethrower pilot light
    # The artillery's hazard yellow is stronger than the kit's, which weathers to cream.
    "hazard_strong": ("ecb20c", 0.55, 0.3, None, 0),
})


def octagon(r, turn=22.5):
    return [(r * math.cos(math.radians(turn + 45 * i)), r * math.sin(math.radians(turn + 45 * i))) for i in range(8)]


# ---------------------------------------------------------------------------------------------
# Turrets.

@model("laser-turret")
def laser_turret():
    """Factorio's laser turret. The base is an open stand: four ladder legs, two rails and their
    rungs, slope down from a dark hub to feet out at the corners (from the south the far two look
    level and the near two steep, as in the sprite), an orange and a green capacitor sticking out
    west and east, black cables looping round on the ground. The head (`anim_turret_head`) is a
    swivel block on the hub, a dark arm up and back, and the long gun high above: a white rear
    block with three slots a side, the rusty orange middle, the white front block and a
    three-pronged emitter at the muzzle, a cable from its back down to the swivel."""
    p = Part()
    zt = 0.45
    zh = 0.75
    # Hub: a dark drum with a rim, the swivel's socket in its top.
    p.cyl((0, 0, zh - 0.2), 0.22, 0.4, "rust_dark", segs=12, bevel=0.02)
    p.ring_band((0, 0), 0.18, 0.27, zh - 0.06, zh + 0.02, 0, 360, "steel", segs=12)
    p.cyl((0, 0, zh), 0.18, 0.01, "soot", segs=12)
    # Legs: ladders from the hub's rim down to feet out at the corners. The far two splay wide to
    # the east and west and stand on raised pads, the near two reach in steeply to the south.
    for fx, fy, fz in ((0.78, 0.62, 0.1), (-0.78, 0.62, 0.1), (0.5, -0.55, 0.05), (-0.5, -0.55, 0.05)):
        r = math.atan2(fy, fx)
        c, s_ = math.cos(r), math.sin(r)
        tc, ts = -s_, c
        top = Vector((0.24 * c, 0.24 * s_, zh - 0.02))
        foot = Vector((fx, fy, fz))
        rails = []
        for k in (-1, 1):
            a0 = top + Vector((tc, ts, 0)) * (k * 0.1)
            a1 = foot + Vector((tc, ts, 0)) * (k * 0.2)
            p.beam(a0, a1, 0.08, 0.045, "steel_light", up=(c, s_, 1.0), bevel=0.01)
            p.bolt((a0.x, a0.y, a0.z + 0.03), "rust_brown", radius=0.03)
            rails.append((a0, a1))
        for t in (0.35, 0.68):
            q0 = rails[0][0].lerp(rails[0][1], t)
            q1 = rails[1][0].lerp(rails[1][1], t)
            p.beam(q0, q1, 0.05, 0.035, "steel_dark")
        for k in (-1, 1):
            q = foot + Vector((tc, ts, 0)) * (k * 0.2)
            p.box((q.x, q.y, fz / 2 + 0.02), (0.09, 0.09, fz + 0.04), "steel_black", bevel=0.015)
            p.bolt((q.x, q.y, fz + 0.05), "rust_brown", radius=0.03)
    # Capacitors sticking out of the hub: orange west, green east.
    for sx, mat in ((-1, "copper_dull"), (1, "paint_green_pale")):
        p.cyl((sx * 0.42, 0.08, 0.42), 0.11, 0.3, mat, segs=12, axis="X", bevel=0.02)
        for x in (0.28, 0.56):
            p.cyl((sx * x, 0.08, 0.42), 0.13, 0.04, "steel_light", segs=12, axis="X", bevel=0.01)
        p.cyl((sx * 0.6, 0.08, 0.42), 0.08, 0.05, "rust_brown", segs=10, axis="X")
    # Cables looping round on the ground, in front between the near legs as in the sprite.
    for sx in (-1, 1):
        p.pipe([(sx * 0.5, 0.08, 0.32), (sx * 0.62, -0.1, 0.08), (sx * 0.4, -0.5, 0.05), (0.0, -0.58, 0.05),
                (-sx * 0.3, -0.4, 0.06), (-sx * 0.12, -0.15, 0.25)], 0.035, "rubber", segs=6)
    # Low frame: beams on the ground from foot to foot round the stand (the sprite's outline).
    feet = [(0.78, 0.62), (0.5, -0.55), (-0.5, -0.55), (-0.78, 0.62)]
    for (ax, ay), (bx, by) in zip(feet, feet[1:] + feet[:1]):
        p.beam((ax, ay, 0.1), (bx, by, 0.1), 0.07, 0.06, "steel_dark")
    # The stand sized to the sprite (tools/models/fit_cells.py --fit scale,shift): a little
    # longer north-south and taller; the head stays on its axis.
    p.transform(T(0, 0.043, 0) @ S(0.972, 1.087, 1.032))

    head = Part("anim_turret_head", pivot=(0.0, 0.0, zt))
    # Swivel: two rusty white blocks on the socket.
    head.slab(-0.22, -0.24, zt + 0.02, 0.22, 0.2, zt + 0.3, "paint_white", bevel=0.03)
    head.cyl((0, -0.02, zt + 0.5), 0.12, 0.4, "steel_dark", segs=10)
    head.slab(-0.17, -0.3, zt + 0.66, 0.17, 0.12, zt + 0.92, "paint_white", bevel=0.03)
    for x in (-0.23, 0.23):
        head.bolt((x, -0.05, zt + 0.14), "rust_brown", radius=0.035, axis="X")
    gz = 2.25
    # Arm up and back to the gun's belly.
    head.beam((0, -0.05, zt + 0.85), (0, -0.25, gz - 0.24), 0.2, 0.14, "steel_dark", up=(0, 1, 0), bevel=0.02)
    head.slab(-0.15, -0.5, gz - 0.33, 0.15, -0.16, gz - 0.2, "paint_white", bevel=0.02)
    # Rear block with three slots a side.
    head.slab(-0.27, -0.6, gz - 0.24, 0.27, -0.1, gz + 0.24, "paint_white", bevel=0.05)
    for sx in (-1, 1):
        for k in range(3):
            y = -0.5 + k * 0.14
            head.slab(sx * 0.265, y - 0.04, gz - 0.15, sx * 0.285, y + 0.04, gz + 0.17, "soot")
        for z in (gz - 0.15, gz + 0.13):
            head.bolt((sx * 0.28, -0.57, z), "rust_brown", radius=0.035, axis="X")
    for k in range(3):
        head.slab(-0.14 + k * 0.11, -0.5, gz + 0.235, -0.09 + k * 0.11, -0.2, gz + 0.255, "soot")
    # Rusty orange middle, a little slimmer.
    head.slab(-0.21, -0.12, gz - 0.19, 0.21, 0.28, gz + 0.19, "paint_ochre", bevel=0.03)
    head.slab(-0.22, 0.04, gz - 0.2, 0.22, 0.1, gz + 0.2, "rust_brown")
    # Front block, with a small box on its east side.
    head.slab(-0.25, 0.26, gz - 0.24, 0.25, 0.58, gz + 0.24, "paint_white", bevel=0.05)
    head.slab(0.24, 0.0, gz - 0.05, 0.36, 0.22, gz + 0.18, "paint_ochre", bevel=0.02)
    # Emitter: three prongs closing in on the muzzle.
    for a in (90, 210, 330):
        r = math.radians(a)
        c, s = math.cos(r), math.sin(r)
        head.beam((0.16 * c, 0.56, gz + 0.16 * s), (0.08 * c, 0.8, gz + 0.08 * s), 0.05, 0.05, "steel_black")
        head.box((0.075 * c, 0.8, gz + 0.075 * s), (0.07, 0.07, 0.07), "rust_brown")
    head.cyl((0, 0.62, gz), 0.07, 0.1, "steel_dark", segs=8, axis="Y")
    # Cable from the back of the gun down to the swivel.
    head.pipe([(-0.12, -0.61, gz - 0.08), (-0.3, -0.85, gz - 0.45), (-0.34, -0.6, zt + 0.9), (-0.17, -0.3, zt + 0.75)],
              0.04, "rubber", segs=6)
    return [p, head]


@model("flamethrower-turret")
def flamethrower_turret():
    """Factorio's flamethrower turret, 2x3, facing north: a fat pipe across its south end with
    flanged ends (the fluid inputs) and the pump box on it, its grille and hand wheel to the
    south; pipes and hoses from the pump up to a rusty three-armed mount (two legs sloping down
    to feet near the north corners, a stem back to the pump), where the gun turns
    (`anim_turret_head`): a riveted grey drum with a perforated muzzle, the orange pilot light
    on top and a coiled hose under its back."""
    p = Part()
    # The pipe across the south end.
    py, pz = -1.12, 0.37
    p.cyl((0, py, pz), 0.34, 1.9, "olive_steel", segs=18, axis="X", bevel=0.03)
    for sx in (-1, 1):
        p.cyl((sx * 0.92, py, pz), 0.38, 0.08, "steel_dark", segs=18, axis="X", bevel=0.02)
        p.bolts_ring((sx * 0.97, py, pz), 0.31, 8, "rust_brown", radius=0.025, axis="X", start=22.5)
    for x in (-0.55, 0.55):
        p.cyl((x, py, pz), 0.35, 0.04, "rust_brown", segs=18, axis="X")
    # Pump box on the pipe, grille and hand wheel facing south.
    p.prism([(-0.5, -1.78), (0.5, -1.78), (0.42, -0.85), (-0.42, -0.85)], 0.0, 0.64, "steel_dark", bevel=0.05)
    p.slab(-0.42, -1.78, 0.08, 0.42, -1.72, 0.5, "steel", bevel=0.01)
    p.slab(-0.24, -1.81, 0.18, 0.0, -1.76, 0.34, "soot")
    p.cyl((0.22, -1.8, 0.26), 0.11, 0.03, "steel_light", segs=10, axis="Y")
    p.beam((0.12, -1.82, 0.26), (0.32, -1.82, 0.26), 0.02, 0.02, "steel_light")
    p.beam((0.22, -1.82, 0.16), (0.22, -1.82, 0.36), 0.02, 0.02, "steel_light")
    p.slab(-0.4, -1.4, 0.62, 0.4, -0.85, 0.72, "rust_dark", bevel=0.03)
    p.slab(-0.25, -1.3, 0.72, 0.25, -0.95, 0.78, "steel_dark", bevel=0.02)
    for x in (-0.42, 0.42):
        for z in (0.14, 0.56):
            p.bolt((x, -1.75, z), "steel_light", radius=0.03, axis="Y")
    # Feeds from the pump to the mount: two pipes with elbows and a bundle of hoses.
    for sx in (-1, 1):
        p.pipe([(sx * 0.2, -0.8, 0.8), (sx * 0.22, -0.4, 0.75), (sx * 0.16, 0.0, 0.7)], 0.09, "steel", segs=8)
        p.cyl((sx * 0.21, -0.55, 0.77), 0.11, 0.06, "steel_dark", segs=8, axis="Y")
    for k, x in enumerate((-0.07, 0.0, 0.07)):
        p.pipe([(x, -0.9, 0.8), (x * 2.5, -0.4, 0.62 + 0.03 * k), (x, 0.05, 0.7)], 0.035, "rubber", segs=6)
    # The three-armed mount: two legs sloping down to bolted feet near the north corners, a
    # stem back to the pump.
    my, mz = 0.3, 0.86
    p.cyl((0, my, mz / 2), 0.22, mz, "rust_dark", segs=12, bevel=0.03)
    for sx in (-1, 1):
        top = Vector((sx * 0.15, my + 0.05, mz - 0.06))
        foot = Vector((sx * 0.74, 1.05, 0.14))
        p.beam(top, foot, 0.3, 0.13, "rust_dark", up=(0, 0, 1), bevel=0.02)
        p.slab(foot.x - 0.17, foot.y - 0.16, 0.0, foot.x + 0.17, foot.y + 0.16, 0.16, "steel_dark", bevel=0.03)
        for k in (-1, 1):
            p.bolt((foot.x + k * 0.09, foot.y, 0.17), "steel_light", radius=0.03)
    root = Vector((0, my, 0))
    end = Vector((0.0, -0.4, 0))
    d = (end - root).normalized()
    side = Vector((-d.y, d.x, 0)) * 0.26
    pts = [root - side, end - side * 0.55, end + side * 0.55, root + side]
    p.prism([(v.x, v.y) for v in pts], mz - 0.12, mz, "rust_dark", bevel=0.02)
    p.beam((end.x, end.y, mz - 0.06), (end.x, end.y - 0.2, 0.3), 0.3, 0.12, "rust_dark", bevel=0.02)
    p.prism(octagon(0.3), mz - 0.1, mz + 0.03, "rust_dark", bevel=0.02, matrix=T(0, my, 0))

    head = Part("anim_turret_head", pivot=(0.0, 0.19, mz))
    hz = 1.3
    head.cyl((0, 0.19, mz + 0.12), 0.18, 0.22, "steel_dark", segs=10)
    head.slab(-0.14, -0.05, mz + 0.18, 0.14, 0.4, hz - 0.12, "steel_dark", bevel=0.03)
    # Drum body along the barrel.
    head.cyl((0, 0.45, hz), 0.25, 1.0, "steel_light", segs=14, axis="Y", bevel=0.03)
    for y in (0.0, 0.3, 0.62, 0.93):
        head.cyl((0, y, hz), 0.265, 0.05, "steel_dark", segs=14, axis="Y")
    for y in (0.15, 0.78):
        for k in range(10):
            a = math.radians(k * 36)
            head.bolt((0.26 * math.cos(a), y, hz + 0.26 * math.sin(a)), "rust_brown", radius=0.022, axis="Y")
    head.slab(-0.12, 0.35, hz + 0.24, 0.12, 0.6, hz + 0.3, "steel_dark", bevel=0.01)
    # Perforated muzzle.
    head.cyl((0, 1.12, hz), 0.2, 0.36, "steel_dark", segs=12, axis="Y")
    head.cyl((0, 1.3, hz), 0.14, 0.02, "soot", segs=10, axis="Y")
    for k in range(6):
        a = math.radians(k * 60 + 30)
        head.cyl((0.2 * math.cos(a), 1.12, hz + 0.2 * math.sin(a)), 0.05, 0.24, "soot", segs=6, axis="Y")
    # Pilot light and its bracket.
    head.cyl((0, 1.18, hz + 0.27), 0.065, 0.12, "lamp_orange", segs=8)
    head.cyl((0, 1.18, hz + 0.22), 0.075, 0.04, "brass", segs=8)
    # Back end and the hose coil down to the mount.
    head.cyl((0, -0.1, hz), 0.2, 0.14, "steel_dark", segs=12, axis="Y")
    coil = []
    for k in range(13):
        t = k / 12
        a = t * 4 * math.pi
        coil.append((0.2 * math.cos(a), -0.15 - 0.12 * t + 0.05 * math.sin(a), hz - 0.15 - (hz - mz - 0.2) * t))
    head.pipe(coil, 0.04, "rubber", segs=6, joints=False)
    return [p, head]


@model("land-mine")
def land_mine():
    """Factorio's land mine, lying flat: a rusty ring with square tabs all round its rim, bent
    up and out like a crown, a low grey drum in the middle with a cross-hatched pressure plate
    on top."""
    p = Part()
    p.cyl((0, 0, 0.035), 0.3, 0.07, "rust_brown", segs=24, bevel=0.015)
    for k in range(14):
        a = math.radians(k * 360 / 14 + 8)
        c, s_ = math.cos(a), math.sin(a)
        p.beam((0.24 * c, 0.24 * s_, 0.06), (0.43 * c, 0.43 * s_, 0.22), 0.13, 0.035, "rust_light",
               up=(-c, -s_, 0.8))
    # The grey drum slopes up over the tabs' roots to a groove round the plate.
    p.cyl((0, 0, 0.13), 0.37, 0.1, "stone_dark", segs=24, radius_top=0.25, bevel=0.01)
    p.cyl((0, 0, 0.19), 0.23, 0.02, "soot", segs=20)
    p.cyl((0, 0, 0.22), 0.2, 0.05, "rust", segs=20, bevel=0.01)
    for k in range(-4, 5):
        for turn in (45, -45):
            p.box((0.034 * k, 0, 0.248), (0.014, 0.3 - abs(k) * 0.05, 0.012), "rust_brown", matrix=R("Z", turn))
    # Fitted to the sprite (tools/models/fit_cells.py --fit scale): a little wider and taller,
    # shorter north-south (overlap 0.875 -> 0.91).
    p.transform(T(0.01, 0.005, 0) @ S(1.032, 0.907, 1.067))
    return p


def artillery_cannon(pivot, z_ring, head_name="anim_turret_head", barrel=3.5, elevation=25.0, scale=1.0):
    """The artillery cannon shared by the turret and the wagon: a slewing ring with red lights,
    a tall dark machinery block with the trunnions and gear boxes either side, the breech, and
    a long barrel in three steps with a slotted sleeve near its root, raised `elevation`
    degrees, pointing north."""
    px, py = pivot
    k = scale
    h = Part(head_name, pivot=(px, py, z_ring))
    h.ring_band((px, py), 0.62 * k, 0.8 * k, z_ring, z_ring + 0.12, 0, 360, "steel", segs=24, bevel=0.01)
    for a in (160, 200, 340, 20):
        r = math.radians(a)
        h.sphere((px + 0.78 * k * math.cos(r), py + 0.78 * k * math.sin(r), z_ring + 0.14), 0.04, "lamp_red", segs=6,
                 rings=3)
    h.cyl((px, py, z_ring + 0.2), 0.62 * k, 0.16, "steel_dark", segs=20)
    # Machinery: the cradle block, side gear boxes, pipes, the breech housing behind.
    zc = z_ring + 0.85 * k
    h.slab(px - 0.36 * k, py - 0.5 * k, z_ring + 0.25, px + 0.36 * k, py + 0.3 * k, zc + 0.2 * k, "steel_dark", bevel=0.06)
    h.slab(px - 0.3 * k, py - 0.62 * k, z_ring + 0.3, px + 0.3 * k, py - 0.2 * k, zc - 0.1 * k, "steel", bevel=0.05)
    for sx in (-1, 1):
        h.cyl((px + sx * 0.42 * k, py - 0.05 * k, zc), 0.22 * k, 0.14 * k, "steel", segs=12, axis="X", bevel=0.02)
        h.cyl((px + sx * 0.5 * k, py - 0.05 * k, zc), 0.1 * k, 0.06 * k, "steel_light", segs=8, axis="X")
        h.slab(px + sx * 0.3 * k, py - 0.55 * k, z_ring + 0.3, px + sx * 0.6 * k, py - 0.15 * k, zc - 0.25 * k,
               "steel_black", bevel=0.03)
        h.pipe([(px + sx * 0.3 * k, py - 0.5 * k, zc + 0.15 * k), (px + sx * 0.52 * k, py - 0.68 * k, zc - 0.15 * k),
                (px + sx * 0.58 * k, py - 0.45 * k, z_ring + 0.35)], 0.04 * k, "steel_light", segs=6)
    h.slab(px - 0.2 * k, py - 0.78 * k, zc - 0.25 * k, px + 0.2 * k, py - 0.35 * k, zc + 0.25 * k, "steel", bevel=0.04)
    h.sphere((px + 0.3 * k, py - 0.45 * k, zc + 0.32 * k), 0.12 * k, "steel_light", segs=8, rings=4)
    h.cyl((px - 0.18 * k, py - 0.3 * k, zc + 0.3 * k), 0.08 * k, 0.2 * k, "steel_dark", segs=8)
    # Barrel, raised.
    e = math.radians(elevation)
    d = Vector((0, math.cos(e), math.sin(e)))
    root = Vector((px, py - 0.05 * k, zc + 0.05 * k))
    h.tube(root - d * 0.45 * k, root + d * 0.6 * k, 0.22 * k, "steel_dark", segs=14)
    h.tube(root + d * 0.6 * k, root + d * 1.4 * k, 0.16 * k, "steel", segs=14)
    h.tube(root + d * 0.85 * k, root + d * 1.2 * k, 0.165 * k, "soot", segs=14)
    h.tube(root + d * 1.4 * k, root + d * barrel, 0.13 * k, "steel_light", segs=14)
    h.tube(root + d * (barrel - 0.06), root + d * (barrel + 0.04), 0.145 * k, "steel_dark", segs=14)
    h.tube(root + d * (barrel + 0.03), root + d * (barrel + 0.05), 0.09 * k, "soot", segs=12)
    return own_materials(h, "cannon")


@model("artillery-turret")
def artillery_turret():
    """Factorio's artillery turret, 3x3: a squat pedestal with chamfered corners in yellow and
    black hazard stripes with a hatch on its south face, a thick rounded ring of armour on it and
    the slewing ring on top, where the cannon (`anim_turret_head`) turns: tall dark machinery
    and a long barrel raised high to the north."""
    p = Part()
    h, c = 1.47, 0.45
    sq = [(h, -h + c), (h, h - c), (h - c, h), (-h + c, h), (-h, h - c), (-h, -h + c), (-h + c, -h), (h - c, -h)]
    p.prism(sq, 0.0, 0.1, "steel_black", bevel=0.03)
    # Hazard pedestal: vertical yellow and black bands round the sides.
    inner = [(x * 0.97, y * 0.97) for x, y in sq]
    n = 0
    for i in range(8):
        a, b = inner[i], inner[(i + 1) % 8]
        steps = 3 if i % 2 == 0 else 1
        for s in range(steps):
            t0, t1 = s / steps, (s + 1) / steps
            q0 = (a[0] + (b[0] - a[0]) * t0, a[1] + (b[1] - a[1]) * t0)
            q1 = (a[0] + (b[0] - a[0]) * t1, a[1] + (b[1] - a[1]) * t1)
            p.prism([(0, 0), q0, q1], 0.1, 0.95, "hazard_strong" if n % 2 == 0 else "hazard_black")
            n += 1
    p.prism(sq, 0.95, 1.05, "steel_dark", bevel=0.03)
    # South hatch.
    p.slab(-0.48, -1.5, 0.12, 0.48, -1.36, 0.66, "steel_dark", bevel=0.03)
    p.slab(-0.38, -1.53, 0.18, 0.38, -1.48, 0.6, "soot")
    for x in (-0.22, 0.0, 0.22):
        p.slab(x - 0.05, -1.55, 0.2, x + 0.05, -1.52, 0.58, "steel")
    # Rounded armour ring, the drum inside it and the ring the cannon turns on.
    p.cyl((0, 0, 1.2), 1.0, 0.4, "steel_dark", segs=28)
    p.ring_band((0, 0), 0.85, 1.4, 1.02, 1.28, 0, 360, "steel", segs=32, bevel=0.1)
    p.ring_band((0, 0), 0.9, 1.26, 1.28, 1.4, 0, 360, "steel", segs=32, bevel=0.05)
    p.ring_band((0, 0), 0.82, 1.0, 1.4, 1.52, 0, 360, "steel_light", segs=28, bevel=0.02)
    p.cyl((0, 0, 1.44), 0.82, 0.02, "soot", segs=24)
    for k in range(16):
        a = math.radians(k * 22.5)
        p.bolt((0.91 * math.cos(a), 0.91 * math.sin(a), 1.52), "steel_dark", radius=0.03)
    for sx in (-1, 1):
        p.slab(sx * 1.2, -0.3, 1.0, sx * 1.42, 0.3, 1.3, "steel_dark", bevel=0.04)
    head = artillery_cannon((0.0, 0.0), 1.44, barrel=3.9)
    return [p, head]


# ---------------------------------------------------------------------------------------------
# Vehicles.

# Closed-loop 3-circle caterpillar track contour in Blender (y_north, z_up) coordinates
# (shared verbatim with client/scripts/world/vehicle_anim.gd).
# C0 = rear drive sprocket, C1 = front-most road wheel, C2 = raised front idler.
TANK_CIRCLES = ((-1.06, 0.34, 0.28), (0.82, 0.22, 0.16), (1.24, 0.39, 0.23))
TANK_CLEATS = 32
TANK_CLEAT_START_Y = 0.85  # Cleat #0 sits open on the horizontal top run (y = +0.85, z = 0.62).


def _tank_track_segments():
    """Precomputes the 6 C1-continuous segments (lines + CW circular arcs) starting at
    (y=TANK_CLEAT_START_Y, z=0.62) going forward (+Y), down the front idler, back along
    the bottom run, and up the rear sprocket."""
    c0, c1, c2 = TANK_CIRCLES

    def ext_tangent(a, b):
        ay, az, ra = a
        by, bz, rb = b
        dy, dz = by - ay, bz - az
        d = math.hypot(dy, dz)
        ang = math.atan2(dz, dy) + math.acos((ra - rb) / d)
        nx, nz = math.cos(ang), math.sin(ang)
        return (ay + ra * nx, az + ra * nz), (by + rb * nx, bz + rb * nz), ang

    top_a, top_b, ang_top = ext_tangent(c0, c2)
    diag_a, diag_b, ang_diag = ext_tangent(c2, c1)
    bot_a, bot_b, ang_bot = ext_tangent(c1, c0)
    # Start on top straight at y = TANK_CLEAT_START_Y going forward (+Y) -> wrap CW loop.
    segs = [
        ("line", (TANK_CLEAT_START_Y, top_b[1]), top_b, ang_top),
        ("arc", c2, ang_top, ang_diag),
        ("line", diag_a, diag_b, ang_diag),
        ("arc", c1, ang_diag, ang_bot - 2 * math.pi if ang_bot > ang_diag else ang_bot),
        ("line", bot_a, bot_b, ang_bot),
        ("arc", c0, ang_bot if ang_bot < ang_top else ang_bot - 2 * math.pi, ang_top - 2 * math.pi),
        ("line", top_a, (TANK_CLEAT_START_Y, top_a[1]), ang_top),
    ]
    out = []
    total = 0.0
    for seg in segs:
        if seg[0] == "line":
            _, p0, p1, ang = seg
            L = math.hypot(p1[0] - p0[0], p1[1] - p0[1])
            out.append(("line", L, p0, p1, ang))
        else:
            _, (cy, cz, r), a0, a1 = seg
            while a1 > a0:
                a1 -= 2 * math.pi
            L = r * (a0 - a1)
            out.append(("arc", L, cy, cz, r, a0, a1))
        total += L
    return out, total


_TANK_SEGS, _TANK_PERIM = _tank_track_segments()


def tank_track_sample(s):
    """(y, z, normal_angle_rad) along the CW track loop at arc length s (0.._TANK_PERIM)."""
    s = s % _TANK_PERIM
    for seg in _TANK_SEGS:
        L = seg[1]
        if s <= L or seg is _TANK_SEGS[-1]:
            t = 0.0 if L <= 1e-8 else min(1.0, s / L)
            if seg[0] == "line":
                _, _, p0, p1, ang = seg
                return p0[0] + (p1[0] - p0[0]) * t, p0[1] + (p1[1] - p0[1]) * t, ang
            _, _, cy, cz, r, a0, a1 = seg
            ang = a0 + (a1 - a0) * t
            return cy + r * math.cos(ang), cz + r * math.sin(ang), ang
        s -= L
    return TANK_CLEAT_START_Y, 0.62, math.pi / 2


def _track_wheel(part, wx, wy, wz, r, w, spokes=3, teeth=0):
    """Symmetric circular track wheel centered on (wx, wy, wz) for zero-slip rolling."""
    sx = 1 if wx > 0 else -1
    part.cyl((wx, wy, wz), r, w, "steel_dark", segs=10, axis="X")
    out_x = wx + sx * (w * 0.5 - 0.005)
    part.cyl((out_x, wy, wz), r * 0.74, 0.025, "steel_black", segs=10, axis="X")
    part.cyl((out_x + sx * 0.015, wy, wz), r * 0.44, 0.030, "rust_brown", segs=8, axis="X")
    if teeth > 0 or r > 0.20:
        part.cyl((out_x + sx * 0.028, wy, wz), r * 0.22, 0.032, "steel", segs=8, axis="X")
    bar_count = 1 if spokes <= 3 else 2
    for k in range(bar_count):
        a = k * math.pi / bar_count
        m = T(out_x + sx * 0.014, wy, wz) @ R("X", math.degrees(a))
        part.box((0, 0, 0), (0.022, r * 1.36, 0.038), "steel", matrix=m)
    if teeth > 0:
        # 8 symmetric sprocket teeth (every 45°) keep bounding radius symmetric on X/Y/Z.
        nt = min(teeth, 8)
        for k in range(nt):
            a = math.radians(k * 360.0 / nt)
            ca, sa = math.cos(a), math.sin(a)
            m = T(wx + sx * 0.01, wy + ca * (r - 0.005), wz + sa * (r - 0.005)) @ R("X", math.degrees(a) - 90.0)
            part.box((0, 0, 0), (w * 0.94, 0.040, 0.032), "steel", matrix=m)


def track_assembly(body, x, side_tag, w=0.36):
    """One side of the tank's caterpillar tracks: solid dark core band in `body`, exterior
    open bogie suspension frame in `body`, 7 true-circle wheels (`anim_wheel_track`), and
    32 closed-loop cleats (`anim_tread_l` / `anim_tread_r`) around the 3-circle contour."""
    sx = 1 if x > 0 else -1
    # Inner track band polygon sampled around the 3-circle loop (inset slightly inside cleats).
    core_pts = []
    for k in range(28):
        y, z, ang = tank_track_sample(_TANK_PERIM * k / 28)
        core_pts.append((y - 0.005 * math.cos(ang), z - 0.005 * math.sin(ang)))
    # CW in (y, z) -> reverse for CCW in side_prism seen from +X.
    body.side_prism(list(reversed(core_pts)), x - w * 0.45, x + w * 0.45, "steel_black")

    # Open exterior bogie suspension beam & swing-arm brackets outside the wheels.
    bx = x + sx * (w * 0.5 + 0.055)
    body.slab(bx - 0.035, -0.78, 0.17, bx + 0.035, 0.90, 0.25, "rust_brown", bevel=0.01)
    body.beam((bx, 0.86, 0.22), (bx, 1.24, 0.39), 0.06, 0.06, "rust_dark", up=(sx, 0, 0))
    body.beam((bx, -0.74, 0.22), (bx, -1.06, 0.34), 0.07, 0.07, "rust_dark", up=(sx, 0, 0))
    body.cyl((bx, 1.24, 0.39), 0.08, 0.07, "steel_dark", segs=8, axis="X")
    body.cyl((bx, -1.06, 0.34), 0.11, 0.08, "steel_dark", segs=8, axis="X")
    road_ys = (-0.58, -0.23, 0.12, 0.47, 0.82)
    for wy in road_ys:
        body.slab(bx - 0.03, wy - 0.045, 0.20, bx + 0.03, wy + 0.045, 0.50, "steel_dark")
        body.bolt((bx + sx * 0.035, wy, 0.22), "steel_light", radius=0.022, axis="X")

    # True-circle rolling wheels (5 road wheels, 1 raised front idler, 1 toothed rear sprocket).
    wheels = []
    for wy in road_ys:
        wpart = Part("anim_wheel_track", pivot=(x, wy, 0.22))
        _track_wheel(wpart, x, wy, 0.22, 0.16, w * 0.82, spokes=3)
        wheels.append(wpart)
    idler = Part("anim_wheel_track", pivot=(x, 1.24, 0.39))
    _track_wheel(idler, x, 1.24, 0.39, 0.215, w * 0.84, spokes=4)
    wheels.append(idler)
    sprocket = Part("anim_wheel_track", pivot=(x, -1.06, 0.34))
    _track_wheel(sprocket, x, -1.06, 0.34, 0.26, w * 0.88, spokes=4, teeth=10)
    wheels.append(sprocket)

    # 32 closed-loop caterpillar cleats (`anim_tread_l` / `anim_tread_r`), Cleat #0 exposed at top.
    tread = Part("anim_tread_" + side_tag, pivot=(x, 0.0, 0.62))
    pad_prof = [(-0.064, 0.0), (0.064, 0.0), (0.052, 0.042), (-0.052, 0.042)]
    for k in range(TANK_CLEATS):
        y, z, ang = tank_track_sample(_TANK_PERIM * k / TANK_CLEATS)
        # Local pad +Z aligns with outward track normal ang (ang - pi/2 rotation about X: local +Z -> (cos, sin) in (y, z)? Wait:
        # In Blender R("X", deg): Y' = Y*cos - Z*sin, Z' = Y*sin + Z*cos!
        # Setting local +Z along (cos(ang), sin(ang)) requires -sin(rot) = cos(ang), cos(rot) = sin(ang) => rot = ang - pi/2!
        # Let's check top run ang = +pi/2 => rot = 0 deg -> local +Z = +Z world!
        # Bottom run ang = -pi/2 => rot = -180 deg -> local +Z = -Z world!
        m = T(x, y, z) @ R("X", math.degrees(ang) - 90.0)
        tread.side_prism(pad_prof, -w * 0.52, w * 0.52, "rubber", matrix=m)
        tread.box((0.0, 0.0, 0.051), (w * 0.96, 0.030, 0.018), "steel_dark", matrix=m)

    return [tread] + wheels


@model("tank")
def tank():
    """Factorio's tank, front north, built directly in true world proportions: two 3-circle
    caterpillar track runs (`anim_tread_l`/`anim_tread_r` + 14 true-circle `anim_wheel_track`
    wheels) in open bogie suspension frames; stepped rusty side fenders with a rear-west
    perforated steel catwalk; a curved V-notched front bulldozer ram/plough framing recessed
    glowing headlights (`anim_headlight`); a pale steel front engine deck with 4 curved exhaust
    manifold pipes per side; a sloped riveted casemate with bolted steel side access doors and
    rear-corner cylindrical drums; ONE horizontal east-west cream rear fuel tank with bolted
    top hatch in a protective roll frame; and a ribbed cast-iron domed cupola turret
    (`anim_turret_head`) with independent recoiling twin cannons (`anim_turret_barrel`) and
    lower central coaxial MG/flamethrower barrel (`anim_turret_coax`)."""
    p = Part()
    running = []
    for sx, side_tag in ((-1, "l"), (1, "r")):
        running += track_assembly(p, sx * 0.66, side_tag, w=0.36)

    # Lower armored hull spine & front/rear plates.
    p.slab(-0.48, -1.28, 0.24, 0.48, 1.38, 0.74, "rust_dark", bevel=0.04)

    # Mid-track stepped rusty fenders & side skirt boxes (leaving front/rear top cleats exposed!).
    for sx in (-1, 1):
        x0, x1 = sorted((sx * 0.45, sx * 0.90))
        p.slab(x0, -0.56, 0.69, x1, 0.62, 0.80, "rust_brown", bevel=0.025)
        # Stepped mid-fender storage/armor blocks.
        bx0, bx1 = sorted((sx * 0.72, sx * 0.93))
        p.slab(bx0, -0.32, 0.54, bx1, 0.36, 0.84, "steel_dark", bevel=0.02)
        p.slab(bx0, -0.24, 0.82, bx1 - sx * 0.03, 0.28, 0.92, "steel", bevel=0.015)
        for k in range(5):
            p.bolt((sx * 0.905, -0.45 + k * 0.24, 0.77), "steel_light", radius=0.018, axis="X")

    # Signature rear-west perforated steel catwalk step (-X side only, as in Factorio's sprite).
    p.slab(-0.98, -1.30, 0.65, -0.76, -0.46, 0.73, "steel_light", bevel=0.015)
    for k in range(6):
        p.slab(-0.94, -1.22 + k * 0.13, 0.725, -0.80, -1.16 + k * 0.13, 0.738, "soot")

    # Curved V-notched front bulldozer ram/plough (`y = 1.40..1.78`) leaving central notch open.
    wing_prof = [
        (1.40, 0.14), (1.58, 0.11), (1.72, 0.23), (1.77, 0.44), (1.69, 0.68),
        (1.60, 0.72), (1.66, 0.44), (1.56, 0.26), (1.40, 0.26),
    ]
    for sx in (-1, 1):
        m_wing = T(sx * 0.54, 1.56, 0.0) @ R("Z", sx * 8.0) @ T(-sx * 0.54, -1.56, 0.0)
        x0, x1 = sorted((sx * 0.21, sx * 0.88))
        p.side_prism(wing_prof, x0, x1, "rust_brown", bevel=0.015, matrix=m_wing)
        p.beam((sx * 0.46, 1.24, 0.56), (sx * 0.56, 1.60, 0.36), 0.11, 0.07, "steel_dark", up=(0, 0, 1))
        p.beam((sx * 0.38, 1.32, 0.36), (sx * 0.52, 1.56, 0.24), 0.09, 0.06, "steel_dark", up=(0, 0, 1))
        for z in (0.28, 0.54):
            p.bolt((sx * 0.64, 1.72, z), "steel_light", radius=0.02, axis="Y")
    # Lower chin bar uniting the V-notch below the headlights.
    p.slab(-0.24, 1.44, 0.14, 0.24, 1.64, 0.38, "rust_dark", bevel=0.02)

    # Front armored engine deck (`steel_light`) + recessed headlight bay + 4 curved exhaust pipes/side.
    p.slab(-0.36, 0.52, 0.72, 0.36, 1.34, 1.04, "steel_light", bevel=0.03)
    p.slab(-0.24, 0.60, 1.03, 0.24, 1.26, 1.09, "steel", bevel=0.015)
    for sx in (-1, 1):
        p.slab(min(sx * 0.08, sx * 0.22), 0.62, 1.08, max(sx * 0.08, sx * 0.22), 1.22, 1.12, "steel_dark")
        for k in range(4):
            py = 0.68 + k * 0.165
            p.pipe([(sx * 0.33, py, 0.94), (sx * 0.52, py, 0.92), (sx * 0.56, py, 0.74)], 0.044, "steel_light", segs=6)
    # Recessed twin headlight bay in the front nose (visible through the V-notch).
    p.slab(-0.26, 1.26, 0.66, 0.26, 1.40, 0.92, "steel_dark", bevel=0.02)
    p.slab(-0.22, 1.37, 0.70, 0.22, 1.41, 0.86, "soot")
    p.cyl((0.0, 1.415, 0.87), 0.022, 0.48, "steel", segs=6, axis="X")
    headlight = Part("anim_headlight", pivot=(0.0, 1.39, 0.78))
    for sx in (-1, 1):
        headlight.cyl((sx * 0.12, 1.395, 0.78), 0.052, 0.015, "lamp_headlight", segs=10, axis="Y")

    # Tall sloped trapezoidal armored casemate (`y = -0.60..0.56, z = 0.74..1.40`).
    # Built as a smooth tapered octagonal/box hull tapering into the turret collar.
    casemate = Part()
    casemate.prism([(-0.68, -0.60), (0.68, -0.60), (0.68, 0.42), (0.48, 0.60), (-0.48, 0.60), (-0.68, 0.42)],
                   0.74, 1.38, "rust_brown", bevel=0.04)
    casemate.warp(lambda co: (
        co.x * (1.0 - 0.18 * max(0.0, co.z - 0.74) / 0.64),
        co.y * (1.0 - 0.10 * max(0.0, co.z - 0.74) / 0.64),
        co.z,
    ))
    p.add_part(casemate)
    # Heavy circular bolted turret ring collar at z = 1.36..1.42 (zero gap beneath turret!).
    p.ring_band((0.0, 0.0), 0.48, 0.59, 1.34, 1.42, 0, 360, "rust_dark", segs=18, bevel=0.015)
    p.bolts_ring((0.0, 0.0, 1.425), 0.54, 10, "steel_light", radius=0.016)

    # Bolted steel side access doors on both flanks of the casemate (with horizontal rusty hinges).
    for sx in (-1, 1):
        m_door = T(sx * 0.62, -0.05, 1.08) @ R("Y", sx * -9.0)
        p.box((0, 0, 0), (0.07, 0.52, 0.42), "steel_dark", bevel=0.015, matrix=m_door)
        p.box((sx * 0.025, 0, 0), (0.04, 0.44, 0.34), "steel_light", bevel=0.01, matrix=m_door)
        for dz in (-0.09, 0.09):
            p.box((sx * 0.048, -0.10, dz), (0.025, 0.22, 0.055), "rust_brown", matrix=m_door)
        p.box((sx * 0.048, 0.15, 0.0), (0.03, 0.06, 0.04), "steel_dark", matrix=m_door)
        # Rear-corner vertical cylindrical air-filter / coolant drums.
        p.cyl((sx * 0.61, -0.58, 1.04), 0.135, 0.42, "steel_light", segs=12)
        p.sphere((sx * 0.61, -0.58, 1.25), 0.135, "steel_light", segs=12, rings=4, hemisphere=True, scale=(1, 1, 0.4))
        for z in (0.94, 1.16):
            p.cyl((sx * 0.61, -0.58, z), 0.145, 0.035, "steel_dark", segs=12)

    # Rear ONE horizontal east-west weathered-white fuel tank + bolted top hatch + protective frame.
    p.slab(-0.56, -1.28, 0.72, 0.56, -0.60, 0.80, "rust_dark", bevel=0.02)
    p.cyl((0.0, -0.94, 1.04), 0.275, 0.86, "tank_white", segs=12, axis="X", bevel=0.04)
    for sx in (-1, 1):
        p.sphere((sx * 0.43, -0.94, 1.04), 0.275, "tank_white", segs=12, rings=4, scale=(0.45, 1.0, 1.0))
        p.cyl((sx * 0.24, -0.94, 1.04), 0.288, 0.042, "steel_dark", segs=12, axis="X")
    # Bolted circular filler hatch on top of the rear fuel tank.
    p.cyl((0.0, -0.94, 1.32), 0.165, 0.05, "steel_light", segs=10, bevel=0.01)
    p.bolts_ring((0.0, -0.94, 1.35), 0.125, 6, "steel_dark", radius=0.016)
    p.cyl((0.0, -0.94, 1.36), 0.045, 0.04, "rust_brown", segs=8)
    # Protective rear steel roll-bar frame & 3 rear exhaust/tow stubs.
    for sx in (-1, 1):
        p.pipe([(sx * 0.60, -0.62, 1.24), (sx * 0.60, -1.28, 1.24), (sx * 0.60, -1.28, 0.78)], 0.036, "steel_dark", segs=6)
    p.cyl((0.0, -1.28, 1.24), 0.036, 1.20, "steel_dark", segs=6, axis="X")
    for rx in (-0.18, 0.0, 0.18):
        p.cyl((rx, -1.35, 0.58), 0.048, 0.16, "steel_dark", segs=8, axis="Y")
        p.cyl((rx, -1.43, 0.58), 0.034, 0.02, "soot", segs=6, axis="Y")

    # Ribbed cast-iron domed cupola turret + independent recoiling twin cannon & coax MG barrels.
    tz = 1.40
    head = Part("anim_turret_head", pivot=(0.0, 0.0, tz))
    head.cyl((0.0, 0.0, tz + 0.05), 0.55, 0.10, "steel_dark", segs=14)
    space_kit.lathe(
        head,
        (0.0, 0.0, tz + 0.06),
        [(0.54, 0.0), (0.53, 0.14), (0.47, 0.34), (0.39, 0.45), (0.36, 0.50), (0.0, 0.51)],
        "steel_light",
        segs=14,
    )
    # 16 vertical fluted armor ribs around the dome slope (clear of front gun mantlet).
    for k in range(16):
        ang = 22.5 * k
        if 65.0 < ang < 115.0:
            continue
        rad = math.radians(ang)
        ca, sa = math.cos(rad), math.sin(rad)
        m_rib = T(0.49 * ca, 0.49 * sa, tz + 0.27) @ R("Z", ang) @ R("Y", -17.0)
        head.box((0.0, 0.0, 0.0), (0.065, 0.070, 0.34), "steel", matrix=m_rib)
    # Domed upper cupola cap & perimeter rivets.
    space_kit.lathe(
        head,
        (0.0, 0.0, tz + 0.54),
        [(0.38, 0.0), (0.37, 0.09), (0.28, 0.20), (0.15, 0.26), (0.0, 0.27)],
        "steel_light",
        segs=12,
    )
    head.bolts_ring((0.0, 0.0, tz + 0.62), 0.35, 8, "steel_dark", radius=0.018)
    # Signature rusty spine arch strap cleanly outside the dome + bolted commander's cupola hatch.
    spine = [(-0.56, tz + 0.14), (-0.54, tz + 0.34), (-0.42, tz + 0.62), (-0.28, tz + 0.79),
             (0.0, tz + 0.85), (0.28, tz + 0.79), (0.42, tz + 0.62), (0.50, tz + 0.44),
             (0.42, tz + 0.42), (0.34, tz + 0.56), (0.22, tz + 0.72), (0.0, tz + 0.78),
             (-0.22, tz + 0.72), (-0.35, tz + 0.54), (-0.46, tz + 0.32), (-0.46, tz + 0.14)]
    head.side_prism(spine, -0.10, 0.10, "rust_brown")
    head.cyl((0.0, -0.02, tz + 0.80), 0.165, 0.07, "rust_dark", segs=12, bevel=0.015)
    head.bolts_ring((0.0, -0.02, tz + 0.84), 0.12, 6, "steel_light", radius=0.016)
    head.cyl((0.0, -0.02, tz + 0.85), 0.04, 0.04, "steel", segs=8)
    # Armored front gun mantlet & recoil cradle sleeves.
    head.slab(-0.26, 0.34, tz + 0.08, 0.26, 0.64, tz + 0.48, "rust_dark", bevel=0.03)
    head.slab(-0.22, 0.52, tz + 0.24, 0.22, 0.70, tz + 0.42, "rust_brown", bevel=0.02)
    for sx in (-1, 1):
        head.cyl((sx * 0.135, 0.62, tz + 0.34), 0.082, 0.16, "steel_dark", segs=10, axis="Y")
    head.cyl((0.0, 0.60, tz + 0.16), 0.056, 0.14, "steel_dark", segs=8, axis="Y")

    # Twin heavy cannon barrels (`anim_turret_barrel`).
    barrel = Part("anim_turret_barrel", pivot=(0.0, 0.0, tz))
    for sx in (-1, 1):
        bx = sx * 0.135
        bz = tz + 0.34
        barrel.cyl((bx, 0.74, bz), 0.062, 0.26, "steel_dark", segs=10, axis="Y", bevel=0.01)
        barrel.cyl((bx, 1.09, bz), 0.045, 0.46, "steel_light", segs=10, axis="Y")
        barrel.cyl((bx, 1.35, bz), 0.060, 0.12, "steel_dark", segs=10, axis="Y", bevel=0.01)
        barrel.cyl((bx, 1.415, bz), 0.034, 0.02, "soot", segs=8, axis="Y")

    # Lower centered coaxial MG / flamethrower tube (`anim_turret_coax`).
    coax = Part("anim_turret_coax", pivot=(0.0, 0.0, tz))
    cz = tz + 0.16
    coax.cyl((0.0, 0.72, cz), 0.040, 0.26, "steel_dark", segs=8, axis="Y", bevel=0.008)
    coax.cyl((0.0, 0.94, cz), 0.028, 0.20, "steel", segs=8, axis="Y")
    coax.cyl((0.0, 1.045, cz), 0.018, 0.015, "soot", segs=6, axis="Y")

    return [
        p,
        own_materials(head, "turret"),
        own_materials(barrel, "turret"),
        own_materials(coax, "turret"),
        headlight,
    ] + running


# Spidertron: legs from the hips (Factorio's mount_position) to the feet (ground_position),
# Factorio coordinates (x east, y south), tiles.
SPIDER_LEGS = [((15, -22), (2.25, -2.5)), ((23, -10), (3.0, -1.0)), ((25, 4), (3.0, 1.0)), ((15, 17), (2.25, 2.5))]
SPIDER_HIP_Z = 2.55
SPIDER_KNEE_Z = 3.8
SPIDER_KNEE_AT = 0.4  # of the way from hip to foot (Factorio's knee_distance_factor)


def spider_hip(mx, my, sx, zb):
    """A hip ball on the bowl's rim, towards the leg's mount_position (about 0.9 tiles out)."""
    return Vector((sx * mx / 32.0 * 1.15, -my / 32.0 * 1.15, zb - 0.08))


@model("spidertron")
def spidertron():
    """Factorio's spidertron. The torso floats about two tiles up: a rusty ring underneath
    with ball joints for the hips, and the riveted grey shell on it, bulging into two humps,
    the eyes (red lamps) round the front, the slotted rocket pod at the back, an antenna. The
    eight legs are posed standing (Factorio draws them as separate entities that step on their
    own): upper legs rise from the hips to knees above the shell, lower legs reach down to the
    feet two to three tiles out.

    Moving parts, as Factorio draws it: the shell (`anim_torso`, pivot on its axis) turns with
    the torso's aim over the bowl, which doesn't turn (base_animation has one direction); each
    leg is an upper (`anim_leg_upper`, pivot at the hip) and a lower part (`anim_leg_lower`,
    pivot at the knee), which the client stretches and bends between hip, knee and foot as
    Factorio stretches its leg sprites (vehicle_anim.gd)."""
    p = Part()
    zb = SPIDER_HIP_Z
    # The bottom: a wide shallow rusty bowl, the eight hip balls round its rim and the leg
    # brackets under them (spidertron-body-bottom).
    p.cyl((0, 0, zb - 0.1), 0.62, 0.3, "rust_brown", segs=28, radius_top=0.97, bevel=0.02)
    p.ring_band((0, 0), 0.84, 0.99, zb + 0.03, zb + 0.11, 0, 360, "rust_brown", segs=28, bevel=0.02)
    p.cyl((0, 0, zb - 0.27), 0.56, 0.06, "rust_dark", segs=20)
    p.sphere((0, 0, zb - 0.3), 0.38, "steel_dark", segs=12, rings=6, scale=(1, 1, 0.5))
    for (mx, my), _ in SPIDER_LEGS:
        for sx in (-1, 1):
            hip = spider_hip(mx, my, sx, zb)
            p.sphere(tuple(hip), 0.16, "rust_brown", segs=10, rings=5)
            p.beam((hip.x * 0.7, hip.y * 0.7, zb - 0.22), (hip.x * 1.05, hip.y * 1.05, zb - 0.02), 0.12, 0.08,
                   "steel_dark")
    # Shell: a dome with two humps (front and back), narrower than the bowl, a band round the
    # waist.
    t = Part("anim_torso", pivot=(0.0, 0.0, zb))
    t.sphere((0, 0, zb + 0.08), 0.74, "steel_spider", segs=24, rings=10, hemisphere=True, scale=(1.0, 0.95, 1.45))
    t.sphere((0, -0.1, zb + 0.65), 0.46, "steel_spider", segs=18, rings=8, hemisphere=True, scale=(1.3, 1.1, 1.0))
    t.sphere((0, 0.33, zb + 0.45), 0.37, "steel_spider", segs=18, rings=8, hemisphere=True, scale=(1.3, 0.9, 0.85))
    t.cyl((0, 0, zb + 0.12), 0.77, 0.1, "steel_dark", segs=24)
    for k in range(16):
        a = math.radians(k * 22.5)
        t.bolt((0.78 * math.cos(a), 0.73 * math.sin(a), zb + 0.12), "steel_light", radius=0.03, axis="Z")
    # Eyes: a row of red lamps round the front.
    for k, a in enumerate((60, 75, 90, 105, 120)):
        r = math.radians(a)
        t.sphere((0.7 * math.cos(r), 0.66 * math.sin(r), zb + 0.42 + 0.05 * (k % 2)), 0.06, "lamp_red", segs=8, rings=4)
    for sx in (-1, 1):
        t.sphere((sx * 0.62, 0.35, zb + 0.6), 0.06, "lamp_red", segs=8, rings=4)
        t.sphere((sx * 0.45, -0.55, zb + 0.75), 0.05, "lamp_red", segs=8, rings=4)
    # Rocket pod at the back with its slots, and the hatch above.
    t.slab(-0.42, -0.9, zb + 0.32, 0.42, -0.5, zb + 0.86, "steel_dark", bevel=0.05)
    for k in range(4):
        x = -0.27 + k * 0.18
        t.slab(x - 0.05, -0.92, zb + 0.4, x + 0.05, -0.88, zb + 0.78, "soot")
    # The rusty band round the shell's waist.
    t.ring_band((0, 0), 0.7, 0.82, zb + 0.12, zb + 0.26, 0, 360, "rust_brown", segs=28, bevel=0.03)
    t.tube((0.2, -0.45, zb + 0.95), (0.42, -0.9, zb + 1.7), 0.015, "steel_light", segs=5)
    t.cyl((0.2, -0.45, zb + 0.97), 0.05, 0.06, "steel_dark", segs=8)
    # Legs: their own parts (and materials), coloured from Factorio's leg sprites, not the torso's.
    parts = [p, t]
    for (mx, my), (gx, gy) in SPIDER_LEGS:
        for sx in (-1, 1):
            hip = spider_hip(mx, my, sx, zb)
            foot = Vector((sx * gx, -gy, 0.0))
            knee = hip + (foot - hip) * SPIDER_KNEE_AT
            knee.z = SPIDER_KNEE_Z
            upper = Part("anim_leg_upper", pivot=tuple(hip))
            upper.tube(hip, knee, 0.07, "steel_dark", segs=8)
            upper.tube(hip + (knee - hip) * 0.15, hip + (knee - hip) * 0.85, 0.085, "rust_brown", segs=8)
            # Hydraulic rams along the legs.
            upper.tube(hip + (knee - hip) * 0.3 + Vector((0, 0, 0.1)), knee + (hip - knee) * 0.1 + Vector((0, 0, 0.1)),
                       0.03, "steel_light", segs=5)
            lower = Part("anim_leg_lower", pivot=tuple(knee))
            lower.sphere(knee, 0.11, "steel_dark", segs=10, rings=5)
            lower.tube(knee, foot + Vector((0, 0, 0.18)), 0.06, "steel_dark", segs=8)
            lower.tube(knee + (foot - knee) * 0.1, knee + (foot - knee) * 0.55, 0.075, "rust_brown", segs=8)
            lower.cyl((foot.x, foot.y, 0.08), 0.13, 0.16, "steel_black", segs=10, radius_top=0.07)
            parts += [own_materials(upper, "leg"), own_materials(lower, "leg")]
    return parts


@model("artillery-wagon")
def artillery_wagon():
    """Factorio's artillery wagon, front north, from its base sheets: a heavy riveted flat car on
    two bogies. At the back a square base with rounded corners carries the round armoured ring
    the cannon (`anim_turret_head`) turns on, pointing forward as Factorio parks it, a gauge
    beside it; in the middle an open frame racks brass shells across the car between struts
    rising to the front; at the front a box in yellow and black hazard stripes with a big grille
    on top, red lamps at its corners, an amber lamp and a handle."""
    p = Part()
    axles = []
    for y in (-2.0, 2.0):
        axles += bogie(p, y)
    # Deck and frame, riveted along the sills; hazard plates on the buffer ends.
    along_y(p, mirrored([(0.95, 0.85), (1.0, 1.22)]), -3.25, 3.25, "steel_dark", bevel=0.04)
    for sx in (-1, 1):
        detail.rivet_line(p, (sx * 1.005, -3.1, 1.12), (sx * 1.005, 3.1, 1.12), 26, "X")
    for sy in (-1, 1):
        buffers(p, sy * 3.32)
        for k in range(5):
            x0 = -0.95 + k * 0.38
            p.slab(x0, sy * 3.05, 1.22, x0 + 0.19, sy * 3.25, 1.24, "hazard_black")
            p.slab(x0 + 0.19, sy * 3.05, 1.22, x0 + 0.38, sy * 3.25, 1.24, "hazard_strong")

    # Front: the hazard-striped box, a grille on top inside a striped border, lamps, a handle.
    lo, hi = (-0.86, 1.5, 1.22), (0.86, 3.08, 2.2)
    p.slab(*lo, *hi, "steel", bevel=0.06)
    for face in ("+x", "-x", "+y"):
        detail.stripes(p, lo, hi, face, 7, mats=("hazard_strong", "hazard_black"), slant=0.5, depth=0.012)
    gl, gh = (-0.62, 1.72, 2.2), (0.62, 2.9, 2.24)
    p.slab(*gl, *gh, "steel_dark", bevel=0.01)
    detail.slots(p, gl, gh, "+z", 9, mat="grime", along=1, depth=0.008)
    for sx in (-1, 1):
        p.slab(sx * 0.62, 1.55, 2.2, sx * 0.84, 3.05, 2.215, "hazard_strong")
        for sy, y in ((-1, 1.56), (1, 3.02)):
            p.sphere((sx * 0.8, y, 2.24), 0.04, "lamp_red", segs=6, rings=3)
    p.slab(-0.62, 1.53, 2.2, 0.62, 1.7, 2.215, "hazard_black")
    p.slab(-0.62, 2.92, 2.2, 0.62, 3.05, 2.215, "hazard_black")
    p.pipe([(-0.3, 3.08, 1.95), (-0.3, 3.18, 2.0), (0.3, 3.18, 2.0), (0.3, 3.08, 1.95)], 0.025, "steel_light", segs=6)
    p.slab(-0.42, 1.44, 1.4, 0.42, 1.5, 2.1, "steel_dark")
    p.box((0.0, 1.43, 1.92), (0.12, 0.03, 0.08), "hazard_strong")
    detail.rivet_line(p, (-0.36, 1.435, 1.5), (0.36, 1.435, 1.5), 5, "Y")

    # Middle: an open rack of shells lying across the car, struts rising to the front box.
    p.slab(-0.7, -0.95, 1.22, 0.7, 1.5, 1.32, "steel_black")
    for sx in (-1, 1):
        p.beam((sx * 0.58, -0.95, 1.78), (sx * 0.58, 1.5, 1.78), 0.08, 0.07, "steel", bevel=0.01)
        p.beam((sx * 0.58, -0.95, 1.3), (sx * 0.58, 1.5, 1.3), 0.08, 0.07, "steel")
        for y in (-0.85, -0.15, 0.55, 1.25):
            p.beam((sx * 0.58, y, 1.3), (sx * 0.58, y, 1.8), 0.07, 0.07, "steel", up=(0, 1, 0))
        p.beam((sx * 0.75, -0.6, 1.95), (sx * 0.75, 1.5, 2.15), 0.05, 0.05, "steel_light")
        p.slab(sx * 0.62, -0.9, 1.22, sx * 0.98, 1.45, 1.55, "steel_dark", bevel=0.03)
        detail.rivet_line(p, (sx * 0.985, -0.8, 1.45), (sx * 0.985, 1.35, 1.45), 9, "X")
        p.cyl((sx * 0.8, 0.3, 1.6), 0.12, 1.5, "steel", segs=10, axis="Y", bevel=0.02)
    for y in (-0.62, -0.2, 0.22, 0.64, 1.06):
        p.cyl((0, y, 1.5), 0.15, 0.82, "brass", segs=12, axis="X")
        p.cyl((0.52, y, 1.5), 0.15, 0.22, "steel_dark", segs=12, axis="X", radius_top=0.05)
        p.cyl((-0.43, y, 1.5), 0.155, 0.04, "copper_dull", segs=12, axis="X")
    for y in (-0.85, 0.55):
        p.beam((-0.58, y, 1.78), (0.58, y, 1.78), 0.06, 0.05, "steel")

    # Back: the square base with rounded corners and the armoured ring the cannon turns on.
    ry, zr = -2.07, 1.9
    c = 0.3
    base = [(1.0, -3.2 + c), (1.0, -0.95 - c), (1.0 - c, -0.95), (-1.0 + c, -0.95), (-1.0, -0.95 - c),
            (-1.0, -3.2 + c), (-1.0 + c, -3.2), (1.0 - c, -3.2)]
    p.prism(base, 1.22, 1.5, "steel_dark", bevel=0.05)
    for sx in (-1, 1):
        detail.rivet_line(p, (sx * 1.005, -2.9, 1.4), (sx * 1.005, -1.25, 1.4), 7, "X")
    p.cyl((0, ry, 1.62), 1.06, 0.26, "steel", segs=32, bevel=0.04)
    p.ring_band((0, ry), 0.82, 1.1, 1.74, zr, 0, 360, "steel_dark", segs=32, bevel=0.04)
    p.cyl((0, ry, 1.78), 0.82, 0.04, "soot", segs=28)
    for k in range(16):
        a = math.radians(k * 22.5)
        p.bolt((0.97 * math.cos(a), ry + 0.97 * math.sin(a), zr), "steel_light", radius=0.028)
        p.bolt((1.07 * math.cos(a), ry + 1.07 * math.sin(a), 1.6), "steel_light", radius=0.022, axis="X")
    p.cyl((-0.88, -1.12, 1.68), 0.13, 0.36, "steel_dark", segs=12, bevel=0.02)
    p.cyl((-0.88, -1.12, 1.87), 0.1, 0.02, "ceramic", segs=12)
    p.slab(0.75, -3.15, 1.5, 0.95, -2.85, 1.72, "steel_black", bevel=0.03)
    head = artillery_cannon((0.0, ry), zr, barrel=4.3, elevation=21.0, scale=1.25)
    return [p, head] + axles


# ---------------------------------------------------------------------------------------------
# Combat robots. Drawn flying (the client lifts them, visuals.gd FLYING); modelled from the
# ground up, their features at the back (-y) as the sprites' first frame shows them.

@model("defender")
def defender():
    """Factorio's defender: a white dome with a copper band, its stubby gun leaning out of the
    back of the dome, a stack of dark rings underneath, a nozzle pointing forward and down, two thin
    legs out to the sides with cyan lamps."""
    p = Part()
    z = 0.64
    p.sphere((0, 0, z), 0.235, "paint_white", segs=16, rings=6, hemisphere=True, scale=(1, 1, 0.6))
    p.cyl((0, 0, z - 0.01), 0.24, 0.03, "copper_dull", segs=16)
    for k, r in enumerate((0.225, 0.22, 0.21, 0.2, 0.18)):
        p.cyl((0, 0, z - 0.06 - 0.066 * k), r, 0.056, "rust_brown" if k % 2 else "steel_dark", segs=14)
    p.tube((0, -0.12, z + 0.05), (0, -0.27, z + 0.08), 0.07, "paint_white", segs=6, radius_top=0.045)
    # A block on the front of the rings with the nozzle straight out of it, a post underneath.
    p.slab(-0.09, 0.12, z - 0.38, 0.09, 0.25, z - 0.2, "blue_steel", bevel=0.015)
    p.cyl((0, 0.255, z - 0.29), 0.05, 0.02, "rust_brown", segs=8, axis="Y")
    p.tube((0.0, 0.25, z - 0.29), (0.0, 0.4, z - 0.29), 0.035, "steel", segs=6)
    p.cyl((0, 0, z - 0.43), 0.06, 0.12, "steel_dark", segs=8)
    for sx in (-1, 1):
        p.tube((sx * 0.17, 0, z - 0.1), (sx * 0.37, 0, z - 0.3), 0.014, "steel_dark", segs=4)
        p.sphere((sx * 0.37, 0, z - 0.3), 0.027, "lamp_cyan", segs=6, rings=3)
    # Modelled at the sprite's heights, then set down on the ground like the other robots.
    p.transform(T(0, 0, -0.15))
    return p


@model("distractor")
def distractor():
    """Factorio's distractor: a squat riveted copper-and-steel body, an octagonal collar on top
    round a fan of radial vanes, short cylinders out east and west, four legs with cyan lamps
    and a stacked nozzle leaning down and out at the back."""
    p = Part()
    z = 0.5
    p.cyl((0, 0, z - 0.035), 0.33, 0.21, "copper_dull", segs=16, bevel=0.04)
    p.cyl((0, 0, z + 0.1), 0.33, 0.06, "copper_dull", segs=16, radius_top=0.25)
    oct_out, oct_in = octagon(0.25), octagon(0.19)
    for i in range(8):
        a, b = oct_out[i], oct_out[(i + 1) % 8]
        c, d = oct_in[i], oct_in[(i + 1) % 8]
        p.prism([a, b, d, c], z + 0.1, z + 0.22, "paint_cream")
    p.cyl((0, 0, z + 0.135), 0.19, 0.01, "soot", segs=12)
    for k in range(8):
        a = math.radians(k * 45 + 22.5)
        p.beam((0, 0, z + 0.18), (0.18 * math.cos(a), 0.18 * math.sin(a), z + 0.17), 0.03, 0.015, "brass")
    p.sphere((0, 0, z + 0.185), 0.035, "brass", segs=6, rings=3)
    for k in range(12):
        a = math.radians(k * 30)
        p.bolt((0.32 * math.cos(a), 0.32 * math.sin(a), z + 0.06), "steel_light", radius=0.02, axis="Z")
    for sx in (-1, 1):
        p.cyl((sx * 0.4, 0, z - 0.1), 0.06, 0.14, "steel_dark", segs=8, axis="X")
        p.cyl((sx * 0.48, 0, z - 0.1), 0.045, 0.04, "steel_light", segs=8, axis="X")
    for x, y in ((0.32, 0.3), (-0.32, 0.3), (-0.32, -0.3), (0.32, -0.3)):
        p.tube((0.6 * x, 0.6 * y, z - 0.02), (x, y, z - 0.02), 0.014, "steel_dark", segs=4)
        p.sphere((x, y, z - 0.02), 0.032, "lamp_cyan", segs=6, rings=3)
    d = Vector((0, -0.3, -1)).normalized()
    root = Vector((0, -0.1, z - 0.12))
    for k in range(4):
        q = root + d * (0.07 * k)
        p.tube(q, q + d * 0.06, 0.075 - 0.01 * k, "brass" if k % 2 else "steel_dark", segs=8)
    p.tube(root + d * 0.28, root + d * 0.36, 0.03, "steel_black", segs=6)
    # Modelled at the sprite's heights, then set down on the ground like the other robots; sized
    # to all 16 rotation frames (tools/models/fit_cells.py --fit scale): narrower, taller.
    p.transform(S(0.928, 1.007, 1.064) @ T(0, 0, -0.027))
    return p


@model("destroyer")
def destroyer():
    """Factorio's destroyer: a big riveted steel dome in six segments over a copper skirt, a
    cap on top, a dark bowl underneath, four ringed horn-like guns out round it, leaning down,
    and a red lamp under the middle."""
    p = Part()
    z = 0.6
    r = 0.4
    p.sphere((0, 0, z), r, "steel_spider", segs=20, rings=8, hemisphere=True, scale=(1, 1, 1.0))
    for k in range(6):
        a = math.radians(k * 60)
        p.beam((0.1 * math.cos(a), 0.1 * math.sin(a), z + 0.39), (r * math.cos(a), r * math.sin(a), z + 0.02),
               0.03, 0.03, "steel_dark")
    for ring, zz in ((0.38, z + 0.13), (0.3, z + 0.28)):
        for k in range(10):
            a = math.radians(k * 36 + 18)
            p.bolt((ring * math.cos(a), ring * math.sin(a), zz), "steel_dark", radius=0.02, axis="Z")
    p.sphere((0, 0, z + 0.37), 0.12, "steel", segs=10, rings=4, hemisphere=True)
    p.cyl((0, 0, z - 0.03), r + 0.01, 0.08, "copper_dull", segs=20, bevel=0.01)
    p.sphere((0, 0, z - 0.06), r - 0.04, "steel_dark", segs=16, rings=6, scale=(1, 1, 0.5))
    # Four ringed guns, one each way, leaning down; the red lamp hangs under the middle.
    for k in range(4):
        a = math.radians(k * 90)
        out = Vector((math.cos(a), math.sin(a), 0))
        d = (out - Vector((0, 0, 0.45))).normalized()
        root = out * 0.3 + Vector((0, 0, z - 0.09))
        for j in range(3):
            q = root + d * (0.1 * j)
            p.tube(q, q + d * 0.09, 0.085 - 0.017 * j, "brass" if j % 2 else "steel", segs=8,
                   radius_top=0.075 - 0.017 * j)
        p.tube(root + d * 0.3, root + d * 0.36, 0.03, "soot", segs=6)
    p.cyl((0, 0, z - 0.25), 0.05, 0.05, "steel_dark", segs=8)
    p.sphere((0, 0, z - 0.28), 0.025, "lamp_red", segs=6, rings=3)
    # Modelled at the sprite's heights, then set down on the ground like the other robots; sized
    # to all 32 rotation frames (tools/models/fit_cells.py --fit scale).
    p.transform(S(1.04, 1.031, 1.057) @ T(0, 0, -0.295))
    return p
