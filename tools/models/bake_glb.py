#!/usr/bin/env python3
"""Bakes ambient occlusion into a textured model's .glb, without Blender: bake.py's occlusion (rays
over the hemisphere through a voxel copy of the model and the ground) written per vertex as COLOR_0
alpha, the layout Zenith's own models carry (client/assets/models/README.md).

    python tools/models/bake_glb.py FILE.glb [FILE.glb...] --out DIR    # baked copies in DIR
    python tools/models/bake_glb.py FILE.glb [FILE.glb...] --in-place   # the files themselves

Textured models (FUE5's, client/assets/models/fue5/; a modeller's in models/) have their own wear
in their pictures but no occlusion: corners, the undersides of pipes and the gaps between parts
were lit as brightly as the tops. The client's model shader (factorio_material.gdshaderinc) darkens
a textured model's colour and direct light by this, and adds none of its own grime with it.

What is written, per primitive:

- COLOR_0  rgb 1 (kept if this script baked the file before), a = occlusion (1 open, 0 enclosed),
           as normalised 16-bit integers.
- TEXCOORD_1 (0, 0.5) when the primitive has none: the client keeps a modeller's COLOR_0 only beside
           a second UV map (else it is Blender's own vertex paint, not Zenith's data); (0, 0.5) is
           "no worn edge, the middle part value", which looks the same as no data.
- asset.extras.zenith_bake = BAKE_VERSION, so a file says it was baked.

Every mesh node of the scene counts, moving parts (`anim_*`) at rest, so parts shade one another; a
skinned mesh is posed at its joints' rest transforms, as the client draws it. Deterministic: the same
file bakes to the same numbers. fue5.py runs it on every model it converts (and fue5_furnace.py after
its refit); for a modeller's folder, bake copies to a scratch folder with --out and look at them
before using --in-place on the originals.
"""

import argparse
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import bake  # noqa: E402
from part_colors import Glb, node_matrix  # noqa: E402

BAKE_VERSION = 1


def _world_matrices(doc):
    """Node index -> its world matrix (4x4), for every node reachable from the scene."""
    out = {}

    def visit(i, parent):
        m = parent @ node_matrix(doc["nodes"][i])
        out[i] = m
        for c in doc["nodes"][i].get("children", []):
            visit(c, m)

    scene = doc.get("scenes", [{}])[doc.get("scene", 0)] if doc.get("scenes") else {"nodes": []}
    for root in scene.get("nodes", []):
        visit(root, np.eye(4))
    return out


def _skinned_positions(glb, skin, attrs, pos, world):
    """Vertex positions posed at the skin's joints (rest transforms): sum of weight * joint world *
    inverse bind. Without inverse bind matrices the joints' bind is the identity."""
    joints = skin.get("joints", [])
    if not joints or "JOINTS_0" not in attrs or "WEIGHTS_0" not in attrs:
        return pos
    if "inverseBindMatrices" in skin:
        ibm = glb.accessor(skin["inverseBindMatrices"]).reshape(-1, 4, 4).transpose(0, 2, 1)
    else:
        ibm = np.tile(np.eye(4), (len(joints), 1, 1))
    mats = np.stack([world.get(j, np.eye(4)) @ ibm[k] for k, j in enumerate(joints)])  # (J, 4, 4)
    ji = glb.accessor(attrs["JOINTS_0"]).astype(np.int64)
    w = glb.accessor(attrs["WEIGHTS_0"])
    w = w / np.maximum(w.sum(axis=1, keepdims=True), 1e-12)
    ji = np.clip(ji, 0, len(joints) - 1)
    h = np.concatenate([pos, np.ones((len(pos), 1))], axis=1)
    out = np.zeros((len(pos), 3))
    for k in range(ji.shape[1]):
        m = mats[ji[:, k]]  # (N, 4, 4)
        out += w[:, k:k + 1] * np.einsum("nij,nj->ni", m, h)[:, :3]
    return out


def collect(glb):
    """The model's triangles in model space: (tris (T, 3, 3), normals (T, 3, 3), per primitive
    [(prim dict, vertex count, corner vertex indices (t, 3), slice of the triangles)])."""
    doc = glb.doc
    world = _world_matrices(doc)
    tris, nrms, spans = [], [], []
    t0 = 0
    for i, m in world.items():
        node = doc["nodes"][i]
        if "mesh" not in node:
            continue
        skin = doc["skins"][node["skin"]] if "skin" in node and node["skin"] < len(doc.get("skins", [])) else None
        for prim in doc["meshes"][node["mesh"]]["primitives"]:
            if prim.get("mode", 4) != 4:
                continue
            a = prim["attributes"]
            pos = glb.accessor(a["POSITION"])[:, :3]
            count = len(pos)
            if skin is not None:
                # glTF ignores a skinned mesh's own node transform.
                pos = _skinned_positions(glb, skin, a, pos, world)
                lin = np.eye(3)
            else:
                pos = pos @ m[:3, :3].T + m[:3, 3]
                lin = m[:3, :3]
            idx = glb.accessor(prim["indices"])[:, 0].astype(np.int64).reshape(-1, 3) if "indices" in prim \
                else np.arange(count).reshape(-1, 3)
            t = pos[idx]
            fn = np.cross(t[:, 1] - t[:, 0], t[:, 2] - t[:, 0])
            if "NORMAL" in a:
                vn = glb.accessor(a["NORMAL"])[:, :3] @ np.linalg.inv(lin).T
                n = vn[idx]
            else:
                n = np.repeat(fn[:, None, :], 3, axis=1)
            n = n / np.maximum(np.linalg.norm(n, axis=2, keepdims=True), 1e-12)
            # A corner whose normal is missing or zero takes its face's.
            bad = ~np.isfinite(n).all(axis=2) | (np.linalg.norm(n, axis=2) < 0.5)
            if bad.any():
                f = fn / np.maximum(np.linalg.norm(fn, axis=1, keepdims=True), 1e-12)
                n[bad] = np.repeat(f[:, None, :], 3, axis=1)[bad]
            tris.append(t)
            nrms.append(n)
            spans.append((prim, count, idx, slice(t0, t0 + len(idx))))
            t0 += len(idx)
    if not tris:
        return np.zeros((0, 3, 3)), np.zeros((0, 3, 3)), []
    return np.concatenate(tris), np.concatenate(nrms), spans


def set_color(glb, prim, values):
    """COLOR_0 as VEC4 normalised unsigned shorts: over its old data when the layout matches, else
    appended (re-running doesn't grow the file)."""
    data = np.ascontiguousarray(np.round(np.clip(values, 0.0, 1.0) * 65535.0).astype("<u2"))
    attrs = prim["attributes"]
    if "COLOR_0" in attrs:
        acc = glb.doc["accessors"][attrs["COLOR_0"]]
        if acc["componentType"] == 5123 and acc["type"] == "VEC4" and acc["count"] == len(data) \
                and "bufferView" in acc and acc.get("normalized"):
            view = glb.doc["bufferViews"][acc["bufferView"]]
            if view.get("byteStride", 8) == 8:
                base = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
                glb.bin[base:base + data.nbytes] = data.tobytes()
                return
    while len(glb.bin) % 4:
        glb.bin.append(0)
    views = glb.doc.setdefault("bufferViews", [])
    views.append({"buffer": 0, "byteOffset": len(glb.bin), "byteLength": data.nbytes, "target": 34962})
    glb.bin += data.tobytes()
    accessors = glb.doc.setdefault("accessors", [])
    accessors.append({"bufferView": len(views) - 1, "componentType": 5123, "count": len(data), "type": "VEC4",
                      "normalized": True})
    attrs["COLOR_0"] = len(accessors) - 1


def bake_file(src, dest=None):
    """Bakes `src` into `dest` (src itself when None). Returns (triangles, mean occlusion)."""
    glb = Glb(src)
    if not glb.doc.get("buffers"):
        glb.doc["buffers"] = [{"byteLength": 0}]
    tris, nrms, spans = collect(glb)
    if len(tris) == 0:
        return 0, 1.0
    ao, _edge, _part, _vis = bake.bake(tris, nrms, up=1)
    ours = (glb.doc.get("asset", {}).get("extras") or {}).get("zenith_bake") is not None
    done = {}  # id(prim) -> (sum, hits): a primitive several nodes draw gets the mean of them
    for prim, count, idx, sl in spans:
        s, h = done.setdefault(id(prim), (np.zeros(count), np.zeros(count)))
        for c in range(3):
            np.add.at(s, idx[:, c], ao[sl, c])
            np.add.at(h, idx[:, c], 1.0)
    seen = set()
    total = []
    for prim, count, _idx, _sl in spans:
        if id(prim) in seen:
            continue
        seen.add(id(prim))
        s, h = done[id(prim)]
        occ = np.where(h > 0, s / np.maximum(h, 1.0), 1.0)
        rgb = np.ones((count, 3))
        attrs = prim["attributes"]
        if ours and "COLOR_0" in attrs:
            old = glb.accessor(attrs["COLOR_0"])
            if old.shape[0] == count:
                rgb = old[:, :3]
        set_color(glb, prim, np.concatenate([rgb, occ[:, None]], axis=1))
        if "TEXCOORD_1" not in attrs:
            glb.set_vec2(prim, "TEXCOORD_1", np.tile([0.0, 0.5], (count, 1)))
        total.append(occ)
    asset = glb.doc.setdefault("asset", {"version": "2.0"})
    extras = asset.get("extras") if isinstance(asset.get("extras"), dict) else {}
    extras["zenith_bake"] = BAKE_VERSION
    asset["extras"] = extras
    glb.save(dest or src)
    return len(tris), float(np.concatenate(total).mean()) if total else 1.0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+", help=".glb files (or folders: every .glb in them)")
    where = ap.add_mutually_exclusive_group(required=True)
    where.add_argument("--out", help="write baked copies into this folder")
    where.add_argument("--in-place", action="store_true", help="rewrite the files themselves")
    a = ap.parse_args(argv)
    files = []
    for f in a.files:
        if os.path.isdir(f):
            files += sorted(os.path.join(f, n) for n in os.listdir(f) if n.lower().endswith(".glb"))
        else:
            files.append(f)
    if a.out:
        os.makedirs(a.out, exist_ok=True)
    for f in files:
        dest = f if a.in_place else os.path.join(a.out, os.path.basename(f))
        if not a.in_place and os.path.abspath(dest) == os.path.abspath(f):
            print("%s: --out is the file's own folder; use --in-place" % f)
            return 1
        n, mean = bake_file(f, dest)
        print("%-44s %7d triangles, occlusion mean %.2f -> %s" % (os.path.basename(f), n, mean, dest))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
