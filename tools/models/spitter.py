#!/usr/bin/env python3
"""Procedural watertight big-spitter generator for the Placeholders pack.

    python tools/models/spitter.py                   # generate all 6 big-spitter*.glb files
    python tools/models/spitter.py --out DIR         # write into a custom folder
    python tools/models/spitter.py --preview DIR     # render multi-angle & tier preview PNGs

Builds a 100% closed, watertight, manifold Factorio-faithful big-spitter (`0` open edges,
outward-facing normals) and its 5 pose variants (`big-spitter-attack`, `big-spitter-corpse`,
`big-spitter-corpse-1..3`) directly in plain Python + numpy + PIL (no Blender dependency).

Matches the exact materials (`flesh_spitter`, `flesh_leg`, `chitin_spitter`), 12-limb rig
joint/knee layout (`client/data/creature_rigs.json`), pose transforms
(`client/data/creature_poses.json`), and shader attribute encoding (`COLOR_0`, `TEXCOORD_0..5`)
expected by `creature_models.gd`, `creature_skins.json`, `factorio_material.gdshaderinc`,
`addon_creatures.gd`, `model_load_test.gd`, and `tools/models/check.py`.
"""

import argparse
import json
import math
import os
import struct
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

import bake  # noqa: E402

PLACEHOLDERS_DIR = os.path.join(REPO, "client", "assets", "models", "packs", "placeholders")
RIGS_JSON = os.path.join(REPO, "client", "data", "creature_rigs.json")
POSES_JSON = os.path.join(REPO, "client", "data", "creature_poses.json")
SKINS_JSON = os.path.join(REPO, "client", "data", "creature_skins.json")

GENERATOR = "Zenith tools/models/spitter.py"
COPYRIGHT = "Zenith contributors (GPL-3.0)"

# Matches wube_recipes.py / part_colors.py / factorio_material.gdshaderinc.
PART_RANGE = 4.0
PART_SHARE = 0.25

# Exact PBR factors matching wube3dp/big-spitter.glb / wube_recipes.py (sRGB hex -> linear).
MATERIALS = (
    ("flesh_spitter", "6e4a40", 0.70, 0.00),
    ("flesh_leg", "a8705a", 0.70, 0.00),
    ("chitin_spitter", "4a6f86", 0.45, 0.10),
)

POSE_NAMES = (
    "big-spitter-attack",
    "big-spitter-corpse",
    "big-spitter-corpse-1",
    "big-spitter-corpse-2",
    "big-spitter-corpse-3",
)


def srgb_hex_to_linear(hex_colour):
    out = []
    for i in (0, 2, 4):
        c = int(hex_colour[i:i + 2], 16) / 255.0
        out.append(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4)
    return out


def linear_to_srgb(x):
    x = np.clip(x, 0.0, 1.0)
    return np.where(x <= 0.0031308, x * 12.92, 1.055 * (x ** (1.0 / 2.4)) - 0.055)


def smoothstep(edge0, edge1, x):
    t = np.clip((x - edge0) / max(edge1 - edge0, 1e-9), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def rodrigues(pts, axis, angles):
    """Rotate points (N, 3) about unit axis by per-point angles (N,) or scalar."""
    a = np.asarray(axis, dtype=np.float64)
    n = np.linalg.norm(a)
    if n < 1e-12:
        return pts.copy()
    a = a / n
    ang = np.asarray(angles, dtype=np.float64)
    c = np.cos(ang)
    s = np.sin(ang)
    if pts.ndim == 1:
        return pts * c + np.cross(a, pts) * s + a * np.dot(a, pts) * (1.0 - c)
    if c.ndim == 0:
        return pts * c + np.cross(a, pts) * s + np.outer(pts @ a, a) * (1.0 - c)
    return pts * c[:, None] + np.cross(a, pts) * s[:, None] + np.outer(pts @ a, a) * (1.0 - c)[:, None]


def quat_to_matrix(q):
    """glTF / Godot quaternion [x, y, z, w] -> 3x3 rotation matrix."""
    qx, qy, qz, qw = [float(c) for c in q]
    n = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
    if n > 1e-12:
        qx, qy, qz, qw = qx / n, qy / n, qz / n, qw / n
    return np.array([
        [1.0 - 2.0 * (qy * qy + qz * qz), 2.0 * (qx * qy - qz * qw), 2.0 * (qx * qz + qy * qw)],
        [2.0 * (qx * qy + qz * qw), 1.0 - 2.0 * (qx * qx + qz * qz), 2.0 * (qy * qz - qx * qw)],
        [2.0 * (qx * qz - qy * qw), 2.0 * (qy * qz + qx * qw), 1.0 - 2.0 * (qx * qx + qy * qy)],
    ], dtype=np.float64)


# ---------------------------------------------------------------------------------------------
# Watertight solid geometry builders

def signed_volume(verts, faces):
    v0 = verts[faces[:, 0]]
    v1 = verts[faces[:, 1]]
    v2 = verts[faces[:, 2]]
    return float(np.einsum("ij,ij->i", v0, np.cross(v1, v2)).sum() / 6.0)


def verify_manifold(verts, faces, label="piece"):
    """Assert closed 2-manifold topology, consistent outward winding, and non-degenerate faces."""
    f = np.asarray(faces, dtype=np.int64)
    v = np.asarray(verts, dtype=np.float64)
    if len(f) == 0 or len(v) == 0:
        raise ValueError(f"{label}: empty geometry")
    e_dir = np.vstack([f[:, [0, 1]], f[:, [1, 2]], f[:, [2, 0]]])
    e_undir = np.sort(e_dir, axis=1)
    _, counts = np.unique(e_undir, axis=0, return_counts=True)
    open_e = int((counts == 1).sum())
    nonm_e = int((counts > 2).sum())
    if open_e != 0 or nonm_e != 0:
        raise ValueError(f"{label}: non-watertight (open={open_e}, nonmanifold={nonm_e})")
    _, dcounts = np.unique(e_dir, axis=0, return_counts=True)
    if int((dcounts != 1).sum()) != 0:
        raise ValueError(f"{label}: inconsistent face winding")
    vol = signed_volume(v, f)
    if vol <= 1e-10:
        raise ValueError(f"{label}: non-positive signed volume ({vol:.6g})")
    areas = 0.5 * np.linalg.norm(np.cross(v[f[:, 1]] - v[f[:, 0]], v[f[:, 2]] - v[f[:, 0]]), axis=1)
    if float(areas.min()) <= 1e-10:
        raise ValueError(f"{label}: degenerate triangle (min area={areas.min():.3e})")


def ensure_outward(verts, faces):
    verts = np.asarray(verts, dtype=np.float64)
    faces = np.asarray(faces, dtype=np.int64).copy()
    if signed_volume(verts, faces) < 0.0:
        faces[:, [1, 2]] = faces[:, [2, 1]]
    return verts, faces


def compute_smooth_normals(verts, faces):
    """Area-weighted smooth outward vertex normals."""
    v = np.asarray(verts, dtype=np.float64)
    f = np.asarray(faces, dtype=np.int64)
    fn = np.cross(v[f[:, 1]] - v[f[:, 0]], v[f[:, 2]] - v[f[:, 0]])
    n = np.zeros_like(v)
    for k in range(3):
        np.add.at(n, f[:, k], fn)
    lens = np.linalg.norm(n, axis=1, keepdims=True)
    return n / np.maximum(lens, 1e-12)


def loft_solid(rings, start_center=None, end_center=None, label="loft"):
    """Closed manifold solid lofted through M rings of N vertices, capped with apex fans."""
    m = len(rings)
    n = len(rings[0])
    ring_arr = [np.asarray(r, dtype=np.float64) for r in rings]
    verts = list(np.vstack(ring_arr))
    faces = []
    for r in range(m - 1):
        base0 = r * n
        base1 = (r + 1) * n
        for i in range(n):
            j = (i + 1) % n
            faces.append([base0 + i, base0 + j, base1 + j])
            faces.append([base0 + i, base1 + j, base1 + i])
    sc = ring_arr[0].mean(axis=0) if start_center is None else np.asarray(start_center, dtype=np.float64)
    idx_s = len(verts)
    verts.append(sc)
    for i in range(n):
        j = (i + 1) % n
        faces.append([idx_s, j, i])
    ec = ring_arr[-1].mean(axis=0) if end_center is None else np.asarray(end_center, dtype=np.float64)
    idx_e = len(verts)
    verts.append(ec)
    top = (m - 1) * n
    for i in range(n):
        j = (i + 1) % n
        faces.append([idx_e, top + i, top + j])
    verts, faces = ensure_outward(np.asarray(verts, dtype=np.float64), np.asarray(faces, dtype=np.int64))
    verify_manifold(verts, faces, label)
    return verts, faces


def ellipsoid_solid(center, radii, rings=5, segs=10, rot=None, deform_fn=None, label="ellipsoid"):
    """Closed manifold UV-ellipsoid with shared pole vertices (0 open edges)."""
    c = np.asarray(center, dtype=np.float64)
    rx, ry, rz = [float(r) for r in radii]
    ring_list = []
    for k in range(1, rings):
        phi = math.pi * k / rings - 0.5 * math.pi
        cp, sp = math.cos(phi), math.sin(phi)
        pts = []
        for i in range(segs):
            th = 2.0 * math.pi * i / segs
            pts.append([rx * cp * math.cos(th), ry * sp, rz * cp * math.sin(th)])
        ring_list.append(np.asarray(pts, dtype=np.float64))
    south = np.array([0.0, -ry, 0.0], dtype=np.float64)
    north = np.array([0.0, ry, 0.0], dtype=np.float64)
    if rot is not None:
        r_mat = np.asarray(rot, dtype=np.float64)
        ring_list = [r @ r_mat.T for r in ring_list]
        south = south @ r_mat.T
        north = north @ r_mat.T
    ring_list = [r + c for r in ring_list]
    south = south + c
    north = north + c
    verts, faces = loft_solid(ring_list, start_center=south, end_center=north, label=label + "_raw")
    if deform_fn is not None:
        verts = deform_fn(verts)
        verts, faces = ensure_outward(verts, faces)
        verify_manifold(verts, faces, label)
    return verts, faces


def bishop_frames(pts):
    """Parallel-transport (Bishop) frames (T, U, V) along a 3D polyline."""
    p = np.asarray(pts, dtype=np.float64)
    m = len(p)
    tangents = np.zeros((m, 3), dtype=np.float64)
    for i in range(m):
        if i == 0:
            t = p[1] - p[0]
        elif i == m - 1:
            t = p[-1] - p[-2]
        else:
            t = p[i + 1] - p[i - 1]
        tangents[i] = t / max(np.linalg.norm(t), 1e-12)
    ref = np.array([0.0, 1.0, 0.0]) if abs(tangents[0][1]) < 0.92 else np.array([1.0, 0.0, 0.0])
    u0 = np.cross(ref, tangents[0])
    u0 /= max(np.linalg.norm(u0), 1e-12)
    v0 = np.cross(tangents[0], u0)
    us = [u0]
    vs = [v0]
    for i in range(1, m):
        t_prev, t_cur = tangents[i - 1], tangents[i]
        axis = np.cross(t_prev, t_cur)
        alen = np.linalg.norm(axis)
        if alen > 1e-8:
            ang = math.acos(max(-1.0, min(1.0, float(np.dot(t_prev, t_cur)))))
            u_cur = rodrigues(us[-1], axis / alen, ang)
        else:
            u_cur = us[-1].copy()
        u_cur = u_cur - np.dot(u_cur, t_cur) * t_cur
        u_cur /= max(np.linalg.norm(u_cur), 1e-12)
        v_cur = np.cross(t_cur, u_cur)
        us.append(u_cur)
        vs.append(v_cur)
    return tangents, np.asarray(us), np.asarray(vs)


def tube_solid(spine, radii, segs=8, start_cap_push=0.0, end_cap_push=0.0,
               oval_bias=None, label="tube"):
    """Closed manifold curved tube along 3D spine with radii (M,) or (M, 2)."""
    p = np.asarray(spine, dtype=np.float64)
    rad = np.asarray(radii, dtype=np.float64)
    if rad.ndim == 1:
        rad = np.column_stack([rad, rad])
    tangents, us, vs = bishop_frames(p)
    rings = []
    angles = np.linspace(0.0, 2.0 * math.pi, segs, endpoint=False)
    ca, sa = np.cos(angles), np.sin(angles)
    for k in range(len(p)):
        ru, rv = rad[k, 0], rad[k, 1]
        if oval_bias is not None:
            up_ref = np.array([0.0, 1.0, 0.0])
            side_v = np.cross(up_ref, tangents[k])
            if np.linalg.norm(side_v) > 0.15:
                side_v /= np.linalg.norm(side_v)
                up_v = np.cross(tangents[k], side_v)
                ring = p[k] + np.outer(ca * ru, side_v) + np.outer(sa * rv, up_v)
                rings.append(ring)
                continue
        ring = p[k] + np.outer(ca * ru, us[k]) + np.outer(sa * rv, vs[k])
        rings.append(ring)
    sc = p[0] - tangents[0] * start_cap_push
    ec = p[-1] + tangents[-1] * end_cap_push
    return loft_solid(rings, start_center=sc, end_center=ec, label=label)


def carapace_plate_solid(stations, ridge_boost=0.06, flare=0.0, lip_lift=0.0,
                         chevron=0.14, arch_pow=2.05, label="plate"):
    """Closed thick beveled arched carapace crest plate with uniform-thickness side skirts.

    stations: list of (z, y_crown, half_w, arch_drop, thickness) from anterior to posterior.
    """
    rings = []
    u_outer = np.array([-1.0, -0.88, -0.62, -0.30, 0.0, 0.30, 0.62, 0.88, 1.0], dtype=np.float64)
    u_inner = np.array([0.86, 0.48, 0.0, -0.48, -0.86], dtype=np.float64)

    for idx, (z, y_crown, hw, drop, thick) in enumerate(stations):
        s = idx / max(len(stations) - 1, 1)
        shingle = lip_lift * (s ** 2.1)
        ring = []
        for u in u_outer:
            au = abs(u)
            x = u * hw * (1.0 + flare * (s ** 1.4) * (0.4 + 0.6 * au))
            arch = drop * (au ** arch_pow)
            keel = ridge_boost * ((1.0 - min(au / 0.38, 1.0)) ** 2) * (0.45 + 0.55 * s)
            rim_tuck = 0.16 * thick * max(0.0, (au - 0.85) / 0.15)
            y = y_crown + shingle - arch + keel - rim_tuck
            z_off = chevron * hw * (au ** 1.55) * (0.35 + 0.65 * s)
            ring.append([x, y, z + z_off])
        for u in u_inner:
            au = abs(u)
            # Inset horizontally on steep side skirts and vertically at the crown
            x_scale = max(0.68, 1.0 - thick / max(hw, 0.12))
            x = u * hw * x_scale * (1.0 + flare * (s ** 1.4) * (0.4 + 0.6 * au))
            arch = drop * (au ** arch_pow)
            y_in_off = thick * (0.95 - 0.55 * (au ** 1.6))
            y = y_crown + shingle - arch - y_in_off
            z_off = chevron * hw * (au ** 1.55) * (0.35 + 0.65 * s)
            ring.append([x, y, z + z_off])
        rings.append(np.asarray(ring, dtype=np.float64))

    z0, yc0, _hw0, dr0, th0 = stations[0]
    z1, yc1, _hw1, dr1, th1 = stations[-1]
    front_c = np.array([0.0, yc0 - 0.32 * dr0 - 0.40 * th0, z0 - 0.03], dtype=np.float64)
    back_c = np.array([0.0, yc1 + lip_lift - 0.24 * dr1 - 0.36 * th1, z1 + 0.045], dtype=np.float64)
    return loft_solid(rings, start_center=front_c, end_center=back_c, label=label)


# ---------------------------------------------------------------------------------------------
# Mesh accumulator by material

class MeshBuilder:
    def __init__(self):
        self.groups = {name: [] for name, _, _, _ in MATERIALS}

    def add(self, material, verts, faces, uv0, part_rgb):
        v = np.asarray(verts, dtype=np.float64)
        f = np.asarray(faces, dtype=np.int64)
        uv = np.asarray(uv0, dtype=np.float64)
        if uv.ndim == 1:
            uv = np.tile(uv, (len(v), 1))
        prgb = np.asarray(part_rgb, dtype=np.float64)
        if prgb.ndim == 1:
            prgb = np.tile(prgb, (len(v), 1))
        self.groups[material].append((v, f, uv, prgb))

    def merged(self):
        out = []
        for name, _, _, _ in MATERIALS:
            pieces = self.groups[name]
            if not pieces:
                continue
            v_list, f_list, uv_list, c_list = [], [], [], []
            offset = 0
            for v, f, uv, prgb in pieces:
                v_list.append(v)
                f_list.append(f + offset)
                uv_list.append(uv)
                c_list.append(prgb)
                offset += len(v)
            V = np.vstack(v_list)
            F = np.vstack(f_list)
            UV = np.vstack(uv_list)
            C = np.vstack(c_list)
            verify_manifold(V, F, f"material:{name}")
            out.append((name, V, F, UV, C))
        return out


# ---------------------------------------------------------------------------------------------
# Color & skin mask painters (linear values encoded into TEXCOORD_4/5 = CUSTOM1)

def spitter_spine_y(z):
    """Reference fleshy torso centerline Y along Z (sloped posture matching creature_rigs.json)."""
    return 1.00 - 0.34 * z - 0.04 * (z ** 2)


def paint_flesh(verts, base=(0.108, 0.048, 0.036), belly=(0.165, 0.078, 0.056),
                dark=(0.042, 0.018, 0.015), z_ribs=0.0):
    """Organic earthy reddish-brown spitter flesh following the sloped body centerline."""
    v = np.asarray(verts, dtype=np.float64)
    base_c = np.asarray(base, dtype=np.float64)
    belly_c = np.asarray(belly, dtype=np.float64)
    dark_c = np.asarray(dark, dtype=np.float64)
    y_rel = v[:, 1] - spitter_spine_y(v[:, 2])
    b_t = 1.0 - smoothstep(-0.28, 0.16, y_rel)
    d_t = smoothstep(0.18, 0.52, y_rel) * 0.68
    col = base_c[None, :] * (1.0 - b_t[:, None]) + belly_c[None, :] * b_t[:, None]
    col = col * (1.0 - d_t[:, None]) + dark_c[None, :] * d_t[:, None]
    if z_ribs > 0.0:
        rib = 0.5 + 0.5 * np.sin(v[:, 2] * z_ribs)
        col *= (0.86 + 0.24 * rib * (0.4 + 0.6 * b_t))[:, None]
    return np.clip(col, 0.005, 1.5)


def paint_chitin_mask(verts, y_lo, y_hi, z_range=None, is_spine=False, tip_t=None):
    """Encode skin_mode 1 masks (R=mask1_shade, G=mask2_shade, B=mask2_cover) for all 4 spitter tiers."""
    v = np.asarray(verts, dtype=np.float64)
    ht = smoothstep(y_lo, y_hi, v[:, 1])
    ridge = (1.0 - smoothstep(0.0, 0.36, np.abs(v[:, 0]))) * (0.35 + 0.65 * ht)
    if is_spine:
        tt = ht if tip_t is None else np.clip(tip_t, 0.0, 1.0)
        m1 = 0.095 + 0.145 * tt
        m2 = 0.125 + 0.305 * (tt ** 1.15)
        cov = 0.56 + 0.35 * tt
    else:
        m1 = 0.068 + 0.100 * ht + 0.052 * ridge
        m2 = 0.048 + 0.155 * ht + 0.122 * ridge
        cov = 0.44 + 0.24 * ht + 0.18 * ridge
        if z_range is not None:
            z0, z1 = z_range
            z_t = smoothstep(z0, z1, v[:, 2])
            m1 *= (0.70 + 0.40 * z_t)
            m2 *= (0.64 + 0.52 * z_t)
            cov += 0.10 * (z_t - 0.5)
    return np.column_stack([np.clip(m1, 0.02, 0.45), np.clip(m2, 0.015, 0.65), np.clip(cov, 0.24, 0.94)])


# ---------------------------------------------------------------------------------------------
# Big-spitter anatomical builder

def build_big_spitter(rig):
    """Build the watertight standing big-spitter matching client/data/creature_rigs.json."""
    mb = MeshBuilder()
    body_uv = np.array([0.0, 0.0], dtype=np.float64)

    # =========================================================================================
    # 1. ELEVATED ACID-SPITTING HEAD, SNOUT, MANDIBLES & NECK (z ≈ -1.56 .. -0.34)
    # =========================================================================================

    # 1a. Muscular ribbed neck bridging elevated head into arched thorax.
    # Tall dorsal muscle arch rises right into the underside of the cranial/thoracic carapace!
    # Explicit stations around z = -0.42 give addon_creatures.gd a crisp closed split loop.
    neck_spec = [
        (-0.96, 1.24, 0.34, 0.24, 0.48),
        (-0.80, 1.25, 0.40, 0.29, 0.55),
        (-0.64, 1.25, 0.45, 0.34, 0.60),
        (-0.50, 1.24, 0.47, 0.38, 0.62),
        (-0.42, 1.23, 0.48, 0.40, 0.63),
        (-0.34, 1.21, 0.49, 0.41, 0.63),
    ]
    neck_rings = []
    segs_n = 14
    th_n = np.linspace(0.0, 2.0 * math.pi, segs_n, endpoint=False)
    for idx, (z, yc, rx, ry_d, ry_u) in enumerate(neck_spec):
        ca, sa = np.cos(th_n), np.sin(th_n)
        rib = 1.0 + 0.060 * (1 if idx % 2 == 0 else -1)
        x = ca * rx * np.where(sa < -0.3, 0.88, np.where(sa > 0.35, 0.90, 1.0))
        y = yc + np.where(sa < 0, sa * ry_d * rib, sa * ry_u)
        neck_rings.append(np.column_stack([x, y, np.full(segs_n, z)]))
    v, f = loft_solid(neck_rings, start_center=[0.0, 1.28, -1.02], end_center=[0.0, 1.24, -0.30], label="neck")
    mb.add("flesh_spitter", v, f, body_uv, paint_flesh(v, z_ribs=28.0))

    # 1b. Slender Elevated Acid-Spitting Head & Tapered Oral Snout (z ≈ -1.52 .. -0.82)
    head_spec = [
        (-1.48, 1.06, 0.11, 0.085, 0.14, 0.00),  # oral acid-nozzle snout tip
        (-1.38, 1.11, 0.18, 0.135, 0.24, 0.01),  # tapered oral duct
        (-1.24, 1.17, 0.26, 0.180, 0.36, 0.02),  # mid-snout cheeks under forehead hood
        (-1.08, 1.22, 0.32, 0.215, 0.44, 0.03),  # broad cranial cheek muscle
        (-0.92, 1.25, 0.35, 0.235, 0.48, 0.02),  # occiput joining neck
        (-0.80, 1.25, 0.32, 0.220, 0.46, 0.00),
    ]
    head_rings = []
    segs_h = 14
    th_h = np.linspace(0.0, 2.0 * math.pi, segs_h, endpoint=False)
    for z, yc, rx, ry_d, ry_u, cheek in head_spec:
        ca, sa = np.cos(th_h), np.sin(th_h)
        x = ca * (rx + cheek * np.exp(-((sa + 0.15) ** 2) * 4.5))
        y = yc + np.where(sa < 0, sa * ry_d, sa * ry_u)
        head_rings.append(np.column_stack([x, y, np.full(segs_h, z)]))
    v, f = loft_solid(head_rings, start_center=[0.0, 1.04, -1.52], end_center=[0.0, 1.26, -0.74], label="cranium")
    col_head = paint_flesh(v, base=(0.115, 0.052, 0.038), belly=(0.160, 0.076, 0.054))
    nozzle_t = smoothstep(-1.30, -1.51, v[:, 2]) * (1.0 - smoothstep(1.06, 1.22, v[:, 1]))
    col_head = col_head * (1.0 - 0.65 * nozzle_t[:, None]) + np.array([0.036, 0.044, 0.016]) * (0.65 * nozzle_t[:, None])
    mb.add("flesh_spitter", v, f, body_uv, col_head)

    # 1c. Sculpted Oral Acid-Duct Collar / Lip Ring at snout front (watertight bulbous rim)
    v, f = ellipsoid_solid([0.0, 1.045, -1.495], [0.095, 0.074, 0.055], rings=4, segs=10, label="oral_duct_collar")
    duct_t = smoothstep(-1.46, -1.55, v[:, 2])
    duct_col = (1.0 - duct_t[:, None]) * np.array([0.088, 0.042, 0.030]) + duct_t[:, None] * np.array([0.024, 0.038, 0.014])
    mb.add("flesh_spitter", v, f, body_uv, duct_col)

    # 1d. Tall Forward-Curving Cranial Crest / Forehead Helmet Hood (chitin_spitter)
    # Wraps tightly over occiput and curves cleanly above eyes so snout & eyes stay readable.
    head_plate = [
        (-1.52, 1.56, 0.16, 0.24, 0.044),
        (-1.38, 1.88, 0.30, 0.50, 0.066),
        (-1.20, 2.18, 0.42, 0.74, 0.082),
        (-1.00, 2.38, 0.49, 0.90, 0.090),
        (-0.82, 2.46, 0.52, 0.96, 0.086),
    ]
    v, f = carapace_plate_solid(head_plate, ridge_boost=0.068, flare=0.07, lip_lift=0.045,
                                chevron=0.12, arch_pow=2.05, label="cranial_crest")
    mb.add("chitin_spitter", v, f, body_uv, paint_chitin_mask(v, 1.24, 2.52, z_range=(-1.52, -0.82)))

    # 1e. Swept Brow Ridges, Dark Glossy Eyes, Twin Side Acid-Channeling Mandibles & Oral Palps
    for side in (-1.0, 1.0):
        tag = "l" if side < 0 else "r"
        # Sleek swept-back armored brow ridge hugging the lower rim of the cranial hood right over eyes
        brow_spine = [
            [side * 0.16, 1.36, -1.41],
            [side * 0.29, 1.44, -1.23],
            [side * 0.39, 1.51, -1.03],
            [side * 0.46, 1.57, -0.83],
        ]
        brow_rad = [[0.032, 0.024], [0.044, 0.032], [0.038, 0.028], [0.013, 0.011]]
        v, f = tube_solid(brow_spine, brow_rad, segs=6, start_cap_push=0.02, end_cap_push=0.042, label=f"brow_{tag}")
        tip_t = smoothstep(-1.41, -0.79, v[:, 2])
        mb.add("chitin_spitter", v, f, body_uv, paint_chitin_mask(v, 1.30, 1.62, is_spine=True, tip_t=tip_t))

        # Primary outer eye node + secondary forward ocellus (dark glossy insectoid eyes)
        v, f = ellipsoid_solid([side * 0.27, 1.27, -1.16], [0.056, 0.050, 0.066], rings=4, segs=8, label=f"eye_main_{tag}")
        mb.add("flesh_spitter", v, f, body_uv, np.array([0.009, 0.007, 0.018]))

        v, f = ellipsoid_solid([side * 0.17, 1.23, -1.32], [0.038, 0.035, 0.044], rings=3, segs=6, label=f"eye_sub_{tag}")
        mb.add("flesh_spitter", v, f, body_uv, np.array([0.011, 0.008, 0.020]))

        # Twin slender acid-channeling side mandibles framing the oral duct
        jaw_spine = [
            [side * 0.17, 1.07, -1.16],
            [side * 0.25, 1.04, -1.32],
            [side * 0.24, 1.01, -1.46],
            [side * 0.13, 0.99, -1.55],
        ]
        jaw_rad = [[0.052, 0.060], [0.046, 0.054], [0.034, 0.040], [0.010, 0.011]]
        v, f = tube_solid(jaw_spine, jaw_rad, segs=7, start_cap_push=0.025, end_cap_push=0.032,
                          oval_bias=True, label=f"mandible_{tag}")
        jt = smoothstep(-1.18, -1.56, v[:, 2])
        j_col = (1.0 - jt[:, None]) * np.array([0.052, 0.022, 0.018]) + jt[:, None] * np.array([0.22, 0.145, 0.092])
        mb.add("flesh_spitter", v, f, body_uv, j_col)

        # Pair of sharp inner mandible barbs
        for bi, (tb, tt_pt, tr) in enumerate([
            ([side * 0.22, 1.03, -1.34], [side * 0.12, 1.02, -1.38], 0.024),
            ([side * 0.20, 1.00, -1.46], [side * 0.11, 0.99, -1.50], 0.018),
        ]):
            mid = 0.5 * (np.array(tb) + np.array(tt_pt)) + np.array([0.0, 0.006, -0.008])
            v, f = tube_solid([tb, mid, tt_pt], [tr, tr * 0.55, 0.004], segs=5,
                              start_cap_push=0.012, end_cap_push=0.012, label=f"barb_{tag}_{bi}")
            mb.add("flesh_spitter", v, f, body_uv, np.array([0.25, 0.175, 0.112]))

        # Slender lower oral feeder palps beneath the acid nozzle
        palp_spine = [
            [side * 0.11, 0.97, -1.24],
            [side * 0.14, 0.93, -1.39],
            [side * 0.07, 0.92, -1.50],
        ]
        v, f = tube_solid(palp_spine, [0.030, 0.022, 0.008], segs=6,
                          start_cap_push=0.018, end_cap_push=0.020, label=f"palp_{tag}")
        mb.add("flesh_spitter", v, f, body_uv, np.array([0.092, 0.038, 0.028]))

    # =========================================================================================
    # 2. ARCHED INSECTOID THORAX & TOWERING SHINGLED CARAPACE CREST (z ≈ -0.78 .. +0.44)
    # =========================================================================================

    # 2a. Arched Fleshy Thorax with Ribbed Ventral Belly & Anatomical Waist at z = +0.34..+0.36
    # High dorsal muscle core fills right up inside the vaulted carapace shell (ZERO gap!).
    # Explicit stations at z = -0.42 and z = +0.36 for clean ragdoll body-split slices.
    thorax_spec = [
        (-0.76, 1.24, 0.44, 0.34, 0.60),
        (-0.60, 1.24, 0.48, 0.39, 0.65),
        (-0.42, 1.23, 0.50, 0.43, 0.67),  # head/thorax split plane
        (-0.24, 1.20, 0.51, 0.45, 0.68),
        (-0.06, 1.15, 0.50, 0.44, 0.66),
        (0.10, 1.09, 0.46, 0.40, 0.62),
        (0.24, 1.01, 0.41, 0.36, 0.58),
        (0.36, 0.95, 0.38, 0.34, 0.56),   # anatomical waist & thorax/abdomen split plane
        (0.46, 0.90, 0.40, 0.36, 0.56),
    ]
    thorax_rings = []
    segs_t = 16
    th_t = np.linspace(0.0, 2.0 * math.pi, segs_t, endpoint=False)
    for idx, (z, yc, rx, ry_d, ry_u) in enumerate(thorax_spec):
        ca, sa = np.cos(th_t), np.sin(th_t)
        rib = 1.0 + 0.075 * math.sin(idx * 2.3)
        width_mod = np.where(sa < -0.35, 0.85, np.where(sa > 0.35, 0.88, 1.0))
        x = ca * rx * width_mod * (1.0 + 0.045 * np.exp(-(sa ** 2) * 5.5))
        y = yc + np.where(sa < 0, sa * ry_d * rib, sa * ry_u)
        thorax_rings.append(np.column_stack([x, y, np.full(segs_t, z)]))
    v, f = loft_solid(thorax_rings, start_center=[0.0, 1.26, -0.82], end_center=[0.0, 0.92, 0.52], label="thorax_flesh")
    mb.add("flesh_spitter", v, f, body_uv, paint_flesh(v, z_ribs=26.0))

    # 2b. Sculpted Ventral Sternite Chest Ribs along the sloped thoracic belly
    for ri, (rz, r_rx, r_y) in enumerate([
        (-0.56, 0.31, 0.88),
        (-0.32, 0.35, 0.80),
        (-0.08, 0.34, 0.74),
        (0.14, 0.30, 0.70),
    ]):
        v, f = ellipsoid_solid([0.0, r_y, rz], [r_rx, 0.044, 0.082], rings=3, segs=10, label=f"sternite_t{ri}")
        mb.add("flesh_spitter", v, f, body_uv, paint_flesh(v, base=(0.140, 0.064, 0.046), belly=(0.188, 0.088, 0.062)))

    # 2c. 3 Towering Swept-Back Shingled Thoracic Carapace Crest Plates (chitin_spitter)
    # Deep vaulted side skirts (arch_drop ≈ 0.96..1.05) hug the upper fleshy flanks seamlessly!
    thorax_plates = [
        ("carapace_th1", [
            (-0.96, 2.30, 0.46, 0.84, 0.076),
            (-0.78, 2.48, 0.54, 0.98, 0.096),
            (-0.60, 2.55, 0.57, 1.04, 0.102),
            (-0.42, 2.53, 0.56, 1.02, 0.090),
        ], 0.078, 0.060),
        ("carapace_th2", [
            (-0.50, 2.46, 0.52, 0.94, 0.086),
            (-0.34, 2.57, 0.58, 1.05, 0.104),
            (-0.16, 2.56, 0.58, 1.05, 0.104),
            (0.02, 2.48, 0.54, 1.00, 0.088),
        ], 0.082, 0.064),
        ("carapace_th3", [
            (-0.06, 2.40, 0.50, 0.94, 0.080),
            (0.10, 2.47, 0.54, 1.02, 0.096),
            (0.24, 2.41, 0.50, 1.00, 0.088),
            (0.38, 2.31, 0.45, 0.96, 0.074),
        ], 0.072, 0.056),
    ]
    for pname, stations, ridge, lift in thorax_plates:
        v, f = carapace_plate_solid(stations, ridge_boost=ridge, flare=0.07, lip_lift=lift,
                                    chevron=0.14, arch_pow=2.05, label=pname)
        mb.add("chitin_spitter", v, f, body_uv,
               paint_chitin_mask(v, 1.38, 2.64, z_range=(stations[0][0], stations[-1][0])))

    # 2d. Sleek Swept-Back Dorsal Crest Spines & Upper Shoulder Horns (chitin_spitter)
    dorsal_spines = [
        ("spine_c0", [[0.0, 2.18, -1.24], [0.0, 2.38, -1.06], [0.0, 2.49, -0.84]], [[0.048, 0.072], [0.030, 0.046], [0.009, 0.012]], 0.042),
        ("spine_c1", [[0.0, 2.44, -0.78], [0.0, 2.58, -0.58], [0.0, 2.62, -0.36]], [[0.056, 0.082], [0.036, 0.052], [0.010, 0.013]], 0.046),
        ("spine_c2", [[0.0, 2.46, -0.34], [0.0, 2.59, -0.14], [0.0, 2.61, 0.10]], [[0.060, 0.086], [0.038, 0.054], [0.010, 0.013]], 0.048),
        ("spine_c3", [[0.0, 2.36, 0.08], [0.0, 2.48, 0.26], [0.0, 2.49, 0.48]], [[0.052, 0.074], [0.032, 0.046], [0.009, 0.012]], 0.042),
    ]
    for side in (-1.0, 1.0):
        tag = "l" if side < 0 else "r"
        dorsal_spines.append((
            f"spine_s1_{tag}",
            [[side * 0.22, 2.32, -0.72], [side * 0.32, 2.46, -0.54], [side * 0.38, 2.52, -0.32]],
            [[0.040, 0.058], [0.025, 0.038], [0.008, 0.010]], 0.038,
        ))
        dorsal_spines.append((
            f"spine_s2_{tag}",
            [[side * 0.24, 2.32, -0.26], [side * 0.35, 2.45, -0.08], [side * 0.41, 2.49, 0.14]],
            [[0.042, 0.060], [0.026, 0.040], [0.008, 0.010]], 0.040,
        ))
        dorsal_spines.append((
            f"spine_s3_{tag}",
            [[side * 0.21, 2.20, 0.16], [side * 0.30, 2.31, 0.34], [side * 0.36, 2.34, 0.54]],
            [[0.036, 0.052], [0.022, 0.034], [0.008, 0.010]], 0.034,
        ))
    for hname, hspine, hrad, push in dorsal_spines:
        v, f = tube_solid(hspine, hrad, segs=6, start_cap_push=0.028, end_cap_push=push,
                          oval_bias=True, label=hname)
        y0 = hspine[0][1]
        y1 = hspine[-1][1] + push * 0.4
        tip_t = smoothstep(y0, y1, v[:, 1])
        mb.add("chitin_spitter", v, f, body_uv, paint_chitin_mask(v, y0, y1, is_spine=True, tip_t=tip_t))

    # =========================================================================================
    # 3. ELONGATED RIBBED ABDOMEN, REAR CARAPACE PLATES & BULBOUS ACID-SAC (z ≈ +0.26 .. +1.56)
    # =========================================================================================

    # 3a. Elongated Ribbed Ventral Abdomen (smoothly joins thoracic waist at z=+0.36;
    # tall dorsal ridge stays deeply seated inside the rear carapace shell plates!)
    abdomen_spec = [
        (0.26, 1.00, 0.40, 0.35, 0.58),
        (0.36, 0.95, 0.38, 0.34, 0.56),   # waist socket matching thorax seamlessly
        (0.50, 0.89, 0.44, 0.39, 0.58),
        (0.68, 0.81, 0.46, 0.41, 0.60),
        (0.88, 0.72, 0.44, 0.40, 0.58),
        (1.06, 0.65, 0.40, 0.36, 0.54),
        (1.24, 0.61, 0.34, 0.30, 0.50),
        (1.38, 0.61, 0.25, 0.22, 0.42),
        (1.48, 0.64, 0.14, 0.12, 0.26),
    ]
    abd_rings = []
    segs_a = 14
    th_a = np.linspace(0.0, 2.0 * math.pi, segs_a, endpoint=False)
    for idx, (z, yc, rx, ry_d, ry_u) in enumerate(abdomen_spec):
        ca, sa = np.cos(th_a), np.sin(th_a)
        rib = 1.0 + 0.08 * math.sin(idx * 2.4)
        width_mod = np.where(sa < -0.35, 0.87, np.where(sa > 0.35, 0.88, 1.0))
        x = ca * rx * width_mod
        y = yc + np.where(sa < 0, sa * ry_d * rib, sa * ry_u)
        abd_rings.append(np.column_stack([x, y, np.full(segs_a, z)]))
    v, f = loft_solid(abd_rings, start_center=[0.0, 1.00, 0.20], end_center=[0.0, 0.66, 1.53], label="abdomen_flesh")
    mb.add("flesh_spitter", v, f, body_uv, paint_flesh(v, z_ribs=25.0))

    # 3b. Sculpted Ventral Abdominal Sternite Ribs
    for ri, (rz, r_rx, r_y) in enumerate([
        (0.50, 0.30, 0.53),
        (0.70, 0.32, 0.43),
        (0.90, 0.29, 0.35),
        (1.10, 0.24, 0.32),
    ]):
        v, f = ellipsoid_solid([0.0, r_y, rz], [r_rx, 0.040, 0.074], rings=3, segs=8, label=f"sternite_a{ri}")
        mb.add("flesh_spitter", v, f, body_uv, paint_flesh(v, base=(0.140, 0.064, 0.046), belly=(0.188, 0.088, 0.062)))

    # 3c. Bulbous Rear Acid-Sac / Glandular Tail Bulb nestled snugly under the rear carapace hood
    sac_spec = [
        (0.98, 0.78, 0.32, 0.28, 0.40),
        (1.14, 0.78, 0.38, 0.32, 0.44),
        (1.28, 0.80, 0.36, 0.30, 0.42),
        (1.42, 0.82, 0.28, 0.24, 0.32),
        (1.51, 0.84, 0.15, 0.13, 0.16),
    ]
    sac_rings = []
    segs_s = 12
    th_s = np.linspace(0.0, 2.0 * math.pi, segs_s, endpoint=False)
    for z, yc, rx, ry_d, ry_u in sac_spec:
        ca, sa = np.cos(th_s), np.sin(th_s)
        lobe = 1.0 + 0.05 * np.cos(3.0 * th_s)
        x = ca * rx * lobe
        y = yc + np.where(sa < 0, sa * ry_d * lobe, sa * ry_u * lobe)
        sac_rings.append(np.column_stack([x, y, np.full(segs_s, z)]))
    v, f = loft_solid(sac_rings, start_center=[0.0, 0.78, 0.92], end_center=[0.0, 0.85, 1.55], label="acid_sac")
    sac_base = paint_flesh(v, base=(0.115, 0.056, 0.036), belly=(0.158, 0.084, 0.050))
    sac_glow = smoothstep(1.06, 1.50, v[:, 2]) * (1.0 - smoothstep(0.95, 1.24, v[:, 1]))
    sac_col = sac_base * (1.0 - 0.50 * sac_glow[:, None]) + np.array([0.140, 0.125, 0.042]) * (0.50 * sac_glow[:, None])
    mb.add("flesh_spitter", v, f, body_uv, sac_col)

    # Twin small rear glandular cerci flanking the lower acid-sac
    for side in (-1.0, 1.0):
        tag = "l" if side < 0 else "r"
        cerc_spine = [
            [side * 0.16, 0.64, 1.32],
            [side * 0.21, 0.60, 1.44],
            [side * 0.14, 0.59, 1.53],
        ]
        v, f = tube_solid(cerc_spine, [0.042, 0.028, 0.009], segs=6,
                          start_cap_push=0.02, end_cap_push=0.024, label=f"cercus_{tag}")
        mb.add("flesh_spitter", v, f, body_uv, np.array([0.088, 0.042, 0.028]))

    # 3d. 3 Segmented Overlapping Rear Carapace Plates wrapping deeply down over abdomen & acid-sac
    abd_plates = [
        ("abd_plate_1", [
            (0.30, 2.28, 0.45, 0.92, 0.076),
            (0.46, 2.32, 0.50, 1.02, 0.088),
            (0.62, 2.26, 0.50, 1.02, 0.084),
            (0.78, 2.14, 0.47, 0.98, 0.070),
        ], 0.072, 0.056),
        ("abd_plate_2", [
            (0.70, 2.10, 0.44, 0.92, 0.072),
            (0.86, 2.12, 0.48, 1.00, 0.082),
            (1.02, 2.02, 0.45, 0.96, 0.076),
            (1.16, 1.86, 0.41, 0.90, 0.064),
        ], 0.064, 0.050),
        ("abd_plate_3", [
            (1.08, 1.80, 0.39, 0.84, 0.064),
            (1.24, 1.74, 0.40, 0.84, 0.070),
            (1.38, 1.56, 0.33, 0.72, 0.060),
            (1.52, 1.28, 0.20, 0.46, 0.044),
        ], 0.052, 0.036),
    ]
    for pname, stations, ridge, lift in abd_plates:
        v, f = carapace_plate_solid(stations, ridge_boost=ridge, flare=0.06, lip_lift=lift,
                                    chevron=0.13, arch_pow=2.05, label=pname)
        mb.add("chitin_spitter", v, f, body_uv,
               paint_chitin_mask(v, 0.88, 2.38, z_range=(stations[0][0], stations[-1][0])))

    # 3e. Curved Armored Tail Tip Crest + 2 Rear Dorsal Spines (chitin_spitter)
    tail_spine = [
        [0.0, 1.52, 1.34],
        [0.0, 1.36, 1.48],
        [0.0, 1.14, 1.55],
        [0.0, 0.94, 1.56],
    ]
    tail_rad = [[0.088, 0.076], [0.068, 0.058], [0.042, 0.038], [0.012, 0.012]]
    v, f = tube_solid(tail_spine, tail_rad, segs=6, start_cap_push=0.035, end_cap_push=0.028, label="tail_crest")
    tip_t = smoothstep(1.34, 1.58, v[:, 2])
    mb.add("chitin_spitter", v, f, body_uv, paint_chitin_mask(v, 0.88, 1.58, is_spine=True, tip_t=tip_t))

    rear_horns = [
        ("spine_a1", [[0.0, 2.20, 0.50], [0.0, 2.30, 0.68], [0.0, 2.29, 0.88]], [[0.046, 0.064], [0.028, 0.040], [0.008, 0.011]], 0.038),
        ("spine_a2", [[0.0, 1.98, 0.88], [0.0, 2.05, 1.04], [0.0, 2.00, 1.22]], [[0.038, 0.052], [0.024, 0.034], [0.008, 0.010]], 0.032),
    ]
    for hname, hspine, hrad, push in rear_horns:
        v, f = tube_solid(hspine, hrad, segs=6, start_cap_push=0.024, end_cap_push=push, oval_bias=True, label=hname)
        tip_t = smoothstep(hspine[0][1], hspine[-1][1] + push * 0.4, v[:, 1])
        mb.add("chitin_spitter", v, f, body_uv, paint_chitin_mask(v, hspine[0][1], hspine[-1][1] + push, is_spine=True, tip_t=tip_t))

    # =========================================================================================
    # 4. 12 SOLID ARTICULATED LEGS (anchored at exact creature_rigs.json joint & knee coords!)
    # =========================================================================================
    # Claw target offsets relative to knee (dx_out, dy_down, dz_fwd) tuned per limb so:
    #  - every leg follows its exact rig joint -> knee -> tibia -> tarsus -> claw path,
    #  - overall bounds stay cleanly within X: [-0.84, +0.84], Z: [-1.57, +1.57],
    #  - rear feet ground cleanly at lo.y == 0.0000 in rest pose AND all 12 feet sweep cleanly
    #    above/on ground y ≈ 0.00..0.35 under rig_mode == 1 (rig_body pitch -16.1 deg, dy -0.397).
    claw_specs = {
        # name: (foot_x, foot_y, foot_z, femur_r, knee_r, claw_r)
        "leg_la": (-0.64, 0.90, -1.24, 0.060, 0.048, 0.009),
        "leg_lb": (-0.74, 0.72, -0.62, 0.058, 0.046, 0.009),
        "leg_lc": (-0.75, 0.48,  0.24, 0.054, 0.044, 0.008),
        "leg_ld": (-0.75, 0.38,  0.48, 0.058, 0.046, 0.009),
        "leg_le": (-0.68, 0.16,  0.80, 0.054, 0.043, 0.008),
        "leg_lf": (-0.69, 0.24,  1.00, 0.054, 0.044, 0.008),
        "leg_ra": ( 0.68, 0.90, -0.94, 0.060, 0.048, 0.009),
        "leg_rb": ( 0.73, 0.78, -0.66, 0.056, 0.045, 0.009),
        "leg_rc": ( 0.71, 0.92, -0.58, 0.054, 0.044, 0.008),
        "leg_rd": ( 0.73, 0.42, -0.02, 0.054, 0.044, 0.008),
        "leg_re": ( 0.74, 0.23,  0.60, 0.054, 0.043, 0.008),
        "leg_rf": ( 0.68, 0.00,  1.28, 0.056, 0.044, 0.009),
    }

    for i, limb in enumerate(rig["limbs"]):
        lname = limb["name"]
        limb_id = float(i + 1)
        side = -1.0 if lname[4] == "l" else 1.0
        joint = np.asarray(limb["joint"], dtype=np.float64)
        rig_knee = np.asarray(limb["knee"], dtype=np.float64)
        fx, fy, fz, femur_r, knee_r, claw_r = claw_specs[lname]
        foot = np.array([fx, fy, fz], dtype=np.float64)

        # 4a. Stationary muscular coxa root bridging symmetrical torso wall cleanly into `joint` (UV.x = 0)
        anchor_z = max(-0.88, min(1.22, joint[2] * 0.92))
        anchor_y = spitter_spine_y(anchor_z) - 0.10
        anchor_x = side * min(abs(joint[0]) - 0.10, 0.30)
        coxa_root = np.array([anchor_x, anchor_y, anchor_z], dtype=np.float64)
        coxa_mid = 0.48 * coxa_root + 0.52 * joint + np.array([0.0, 0.03, 0.0])
        v, f = tube_solid([coxa_root, coxa_mid, joint],
                          [[0.074, 0.082], [0.066, 0.072], [0.058, 0.062]],
                          segs=7, start_cap_push=0.04, end_cap_push=0.02, label=f"{lname}_coxa")
        mb.add("flesh_spitter", v, f, body_uv, paint_flesh(v))

        # 4b. Hip socket ball at exact `joint` (UV.y = 0.0 -> stays firmly seated as leg rotates)
        v, f = ellipsoid_solid(joint, [0.064, 0.064, 0.068], rings=4, segs=8, label=f"{lname}_socket")
        sock_col = paint_flesh(v, base=(0.112, 0.048, 0.034), belly=(0.142, 0.064, 0.044))
        mb.add("flesh_leg", v, f, np.array([limb_id, 0.0]), sock_col)

        # 4c. Continuous watertight Femur -> Knee -> Tibia -> Tarsus -> Grounded Claw (UV.y = 1.0)
        # Keep outer knee vertices cleanly within wube3dp bounds |X| <= 0.84.
        out_pad = 0.008 if abs(rig_knee[0]) > 0.72 else 0.022
        knee_apex = rig_knee.copy() + np.array([side * out_pad, 0.024, 0.0])
        femur_mid = 0.50 * joint + 0.50 * knee_apex + np.array([0.0, 0.022, 0.0])
        arch_out = 0.014 if abs(rig_knee[0]) > 0.72 else 0.032
        post_knee = 0.74 * knee_apex + 0.26 * foot + np.array([side * arch_out, 0.014, 0.0])
        tibia_mid = 0.42 * knee_apex + 0.58 * foot + np.array([side * arch_out, 0.005, 0.0])
        ankle = 0.14 * knee_apex + 0.86 * foot + np.array([side * 0.010, 0.020, 0.0])
        claw_tip = np.array([foot[0], max(foot[1], 0.018), foot[2]], dtype=np.float64)

        leg_spine = [joint, femur_mid, knee_apex, post_knee, tibia_mid, ankle, claw_tip]
        leg_radii = [
            [femur_r * 0.88, femur_r * 0.94],
            [femur_r * 1.02, femur_r * 1.15],
            [knee_r, knee_r * 1.10],
            [knee_r * 0.86, knee_r * 0.94],
            [knee_r * 0.66, knee_r * 0.72],
            [knee_r * 0.46, knee_r * 0.50],
            [claw_r, claw_r],
        ]
        v, f = tube_solid(leg_spine, leg_radii, segs=7, start_cap_push=0.016, end_cap_push=0.018,
                          label=f"{lname}_limb")
        if lname == "leg_rf":
            min_y = float(v[:, 1].min())
            if min_y != 0.0:
                claw_w = 1.0 - smoothstep(0.0, 0.16, v[:, 1] - min_y)
                v[:, 1] -= min_y * claw_w
                v[:, 1] = np.maximum(v[:, 1], 0.0)
            verify_manifold(v, f, f"{lname}_limb_grounded")

        leg_y_lo = float(v[:, 1].min())
        leg_y_hi = max(float(v[:, 1].max()), leg_y_lo + 0.08)
        tip_dark = 1.0 - smoothstep(leg_y_lo, leg_y_lo + 0.42 * (leg_y_hi - leg_y_lo), v[:, 1])
        knee_hi = np.exp(-((v[:, 1] - knee_apex[1]) ** 2) * 18.0)
        l_col = (
            np.tile(np.array([0.138, 0.062, 0.044]), (len(v), 1))
            + knee_hi[:, None] * np.array([0.050, 0.026, 0.016])
        )
        l_col = l_col * (1.0 - tip_dark[:, None]) + np.array([0.028, 0.013, 0.011]) * tip_dark[:, None]
        mb.add("flesh_leg", v, f, np.array([limb_id, 1.0]), l_col)

        # 4d. Armored Chitin Femur/Knee Guard with Swept Dorsal Spur (chitin_spitter, tier-colored!)
        f_dir = knee_apex - joint
        f_len = max(np.linalg.norm(f_dir), 1e-6)
        f_dir = f_dir / f_len
        spur_tip_x = side * min(abs(knee_apex[0]) + 0.042, 0.825)
        guard_spine = [
            0.28 * joint + 0.72 * femur_mid + np.array([0.0, 0.044, 0.0]),
            knee_apex + np.array([side * 0.008, 0.042, 0.0]),
            np.array([spur_tip_x, knee_apex[1] + 0.072, knee_apex[2] + f_dir[2] * 0.038]),
        ]
        guard_rad = [[0.032, 0.024], [0.040, 0.030], [0.009, 0.009]]
        v, f = tube_solid(guard_spine, guard_rad, segs=6, start_cap_push=0.016, end_cap_push=0.020,
                          oval_bias=True, label=f"{lname}_kneeguard")
        kt = smoothstep(guard_spine[0][1] - 0.03, guard_spine[-1][1] + 0.03, v[:, 1])
        mb.add("chitin_spitter", v, f, np.array([limb_id, 1.0]),
               paint_chitin_mask(v, guard_spine[0][1] - 0.03, guard_spine[-1][1] + 0.03, is_spine=True, tip_t=kt))

    merged = mb.merged()
    # Final global grounding guard: ensure exact lo.y == 0.0000 across all primitives
    global_min_y = min(float(v[:, 1].min()) for _, v, _, _, _ in merged)
    if abs(global_min_y) > 1e-9:
        grounded = []
        for mat, v, f, uv, c in merged:
            v2 = v.copy()
            v2[:, 1] -= global_min_y
            grounded.append((mat, v2, f, uv, c))
        merged = grounded
    return merged


# ---------------------------------------------------------------------------------------------
# Posing (matches factorio_material.gdshaderinc + creatures.gd _posed_body 1:1)

def pose_groups(base_groups, rig, pose_entry):
    """Apply creature_poses.json leg angles & body transform, keeping 100% watertight geometry."""
    limbs = rig["limbs"]
    legs_angles = pose_entry.get("legs", [])
    at = np.asarray(pose_entry["at"], dtype=np.float64)
    to = np.asarray(pose_entry["to"], dtype=np.float64)
    rot_m = quat_to_matrix(pose_entry["turn"])
    scale = float(pose_entry.get("scale", 1.0))

    posed_verts = []
    min_y = math.inf
    for _mat, v, _f, uv, _c in base_groups:
        p = v.copy()
        limb_idx = np.round(uv[:, 0]).astype(int) - 1
        w = uv[:, 1]
        for i, l in enumerate(limbs):
            if i >= len(legs_angles):
                continue
            sw, li, kn = [float(a) for a in legs_angles[i]]
            sel = (limb_idx == i) & (w > 0.0)
            if not sel.any() or (sw == 0.0 and li == 0.0 and kn == 0.0):
                continue
            j = np.asarray(l["joint"], dtype=np.float64)
            q = p[sel] - j
            reach = float(l.get("reach", 0.0))
            if reach > 0.0 and kn != 0.0:
                k = np.asarray(l["knee"], dtype=np.float64) - j
                d = np.linalg.norm(q, axis=1)
                fold = kn * smoothstep(0.45 * reach, 0.57 * reach, d)
                q = k + rodrigues(q - k, l["lift"], fold)
            q = rodrigues(q, l["lift"], li * w[sel])
            q = rodrigues(q, l["swing"], sw * w[sel])
            p[sel] = j + q
        p = ((p - at) @ rot_m.T) * scale + to
        min_y = min(min_y, float(p[:, 1].min()))
        posed_verts.append(p)

    out = []
    for (mat, _v, f, _uv, c), p in zip(base_groups, posed_verts):
        p = p.copy()
        p[:, 1] -= min_y
        verify_manifold(p, f, f"posed:{mat}")
        uv_planar = p[:, [0, 2]].copy()
        out.append((mat, p, f, uv_planar, c))
    return out


# ---------------------------------------------------------------------------------------------
# Baking & glTF 2.0 binary writer

def bake_model_attributes(groups):
    """Run tools/models/bake.py over all primitives jointly so parts occlude each other."""
    normals = [compute_smooth_normals(v, f) for _, v, f, _, _ in groups]
    tris = np.concatenate([v[f] for _, v, f, _, _ in groups], axis=0)
    nrms = np.concatenate([n[f] for (_, _, f, _, _), n in zip(groups, normals)], axis=0)
    sides = np.linalg.norm(tris - np.roll(tris, 1, axis=1), axis=2).max(axis=1)
    area = 0.5 * np.linalg.norm(np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0]), axis=1)
    ao, edge, part, vis = bake.bake(tris, nrms, up=1, width=area / np.maximum(sides, 1e-9),
                                    views=bake.factorio_views(up=1))
    out, t0 = [], 0
    for (_, v, f, uv0, part_rgb), nrm in zip(groups, normals):
        nf = len(f)
        nv = len(v)
        count = np.zeros(nv, dtype=np.float64)
        np.add.at(count, f.reshape(-1), 1.0)
        count = np.maximum(count, 1.0)[:, None]

        def avg_v(vals):
            acc = np.zeros((nv, vals.shape[2]), dtype=np.float64)
            np.add.at(acc, f.reshape(-1), vals.reshape(-1, vals.shape[2]))
            return acc / count

        a = avg_v(ao[t0:t0 + nf, :, None])
        a = np.clip(0.22 + 0.78 * a, 0.0, 1.0)
        e = avg_v(edge[t0:t0 + nf, :, None])
        pt = avg_v(np.repeat(part[t0:t0 + nf, None, None], 3, axis=1))
        vs = avg_v(vis[t0:t0 + nf])
        t0 += nf

        rgb = np.clip(part_rgb, 0.0, PART_RANGE) / PART_RANGE
        rgb /= np.maximum(rgb.max(axis=1), 1.0)[:, None]
        uv4 = np.clip(rgb[:, 0:2], 0.0, 1.0)
        uv5 = np.column_stack([np.clip(rgb[:, 2], 0.0, 1.0), np.full(nv, PART_SHARE, dtype=np.float64)])

        out.append({
            "NORMAL": nrm,
            "COLOR_0": np.hstack([np.ones((nv, 3), dtype=np.float64), a]),
            "TEXCOORD_0": uv0,
            "TEXCOORD_1": np.hstack([e, pt]),
            "TEXCOORD_2": vs[:, 0:2],
            "TEXCOORD_3": vs[:, 2:4],
            "TEXCOORD_4": uv4,
            "TEXCOORD_5": uv5,
        })
    return out


def write_glb(path, groups):
    """Write a glTF 2.0 binary (.glb) matching wube3dp/big-spitter.glb's exact layout."""
    mat_lookup = {name: (hex_col, rough, metal) for name, hex_col, rough, metal in MATERIALS}
    baked = bake_model_attributes(groups)

    bin_chunk = bytearray()
    buffer_views, accessors, primitives, materials = [], [], [], []

    def add_view(data, target):
        while len(bin_chunk) % 4:
            bin_chunk.append(0)
        buffer_views.append({
            "buffer": 0,
            "byteOffset": len(bin_chunk),
            "byteLength": len(data),
            "target": target,
        })
        bin_chunk.extend(data)
        return len(buffer_views) - 1

    for (mat_name, v, f, _uv0, _prgb), attrs_data in zip(groups, baked):
        pos = np.ascontiguousarray(v, dtype=np.float32)
        nrm = np.ascontiguousarray(attrs_data["NORMAL"], dtype=np.float32)
        idx = np.ascontiguousarray(f.reshape(-1))
        idx = idx.astype(np.uint16 if len(pos) < 65536 else np.uint32)

        pv = add_view(pos.tobytes(), 34962)
        accessors.append({
            "bufferView": pv,
            "componentType": 5126,
            "count": len(pos),
            "type": "VEC3",
            "min": [float(x) for x in pos.min(axis=0)],
            "max": [float(x) for x in pos.max(axis=0)],
        })
        pa = len(accessors) - 1

        nv = add_view(nrm.tobytes(), 34962)
        accessors.append({
            "bufferView": nv,
            "componentType": 5126,
            "count": len(nrm),
            "type": "VEC3",
        })
        na = len(accessors) - 1

        iv = add_view(idx.tobytes(), 34963)
        accessors.append({
            "bufferView": iv,
            "componentType": 5123 if idx.dtype == np.uint16 else 5125,
            "count": len(idx),
            "type": "SCALAR",
        })
        ia = len(accessors) - 1

        hex_col, rough, metal = mat_lookup[mat_name]
        materials.append({
            "name": mat_name,
            "pbrMetallicRoughness": {
                "baseColorFactor": srgb_hex_to_linear(hex_col) + [1.0],
                "metallicFactor": metal,
                "roughnessFactor": rough,
            },
        })

        prim_attrs = {"POSITION": pa, "NORMAL": na}
        for key in ("COLOR_0", "TEXCOORD_0", "TEXCOORD_1", "TEXCOORD_2", "TEXCOORD_3"):
            arr = np.ascontiguousarray(attrs_data[key], dtype=np.float32)
            view = add_view(arr.tobytes(), 34962)
            accessors.append({
                "bufferView": view,
                "componentType": 5126,
                "count": len(arr),
                "type": f"VEC{arr.shape[1]}",
            })
            prim_attrs[key] = len(accessors) - 1

        for key in ("TEXCOORD_4", "TEXCOORD_5"):
            arr = np.ascontiguousarray(np.round(np.clip(attrs_data[key], 0.0, 1.0) * 65535.0), dtype=np.uint16)
            view = add_view(arr.tobytes(), 34962)
            accessors.append({
                "bufferView": view,
                "componentType": 5123,
                "normalized": True,
                "count": len(arr),
                "type": "VEC2",
            })
            prim_attrs[key] = len(accessors) - 1

        primitives.append({
            "attributes": prim_attrs,
            "indices": ia,
            "material": len(materials) - 1,
            "mode": 4,
        })

    while len(bin_chunk) % 4:
        bin_chunk.append(0)

    doc = {
        "asset": {"version": "2.0", "generator": GENERATOR, "copyright": COPYRIGHT},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"name": "body", "mesh": 0}],
        "meshes": [{"name": "body", "primitives": primitives}],
        "materials": materials,
        "accessors": accessors,
        "bufferViews": buffer_views,
        "buffers": [{"byteLength": len(bin_chunk)}],
    }
    js = json.dumps(doc, separators=(",", ":")).encode("utf-8")
    js += b" " * (-len(js) % 4)

    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    header = struct.pack("<4sII", b"glTF", 2, 12 + 8 + len(js) + 8 + len(bin_chunk))
    with open(path, "wb") as fp:
        fp.write(header)
        fp.write(struct.pack("<I4s", len(js), b"JSON") + js)
        fp.write(struct.pack("<I4s", len(bin_chunk), b"BIN\0") + bytes(bin_chunk))


# ---------------------------------------------------------------------------------------------
# Software multi-angle & tier preview renderer (PIL + numpy, for visual QA)

def render_preview(groups, out_path, skins, tier="big-spitter", size=320):
    from PIL import Image

    t1, t2 = skins["big-spitter"]["tiers"][tier]
    t1_rgb = np.array(t1[:3], dtype=np.float64)
    t2_rgb = np.array(t2[:3], dtype=np.float64)
    a2 = float(t2[3])

    all_tris, all_cols, all_nrms = [], [], []
    for mat, v, f, _uv, c in groups:
        nrm = compute_smooth_normals(v, f)
        tri_v = v[f]
        tri_c = c[f].mean(axis=1)
        tri_n = nrm[f].mean(axis=1)
        tri_n /= np.maximum(np.linalg.norm(tri_n, axis=1, keepdims=True), 1e-9)
        if mat == "chitin_spitter":
            a = np.clip(tri_c[:, 2] * a2, 0.0, 1.0)[:, None]
            rgb = tri_c[:, 0:1] * t1_rgb * (1.0 - a) + tri_c[:, 1:2] * t2_rgb * a
        else:
            rgb = tri_c
        all_tris.append(tri_v)
        all_cols.append(rgb)
        all_nrms.append(tri_n)
    tris = np.concatenate(all_tris, axis=0)
    cols = np.concatenate(all_cols, axis=0)
    nrms = np.concatenate(all_nrms, axis=0)
    center = 0.5 * (tris.reshape(-1, 3).min(axis=0) + tris.reshape(-1, 3).max(axis=0))
    span = float(np.linalg.norm(tris.reshape(-1, 3).max(axis=0) - tris.reshape(-1, 3).min(axis=0))) * 0.58

    views = [
        ("iso_front", np.array([0.75, 0.60, -0.85])),
        ("side", np.array([1.0, 0.18, 0.0])),
        ("top", np.array([0.0, 1.0, 0.12])),
        ("iso_back", np.array([-0.75, 0.50, 0.85])),
        ("under", np.array([0.45, -0.85, -0.45])),
    ]
    light_dir = np.array([0.4, 0.8, -0.45])
    light_dir /= np.linalg.norm(light_dir)

    tiles = []
    for _vname, eye in views:
        fwd = -eye / np.linalg.norm(eye)
        up_ref = np.array([0.0, 1.0, 0.0]) if abs(fwd[1]) < 0.95 else np.array([0.0, 0.0, -1.0])
        right = np.cross(fwd, up_ref)
        right /= np.linalg.norm(right)
        up = np.cross(right, fwd)

        rel = tris - center
        px = np.einsum("ijk,k->ij", rel, right) / span
        py = np.einsum("ijk,k->ij", rel, up) / span
        pz = np.einsum("ijk,k->ij", rel, fwd)

        sx = (px * 0.45 + 0.5) * size
        sy = (0.5 - py * 0.45) * size

        img = np.full((size, size, 3), 0.16, dtype=np.float64)
        zbuf = np.full((size, size), np.inf, dtype=np.float64)
        key = np.maximum(0.0, nrms @ light_dir)
        fill = np.maximum(0.0, nrms @ (-light_dir * 0.6 + np.array([0.0, -0.5, 0.0])))
        shade = 0.28 + 1.05 * key + 0.35 * fill
        lit = linear_to_srgb(cols * shade[:, None] * 1.45)

        order = np.argsort(pz.mean(axis=1))
        for ti in order:
            x0, x1, x2 = sx[ti]
            y0, y1, y2 = sy[ti]
            area2 = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
            if area2 >= -1e-5:
                continue
            ix0 = max(0, int(math.floor(min(x0, x1, x2))))
            ix1 = min(size - 1, int(math.ceil(max(x0, x1, x2))))
            iy0 = max(0, int(math.floor(min(y0, y1, y2))))
            iy1 = min(size - 1, int(math.ceil(max(y0, y1, y2))))
            if ix1 < ix0 or iy1 < iy0:
                continue
            xs = np.arange(ix0, ix1 + 1, dtype=np.float64) + 0.5
            ys = np.arange(iy0, iy1 + 1, dtype=np.float64) + 0.5
            gx, gy = np.meshgrid(xs, ys)
            w0 = ((x1 - gx) * (y2 - gy) - (x2 - gx) * (y1 - gy)) / area2
            w1 = ((x2 - gx) * (y0 - gy) - (x0 - gx) * (y2 - gy)) / area2
            w2 = 1.0 - w0 - w1
            inside = (w0 >= 0.0) & (w1 >= 0.0) & (w2 >= 0.0)
            if not inside.any():
                continue
            zval = w0 * pz[ti, 0] + w1 * pz[ti, 1] + w2 * pz[ti, 2]
            sub_z = zbuf[iy0:iy1 + 1, ix0:ix1 + 1]
            hit = inside & (zval < sub_z)
            if hit.any():
                sub_z[hit] = zval[hit]
                img[iy0:iy1 + 1, ix0:ix1 + 1][hit] = lit[ti]
        tiles.append(img)
    strip = np.concatenate(tiles, axis=1)
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    Image.fromarray((np.clip(strip, 0.0, 1.0) * 255.0).astype(np.uint8)).save(out_path)


# ---------------------------------------------------------------------------------------------
# CLI entry point

def main(argv=None):
    ap = argparse.ArgumentParser(description="Generate watertight Placeholders big-spitter models.")
    ap.add_argument("--out", default=PLACEHOLDERS_DIR, help="Output folder (default: placeholders pack)")
    ap.add_argument("--preview", default=None, help="Optional folder to save visual QA preview PNGs")
    args = ap.parse_args(argv)

    with open(RIGS_JSON, encoding="utf-8") as fp:
        rig = json.load(fp)["big-spitter"]
    with open(POSES_JSON, encoding="utf-8") as fp:
        poses = json.load(fp)

    base_groups = build_big_spitter(rig)
    base_path = os.path.join(args.out, "big-spitter.glb")
    write_glb(base_path, base_groups)
    all_v = np.vstack([v for _, v, _, _, _ in base_groups])
    tris = sum(len(f) for _, _, f, _, _ in base_groups)
    lo, hi = all_v.min(axis=0), all_v.max(axis=0)
    print(f"wrote big-spitter.glb          {tris:5d} tris  size=({hi[0]-lo[0]:.2f}, {hi[1]-lo[1]:.2f}, {hi[2]-lo[2]:.2f})  lo.y={lo[1]:.4f}")

    posed_map = {"big-spitter": base_groups}
    for pname in POSE_NAMES:
        pg = pose_groups(base_groups, rig, poses[pname])
        out_path = os.path.join(args.out, f"{pname}.glb")
        write_glb(out_path, pg)
        pv = np.vstack([v for _, v, _, _, _ in pg])
        ptris = sum(len(f) for _, _, f, _, _ in pg)
        plo, phi = pv.min(axis=0), pv.max(axis=0)
        print(f"wrote {pname + '.glb':24s} {ptris:5d} tris  size=({phi[0]-plo[0]:.2f}, {phi[1]-plo[1]:.2f}, {phi[2]-plo[2]:.2f})  lo.y={plo[1]:.4f}")
        posed_map[pname] = pg

    if args.preview:
        with open(SKINS_JSON, encoding="utf-8") as fp:
            skins = json.load(fp)
        for tier in ("small-spitter", "medium-spitter", "big-spitter", "behemoth-spitter"):
            render_preview(base_groups, os.path.join(args.preview, f"{tier}.png"), skins, tier=tier)
        for pname in ("big-spitter-attack", "big-spitter-corpse", "big-spitter-corpse-1"):
            render_preview(posed_map[pname], os.path.join(args.preview, f"{pname}.png"), skins, tier="big-spitter")
        print(f"wrote preview PNGs to {args.preview}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
