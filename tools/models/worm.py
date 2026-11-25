#!/usr/bin/env python3
"""Procedural watertight big-worm-turret generator for the Placeholders pack.

    python tools/models/worm.py                   # generate big-worm-turret.glb + corpse
    python tools/models/worm.py --out DIR         # write into a custom folder
    python tools/models/worm.py --preview DIR     # render multi-angle & tier preview PNGs

Builds a 100% closed, watertight, manifold Factorio-faithful big-worm-turret (`0` open edges,
outward-facing normals, positive volume on every primitive) and its fallen corpse
(`big-worm-turret-corpse.glb`) directly in plain Python + numpy + PIL (no Blender or Factorio
install required at runtime).

Shape & proportions come from Factorio 2.1's prepared/attack worm silhouettes (fat ribbed bottle
body standing to ~3.6 tiles, flared fleshy head crowned by a recessed toothed circular maw and
curved chitin horns, total height ~4.35 tiles). Uses the exact materials (`belly_worm`,
`flesh_worm`, `horn_worm`, `mouth_worm`), `rig_mode 4` vertex-shader compatibility
(`creature_rigs.json["big-worm-turret"]`), `skin_mode 2` tier mask encoding (`COLOR_0` +
`TEXCOORD_4/5` for `creature_skins.json`), and corpse pose (`creature_poses.json`).
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
POSES_JSON = os.path.join(REPO, "client", "data", "creature_poses.json")
SKINS_JSON = os.path.join(REPO, "client", "data", "creature_skins.json")

NAME = "big-worm-turret"
CORPSE_NAME = "big-worm-turret-corpse"
GENERATOR = "Zenith tools/models/worm.py"
COPYRIGHT = "Zenith contributors (GPL-3.0)"

PART_RANGE = 4.0
PART_SHARE = 0.25

# Exact PBR factors matching wube_recipes.py EXTRA_MATERIALS (sRGB hex converted to linear).
MATERIALS = (
    ("belly_worm", "c07a62", 0.60, 0.00),
    ("flesh_worm", "b8705a", 0.65, 0.00),
    ("horn_worm", "6e6460", 0.45, 0.05),
    ("mouth_worm", "2a1416", 0.30, 0.00),
)

# Measured Factorio 2.1 big-worm-turret standing bottle silhouette: (height_y, radius) in tiles.
PROFILE_Y = np.array([
    0.000, 0.225, 0.450, 0.675, 0.900, 1.125, 1.350, 1.575,
    1.800, 2.025, 2.250, 2.475, 2.700, 2.925, 3.150, 3.375,
    3.550, 3.645,
], dtype=np.float64)
PROFILE_R = np.array([
    1.185, 1.242, 1.250, 1.224, 1.178, 1.118, 1.050, 0.988,
    0.935, 0.904, 0.883, 0.872, 0.874, 0.886, 0.902, 0.836,
    0.768, 0.720,
], dtype=np.float64)

Y_TOP = float(PROFILE_Y[-1])   # 3.645
R_TOP = float(PROFILE_R[-1])   # 0.720


def profile_radius(y):
    return np.interp(y, PROFILE_Y, PROFILE_R)


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


def quat_to_matrix(q):
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
               ridge_fn=None, label="tube"):
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
        if ridge_fn is not None:
            mult = ridge_fn(k / max(len(p) - 1, 1), angles)
            ring = p[k] + np.outer(ca * ru * mult, us[k]) + np.outer(sa * rv * mult, vs[k])
        else:
            ring = p[k] + np.outer(ca * ru, us[k]) + np.outer(sa * rv, vs[k])
        rings.append(ring)
    sc = p[0] - tangents[0] * start_cap_push
    ec = p[-1] + tangents[-1] * end_cap_push
    return loft_solid(rings, start_center=sc, end_center=ec, label=label)


def ellipsoid_solid(center, radii, rings=4, segs=10, rot=None, label="ellipsoid"):
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
    return loft_solid(ring_list, start_center=south + c, end_center=north + c, label=label)


def armor_band_solid(y_bot, y_top, half_arc_deg=126.0, thickness=0.11, bulge=0.055,
                     flare_top=0.025, collar_ears=0.0, ground_flat=False,
                     az_steps=19, label="armor_band"):
    """Watertight thick curved dorsal carapace band wrapping around the worm's back (+Z).

    Lofted azimuthally along `alpha in [-1, 1]` (left flank -> dorsal spine -> right flank) so
    every cross-section ring is strictly convex in the radial-vertical plane: 0 open edges,
    positive volume, crisp shingled upper/lower lips, dorsal medial ridge & seam groove.

    Returns (verts, faces, is_outer_mask) where `is_outer_mask` is True for visible exterior
    carapace vertices and False for buried inner-underside vertices.
    """
    half_arc = math.radians(half_arc_deg)
    # Denser azimuth sampling near the dorsal spine (alpha=0) and lateral rims (|alpha|=1).
    u_half = np.array([0.0, 0.08, 0.19, 0.34, 0.50, 0.67, 0.82, 0.93, 1.0], dtype=np.float64)
    alphas = np.concatenate([-u_half[:0:-1], u_half])  # 17 stations across the wrap
    h_band = y_top - y_bot
    rings = []
    outer_flags = []

    # 8-vertex convex cross-section per azimuth station:
    # 0..4: outer dorsal face from bottom lip -> mid-lower -> upper crest -> top bevel -> top inner lip
    # 5..7: solid inner underside tucked cleanly inside the core -> bottom inner lip
    sec_s = np.array([0.0, 0.28, 0.68, 0.92, 1.0, 0.88, 0.45, 0.0], dtype=np.float64)
    sec_is_out = np.array([True, True, True, True, True, False, False, False], dtype=bool)

    for a in alphas:
        aa = abs(a)
        th = math.pi + a * half_arc  # pi = back (+Z); pi +- half_arc = front flanks
        # Pronounced chevron sweep: plates dip at dorsal spine & sweep upward at flanks (Factorio worm)
        chevron = (0.075 * h_band) * (2.0 * aa - 1.0) if not ground_flat else 0.0
        # Flared armored turtleneck collar ears on upper flanks (top band only)
        ear_lift = collar_ears * math.exp(-((aa - 0.74) / 0.26) ** 2)
        # Smooth organic feather taper at lateral ends so armor blends cleanly into belly ribs (no cliff)
        tip_taper = float(1.0 - smoothstep(0.74, 1.0, aa) * 0.72)
        # Bold dorsal spine ridge + crisp central vertical groove (Factorio worm's back ridge)
        spine_crest = 0.088 * math.exp(-((aa / 0.16) ** 2))
        spine_groove = -0.036 * math.exp(-((aa / 0.048) ** 2))
        dorsal_bump = spine_crest + spine_groove

        # Outer radial offsets per cross-section vertex (shingled overhang toward upper edge)
        r_out_off = np.array([
            0.004,                           # bottom lip tucked cleanly into seam
            bulge * 0.78,                    # lower flank of plate
            bulge * 1.18 + flare_top * 0.55, # prominent shingled crest
            bulge * 0.98 + flare_top,        # upper bevel shoulder
            0.012 + flare_top * 0.50,        # top bevel inner rim
            -thickness * 0.88,               # upper inner underside
            -thickness,                      # mid inner underside
            -thickness * 0.88,               # lower inner underside
        ], dtype=np.float64)

        pts = []
        for si in range(len(sec_s)):
            s = sec_s[si]
            y_lo = 0.0 if ground_flat else (y_bot + chevron)
            y_hi = y_top + chevron + ear_lift
            y = y_lo + s * (y_hi - y_lo)
            r_base = float(profile_radius(np.clip(y, 0.0, Y_TOP)))
            if sec_is_out[si]:
                r = r_base + (r_out_off[si] + dorsal_bump * (0.35 + 0.65 * math.sin(s * math.pi))) * tip_taper
            else:
                r = r_base + r_out_off[si] * (0.55 + 0.45 * tip_taper)
            pts.append([r * math.sin(th), y, -r * math.cos(th)])
        rings.append(np.asarray(pts, dtype=np.float64))
        outer_flags.append(sec_is_out.copy())

    # End caps: slightly beyond first/last azimuth ring, tucked inward by 2% radius into body core
    def tip_center(sign):
        th = math.pi + sign * (half_arc + math.radians(3.5))
        y_m = 0.5 * ((0.0 if ground_flat else y_bot) + y_top)
        r_m = float(profile_radius(np.clip(y_m, 0.0, Y_TOP))) - thickness * 0.35
        return np.array([r_m * math.sin(th), y_m, -r_m * math.cos(th)], dtype=np.float64)

    v, f = loft_solid(rings, start_center=tip_center(-1.0), end_center=tip_center(1.0), label=label)
    # Mark end-cap apex vertices as unmasked (buried inside body seam)
    is_outer = np.concatenate(outer_flags + [np.array([False, False], dtype=bool)])
    return v, f, is_outer


# ---------------------------------------------------------------------------------------------
# Mesh accumulator by material (supports COLOR_0 skin_mode 2 mask on flesh_worm)

class MeshBuilder:
    def __init__(self):
        self.groups = {name: [] for name, _, _, _ in MATERIALS}

    def add(self, material, verts, faces, part_rgb, color_rgb=None):
        v = np.asarray(verts, dtype=np.float64)
        f = np.asarray(faces, dtype=np.int64)
        prgb = np.asarray(part_rgb, dtype=np.float64)
        if prgb.ndim == 1:
            prgb = np.tile(prgb, (len(v), 1))
        if color_rgb is None:
            crgb = np.ones((len(v), 3), dtype=np.float64)
        else:
            crgb = np.asarray(color_rgb, dtype=np.float64)
            if crgb.ndim == 1:
                crgb = np.tile(crgb, (len(v), 1))
        self.groups[material].append((v, f, prgb, crgb))

    def merged(self):
        out = []
        for name, _, _, _ in MATERIALS:
            pieces = self.groups[name]
            if not pieces:
                continue
            v_list, f_list, p_list, c_list = [], [], [], []
            offset = 0
            for v, f, prgb, crgb in pieces:
                v_list.append(v)
                f_list.append(f + offset)
                p_list.append(prgb)
                c_list.append(crgb)
                offset += len(v)
            V = np.vstack(v_list)
            F = np.vstack(f_list)
            P = np.vstack(p_list)
            C = np.vstack(c_list)
            verify_manifold(V, F, f"material:{name}")
            out.append((name, V, F, P, C))
        return out


# ---------------------------------------------------------------------------------------------
# Big-worm-turret anatomical builder

def build_big_worm():
    """Build the watertight standing big-worm-turret matching Factorio's silhouette & rig_mode 4."""
    mb = MeshBuilder()

    # =========================================================================================
    # 1. WATERTIGHT MUSCULAR RIBBED BODY CORE + SCULPTED FLESHY HEAD (belly_worm)
    # =========================================================================================
    sides_body = 36
    th = np.linspace(0.0, 2.0 * math.pi, sides_body, endpoint=False)  # 0 = front (-Z), pi = back (+Z)
    ct, st = np.cos(th), np.sin(th)
    front_w = np.clip(ct, 0.0, 1.0)
    back_w = np.clip(-ct, 0.0, 1.0)
    ang_front = np.arctan2(st, ct)

    # Explicitly sampled body rings aligned 1:1 with the 11 dorsal segments (3 rings/rib:
    # deep crease trough -> bold belly rib crest -> upper shoulder) so ribs never alias!
    n_bands = 11
    band_edges = np.linspace(0.0, 3.56, n_bands + 1)
    body_ring_specs = []
    for bi in range(n_bands):
        y0, y1 = float(band_edges[bi]), float(band_edges[bi + 1])
        h_b = y1 - y0
        if bi == 0:
            body_ring_specs.append((0.0, 0.10))
        else:
            body_ring_specs.append((y0 + 0.03 * h_b, 0.00))  # deep crisp ventral rib trough
        body_ring_specs.append((y0 + 0.45 * h_b, 1.00))      # prominent ventral rib crest
        body_ring_specs.append((y0 + 0.80 * h_b, 0.72))      # upper rounded rib shoulder
    body_ring_specs.append((3.54, 0.15))                     # recessed neck collar crease

    # Sculpted 4-lobed fleshy head crown emerging above the armored collar
    head_specs = [
        # (y, r_base, lobe_amp, pinch, mouth_lip)
        (3.59, 0.69, 0.06, 0.03, 0.000),
        (3.68, 0.74, 0.12, 0.00, 0.000),
        (3.79, 0.70, 0.14, 0.00, 0.000),
        (3.90, 0.56, 0.10, 0.00, 0.010),
        (3.99, 0.38, 0.04, 0.00, 0.028),
        (4.03, 0.24, 0.01, 0.00, 0.034),  # raised fleshy mouth lip surrounding the dark maw
        (3.96, 0.15, 0.00, 0.00, 0.000),  # dips inward into mouth socket
    ]

    core_rings = []
    core_rib_val = []
    for y, rv in body_ring_specs:
        r0 = float(profile_radius(y))
        below_collar = float(1.0 - smoothstep(3.32, 3.55, y))
        # Bold horizontal belly ribs wrapping across front & anterolateral flanks
        belly_rib = (0.056 * rv - 0.018 * (1.0 - rv)) * (front_w ** 0.55) * below_collar
        # Crisp vertical ventral midline furrow down the center of the belly
        mid_crease = -0.032 * np.exp(-((ang_front / 0.11) ** 2)) * below_collar
        # Tuck back/sides cleanly inward so the thick armored dorsal plates wrap over with zero z-fighting
        dorsal_tuck = -0.055 * smoothstep(0.05, 0.45, back_w) * below_collar
        rr = r0 + belly_rib + mid_crease + dorsal_tuck
        ring = np.column_stack([rr * st, np.full(sides_body, y), -rr * ct])
        core_rings.append(ring)
        core_rib_val.append(np.full(sides_body, rv, dtype=np.float64))

    for y, r0, lobe_amp, pinch, lip in head_specs:
        # 4 muscular horn-socket lobes (front, right, back, left) with concave fleshy cheeks between
        lobe4 = (0.5 + 0.5 * np.cos(4.0 * th)) ** 1.5 - 0.25 * (0.5 - 0.5 * np.cos(4.0 * th))
        z_shift = -0.06 * smoothstep(3.62, 4.00, y)
        rr = (r0 - pinch) + lobe_amp * lobe4
        y_ring = y + lip - 0.035 * ct * smoothstep(3.64, 4.02, y)
        ring = np.column_stack([rr * st, y_ring, -rr * ct + z_shift])
        core_rings.append(ring)
        core_rib_val.append(np.full(sides_body, 0.5, dtype=np.float64))

    v_core, f_core = loft_solid(
        core_rings,
        start_center=[0.0, 0.0, 0.0],
        end_center=[0.0, 3.88, -0.06],
        label="worm_belly_core",
    )
    rib_v = np.concatenate(core_rib_val + [np.array([0.0, 0.0], dtype=np.float64)])

    # Paint belly_worm: rich ribbed burnt-sienna/terracotta belly -> pale fleshy pink-tan head!
    vy = v_core[:, 1]
    vz = v_core[:, 2]
    head_t = smoothstep(3.52, 3.70, vy)
    base_dark = 1.0 - smoothstep(0.0, 0.65, vy)
    mid_v = np.exp(-((np.arctan2(v_core[:, 0], -vz) / 0.12) ** 2)) * (1.0 - head_t)
    # Body belly color: deep dark-umber in rib creases, warm mottled ochre-rust on crests
    body_col = (
        np.array([0.052, 0.017, 0.012])[None, :] * (1.0 - rib_v[:, None])
        + np.array([0.205, 0.078, 0.050])[None, :] * rib_v[:, None]
    )
    body_col *= (1.0 - 0.45 * base_dark - 0.28 * mid_v)[:, None]
    # Pale fleshy pinkish-peach head with dark collar crease and crimson-pink mouth rim
    collar_crease = np.exp(-((vy - 3.57) / 0.065) ** 2)
    mouth_rim = smoothstep(3.90, 4.03, vy) * (1.0 - smoothstep(0.14, 0.34, np.hypot(v_core[:, 0], vz + 0.06)))
    head_col = np.tile(np.array([0.315, 0.155, 0.125]), (len(v_core), 1))
    head_col = head_col * (1.0 - 0.55 * collar_crease[:, None]) + np.array([0.10, 0.028, 0.022]) * (0.55 * collar_crease[:, None])
    head_col = head_col * (1.0 - 0.55 * mouth_rim[:, None]) + np.array([0.16, 0.036, 0.034]) * (0.55 * mouth_rim[:, None])
    core_rgb = body_col * (1.0 - head_t[:, None]) + head_col * head_t[:, None]
    mb.add("belly_worm", v_core, f_core, core_rgb)

    # 1b. 4 Sculpted Fleshy Muscular Horn-Socket Bosses on the head (belly_worm)
    boss_specs = [
        ([-0.52, 3.74, -0.02], [0.24, 0.19, 0.21]),
        ([+0.52, 3.74, -0.02], [0.24, 0.19, 0.21]),
        ([0.00, 3.80, +0.44], [0.22, 0.20, 0.21]),
        ([0.00, 3.72, -0.49], [0.23, 0.18, 0.21]),
    ]
    for bi, (bc, br) in enumerate(boss_specs):
        vb, fb = ellipsoid_solid(bc, br, rings=4, segs=8, label=f"head_boss_{bi}")
        bt_y = smoothstep(3.56, 3.96, vb[:, 1])
        b_rgb = (1.0 - bt_y[:, None]) * np.array([0.21, 0.088, 0.068]) + bt_y[:, None] * np.array([0.32, 0.165, 0.135])
        mb.add("belly_worm", vb, fb, b_rgb)

    # =========================================================================================
    # 2. WATERTIGHT SEGMENTED OVERLAPPING ARMORED DORSAL PLATES (flesh_worm, skin_mode 2 masked!)
    # =========================================================================================
    for bi in range(n_bands):
        y0 = float(band_edges[bi])
        y1 = float(band_edges[bi + 1])
        y_lo = 0.0 if bi == 0 else y0 - 0.055
        y_hi = y1 + (0.04 if bi == n_bands - 1 else 0.025)
        top_collar = (bi == n_bands - 1)
        arc_deg = 128.0 if bi < n_bands - 2 else (134.0 if bi == n_bands - 2 else 140.0)
        v_p, f_p, is_out = armor_band_solid(
            y_lo, y_hi,
            half_arc_deg=arc_deg,
            thickness=0.115 if not top_collar else 0.105,
            bulge=0.054 + 0.010 * (bi / n_bands),
            flare_top=0.024 if not top_collar else 0.064,
            collar_ears=0.15 if top_collar else (0.045 if bi == n_bands - 2 else 0.0),
            ground_flat=(bi == 0),
            label=f"dorsal_plate_{bi}",
        )

        # Rich organic dark bronze-rust Factorio carapace under the tier mask
        local_s = smoothstep(y_lo, y_hi, v_p[:, 1])
        h_frac = smoothstep(0.0, 3.55, v_p[:, 1])
        ang_back = np.abs(np.arctan2(v_p[:, 0], v_p[:, 2])) / math.pi
        spine_seam = np.exp(-((ang_back / 0.045) ** 2))
        ridge_hi = np.exp(-((ang_back / 0.18) ** 2)) * (1.0 - 0.75 * spine_seam)
        flank_wear = smoothstep(0.35, 0.72, ang_back) * (1.0 - smoothstep(0.76, 0.96, ang_back))

        base_lo = np.array([0.055, 0.018, 0.013])
        base_hi = np.array([0.215, 0.088, 0.060])
        p_rgb = base_lo[None, :] * (1.0 - (0.30 + 0.70 * local_s)[:, None]) + base_hi[None, :] * (0.30 + 0.70 * local_s)[:, None]
        # Pale dusty chitin highlights along flank shoulders & dark spine groove (like sprite_worm_0.png!)
        p_rgb += flank_wear[:, None] * (0.3 + 0.7 * local_s)[:, None] * np.array([0.065, 0.045, 0.036])
        p_rgb *= (0.68 + 0.36 * h_frac + 0.14 * ridge_hi - 0.32 * spine_seam)[:, None]

        # skin_mode 2 mask in COLOR_0: balanced organic tier tinting over carapace + unmasked inner faces
        c_rgb = np.ones((len(v_p), 3), dtype=np.float64)
        mask_on = is_out.copy()
        if top_collar:
            mask_on &= (v_p[:, 1] < y_hi - 0.015)
        shade = (0.045 + 0.115 * (local_s ** 1.2) + 0.055 * ridge_hi) * (0.68 + 0.38 * h_frac) * (1.0 - 0.45 * spine_seam)
        cover = np.clip(0.32 + 0.32 * local_s + 0.12 * (1.0 - ang_back) - 0.15 * flank_wear, 0.18, 0.74)
        c_rgb[mask_on, 0] = np.sqrt(np.clip(shade[mask_on] / 4.0, 0.0, 1.0))
        c_rgb[mask_on, 1] = cover[mask_on]
        c_rgb[mask_on, 2] = 0.0
        mb.add("flesh_worm", v_p, f_p, p_rgb, c_rgb)

    # =========================================================================================
    # 3. WATERTIGHT CURVED CHITIN HORNS, TUSKS & MAW TEETH (horn_worm)
    # =========================================================================================
    s = R_TOP  # 0.720
    # 4 heavy fierce inward-hooking curved horns around the toothed maw + 2 front chin tusks
    horn_defs = [
        ("horn_left", [
            [-0.46 * s, 3.70, -0.02 * s],
            [-0.90 * s, 3.82, -0.04 * s],
            [-1.16 * s, 4.08, -0.05 * s],
            [-1.04 * s, 4.30, -0.06 * s],
            [-0.76 * s, 4.36, -0.06 * s],
        ], [0.200, 0.156, 0.112, 0.064, 0.016], 0.06, 0.072),
        ("horn_right", [
            [+0.46 * s, 3.70, -0.02 * s],
            [+0.90 * s, 3.82, -0.04 * s],
            [+1.16 * s, 4.08, -0.05 * s],
            [+1.04 * s, 4.30, -0.06 * s],
            [+0.76 * s, 4.36, -0.06 * s],
        ], [0.200, 0.156, 0.112, 0.064, 0.016], 0.06, 0.072),
        ("horn_back", [
            [0.0, 3.74, +0.44 * s],
            [0.0, 3.96, +0.66 * s],
            [0.0, 4.22, +0.66 * s],
            [0.0, 4.36, +0.48 * s],
            [0.0, 4.35, +0.28 * s],
        ], [0.175, 0.136, 0.096, 0.056, 0.015], 0.055, 0.065),
        ("horn_front", [
            [0.0, 3.66, -0.46 * s],
            [0.0, 3.82, -0.82 * s],
            [0.0, 4.06, -0.88 * s],
            [0.0, 4.24, -0.70 * s],
            [0.0, 4.26, -0.48 * s],
        ], [0.172, 0.132, 0.092, 0.052, 0.014], 0.055, 0.060),
        ("tusk_left", [
            [-0.36 * s, 3.72, -0.50 * s],
            [-0.54 * s, 3.66, -0.80 * s],
            [-0.50 * s, 3.52, -0.94 * s],
            [-0.36 * s, 3.38, -0.90 * s],
        ], [0.092, 0.066, 0.040, 0.011], 0.04, 0.045),
        ("tusk_right", [
            [+0.36 * s, 3.72, -0.50 * s],
            [+0.54 * s, 3.66, -0.80 * s],
            [+0.50 * s, 3.52, -0.94 * s],
            [+0.36 * s, 3.38, -0.90 * s],
        ], [0.092, 0.066, 0.040, 0.011], 0.04, 0.045),
    ]

    for hname, spine, rads, spush, epush in horn_defs:
        sp = np.asarray(spine, dtype=np.float64)
        v_h, f_h = tube_solid(sp, rads, segs=8, start_cap_push=spush, end_cap_push=epush, label=hname)
        d_root = np.linalg.norm(v_h - sp[0], axis=1)
        tot_len = float(np.sum(np.linalg.norm(np.diff(sp, axis=0), axis=1)))
        tip_t = smoothstep(0.05, tot_len * 0.92, d_root)
        h_rgb = (1.0 - tip_t[:, None]) * np.array([0.24, 0.155, 0.130]) + tip_t[:, None] * np.array([0.040, 0.036, 0.034])
        mb.add("horn_worm", v_h, f_h, h_rgb)

    # Ring of 10 small sharp inward-pointing teeth ringing the circular maw (Factorio worm teeth!)
    mouth_center = np.array([0.0, 3.99, -0.06], dtype=np.float64)
    mouth_n = np.array([0.0, 0.94, -0.34], dtype=np.float64)
    mouth_n /= np.linalg.norm(mouth_n)
    mouth_u = np.array([1.0, 0.0, 0.0], dtype=np.float64)
    mouth_v = np.cross(mouth_n, mouth_u)
    for ti in range(10):
        ang = 2.0 * math.pi * ti / 10.0
        radial = math.cos(ang) * mouth_u + math.sin(ang) * mouth_v
        base_pt = mouth_center + radial * 0.195 - mouth_n * 0.025
        mid_pt = mouth_center + radial * 0.130 + mouth_n * 0.020
        tip_pt = mouth_center + radial * 0.068 - mouth_n * 0.010
        v_t, f_t = tube_solid([base_pt, mid_pt, tip_pt], [0.028, 0.018, 0.004], segs=5,
                              start_cap_push=0.018, end_cap_push=0.016, label=f"maw_tooth_{ti}")
        mb.add("horn_worm", v_t, f_t, np.array([0.28, 0.21, 0.14]))

    # =========================================================================================
    # 4. WATERTIGHT RECESSED DARK GLOSSY MAW GULLET CUP (mouth_worm)
    # =========================================================================================
    m_segs = 14
    m_angs = np.linspace(0.0, 2.0 * math.pi, m_segs, endpoint=False)
    gullet_prof = [
        (-0.18, 0.11),
        (-0.12, 0.21),
        (-0.02, 0.23),
        (+0.03, 0.20),
        (-0.01, 0.14),
        (-0.10, 0.08),
    ]
    m_rings = []
    for h_off, rad in gullet_prof:
        pts = [mouth_center + mouth_n * h_off + rad * (math.cos(a) * mouth_u + math.sin(a) * mouth_v)
               for a in m_angs]
        m_rings.append(np.asarray(pts, dtype=np.float64))
    v_m, f_m = loft_solid(
        m_rings,
        start_center=mouth_center - mouth_n * 0.22,
        end_center=mouth_center - mouth_n * 0.13,
        label="mouth_gullet",
    )
    m_depth = (v_m - mouth_center) @ mouth_n
    lip_t = smoothstep(-0.08, 0.03, m_depth)
    m_rgb = (1.0 - lip_t[:, None]) * np.array([0.010, 0.002, 0.004]) + lip_t[:, None] * np.array([0.048, 0.012, 0.016])
    mb.add("mouth_worm", v_m, f_m, m_rgb)

    return mb.merged()


# ---------------------------------------------------------------------------------------------
# Corpse posing (matches creature_poses.json["big-worm-turret-corpse"] 1:1)

def pose_worm_corpse(base_groups, pose_entry):
    """Apply the fallen corpse rigid transform and bruised-corpse palette while keeping 100% watertightness."""
    at = np.asarray(pose_entry["at"], dtype=np.float64)
    to = np.asarray(pose_entry["to"], dtype=np.float64)
    rot_m = quat_to_matrix(pose_entry["turn"])
    scale = float(pose_entry.get("scale", 1.0))

    posed_verts = []
    min_y = math.inf
    for _mat, v, _f, _p, _c in base_groups:
        p = ((v - at) @ rot_m.T) * scale + to
        min_y = min(min_y, float(p[:, 1].min()))
        posed_verts.append(p)

    # Shift cleanly onto y = 0.0000 and apply bruised dead-worm toning (matching Factorio's corpse)
    out = []
    for (mat, _v, f, prgb, crgb), p in zip(base_groups, posed_verts):
        p = p.copy()
        p[:, 1] -= min_y
        verify_manifold(p, f, f"corpse:{mat}")
        p_dead = prgb.copy()
        if mat in ("belly_worm", "flesh_worm"):
            # Bruised dead-flesh desaturation & subtle purplish-slate cast (Factorio worm corpse)
            lum = (0.299 * p_dead[:, 0] + 0.587 * p_dead[:, 1] + 0.114 * p_dead[:, 2])[:, None]
            bruise = lum * np.array([0.92, 0.62, 0.88])[None, :]
            p_dead = p_dead * 0.52 + bruise * 0.48
        elif mat == "horn_worm":
            p_dead *= 0.65
        out.append((mat, p, f, p_dead, crgb.copy()))
    return out


# ---------------------------------------------------------------------------------------------
# Baking & glTF 2.0 binary writer

def bake_model_attributes(groups):
    """Run tools/models/bake.py jointly over all primitives so plates, core and horns occlude each other."""
    normals = [compute_smooth_normals(v, f) for _, v, f, _, _ in groups]
    tris = np.concatenate([v[f] for _, v, f, _, _ in groups], axis=0)
    nrms = np.concatenate([n[f] for (_, _, f, _, _), n in zip(groups, normals)], axis=0)
    sides = np.linalg.norm(tris - np.roll(tris, 1, axis=1), axis=2).max(axis=1)
    area = 0.5 * np.linalg.norm(np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0]), axis=1)
    ao, edge, part, vis = bake.bake(tris, nrms, up=1, width=area / np.maximum(sides, 1e-9),
                                    views=bake.factorio_views(up=1))
    out, t0 = [], 0
    for (_, v, f, part_rgb, color_rgb), nrm in zip(groups, normals):
        nf = len(f)
        nv = len(v)
        count = np.zeros(nv, dtype=np.float64)
        np.add.at(count, f.reshape(-1), 1.0)
        count = np.maximum(count, 1.0)[:, None]

        def avg_v(vals):
            acc = np.zeros((nv, vals.shape[2]), dtype=np.float64)
            np.add.at(acc, f.reshape(-1), vals.reshape(-1, vals.shape[2]))
            return acc / count

        a = np.clip(0.20 + 0.80 * avg_v(ao[t0:t0 + nf, :, None]), 0.0, 1.0)
        e = avg_v(edge[t0:t0 + nf, :, None])
        pt = avg_v(np.repeat(part[t0:t0 + nf, None, None], 3, axis=1))
        vs = avg_v(vis[t0:t0 + nf])
        t0 += nf

        rgb = np.clip(part_rgb, 0.0, PART_RANGE) / PART_RANGE
        rgb /= np.maximum(rgb.max(axis=1), 1.0)[:, None]
        uv4 = np.clip(rgb[:, 0:2], 0.0, 1.0)
        uv5 = np.column_stack([np.clip(rgb[:, 2], 0.0, 1.0), np.full(nv, PART_SHARE, dtype=np.float64)])
        uv0 = v[:, [0, 2]].copy()  # planar (x, z); rig_mode 4 bends by vertex position alone

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

    for (mat_name, v, f, _prgb, _crgb), attrs_data in zip(groups, baked):
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

def render_preview(groups, out_path, skins, tier="big-worm-turret", size=300):
    from PIL import Image

    t1, t2 = skins["big-worm-turret"]["tiers"][tier]
    t1_rgb = np.array(t1[:3], dtype=np.float64)
    a1 = float(t2[3])

    all_tris, all_cols, all_nrms = [], [], []
    for mat, v, f, prgb, crgb in groups:
        nrm = compute_smooth_normals(v, f)
        tri_v = v[f]
        tri_p = prgb[f].mean(axis=1)
        tri_c = crgb[f].mean(axis=1)
        tri_n = nrm[f].mean(axis=1)
        tri_n /= np.maximum(np.linalg.norm(tri_n, axis=1, keepdims=True), 1e-9)
        if mat == "flesh_worm":
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
    span = float(np.linalg.norm(tris.reshape(-1, 3).max(axis=0) - tris.reshape(-1, 3).min(axis=0))) * 0.55

    views = [
        np.array([0.65, 0.55, -0.85]),  # front-iso (belly & mouth)
        np.array([0.65, 0.55, +0.85]),  # back-iso (dorsal plates)
        np.array([1.0, 0.20, 0.0]),     # side profile
        np.array([0.0, 1.0, -0.15]),    # top crown (horns & toothed maw)
    ]
    light_dir = np.array([-0.45, 0.78, -0.42])
    light_dir /= np.linalg.norm(light_dir)

    tiles = []
    for eye in views:
        fwd = -eye / np.linalg.norm(eye)
        up_ref = np.array([0.0, 1.0, 0.0]) if abs(fwd[1]) < 0.95 else np.array([0.0, 0.0, 1.0])
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
        fill = np.maximum(0.0, nrms @ (-light_dir * 0.55 + np.array([0.0, 0.3, 0.25])))
        shade = 0.30 + 1.00 * key + 0.35 * fill
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
# Build & CLI entry point

def build(raw=None, out_dir=None, preview_dir=None):
    """Generate big-worm-turret.glb and big-worm-turret-corpse.glb into `out_dir` (default: placeholders)."""
    out_dir = out_dir or PLACEHOLDERS_DIR
    with open(POSES_JSON, encoding="utf-8") as fp:
        poses = json.load(fp)

    base_groups = build_big_worm()
    base_path = os.path.join(out_dir, f"{NAME}.glb")
    write_glb(base_path, base_groups)
    all_v = np.vstack([v for _, v, _, _, _ in base_groups])
    tris = sum(len(f) for _, _, f, _, _ in base_groups)
    lo, hi = all_v.min(axis=0), all_v.max(axis=0)
    print(f"wrote {NAME + '.glb':28s} {tris:5d} tris  size=({hi[0]-lo[0]:.2f}, {hi[1]-lo[1]:.2f}, {hi[2]-lo[2]:.2f})  lo.y={lo[1]:.4f}")

    corpse_groups = pose_worm_corpse(base_groups, poses[CORPSE_NAME])
    corpse_path = os.path.join(out_dir, f"{CORPSE_NAME}.glb")
    write_glb(corpse_path, corpse_groups)
    cv = np.vstack([v for _, v, _, _, _ in corpse_groups])
    ctris = sum(len(f) for _, _, f, _, _ in corpse_groups)
    clo, chi = cv.min(axis=0), cv.max(axis=0)
    print(f"wrote {CORPSE_NAME + '.glb':28s} {ctris:5d} tris  size=({chi[0]-clo[0]:.2f}, {chi[1]-clo[1]:.2f}, {chi[2]-clo[2]:.2f})  lo.y={clo[1]:.4f}")

    if preview_dir:
        with open(SKINS_JSON, encoding="utf-8") as fp:
            skins = json.load(fp)
        for tier in ("small-worm-turret", "medium-worm-turret", "big-worm-turret", "behemoth-worm-turret"):
            render_preview(base_groups, os.path.join(preview_dir, f"{tier}.png"), skins, tier=tier)
        render_preview(corpse_groups, os.path.join(preview_dir, f"{CORPSE_NAME}.png"), skins, tier="big-worm-turret")
        print(f"wrote preview PNGs to {preview_dir}")
    return base_path


def main(argv=None):
    ap = argparse.ArgumentParser(description="Generate watertight Placeholders big-worm-turret models.")
    ap.add_argument("--out", default=PLACEHOLDERS_DIR, help="Output folder (default: placeholders pack)")
    ap.add_argument("--preview", default=None, help="Optional folder to save visual QA preview PNGs")
    args = ap.parse_args(argv)
    build(out_dir=args.out, preview_dir=args.preview)
    return 0


if __name__ == "__main__":
    sys.exit(main())
