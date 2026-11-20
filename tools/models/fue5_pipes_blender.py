"""Blender side of fue5.py's pipe kit: FUE5's straight pipe made into each of Factorio's pipe pictures,
and FUE5's pipe-to-ground fitted to them.

    blender --background --factory-startup --python tools/models/fue5_pipes_blender.py -- JOB.json

JOB: {"out": path.glb, "shape": a model name (pipe, pipe-<shape>, pipe-to-ground),
      "pipe_fbx": FUE5's pipe-I.fbx, "ptg_fbx": FUE5's pipe-to-ground.fbx, "texture": the picture worn,
      "uv_box": [u0, v0, u1, v1], the part of it every piece's 0..1 mapping is fitted into}

FUE5's straight pipe (pipe-I.fbx, 2 units a tile) is a 0.3-tile body between two flanges with 20
bolts each, 2,996 triangles where a pipe piece may have 1,500 (specs.py LOGISTICS), with a window
Factorio's plain pipe hasn't. So its parts are swept again from FUE5's own measurements: the body
(radius 0.6 units), the flange's chamfered profile (radius 0.566 to 0.72 units, 0.118 thick) and its
bolts' heads (on the back of the flange at radius 0.647), along each piece's path, at 20 sides and 12
bolts a flange, on the cylindrical mapping FUE5's body uses (u round, v along), fitted into `uv_box`.
Joints sit as Factorio's do: a flange on every connected tile edge, its face on the edge, so two
neighbours' flanges meet face to face; corners are elbows from edge to edge (Factorio's bends),
T pieces and the cross a straight with arms, endings a straight with an end cap (concentric rings,
as Factorio's ending pictures), the lone pipe capped at both ends. The cross-section is scaled
towards Factorio's pipe (0.76 tiles across the flanges, FUE5's 0.72), its axis 0.38 up, the flanges'
rims on the ground; endings' caps stand where Factorio's pictures end them (END_INSET). The
pipe-to-ground keeps FUE5's elbow (its own UVs, fitted alike), scaled alike about its flange,
lowered so its flange's axis meets the pipes' and cut at the ground, with the kit's flange and bolts.
"""

import json
import math
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

job = json.load(open(sys.argv[sys.argv.index("--") + 1]))
bpy.ops.wm.read_factory_settings(use_empty=True)

U = 0.5            # FUE5 units to tiles
# FUE5's pipe is 0.72 tiles across its flanges, Factorio's pictures about 0.8 (our fitted pipes are
# squashed ellipses, which Factorio's camera draws round): its cross-section is scaled by 1.05, round,
# the best overlap with Factorio's pictures over all 18 pieces (fue5.py --score: 1.0 and 1.11 do worse).
# Its length stays the tile's.
S = job.get("radial", 1.05)
H = 0.36 * S       # the axis' height: the flange's rim (radius 0.72 units) on the ground
R_BODY = 0.3 * S
N = 20             # sides round the pipe
EDGE = 0.5
# The flange (pipe-I's Tube, from its outer face inwards, t <= 0): front face, chamfer, rim,
# chamfer, back face down to the body. Its inner wall (radius 0.283) lies inside the body: left out.
FLANGE = [(r * S, t * S) for r, t in [(0.291, 0.0), (0.3515, 0.0), (0.36, -0.009), (0.36, -0.05), (0.3515, -0.059), (0.3, -0.059)]]
FLANGE_MID = (0.33 * S, -0.03 * S)
BODY_END = -0.0355 * S  # pipe-I's body ends 0.937 units from its middle, inside its flange
BOLTS = 12
BOLT_R = (0.305 * S, 0.347 * S)     # pipe-I's bolt heads: radius 0.6-0.694 units
BOLT_T = (-0.0885 * S, -0.057 * S)  # 0.831-0.941 units: proud of the flange's back by 0.03
BOLT_W = 0.0205 * S
V_PER_TILE = 0.8            # FUE5's body: v 0..0.8 over its 0.937-unit half lengths

bm = bmesh.new()
uvl = bm.loops.layers.uv.new("UVMap")


def frame_at(origin, axis):
    """Axis a horizontal unit vector (the pipe's way); side, up perpendicular to it."""
    a = Vector(axis).normalized()
    side = Vector((a.y, -a.x, 0.0))
    return Vector(origin), a, side, Vector((0, 0, 1))


def ring_point(fr, r, t, th):
    o, a, side, up = fr
    return o + a * t + (side * math.cos(th) + up * math.sin(th)) * r


def quad(vs, uvs, expect):
    """A face from vs with uvs, wound so its normal agrees with `expect` (outwards)."""
    n = (vs[1] - vs[0]).cross(vs[2] - vs[0])
    if len(vs) == 4:
        n = n + (vs[2] - vs[0]).cross(vs[3] - vs[0])
    if n.dot(expect) < 0:
        vs, uvs = vs[::-1], uvs[::-1]
    f = bm.faces.new([bm.verts.new(v) for v in vs])
    for loop, uv in zip(f.loops, uvs):
        loop[uvl].uv = uv
    return f


def theta(j):
    return -math.pi / 2 + j * math.tau / N  # the seam underneath


def sweep(frames):
    """The body as rings at each frame (frame, v), radius R_BODY, u round, v given."""
    for (f0, v0), (f1, v1) in zip(frames, frames[1:]):
        for j in range(N):
            t0, t1 = theta(j), theta(j + 1)
            ps = [ring_point(f0, R_BODY, 0, t0), ring_point(f0, R_BODY, 0, t1),
                  ring_point(f1, R_BODY, 0, t1), ring_point(f1, R_BODY, 0, t0)]
            uvs = [(j / N, v0), ((j + 1) / N, v0), ((j + 1) / N, v1), (j / N, v1)]
            mid = (ps[0] + ps[1] + ps[2] + ps[3]) / 4
            centre = (f0[0] + f1[0]) / 2
            quad(ps, uvs, mid - centre)


def straight(d, t0, t1):
    """A straight body along direction d from distance t0 to t1 from the middle (signed)."""
    o = Vector((0, 0, H))
    a = Vector(d)
    frames = []
    for t in ((t0, 0.0, t1) if t0 < 0 < t1 else (t0, t1)):  # v highest in the middle
        frames.append((frame_at(o + a * t, a), V_PER_TILE * (EDGE - abs(t))))
    sweep(frames)


def flange(d, inset=0.0):
    """The flange on the tile edge in direction d (its face `inset` in from the edge), and its bolts."""
    a = Vector(d)
    fr = frame_at(Vector((0, 0, H)) + a * (EDGE - inset), a)
    lengths = [0.0]
    for p, q in zip(FLANGE, FLANGE[1:]):
        lengths.append(lengths[-1] + math.hypot(q[0] - p[0], q[1] - p[1]))
    for k, (p, q) in enumerate(zip(FLANGE, FLANGE[1:])):
        # Outwards in the profile's plane: away from the flange's middle.
        dr, dt = q[0] - p[0], q[1] - p[1]
        nr, nt = dt, -dr
        mr, mt = (p[0] + q[0]) / 2 - FLANGE_MID[0], (p[1] + q[1]) / 2 - FLANGE_MID[1]
        if nr * mr + nt * mt < 0:
            nr, nt = -nr, -nt
        va, vb = 0.85 + lengths[k] * V_PER_TILE, 0.85 + lengths[k + 1] * V_PER_TILE
        for j in range(N):
            t0, t1 = theta(j), theta(j + 1)
            ps = [ring_point(fr, p[0], p[1], t0), ring_point(fr, p[0], p[1], t1),
                  ring_point(fr, q[0], q[1], t1), ring_point(fr, q[0], q[1], t0)]
            radial = ring_point(fr, 1, 0, (t0 + t1) / 2) - fr[0]
            quad(ps, [(j / N, va), ((j + 1) / N, va), ((j + 1) / N, vb), (j / N, vb)], radial * nr + fr[1] * nt)
    for b in range(BOLTS):
        th = theta(0) + (b + 0.5) * math.tau / BOLTS
        o, ax, side, up = fr
        rad = side * math.cos(th) + up * math.sin(th)
        tan = ax.cross(rad)

        def at(r, t, w):
            return o + ax * t + rad * r + tan * w

        r0, r1 = BOLT_R
        b0, b1 = BOLT_T
        w = BOLT_W
        # A patch of the texture's top edge for every bolt head.
        uv = [(0.05 + 0.04 * b / BOLTS, 0.97), (0.07 + 0.04 * b / BOLTS, 0.97),
              (0.07 + 0.04 * b / BOLTS, 0.99), (0.05 + 0.04 * b / BOLTS, 0.99)]
        quad([at(r0, b0, -w), at(r1, b0, -w), at(r1, b0, w), at(r0, b0, w)], uv, -ax)  # its head
        quad([at(r1, b0, -w), at(r1, b1, -w), at(r1, b1, w), at(r1, b0, w)], uv, rad)
        quad([at(r0, b0, -w), at(r0, b1, -w), at(r0, b1, w), at(r0, b0, w)], uv, -rad)
        quad([at(r0, b0, w), at(r1, b0, w), at(r1, b1, w), at(r0, b1, w)], uv, tan)
        quad([at(r0, b0, -w), at(r1, b0, -w), at(r1, b1, -w), at(r0, b1, -w)], uv, -tan)


# Factorio's ending pictures: a disc over the flange's opening, two rings stepping out to a boss.
CAP = [(r * S, t * S) for r, t in [(0.291, 0.0), (0.22, 0.0), (0.22, 0.015), (0.13, 0.015), (0.13, 0.03), (0.0, 0.03)]]
# Where Factorio's pictures end a pipe (as our fitted pipes do): an ending going north or south has its
# cap's boss 0.355 tiles from the middle, one going east or west on the tile's edge; the lone pipe's
# 0.415 either way.
END_INSET = {"ns": EDGE - 0.355 + CAP[-1][1], "ew": 0.01 + CAP[-1][1]}
LONE_INSET = EDGE - 0.415 + CAP[-1][1]


def cap(d, inset):
    a = Vector(d)
    fr = frame_at(Vector((0, 0, H)) + a * (EDGE - inset), a)

    def uv_of(r, th):  # planar, about the same texels a tile as the body
        return (0.25 + 0.53 * r * math.cos(th), 0.45 + 1.06 * r * math.sin(th))

    for p, q in zip(CAP, CAP[1:]):
        flat = abs(p[1] - q[1]) < 1e-9
        for j in range(N):
            t0, t1 = theta(j), theta(j + 1)
            radial = ring_point(fr, 1, 0, (t0 + t1) / 2) - fr[0]
            expect = fr[1] if flat else radial
            if q[0] == 0.0:
                ps = [ring_point(fr, p[0], p[1], t0), ring_point(fr, p[0], p[1], t1), ring_point(fr, 0, q[1], 0)]
                quad(ps, [uv_of(p[0], t0), uv_of(p[0], t1), uv_of(0, 0)], expect)
                continue
            ps = [ring_point(fr, p[0], p[1], t0), ring_point(fr, p[0], p[1], t1),
                  ring_point(fr, q[0], q[1], t1), ring_point(fr, q[0], q[1], t0)]
            quad(ps, [uv_of(p[0], t0), uv_of(p[0], t1), uv_of(q[0], t1), uv_of(q[0], t0)], expect)


def elbow(d0, d1, steps=10):
    """An elbow from the edge in direction d0 to the edge in d1, round the tile's corner between them
    (radius 0.5: Factorio's bend), its ends inside the flanges."""
    a0, a1 = Vector(d0), Vector(d1)
    c = Vector((0, 0, H)) + (a0 + a1) * EDGE  # the corner
    R = EDGE
    trim = math.asin(-BODY_END / R)
    frames = []
    length = R * (math.pi / 2)
    for k in range(steps + 1):
        f = trim + (math.pi / 2 - 2 * trim) * k / steps  # angle from the d0 end
        # On the arc: from the d0 edge's middle (c - a1*R) to the d1 edge's (c - a0*R).
        p = c - a1 * (R * math.cos(f)) - a0 * (R * math.sin(f))
        tangent = (a1 * math.sin(f) - a0 * math.cos(f)).normalized()
        s = R * f
        frames.append((frame_at(p, tangent), V_PER_TILE * min(s, length - s)))
    sweep(frames)


DIRS = {"n": (0, 1, 0), "e": (1, 0, 0), "s": (0, -1, 0), "w": (-1, 0, 0)}
SHAPES = {  # Factorio's picture -> its connections (model_library.gd PIPE_SHAPES)
    "straight-vertical-single": "", "ending-up": "n", "ending-right": "e", "corner-up-right": "ne",
    "ending-down": "s", "straight-vertical": "ns", "corner-down-right": "es", "t-right": "nes",
    "ending-left": "w", "corner-up-left": "nw", "straight-horizontal": "ew", "t-up": "new",
    "corner-down-left": "sw", "t-left": "nsw", "t-down": "esw", "cross": "nesw",
}
OPPOSITE = {"n": "s", "s": "n", "e": "w", "w": "e"}


def pipe_shape(conns):
    if conns == "":  # the lone pipe: north-south, capped at both ends
        straight(DIRS["s"], -(EDGE - LONE_INSET), EDGE - LONE_INSET)
        for k in "ns":
            flange(DIRS[k], LONE_INSET)
            cap(DIRS[k], LONE_INSET)
        return
    if len(conns) == 1:  # an ending: across the tile, capped on the far edge
        k = conns
        inset = END_INSET["ns" if k in "ns" else "ew"]
        straight(DIRS[k], -(EDGE - inset), EDGE + BODY_END)
        flange(DIRS[k])
        flange(DIRS[OPPOSITE[k]], inset)
        cap(DIRS[OPPOSITE[k]], inset)
        return
    if len(conns) == 2 and OPPOSITE[conns[0]] != conns[1]:  # a corner
        elbow(DIRS[conns[0]], DIRS[conns[1]])
        for k in conns:
            flange(DIRS[k])
        return
    done = set()
    for k in conns:  # straights through, arms from the middle for the rest
        if k in done:
            continue
        if OPPOSITE[k] in conns:
            straight(DIRS[k], -(EDGE + BODY_END), EDGE + BODY_END)
            done |= {k, OPPOSITE[k]}
        else:
            straight(DIRS[k], 0.0, EDGE + BODY_END)
            done.add(k)
    for k in conns:
        flange(DIRS[k])


def pipe_to_ground():
    """FUE5's elbow, from its flange on the north edge down into the ground at the middle."""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.fbx(filepath=job["ptg_fbx"])
    src = [o for o in bpy.data.objects if o not in before]
    body = next(o for o in src if o.type == "MESH" and o.name.split(".")[0] == "Cylinder")
    # Its flange (Tube.001): centre 0.9645 units up, its face 1.018 units north.
    # Scaled as the pipes' cross-section is, about its flange's face (on the north edge).
    m = (Matrix.Translation((0, EDGE, H)) @ Matrix.Diagonal((S, S, S, 1))
         @ Matrix.Translation((0, -1.018 * U, -0.9645 * U)) @ Matrix.Diagonal((U, U, U, 1)) @ body.matrix_world)
    tmp = bmesh.new()
    tmp.from_mesh(body.data)
    tmp.transform(m)
    geom = tmp.verts[:] + tmp.edges[:] + tmp.faces[:]
    bmesh.ops.bisect_plane(tmp, geom=geom, plane_co=(0, 0, 0), plane_no=(0, 0, 1), clear_inner=True)
    src_uv = tmp.loops.layers.uv[0]
    for f in tmp.faces:
        nf = bm.faces.new([bm.verts.new(v.co) for v in f.verts])
        for l0, l1 in zip(f.loops, nf.loops):
            l1[uvl].uv = l0[src_uv].uv
    tmp.free()
    for o in src:
        bpy.data.objects.remove(o)
    flange(DIRS["n"])


shape = job["shape"]
if shape == "pipe-to-ground":
    pipe_to_ground()
elif shape == "pipe":  # a pipe without its connections known: the straight one, as ours
    pipe_shape("ns")
else:
    pipe_shape(SHAPES[shape[len("pipe-"):]])

# Every mapping into the picture's part `uv_box` (fue5.py pipe_job: the picture's even middle).
u0, v0, u1, v1 = job.get("uv_box", [0.0, 0.0, 1.0, 1.0])
for f in bm.faces:
    for loop in f.loops:
        u, v = loop[uvl].uv
        loop[uvl].uv = (u0 + (u1 - u0) * min(1.0, max(0.0, u)), v0 + (v1 - v0) * min(1.0, max(0.0, v)))
bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
me = bpy.data.meshes.new(shape)
bm.to_mesh(me)
bm.free()
me.shade_smooth()
me.set_sharp_from_angle(angle=math.radians(40))
ob = bpy.data.objects.new("body", me)
bpy.context.collection.objects.link(ob)

mat = bpy.data.materials.new("fue5_pipe")
mat.use_nodes = True
nt = mat.node_tree
bsdf = nt.nodes["Principled BSDF"]
bsdf.inputs["Roughness"].default_value = 0.7
bsdf.inputs["Metallic"].default_value = 0.0
tex = nt.nodes.new("ShaderNodeTexImage")
tex.image = bpy.data.images.load(job["texture"])
nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
me.materials.append(mat)

tris = sum(len(p.vertices) - 2 for p in me.polygons)
bpy.ops.export_scene.gltf(filepath=job["out"], export_format="GLB", export_image_format="AUTO",
                          export_yup=True, export_apply=True, export_animations=False, export_skins=False,
                          export_morph=False, export_cameras=False, export_lights=False)
print("FUE5 wrote", job["out"], tris, "triangles")
