"""Builds the procedural models and exports them to their pack (packs.py: over the model of that
name where it is, a new one into client/assets/models/packs/placeholders/<name>.glb).

    blender --background --factory-startup --python tools/models/build.py -- [names...] [--out=DIR]

With no names it rebuilds every registered model, except those already replaced by a model
converted from Wube's printable files (tools/models/wube.py); name one to rebuild it anyway. Then
run `python tools/models/check.py` and `godot --headless --path client --import`.
"""

import importlib
import json
import os
import struct
import sys
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

import kit  # noqa: E402
import packs  # noqa: E402
import specs  # noqa: E402

# One module per family; each registers its models with @kit.model.
MODULES = ["belts", "chests", "machines", "power", "defence", "fluids", "electric", "oil", "vehicles",
           "circuits", "logistics", "rails", "railway", "crash_site", "fish", "military", "nuclear", "rocket",
           "space_platform", "vulcanus", "fulgora", "space_nature"]
MODULES += ["gleba", "aquilo"]  # Space Age: Gleba and Aquilo (m-space2)
MODULES += ["placeholders"]  # entities the client drew as boxes (placeholders.py)
MODULES += ["mech_armor"]  # the character in Space Age's mech armour

# The glTF generator tag tools/models/wube.py writes into the models it converts.
WUBE_GENERATOR = "factorio-3d tools/models/wube.py"


def converted_from_wube(path):
    """True if the .glb at path was made by tools/models/wube.py."""
    try:
        with open(path, "rb") as f:
            head = f.read(20)
            size = struct.unpack_from("<I", head, 12)[0]
            doc = json.loads(f.read(size))
    except (OSError, ValueError, struct.error):
        return False
    return doc.get("asset", {}).get("generator") == WUBE_GENERATOR


def out_path(out_dir, name):
    """--out's folder, or the model's own pack."""
    return os.path.join(out_dir, name + ".glb") if out_dir else packs.out_path(name)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    out_dir = None  # the packs
    names = []
    for arg in argv:
        if arg.startswith("--out="):
            out_dir = os.path.abspath(arg.split("=", 1)[1])
        else:
            names.append(arg)

    for module in MODULES:
        importlib.import_module(module)
    if not names:
        names = []
        for name in sorted(kit.REGISTRY):
            if converted_from_wube(out_path(out_dir, name)):
                print("build: keep %-28s converted from Wube's model; name it to rebuild" % name)
            else:
                names.append(name)
    unknown = [n for n in names if n not in kit.REGISTRY]
    if unknown:
        print("build: unknown model(s): %s" % ", ".join(unknown))
        print("build: known: %s" % ", ".join(sorted(kit.REGISTRY)))
        return 1

    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    failed = 0
    for name in names:
        start = time.time()
        try:
            parts = kit.as_parts(kit.REGISTRY[name]())
            tris = sum(p.triangles() for p in parts)
            path = out_path(out_dir, name)
            kit.export(parts, path)
        except Exception:
            traceback.print_exc()
            print("build: FAIL %s" % name)
            failed += 1
            continue
        budget = specs.SPECS.get(name, {}).get("budget", 0)
        flag = "" if not budget or tris <= budget else "  OVER BUDGET (%d)" % budget
        print("build: %-28s %6d tris  %.1fs%s" % (name, tris, time.time() - start, flag))
    print("build: %d built, %d failed -> %s" % (len(names) - failed, failed, out_dir or packs.PACKS_DIR))
    if len(names) > failed:
        # Blender's Python has no scipy: the part colours (the client's default look) are a step after.
        print("build: next, part colours from the sprites: python tools/models/part_colors.py %s" % " ".join(names))
    return 1 if failed else 0


if __name__ == "__main__":
    code = main()
    sys.stdout.flush()
    sys.exit(code)
