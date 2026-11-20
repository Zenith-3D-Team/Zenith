"""Blender side of fue5.py's underground belts: FUE5's underground-belt/static.fbx as one entrance (or exit).

    blender --background --factory-startup --python tools/models/fue5_underground_blender.py -- JOB.json

JOB: {"fbx": the underground's FBX, "belt_fbx": FUE5's belt-I.fbx, "out": path.glb,
      "paint": the tier's hood picture (fue5.py _underground_paint), "pictures": {"steel", "rim", "side": path},
      "surface": the tier's belt surface picture, "frame": FUE5's belt side picture,
      "scale": [across, along, up] on FUE5's own size (2 units a tile), "slab_end": tiles north of the middle
      where the belt under the hood stops, "slab_half": its half width, "hood_north": the hood's middle north of the tile's, "inner": [r, g, b] linear, "budget": triangles}

FUE5's underground (2 units a tile, Z up) is a quarter-round hood: its mouth, open and as tall as the hood,
at FUE5's -X, its back curving down to the ground at +X, two bolted rims on its edges and a cheek each side.
It has no belt (FUE5's game laid one under it): the belt here is FUE5's own straight slab (belt-I.fbx, as
fue5_belt_blender.py's) from the tile's open edge under the hood, cut where the hood comes down to it, its top
the tier's scrolling `fue5_belt_surface` (model_library.gd _setup_belt: an exit's model is the entrance
turned half way round, its belt run backwards). Zenith's entrance faces north with its mouth south, where
items come in (Wube's and Zenith's own models): FUE5's -X turned to the south. One file serves both ends:
the exit is drawn as this one turned round (model_library.gd turn_dir).

Dropped: a box under the ground in front of the mouth (FUE5's pit for its belt) and the see-through
gradient across the mouth (`darken`); the shell's inner faces are a flat dark instead (`inner`), the shadow
under the hood Factorio's sprite has. The hood's yellow-and-chevron picture (mat1) and its shine (specular)
carry a stamped trademark and aren't used: fue5.py draws the chevrons afresh from FUE5's clean normal map.
"""

import json
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

job = json.load(open(sys.argv[sys.argv.index("--") + 1]))
bpy.ops.wm.read_factory_settings(use_empty=True)


def material(name, path=None, colour=None, metallic=0.0, roughness=0.7):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    if path:
        tex = nt.nodes.new("ShaderNodeTexImage")
        tex.image = bpy.data.images.load(path)
        tex.extension = "REPEAT"
        nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    else:
        bsdf.inputs["Base Color"].default_value = list(colour) + [1.0]
    return mat


pics = job["pictures"]
mats = {"mat1": material("fue5_ug_paint", job["paint"]), "mat2": material("fue5_ug_steel", pics["steel"]),
        "mat3": material("fue5_ug_rim", pics["rim"]), "mat4": material("fue5_ug_side", pics["side"])}
inner = material("fue5_ug_inner", colour=job["inner"])
surface = material("fue5_belt_surface", job["surface"])
frame = material("fue5_belt_frame", job["frame"])


def flatten(objs):
    for o in objs:
        o.data = o.data.copy()
        m = o.matrix_world.copy()
        o.parent = None
        o.data.transform(m)
        o.matrix_world = Matrix.Identity(4)


def tris(o):
    return sum(len(p.vertices) - 2 for p in o.data.polygons)


# --- The hood ---------------------------------------------------------------------------------
bpy.ops.import_scene.fbx(filepath=job["fbx"])
hood = [o for o in bpy.data.objects if o.type == "MESH" and o.name not in ("Cube", "darken")]
flatten(hood)
for o in list(bpy.data.objects):
    if o not in hood:
        bpy.data.objects.remove(o)
for o in hood:
    me = o.data
    for i, mm in enumerate(me.materials):
        me.materials[i] = mats.get(mm.name.split(".")[0], mats["mat2"]) if mm is not None else mats["mat2"]
# Within the budget: the bolts and the rims' fine rounding are far denser than the rest.
budget = job["budget"]
total = sum(tris(o) for o in hood)
print("FUE5 hood triangles", total)
for o in hood:
    t = tris(o)
    target = None
    if o.name.startswith("Sphere"):
        target = 24  # two bolts, each a dozen triangles
    elif o.name.startswith("Extrude_1"):
        target = int(budget * 0.35)
    elif o.name.startswith("Plane"):
        target = 120
    if target and t > target:
        bpy.context.view_layer.objects.active = o
        mod = o.modifiers.new("dec", "DECIMATE")
        mod.ratio = target / t
        mod.use_collapse_triangulate = True
        bpy.ops.object.select_all(action="DESELECT")
        o.select_set(True)
        bpy.ops.object.modifier_apply(modifier=mod.name)
print("FUE5 hood decimated to", sum(tris(o) for o in hood))
# The shell's inside. FUE5's cover and cheeks are single surfaces facing out, and Zenith draws a face
# from its front only: seen through the mouth the hood would be empty. Each gets a copy facing in, in
# the flat dark of the sprite's shadow under the hood.
for o in hood:
    me = o.data
    cover = o.name.startswith("Extrude") and not o.name.startswith("Extrude_1")
    if cover or o.name.startswith("Plane"):
        me.materials.append(inner)
        k = len(me.materials) - 1
        bm = bmesh.new()
        bm.from_mesh(me)
        faces = [f for f in bm.faces if not cover or me.materials[f.material_index] is mats["mat1"]]
        dup = bmesh.ops.duplicate(bm, geom=faces)
        inside = [f for f in dup["geom"] if isinstance(f, bmesh.types.BMFace)]
        bmesh.ops.reverse_faces(bm, faces=inside)
        for f in inside:
            f.material_index = k
        bm.to_mesh(me)
        bm.free()
        print("FUE5 inner faces for", o.name, len(inside))
bpy.ops.object.select_all(action="DESELECT")
for o in hood:
    o.select_set(True)
bpy.context.view_layer.objects.active = hood[0]
bpy.ops.object.join()
body = bpy.context.view_layer.objects.active
body.name = "body"
sx, sy, sz = job["scale"]
# FUE5's -X (the mouth) to Blender -Y (south): a quarter turn anticlockwise seen from above.
turn = Matrix.Rotation(1.5707963, 4, "Z")
body.data.transform(Matrix.Diagonal((sx * 0.5, sy * 0.5, sz * 0.5, 1)) @ turn)
vs = [v.co for v in body.data.vertices]
lo = Vector([min(v[i] for v in vs) for i in range(3)])
hi = Vector([max(v[i] for v in vs) for i in range(3)])
body.data.transform(Matrix.Translation((-(lo.x + hi.x) / 2, job["hood_north"] - (lo.y + hi.y) / 2, -lo.z)))
print("FUE5 hood size %.3f x %.3f x %.3f" % tuple(hi - lo))

# --- The belt under it ------------------------------------------------------------------------
before = set(bpy.data.objects.keys())
bpy.ops.import_scene.fbx(filepath=job["belt_fbx"])
slab = [bpy.data.objects[n] for n in set(bpy.data.objects.keys()) - before if bpy.data.objects[n].type == "MESH"]
flatten(slab)
for o in list(bpy.data.objects):
    if o.name not in before and o not in slab:
        bpy.data.objects.remove(o)
for o in slab:
    for i, mm in enumerate(o.data.materials):
        o.data.materials[i] = surface if mm is not None and mm.name.startswith("mat1") else frame
    # FUE5's slab (0.4625 tiles either side of the middle) narrowed to fit between the cheeks, its
    # height and surface the belts' own.
    o.data.transform(Matrix.Diagonal((0.5 * job["slab_half"] / 0.4625, 0.5, 0.5, 1)))
bpy.ops.object.select_all(action="DESELECT")
for o in slab:
    o.select_set(True)
bpy.context.view_layer.objects.active = slab[0]
if len(slab) > 1:
    bpy.ops.object.join()
belt = bpy.context.view_layer.objects.active
bm = bmesh.new()
bm.from_mesh(belt.data)
cut = bmesh.ops.bisect_plane(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:], plane_co=(0, job["slab_end"], 0),
                             plane_no=(0, 1, 0), clear_outer=True)
edges = [e for e in cut["geom_cut"] if isinstance(e, bmesh.types.BMEdge)]
new = bmesh.ops.edgeloop_fill(bm, edges=edges)
frame_index = list(belt.data.materials).index(frame)
for f in new["faces"]:
    f.material_index = frame_index
    f.normal_update()
    if f.normal.y < 0.0:
        f.normal_flip()
bm.normal_update()
bm.to_mesh(belt.data)
bm.free()
bpy.ops.object.select_all(action="DESELECT")
belt.select_set(True)
body.select_set(True)
bpy.context.view_layer.objects.active = body
bpy.ops.object.join()
body = bpy.context.view_layer.objects.active
body.name = "body"

bpy.ops.export_scene.gltf(filepath=job["out"], export_format="GLB", export_image_format="JPEG",
                          export_jpeg_quality=90, export_yup=True, export_apply=True,
                          export_animations=False, export_skins=False, export_morph=False,
                          export_cameras=False, export_lights=False)
print("FUE5 wrote", job["out"], tris(body), "triangles")
