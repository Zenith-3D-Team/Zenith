"""Blender side of fue5.py: one FUE5 FBX (or several) to one client model.

    blender --background --factory-startup --python tools/models/fue5_blender.py -- JOB.json

JOB: {"fbx": [paths], "out": path.glb, "yaw": degrees (clockwise from above), "budget": triangles,
      "tex": atlas size, "drop": [object name prefixes], "anim": {node name: [ancestor names]},
      "pivot": {node name: [x, y, z] in tiles, or "centre"}, "centre": [x, y] in tiles or null,
      "shift": [x, y, z] tiles, "scale": [sx, sy, sz], "name": material name,
      "images": {material: texture path}, "tint": {material: [r, g, b] linear multiplier},
      "flat": {material: [r, g, b] linear base colour, its textures dropped}, "rig": an inserter arm (below),
      "side_parts": {part: [[names], sign]} a mirrored mesh's one side as a part, "planar": degrees of flat
      faces merged before decimating, "together": every part decimated in one go (below)}

FUE5's models are Cinema 4D exports: 2 units a tile, Z up. Flat see-through ground decals
(scorch marks) are dropped. Every texture is baked into one atlas on a fresh UV map, so the
model has one material with one base colour texture (embedded in the .glb as JPEG).
"""

import json
import math
import sys

import bpy
from mathutils import Matrix, Vector

job = json.load(open(sys.argv[sys.argv.index("--") + 1]))
bpy.ops.wm.read_factory_settings(use_empty=True)
file_of = {}  # object name -> index of the FBX it came from
for i, f in enumerate(job["fbx"]):
    before = set(bpy.data.objects.keys())
    bpy.ops.import_scene.fbx(filepath=f)
    for name in set(bpy.data.objects.keys()) - before:
        file_of[name] = i

# Flat colours in place of pictures that mustn't ship (`flat`: {material: [r, g, b] linear}): a
# stock photo's watermark in FUE5's inserter, robot and logistic chest pictures. The material's
# textures are taken off and it is painted that one colour (from Factorio's sprites, or the mean of
# the picture it replaces), the baked occlusion shading it. A key names the material exactly
# ("mat1.001") or by its name before the dot ("mat1" for "mat1.002" too); the exact name wins.
FLAT = job.get("flat", {})


def flat_colour(mat):
    if mat is None:
        return None
    return FLAT.get(mat.name) or FLAT.get(mat.name.split(".")[0])


# Textures the FBX names differently from the files downloaded (`images`: {material: path}), and
# colours Unreal's material instances gave a shared mesh (`tint`: {material: [r, g, b]}, linear,
# multiplying the texture), as FUE5's logistic chests are one mesh painted five ways.
for mat in bpy.data.materials:
    if not mat.use_nodes:
        continue
    nt = mat.node_tree
    path = job.get("images", {}).get(mat.name)
    if path:
        img = bpy.data.images.load(path, check_existing=True)
        texs = [n for n in nt.nodes if n.type == "TEX_IMAGE"]
        for n in texs:
            n.image = img
        if not texs:
            n = nt.nodes.new("ShaderNodeTexImage")
            n.image = img
            bsdf = next((b for b in nt.nodes if b.type == "BSDF_PRINCIPLED"), None)
            if bsdf is not None:
                nt.links.new(n.outputs["Color"], bsdf.inputs["Base Color"])
    tint = job.get("tint", {}).get(mat.name)
    if tint:
        bsdf = next((b for b in nt.nodes if b.type == "BSDF_PRINCIPLED"), None)
        base = bsdf.inputs["Base Color"] if bsdf is not None else None
        if base is not None and base.is_linked:
            src = base.links[0].from_socket
            mul = nt.nodes.new("ShaderNodeVectorMath")
            mul.operation = "MULTIPLY"
            mul.inputs[1].default_value = tint
            nt.links.new(src, mul.inputs[0])
            nt.links.new(mul.outputs["Vector"], base)
        elif base is not None:
            c = base.default_value
            base.default_value = (c[0] * tint[0], c[1] * tint[1], c[2] * tint[2], c[3])
    flat = flat_colour(mat)
    if flat:
        bsdf = next((b for b in nt.nodes if b.type == "BSDF_PRINCIPLED"), None)
        if bsdf is not None:
            base = bsdf.inputs["Base Color"]
            for link in list(base.links):
                nt.links.remove(link)
            base.default_value = (flat[0], flat[1], flat[2], 1.0)
        for n in [n for n in nt.nodes if n.type == "TEX_IMAGE"]:
            nt.nodes.remove(n)


def ancestors(o):
    out = []
    p = o.parent
    while p is not None:
        out.append(p.name)
        p = p.parent
    return out


# Which moving part each mesh belongs to, from its own and its parents' names.
group_of = {}
ancestry = {}  # mesh name -> its own and its parents' names
for o in bpy.data.objects:
    if o.type != "MESH":
        continue
    names = [o.name] + ancestors(o)
    ancestry[o.name] = names
    # A whole file as one moving part (`file_parts`: {index: part}), like a turret's head.
    group_of[o.name] = job.get("file_parts", {}).get(str(file_of.get(o.name, 0)), "")
    for part, keys in job.get("anim", {}).items():
        if any(n == k or n.startswith(k + ".") for n in names for k in keys):
            group_of[o.name] = part
            break
    # A name ending in "$" drops only that exact object or group, not every name it starts.
    if any(n == p[:-1] if p.endswith("$") else n.startswith(p) for n in names for p in job.get("drop", [])):
        group_of[o.name] = None

# Bake each mesh into world space with its own data.
meshes = [o for o in bpy.data.objects if o.type == "MESH"]
for o in meshes:
    o.data = o.data.copy()
    m = o.matrix_world.copy()
    o.parent = None
    o.data.transform(m)
    o.matrix_world = Matrix.Identity(4)
    for mod in list(o.modifiers):
        o.modifiers.remove(mod)

# Parts FUE5 made as one mirrored mesh (its Symmetry objects: a splitter's two outer gears are one mesh)
# split by side (`side_parts`: {part: [[object or parent names], sign]}): those meshes' faces on the side
# where FUE5's own x times `sign` is positive become that part; the mesh itself goes.
import bmesh  # noqa: E402
for part, (keys, sign) in job.get("side_parts", {}).items():
    for o in list(meshes):
        if group_of.get(o.name) is None or not any(
                n == k or n.startswith(k + ".") for n in ancestry.get(o.name, ()) for k in keys):
            continue
        piece = o.copy()
        piece.data = o.data.copy()
        bpy.context.collection.objects.link(piece)
        bm = bmesh.new()
        bm.from_mesh(piece.data)
        bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.calc_center_median().x * sign <= 0], context="FACES")
        bm.to_mesh(piece.data)
        bm.free()
        group_of[piece.name] = part
        ancestry[piece.name] = ancestry.get(o.name, [o.name])
        meshes.append(piece)
for keys, _ in job.get("side_parts", {}).values():
    for o in meshes:
        if group_of.get(o.name) not in job.get("side_parts", {}) and any(
                n == k or n.startswith(k + ".") for n in ancestry.get(o.name, ()) for k in keys):
            group_of[o.name] = None


# An inserter's arm kept as a rig the client's arm drives (`rig`: client/scripts/world/model_rig.gd):
# FUE5's skinned arm (bones `lower` and `upper`, the wrist at `wrist`'s head) is cut into rigid parts,
# its hand's two fingers (islands past `hand_from` of the forearm, off its middle line) the pincers,
# which FUE5 doesn't rig; laid folded over the base at rest (`fold`: the lower and upper arm's angles
# up from level, degrees), each arm segment stretched along itself by `stretch` (a long-handed arm),
# the hand kept rigid. A new armature with model_rig.gd's joint names is made at export.
rig = job.get("rig")
rig_obj = None
rig_points = {}
if rig:
    import bmesh as _bm
    arm_ob = next(o for o in bpy.data.objects if o.type == "ARMATURE")
    rig_obj = next(o for o in meshes if o.vertex_groups and o.vertex_groups.get(rig["lower"]) is not None)
    bone = lambda n: arm_ob.matrix_world @ arm_ob.data.bones[n].head_local
    S, E, W = bone(rig["lower"]), bone(rig["upper"]), bone(rig["wrist"])
    k = rig.get("stretch", 1.0)

    def _angle(d):
        return math.atan2(d.z, d.y)

    def _stretch(d, v):
        d = d.normalized()
        return v + d * (v.dot(d) * (k - 1.0))

    d1, d2 = E - S, W - E
    R1 = Matrix.Rotation(math.radians(rig["fold"][0]) - _angle(d1), 3, "X")
    R2 = Matrix.Rotation(math.radians(rig["fold"][1]) - _angle(d2), 3, "X")
    E2 = S + R1 @ (d1 * k)
    W2 = E2 + R2 @ (d2 * k)
    me = rig_obj.data
    lower_g = rig_obj.vertex_groups[rig["lower"]].index
    strongest = [max(v.groups, key=lambda g: g.weight).group if v.groups else lower_g for v in me.vertices]
    bm = _bm.new()
    bm.from_mesh(me)
    bm.verts.ensure_lookup_table()
    role = [None] * len(me.vertices)  # "lower", "upper", "pa", "pb"
    seen = set()
    for f in bm.faces:
        if f.index in seen:
            continue
        island, todo = [], [f]
        seen.add(f.index)
        while todo:
            g = todo.pop()
            island.append(g)
            for e in g.edges:
                for h in e.link_faces:
                    if h.index not in seen:
                        seen.add(h.index)
                        todo.append(h)
        vs = {v.index for g in island for v in g.verts}
        ups = sum(1 for i in vs if strongest[i] != lower_g)
        c = sum((me.vertices[i].co for i in vs), Vector()) / len(vs)
        if ups * 2 < len(vs):
            r = "lower"
        elif (c - E).dot(d2.normalized()) / d2.length > rig.get("hand_from", 0.65):
            r = "hand" if abs(c.x) < rig.get("finger_x", 0.3) else ("pa" if c.x < 0 else "pb")
        else:
            r = "upper"
        for i in vs:
            role[i] = r
    bm.free()
    for i in range(len(role)):
        if role[i] is None:
            role[i] = "lower" if strongest[i] == lower_g else "upper"
    for v, r in zip(me.vertices, role):
        p = v.co.copy()
        if r == "lower":
            v.co = S + R1 @ _stretch(d1, p - S)
        elif r == "upper":
            v.co = E2 + R2 @ _stretch(d2, p - E)
        else:
            v.co = W2 + R2 @ (p - W)
    # Each pincer's joint: its root, the end nearest the elbow; its tip the far end.
    along = (W2 - E2).normalized()
    for r in ("pa", "pb"):
        pts = [v.co.copy() for v, q in zip(me.vertices, role) if q == r]
        if not pts:
            raise SystemExit("FUE5 rig: no %s finger found" % r)
        ts = [(p - E2).dot(along) for p in pts]
        lo_t, hi_t = min(ts), max(ts)
        root = [p for p, t in zip(pts, ts) if t <= lo_t + 0.15 * (hi_t - lo_t)]
        tip = [p for p, t in zip(pts, ts) if t >= hi_t - 0.15 * (hi_t - lo_t)]
        rig_points[r] = sum(root, Vector()) / len(root)
        rig_points[r + "_tip"] = sum(tip, Vector()) / len(tip)
    rig_points.update({"shoulder": S.copy(), "elbow": E2, "wrist": W2})
    # Rigid parts: every vertex wholly its part's.
    for g in list(rig_obj.vertex_groups):
        rig_obj.vertex_groups.remove(g)
    names = {"lower": "Lower Arm", "upper": "Upper Arm", "hand": "Upper Arm", "pa": "Pincer1", "pb": "Pincer2"}
    groups = {n: rig_obj.vertex_groups.new(name=n) for n in sorted(set(names.values()))}
    for v, r in zip(me.vertices, role):
        groups[names[r]].add([v.index], 1.0, "REPLACE")
    group_of[rig_obj.name] = "rig"
    print("FUE5 rig:", {r: role.count(r) for r in set(role)})


# Skinned meshes (FUE5's animated*.fbx): faces carried by a recipe's bones become that moving part
# (`bones`: {part: [bone names]}), drawn at rest; the first bone's head is the part's pivot.
pivots = {}
import bmesh  # noqa: E402
arm = next((o for o in bpy.data.objects if o.type == "ARMATURE"), None)
for part, bone_names in job.get("bones", {}).items():
    if arm is None:
        break
    bone = arm.data.bones.get(bone_names[0])
    if bone is not None:
        pivots[part] = arm.matrix_world @ bone.head_local
    for o in list(meshes):
        if not o.vertex_groups or o.name not in group_of:
            continue
        ids = {g.index for g in o.vertex_groups if g.name in bone_names}
        carried = {v.index for v in o.data.vertices if v.groups and max(v.groups, key=lambda g: g.weight).group in ids}
        if not carried:
            continue
        piece = o.copy()
        piece.data = o.data.copy()
        bpy.context.collection.objects.link(piece)
        for ob, keep in ((piece, True), (o, False)):
            bm = bmesh.new()
            bm.from_mesh(ob.data)
            gone = [f for f in bm.faces if all(v.index in carried for v in f.verts) != keep]
            bmesh.ops.delete(bm, geom=gone, context="FACES")
            bm.to_mesh(ob.data)
            bm.free()
        group_of[piece.name] = part
        meshes.append(piece)


# Lamp parts (`lamp_parts`: {part: {"objects": [names], "color": [r, g, b]}}): copies of those objects
# become a part of their own, painted one colour and lit, and the originals go: a robot's cargo and
# empty lamps from one FUE5 bulb, its nozzle light. (Not `lamps`: the rail signals' lenses, below.)
lamp_color = {}
lamp_from = set()
for part, spec in job.get("lamp_parts", {}).items():
    lamp_color[part] = spec["color"]
    for o in list(meshes):
        if o.name not in spec["objects"]:
            continue
        c = o.copy()
        c.data = o.data.copy()
        bpy.context.collection.objects.link(c)
        group_of[c.name] = part
        ancestry[c.name] = ancestry.get(o.name, [o.name])
        meshes.append(c)
        lamp_from.add(o.name)
for name in lamp_from:
    group_of[name] = None


def moved(m):
    for k in pivots:
        pivots[k] = m @ pivots[k]
    for k in rig_points:
        rig_points[k] = m @ rig_points[k]


def has_image(mat):
    if flat_colour(mat):
        return True  # painted flat on purpose
    if mat is None or not mat.use_nodes:
        return False
    return any(n.type == "TEX_IMAGE" and n.image and n.image.size[0] > 0 for n in mat.node_tree.nodes)


def has_alpha(mat):
    if mat is None or not mat.use_nodes:
        return False
    return any(n.type == "TEX_IMAGE" and n.image and "alpha" in n.image.name.lower() for n in mat.node_tree.nodes)


for o in list(bpy.data.objects):
    if o.type != "MESH":
        bpy.data.objects.remove(o)
        continue
    zs = [v.co.z for v in o.data.vertices]
    flat = not zs or max(zs) - min(zs) < 0.06
    decal = flat and o.data.materials and all(has_alpha(m) for m in o.data.materials)
    # Effect cards whose pictures are image sequences Unreal plays (the accumulator's lightning)
    # come without a texture: left out.
    # Materials painted flat (`flat`) have no texture on purpose and stay (has_image says so).
    effect = o.data.materials and not any(has_image(m) for m in o.data.materials)
    if group_of.get(o.name) is None or decal or effect or not o.data.polygons:
        bpy.data.objects.remove(o)


def flat(name, colour, glow=None):
    """A plain material, linear RGB; `glow` makes it emissive (glTF emissive strength 2.5)."""
    mat = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*colour, 1)
    bsdf.inputs["Roughness"].default_value = 0.6
    if glow:
        bsdf.inputs["Emission Color"].default_value = (*glow, 1)
        bsdf.inputs["Emission Strength"].default_value = 2.5
    return mat


def named(o, keys):
    return any(n == k or n.startswith(k + ".") for n in ancestry.get(o.name, ()) for k in keys)


# Parts FUE5 leaves untextured (its rail signals' bodies take Unreal materials it didn't export):
# `paint` {"default": linear RGB, object or parent name: linear RGB}, colours from Zenith's own
# model of it (sampled from Factorio's sprite).
paint = job.get("paint")
if paint:
    for o in bpy.data.objects:
        if any(has_image(m) for m in o.data.materials):
            continue
        colour = next((c for k, c in paint.items() if k != "default" and named(o, [k])), paint["default"])
        o.data.materials.clear()
        o.data.materials.append(flat("paint_%.3f_%.3f_%.3f" % tuple(colour), colour))

# Lamps the client lights by state (`lamps`: [{"groups", "off", "parts": {anim_lit_<colour>: [base, emission]}}]):
# the lens stays in the body in its dark `off` colour, and a copy of it a little larger for each
# lit part, in its own emissive colour, kept out of the atlas (anim.gd shows one per `st`).
lit_parts = set()
for lamp in job.get("lamps", []):
    chosen = [o for o in list(bpy.data.objects) if named(o, lamp["groups"])]
    if not chosen:
        print("FUE5 lamps: nothing named", lamp["groups"])
    for o in chosen:
        o.data.materials.clear()
        o.data.materials.append(flat("lens_off_%.3f_%.3f_%.3f" % tuple(lamp["off"]), lamp["off"]))
        vs = [v.co for v in o.data.vertices]
        c = Vector([(min(v[i] for v in vs) + max(v[i] for v in vs)) / 2 for i in range(3)])
        grow = lamp.get("grow", 1.04)
        for part, (base, glow) in lamp["parts"].items():
            piece = o.copy()
            piece.data = o.data.copy()
            bpy.context.collection.objects.link(piece)
            piece.data.transform(Matrix.Translation(c) @ Matrix.Diagonal((grow, grow, grow, 1)) @ Matrix.Translation(-c))
            piece.data.materials.clear()
            piece.data.materials.append(flat(part.replace("anim_lit_", "lamp_"), base, glow))
            group_of[piece.name] = part
            ancestry[piece.name] = [piece.name]
            lit_parts.add(part)

# Units and facing: 2 units a tile, then turned so the front faces north (+Y).
yaw = math.radians(job.get("yaw", 0))
sx, sy, sz = job.get("scale", [1, 1, 1])
xf = Matrix.Diagonal((0.5 * sx, 0.5 * sy, 0.5 * sz, 1)) @ Matrix.Rotation(-yaw, 4, "Z")
for o in bpy.data.objects:
    o.data.transform(xf)
moved(xf)

lo = Vector((1e9,) * 3)
hi = Vector((-1e9,) * 3)
for o in bpy.data.objects:
    for v in o.data.vertices:
        lo = Vector(map(min, lo, v.co))
        hi = Vector(map(max, hi, v.co))
# FUE5 puts each model's origin on its footprint centre; "bbox" centres the bounds instead.
if job.get("centre") == "bbox":
    cx, cy = (lo.x + hi.x) / 2, (lo.y + hi.y) / 2
else:
    cx, cy = job.get("centre") or (0.0, 0.0)
dx, dy, dz = job.get("shift", [0, 0, 0])
move = Matrix.Translation((-cx + dx, -cy + dy, dz))
for o in bpy.data.objects:
    o.data.transform(move)
moved(move)

# `ground`: its lowest point on the ground (check.py's origin) before anything is cut
# at the ground, for models FUE5 centred in the air (robots: movers.gd flies them).
if job.get("ground"):
    low = min(v.co.z for o in bpy.data.objects for v in o.data.vertices)
    lift = Matrix.Translation((0, 0, -low))
    for o in bpy.data.objects:
        o.data.transform(lift)
    moved(lift)

# Inside the footprint (check.py: an overhang of 0.03 a side), scaled evenly about the centre.
over = max(0.01, job.get("overhang", 0.0) / 2 - 0.01)  # check.py: the overhang is over the whole width
half_x, half_y = job["size"][0] / 2 + over, job["size"][1] / 2 + over
ext_x = max(abs(v.co.x) for o in bpy.data.objects for v in o.data.vertices)
ext_y = max(abs(v.co.y) for o in bpy.data.objects for v in o.data.vertices)
if job.get("fit") == "width":  # off-centre by design (a train stop's arm over the rails): only its width
    xs = [v.co.x for o in bpy.data.objects for v in o.data.vertices]
    ys = [v.co.y for o in bpy.data.objects for v in o.data.vertices]
    ext_x, ext_y = (max(xs) - min(xs)) / 2, (max(ys) - min(ys)) / 2
fit = min(1.0, half_x / ext_x, half_y / ext_y)
if fit < 1.0:
    print("FUE5 scaled by %.3f to fit its footprint" % fit)
    for o in bpy.data.objects:
        o.data.transform(Matrix.Diagonal((fit, fit, fit, 1)))
    moved(Matrix.Diagonal((fit, fit, fit, 1)))

# A hatch cut in two (`hatch`: faces of `mats` lower than `zmax` tiles): the plate, cut to a circle of
# `radius` tiles (24 planes) and in half at x = 0, becomes the `west` and `east` parts.
hatch = job.get("hatch")
door_pieces = []
if hatch:
    for o in list(bpy.data.objects):
        mats = [m.name if m else "" for m in o.data.materials]
        bm = bmesh.new()
        bm.from_mesh(o.data)
        is_plate = lambda f: f.material_index < len(mats) and mats[f.material_index] in hatch["mats"]
        # Whatever else lies in the group the plate belongs to (`clear`: FUE5's half-open iris over
        # its hatch) goes: its dark leaves would cover the doors once raised.
        if hatch.get("clear") in ancestry.get(o.name, ()):
            others = [f for f in bm.faces if not is_plate(f)]
            if others:
                bmesh.ops.delete(bm, geom=others, context="FACES")
                bm.to_mesh(o.data)
        plate = {f.index for f in bm.faces if is_plate(f) and f.calc_center_median().z < hatch["zmax"]}
        bm.free()
        if not plate:
            continue
        for side, sign in (("west", -1.0), ("east", 1.0)):
            piece = o.copy()
            piece.data = o.data.copy()
            bpy.context.collection.objects.link(piece)
            bm = bmesh.new()
            bm.from_mesh(piece.data)
            bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.index not in plate], context="FACES")
            cuts = [((0, 0, 0), (sign, 0, 0), True)]
            for k in range(24):
                a = k * math.tau / 24
                n = (math.cos(a), math.sin(a), 0)
                cuts.append(((n[0] * hatch["radius"], n[1] * hatch["radius"], 0), n, False))
            for co, no, inner in cuts:
                geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
                bmesh.ops.bisect_plane(bm, geom=geom, plane_co=co, plane_no=no, clear_inner=inner, clear_outer=not inner)
            # Both sides: some of FUE5's plate faces down (it was seen from above only, through its
            # ground's hole), which left wedges of the door missing once raised.
            back = bmesh.ops.duplicate(bm, geom=bm.faces[:])
            bmesh.ops.reverse_faces(bm, faces=[f for f in back["geom"] if isinstance(f, bmesh.types.BMFace)])
            bm.to_mesh(piece.data)
            bm.free()
            group_of[piece.name] = hatch[side]
            door_pieces.append(piece)
        bm = bmesh.new()
        bm.from_mesh(o.data)
        bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.index in plate], context="FACES")
        bm.to_mesh(o.data)
        bm.free()

# The plate's pieces together up from where FUE5 sank them to just over the ground (`lift_to`, the
# plate's lowest point), so its layers stay as they were.
if hatch and "lift_to" in hatch and door_pieces:
    low = min(v.co.z for o in door_pieces for v in o.data.vertices)
    for o in door_pieces:
        o.data.transform(Matrix.Translation((0, 0, hatch["lift_to"] - low)))

# Nothing below the ground (FUE5's silo shaft goes 4.5 tiles down) past the spec's `sink`; after the
# hatch is taken out of it.
floor = -max(0.0, job.get("sink", 0.0) - 0.03)  # a little inside it: decimation moves points
for o in list(bpy.data.objects):
    bm = bmesh.new()
    bm.from_mesh(o.data)
    if min((v.co.z for v in bm.verts), default=0) < floor - 1e-4:
        geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
        bmesh.ops.bisect_plane(bm, geom=geom, plane_co=(0, 0, floor), plane_no=(0, 0, 1), clear_inner=True)
        bm.to_mesh(o.data)
    bm.free()
    if not o.data.polygons:
        bpy.data.objects.remove(o)

# The pit under a hatch (`pit`: radius and height in tiles): a dark, grimy floor just over the
# ground, as our own silo has, since the client draws the ground over anything below it.
pit = job.get("pit")
if pit:
    mat = bpy.data.materials.new("fue5_pit")
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    noise = nt.nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 6.0
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (0.012, 0.011, 0.010, 1)
    ramp.color_ramp.elements[1].color = (0.06, 0.05, 0.04, 1)
    nt.links.new(noise.outputs["Fac"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    bpy.ops.mesh.primitive_circle_add(vertices=48, radius=pit["radius"], fill_type="TRIFAN",
                                      location=(0, 0, pit["z"]))
    disc = bpy.context.active_object
    disc.name = "pit"
    disc.data.materials.append(mat)
    bpy.ops.object.transform_apply(location=True)
    group_of[disc.name] = ""

# Our model's size (`match`: [east-west, north-south, height] in tiles; `match_all`: every axis
# exactly, for rolling stock that must fill its length and couple as ours do): an axis more than
# MATCH_SLACK off is scaled to ours, all of them alike when that is enough; a horizontal axis is
# never squeezed under 0.9 of the footprint (ours are drawn shallow where the sprite's camera
# foreshortens them) nor stretched past what check.py allows.
MATCH_SLACK = 0.08
match = job.get("match")
if match:
    vs = [v.co for o in bpy.data.objects for v in o.data.vertices]
    cur = [max(v[i] for v in vs) - min(v[i] for v in vs) for i in range(3)]
    s = [m / c if c > 1e-6 else 1.0 for m, c in zip(match, cur)]
    if not job.get("match_all"):
        s = [k if abs(k - 1.0) > MATCH_SLACK else 1.0 for k in s]
        for i in (0, 1):
            low = 0.9 * job["size"][i] / cur[i]
            high = (job["size"][i] + job.get("overhang", 0.03) - 0.01) / cur[i]
            s[i] = min(max(s[i], min(low, 1.0)), max(high, 1.0))
        if max(s) / min(s) <= 1.0 + MATCH_SLACK:
            s = [(s[0] * s[1] * s[2]) ** (1 / 3)] * 3
    print("FUE5 matched to ours: x%.3f x%.3f x%.3f" % tuple(s))
    m = Matrix.Diagonal((s[0], s[1], s[2], 1))
    for o in bpy.data.objects:
        o.data.transform(m)
    moved(m)

# Parts put where the client expects them (`place`: groups of FUE5's objects by name, moved so
# their `anchor` (top or middle) is at `to`, glTF tiles x east, y up, z south; `copy` adds one
# instead): a pole's insulators on Factorio's wire connection points (wires.gd POLE_POINTS).
for entry in job.get("place", []):
    chosen = [o for o in list(bpy.data.objects)
              if any(n == g or n.startswith(g + ".") for n in ancestry.get(o.name, ()) for g in entry["groups"])]
    if not chosen:
        print("FUE5 place: nothing named", entry["groups"])
        continue
    if entry.get("copy"):
        copies = []
        for o in chosen:
            c = o.copy()
            c.data = o.data.copy()
            bpy.context.collection.objects.link(c)
            group_of[c.name] = group_of.get(o.name, "")
            copies.append(c)
        chosen = copies
    vs = [v.co for o in chosen for v in o.data.vertices]
    lo = Vector([min(v[i] for v in vs) for i in range(3)])
    hi = Vector([max(v[i] for v in vs) for i in range(3)])
    at = Vector(((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, hi.z if entry.get("anchor") == "top" else (lo.z + hi.z) / 2))
    tx, ty, tz = entry["to"]  # null keeps that coordinate
    goal = Vector((at.x if tx is None else tx, at.y if tz is None else -tz, at.z if ty is None else ty))
    step = Matrix.Translation(goal - at)
    for o in chosen:
        o.data.transform(step)

# A wall shape built from FUE5's one straight piece (`wall`: {"arms": sides of "nesw" it joins,
# "hub": "ew" or "ns", "hub_half": tiles, "fill": bool}): a hub of its body round the middle with
# its buttress (`post`, object names), an arm of its body from the hub to each joined side, and
# for `fill` a block over the gap in the middle of a 2x2 group of walls, on the south-east corner.
# The piece runs east-west here; arms and hubs are cut from it across x, the cuts closed with faces
# given the texture's scale from the wall's front.
wall = job.get("wall")
if wall:
    def _named(keys):
        return [o for o in bpy.data.objects if any(n in keys for n in ancestry.get(o.name, ()))]

    post_objs = _named(wall["post"])
    plate_objs = _named(wall["plate"])
    body_objs = [o for o in bpy.data.objects if o not in post_objs and o not in plate_objs]
    print("FUE5 wall: post", [o.name for o in post_objs], "plate", [o.name for o in plate_objs],
          "body", [o.name for o in body_objs])

    def _front_uv_map(o):
        """A linear (x, z) -> uv fitted to the faces looking south or north, for closing cuts."""
        import numpy as np
        rows, us = [], []
        uvl = o.data.uv_layers.active
        for p in o.data.polygons:
            if abs(p.normal.y) < 0.9:
                continue
            for li in p.loop_indices:
                co = o.data.vertices[o.data.loops[li].vertex_index].co
                rows.append([co.x, co.z, 1.0])
                us.append(list(uvl.data[li].uv))
        if len(rows) < 3:
            return None
        coef, *_ = np.linalg.lstsq(np.array(rows), np.array(us), rcond=None)
        return coef

    def _cut(o, x0, x1, caps=(True, True)):
        """A copy of `o` kept between x0 and x1 (tiles), its cuts closed where `caps` says (a cut a
        neighbour's piece or this one's own arm meets is left open: nothing sees it)."""
        c = o.copy()
        c.data = o.data.copy()
        bpy.context.collection.objects.link(c)
        group_of[c.name] = group_of.get(o.name, "")
        coef = _front_uv_map(o)
        bm = bmesh.new()
        bm.from_mesh(c.data)
        uvl = bm.loops.layers.uv.active
        for x, keep_above, cap in ((x0, True, caps[0]), (x1, False, caps[1])):
            geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
            res = bmesh.ops.bisect_plane(bm, geom=geom, plane_co=(x, 0, 0), plane_no=(1, 0, 0),
                                         clear_inner=keep_above, clear_outer=not keep_above)
            edges = [e for e in res["geom_cut"] if isinstance(e, bmesh.types.BMEdge)]
            if not edges or not cap:
                continue
            # FUE5's body and plate are open underneath (they stand on the ground), so a cut is an
            # open chain, which triangle_fill leaves unfilled: the cut then showed the inside (culled
            # faces, see-through ends on lone pillars, wall ends and corners). Close each chain
            # along the ground, its loose ends joined nearest first.
            ends = {}
            for e in edges:
                for v in e.verts:
                    ends[v] = ends.get(v, 0) + 1
            loose = [v for v, n in ends.items() if n == 1]
            while len(loose) >= 2:
                a = loose.pop()
                b = min(loose, key=lambda v: (v.co - a.co).length)
                loose.remove(b)
                if bm.edges.get((a, b)) is None:
                    edges.append(bm.edges.new((a, b)))
            made = bmesh.ops.triangle_fill(bm, use_beauty=True, use_dissolve=False, edges=edges)
            faces = [f for f in made["geom"] if isinstance(f, bmesh.types.BMFace)]
            for f in faces:
                f.normal_update()
                if (f.normal.x < 0) == (not keep_above):  # facing out of the kept part
                    f.normal_flip()
                if coef is not None and uvl is not None:
                    for lp in f.loops:
                        co = lp.vert.co
                        lp[uvl].uv = (coef[0][0] * co.y + coef[1][0] * co.z + coef[2][0],
                                      coef[0][1] * co.y + coef[1][1] * co.z + coef[2][1])
        bm.normal_update()
        bm.to_mesh(c.data)
        bm.free()
        return c

    def _move(objs_, m):
        for o in objs_:
            o.data.transform(m)

    TURN = {"e": 0.0, "n": 90.0, "w": 180.0, "s": 270.0}  # counter-clockwise from east, Blender +Y north
    made = []
    plate_half = max(abs(v.co.y) for o in plate_objs for v in o.data.vertices) if plate_objs else 0.0
    hub = wall.get("hub_half", 0.272)
    # The hub's ends along its run: closed unless an arm goes on from them ("ns" hubs turn +x north).
    arms = wall.get("arms", "")
    run = "ns" if wall.get("hub") == "ns" else "ew"
    hub_caps = (run[1] not in arms, run[0] not in arms)  # (-x, +x): w, e or s, n
    hub_objs = [_cut(o, -hub, hub, hub_caps) for o in body_objs]
    # A lone pillar (`taper`: its half width at the top, tiles) narrows upwards as wall-single.png's
    # does, on a wider foot (`foot`: the plate's width scaled by it).
    if wall.get("taper"):
        top_z = max(v.co.z for o in hub_objs for v in o.data.vertices)
        for o in hub_objs:
            for v in o.data.vertices:
                v.co.x *= 1.0 + (wall["taper"] / hub - 1.0) * max(0.0, v.co.z) / top_z
    plates = [_cut(o, -max(hub, plate_half), max(hub, plate_half), hub_caps) for o in plate_objs]
    _move(plates, Matrix.Diagonal((wall.get("foot", 1.0), 1, 1, 1)))
    hub_objs += plates
    for o in post_objs:
        c = o.copy()
        c.data = o.data.copy()
        bpy.context.collection.objects.link(c)
        group_of[c.name] = group_of.get(o.name, "")
        hub_objs.append(c)
    if wall.get("hub") == "ns":
        _move(hub_objs, Matrix.Rotation(math.radians(90), 4, "Z"))
    made += hub_objs
    for side in wall.get("arms", ""):
        # An arm across the hub's run (a corner's or a T's) starts inside the hub's narrow top: its sides
        # slope in to its narrow top, so one starting at the hub's end left a gap over it.
        across = (side in "ns") != (wall.get("hub") == "ns")
        start = wall.get("across_start", 0.08) if across else hub
        # Its end in the middle closed unless the arm opposite meets it there.
        opposite = {"n": "s", "s": "n", "e": "w", "w": "e"}[side]
        arm = [_cut(o, start, 0.5, (across and opposite not in arms, False)) for o in body_objs]
        arm += [_cut(o, max(hub, plate_half), 0.5, (False, False)) for o in plate_objs]
        _move(arm, Matrix.Rotation(math.radians(TURN[side]), 4, "Z"))
        made += arm
    if wall.get("fill"):
        # The plate's slab, raised to just under the wall's top, between the four walls' middles
        # (`fill_edge` short of them, where their tapered tops are): Factorio's wall-filling.
        top = max(v.co.z for o in body_objs for v in o.data.vertices)
        reach = 0.5 - wall.get("fill_edge", 0.105)
        block = [_cut(o, -reach, reach) for o in plate_objs]
        bz = max(v.co.z for o in block for v in o.data.vertices)
        _move(block, Matrix.Diagonal((1.0, reach / plate_half, 0.985 * top / bz, 1)))
        _move(block, Matrix.Translation((0.5, -0.5, 0)))
        made += block
    for o in post_objs + plate_objs + body_objs:
        bpy.data.objects.remove(o)

# The whole model moved so the middle of some of its objects lands on a point (`align`: {"groups",
# "to": [x, z] glTF tiles}): a rail signal's lamps where Zenith's own model has them, which the
# client's per-direction placement (model_library.gd PLACEMENT_OFFSETS) was fitted to.
align = job.get("align")
if align:
    chosen = [o for o in bpy.data.objects if named(o, align["groups"])]
    vs = [v.co for o in chosen for v in o.data.vertices]
    at = Vector([(min(v[i] for v in vs) + max(v[i] for v in vs)) / 2 for i in range(2)])
    step = Matrix.Translation((align["to"][0] - at.x, -align["to"][1] - at.y, 0))
    for o in bpy.data.objects:
        o.data.transform(step)
    moved(step)

# A piece FUE5's model lacks taken from Zenith's own model of it (`borrow`: {"glb", "min_x"}): its
# body's faces east of `min_x` (glTF tiles), each in its material's flat colour, put in the body
# as they stand there. FUE5's chain signal has the lantern but not Factorio 2.0's cabinet.
borrow = job.get("borrow")
if borrow:
    import struct
    raw = open(borrow["glb"], "rb").read()
    gl = json.loads(raw[20:20 + struct.unpack("<I", raw[12:16])[0]])
    colours = {m.get("name", ""): m.get("pbrMetallicRoughness", {}).get("baseColorFactor", [0.5, 0.5, 0.5, 1])[:3]
               for m in gl.get("materials", [])}
    before = set(bpy.data.objects.keys())
    bpy.ops.import_scene.gltf(filepath=borrow["glb"])
    for name in sorted(set(bpy.data.objects.keys()) - before):
        o = bpy.data.objects[name]
        if o.type != "MESH" or any(n.startswith("anim_") for n in [o.name] + ancestors(o)):
            continue
        o.data = o.data.copy()
        o.data.transform(o.matrix_world)
        o.parent = None
        o.matrix_world = Matrix.Identity(4)
        mats = [colours.get(m.name.split(".")[0], [0.5, 0.5, 0.5]) if m else [0.5, 0.5, 0.5] for m in o.data.materials]
        bm = bmesh.new()
        bm.from_mesh(o.data)
        bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.calc_center_median().x <= borrow["min_x"]], context="FACES")
        bm.to_mesh(o.data)
        bm.free()
        for a in list(o.data.color_attributes):
            o.data.color_attributes.remove(a)
        o.data.materials.clear()
        for c in mats:
            o.data.materials.append(flat("borrowed_%.3f_%.3f_%.3f" % tuple(c), c))
        group_of[o.name] = ""
        ancestry[o.name] = [o.name]
    for name in set(bpy.data.objects.keys()) - before:
        o = bpy.data.objects[name]
        if group_of.get(name) != "" or not o.data.polygons:
            bpy.data.objects.remove(o)

# One object per group: the body, and each moving part.
groups = {}
for o in list(bpy.data.objects):
    groups.setdefault(group_of[o.name], []).append(o)
objs = {}
for g, members in groups.items():
    bpy.ops.object.select_all(action="DESELECT")
    for o in members:
        o.select_set(True)
    bpy.context.view_layer.objects.active = members[0]
    if len(members) > 1:
        bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    ob.name = g or "body"
    objs[g] = ob

# Triangle budget: decimate every object by the same ratio.
def tris(o):
    return sum(len(p.vertices) - 2 for p in o.data.polygons)

total = sum(tris(o) for o in objs.values())
budget = job.get("budget", 10000)
print("FUE5 triangles", total, "budget", budget)
# A rig's arm on a budget of its own (`rig.budget`): its small parts would lose their shape at the
# base's ratio; the base gets what is left.
if "rig" in objs:
    ro = objs.pop("rig")
    want = rig.get("budget", tris(ro))
    if tris(ro) > want:
        mod = ro.modifiers.new("dec", "DECIMATE")
        mod.ratio = want / tris(ro)
        mod.use_collapse_triangulate = True
        bpy.context.view_layer.objects.active = ro
        bpy.ops.object.modifier_apply(modifier=mod.name)
    budget -= tris(ro)
    total = sum(tris(o) for o in objs.values())
    print("FUE5 rig arm", tris(ro), "triangles; the rest", total, "of", budget)
else:
    ro = None
# `planar`: flat faces merged first (Blender's planar dissolve, under this many degrees): FUE5's remeshed
# gear rings are dense triangle soup on flat faces, which loses nothing to it.
if job.get("planar") and total > budget:
    for o in objs.values():
        mod = o.modifiers.new("flat", "DECIMATE")
        mod.decimate_type = "DISSOLVE"
        mod.angle_limit = math.radians(job["planar"])
        mod.delimit = {"MATERIAL", "SEAM"}
        bpy.context.view_layer.objects.active = o
        bpy.ops.object.modifier_apply(modifier=mod.name)
    total = sum(tris(o) for o in objs.values())
    print("FUE5 flat faces merged:", total)
# `together`: every part collapsed in one go, so the triangles go where they matter least across the
# whole model (a splitter's gears, most of its triangles, against its body) instead of each part by the
# same share. The parts stay apart: each wears copies of its materials, tagged with its name, while joined.
if job.get("together") and total > budget:
    tagged = []
    for g, o in objs.items():
        for i, m in enumerate(o.data.materials):
            c = m.copy() if m is not None else bpy.data.materials.new("none")
            c.name = "%s|zpart|%s" % (m.name if m is not None else "", g or "body")
            c["zsrc"] = m.name if m is not None else ""
            o.data.materials[i] = c
        tagged.append(o)
    bpy.ops.object.select_all(action="DESELECT")
    for o in tagged:
        o.select_set(True)
    whole = tagged[0]
    bpy.context.view_layer.objects.active = whole
    whole.name = "zwhole"
    bpy.ops.object.join()
    mod = whole.modifiers.new("dec", "DECIMATE")
    mod.ratio = budget / max(1, tris(whole))
    mod.use_collapse_triangulate = True
    bpy.ops.object.modifier_apply(modifier=mod.name)
    for g in list(objs):
        part = whole.copy()
        part.data = whole.data.copy()
        bpy.context.collection.objects.link(part)
        bm = bmesh.new()
        bm.from_mesh(part.data)
        mats = part.data.materials
        bmesh.ops.delete(bm, geom=[f for f in bm.faces if mats[f.material_index].name.split("|zpart|")[-1] != (g or "body")],
                         context="FACES")
        bm.to_mesh(part.data)
        bm.free()
        for i, m in enumerate(part.data.materials):
            src = bpy.data.materials.get(m.get("zsrc", ""))
            part.data.materials[i] = src
        objs[g] = part
    bpy.data.objects.remove(whole)
    for g, part in objs.items():
        part.name = g or "body"
    for m in [m for m in bpy.data.materials if "|zpart|" in m.name]:
        bpy.data.materials.remove(m)
    print("FUE5 decimated together to", sum(tris(o) for o in objs.values()))
elif total > budget:
    # Small pieces (a plate cut as doors, a fan) keep every triangle: collapsing their few would
    # open holes. The rest share what is left of the budget.
    small = [o for o in objs.values() if tris(o) < 300]
    big = [o for o in objs.values() if o not in small]
    ratio = max(0.01, (budget - sum(tris(o) for o in small)) / max(1, sum(tris(o) for o in big)))
    for o in big:
        mod = o.modifiers.new("dec", "DECIMATE")
        mod.ratio = ratio
        mod.use_collapse_triangulate = True
        bpy.context.view_layer.objects.active = o
        bpy.ops.object.modifier_apply(modifier=mod.name)
    print("FUE5 decimated to", sum(tris(o) for o in objs.values()))
if ro is not None:
    objs["rig"] = ro

# Lit lamps keep their own emissive material (`lamps`); everything else shares the atlas.
baked = {g: o for g, o in objs.items() if g not in lit_parts}
# Atlas: a fresh UV map over every object, packed together, each texture baked into it.
size = job.get("tex", 2048)
atlas = bpy.data.images.new("atlas", size, size)
for o in baked.values():
    src = o.data.uv_layers[0].name if o.data.uv_layers else None
    o["src_uv"] = src or ""
    uv = o.data.uv_layers.new(name="atlas")
    o.data.uv_layers.active = uv
for mat in bpy.data.materials:
    if not mat.use_nodes:
        continue
    nt = mat.node_tree
    for n in list(nt.nodes):
        if n.type == "TEX_IMAGE" and not n.inputs["Vector"].is_linked:
            uvn = nt.nodes.new("ShaderNodeUVMap")
            uvn.uv_map = "UVMap"
            nt.links.new(uvn.outputs["UV"], n.inputs["Vector"])
    target = nt.nodes.new("ShaderNodeTexImage")
    target.image = atlas
    nt.nodes.active = target
# UV maps named per object: point each texture at its object's own map.
for o in baked.values():
    for mat in o.data.materials:
        if mat and mat.use_nodes:
            for n in mat.node_tree.nodes:
                if n.type == "UVMAP":
                    n.uv_map = o["src_uv"]

bpy.ops.object.select_all(action="DESELECT")
for o in baked.values():
    o.select_set(True)
bpy.context.view_layer.objects.active = next(iter(baked.values()))
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.select_all(action="SELECT")
bpy.ops.uv.smart_project(angle_limit=math.radians(60), island_margin=0.002, area_weight=0.0, scale_to_bounds=False)
bpy.ops.uv.pack_islands(margin=0.002)
bpy.ops.object.mode_set(mode="OBJECT")

scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.device = "CPU"
scene.cycles.samples = 1
scene.render.bake.use_pass_direct = False
scene.render.bake.use_pass_indirect = False
scene.render.bake.use_pass_color = True
scene.render.bake.margin = 6
bpy.ops.object.bake(type="DIFFUSE", pass_filter={"COLOR"}, use_clear=True, margin=6)

# One material: the atlas on the atlas map.
mat = bpy.data.materials.new(job.get("name", "fue5"))
mat.use_nodes = True
nt = mat.node_tree
bsdf = nt.nodes["Principled BSDF"]
bsdf.inputs["Roughness"].default_value = 0.7
bsdf.inputs["Metallic"].default_value = 0.0
tex = nt.nodes.new("ShaderNodeTexImage")
tex.image = atlas
nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
atlas.file_format = "JPEG"


def _lit(name, color, strength, image=None):
    """A material lit in `color` (the shader dims it by the part's glow), its base colour the atlas
    or the colour itself."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Roughness"].default_value = 0.5
    if image is not None:
        t = m.node_tree.nodes.new("ShaderNodeTexImage")
        t.image = image
        m.node_tree.links.new(t.outputs["Color"], b.inputs["Base Color"])
    else:
        b.inputs["Base Color"].default_value = (*color, 1)
    b.inputs["Emission Color"].default_value = (*color, 1)
    b.inputs["Emission Strength"].default_value = strength
    return m


# Faces of a `glow_mats` material ({FUE5 material: [r, g, b, strength]}) get a lit copy of the atlas
# material: a logistic robot's red thruster tips, lit while it flies (robot_part 1).
glow_mats = job.get("glow_mats", {})
glow_of = {}
for key, (r, g, b_, strength) in glow_mats.items():
    glow_of[key] = _lit(job.get("name", "fue5") + "_glow_" + key, (r, g, b_), strength, atlas)
for gname, o in baked.items():
    if gname in lamp_color:
        o.data.materials.clear()
        o.data.materials.append(_lit(job.get("name", "fue5") + "_" + gname, tuple(lamp_color[gname]), 1.5))
        for uv in list(o.data.uv_layers):
            if uv.name != "atlas":
                o.data.uv_layers.remove(uv)
        o.data.uv_layers["atlas"].name = "UVMap"
        continue
    names = [(m.name.split(".")[0] if m else "") for m in o.data.materials]
    lit = [names[p.material_index] if p.material_index < len(names) and names[p.material_index] in glow_of else None
           for p in o.data.polygons]
    o.data.materials.clear()
    o.data.materials.append(mat)
    keys = sorted({k for k in lit if k})
    for k in keys:
        o.data.materials.append(glow_of[k])
    for p, k in zip(o.data.polygons, lit):
        p.material_index = 1 + keys.index(k) if k else 0
    for uv in list(o.data.uv_layers):
        if uv.name != "atlas":
            o.data.uv_layers.remove(uv)
    o.data.uv_layers["atlas"].name = "UVMap"

# Moving parts: their origin on the pivot.
for g, o in objs.items():
    if not g or g == "rig":
        continue
    piv = job.get("pivot", {}).get(g, "bone" if g in pivots else "centre")
    if piv == "bone":
        piv = list(pivots[g])
    elif piv == "axis":  # on the model's vertical middle line, at the part's foot
        piv = [0.0, 0.0, min(v.co.z for v in o.data.vertices)]
    elif piv == "axis_top":  # the same line, at the part's top: where a robot's legs or arms hang from
        piv = [0.0, 0.0, max(v.co.z for v in o.data.vertices)]
    elif piv == "bbox":
        vs = [v.co for v in o.data.vertices]
        piv = [(min(v[i] for v in vs) + max(v[i] for v in vs)) / 2 for i in range(3)]
    elif piv == "centre":
        vs = [v.co for v in o.data.vertices]
        c = sum(vs, Vector()) / len(vs)
        piv = [c.x, c.y, min(v.z for v in vs)]
    p = Vector(piv)
    o.data.transform(Matrix.Translation(-p))
    o.location = p

# The rig's armature, model_rig.gd's joints: Base on the ground, Lower Arm at the shoulder, Upper
# Arm at the elbow, a pincer at each finger's root; the arm skinned to it at rest.
if ro is not None:
    data = bpy.data.armatures.new("inserter_rig")
    armature = bpy.data.objects.new("inserter_rig", data)
    bpy.context.collection.objects.link(armature)
    bpy.ops.object.select_all(action="DESELECT")
    bpy.context.view_layer.objects.active = armature
    armature.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    P = rig_points

    def _bone(name, head, tail, parent=None):
        b = data.edit_bones.new(name)
        b.head, b.tail = head, tail
        if parent is not None:
            b.parent = data.edit_bones[parent]
        return b

    _bone("Base", Vector((0, 0, 0)), Vector((0, 0, P["shoulder"].z or 0.05)))
    # No Rotation joint: nothing of FUE5's arm turns apart from it (its dome is round), and a
    # turntable joint without a part would be drawn empty.
    _bone("Lower Arm", P["shoulder"], P["elbow"], "Base")
    _bone("Upper Arm", P["elbow"], P["wrist"], "Lower Arm")
    _bone("Pincer1", P["pa"], P["pa_tip"], "Upper Arm")
    _bone("Pincer2", P["pb"], P["pb_tip"], "Upper Arm")
    bpy.ops.object.mode_set(mode="OBJECT")
    ro.parent = armature
    mod = ro.modifiers.new("rig", "ARMATURE")
    mod.object = armature
    print("FUE5 rig joints:", {k: [round(x, 3) for x in v] for k, v in P.items()})

bpy.ops.export_scene.gltf(filepath=job["out"], export_format="GLB", export_image_format="JPEG",
                          export_jpeg_quality=88, export_yup=True, export_apply=True,
                          export_animations=False, export_skins=ro is not None, export_morph=False,
                          export_cameras=False, export_lights=False)
print("FUE5 wrote", job["out"], {g or "body": tris(o) for g, o in objs.items()})
