"""Checks exported models against the conventions in docs/PLAN.md §4 and the budgets in §6.4.

    python tools/models/check.py [names or .glb paths...]

With no arguments it checks every .glb in the three packs (packs.py: ours, then FUE5's). A name
is ours, or FUE5's when only FUE5 has it; fue5/<name> (or placeholders/, wube3dp/) names that
pack's. Plain Python (reads the glTF binary directly), no Blender needed. For each model:

- the name is a known prototype (docs/ASSET-INVENTORY.md) or a variant listed in specs.py;
- the footprint (x by z extents) fits the selection box and fills enough of it. For entities
  that aren't square this also catches a model turned 90 degrees;
- the origin is on the ground (lowest point at y = 0) and at the footprint centre;
- no root node is rotated, so "facing north" lives in the geometry, not in a node transform
  (a square model built facing the wrong way can't be caught here: look at a preview);
- the triangle count is within budget.

A model in a folder called `items` is an item (items on belts, MODELLERS.md): its name must be an
item the Placeholders pack has a model for, and it must fit in a tile, sit on the ground, be centred
and stay within specs.ITEM_BUDGET. Numbered ore rocks (`iron-ore-1`, specs.ORE_VARIANTS) are known.

Exits 1 if any model fails.
"""

import json
import math
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

import packs  # noqa: E402
import specs  # noqa: E402

INVENTORY = os.path.join(REPO, "docs", "ASSET-INVENTORY.md")
ITEMS = os.path.join(REPO, "client", "assets", "models", "packs", "placeholders", "items")
DECORATIVES_JSON = os.path.join(REPO, "client", "data", "decoratives.json")
DECOR_SIZE = 4.5
DECOR_BUDGET = 250


def known_items():
    return {os.path.splitext(f)[0] for f in os.listdir(ITEMS) if f.endswith(".glb")} if os.path.isdir(ITEMS) else set()


def known_decoratives():
    if not os.path.isfile(DECORATIVES_JSON):
        return set()
    with open(DECORATIVES_JSON, encoding="utf-8") as f:
        return set(json.load(f).keys())


def is_item(path):
    return os.path.basename(os.path.dirname(os.path.abspath(path))).lower() == "items"


def is_decorative(path):
    return os.path.basename(os.path.dirname(os.path.abspath(path))).lower() == "decoratives"


def is_ore_variant(name):
    m = re.fullmatch(r"(.+)-(\d+)", name)
    return bool(m) and m.group(1) in specs.ORE_VARIANTS


def known_prototypes():
    names = set()
    with open(INVENTORY, encoding="utf-8") as f:
        text = f.read()
    for name in re.findall(r"`([a-z0-9][a-z0-9-]*)`", text):
        names.add(name)
    # `tree-01` … `tree-09`
    for prefix, a, b in re.findall(r"`([a-z-]+?)(\d+)`\s*…\s*`[a-z-]+?(\d+)`", text):
        for i in range(int(a), int(b) + 1):
            names.add("%s%0*d" % (prefix, len(a), i))
    return names


def read_glb(path):
    with open(path, "rb") as f:
        data = f.read()
    magic, version, _length = struct.unpack_from("<4sII", data, 0)
    if magic != b"glTF" or version != 2:
        raise ValueError("not a glTF 2 binary")
    offset, doc = 12, None
    while offset < len(data):
        size, kind = struct.unpack_from("<I4s", data, offset)
        if kind == b"JSON":
            doc = json.loads(data[offset + 8:offset + 8 + size])
        offset += 8 + size
    if doc is None:
        raise ValueError("no JSON chunk")
    return doc


def mat_mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def node_matrix(node):
    if "matrix" in node:
        m = node["matrix"]  # column-major
        return [[m[c * 4 + r] for c in range(4)] for r in range(4)]
    tx, ty, tz = node.get("translation", [0, 0, 0])
    qx, qy, qz, qw = node.get("rotation", [0, 0, 0, 1])
    sx, sy, sz = node.get("scale", [1, 1, 1])
    r = [
        [1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qz * qw), 2 * (qx * qz + qy * qw)],
        [2 * (qx * qy + qz * qw), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qx * qw)],
        [2 * (qx * qz - qy * qw), 2 * (qy * qz + qx * qw), 1 - 2 * (qx * qx + qy * qy)],
    ]
    return [
        [r[0][0] * sx, r[0][1] * sy, r[0][2] * sz, tx],
        [r[1][0] * sx, r[1][1] * sy, r[1][2] * sz, ty],
        [r[2][0] * sx, r[2][1] * sy, r[2][2] * sz, tz],
        [0, 0, 0, 1],
    ]


def is_rotated(node):
    if "matrix" in node:
        m = node_matrix(node)
        return any(abs(m[i][j] - (1 if i == j else 0)) > 1e-4 for i in range(3) for j in range(3))
    q = node.get("rotation", [0, 0, 0, 1])
    return abs(abs(q[3]) - 1) > 1e-4


def measure(doc):
    """World-space bounds (min, max), triangle count, and rotated root node names."""
    lo, hi = [math.inf] * 3, [-math.inf] * 3
    tris = 0
    scene = doc["scenes"][doc.get("scene", 0)]
    rotated = [doc["nodes"][i].get("name", str(i)) for i in scene["nodes"] if is_rotated(doc["nodes"][i])]

    def visit(index, parent):
        nonlocal tris
        node = doc["nodes"][index]
        m = mat_mul(parent, node_matrix(node))
        if "mesh" in node:
            for prim in doc["meshes"][node["mesh"]]["primitives"]:
                pos = doc["accessors"][prim["attributes"]["POSITION"]]
                if prim.get("mode", 4) == 4:
                    count = doc["accessors"][prim["indices"]]["count"] if "indices" in prim else pos["count"]
                    tris += count // 3
                a, b = pos["min"], pos["max"]
                for cx in (a[0], b[0]):
                    for cy in (a[1], b[1]):
                        for cz in (a[2], b[2]):
                            p = [sum(m[r][k] * v for k, v in enumerate((cx, cy, cz, 1))) for r in range(3)]
                            for i in range(3):
                                lo[i] = min(lo[i], p[i])
                                hi[i] = max(hi[i], p[i])
        for child in node.get("children", []):
            visit(child, m)

    identity = [[1 if i == j else 0 for j in range(4)] for i in range(4)]
    for root in scene["nodes"]:
        visit(root, identity)
    return lo, hi, tris, rotated


def check_item(name, lo, hi, tris, rotated, items):
    problems = []
    if name not in items:
        problems.append("unknown item (no Placeholders item model of that name)")
    w, d = hi[0] - lo[0], hi[2] - lo[2]
    cx, cz = (hi[0] + lo[0]) / 2, (hi[2] + lo[2]) / 2
    if abs(lo[1]) > specs.GROUND_TOLERANCE:
        problems.append("lowest point at y=%.3f, not on the ground" % lo[1])
    if rotated:
        problems.append("rotated root node(s) %s: model the rotation into the mesh" % ", ".join(rotated))
    if w > specs.ITEM_SIZE or d > specs.ITEM_SIZE:
        problems.append("item %.2f x %.2f larger than a tile" % (w, d))
    if abs(cx) > specs.ITEM_CENTRE or abs(cz) > specs.ITEM_CENTRE:
        problems.append("item centred at (%.2f, %.2f), not the origin" % (cx, cz))
    if tris > specs.ITEM_BUDGET:
        problems.append("%d triangles, item budget %d" % (tris, specs.ITEM_BUDGET))
    return problems


def check_decorative(name, lo, hi, tris, rotated, decors):
    problems = []
    base = re.sub(r"-\d+$", "", name)
    if name not in decors and base not in decors:
        problems.append("unknown decorative (not in client/data/decoratives.json)")
    w, d = hi[0] - lo[0], hi[2] - lo[2]
    if abs(lo[1]) > specs.GROUND_TOLERANCE:
        problems.append("lowest point at y=%.3f, not on the ground" % lo[1])
    if rotated:
        problems.append("rotated root node(s) %s: model the rotation into the mesh" % ", ".join(rotated))
    if w > DECOR_SIZE or d > DECOR_SIZE:
        problems.append("decorative %.2f x %.2f exceeds %g x %g" % (w, d, DECOR_SIZE, DECOR_SIZE))
    if tris > DECOR_BUDGET:
        problems.append("%d triangles, decorative budget %d" % (tris, DECOR_BUDGET))
    return problems


def check(path, known, items=None, decors=None):
    name = os.path.splitext(os.path.basename(path))[0]
    problems, notes = [], []
    if is_item(path):
        try:
            lo, hi, tris, rotated = measure(read_glb(path))
        except Exception as e:
            return name, ["unreadable: %s" % e], [], None
        if lo[0] == math.inf:
            return name, ["no meshes"], [], None
        problems = check_item(name, lo, hi, tris, rotated, known_items() if items is None else items)
        return "items/" + name, problems, [], "%5.2f x %5.2f x %4.2f  %6d tris" % (
            hi[0] - lo[0], hi[2] - lo[2], hi[1] - lo[1], tris)
    if is_decorative(path):
        try:
            lo, hi, tris, rotated = measure(read_glb(path))
        except Exception as e:
            return name, ["unreadable: %s" % e], [], None
        if lo[0] == math.inf:
            return name, ["no meshes"], [], None
        problems = check_decorative(name, lo, hi, tris, rotated, known_decoratives() if decors is None else decors)
        return "decoratives/" + name, problems, [], "%5.2f x %5.2f x %4.2f  %6d tris" % (
            hi[0] - lo[0], hi[2] - lo[2], hi[1] - lo[1], tris)
    spec = specs.SPECS.get(name)
    if spec is None and name not in known and not is_ore_variant(name):
        problems.append("unknown name (not a prototype in ASSET-INVENTORY.md or a variant in specs.py)")
    try:
        doc = read_glb(path)
        lo, hi, tris, rotated = measure(doc)
    except Exception as e:  # a broken file is a failure, not a crash
        return name, ["unreadable: %s" % e], [], None
    if lo[0] == math.inf:
        return name, ["no meshes"], [], None
    # glTF: x east, y up, z south (north is -z).
    w, d = hi[0] - lo[0], hi[2] - lo[2]
    cx, cz = (hi[0] + lo[0]) / 2, (hi[2] + lo[2]) / 2
    sink = spec.get("sink", 0.0) if spec else 0.0
    lift = spec.get("lift", 0.0) if spec else 0.0  # elevated rails float on their supports
    if lo[1] > lift + specs.GROUND_TOLERANCE or lo[1] < -sink - specs.GROUND_TOLERANCE:
        problems.append("lowest point at y=%.3f, not on the ground" % lo[1])
    if rotated:
        problems.append("rotated root node(s) %s: model the rotation into the mesh" % ", ".join(rotated))
    if spec:
        sw, sd = spec["size"]
        fw, fd = spec.get("fill", specs.DEFAULT_FILL)
        overhang = spec.get("overhang", specs.OVERHANG)
        if w > sw + overhang or d > sd + overhang:
            problems.append("footprint %.2f x %.2f exceeds %g x %g" % (w, d, sw, sd))
        if w < sw * fw or d < sd * fd:
            problems.append("footprint %.2f x %.2f too small for %g x %g (turned or mis-scaled?)" % (w, d, sw, sd))
        tol = spec.get("centre", specs.CENTRE_TOLERANCE)
        if abs(cx) > tol * max(sw, 1) or abs(cz) > tol * max(sd, 1):
            problems.append("footprint centred at (%.2f, %.2f), not the origin" % (cx, cz))
        if tris > spec["budget"]:
            problems.append("%d triangles, budget %d" % (tris, spec["budget"]))
    else:
        notes.append("no spec in specs.py: footprint and budget not checked")
    summary = "%5.2f x %5.2f x %4.2f  %6d tris" % (w, d, hi[1] - lo[1], tris)
    return name, problems, notes, summary


def main(argv):
    known = known_prototypes()
    items = known_items()
    decors = known_decoratives()
    paths = []
    for arg in argv:
        if arg.endswith((".glb", ".gltf")):
            paths.append(arg)
        else:
            paths.append(packs.resolve(arg))
    if not paths:
        paths = packs.glbs(fue5=True)
    failed = 0
    for path in paths:
        if not os.path.exists(path):
            print("FAIL %-28s missing: %s" % (os.path.basename(path), path))
            failed += 1
            continue
        name, problems, notes, summary = check(path, known, items, decors)
        if packs.pack_of(path) == "fue5":
            name = "fue5/" + name  # most share a name with one of ours
        print("%s %-28s %s" % ("FAIL" if problems else "ok  ", name, summary or ""))
        for p in problems:
            print("       - " + p)
        for n in notes:
            print("       . " + n)
        failed += bool(problems)
    print("%d checked, %d failed" % (len(paths), failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
