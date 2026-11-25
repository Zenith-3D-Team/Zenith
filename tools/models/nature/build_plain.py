#!/usr/bin/env python3
"""build_nature.py on a PC without Blender: the Nauvis nature models built in plain Python.

    python tools/models/nature/build_plain.py [names...] [--out DIR]

The same model functions (trees.py, rocks.py, cliffs.py), with plain_geo.py in geo.py's place and
noblender.py's stand-ins for `mathutils`; the same .glb layout (plain_geo.py). Output goes to the
model's pack (tools/models/packs.py: client/assets/models/packs/placeholders/<name>.glb) unless
--out says otherwise. Then, as after build_nature.py:

    python tools/models/part_colors.py <names...>        # each part's colour from the sprite
    python tools/models/nature/tree_looks.py              # the client's variations (trees' heights)
    python tools/models/nature/score.py <names...>        # silhouettes against the sprites
    godot --headless --path client --import

Blender's noise isn't here (plain_geo.noise is its own), so a model with lumpy blobs comes out with
other lumps than a Blender build of it; everything else is the same.
"""

import os
import random
import sys
import time
import types
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))  # tools/models
TRI_BUDGET = 3000


def setup():
    """The stand-ins in sys.modules, plain_geo as `geo`; returns the registry of models."""
    import noblender
    noblender.install()
    import plain_geo
    sys.modules["geo"] = plain_geo
    sys.modules["mathutils"].noise = types.SimpleNamespace(noise=plain_geo.noise)
    import cliffs
    import rocks
    import trees
    return {**trees.MODELS, **rocks.MODELS, **cliffs.MODELS}


def build(name, registry):
    """One model built: (plain_geo.Model, triangles)."""
    import plain_geo
    import trees
    import cliffs
    seed = {**trees.SEED_AS, **cliffs.SEED_AS}.get(name, name)
    m = plain_geo.Model(name, random.Random(zlib.crc32(seed.encode())))
    registry[name](m)
    return m, m.triangles()


def main(argv):
    import packs
    out = None  # each model's pack
    names = []
    it = iter(argv)
    for a in it:
        if a == "--out":
            out = os.path.abspath(next(it))
        else:
            names.append(a)
    registry = setup()
    unknown = [n for n in names if n not in registry]
    if unknown:
        raise SystemExit("unknown model(s): %s" % ", ".join(unknown))
    if out:
        os.makedirs(out, exist_ok=True)
    over = []
    for name in names or list(registry):
        t0 = time.time()
        m, tris = build(name, registry)
        m.export(os.path.join(out, name + ".glb") if out else packs.out_path(name))
        zs = [v.co.z for v in m.bm.verts]
        print("%-22s %5d tris  z %5.2f..%5.2f  %.1fs" % (name, tris, min(zs), max(zs), time.time() - t0))
        if tris > TRI_BUDGET:
            over.append(name)
    if over:
        print("OVER BUDGET (%d tris): %s" % (TRI_BUDGET, ", ".join(over)))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
