#!/usr/bin/env python3
"""Writes client/data/nature_looks.json: how the client varies Nauvis trees and rocks, measured from
Factorio's own sprites (numbers only; the pictures stay in the player's install).

    python tools/models/nature/tree_looks.py [--check]

Per tree prototype (tree-01, tree-08-brown...):
  weights   Factorio's variation_weights (or evenly): how often each variation grows.
  shapes    per variation [across, up, tilt, squash] for its model (variation a's shape):
            standing ones scaled `across` (x, z) and `up` (y) to the variation's leaves against a's;
            fallen ones (the last two of six types, lying or leaning) scaled by `across`, tipped
            `tilt` degrees over and squashed `squash` up and down, so the crown lies on the ground.
  tints     the prototype's `colors`, each over their mean in linear light: one of them, picked per
            tree, multiplies its leaves (the models' leaves are the mean already).
  leaves    the leaves picture (variation a, frame 0) and the PATCH-pixel patches of it the client's
            leaf cards wear (nature_looks.gd): their centres, and the crown's mean colour (linear).
Per rock (big-rock, huge-rock, big-sand-rock):
  shapes    per picture [across, up] against the picture the model was fitted to; the client picks
            one evenly, as Factorio does.

--check compares with the committed file and exits 1 when it differs.
"""

import json
import math
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, HERE)
sys.path.append(os.path.dirname(HERE))  # tools/models, after nature/ (both have a score.py)
import packs  # noqa: E402
import raster  # noqa: E402
import tree_sprites as ts  # noqa: E402

OUT = os.path.join(REPO, "client", "data", "nature_looks.json")
COS = math.cos(math.radians(48.0))
# A fallen tree's crown presses this far into the ground at most (tiles), as the sprites' lie flat;
# it is tipped this far over (degrees), its trunk resting on its roots and crown.
SINK = 0.2
TILT = 84.0


def _r(x, k=3):
    return round(float(x), k)


def model_points(name):
    m = raster.Model(packs.model_path(name))
    return m.p.reshape(-1, 3)


def _ground_points(tree, letter, part, cut=0.5):
    """A variation's picture's opaque pixels as points on the ground (east, north) in tiles from the
    entity: a fallen tree lies flat, so its picture's north-south is the ground's, drawn at COS48."""
    img, (w, h, sx, sy) = ts.picture(tree, letter, part)
    ys, xs = np.nonzero(img[..., 3] > cut)
    east = (xs + 0.5 - w / 2) / ts.PX + sx / 32.0
    up = -((ys + 0.5 - h / 2) / ts.PX + sy / 32.0)
    return np.c_[east, up / math.sin(math.radians(48.0))]


def fallen_shape(points, tree, letter):
    """[across, up, tilt, squash, back] for a fallen variation, lying on the ground as its picture
    does: as long as the picture's trunk and crown (on the ground), tipped TILT degrees, squashed so
    its crown sinks no more than SINK into the ground, and its root end `back` tiles behind the
    entity (the client lays it along a random way, as it turns standing trees)."""
    trunk = _ground_points(tree, letter, "trunk")
    leaves = _ground_points(tree, letter, "leaves")
    both = np.r_[trunk, leaves]
    centre = both.mean(0)
    val, vec = np.linalg.eigh(np.cov((both - centre).T))
    axis = vec[:, 1]
    if (leaves.mean(0) - trunk.mean(0)) @ axis < 0.0:
        axis = -axis  # from the roots towards the crown
    along = (both - centre) @ axis
    lo, hi = np.percentile(along, 0.5), np.percentile(along, 99.5)
    length = hi - lo
    back = float(-(centre @ axis + lo))  # the entity's distance from the root end, along the tree
    height = points[:, 1].max()
    scale = length / height
    a = math.radians(-TILT)
    c, s = math.cos(a), math.sin(a)
    p = points * scale
    y = p[:, 0] * s + p[:, 1] * c
    low = -y.min()
    squash = 1.0 if low <= SINK else max(0.3, SINK / low)
    return [_r(scale), _r(scale), TILT, _r(squash), _r(back)]


def tree_entry(name, proto):
    t = proto["type"]
    vars_ = ts.variations(t)
    a = vars_[0]
    aw = a["leaves"][1] - a["leaves"][0]
    ah = a["leaves"][3]
    points = None
    shapes = []
    for v in vars_:
        if v["fallen"]:
            if points is None:
                points = model_points(name if os.path.exists(packs.model_path(name)) else "tree-" + t)
            shapes.append(fallen_shape(points, t, v["letter"]))
            continue
        up = v["leaves"][3] / ah
        across = (v["leaves"][1] - v["leaves"][0]) / aw
        # Keep the trunk's thickness believable: across within a quarter of up.
        across = min(max(across, up * 0.75), up * 1.25)
        shapes.append([_r(across), _r(up), 0.0, 1.0, 0.0])
    weights = proto["weights"] or [1.0] * len(vars_)
    weights = weights[:len(vars_)] + [weights[-1]] * (len(vars_) - len(weights))
    entry = {
        "weights": [_r(x, 2) for x in weights],
        "shapes": shapes,
        "tints": [[_r(c) for c in rt] for rt in ts.relative_tints(t, name)],
    }
    patches = ts.leaf_patches(t)
    if not patches:
        return entry  # tree-06: strands of leaves, no cards to dress
    img, (w, h, _, _) = ts.picture(t, "a", "leaves")
    entry["leaves"] = {
        "file": "__base__/graphics/entity/tree/%s/tree-%s-a-leaves.png" % (t, t),
        "frame": [int(w), int(h)],
        "patch": ts.PATCH,
        "patches": [[int(x), int(y)] for x, y in patches],
        "mean": [_r(c, 4) for c in ts.crown_mean(img)],
    }
    return entry


ROCKS = {
    # name: (folder, file pattern, picture numbers, the picture its model was fitted to)
    "big-rock": ("big-rock", "big-rock-%02d.png", range(1, 21), 1),
    "huge-rock": ("huge-rock", "huge-rock-%02d.png", range(5, 21), 5),
    "big-sand-rock": ("sand-rock", "big-sand-rock-%02d.png", range(1, 17), 1),
}


def rock_entry(name):
    folder, pat, nums, fitted = ROCKS[name]

    def extent(k):
        img = np.asarray(Image.open(os.path.join(ts.data_dir(), "base", "graphics", "decorative", folder, pat % k)).convert("RGBA"))
        ys, xs = np.nonzero(img[..., 3] > 40)
        return xs.max() - xs.min() + 1, ys.max() - ys.min() + 1
    w0, h0 = extent(fitted)
    shapes = []
    for k in nums:
        w, h = extent(k)
        across, up = w / w0, h / h0
        shapes.append([_r(across), _r(min(max(up, across * 0.7), across * 1.3))])
    return {"shapes": shapes}


# How much of the grain the bark and rock materials take (nature_looks.gd `detail`'s strength).
BARK_GRAIN = 0.8
ROCK_GRAIN = 0.9
ROCK_PICTURES = {"rock": "__base__/graphics/decorative/big-rock/big-rock-01.png",
                 "sand-rock": "__base__/graphics/decorative/sand-rock/big-sand-rock-01.png"}


def details():
    """The grain layers ([{file, rect}]) and which materials wear which ({material: [layer, strength]}):
    each tree type's bark from its trunk picture (variation a), the rocks' from their first picture."""
    layers, materials = [], {}
    for t in sorted(ts.tree_types()):
        img, _ = ts.picture(t, "a", "trunk")
        rect = ts.bark_strip(img[..., 3])
        if rect is None:
            continue
        materials["bark-" + t] = [len(layers), BARK_GRAIN]
        layers.append({"file": "__base__/graphics/entity/tree/%s/tree-%s-a-trunk.png" % (t, t), "rect": list(rect)})
    for material, path in ROCK_PICTURES.items():
        x, y, side = ts.opaque_square(ts.load_file(path)[..., 3])
        materials[material] = [len(layers), ROCK_GRAIN]
        layers.append({"file": path, "rect": [int(x), int(y), int(side), int(side)]})
    return {"size": ts.DETAIL, "layers": layers, "materials": materials}


def build():
    trees = {}
    for name, proto in sorted(ts.prototypes().items()):
        if proto["enabled"]:
            trees[name] = tree_entry(name, proto)
    rocks = {name: rock_entry(name) for name in ROCKS}
    return {"trees": trees, "rocks": rocks, "grain": details()}


def main(argv):
    data = build()
    text = json.dumps(data, indent=1, sort_keys=True) + "\n"
    if "--check" in argv:
        old = open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else ""
        if old != text:
            print("nature_looks.json differs from what the sprites give")
            return 1
        print("nature_looks.json is current")
        return 0
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    for name, e in data["trees"].items():
        fallen = [s for s in e["shapes"] if s[2]]
        print("%-16s %2d variations (%d fallen: %s), %d tints, %d patches" % (
            name, len(e["shapes"]), len(fallen), fallen, len(e["tints"]), len(e.get("leaves", {}).get("patches", []))))
    for name, e in data["rocks"].items():
        ups = [s[1] for s in e["shapes"]]
        print("%-16s %2d pictures, height %.2f..%.2f" % (name, len(ups), min(ups), max(ups)))
    print("wrote", OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
