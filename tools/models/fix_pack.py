"""Makes a fixed copy of a modeller's export, from a list of fixes kept as data.

    python tools/models/fix_pack.py <source folder> <output folder> [--fixes tools/models/fixes/<list>.json]

A modeller's export often can't be used by Zenith as it is: a name that isn't Factorio's, items at
the top level instead of in `items/`, an origin tiles away from the footprint, a pipe piece that
has to serve several of Zenith's pipe shapes, an emission picture wired where nothing glows, a
see-through (Alpha Blend) material whose picture is opaque. This writes a copy with those fixed,
leaving the source folder untouched, and is meant to be run again on the modeller's next export: the
fixes live in a JSON list (`tools/models/fixes/vasillo.json` for Vasillo's). Mostly the glTF JSON is
changed (names, a root transform, materials); the BIN chunk (meshes, textures, animations) is copied
byte for byte, except in a file built from several models, given an inside or with an emission
picture unwired, whose BIN is rebuilt from the parts it uses (pictures shared, nothing re-encoded).

The list, `"files"`: one entry per source model, by its file name without `.glb`:

    "pipe": {
        "offset": [-3, 0, 0],             # moved by this first (in tiles; glTF axes, x east, y up, z south)
        "centre": false,                  # true: also moved so its box is centred in x and z (y kept)
        "out": [                          # the files written, each turned by `turn` degrees
            {"name": "pipe-straight-vertical"},                 # clockwise seen from above, about
            {"name": "pipe-straight-horizontal", "turn": 90},   # the (moved) origin
            {"name": "pipe-ending-up",                          # with other source models merged in,
             "add": [{"model": "pipe-cap", "turn": 180,         # each moved by its own entry and turned;
                      "inside": true}]}                         # "inside" on a part: that part alone
                                                                # drawn from both sides (add_inside)
        ],
        "mask": ["Pipe_Straight"],        # these materials become Alpha Clip (glTF MASK)
        "inside": true,                   # every triangle also drawn from behind (add_inside): a
                                          # single-sided shell with an open end, which Blender shows
                                          # from inside and Zenith (one side only) doesn't
        "note": "free text: what was measured, why"
    }

`out` defaults to one file of the same name; a name may hold a folder (`items/iron-plate`); `[]`
writes nothing (a model used only as a part). The move and turn are put on the root node(s):
composed into each scene root's own transform, or, when a root is animated, on a new root node
holding them. `"alpha_cutoff"` (default 0.5) is the clip threshold.

`"materials"` holds rules for every model, listed or not:
- `"unwire_emission": true`: an emission picture with no `emissiveFactor` (glTF: no emission, but
  some readers light it anyway) is unwired;
- `"alpha_by_picture": true`: a BLEND material whose base colour picture's alpha is full on every
  pixel becomes OPAQUE, and one with under `"mask_share"` (default 0.05) of its pixels below full
  becomes MASK; the rest (glass) stays BLEND, as do `"keep_blend"` names. PNGs are read with zlib.

`"metal": 0` (per file): every material's `metallicFactor` is set to this in the written copy (glTF multiplies
the metallic-roughness picture by it, so the picture itself stays his), for rock his export leaves at the
glTF default 1.

`"keep_rest_turn": ["Roller1", ...]` (per file): those objects' rotation keys are put after their rest
turn (rest * key), for an export whose keys spin an object about its own axle but leave out the turn it
stands at (glTF's keys replace the rest rotation, so it lies turned while the action plays); keys that
already keep the rest turn are left, with a warning. The new keys go at the end of the BIN, which is compacted.

`"recolour"` holds rules per material name, for every model (other keys, such as a `"note"`, are text):

    "Iron_Ore": {"mean": [81, 86, 87], "metallic": 0.2, "note": "where the target came from"}

- `"mean"`: the base colour picture is rewritten so its sRGB mean over the pixels the material's
  triangles use (points spread over their surface by area) is this; each colour channel is scaled in
  linear space, clamped to 1, alpha kept;
- `"brightness"`: the same with one scale for all three channels, to this mean linear luminance;
  `"scale"`: one linear scale as given;
- `"metallic"`, `"roughness"`: the material's metallicFactor and roughnessFactor set to these.
A picture is worked out once, on the first model that uses it, and the same result written wherever the
same picture comes again. The new picture is an RGBA8 PNG (filter 0), the old one dropped from the BIN.

`"pack_json"`: keys written into the copy's top `pack.json` (the source's, copied, with these over it; a
new one when the source has none), for example `{"shading": "pbr"}` (Zenith draws the pack's textured models
as their files say: docs/MODELLERS.md). A `"note"` in it is text, not written.

Anything else (`pack.json`, a README, icons, a model nothing changes) is copied unchanged. Plain
Python, no dependencies.
"""

import argparse
import base64
import copy
import hashlib
import json
import math
import os
import shutil
import struct
import sys
import zlib
from urllib.parse import unquote

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_FIXES = os.path.join(HERE, "fixes", "vasillo.json")
MODEL_EXTS = (".glb", ".gltf")


# --- glTF files -------------------------------------------------------------------------------


def read_model(path):
    """(doc, chunks): the glTF JSON and, for a .glb, its other chunks as [(type, bytes)]."""
    with open(path, "rb") as f:
        data = f.read()
    if path.lower().endswith(".gltf"):
        return json.loads(data.decode("utf-8")), None
    magic, version, _length = struct.unpack_from("<4sII", data, 0)
    if magic != b"glTF" or version != 2:
        raise ValueError("%s: not a glTF 2 binary" % path)
    offset, doc, chunks = 12, None, []
    while offset + 8 <= len(data):
        size, kind = struct.unpack_from("<I4s", data, offset)
        body = data[offset + 8:offset + 8 + size]
        if kind == b"JSON" and doc is None:
            doc = json.loads(body.decode("utf-8"))
        else:
            chunks.append((kind, body))
        offset += 8 + size
    if doc is None:
        raise ValueError("%s: no JSON chunk" % path)
    return doc, chunks


def write_model(path, doc, chunks):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    text = json.dumps(doc, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    if chunks is None:
        with open(path, "wb") as f:
            f.write(text)
        return
    text += b" " * (-len(text) % 4)  # the JSON chunk is padded with spaces
    parts = [struct.pack("<I4s", len(text), b"JSON"), text]
    for kind, body in chunks:
        pad = b"\0" * (-len(body) % 4)
        parts += [struct.pack("<I4s", len(body) + len(pad), kind), body, pad]
    body = b"".join(parts)
    with open(path, "wb") as f:
        f.write(struct.pack("<4sII", b"glTF", 2, 12 + len(body)))
        f.write(body)


# --- transforms -------------------------------------------------------------------------------


def quat_mul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return [aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw,
            aw * bw - ax * bx - ay * by - az * bz]


def turn_quat(turn):
    """A turn clockwise seen from above (north -> east) is a negative angle about +y."""
    half = math.radians(-turn) / 2
    q = [0.0, math.sin(half), 0.0, math.cos(half)]
    return [0.0 if abs(c) < 1e-12 else c for c in q]


def rotate(q, v):
    x, y, z, w = q
    m = [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
         [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
         [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]]
    return [sum(m[r][k] * v[k] for k in range(3)) for r in range(3)]


def clean(values):
    return [0.0 if abs(c) < 1e-9 else round(c, 9) for c in values]


def fix_matrix(q, offset):
    """The fix (turn after moving by offset) as a row-major 4x4."""
    r = [rotate(q, e) for e in ([1, 0, 0], [0, 1, 0], [0, 0, 1])]  # columns
    t = rotate(q, offset)
    return [[r[0][i], r[1][i], r[2][i], t[i]] for i in range(3)] + [[0, 0, 0, 1]]


def apply_to_node(node, q, offset):
    """node's local transform becomes fix * node."""
    if "matrix" in node:
        m = node["matrix"]  # column-major
        local = [[m[c * 4 + r] for c in range(4)] for r in range(4)]
        f = fix_matrix(q, offset)
        out = [[sum(f[i][k] * local[k][j] for k in range(4)) for j in range(4)] for i in range(4)]
        node["matrix"] = clean([out[r][c] for c in range(4) for r in range(4)])
        return
    t = node.get("translation", [0, 0, 0])
    node["translation"] = clean(rotate(q, [t[i] + offset[i] for i in range(3)]))
    node["rotation"] = clean(quat_mul(q, node.get("rotation", [0, 0, 0, 1])))
    for key, identity in (("translation", [0, 0, 0]), ("rotation", [0, 0, 0, 1])):
        if node[key] == identity:
            del node[key]


def transform_roots(doc, turn, offset, wrapper_name):
    """Moves by offset, then turns, every scene's content. Returns what was done, for the log."""
    if not turn and not any(offset):
        return ""
    q = turn_quat(turn)
    scenes = doc.get("scenes", [])
    roots = []
    for scene in scenes:
        for i in scene.get("nodes", []):
            if i not in roots:
                roots.append(i)
    animated = {c["target"].get("node") for a in doc.get("animations", []) for c in a.get("channels", [])
                if c.get("target", {}).get("path") in ("translation", "rotation", "scale")}
    if roots and not animated.intersection(roots):
        for i in roots:
            apply_to_node(doc["nodes"][i], q, offset)
        return "root"
    # An animated root would lose the fix on its first frame: hold everything in a new root.
    doc.setdefault("nodes", [])
    new = {"name": wrapper_name}
    apply_to_node(new, q, offset)
    for scene in scenes:
        index = len(doc["nodes"])
        node = dict(new, children=list(scene.get("nodes", [])))
        doc["nodes"].append(node)
        scene["nodes"] = [index]
    return "new root"


def keep_rest_turn(doc, chunks, names):
    """The `"keep_rest_turn"` fix: each named object's rotation keys put after its rest turn (rest * key).

    glTF's rotation keys replace a node's rest rotation. An export whose keys only spin an object about its
    own axle (Vasillo's splitter rollers: a turn about z) and leave out the rest turn that lays it across
    the belt (-90 degrees about y) shows the object turned a quarter as soon as the action plays, in any
    glTF reader. Keys whose first value is already nearer the rest turn than no turn are left alone (an
    export that keeps it). Returns (chunks, log lines, problems)."""
    nodes = doc.get("nodes", [])
    done, problems, data, made = [], [], None, {}
    users = {}  # output accessor -> the rotation channels' nodes that read it
    for anim in doc.get("animations", []):
        for ch in anim.get("channels", []):
            smp = anim["samplers"][ch["sampler"]]
            users.setdefault(smp["output"], []).append((ch.get("target", {}).get("node"), ch.get("target", {}).get("path")))
    for name in names:
        index = next((i for i, n in enumerate(nodes) if n.get("name") == name), None)
        if index is None:
            problems.append("keep_rest_turn: no node %s" % name)
            continue
        rest = [float(c) for c in nodes[index].get("rotation", [0, 0, 0, 1])]
        if "matrix" in nodes[index] or abs(abs(rest[3]) - 1) < 1e-6:
            problems.append("keep_rest_turn: %s has no rest turn to keep" % name)
            continue
        fixed = 0
        for anim in doc.get("animations", []):
            for ch in anim.get("channels", []):
                if ch.get("target", {}).get("node") != index or ch["target"].get("path") != "rotation":
                    continue
                smp = anim["samplers"][ch["sampler"]]
                old = smp["output"]
                key = (old, tuple(rest))
                if key in made:  # keys shared with an object done already (its accessor may be the new one)
                    smp["output"] = made[key]
                    fixed += 1
                    continue
                acc = doc["accessors"][old]
                values = read_accessor(doc, chunks, old) if acc.get("componentType") == 5126 else None
                if not values:
                    problems.append("keep_rest_turn: %s's keys aren't plain floats, left" % name)
                    continue
                first = values[1] if smp.get("interpolation") == "CUBICSPLINE" and len(values) > 1 else values[0]
                if abs(sum(a * b for a, b in zip(first, rest))) >= abs(first[3]):
                    problems.append("keep_rest_turn: %s's keys already keep its rest turn, left" % name)
                    continue
                if data is None:
                    data = bytearray(bin_chunk(chunks))
                data += b"\0" * (-len(data) % 4)
                turned = [clean(quat_mul(rest, list(v))) for v in values]
                doc["bufferViews"].append({"buffer": 0, "byteOffset": len(data), "byteLength": 16 * len(values)})
                data += b"".join(struct.pack("<4f", *v) for v in turned)
                new = {k: v for k, v in acc.items() if k not in ("byteOffset", "min", "max", "sparse")}
                new["bufferView"] = len(doc["bufferViews"]) - 1
                # Only these nodes' rotations read it: changed in place, so the old keys drop out of the BIN.
                if all(u == (index, "rotation") or (u[1] == "rotation" and u[0] is not None
                       and [float(c) for c in nodes[u[0]].get("rotation", [0, 0, 0, 1])] == rest
                       and nodes[u[0]].get("name") in names) for u in users.get(old, [])):
                    doc["accessors"][old] = new
                    made[key] = old
                else:
                    doc["accessors"].append(new)
                    made[key] = len(doc["accessors"]) - 1
                smp["output"] = made[key]
                fixed += 1
        if fixed:
            done.append("%s keeps its rest turn" % name)
        elif not any(p.startswith("keep_rest_turn: %s" % name) for p in problems):
            problems.append("keep_rest_turn: %s has no rotation keys" % name)
    if data is not None:
        doc["buffers"][0]["byteLength"] = len(data)
        chunks = compact(doc, [(b"BIN\0", bytes(data))] + [c for c in chunks if c[0] != b"BIN\0"])
    return chunks, done, problems


def node_matrix(node):
    """A node's local transform as a row-major 4x4."""
    if "matrix" in node:
        m = node["matrix"]
        return [[m[c * 4 + r] for c in range(4)] for r in range(4)]
    s = node.get("scale", [1, 1, 1])
    r = [rotate(node.get("rotation", [0, 0, 0, 1]), e) for e in ([1, 0, 0], [0, 1, 0], [0, 0, 1])]
    t = node.get("translation", [0, 0, 0])
    return [[r[0][i] * s[0], r[1][i] * s[1], r[2][i] * s[2], t[i]] for i in range(3)] + [[0, 0, 0, 1]]


def box(doc):
    """The scene's bounds (lo, hi) from the accessors' min/max, through the node transforms."""
    lo, hi = [math.inf] * 3, [-math.inf] * 3
    scene = doc["scenes"][doc.get("scene", 0)]

    def visit(index, parent):
        node = doc["nodes"][index]
        local = node_matrix(node)
        m = [[sum(parent[i][k] * local[k][j] for k in range(4)) for j in range(4)] for i in range(4)]
        for prim in doc["meshes"][node["mesh"]]["primitives"] if "mesh" in node else []:
            pos = doc["accessors"][prim["attributes"]["POSITION"]]
            a, b = pos["min"], pos["max"]
            for corner in [(x, y, z) for x in (a[0], b[0]) for y in (a[1], b[1]) for z in (a[2], b[2])]:
                p = [sum(m[r][k] * v for k, v in enumerate(corner + (1,))) for r in range(3)]
                for i in range(3):
                    lo[i], hi[i] = min(lo[i], p[i]), max(hi[i], p[i])
        for child in node.get("children", []):
            visit(child, m)

    for root in scene.get("nodes", []):
        visit(root, [[1 if i == j else 0 for j in range(4)] for i in range(4)])
    return lo, hi


# --- pictures: the alpha of a PNG, standard library only ------------------------------------------


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def png_alpha(data):
    """(pixels, below): the pixel count and how many have alpha below full; None when unreadable.
    Reads 8 and 16 bit grey, RGB, grey+alpha, RGBA and palette (1-8 bit, tRNS) PNGs, not interlaced."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    pos, idat, trns, head = 8, [], None, None
    while pos + 8 <= len(data):
        size, kind = struct.unpack_from(">I4s", data, pos)
        body = data[pos + 8:pos + 8 + size]
        if kind == b"IHDR":
            head = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat.append(body)
        elif kind == b"tRNS":
            trns = body
        elif kind == b"IEND":
            break
        pos += 12 + size
    if head is None:
        return None
    width, height, depth, colour, _comp, _filt, interlace = head
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(colour)
    if channels is None or interlace or depth not in (1, 2, 4, 8, 16):
        return None
    if colour in (0, 2) and trns is None:
        return width * height, 0  # no alpha channel: opaque
    if colour in (0, 2):
        return None  # a colour-key transparency: rare, left as it is
    raw = zlib.decompress(b"".join(idat))
    bpp = max(1, channels * depth // 8)
    stride = (width * channels * depth + 7) // 8
    prev = bytearray(stride)
    below, at = 0, 0
    full = 255 if depth == 8 else 65535
    for _row in range(height):
        kind, line = raw[at], bytearray(raw[at + 1:at + 1 + stride])
        at += 1 + stride
        if kind == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 255
        elif kind == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif kind == 3:
            for i in range(stride):
                line[i] = (line[i] + ((line[i - bpp] if i >= bpp else 0) + prev[i]) // 2) & 255
        elif kind == 4:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + _paeth(left, prev[i], prev[i - bpp] if i >= bpp else 0)) & 255
        elif kind != 0:
            return None
        prev = line
        if colour == 3:
            alphas = bytes(trns) + b"\xff" * 256
            per = 8 // depth if depth < 8 else 1
            for x in range(width):
                byte = line[x // per] if depth < 8 else line[x]
                index = (byte >> (8 - depth * (x % per + 1))) & ((1 << depth) - 1) if depth < 8 else byte
                below += alphas[index] < 255
        elif depth == 8:
            below += sum(1 for a in line[channels - 1::channels] if a < full)
        else:
            step = channels * 2
            below += sum(1 for i in range(step - 2, stride, step) if (line[i] << 8 | line[i + 1]) < full)
    return width * height, below


def image_bytes(doc, chunks, index, folder):
    """The bytes of image `index`: from the BIN chunk, a data: URI or a file beside the model."""
    image = doc["images"][index]
    if "bufferView" in image:
        view = doc["bufferViews"][image["bufferView"]]
        start = view.get("byteOffset", 0)
        return bin_chunk(chunks)[start:start + view["byteLength"]]
    uri = image.get("uri", "")
    if uri.startswith("data:"):
        return base64.b64decode(uri.split(",", 1)[1])
    path = os.path.join(folder, unquote(uri))
    if uri and os.path.isfile(path):
        with open(path, "rb") as f:
            return f.read()
    return None


_alpha_cache = {}


def picture_alpha(doc, chunks, texture, folder):
    """(pixels, below full alpha) of a texture's picture, or None when it can't be read."""
    source = doc.get("textures", [])[texture].get("source")
    if source is None:
        return None
    data = image_bytes(doc, chunks, source, folder)
    if data is None:
        return None
    if data[:3] == b"\xff\xd8\xff":
        return 1, 0  # a JPEG has no alpha
    key = hashlib.sha256(data).hexdigest()
    if key not in _alpha_cache:
        _alpha_cache[key] = png_alpha(data)
    return _alpha_cache[key]


def clean_materials(doc, chunks, rules, folder):
    """The material fixes driven by the list's "materials" rules. Returns log lines.

    - `unwire_emission`: an emission picture with no `emissiveFactor` (glTF: no emission) is unwired;
    - `alpha_by_picture`: a BLEND material whose alpha (base colour factor x picture) is full on every
      pixel becomes OPAQUE, and one with under `mask_share` of its pixels below full becomes MASK;
    - `keep_blend`: these material names are never changed from BLEND (glass)."""
    done = []
    used_with_alpha_colours = set()
    for mesh in doc.get("meshes", []):
        for prim in mesh.get("primitives", []):
            colour = prim.get("attributes", {}).get("COLOR_0")
            if colour is not None and doc["accessors"][colour].get("type") == "VEC4":
                used_with_alpha_colours.add(prim.get("material"))
    keep = set(rules.get("keep_blend", []))
    share = float(rules.get("mask_share", 0.05))
    cutoff = float(rules.get("alpha_cutoff", 0.5))
    for index, m in enumerate(doc.get("materials", [])):
        name = m.get("name", str(index))
        if rules.get("unwire_emission") and "emissiveTexture" in m and not any(m.get("emissiveFactor", [0, 0, 0])):
            del m["emissiveTexture"]
            m.pop("emissiveFactor", None)
            ext = m.get("extensions", {})
            ext.pop("KHR_materials_emissive_strength", None)
            if "extensions" in m and not ext:
                del m["extensions"]
            done.append("%s: emission unwired" % name)
        if not rules.get("alpha_by_picture") or m.get("alphaMode") != "BLEND":
            continue
        if name in keep:
            done.append("%s: stays BLEND (keep_blend)" % name)
            continue
        pbr = m.get("pbrMetallicRoughness", {})
        if pbr.get("baseColorFactor", [1, 1, 1, 1])[3] < 1 or index in used_with_alpha_colours:
            done.append("%s: stays BLEND (see-through colour)" % name)
            continue
        if "baseColorTexture" in pbr:
            alpha = picture_alpha(doc, chunks, pbr["baseColorTexture"]["index"], folder)
            if alpha is None:
                done.append("%s: stays BLEND (picture not read)" % name)
                continue
            pixels, below = alpha
        else:
            pixels, below = 1, 0
        if below == 0:
            m["alphaMode"] = "OPAQUE"
            m.pop("alphaCutoff", None)
            done.append("%s: OPAQUE (alpha full on all %d pixels)" % (name, pixels))
        elif below < share * pixels:
            m["alphaMode"] = "MASK"
            m["alphaCutoff"] = cutoff
            done.append("%s: MASK %g (%.2f%% below full)" % (name, cutoff, 100.0 * below / pixels))
        else:
            done.append("%s: stays BLEND (%.1f%% below full)" % (name, 100.0 * below / pixels))
    return done


# --- recolouring a material's picture: PNG pixels in and out, standard library only ---------------


def _unfilter(raw, width, height, bpp):
    """The rows of a non-interlaced 8-bit PNG's decompressed data, unfiltered, as one bytearray."""
    stride = width * bpp
    out = bytearray(stride * height)
    prev = bytearray(stride)
    at = 0
    for row in range(height):
        kind, line = raw[at], bytearray(raw[at + 1:at + 1 + stride])
        at += 1 + stride
        if kind == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 255
        elif kind == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif kind == 3:
            for i in range(stride):
                line[i] = (line[i] + ((line[i - bpp] if i >= bpp else 0) + prev[i]) // 2) & 255
        elif kind == 4:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + _paeth(left, prev[i], prev[i - bpp] if i >= bpp else 0)) & 255
        elif kind != 0:
            return None
        out[row * stride:(row + 1) * stride] = line
        prev = line
    return out


def png_rgba(data):
    """(width, height, RGBA8 pixels as a bytearray, row by row from the top) of a PNG, None when it isn't
    one this reads: 8-bit grey, RGB, grey+alpha, RGBA or palette (tRNS), not interlaced."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    pos, idat, trns, plte, head = 8, [], None, None, None
    while pos + 8 <= len(data):
        size, kind = struct.unpack_from(">I4s", data, pos)
        body = data[pos + 8:pos + 8 + size]
        if kind == b"IHDR":
            head = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat.append(body)
        elif kind == b"tRNS":
            trns = body
        elif kind == b"PLTE":
            plte = body
        elif kind == b"IEND":
            break
        pos += 12 + size
    if head is None:
        return None
    width, height, depth, colour, _comp, _filt, interlace = head
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(colour)
    if channels is None or interlace or depth != 8 or (colour in (0, 2) and trns is not None):
        return None
    pixels = _unfilter(zlib.decompress(b"".join(idat)), width, height, channels)
    if pixels is None:
        return None
    if colour == 6:
        return width, height, pixels
    out = bytearray(width * height * 4)
    if colour == 2:
        for c in range(3):
            out[c::4] = pixels[c::3]
        out[3::4] = b"\xff" * (width * height)
    elif colour == 0:
        for c in range(3):
            out[c::4] = pixels
        out[3::4] = b"\xff" * (width * height)
    elif colour == 4:
        for c in range(3):
            out[c::4] = pixels[0::2]
        out[3::4] = pixels[1::2]
    else:
        if plte is None:
            return None
        table = bytes(plte) + b"\0" * (768 - len(plte))
        alphas = (bytes(trns) if trns else b"") + b"\xff" * 256
        for c in range(3):
            out[c::4] = pixels.translate(bytes(table[i * 3 + c] for i in range(256)))
        out[3::4] = pixels.translate(alphas[:256])
    return width, height, out


def png_write(width, height, rgba):
    """A PNG of RGBA8 pixels (row by row from the top), every row filter 0 (none)."""
    stride = width * 4
    raw = bytearray()
    for row in range(height):
        raw += b"\0" + rgba[row * stride:(row + 1) * stride]

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


_COMPONENTS = {5120: "b", 5121: "B", 5122: "h", 5123: "H", 5125: "I", 5126: "f"}
_COUNTS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}


def read_accessor(doc, chunks, index):
    """An accessor's values as tuples (normalized integers as 0..1); None for one this doesn't read."""
    a = doc["accessors"][index]
    form, n = _COMPONENTS.get(a.get("componentType")), _COUNTS.get(a.get("type"))
    if form is None or n is None or "bufferView" not in a or "sparse" in a:
        return None
    view = doc["bufferViews"][a["bufferView"]]
    size = struct.calcsize("<%d%s" % (n, form))
    stride = view.get("byteStride") or size
    base = view.get("byteOffset", 0) + a.get("byteOffset", 0)
    data = bin_chunk(chunks)
    out = [struct.unpack_from("<%d%s" % (n, form), data, base + k * stride) for k in range(a["count"])]
    if a.get("normalized") and form in "BH":
        top = 255.0 if form == "B" else 65535.0
        out = [tuple(c / top for c in v) for v in out]
    return out


def to_linear(c):
    c /= 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def to_srgb(c):
    c = min(1.0, max(0.0, c))
    return 255.0 * (c * 12.92 if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055)


LUMA = (0.2126, 0.7152, 0.0722)
_LINEAR = [to_linear(v) for v in range(256)]


def used_pixels(doc, chunks, material, width, height, texcoord=0, samples=20000, seed=1):
    """{pixel index: weight}: the picture's pixels under the material's triangles, by points spread over
    their surface by area (as the measurements do: vas-look-rd's uvmean.py). {} when none are read."""
    import random
    tris, areas = [], []
    for mesh in doc.get("meshes", []):
        for prim in mesh.get("primitives", []):
            attrs = prim.get("attributes", {})
            uv_at = attrs.get("TEXCOORD_%d" % texcoord)
            if prim.get("material") != material or uv_at is None or "POSITION" not in attrs or prim.get("mode", 4) != 4:
                continue
            uv, pos = read_accessor(doc, chunks, uv_at), read_accessor(doc, chunks, attrs["POSITION"])
            if uv is None or pos is None:
                continue
            idx = [v[0] for v in read_accessor(doc, chunks, prim["indices"]) or []] if "indices" in prim else list(range(len(pos)))
            for k in range(0, len(idx) - 2, 3):
                a, b, c = pos[idx[k]], pos[idx[k + 1]], pos[idx[k + 2]]
                u = [b[i] - a[i] for i in range(3)]
                v = [c[i] - a[i] for i in range(3)]
                cross = (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])
                tris.append((uv[idx[k]], uv[idx[k + 1]], uv[idx[k + 2]]))
                areas.append(0.5 * math.sqrt(sum(x * x for x in cross)))
    if not tris or sum(areas) <= 0:
        return {}
    rng = random.Random(seed)
    weights = {}
    for a, b, c in rng.choices(tris, weights=areas, k=samples):
        r1, r2 = rng.random(), rng.random()
        if r1 + r2 > 1:
            r1, r2 = 1 - r1, 1 - r2
        u = a[0] + (b[0] - a[0]) * r1 + (c[0] - a[0]) * r2
        v = a[1] + (b[1] - a[1]) * r1 + (c[1] - a[1]) * r2
        at = (int(v % 1.0 * height) % height) * width + int(u % 1.0 * width) % width
        weights[at] = weights.get(at, 0) + 1
    return weights


def _histograms(rgba, weights):
    """Per colour channel, the weight of each of its 256 values over the used pixels."""
    hist = [[0] * 256 for _ in range(3)]
    for at, w in weights.items():
        for c in range(3):
            hist[c][rgba[at * 4 + c]] += w
    return hist


def _mean_srgb(h, k):
    total = sum(h)
    return sum(w * to_srgb(_LINEAR[v] * k) for v, w in enumerate(h) if w) / total


def _mean_linear(h, k):
    total = sum(h)
    return sum(w * min(1.0, _LINEAR[v] * k) for v, w in enumerate(h) if w) / total


def _solve(f, target):
    """The scale k (1e-4 .. 1e4) where the non-decreasing f(k) reaches target."""
    lo, hi = math.log(1e-4), math.log(1e4)
    for _ in range(60):
        mid = (lo + hi) / 2
        if f(math.exp(mid)) < target:
            lo = mid
        else:
            hi = mid
    return math.exp((lo + hi) / 2)


def recolour_scales(hist, rule):
    """The linear scale per colour channel a rule asks for: `mean` (sRGB, per channel), `brightness`
    (the mean linear luminance, one scale) or `scale` (one scale as given)."""
    if "mean" in rule:
        return [_solve(lambda k, h=hist[c]: _mean_srgb(h, k), float(rule["mean"][c])) for c in range(3)]
    if "brightness" in rule:
        k = _solve(lambda k: sum(LUMA[c] * _mean_linear(hist[c], k) for c in range(3)), float(rule["brightness"]))
        return [k, k, k]
    if "scale" in rule:
        return [float(rule["scale"])] * 3
    return None


def describe(hist, scales=(1.0, 1.0, 1.0)):
    """'srgb (r, g, b) lum l' of the used pixels after scaling."""
    srgb = [_mean_srgb(hist[c], scales[c]) for c in range(3)]
    lum = sum(LUMA[c] * _mean_linear(hist[c], scales[c]) for c in range(3))
    return "srgb (%d, %d, %d) lum %.3f" % (round(srgb[0]), round(srgb[1]), round(srgb[2]), lum)


def recolour_picture(data, doc, chunks, material, texcoord, rule):
    """(new PNG bytes, log text) for a base colour picture recoloured by `rule`, or (None, why)."""
    decoded = png_rgba(data)
    if decoded is None:
        return None, "picture not a PNG this reads"
    width, height, rgba = decoded
    weights = used_pixels(doc, chunks, material, width, height, texcoord)
    if not weights:
        return None, "no triangles of it read"
    hist = _histograms(rgba, weights)
    scales = recolour_scales(hist, rule)
    if scales is None:
        return None, "no mean, brightness or scale given"
    for c in range(3):
        table = bytes(int(round(to_srgb(_LINEAR[v] * scales[c]))) for v in range(256))
        rgba[c::4] = rgba[c::4].translate(table)
    after = _histograms(rgba, weights)
    return png_write(width, height, rgba), "%s -> %s (x%s linear)" % (
        describe(hist), describe(after), "/".join("%.3g" % s for s in scales))


def recolour_materials(doc, chunks, rules, cache, found):
    """The `"recolour"` rules: per material name, its base colour picture rewritten (`mean`, `brightness`
    or `scale`, see recolour_scales) and its `metallic`/`roughness` factors set. A picture is rewritten once
    and the result reused wherever the same picture comes again (`cache`: sha256 of the original ->
    (bytes, log)). Returns (chunks, log lines, problems); `found` collects the names met."""
    done, problems, new_images = [], [], {}
    for index, m in enumerate(doc.get("materials", [])):
        name = m.get("name", "")
        rule = rules.get(name)
        if not isinstance(rule, dict):
            continue
        found.add(name)
        pbr = m.setdefault("pbrMetallicRoughness", {})
        for key, factor in (("metallic", "metallicFactor"), ("roughness", "roughnessFactor")):
            if key in rule:
                pbr[factor] = float(rule[key])
                done.append("%s: %s %g" % (name, key, float(rule[key])))
        if not any(k in rule for k in ("mean", "brightness", "scale")):
            continue
        ref = pbr.get("baseColorTexture")
        source = doc.get("textures", [])[ref["index"]].get("source") if ref else None
        if source is None:
            problems.append("%s: no base colour picture to recolour" % name)
            continue
        image = doc["images"][source]
        if "bufferView" not in image or chunks is None:
            problems.append("%s: its picture isn't in the model's BIN, not recoloured" % name)
            continue
        others = [o.get("name", "") for i, o in enumerate(doc["materials"]) if i != index and o.get("name") != name
                  and any(r["index"] == ref["index"] or doc["textures"][r["index"]].get("source") == source for r in _texture_refs(o))]
        if others:
            problems.append("%s: its picture is shared with %s, not recoloured" % (name, ", ".join(others)))
            continue
        if source in new_images:
            continue
        data = image_bytes(doc, chunks, source, "")
        key = hashlib.sha256(data).hexdigest()
        if key not in cache:
            cache[key] = recolour_picture(data, doc, chunks, index, int(ref.get("texCoord", 0)), rule)
        new, text = cache[key]
        if new is None:
            problems.append("%s: %s" % (name, text))
            continue
        new_images[source] = new
        done.append("%s: picture %s" % (name, text))
    if new_images:
        data = bytearray(bin_chunk(chunks))
        for source, new in new_images.items():
            data += b"\0" * (-len(data) % 4)
            doc["bufferViews"].append({"buffer": 0, "byteOffset": len(data), "byteLength": len(new)})
            data += new
            doc["images"][source] = {k: v for k, v in doc["images"][source].items() if k != "uri"}
            doc["images"][source].update(bufferView=len(doc["bufferViews"]) - 1, mimeType="image/png")
        chunks = compact(doc, [(b"BIN\0", bytes(data))] + [c for c in chunks if c[0] != b"BIN\0"])
    return chunks, done, problems


# --- merging two models into one file, and compacting the BIN ------------------------------------


def bin_chunk(chunks):
    for kind, body in chunks or []:
        if kind == b"BIN\0":
            return body
    return b""


def _texture_refs(value):
    """Every {"index": n} under a key ending in "Texture" (core and extensions), for remapping."""
    found = []
    if isinstance(value, dict):
        for key, item in value.items():
            if key.lower().endswith("texture") and isinstance(item, dict) and "index" in item:
                found.append(item)
            found += _texture_refs(item)
    elif isinstance(value, list):
        for item in value:
            found += _texture_refs(item)
    return found


# Extensions that keep their own buffer view or picture source inside an "extensions" object, which merge_into and
# compact don't remap: a merged or compacted file using one would point at the wrong bytes.
UNREMAPPED_EXTENSIONS = ("KHR_draco_mesh_compression", "EXT_meshopt_compression", "EXT_texture_webp",
                         "KHR_texture_basisu")


def refuse_unremapped(doc, what):
    """Raises ValueError when doc's extensionsUsed names one of UNREMAPPED_EXTENSIONS."""
    used = [e for e in UNREMAPPED_EXTENSIONS if e in doc.get("extensionsUsed", [])]
    if used:
        raise ValueError("%s uses %s, whose own bufferView or source fix_pack can't remap; export it without "
                         "(no mesh compression, PNG or JPEG pictures) to merge or compact it" % (what, ", ".join(used)))


def merge_into(doc, chunks, part, part_chunks):
    """Appends part's scene (nodes, meshes, materials, pictures, BIN) into doc. Returns doc's new chunks."""
    refuse_unremapped(doc, "the model")
    refuse_unremapped(part, "the added part")
    for d in (doc, part):
        if len(d.get("buffers", [])) > 1 or any("uri" in b for b in d.get("buffers", [])):
            raise ValueError("merging needs single-buffer .glb files")
    base = bin_chunk(chunks)
    base += b"\0" * (-len(base) % 4)
    extra = bin_chunk(part_chunks)
    off = {k: len(doc.get(k, [])) for k in ("nodes", "meshes", "materials", "textures", "images", "samplers",
                                             "accessors", "bufferViews", "skins", "cameras")}
    part = copy.deepcopy(part)
    for v in part.get("bufferViews", []):
        v["buffer"] = 0
        v["byteOffset"] = v.get("byteOffset", 0) + len(base)
    for a in part.get("accessors", []):
        if "bufferView" in a:
            a["bufferView"] += off["bufferViews"]
        for key in ("indices", "values"):
            if key in a.get("sparse", {}):
                a["sparse"][key]["bufferView"] += off["bufferViews"]
    for i in part.get("images", []):
        if "bufferView" in i:
            i["bufferView"] += off["bufferViews"]
    for t in part.get("textures", []):
        if "source" in t:
            t["source"] += off["images"]
        if "sampler" in t:
            t["sampler"] += off["samplers"]
    for m in part.get("materials", []):
        for ref in _texture_refs(m):
            ref["index"] += off["textures"]
    for mesh in part.get("meshes", []):
        for p in mesh.get("primitives", []):
            p["attributes"] = {k: v + off["accessors"] for k, v in p["attributes"].items()}
            if "indices" in p:
                p["indices"] += off["accessors"]
            if "material" in p:
                p["material"] += off["materials"]
            p["targets"] = [{k: v + off["accessors"] for k, v in t.items()} for t in p.get("targets", [])]
            if not p["targets"]:
                del p["targets"]
    for n in part.get("nodes", []):
        for key in ("mesh", "skin", "camera"):
            if key in n:
                n[key] += off[key + ("es" if key == "mesh" else "s")]
        if "children" in n:
            n["children"] = [c + off["nodes"] for c in n["children"]]
    for s in part.get("skins", []):
        s["joints"] = [j + off["nodes"] for j in s["joints"]]
        if "skeleton" in s:
            s["skeleton"] += off["nodes"]
        if "inverseBindMatrices" in s:
            s["inverseBindMatrices"] += off["accessors"]
    for a in part.get("animations", []):
        for s in a.get("samplers", []):
            s["input"] += off["accessors"]
            s["output"] += off["accessors"]
        for c in a.get("channels", []):
            if "node" in c.get("target", {}):
                c["target"]["node"] += off["nodes"]
    for key in off:
        if part.get(key):
            doc.setdefault(key, []).extend(part[key])
    if part.get("animations"):
        doc.setdefault("animations", []).extend(part["animations"])
    roots = [i + off["nodes"] for i in part["scenes"][part.get("scene", 0)].get("nodes", [])]
    for scene in doc.get("scenes", []):
        scene["nodes"] = scene.get("nodes", []) + roots
    for key in ("extensionsUsed", "extensionsRequired"):
        names = list(dict.fromkeys(doc.get(key, []) + part.get(key, [])))
        if names:
            doc[key] = names
    data = base + extra
    doc["buffers"] = [{"byteLength": len(data)}]
    return [(b"BIN\0", data)] + [c for c in chunks or [] if c[0] != b"BIN\0"]


def compact(doc, chunks):
    """Drops pictures and buffer views nothing uses any more, shares identical pictures, textures and
    materials, and rebuilds the BIN from what is left. Returns the new chunks."""
    refuse_unremapped(doc, "the model")
    data = bin_chunk(chunks)

    def view_bytes(i):
        v = doc["bufferViews"][i]
        return data[v.get("byteOffset", 0):v.get("byteOffset", 0) + v["byteLength"]]

    def dedupe(items, key):
        """(kept items, old index -> new index) keeping the first of each equal key."""
        seen, kept, remap = {}, [], {}
        for i, item in enumerate(items):
            k = key(i, item)
            if k not in seen:
                seen[k] = len(kept)
                kept.append(item)
            remap[i] = seen[k]
        return kept, remap

    # Materials first, then what they use; anything unused falls out.
    used_tex = sorted({r["index"] for m in doc.get("materials", []) for r in _texture_refs(m)})
    images = doc.get("images", [])
    img_key = {}
    for i, image in enumerate(images):
        body = view_bytes(image["bufferView"]) if "bufferView" in image else image.get("uri", "").encode()
        img_key[i] = (image.get("mimeType"), hashlib.sha256(body).hexdigest())
    textures = doc.get("textures", [])
    tex_key = {i: (json.dumps(doc.get("samplers", [])[t["sampler"]], sort_keys=True) if "sampler" in t else None,
                   img_key.get(t.get("source")), json.dumps(t.get("extensions"), sort_keys=True)) for i, t in enumerate(textures)}
    canon_tex, new_textures = {}, []
    for i in used_tex:
        k = tex_key[i]
        if k not in canon_tex:
            canon_tex[k] = len(new_textures)
            new_textures.append(copy.deepcopy(textures[i]))
    for m in doc.get("materials", []):
        for r in _texture_refs(m):
            r["index"] = canon_tex[tex_key[r["index"]]]
    # Pictures and samplers the kept textures use.
    new_images, image_index, new_samplers, sampler_index = [], {}, [], {}
    for t in new_textures:
        if "source" in t:
            k = img_key[t["source"]]
            if k not in image_index:
                image_index[k] = len(new_images)
                new_images.append(images[t["source"]])
            t["source"] = image_index[k]
        if "sampler" in t:
            k = json.dumps(doc["samplers"][t["sampler"]], sort_keys=True)
            if k not in sampler_index:
                sampler_index[k] = len(new_samplers)
                new_samplers.append(doc["samplers"][t["sampler"]])
            t["sampler"] = sampler_index[k]
    materials, mat_remap = dedupe(doc.get("materials", []), lambda i, m: json.dumps(m, sort_keys=True))
    for mesh in doc.get("meshes", []):
        for p in mesh.get("primitives", []):
            if "material" in p:
                p["material"] = mat_remap[p["material"]]
    for key, value in (("textures", new_textures), ("images", new_images), ("samplers", new_samplers),
                       ("materials", materials)):
        if value:
            doc[key] = value
        else:
            doc.pop(key, None)
    # Buffer views: those the accessors and kept pictures use, in their old order, 4-aligned.
    used_views = set()
    for a in doc.get("accessors", []):
        if "bufferView" in a:
            used_views.add(a["bufferView"])
        for key in ("indices", "values"):
            if key in a.get("sparse", {}):
                used_views.add(a["sparse"][key]["bufferView"])
    used_views.update(i["bufferView"] for i in doc.get("images", []) if "bufferView" in i)
    out, views, view_remap = bytearray(), [], {}
    for i in sorted(used_views):
        out += b"\0" * (-len(out) % 4)
        v = dict(doc["bufferViews"][i], byteOffset=len(out), buffer=0)
        out += view_bytes(i)
        view_remap[i] = len(views)
        views.append(v)
    for a in doc.get("accessors", []):
        if "bufferView" in a:
            a["bufferView"] = view_remap[a["bufferView"]]
        for key in ("indices", "values"):
            if key in a.get("sparse", {}):
                a["sparse"][key]["bufferView"] = view_remap[a["sparse"][key]["bufferView"]]
    for image in doc.get("images", []):
        if "bufferView" in image:
            image["bufferView"] = view_remap[image["bufferView"]]
    doc["bufferViews"] = views
    out += b"\0" * (-len(out) % 4)
    doc["buffers"] = [{"byteLength": len(out)}]
    return [(b"BIN\0", bytes(out))] + [c for c in chunks or [] if c[0] != b"BIN\0"]


def add_inside(doc, chunks):
    """Gives every triangle of every mesh a back face: a copy wound the other way round, its normals (and
    tangents) turned over, the rest of each vertex (UVs, colours) the same. Blender draws a face from both
    sides unless its material's Backface Culling is on, and glTF says so with doubleSided; Zenith draws one
    side only, so a single-sided shell with an open end (a pipe's tube) is see-through from inside.
    Returns (new chunks, triangles added). Only indexed or plain triangle lists of float or normalized
    attributes; morph targets, skins and anything else are refused (ValueError)."""
    refuse_unremapped(doc, "the model")
    if len(doc.get("buffers", [])) > 1 or any("uri" in b for b in doc.get("buffers", [])):
        raise ValueError("adding an inside needs a single-buffer .glb file")
    data = bytearray(bin_chunk(chunks))
    views = doc.setdefault("bufferViews", [])

    def put(values, n, form, target):
        data.extend(b"\0" * (-len(data) % 4))
        body = b"".join(struct.pack("<%d%s" % (n, form), *v) for v in values)
        views.append({"buffer": 0, "byteOffset": len(data), "byteLength": len(body), "target": target})
        data.extend(body)
        return len(views) - 1

    doubled, added = {}, 0  # accessor -> its doubled accessor; shared ones are doubled once
    for mesh in doc.get("meshes", []):
        for p in mesh.get("primitives", []):
            if p.get("mode", 4) != 4 or p.get("targets"):
                raise ValueError("adding an inside needs plain triangles without morph targets")
            attrs = p["attributes"]
            if any(k.startswith(("JOINTS_", "WEIGHTS_")) for k in attrs):
                raise ValueError("adding an inside doesn't do skinned meshes")
            count = doc["accessors"][attrs["POSITION"]]["count"]
            for key, index in sorted(attrs.items()):
                if (index, count) in doubled:
                    attrs[key] = doubled[(index, count)]
                    continue
                values = read_accessor(doc, chunks, index)
                a = doc["accessors"][index]
                if values is None or len(values) != count:
                    raise ValueError("adding an inside: attribute %s can't be read" % key)
                if key == "NORMAL":
                    back = [tuple(-c for c in v) for v in values]
                elif key == "TANGENT":
                    back = [(-v[0], -v[1], -v[2], v[3]) for v in values]
                else:
                    back = values
                n = _COUNTS[a["type"]]
                acc = {"bufferView": put(values + back, n, "f", 34962), "componentType": 5126,
                       "count": 2 * count, "type": a["type"]}
                for bound in ("min", "max"):
                    if bound in a and not a.get("normalized"):
                        acc[bound] = a[bound]
                doc["accessors"].append(acc)
                doubled[(index, count)] = attrs[key] = len(doc["accessors"]) - 1
            if "indices" in p:
                idx = [v[0] for v in read_accessor(doc, chunks, p["indices"])]
            else:
                idx = list(range(count))
            tris = len(idx) // 3
            back = []
            for t in range(tris):
                a, b, c = idx[3 * t:3 * t + 3]
                back += [a + count, c + count, b + count]
            every = idx[:3 * tris] + back
            form, ctype = ("I", 5125) if 2 * count > 65535 else ("H", 5123)
            doc["accessors"].append({"bufferView": put([(i,) for i in every], 1, form, 34963), "componentType": ctype,
                                     "count": len(every), "type": "SCALAR"})
            p["indices"] = len(doc["accessors"]) - 1
            added += tris
    # The old accessors nothing uses any more fall out with their bytes (compact keeps the views accessors use).
    used = {i for m in doc.get("meshes", []) for p in m["primitives"] for i in list(p["attributes"].values()) + [p.get("indices")]}
    for s in doc.get("skins", []):
        used.add(s.get("inverseBindMatrices"))
    for an in doc.get("animations", []):
        for s in an.get("samplers", []):
            used.update((s["input"], s["output"]))
    remap, kept = {}, []
    for i, a in enumerate(doc["accessors"]):
        if i in used:
            remap[i] = len(kept)
            kept.append(a)
    doc["accessors"] = kept
    for m in doc.get("meshes", []):
        for p in m["primitives"]:
            p["attributes"] = {k: remap[v] for k, v in p["attributes"].items()}
            p["indices"] = remap[p["indices"]]
    for s in doc.get("skins", []):
        if "inverseBindMatrices" in s:
            s["inverseBindMatrices"] = remap[s["inverseBindMatrices"]]
    for an in doc.get("animations", []):
        for s in an.get("samplers", []):
            s["input"], s["output"] = remap[s["input"]], remap[s["output"]]
    doc["buffers"] = [{"byteLength": len(data)}]
    new = [(b"BIN\0", bytes(data))] + [c for c in chunks or [] if c[0] != b"BIN\0"]
    return compact(doc, new), added


def mask_materials(doc, names, cutoff):
    """Sets the named materials (or all, "*") to Alpha Clip. Returns the names not found."""
    mats = doc.get("materials", [])
    found = set()
    for m in mats:
        name = m.get("name", "")
        if "*" in names or name in names:
            m["alphaMode"] = "MASK"
            m["alphaCutoff"] = cutoff
            found.add(name)
    return [n for n in names if n != "*" and n not in found]


# --- the pack ---------------------------------------------------------------------------------


def load_fixes(path):
    with open(path, encoding="utf-8") as f:
        fixes = json.load(f)
    if not isinstance(fixes.get("files"), dict):
        raise ValueError("%s: no \"files\" object" % path)
    return fixes


def model_name(rel):
    base, ext = os.path.splitext(rel.replace(os.sep, "/"))
    return base if ext.lower() in MODEL_EXTS else None


def fix_pack(src, dst, fixes, log=print):
    """Writes the fixed copy of src into dst. Returns (files written, problems)."""
    src, dst = os.path.abspath(src), os.path.abspath(dst)
    if not os.path.isdir(src):
        raise ValueError("no source folder %s" % src)
    s, d = os.path.normcase(src), os.path.normcase(dst)
    if d == s or d.startswith(s + os.sep) or s.startswith(d + os.sep):
        raise ValueError("the output folder must be outside the source folder (and not hold it)")
    entries = fixes["files"]
    cutoff = float(fixes.get("alpha_cutoff", 0.5))
    rules = dict(fixes.get("materials", {}), alpha_cutoff=cutoff)
    recolour = {k: v for k, v in fixes.get("recolour", {}).items() if isinstance(v, dict)}
    recoloured, recolour_found = {}, set()
    written, problems, seen = {}, [], set()
    sources = {}

    def source(name):
        """(doc, chunks, offset) of a top-level source model, its entry's move worked out."""
        if name not in sources:
            path = next((os.path.join(src, name + e) for e in MODEL_EXTS if os.path.isfile(os.path.join(src, name + e))), None)
            if path is None:
                raise ValueError("%s: no such model in the source to add" % name)
            doc, chunks = read_model(path)
            entry = entries.get(name, {})
            offset = [float(c) for c in entry.get("offset", [0, 0, 0])]
            if entry.get("centre"):
                lo, hi = box(doc)
                offset = [offset[0] - (lo[0] + hi[0]) / 2, offset[1], offset[2] - (lo[2] + hi[2]) / 2]
            sources[name] = (doc, chunks, offset)
        return sources[name]

    def claim(rel, what):
        key = rel.replace(os.sep, "/").lower()
        if key in written:
            problems.append("%s written twice (%s and %s)" % (rel, written[key], what))
        written[key] = what

    for folder, dirs, files in os.walk(src):
        dirs.sort()
        for f in sorted(files):
            path = os.path.join(folder, f)
            rel = os.path.relpath(path, src)
            name = model_name(rel)
            entry = entries.get(name) if name is not None else None
            ext = os.path.splitext(f)[1]
            if entry is None and name is not None and (rules or recolour):
                entry = {}  # not listed, but the material rules cover every model
            if entry is None:
                out = os.path.join(dst, rel)
                os.makedirs(os.path.dirname(out), exist_ok=True)
                shutil.copy2(path, out)
                claim(rel, rel)
                continue
            seen.add(name)
            doc, chunks = read_model(path)
            if os.path.dirname(rel) == "":
                _doc, _chunks, offset = source(name)
            else:
                offset = [float(c) for c in entry.get("offset", [0, 0, 0])]
            for out in entry.get("out", [{"name": name}]):
                piece, piece_chunks = copy.deepcopy(doc), chunks
                turn = float(out.get("turn", 0))
                done, adds = [], []
                if entry.get("keep_rest_turn"):
                    if piece_chunks is None:
                        problems.append("%s: keep_rest_turn needs a .glb" % name)
                    else:
                        piece_chunks, kept, trouble = keep_rest_turn(piece, piece_chunks, entry["keep_rest_turn"])
                        adds += kept
                        problems += ["%s: %s" % (out["name"], t) for t in trouble]
                how = transform_roots(piece, turn, offset, os.path.basename(out["name"]))
                for part in out.get("add", []):
                    try:
                        pdoc, pchunks, poffset = source(part["model"])
                    except ValueError as e:
                        problems.append("%s: %s" % (out["name"], e))
                        continue
                    pdoc = copy.deepcopy(pdoc)
                    transform_roots(pdoc, float(part.get("turn", 0)), poffset, part["model"])
                    inside = ""
                    try:
                        if part.get("inside"):
                            pchunks, added = add_inside(pdoc, pchunks)
                            inside = " with an inside (%d back faces)" % added
                        piece_chunks = merge_into(piece, piece_chunks, pdoc, pchunks)
                    except ValueError as e:
                        raise ValueError("%s + %s: %s" % (rel, part["model"], e)) from e
                    adds.append("+ %s%s%s" % (part["model"], " turned %g" % part["turn"] if part.get("turn") else "", inside))
                if entry.get("inside"):
                    try:
                        piece_chunks, added = add_inside(piece, piece_chunks)
                    except ValueError as e:
                        raise ValueError("%s: %s" % (rel, e)) from e
                    adds.append("inside added (%d back faces)" % added)
                missing = mask_materials(piece, entry.get("mask", []), cutoff)
                if missing:
                    problems.append("%s: no material %s to mask" % (name, ", ".join(missing)))
                cleaned = clean_materials(piece, piece_chunks, rules, folder) if rules else []
                if piece_chunks is not None and (out.get("add") or any("emission" in c for c in cleaned)):
                    try:
                        piece_chunks = compact(piece, piece_chunks)
                    except ValueError as e:
                        raise ValueError("%s: %s" % (rel, e)) from e
                if "metal" in entry:
                    for m in piece.get("materials", []):
                        m.setdefault("pbrMetallicRoughness", {})["metallicFactor"] = float(entry["metal"])
                    cleaned.append("metal %g" % float(entry["metal"]))
                if recolour:
                    piece_chunks, coloured, trouble = recolour_materials(piece, piece_chunks, recolour, recoloured, recolour_found)
                    cleaned += coloured
                    problems += ["%s: %s" % (out["name"], t) for t in trouble]
                changed = piece != doc or piece_chunks is not chunks
                rel_out = os.path.join(os.path.dirname(rel), out["name"].replace("/", os.sep) + ext)
                if changed:
                    write_model(os.path.join(dst, rel_out), piece, piece_chunks)
                else:
                    os.makedirs(os.path.dirname(os.path.join(dst, rel_out)), exist_ok=True)
                    shutil.copy2(path, os.path.join(dst, rel_out))
                claim(rel_out, rel)
                if out["name"] != name:
                    done.append("from " + name)
                if any(offset):
                    done.append("moved %s" % [round(c, 4) for c in offset])
                if turn:
                    done.append("turned %g" % turn)
                if how == "new root":
                    done.append("(new root)")
                done += adds
                if entry.get("mask"):
                    done.append("mask " + ", ".join(entry["mask"]))
                done += ["[%s]" % c for c in dict.fromkeys(cleaned)]
                log("%-36s %s" % (rel_out.replace(os.sep, "/"), " ".join(done) or "copied"))
    pack_keys = {k: v for k, v in (fixes.get("pack_json") or {}).items() if k != "note"}
    if pack_keys:
        info_path = os.path.join(dst, "pack.json")
        info = {}
        if os.path.isfile(info_path) and "pack.json" in written:
            try:
                with open(info_path, encoding="utf-8") as f:
                    info = json.load(f)
            except ValueError as e:
                problems.append("pack.json: the source's can't be read (%s); written with the list's keys only" % e)
            if not isinstance(info, dict):
                info = {}
        info.update(pack_keys)
        os.makedirs(dst, exist_ok=True)
        with open(info_path, "w", encoding="utf-8", newline="\n") as f:
            json.dump(info, f, indent="\t", ensure_ascii=False)
            f.write("\n")
        if "pack.json" not in written:
            claim("pack.json", "pack_json")
        log("%-36s %s" % ("pack.json", "with " + ", ".join("%s=%s" % (k, json.dumps(v)) for k, v in pack_keys.items())))
    for name in entries:
        if name not in seen:
            problems.append("%s: listed but not in the source" % name)
    for name in recolour:
        if name not in recolour_found:
            problems.append("recolour: no material %s in any model" % name)
    return len(written), problems


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("source", help="the modeller's export (left untouched)")
    parser.add_argument("output", help="where the fixed copy goes (outside the source)")
    parser.add_argument("--fixes", default=DEFAULT_FIXES, help="the JSON list of fixes")
    args = parser.parse_args(argv)
    count, problems = fix_pack(args.source, args.output, load_fixes(args.fixes))
    for p in problems:
        print("WARN " + p)
    print("%d files written to %s, %d warnings" % (count, args.output, len(problems)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
