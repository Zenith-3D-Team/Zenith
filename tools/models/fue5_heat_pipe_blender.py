"""Blender side of fue5.py's heat pipe kit: FUE5's one heat pipe piece to one of Zenith's 17 heat pipe
files (the kit nuclear.py's own heat pipes come as, named after Factorio's pictures).

    blender --background --factory-startup --python tools/models/fue5_heat_pipe_blender.py -- JOB.json

JOB: {"fbx": path, "out": path.glb, "conns": "NE" (the sides it joins: N E S W, "" for none),
      "emission": path of the graded glow picture, "textures": folder of FUE5's pictures}

FUE5's piece is a straight north-south tile: a pair of copper pipes, and at each end a steel sleeve
that straddles the tile's edge (half in this tile, half in the next). Everything here is cut from it:

- an arm: the copper from the middle (or a little short of it) to one edge, with the half sleeve
  inside the tile at that edge, so two neighbours' halves make one whole sleeve at their joint;
- a radiator (Factorio's closed end, ending and single pictures): a whole sleeve stretched along the
  pipe and capped, south of the middle as Factorio's ending pictures have it;
- a junction box (tees, the cross): a whole sleeve stretched square and capped where the runs meet;
- a corner: the straight tile bent round a quarter circle between the two edges' middles.

Two materials, the same pictures in every file: the copper (FUE5's diffuse, and its glow picture,
graded to Factorio's heated colours, as its emission: the client lights it only while the pipe is hot,
anim.gd STATE_HEAT) and the steel sleeves.
"""

import json
import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

job = json.load(open(sys.argv[sys.argv.index("--") + 1]))
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=job["fbx"])

COPPER, STEEL = 0, 1
TILE = 0.5  # FUE5: 2 units a tile

# The piece in tiles, as one bmesh: copper (FUE5's mat1) and steel (mat2) faces, its UVs.
src = bmesh.new()
for o in [o for o in bpy.data.objects if o.type == "MESH"]:
    me = o.data.copy()
    if "custom_normal" in me.attributes:
        me.attributes.remove(me.attributes["custom_normal"])
    me.transform(Matrix.Scale(TILE, 4) @ o.matrix_world)
    which = STEEL if any(s.material and s.material.name.startswith("mat2") for s in o.material_slots) else COPPER
    for p in me.polygons:
        p.material_index = which
    src.from_mesh(me)
lift = -min(v.co.z for v in src.verts)
bmesh.ops.translate(src, verts=src.verts, vec=(0, 0, lift))


def copy(bm, faces=None):
    """A new bmesh of bm's faces (all, or those `faces(f)` keeps)."""
    me = bpy.data.meshes.new("t")
    bm.to_mesh(me)
    out = bmesh.new()
    out.from_mesh(me)
    bpy.data.meshes.remove(me)
    if faces is not None:
        bmesh.ops.delete(out, geom=[f for f in out.faces if not faces(f)], context="FACES")
        bmesh.ops.delete(out, geom=[v for v in out.verts if not v.link_faces], context="VERTS")
    return out


def centre_y(f):
    return f.calc_center_median().y


def clip(bm, axis, lo=None, hi=None):
    """Cuts bm to lo <= axis <= hi (open where cut: a neighbour or a cap covers it)."""
    i = "xyz".index(axis)
    for at, sign in ((lo, -1), (hi, 1)):
        if at is None:
            continue
        no = Vector((0, 0, 0))
        no[i] = sign
        co = Vector((0, 0, 0))
        co[i] = at
        geom = list(bm.verts) + list(bm.edges) + list(bm.faces)
        bmesh.ops.bisect_plane(bm, geom=geom, plane_co=co, plane_no=no, clear_outer=True)
    return bm


def slices(bm, axis, lo, hi, n):
    """Edge loops across bm every (hi - lo) / n along axis, for bending."""
    i = "xyz".index(axis)
    for k in range(1, n):
        co = Vector((0, 0, 0))
        co[i] = lo + (hi - lo) * k / n
        no = Vector((0, 0, 0))
        no[i] = 1
        geom = list(bm.verts) + list(bm.edges) + list(bm.faces)
        bmesh.ops.bisect_plane(bm, geom=geom, plane_co=co, plane_no=no)
    return bm


def _hull(points):
    """The convex hull of 2D points, anticlockwise (monotone chain)."""
    pts = sorted(set(points))
    if len(pts) < 3:
        return pts

    def half(seq):
        out = []
        for p in seq:
            while len(out) >= 2 and ((out[-1][0] - out[-2][0]) * (p[1] - out[-2][1])
                                     - (out[-1][1] - out[-2][1]) * (p[0] - out[-2][0])) <= 0:
                out.pop()
            out.append(p)
        return out
    return half(pts)[:-1] + half(reversed(pts))[:-1]


def cap(bm):
    """Closes a sleeve's two ends: the sleeve is a hollow ring (its end faces are rings round an opening),
    so each end gets a plate the shape of its outline, just inside it, wearing the steel's mean colour
    there (the UV of the ring's end faces)."""
    uvl = bm.loops.layers.uv[0]
    ys = [v.co.y for v in bm.verts]
    for end, sign in ((max(ys), -1), (min(ys), 1)):
        ring = [v for v in bm.verts if abs(v.co.y - end) < 2e-3]
        uvs = [l[uvl].uv.copy() for v in ring for l in v.link_loops]
        uv = sum(uvs, Vector((0, 0))) / max(1, len(uvs))
        outline = _hull([(round(v.co.x, 5), round(v.co.z, 5)) for v in ring])
        if len(outline) < 3:
            continue
        y = end + sign * 2e-3
        f = bm.faces.new([bm.verts.new((x, y, z)) for x, z in outline])
        f.material_index = STEEL
        for l in f.loops:
            l[uvl].uv = uv
        f.normal_update()
        if (f.normal.y > 0) != (sign < 0):  # facing out of the sleeve's end
            f.normal_flip()
    return bm


def place(bm, m):
    bmesh.ops.transform(bm, matrix=m, verts=bm.verts)
    return bm


copper = copy(src, lambda f: f.material_index == COPPER)
north_sleeve = copy(src, lambda f: f.material_index == STEEL and centre_y(f) > 0)
SLEEVE_Y = sum(v.co.y for v in north_sleeve.verts) / len(north_sleeve.verts)  # about the tile's edge
place(north_sleeve, Matrix.Translation((0, -SLEEVE_Y, 0)))  # a whole sleeve on the origin
SLEEVE_LEN = max(v.co.y for v in north_sleeve.verts) - min(v.co.y for v in north_sleeve.verts)

ROT = {"N": 0, "E": -90, "S": 180, "W": 90}  # a north arm turned to face each side (anticlockwise)


# Factorio draws an east-west run of heat pipe shallower than a north-south one (0.3 tiles deep against
# 0.36 wide, nuclear.py HP_R) and a pixel south of the middle: east and west arms are drawn so.
EW_DEPTH, EW_SHIFT = 0.8, -0.02


def turned(bm, side):
    place(bm, Matrix.Rotation(math.radians(ROT[side]), 4, "Z"))
    if side in "EW":
        place(bm, Matrix.Translation((0, EW_SHIFT, 0)) @ Matrix.Diagonal((1, EW_DEPTH, 1, 1)))
    return bm


def edge_half():
    """The half of the sleeve inside the tile at its north edge."""
    return clip(place(copy(north_sleeve), Matrix.Translation((0, 0.5, 0))), "y", hi=0.5)


def arm(side, start=0.0):
    """Copper from y = start to the north edge, with its half sleeve, turned to `side`."""
    out = clip(copy(copper), "y", lo=start, hi=0.5)
    join(out, edge_half())
    return turned(out, side)


def sleeve_box(length, y=0.0, width=None):
    """A whole sleeve stretched to `length` along the pipe (and `width` across), capped, at y."""
    out = copy(north_sleeve)
    w = 1.0 if width is None else width / (max(v.co.x for v in out.verts) - min(v.co.x for v in out.verts))
    place(out, Matrix.Translation((0, y, 0)) @ Matrix.Diagonal((w, length / SLEEVE_LEN, 1, 1)))
    return cap(out)


def join(into, other):
    me = bpy.data.meshes.new("t")
    other.to_mesh(me)
    into.from_mesh(me)
    bpy.data.meshes.remove(me)
    return into


def straight():
    out = clip(copy(copper), "y", lo=-0.5, hi=0.5)
    join(out, edge_half())
    join(out, turned(edge_half(), "S"))
    return out


def bent_se(ew_end, inward):
    """The straight tile bent round a quarter circle from the south edge's middle to the east's. The
    end that will be east or west once turned (`ew_end`: 0 the south one, 1 the east one) eases to
    EW_DEPTH across and EW_SHIFT south (`inward`: that shift towards the bend's centre), so it meets
    an east-west neighbour's sleeve."""
    out = slices(straight(), "y", -0.5, 0.5, 10)
    c = Vector((0.5, -0.5))
    for v in out.verts:
        s = min(1.0, max(0.0, v.co.y + 0.5))
        phi = math.pi - s * math.pi / 2
        w = s if ew_end else 1.0 - s
        r = 0.5 - (v.co.x * (1.0 - (1.0 - EW_DEPTH) * w) + inward * w)
        v.co.x, v.co.y = c.x + r * math.cos(phi), c.y + r * math.sin(phi)
    return out


# Factorio's ending pictures: the closed end's sleeve from 0.09 to 0.36 tiles south of the middle
# (nuclear.py ENDS), its pipes from the edge into it.
END_Y, END_LEN = -0.225, 0.27
# Each corner: the south-east one turned anticlockwise, which of its ends is then east or west, and
# which way a south shift there goes along the bend's radius.
CORNER_TURN = {"SE": (0, 1, -EW_SHIFT), "NE": (90, 0, EW_SHIFT), "NW": (180, 1, EW_SHIFT), "SW": (-90, 0, -EW_SHIFT)}

conns = job["conns"]
if not conns:
    # Factorio's single heat pipe: two closed ends end to end, a collar of copper between.
    piece = clip(copy(copper), "y", lo=-0.12, hi=0.12)
    join(piece, sleeve_box(0.32, 0.19))
    join(piece, sleeve_box(0.32, -0.19))
elif len(conns) == 1:
    piece = turned(join(arm("N", END_Y), sleeve_box(END_LEN, END_Y)), conns)
elif sorted(conns) == ["N", "S"]:
    piece = straight()
elif sorted(conns) == ["E", "W"]:
    piece = turned(straight(), "E")
elif len(conns) == 2:
    key = "".join(sorted(conns, key="NSEW".index))
    turn, ew_end, inward = CORNER_TURN[key]
    piece = place(bent_se(ew_end, inward), Matrix.Rotation(math.radians(turn), 4, "Z"))
else:
    # Tees and the cross: the runs into a square junction box where they meet.
    piece = bmesh.new()
    for c in conns:
        join(piece, arm(c, 0.12))
    width = max(v.co.x for v in north_sleeve.verts) - min(v.co.x for v in north_sleeve.verts)
    join(piece, sleeve_box(width, 0.0, width))

bmesh.ops.remove_doubles(piece, verts=piece.verts, dist=1e-5)
me = bpy.data.meshes.new("heat-pipe")
piece.to_mesh(me)
me.shade_smooth()
me.set_sharp_from_angle(angle=math.radians(40))
me.uv_layers[0].name = "UVMap"


def material(name, diffuse, emission=None):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = 0.7
    bsdf.inputs["Metallic"].default_value = 0.0
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = bpy.data.images.load(diffuse)
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    if emission:
        glow = nt.nodes.new("ShaderNodeTexImage")
        glow.image = bpy.data.images.load(emission)
        nt.links.new(glow.outputs["Color"], bsdf.inputs["Emission Color"])
        bsdf.inputs["Emission Strength"].default_value = job.get("glow", 1.6)
    return m


T = job["textures"]
me.materials.append(material("fue5_heat_pipe_copper", os.path.join(T, "heat-pipe_mat1_diffuse.jpg"), job["emission"]))
me.materials.append(material("fue5_heat_pipe_steel", os.path.join(T, "heat-pipe_mat2_diffuse.jpg")))

for o in list(bpy.data.objects):
    bpy.data.objects.remove(o)
ob = bpy.data.objects.new(os.path.splitext(os.path.basename(job["out"]))[0], me)
bpy.context.scene.collection.objects.link(ob)
bpy.ops.export_scene.gltf(filepath=job["out"], export_format="GLB", export_image_format="JPEG",
                          export_jpeg_quality=88, export_yup=True, export_apply=True,
                          export_animations=False, export_skins=False, export_morph=False,
                          export_cameras=False, export_lights=False)
print("FUE5 wrote", job["out"], conns or "single", len(me.polygons), "faces",
      sum(len(p.vertices) - 2 for p in me.polygons), "triangles")
