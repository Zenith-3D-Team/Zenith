#!/usr/bin/env python3
"""Procedural watertight biter-spawner & corpse generator for the Placeholders pack.

    python tools/models/spawner.py                # generate biter-spawner.glb + corpse
    python tools/models/spawner.py --out DIR      # write into a custom folder
    python tools/models/spawner.py --preview DIR  # render multi-angle & tier preview PNGs

Builds 100% closed, watertight, manifold Factorio-faithful alien hive spawners (`0` open edges,
outward-facing normals, positive volume on every primitive) directly in plain Python + numpy +
PIL (no Blender dependency).

Matches `wube3dp/biter-spawner*.glb` footprint (~6.4 x 1.8 x 5.8 live, ~6.4 x 0.75 x 5.8 corpse,
grounded cleanly at `lo.y == 0.0000`), materials (`stone_spawner_dirt`, `flesh_spawner`,
`flesh_spawner_dome`, `flesh_spawner_hollow`), pulsing dome rig (`creature_rigs.json["biter-spawner"]`
`sac_dome`: `UV.x = 1, UV.y = 1.0` on `flesh_spawner_dome`), and `skin_mode 2` tier tinting
(`creature_skins.json` / `creature_models.gd` so `spitter-spawner` tints the dome web crimson
while preserving pale cream egg-sac blisters).
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
SKINS_JSON = os.path.join(REPO, "client", "data", "creature_skins.json")

LIVE_NAME = "biter-spawner"
CORPSE_NAME = "biter-spawner-corpse"
GENERATOR = "Zenith tools/models/spawner.py"
COPYRIGHT = "Zenith contributors (GPL-3.0)"

PART_RANGE = 4.0
PART_SHARE = 0.25

# Exact PBR factors matching wube_recipes.py EXTRA_MATERIALS (sRGB hex converted to linear).
MATERIALS = (
    ("stone_spawner_dirt", "5e4a36", 0.95, 0.00),
    ("flesh_spawner", "a9705e", 0.70, 0.00),
    ("flesh_spawner_dome", "c79a8e", 0.55, 0.00),
    ("flesh_spawner_hollow", "5a3350", 0.35, 0.00),
)

# Shared base semi-axes so the full root/dirt footprint lands cleanly at ~6.4 x 5.7 tiles
FOOT_RX = 2.74
FOOT_RZ = 2.70

# 5 massive asymmetric curved anchor-claw buttress roots dominating the outer silhouette:
# (angle_deg, reach_scale, curve_deg, thick_scale)
CLAW_ROOTS = (
    (-148.0, 1.03, -20.0, 1.12),  # SW-W heavy sweeping claw
    (-76.0, 0.98, +16.0, 1.04),   # S-SW broad anchor claw
    (+10.0, 1.02, -18.0, 1.10),   # E-SE sweeping horn root
    (+82.0, 0.96, +16.0, 1.02),   # N-NE anchor root
    (+150.0, 1.01, +22.0, 1.08),  # NW curving rear claw
)

# 16 dense radial bulbous root-lobes / anchor tentacles packed around the full perimeter:
# (angle_deg, reach_scale, rad_scale, curve_deg)
LOBE_ROOTS = (
    (-176.0, 0.91, 1.05, +9.0),
    (-162.0, 0.87, 0.94, -6.0),
    (-128.0, 0.92, 1.12, -8.0),
    (-112.0, 0.90, 1.02, +6.0),
    (-94.0, 0.88, 0.98, -5.0),
    (-56.0, 0.93, 1.10, -8.0),
    (-38.0, 0.90, 1.04, +5.0),
    (-20.0, 0.91, 1.06, -6.0),
    (-4.0, 0.87, 0.94, +4.0),
    (+30.0, 0.92, 1.08, +8.0),
    (+48.0, 0.89, 1.00, -7.0),
    (+64.0, 0.88, 0.96, +5.0),
    (+102.0, 0.92, 1.08, -7.0),
    (+118.0, 0.90, 1.02, +6.0),
    (+134.0, 0.87, 0.95, -5.0),
    (+168.0, 0.92, 1.06, +7.0),
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
    a = np.asarray(axis, dtype=np.float64)
    n = np.linalg.norm(a)
    if n < 1e-12:
        return pts.copy()
    a = a / n
    ang = np.asarray(angles, dtype=np.float64)
    c, s = np.cos(ang), np.sin(ang)
    if pts.ndim == 1:
        return pts * c + np.cross(a, pts) * s + a * np.dot(a, pts) * (1.0 - c)
    if c.ndim == 0:
        return pts * c + np.cross(a, pts) * s + np.outer(pts @ a, a) * (1.0 - c)
    return pts * c[:, None] + np.cross(a, pts) * s[:, None] + np.outer(pts @ a, a) * (1.0 - c)[:, None]


def perim_warp(theta):
    """Deterministic organic irregular perimeter radius factor around 1.0."""
    return (
        1.0
        + 0.042 * np.cos(2.0 * theta - 0.4)
        + 0.032 * np.sin(3.0 * theta + 0.8)
        + 0.024 * np.cos(5.0 * theta - 1.1)
        + 0.016 * np.sin(7.0 * theta + 0.3)
    )


def organic_noise(pts):
    """Smooth deterministic 3D biological surface mottling in [0, 1]."""
    p = np.asarray(pts, dtype=np.float64)
    v = (
        0.45 * np.sin(p[:, 0] * 2.7 + p[:, 2] * 2.1 + 0.4) * np.cos(p[:, 1] * 3.1 - p[:, 2] * 1.9)
        + 0.32 * np.sin(p[:, 0] * 5.9 - p[:, 2] * 4.8 + p[:, 1] * 4.2 + 1.3)
        + 0.23 * np.cos(p[:, 0] * 9.3 + p[:, 2] * 8.7 - p[:, 1] * 6.5 + 2.6)
    )
    return np.clip(0.5 + 0.5 * v, 0.0, 1.0)


def frame_from_normal(normal):
    n = np.asarray(normal, dtype=np.float64)
    n /= max(np.linalg.norm(n), 1e-12)
    ref = np.array([1.0, 0.0, 0.0]) if abs(n[0]) < 0.85 else np.array([0.0, 0.0, 1.0])
    u = np.cross(ref, n)
    u /= max(np.linalg.norm(u), 1e-12)
    v = np.cross(n, u)
    return u, v, n


# ---------------------------------------------------------------------------------------------
# Watertight solid geometry builders

def signed_volume(verts, faces):
    v0 = verts[faces[:, 0]]
    v1 = verts[faces[:, 1]]
    v2 = verts[faces[:, 2]]
    return float(np.einsum("ij,ij->i", v0, np.cross(v1, v2)).sum() / 6.0)


def verify_manifold(verts, faces, label="piece"):
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
    v = np.asarray(verts, dtype=np.float64)
    f = np.asarray(faces, dtype=np.int64)
    fn = np.cross(v[f[:, 1]] - v[f[:, 0]], v[f[:, 2]] - v[f[:, 0]])
    n = np.zeros_like(v)
    for k in range(3):
        np.add.at(n, f[:, k], fn)
    lens = np.linalg.norm(n, axis=1, keepdims=True)
    return n / np.maximum(lens, 1e-12)


def loft_solid(rings, start_center=None, end_center=None, label="loft"):
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


def bishop_frames(pts):
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
    us, vs = [u0], [v0]
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
               oval_bias=False, rib_amp=0.0, rib_freq=0.0, ground_floor=None, label="tube"):
    p = np.asarray(spine, dtype=np.float64)
    rad = np.asarray(radii, dtype=np.float64)
    if rad.ndim == 1:
        rad = np.column_stack([rad, rad])
    tangents, us, vs = bishop_frames(p)
    rings = []
    angles = np.linspace(0.0, 2.0 * math.pi, segs, endpoint=False)
    ca, sa = np.cos(angles), np.sin(angles)
    m = len(p)
    for k in range(m):
        s_t = k / max(m - 1, 1)
        rib = 1.0 + rib_amp * math.sin(s_t * rib_freq * 2.0 * math.pi)
        ru, rv = rad[k, 0] * rib, rad[k, 1] * rib
        if oval_bias:
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
    v, f = loft_solid(rings, start_center=sc, end_center=ec, label=label + "_raw")
    if ground_floor is not None:
        lo_y = float(v[:, 1].min())
        if lo_y < ground_floor:
            v[:, 1] = np.where(
                v[:, 1] < ground_floor + 0.08,
                ground_floor + np.maximum(v[:, 1] - lo_y, 0.0) * (0.08 / max(ground_floor + 0.08 - lo_y, 1e-6)),
                v[:, 1],
            )
            v, f = ensure_outward(v, f)
            verify_manifold(v, f, label)
    return v, f


def ellipsoid_solid(center, radii, rings=4, segs=10, rot=None, deform_fn=None, label="ellipsoid"):
    c = np.asarray(center, dtype=np.float64)
    rx, ry, rz = [float(r) for r in radii]
    ring_list = []
    for k in range(1, rings):
        phi = math.pi * k / rings - 0.5 * math.pi
        cp, sp = math.cos(phi), math.sin(phi)
        pts = [[rx * cp * math.cos(2.0 * math.pi * i / segs),
                ry * sp,
                rz * cp * math.sin(2.0 * math.pi * i / segs)] for i in range(segs)]
        ring_list.append(np.asarray(pts, dtype=np.float64))
    south = np.array([0.0, -ry, 0.0], dtype=np.float64)
    north = np.array([0.0, ry, 0.0], dtype=np.float64)
    if rot is not None:
        rm = np.asarray(rot, dtype=np.float64)
        ring_list = [r @ rm.T for r in ring_list]
        south = south @ rm.T
        north = north @ rm.T
    ring_list = [r + c for r in ring_list]
    v, f = loft_solid(ring_list, start_center=south + c, end_center=north + c, label=label + "_raw")
    if deform_fn is not None:
        v = deform_fn(v)
        v, f = ensure_outward(v, f)
        verify_manifold(v, f, label)
    return v, f


def curved_wall_solid(th_center, half_arc_rad, r_base_fn, y_bot, y_top_fn, thickness=0.24,
                      lean_out=0.0, rib_count=3.0, az_steps=11, label="wall"):
    """Watertight thick curved organic hive-collar or torn corpse-flap wall segment."""
    alphas = np.linspace(-1.0, 1.0, az_steps)
    sec_s = np.array([0.0, 0.28, 0.70, 0.95, 1.0, 0.78, 0.36, 0.0], dtype=np.float64)
    rings = []
    for a in alphas:
        aa = abs(a)
        th = th_center + a * half_arc_rad
        r0 = float(r_base_fn(th))
        yt = float(y_top_fn(a, th))
        taper = 1.0 - 0.32 * (aa ** 2.4)
        flute = 0.062 * math.cos(a * math.pi * rib_count) * taper
        thk = thickness * taper
        r_offs = np.array([
            0.04 * taper,
            0.10 * taper + flute,
            0.07 * taper + flute * 0.9 + lean_out * 0.65,
            0.01 + lean_out,
            -thk * 0.45 + lean_out * 0.85,
            -thk + lean_out * 0.45,
            -thk * 0.95,
            -thk * 0.75,
        ], dtype=np.float64)
        pts = []
        for si, s in enumerate(sec_s):
            y = y_bot + s * (yt - y_bot)
            r = r0 + r_offs[si]
            pts.append([r * math.cos(th), y, r * math.sin(th)])
        rings.append(np.asarray(pts, dtype=np.float64))

    def end_cap(sign):
        th = th_center + sign * (half_arc_rad + 0.03)
        r0 = float(r_base_fn(th)) - thickness * 0.25 + lean_out * 0.25
        yt = float(y_top_fn(sign, th))
        ym = 0.5 * (y_bot + yt)
        return np.array([r0 * math.cos(th), ym, r0 * math.sin(th)], dtype=np.float64)

    return loft_solid(rings, start_center=end_cap(-1.0), end_center=end_cap(1.0), label=label)


# ---------------------------------------------------------------------------------------------
# Mesh accumulator by material

class MeshBuilder:
    def __init__(self, mat_names):
        self.mat_names = tuple(mat_names)
        self.groups = {name: [] for name in self.mat_names}

    def add(self, material, verts, faces, part_rgb, uv0=None, color_rgb=None):
        v = np.asarray(verts, dtype=np.float64)
        f = np.asarray(faces, dtype=np.int64)
        prgb = np.asarray(part_rgb, dtype=np.float64)
        if prgb.ndim == 1:
            prgb = np.tile(prgb, (len(v), 1))
        if uv0 is None:
            uv = v[:, [0, 2]].copy()
        else:
            uv = np.asarray(uv0, dtype=np.float64)
            if uv.ndim == 1:
                uv = np.tile(uv, (len(v), 1))
        if color_rgb is None:
            crgb = np.ones((len(v), 3), dtype=np.float64)
        else:
            crgb = np.asarray(color_rgb, dtype=np.float64)
            if crgb.ndim == 1:
                crgb = np.tile(crgb, (len(v), 1))
        self.groups[material].append((v, f, uv, prgb, crgb))

    def merged(self):
        out = []
        for name in self.mat_names:
            pieces = self.groups[name]
            if not pieces:
                continue
            v_list, f_list, uv_list, p_list, c_list = [], [], [], [], []
            offset = 0
            for v, f, uv, prgb, crgb in pieces:
                v_list.append(v)
                f_list.append(f + offset)
                uv_list.append(uv)
                p_list.append(prgb)
                c_list.append(crgb)
                offset += len(v)
            V = np.vstack(v_list)
            F = np.vstack(f_list)
            UV = np.vstack(uv_list)
            P = np.vstack(p_list)
            C = np.vstack(c_list)
            verify_manifold(V, F, f"material:{name}")
            out.append((name, V, F, UV, P, C))
        return out


# ---------------------------------------------------------------------------------------------
# Shared dirt crater base & radial root system helpers

def add_dirt_base(mb, corpse=False, uv_static=None):
    """Add tight scalloped terraced rocky/dirt crater base + upturned soil clods (lo.y = 0.0).

    Hugs closely beneath the radiating claws and fleshy anchor-lobes (total footprint ~6.4 x 5.8)
    so the roots & claws dominate the silhouette just like Factorio's spawner sprites!
    """
    segs = 48
    th = np.linspace(0.0, 2.0 * math.pi, segs, endpoint=False)
    pw = perim_warp(th)
    ct, st = np.cos(th), np.sin(th)
    # Localized crusty upturned earth collars hugging right around the 5 big claw tips
    claw_bulge = np.zeros(segs, dtype=np.float64)
    for ang_deg, lscale, cdeg, _ in CLAW_ROOTS:
        tip_ang = math.radians(ang_deg + cdeg * 0.78)
        da = np.arctan2(np.sin(th - tip_ang), np.cos(th - tip_ang))
        claw_bulge += 0.13 * lscale * np.exp(-((da / 0.22) ** 2))

    if corpse:
        ring_spec = [
            (0.16, 0.045, 0.008),
            (0.42, 0.065, 0.012),
            (0.66, 0.160, 0.025),
            (0.82, 0.165, 0.032),
            (0.93, 0.095, 0.024),
            (0.98, 0.035, 0.012),
            (1.00, 0.000, 0.000),  # flush ground contact at y = 0.0000
            (0.72, 0.000, 0.000),  # solid flat underside
        ]
        top_y = 0.042
    else:
        ring_spec = [
            (0.16, 0.110, 0.010),
            (0.45, 0.150, 0.018),
            (0.68, 0.240, 0.032),  # raised earth collar beneath fleshy walls
            (0.83, 0.195, 0.036),  # terraced soil step beneath root-lobes
            (0.93, 0.110, 0.026),  # upturned outer dirt berm
            (0.98, 0.040, 0.014),  # crusty rim edge
            (1.00, 0.000, 0.000),  # flush ground contact at y = 0.0000
            (0.72, 0.000, 0.000),  # solid flat underside
        ]
        top_y = 0.105

    rings = []
    for r_frac, yb, lamp in ring_spec:
        lump = lamp * (0.5 + 0.5 * np.sin(th * 7.0 + r_frac * 9.0) * np.cos(th * 4.0 - 0.6))
        y = np.full(segs, yb, dtype=np.float64) if yb == 0.0 else np.maximum(yb + lump, 0.012)
        scale_r = pw + claw_bulge * smoothstep(0.50, 0.95, r_frac)
        rx = FOOT_RX * r_frac * scale_r
        rz = FOOT_RZ * r_frac * scale_r
        rings.append(np.column_stack([rx * ct, y, rz * st]))

    v, f = loft_solid(rings, start_center=[0.0, top_y, 0.0], end_center=[0.0, 0.0, 0.0], label="dirt_mound")
    n = organic_noise(v)
    ht = smoothstep(0.0, 0.24 if not corpse else 0.17, v[:, 1])
    d_dark = np.array([0.040, 0.023, 0.014])
    d_mid = np.array([0.102, 0.060, 0.032])
    d_hi = np.array([0.158, 0.098, 0.054])
    col = d_dark[None, :] * (1.0 - ht[:, None]) + d_mid[None, :] * ht[:, None]
    col = col * (0.76 + 0.44 * n[:, None]) + d_hi[None, :] * (ht * n * 0.24)[:, None]
    if corpse:
        col *= np.array([0.84, 0.79, 0.82])[None, :]
    mb.add("stone_spawner_dirt", v, f, col, uv0=uv_static)

    # Crusty upturned soil berms & rocky clods right at the 5 anchor-claw tips & between lobes
    clod_specs = []
    for ang_deg, lscale, cdeg, _ in CLAW_ROOTS:
        tip_deg = ang_deg + cdeg * 0.85
        clod_specs.append((tip_deg - 6.0, 0.98 * lscale, 0.24, 0.14))
        clod_specs.append((tip_deg + 7.0, 0.96 * lscale, 0.21, 0.12))
    for extra_deg in (-114.0, -40.0, +46.0, +116.0):
        clod_specs.append((extra_deg, 0.93, 0.22, 0.13))

    for ci, (adeg, rf, rx_c, ry_c) in enumerate(clod_specs):
        ang = math.radians(adeg)
        w = float(perim_warp(ang))
        cx = FOOT_RX * rf * w * math.cos(ang)
        cz = FOOT_RZ * rf * w * math.sin(ang)
        ry_eff = ry_c * (0.78 if corpse else 1.0)
        rz_c = rx_c * 0.88
        ca, sa = math.cos(ang), math.sin(ang)
        rot = np.array([[ca, 0.0, -sa], [0.0, 1.0, 0.0], [sa, 0.0, ca]], dtype=np.float64)

        def clod_deform(pts, seed=ci):
            p = pts.copy()
            p[:, 0] += 0.025 * np.sin(p[:, 2] * 8.0 + seed)
            p[:, 2] += 0.025 * np.cos(p[:, 0] * 8.0 - seed)
            lo = float(p[:, 1].min())
            if lo < 0.002:
                p[:, 1] -= (lo - 0.002)
            return p

        vc, fc = ellipsoid_solid([cx, ry_eff * 0.68, cz], [rx_c, ry_eff, rz_c], rings=4, segs=7,
                                 rot=rot, deform_fn=clod_deform, label=f"dirt_clod_{ci}")
        nc = organic_noise(vc)
        hc = smoothstep(0.0, 0.22, vc[:, 1])
        c_col = (d_dark[None, :] * (1.0 - hc[:, None]) + d_hi[None, :] * hc[:, None]) * (0.74 + 0.45 * nc[:, None])
        if corpse:
            c_col *= np.array([0.84, 0.79, 0.82])[None, :]
        mb.add("stone_spawner_dirt", vc, fc, c_col, uv0=uv_static)


def add_radial_roots(mb, corpse=False, uv_static=None):
    """Add 5 massive curved anchor-claw buttress roots + 16 dense bulbous fleshy root-lobes."""
    y_squash = 0.64 if corpse else 1.0

    # 1. Five massive curved anchor-claw / horn buttress roots reaching to the outer edge (~3.1 tiles)
    for ci, (ang_deg, lscale, cdeg, tscale) in enumerate(CLAW_ROOTS):
        base_a = math.radians(ang_deg)
        curve_a = math.radians(cdeg)
        ts = np.linspace(0.0, 1.0, 6)
        r_steps = np.array([1.35, 1.76, 2.20, 2.60, 2.90, 3.08], dtype=np.float64) * lscale
        y_steps = np.array([0.66, 0.60, 0.48, 0.34, 0.21, 0.11], dtype=np.float64) * y_squash
        spine = []
        for k, t in enumerate(ts):
            a = base_a + curve_a * (t ** 1.4)
            rx = r_steps[k] * (FOOT_RX / 2.86)
            rz = r_steps[k] * (FOOT_RZ / 2.86)
            spine.append([rx * math.cos(a), y_steps[k], rz * math.sin(a)])
        rads = np.array([
            [0.39, 0.36],
            [0.37, 0.34],
            [0.30, 0.27],
            [0.22, 0.19],
            [0.12, 0.10],
            [0.032, 0.028],
        ], dtype=np.float64) * tscale
        if corpse:
            rads[:, 1] *= 0.78

        v, f = tube_solid(spine, rads, segs=8, start_cap_push=0.14, end_cap_push=0.12,
                          oval_bias=True, rib_amp=0.065, rib_freq=3.5, ground_floor=0.015,
                          label=f"claw_root_{ci}")
        r_dist = np.hypot(v[:, 0] / (FOOT_RX / 2.86), v[:, 2] / (FOOT_RZ / 2.86))
        shaft_t = smoothstep(1.55, 2.60, r_dist)
        tip_t = smoothstep(2.55, 3.08, r_dist)
        nv = organic_noise(v)
        cuff_col = np.array([0.255, 0.088, 0.062])
        horn_col = np.array([0.175, 0.118, 0.062])
        tip_col = np.array([0.115, 0.062, 0.034])
        col = cuff_col[None, :] * (1.0 - shaft_t[:, None]) + horn_col[None, :] * shaft_t[:, None]
        col = col * (1.0 - tip_t[:, None]) + tip_col[None, :] * tip_t[:, None]
        col *= (0.76 + 0.44 * nv[:, None])
        if corpse:
            col = col * np.array([0.78, 0.70, 0.76])[None, :] + np.array([0.015, 0.008, 0.016])[None, :]
        mb.add("flesh_spawner", v, f, col, uv0=uv_static)

        # Thick muscular reddish fleshy collar cuff wrapping around the claw root exit
        cuff_pos = np.asarray(spine[1], dtype=np.float64) + np.array([0.0, 0.07 * y_squash, 0.0])
        ca, sa = math.cos(base_a), math.sin(base_a)
        rot = np.array([[ca, 0.0, -sa], [0.0, 1.0, 0.0], [sa, 0.0, ca]], dtype=np.float64)
        vc, fc = ellipsoid_solid(cuff_pos, [0.27 * tscale, 0.28 * y_squash, 0.42 * tscale],
                                 rings=4, segs=8, rot=rot, label=f"claw_cuff_{ci}")
        nc = organic_noise(vc)
        c_col = np.array([0.260, 0.088, 0.068])[None, :] * (0.78 + 0.40 * nc[:, None])
        if corpse:
            c_col = c_col * np.array([0.68, 0.62, 0.74])[None, :]
        mb.add("flesh_spawner", vc, fc, c_col, uv0=uv_static)

    # 2. Sixteen bold ribbed bulbous fleshy root-lobes packed closely around the whole nest rim
    for li, (ang_deg, rscale, rads_k, cdeg) in enumerate(LOBE_ROOTS):
        base_a = math.radians(ang_deg)
        curve_a = math.radians(cdeg)
        ts = np.linspace(0.0, 1.0, 5)
        r_steps = np.array([1.48, 1.90, 2.30, 2.66, 2.86], dtype=np.float64) * rscale
        y_steps = np.array([0.52, 0.44, 0.34, 0.25, 0.16], dtype=np.float64) * y_squash
        spine = []
        for k, t in enumerate(ts):
            a = base_a + curve_a * (t ** 1.3)
            rx = r_steps[k] * (FOOT_RX / 2.86)
            rz = r_steps[k] * (FOOT_RZ / 2.86)
            spine.append([rx * math.cos(a), y_steps[k], rz * math.sin(a)])
        # Thick fleshy shafts swelling into lumpy bulbous tan-ochre anchor pads (Factorio's front lobes!)
        rads = np.array([
            [0.24, 0.22],
            [0.20, 0.19],
            [0.22, 0.19],
            [0.26, 0.20],
            [0.14, 0.11],
        ], dtype=np.float64) * rads_k
        if corpse:
            rads[:, 1] *= 0.76

        v, f = tube_solid(spine, rads, segs=7, start_cap_push=0.10, end_cap_push=0.10,
                          oval_bias=True, rib_amp=0.07, rib_freq=2.5, ground_floor=0.015,
                          label=f"lobe_root_{li}")
        r_dist = np.hypot(v[:, 0] / (FOOT_RX / 2.86), v[:, 2] / (FOOT_RZ / 2.86))
        out_t = smoothstep(1.60, 2.45, r_dist)
        nv = organic_noise(v)
        inner_col = np.array([0.240, 0.082, 0.058])
        outer_col = np.array([0.215, 0.132, 0.062])
        col = inner_col[None, :] * (1.0 - out_t[:, None]) + outer_col[None, :] * out_t[:, None]
        col *= (0.76 + 0.44 * nv[:, None])
        if corpse:
            col = col * np.array([0.74, 0.68, 0.74])[None, :]
        mb.add("flesh_spawner", v, f, col, uv0=uv_static)


# ---------------------------------------------------------------------------------------------
# Living spawner builder (biter-spawner.glb, also tinted for spitter-spawner)

def build_live_spawner():
    """Build watertight living biter-spawner with pulsing egg-sac dome (`UV.x=1, UV.y=1`)."""
    mb = MeshBuilder(("stone_spawner_dirt", "flesh_spawner", "flesh_spawner_dome"))
    uv_static = np.array([0.0, 0.0], dtype=np.float64)
    uv_dome = np.array([1.0, 1.0], dtype=np.float64)

    # 1. Tight scalloped terraced dirt crater base (`stone_spawner_dirt`, UV=(0,0))
    add_dirt_base(mb, corpse=False, uv_static=uv_static)

    # 2. Massive radial anchor-claws, 16 bulbous root-lobes, muscular collar walls & tendons (`flesh_spawner`)
    add_radial_roots(mb, corpse=False, uv_static=uv_static)

    # 2a. 8 overlapping thick gnarled fleshy hive collar wall buttresses gripping the dome skirt
    n_walls = 8
    for wi in range(n_walls):
        th_c = 2.0 * math.pi * wi / n_walls + 0.18
        half_arc = math.pi / n_walls * 1.16

        def r_wall(th):
            w = float(perim_warp(th))
            rx, rz = 2.02 * w, 1.84 * w
            return 1.0 / math.hypot(math.cos(th) / rx, math.sin(th) / rz)

        def y_wall(a, th, idx=wi):
            arch = 1.0 - 0.28 * (a * a)
            wave = 0.09 * math.sin(th * 3.0 + idx)
            return (0.74 + wave) * arch

        vw, fw = curved_wall_solid(th_c, half_arc, r_wall, y_bot=0.05, y_top_fn=y_wall,
                                   thickness=0.34, lean_out=-0.12, rib_count=3.5, az_steps=9,
                                   label=f"hive_collar_{wi}")
        nw = organic_noise(vw)
        ht = smoothstep(0.10, 0.78, vw[:, 1])
        w_lo = np.array([0.140, 0.052, 0.040])
        w_hi = np.array([0.260, 0.102, 0.078])
        w_col = (w_lo[None, :] * (1.0 - ht[:, None]) + w_hi[None, :] * ht[:, None]) * (0.76 + 0.42 * nw[:, None])
        mb.add("flesh_spawner", vw, fw, w_col, uv0=uv_static)

    # 2b. 10 braided organic sinew tendons strapping from the roots up onto the dome flank
    for ti in range(10):
        ang = 2.0 * math.pi * ti / 10.0 + 0.35
        twist = 0.22 * (1.0 if ti % 2 == 0 else -1.0)
        ts = np.linspace(0.0, 1.0, 5)
        r_t = np.array([2.44, 2.22, 1.98, 1.76, 1.50], dtype=np.float64)
        y_t = np.array([0.18, 0.38, 0.62, 0.84, 0.98], dtype=np.float64)
        spine = []
        for k, t in enumerate(ts):
            a = ang + twist * math.sin(t * math.pi)
            rx = r_t[k] * (FOOT_RX / 2.86)
            rz = r_t[k] * (FOOT_RZ / 2.86)
            spine.append([rx * math.cos(a), y_t[k], rz * math.sin(a)])
        rads = [0.068, 0.062, 0.054, 0.044, 0.022]
        vt, ft = tube_solid(spine, rads, segs=6, start_cap_push=0.05, end_cap_push=0.06,
                            ground_floor=0.018, label=f"sinew_tendon_{ti}")
        nt = organic_noise(vt)
        t_col = np.array([0.295, 0.188, 0.102])[None, :] * (0.78 + 0.38 * nt[:, None])
        mb.add("flesh_spawner", vt, ft, t_col, uv0=uv_static)

    # =========================================================================================
    # 3. BULBOUS RIBBED PULSING CENTRAL EGG-SAC DOME + 8 LARGE EGG-SAC BLISTERS (`flesh_spawner_dome`)
    #    UV = (1.0, 1.0) -> rig_mode 2 pulses smoothly with creature_rigs.json["biter-spawner"]!
    # =========================================================================================
    dome_rx, dome_rz = 2.02, 1.88
    dome_y0 = 0.08
    dome_h = 1.54  # total height with top egg-sac rim lands right at ~1.80 tiles!

    # 8 large well-spaced egg-sac sockets covering the dome (Factorio spawner proportions!)
    # (theta_deg, polar_u, radius_u, is_open_pore)
    sockets = [
        (-18.0, 0.14, 0.30, False),   # prominent crown bulging egg-sac (well separated from ring)
        (-146.0, 0.56, 0.32, False),  # huge W-SW bulging egg-sac
        (-86.0, 0.62, 0.29, True),    # cupped front-S spawning pore
        (-28.0, 0.66, 0.27, True),    # cupped SE spawning pore
        (+36.0, 0.60, 0.31, False),   # large E-NE bulging egg-sac
        (+98.0, 0.56, 0.31, False),   # large N-NW bulging egg-sac
        (+158.0, 0.64, 0.27, False),  # W flank bulging egg-sac
        (-114.0, 0.78, 0.22, False),  # lower SW egg-sac
    ]

    def dome_base_point(u, theta):
        w = 1.0 + 0.030 * np.cos(2.0 * theta - 0.5) + 0.020 * np.sin(3.0 * theta + 0.7)
        rib = 1.0 + 0.024 * np.cos(8.0 * theta + 0.5 * u) * np.sin(u * math.pi)
        r_x = dome_rx * u * w * rib
        r_z = dome_rz * u * w * rib
        profile = (max(0.0, 1.0 - (u ** 2.35))) ** 0.56
        y = dome_y0 + dome_h * profile
        return np.array([r_x * math.cos(theta), y, r_z * math.sin(theta)], dtype=np.float64)

    sock_info = []
    for adeg, su, srad, is_pore in sockets:
        ath = math.radians(adeg)
        c3 = dome_base_point(su, ath)
        p_u = dome_base_point(min(su + 0.02, 0.98), ath) - dome_base_point(max(su - 0.02, 0.01), ath)
        p_t = dome_base_point(su, ath + 0.03) - dome_base_point(su, ath - 0.03)
        n3 = np.cross(p_t, p_u)
        if n3[1] < 0.0:
            n3 = -n3
        n3 /= max(np.linalg.norm(n3), 1e-12)
        world_r = srad * 1.66
        sock_info.append((c3, n3, world_r, is_pore))

    # Higher-resolution sculpted dome shell (52 azimuth x 16 rings) for crisp raised crater rims!
    d_segs = 52
    d_th = np.linspace(0.0, 2.0 * math.pi, d_segs, endpoint=False)
    u_rings = np.array([0.06, 0.14, 0.22, 0.30, 0.39, 0.48, 0.57, 0.66, 0.74, 0.82, 0.89, 0.95, 0.98, 1.00, 0.95], dtype=np.float64)

    dome_rings = []
    dome_rim_vals = []
    dome_cup_vals = []
    for ri, u in enumerate(u_rings):
        ring_pts = []
        ring_rim = []
        ring_cup = []
        for theta in d_th:
            if ri == len(u_rings) - 1:
                w = 1.0 + 0.030 * math.cos(2.0 * theta - 0.5) + 0.020 * math.sin(3.0 * theta + 0.7)
                p = np.array([dome_rx * 0.86 * w * math.cos(theta), dome_y0, dome_rz * 0.86 * w * math.sin(theta)])
                ring_pts.append(p)
                ring_rim.append(0.0)
                ring_cup.append(0.0)
                continue
            p = dome_base_point(u, theta)
            if ri == len(u_rings) - 2:
                p[1] = dome_y0
                ring_pts.append(p)
                ring_rim.append(0.0)
                ring_cup.append(0.0)
                continue
            out_dir = np.array([p[0] / (dome_rx * dome_rx), (p[1] - dome_y0) / (dome_h * dome_h), p[2] / (dome_rz * dome_rz)])
            out_dir /= max(np.linalg.norm(out_dir), 1e-12)
            disp = 0.032 * math.sin(p[0] * 3.8 + p[2] * 3.2) * math.cos(p[1] * 3.5) * (1.0 - smoothstep(0.84, 0.98, u))
            rim_acc = 0.0
            cup_acc = 0.0
            for c3, n3, wr, _is_pore in sock_info:
                dist = float(np.linalg.norm(p - c3))
                rn = dist / wr
                if rn < 1.65:
                    rim_w = math.exp(-((rn - 1.02) / 0.30) ** 2)
                    cup_w = max(0.0, 1.0 - (rn / 0.88) ** 2) ** 1.35 if rn < 0.88 else 0.0
                    disp += 0.115 * rim_w - 0.195 * cup_w
                    rim_acc = max(rim_acc, rim_w)
                    cup_acc = max(cup_acc, cup_w)
            p = p + out_dir * disp
            p[1] = max(p[1], dome_y0 + 0.025)
            ring_pts.append(p)
            ring_rim.append(rim_acc)
            ring_cup.append(cup_acc)
        dome_rings.append(np.asarray(ring_pts, dtype=np.float64))
        dome_rim_vals.append(np.asarray(ring_rim, dtype=np.float64))
        dome_cup_vals.append(np.asarray(ring_cup, dtype=np.float64))

    crown_p = dome_base_point(0.0, 0.0)
    for c3, n3, wr, _ in sock_info:
        rn = float(np.linalg.norm(crown_p - c3)) / wr
        if rn < 1.65:
            crown_p[1] += 0.115 * math.exp(-((rn - 1.02) / 0.30) ** 2) - 0.195 * (max(0.0, 1.0 - (rn / 0.88) ** 2) ** 1.35 if rn < 0.88 else 0.0)

    v_d, f_d = loft_solid(dome_rings, start_center=crown_p, end_center=[0.0, dome_y0, 0.0], label="spawner_dome")
    rim_v = np.concatenate(dome_rim_vals + [np.array([0.0, 0.0])])
    cup_v = np.concatenate(dome_cup_vals + [np.array([0.0, 0.0])])

    # Mottled pale lavender-pink organic dome web with deeper warm fleshy red lower walls & creases
    nd = organic_noise(v_d)
    ht_d = smoothstep(0.25, 1.62, v_d[:, 1])
    web_lo = np.array([0.215, 0.082, 0.075])   # rich dark fleshy rose lower skirt
    web_hi = np.array([0.320, 0.220, 0.232])   # pale mottled pinkish-lavender upper crown (Factorio spawner!)
    cup_col = np.array([0.105, 0.045, 0.038])  # dark fleshy socket crease
    d_rgb = web_lo[None, :] * (1.0 - ht_d[:, None]) + web_hi[None, :] * ht_d[:, None]
    d_rgb = d_rgb * (0.74 + 0.44 * nd[:, None]) + np.array([0.042, 0.022, 0.020])[None, :] * rim_v[:, None]
    d_rgb = d_rgb * (1.0 - 0.72 * cup_v[:, None]) + cup_col[None, :] * (0.72 * cup_v[:, None])

    # skin_mode 2 mask in COLOR_0 on dome web:
    #   biter-spawner (orange-red alpha=0.5) -> subtle warm reddish fleshy mottling
    #   spitter-spawner (crimson alpha=1.0) -> rich deep crimson-red dome web (not neon cherry!)
    d_col0 = np.ones((len(v_d), 3), dtype=np.float64)
    mask_on = (v_d[:, 1] > dome_y0 + 0.03) & (cup_v < 0.55)
    m_shade = (0.095 + 0.115 * ht_d + 0.095 * nd + 0.045 * rim_v) * (1.0 - 0.5 * cup_v)
    m_cover = np.clip((0.46 + 0.34 * (1.0 - 0.40 * ht_d) + 0.18 * (nd - 0.5)) * (1.0 - cup_v), 0.14, 0.86)
    d_col0[mask_on, 0] = np.sqrt(np.clip(m_shade[mask_on] / 4.0, 0.0, 1.0))
    d_col0[mask_on, 1] = m_cover[mask_on]
    d_col0[mask_on, 2] = 0.0
    mb.add("flesh_spawner_dome", v_d, f_d, d_rgb, uv0=uv_dome, color_rgb=d_col0)

    # 3b. 8 Large Bulbous Cream/Tan Egg-Sac Blisters & Cupped Open Spawning Pores (`flesh_spawner_dome`)
    for si, (c3, n3, wr, is_pore) in enumerate(sock_info):
        u_ax, v_ax, n_ax = frame_from_normal(n3)
        rot = np.column_stack([u_ax, n_ax, v_ax])
        if not is_pore:
            rad_lat = wr * 0.88
            rad_out = wr * 0.46
            center = c3 - n_ax * (wr * 0.14)

            def egg_deform(pts, seed=si, c=center, n=n_ax):
                p = pts.copy()
                bump = 0.025 * np.sin(p[:, 0] * 7.5 + seed) * np.cos(p[:, 2] * 7.5 - seed)
                p += bump[:, None] * n[None, :]
                return p

            ve, fe = ellipsoid_solid(center, [rad_lat, rad_out, rad_lat * 0.90], rings=5, segs=12,
                                     rot=rot, deform_fn=egg_deform, label=f"egg_sac_{si}")
            out_h = (ve - center) @ n_ax
            crown_t = smoothstep(-0.08, rad_out * 0.82, out_h)
            ne = organic_noise(ve)
            egg_rim = np.array([0.135, 0.068, 0.044])
            egg_top = np.array([0.430, 0.300, 0.218])
            e_rgb = (egg_rim[None, :] * (1.0 - crown_t[:, None]) + egg_top[None, :] * crown_t[:, None]) * (0.86 + 0.26 * ne[:, None])
            mb.add("flesh_spawner_dome", ve, fe, e_rgb, uv0=uv_dome, color_rgb=np.ones((len(ve), 3)))
        else:
            p_segs = 14
            p_angs = np.linspace(0.0, 2.0 * math.pi, p_segs, endpoint=False)
            pore_prof = [
                (-0.22 * wr, 0.56 * wr),
                (-0.10 * wr, 0.86 * wr),
                (+0.05 * wr, 0.82 * wr),
                (+0.10 * wr, 0.64 * wr),
                (-0.03 * wr, 0.44 * wr),
                (-0.15 * wr, 0.22 * wr),
            ]
            p_rings = []
            for ho, rad in pore_prof:
                pts = [c3 + n_ax * ho + rad * (math.cos(a) * u_ax + 0.84 * math.sin(a) * v_ax) for a in p_angs]
                p_rings.append(np.asarray(pts, dtype=np.float64))
            vp, fp = loft_solid(p_rings, start_center=c3 - n_ax * (0.28 * wr),
                                end_center=c3 - n_ax * (0.19 * wr), label=f"egg_pore_{si}")
            depth = (vp - c3) @ n_ax
            lip_t = smoothstep(-0.15 * wr, 0.09 * wr, depth)
            p_rgb = (1.0 - lip_t[:, None]) * np.array([0.070, 0.040, 0.028]) + lip_t[:, None] * np.array([0.335, 0.220, 0.155])
            mb.add("flesh_spawner_dome", vp, fp, p_rgb, uv0=uv_dome, color_rgb=np.ones((len(vp), 3)))

    return mb.merged()


# ---------------------------------------------------------------------------------------------
# Ruptured spawner corpse builder (biter-spawner-corpse.glb)

def build_corpse_spawner():
    """Build watertight ruptured collapsed biter-spawner-corpse (~6.4 x 0.74 x 5.8, lo.y = 0.0)."""
    mb = MeshBuilder(("stone_spawner_dirt", "flesh_spawner", "flesh_spawner_hollow"))

    # 1. Tight flattened upturned dirt crater rim (`stone_spawner_dirt`, lo.y = 0.0000)
    add_dirt_base(mb, corpse=True, uv_static=None)

    # 2. Collapsed splayed claws & 16 root-lobes + jagged torn fleshy wall flaps (`flesh_spawner`)
    add_radial_roots(mb, corpse=True, uv_static=None)

    # 2a. 8 jagged torn collapsed fleshy dome wall flaps ringing the ruptured central cavity (y <= 0.74)
    flap_specs = [
        # (center_deg, half_arc_deg, peak_y, lean_out, jagged_phase)
        (-160.0, 21.0, 0.58, +0.18, 0.4),
        (-112.0, 22.0, 0.66, +0.22, 1.3),
        (-66.0, 20.0, 0.54, +0.15, 2.1),
        (-20.0, 23.0, 0.64, +0.20, 0.8),
        (+26.0, 21.0, 0.68, +0.23, 1.9),
        (+72.0, 20.0, 0.57, +0.16, 2.7),
        (+118.0, 22.0, 0.65, +0.21, 0.2),
        (+164.0, 20.0, 0.56, +0.15, 1.5),
    ]
    for fi, (cdeg, hdeg, py, lean, phase) in enumerate(flap_specs):
        th_c = math.radians(cdeg)
        half_a = math.radians(hdeg)

        def r_flap(th):
            w = float(perim_warp(th))
            rx, rz = 1.66 * w, 1.50 * w
            return 1.0 / math.hypot(math.cos(th) / rx, math.sin(th) / rz)

        def y_flap(a, th, peak=py, ph=phase):
            arch = 1.0 - 0.34 * (a * a)
            jag = 0.068 * math.sin(a * 5.2 + ph) + 0.042 * math.cos(a * 9.0 - ph)
            return min(0.73, max(0.28, (peak + jag) * arch))

        vf, ff = curved_wall_solid(th_c, half_a, r_flap, y_bot=0.05, y_top_fn=y_flap,
                                   thickness=0.34, lean_out=lean, rib_count=2.5, az_steps=10,
                                   label=f"torn_flap_{fi}")
        nf = organic_noise(vf)
        ht = smoothstep(0.16, py, vf[:, 1])
        r_rad = np.hypot(vf[:, 0] / 1.66, vf[:, 2] / 1.50)
        torn_edge = smoothstep(py - 0.16, py, vf[:, 1]) * (1.0 - smoothstep(0.84, 1.12, r_rad))
        skin_lo = np.array([0.110, 0.050, 0.056])
        skin_hi = np.array([0.200, 0.125, 0.130])
        torn_col = np.array([0.340, 0.240, 0.188])
        f_col = (skin_lo[None, :] * (1.0 - ht[:, None]) + skin_hi[None, :] * ht[:, None]) * (0.76 + 0.40 * nf[:, None])
        f_col = f_col * (1.0 - 0.74 * torn_edge[:, None]) + torn_col[None, :] * (0.74 * torn_edge[:, None])
        mb.add("flesh_spawner", vf, ff, f_col)

    # 2b. 6 slumped severed fleshy tendons draping over the torn rim into the purple crater
    for si in range(6):
        ang = math.radians(si * 60.0 + 18.0)
        ca, sa = math.cos(ang), math.sin(ang)
        spine = [
            [1.68 * ca, 0.48, 1.52 * sa],
            [1.42 * ca, 0.42, 1.28 * sa],
            [1.16 * ca, 0.28, 1.05 * sa],
            [0.95 * ca, 0.18, 0.86 * sa],
        ]
        vs, fs = tube_solid(spine, [0.052, 0.042, 0.032, 0.014], segs=6,
                            start_cap_push=0.04, end_cap_push=0.03, ground_floor=0.08,
                            label=f"torn_tendon_{si}")
        mb.add("flesh_spawner", vs, fs, np.array([0.195, 0.075, 0.095]))

    # =========================================================================================
    # 3. EXPOSED DARK GLOSSY HOLLOW RUPTURED CORE (`flesh_spawner_hollow`, rough=0.35)
    # =========================================================================================
    h_segs = 38
    h_th = np.linspace(0.0, 2.0 * math.pi, h_segs, endpoint=False)
    h_ct, h_st = np.cos(h_th), np.sin(h_th)
    hw = 1.0 + 0.055 * np.cos(2.0 * h_th + 0.3) + 0.042 * np.sin(3.0 * h_th - 0.9)
    hol_rx, hol_rz = 1.50, 1.35

    hol_spec = [
        (0.14, 0.14, 0.016),
        (0.36, 0.16, 0.024),
        (0.58, 0.21, 0.032),
        (0.78, 0.31, 0.038),
        (0.94, 0.39, 0.035),
        (1.00, 0.22, 0.000),
        (0.92, 0.04, 0.000),
    ]
    h_rings = []
    for rf, yb, ramp in hol_spec:
        rip = ramp * (0.5 + 0.5 * np.sin(h_th * 5.0 + rf * 7.0) * np.cos(h_th * 3.0 - 0.5))
        y = np.full(h_segs, yb, dtype=np.float64) if ramp == 0.0 else yb + rip
        h_rings.append(np.column_stack([hol_rx * rf * hw * h_ct, y, hol_rz * rf * hw * h_st]))

    vh, fh = loft_solid(h_rings, start_center=[0.0, 0.13, 0.0], end_center=[0.0, 0.04, 0.0],
                        label="ruptured_hollow")
    nh = organic_noise(vh)
    r_hn = np.hypot(vh[:, 0] / hol_rx, vh[:, 2] / hol_rz)
    rim_h = smoothstep(0.45, 0.95, r_hn)
    pool_col = np.array([0.138, 0.035, 0.130])
    wall_col = np.array([0.230, 0.068, 0.162])
    h_rgb = (pool_col[None, :] * (1.0 - rim_h[:, None]) + wall_col[None, :] * rim_h[:, None]) * (0.76 + 0.44 * nh[:, None])
    mb.add("flesh_spawner_hollow", vh, fh, h_rgb)

    viscera_specs = [
        ([-0.38, 0.18, -0.26], [0.24, 0.11, 0.20], False),
        ([+0.44, 0.21, -0.18], [0.22, 0.12, 0.24], False),
        ([+0.12, 0.17, +0.42], [0.26, 0.10, 0.20], False),
        ([-0.52, 0.23, +0.34], [0.20, 0.12, 0.22], False),
        ([+0.68, 0.27, +0.26], [0.21, 0.13, 0.18], False),
        ([-0.14, 0.17, -0.06], [0.14, 0.07, 0.11], True),
        ([+0.18, 0.18, +0.08], [0.12, 0.06, 0.10], True),
        ([-0.02, 0.19, +0.24], [0.10, 0.06, 0.09], True),
    ]
    for vi, (vc, vr, is_egg_bit) in enumerate(viscera_specs):
        vv, fv = ellipsoid_solid(vc, vr, rings=4, segs=8, label=f"hollow_viscera_{vi}")
        nv = organic_noise(vv)
        if is_egg_bit:
            v_col = np.array([0.325, 0.225, 0.195])[None, :] * (0.82 + 0.30 * nv[:, None])
        else:
            v_col = np.array([0.215, 0.058, 0.155])[None, :] * (0.76 + 0.42 * nv[:, None])
        mb.add("flesh_spawner_hollow", vv, fv, v_col)

    return mb.merged()


# ---------------------------------------------------------------------------------------------
# Baking & glTF 2.0 binary writer

def bake_model_attributes(groups):
    normals = [compute_smooth_normals(v, f) for _, v, f, _, _, _ in groups]
    tris = np.concatenate([v[f] for _, v, f, _, _, _ in groups], axis=0)
    nrms = np.concatenate([n[f] for (_, _, f, _, _, _), n in zip(groups, normals)], axis=0)
    sides = np.linalg.norm(tris - np.roll(tris, 1, axis=1), axis=2).max(axis=1)
    area = 0.5 * np.linalg.norm(np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0]), axis=1)
    ao, edge, part, vis = bake.bake(tris, nrms, up=1, width=area / np.maximum(sides, 1e-9),
                                    views=bake.factorio_views(up=1))
    out, t0 = [], 0
    for (_, v, f, uv0, part_rgb, color_rgb), nrm in zip(groups, normals):
        nf = len(f)
        nv = len(v)
        count = np.zeros(nv, dtype=np.float64)
        np.add.at(count, f.reshape(-1), 1.0)
        count = np.maximum(count, 1.0)[:, None]

        def avg_v(vals):
            acc = np.zeros((nv, vals.shape[2]), dtype=np.float64)
            np.add.at(acc, f.reshape(-1), vals.reshape(-1, vals.shape[2]))
            return acc / count

        a = np.clip(0.18 + 0.82 * avg_v(ao[t0:t0 + nf, :, None]), 0.0, 1.0)
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
            "COLOR_0": np.hstack([np.clip(color_rgb, 0.0, 1.0), a]),
            "TEXCOORD_0": uv0,
            "TEXCOORD_1": np.hstack([e, pt]),
            "TEXCOORD_2": vs[:, 0:2],
            "TEXCOORD_3": vs[:, 2:4],
            "TEXCOORD_4": uv4,
            "TEXCOORD_5": uv5,
        })
    return out


def write_glb(path, groups):
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

    for (mat_name, v, f, _uv0, _prgb, _crgb), attrs_data in zip(groups, baked):
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

def render_preview(groups, out_path, skins=None, tier=None, size=320):
    from PIL import Image

    t1_rgb, a1 = None, 0.0
    if skins is not None and tier is not None:
        t1, t2 = skins["biter-spawner"]["tiers"][tier]
        t1_rgb = np.array(t1[:3], dtype=np.float64)
        a1 = float(t2[3])

    all_tris, all_cols, all_nrms = [], [], []
    for mat, v, f, _uv, prgb, crgb in groups:
        nrm = compute_smooth_normals(v, f)
        tri_v = v[f]
        tri_p = prgb[f].mean(axis=1)
        tri_c = crgb[f].mean(axis=1)
        tri_n = nrm[f].mean(axis=1)
        tri_n /= np.maximum(np.linalg.norm(tri_n, axis=1, keepdims=True), 1e-9)
        if mat == "flesh_spawner_dome" and t1_rgb is not None:
            unm = tri_c[:, 2]
            mr = np.maximum(tri_c[:, 0] - unm, 0.0)
            shade = 4.0 * mr * mr
            cov = np.clip(np.maximum(tri_c[:, 1] - unm, 0.0) * a1, 0.0, 1.0)[:, None]
            rgb = tri_p * (1.0 - cov) + shade[:, None] * t1_rgb * cov
        else:
            rgb = tri_p
        all_tris.append(tri_v)
        all_cols.append(rgb)
        all_nrms.append(tri_n)

    tris = np.concatenate(all_tris, axis=0)
    cols = np.concatenate(all_cols, axis=0)
    nrms = np.concatenate(all_nrms, axis=0)
    center = 0.5 * (tris.reshape(-1, 3).min(axis=0) + tris.reshape(-1, 3).max(axis=0))
    span = float(np.linalg.norm(tris.reshape(-1, 3).max(axis=0) - tris.reshape(-1, 3).min(axis=0))) * 0.52

    views = [
        np.array([0.0, 0.78, +0.72]),
        np.array([0.75, 0.65, +0.65]),
        np.array([1.0, 0.25, 0.0]),
        np.array([0.0, 1.0, +0.12]),
    ]
    light_dir = np.array([-0.55, 0.78, 0.30])
    light_dir /= np.linalg.norm(light_dir)

    tiles = []
    for eye in views:
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
        fill = np.maximum(0.0, nrms @ (-light_dir * 0.5 + np.array([0.0, 0.4, 0.0])))
        shade = 0.32 + 0.98 * key + 0.32 * fill
        lit = linear_to_srgb(cols * shade[:, None] * 1.45)

        for ti in np.argsort(pz.mean(axis=1)):
            x0, x1, x2 = sx[ti]
            y0, y1, y2 = sy[ti]
            area2 = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
            if area2 >= -1e-5:
                continue
            ix0, ix1 = max(0, int(math.floor(min(x0, x1, x2)))), min(size - 1, int(math.ceil(max(x0, x1, x2))))
            iy0, iy1 = max(0, int(math.floor(min(y0, y1, y2)))), min(size - 1, int(math.ceil(max(y0, y1, y2))))
            if ix1 < ix0 or iy1 < iy0:
                continue
            gx, gy = np.meshgrid(np.arange(ix0, ix1 + 1) + 0.5, np.arange(iy0, iy1 + 1) + 0.5)
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
    ap = argparse.ArgumentParser(description="Generate watertight Placeholders spawner models.")
    ap.add_argument("--out", default=PLACEHOLDERS_DIR, help="Output folder (default: placeholders pack)")
    ap.add_argument("--preview", default=None, help="Optional folder to save visual QA preview PNGs")
    args = ap.parse_args(argv)

    live_groups = build_live_spawner()
    live_path = os.path.join(args.out, f"{LIVE_NAME}.glb")
    write_glb(live_path, live_groups)
    lv = np.vstack([v for _, v, _, _, _, _ in live_groups])
    ltris = sum(len(f) for _, _, f, _, _, _ in live_groups)
    llo, lhi = lv.min(axis=0), lv.max(axis=0)
    print(f"wrote {LIVE_NAME + '.glb':28s} {ltris:5d} tris  size=({lhi[0]-llo[0]:.2f}, {lhi[1]-llo[1]:.2f}, {lhi[2]-llo[2]:.2f})  lo.y={llo[1]:.4f}")

    corpse_groups = build_corpse_spawner()
    corpse_path = os.path.join(args.out, f"{CORPSE_NAME}.glb")
    write_glb(corpse_path, corpse_groups)
    cv = np.vstack([v for _, v, _, _, _, _ in corpse_groups])
    ctris = sum(len(f) for _, _, f, _, _, _ in corpse_groups)
    clo, chi = cv.min(axis=0), cv.max(axis=0)
    print(f"wrote {CORPSE_NAME + '.glb':28s} {ctris:5d} tris  size=({chi[0]-clo[0]:.2f}, {chi[1]-clo[1]:.2f}, {chi[2]-clo[2]:.2f})  lo.y={clo[1]:.4f}")

    if args.preview:
        with open(SKINS_JSON, encoding="utf-8") as fp:
            skins = json.load(fp)
        render_preview(live_groups, os.path.join(args.preview, "biter-spawner.png"), skins, tier="biter-spawner")
        render_preview(live_groups, os.path.join(args.preview, "spitter-spawner.png"), skins, tier="spitter-spawner")
        render_preview(corpse_groups, os.path.join(args.preview, "biter-spawner-corpse.png"))
        print(f"wrote preview PNGs to {args.preview}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
