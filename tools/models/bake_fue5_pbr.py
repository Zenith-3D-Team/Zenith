#!/usr/bin/env python3
"""Derives packed ORM (Occlusion/Roughness/Metallic) and OpenGL tangent-space
Normal maps directly from FUE5's embedded diffuse textures, injects them
losslessly into client/assets/models/packs/fue5/*.glb, updates pack.json and
.glb.import files, and verifies the result.

    .venv/Scripts/python tools/models/bake_fue5_pbr.py --update-pack-json --fix-imports
    .venv/Scripts/python tools/models/bake_fue5_pbr.py --names wooden-chest inserter
    .venv/Scripts/python tools/models/bake_fue5_pbr.py --verify

Plain Python + numpy + Pillow (no Blender required).
"""

import argparse
from concurrent.futures import ProcessPoolExecutor
import glob
import hashlib
import io
import json
import math
import os
import struct
import sys
import time

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import bake_pbr  # noqa: E402

FUE5_DIR = os.path.join(REPO, "client", "assets", "models", "packs", "fue5")

LINEAR_REPEAT_SAMPLER = {
    "magFilter": 9729,
    "minFilter": 9987,
    "wrapS": 10497,
    "wrapT": 10497,
}

BARE_STEEL_MATS = {
    "fue5_iron-chest",
    "fue5_steel-chest",
    "fue5_steel-furnace",
    "fue5_splitter",
    "fue5_fast-splitter",
    "fue5_express-splitter",
    "fue5_turbo-splitter",
    "fue5_small-lamp",
    "fue5_substation",
    "fue5_big-electric-pole",
    "fue5_medium-electric-pole",
}

FLAT_PAINTED_MATS = {
    "fue5_active-provider-chest",
    "fue5_passive-provider-chest",
    "fue5_storage-chest",
    "fue5_buffer-chest",
    "fue5_requester-chest",
    "fue5_inserter",
    "fue5_burner-inserter",
    "fue5_fast-inserter",
    "fue5_long-handed-inserter",
    "fue5_bulk-inserter",
    "fue5_stack-inserter",
    "fue5_construction-robot",
    "fue5_logistic-robot",
    "fue5_logistic-robot_glow_mat5",
    "fue5_rail-signal",
    "fue5_rail-chain-signal",
}

GLASS_ACCENT_MATS = {
    "fue5_lab",
    "fue5_beacon",
    "fue5_accumulator",
    "fue5_centrifuge",
    "fue5_chemical-plant",
}

TILED_STEEL_MATS = {
    "fue5_belt_frame",
    "fue5_heat_pipe_steel",
    "fue5_pipe",
    "fue5_ug_steel",
    "fue5_ug_rim",
    "fue5_ug_side",
}

LAMP_MATS = {
    "lamp_red",
    "lamp_green",
    "lamp_yellow",
    "lamp_blue",
    "fue5_construction-robot_anim_lamp_nozzle",
    "fue5_logistic-robot_anim_lamp_cargo",
    "fue5_logistic-robot_anim_lamp_empty",
}

AO_FLOOR = {
    "stone": 0.78,
    "wood": 0.78,
    "wood_pole": 0.80,
    "bare_steel": 0.84,
    "painted_industrial": 0.84,
    "belt_surface": 0.84,
    "copper_heat_pipe": 0.88,
    "flat_painted_metal": 0.88,
    "solar_panel": 0.88,
}

NORMAL_STRENGTH = {
    "stone": 2.6,
    "wood": 2.0,
    "belt_surface": 2.0,
    "wood_pole": 1.9,
    "bare_steel": 1.8,
    "painted_industrial": 1.8,
    "copper_heat_pipe": 1.6,
    "flat_painted_metal": 1.6,
    "solar_panel": 1.5,
}


def classify_fue5_material(mat_name):
    """Returns (profile_name, is_tiled, variant_tag) for a textured FUE5 material."""
    low = mat_name.lower()
    if low == "fue5_belt_surface":
        return "belt_surface", True, ""
    if low == "fue5_heat_pipe_copper":
        return "copper_heat_pipe", True, ""
    if low in TILED_STEEL_MATS:
        return "bare_steel", True, ""
    if low == "fue5_ug_paint":
        return "flat_painted_metal", True, ""
    if low == "fue5_wooden-chest":
        return "wood", False, ""
    if low == "fue5_small-electric-pole":
        return "wood_pole", False, ""
    if low == "fue5_stone-wall" or low.startswith("fue5_stone-wall-"):
        return "stone", False, ""
    if low == "fue5_stone-furnace":
        return "stone", False, "furnace"
    if low == "fue5_solar-panel":
        return "solar_panel", False, ""
    if low in BARE_STEEL_MATS:
        return "bare_steel", False, ""
    if low in FLAT_PAINTED_MATS:
        return "flat_painted_metal", False, ""
    variant = "glass" if low in GLASS_ACCENT_MATS else ""
    return "painted_industrial", False, variant


def untextured_factors(mat_name):
    """Returns (metallicFactor, roughnessFactor) for FUE5 materials without baseColorTexture."""
    low = mat_name.lower()
    if low == "fue5_ug_inner":
        return 0.05, 0.92
    if low in LAMP_MATS or low.startswith("lamp_"):
        return 0.0, 0.18
    if low == "heater":
        return 0.65, 0.48
    return None


def target_dimensions(w, h, hero_size, max_size):
    """Chooses output PBR texture dimensions keeping native aspect ratio."""
    longest = max(w, h)
    if longest >= 2048:
        limit = hero_size
    elif longest > max_size:
        limit = max_size
    else:
        return w, h
    scale = limit / float(longest)
    tw = max(2, int(round(w * scale / 2.0)) * 2)
    th = max(2, int(round(h * scale / 2.0)) * 2)
    return tw, th


def smoothstep(edge0, edge1, x):
    t = np.clip((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def gaussian_blur(arr, sigma, wrap=False):
    """Separable pure-NumPy 1D Gaussian blur along X then Y."""
    if sigma <= 0.05:
        return arr.astype(np.float32, copy=True)
    radius = max(1, int(math.ceil(sigma * 3.0)))
    x = np.arange(-radius, radius + 1, dtype=np.float32)
    kernel = np.exp(-0.5 * (x / sigma) ** 2)
    kernel /= np.sum(kernel)

    h, w = arr.shape[:2]
    src = arr.astype(np.float32, copy=False)

    # Blur along axis 1 (width)
    if wrap:
        idx_x = (np.arange(-radius, w + radius) % w)
        padded_x = src[:, idx_x]
    else:
        pad_spec = ((0, 0), (radius, radius)) if src.ndim == 2 else ((0, 0), (radius, radius), (0, 0))
        padded_x = np.pad(src, pad_spec, mode="edge")
    out_x = np.zeros_like(src, dtype=np.float32)
    for k_i, k_w in enumerate(kernel):
        out_x += k_w * padded_x[:, k_i:k_i + w]

    # Blur along axis 0 (height)
    if wrap:
        idx_y = (np.arange(-radius, h + radius) % h)
        padded_y = out_x[idx_y, :]
    else:
        pad_spec = ((radius, radius), (0, 0)) if src.ndim == 2 else ((radius, radius), (0, 0), (0, 0))
        padded_y = np.pad(out_x, pad_spec, mode="edge")
    out_y = np.zeros_like(src, dtype=np.float32)
    for k_i, k_w in enumerate(kernel):
        out_y += k_w * padded_y[k_i:k_i + h, :]
    return out_y


def _hash2_uint(ix, iy, seed):
    with np.errstate(over="ignore"):
        h = (
            ix.astype(np.uint32) * np.uint32(374761393)
            + iy.astype(np.uint32) * np.uint32(668265263)
            + np.uint32(seed) * np.uint32(2147483647)
        )
        h ^= h >> np.uint32(13)
        h *= np.uint32(1274126177)
        h ^= h >> np.uint32(16)
    return h.astype(np.float32) * np.float32(1.0 / 4294967295.0)


def tileable_vnoise2d(h, w, periods_y, periods_x, seed):
    """Deterministic periodic 2D value noise in [0, 1] of shape (h, w)."""
    py = max(2, int(periods_y))
    px = max(2, int(periods_x))
    y = np.arange(h, dtype=np.float32) * (py / float(h))
    x = np.arange(w, dtype=np.float32) * (px / float(w))

    iy0 = np.floor(y).astype(np.int32) % py
    iy1 = (iy0 + 1) % py
    ty = y - np.floor(y)
    uy = (ty * ty * (3.0 - 2.0 * ty))[:, None]

    ix0 = np.floor(x).astype(np.int32) % px
    ix1 = (ix0 + 1) % px
    tx = x - np.floor(x)
    ux = (tx * tx * (3.0 - 2.0 * tx))[None, :]

    c00 = _hash2_uint(ix0[None, :], iy0[:, None], seed)
    c10 = _hash2_uint(ix1[None, :], iy0[:, None], seed)
    c01 = _hash2_uint(ix0[None, :], iy1[:, None], seed)
    c11 = _hash2_uint(ix1[None, :], iy1[:, None], seed)

    top = c00 + (c10 - c00) * ux
    bot = c01 + (c11 - c01) * ux
    return top + (bot - top) * uy


def central_diff(grid, wrap=False):
    """Computes (dh_dx, dh_dy) along axis 1 (+U) and axis 0 (+V)."""
    if wrap:
        dh_dx = 0.5 * (np.roll(grid, -1, axis=1) - np.roll(grid, 1, axis=1))
        dh_dy = 0.5 * (np.roll(grid, -1, axis=0) - np.roll(grid, 1, axis=0))
    else:
        px = np.pad(grid, ((0, 0), (1, 1)), mode="edge")
        py = np.pad(grid, ((1, 1), (0, 0)), mode="edge")
        dh_dx = 0.5 * (px[:, 2:] - px[:, :-2])
        dh_dy = 0.5 * (py[2:, :] - py[:-2, :])
    return dh_dx.astype(np.float32), dh_dy.astype(np.float32)


def encode_png_rgb(arr_u8):
    buf = io.BytesIO()
    Image.fromarray(arr_u8, mode="RGB").save(buf, format="PNG", optimize=True, compress_level=9)
    return buf.getvalue()


def synthesize_fue5_maps(img_bytes, profile, is_tiled, variant_tag, target_size, seed_int):
    """Synthesizes (orm_png_bytes, normal_png_bytes) from an embedded diffuse image."""
    im = Image.open(io.BytesIO(img_bytes)).convert("RGB")
    if im.size != target_size:
        im = im.resize(target_size, Image.Resampling.LANCZOS)

    rgb_srgb = np.asarray(im, dtype=np.float32) / 255.0
    h, w = rgb_srgb.shape[:2]

    if is_tiled:
        pad_mask = np.zeros((h, w), dtype=bool)
    else:
        pad_mask = np.max(rgb_srgb, axis=2) < 0.025
        if np.any(~pad_mask) and np.any(pad_mask):
            rgb_srgb = bake_pbr.dilate_atlas(rgb_srgb, ~pad_mask, passes=6)

    rgb_lin = np.power(np.clip(rgb_srgb, 0.0, 1.0), 2.2)
    lum = (0.2126 * rgb_lin[..., 0] + 0.7152 * rgb_lin[..., 1] + 0.0722 * rgb_lin[..., 2]).astype(np.float32)
    lum_s = (0.2126 * rgb_srgb[..., 0] + 0.7152 * rgb_srgb[..., 1] + 0.0722 * rgb_srgb[..., 2]).astype(np.float32)

    lum_clean = gaussian_blur(lum, 0.85, wrap=is_tiled)
    lum_s_clean = gaussian_blur(lum_s, 0.85, wrap=is_tiled)
    lum_s_med = gaussian_blur(lum_s_clean, 2.2, wrap=is_tiled)
    lum_macro = gaussian_blur(lum_clean, 5.0, wrap=is_tiled)

    # 1. Micro-cavity AO (ORM R): gentle seam darkening without double-darkening COLOR_0.a
    ao_floor = AO_FLOOR[profile]
    rel = np.clip(lum_clean / np.maximum(lum_macro, 0.06), 0.0, 1.0)
    occ = np.clip(ao_floor + (1.0 - ao_floor) * rel, ao_floor, 1.0)

    # 2. Tangent-space normal map (OpenGL convention: +Y up -> ny = +dh_dy)
    height = 0.55 * lum_s_clean + 0.45 * lum_s_med
    dh_dx, dh_dy = central_diff(height, wrap=is_tiled)
    dh_dx = np.tanh(dh_dx * 3.5) / 3.5
    dh_dy = np.tanh(dh_dy * 3.5) / 3.5

    gmag = gaussian_blur(np.hypot(dh_dx, dh_dy), 2.5, wrap=is_tiled)
    flat_w = smoothstep(0.018, 0.004, gmag)
    if np.any(pad_mask):
        flat_w = flat_w * (~pad_mask).astype(np.float32)

    n_fine = tileable_vnoise2d(h, w, max(16, round(h / 4.5)), max(16, round(w / 4.5)), seed_int + 17)
    n_mid = tileable_vnoise2d(h, w, max(6, round(h / 18.0)), max(6, round(w / 18.0)), seed_int + 53)
    micro_h = (0.65 * (n_fine - 0.5) + 0.35 * (n_mid - 0.5)).astype(np.float32)
    mdx, mdy = central_diff(micro_h, wrap=True)

    micro_bump = 0.055 if profile == "flat_painted_metal" else 0.025
    dh_dx = dh_dx + mdx * micro_bump * flat_w
    dh_dy = dh_dy + mdy * micro_bump * flat_w

    strength = NORMAL_STRENGTH[profile]
    nx = -dh_dx * strength
    ny = dh_dy * strength
    nz = np.ones((h, w), dtype=np.float32)
    inv_len = 1.0 / np.sqrt(nx * nx + ny * ny + nz * nz)
    nrm_f = np.stack(
        [nx * inv_len * 0.5 + 0.5, ny * inv_len * 0.5 + 0.5, nz * inv_len * 0.5 + 0.5],
        axis=-1,
    )

    # 3. Roughness (ORM G) & Metallic (ORM B) using perceptual sRGB saturation/darkness
    # (linearizing RGB inflates warm grey metal saturation and pulls mid-dark steel into soot).
    cmax = np.max(rgb_srgb, axis=2)
    cmin = np.min(rgb_srgb, axis=2)
    sat = np.where(cmax > 1e-4, (cmax - cmin) / np.maximum(cmax, 1e-4), 0.0)

    valid_lum = lum_s_clean[~pad_mask] if np.any(~pad_mask) else lum_s_clean.ravel()
    if valid_lum.size > 0:
        p10, p90 = np.percentile(valid_lum, [10.0, 90.0])
    else:
        p10, p90 = 0.15, 0.85
    lum_norm = np.clip((lum_s_clean - p10) / max(float(p90 - p10), 0.15), 0.0, 1.0)

    r_ch, g_ch, b_ch = rgb_srgb[..., 0], rgb_srgb[..., 1], rgb_srgb[..., 2]
    rust_w = (
        smoothstep(1.06, 1.24, r_ch / np.maximum(g_ch, 1e-4))
        * smoothstep(1.06, 1.24, g_ch / np.maximum(b_ch, 1e-4))
        * smoothstep(0.24, 0.42, sat)
        * smoothstep(0.62, 0.28, lum_s_clean)
    )
    dark_w = smoothstep(0.16, 0.06, lum_s_clean)

    if profile == "wood":
        rough = 0.90 - 0.18 * lum_norm
        strap_w = smoothstep(0.18, 0.08, sat) * smoothstep(0.45, 0.22, lum_s_clean) * (1.0 - dark_w * 0.4)
        metal = 0.45 * strap_w
        rough = rough * (1.0 - strap_w) + 0.52 * strap_w
    elif profile == "wood_pole":
        ceramic_w = smoothstep(0.60, 0.72, lum_s_clean) * smoothstep(0.20, 0.08, sat)
        bracket_w = smoothstep(0.18, 0.08, sat) * smoothstep(0.22, 0.34, lum_s_clean) * smoothstep(0.60, 0.45, lum_s_clean)
        rough = 0.90 - 0.16 * lum_norm
        metal = 0.02 * ceramic_w + 0.62 * bracket_w
        rough = rough * (1.0 - ceramic_w) + 0.24 * ceramic_w
        rough = rough * (1.0 - bracket_w) + 0.46 * bracket_w
    elif profile == "stone":
        rough = 0.95 - 0.17 * lum_norm
        if variant_tag == "furnace":
            band_w = smoothstep(0.18, 0.08, sat) * smoothstep(0.42, 0.20, lum_s_clean)
            metal = 0.28 * band_w
            rough = rough * (1.0 - band_w) + 0.56 * band_w
        else:
            metal = np.zeros((h, w), dtype=np.float32)
    elif profile == "belt_surface":
        chev_w = smoothstep(0.32, 0.48, sat) * smoothstep(0.20, 0.35, lum_s_clean)
        rim_w = smoothstep(0.24, 0.12, sat) * smoothstep(0.42, 0.55, lum_s_clean)
        rubber_w = np.clip(1.0 - np.maximum(chev_w, rim_w), 0.0, 1.0)
        metal = 0.05 * rubber_w + 0.10 * chev_w + 0.58 * rim_w
        rough = (0.86 - 0.14 * lum_norm) * rubber_w + 0.44 * chev_w + 0.42 * rim_w
    elif profile == "copper_heat_pipe":
        metal = 0.68 + 0.24 * lum_norm
        rough = 0.46 - 0.22 * lum_norm
    elif profile == "solar_panel":
        pv_w = smoothstep(0.18, 0.34, sat) * smoothstep(0.95, 1.08, b_ch / np.maximum(np.maximum(r_ch, g_ch), 1e-4))
        frame_w = smoothstep(0.20, 0.08, sat) * smoothstep(0.20, 0.36, lum_s_clean)
        metal = 0.08 + 0.04 * pv_w + 0.66 * frame_w * (1.0 - pv_w)
        rough = (0.78 - 0.30 * frame_w) * (1.0 - pv_w) + (0.24 - 0.08 * lum_norm) * pv_w
    elif profile == "bare_steel":
        paint_w = smoothstep(0.38, 0.55, sat) * (1.0 - rust_w)
        metal = 0.60 + 0.25 * lum_norm
        rough = 0.52 - 0.24 * lum_norm
        metal = metal * (1.0 - paint_w) + 0.14 * paint_w
        rough = rough * (1.0 - paint_w) + 0.44 * paint_w
        metal = metal * (1.0 - rust_w) + 0.14 * rust_w
        rough = rough * (1.0 - rust_w) + 0.80 * rust_w
        metal = metal * (1.0 - dark_w) + 0.16 * dark_w
        rough = rough * (1.0 - dark_w) + 0.84 * dark_w
    elif profile == "flat_painted_metal":
        paint_w = smoothstep(0.18, 0.32, sat)
        chassis_metal = 0.55 + 0.17 * lum_norm
        chassis_rough = 0.52 - 0.14 * lum_norm
        paint_metal = 0.14 + 0.08 * lum_norm
        paint_rough = 0.52 - 0.14 * lum_norm
        metal = chassis_metal * (1.0 - paint_w) + paint_metal * paint_w
        rough = chassis_rough * (1.0 - paint_w) + paint_rough * paint_w
        metal = metal * (1.0 - dark_w) + 0.12 * dark_w
        rough = rough * (1.0 - dark_w) + 0.80 * dark_w
    else:  # painted_industrial
        paint_w = smoothstep(0.24, 0.42, sat) * (1.0 - rust_w)
        bare_metal = 0.65 + 0.17 * lum_norm
        bare_rough = 0.48 - 0.18 * lum_norm
        paint_rough = 0.54 - 0.14 * lum_norm
        metal = bare_metal * (1.0 - paint_w) + 0.14 * paint_w
        rough = bare_rough * (1.0 - paint_w) + paint_rough * paint_w
        if variant_tag == "glass":
            cyan_w = smoothstep(0.22, 0.38, sat) * smoothstep(0.95, 1.18, np.maximum(g_ch, b_ch) / np.maximum(r_ch, 1e-4))
            metal = metal * (1.0 - cyan_w) + 0.08 * cyan_w
            rough = rough * (1.0 - cyan_w) + 0.20 * cyan_w
        metal = metal * (1.0 - rust_w) + 0.12 * rust_w
        rough = rough * (1.0 - rust_w) + 0.80 * rust_w
        metal = metal * (1.0 - dark_w) + 0.10 * dark_w
        rough = rough * (1.0 - dark_w) + 0.82 * dark_w

    rough_amp = 0.05 if profile == "flat_painted_metal" else 0.015
    rough = rough + (micro_h * 2.0) * rough_amp * flat_w

    orm_f = np.stack(
        [np.clip(occ, 0.0, 1.0), np.clip(rough, 0.04, 1.0), np.clip(metal, 0.0, 1.0)],
        axis=-1,
    ).astype(np.float32)

    if not is_tiled and np.any(~pad_mask) and np.any(pad_mask):
        valid = ~pad_mask
        orm_f = bake_pbr.dilate_atlas(orm_f, valid, passes=4)
        nrm_f = bake_pbr.dilate_atlas(nrm_f, valid, passes=4)
        nrm_vec = nrm_f * 2.0 - 1.0
        nlen = np.sqrt(np.sum(nrm_vec * nrm_vec, axis=-1, keepdims=True))
        nrm_f = (nrm_vec / np.maximum(nlen, 1e-6)) * 0.5 + 0.5

    orm_u8 = np.clip(np.round(orm_f * 255.0), 0, 255).astype(np.uint8)
    nrm_u8 = np.clip(np.round(nrm_f * 255.0), 0, 255).astype(np.uint8)
    return encode_png_rgb(orm_u8), encode_png_rgb(nrm_u8)


def _synth_worker(job):
    key, img_bytes = job
    profile, is_tiled, variant_tag, tw, th, base_md5 = key
    seed_int = int(base_md5[:8], 16)
    orm_bytes, nrm_bytes = synthesize_fue5_maps(
        img_bytes, profile, is_tiled, variant_tag, (tw, th), seed_int
    )
    return key, (orm_bytes, nrm_bytes)


def extract_image_bytes(doc, bin_chunk, img_idx):
    img = doc["images"][img_idx]
    bv = doc["bufferViews"][img["bufferView"]]
    off = bv.get("byteOffset", 0)
    return bin_chunk[off:off + bv["byteLength"]]


def rewrite_fue5_glb(path, cache_by_key, hero_size, max_size):
    """Losslessly injects cached ORM + Normal maps into one FUE5 .glb cleanly & idempotently."""
    doc, bin_chunk = bake_pbr.read_glb(path)
    mats = doc.get("materials", [])
    textures = doc.get("textures", [])
    images = doc.get("images", [])
    orig_bvs = doc.get("bufferViews", [])
    accessors = doc.get("accessors", [])
    samplers = list(doc.get("samplers", []))

    # Collect original texture/image indices used for baseColor and emissive so they stay fixed in place.
    kept_tex_indices = set()
    for m in mats:
        pbr = m.get("pbrMetallicRoughness", {})
        if "baseColorTexture" in pbr:
            kept_tex_indices.add(pbr["baseColorTexture"]["index"])
        if "emissiveTexture" in m:
            kept_tex_indices.add(m["emissiveTexture"]["index"])

    max_kept_tex = max(kept_tex_indices, default=-1)
    kept_img_indices = {
        textures[ti]["source"]
        for ti in kept_tex_indices
        if 0 <= ti < len(textures) and "source" in textures[ti]
    }
    max_kept_img = max(kept_img_indices, default=-1)

    new_textures = list(textures[:max_kept_tex + 1])
    new_images = list(images[:max_kept_img + 1])

    # Collect all bufferViews still needed (accessors + retained images).
    retained_bvs = set()
    for acc in accessors:
        if "bufferView" in acc:
            retained_bvs.add(acc["bufferView"])
        sparse = acc.get("sparse")
        if sparse:
            if "indices" in sparse and "bufferView" in sparse["indices"]:
                retained_bvs.add(sparse["indices"]["bufferView"])
            if "values" in sparse and "bufferView" in sparse["values"]:
                retained_bvs.add(sparse["values"]["bufferView"])
    for img_i in sorted(kept_img_indices):
        if "bufferView" in new_images[img_i]:
            retained_bvs.add(new_images[img_i]["bufferView"])

    bb = bake_pbr.BinBuilder()
    bv_remap = {}
    for old_bv_i in sorted(retained_bvs):
        old_bv = orig_bvs[old_bv_i]
        off = old_bv.get("byteOffset", 0)
        raw = bin_chunk[off:off + old_bv["byteLength"]]
        new_bv_i = bb.add_view(raw, target=old_bv.get("target"))
        if "byteStride" in old_bv:
            bb.views[new_bv_i]["byteStride"] = old_bv["byteStride"]
        bv_remap[old_bv_i] = new_bv_i

    for acc in accessors:
        if "bufferView" in acc:
            acc["bufferView"] = bv_remap[acc["bufferView"]]
        sparse = acc.get("sparse")
        if sparse:
            if "indices" in sparse and "bufferView" in sparse["indices"]:
                sparse["indices"]["bufferView"] = bv_remap[sparse["indices"]["bufferView"]]
            if "values" in sparse and "bufferView" in sparse["values"]:
                sparse["values"]["bufferView"] = bv_remap[sparse["values"]["bufferView"]]

    img_bytes_by_idx = {}
    for img_i in sorted(kept_img_indices):
        img = dict(new_images[img_i])
        old_bv_i = img["bufferView"]
        img_bytes_by_idx[img_i] = extract_image_bytes(doc, bin_chunk, img_i)
        img["bufferView"] = bv_remap[old_bv_i]
        new_images[img_i] = img

    # Ensure linear+repeat sampler exists without mutating existing samplers.
    sampler_idx = None
    for si, smp in enumerate(samplers):
        if smp == LINEAR_REPEAT_SAMPLER:
            sampler_idx = si
            break
    if sampler_idx is None:
        sampler_idx = len(samplers)
        samplers.append(dict(LINEAR_REPEAT_SAMPLER))

    # Append generated ORM + Normal textures per unique (profile, base_src) within this file.
    local_tex_cache = {}
    for m in mats:
        mname = m.get("name", "")
        pbr = m.get("pbrMetallicRoughness")
        if pbr is None:
            pbr = {}
            m["pbrMetallicRoughness"] = pbr

        if "baseColorTexture" not in pbr:
            factors = untextured_factors(mname)
            if factors is not None:
                pbr["metallicFactor"], pbr["roughnessFactor"] = factors
            continue

        base_tex_idx = pbr["baseColorTexture"]["index"]
        base_img_idx = new_textures[base_tex_idx]["source"]
        raw_base = img_bytes_by_idx[base_img_idx]
        base_md5 = hashlib.md5(raw_base).hexdigest()
        profile, is_tiled, variant_tag = classify_fue5_material(mname)
        with Image.open(io.BytesIO(raw_base)) as im:
            tw, th = target_dimensions(im.size[0], im.size[1], hero_size, max_size)
        key = (profile, is_tiled, variant_tag, tw, th, base_md5)

        local_id = (profile, is_tiled, variant_tag, base_img_idx)
        if local_id not in local_tex_cache:
            orm_bytes, nrm_bytes = cache_by_key[key]
            bv_orm = bb.add_view(orm_bytes)
            bv_nrm = bb.add_view(nrm_bytes)

            orm_img_i = len(new_images)
            new_images.append({"bufferView": bv_orm, "mimeType": "image/png"})
            nrm_img_i = len(new_images)
            new_images.append({"bufferView": bv_nrm, "mimeType": "image/png"})

            orm_tex_i = len(new_textures)
            new_textures.append({"source": orm_img_i, "sampler": sampler_idx})
            nrm_tex_i = len(new_textures)
            new_textures.append({"source": nrm_img_i, "sampler": sampler_idx})

            local_tex_cache[local_id] = (orm_tex_i, nrm_tex_i)

        orm_tex_i, nrm_tex_i = local_tex_cache[local_id]
        pbr["metallicRoughnessTexture"] = {"index": orm_tex_i}
        pbr["metallicFactor"] = 1.0
        pbr["roughnessFactor"] = 1.0
        m["occlusionTexture"] = {"index": orm_tex_i}
        m["normalTexture"] = {"index": nrm_tex_i}

    doc["textures"] = new_textures
    doc["images"] = new_images
    doc["samplers"] = samplers
    doc["bufferViews"] = bb.views
    doc["buffers"] = [{"byteLength": len(bb.buf)}]
    bake_pbr.write_glb(path, doc, bb.buf)
    return os.path.getsize(path)


def update_pack_json():
    pj_path = os.path.join(FUE5_DIR, "pack.json")
    with open(pj_path, encoding="utf-8") as f:
        data = json.load(f)
    data["shading"] = "pbr"
    tmp_path = pj_path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, indent="\t", ensure_ascii=False)
        f.write("\n")
    os.replace(tmp_path, pj_path)
    return pj_path


def verify_fue5(targets):
    errors = []
    pj_path = os.path.join(FUE5_DIR, "pack.json")
    try:
        with open(pj_path, encoding="utf-8") as f:
            pj = json.load(f)
        if pj.get("shading") != "pbr":
            errors.append(f"pack.json shading is {pj.get('shading')!r}, expected 'pbr'")
    except Exception as exc:
        errors.append(f"pack.json unreadable: {exc}")

    checked_mats = 0
    for path in targets:
        name = os.path.basename(path)
        imp = path + ".import"
        if not os.path.exists(imp):
            errors.append(f"{name}: missing .glb.import")
        else:
            imp_text = open(imp, encoding="utf-8").read()
            if "gltf/embedded_image_handling=3" not in imp_text:
                errors.append(f"{name}: .glb.import missing gltf/embedded_image_handling=3")

        doc, bin_chunk = bake_pbr.read_glb(path)
        textures = doc.get("textures", [])
        images = doc.get("images", [])
        bvs = doc.get("bufferViews", [])

        # Verify all bufferViews bounds & image signatures.
        for ii, im in enumerate(images):
            bv = bvs[im["bufferView"]]
            off = bv.get("byteOffset", 0)
            ln = bv["byteLength"]
            if off + ln > len(bin_chunk):
                errors.append(f"{name}: image[{ii}] exceeds BIN chunk")
                continue
            raw = bin_chunk[off:off + ln]
            mime = im.get("mimeType")
            if mime == "image/jpeg" and not raw.startswith(b"\xff\xd8\xff"):
                errors.append(f"{name}: image[{ii}] bad JPEG header")
            elif mime == "image/png" and not raw.startswith(b"\x89PNG\r\n\x1a\n"):
                errors.append(f"{name}: image[{ii}] bad PNG header")
            elif mime not in ("image/jpeg", "image/png"):
                errors.append(f"{name}: image[{ii}] unexpected mimeType {mime}")

        if name == "wooden-chest.glb":
            mats0 = doc.get("materials", [])
            if not mats0 or mats0[0].get("pbrMetallicRoughness", {}).get("baseColorTexture", {}).get("index") != 0:
                errors.append("wooden-chest.glb: baseColorTexture must remain at textures[0]")

        for mi, m in enumerate(doc.get("materials", [])):
            pbr = m.get("pbrMetallicRoughness", {})
            if "baseColorTexture" not in pbr:
                continue
            checked_mats += 1
            orm_t = pbr.get("metallicRoughnessTexture", {}).get("index")
            occ_t = m.get("occlusionTexture", {}).get("index")
            nrm_t = m.get("normalTexture", {}).get("index")
            if orm_t is None or occ_t is None or nrm_t is None:
                errors.append(f"{name} mat[{mi}] {m.get('name')}: missing PBR texture ref(s)")
                continue
            if occ_t != orm_t:
                errors.append(f"{name} mat[{mi}] {m.get('name')}: occlusionTexture {occ_t} != ORM {orm_t}")
            if pbr.get("metallicFactor") != 1.0 or pbr.get("roughnessFactor") != 1.0:
                errors.append(
                    f"{name} mat[{mi}] {m.get('name')}: factors=({pbr.get('metallicFactor')}, {pbr.get('roughnessFactor')})"
                )
            orm_img = images[textures[orm_t]["source"]]
            nrm_img = images[textures[nrm_t]["source"]]
            if orm_img.get("mimeType") != "image/png" or nrm_img.get("mimeType") != "image/png":
                errors.append(f"{name} mat[{mi}]: ORM/Normal must be image/png")

        # Verify COLOR_0 preserved everywhere and JOINTS_0 preserved on inserters.
        has_joints = False
        for mesh in doc.get("meshes", []):
            for pr in mesh.get("primitives", []):
                attrs = pr.get("attributes", {})
                if "COLOR_0" not in attrs:
                    errors.append(f"{name}: primitive missing COLOR_0")
                if "JOINTS_0" in attrs:
                    has_joints = True
        if name.endswith("inserter.glb") and (not doc.get("skins") or not has_joints):
            errors.append(f"{name}: missing skin or JOINTS_0")

    print(f"verify: files={len(targets)}, textured_materials={checked_mats}, errors={len(errors)}")
    for err in errors[:30]:
        print("  ERROR:", err)
    return 1 if errors else 0


def collect_targets(names):
    if not names:
        return sorted(glob.glob(os.path.join(FUE5_DIR, "*.glb")))
    out = []
    for raw in names:
        clean = raw[:-4] if raw.endswith(".glb") else raw
        p = os.path.join(FUE5_DIR, clean + ".glb")
        if not os.path.exists(p):
            raise FileNotFoundError(p)
        out.append(p)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--names", nargs="*", help="Subset of model basenames (without .glb)")
    ap.add_argument("--hero-size", type=int, default=512, help="Max dim for >=2048px textures (default: 512)")
    ap.add_argument("--max-size", type=int, default=512, help="Max dim for <=1024px textures (default: 512)")
    ap.add_argument("--jobs", type=int, default=max(1, min(8, os.cpu_count() or 4)))
    ap.add_argument("--update-pack-json", action="store_true")
    ap.add_argument("--fix-imports", action="store_true")
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    targets = collect_targets(args.names)
    if args.verify:
        return verify_fue5(targets)

    t0 = time.time()
    before_bytes = sum(os.path.getsize(p) for p in targets)

    # Phase 1: Scan all target GLBs and collect unique texture synthesis jobs.
    unique_jobs = {}
    for p in targets:
        doc, bin_chunk = bake_pbr.read_glb(p)
        textures = doc.get("textures", [])
        for m in doc.get("materials", []):
            pbr = m.get("pbrMetallicRoughness", {})
            if "baseColorTexture" not in pbr:
                continue
            ti = pbr["baseColorTexture"]["index"]
            img_i = textures[ti]["source"]
            raw_base = extract_image_bytes(doc, bin_chunk, img_i)
            base_md5 = hashlib.md5(raw_base).hexdigest()
            profile, is_tiled, variant_tag = classify_fue5_material(m.get("name", ""))
            with Image.open(io.BytesIO(raw_base)) as im:
                tw, th = target_dimensions(im.size[0], im.size[1], args.hero_size, args.max_size)
            key = (profile, is_tiled, variant_tag, tw, th, base_md5)
            if key not in unique_jobs:
                unique_jobs[key] = raw_base

    print(f"FUE5 PBR: {len(targets)} models, {len(unique_jobs)} unique textures to synthesize (before={before_bytes / 1e6:.2f} MB)")
    if args.dry_run:
        return 0

    # Phase 2: Synthesize each unique texture once (parallel).
    cache_by_key = {}
    job_list = list(unique_jobs.items())
    if args.jobs > 1 and len(job_list) > 4:
        with ProcessPoolExecutor(max_workers=args.jobs) as pool:
            for idx, (key, res) in enumerate(pool.map(_synth_worker, job_list), 1):
                cache_by_key[key] = res
                if idx % 25 == 0 or idx == len(job_list):
                    print(f"  synthesized {idx}/{len(job_list)} unique maps ({time.time() - t0:.1f}s)")
    else:
        for idx, job in enumerate(job_list, 1):
            key, res = _synth_worker(job)
            cache_by_key[key] = res

    # Phase 3: Inject ORM + Normal into each target GLB.
    after_bytes = 0
    for idx, p in enumerate(targets, 1):
        sz = rewrite_fue5_glb(p, cache_by_key, args.hero_size, args.max_size)
        after_bytes += sz
        if idx <= 5 or idx % 40 == 0 or idx == len(targets):
            print(f"  [{idx}/{len(targets)}] {os.path.basename(p)}: {sz / 1024:.1f} KB")

    if args.update_pack_json:
        pj = update_pack_json()
        print(f"updated {os.path.relpath(pj, REPO)} with shading='pbr'")

    if args.fix_imports:
        n_fix = bake_pbr.fix_imports([("fue5", p) for p in targets])
        print(f"fix_imports: updated {n_fix} .glb.import files")

    print(f"done in {time.time() - t0:.1f}s | total: {before_bytes / 1e6:.2f} MB -> {after_bytes / 1e6:.2f} MB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
