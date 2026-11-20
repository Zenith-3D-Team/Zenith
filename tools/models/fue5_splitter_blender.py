"""Blender side of fue5.py's splitters: FUE5's splitter body (fue5_blender.py's .glb) over two of FUE5's
straight belts (fue5_belt_blender.py's .glb), one under each half, as one model.

    blender --background --factory-startup --python tools/models/fue5_splitter_blender.py -- JOB.json

JOB: {"body": path.glb, "belt": path.glb, "out": path.glb, "halves": [x, ...] tile centres east of the middle}

FUE5's splitter is the structure alone (gears, chevron plates, the rack): in Unreal it stood over its own
belts. Factorio draws a splitter's structure over two belt pictures, so the belt under each half is FUE5's
belt piece of the same tier, its surface (`fue5_belt_surface`) scrolling as a belt's does
(model_library.gd _setup_belt) and its frame FUE5's steel. Both pieces keep their own materials and the
body its moving parts (`anim_*` nodes), as the two files had them.
"""

import json
import sys

import bpy
from mathutils import Matrix

job = json.load(open(sys.argv[sys.argv.index("--") + 1]))
bpy.ops.wm.read_factory_settings(use_empty=True)

bpy.ops.import_scene.gltf(filepath=job["body"])
# `mirror`: FUE5's splitter is Factorio's mirrored east-west (its cable trails off the west end, the
# sprite's the east): flipped across x, its faces turned back out and its normals made again (shaded smooth
# under 30 degrees, as FUE5's hard edges were), each moving part's pivot with it.
if job.get("mirror"):
    for o in list(bpy.data.objects):
        if o.type != "MESH":
            continue
        o.data.transform(Matrix.Diagonal((-1.0, 1.0, 1.0, 1.0)))
        o.data.flip_normals()
        o.location.x = -o.location.x
        bpy.ops.object.select_all(action="DESELECT")
        o.select_set(True)
        bpy.context.view_layer.objects.active = o
        if o.data.has_custom_normals:
            bpy.ops.mesh.customdata_custom_splitnormals_clear()
        bpy.ops.object.shade_smooth_by_angle(angle=0.5236)
before = set(bpy.data.objects.keys())
bpy.ops.import_scene.gltf(filepath=job["belt"])
belt = next(bpy.data.objects[n] for n in set(bpy.data.objects.keys()) - before if bpy.data.objects[n].type == "MESH")
belt.parent = None
belt.data.transform(belt.matrix_world)
belt.matrix_world = Matrix.Identity(4)
belt.name = "belt"
pieces = [belt]
for _ in job["halves"][1:]:
    c = belt.copy()
    c.data = belt.data.copy()
    bpy.context.collection.objects.link(c)
    pieces.append(c)
for piece, x in zip(pieces, job["halves"]):
    piece.data.transform(Matrix.Translation((x, 0.0, 0.0)))
# The belts are static: they join the body, whose node the client merges into the model's mesh.
body = bpy.data.objects.get("body")
bpy.ops.object.select_all(action="DESELECT")
for o in pieces + [body]:
    o.select_set(True)
bpy.context.view_layer.objects.active = body
bpy.ops.object.join()
for o in list(bpy.data.objects):
    if o.type not in ("MESH",) and not o.children:
        bpy.data.objects.remove(o)

bpy.ops.export_scene.gltf(filepath=job["out"], export_format="GLB", export_image_format="JPEG",
                          export_jpeg_quality=90, export_yup=True, export_apply=True,
                          export_animations=False, export_skins=False, export_morph=False,
                          export_cameras=False, export_lights=False)
print("FUE5 wrote", job["out"], {o.name: sum(len(p.vertices) - 2 for p in o.data.polygons)
                                 for o in bpy.data.objects if o.type == "MESH"})
