"""Blender side of fue5.py's belts: FUE5's belt-I.fbx (straight) or belt-L.fbx (curve) as one belt piece.

    blender --background --factory-startup --python tools/models/fue5_belt_blender.py -- JOB.json

JOB: {"fbx": path or null, "out": path.glb, "piece": "straight" | "curve-left" | "curve-right" | "start" | "end",
      "surface": the tier's surface picture, "frame": FUE5's side picture, "nose": [length, height] in tiles}

FUE5's belt is a slab (2 units a tile, Z up): its top face (mat1) is the moving surface, its sides (mat2)
the frame. Unlike fue5_blender.py nothing is baked into an atlas: the top keeps FUE5's own UVs (U runs
along the belt, 0 to 1 a tile, the way items go: four slats a tile, as Factorio's sprite) on its own
material, `fue5_belt_surface`, which model_library.gd scrolls at the tier's speed (_setup_belt,
_belt_uv_scroll) as it does a modeller's textured belt; the sides keep theirs on `fue5_belt_frame`.
FUE5's straight runs north (Blender +Y) as Zenith's do. Its L piece turns round the north-east corner, in
at the east edge, out at the north: Zenith's right curve; the left curve is its mirror image. Both curves
are centred on a radius of 0.5 tiles from the corner, the slab from 0.04 to 0.97, so Factorio's lanes
(radii 0.25 and 0.75) lie on it as on its straights (+-0.46).

FUE5 has no line-end pieces. "start" and "end" are made here: a short sloping nose of the frame where
a line begins or ends, so the slab's square end reads as a belt's closed end. Zenith models end
pieces with the belt running east (model_library.gd BELT_END_FACING): the end past the tile's east
edge, the start past its west edge.
"""

import json
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

job = json.load(open(sys.argv[sys.argv.index("--") + 1]))
bpy.ops.wm.read_factory_settings(use_empty=True)


def material(name, path):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = 0.7
    bsdf.inputs["Metallic"].default_value = 0.0
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = bpy.data.images.load(path)
    tex.extension = "REPEAT"
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    return mat


frame = material("fue5_belt_frame", job["frame"])
piece = job["piece"]

if piece in ("start", "end"):
    # The nose: the slab's top (`height`) sloping down over `length` past the tile edge to a third
    # of it, closed at its end, as wide as the slab; UVs a planar map of the frame picture.
    length, height = job["nose"]
    half = job.get("half_width", 0.4625)
    low = height / 3.0
    sign = 1.0 if piece == "end" else -1.0
    x0, x1 = 0.5 * sign, (0.5 + length) * sign
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    pts = {}
    for side, y in (("s", -half), ("n", half)):
        pts[side] = [bm.verts.new(p) for p in ((x0, y, 0.007), (x0, y, height), (x1, y, low), (x1, y, 0.007))]
    s, n = pts["s"], pts["n"]
    faces = [
        [s[0], s[1], s[2], s[3]],  # south side
        [n[3], n[2], n[1], n[0]],  # north side
        [s[1], n[1], n[2], s[2]],  # sloping top
        [s[2], n[2], n[3], s[3]],  # end
        [s[0], s[3], n[3], n[0]],  # underneath
    ]
    for vs in faces:
        f = bm.faces.new(vs)
        for lp in f.loops:
            co = lp.vert.co
            lp[uv].uv = ((co.y + half) / (2 * half), co.z / height)
    bm.normal_update()
    # Every face facing out of the nose.
    for f in bm.faces:
        c = f.calc_center_median()
        mid = ((x0 + x1) / 2, 0.0, height / 2)
        if (c - Vector(mid)).dot(f.normal) < 0:
            f.normal_flip()
    me = bpy.data.meshes.new("body")
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new("body", me)
    bpy.context.collection.objects.link(ob)
    me.materials.append(frame)
else:
    surface = material("fue5_belt_surface", job["surface"])
    bpy.ops.import_scene.fbx(filepath=job["fbx"])
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    for o in meshes:
        o.data = o.data.copy()
        m = o.matrix_world.copy()
        o.parent = None
        o.data.transform(m)
        o.matrix_world = Matrix.Identity(4)
        # In place: clearing the slots would set every face's to the first.
        for i, mm in enumerate(o.data.materials):
            o.data.materials[i] = surface if mm is not None and mm.name.startswith("mat1") else frame
    for o in list(bpy.data.objects):
        if o.type != "MESH":
            bpy.data.objects.remove(o)
    bpy.ops.object.select_all(action="DESELECT")
    for o in meshes:
        o.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    if len(meshes) > 1:
        bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    ob.name = "body"
    xf = Matrix.Diagonal((0.5, 0.5, 0.5, 1))
    if piece.startswith("curve"):
        # FUE5's arcs turn round a point 0.011 tiles west of the tile's corner: moved onto it, so the
        # slats' rows run round Zenith's centre (the shader's belt_coords) and the fit of the texture's
        # scroll (model_library.gd _belt_uv_scroll) finds no sideways drift (0.12 a tile before).
        me = ob.data
        uvl = me.uv_layers[0]
        rows = {}
        for p in me.polygons:
            if me.materials[p.material_index].name == "fue5_belt_surface":
                for li in p.loop_indices:
                    co = xf @ me.vertices[me.loops[li].vertex_index].co
                    rows.setdefault(round(uvl.data[li].uv[1], 2), {})[me.loops[li].vertex_index] = co
        centres = []
        for pts in rows.values():
            pts = list(pts.values())
            # A circle through the row (least squares, x^2 + y^2 = 2ax + 2by + c).
            sxx = sum(p.x * p.x for p in pts); syy = sum(p.y * p.y for p in pts); sxy = sum(p.x * p.y for p in pts)
            sx = sum(p.x for p in pts); sy = sum(p.y for p in pts); n = len(pts)
            r2 = [p.x * p.x + p.y * p.y for p in pts]
            rhs = (sum(2 * p.x * q for p, q in zip(pts, r2)), sum(2 * p.y * q for p, q in zip(pts, r2)), sum(r2))
            m = Matrix(((4 * sxx, 4 * sxy, 2 * sx), (4 * sxy, 4 * syy, 2 * sy), (2 * sx, 2 * sy, n)))
            a, b, c = m.inverted() @ Vector(rhs)
            if c + a * a + b * b > 0.04:  # the inner row (radius 0.035) is too short an arc to say
                centres.append((a, b))
        ca = sum(c[0] for c in centres) / len(centres)
        cb = sum(c[1] for c in centres) / len(centres)
        print("FUE5 curve centre (%.4f, %.4f) moved onto the corner" % (ca, cb))
        xf = Matrix.Translation((0.5 - ca, 0.5 - cb, 0)) @ xf
    if piece == "curve-left":
        xf = Matrix.Diagonal((-1, 1, 1, 1)) @ xf
    ob.data.transform(xf)
    if piece == "curve-left":
        ob.data.flip_normals()
    ob.data.update()

bpy.ops.export_scene.gltf(filepath=job["out"], export_format="GLB", export_image_format="JPEG",
                          export_jpeg_quality=90, export_yup=True, export_apply=True,
                          export_animations=False, export_skins=False, export_morph=False,
                          export_cameras=False, export_lights=False)
print("FUE5 wrote", job["out"], piece, sum(len(p.vertices) - 2 for p in ob.data.polygons), "triangles")
