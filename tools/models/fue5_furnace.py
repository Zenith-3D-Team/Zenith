#!/usr/bin/env python3
"""Brings FUE5's electric furnace nearer Factorio's sprite (owner's H15), on the converted .glb.

    python tools/models/fue5_furnace.py

Run after `fue5.py electric-furnace`; a file already done is left alone. Plain Python, no Blender.
It bakes the model's occlusion again at the end (bake_glb.py), for the new shape:

- FUE5's tall chimney and fan cans squashed to the sprite's height (they stood 0.2 tiles over it).
- The grille box at the back east that Factorio's picture has and FUE5's lacks, in FUE5's own atlas.
- Its heater loops were painted glowing orange, working or not: they become an `anim_glow_heater`
  part, dark at rest and lit while the furnace works, and the gold plate behind them goes dark.
- The atlas graded towards Factorio's colours: the loud blue to the sprite's dull steel and the
  front's dark teal, the rust cone to weathered steel, bright orange trim to rust.

The result stays under FUE5's licence (CC BY-NC-SA 3.0, fue5/README.md).
"""

import colorsys
import io
import json
import os
import struct

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
PATH = os.path.join(os.path.dirname(os.path.dirname(HERE)), "client", "assets", "models", "fue5", "electric-furnace.glb")
SQUASH_FROM, SQUASH = 0.9, 0.68      # above this height the back west part keeps this share of its height
WINDOW = ((-0.55, 0.05, 0.75), (0.9, 0.95, 1.3))
# The grille box (x, height, south), and where its faces come from in the atlas (u0, v0, u1, v1).
BOX = ((0.56, 0.3, -1.3), (1.42, 0.82, -0.62))
PLATE_UV = (0.012, 0.495, 0.1, 0.56)
GRILLE_UV = (0.245, 0.498, 0.325, 0.525)
HEATER = {"name": "heater", "doubleSided": True, "emissiveFactor": [1.0, 0.25, 0.03],
          "extensions": {"KHR_materials_emissive_strength": {"emissiveStrength": 1.6}},
          "pbrMetallicRoughness": {"baseColorFactor": [0.09, 0.05, 0.035, 1.0], "metallicFactor": 0.4, "roughnessFactor": 0.6}}


def read(path):
    b = open(path, "rb").read()
    n = struct.unpack("<I", b[12:16])[0]
    return json.loads(b[20:20 + n]), b[20 + n + 8:]


def accessor(doc, blob, i):
    a = doc["accessors"][i]
    v = doc["bufferViews"][a["bufferView"]]
    k = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[a["type"]]
    dt = {5126: np.float32, 5125: np.uint32, 5123: np.uint16}[a["componentType"]]
    return np.frombuffer(blob, dt, a["count"] * k, v.get("byteOffset", 0) + a.get("byteOffset", 0)).reshape(-1, k)


def components(pos, tris):
    """A label per triangle: which welded piece of the mesh it belongs to."""
    _, vid = np.unique(np.round(pos / 1e-4).astype(np.int64), axis=0, return_inverse=True)
    vid = vid.reshape(-1)
    parent = list(range(vid.max() + 1))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    for t in vid[tris]:
        parent[find(t[0])] = find(t[1])
        parent[find(t[0])] = find(t[2])
    return np.array([find(vid[t[0]]) for t in tris])


def squash(y):
    return np.where(y > SQUASH_FROM, SQUASH_FROM + (y - SQUASH_FROM) * SQUASH, y)


def mean_colour(atlas, uv):
    px = np.clip((uv * (atlas.shape[0] - 1)).astype(int), 0, atlas.shape[0] - 1)
    return atlas[px[:, 1], px[:, 0]].mean(axis=0) / 255.0


def uv_mask(size, uv, tris):
    """Where these triangles lie on the atlas, grown a little over their seams."""
    img = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(img)
    for t in tris:
        draw.polygon([tuple(p) for p in (uv[t] * size).tolist()], fill=255, outline=255)
    return np.asarray(img) > 0


def grade(atlas, rusty, window, front):
    """The atlas in HSV, re-coloured by hue; `rusty`, `window` and `front` mask parts done apart."""
    rgb = atlas / 255.0
    hsv = np.stack(np.vectorize(colorsys.rgb_to_hsv, otypes=[float, float, float])(rgb[..., 0], rgb[..., 1], rgb[..., 2]),
                   axis=-1)
    h, s, v = hsv[..., 0], hsv[..., 1], hsv[..., 2]
    blue = (h > 0.5) & (h < 0.75) & (s > 0.08)
    # The sprite's blue is a dull steel (the tank's wrap, the capacitors), its front a dark teal.
    h = np.where(blue, np.where(front, 0.46, 0.58), h)
    s = np.where(blue, s * np.where(front, 0.75, 0.5), s)
    v = np.where(blue, v * np.where(front, 0.62, 0.82), v)
    orange = (h > 0.05) & (h < 0.14) & (s > 0.7) & (v > 0.6)
    s = np.where(orange, s * 0.75, s)
    v = np.where(orange, v * 0.55, v)
    s = np.where(rusty, s * 0.45, s)
    v = np.where(rusty, v * 0.72, v)
    v = np.where(window, v * 0.18, v)
    out = np.stack(np.vectorize(colorsys.hsv_to_rgb, otypes=[float, float, float])(h, s, v), axis=-1)
    return (np.clip(out, 0, 1) * 255).astype(np.uint8)


def box_mesh():
    """The grille box: six quads with flat normals; a grille on the east end, plates elsewhere."""
    (x0, y0, z0), (x1, y1, z1) = BOX
    faces = [  # corners counter-clockwise seen from outside, normal, atlas patch
        ([(x0, y1, z1), (x1, y1, z1), (x1, y1, z0), (x0, y1, z0)], (0, 1, 0), PLATE_UV),
        ([(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)], (0, 0, 1), PLATE_UV),
        ([(x1, y0, z1), (x1, y0, z0), (x1, y1, z0), (x1, y1, z1)], (1, 0, 0), GRILLE_UV),
        ([(x0, y0, z0), (x0, y0, z1), (x0, y1, z1), (x0, y1, z0)], (-1, 0, 0), PLATE_UV),
        ([(x1, y0, z0), (x0, y0, z0), (x0, y1, z0), (x1, y1, z0)], (0, 0, -1), PLATE_UV),
    ]
    pos, nrm, uv, tris = [], [], [], []
    for corners, n, (u0, v0, u1, v1) in faces:
        k = len(pos)
        pos += corners
        nrm += [n] * 4
        uv += [(u0, v1), (u1, v1), (u1, v0), (u0, v0)]
        tris += [(k, k + 1, k + 2), (k, k + 2, k + 3)]
    return np.array(pos, float), np.array(nrm, float), np.array(uv, float), np.array(tris)


def write(path, doc, meshes, image):
    blob, views, accessors = bytearray(), [], []

    def add(data, kind, component, target=None):
        data = np.ascontiguousarray(data)
        while len(blob) % 4:
            blob.append(0)
        view = {"buffer": 0, "byteOffset": len(blob), "byteLength": data.nbytes}
        if target:
            view["target"] = target
        views.append(view)
        blob.extend(data.tobytes())
        acc = {"bufferView": len(views) - 1, "componentType": component, "count": len(data), "type": kind}
        if kind == "VEC3":
            acc["min"], acc["max"] = data.min(axis=0).tolist(), data.max(axis=0).tolist()
        accessors.append(acc)
        return len(accessors) - 1

    out_meshes = []
    for name, pos, nrm, uv, tris, material in meshes:
        attrs = {"POSITION": add(pos.astype(np.float32), "VEC3", 5126, 34962),
                 "NORMAL": add(nrm.astype(np.float32), "VEC3", 5126, 34962),
                 "TEXCOORD_0": add(uv.astype(np.float32), "VEC2", 5126, 34962)}
        out_meshes.append({"name": name, "primitives": [{"attributes": attrs, "material": material, "mode": 4,
                                                          "indices": add(tris.astype(np.uint32).reshape(-1), "SCALAR", 5125, 34963)}]})
    while len(blob) % 4:
        blob.append(0)
    views.append({"buffer": 0, "byteOffset": len(blob), "byteLength": len(image)})
    doc["images"][0]["bufferView"] = len(views) - 1
    blob.extend(image)
    while len(blob) % 4:
        blob.append(0)
    doc.update(meshes=out_meshes, accessors=accessors, bufferViews=views, buffers=[{"byteLength": len(blob)}])
    text = json.dumps(doc, separators=(",", ":")).encode()
    text += b" " * ((4 - len(text) % 4) % 4)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, 28 + len(text) + len(blob)))
        f.write(struct.pack("<II", len(text), 0x4E4F534A) + text)
        f.write(struct.pack("<II", len(blob), 0x004E4942) + bytes(blob))


def main():
    doc, blob = read(PATH)
    if doc["asset"].get("extras", {}).get("zenith_refit"):
        print("already refitted")
        return
    view = doc["bufferViews"][doc["images"][0]["bufferView"]]
    start = view.get("byteOffset", 0)
    atlas = np.asarray(Image.open(io.BytesIO(blob[start:start + view["byteLength"]])).convert("RGB")).astype(np.float64)
    meshes = {}
    for node in doc["nodes"]:
        prim = doc["meshes"][node["mesh"]]["primitives"][0]
        meshes[node["name"]] = [accessor(doc, blob, prim["attributes"][k]).astype(np.float64)
                                for k in ("POSITION", "NORMAL", "TEXCOORD_0")] + [
            accessor(doc, blob, prim["indices"]).reshape(-1, 3).astype(np.int64)]
    pos, nrm, uv, tris = meshes["body"]
    pos = pos.copy()

    # Sort the body's pieces: heater loops, the plate behind them, the chimney.
    label = components(pos, tris)
    heater, window, rusty, front = [], [], [], []
    moved = np.zeros(len(pos), bool)
    for k in np.unique(label):
        sel = tris[label == k]
        corners = pos[sel.reshape(-1)]
        lo, hi, mid = corners.min(axis=0), corners.max(axis=0), corners.mean(axis=0)
        r, g, b = mean_colour(atlas, uv[sel.reshape(-1)])
        in_window = all(WINDOW[0][a] <= lo[a] and hi[a] <= WINDOW[1][a] for a in range(3))
        if in_window and r > 0.75 and b < 0.35:
            heater.append(sel)
            continue
        if in_window and r > g * 1.15 > b * 1.15:
            window.append(sel)
        if mid[2] > 0.75:
            front.append(sel)
        if mid[0] < 0.25 and mid[2] < 0.5:
            moved[sel.reshape(-1)] = True
            if hi[1] > 1.2 and r > b * 1.15:
                rusty.append(sel)
    pos[moved, 1] = squash(pos[moved, 1])
    size = atlas.shape[0]
    empty = np.zeros((0, 3), np.int64)
    rusty_mask = uv_mask(size, uv, np.concatenate(rusty) if rusty else empty)
    window_mask = uv_mask(size, uv, np.concatenate(window) if window else empty)
    front_mask = uv_mask(size, uv, np.concatenate(front) if front else empty)
    graded = grade(atlas, rusty_mask, window_mask, front_mask)
    buf = io.BytesIO()
    Image.fromarray(graded).save(buf, "JPEG", quality=92)

    heater_t = np.concatenate(heater)
    body_t = tris[~np.isin(np.arange(len(tris)), np.nonzero(np.isin(label, np.unique(label[np.isin(tris, np.unique(heater_t)).all(axis=1)])))[0])]
    bpos, bnrm, buv, btri = box_mesh()
    body = ("body", np.concatenate([pos, bpos]), np.concatenate([nrm, bnrm]), np.concatenate([uv, buv]),
            np.concatenate([body_t, btri + len(pos)]), 0)
    used = np.unique(heater_t)
    remap = -np.ones(len(pos), np.int64)
    remap[used] = np.arange(len(used))
    glow = ("anim_glow_heater", pos[used], nrm[used], uv[used], remap[heater_t], 1)
    doc["materials"].append(HEATER)
    doc.setdefault("extensionsUsed", []).append("KHR_materials_emissive_strength")
    doc["asset"]["extras"] = {"zenith_refit": 1}
    parts = []
    for i, node in enumerate(doc["nodes"]):
        if node["name"] == "body":
            parts.append(body)
            continue
        p, n, u, t = meshes[node["name"]]
        node["translation"][1] = float(squash(np.array(node["translation"][1])))
        parts.append((node["name"], p, n, u, t, 0))
    doc["nodes"].append({"name": "anim_glow_heater", "mesh": len(parts)})
    parts.append(glow)
    doc["scenes"][0]["nodes"].append(len(doc["nodes"]) - 1)
    for i, node in enumerate(doc["nodes"]):
        node["mesh"] = i
    write(PATH, doc, parts, buf.getvalue())
    print("refitted: %d heater loops, %d plate pieces, %d chimney pieces" % (len(heater), len(window), len(rusty)))
    # Its occlusion again, for the refitted shape (the parts rewritten above lost fue5.py's).
    import sys
    sys.path.insert(0, HERE)
    import bake_glb
    bake_glb.bake_file(PATH)


if __name__ == "__main__":
    main()
