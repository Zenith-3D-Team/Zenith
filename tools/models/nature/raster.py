#!/usr/bin/env python3
"""Nature models drawn from Factorio's camera in plain Python (no Blender, no window), beside
Factorio's own sprite, to judge shape, size and colour.

    python tools/models/nature/raster.py OUT.png NAME[@REF][:LEAVES] [...] [--zoom 1] [--scale 1]
        [--tilt DEG] [--tint K] [--shadows off] [--grain off]

NAME is one of our models (tools/models/packs.py), or a path to a .glb. REF picks the sprite: a
variation letter for tree-01..09 (default a), a picture number for rocks (default 1). LEAVES is how leaf
cards are cut: `proc` (the shader's procedural leaves, the default) or `atlas` (patches of the
tree's own leaves sprite, as nature_looks.gd builds them in the client). Each NAME gets a row:
the sprite, then the model, at 64 px a tile times --zoom. --scale and --tilt draw the model as a
variation would be placed (chunk_view.gd): scaled, or tipped over by that many degrees like a
fallen tree; a variation's letter as REF (tree-01@k) places the model as the client places that
variation instead. --tint multiplies the leaves by a colour from the prototype's `colors` list
relative to their mean (an index, as the client picks one per tree). With `atlas` leaves the bark
and rock take their grain too (--grain off: not); --shadows off leaves out the shadow map.

It is the client's material reduced to what shows from Factorio's view: albedo times the baked
vertex colour and occlusion (COLOR_0), the part colours (TEXCOORD_4/5) where the model has them,
lit by Factorio's painted light (part_colors.py's LIGHT and AMBIENT) instead of Godot's sun, no
shadows or weathering. Leaf cards are lit by the crown normal they carry, both sides. Good for
shape and colour against the sprite; the client's own look (SSAO, shadows, the sun) needs a
screenshot.

The sprites are read from the player's Factorio install and drawn only into OUT, which belongs in
the git-ignored art-src/: never commit it. Needs numpy and pillow (the repo's .venv).
"""

import json
import math
import os
import re
import struct
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, HERE)
sys.path.append(os.path.dirname(HERE))  # tools/models, after nature/ (both have a score.py)
import packs  # noqa: E402
import tree_sprites  # noqa: E402

SIN, COS = math.sin(math.radians(48.0)), math.cos(math.radians(48.0))
LIGHT = np.array([-0.604, 0.766, 0.22])
LIGHT = LIGHT / np.linalg.norm(LIGHT)
AMBIENT = 0.625
PART_RANGE = 4.0
PART_SHARE = 0.5
BACKGROUND = np.array([0.30, 0.31, 0.21])
SS = 2  # supersampling


def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


# --- glTF ---------------------------------------------------------------------------------------

def _accessor(doc, blob, i):
    a = doc["accessors"][i]
    bv = doc["bufferViews"][a["bufferView"]]
    comp = {5126: np.float32, 5123: np.uint16, 5125: np.uint32, 5121: np.uint8, 5122: np.int16, 5120: np.int8}[a["componentType"]]
    n = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[a["type"]]
    start = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    size = np.dtype(comp).itemsize
    stride = bv.get("byteStride", 0) or n * size
    raw = np.frombuffer(blob, dtype=np.uint8, count=stride * (a["count"] - 1) + n * size, offset=start)
    rows = np.lib.stride_tricks.as_strided(raw, shape=(a["count"], n * size), strides=(stride, 1)).copy()
    out = rows.view(comp).reshape(a["count"], n).astype(np.float64)
    if a.get("normalized"):
        out /= float(np.iinfo(comp).max)
    return out


def _node_matrix(node):
    if "matrix" in node:
        return np.array(node["matrix"], dtype=np.float64).reshape(4, 4).T
    t = np.array(node.get("translation", [0, 0, 0]), dtype=np.float64)
    x, y, z, w = node.get("rotation", [0, 0, 0, 1])
    r = np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                  [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                  [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])
    s = np.array(node.get("scale", [1, 1, 1]), dtype=np.float64)
    m = np.eye(4)
    m[:3, :3] = r * s
    m[:3, 3] = t
    return m


class Model:
    """Triangles of a .glb, flattened: corners (T, 3, ...) of position, normal, colour, uv, seed,
    part colour, and per triangle its material's name and base colour."""

    def __init__(self, path):
        data = open(path, "rb").read()
        n = struct.unpack_from("<I", data, 12)[0]
        doc = json.loads(data[20:20 + n])
        blob = data[20 + n + 8:]
        mats = doc.get("materials", [])
        lists = {k: [] for k in ("p", "n", "c", "uv", "seed", "part", "mat")}
        self.names = [m.get("name", "") for m in mats]
        self.base = [np.array(m.get("pbrMetallicRoughness", {}).get("baseColorFactor", [1, 1, 1, 1])[:3]) for m in mats]

        def walk(i, parent):
            node = doc["nodes"][i]
            m = parent @ _node_matrix(node)
            if "mesh" in node:
                for prim in doc["meshes"][node["mesh"]]["primitives"]:
                    at = prim["attributes"]
                    pos = _accessor(doc, blob, at["POSITION"])
                    cnt = len(pos)
                    pos = (np.c_[pos, np.ones(cnt)] @ m.T)[:, :3]
                    nor = _accessor(doc, blob, at["NORMAL"]) @ np.linalg.inv(m[:3, :3])  # (inverse transpose, row form)
                    nor /= np.maximum(np.linalg.norm(nor, axis=1, keepdims=True), 1e-9)
                    col = _accessor(doc, blob, at["COLOR_0"]) if "COLOR_0" in at else np.ones((cnt, 4))
                    if col.shape[1] == 3:
                        col = np.c_[col, np.ones(cnt)]
                    uv = _accessor(doc, blob, at["TEXCOORD_0"]) if "TEXCOORD_0" in at else np.zeros((cnt, 2))
                    uv2 = _accessor(doc, blob, at["TEXCOORD_1"]) if "TEXCOORD_1" in at else np.full((cnt, 2), 0.5)
                    if "TEXCOORD_4" in at and "TEXCOORD_5" in at:
                        t4, t5 = _accessor(doc, blob, at["TEXCOORD_4"]), _accessor(doc, blob, at["TEXCOORD_5"])
                        part = np.c_[t4, t5]
                    else:
                        part = np.zeros((cnt, 4))
                    idx = _accessor(doc, blob, prim["indices"]).astype(np.int64).ravel() if "indices" in prim else np.arange(cnt)
                    tri = idx.reshape(-1, 3)
                    lists["p"].append(pos[tri])
                    lists["n"].append(nor[tri])
                    lists["c"].append(col[tri])
                    lists["uv"].append(uv[tri])
                    lists["seed"].append(uv2[tri][:, :, 1])
                    lists["part"].append(part[tri])
                    lists["mat"].append(np.full(len(tri), prim.get("material", -1)))
            for c in node.get("children", []):
                walk(c, m)

        scene = doc["scenes"][doc.get("scene", 0)]
        for i in scene["nodes"]:
            walk(i, np.eye(4))
        for k in lists:
            setattr(self, k, np.concatenate(lists[k]))

    def kind(self, t):
        name = self.names[self.mat[t]] if self.mat[t] >= 0 else ""
        return "card" if name.startswith("leafcard") else ("core" if name.startswith("leaf-shadow") else "solid")


# --- leaves ------------------------------------------------------------------------------------

def _fract(x):
    return x - np.floor(x)


def hash12(p):
    """The shader's hash12 (Dave Hoskins' hash without sine), for (..., 2) arrays."""
    p3 = _fract(np.stack([p[..., 0], p[..., 1], p[..., 0]], -1) * 0.1031)
    d = (p3 * (np.stack([p3[..., 1], p3[..., 2], p3[..., 0]], -1) + 33.33)).sum(-1, keepdims=True)
    p3 = p3 + d
    return _fract((p3[..., 0] + p3[..., 1]) * p3[..., 2])


def leaf_cut_proc(uv, seed):
    """factorio_material.gdshaderinc leaf_cut, close up (no far disk): (keep, shade) per pixel."""
    cells = 5.0
    g = uv * cells
    cell = np.floor(g)
    off = np.stack([seed * 61.0, seed * 37.0], -1)
    cover = np.zeros(uv.shape[:-1])
    shade = np.ones(uv.shape[:-1])
    for j in (-1, 0, 1):
        for i in (-1, 0, 1):
            c = cell + np.array([i, j], dtype=np.float64)
            h1 = hash12(c + off)
            h2 = hash12(c + off + 17.31)
            h3 = hash12(c + off + 41.7)
            centre = c + 0.15 + 0.7 * np.stack([h1, h2], -1)
            at = centre / cells * 2.0 - 1.0
            ok = (at * at).sum(-1) <= 0.72 + 0.2 * h3
            a = h3 * 6.2831853
            d = g - centre
            dx = d[..., 0] * np.cos(a) + d[..., 1] * np.sin(a)
            dy = -d[..., 0] * np.sin(a) + d[..., 1] * np.cos(a)
            ln = 0.6 + 0.25 * h1
            wid = (0.26 + 0.1 * h2) * np.maximum(0.0, 1.0 - np.abs(dx) / ln)
            v = 1.0 - dx * dx / (ln * ln) - dy * dy / np.maximum(wid * wid, 1e-4)
            better = ok & (v > cover)
            cover = np.where(better, v, cover)
            shade = np.where(better, 0.72 + 0.5 * hash12(c + off + 5.3), shade)
    keep = cover > 0.0
    return keep, shade * (0.7 + 0.3 * np.sqrt(np.clip(cover, 0.0, 1.0)))


class Atlas:
    """nature_looks.gd's leaf atlas, built the same way (tree_sprites.leaf_atlas)."""

    def __init__(self, name):
        self.rgba, self.cells = tree_sprites.leaf_atlas(tree_sprites.tree_type(name))
        self.size = self.rgba.shape[0] // self.cells

    def cut(self, uv, seed, detail=0.8):
        """leaf_atlas_cut close up: (keep, colour factor) per pixel."""
        n = self.cells
        k = np.floor(_fract(seed * 7.137) * n * n).astype(int)
        turn = np.floor(_fract(seed * 3.71) * 4.0)
        tx, ty = uv[..., 0] - 0.5, uv[..., 1] - 0.5
        rx = np.where(turn < 0.5, tx, np.where(turn < 1.5, ty, np.where(turn < 2.5, -tx, -ty)))
        ry = np.where(turn < 0.5, ty, np.where(turn < 1.5, -tx, np.where(turn < 2.5, -ty, tx)))
        u = np.clip(rx + 0.5, 0.0, 0.999)
        v = np.clip(ry + 0.5, 0.0, 0.999)
        px = ((k % n + u) * self.size).astype(int)
        py = ((k // n + v) * self.size).astype(int)
        s = self.rgba[py, px]
        factor = 0.85 * (1.0 + (s[..., :3] * 2.0 - 1.0) * detail)
        return s[..., 3] >= 0.5, factor


# --- drawing -----------------------------------------------------------------------------------

def place(model, scale, tilt, squash=1.0, back=0.0):
    """The model as chunk_view.gd (TreeLooks.basis) places a variation, turned to lie east: scaled
    (x, y, z), tipped `tilt` degrees over towards +x, squashed `squash` in height, its root end
    `back` tiles west of the entity."""
    p = model.p * np.array([scale[0], scale[1], scale[0]])
    n = model.n / np.array([scale[0], scale[1], scale[0]])
    if tilt:
        a = math.radians(-tilt)
        c, s = math.cos(a), math.sin(a)
        r = np.array([[c, -s, 0.0], [s, c, 0.0], [0.0, 0.0, 1.0]])
        p = p @ r.T
        n = n @ r.T
    p = p * np.array([1.0, squash, 1.0]) - np.array([back, 0.0, 0.0])
    n = n / np.array([1.0, squash, 1.0])
    n /= np.maximum(np.linalg.norm(n, axis=-1, keepdims=True), 1e-9)
    return p, n


def _raster(model, px, py, depth, w, h, leaves, atlas, shadow=False):
    """The frontmost triangle per pixel and its barycentrics: (ids (h, w), bary (h, w, 3)).
    Leaf cards are cut as the shader cuts them (in the shadow pass: their round spray)."""
    zbuf = np.full((h, w), -1e9)
    ids = np.full((h, w), -1, dtype=np.int64)
    bary = np.zeros((h, w, 3))
    e1x, e1y = px[:, 1] - px[:, 0], py[:, 1] - py[:, 0]
    e2x, e2y = px[:, 2] - px[:, 0], py[:, 2] - py[:, 0]
    area = e1x * e2y - e1y * e2x
    for t in np.nonzero(np.abs(area) > 1e-9)[0]:
        x0, x1 = max(int(math.floor(px[t].min())), 0), min(int(math.ceil(px[t].max())), w - 1)
        y0, y1 = max(int(math.floor(py[t].min())), 0), min(int(math.ceil(py[t].max())), h - 1)
        if x1 < x0 or y1 < y0:
            continue
        gx, gy = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
        dx, dy = gx - px[t, 0], gy - py[t, 0]
        b1 = (dx * e2y[t] - dy * e2x[t]) / area[t]
        b2 = (e1x[t] * dy - e1y[t] * dx) / area[t]
        b0 = 1.0 - b1 - b2
        inside = (b0 >= -1e-6) & (b1 >= -1e-6) & (b2 >= -1e-6)
        if not inside.any():
            continue
        bc = np.stack([b0, b1, b2], -1)
        d = bc @ depth[t]
        if model.kind(t) == "card":
            uv = bc @ model.uv[t]
            seed = np.full(d.shape, model.seed[t].mean())
            if shadow:
                q = uv * 2.0 - 1.0
                off = np.stack([seed * 61.0, seed * 37.0], -1)
                disk = 0.78 + 0.18 * hash12(np.floor(uv * 10.0) + off) - np.sqrt((q * q).sum(-1))
                keep = disk > 0.0
            elif leaves == "atlas" and atlas is not None:
                keep, _ = atlas.cut(uv, seed)
            else:
                keep, _ = leaf_cut_proc(uv, seed)
            inside &= keep
        zb = zbuf[y0:y1 + 1, x0:x1 + 1]
        front = inside & (d > zb)
        if not front.any():
            continue
        zb[front] = d[front]
        ids[y0:y1 + 1, x0:x1 + 1][front] = t
        bary[y0:y1 + 1, x0:x1 + 1][front] = bc[front]
    return ids, bary


def draw(model, ppt, leaves="proc", atlas=None, scale=(1.0, 1.0), tilt=0.0, leaf_tint=None, size=None, squash=1.0,
         back=0.0, shadows=True, grain=None):
    p, nrm = place(model, scale, tilt, squash, back)
    x, y, z = p[..., 0], p[..., 1], p[..., 2]
    sx = x
    sy = y * COS - z * SIN
    depth = y * SIN + z * COS  # towards the camera
    lo_x, hi_x = sx.min() - 0.3, sx.max() + 0.3
    lo_y, hi_y = sy.min() - 0.3, sy.max() + 0.3
    w, h = int((hi_x - lo_x) * ppt) * SS, int((hi_y - lo_y) * ppt) * SS
    ox, oy = -lo_x * ppt * SS, hi_y * ppt * SS
    px = ox + sx * ppt * SS
    py = oy - sy * ppt * SS
    ids, bary = _raster(model, px, py, depth, w, h, leaves, atlas)
    hit = ids >= 0
    t = ids[hit]
    bc = bary[hit]
    pos = np.einsum("nk,nkc->nc", bc, p[t])
    n = np.einsum("nk,nkc->nc", bc, nrm[t])
    n /= np.maximum(np.linalg.norm(n, axis=-1, keepdims=True), 1e-9)
    col = np.einsum("nk,nkc->nc", bc, model.c[t])
    part = np.einsum("nk,nkc->nc", bc, model.part[t])
    uv = np.einsum("nk,nkc->nc", bc, model.uv[t])
    seed = model.seed[t].mean(1)
    kinds = np.array([model.kind(i) for i in range(len(model.mat))])[t]
    mats = model.mat[t]
    alb = np.array([model.base[m] if m >= 0 else np.ones(3) for m in range(len(model.base))] + [np.ones(3)])[np.where(mats >= 0, mats, -1)]
    share = part[:, 3]
    headroom = share <= PART_SHARE + 1e-4
    pc = np.clip(np.where(headroom, share / PART_SHARE, share), 0.0, 1.0)
    prgb = part[:, :3] * np.where(headroom, PART_RANGE, 1.0)[:, None]
    c = (alb * (1.0 - pc[:, None]) + prgb * pc[:, None]) * col[:, :3]
    cards = kinds == "card"
    if cards.any():
        if leaves == "atlas" and atlas is not None:
            _, f = atlas.cut(uv[cards], seed[cards])
            c[cards] *= f
        else:
            _, sh = leaf_cut_proc(uv[cards], seed[cards])
            c[cards] *= sh[:, None]
    if leaf_tint is not None:
        leafy = cards | (kinds == "core")
        c[leafy] *= np.asarray(leaf_tint)
    if grain:
        # The grain from the bark's or rock's own picture, from three sides (nature_detail).
        for mi, name in enumerate(model.names):
            g = grain.get(name)
            if g is None:
                continue
            sel = mats == mi
            layer, strength = g
            ww = n[sel] ** 4
            ww /= np.maximum(ww.sum(1, keepdims=True), 1e-9)
            q = pos[sel]
            planes = (np.c_[q[:, 2], -q[:, 1]], np.c_[q[:, 0], q[:, 2]], np.c_[q[:, 0], -q[:, 1]])
            acc = np.zeros((sel.sum(), 3))
            for k, uvp in enumerate(planes):
                m = 1.0 - np.abs(_fract(uvp * 0.5) * 2.0 - 1.0)
                tx = np.clip((m * layer.shape[0]).astype(int), 0, layer.shape[0] - 1)
                acc += ww[:, k:k + 1] * layer[tx[:, 1], tx[:, 0]]
            c[sel] *= 1.0 + (acc * 2.0 - 1.0) * strength
    lit = np.ones(len(t))
    if shadows:
        # A shadow map from the light: orthographic along LIGHT, the leaf cards' sprays cut out.
        fwd = LIGHT
        u = np.cross(np.array([0.0, 1.0, 0.0]), fwd)
        u /= np.linalg.norm(u)
        v = np.cross(fwd, u)
        lp = p.reshape(-1, 3)
        lx, ly, ld = lp @ u, lp @ v, lp @ fwd
        res = ppt * SS
        sx0, sy0 = lx.min() - 0.2, ly.max() + 0.2
        sw, sh_ = int((lx.max() - sx0 + 0.2) * res) + 1, int((sy0 - ly.min() + 0.2) * res) + 1
        spx = ((lx - sx0) * res).reshape(-1, 3)
        spy = ((sy0 - ly) * res).reshape(-1, 3)
        sids, sbary = _raster(model, spx, spy, ld.reshape(-1, 3), sw, sh_, leaves, atlas, shadow=True)
        sdepth = np.where(sids >= 0, np.einsum("hwk,hwk->hw", sbary, ld.reshape(-1, 3)[np.maximum(sids, 0)]), -1e9)
        qx = np.clip(((pos @ u - sx0) * res).astype(int), 0, sw - 1)
        qy = np.clip(((sy0 - pos @ v) * res).astype(int), 0, sh_ - 1)
        occluder = sdepth[qy, qx]
        lit = np.where(pos @ fwd < occluder - 0.06, 0.0, 1.0)
    ao = col[:, 3]
    ndl = np.clip(n @ LIGHT, 0.0, None)
    light = AMBIENT * (0.4 + 0.6 * ao) + (1.0 - AMBIENT) * 1.6 * ndl * lit
    rgb = np.zeros((h, w, 3))
    rgb[hit] = c * light[:, None]
    out = np.where(hit[..., None], linear_to_srgb(rgb), BACKGROUND)
    alpha = hit.astype(np.float64)
    out = out.reshape(h // SS, SS, w // SS, SS, 3).mean((1, 3))
    alpha = alpha.reshape(h // SS, SS, w // SS, SS).mean((1, 3))
    return out, alpha, (ox / SS, oy / SS)


def main(argv):
    args, opts = [], {"zoom": 1.0, "scale": "1", "tilt": 0.0, "tint": None}
    it = iter(argv)
    for a in it:
        if a.startswith("--"):
            opts[a[2:]] = next(it)
        else:
            args.append(a)
    out_path, specs = args[0], args[1:]
    ppt = 64.0 * float(opts["zoom"])
    sc = [float(v) for v in str(opts["scale"]).split(",")]
    scale = (sc[0], sc[-1])
    rows = []
    for spec in specs:
        leaves = "proc"
        if re.search(r":(proc|atlas)$", spec):
            spec, leaves = spec.rsplit(":", 1)
        name, _, ref = spec.partition("@")
        path = name if name.endswith(".glb") else packs.model_path(name)
        model_name = os.path.basename(path)[:-4]
        model = Model(path)
        atlas = Atlas(model_name) if leaves == "atlas" and tree_sprites.tree_type(model_name) else None
        tint = None
        if opts["tint"] is not None:
            tint = np.array(tree_sprites.relative_tints(tree_sprites.tree_type(model_name), model_name)[int(opts["tint"])])
        sprite = tree_sprites.reference(model_name, ref or None, ppt)
        sc, tilt, squash, back = scale, float(opts["tilt"]), 1.0, 0.0
        if ref and len(ref) == 1 and tree_sprites.tree_type(model_name):
            # A variation's letter: placed as the client places that variation (nature_looks.json).
            looks = json.load(open(os.path.join(REPO, "client", "data", "nature_looks.json")))
            shape = looks["trees"][model_name if model_name in looks["trees"] else "tree-" + tree_sprites.tree_type(model_name)]["shapes"][ord(ref) - 97]
            sc, tilt, squash, back = (shape[0], shape[1]), shape[2], shape[3], shape[4]
        grain = None
        if opts.get("grain", "on") != "off" and leaves == "atlas":
            looks = json.load(open(os.path.join(REPO, "client", "data", "nature_looks.json")))
            g = looks.get("grain", {})
            grain = {}
            for mat, (layer, strength) in g.get("materials", {}).items():
                spec_ = g["layers"][layer]
                grain[mat] = (tree_sprites.detail_layer(spec_["file"], spec_["rect"]), strength)
        img, alpha, origin = draw(model, ppt, leaves, atlas, sc, tilt, tint, squash=squash, back=back,
                                  shadows=opts.get("shadows", "on") != "off", grain=grain)
        rows.append((spec + ":" + leaves, sprite, img, origin))
    pad = 8
    blocks = []
    for label, sprite, img, origin in rows:
        parts = []
        if sprite:
            s, (sox, soy) = sprite
            parts.append((s[..., :3], s[..., 3], sox, soy))
        parts.append((img, np.ones(img.shape[:2]), origin[0], origin[1]))
        above = max(p[3] for p in parts)
        below = max(p[0].shape[0] - p[3] for p in parts)
        width = sum(p[0].shape[1] for p in parts) + pad * (len(parts) + 1)
        block = np.tile(BACKGROUND, (int(above + below) + 2 * pad, width, 1))
        x = pad
        for rgb, a, ox, oy in parts:
            top = int(round(pad + above - oy))
            region = block[top:top + rgb.shape[0], x:x + rgb.shape[1]]
            a = a[:region.shape[0], :region.shape[1], None]
            region[:] = rgb[:region.shape[0], :region.shape[1]] * a + region * (1 - a)
            x += rgb.shape[1] + pad
        blocks.append(block)
    width = max(b.shape[1] for b in blocks)
    canvas = np.tile(BACKGROUND, (sum(b.shape[0] for b in blocks), width, 1))
    y = 0
    for b in blocks:
        canvas[y:y + b.shape[0], :b.shape[1]] = b
        y += b.shape[0]
    Image.fromarray((np.clip(canvas, 0, 1) * 255).astype(np.uint8)).save(out_path)
    print("wrote", out_path)


if __name__ == "__main__":
    main(sys.argv[1:])
