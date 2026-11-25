"""Cliffs, modelled on Factorio's cliff sprites (data/base/graphics/terrain/cliffs/, and Space
Age's under data/space-age/graphics/terrain/cliffs/<planet>/).

A Factorio cliff is a chain of entities on a 4x4-tile grid. Each one runs from the middle of one
edge of its cell to the middle of another (`cliff_orientation`, "west-to-east" ... "none-to-north")
with the high ground on its left; the cliff face looks out to the right, over the low ground.
Twenty orientations come from five pieces, each turned in quarter turns by the client
(model_library.gd, CLIFF_PIECES):

    sides     straight, west to east (the face looks south)
    outer     turning left, west to north: a corner of the high ground
    inner     turning right, west to south: a bay in the high ground
    exit      west to none: the cliff runs out in the middle of the cell
    entrance  none to east: the cliff starts in the middle of the cell

Every piece has the same cross-section where it meets the edge of its cell, so any chain joins
up. The ground stays flat in the client, so a cliff is a ridge: a steep face of tall, broken,
column-like blocks (the Nauvis sprites' look; Vulcanus, Gleba and Fulgora have flat layered
slabs instead), a crest with loose boulders, and a slope back down on the high side. Sizes
come from the HR sprites: the tallest blocks stand about 2.6 tiles high and the whole cliff is about
3.3 tiles across.

Nauvis's pieces are one fused wall of blocks with a scree apron and crest stones (`wall` below),
with seeded variants `cliff-<piece>-1`...; its first pieces (separate columns, `columns`) are kept
as `cliff-<piece>-old` for the client's `--cliff-pieces=old`.
"""

import math

from mathutils import Vector

from geo import material
from rocks import column, fragment

ROCK = material("cliff-rock", "#8a6844", 0.95)
ROCK_DARK = material("cliff-rock-dark", "#4a3620", 1.0)
HEIGHT = 2.5
# The cross-section, from the high side to the low: (offset towards the face, height / HEIGHT).
# The crest stands a little in front of the line and the face's foot near the cell's edge, as
# the sprites have it (seen along the cliff, the north-south sprites span -1.5 to +1.75 tiles).
PROFILE = ((-1.5, 0.0), (-1.0, 0.25), (-0.5, 0.58), (-0.1, 0.74), (0.25, 0.76), (0.7, 0.5), (1.2, 0.22),
           (1.75, 0.0))
STEPS = 16

PLANETS = {
    # suffix: (rock, dark rock, style)
    "": (ROCK, ROCK_DARK, "wall"),
    "old": (ROCK, ROCK_DARK, "columns"),  # Nauvis's old pieces, `cliff-<piece>-old`
    "vulcanus": (material("cliff-vulcanus-rock", "#4a4440", 0.95), material("cliff-vulcanus-rock-dark", "#1e1b1a", 1.0),
                 "slabs"),
    "gleba": (material("cliff-gleba-rock", "#6a6a58", 0.95), material("cliff-gleba-rock-dark", "#2c2e24", 1.0),
              "slabs"),
    "fulgora": (material("cliff-fulgora-rock", "#9a5a58", 0.95), material("cliff-fulgora-rock-dark", "#4a2626", 1.0),
                "slabs"),
}
# Gleba's cliffs are wrapped in orange roots.
GLEBA_ROOT = material("cliff-gleba-flesh-root", "#a06a2a", 0.8)


def smooth(a, b, x):
    t = min(1.0, max(0.0, (x - a) / (b - a)))
    return t * t * (3.0 - 2.0 * t)


def path(kind):
    """The piece's line as a function of t in 0..1 -> (point, tangent, scale): x east, y north,
    in tiles from the cell's centre. `scale` shrinks the ridge where a cliff starts or ends."""
    if kind == "sides":
        return lambda t: (Vector((-2.0 + 4.0 * t, 0.0)), Vector((1.0, 0.0)), 1.0)
    if kind == "outer":  # quarter circle round the north-west corner, turning left
        def outer(t):
            a = math.radians(-90.0 + 90.0 * t)
            return (Vector((-2.0, 2.0)) + 2.0 * Vector((math.cos(a), math.sin(a))),
                    Vector((-math.sin(a), math.cos(a))), 1.0)
        return outer
    if kind == "inner":  # quarter circle round the south-west corner, turning right
        def inner(t):
            a = math.radians(90.0 - 90.0 * t)
            return (Vector((-2.0, -2.0)) + 2.0 * Vector((math.cos(a), math.sin(a))),
                    Vector((math.sin(a), -math.cos(a))), 1.0)
        return inner
    if kind == "exit":
        return lambda t: (Vector((-2.0 + 3.0 * t, 0.0)), Vector((1.0, 0.0)), 1.0 - smooth(0.35, 1.0, t))
    if kind == "entrance":
        return lambda t: (Vector((-1.0 + 3.0 * t, 0.0)), Vector((1.0, 0.0)), smooth(0.0, 0.65, t))
    raise ValueError(kind)


def length(kind):
    return {"sides": 4.0, "outer": math.pi, "inner": math.pi, "exit": 3.0, "entrance": 3.0}[kind]


def frame(f, t, r, z):
    """A point `r` tiles to the right of the line (towards the face) at height z."""
    p, tangent, _ = f(t)
    right = Vector((tangent.y, -tangent.x))
    q = p + right * r
    return Vector((q.x, q.y, z))


def body(m, kind, rock, rng):
    """The ridge itself: the profile swept along the line, wobbling a little except at the ends
    (where it must meet the next piece exactly)."""
    f = path(kind)
    bm = m.bm
    rings = []
    for i in range(STEPS + 1):
        t = i / STEPS
        s = f(t)[2]
        edge = min(t, 1.0 - t)
        wobble = smooth(0.0, 0.12, edge) if kind not in ("exit", "entrance") else smooth(0.0, 0.12, t if kind == "exit" else 1.0 - t)
        ring = []
        for k, (r, h) in enumerate(PROFILE):
            w = wobble * (0.0 if h == 0.0 else rng.uniform(-0.12, 0.12))
            reach = 0.35 + 0.65 * s  # a dying cliff is narrower as well as lower
            ring.append(bm.verts.new(frame(f, t, r * reach + w, max(0.0, h * HEIGHT * s * (1.0 + w)) - (0.06 if h == 0.0 else 0.0))))
        rings.append(ring)
    verts = []
    for a, b in zip(rings, rings[1:]):
        for k in range(len(PROFILE) - 1):
            bm.faces.new((a[k], a[k + 1], b[k + 1], b[k]))
        verts += a
    verts += rings[-1]
    for ring in (rings[0], rings[-1]):
        if f(0.0 if ring is rings[0] else 1.0)[2] > 0.05:
            bm.faces.new(ring)
    m._tag(verts, rock, False, (0.85, 0.85, 0.85), 0.15)


def columns(m, kind, rock, dark, rng):
    """Tall, broken, column-like blocks standing along the face (Nauvis), shorter ones in front
    of them and a skirt of fallen stones at the foot."""
    f = path(kind)
    n = int(length(kind) / 0.5)
    for i in range(n):
        t = (i + rng.uniform(0.25, 0.75)) / n
        s = f(t)[2]
        if s < 0.12:
            continue
        h = HEIGHT * s * rng.uniform(0.62, 1.04)
        reach = 0.35 + 0.65 * s
        base = frame(f, t, rng.uniform(0.15, 0.55) * reach, 0.0)
        p, tangent, _ = f(t)
        out = Vector((tangent.y, -tangent.x, 0.0))
        # Leaning back a little into the cliff, so the tops sit on the crest.
        column(m, base, rng.uniform(0.3, 0.42) * (0.6 + 0.4 * s), h, rock, sides=rng.choice((5, 6)),
               lean=(-out.x * 0.25, -out.y * 0.25), taper=0.8, tint=(rng.uniform(0.75, 1.0),) * 3)
    for i in range(int(n * 0.8)):
        t = (i + rng.uniform(0.0, 1.0)) / int(n * 0.8)
        s = f(t)[2]
        if s < 0.25:
            continue
        base = frame(f, t, rng.uniform(0.8, 1.15) * (0.35 + 0.65 * s), 0.0)
        column(m, base, rng.uniform(0.2, 0.3), HEIGHT * s * rng.uniform(0.2, 0.45), rock, sides=5,
               taper=0.8, tint=(rng.uniform(0.65, 0.85),) * 3)
    lip_and_rubble(m, kind, rock, dark, rng, n)


def slabs(m, kind, rock, dark, rng):
    """Flat layered slabs stacked up the face (Vulcanus, Gleba, Fulgora): each layer a little
    further back than the one under it, with ragged ends."""
    f = path(kind)
    n = int(length(kind) / 0.5)
    layers = 4
    for i in range(n):
        t = (i + 0.5) / n
        s = f(t)[2]
        if s < 0.12:
            continue
        p, tangent, _ = f(t)
        for k in range(layers):
            z0 = HEIGHT * s * k / layers
            z1 = HEIGHT * s * (k + 1) / layers * rng.uniform(0.95, 1.05)
            r = 1.3 - 1.0 * k / layers + rng.uniform(-0.06, 0.06)
            c = frame(f, t, (r - 0.35) * (0.4 + 0.6 * s), z0)
            half = Vector((tangent.x, tangent.y, 0.0)) * rng.uniform(0.3, 0.42)
            depth = Vector((tangent.y, -tangent.x, 0.0)) * 0.35
            slab(m, c, half, depth, z1 - z0, rock if k % 2 == 0 else dark, rng)
    lip_and_rubble(m, kind, rock, dark, rng, n)


def slab(m, centre, half, depth, height, mat, rng):
    """A block with a slightly tilted, uneven top: one layer of a stratified cliff."""
    bm = m.bm
    corners = [centre - half - depth, centre + half - depth, centre + half + depth, centre - half + depth]
    corners = [c + Vector((rng.uniform(-0.05, 0.05), rng.uniform(-0.05, 0.05), 0.0)) for c in corners]
    low = [bm.verts.new(c - Vector((0, 0, 0.03))) for c in corners]
    high = [bm.verts.new(c + Vector((0, 0, height * rng.uniform(0.9, 1.08)))) for c in corners]
    for k in range(4):
        bm.faces.new((low[k], low[(k + 1) % 4], high[(k + 1) % 4], high[k]))
    bm.faces.new(high)
    m._tag(low + high, mat, False, (rng.uniform(0.8, 1.0),) * 3)


def lip_and_rubble(m, kind, rock, dark, rng, n):
    """Pale boulders along the crest (what Factorio shows of a cliff seen from the high side) and
    fallen stones in front of the face."""
    f = path(kind)
    for i in range(max(3, n // 3)):
        t = (i + rng.uniform(0.2, 0.8)) / max(3, n // 3)
        s = f(t)[2]
        if s < 0.3:
            continue
        r = rng.uniform(-0.35, 0.05)
        z = HEIGHT * s * 0.7
        fragment(m, frame(f, t, r, z), rng.uniform(0.16, 0.26) * s, rock, scale=(1.2, 1.0, 0.75),
                 tint=(rng.uniform(0.95, 1.1),) * 3)
    for i in range(max(4, int(n * 0.7))):
        t = rng.uniform(0.04, 0.96)
        s = f(t)[2]
        if s < 0.2:
            continue
        fragment(m, frame(f, t, rng.uniform(1.3, 2.0) * (0.5 + 0.5 * s), 0.0), rng.uniform(0.07, 0.17), dark,
                 scale=(1.2, 1.0, 0.7), tint=(rng.uniform(0.7, 0.95),) * 3)


def roots(m, kind, rng):
    """Gleba: thick orange roots drape from the crest and fork across the low ground."""
    f = path(kind)
    n = max(5, int(length(kind) / 0.52))
    for i in range(n):
        t = (i + rng.uniform(0.2, 0.8)) / n
        s = f(t)[2]
        if s < 0.3:
            continue
        # Each tendril sweeps sideways along the cliff as it drapes over the face, then spreads
        # across the ground. This follows Gleba's wide branching root fans instead of making
        # parallel vertical ropes.
        drift = rng.choice((-1, 1)) * rng.uniform(0.14, 0.28)
        t1 = min(0.98, max(0.02, t + drift * 0.35))
        t2 = min(0.98, max(0.02, t + drift))
        t3 = min(0.98, max(0.02, t + drift * 1.45))
        top = frame(f, t, -0.16, HEIGHT * s * 0.98)
        mid = frame(f, t1, 0.22, HEIGHT * s * 0.84)
        shoulder = frame(f, t2, 0.82, HEIGHT * s * 0.58)
        lower = frame(f, t2, 1.52, HEIGHT * s * 0.32)
        outer = frame(f, t3, 2.18, HEIGHT * s * 0.12)
        foot = frame(f, t3, rng.uniform(2.65, 3.25), 0.0)
        m.tube((top, mid, shoulder, lower, outer, foot), (0.19, 0.17, 0.14, 0.10, 0.06, 0.022),
               GLEBA_ROOT, segments=5, smooth=False)
        fork_t = min(0.98, max(0.02, t2 - math.copysign(rng.uniform(0.25, 0.38), drift)))
        fork = frame(f, fork_t, rng.uniform(2.4, 3.1), 0.0)
        m.tube((shoulder, frame(f, fork_t, 1.5, HEIGHT * s * 0.38), fork),
               (0.105, 0.065, 0.02), GLEBA_ROOT, segments=5, smooth=False)


def shade(m):
    def fn(face, p, n):
        h = min(1.0, max(0.0, p.z / HEIGHT))
        up = max(0.0, n.z)
        return 0.35 + 0.65 * min(1.0, 0.2 + 0.45 * h + 0.45 * up)
    m.shade(fn)


def cliff(kind, planet=""):
    rock, dark, style = PLANETS[planet]

    def build(m):
        rng = m.rng
        body(m, kind, rock, rng)
        if style == "columns":
            columns(m, kind, rock, dark, rng)
        else:
            slabs(m, kind, rock, dark, rng)
        if planet == "gleba":
            roots(m, kind, rng)
        shade(m)
    return build




# --- Nauvis: one fused wall (the look since the cliff-models work) ---------------------------------
#
# Factorio's Nauvis cliff sprites (cliff-sides.png, the south-facing row) are one wall of upright,
# faceted blocks of uneven width standing shoulder to shoulder, about 3 tiles tall on screen, with a
# ragged top line, pale loose scree at the foot (the `-lower` layer) and, seen from the high side,
# only a line of pale crest boulders. Colours from the sprites (R&D cliff-natural-rd): the face's
# mean #3d2d19 and lit quarter #785c3c, the scree's #61492f / #937854, the crest's #765f42 / #b5a07e.
#
# Joins: every piece starts (and ends) with the same joint block, cut by the cell's edge, and the
# shared body's cross-section there is WALL_PROFILE exactly; nothing else reaches the edge. So any
# piece and any variant meets any neighbour (model_packs_test checks the edge cross-sections).

WALL_ROCK = material("cliff-rock", "#6a5034", 0.95)
WALL_SCREE = material("cliff-scree", "#7a6040", 0.97)
WALL_CREST = material("cliff-crest", "#a08a68", 0.95)
# (offset towards the face, height / HEIGHT): the high side's slope, the crest, the face's foot
# behind the blocks, then the scree apron (from WALL_APRON on) running out over the low ground.
WALL_PROFILE = ((-1.5, 0.0), (-1.0, 0.2), (-0.55, 0.52), (-0.25, 0.7), (0.1, 0.72), (0.4, 0.42), (0.62, 0.12),
                (1.15, 0.04), (1.85, 0.0))
WALL_APRON = 6  # segments from this profile point on are scree
# The joint block: (offset towards the face, height / HEIGHT) round its cross-section, the same in
# every piece; JOINT_W tiles of it on each side of the cell's edge.
JOINT = ((-0.32, -0.03), (0.58, -0.03), (0.34, 0.8), (0.14, 0.86), (-0.32, 0.82))
JOINT_W = 0.3


def wall_body(m, kind, rng):
    """The shared body: WALL_PROFILE swept along the line, wobbling inside the cell only."""
    f = path(kind)
    bm = m.bm
    rings = []
    for i in range(STEPS + 1):
        t = i / STEPS
        s = f(t)[2]
        if kind == "exit":
            wobble = smooth(0.0, 0.12, t)
        elif kind == "entrance":
            wobble = smooth(0.0, 0.12, 1.0 - t)
        else:
            wobble = smooth(0.0, 0.12, min(t, 1.0 - t))
        ring = []
        reach = 0.35 + 0.65 * s
        for r, h in WALL_PROFILE:
            w = wobble * (0.0 if h == 0.0 else rng.uniform(-0.1, 0.1))
            z = max(0.0, h * HEIGHT * s * (1.0 + w)) - (0.06 if h == 0.0 else 0.0)
            ring.append(bm.verts.new(frame(f, t, r * reach + w, z)))
        rings.append(ring)
    rock, scree = [], []
    for a, b in zip(rings, rings[1:]):
        for k in range(len(WALL_PROFILE) - 1):
            face = bm.faces.new((a[k], a[k + 1], b[k + 1], b[k]))
            (scree if k >= WALL_APRON else rock).append(face)
    for ring in (rings[0], rings[-1]):
        if f(0.0 if ring is rings[0] else 1.0)[2] > 0.05:
            rock.append(bm.faces.new(ring[:WALL_APRON + 1]))
    for faces, mat in ((rock, WALL_ROCK), (scree, WALL_SCREE)):
        _tag_faces(m, faces, mat, (0.85, 0.85, 0.85))


def _tag_faces(m, faces, mat, tint):
    """Material and corner colour of just these faces (geo.Model or build_plain's plain_geo.Model)."""
    index = m.mat(mat)
    for face in faces:
        face.material_index = index
        face.smooth = False
        if hasattr(face, "loops"):
            for loop in face.loops:
                loop[m.color] = (tint[0], tint[1], tint[2], 1.0)
        else:
            face.colors = [tuple(tint)] * len(face.verts)


def _edge_frame(f, t, s_off):
    """The point and axes `s_off` tiles along the straight tangent from the line's point at t."""
    p, tangent, _ = f(t)
    right = Vector((tangent.y, -tangent.x))
    return p + tangent * s_off, tangent, right


def joint(m, kind, at_start):
    """Half the joint block, cut flat by the cell's edge: identical in every piece and variant."""
    f = path(kind)
    t = 0.0 if at_start else 1.0
    p, tangent, right = _edge_frame(f, t, 0.0)
    inward = JOINT_W if at_start else -JOINT_W
    bm = m.bm
    rows = []
    for along in (0.0, inward):
        q = p + tangent * along
        rows.append([bm.verts.new(Vector((q.x + right.x * r, q.y + right.y * r, h * HEIGHT if h > 0 else h)))
                     for r, h in JOINT])
    a, b = rows
    n = len(JOINT)
    faces = [bm.faces.new((a[k], a[(k + 1) % n], b[(k + 1) % n], b[k])) for k in range(n)]
    faces += [bm.faces.new(a), bm.faces.new(b[::-1])]
    _tag_faces(m, faces, WALL_ROCK, (0.92, 0.92, 0.92))


def block(m, f, L, a, b, r_back, r_front, lean, h, rng, mat, tint):
    """One upright block from a to b tiles along the line: a flat front leaning back by `lean`, a
    vertical crease down the front, a chamfered front edge and a cap tipped a little."""
    bm = m.bm
    ins = rng.uniform(0.0, 0.05) * (b - a)
    mid = (a + b) / 2 + rng.uniform(-0.15, 0.15) * (b - a)
    bulge = rng.uniform(0.0, 0.09)
    cham = rng.uniform(0.05, 0.16)
    yaw = rng.uniform(-0.07, 0.07)
    hl = h * rng.uniform(0.86, 1.08)
    hr = h * rng.uniform(0.86, 1.08)
    hb = rng.uniform(0.92, 1.02)

    def at(s, r, z):
        return bm.verts.new(frame(f, min(1.0, max(0.0, s / L)), r, z))

    def front(k):  # the front's offset at a (k=-1), the crease (0) and b (1)
        return r_front + yaw * k + (bulge if k == 0 else 0.0)

    # A peaked top on about half the blocks (the sprites' tilted, broken caps), else a slanted one.
    hm = max(hl, hr) * rng.uniform(1.0, 1.06) if rng.random() < 0.5 else (hl + hr) / 2
    heights = (hl, hm, hr)
    alongs_base = (a, mid, b)
    alongs_top = (a + ins, mid, b - ins)
    base_f = [at(s, front(k), -0.06) for k, s in zip((-1, 0, 1), alongs_base)]
    top_f = [at(s, front(k) - lean, z - cham) for k, s, z in zip((-1, 0, 1), alongs_top, heights)]
    cap_f = [at(s, front(k) - lean - cham * 0.8, z) for k, s, z in zip((-1, 0, 1), alongs_top, heights)]
    base_b = [at(a, r_back, -0.06), at(b, r_back, -0.06)]
    top_b = [at(a + ins, r_back, hl * hb), at(b - ins, r_back, hr * hb)]
    faces = []
    for lo, hi in ((base_f, top_f), (top_f, cap_f)):
        for k in range(2):
            faces.append(bm.faces.new((lo[k], lo[k + 1], hi[k + 1], hi[k])))
    faces.append(bm.faces.new((cap_f[0], cap_f[1], cap_f[2], top_b[1], top_b[0])))
    faces.append(bm.faces.new((base_b[0], base_b[1], top_b[1], top_b[0])))
    faces.append(bm.faces.new((base_b[0], base_f[0], top_f[0], cap_f[0], top_b[0])))
    faces.append(bm.faces.new((base_f[2], base_b[1], top_b[1], cap_f[2], top_f[2])))
    k = rng.uniform(0.82, 1.05)
    _tag_faces(m, faces, mat, (tint * k,) * 3)


def _inside(f, kind, q, margin):
    """Whether point q (x, y) stays `margin` tiles inside the cell's edges the piece meets (a stone
    near an edge would show past the joint; in an inner corner even far along the line)."""
    for t, sign, open_end in ((0.0, 1.0, kind == "entrance"), (1.0, -1.0, kind == "exit")):
        if open_end:
            continue
        p, tangent, _ = f(t)
        if (Vector((q.x, q.y)) - p).dot(tangent) * sign < margin:
            return False
    return True


def wall(m, kind, rng):
    """The face: blocks shoulder to shoulder, a top line broken by slow and per-block changes and
    notches, shorter blocks in front, pale scree on the apron and pale boulders along the crest."""
    f = path(kind)
    L = length(kind)
    start = 0.0 if kind == "entrance" else JOINT_W
    end = L if kind == "exit" else L - JOINT_W
    if kind != "entrance":
        joint(m, kind, True)
    if kind != "exit":
        joint(m, kind, False)
    ph1, ph2 = rng.uniform(0.0, math.tau), rng.uniform(0.0, math.tau)
    a = start
    while a < end - 0.05:
        w = 0.3 + 0.7 * rng.random() ** 2  # 0.3 to 1 tile, mostly narrow as the sprites' blocks
        b = end if end - (a + w) < 0.3 else a + w
        tm = (a + b) / 2 / L
        s = f(tm)[2]
        if s >= 0.12:
            reach = 0.35 + 0.65 * s
            slow = 0.86 + 0.08 * math.sin(math.tau * tm * L / 3.1 + ph1) + 0.05 * math.sin(math.tau * tm * L / 1.3 + ph2)
            h = HEIGHT * s * (slow + rng.uniform(-0.1, 0.1))
            if rng.random() < 0.25:
                h *= rng.uniform(0.6, 0.76)  # a notch in the top line
            r_front = rng.uniform(0.4, 0.66) * reach
            lean = rng.uniform(0.18, 0.32) * reach
            block(m, f, L, a, b, -0.34 * reach, r_front, lean, h, rng, WALL_ROCK, 1.0)
        a = b
    # Shorter blocks standing in front of the wall.
    lo, hi = max(start, 0.4), min(end, L - 0.4)
    n = max(1, int(L / 1.3))
    for i in range(n):
        w = rng.uniform(0.3, 0.6)
        a = lo + (hi - lo - w) * (i + rng.uniform(0.1, 0.9)) / n
        tm = (a + w / 2) / L
        s = f(tm)[2]
        if s < 0.3:
            continue
        reach = 0.35 + 0.65 * s
        block(m, f, L, a, a + w, 0.3 * reach, rng.uniform(0.85, 1.05) * reach, rng.uniform(0.06, 0.14),
              HEIGHT * s * rng.uniform(0.22, 0.45), rng, WALL_ROCK, 0.8)
    # Pale boulders along the crest.
    n = max(2, int(L / 0.85))
    for i in range(n):
        tm = (0.35 + (L - 0.7) * (i + rng.uniform(0.15, 0.85)) / n) / L
        s = f(tm)[2]
        if s < 0.3:
            continue
        r = rng.uniform(-0.7, -0.4) * (0.35 + 0.65 * s)
        z = HEIGHT * s * 0.55
        size = rng.uniform(0.15, 0.24) * s
        at = frame(f, tm, r, z)
        if _inside(f, kind, at, size * 1.6 + 0.05):
            fragment(m, at, size, WALL_CREST, scale=(1.2, 1.0, 0.75), tint=(rng.uniform(0.9, 1.08),) * 3)
    # Scree on the apron.
    n = max(3, int(L * 1.6))
    for i in range(n):
        tm = (0.3 + (L - 0.6) * (i + rng.uniform(0.0, 1.0)) / n) / L
        s = f(tm)[2]
        if s < 0.2:
            continue
        reach = 0.35 + 0.65 * s
        at = frame(f, tm, rng.uniform(1.0, 1.6) * reach, 0.0)
        size = rng.uniform(0.06, 0.15)
        if _inside(f, kind, at, size * 1.6 + 0.05):
            fragment(m, at, size, WALL_SCREE, scale=(1.2, 1.0, 0.65), tint=(rng.uniform(0.85, 1.05),) * 3)


def wall_shade(m):
    """Dark at the base and in the joints, lit towards the top (the sprites' look); the apron and
    the crest stones lighter."""
    def fn(face, p, n):
        h = min(1.0, max(0.0, p.z / HEIGHT))
        up = max(0.0, n.z)
        return 0.32 + 0.68 * min(1.0, 0.18 + 0.5 * h + 0.4 * up)
    m.shade(fn)


def cliff(kind, planet=""):
    rock, dark, style = PLANETS[planet]

    def build(m):
        rng = m.rng
        if style == "wall":
            wall_body(m, kind, rng)
            wall(m, kind, rng)
            wall_shade(m)
            return
        body(m, kind, rock, rng)
        if style == "columns":
            columns(m, kind, rock, dark, rng)
        else:
            slabs(m, kind, rock, dark, rng)
        if planet == "gleba":
            roots(m, kind, rng)
        shade(m)
    return build


KINDS = ("sides", "outer", "inner", "exit", "entrance")
# Nauvis's variants (`cliff-<piece>-1`... beside the plain one, drawn by the client's
# ModelLibrary.pick_variant): with the plain piece, 4 sides, 3 outer, 3 inner, 2 exit, 2 entrance.
VARIANTS = {"sides": 3, "outer": 2, "inner": 2, "exit": 1, "entrance": 1}
# The old Nauvis pieces (separate columns on a ridge), kept as `cliff-<piece>-old` for
# `--cliff-pieces=old`; built with their old seed so a rebuild gives the same rock.
SEED_AS = {"cliff-%s-old" % k: "cliff-%s" % k for k in KINDS}
MODELS = {}
for _planet in PLANETS:
    if _planet == "old":
        continue  # the old Nauvis pieces are `cliff-<piece>-old` (below), not `cliff-old-<piece>`
    for _kind in KINDS:
        MODELS["cliff-%s%s" % (_planet + "-" if _planet else "", _kind)] = cliff(_kind, _planet)
for _kind in KINDS:
    for _i in range(1, VARIANTS[_kind] + 1):
        MODELS["cliff-%s-%d" % (_kind, _i)] = cliff(_kind)
    MODELS["cliff-%s-old" % _kind] = cliff(_kind, "old")
