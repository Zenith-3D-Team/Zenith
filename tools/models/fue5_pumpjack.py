#!/usr/bin/env python3
"""Puts FUE5's pumpjack's oil outlet where Factorio's pumpjack has its output (owner's L8), and
rigs and animates its walking beam, horsehead, cranks, pitman arms, polished rod, flywheels and
gearbox gear on the converted .glb.

    python tools/models/fue5_pumpjack.py [--force]

Run after `fue5.py pumpjack`; a file already done is left alone unless `--force` is passed.
Plain Python + numpy, no Blender.

Factorio's north-facing pumpjack puts its oil out at the north-east tile, northwards (its
output_fluid_box: positions {1, -1}, {1, 1}, {-1, 1}, {-1, -1} for north, east, south, west, read in
2.1.24). FUE5's model has its outlet (the red box and the flange) at the south-west tile, pointing
west: the mirror image of Factorio's base, so no quarter turn puts it right (each one leaves the
outlet on the right corner pointing the wrong way, or the wrong corner). Mirrored across the
north-west to south-east diagonal (x and z swapped, Godot's x east and z south) it is Factorio's
north layout, and turned with the entity (the client turns this one model to each direction) every
direction's outlet lands on Factorio's: north-east north, south-east east, south-west south,
north-west west. The walking beam then runs north-south facing north and east-west facing east;
Factorio's beam is drawn east-west in every direction, which one turned model can't do either way.

The swap is a reflection: normals are swapped the same way and every triangle's winding reversed, so
faces keep facing out. The occlusion baked per vertex (COLOR_0, bake_glb.py) goes with its vertex.
`animate()` then rigs the transposed mesh with a 7-bone skin and an 81-frame 60 fps looping
animation (1.3333 s, Factorio's 40 frames at 0.5/tick) under a `StretchYZ` parent matching the
conversion's vertical stretch so circular flywheels and shafts rotate without wobble.
The result stays under FUE5's licence (CC BY-NC-SA 3.0, packs/fue5/README.md).
"""

import argparse
from collections import defaultdict, deque
import json
import math
import os
import struct

import numpy as np

import packs

PATH = packs.fue5_path("pumpjack")
MARK = "zenith_transposed"
ANIM_MARK = "zenith_pumpjack_anim"

BONE_NAMES = ["Base", "Beam", "Crank", "Pitman", "PolishedRod", "Flywheel", "InnerGear"]
EXPECTED_ISLANDS = (205, 24, 7, 4, 4, 5, 1)
EXPECTED_TRIS = (7617, 748, 408, 48, 52, 718, 396)
KEYS = 81
DURATION = 4.0 / 3.0  # Factorio: 40 frames / (0.5 * 60 ticks/s) = 4/3 s


def read(path):
    b = open(path, "rb").read()
    n = struct.unpack("<I", b[12:16])[0]
    return json.loads(b[20:20 + n]), bytearray(b[20 + n + 8:])


def write(path, doc, blob):
    js = json.dumps(doc, separators=(",", ":")).encode()
    js += b" " * ((4 - len(js) % 4) % 4)
    blob = bytes(blob)
    blob += b"\0" * ((4 - len(blob) % 4) % 4)
    total = 12 + 8 + len(js) + 8 + len(blob)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total))
        f.write(struct.pack("<II", len(js), 0x4E4F534A) + js)
        f.write(struct.pack("<II", len(blob), 0x004E4942) + blob)


def view(doc, blob, i):
    """The accessor's data as a writable numpy array over the blob, and the accessor."""
    a = doc["accessors"][i]
    v = doc["bufferViews"][a["bufferView"]]
    k = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[a["type"]]
    dt = {5126: np.float32, 5125: np.uint32, 5123: np.uint16, 5121: np.uint8}[a["componentType"]]
    start = v.get("byteOffset", 0) + a.get("byteOffset", 0)
    stride = v.get("byteStride", 0)
    if stride and stride != k * np.dtype(dt).itemsize:
        raise SystemExit("interleaved buffers aren't handled")
    arr = np.frombuffer(blob, dt, a["count"] * k, start).reshape(-1, k)
    return arr, a


def transpose(doc, blob):
    for node in doc.get("nodes", []):
        t = node.get("translation", [0, 0, 0])
        if "rotation" in node or "matrix" in node or "scale" in node or t[0] != t[2]:
            raise SystemExit("a node with its own transform: transpose it too before using this")
    for mesh in doc["meshes"]:
        for prim in mesh["primitives"]:
            attrs = prim["attributes"]
            pos, acc = view(doc, blob, attrs["POSITION"])
            pos[:, [0, 2]] = pos[:, [2, 0]]
            if "min" in acc and "max" in acc:
                acc["min"] = [acc["min"][2], acc["min"][1], acc["min"][0]]
                acc["max"] = [acc["max"][2], acc["max"][1], acc["max"][0]]
            if "NORMAL" in attrs:
                nrm, _ = view(doc, blob, attrs["NORMAL"])
                nrm[:, [0, 2]] = nrm[:, [2, 0]]
            if "TANGENT" in attrs:
                tan, _ = view(doc, blob, attrs["TANGENT"])
                tan[:, [0, 2]] = tan[:, [2, 0]]
                tan[:, 3] = -tan[:, 3]
            if prim.get("mode", 4) != 4 or "indices" not in prim:
                raise SystemExit("only indexed triangle lists are handled")
            idx, _ = view(doc, blob, prim["indices"])
            tri = idx.reshape(-1, 3)
            tri[:, [1, 2]] = tri[:, [2, 1]]


def _append_view(doc, blob, data_bytes, target=None):
    while len(blob) % 4:
        blob.append(0)
    off = len(blob)
    blob.extend(data_bytes)
    bv = {"buffer": 0, "byteOffset": off, "byteLength": len(data_bytes)}
    if target is not None:
        bv["target"] = target
    doc.setdefault("bufferViews", []).append(bv)
    return len(doc["bufferViews"]) - 1


def _add_accessor(doc, blob, arr, comp_type, acc_type, target=None, include_minmax=False):
    raw = np.ascontiguousarray(arr).tobytes()
    bv_idx = _append_view(doc, blob, raw, target=target)
    acc = {
        "bufferView": bv_idx,
        "componentType": comp_type,
        "count": int(len(arr)),
        "type": acc_type,
    }
    if include_minmax:
        if arr.ndim == 1:
            acc["min"] = [float(arr.min())]
            acc["max"] = [float(arr.max())]
        else:
            acc["min"] = [float(x) for x in arr.min(axis=0)]
            acc["max"] = [float(x) for x in arr.max(axis=0)]
    doc.setdefault("accessors", []).append(acc)
    return len(doc["accessors"]) - 1


def strip_animation(doc, blob):
    """Removes prior rigging/animation data and compacts retained mesh + image buffers."""
    doc.pop("skins", None)
    doc.pop("animations", None)
    mesh = doc["meshes"][0]
    prim = mesh["primitives"][0]
    prim["attributes"].pop("JOINTS_0", None)
    prim["attributes"].pop("WEIGHTS_0", None)
    doc["nodes"] = [{"mesh": 0, "name": "body"}]
    doc["scenes"] = [{"name": "Scene", "nodes": [0]}]
    doc["scene"] = 0

    old_accs = doc.get("accessors", [])
    old_bvs = doc.get("bufferViews", [])
    used_accs = sorted(set(prim["attributes"].values()) | {prim["indices"]})
    acc_remap = {}
    new_accs = []
    used_bvs = set()
    for old_ai in used_accs:
        acc_remap[old_ai] = len(new_accs)
        acc = dict(old_accs[old_ai])
        new_accs.append(acc)
        used_bvs.add(acc["bufferView"])
    for k, old_ai in list(prim["attributes"].items()):
        prim["attributes"][k] = acc_remap[old_ai]
    prim["indices"] = acc_remap[prim["indices"]]

    for im in doc.get("images", []):
        if "bufferView" in im:
            used_bvs.add(im["bufferView"])

    new_blob = bytearray()
    bv_remap = {}
    new_bvs = []
    for old_bvi in sorted(used_bvs):
        old_bv = old_bvs[old_bvi]
        off = old_bv.get("byteOffset", 0)
        raw = bytes(blob[off:off + old_bv["byteLength"]])
        while len(new_blob) % 4:
            new_blob.append(0)
        new_off = len(new_blob)
        new_blob.extend(raw)
        bv = dict(old_bv)
        bv["byteOffset"] = new_off
        bv_remap[old_bvi] = len(new_bvs)
        new_bvs.append(bv)

    for acc in new_accs:
        acc["bufferView"] = bv_remap[acc["bufferView"]]
    for im in doc.get("images", []):
        if "bufferView" in im:
            im["bufferView"] = bv_remap[im["bufferView"]]

    doc["accessors"] = new_accs
    doc["bufferViews"] = new_bvs
    doc["buffers"] = [{"byteLength": len(new_blob)}]
    return new_blob


def _islands(pos, idx):
    """Groups connected triangles via 1e-4-welded vertex positions."""
    q = np.round(pos * 10000).astype(np.int64)
    vmap = {}
    vid = np.empty(len(pos), dtype=np.int32)
    for i, pt in enumerate(map(tuple, q)):
        if pt not in vmap:
            vmap[pt] = len(vmap)
        vid[i] = vmap[pt]
    adj = defaultdict(list)
    for a, b, c in vid[idx]:
        adj[a].extend((b, c))
        adj[b].extend((a, c))
        adj[c].extend((a, b))
    v2t = defaultdict(list)
    for ti, (a, b, c) in enumerate(vid[idx]):
        v2t[a].append(ti)
        v2t[b].append(ti)
        v2t[c].append(ti)
    seen = set()
    out = []
    for v0 in range(len(vmap)):
        if v0 in seen:
            continue
        dq = deque([v0])
        seen.add(v0)
        vs = set()
        while dq:
            u = dq.popleft()
            vs.add(u)
            for w in adj[u]:
                if w not in seen:
                    seen.add(w)
                    dq.append(w)
        ts = set()
        for u in vs:
            ts.update(v2t[u])
        if not ts:
            continue
        uverts = np.unique(idx[list(ts)])
        pts = pos[uverts]
        lo, hi = pts.min(0), pts.max(0)
        out.append({
            "tris": len(ts),
            "lo": lo,
            "hi": hi,
            "ctr": (lo + hi) * 0.5,
            "verts": uverts,
            "pts": pts,
        })
    return out


def _classify_island(isl):
    """Maps one welded mesh island to bone index 0..6 by geometric bounds."""
    lo, hi = isl["lo"], isl["hi"]
    # Check PolishedRod before Beam so top clamps / rod aren't claimed by Beam.
    if abs(lo[0]) < 0.04 and abs(hi[0]) < 0.04 and lo[2] < -1.30 and hi[2] < -1.29 and hi[1] > 1.85:
        return 4
    if (hi[0] < 0.21 and lo[0] > -0.21 and lo[1] > 2.10) or (
            lo[1] > 2.13 and hi[1] < 2.18 and lo[2] > 1.03 and hi[2] < 1.065 and abs(lo[0]) < 0.47 and abs(hi[0]) < 0.47):
        return 1
    if lo[2] > 1.02 and hi[2] < 1.075 and hi[1] > 2.05 and hi[1] < 2.16 and (lo[0] > 0.41 or hi[0] < -0.41):
        return 3
    if lo[0] < -0.40 and hi[0] > 0.40 and lo[1] > 0.74 and hi[1] < 0.85 and lo[2] > 1.00 and hi[2] < 1.09:
        return 2
    if ((lo[0] > 0.33 and hi[0] < 0.39) or (lo[0] > -0.39 and hi[0] < -0.33)) \
            and lo[1] > 0.32 and hi[1] < 0.89 and lo[2] > 0.67 and hi[2] < 1.42:
        return 2
    if ((lo[0] > 0.36 and hi[0] < 0.47) or (lo[0] > -0.47 and hi[0] < -0.36)) \
            and lo[1] > 0.51 and hi[1] < 0.80 and lo[2] > 1.02 and hi[2] < 1.075:
        return 2
    if lo[0] > -0.51 and hi[0] < -0.18 and lo[1] > 0.50 and hi[1] < 1.50 and lo[2] > -0.02 and hi[2] < 0.82:
        return 5
    if lo[0] > 0.08 and hi[0] < 0.15 and lo[1] > 0.41 and hi[1] < 0.99 and lo[2] > 0.25 and hi[2] < 0.74:
        return 6
    return 0


def _fit_ellipse_yz(pts):
    """Fits an axis-aligned ellipse in YZ to outer rim vertices: returns (cy, cz, ry/rz)."""
    lo, hi = pts.min(0), pts.max(0)
    cy0, cz0 = (lo[1] + hi[1]) * 0.5, (lo[2] + hi[2]) * 0.5
    ry0, rz0 = max(1e-4, (hi[1] - lo[1]) * 0.5), max(1e-4, (hi[2] - lo[2]) * 0.5)
    d = np.hypot((pts[:, 1] - cy0) / ry0, (pts[:, 2] - cz0) / rz0)
    rim = pts[d > d.max() * 0.96]
    mat = np.column_stack([rim[:, 1] ** 2, rim[:, 1], rim[:, 2], np.ones(len(rim))])
    a, c_lin, d_lin, e = np.linalg.lstsq(mat, -rim[:, 2] ** 2, rcond=None)[0]
    cy = -c_lin / (2.0 * a)
    cz = -d_lin / 2.0
    rhs = a * cy ** 2 + cz ** 2 - e
    rz = math.sqrt(rhs)
    ry = math.sqrt(rhs / a)
    return float(cy), float(cz), float(ry / rz)


def _quat_x(angles):
    half = angles * 0.5
    out = np.zeros((len(angles), 4), dtype=np.float32)
    out[:, 0] = np.sin(half)
    out[:, 3] = np.cos(half)
    return out


def _ibm_stretch(y0, z0, k_yz):
    """Column-major 4x4 inverse bind matrix for a StretchYZ child at local (0, y0, z0)."""
    return np.array([
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0 / k_yz, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, -y0, -z0, 1.0,
    ], dtype=np.float32)


def animate(doc, blob):
    """Rigs pumpjack.glb with a 7-bone skin and 81-frame 4-bar crank-rocker animation."""
    prim = doc["meshes"][0]["primitives"][0]
    pos, _ = view(doc, blob, prim["attributes"]["POSITION"])
    idx, _ = view(doc, blob, prim["indices"])
    idx = idx.reshape(-1, 3)

    islands = _islands(pos, idx)
    by_bone = defaultdict(list)
    vert_bones = defaultdict(set)
    joint_of_vert = np.zeros(len(pos), dtype=np.uint16)
    for isl in islands:
        b = _classify_island(isl)
        by_bone[b].append(isl)
        for v in isl["verts"]:
            vi = int(v)
            vert_bones[vi].add(b)
            joint_of_vert[vi] = b

    counts = tuple(len(by_bone[b]) for b in range(len(BONE_NAMES)))
    tris = tuple(sum(isl["tris"] for isl in by_bone[b]) for b in range(len(BONE_NAMES)))
    if counts != EXPECTED_ISLANDS or tris != EXPECTED_TRIS:
        raise SystemExit(f"pumpjack island classification mismatch: counts={counts}, tris={tris}")
    shared = sum(1 for bs in vert_bones.values() if len(bs) > 1)
    if shared:
        raise SystemExit(f"pumpjack bones share {shared} vertices")

    # Raise the hidden lower tip of the polished rod inside the wellhead stuffing box
    # so it stays above y = 0 throughout the downward stroke.
    for isl in by_bone[4]:
        if isl["hi"][1] > 3.40 and isl["lo"][1] < 0.75:
            low_verts = isl["verts"][pos[isl["verts"], 1] < 0.75]
            pos[low_verts, 1] = 0.78

    # Measure exact vertical stretch k_yz and mechanism pivots from the classified islands.
    fly_big = sorted(by_bone[5], key=lambda x: x["tris"], reverse=True)[0]
    fy, fz, k_yz = _fit_ellipse_yz(fly_big["pts"])
    gy, gz, _ = _fit_ellipse_yz(by_bone[6][0]["pts"])

    saddle = next(
        isl for isl in by_bone[0]
        if isl["lo"][0] < -0.80 and isl["hi"][0] > 0.80 and isl["lo"][1] > 2.40 and isl["hi"][1] < 2.57
    )
    sy, sz = float(saddle["ctr"][1]), float(saddle["ctr"][2])

    eq_bars = [isl for isl in by_bone[1] if isl["lo"][1] > 2.13 and isl["hi"][1] < 2.18 and isl["lo"][2] > 1.03]
    ey0 = float(np.mean([isl["ctr"][1] for isl in eq_bars]))
    ez0 = float(np.mean([isl["ctr"][2] for isl in eq_bars]))

    crank_shaft = max(by_bone[2], key=lambda isl: isl["hi"][0] - isl["lo"][0])
    cy, cz = float(crank_shaft["ctr"][1]), float(crank_shaft["ctr"][2])

    crank_pins = [isl for isl in by_bone[2] if isl["hi"][1] < 0.58 and isl["lo"][1] > 0.50]
    py0 = float(np.mean([isl["ctr"][1] for isl in crank_pins]))
    pz0 = float(np.mean([isl["ctr"][2] for isl in crank_pins]))

    rod_main = max(by_bone[4], key=lambda isl: isl["hi"][1] - isl["lo"][1])
    z_rod = float(rod_main["ctr"][2])
    r_head = sz - z_rod

    # Solve exact 4-bar crank-rocker linkage in unstretched (z, y0 = y / k_yz) space.
    s_pt = np.array([sz, sy / k_yz])
    e0_pt = np.array([ez0, ey0 / k_yz])
    c_pt = np.array([cz, cy / k_yz])
    p0_pt = np.array([pz0, py0 / k_yz])

    r_crank = float(np.linalg.norm(p0_pt - c_pt))
    l_pit = float(np.linalg.norm(e0_pt - p0_pt))
    r_tail = float(np.linalg.norm(e0_pt - s_pt))
    phi0 = math.atan2(p0_pt[1] - c_pt[1], p0_pt[0] - c_pt[0])
    th0 = math.atan2(e0_pt[1] - s_pt[1], e0_pt[0] - s_pt[0])
    alpha0 = math.atan2(e0_pt[1] - p0_pt[1], e0_pt[0] - p0_pt[0])

    times = np.linspace(0.0, DURATION, KEYS, dtype=np.float32)
    phi_rel = np.linspace(0.0, 2.0 * math.pi, KEYS, dtype=np.float64)
    beam_psi = np.zeros(KEYS, dtype=np.float64)
    pit_psi = np.zeros(KEYS, dtype=np.float64)
    pit_trans = np.zeros((KEYS, 3), dtype=np.float32)
    rod_trans = np.zeros((KEYS, 3), dtype=np.float32)

    for k in range(KEYS):
        phi = phi0 + phi_rel[k]
        p_pt = c_pt + r_crank * np.array([math.cos(phi), math.sin(phi)])
        d = float(np.linalg.norm(p_pt - s_pt))
        a = (r_tail ** 2 - l_pit ** 2 + d ** 2) / (2.0 * d)
        h = math.sqrt(max(0.0, r_tail ** 2 - a ** 2))
        mid = s_pt + a * (p_pt - s_pt) / d
        perp = np.array([-(p_pt[1] - s_pt[1]), p_pt[0] - s_pt[0]]) / d
        e_a, e_b = mid + h * perp, mid - h * perp
        e_pt = e_a if e_a[1] > e_b[1] else e_b
        if abs(np.linalg.norm(e_pt - p_pt) - l_pit) > 1e-9 or abs(np.linalg.norm(e_pt - s_pt) - r_tail) > 1e-9:
            raise SystemExit(f"4-bar linkage failed at frame {k}")
        th = math.atan2(e_pt[1] - s_pt[1], e_pt[0] - s_pt[0])
        alpha = math.atan2(e_pt[1] - p_pt[1], e_pt[0] - p_pt[0])
        # +X rotation rotates +Y toward +Z, opposite to atan2(y0, z).
        beam_psi[k] = -(th - th0)
        pit_psi[k] = -(alpha - alpha0)
        pit_trans[k] = [0.0, float(p_pt[1]), float(p_pt[0])]
        rod_trans[k] = [0.0, float(-k_yz * r_head * (th - th0)), 0.0]

    crank_q = _quat_x(-phi_rel)
    beam_q = _quat_x(beam_psi)
    pit_q = _quat_x(pit_psi)
    fly_q = _quat_x(-2.0 * phi_rel)
    gear_q = _quat_x(3.0 * phi_rel)

    n_verts = len(pos)
    del pos, idx
    joints_arr = np.zeros((n_verts, 4), dtype=np.uint16)
    joints_arr[:, 0] = joint_of_vert
    weights_arr = np.zeros((n_verts, 4), dtype=np.float32)
    weights_arr[:, 0] = 1.0

    j_acc = _add_accessor(doc, blob, joints_arr, 5123, "VEC4", target=34962)
    w_acc = _add_accessor(doc, blob, weights_arr, 5126, "VEC4", target=34962)
    prim["attributes"]["JOINTS_0"] = j_acc
    prim["attributes"]["WEIGHTS_0"] = w_acc

    # Order of StretchYZ children: Beam(6), Crank(7), Pitman(8), Flywheel(9), InnerGear(10).
    pivots_yz = [
        (sy, sz),
        (cy, cz),
        (py0, pz0),
        (fy, fz),
        (gy, gz),
    ]
    ibms = np.zeros((7, 16), dtype=np.float32)
    ident = np.array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1], dtype=np.float32)
    ibms[0] = ident
    ibms[4] = ident
    for idx_child, (yp, zp) in enumerate(pivots_yz):
        joint_slot = (1, 2, 3, 5, 6)[idx_child]
        ibms[joint_slot] = _ibm_stretch(yp / k_yz, zp, k_yz)
    ibm_acc = _add_accessor(doc, blob, ibms, 5126, "MAT4")

    t_acc = _add_accessor(doc, blob, times, 5126, "SCALAR", include_minmax=True)
    beam_r_acc = _add_accessor(doc, blob, beam_q, 5126, "VEC4")
    crank_r_acc = _add_accessor(doc, blob, crank_q, 5126, "VEC4")
    pit_t_acc = _add_accessor(doc, blob, pit_trans, 5126, "VEC3")
    pit_r_acc = _add_accessor(doc, blob, pit_q, 5126, "VEC4")
    rod_t_acc = _add_accessor(doc, blob, rod_trans, 5126, "VEC3")
    fly_r_acc = _add_accessor(doc, blob, fly_q, 5126, "VEC4")
    gear_r_acc = _add_accessor(doc, blob, gear_q, 5126, "VEC4")

    doc["nodes"] = [
        {"name": "Root", "children": [1, 2]},
        {"name": "body", "mesh": 0, "skin": 0},
        {"name": "Armature", "children": [3, 4, 5]},
        {"name": "Base"},
        {"name": "PolishedRod"},
        {"name": "StretchYZ", "scale": [1.0, k_yz, 1.0], "children": [6, 7, 8, 9, 10]},
        {"name": "Beam", "translation": [0.0, sy / k_yz, sz]},
        {"name": "Crank", "translation": [0.0, cy / k_yz, cz]},
        {"name": "Pitman", "translation": [0.0, py0 / k_yz, pz0]},
        {"name": "Flywheel", "translation": [0.0, fy / k_yz, fz]},
        {"name": "InnerGear", "translation": [0.0, gy / k_yz, gz]},
    ]
    doc["scenes"] = [{"name": "Scene", "nodes": [0]}]
    doc["scene"] = 0
    doc["skins"] = [{
        "name": "PumpjackRig",
        "joints": [3, 6, 7, 8, 4, 9, 10],
        "inverseBindMatrices": ibm_acc,
    }]
    channel_specs = [
        (6, "rotation", beam_r_acc),
        (7, "rotation", crank_r_acc),
        (8, "translation", pit_t_acc),
        (8, "rotation", pit_r_acc),
        (4, "translation", rod_t_acc),
        (9, "rotation", fly_r_acc),
        (10, "rotation", gear_r_acc),
    ]
    doc["animations"] = [{
        "name": "Pump",
        "samplers": [
            {"input": t_acc, "output": out_acc, "interpolation": "LINEAR"}
            for _, _, out_acc in channel_specs
        ],
        "channels": [
            {"sampler": si, "target": {"node": node_i, "path": path}}
            for si, (node_i, path, _) in enumerate(channel_specs)
        ],
    }]
    while len(blob) % 4:
        blob.append(0)
    doc["buffers"] = [{"byteLength": len(blob)}]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true", help="rebuild rigging/animation even if already present")
    args = ap.parse_args()

    doc, blob = read(PATH)
    extras = doc.setdefault("asset", {}).setdefault("extras", {})
    need_transpose = not extras.get(MARK)
    need_anim = args.force or not extras.get(ANIM_MARK)
    if not need_transpose and not need_anim:
        print("pumpjack.glb: already done")
        return

    msgs = []
    if need_transpose:
        transpose(doc, blob)
        extras[MARK] = 1
        msgs.append("outlet moved to Factorio's (x and z swapped)")
    if need_anim:
        if extras.get(ANIM_MARK) or doc.get("skins") or doc.get("animations"):
            blob = strip_animation(doc, blob)
        animate(doc, blob)
        extras[ANIM_MARK] = 1
        msgs.append("rigged and animated (7 bones, 81 frames)")

    write(PATH, doc, blob)
    print("pumpjack.glb: " + "; ".join(msgs))


if __name__ == "__main__":
    main()
