#!/usr/bin/env python3
"""Bakes procedural PBR textures (Albedo, packed ORM, tangent-space Normal) directly into the
Placeholders or Wube3DP pack's .glb files (for non-rigged, non-Zenith/belt models).

    .venv/Scripts/python tools/models/bake_pbr.py [options]
    .venv/Scripts/python tools/models/bake_pbr.py --entities --items --update-pack-json --fix-imports
    .venv/Scripts/python tools/models/bake_pbr.py --pack wube3dp --update-pack-json --fix-imports
    .venv/Scripts/python tools/models/bake_pbr.py --names assembling-machine-2 items/tungsten-plate --fix-imports
    .venv/Scripts/python tools/models/bake_pbr.py --verify
    .venv/Scripts/python tools/models/bake_pbr.py --pack wube3dp --verify

Plain Python + numpy + Pillow (no Blender required).
"""

import argparse
from collections import deque
from concurrent.futures import ProcessPoolExecutor
import glob
import io
import json
import math
import os
import re
import struct
import sys
import time
import zipfile

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
PLACEHOLDERS_DIR = os.path.join(REPO, "client", "assets", "models", "packs", "placeholders")
PLACEHOLDERS_ITEMS_DIR = os.path.join(PLACEHOLDERS_DIR, "items")
WUBE3DP_DIR = os.path.join(REPO, "client", "assets", "models", "packs", "wube3dp")
WUBE3DP_EXCLUDED_BELTS = {
    "transport-belt",
    "transport-belt-curve-left",
    "transport-belt-curve-right",
    "underground-belt-input",
    "underground-belt-output",
}
CREATURE_RIGS_JSON = os.path.join(REPO, "client", "data", "creature_rigs.json")
DEFAULT_ZENITH_ZIP = os.path.join(REPO, "models", "Zenith.zip")
HIGH_DETAIL_MODELS = {"assembling-machine-1", "assembling-machine-2", "assembling-machine-3"}

# Fallback sets if models/Zenith.zip is absent (kept in sync with Zenith.zip).
FALLBACK_ZENITH_ENTS = {
    "burner-mining-drill", "coal", "copper-ore", "iron-ore", "pipe",
    "pipe-corner-down-left", "pipe-corner-down-right", "pipe-corner-up-left",
    "pipe-corner-up-right", "pipe-cross", "pipe-ending-down", "pipe-ending-left",
    "pipe-ending-right", "pipe-ending-up", "pipe-straight-horizontal",
    "pipe-straight-vertical", "pipe-straight-vertical-single", "pipe-t-down",
    "pipe-t-left", "pipe-t-right", "pipe-t-up", "pipe-to-ground", "splitter",
    "stone", "uranium-ore",
}
FALLBACK_ZENITH_ITEMS = {
    "advanced-circuit", "automation-science-pack", "chemical-science-pack", "coal",
    "copper-cable", "copper-ore", "copper-plate", "electronic-circuit",
    "iron-gear-wheel", "iron-ore", "iron-plate", "logistic-science-pack",
    "military-science-pack", "plastic-bar", "processing-unit", "steel-plate",
    "stone", "stone-brick", "sulfur", "uranium-ore",
}
FALLBACK_RIGGED_BASES = {
    "big-biter", "big-spitter", "big-worm-turret", "big-wriggler-pentapod",
    "biter-spawner", "character", "character-armor-2", "character-armor-3",
    "character-mech-armor", "gleba-spawner", "gleba-spawner-small",
}

LEAF_PREFIXES = ("leafcard", "leaf-shadow", "leaf-0")
BELT_MATERIAL = "belt_surface"
TIER_MATERIAL = "tier_paint"
FIRE_MATERIALS = ("fire", "flame", "molten")
PAINT_GLOW_NAMES = {"lava_demolisher", "lava_demolisher_dim"}
PART_RANGE = 4.0
PART_SHARE = 0.25
PART_COLOR_SCALE = 0.82
ITEM_EXPOSURE = 0.75

# Six axis projections (T, B, N_axis) satisfying cross(T, B) == N_axis.
# U = dot(p, T), V = -dot(p, B), so +U is +T and -V (image up) is +B.
AXIS_BASES = (
    (np.array([0.0, 0.0, -1.0]), np.array([0.0, 1.0, 0.0]), np.array([1.0, 0.0, 0.0])),   # +X
    (np.array([0.0, 0.0, 1.0]), np.array([0.0, 1.0, 0.0]), np.array([-1.0, 0.0, 0.0])),  # -X
    (np.array([1.0, 0.0, 0.0]), np.array([0.0, 0.0, -1.0]), np.array([0.0, 1.0, 0.0])),  # +Y
    (np.array([1.0, 0.0, 0.0]), np.array([0.0, 0.0, 1.0]), np.array([0.0, -1.0, 0.0])),  # -Y
    (np.array([1.0, 0.0, 0.0]), np.array([0.0, 1.0, 0.0]), np.array([0.0, 0.0, 1.0])),   # +Z
    (np.array([-1.0, 0.0, 0.0]), np.array([0.0, 1.0, 0.0]), np.array([0.0, 0.0, -1.0])), # -Z
)

# Material class table matching client/scripts/world/model_library.gd.
MATERIAL_CLASSES = (
    ("fulgurite", "fulgurite"), ("scrap", "scrap"), ("wreck_yellow", "wreck_paint"),
    ("glass", "glass"), ("screen_glass", "glass"), ("panel_blue", "glass"),
    ("leaf", "foliage"), ("flesh", "organic"), ("chitin", "organic"), ("bone_", "organic"),
    ("fish_", "organic"), ("ice", "ice"), ("snow", "ice"),
    ("rubber", "dark"), ("belt_surface", "dark"), ("hazard_black", "dark"), ("soot", "dark"),
    ("steel_black", "steel_black"),
    ("bark", "wood"), ("wood", "wood"),
    ("rock_carbonic", "asteroid"), ("rock_metallic", "asteroid_metal"),
    ("rock_oxide", "asteroid"), ("rock_promethium", "asteroid"),
    ("rock", "stone"), ("stone", "stone"), ("concrete", "stone"), ("ceramic", "stone"),
    ("insulator", "stone"), ("calcite", "stone"), ("-chunk", "ore"), ("-dust", "stone"),
    ("copper", "copper"), ("brass", "copper"), ("bronze", "copper"), ("gold", "copper"),
    ("rust", "rusty"),
    ("steel_dark", "steel_dark"), ("steel", "steel"), ("iron", "steel"),
    ("tungsten", "steel_dark"),
)

# Class synthesis parameters (all values in linear/PBR [0..1]).
CLASS_PARAMS = {
    "paint": {
        "metal": 0.10, "rough": 0.50, "rust": 0.45, "streaks": 0.30, "edge_wear": 0.72,
        "grime": 0.65, "dust": 0.25, "grain": 0.06, "bump": 0.14, "aniso": (1.0, 1.0, 1.0),
        "edge_col": (0.62, 0.60, 0.56), "edge_metal": 0.80, "edge_rough": 0.28,
        "part_wear": (0.45, 0.28, 0.55, 0.15), "ao_pow": 1.0, "ground_h": 0.45,
    },
    "wreck_paint": {
        "metal": 0.12, "rough": 0.52, "rust": 0.20, "streaks": 0.12, "edge_wear": 0.55,
        "grime": 0.40, "dust": 0.10, "grain": 0.05, "bump": 0.14, "aniso": (1.0, 1.0, 1.0),
        "edge_col": (0.62, 0.60, 0.56), "edge_metal": 0.75, "edge_rough": 0.30,
        "part_wear": (0.45, 0.25, 0.50, 0.12), "ao_pow": 1.0, "ground_h": 0.45,
    },
    "steel": {
        "metal": 0.88, "rough": 0.38, "rust": 0.55, "streaks": 0.35, "edge_wear": 0.65,
        "grime": 0.65, "dust": 0.20, "grain": 0.07, "bump": 0.18, "aniso": (2.2, 0.8, 2.2),
        "edge_col": (0.72, 0.70, 0.66), "edge_metal": 0.95, "edge_rough": 0.20,
        "part_wear": (0.42, 0.25, 0.55, 0.12), "ao_pow": 1.0, "ground_h": 0.45,
    },
    "steel_dark": {
        "metal": 0.72, "rough": 0.46, "rust": 0.50, "streaks": 0.30, "edge_wear": 0.60,
        "grime": 0.60, "dust": 0.20, "grain": 0.07, "bump": 0.18, "aniso": (2.0, 0.8, 2.0),
        "edge_col": (0.58, 0.56, 0.53), "edge_metal": 0.90, "edge_rough": 0.24,
        "part_wear": (0.40, 0.25, 0.55, 0.12), "ao_pow": 1.0, "ground_h": 0.45,
    },
    "steel_black": {
        "metal": 0.38, "rough": 0.56, "rust": 0.15, "streaks": 0.10, "edge_wear": 0.45,
        "grime": 0.40, "dust": 0.25, "grain": 0.06, "bump": 0.15, "aniso": (1.4, 1.0, 1.4),
        "edge_col": (0.45, 0.45, 0.44), "edge_metal": 0.78, "edge_rough": 0.30,
        "part_wear": (0.35, 0.25, 0.50, 0.15), "ao_pow": 1.0, "ground_h": 0.45,
    },
    "copper": {
        "metal": 0.92, "rough": 0.34, "rust": 0.0, "streaks": 0.0, "edge_wear": 0.70,
        "grime": 0.60, "dust": 0.18, "grain": 0.06, "bump": 0.16, "aniso": (2.0, 0.8, 2.0),
        "edge_col": (0.84, 0.60, 0.40), "edge_metal": 0.96, "edge_rough": 0.18,
        "part_wear": (0.0, 0.25, 0.55, 0.12), "ao_pow": 1.0, "ground_h": 0.45,
    },
    "rusty": {
        "metal": 0.30, "rough": 0.84, "rust": 0.55, "streaks": 0.30, "edge_wear": 0.35,
        "grime": 0.75, "dust": 0.20, "grain": 0.12, "bump": 0.32, "aniso": (1.0, 1.0, 1.0),
        "edge_col": (0.54, 0.45, 0.38), "edge_metal": 0.60, "edge_rough": 0.48,
        "part_wear": (0.50, 0.25, 0.60, 0.15), "ao_pow": 1.0, "ground_h": 0.45,
    },
    "dark": {
        "metal": 0.0, "rough": 0.88, "rust": 0.0, "streaks": 0.0, "edge_wear": 0.25,
        "grime": 0.40, "dust": 0.30, "grain": 0.08, "bump": 0.16, "aniso": (1.0, 1.0, 1.0),
        "edge_col": (0.35, 0.34, 0.33), "edge_metal": 0.15, "edge_rough": 0.65,
        "part_wear": (0.0, 0.20, 0.50, 0.15), "ao_pow": 1.0, "ground_h": 0.45,
    },
    "wood": {
        "metal": 0.0, "rough": 0.86, "rust": 0.0, "streaks": 0.0, "edge_wear": 0.42,
        "grime": 0.65, "dust": 0.18, "grain": 0.14, "bump": 0.40, "aniso": (1.0, 0.22, 1.0),
        "edge_col": (0.68, 0.54, 0.36), "edge_metal": 0.0, "edge_rough": 0.72,
        "part_wear": (0.0, 0.22, 0.55, 0.12), "ao_pow": 1.0, "ground_h": 0.45,
    },
    "stone": {
        "metal": 0.0, "rough": 0.90, "rust": 0.0, "streaks": 0.0, "edge_wear": 0.40,
        "grime": 0.60, "dust": 0.22, "grain": 0.13, "bump": 0.38, "aniso": (1.0, 1.0, 1.0),
        "edge_col": (0.72, 0.66, 0.58), "edge_metal": 0.0, "edge_rough": 0.78,
        "part_wear": (0.0, 0.20, 0.55, 0.12), "ao_pow": 1.0, "ground_h": 0.45,
    },
    "asteroid": {
        "metal": 0.05, "rough": 0.82, "rust": 0.0, "streaks": 0.0, "edge_wear": 0.60,
        "grime": 0.90, "dust": 0.0, "grain": 0.24, "bump": 0.42, "aniso": (1.0, 1.0, 1.0),
        "edge_col": (0.72, 0.70, 0.67), "edge_metal": 0.0, "edge_rough": 0.68,
        "part_wear": (0.0, 0.35, 0.75, 0.0), "ao_pow": 1.0, "ground_h": 0.01,
    },
    "asteroid_metal": {
        "metal": 0.62, "rough": 0.55, "rust": 0.0, "streaks": 0.0, "edge_wear": 0.65,
        "grime": 0.75, "dust": 0.0, "grain": 0.20, "bump": 0.38, "aniso": (1.0, 1.0, 1.0),
        "edge_col": (0.80, 0.78, 0.75), "edge_metal": 0.85, "edge_rough": 0.32,
        "part_wear": (0.0, 0.35, 0.70, 0.0), "ao_pow": 1.0, "ground_h": 0.01,
    },
    "ore": {
        "metal": 0.15, "rough": 0.45, "rust": 0.0, "streaks": 0.0, "edge_wear": 0.25,
        "grime": 0.30, "dust": 0.10, "grain": 0.10, "bump": 0.28, "aniso": (1.0, 1.0, 1.0),
        "edge_col": (0.70, 0.70, 0.70), "edge_metal": 0.25, "edge_rough": 0.30,
        "part_wear": (0.0, 0.20, 0.45, 0.10), "ao_pow": 1.0, "ground_h": 0.45,
    },
    "glass": {
        "metal": 0.08, "rough": 0.14, "rust": 0.0, "streaks": 0.0, "edge_wear": 0.0,
        "grime": 0.20, "dust": 0.15, "grain": 0.02, "bump": 0.02, "aniso": (1.0, 1.0, 1.0),
        "edge_col": (0.8, 0.85, 0.9), "edge_metal": 0.1, "edge_rough": 0.12,
        "part_wear": (0.0, 0.0, 0.30, 0.15), "ao_pow": 0.6, "ground_h": 0.45,
    },
    "foliage": {
        "metal": 0.0, "rough": 0.82, "rust": 0.0, "streaks": 0.0, "edge_wear": 0.0,
        "grime": 0.25, "dust": 0.0, "grain": 0.10, "bump": 0.18, "aniso": (1.0, 1.0, 1.0),
        "edge_col": (0.5, 0.6, 0.4), "edge_metal": 0.0, "edge_rough": 0.75,
        "part_wear": (0.0, 0.0, 0.5, 0.0), "ao_pow": 0.45, "ground_h": 0.45,
    },
    "organic": {
        "metal": 0.0, "rough": 0.58, "rust": 0.0, "streaks": 0.0, "edge_wear": 0.15,
        "grime": 0.45, "dust": 0.10, "grain": 0.12, "bump": 0.26, "aniso": (1.2, 0.7, 1.2),
        "edge_col": (0.78, 0.60, 0.52), "edge_metal": 0.0, "edge_rough": 0.48,
        "part_wear": (0.0, 0.20, 0.50, 0.10), "ao_pow": 1.0, "ground_h": 0.45,
    },
    "scrap": {
        "metal": 0.48, "rough": 0.72, "rust": 0.70, "streaks": 0.40, "edge_wear": 0.80,
        "grime": 0.90, "dust": 0.45, "grain": 0.24, "bump": 0.34, "aniso": (1.0, 1.0, 1.0),
        "edge_col": (0.56, 0.54, 0.50), "edge_metal": 0.75, "edge_rough": 0.35,
        "part_wear": (0.85, 0.80, 1.0, 0.65), "ao_pow": 1.0, "ground_h": 0.45,
    },
    "fulgurite": {
        "metal": 0.05, "rough": 0.65, "rust": 0.0, "streaks": 0.0, "edge_wear": 0.55,
        "grime": 0.80, "dust": 0.40, "grain": 0.30, "bump": 0.36, "aniso": (1.0, 0.4, 1.0),
        "edge_col": (0.80, 0.72, 0.74), "edge_metal": 0.0, "edge_rough": 0.40,
        "part_wear": (0.0, 0.80, 0.90, 0.70), "ao_pow": 1.0, "ground_h": 0.45,
    },
    "ice": {
        "metal": 0.0, "rough": 0.22, "rust": 0.0, "streaks": 0.0, "edge_wear": 0.35,
        "grime": 0.18, "dust": 0.12, "grain": 0.07, "bump": 0.16, "aniso": (1.0, 1.0, 1.0),
        "edge_col": (0.93, 0.97, 1.0), "edge_metal": 0.0, "edge_rough": 0.14,
        "part_wear": (0.0, 0.25, 0.40, 0.15), "ao_pow": 0.8, "ground_h": 0.45,
    },
    "emissive": {
        "metal": 0.0, "rough": 0.45, "rust": 0.0, "streaks": 0.0, "edge_wear": 0.0,
        "grime": 0.0, "dust": 0.0, "grain": 0.0, "bump": 0.0, "aniso": (1.0, 1.0, 1.0),
        "edge_col": (1.0, 1.0, 1.0), "edge_metal": 0.0, "edge_rough": 0.45,
        "part_wear": (0.0, 0.0, 0.0, 0.0), "ao_pow": 0.3, "ground_h": 0.45,
    },
}


def base_of_variant(name):
    m = re.match(r"^(.+)-(\d+)$", name)
    return m.group(1) if m else name


def strip_facing(name):
    return re.sub(r"-(?:east|south|west)$", "", name)


def load_exclusions(zenith_zip_path):
    """Returns (zenith_ents, zenith_ent_bases, zenith_items, zenith_item_bases, rigged_set)."""
    if zenith_zip_path and os.path.exists(zenith_zip_path):
        z_ents, z_items = set(), set()
        with zipfile.ZipFile(zenith_zip_path) as z:
            for n in z.namelist():
                if not n.endswith(".glb"):
                    continue
                if n.startswith("items/"):
                    z_items.add(os.path.splitext(n[6:])[0])
                else:
                    z_ents.add(os.path.splitext(n)[0])
    else:
        z_ents = set(FALLBACK_ZENITH_ENTS)
        z_items = set(FALLBACK_ZENITH_ITEMS)
    z_ent_bases = {base_of_variant(x) for x in z_ents}
    z_item_bases = {base_of_variant(x) for x in z_items}

    rig_bases = set(FALLBACK_RIGGED_BASES)
    if os.path.exists(CREATURE_RIGS_JSON):
        with open(CREATURE_RIGS_JSON, encoding="utf-8") as f:
            rig_bases = set(json.load(f).keys())
    return z_ents, z_ent_bases, z_items, z_item_bases, rig_bases


def is_zenith_covered(name, exact_set, base_set, strip_dir=False):
    if name in exact_set or base_of_variant(name) in base_set:
        return True
    if strip_dir:
        bare = strip_facing(name)
        return bare in exact_set or base_of_variant(bare) in base_set
    return False


def is_rigged_entity(name, rig_bases):
    return name in rig_bases or any(name.startswith(r + "-") for r in rig_bases)


def is_wube3dp_excluded(name, rig_bases):
    return is_rigged_entity(name, rig_bases) or name in WUBE3DP_EXCLUDED_BELTS


def classify_material(name, is_emissive=False, gltf_metal=None, gltf_rough=None):
    if is_emissive:
        return "emissive", dict(CLASS_PARAMS["emissive"])
    low = name.lower()
    cls = "paint"
    for frag, target in MATERIAL_CLASSES:
        if frag in low:
            cls = target
            break
    params = dict(CLASS_PARAMS[cls])
    # Respect authored glTF roughness/metallic nuances while staying in physical range.
    if gltf_rough is not None:
        if cls in ("glass", "ice"):
            params["rough"] = float(np.clip(gltf_rough, 0.06, 0.35))
        elif cls in ("steel", "steel_dark", "copper"):
            params["rough"] = float(np.clip(gltf_rough * 0.88, 0.24, 0.65))
        elif cls == "paint":
            params["rough"] = float(np.clip(gltf_rough * 0.90, 0.32, 0.68))
    if gltf_metal is not None and cls == "ore":
        params["metal"] = float(np.clip(gltf_metal, 0.0, 0.45))
    return cls, params


def classify_item(item_name):
    low = item_name.lower()
    if "science-pack" in low or "glass" in low or "barrel" in low and "empty" not in low:
        if "science-pack" in low:
            return "glass"
    if any(k in low for k in ("copper-cable", "copper-plate", "copper-bacteria", "wire")):
        if "copper" in low:
            return "copper"
    if any(k in low for k in ("iron-plate", "iron-gear", "steel-plate", "engine-unit", "iron-stick",
                              "pipe", "tungsten-plate", "tungsten-carbide", "flying-robot-frame",
                              "low-density-structure", "electric-engine")):
        return "steel"
    if any(k in low for k in ("ice", "fluoroketone")):
        return "ice"
    if any(k in low for k in ("wood", "spoilage")):
        return "wood"
    if any(k in low for k in ("ore", "stone", "coal", "brick", "concrete", "calcite", "carbon",
                              "sulfur", "lithium", "holmium")):
        if "brick" in low or "concrete" in low or "stone" in low or "calcite" in low:
            return "stone"
        return "ore"
    if any(k in low for k in ("biter", "egg", "jelly", "yumako", "bioflux", "nutrients", "fish",
                              "pentapod", "science", "resin")):
        return "organic"
    if any(k in low for k in ("plastic", "rubber", "solid-fuel", "rocket-fuel", "nuclear-fuel", "explosives")):
        return "dark"
    if any(k in low for k in ("circuit", "module", "processor", "battery", "capacitor", "superconductor")):
        return "paint"
    return "paint"


# --- glTF binary I/O ----------------------------------------------------------------------------

COMP_DTYPE = {
    5120: np.int8,
    5121: np.uint8,
    5122: np.int16,
    5123: np.uint16,
    5125: np.uint32,
    5126: np.float32,
}
TYPE_COUNT = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def read_glb(path):
    with open(path, "rb") as f:
        data = f.read()
    magic, version, _length = struct.unpack_from("<4sII", data, 0)
    if magic != b"glTF" or version != 2:
        raise ValueError(f"{path}: not a glTF 2 binary")
    offset, doc, bin_chunk = 12, None, b""
    while offset + 8 <= len(data):
        size, kind = struct.unpack_from("<I4s", data, offset)
        body = data[offset + 8:offset + 8 + size]
        if kind == b"JSON" and doc is None:
            doc = json.loads(body.decode("utf-8"))
        elif kind == b"BIN\x00":
            bin_chunk = body
        offset += 8 + size
    if doc is None:
        raise ValueError(f"{path}: no JSON chunk")
    return doc, bin_chunk


def write_glb(path, doc, bin_chunk):
    json_bytes = json.dumps(doc, separators=(",", ":")).encode("utf-8")
    json_bytes += b" " * (-len(json_bytes) % 4)
    bin_bytes = bytes(bin_chunk) + b"\x00" * (-len(bin_chunk) % 4)
    total = 12 + 8 + len(json_bytes) + 8 + len(bin_bytes)
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total))
        f.write(struct.pack("<II", len(json_bytes), 0x4E4F534A))
        f.write(json_bytes)
        f.write(struct.pack("<II", len(bin_bytes), 0x004E4942))
        f.write(bin_bytes)
    os.replace(tmp, path)


def read_accessor(doc, bin_chunk, acc_idx):
    acc = doc["accessors"][acc_idx]
    count = acc["count"]
    ncomp = TYPE_COUNT[acc["type"]]
    dt = np.dtype(COMP_DTYPE[acc["componentType"]]).newbyteorder("<")
    bv = doc["bufferViews"][acc["bufferView"]]
    offset = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    stride = bv.get("byteStride", 0)
    elem_bytes = dt.itemsize * ncomp
    if stride and stride != elem_bytes:
        raw = np.frombuffer(bin_chunk, dtype=np.uint8, count=count * stride, offset=offset)
        arr = np.frombuffer(
            np.ascontiguousarray(raw.reshape(count, stride)[:, :elem_bytes]).tobytes(),
            dtype=dt,
        ).reshape(count, ncomp)
    else:
        arr = np.frombuffer(bin_chunk, dtype=dt, count=count * ncomp, offset=offset)
        if ncomp > 1:
            arr = arr.reshape(count, ncomp)
    if acc.get("normalized", False):
        info = np.iinfo(dt)
        arr = np.clip(arr.astype(np.float32) / float(info.max), 0.0, 1.0)
    else:
        arr = arr.astype(np.float32 if dt == np.float32 else arr.dtype)
    return arr.copy()


def node_matrix_4x4(node):
    if "matrix" in node:
        return np.array(node["matrix"], dtype=np.float64).reshape(4, 4).T
    tx, ty, tz = node.get("translation", (0.0, 0.0, 0.0))
    qx, qy, qz, qw = node.get("rotation", (0.0, 0.0, 0.0, 1.0))
    sx, sy, sz = node.get("scale", (1.0, 1.0, 1.0))
    m = np.eye(4, dtype=np.float64)
    m[0, 0] = (1.0 - 2.0 * (qy * qy + qz * qz)) * sx
    m[0, 1] = (2.0 * (qx * qy - qz * qw)) * sy
    m[0, 2] = (2.0 * (qx * qz + qy * qw)) * sz
    m[1, 0] = (2.0 * (qx * qy + qz * qw)) * sx
    m[1, 1] = (1.0 - 2.0 * (qx * qx + qz * qz)) * sy
    m[1, 2] = (2.0 * (qy * qz - qx * qw)) * sz
    m[2, 0] = (2.0 * (qx * qz - qy * qw)) * sx
    m[2, 1] = (2.0 * (qy * qz + qx * qw)) * sy
    m[2, 2] = (1.0 - 2.0 * (qx * qx + qy * qy)) * sz
    m[0, 3], m[1, 3], m[2, 3] = tx, ty, tz
    return m


def collect_node_transforms(doc):
    """Returns node_index -> (model_4x4, under_anim_glow_bool)."""
    nodes = doc.get("nodes", [])
    out = {}
    scenes = doc.get("scenes", [])
    roots = scenes[doc.get("scene", 0)].get("nodes", []) if scenes else list(range(len(nodes)))

    def visit(idx, parent_m, in_glow):
        nd = nodes[idx]
        m = parent_m @ node_matrix_4x4(nd)
        nn = nd.get("name", "")
        glow = in_glow or nn.startswith("anim_glow") or nn.startswith("anim_lit")
        out[idx] = (m, glow)
        for ch in nd.get("children", []):
            visit(ch, m, glow)

    ident = np.eye(4, dtype=np.float64)
    for r in roots:
        visit(r, ident, False)
    return out


# --- Vectorized 3D value noise -----------------------------------------------------------------

def _hash3_uint(ix, iy, iz):
    with np.errstate(over="ignore"):
        h = (ix.astype(np.uint32) * np.uint32(374761393)
             + iy.astype(np.uint32) * np.uint32(668265263)
             + iz.astype(np.uint32) * np.uint32(2147483647))
        h ^= h >> np.uint32(13)
        h *= np.uint32(1274126177)
        h ^= h >> np.uint32(16)
    return h.astype(np.float32) * np.float32(1.0 / 4294967295.0)


def vnoise3(p):
    """p: (N, 3) float32 -> (N,) float32 in [0, 1]."""
    fl = np.floor(p)
    ix = fl[:, 0].astype(np.int32)
    iy = fl[:, 1].astype(np.int32)
    iz = fl[:, 2].astype(np.int32)
    f = p - fl
    u = f * f * (3.0 - 2.0 * f)
    ux, uy, uz = u[:, 0], u[:, 1], u[:, 2]

    c000 = _hash3_uint(ix, iy, iz)
    c100 = _hash3_uint(ix + 1, iy, iz)
    c010 = _hash3_uint(ix, iy + 1, iz)
    c110 = _hash3_uint(ix + 1, iy + 1, iz)
    c001 = _hash3_uint(ix, iy, iz + 1)
    c101 = _hash3_uint(ix + 1, iy, iz + 1)
    c011 = _hash3_uint(ix, iy + 1, iz + 1)
    c111 = _hash3_uint(ix + 1, iy + 1, iz + 1)

    x00 = c000 + (c100 - c000) * ux
    x10 = c010 + (c110 - c010) * ux
    x01 = c001 + (c101 - c001) * ux
    x11 = c011 + (c111 - c011) * ux
    y0 = x00 + (x10 - x00) * uy
    y1 = x01 + (x11 - x01) * uy
    return y0 + (y1 - y0) * uz


def fbm3(p):
    return 0.50 * vnoise3(p) + 0.30 * vnoise3(p * 2.03 + 11.7) + 0.20 * vnoise3(p * 4.07 + 23.3)


# --- Chart Extraction & Packing ----------------------------------------------------------------

def extract_charts(pos_m, indices, mat_group_ids):
    """Groups triangles of a primitive into connected same-axis non-overlapping planar charts.
    Returns list of (tri_indices_array, axis_id, u_raw, v_raw) per chart."""
    ntri = len(indices) // 3
    if ntri == 0:
        return []
    tris = indices.reshape(ntri, 3)
    p0 = pos_m[tris[:, 0]]
    p1 = pos_m[tris[:, 1]]
    p2 = pos_m[tris[:, 2]]
    fn = np.cross(p1 - p0, p2 - p0)
    lens = np.linalg.norm(fn, axis=1, keepdims=True)
    fn_unit = fn / np.maximum(lens, 1e-12)

    abs_n = np.abs(fn_unit)
    dom = np.argmax(abs_n, axis=1)
    sign_neg = fn_unit[np.arange(ntri), dom] < 0
    axis_id = dom * 2 + sign_neg.astype(np.int32)

    # Quantized vertex positions for adjacency across split normals on smooth/hard edges.
    qpos = np.round(pos_m * 10000.0).astype(np.int64)
    qtris = qpos[tris]  # (ntri, 3, 3)
    vert_to_tris = {}
    for t in range(ntri):
        for k in range(3):
            key = (int(qtris[t, k, 0]), int(qtris[t, k, 1]), int(qtris[t, k, 2]))
            lst = vert_to_tris.get(key)
            if lst is None:
                vert_to_tris[key] = [t]
            else:
                lst.append(t)

    visited = np.zeros(ntri, dtype=bool)
    charts = []
    for seed in range(ntri):
        if visited[seed]:
            continue
        ax = int(axis_id[seed])
        mg = int(mat_group_ids[seed])
        seed_n = fn_unit[seed]
        comp = []
        queue = deque([seed])
        visited[seed] = True
        while queue:
            cur = queue.popleft()
            comp.append(cur)
            for k in range(3):
                key = (int(qtris[cur, k, 0]), int(qtris[cur, k, 1]), int(qtris[cur, k, 2]))
                for nb in vert_to_tris[key]:
                    if not visited[nb] and int(axis_id[nb]) == ax and int(mat_group_ids[nb]) == mg:
                        if float(np.dot(fn_unit[nb], seed_n)) >= 0.42:
                            visited[nb] = True
                            queue.append(nb)
        comp_arr = np.array(comp, dtype=np.int32)
        T, B, _ = AXIS_BASES[ax]
        u_raw = pos_m @ T
        v_raw = -(pos_m @ B)
        charts.append((comp_arr, ax, u_raw, v_raw))
    return charts


def _ortho_basis(n):
    """Returns right-handed (T, B, N) orthonormal basis satisfying cross(T, B) == N."""
    ref = np.array([0.0, 1.0, 0.0], dtype=np.float32) if abs(float(n[1])) < 0.9 else np.array([0.0, 0.0, -1.0], dtype=np.float32)
    t = np.cross(ref, n)
    t = t / max(float(np.linalg.norm(t)), 1e-12)
    b = np.cross(n, t)
    return t.astype(np.float32), b.astype(np.float32), n.astype(np.float32)


def extract_charts_adaptive(pos_m, indices, mat_group_ids):
    """Groups triangles into smooth edge-connected UV charts with adaptive projection normals
    so high-poly sculpted CAD/STL meshes avoid excessive micro-island fragmentation."""
    ntri = len(indices) // 3
    if ntri == 0:
        return []
    tris = indices.reshape(ntri, 3)
    p0, p1, p2 = pos_m[tris[:, 0]], pos_m[tris[:, 1]], pos_m[tris[:, 2]]
    fn = np.cross(p1 - p0, p2 - p0)
    lens = np.linalg.norm(fn, axis=1)
    fn_u = fn / np.maximum(lens[:, None], 1e-12)

    qpos = np.round(pos_m * 10000.0).astype(np.int64)
    qtris = qpos[tris]
    edge_to_tris = {}
    for t in range(ntri):
        for k in range(3):
            a = (int(qtris[t, k, 0]), int(qtris[t, k, 1]), int(qtris[t, k, 2]))
            c = (int(qtris[t, (k + 1) % 3, 0]), int(qtris[t, (k + 1) % 3, 1]), int(qtris[t, (k + 1) % 3, 2]))
            ek = (a, c) if a < c else (c, a)
            lst = edge_to_tris.get(ek)
            if lst is None:
                edge_to_tris[ek] = [t]
            else:
                lst.append(t)

    # Phase 1: area-first greedy growth along edge adjacency with running area-weighted normal.
    vis = np.zeros(ntri, dtype=bool)
    charts = []
    chart_ns = []
    chart_mgs = []
    tri_chart = np.full(ntri, -1, dtype=np.int32)
    for seed in np.argsort(-lens):
        seed = int(seed)
        if vis[seed]:
            continue
        ci = len(charts)
        mg = int(mat_group_ids[seed])
        seed_n = fn_u[seed]
        n_sum = fn[seed].copy()
        cur_n = seed_n.copy()
        comp = []
        st = [seed]
        vis[seed] = True
        while st:
            u = st.pop()
            comp.append(u)
            tri_chart[u] = ci
            for k in range(3):
                a = (int(qtris[u, k, 0]), int(qtris[u, k, 1]), int(qtris[u, k, 2]))
                c = (int(qtris[u, (k + 1) % 3, 0]), int(qtris[u, (k + 1) % 3, 1]), int(qtris[u, (k + 1) % 3, 2]))
                ek = (a, c) if a < c else (c, a)
                for nb in edge_to_tris[ek]:
                    if not vis[nb] and int(mat_group_ids[nb]) == mg:
                        if float(np.dot(fn_u[nb], cur_n)) >= 0.25 and float(np.dot(fn_u[nb], seed_n)) >= 0.15:
                            vis[nb] = True
                            st.append(nb)
                            n_sum = n_sum + fn[nb]
                            nl = float(np.linalg.norm(n_sum))
                            if nl > 1e-12:
                                cur_n = n_sum / nl
        charts.append(comp)
        chart_ns.append(cur_n)
        chart_mgs.append(mg)

    # Phase 2: greedy merge of adjacent charts (smallest first) keeping all tris front-facing.
    for _pass in range(4):
        merged = 0
        c_order = sorted((ci for ci in range(len(charts)) if charts[ci]), key=lambda ci: len(charts[ci]))
        for ci in c_order:
            ct = charts[ci]
            if not ct:
                continue
            mg = chart_mgs[ci]
            nbs = {}
            for t in ct:
                for k in range(3):
                    a = (int(qtris[t, k, 0]), int(qtris[t, k, 1]), int(qtris[t, k, 2]))
                    c = (int(qtris[t, (k + 1) % 3, 0]), int(qtris[t, (k + 1) % 3, 1]), int(qtris[t, (k + 1) % 3, 2]))
                    ek = (a, c) if a < c else (c, a)
                    for nb in edge_to_tris[ek]:
                        nci = int(tri_chart[nb])
                        if nci != ci and charts[nci] and chart_mgs[nci] == mg:
                            nbs[nci] = nbs.get(nci, 0) + 1
            best = -1
            best_sc = -1.0
            best_n = None
            for nci, se in sorted(nbs.items(), key=lambda kv: -kv[1])[:8]:
                comb = ct + charts[nci]
                ns = fn[comb].sum(axis=0)
                nl = float(np.linalg.norm(ns))
                if nl < 1e-12:
                    continue
                cn = ns / nl
                dots = fn_u[comb] @ cn
                if float(dots.min()) >= 0.08:
                    sc = se * float(dots.mean())
                    if sc > best_sc:
                        best_sc = sc
                        best = nci
                        best_n = cn
            if best >= 0:
                for t in ct:
                    tri_chart[t] = best
                charts[best].extend(ct)
                chart_ns[best] = best_n
                charts[ci] = []
                merged += 1
        if not merged:
            break

    out = []
    for ci, ct in enumerate(charts):
        if not ct:
            continue
        comp_arr = np.array(ct, dtype=np.int32)
        T, B, _ = _ortho_basis(chart_ns[ci])
        u_raw = pos_m @ T
        v_raw = -(pos_m @ B)
        out.append((comp_arr, ci, u_raw, v_raw))
    return out


def pack_charts(charts_info, atlas_size, margin_px=2.5):
    """charts_info: list of dict with keys (u0, u1, v0, v1, ...).
    Finds uniform scale via binary search and shelf-packs inside atlas_size x atlas_size.
    Sets ('px_x', 'px_y', 'scale') on each chart dict."""
    if not charts_info:
        return 1.0
    sizes = []
    for c in charts_info:
        w = max(c["u1"] - c["u0"], 1e-4)
        h = max(c["v1"] - c["v0"], 1e-4)
        sizes.append((w, h, c))

    # Order largest height first for compact shelf packing.
    sizes.sort(key=lambda item: (-max(item[1], item[0]), -item[0]))
    pad = 2.0 * margin_px

    def try_pack(scale):
        x, y, row_h = 0.0, 0.0, 0.0
        placements = []
        for w, h, c in sizes:
            pw = w * scale + pad
            ph = h * scale + pad
            if pw > atlas_size or ph > atlas_size:
                return None
            if x + pw > atlas_size + 1e-6:
                y += row_h
                x = 0.0
                row_h = 0.0
            if y + ph > atlas_size + 1e-6:
                return None
            placements.append((c, x + margin_px, y + margin_px))
            x += pw
            if ph > row_h:
                row_h = ph
        return placements

    total_area = sum(w * h for w, h, _ in sizes)
    max_dim = max(max(w, h) for w, h, _ in sizes)
    hi = min((atlas_size - pad) / max_dim, math.sqrt((atlas_size * atlas_size) / max(total_area, 1e-8)))
    lo = 0.1
    best_scale = lo
    best_place = try_pack(lo)
    for _ in range(20):
        mid = 0.5 * (lo + hi)
        res = try_pack(mid)
        if res is not None:
            best_scale = mid
            best_place = res
            lo = mid
        else:
            hi = mid
    if best_place is None:
        # Fallback: individual unit scaling if extreme aspect ratios occurred.
        n = len(sizes)
        cols = max(1, int(math.ceil(math.sqrt(n))))
        cell = atlas_size / cols
        for idx, (w, h, c) in enumerate(sizes):
            cx = (idx % cols) * cell + margin_px
            cy = (idx // cols) * cell + margin_px
            s_local = (cell - pad) / max(w, h)
            c["px_x"], c["px_y"], c["scale"] = cx, cy, s_local
        return 1.0

    for c, px, py in best_place:
        c["px_x"] = px
        c["px_y"] = py
        c["scale"] = best_scale
    return best_scale


# --- Vectorized Rasterization & Texture Generation ---------------------------------------------

def rasterize_charts(atlas_size, tris_data):
    """tris_data: dict with per-triangle packed arrays across all baked charts:
      uv_px: (T, 3, 2) pixel coords in [0, S]
      pos_m: (T, 3, 3), norm_m: (T, 3, 3), color: (T, 3, 4), edge: (T, 3, 2), part_rgba: (T, 3, 4)
      chart_id: (T,), mat_id: (T,)
    Returns per-pixel buffers of shape (S, S, ...)."""
    S = atlas_size
    uv = tris_data["uv_px"]
    T = len(uv)
    chart_buf = np.full((S, S), -1, dtype=np.int32)
    mat_buf = np.zeros((S, S), dtype=np.int32)
    pos_buf = np.zeros((S, S, 3), dtype=np.float32)
    nrm_buf = np.zeros((S, S, 3), dtype=np.float32)
    col_buf = np.ones((S, S, 4), dtype=np.float32)
    edg_buf = np.zeros((S, S, 2), dtype=np.float32)
    prt_buf = np.zeros((S, S, 4), dtype=np.float32)

    if T == 0:
        return chart_buf, mat_buf, pos_buf, nrm_buf, col_buf, edg_buf, prt_buf

    u0, v0 = uv[:, 0, 0], uv[:, 0, 1]
    u1, v1 = uv[:, 1, 0], uv[:, 1, 1]
    u2, v2 = uv[:, 2, 0], uv[:, 2, 1]

    xmin = np.clip(np.floor(np.minimum(np.minimum(u0, u1), u2)).astype(np.int32), 0, S - 1)
    xmax = np.clip(np.ceil(np.maximum(np.maximum(u0, u1), u2)).astype(np.int32), 0, S - 1)
    ymin = np.clip(np.floor(np.minimum(np.minimum(v0, v1), v2)).astype(np.int32), 0, S - 1)
    ymax = np.clip(np.ceil(np.maximum(np.maximum(v0, v1), v2)).astype(np.int32), 0, S - 1)

    bw = np.maximum(0, xmax - xmin + 1)
    bh = np.maximum(0, ymax - ymin + 1)
    area = bw.astype(np.int64) * bh.astype(np.int64)
    denom = (u1 - u0) * (v2 - v0) - (u2 - u0) * (v1 - v0)
    valid = (np.abs(denom) > 1e-10) & (bw > 0) & (bh > 0)

    hit_tri = np.zeros(T, dtype=bool)
    small_idx = np.flatnonzero(valid & (area <= 2048))
    large_idx = np.flatnonzero(valid & (area > 2048))

    def stamp_pixels(px_tri, px_x, px_y, w0, w1, w2):
        hit_tri[px_tri] = True
        chart_buf[px_y, px_x] = tris_data["chart_id"][px_tri]
        mat_buf[px_y, px_x] = tris_data["mat_id"][px_tri]

        def interp(arr):
            return (arr[px_tri, 0] * w0[:, None]
                    + arr[px_tri, 1] * w1[:, None]
                    + arr[px_tri, 2] * w2[:, None])

        pos_buf[px_y, px_x] = interp(tris_data["pos_m"])
        nrm_buf[px_y, px_x] = interp(tris_data["norm_m"])
        col_buf[px_y, px_x] = interp(tris_data["color"])
        edg_buf[px_y, px_x] = interp(tris_data["edge"])
        prt_buf[px_y, px_x] = interp(tris_data["part_rgba"])

    # Vectorized expansion in bounded candidate chunks (~600k candidates max per batch).
    batch_start = 0
    while batch_start < len(small_idx):
        batch_end = batch_start
        cand_sum = 0
        while batch_end < len(small_idx) and (cand_sum < 500000 or batch_end == batch_start):
            cand_sum += int(area[small_idx[batch_end]])
            batch_end += 1
        sub = small_idx[batch_start:batch_end]
        batch_start = batch_end

        h_sub = bh[sub]
        r_starts = np.zeros(len(sub), dtype=np.int64)
        if len(sub) > 1:
            r_starts[1:] = np.cumsum(h_sub[:-1])
        row_tri = np.repeat(sub, h_sub)
        row_y = ymin[row_tri] + (np.arange(len(row_tri), dtype=np.int32) - np.repeat(r_starts, h_sub).astype(np.int32))

        rw = bw[row_tri]
        p_starts = np.zeros(len(row_tri), dtype=np.int64)
        if len(row_tri) > 1:
            p_starts[1:] = np.cumsum(rw[:-1])
        px_tri = np.repeat(row_tri, rw)
        px_y = np.repeat(row_y, rw)
        px_x = xmin[px_tri] + (np.arange(len(px_tri), dtype=np.int32) - np.repeat(p_starts, rw).astype(np.int32))

        cx = px_x.astype(np.float32) + 0.5
        cy = px_y.astype(np.float32) + 0.5
        inv_d = 1.0 / denom[px_tri]
        w1 = ((cx - u0[px_tri]) * (v2[px_tri] - v0[px_tri]) - (u2[px_tri] - u0[px_tri]) * (cy - v0[px_tri])) * inv_d
        w2 = ((u1[px_tri] - u0[px_tri]) * (cy - v0[px_tri]) - (cx - u0[px_tri]) * (v1[px_tri] - v0[px_tri])) * inv_d
        w0 = 1.0 - w1 - w2
        inside = (w0 >= -1e-4) & (w1 >= -1e-4) & (w2 >= -1e-4)
        if np.any(inside):
            w0i = np.clip(w0[inside], 0.0, 1.0)
            w1i = np.clip(w1[inside], 0.0, 1.0)
            w2i = np.clip(w2[inside], 0.0, 1.0)
            s = np.maximum(w0i + w1i + w2i, 1e-6)
            stamp_pixels(px_tri[inside], px_x[inside], px_y[inside], w0i / s, w1i / s, w2i / s)

    for ti in large_idx:
        xs = np.arange(xmin[ti], xmax[ti] + 1, dtype=np.int32)
        ys = np.arange(ymin[ti], ymax[ti] + 1, dtype=np.int32)
        gx, gy = np.meshgrid(xs, ys)
        px_x = gx.ravel()
        px_y = gy.ravel()
        cx = px_x.astype(np.float32) + 0.5
        cy = px_y.astype(np.float32) + 0.5
        inv_d = 1.0 / denom[ti]
        w1 = ((cx - u0[ti]) * (v2[ti] - v0[ti]) - (u2[ti] - u0[ti]) * (cy - v0[ti])) * inv_d
        w2 = ((u1[ti] - u0[ti]) * (cy - v0[ti]) - (cx - u0[ti]) * (v1[ti] - v0[ti])) * inv_d
        w0 = 1.0 - w1 - w2
        inside = (w0 >= -1e-4) & (w1 >= -1e-4) & (w2 >= -1e-4)
        if np.any(inside):
            w0i = np.clip(w0[inside], 0.0, 1.0)
            w1i = np.clip(w1[inside], 0.0, 1.0)
            w2i = np.clip(w2[inside], 0.0, 1.0)
            s = np.maximum(w0i + w1i + w2i, 1e-6)
            stamp_pixels(np.full(len(w0i), ti, dtype=np.int32), px_x[inside], px_y[inside], w0i / s, w1i / s, w2i / s)

    # Guarantee every triangle (even tiny sub-pixel slivers) paints at least its centroid pixel.
    missed = np.flatnonzero(~hit_tri)
    if len(missed) > 0:
        cx_p = np.clip(np.floor((u0[missed] + u1[missed] + u2[missed]) / 3.0).astype(np.int32), 0, S - 1)
        cy_p = np.clip(np.floor((v0[missed] + v1[missed] + v2[missed]) / 3.0).astype(np.int32), 0, S - 1)
        empty = chart_buf[cy_p, cx_p] < 0
        if np.any(empty):
            m_sub = missed[empty]
            w_third = np.full(len(m_sub), 1.0 / 3.0, dtype=np.float32)
            stamp_pixels(m_sub, cx_p[empty], cy_p[empty], w_third, w_third, w_third)

    return chart_buf, mat_buf, pos_buf, nrm_buf, col_buf, edg_buf, prt_buf


def dilate_atlas(img, valid_mask, passes=5):
    """Bleeds covered texel colours out into gutter pixels so mipmaps never sample black edges."""
    out = img.copy()
    mask = valid_mask.copy()
    for _ in range(passes):
        if np.all(mask):
            break
        acc = np.zeros_like(out, dtype=np.float32)
        cnt = np.zeros(mask.shape, dtype=np.float32)
        # 4-neighbour pull
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            sy0, sy1 = max(0, dy), out.shape[0] + min(0, dy)
            sx0, sx1 = max(0, dx), out.shape[1] + min(0, dx)
            ty0, ty1 = max(0, -dy), out.shape[0] + min(0, -dy)
            tx0, tx1 = max(0, -dx), out.shape[1] + min(0, -dx)
            m = mask[sy0:sy1, sx0:sx1]
            acc[ty0:ty1, tx0:tx1] += np.where(m[..., None] if out.ndim == 3 else m, out[sy0:sy1, sx0:sx1], 0.0)
            cnt[ty0:ty1, tx0:tx1] += m.astype(np.float32)
        fill = (~mask) & (cnt > 0)
        if not np.any(fill):
            break
        if out.ndim == 3:
            out[fill] = acc[fill] / cnt[fill, None]
        else:
            out[fill] = acc[fill] / cnt[fill]
        mask |= fill
    return out


def linear_to_srgb(lin):
    lin = np.clip(lin, 0.0, 1.0)
    return np.where(lin <= 0.0031308, lin * 12.92, 1.055 * np.power(lin, 1.0 / 2.4) - 0.055)


def synthesize_entity_textures(atlas_size, tris_data, mat_specs, seed_offset=0, high_detail=False):
    """Renders Albedo (uint8 RGB/RGBA), ORM (uint8 RGB), and Normal (uint8 RGB) atlases."""
    S = atlas_size
    chart_buf, mat_buf, pos_buf, nrm_buf, col_buf, edg_buf, prt_buf = rasterize_charts(S, tris_data)
    valid = chart_buf >= 0
    ys, xs = np.nonzero(valid)
    if len(ys) == 0:
        albedo_u8 = np.full((S, S, 4), (180, 180, 180, 255), dtype=np.uint8)
        orm_u8 = np.full((S, S, 3), (255, 180, 0), dtype=np.uint8)
        nrm_u8 = np.full((S, S, 3), (128, 128, 255), dtype=np.uint8)
        return albedo_u8, orm_u8, nrm_u8

    mids = mat_buf[ys, xs]
    p = pos_buf[ys, xs]
    n = nrm_buf[ys, xs]
    n_len = np.linalg.norm(n, axis=1, keepdims=True)
    n = n / np.maximum(n_len, 1e-8)
    tint = np.maximum(col_buf[ys, xs, :3], 0.0)
    v_ao = np.clip(col_buf[ys, xs, 3], 0.0, 1.0)
    edge = np.clip(edg_buf[ys, xs, 0], 0.0, 1.0)
    part_seed = edg_buf[ys, xs, 1]

    # Decode CUSTOM1 part colours (headroom vs legacy layout, factorio_material.gdshaderinc:1408).
    pa = prt_buf[ys, xs, 3]
    headroom = pa <= (PART_SHARE + 1e-4)
    pc = np.clip(np.where(headroom, pa / PART_SHARE, pa), 0.0, 1.0)
    part_rgb = np.maximum(prt_buf[ys, xs, :3], 0.0) * np.where(headroom, PART_RANGE, 1.0)[:, None]
    part_rgb = np.clip(part_rgb * PART_COLOR_SCALE, 0.0, 1.0)

    # Per-pixel material tables.
    M = len(mat_specs)
    def table(fn, dtype=np.float32):
        return np.array([fn(ms) for ms in mat_specs], dtype=dtype)[mids]

    m_base = table(lambda ms: ms["base_rgb"])
    m_base_a = table(lambda ms: ms["base_alpha"])
    m_metal = table(lambda ms: ms["params"]["metal"])
    m_rough = table(lambda ms: ms["params"]["rough"])
    m_rust = table(lambda ms: ms["params"]["rust"])
    m_streaks = table(lambda ms: ms["params"]["streaks"])
    m_edge_w = table(lambda ms: ms["params"]["edge_wear"])
    m_grime = table(lambda ms: ms["params"]["grime"])
    m_dust = table(lambda ms: ms["params"]["dust"])
    m_grain = table(lambda ms: ms["params"]["grain"])
    m_bump = table(lambda ms: ms["params"]["bump"])
    m_aniso = table(lambda ms: ms["params"]["aniso"])
    m_edge_col = table(lambda ms: ms["params"]["edge_col"])
    m_edge_met = table(lambda ms: ms["params"]["edge_metal"])
    m_edge_rgh = table(lambda ms: ms["params"]["edge_rough"])
    m_wear = table(lambda ms: ms["params"]["part_wear"])
    m_ao_pow = table(lambda ms: ms["params"]["ao_pow"])
    m_ground_h = table(lambda ms: ms["params"]["ground_h"])
    m_neutral = table(lambda ms: 1.0 if ms["mode"] == "neutral" else 0.0, dtype=np.float32)
    m_glow_keep = table(lambda ms: 1.0 if ms["mode"] == "glow_keep" else 0.0, dtype=np.float32)
    m_has_parts = table(lambda ms: 1.0 if ms["has_parts"] else 0.0, dtype=np.float32)
    m_is_paint = table(lambda ms: 1.0 if ms.get("cls") in ("paint", "wreck_paint") else 0.0, dtype=np.float32)
    m_is_steel = table(lambda ms: 1.0 if ms.get("cls") in ("steel", "steel_dark", "steel_black") else 0.0, dtype=np.float32)
    m_is_cast = table(lambda ms: 1.0 if ms.get("cls") in ("rusty", "copper") else 0.0, dtype=np.float32)

    if high_detail:
        # Preserve sharp metal/copper/paint separation while keeping Factorio's macro-shading.
        pc_scale = np.where(m_is_paint > 0.5, 0.34, np.where((m_is_steel > 0.5) | (m_is_cast > 0.5), 0.14, 0.55))
        pc_eff = pc * m_has_parts * pc_scale
    else:
        pc_eff = pc * m_has_parts
    col = m_base * (1.0 - pc_eff)[:, None] + part_rgb * pc_eff[:, None]
    col = col * tint

    # Keep neutral greyscale texture for tier_paint so runtime colour tints work accurately.
    lum_col = 0.2126 * col[:, 0] + 0.7152 * col[:, 1] + 0.0722 * col[:, 2]
    neutral_val = np.clip(0.85 + 0.15 * (lum_col - 0.35), 0.75, 1.0)
    col = np.where(m_neutral[:, None] > 0.5, neutral_val[:, None], col)

    # For anim_glow* materials without emissiveFactor: keep palette baseColorFactor and put surface mod in tex.
    ratio_col = np.clip(col / np.maximum(m_base, 0.03), 0.35, 1.0)
    col = np.where(m_glow_keep[:, None] > 0.5, ratio_col, col)

    # Deterministic 3D noise octaves on covered pixels only.
    np_p = p + np.array([seed_offset * 13.7, 0.0, seed_offset * 19.3], dtype=np.float32) + part_seed[:, None] * 11.0
    patches = fbm3(np_p * 2.4)
    mid = vnoise3(np_p * 7.5 + 5.0)
    aniso_p = np_p * m_aniso
    fine = vnoise3(aniso_p * 26.0)
    micro = vnoise3(aniso_p * 52.0 + 17.0)

    # Subtle surface mottling.
    col = col * (1.0 + m_grain * ((fine - 0.5) * 1.3 + (mid - 0.5) * 1.1))[:, None]

    # Rust patches + streaks.
    occluded = 1.0 - v_ao
    side = 1.0 - np.abs(n[:, 1])
    low = 1.0 - np.clip((p[:, 1]) / 0.9, 0.0, 1.0)
    rust_place = 0.25 * occluded + 0.12 * low + 0.2 * (part_seed - 0.5)
    rust_mask = np.clip((patches + rust_place - 0.62) / 0.18, 0.0, 1.0)
    rust_mask = rust_mask * rust_mask * (3.0 - 2.0 * rust_mask)
    streak_v = np.zeros_like(rust_mask)
    has_str = (m_streaks > 0.0) & (side > 0.05)
    if np.any(has_str):
        ps = np_p[has_str]
        s1 = np.clip((vnoise3(np.stack([ps[:, 0] * 11.0, ps[:, 1] * 0.9, ps[:, 2] * 11.0], axis=1)) - 0.55) / 0.30, 0.0, 1.0)
        s2 = np.clip((vnoise3(ps * 1.7 + 3.0) - 0.35) / 0.30, 0.0, 1.0)
        streak_v[has_str] = s1 * s1 * (3.0 - 2.0 * s1) * s2 * s2 * (3.0 - 2.0 * s2) * side[has_str]

    wear_mix = np.ones((len(ys), 4), dtype=np.float32) * (1.0 - pc_eff)[:, None] + m_wear * pc_eff[:, None]
    r_amt = np.clip((m_rust * rust_mask * (0.6 + 0.6 * fine) + m_streaks * streak_v) * wear_mix[:, 0], 0.0, 1.0)
    rust_col = np.array([0.32, 0.14, 0.06], dtype=np.float32)[None, :] * (0.75 + 0.5 * mid)[:, None]
    col = col * (1.0 - r_amt)[:, None] + rust_col * r_amt[:, None]
    metal = m_metal * (1.0 - r_amt) + 0.18 * r_amt
    rough = m_rough * (1.0 - r_amt) + 0.90 * r_amt + 0.06 * (fine - 0.5)

    # Worn edges: chipped back to bright bare metal (or lighter wood/stone).
    chips = np.clip((vnoise3(np_p * 31.0) + 0.25 * edge - 0.32) / 0.28, 0.0, 1.0)
    chips = chips * chips * (3.0 - 2.0 * chips)
    e_amt = np.clip(m_edge_w * wear_mix[:, 1] * edge * chips * (1.0 - 0.6 * r_amt), 0.0, 1.0)
    e_col = np.where(m_neutral[:, None] > 0.5, 0.96, m_edge_col) * (0.88 + 0.24 * fine)[:, None]
    col = col * (1.0 - e_amt)[:, None] + e_col * e_amt[:, None]
    metal = metal * (1.0 - e_amt) + m_edge_met * e_amt
    rough = rough * (1.0 - e_amt) + m_edge_rgh * e_amt

    # Crevice grime & base grime.
    ground = 1.0 - np.clip(p[:, 1] / np.maximum(m_ground_h, 0.01), 0.0, 1.0)
    grime_amt = m_grime * wear_mix[:, 2] * np.clip(occluded * 1.3 + ground * 0.75, 0.0, 1.0)
    g_amt = np.clip(grime_amt * (0.50 + 0.60 * patches), 0.0, 0.80)
    grime_col = np.array([0.08, 0.07, 0.055], dtype=np.float32)[None, :]
    col = col * (1.0 - g_amt)[:, None] + grime_col * g_amt[:, None]
    metal = metal * (1.0 - g_amt) + 0.05 * g_amt
    rough = rough * (1.0 - g_amt) + 0.93 * g_amt

    # Dust on upward surfaces.
    up_mask = np.clip((n[:, 1] - 0.35) / 0.60, 0.0, 1.0)
    up_mask = up_mask * up_mask * (3.0 - 2.0 * up_mask)
    d_patch = np.clip((patches + 0.2 * fine - 0.30) / 0.40, 0.0, 1.0)
    d_amt = np.clip(m_dust * wear_mix[:, 3] * up_mask * d_patch, 0.0, 0.65)
    dust_col = np.array([0.36, 0.32, 0.25], dtype=np.float32)[None, :]
    col = col * (1.0 - d_amt)[:, None] + dust_col * d_amt[:, None]
    metal = metal * (1.0 - d_amt)
    rough = rough * (1.0 - d_amt) + 0.96 * d_amt

    extra_height = np.zeros(len(ys), dtype=np.float32)
    if high_detail:
        # High-frequency industrial detail: hammered paint peel, machined metal grain, cast pitting, oil & scratches.
        peel = vnoise3(np_p * 74.0) * 0.65 + vnoise3(np_p * 142.0 + 9.0) * 0.35
        machined = vnoise3(aniso_p * 64.0 + 3.1) * 0.6 + vnoise3(aniso_p * 124.0 + 19.0) * 0.4
        cast_pit = np.clip((0.48 - fbm3(np_p * 29.0)) * 2.5, 0.0, 1.0) * (0.4 + 0.6 * peel)

        # Directional industrial scratches cutting down to bright bare steel.
        sc1 = np.clip((vnoise3(np.stack([np_p[:, 0] * 36.0, np_p[:, 1] * 125.0, np_p[:, 2] * 36.0], axis=1)) - 0.77) / 0.07, 0.0, 1.0)
        sc2 = np.clip((vnoise3(np.stack([np_p[:, 0] * 118.0, np_p[:, 1] * 32.0, np_p[:, 2] * 118.0], axis=1)) - 0.78) / 0.07, 0.0, 1.0)
        sc_gate = np.clip((patches + edge * 0.6 - 0.45) / 0.30, 0.0, 1.0)
        sc_mask = np.clip((sc1 + sc2) * 0.85 * sc_gate * (m_is_paint + 0.6 * m_is_steel), 0.0, 1.0)
        sc_col = m_edge_col * (0.95 + 0.15 * fine)[:, None]
        col = col * (1.0 - 0.75 * sc_mask)[:, None] + sc_col * (0.75 * sc_mask)[:, None]
        metal = np.maximum(metal, 0.90 * sc_mask)
        rough = rough * (1.0 - sc_mask) + 0.20 * sc_mask

        # Machined steel polish vs sand-cast iron/copper roughness contrast & glossy oil patches in low interior recesses.
        rough = np.where(m_is_steel > 0.5, np.clip(rough * 0.74 + 0.12 * (machined - 0.5), 0.14, 0.72), rough)
        metal = np.where(m_is_steel > 0.5, np.clip(metal + 0.08 * (1.0 - r_amt - g_amt), 0.0, 0.96), metal)
        metal = np.where(m_is_cast > 0.5, np.clip(metal + 0.14 * (1.0 - cast_pit) * (1.0 - g_amt), 0.0, 0.94), metal)
        rough = np.where(m_is_cast > 0.5, np.clip(rough * 0.85 + 0.25 * cast_pit, 0.26, 0.92), rough)

        oil_patch = np.clip((occluded * 0.9 + low * 0.5 - 0.68) / 0.22, 0.0, 1.0) * np.clip((patches - 0.42) / 0.25, 0.0, 1.0)
        col = col * (1.0 - 0.45 * oil_patch)[:, None]
        rough = rough * (1.0 - 0.70 * oil_patch) + 0.13 * (0.70 * oil_patch)

        extra_height = (
            m_is_paint * (peel - 0.5) * 0.14
            + m_is_steel * (machined - 0.5) * 0.22
            - m_is_cast * cast_pit * 0.28
            - sc_mask * 0.24
        )

    # Lift dark high-metal steel slightly so sky reflections keep readable charcoal tones.
    dark_met = metal > 0.65
    if np.any(dark_met):
        col[dark_met] = np.maximum(col[dark_met], 0.065)

    # Baked AO goes cleanly into ORM.r (mild cavity tint in albedo for deep crevices).
    ao_pow = m_ao_pow * (1.35 if high_detail else 1.0)
    ao_val = np.clip(np.power(np.maximum(v_ao, 0.01), ao_pow) * (1.0 - (0.34 if high_detail else 0.28) * g_amt), 0.12 if high_detail else 0.15, 1.0)
    col = col * ((0.76 + 0.24 * ao_val) if high_detail else (0.85 + 0.15 * ao_val))[:, None]

    # Scalar height field for tangent-space normal generation.
    bump_scale = 1.65 if high_detail else 1.0
    height = ((
        (fine - 0.5) * 0.55
        + (micro - 0.5) * 0.30
        + (mid - 0.5) * 0.25
        + e_amt * 0.28
        - r_amt * 0.35
    ) * m_bump + extra_height) * bump_scale

    albedo_lin = np.zeros((S, S, 4), dtype=np.float32)
    orm_f = np.zeros((S, S, 3), dtype=np.float32)
    h_grid = np.zeros((S, S), dtype=np.float32)

    albedo_lin[ys, xs, :3] = np.clip(col, 0.0, 1.0)
    albedo_lin[ys, xs, 3] = np.clip(m_base_a, 0.0, 1.0)
    orm_f[ys, xs, 0] = ao_val
    orm_f[ys, xs, 1] = np.clip(rough, 0.05, 1.0)
    orm_f[ys, xs, 2] = np.clip(metal, 0.0, 1.0)
    h_grid[ys, xs] = height

    # Compute tangent-space normal strictly inside each chart (zero cross-seam spikes).
    dh_dx = np.zeros((S, S), dtype=np.float32)
    dh_dy = np.zeros((S, S), dtype=np.float32)
    same_l = np.zeros((S, S), dtype=bool)
    same_r = np.zeros((S, S), dtype=bool)
    same_u = np.zeros((S, S), dtype=bool)
    same_d = np.zeros((S, S), dtype=bool)
    same_l[:, 1:] = valid[:, 1:] & (chart_buf[:, 1:] == chart_buf[:, :-1])
    same_r[:, :-1] = valid[:, :-1] & (chart_buf[:, :-1] == chart_buf[:, 1:])
    same_u[1:, :] = valid[1:, :] & (chart_buf[1:, :] == chart_buf[:-1, :])
    same_d[:-1, :] = valid[:-1, :] & (chart_buf[:-1, :] == chart_buf[1:, :])

    both_x = same_l & same_r
    dh_dx[both_x] = 0.5 * (np.roll(h_grid, -1, axis=1)[both_x] - np.roll(h_grid, 1, axis=1)[both_x])
    only_r = (~same_l) & same_r
    dh_dx[only_r] = np.roll(h_grid, -1, axis=1)[only_r] - h_grid[only_r]
    only_l = same_l & (~same_r)
    dh_dx[only_l] = h_grid[only_l] - np.roll(h_grid, 1, axis=1)[only_l]

    both_y = same_u & same_d
    dh_dy[both_y] = 0.5 * (np.roll(h_grid, -1, axis=0)[both_y] - np.roll(h_grid, 1, axis=0)[both_y])
    only_d = (~same_u) & same_d
    dh_dy[only_d] = np.roll(h_grid, -1, axis=0)[only_d] - h_grid[only_d]
    only_u = same_u & (~same_d)
    dh_dy[only_u] = h_grid[only_u] - np.roll(h_grid, 1, axis=0)[only_u]

    # OpenGL tangent frame (+X = +U, +Y = -V = up in image).
    n_scale = 3.6 if high_detail else 2.2
    nx = -dh_dx * n_scale
    ny = dh_dy * n_scale
    nz = np.ones((S, S), dtype=np.float32)
    nl = np.sqrt(nx * nx + ny * ny + nz * nz)
    nrm_f = np.stack([nx / nl * 0.5 + 0.5, ny / nl * 0.5 + 0.5, nz / nl * 0.5 + 0.5], axis=-1)
    nrm_f[~valid] = np.array([0.5, 0.5, 1.0], dtype=np.float32)

    albedo_lin = dilate_atlas(albedo_lin, valid, passes=5)
    orm_f = dilate_atlas(orm_f, valid, passes=5)
    nrm_f = dilate_atlas(nrm_f, valid, passes=4)

    albedo_srgb = np.empty_like(albedo_lin)
    albedo_srgb[..., :3] = linear_to_srgb(albedo_lin[..., :3])
    albedo_srgb[..., 3] = albedo_lin[..., 3]

    albedo_u8 = np.clip(np.round(albedo_srgb * 255.0), 0, 255).astype(np.uint8)
    orm_u8 = np.clip(np.round(orm_f * 255.0), 0, 255).astype(np.uint8)
    nrm_u8 = np.clip(np.round(nrm_f * 255.0), 0, 255).astype(np.uint8)
    return albedo_u8, orm_u8, nrm_u8


def synthesize_item_textures(atlas_size, tris_data, item_cls, seed_offset=0):
    """Renders 128x128 Albedo, ORM, and Normal atlases for a small item model."""
    S = atlas_size
    chart_buf, _mat, pos_buf, nrm_buf, col_buf, _edg, _prt = rasterize_charts(S, tris_data)
    valid = chart_buf >= 0
    ys, xs = np.nonzero(valid)
    if len(ys) == 0:
        return (
            np.full((S, S, 3), 180, dtype=np.uint8),
            np.full((S, S, 3), (255, 180, 0), dtype=np.uint8),
            np.full((S, S, 3), (128, 128, 255), dtype=np.uint8),
        )

    p = pos_buf[ys, xs]
    col = np.clip(col_buf[ys, xs, :3] * ITEM_EXPOSURE, 0.0, 1.0)
    params = CLASS_PARAMS[item_cls]
    np_p = p * 8.0 + np.array([seed_offset * 9.3, 0.0, seed_offset * 14.1], dtype=np.float32)
    aniso_p = np_p * np.array(params["aniso"], dtype=np.float32)
    fine = vnoise3(aniso_p * 24.0)
    mid = vnoise3(np_p * 8.0 + 3.0)

    # For composite items (machines/circuits), let low-saturation grey metal pixels be metallic.
    c_max = np.max(col, axis=1)
    c_min = np.min(col, axis=1)
    sat = (c_max - c_min) / np.maximum(c_max, 1e-4)
    base_metal = np.full(len(ys), params["metal"], dtype=np.float32)
    base_rough = np.full(len(ys), params["rough"], dtype=np.float32)
    if item_cls == "paint":
        metal_part = np.clip(1.0 - sat * 2.5, 0.0, 1.0) * np.clip((c_max - 0.05) * 4.0, 0.0, 1.0)
        base_metal = np.where(metal_part > 0.3, 0.72 * metal_part, 0.12)
        base_rough = np.where(metal_part > 0.3, 0.36, 0.48)

    col = col * (1.0 + params["grain"] * 0.85 * ((fine - 0.5) + 0.7 * (mid - 0.5)))[:, None]
    rough = np.clip(base_rough + 0.08 * (fine - 0.5), 0.08, 0.98)
    metal = np.clip(base_metal, 0.0, 0.98)
    ao_val = np.clip(0.92 + 0.08 * (mid - 0.5), 0.75, 1.0)
    height = ((fine - 0.5) * 0.65 + (mid - 0.5) * 0.35) * params["bump"]

    albedo_lin = np.zeros((S, S, 3), dtype=np.float32)
    orm_f = np.zeros((S, S, 3), dtype=np.float32)
    h_grid = np.zeros((S, S), dtype=np.float32)
    albedo_lin[ys, xs] = np.clip(col, 0.0, 1.0)
    orm_f[ys, xs, 0] = ao_val
    orm_f[ys, xs, 1] = rough
    orm_f[ys, xs, 2] = metal
    h_grid[ys, xs] = height

    dh_dx = np.zeros((S, S), dtype=np.float32)
    dh_dy = np.zeros((S, S), dtype=np.float32)
    same_l = np.zeros((S, S), dtype=bool)
    same_r = np.zeros((S, S), dtype=bool)
    same_u = np.zeros((S, S), dtype=bool)
    same_d = np.zeros((S, S), dtype=bool)
    same_l[:, 1:] = valid[:, 1:] & (chart_buf[:, 1:] == chart_buf[:, :-1])
    same_r[:, :-1] = valid[:, :-1] & (chart_buf[:, :-1] == chart_buf[:, 1:])
    same_u[1:, :] = valid[1:, :] & (chart_buf[1:, :] == chart_buf[:-1, :])
    same_d[:-1, :] = valid[:-1, :] & (chart_buf[:-1, :] == chart_buf[1:, :])
    both_x = same_l & same_r
    dh_dx[both_x] = 0.5 * (np.roll(h_grid, -1, axis=1)[both_x] - np.roll(h_grid, 1, axis=1)[both_x])
    only_r = (~same_l) & same_r
    dh_dx[only_r] = np.roll(h_grid, -1, axis=1)[only_r] - h_grid[only_r]
    only_l = same_l & (~same_r)
    dh_dx[only_l] = h_grid[only_l] - np.roll(h_grid, 1, axis=1)[only_l]
    both_y = same_u & same_d
    dh_dy[both_y] = 0.5 * (np.roll(h_grid, -1, axis=0)[both_y] - np.roll(h_grid, 1, axis=0)[both_y])
    only_d = (~same_u) & same_d
    dh_dy[only_d] = np.roll(h_grid, -1, axis=0)[only_d] - h_grid[only_d]
    only_u = same_u & (~same_d)
    dh_dy[only_u] = h_grid[only_u] - np.roll(h_grid, 1, axis=0)[only_u]

    nx = -dh_dx * 1.8
    ny = dh_dy * 1.8
    nz = np.ones((S, S), dtype=np.float32)
    nl = np.sqrt(nx * nx + ny * ny + nz * nz)
    nrm_f = np.stack([nx / nl * 0.5 + 0.5, ny / nl * 0.5 + 0.5, nz / nl * 0.5 + 0.5], axis=-1)
    nrm_f[~valid] = np.array([0.5, 0.5, 1.0], dtype=np.float32)

    albedo_lin = dilate_atlas(albedo_lin, valid, passes=4)
    orm_f = dilate_atlas(orm_f, valid, passes=4)
    nrm_f = dilate_atlas(nrm_f, valid, passes=3)

    albedo_u8 = np.clip(np.round(linear_to_srgb(albedo_lin) * 255.0), 0, 255).astype(np.uint8)
    orm_u8 = np.clip(np.round(orm_f * 255.0), 0, 255).astype(np.uint8)
    nrm_u8 = np.clip(np.round(nrm_f * 255.0), 0, 255).astype(np.uint8)
    return albedo_u8, orm_u8, nrm_u8


def encode_image(arr, mime, jpeg_quality=88):
    buf = io.BytesIO()
    if mime == "image/jpeg":
        Image.fromarray(arr[..., :3], mode="RGB").save(buf, format="JPEG", quality=jpeg_quality, subsampling=1)
    else:
        mode = "RGBA" if arr.shape[2] == 4 else "RGB"
        Image.fromarray(arr, mode=mode).save(buf, format="PNG", optimize=True)
    return buf.getvalue()


# --- GLB Assembly Helpers -----------------------------------------------------------------------

class BinBuilder:
    def __init__(self):
        self.buf = bytearray()
        self.views = []
        self.accessors = []

    def add_view(self, data, target=None):
        pad = (-len(self.buf)) % 4
        if pad:
            self.buf.extend(b"\x00" * pad)
        offset = len(self.buf)
        self.buf.extend(data)
        bv = {"buffer": 0, "byteOffset": offset, "byteLength": len(data)}
        if target is not None:
            bv["target"] = target
        idx = len(self.views)
        self.views.append(bv)
        return idx

    def add_accessor(self, arr, acc_type, target=34962, with_minmax=False):
        raw = np.ascontiguousarray(arr)
        bv_idx = self.add_view(raw.tobytes(), target=target)
        comp_map = {
            np.dtype(np.float32): 5126,
            np.dtype(np.uint16): 5123,
            np.dtype(np.uint32): 5125,
            np.dtype(np.uint8): 5121,
        }
        acc = {
            "bufferView": bv_idx,
            "componentType": comp_map[raw.dtype],
            "count": int(len(raw)),
            "type": acc_type,
        }
        if with_minmax and len(raw) > 0:
            acc["min"] = [float(x) for x in np.min(raw, axis=0)]
            acc["max"] = [float(x) for x in np.max(raw, axis=0)]
        idx = len(self.accessors)
        self.accessors.append(acc)
        return idx


def _material_group_key(mat, in_glow):
    """Determines whether a material consolidates into pbr_body or keeps its own glTF material."""
    name = mat.get("name", "")
    low = name.lower()
    if any(low.startswith(p) for p in LEAF_PREFIXES):
        return ("untouched", name)
    if BELT_MATERIAL in low:
        return ("untouched_belt", name)

    emit = mat.get("emissiveFactor")
    is_emit = bool(emit and any(c > 0 for c in emit)) or any(w in low for w in FIRE_MATERIALS)
    alpha_mode = mat.get("alphaMode")
    is_alpha = alpha_mode in ("BLEND", "MASK")

    if low == TIER_MATERIAL:
        return ("keep", name, "neutral")
    if name in PAINT_GLOW_NAMES:
        return ("keep", name, "regular")
    if in_glow and not is_emit:
        return ("keep", f"{name}__glow" if not is_alpha else name, "glow_keep", name)
    if is_emit or is_alpha:
        return ("keep", name, "regular")
    if name in ("rock", "sand-rock") or low.startswith("bark-") or low.startswith("cliff-"):
        return ("keep_named", name, "regular")
    return ("consolidate", "pbr_body", "regular")


def _is_already_baked(doc):
    """Returns True if a GLB already carries baked PBR images/materials (prevents destructive double-bake)."""
    if doc.get("images"):
        return True
    for m in doc.get("materials", []):
        if m.get("name") in ("pbr_body", "item_pbr"):
            return True
        if "baseColorTexture" in m.get("pbrMetallicRoughness", {}):
            return True
    return False


def bake_entity_glb(path, adaptive_charts=False, atlas_size=0, high_detail=None):
    """Bakes procedural PBR atlases into an entity .glb in place. Returns stats dict."""
    doc, bin_chunk = read_glb(path)
    if _is_already_baked(doc):
        return {"skipped": "already_baked", "bytes": os.path.getsize(path)}
    model_name = os.path.splitext(os.path.basename(path))[0]
    if high_detail is None:
        high_detail = model_name in HIGH_DETAIL_MODELS
    if high_detail:
        adaptive_charts = True
    seed_off = sum(ord(c) * (i + 1) for i, c in enumerate(model_name)) % 997

    node_xforms = collect_node_transforms(doc)
    orig_mats = doc.get("materials", [])
    meshes = doc.get("meshes", [])
    nodes = doc.get("nodes", [])

    # Measure model footprint in model space for atlas resolution.
    all_lo = np.array([math.inf, math.inf, math.inf])
    all_hi = np.array([-math.inf, -math.inf, -math.inf])

    # Track per-mesh usage across nodes (each mesh in placeholders belongs to one node, handle safely).
    mesh_info = {}
    for ni, nd in enumerate(nodes):
        if "mesh" not in nd:
            continue
        mi = nd["mesh"]
        xform, in_glow = node_xforms.get(ni, (np.eye(4), False))
        mesh_info.setdefault(mi, []).append((ni, xform, in_glow))

    # Build bake entries for every primitive.
    prim_records = []
    untouched_prims = []
    mat_spec_map = {}
    mat_specs = []
    charts_all = []
    mat_group_counter = {}

    for mi, mesh in enumerate(meshes):
        instances = mesh_info.get(mi, [(-1, np.eye(4), False)])
        # Use first node's transform and glow flag (placeholders don't instance shared meshes across nodes).
        _ni, xform, in_glow = instances[0]
        rot3 = xform[:3, :3]
        norm_mat = np.linalg.inv(rot3).T if abs(np.linalg.det(rot3)) > 1e-12 else rot3

        for pi, pr in enumerate(mesh.get("primitives", [])):
            attrs = pr.get("attributes", {})
            mat_idx = pr.get("material", 0)
            orig_mat = orig_mats[mat_idx] if mat_idx < len(orig_mats) else {"name": "default"}
            mname = orig_mat.get("name", "")
            low = mname.lower()

            pos_local = read_accessor(doc, bin_chunk, attrs["POSITION"])
            nrm_local = read_accessor(doc, bin_chunk, attrs["NORMAL"])
            if "indices" in pr:
                indices = read_accessor(doc, bin_chunk, pr["indices"]).astype(np.int32).ravel()
            else:
                indices = np.arange(len(pos_local), dtype=np.int32)

            pos_m = (pos_local @ rot3.T + xform[:3, 3]).astype(np.float32)
            nrm_m = (nrm_local @ norm_mat.T).astype(np.float32)
            all_lo = np.minimum(all_lo, np.min(pos_m, axis=0))
            all_hi = np.maximum(all_hi, np.max(pos_m, axis=0))

            if any(low.startswith(p) for p in LEAF_PREFIXES) or BELT_MATERIAL in low:
                # Preserve untouched primitive geometry, UVs, vertex attributes, and material.
                raw_attrs = {}
                for ak, ai in attrs.items():
                    raw_attrs[ak] = read_accessor(doc, bin_chunk, ai)
                untouched_prims.append({
                    "mi": mi, "pi": pi, "attrs": raw_attrs, "indices": indices,
                    "orig_mat": orig_mat,
                })
                continue

            color = read_accessor(doc, bin_chunk, attrs["COLOR_0"]) if "COLOR_0" in attrs else np.ones((len(pos_local), 4), dtype=np.float32)
            edge = read_accessor(doc, bin_chunk, attrs["TEXCOORD_1"]) if "TEXCOORD_1" in attrs else np.zeros((len(pos_local), 2), dtype=np.float32)
            has_parts = "TEXCOORD_4" in attrs and "TEXCOORD_5" in attrs
            if has_parts:
                t4 = read_accessor(doc, bin_chunk, attrs["TEXCOORD_4"])
                t5 = read_accessor(doc, bin_chunk, attrs["TEXCOORD_5"])
                part_rgba = np.column_stack([t4, t5]).astype(np.float32)
            else:
                part_rgba = np.zeros((len(pos_local), 4), dtype=np.float32)

            gkey = _material_group_key(orig_mat, in_glow)
            if gkey[0] == "consolidate":
                # Keep cliff- prefix if consolidating multiple cliff materials.
                if low.startswith("cliff-"):
                    gkey = ("consolidate", "cliff-pbr", "regular")
            if gkey not in mat_group_counter:
                mat_group_counter[gkey] = len(mat_group_counter)
            target_mat_key = gkey[:2]

            pbr_block = orig_mat.get("pbrMetallicRoughness", {})
            base_rgba = pbr_block.get("baseColorFactor", [1.0, 1.0, 1.0, 1.0])
            emit = orig_mat.get("emissiveFactor")
            is_emit = bool(emit and any(c > 0 for c in emit)) or any(w in low for w in FIRE_MATERIALS)
            _cls, params = classify_material(
                mname,
                is_emissive=is_emit,
                gltf_metal=pbr_block.get("metallicFactor"),
                gltf_rough=pbr_block.get("roughnessFactor"),
            )
            mode = gkey[2]
            spec_key = (target_mat_key, mname, mode, has_parts)
            if spec_key not in mat_spec_map:
                mat_spec_map[spec_key] = len(mat_specs)
                mat_specs.append({
                    "target_key": target_mat_key,
                    "orig_mat": orig_mat,
                    "real_name": gkey[3] if len(gkey) > 3 else mname,
                    "base_rgb": tuple(base_rgba[:3]),
                    "base_alpha": float(base_rgba[3]) if len(base_rgba) > 3 else 1.0,
                    "cls": _cls,
                    "params": params,
                    "mode": mode,
                    "has_parts": has_parts,
                    "is_emit": is_emit,
                })
            spec_id = mat_spec_map[spec_key]

            prim_records.append({
                "mi": mi, "pi": pi, "target_key": target_mat_key, "orig_mat": orig_mat,
                "mode": mode, "real_name": gkey[3] if len(gkey) > 3 else mname,
                "pos_local": pos_local, "nrm_local": nrm_local, "pos_m": pos_m, "nrm_m": nrm_m,
                "color": color, "edge": edge, "part_rgba": part_rgba, "indices": indices,
                "spec_id": spec_id,
            })

    if not prim_records:
        return {"skipped": True}

    footprint_area = max(float((all_hi[0] - all_lo[0]) * (all_hi[2] - all_lo[2])), 0.0)
    if atlas_size <= 0:
        atlas_size = 1024 if high_detail else (256 if footprint_area <= 2.25 else 512)

    # Extract connected planar charts for every baked primitive.
    per_prim_tris = []
    for r in prim_records:
        ntri = len(r["indices"]) // 3
        m_ids = np.full(ntri, r["spec_id"], dtype=np.int32)
        if adaptive_charts:
            p_charts = extract_charts_adaptive(r["pos_m"], r["indices"], m_ids)
        else:
            p_charts = extract_charts(r["pos_m"], r["indices"], m_ids)
        for comp_arr, _ax, u_raw, v_raw in p_charts:
            tris = r["indices"].reshape(ntri, 3)[comp_arr]
            u_vals = u_raw[tris]
            v_vals = v_raw[tris]
            cid = len(charts_all)
            charts_all.append({
                "cid": cid,
                "u0": float(np.min(u_vals)), "u1": float(np.max(u_vals)),
                "v0": float(np.min(v_vals)), "v1": float(np.max(v_vals)),
                "u_raw": u_raw, "v_raw": v_raw, "tris": tris,
                "rec": r,
            })

    margin = 2.0 if high_detail else (1.5 if (adaptive_charts and len(charts_all) > 400) else 2.5)
    pack_charts(charts_all, atlas_size, margin_px=margin)

    # Assemble per-triangle data for rasterizer AND build new per-(mi, target_key) split vertex buffers.
    all_uv_px = []
    all_pos_m = []
    all_nrm_m = []
    all_col = []
    all_edg = []
    all_prt = []
    all_cid = []
    all_mid = []

    mesh_groups = {}  # (mi, target_key) -> {"pos": [], "nrm": [], "uv": [], "idx": [], "orig_mat": ..., "mode": ..., "real_name": ...}
    for ch in charts_all:
        r = ch["rec"]
        tris = ch["tris"]
        flat = tris.ravel()
        u_px = (ch["u_raw"][flat] - ch["u0"]) * ch["scale"] + ch["px_x"]
        v_px = (ch["v_raw"][flat] - ch["v0"]) * ch["scale"] + ch["px_y"]
        uv_px_tri = np.stack([u_px, v_px], axis=-1).reshape(len(tris), 3, 2).astype(np.float32)

        all_uv_px.append(uv_px_tri)
        all_pos_m.append(r["pos_m"][tris])
        all_nrm_m.append(r["nrm_m"][tris])
        all_col.append(r["color"][tris])
        all_edg.append(r["edge"][tris])
        all_prt.append(r["part_rgba"][tris])
        all_cid.append(np.full(len(tris), ch["cid"], dtype=np.int32))
        all_mid.append(np.full(len(tris), r["spec_id"], dtype=np.int32))

        # Deduplicate local (orig_vert_idx) within THIS chart only, so vertices split cleanly across charts.
        uniq, inv = np.unique(flat, return_inverse=True)
        u_v = ((ch["u_raw"][uniq] - ch["u0"]) * ch["scale"] + ch["px_x"]) / float(atlas_size)
        v_v = ((ch["v_raw"][uniq] - ch["v0"]) * ch["scale"] + ch["px_y"]) / float(atlas_size)
        uv_v = np.stack([u_v, v_v], axis=-1).astype(np.float32)

        gkey = (r["mi"], r["target_key"])
        grp = mesh_groups.get(gkey)
        if grp is None:
            grp = {
                "pos": [], "nrm": [], "uv": [], "idx": [], "vcount": 0,
                "orig_mat": r["orig_mat"], "mode": r["mode"], "real_name": r["real_name"],
            }
            mesh_groups[gkey] = grp
        base_v = grp["vcount"]
        grp["pos"].append(r["pos_local"][uniq])
        grp["nrm"].append(r["nrm_local"][uniq])
        grp["uv"].append(uv_v)
        grp["idx"].append((inv + base_v).astype(np.uint32))
        grp["vcount"] += len(uniq)

    tris_data = {
        "uv_px": np.concatenate(all_uv_px, axis=0),
        "pos_m": np.concatenate(all_pos_m, axis=0),
        "norm_m": np.concatenate(all_nrm_m, axis=0),
        "color": np.concatenate(all_col, axis=0),
        "edge": np.concatenate(all_edg, axis=0),
        "part_rgba": np.concatenate(all_prt, axis=0),
        "chart_id": np.concatenate(all_cid, axis=0),
        "mat_id": np.concatenate(all_mid, axis=0),
    }

    albedo_u8, orm_u8, nrm_u8 = synthesize_entity_textures(
        atlas_size, tris_data, mat_specs, seed_offset=seed_off, high_detail=high_detail
    )
    # Check if any material needs alpha in texture (BLEND materials keep baseColorFactor[3]; JPEG keeps opaque RGB).
    albedo_bytes = encode_image(albedo_u8, "image/jpeg", jpeg_quality=92 if high_detail else 88)
    orm_bytes = encode_image(orm_u8, "image/png")
    nrm_bytes = encode_image(nrm_u8, "image/png")

    # Assemble clean new glTF JSON + BIN.
    bb = BinBuilder()
    bv_alb = bb.add_view(albedo_bytes)
    bv_orm = bb.add_view(orm_bytes)
    bv_nrm = bb.add_view(nrm_bytes)

    new_mats = []
    mat_idx_map = {}

    def get_pbr_mat(target_key, orig_mat, mode, real_name):
        if target_key in mat_idx_map:
            return mat_idx_map[target_key]
        m_name = target_key[1] if target_key[0] == "consolidate" else real_name
        orig_pbr = orig_mat.get("pbrMetallicRoughness", {})
        orig_base = orig_pbr.get("baseColorFactor", [1.0, 1.0, 1.0, 1.0])
        alpha = float(orig_base[3]) if len(orig_base) > 3 else 1.0
        if mode in ("neutral", "glow_keep"):
            base_factor = [float(orig_base[0]), float(orig_base[1]), float(orig_base[2]), alpha]
        else:
            base_factor = [1.0, 1.0, 1.0, alpha]
        m = {
            "name": m_name,
            "pbrMetallicRoughness": {
                "baseColorTexture": {"index": 0},
                "baseColorFactor": base_factor,
                "metallicRoughnessTexture": {"index": 1},
                "metallicFactor": 1.0,
                "roughnessFactor": 1.0,
            },
            "occlusionTexture": {"index": 1},
            "normalTexture": {"index": 2},
        }
        if "alphaMode" in orig_mat:
            m["alphaMode"] = orig_mat["alphaMode"]
        if "alphaCutoff" in orig_mat:
            m["alphaCutoff"] = orig_mat["alphaCutoff"]
        if "doubleSided" in orig_mat:
            m["doubleSided"] = orig_mat["doubleSided"]
        if "emissiveFactor" in orig_mat:
            m["emissiveFactor"] = orig_mat["emissiveFactor"]
        if "extensions" in orig_mat:
            m["extensions"] = orig_mat["extensions"]
        idx = len(new_mats)
        new_mats.append(m)
        mat_idx_map[target_key] = idx
        return idx

    untouched_mat_map = {}
    def get_untouched_mat(orig_mat):
        key = json.dumps(orig_mat, sort_keys=True)
        if key not in untouched_mat_map:
            untouched_mat_map[key] = len(new_mats)
            new_mats.append(dict(orig_mat))
        return untouched_mat_map[key]

    new_meshes = [{"name": m.get("name", f"mesh_{mi}"), "primitives": []} for mi, m in enumerate(meshes)]

    for (mi, target_key), grp in mesh_groups.items():
        pos_arr = np.concatenate(grp["pos"], axis=0).astype(np.float32)
        nrm_arr = np.concatenate(grp["nrm"], axis=0).astype(np.float32)
        uv_arr = np.concatenate(grp["uv"], axis=0).astype(np.float32)
        idx_arr = np.concatenate(grp["idx"], axis=0)
        if len(pos_arr) <= 65535:
            idx_arr = idx_arr.astype(np.uint16)
        else:
            idx_arr = idx_arr.astype(np.uint32)
        m_i = get_pbr_mat(target_key, grp["orig_mat"], grp["mode"], grp["real_name"])
        new_meshes[mi]["primitives"].append({
            "attributes": {
                "POSITION": bb.add_accessor(pos_arr, "VEC3", with_minmax=True),
                "NORMAL": bb.add_accessor(nrm_arr, "VEC3"),
                "TEXCOORD_0": bb.add_accessor(uv_arr, "VEC2"),
            },
            "indices": bb.add_accessor(idx_arr, "SCALAR", target=34963),
            "material": m_i,
        })

    for up in untouched_prims:
        attrs_out = {}
        for ak, arr in up["attrs"].items():
            if ak == "POSITION":
                attrs_out[ak] = bb.add_accessor(arr.astype(np.float32), "VEC3", with_minmax=True)
            elif ak == "NORMAL":
                attrs_out[ak] = bb.add_accessor(arr.astype(np.float32), "VEC3")
            elif ak.startswith("TEXCOORD_"):
                attrs_out[ak] = bb.add_accessor(arr.astype(np.float32), "VEC2")
            elif ak == "COLOR_0":
                attrs_out[ak] = bb.add_accessor(arr.astype(np.float32), "VEC4")
        idx_arr = up["indices"].astype(np.uint16 if len(up["attrs"]["POSITION"]) <= 65535 else np.uint32)
        new_meshes[up["mi"]]["primitives"].append({
            "attributes": attrs_out,
            "indices": bb.add_accessor(idx_arr, "SCALAR", target=34963),
            "material": get_untouched_mat(up["orig_mat"]),
        })

    out_doc = {
        "asset": {"version": "2.0", "generator": doc.get("asset", {}).get("generator", "factorio-3d tools/models/bake_pbr.py")},
        "scene": doc.get("scene", 0),
        "scenes": doc.get("scenes", [{"nodes": list(range(len(nodes)))}]),
        "nodes": nodes,
        "meshes": new_meshes,
        "materials": new_mats,
        "samplers": [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}],
        "images": [
            {"bufferView": bv_alb, "mimeType": "image/jpeg"},
            {"bufferView": bv_orm, "mimeType": "image/png"},
            {"bufferView": bv_nrm, "mimeType": "image/png"},
        ],
        "textures": [
            {"source": 0, "sampler": 0},
            {"source": 1, "sampler": 0},
            {"source": 2, "sampler": 0},
        ],
        "buffers": [{"byteLength": len(bb.buf)}],
        "bufferViews": bb.views,
        "accessors": bb.accessors,
    }
    if "extensionsUsed" in doc:
        out_doc["extensionsUsed"] = doc["extensionsUsed"]
    write_glb(path, out_doc, bb.buf)
    return {
        "skipped": False,
        "atlas": atlas_size,
        "charts": len(charts_all),
        "mats": len(new_mats),
        "bytes": os.path.getsize(path),
    }


def bake_item_glb(path):
    """Bakes procedural PBR atlases (128x128) into an item .glb in place, dropping COLOR_0."""
    doc, bin_chunk = read_glb(path)
    if _is_already_baked(doc):
        return {"skipped": "already_baked", "bytes": os.path.getsize(path)}
    item_name = os.path.splitext(os.path.basename(path))[0]
    seed_off = sum(ord(c) * (i + 1) for i, c in enumerate(item_name)) % 997
    item_cls = classify_item(item_name)

    meshes = doc.get("meshes", [])
    nodes = doc.get("nodes", [])
    orig_mats = doc.get("materials", [])
    node_xforms = collect_node_transforms(doc)
    mesh_info = {}
    for ni, nd in enumerate(nodes):
        if "mesh" in nd:
            mesh_info.setdefault(nd["mesh"], []).append(node_xforms.get(ni, (np.eye(4), False))[0])

    prim_records = []
    for mi, mesh in enumerate(meshes):
        xform = mesh_info.get(mi, [np.eye(4)])[0]
        rot3 = xform[:3, :3]
        norm_mat = np.linalg.inv(rot3).T if abs(np.linalg.det(rot3)) > 1e-12 else rot3
        for pr in mesh.get("primitives", []):
            attrs = pr.get("attributes", {})
            mat_idx = pr.get("material", 0)
            orig_mat = orig_mats[mat_idx] if mat_idx < len(orig_mats) else {"name": "item"}
            base_rgba = orig_mat.get("pbrMetallicRoughness", {}).get("baseColorFactor", [1.0, 1.0, 1.0, 1.0])
            pos_local = read_accessor(doc, bin_chunk, attrs["POSITION"])
            nrm_local = read_accessor(doc, bin_chunk, attrs["NORMAL"])
            if "indices" in pr:
                indices = read_accessor(doc, bin_chunk, pr["indices"]).astype(np.int32).ravel()
            else:
                indices = np.arange(len(pos_local), dtype=np.int32)
            color = read_accessor(doc, bin_chunk, attrs["COLOR_0"]) if "COLOR_0" in attrs else np.ones((len(pos_local), 4), dtype=np.float32)
            color = color.copy()
            color[:, :3] *= np.array(base_rgba[:3], dtype=np.float32)[None, :]
            pos_m = (pos_local @ rot3.T + xform[:3, 3]).astype(np.float32)
            nrm_m = (nrm_local @ norm_mat.T).astype(np.float32)
            prim_records.append({
                "mi": mi, "pos_local": pos_local, "nrm_local": nrm_local,
                "pos_m": pos_m, "nrm_m": nrm_m, "color": color, "indices": indices,
            })

    atlas_size = 128
    charts_all = []
    for r in prim_records:
        ntri = len(r["indices"]) // 3
        m_ids = np.zeros(ntri, dtype=np.int32)
        for comp_arr, _ax, u_raw, v_raw in extract_charts(r["pos_m"], r["indices"], m_ids):
            tris = r["indices"].reshape(ntri, 3)[comp_arr]
            u_vals = u_raw[tris]
            v_vals = v_raw[tris]
            charts_all.append({
                "cid": len(charts_all),
                "u0": float(np.min(u_vals)), "u1": float(np.max(u_vals)),
                "v0": float(np.min(v_vals)), "v1": float(np.max(v_vals)),
                "u_raw": u_raw, "v_raw": v_raw, "tris": tris, "rec": r,
            })
    pack_charts(charts_all, atlas_size, margin_px=2.0)

    all_uv_px, all_pos_m, all_nrm_m, all_col, all_cid = [], [], [], [], []
    mesh_acc = {}
    for ch in charts_all:
        r = ch["rec"]
        tris = ch["tris"]
        flat = tris.ravel()
        u_px = (ch["u_raw"][flat] - ch["u0"]) * ch["scale"] + ch["px_x"]
        v_px = (ch["v_raw"][flat] - ch["v0"]) * ch["scale"] + ch["px_y"]
        all_uv_px.append(np.stack([u_px, v_px], axis=-1).reshape(len(tris), 3, 2).astype(np.float32))
        all_pos_m.append(r["pos_m"][tris])
        all_nrm_m.append(r["nrm_m"][tris])
        all_col.append(r["color"][tris])
        all_cid.append(np.full(len(tris), ch["cid"], dtype=np.int32))

        uniq, inv = np.unique(flat, return_inverse=True)
        u_v = ((ch["u_raw"][uniq] - ch["u0"]) * ch["scale"] + ch["px_x"]) / float(atlas_size)
        v_v = ((ch["v_raw"][uniq] - ch["v0"]) * ch["scale"] + ch["px_y"]) / float(atlas_size)
        grp = mesh_acc.setdefault(r["mi"], {"pos": [], "nrm": [], "uv": [], "idx": [], "vcount": 0})
        grp["pos"].append(r["pos_local"][uniq])
        grp["nrm"].append(r["nrm_local"][uniq])
        grp["uv"].append(np.stack([u_v, v_v], axis=-1).astype(np.float32))
        grp["idx"].append((inv + grp["vcount"]).astype(np.uint16))
        grp["vcount"] += len(uniq)

    ntotal = sum(len(x) for x in all_cid)
    tris_data = {
        "uv_px": np.concatenate(all_uv_px, axis=0),
        "pos_m": np.concatenate(all_pos_m, axis=0),
        "norm_m": np.concatenate(all_nrm_m, axis=0),
        "color": np.concatenate(all_col, axis=0),
        "edge": np.zeros((ntotal, 3, 2), dtype=np.float32),
        "part_rgba": np.zeros((ntotal, 3, 4), dtype=np.float32),
        "chart_id": np.concatenate(all_cid, axis=0),
        "mat_id": np.zeros(ntotal, dtype=np.int32),
    }

    albedo_u8, orm_u8, nrm_u8 = synthesize_item_textures(atlas_size, tris_data, item_cls, seed_offset=seed_off)
    bb = BinBuilder()
    bv_alb = bb.add_view(encode_image(albedo_u8, "image/jpeg"))
    bv_orm = bb.add_view(encode_image(orm_u8, "image/png"))
    bv_nrm = bb.add_view(encode_image(nrm_u8, "image/png"))

    new_meshes = []
    for mi, m in enumerate(meshes):
        grp = mesh_acc[mi]
        pos_arr = np.concatenate(grp["pos"], axis=0).astype(np.float32)
        nrm_arr = np.concatenate(grp["nrm"], axis=0).astype(np.float32)
        uv_arr = np.concatenate(grp["uv"], axis=0).astype(np.float32)
        idx_arr = np.concatenate(grp["idx"], axis=0).astype(np.uint16 if len(pos_arr) <= 65535 else np.uint32)
        new_meshes.append({
            "name": m.get("name", "mesh"),
            "primitives": [{
                "attributes": {
                    "POSITION": bb.add_accessor(pos_arr, "VEC3", with_minmax=True),
                    "NORMAL": bb.add_accessor(nrm_arr, "VEC3"),
                    "TEXCOORD_0": bb.add_accessor(uv_arr, "VEC2"),
                },
                "indices": bb.add_accessor(idx_arr, "SCALAR", target=34963),
                "material": 0,
            }],
        })

    out_doc = {
        "asset": {"version": "2.0", "generator": doc.get("asset", {}).get("generator", "Factorio 3D tools/models/bake_pbr.py")},
        "scene": doc.get("scene", 0),
        "scenes": doc.get("scenes", [{"nodes": list(range(len(nodes)))}]),
        "nodes": nodes,
        "meshes": new_meshes,
        "materials": [{
            "name": "item_pbr",
            "pbrMetallicRoughness": {
                "baseColorTexture": {"index": 0},
                "baseColorFactor": [1.0, 1.0, 1.0, 1.0],
                "metallicRoughnessTexture": {"index": 1},
                "metallicFactor": 1.0,
                "roughnessFactor": 1.0,
            },
            "occlusionTexture": {"index": 1},
            "normalTexture": {"index": 2},
        }],
        "samplers": [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}],
        "images": [
            {"bufferView": bv_alb, "mimeType": "image/jpeg"},
            {"bufferView": bv_orm, "mimeType": "image/png"},
            {"bufferView": bv_nrm, "mimeType": "image/png"},
        ],
        "textures": [
            {"source": 0, "sampler": 0},
            {"source": 1, "sampler": 0},
            {"source": 2, "sampler": 0},
        ],
        "buffers": [{"byteLength": len(bb.buf)}],
        "bufferViews": bb.views,
        "accessors": bb.accessors,
    }
    write_glb(path, out_doc, bb.buf)
    return {"skipped": False, "atlas": atlas_size, "charts": len(charts_all), "mats": 1, "bytes": os.path.getsize(path)}


def _worker_job(job, atlas_size=0, high_detail=None):
    kind, path = job
    if kind == "item":
        res = bake_item_glb(path)
    elif kind == "wube_entity":
        res = bake_entity_glb(path, adaptive_charts=True, atlas_size=atlas_size, high_detail=high_detail)
    else:
        res = bake_entity_glb(path, atlas_size=atlas_size, high_detail=high_detail)
    return kind, os.path.basename(path), res


def fix_imports(targets):
    """Sets gltf/embedded_image_handling=3 on modified .glb.import files before godot --import."""
    fixed = 0
    for _kind, path in targets:
        imp = path + ".import"
        if not os.path.exists(imp):
            continue
        with open(imp, encoding="utf-8") as f:
            text = f.read()
        if "gltf/embedded_image_handling=1" in text:
            with open(imp, "w", encoding="utf-8", newline="\n") as f:
                f.write(text.replace("gltf/embedded_image_handling=1", "gltf/embedded_image_handling=3"))
            fixed += 1
    return fixed


def _write_pack_json(pj_path, data):
    tmp_path = pj_path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, indent="\t", ensure_ascii=False)
        f.write("\n")
    os.replace(tmp_path, pj_path)


def update_pack_json(zenith_ents, zenith_items, rig_bases):
    """Writes placeholders/pack.json with shading='pbr' and shading_models keeping Zenith/rigged as factorio."""
    pj_path = os.path.join(PLACEHOLDERS_DIR, "pack.json")
    with open(pj_path, encoding="utf-8") as f:
        data = json.load(f)

    z_ent_bases = {base_of_variant(z) for z in zenith_ents}
    z_item_bases = {base_of_variant(z) for z in zenith_items}
    ph_ents = {os.path.splitext(os.path.basename(p))[0] for p in glob.glob(os.path.join(PLACEHOLDERS_DIR, "*.glb"))}
    ph_items = {os.path.splitext(os.path.basename(p))[0] for p in glob.glob(os.path.join(PLACEHOLDERS_ITEMS_DIR, "*.glb"))}

    shading_models = {}
    # Zenith-covered entity models (including directional siblings) and rigged creatures stay factorio.
    for e in sorted(ph_ents):
        if is_zenith_covered(e, zenith_ents, z_ent_bases, strip_dir=True) or is_rigged_entity(e, rig_bases):
            shading_models[e] = "factorio"
    # Cross-collision items (entity in Zenith, item NOT in Zenith) get explicit pbr.
    for it in sorted(ph_items):
        if not is_zenith_covered(it, zenith_items, z_item_bases):
            if it in shading_models:
                shading_models["items/" + it] = "pbr"
        else:
            shading_models["items/" + it] = "factorio"

    data["shading"] = "pbr"
    data["shading_models"] = shading_models
    _write_pack_json(pj_path, data)
    return len(shading_models)


def update_wube3dp_pack_json(rig_bases):
    """Writes wube3dp/pack.json with shading='pbr' and shading_models keeping rigged/belt models as factorio."""
    pj_path = os.path.join(WUBE3DP_DIR, "pack.json")
    with open(pj_path, encoding="utf-8") as f:
        data = json.load(f)

    wube_ents = {os.path.splitext(os.path.basename(p))[0] for p in glob.glob(os.path.join(WUBE3DP_DIR, "*.glb"))}
    shading_models = {
        e: "factorio"
        for e in sorted(wube_ents)
        if is_wube3dp_excluded(e, rig_bases)
    }

    data["shading"] = "pbr"
    data["shading_models"] = shading_models
    _write_pack_json(pj_path, data)
    return len(shading_models)


def verify_wube3dp(rig_bases):
    errors = []
    pj_path = os.path.join(WUBE3DP_DIR, "pack.json")
    excluded_expected = {}
    baked_ents = 0
    untouched_ents = 0

    for p in sorted(glob.glob(os.path.join(WUBE3DP_DIR, "*.glb"))):
        name = os.path.splitext(os.path.basename(p))[0]
        doc, _ = read_glb(p)
        imgs = len(doc.get("images", []))
        if is_wube3dp_excluded(name, rig_bases):
            untouched_ents += 1
            excluded_expected[name] = "factorio"
            if imgs > 0:
                errors.append(f"wube3dp {name}: excluded model should stay untextured, found {imgs} images")
            continue

        baked_ents += 1
        if imgs != 3:
            errors.append(f"wube3dp {name}: expected 3 images, found {imgs}")
            continue
        mimes = [im.get("mimeType") for im in doc["images"]]
        if mimes != ["image/jpeg", "image/png", "image/png"]:
            errors.append(f"wube3dp {name}: unexpected image mimeTypes {mimes}")

        imp = p + ".import"
        if not os.path.exists(imp):
            errors.append(f"wube3dp {name}: missing .glb.import")
        else:
            imp_text = open(imp, encoding="utf-8").read()
            if "gltf/embedded_image_handling=3" not in imp_text:
                errors.append(f"wube3dp {name}: .glb.import missing gltf/embedded_image_handling=3")

        for mi, m in enumerate(doc.get("materials", [])):
            pbr = m.get("pbrMetallicRoughness", {})
            orm_t = pbr.get("metallicRoughnessTexture", {}).get("index")
            base_t = pbr.get("baseColorTexture", {}).get("index")
            occ_t = m.get("occlusionTexture", {}).get("index")
            nrm_t = m.get("normalTexture", {}).get("index")
            if None in (base_t, orm_t, occ_t, nrm_t):
                errors.append(f"wube3dp {name} mat[{mi}] {m.get('name')}: missing PBR texture ref(s)")
            elif occ_t != orm_t:
                errors.append(f"wube3dp {name} mat[{mi}] {m.get('name')}: occlusionTexture {occ_t} != ORM {orm_t}")
            if pbr.get("metallicFactor") != 1.0 or pbr.get("roughnessFactor") != 1.0:
                errors.append(f"wube3dp {name} mat[{mi}]: factors=({pbr.get('metallicFactor')}, {pbr.get('roughnessFactor')})")

    try:
        with open(pj_path, encoding="utf-8") as f:
            pj = json.load(f)
        if pj.get("shading") != "pbr":
            errors.append(f"wube3dp/pack.json shading is {pj.get('shading')!r}, expected 'pbr'")
        if pj.get("shading_models") != excluded_expected:
            errors.append(f"wube3dp/pack.json shading_models mismatch: got {pj.get('shading_models')}, want {excluded_expected}")
    except Exception as exc:
        errors.append(f"wube3dp/pack.json unreadable: {exc}")

    print(f"verify wube3dp: baked={baked_ents}, untouched={untouched_ents}, errors={len(errors)}")
    for e in errors[:30]:
        print("  ERROR:", e)
    return 1 if errors else 0


def verify_placeholders(zenith_zip_path):
    z_ents, z_ent_bases, z_items, z_item_bases, rig_bases = load_exclusions(zenith_zip_path)
    errors = []
    baked_ents = 0
    untouched_ents = 0
    for p in sorted(glob.glob(os.path.join(PLACEHOLDERS_DIR, "*.glb"))):
        name = os.path.splitext(os.path.basename(p))[0]
        doc, _ = read_glb(p)
        imgs = len(doc.get("images", []))
        if is_zenith_covered(name, z_ents, z_ent_bases, strip_dir=True) or is_rigged_entity(name, rig_bases):
            untouched_ents += 1
            if imgs > 0:
                errors.append(f"entity {name} should stay untextured, found {imgs} images")
        else:
            baked_ents += 1
            if imgs != 3:
                errors.append(f"entity {name}: expected 3 images, found {imgs}")
                continue
            mimes = [im.get("mimeType") for im in doc["images"]]
            if not all(m in ("image/jpeg", "image/png") for m in mimes):
                errors.append(f"entity {name}: bad image mimeTypes {mimes}")

    baked_items = 0
    untouched_items = 0
    for p in sorted(glob.glob(os.path.join(PLACEHOLDERS_ITEMS_DIR, "*.glb"))):
        name = os.path.splitext(os.path.basename(p))[0]
        doc, _ = read_glb(p)
        imgs = len(doc.get("images", []))
        if is_zenith_covered(name, z_items, z_item_bases):
            untouched_items += 1
            if imgs > 0:
                errors.append(f"item {name} should stay untextured, found {imgs} images")
        else:
            baked_items += 1
            if imgs != 3:
                errors.append(f"item {name}: expected 3 images, found {imgs}")
            for m in doc.get("meshes", []):
                for pr in m.get("primitives", []):
                    if "COLOR_0" in pr.get("attributes", {}):
                        errors.append(f"item {name}: still has COLOR_0")

    print(f"verify: entities baked={baked_ents}, untouched={untouched_ents}; items baked={baked_items}, untouched={untouched_items}; errors={len(errors)}")
    for e in errors[:30]:
        print("  ERROR:", e)
    return 1 if errors else 0


def collect_targets(args, z_ents, z_ent_bases, z_items, z_item_bases, rig_bases):
    targets = []
    if args.names:
        for raw in args.names:
            clean = raw[:-4] if raw.endswith(".glb") else raw
            if clean.startswith("items/"):
                nm = clean[6:]
                p = os.path.join(PLACEHOLDERS_ITEMS_DIR, nm + ".glb")
                if not os.path.exists(p):
                    raise FileNotFoundError(p)
                if is_zenith_covered(nm, z_items, z_item_bases):
                    print(f"skip Zenith-covered item: {nm}")
                else:
                    targets.append(("item", p))
            else:
                p = os.path.join(PLACEHOLDERS_DIR, clean + ".glb")
                if not os.path.exists(p):
                    raise FileNotFoundError(p)
                if is_zenith_covered(clean, z_ents, z_ent_bases, strip_dir=True) or is_rigged_entity(clean, rig_bases):
                    print(f"skip excluded entity: {clean}")
                else:
                    targets.append(("entity", p))
        return targets

    if args.entities or (not args.entities and not args.items):
        for p in sorted(glob.glob(os.path.join(PLACEHOLDERS_DIR, "*.glb"))):
            nm = os.path.splitext(os.path.basename(p))[0]
            if not is_zenith_covered(nm, z_ents, z_ent_bases, strip_dir=True) and not is_rigged_entity(nm, rig_bases):
                targets.append(("entity", p))
    if args.items or (not args.entities and not args.items):
        for p in sorted(glob.glob(os.path.join(PLACEHOLDERS_ITEMS_DIR, "*.glb"))):
            nm = os.path.splitext(os.path.basename(p))[0]
            if not is_zenith_covered(nm, z_items, z_item_bases):
                targets.append(("item", p))
    return targets


def collect_wube3dp_targets(args, rig_bases):
    targets = []
    if args.names:
        for raw in args.names:
            clean = raw[:-4] if raw.endswith(".glb") else raw
            p = os.path.join(WUBE3DP_DIR, clean + ".glb")
            if not os.path.exists(p):
                raise FileNotFoundError(p)
            if is_wube3dp_excluded(clean, rig_bases):
                print(f"skip excluded wube3dp entity: {clean}")
            else:
                targets.append(("wube_entity", p))
        return targets

    for p in sorted(glob.glob(os.path.join(WUBE3DP_DIR, "*.glb"))):
        nm = os.path.splitext(os.path.basename(p))[0]
        if not is_wube3dp_excluded(nm, rig_bases):
            targets.append(("wube_entity", p))
    return targets


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pack", choices=("placeholders", "wube3dp"), default="placeholders")
    ap.add_argument("--entities", action="store_true")
    ap.add_argument("--items", action="store_true")
    ap.add_argument("--names", nargs="*")
    ap.add_argument("--zenith-zip", default=DEFAULT_ZENITH_ZIP)
    ap.add_argument("--jobs", type=int, default=max(1, min(8, os.cpu_count() or 4)))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--update-pack-json", action="store_true")
    ap.add_argument("--fix-imports", action="store_true")
    ap.add_argument("--atlas-size", type=int, default=0)
    ap.add_argument("--high-detail", action="store_true", default=None)
    args = ap.parse_args()

    z_ents, z_ent_bases, z_items, z_item_bases, rig_bases = load_exclusions(args.zenith_zip)

    if args.verify:
        if args.pack == "wube3dp":
            return verify_wube3dp(rig_bases)
        return verify_placeholders(args.zenith_zip)

    if args.pack == "wube3dp":
        targets = collect_wube3dp_targets(args, rig_bases)
    else:
        targets = collect_targets(args, z_ents, z_ent_bases, z_items, z_item_bases, rig_bases)
    ent_count = sum(1 for k, _ in targets if k in ("entity", "wube_entity"))
    item_count = sum(1 for k, _ in targets if k == "item")
    print(f"targets ({args.pack}): {ent_count} entities, {item_count} items ({len(targets)} total)")
    if args.dry_run:
        return 0

    t0 = time.time()
    total_bytes = 0
    if args.jobs > 1 and len(targets) > 4:
        with ProcessPoolExecutor(max_workers=args.jobs) as pool:
            futs = [pool.submit(_worker_job, job, args.atlas_size, args.high_detail) for job in targets]
            for i, fut in enumerate(futs, 1):
                kind, fname, res = fut.result()
                total_bytes += res.get("bytes", 0)
                if i <= 10 or i % 50 == 0 or i == len(targets):
                    print(f"[{i}/{len(targets)}] {kind} {fname}: {res}")
    else:
        for i, job in enumerate(targets, 1):
            kind, fname, res = _worker_job(job, args.atlas_size, args.high_detail)
            total_bytes += res.get("bytes", 0)
            print(f"[{i}/{len(targets)}] {kind} {fname}: {res}")

    if args.fix_imports:
        n_fix = fix_imports(targets)
        print(f"fix_imports: updated {n_fix} .glb.import files to embedded_image_handling=3")
    if args.update_pack_json:
        if args.pack == "wube3dp":
            n_sm = update_wube3dp_pack_json(rig_bases)
            print(f"update_wube3dp_pack_json: shading='pbr', shading_models={n_sm} rules")
        else:
            n_sm = update_pack_json(z_ents, z_items, rig_bases)
            print(f"update_pack_json: shading='pbr', shading_models={n_sm} rules")

    print(f"done in {time.time() - t0:.1f}s, baked files total {total_bytes / 1e6:.1f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
