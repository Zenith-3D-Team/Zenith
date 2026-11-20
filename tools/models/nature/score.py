#!/usr/bin/env python3
"""Scores nature models against Factorio's sprites from Factorio's camera, in plain Python (raster.py
draws them; no Blender, no window).

    python tools/models/nature/score.py [NAME[@REF] ...] [--models DIR] [--yaws N]

NAME is one of our models (tools/models/packs.py), or the one in --models' folder, or a .glb's path.

For each model (default: the Nauvis trees and rocks), against its sprite (variation a, or the rock's
picture its model was fitted to; @REF picks another), as Factorio's camera sees both:

  overlap   silhouette overlap (intersection over union) at the model's own turn, the sprite's pose
  turned    the same averaged over N turns round its trunk (--yaws, default 8): the client turns
            every tree and rock at random, so a model has to read as its sprite from every side
  gaps      inside the crown's outline (each row between its outermost pixels), the share that is see-
            through: Factorio's crowns are clumps with gaps where the trunk, limbs or ground show
  clumps    how strongly light and shade vary at a clump's scale (a band of 0.06-0.35 tiles) over
            the leaves, against the sprite's: 1 is as clumpy as the sprite, under it flatter
  tris      triangles, and leaf cards

Rocks: the sprite's drawn-in shadow (near black) is left out of its silhouette, as compare.py does.
Prints one line per model and the means. Reads the sprites from the player's install; draws nothing.
"""

import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.append(os.path.dirname(HERE))  # tools/models, after nature/ (both have a score.py)
import packs  # noqa: E402
import raster  # noqa: E402
import tree_sprites as ts  # noqa: E402

TREES = ["tree-0%d" % i for i in (1, 2, 3, 4, 5, 6, 7, 8, 9)]
ROCKS = ["big-rock", "huge-rock", "big-sand-rock"]
FITTED = {"big-rock": "1", "huge-rock": "5", "big-sand-rock": "1"}
PPT = 64.0
LUMA = np.array([0.2126, 0.7152, 0.0722])


def turned(model, yaw):
    """A copy of a raster.Model turned `yaw` radians about its vertical axis (glTF y)."""
    c, s = math.cos(yaw), math.sin(yaw)
    r = np.array([[c, 0.0, s], [0.0, 1.0, 0.0], [-s, 0.0, c]])
    out = object.__new__(type(model))
    out.__dict__.update(model.__dict__)
    out.p = model.p @ r.T
    out.n = model.n @ r.T
    return out


def _blur(a, sigma):
    """A Gaussian blur (separable, edges clamped) of an (h, w) array."""
    rad = max(1, int(3 * sigma))
    x = np.arange(-rad, rad + 1)
    k = np.exp(-0.5 * (x / sigma) ** 2)
    k /= k.sum()
    for axis in (0, 1):
        p = np.pad(a, [(rad, rad) if i == axis else (0, 0) for i in (0, 1)], mode="edge")
        a = sum(w * np.take(p, np.arange(i, i + a.shape[axis]), axis=axis) for i, w in enumerate(k))
    return a


def _canvas(parts):
    """Sprite and model layers on one canvas by their entity points: [(rgb, alpha)] aligned."""
    above = max(oy for _, _, _, oy in parts)
    left = max(ox for _, _, ox, _ in parts)
    below = max(a.shape[0] - oy for _, a, _, oy in parts)
    right = max(a.shape[1] - ox for _, a, ox, _ in parts)
    H, W = int(math.ceil(above + below)) + 2, int(math.ceil(left + right)) + 2
    out = []
    for rgb, a, ox, oy in parts:
        R = np.zeros((H, W, 3))
        A = np.zeros((H, W))
        y0, x0 = int(round(above - oy)), int(round(left - ox))
        R[y0:y0 + a.shape[0], x0:x0 + a.shape[1]] = rgb[:H - y0, :W - x0]
        A[y0:y0 + a.shape[0], x0:x0 + a.shape[1]] = a[:H - y0, :W - x0]
        out.append((R, A))
    return out


def gaps(mask):
    rows = np.nonzero(mask.any(1))[0]
    inside = total = 0
    for r in rows:
        xs = np.nonzero(mask[r])[0]
        span = mask[r, xs.min():xs.max() + 1]
        total += span.size
        inside += span.size - span.sum()
    return inside / max(total, 1)


def clumpiness(rgb, mask):
    """The spread of luminance at a clump's scale over the opaque pixels: a band pass of the
    luminance (blurred at 0.06 tiles less blurred at 0.35), its standard deviation over the mean."""
    lum = rgb @ LUMA
    m = mask.astype(np.float64)

    def masked_blur(v, sigma):
        return _blur(v * m, sigma) / np.maximum(_blur(m, sigma), 1e-3)
    band = masked_blur(lum, 0.06 * PPT) - masked_blur(lum, 0.35 * PPT)
    inner = mask & (_blur(m, 0.06 * PPT) > 0.9)
    if inner.sum() < 50:
        return 0.0
    return float(band[inner].std() / max(lum[inner].mean(), 1e-3))


def score(path, name, ref, yaws):
    model = raster.Model(path)
    model_name = os.path.basename(path)[:-4]
    atlas = raster.Atlas(model_name) if ts.tree_type(model_name) else None
    sprite, (sox, soy) = ts.reference(model_name, ref, PPT)
    s_rgb, s_a = sprite[..., :3], sprite[..., 3]
    rock = model_name in ROCKS
    s_mask = (s_a > 0.5) & ((s_rgb.max(axis=2) > 0.06) if rock else True)
    out = {"tris": len(model.mat), "cards": int(sum(1 for t in range(len(model.mat)) if model.kind(t) == "card") // 2)}
    ious = []
    for k in range(yaws):
        img, alpha, (ox, oy) = raster.draw(turned(model, k * math.tau / yaws), PPT, "atlas", atlas, shadows=False)
        (sr, sa), (mr, ma) = _canvas([(s_rgb, s_mask.astype(np.float64), sox, soy), (img, alpha, ox, oy)])
        sm, mm = sa > 0.5, ma > 0.5
        ious.append((sm & mm).sum() / max((sm | mm).sum(), 1))
        if k == 0:
            out["overlap"] = ious[0]
            out["gaps"] = (gaps(mm), gaps(sm))
            if not rock:
                out["clumps"] = clumpiness(mr, mm) / max(clumpiness(sr, sm), 1e-6)
    out["turned"] = float(np.mean(ious))
    return out


def main(argv):
    models_dir, yaws, names = None, 8, []  # models_dir None: our packs
    it = iter(argv)
    for a in it:
        if a == "--models":
            models_dir = next(it)
        elif a == "--yaws":
            yaws = int(next(it))
        else:
            names.append(a)
    rows = []
    for spec in names or TREES + ROCKS:
        name, _, ref = spec.partition("@")
        ref = ref or FITTED.get(name) or None
        if name.endswith(".glb"):
            path = name
        else:
            path = os.path.join(models_dir, name + ".glb") if models_dir else packs.model_path(name)
        r = score(path, os.path.basename(path)[:-4], ref, yaws)
        rows.append(r)
        clump = " clumps %.2f" % r["clumps"] if "clumps" in r else ""
        print("SCORE %-16s overlap %.3f  turned %.3f  gaps %.2f (sprite %.2f)%s  %5d tris %4d cards" % (
            os.path.basename(path)[:-4], r["overlap"], r["turned"], r["gaps"][0], r["gaps"][1], clump, r["tris"], r["cards"]))
    if len(rows) > 1:
        print("MEAN  overlap %.3f  turned %.3f" % (np.mean([r["overlap"] for r in rows]), np.mean([r["turned"] for r in rows])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
