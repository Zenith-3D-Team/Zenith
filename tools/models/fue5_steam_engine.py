#!/usr/bin/env python3
"""Fits FUE5's steam engine to Factorio's length (owner's L5), on the converted .glb.

    python tools/models/fue5_steam_engine.py

Run after `fue5.py steam-engine`; a file already done is left alone. Plain Python, no Blender. It
bakes the model's occlusion again at the end (bake_glb.py), for the new shape.

FUE5's engine (three upright tanks in a row) was fitted to Zenith's own engine, 5.83 tiles long:
0.4 past each end of its 5-tile box. Factorio chains engines end to end, and its picture ends at
the box's ends (steam-engine-H.png's opaque pixels run -2.50..2.50 tiles from its centre, the pipe
flanges at the ends meeting the next engine's), so two of FUE5's placed end to end overlapped by
0.83 tiles (an engine and its boiler too). It is squeezed along its length to LENGTH, centred on
its box, and across and up by a little less, so its round tanks stay round to within ROUND; its
moving parts' pivots go with it.

The result stays under FUE5's licence (CC BY-NC-SA 3.0, packs/fue5/README.md).
"""

import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import packs  # noqa: E402
from part_colors import Glb  # noqa: E402

PATH = packs.fue5_path("steam-engine")
# North-south, tiles: Factorio's 5 less the gap its tanks keep between themselves (0.03), so two
# engines end to end touch as its pictures do without their tanks fighting.
LENGTH = 4.97
# Across and up are squeezed by the length's squeeze over this: a tank's top view stays this round.
ROUND = 0.95


def fit(path=PATH):
    glb = Glb(path)
    doc = glb.doc
    extras = doc.setdefault("asset", {}).get("extras") or {}
    if extras.get("zenith_fit"):
        print("already fitted:", extras["zenith_fit"])
        return False
    meshed = [n for n in doc["nodes"] if "mesh" in n]
    for n in meshed:
        if any(k in n for k in ("rotation", "scale", "matrix", "children")):
            raise SystemExit("%s: node %s isn't a plain translation; fit it in Blender instead" % (path, n.get("name")))
    lo, hi = np.full(3, np.inf), np.full(3, -np.inf)
    for n in meshed:
        t = np.array(n.get("translation", [0.0, 0.0, 0.0]))
        for prim in doc["meshes"][n["mesh"]]["primitives"]:
            p = glb.accessor(prim["attributes"]["POSITION"]) + t
            lo, hi = np.minimum(lo, p.min(axis=0)), np.maximum(hi, p.max(axis=0))
    sz = LENGTH / (hi[2] - lo[2])
    s = np.array([sz / ROUND, sz / ROUND, sz])
    shift = np.array([0.0, 0.0, -(lo[2] + hi[2]) / 2 * sz])
    # glTF: x east, y up, z south. A node's points are its translation plus its mesh's: both scaled,
    # the shift on the translation (the pivot a moving part turns about moves with it).
    done = set()
    for n in meshed:
        n["translation"] = (np.array(n.get("translation", [0.0, 0.0, 0.0])) * s + shift).tolist()
        for prim in doc["meshes"][n["mesh"]]["primitives"]:
            attrs = prim["attributes"]
            if attrs["POSITION"] not in done:
                done.add(attrs["POSITION"])
                p = glb.accessor(attrs["POSITION"]) * s
                glb.overwrite(attrs["POSITION"], p)
                acc = doc["accessors"][attrs["POSITION"]]
                acc["min"], acc["max"] = p.min(axis=0).tolist(), p.max(axis=0).tolist()
            if "NORMAL" in attrs and attrs["NORMAL"] not in done:
                done.add(attrs["NORMAL"])
                nrm = glb.accessor(attrs["NORMAL"]) / s
                nrm /= np.maximum(np.linalg.norm(nrm, axis=1, keepdims=True), 1e-12)
                glb.overwrite(attrs["NORMAL"], nrm)
    extras["zenith_fit"] = {"length": LENGTH, "scale": [round(float(v), 4) for v in s]}
    doc["asset"]["extras"] = extras
    glb.save(path)
    size = (hi - lo) * s
    print("fitted: %.2f x %.2f x %.2f tiles (east-west, up, north-south), scaled x%.3f x%.3f x%.3f"
          % (size[0], size[1], size[2], s[0], s[1], s[2]))
    # Its occlusion again, for the new shape.
    import bake_glb
    tris, mean = bake_glb.bake_file(path)
    print("occlusion baked: %d triangles, mean %.2f" % (tris, mean))
    return True


if __name__ == "__main__":
    fit(sys.argv[1] if len(sys.argv) > 1 else PATH)
