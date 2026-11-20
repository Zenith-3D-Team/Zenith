"""Where the built-in models live: three packs under client/assets/models/packs/, one per source.

    placeholders/  Zenith's own models, built from Factorio's sprites (build.py, noblender.py,
                   nature/, worm.py and the rest), with the belt pieces, curves and underground ends
    wube3dp/       Wube's printable models as wube.py converts them (its CREDITS.md), and the poses
                   creature_pose.py makes from them
    fue5/          FUE5's textured models as fue5.py converts them (its README.md)

Each holds a pack.json. Which pack's model the client draws for a name is decided at runtime by
the packs' order (client/scripts/world/model_packs.gd, the Model packs window); the
tools don't order them.

For the tools "our models" are placeholders and wube3dp together, as when they were one folder
(client/assets/models/): a name is in one of them at most, so it has one path, and a rebuild
overwrites the file where it is. A new model of ours goes to placeholders. FUE5's are apart (each
shares a name with one of ours), as when they were the fue5/ subfolder. placeholders/items/ (items on belts,
items.py) holds the Placeholders pack's item models; the tools here don't look in it.

Plain Python, no dependencies: Blender's Python imports it too.
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

PACKS_DIR = os.path.join(REPO, "client", "assets", "models", "packs")
PLACEHOLDERS_DIR = os.path.join(PACKS_DIR, "placeholders")
WUBE_DIR = os.path.join(PACKS_DIR, "wube3dp")
FUE5_DIR = os.path.join(PACKS_DIR, "fue5")
# Ours, looked in in this order (a name is never in both).
OURS = (WUBE_DIR, PLACEHOLDERS_DIR)
PACKS = {"placeholders": PLACEHOLDERS_DIR, "wube3dp": WUBE_DIR, "fue5": FUE5_DIR}


def model_path(name):
    """Our model of this name: its .glb in wube3dp or placeholders, else where a new one goes."""
    for folder in OURS:
        path = os.path.join(folder, name + ".glb")
        if os.path.exists(path):
            return path
    return os.path.join(PLACEHOLDERS_DIR, name + ".glb")


def out_path(name, beside=None):
    """Where a tool writes our model of this name: over the one there, else into placeholders, or
    with `beside` into that model's pack (a creature's pose next to the creature)."""
    path = model_path(name)
    if beside and not os.path.exists(path):
        return os.path.join(os.path.dirname(model_path(beside)), name + ".glb")
    return path


def fue5_path(name):
    return os.path.join(FUE5_DIR, name + ".glb")


def glbs(fue5=False):
    """Every .glb of ours (wube3dp and placeholders), sorted by name; FUE5's after them if asked."""
    paths = sorted((os.path.join(d, f) for d in OURS if os.path.isdir(d) for f in os.listdir(d)
                    if f.endswith(".glb")), key=lambda p: os.path.basename(p))
    if fue5 and os.path.isdir(FUE5_DIR):
        paths += sorted(os.path.join(FUE5_DIR, f) for f in os.listdir(FUE5_DIR) if f.endswith(".glb"))
    return paths


def names():
    """The names of our models, sorted."""
    return [os.path.basename(p)[:-4] for p in glbs()]


def pack_of(path):
    """The pack ("placeholders", "wube3dp" or "fue5") a file is in, or None outside them."""
    folder = os.path.normcase(os.path.dirname(os.path.abspath(path)))
    for pack, d in PACKS.items():
        if folder == os.path.normcase(d):
            return pack
    return None


def resolve(arg):
    """The .glb of a model named on a command line: "<name>" is ours, else FUE5's when only FUE5
    has it; "<pack>/<name>" is that pack's. Where it would be if there is none (callers say so)."""
    pack, _, name = arg.rpartition("/")
    if pack:
        return os.path.join(PACKS.get(pack, os.path.join(PACKS_DIR, pack)), name + ".glb")
    path = model_path(name)
    if not os.path.exists(path) and os.path.exists(fue5_path(name)):
        return fue5_path(name)
    return path
