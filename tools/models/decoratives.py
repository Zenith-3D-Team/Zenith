"""Procedural 3D placeholder models for Factorio's 48 raised decoratives
(client/assets/models/packs/placeholders/decoratives/<name>.glb).

Plain Python using tools/models/item_kit.py (numpy + pillow). Colours are sampled from the
local Factorio install when present, with built-in Factorio-matched fallbacks otherwise.

    py -3 tools/models/decoratives.py
"""

import json
import math
import os
import random
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

import item_kit as kit  # noqa: E402
from item_kit import Mesh, box, hexcol, merge, mix, prism, rock, scale, shade_by_height, write_glb  # noqa: E402

DECORATIVES_JSON = os.path.join(REPO, "client", "data", "decoratives.json")
OUT_DIR = os.path.join(REPO, "client", "assets", "models", "packs", "placeholders", "decoratives")
GRASS_WORDS = ("grass", "fluff", "asterisk", "croton", "pita", "bush", "fern", "reed", "shrub")

FALLBACK_PALETTES = {
    "brown-asterisk": ("#5c4a2e", "#876e45", "#b59660"),
    "brown-asterisk-mini": ("#56452b", "#816841", "#ae8f5c"),
    "brown-carpet-grass": ("#4d4528", "#6d6038", "#8f7d4c"),
    "brown-fluff": ("#615133", "#8a754b", "#d0be93"),
    "brown-fluff-dry": ("#5b4c33", "#7e6b48", "#bfa97f"),
    "brown-hairy-grass": ("#4c4327", "#6f6138", "#94814b"),
    "green-asterisk": ("#3a5d27", "#588939", "#7cb252"),
    "green-asterisk-mini": ("#385926", "#538236", "#74a94c"),
    "green-bush-mini": ("#354d23", "#4e7432", "#729b49"),
    "green-carpet-grass": ("#355524", "#507c36", "#709f4c"),
    "green-croton": ("#345724", "#4f8336", "#98b850"),
    "green-desert-bush": ("#42572d", "#5f7a40", "#829e5a"),
    "green-hairy-grass": ("#365624", "#527f37", "#74a54f"),
    "green-pita-mini": ("#395d2c", "#588b43", "#80b462"),
    "green-small-grass": ("#385a26", "#558539", "#78ad52"),
    "red-asterisk": ("#6e3226", "#9d4634", "#ca6a4d"),
    "red-croton": ("#5e2f24", "#914734", "#c47149"),
    "red-desert-bush": ("#623426", "#8d4935", "#b6684b"),
    "v-brown-carpet-grass": ("#4b4227", "#6b5d36", "#8c7a49"),
    "v-brown-hairy-grass": ("#494025", "#6a5c35", "#8f7c48"),
    "v-green-hairy-grass": ("#355323", "#4f7a35", "#709f4b"),
    "white-carpet-grass": ("#6b6b5d", "#94927e", "#bab69f"),
    "white-desert-bush": ("#636256", "#8c8979", "#b3af9b"),
    "black-sceptre": ("#24242b", "#393744", "#59526b"),
    "blood-grape": ("#4e1b2d", "#7e2541", "#b0395b"),
    "blood-grape-vibrant": ("#601c39", "#9b2654", "#d64178"),
    "brambles": ("#3c2b1e", "#5d432e", "#816044"),
    "coral-land": ("#74443c", "#a36355", "#cf8c7a"),
    "coral-water": ("#6a3c4b", "#96546a", "#c77d96"),
    "floating-iceberg-large": ("#4f7d99", "#8bbad4", "#e3f2fa"),
    "floating-iceberg-small": ("#5483a0", "#91c0d9", "#e6f4fb"),
    "fuchsia-pita": ("#592544", "#8a3668", "#bd5693"),
    "fulgora-sunk-ruin-medium": ("#3f3c39", "#5c5550", "#8a6d56"),
    "garballo": ("#4b4528", "#6f683a", "#918850"),
    "garballo-mini-dry": ("#594932", "#7e6746", "#a48a62"),
    "green-cup": ("#3b6131", "#5b9248", "#8ac16a"),
    "green-pita": ("#365c2b", "#568b44", "#7cb661"),
    "honeycomb-fungus": ("#5a4a2b", "#8a7040", "#c49c54"),
    "honeycomb-fungus-1x1": ("#574729", "#846b3c", "#ba944f"),
    "honeycomb-fungus-decayed": ("#463d2d", "#665943", "#8d7c5f"),
    "matches-small": ("#6b3b24", "#a8522d", "#eb7e38"),
    "muddy-stump": ("#3b2b1d", "#5e452e", "#947451"),
    "pink-phalanges": ("#73414c", "#aa6272", "#d8909f"),
    "polycephalum-balloon": ("#523956", "#7e5684", "#b284b8"),
    "red-pita": ("#6b2b24", "#9c3e32", "#c95f4b"),
    "solo-barnacle": ("#4e4b45", "#767168", "#9f998c"),
    "v-red-pita": ("#682923", "#973b30", "#c25b47"),
    "yellow-coral": ("#7a5e22", "#b38c30", "#dfc053"),
}


def sample_palette(factorio, name, entry):
    low_h, mid_h, tip_h = FALLBACK_PALETTES[name]
    fallback = (hexcol(low_h), hexcol(mid_h), hexcol(tip_h))
    if not factorio:
        return fallback
    for pic in entry.get("pics", []):
        rel = pic[0]
        full = os.path.join(factorio, "data", rel)
        if not os.path.isfile(full):
            continue
        try:
            with Image.open(full) as im:
                im = im.convert("RGBA")
                x, y, w, h = int(pic[1]), int(pic[2]), int(pic[3]), int(pic[4])
                if w > 0 and h > 0 and x + w <= im.width and y + h <= im.height:
                    im = im.crop((x, y, x + w, y + h))
                arr = np.asarray(im, dtype=float) / 255.0
        except Exception:
            continue
        alpha = arr[..., 3] > 0.55
        lum = arr[..., :3] @ np.array([0.2126, 0.7152, 0.0722])
        # Skip baked shadow texels (pure black / near-black) when computing plant palette.
        mask = alpha & (lum > 0.09)
        if int(mask.sum()) < 20:
            mask = alpha & (lum > 0.04)
        if int(mask.sum()) < 16:
            return fallback
        cols = arr[..., :3][mask]
        order = np.argsort(cols @ np.array([0.2126, 0.7152, 0.0722]))
        sorted_cols = cols[order]
        n = len(sorted_cols)
        low = tuple(float(v) for v in np.median(sorted_cols[: max(n // 3, 4)], axis=0))
        mid = tuple(float(v) for v in np.median(sorted_cols[n // 4 : (3 * n) // 4 + 1], axis=0))
        tip = tuple(float(v) for v in np.median(sorted_cols[max((2 * n) // 3, n - 4) :], axis=0))
        # Blend lightly with fallback chroma so dark sprites never lose hue under directional sunlight.
        return mix(low, fallback[0], 0.2), mix(mid, fallback[1], 0.2), mix(tip, fallback[2], 0.2)
    return fallback


def is_grass_decor(name, entry):
    return entry.get("layer") == "decorative" and any(w in name for w in GRASS_WORDS)


def blade(w, h, lean, col_base, col_tip, bend_mid=0.35):
    """Tapered two-segment arched blade in XY rising from (0,0,0) along +Y and leaning +X (4 tris)."""
    w0 = w * 0.5
    w1 = w * 0.34
    ym = h * 0.52
    xm = lean * bend_mid
    xm_tip = lean
    v0 = (-w0, 0.0, 0.0)
    v1 = (w0, 0.0, 0.0)
    v2 = (xm - w1, ym, 0.03 * h)
    v3 = (xm + w1, ym, 0.03 * h)
    v4 = (xm_tip, h, -0.02 * h)
    # Slightly folded V cross-section for volume from any yaw angle.
    col_mid = mix(col_base, col_tip, 0.55)
    tris = [
        [v0, v1, v3],
        [v0, v3, v2],
        [v2, v3, v4],
        [v0, v4, v1],  # double-sided / subtle back catch
    ]
    return kit._flat(tris[:3], [col_base, col_base, col_mid]) + kit._flat(
        [[v2, v3, v4]], [col_tip]
    )


def tuft_clump(rng, radius, height, blades, w_blade, low, mid, tip):
    parts = []
    for i in range(blades):
        ang = (360.0 * i / blades) + rng.uniform(-16.0, 16.0)
        hi = height * rng.uniform(0.68, 1.15)
        lean = radius * rng.uniform(0.35, 0.85)
        ro = radius * rng.uniform(0.05, 0.28)
        bw = w_blade * rng.uniform(0.8, 1.2)
        b = blade(bw, hi, lean, mix(low, mid, rng.uniform(0.0, 0.5)), tip)
        b = b.move(x=ro).rot_y(ang)
        parts.append(b)
    return merge(*parts)


def make_carpet(seed, span, height, clusters, low, mid, tip):
    rng = random.Random(seed)
    parts = []
    r_patch = min(max(span * 0.36, 0.38), 0.72)
    for i in range(clusters):
        ang = (2.0 * math.pi * i / max(clusters - 1, 1)) + rng.uniform(-0.35, 0.35)
        dist = 0.0 if i == 0 else r_patch * rng.uniform(0.35, 1.0)
        cx, cz = math.cos(ang) * dist, math.sin(ang) * dist
        clump = tuft_clump(rng, 0.14, height * rng.uniform(0.75, 1.15), 3, 0.07, low, mid, tip)
        parts.append(clump.rot_y(rng.uniform(0, 360)).move(x=cx, z=cz))
    return merge(*parts)


def make_asterisk(seed, r, height, arms, low, mid, tip):
    rng = random.Random(seed)
    parts = [prism(r * 0.18, height * 0.35, 5, low, r_top=r * 0.06, cap=mid, smooth=False)]
    for i in range(arms):
        ang = 360.0 * i / arms + rng.uniform(-10.0, 10.0)
        b = blade(r * 0.34, height * rng.uniform(0.8, 1.1), r * rng.uniform(0.7, 0.95), low, tip, bend_mid=0.55)
        parts.append(b.rot_y(ang))
    return merge(*parts)


def make_fluff(seed, r, height, stalks, low, mid, tip):
    rng = random.Random(seed)
    parts = [tuft_clump(rng, r * 0.55, height * 0.45, 5, r * 0.18, low, mid, mid)]
    for i in range(stalks):
        ang = 360.0 * i / stalks + rng.uniform(-18.0, 18.0)
        h = height * rng.uniform(0.75, 1.08)
        lean = r * rng.uniform(0.18, 0.45)
        tilt_deg = math.degrees(math.atan2(lean, h))
        stem = prism(0.018, h, 4, low, r_top=0.010, cap=mid, smooth=False).rot_z(-tilt_deg)
        head = rock(0.08, 0.09, 0.08, tip, seed=seed + i + 10, points=5, flat_base=False, round_=True).move(
            x=lean * 0.85, y=h * 0.94
        )
        parts.append(merge(stem, head).rot_y(ang))
    return merge(*parts)


def make_croton(seed, r, height, leaves, low, mid, tip):
    rng = random.Random(seed)
    parts = []
    for i in range(leaves):
        ang = 360.0 * i / leaves + rng.uniform(-14.0, 14.0)
        h = height * (0.65 if i % 2 else 1.0) * rng.uniform(0.85, 1.1)
        reach = r * rng.uniform(0.55, 0.95)
        bw = r * rng.uniform(0.36, 0.52)
        leaf = blade(bw, h, reach, mix(low, mid, 0.4), tip, bend_mid=0.5)
        parts.append(leaf.rot_y(ang))
    return merge(*parts)


def make_bush(seed, r, height, blobs, low, mid, tip):
    rng = random.Random(seed)
    parts = [
        prism(r * 0.11, height * 0.55, 5, hexcol("#55402b"), r_top=r * 0.05, smooth=False),
        rock(r * 1.1, height * 0.55, r * 1.0, low, seed=seed + 1, points=6, flat_base=True, round_=True),
    ]
    for i in range(blobs):
        ang = (2.0 * math.pi * i / blobs) + rng.uniform(-0.4, 0.4)
        dist = r * rng.uniform(0.15, 0.48)
        sc = r * rng.uniform(0.58, 0.85)
        hy = height * rng.uniform(0.28, 0.58)
        col = mid if i % 2 == 0 else mix(mid, tip, 0.6)
        b = rock(sc, height * rng.uniform(0.38, 0.55), sc * 0.92, col, seed=seed + 20 + i, points=6, flat_base=False, round_=True)
        parts.append(b.move(x=math.cos(ang) * dist, y=hy, z=math.sin(ang) * dist))
    return merge(*parts)


def make_pita(seed, r, height, outer_n, inner_n, low, mid, tip):
    rng = random.Random(seed)
    parts = []
    for i in range(outer_n):
        ang = 360.0 * i / outer_n + rng.uniform(-8.0, 8.0)
        parts.append(blade(r * 0.34, height * 0.78, r * 0.85, low, mix(mid, tip, 0.6), 0.55).rot_y(ang))
    for i in range(inner_n):
        ang = 360.0 * (i + 0.5) / inner_n + rng.uniform(-10.0, 10.0)
        parts.append(blade(r * 0.25, height * 1.05, r * 0.42, mid, tip, 0.45).rot_y(ang))
    return merge(*parts)


def make_object(name, seed, sz, pal):
    low, mid, tip = pal
    rng = random.Random(seed)
    span = max(sz[0], sz[1], 0.35)
    # Match sprite dimensions cleanly while keeping floating-iceberg readable (JSON uses 0.005 sprite scale!).
    if name == "floating-iceberg-large":
        base = rock(2.2, 1.35, 1.9, low, seed=seed, points=8, flat_base=True)
        spire = rock(1.1, 1.85, 0.95, mix(mid, tip, 0.45), seed=seed + 3, points=7, flat_base=True).move(x=0.22, z=-0.12)
        cap = rock(1.5, 0.65, 1.3, tip, seed=seed + 7, points=7, flat_base=False).move(y=0.9)
        return shade_by_height(merge(base, spire, cap), low=0.72)
    if name == "floating-iceberg-small":
        base = rock(1.15, 0.8, 1.0, low, seed=seed, points=7, flat_base=True)
        spire = rock(0.65, 1.05, 0.6, tip, seed=seed + 5, points=6, flat_base=True).move(x=-0.1, z=0.08)
        return shade_by_height(merge(base, spire), low=0.74)
    if name in ("green-pita", "red-pita", "v-red-pita", "fuchsia-pita"):
        r = min(span * 0.42, 0.65)
        return make_pita(seed, r, max(0.55, r * 1.15), 7, 5, low, mid, tip)
    if name in ("garballo", "garballo-mini-dry"):
        r = max(0.24, min(span * 0.48, 0.55))
        h = 0.58 if name == "garballo" else 0.42
        trunk = prism(r * 0.2, h * 0.55, 5, low, r_top=r * 0.1, smooth=False)
        crown = make_bush(seed, r, h * 0.85, 4, low, mid, tip).move(y=h * 0.25)
        return shade_by_height(merge(trunk, crown), low=0.76)
    if name == "muddy-stump":
        mound = rock(0.72, 0.18, 0.68, scale(low, 0.85), seed=seed, points=7, flat_base=True)
        trunk = prism(0.24, 0.48, 7, mid, r_top=0.19, cap=tip, smooth=False)
        roots = [box(0.12, 0.22, 0.26, low).rot_x(25).rot_y(i * 90 + 20).move(x=math.cos(i * 1.57) * 0.22, z=math.sin(i * 1.57) * 0.22) for i in range(4)]
        return shade_by_height(merge(mound, trunk, *roots), low=0.75)
    if name == "brambles":
        parts = [rock(0.85, 0.35, 0.8, low, seed=seed, points=6, flat_base=True, round_=True)]
        for i in range(8):
            ang = 45.0 * i + rng.uniform(-12, 12)
            parts.append(blade(0.11, rng.uniform(0.55, 0.8), rng.uniform(0.45, 0.72), low, tip, 0.6).rot_y(ang))
        return merge(*parts)
    if name == "black-sceptre":
        parts = []
        for i in range(5):
            ang = 72.0 * i + rng.uniform(-12, 12)
            off = rng.uniform(0.08, 0.34)
            h = rng.uniform(0.75, 1.25)
            cx, cz = math.cos(math.radians(ang)) * off, math.sin(math.radians(ang)) * off
            stalk = prism(0.04, h, 5, low, r_top=0.025, smooth=False)
            bulb = prism(0.075, 0.22, 6, mid, r_top=0.02, cap=tip, smooth=False).move(y=h * 0.86)
            parts.append(merge(stalk, bulb).move(x=cx, z=cz))
        return shade_by_height(merge(*parts), low=0.74)
    if name in ("blood-grape", "blood-grape-vibrant"):
        parts = [prism(0.1, 0.68, 5, scale(low, 0.8), r_top=0.05, smooth=False)]
        for i in range(7):
            ang = 2.0 * math.pi * i / 7 + rng.uniform(-0.25, 0.25)
            d = rng.uniform(0.12, 0.38)
            hy = rng.uniform(0.32, 0.76)
            col = mid if i % 2 == 0 else tip
            orb = rock(0.24, 0.24, 0.24, col, seed=seed + i, points=6, flat_base=False, round_=True)
            parts.append(orb.move(x=math.cos(ang) * d, y=hy, z=math.sin(ang) * d))
        return shade_by_height(merge(*parts), low=0.78)
    if name == "green-cup":
        parts = []
        for i, (ox, oz, sc, h) in enumerate([(0.0, 0.0, 0.38, 0.62), (0.36, -0.22, 0.28, 0.46), (-0.3, 0.26, 0.26, 0.42)]):
            stem = prism(sc * 0.28, h * 0.52, 6, low, r_top=sc * 0.4, smooth=False)
            bowl = prism(sc * 0.4, h * 0.55, 7, mid, r_top=sc, cap=tip, smooth=False).move(y=h * 0.48)
            parts.append(merge(stem, bowl).move(x=ox, z=oz))
        return shade_by_height(merge(*parts), low=0.76)
    if "honeycomb-fungus" in name:
        sc = 0.75 if "1x1" in name else (0.9 if "decayed" in name else 1.15)
        parts = []
        for (ox, oz, r, h) in [(0.0, 0.0, 0.38 * sc, 0.72 * sc), (0.38 * sc, 0.2 * sc, 0.26 * sc, 0.5 * sc), (-0.34 * sc, -0.24 * sc, 0.24 * sc, 0.46 * sc)]:
            stalk = prism(r * 0.34, h * 0.75, 6, low, r_top=r * 0.26, smooth=False)
            cap = prism(r, h * 0.36, 7, mid, r_top=r * 0.4, cap=tip, smooth=False).move(y=h * 0.68)
            parts.append(merge(stalk, cap).move(x=ox, z=oz))
        return shade_by_height(merge(*parts), low=0.76)
    if name == "matches-small":
        parts = []
        for i in range(6):
            ang = 60.0 * i + rng.uniform(-15, 15)
            d = rng.uniform(0.04, 0.14)
            h = rng.uniform(0.32, 0.52)
            stem = prism(0.022, h, 4, low, r_top=0.018, smooth=False)
            head = rock(0.085, 0.11, 0.085, mix(mid, tip, 0.7), seed=seed + i, points=5, flat_base=False, round_=True).move(y=h)
            parts.append(merge(stem, head).rot_z(rng.uniform(-10, 10)).move(x=math.cos(math.radians(ang)) * d, z=math.sin(math.radians(ang)) * d))
        return shade_by_height(merge(*parts), low=0.8)
    if name == "pink-phalanges":
        parts = []
        for i in range(6):
            ang = 60.0 * i + rng.uniform(-14, 14)
            d = rng.uniform(0.14, 0.42)
            h = rng.uniform(0.55, 0.95)
            finger = prism(0.11, h, 6, low, r_top=0.065, cap=tip, smooth=False).rot_z(rng.uniform(-14, 14))
            parts.append(finger.rot_y(ang).move(x=math.cos(math.radians(ang)) * d, z=math.sin(math.radians(ang)) * d))
        return shade_by_height(merge(*parts), low=0.78)
    if name == "polycephalum-balloon":
        parts = []
        for i, (ox, oz, sc, h) in enumerate([(0.0, 0.0, 0.34, 0.72), (0.38, -0.18, 0.25, 0.54), (-0.34, 0.22, 0.24, 0.52)]):
            stalk = prism(sc * 0.22, h * 0.65, 5, low, r_top=sc * 0.18, smooth=False)
            bulb = rock(sc * 1.4, sc * 1.3, sc * 1.4, mid if i else tip, seed=seed + i, points=6, flat_base=False, round_=True).move(y=h * 0.65)
            parts.append(merge(stalk, bulb).move(x=ox, z=oz))
        return shade_by_height(merge(*parts), low=0.76)
    if name in ("coral-land", "coral-water", "yellow-coral"):
        parts = []
        for i in range(6):
            ang = 60.0 * i + rng.uniform(-15, 15)
            d = rng.uniform(0.1, 0.38)
            h = rng.uniform(0.45, 0.85)
            horn = prism(0.085, h, 5, low, r_top=0.04, cap=tip, smooth=False).rot_z(-16.0)
            sub = prism(0.055, h * 0.5, 5, mid, r_top=0.025, cap=tip, smooth=False).rot_z(24.0).move(y=h * 0.45)
            parts.append(merge(horn, sub).rot_y(ang).move(x=math.cos(math.radians(ang)) * d, z=math.sin(math.radians(ang)) * d))
        return shade_by_height(merge(*parts), low=0.78)
    if name == "solo-barnacle":
        cone = prism(0.2, 0.26, 7, low, r_top=0.095, cap=mid, smooth=False)
        rim = prism(0.1, 0.08, 7, tip, r_top=0.075, cap=scale(low, 0.5), smooth=False).move(y=0.23)
        return shade_by_height(merge(cone, rim), low=0.74)
    if name == "fulgora-sunk-ruin-medium":
        slab = box(0.68, 0.85, 0.52, mid, top=tip).rot_z(14.0).rot_y(20.0)
        rib1 = box(0.2, 0.62, 0.22, low, top=mid).move(x=-0.38, z=0.22).rot_x(-10.0)
        rib2 = box(0.24, 0.44, 0.24, tip).move(x=0.34, z=-0.26)
        return shade_by_height(merge(slab, rib1, rib2), low=0.72)
    raise ValueError("unhandled object decorative: %s" % name)


def make_grass_model(name, seed, sz, pal):
    low, mid, tip = pal
    span = max(sz[0], sz[1], 0.3)
    if "carpet" in name:
        return make_carpet(seed, span, 0.26, 8, low, mid, tip)
    if "asterisk" in name:
        r = 0.22 if "mini" in name else 0.42
        h = 0.16 if "mini" in name else 0.30
        return make_asterisk(seed, r, h, 7, low, mid, tip)
    if "fluff" in name:
        return make_fluff(seed, 0.28, 0.42, 4, low, mid, tip)
    if "croton" in name:
        return make_croton(seed, 0.32, 0.32, 6, low, mid, tip)
    if "bush" in name:
        r = 0.24 if "mini" in name else 0.32
        h = 0.28 if "mini" in name else 0.38
        return make_bush(seed, r, h, 4, low, mid, tip)
    if "pita-mini" in name:
        return make_pita(seed, 0.30, 0.34, 6, 4, low, mid, tip)
    # Tuft / hairy / small grass
    rng = random.Random(seed)
    r = min(max(span * 0.45, 0.28), 0.52)
    h = 0.38 if "hairy" in name else 0.28
    return tuft_clump(rng, r, h, 9, 0.085, low, mid, tip)


def finalize_ground(mesh):
    lo, hi = mesh.bounds()
    cx = (lo[0] + hi[0]) * 0.5
    cz = (lo[2] + hi[2]) * 0.5
    return mesh.move(x=-cx, y=-lo[1], z=-cz)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(DECORATIVES_JSON, encoding="utf-8") as f:
        data = json.load(f)
    factorio = kit.find_factorio()
    print("Factorio install:", factorio or "none (using built-in palettes)")
    targets = sorted(k for k, v in data.items() if v.get("layer") == "object" or is_grass_decor(k, v))
    for i, name in enumerate(targets):
        entry = data[name]
        pics = entry.get("pics", [])
        if pics:
            w = float(pics[0][3]) * float(pics[0][5]) / 64.0
            h = float(pics[0][4]) * float(pics[0][5]) / 64.0
        else:
            w, h = 0.6, 0.6
        pal = sample_palette(factorio, name, entry)
        seed = 1000 + i * 37
        if entry.get("layer") == "object":
            mesh = make_object(name, seed, (w, h), pal)
        else:
            mesh = make_grass_model(name, seed, (w, h), pal)
        mesh = finalize_ground(mesh)
        out = os.path.join(OUT_DIR, name + ".glb")
        tris = write_glb(out, mesh, name)
        lo, hi = mesh.bounds()
        print("  %-28s %.2fx%.2fx%.2f  %3d tris" % (name, hi[0] - lo[0], hi[2] - lo[2], hi[1] - lo[1], tris))
    print("Generated %d placeholder decorative models in %s" % (len(targets), OUT_DIR))


if __name__ == "__main__":
    main()
