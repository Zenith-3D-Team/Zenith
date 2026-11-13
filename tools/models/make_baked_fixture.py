#!/usr/bin/env python3
"""client/tests/fixtures/baked_box.glb: the smallest skinned model with a baked action, for
model_bake_test.gd. Two boxes, the bottom one on bone "Base" (still), the top one on bone "Spin",
which turns a full turn about Y over one second (31 keys). Run again only to change the fixture."""
import json
import math
import os
import struct

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "client", "tests", "fixtures", "baked_box.glb")


def box(y0, y1, bone):
    pos, nrm, idx, joints, weights = [], [], [], [], []
    faces = [((0, 1, 0), [(-.5, y1, -.5), (.5, y1, -.5), (.5, y1, .5), (-.5, y1, .5)]),
             ((0, -1, 0), [(-.5, y0, .5), (.5, y0, .5), (.5, y0, -.5), (-.5, y0, -.5)]),
             ((0, 0, 1), [(-.5, y0, .5), (-.5, y1, .5), (.5, y1, .5), (.5, y0, .5)]),
             ((0, 0, -1), [(.5, y0, -.5), (.5, y1, -.5), (-.5, y1, -.5), (-.5, y0, -.5)]),
             ((1, 0, 0), [(.5, y0, .5), (.5, y1, .5), (.5, y1, -.5), (.5, y0, -.5)]),
             ((-1, 0, 0), [(-.5, y0, -.5), (-.5, y1, -.5), (-.5, y1, .5), (-.5, y0, .5)])]
    for n, quad in faces:
        b = len(pos)
        for p in quad:
            pos.append(p)
            nrm.append(n)
            joints.append((bone, 0, 0, 0))
            weights.append((1.0, 0.0, 0.0, 0.0))
        idx += [b, b + 2, b + 1, b, b + 3, b + 2]
    return pos, nrm, idx, joints, weights


lo = box(0.0, 0.5, 0)
hi = box(0.5, 1.0, 1)
pos = lo[0] + hi[0]
nrm = lo[1] + hi[1]
idx = lo[2] + [i + len(lo[0]) for i in hi[2]]
joints = lo[3] + hi[3]
weights = lo[4] + hi[4]
KEYS = 31
times = [k / (KEYS - 1) for k in range(KEYS)]
rots = []
for t in times:
    a = t * 2 * math.pi
    rots += [0.0, math.sin(a / 2), 0.0, math.cos(a / 2)]

blob = bytearray()
views, accs = [], []


def add(data, fmt, typ, comp, count, target=None, mm=None):
    while len(blob) % 4:
        blob.append(0)
    off = len(blob)
    blob.extend(struct.pack("<" + fmt * (len(data)), *data))
    v = {"buffer": 0, "byteOffset": off, "byteLength": len(blob) - off}
    if target:
        v["target"] = target
    views.append(v)
    a = {"bufferView": len(views) - 1, "componentType": comp, "count": count, "type": typ}
    if mm:
        a["min"], a["max"] = mm
    accs.append(a)
    return len(accs) - 1


flat = lambda rows: [x for r in rows for x in r]
p_acc = add(flat(pos), "f", "VEC3", 5126, len(pos), 34962,
            ([min(p[i] for p in pos) for i in range(3)], [max(p[i] for p in pos) for i in range(3)]))
n_acc = add(flat(nrm), "f", "VEC3", 5126, len(nrm), 34962)
j_acc = add(flat(joints), "H", "VEC4", 5123, len(joints), 34962)
w_acc = add(flat(weights), "f", "VEC4", 5126, len(weights), 34962)
i_acc = add(idx, "H", "SCALAR", 5123, len(idx), 34963)
ib_acc = add([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1] * 2, "f", "MAT4", 5126, 2)
t_acc = add(times, "f", "SCALAR", 5126, KEYS, None, ([0.0], [1.0]))
r_acc = add(rots, "f", "VEC4", 5126, KEYS)

doc = {
    "asset": {"version": "2.0", "generator": "make_baked_fixture.py"},
    "scene": 0, "scenes": [{"nodes": [0]}],
    "nodes": [{"name": "Root", "children": [1, 2]}, {"name": "Box", "mesh": 0, "skin": 0},
              {"name": "Base", "children": [3]}, {"name": "Spin", "translation": [0, 0.5, 0]}],
    "meshes": [{"primitives": [{"attributes": {"POSITION": p_acc, "NORMAL": n_acc, "JOINTS_0": j_acc,
                                               "WEIGHTS_0": w_acc}, "indices": i_acc, "material": 0}]}],
    "materials": [{"name": "box", "pbrMetallicRoughness": {"baseColorFactor": [0.6, 0.6, 0.6, 1]}}],
    "skins": [{"joints": [2, 3], "inverseBindMatrices": ib_acc}],
    "animations": [{"name": "Spin", "samplers": [{"input": t_acc, "output": r_acc, "interpolation": "LINEAR"}],
                    "channels": [{"sampler": 0, "target": {"node": 3, "path": "rotation"}}]}],
    "buffers": [{"byteLength": 0}], "bufferViews": views, "accessors": accs,
}
# Spin's inverse bind: undo its rest translation (0, 0.5, 0).
ib = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, -0.5, 0, 1]
off = views[accs[ib_acc]["bufferView"]]["byteOffset"]
blob[off:off + 128] = struct.pack("<32f", *ib)
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
