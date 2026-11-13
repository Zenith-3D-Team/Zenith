#!/usr/bin/env python3
"""client/tests/fixtures/rig_inserter.glb: the smallest inserter rigged as an arm, for
model_textures_test.gd's rig section (client/scripts/world/model_rig.gd). One skinned mesh of boxes,
each on one bone, the joints named as Vasillo's inserters name theirs, the arm standing straight up:

    Base       a platform, its one long leg to the west (so the loader turns it a quarter turn)
    Rotation   a turntable at 0.1
    Lower Arm  0.3 to 1.0          Upper Arm  1.0 to 1.8
    Pincer1/2  at 1.8: a bar out to the side and a finger up at its end, at -Z and +Z

Run again only to change the fixture."""
import json
import os
import struct

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "client", "tests", "fixtures", "rig_inserter.glb")

# name, parent joint, head (global)
JOINTS = [("Base", -1, (0, 0, 0)), ("Rotation", 0, (0, 0.1, 0)), ("Lower Arm", 1, (0, 0.3, 0)),
          ("Upper Arm", 2, (0, 1.0, 0)), ("Pincer1", 3, (0, 1.8, 0)), ("Pincer2", 3, (0, 1.8, 0))]
# (min, max) boxes and their bone
BOXES = [((-0.6, 0.0, -0.45), (0.45, 0.1, 0.45), 0),
         ((-0.12, 0.1, -0.12), (0.12, 0.3, 0.12), 1),
         ((-0.05, 0.3, -0.05), (0.05, 1.0, 0.05), 2),
         ((-0.06, 1.0, -0.06), (0.06, 1.8, 0.06), 3),
         ((-0.04, 1.8, -0.15), (0.04, 1.85, -0.02), 4), ((-0.04, 1.8, -0.25), (0.04, 2.1, -0.15), 4),
         ((-0.04, 1.8, 0.02), (0.04, 1.85, 0.15), 5), ((-0.04, 1.8, 0.15), (0.04, 2.1, 0.25), 5)]


def box(lo, hi, bone):
    (x0, y0, z0), (x1, y1, z1) = lo, hi
    faces = [((0, 1, 0), [(x0, y1, z0), (x1, y1, z0), (x1, y1, z1), (x0, y1, z1)]),
             ((0, -1, 0), [(x0, y0, z1), (x1, y0, z1), (x1, y0, z0), (x0, y0, z0)]),
             ((0, 0, 1), [(x0, y0, z1), (x0, y1, z1), (x1, y1, z1), (x1, y0, z1)]),
             ((0, 0, -1), [(x1, y0, z0), (x1, y1, z0), (x0, y1, z0), (x0, y0, z0)]),
             ((1, 0, 0), [(x1, y0, z1), (x1, y1, z1), (x1, y1, z0), (x1, y0, z0)]),
             ((-1, 0, 0), [(x0, y0, z0), (x0, y1, z0), (x0, y1, z1), (x0, y0, z1)])]
    pos, nrm, idx = [], [], []
    for n, quad in faces:
        b = len(pos)
        pos += quad
        nrm += [n] * 4
        idx += [b, b + 2, b + 1, b, b + 3, b + 2]
    return pos, nrm, idx, [(bone, 0, 0, 0)] * len(pos), [(1.0, 0.0, 0.0, 0.0)] * len(pos)


pos, nrm, idx, joints, weights = [], [], [], [], []
for lo, hi, bone in BOXES:
    p, n, i, j, w = box(lo, hi, bone)
    idx += [k + len(pos) for k in i]
    pos += p
    nrm += n
    joints += j
    weights += w

blob = bytearray()
views, accs = [], []


def add(data, fmt, typ, comp, count, target=None, mm=None):
    while len(blob) % 4:
        blob.append(0)
    off = len(blob)
    blob.extend(struct.pack("<" + fmt * len(data), *data))
    v = {"buffer": 0, "byteOffset": off, "byteLength": len(blob) - off}
    if target:
        v["target"] = target
    views.append(v)
    a = {"bufferView": len(views) - 1, "componentType": comp, "count": count, "type": typ}
    if mm:
        a["min"], a["max"] = mm
    accs.append(a)
    return len(accs) - 1


flat = lambda rows: [x for r in rows for x in r]  # noqa: E731
p_acc = add(flat(pos), "f", "VEC3", 5126, len(pos), 34962,
            ([min(p[i] for p in pos) for i in range(3)], [max(p[i] for p in pos) for i in range(3)]))
n_acc = add(flat(nrm), "f", "VEC3", 5126, len(nrm), 34962)
j_acc = add(flat(joints), "H", "VEC4", 5123, len(joints), 34962)
w_acc = add(flat(weights), "f", "VEC4", 5126, len(weights), 34962)
i_acc = add(idx, "H", "SCALAR", 5123, len(idx), 34963)
ibm = []
for _name, _parent, (x, y, z) in JOINTS:  # column-major: undo the joint's place
    ibm += [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -x, -y, -z, 1]
ib_acc = add(ibm, "f", "MAT4", 5126, len(JOINTS))

# Nodes: 0 the root, 1 the mesh, 2.. the joints (each translated from its parent joint).
nodes = [{"name": "Inserter_Arm", "children": [1, 2]}, {"name": "Inserter", "mesh": 0, "skin": 0}]
for k, (name, parent, head) in enumerate(JOINTS):
    base = JOINTS[parent][2] if parent >= 0 else (0, 0, 0)
    nodes.append({"name": name, "translation": [head[i] - base[i] for i in range(3)]})
for k, (_name, parent, _head) in enumerate(JOINTS):
    if parent >= 0:
        nodes[2 + parent].setdefault("children", []).append(2 + k)

doc = {
    "asset": {"version": "2.0", "generator": "make_rig_fixture.py"},
    "scene": 0, "scenes": [{"nodes": [0]}], "nodes": nodes,
    "meshes": [{"primitives": [{"attributes": {"POSITION": p_acc, "NORMAL": n_acc, "JOINTS_0": j_acc,
                                               "WEIGHTS_0": w_acc}, "indices": i_acc, "material": 0}]}],
    "materials": [{"name": "rig", "pbrMetallicRoughness": {"baseColorFactor": [0.8, 0.5, 0.1, 1]}}],
    "skins": [{"joints": list(range(2, 2 + len(JOINTS))), "inverseBindMatrices": ib_acc}],
    "buffers": [{"byteLength": 0}], "bufferViews": views, "accessors": accs,
}
while len(blob) % 4:
    blob.append(0)
doc["buffers"][0]["byteLength"] = len(blob)
js = json.dumps(doc, separators=(",", ":")).encode()
while len(js) % 4:
    js += b" "
out = struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(blob))
out += struct.pack("<II", len(js), 0x4E4F534A) + js + struct.pack("<II", len(blob), 0x004E4942) + bytes(blob)
os.makedirs(os.path.dirname(OUT), exist_ok=True)
open(OUT, "wb").write(out)
print("wrote", os.path.normpath(OUT), len(out), "bytes")
