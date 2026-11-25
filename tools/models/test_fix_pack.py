"""Tests tools/models/fix_pack.py on tiny fixture .glb files made in a temp folder: a rename, an item moved
into items/, a re-centre, a turn (by where the mesh reaches), Alpha Clip, the mesh data kept byte for byte,
an animated root given a new root, unlisted files copied, the source left untouched, an output inside the
source refused; and the real list (fixes/vasillo.json) names only Zenith's pipe shapes and recolours nothing. The material rules
(emission unwired with no factor; BLEND to OPAQUE or MASK by the picture's alpha, glass kept), the PNG reader,
a pipe ending merged from two models, ores centred and renamed; the recolour rule (a picture to a target
mean over the pixels the mesh uses, alpha kept, metallic set, a shared picture once, the PNG round trip); the rotation keys of rollers put after their rest turn (keep_rest_turn); and check.py's drill allowance, items and names.

    python3 tools/models/test_fix_pack.py [--source <modeller's export> --fixed <its fixed copy>]

"inside" (a back face for every triangle) on a fixture, and with --source and --fixed the real pack's pipe
files: each one's triangles its sources' (doubled with an inside) and its base colour pictures its source's,
pipe-to-ground's from both sides.
"""

import hashlib
import json
import math
import os
import re
import struct
import sys
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import check  # noqa: E402
import fix_pack  # noqa: E402

failures = []


def expect(ok, what):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


def close(a, b, eps=1e-5):
    return all(abs(x - y) < eps for x, y in zip(a, b))


def make_glb(path, root_translation, lo, hi, animated=False):
    """One quad from lo to hi (x, y, z) under a root node at root_translation, two BLEND materials."""
    (x0, y0, z0), (x1, y1, z1) = lo, hi
    verts = [(x0, y0, z0), (x1, y0, z0), (x1, y1, z1), (x0, y1, z1)]
    pos = b"".join(struct.pack("<3f", *v) for v in verts)
    idx = struct.pack("<6H", 0, 1, 2, 0, 2, 3) + b"\0\0"
    times = struct.pack("<2f", 0, 1)
    moves = struct.pack("<6f", *root_translation, *root_translation)
    binary = pos + idx + times + moves
    doc = {
        "asset": {"version": "2.0"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"name": "Root", "translation": list(root_translation), "children": [1]},
                  {"name": "Part", "mesh": 0}],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1, "material": 0}]}],
        "materials": [{"name": "Surface", "alphaMode": "BLEND"}, {"name": "Other", "alphaMode": "BLEND"}],
        "buffers": [{"byteLength": len(binary)}],
        "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 48},
                        {"buffer": 0, "byteOffset": 48, "byteLength": 12},
                        {"buffer": 0, "byteOffset": 60, "byteLength": 8},
                        {"buffer": 0, "byteOffset": 68, "byteLength": 24}],
        "accessors": [{"bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3",
                       "min": [min(x0, x1), min(y0, y1), min(z0, z1)], "max": [max(x0, x1), max(y0, y1), max(z0, z1)]},
                      {"bufferView": 1, "componentType": 5123, "count": 6, "type": "SCALAR"},
                      {"bufferView": 2, "componentType": 5126, "count": 2, "type": "SCALAR", "min": [0], "max": [1]},
                      {"bufferView": 3, "componentType": 5126, "count": 2, "type": "VEC3"}],
    }
    if animated:
        doc["animations"] = [{"samplers": [{"input": 2, "output": 3}],
                              "channels": [{"sampler": 0, "target": {"node": 0, "path": "translation"}}]}]
    fix_pack.write_model(path, doc, [(b"BIN\0", binary)])


def bounds(path):
    lo, hi, _tris, _rot = check.measure(check.read_glb(path))
    return lo, hi


# --- pictures and materials ---------------------------------------------------------------------


def paeth(a, b, c):
    """The PNG spec's predictor, written out here so the reader isn't tested against itself."""
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else (b if pb <= pc else c)


def png(width, height, alpha, colour=6, filters=(0, 1, 2, 3, 4)):
    """An 8-bit PNG whose pixel (x, y) has alpha alpha(x, y), each row with the next filter in turn."""
    channels = {6: 4, 4: 2}[colour]
    rows = []
    for y in range(height):
        row = bytearray()
        for x in range(width):
            grey = (x * 37 + y * 11) & 255
            row += bytes([grey] * (channels - 1) + [alpha(x, y)])
        rows.append(row)
    raw, prev, bpp = bytearray(), bytearray(width * channels), channels
    for y, row in enumerate(rows):
        kind = filters[y % len(filters)]
        out = bytearray()
        for i, v in enumerate(row):
            left = row[i - bpp] if i >= bpp else 0
            up, corner = prev[i], (prev[i - bpp] if i >= bpp else 0)
            pred = (0, left, up, (left + up) // 2, paeth(left, up, corner))[kind]
            out.append((v - pred) & 255)
        raw += bytes([kind]) + out
        prev = row

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xffffffff)
    head = struct.pack(">IIBBBBB", width, height, 8, colour, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", head) + chunk(b"IDAT", zlib.compress(bytes(raw))) + chunk(b"IEND", b"")


def make_textured_glb(path, root_translation, lo, hi, materials):
    """One quad per material, side by side; materials: [(name, alpha picture bytes or None, emissive dict)]."""
    binary, views, accessors, meshes, nodes, mats, images, textures = bytearray(), [], [], [], [], [], [], []

    def add(data):
        binary.extend(b"\0" * (-len(binary) % 4))
        views.append({"buffer": 0, "byteOffset": len(binary), "byteLength": len(data)})
        binary.extend(data)
        return len(views) - 1

    (x0, y0, z0), (x1, y1, z1) = lo, hi
    for i, (name, picture, extra) in enumerate(materials):
        verts = [(x0, y0, z0), (x1, y0, z0), (x1, y1, z1), (x0, y1, z1)]
        accessors.append({"bufferView": add(b"".join(struct.pack("<3f", *v) for v in verts)), "componentType": 5126,
                          "count": 4, "type": "VEC3", "min": [min(x0, x1), min(y0, y1), min(z0, z1)],
                          "max": [max(x0, x1), max(y0, y1), max(z0, z1)]})
        accessors.append({"bufferView": add(struct.pack("<6H", 0, 1, 2, 0, 2, 3)), "componentType": 5123,
                          "count": 6, "type": "SCALAR"})
        meshes.append({"primitives": [{"attributes": {"POSITION": 2 * i}, "indices": 2 * i + 1, "material": i}]})
        nodes.append({"name": "Part%d" % i, "mesh": i})
        mat = {"name": name, "alphaMode": "BLEND", "pbrMetallicRoughness": {}}
        if picture is not None:
            images.append({"bufferView": add(picture), "mimeType": "image/png"})
            textures.append({"source": len(images) - 1, "sampler": 0})
            mat["pbrMetallicRoughness"]["baseColorTexture"] = {"index": len(textures) - 1}
        for key, value in extra.items():
            if key == "emissiveTexture":
                images.append({"bufferView": add(value), "mimeType": "image/png", "name": name + "_Emission"})
                textures.append({"source": len(images) - 1, "sampler": 0})
                mat["emissiveTexture"] = {"index": len(textures) - 1}
            else:
                mat[key] = value
        mats.append(mat)
    binary.extend(b"\0" * (-len(binary) % 4))
    doc = {"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [len(nodes)]}],
           "nodes": nodes + [{"name": "Root", "translation": list(root_translation), "children": list(range(len(nodes)))}],
           "meshes": meshes, "materials": mats, "accessors": accessors, "bufferViews": views,
           "buffers": [{"byteLength": len(binary)}], "samplers": [{"magFilter": 9729}]}
    if images:
        doc["images"], doc["textures"] = images, textures
    fix_pack.write_model(path, doc, [(b"BIN\0", bytes(binary))])


def rgba_png(width, height, pixel):
    """An RGBA8 PNG, filters 0-4 in turn, pixel(x, y) -> (r, g, b, a); and the pixels as bytes."""
    flat = bytearray()
    for y in range(height):
        for x in range(width):
            flat += bytes(pixel(x, y))
    raw, prev, stride = bytearray(), bytearray(width * 4), width * 4
    for y in range(height):
        row, kind, out = flat[y * stride:(y + 1) * stride], y % 5, bytearray()
        for i, v in enumerate(row):
            left = row[i - 4] if i >= 4 else 0
            up, corner = prev[i], (prev[i - 4] if i >= 4 else 0)
            pred = (0, left, up, (left + up) // 2, paeth(left, up, corner))[kind]
            out.append((v - pred) & 255)
        raw += bytes([kind]) + out
        prev = row

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xffffffff)
    head = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", head) + chunk(b"IDAT", zlib.compress(bytes(raw))) + chunk(b"IEND", b"")
    return data, bytes(flat)


def make_uv_glb(path, picture, u0, u1, name="Rock", metallic=1.0):
    """A quad (1 x 1) whose UVs cover u0..u1 of the picture across and all of it down, one material."""
    binary, views = bytearray(), []

    def add(data):
        binary.extend(b"\0" * (-len(binary) % 4))
        views.append({"buffer": 0, "byteOffset": len(binary), "byteLength": len(data)})
        binary.extend(data)
        return len(views) - 1
    pos = add(b"".join(struct.pack("<3f", *v) for v in [(0, 0, 0), (1, 0, 0), (1, 0, 1), (0, 0, 1)]))
    uv = add(b"".join(struct.pack("<2f", *v) for v in [(u0, 0), (u1, 0), (u1, 1), (u0, 1)]))
    idx = add(struct.pack("<6H", 0, 1, 2, 0, 2, 3))
    img = add(picture)
    binary.extend(b"\0" * (-len(binary) % 4))
    doc = {"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"name": "R", "mesh": 0}],
           "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "TEXCOORD_0": 1}, "indices": 2, "material": 0}]}],
           "materials": [{"name": name, "pbrMetallicRoughness": {"baseColorTexture": {"index": 0}, "metallicFactor": metallic}}],
           "textures": [{"source": 0, "sampler": 0}], "samplers": [{}], "images": [{"bufferView": img, "mimeType": "image/png"}],
           "accessors": [{"bufferView": pos, "componentType": 5126, "count": 4, "type": "VEC3", "min": [0, 0, 0], "max": [1, 0, 1]},
                         {"bufferView": uv, "componentType": 5126, "count": 4, "type": "VEC2"},
                         {"bufferView": idx, "componentType": 5123, "count": 6, "type": "SCALAR"}],
           "bufferViews": views, "buffers": [{"byteLength": len(binary)}]}
    fix_pack.write_model(path, doc, [(b"BIN\0", bytes(binary))])


def picture_of(path, material):
    doc, chunks = fix_pack.read_model(path)
    m = next(m for m in doc["materials"] if m["name"] == material)
    source = doc["textures"][m["pbrMetallicRoughness"]["baseColorTexture"]["index"]]["source"]
    return doc, m, fix_pack.image_bytes(doc, chunks, source, "")


def recolour_tests():
    # The PNG reader and writer: every filter read; written (filter 0) and read back the same.
    data, flat = rgba_png(11, 6, lambda x, y: ((x * 23) & 255, (y * 41) & 255, (x * y * 7) & 255, (100 + x * 13) & 255))
    w, h, px = fix_pack.png_rgba(data)
    expect((w, h, bytes(px)) == (11, 6, flat), "PNG pixels: RGBA read through all 5 filters")
    again = fix_pack.png_write(11, 6, px)
    expect(fix_pack.png_rgba(again)[2] == flat and fix_pack.png_alpha(again) == (66, 66),
           "PNG round trip: written as RGBA8 filter 0, read back the same")
    grey = fix_pack.png_rgba(png(5, 4, lambda x, y: 200, colour=4))
    expect(grey is not None and bytes(grey[2][0:4]) == bytes([0, 0, 0, 200]), "grey+alpha read as RGBA")
    with tempfile.TemporaryDirectory() as tmp:
        src, dst = os.path.join(tmp, "src"), os.path.join(tmp, "dst")
        os.makedirs(src)
        # 16 x 8: the left half (the part the rock uses) mid colours with varied alpha, the right half white.
        left = lambda x, y: (40 + x * 9 + y * 3, 60 + y * 7, 20 + x * 5, 90 + x * 20 + y)
        data, _flat = rgba_png(16, 8, lambda x, y: left(x, y) if x < 8 else (255, 255, 255, 255))
        make_uv_glb(os.path.join(src, "rock-a.glb"), data, 0.0, 0.5, "Rock")
        make_uv_glb(os.path.join(src, "rock-b.glb"), data, 0.5, 1.0, "Rock")  # the same picture, its white half
        make_uv_glb(os.path.join(src, "pipe.glb"), rgba_png(8, 8, lambda x, y: (30 + x, 25 + y, 20, 255))[0], 0, 1, "Pipe")
        made = []
        real = fix_pack.recolour_picture

        def counted(*args):
            made.append(args[3])
            return real(*args)
        fix_pack.recolour_picture = counted
        try:
            fixes = {"files": {}, "recolour": {"note": "text",
                                               "Rock": {"mean": [100, 150, 60], "metallic": 0, "roughness": 0.9},
                                               "Pipe": {"brightness": 0.2}, "Gone": {"scale": 2}}}
            lines = []
            _count, problems = fix_pack.fix_pack(src, dst, fixes, log=lines.append)
        finally:
            fix_pack.recolour_picture = real
        expect(problems == ["recolour: no material Gone in any model"], "only the missing material warned (%s)" % problems)
        doc, m, new = picture_of(os.path.join(dst, "rock-a.glb"), "Rock")
        _w, _h, out = fix_pack.png_rgba(new)
        used = [(x, y) for y in range(8) for x in range(8)]
        mean = [sum(out[(y * 16 + x) * 4 + c] for x, y in used) / len(used) for c in range(3)]
        expect(all(abs(mean[c] - [100, 150, 60][c]) < 2.5 for c in range(3)),
               "the picture's mean over the pixels the mesh uses hits the target (%s)" % [round(v, 1) for v in mean])
        expect(all(out[(y * 16 + x) * 4 + 3] == left(x, y)[3] for x, y in used)
               and all(out[(y * 16 + x) * 4 + 3] == 255 for y in range(8) for x in range(8, 16)), "alpha kept on every pixel")
        expect(all(out[(y * 16 + 12) * 4 + c] == 255 for y in range(8) for c in range(3)), "white stays white (clamped to 1)")
        pbr = m["pbrMetallicRoughness"]
        expect(pbr.get("metallicFactor") == 0 and pbr.get("roughnessFactor") == 0.9, "metallic and roughness set")
        expect(len(doc["images"]) == 1 and doc["images"][0]["mimeType"] == "image/png"
               and len(doc["bufferViews"]) == 4, "the old picture dropped from the BIN, the new one in")
        _doc, _m, new_b = picture_of(os.path.join(dst, "rock-b.glb"), "Rock")
        expect(new_b == new and made.count(0) == 2 and len(made) == 2,
               "a picture shared by two files worked out once (on the first) and written to both (%d made)" % len(made))
        _doc, _m, pipe = picture_of(os.path.join(dst, "pipe.glb"), "Pipe")
        _w, _h, out = fix_pack.png_rgba(pipe)
        lum = sum(fix_pack.LUMA[c] * sum(fix_pack.to_linear(out[i * 4 + c]) for i in range(64)) / 64 for c in range(3))
        expect(abs(lum - 0.2) < 0.01, "brightness: one scale to a mean linear luminance of 0.2 (%.3f)" % lum)
        expect(any("Rock: picture srgb" in line for line in lines), "the log says what was recoloured")

def metal_tests():
    # A per-file "metal": the written copy's metallicFactor set, his picture untouched, other files left alone.
    with tempfile.TemporaryDirectory() as tmp:
        src, dst = os.path.join(tmp, "src"), os.path.join(tmp, "dst")
        os.makedirs(src)
        data = rgba_png(8, 8, lambda x, y: (90, 80, 70, 255))[0]
        make_uv_glb(os.path.join(src, "coal-1.glb"), data, 0, 1, "Coal")
        make_uv_glb(os.path.join(src, "pipe.glb"), data, 0, 1, "Pipe")
        fixes = {"files": {"coal-1": {"metal": 0, "out": [{"name": "coal-1"}, {"name": "items/coal-1"}]}}}
        _count, problems = fix_pack.fix_pack(src, dst, fixes, log=lambda _l: None)
        expect(problems == [], "metal: no warnings (%s)" % problems)
        for rel in ("coal-1.glb", os.path.join("items", "coal-1.glb")):
            doc, _m, new = picture_of(os.path.join(dst, rel), "Coal")
            m = doc["materials"][0]["pbrMetallicRoughness"]
            expect(m.get("metallicFactor") == 0 and new == data, "metal 0 in %s, his picture untouched" % rel)
        doc, _m, _p = picture_of(os.path.join(dst, "pipe.glb"), "Pipe")
        expect(doc["materials"][0]["pbrMetallicRoughness"].get("metallicFactor") == 1.0, "an unlisted file keeps its factor")


def materials_tests():
    # The PNG reader, against pictures with every filter and with a palette.
    expect(fix_pack.png_alpha(png(9, 7, lambda x, y: 255)) == (63, 0), "PNG: opaque RGBA read through all 5 filters")
    expect(fix_pack.png_alpha(png(9, 7, lambda x, y: 100 if (x, y) in ((3, 2), (8, 6)) else 255)) == (63, 2),
           "PNG: 2 pixels below full found through the filters")
    expect(fix_pack.png_alpha(png(5, 4, lambda x, y: 255 - x, colour=4)) == (20, 16), "PNG: grey + alpha")

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xffffffff)
    pal = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 4, 2, 2, 3, 0, 0, 0))
           + chunk(b"PLTE", b"\0" * 12) + chunk(b"tRNS", b"\xff\x80")
           + chunk(b"IDAT", zlib.compress(b"\0\x05\0\x00")) + chunk(b"IEND", b""))  # 2-bit indices 0,0,1,1 / 0,0,0,0
    expect(fix_pack.png_alpha(pal) == (8, 2), "PNG: 2-bit palette with tRNS (%s)" % (fix_pack.png_alpha(pal),))

    black = png(4, 4, lambda x, y: 255)
    opaque = png(64, 64, lambda x, y: 255)
    speckled = png(64, 64, lambda x, y: 20 if x < 3 and y < 20 else 255)    # 60 of 4096: 1.5%
    glass = png(64, 64, lambda x, y: 152)                                     # 0.596 everywhere
    patchy = png(64, 64, lambda x, y: 0 if x < 16 else 255)                   # 25%
    with tempfile.TemporaryDirectory() as tmp:
        src, dst = os.path.join(tmp, "export"), os.path.join(tmp, "fixed")
        os.makedirs(src)
        make_textured_glb(os.path.join(src, "box.glb"), (0, 0, 0), (-0.4, 0, -0.4), (0.4, 0.5, 0.4), [
            ("Body", opaque, {"emissiveTexture": black}),
            ("Frame", speckled, {"emissiveTexture": black}),
            ("Glass", glass, {"emissiveTexture": black}),
            ("Leaves", patchy, {}),
            ("Lamp", opaque, {"emissiveTexture": black, "emissiveFactor": [1, 1, 1]}),
            ("Plain", None, {}),
        ])
        # A straight and a cap at the north edge, 3 and 1 tiles east, sharing one picture (as Vasillo's do).
        make_textured_glb(os.path.join(src, "tube.glb"), (3, 0, 0), (-0.45, 0.05, -0.5), (0.45, 0.95, 0.5),
                          [("Pipe_Straight", opaque, {"emissiveTexture": black})])
        make_textured_glb(os.path.join(src, "cap.glb"), (1, 0, 0), (-0.45, 0.05, -0.5), (0.45, 0.95, -0.386),
                          [("Pipe_Straight", opaque, {"emissiveTexture": black})])
        make_textured_glb(os.path.join(src, "rock.glb"), (-1.2, 0, -0.3), (-0.15, 0, -0.1), (0.2, 0.14, 0.17),
                          [("Ore", None, {})])
        make_glb(os.path.join(src, "plain.glb"), (0, 0, 0), (-0.2, 0, -0.2), (0.2, 0.2, 0.2))
        make_textured_glb(os.path.join(src, "solid.glb"), (0, 0, 0), (-0.2, 0, -0.2), (0.2, 0.2, 0.2),
                          [("Steel", opaque, {"alphaMode": "OPAQUE"})])
        fixes = {"materials": {"unwire_emission": True, "alpha_by_picture": True, "mask_share": 0.05,
                               "keep_blend": ["Glass"]},
                 "files": {
                     "tube": {"offset": [-3, 0, 0], "out": [
                         {"name": "pipe-straight-vertical"},
                         {"name": "pipe-ending-up", "add": [{"model": "cap", "turn": 180}]},
                         {"name": "pipe-ending-right", "turn": 90, "add": [{"model": "cap", "turn": 270}]},
                         {"name": "pipe-straight-vertical-single", "add": [{"model": "cap"}, {"model": "cap", "turn": 180}]}]},
                     "cap": {"offset": [-1, 0, 0], "out": []},
                     "rock": {"centre": True, "out": [{"name": "coal-1"}]},
                 }}
        lines = []
        _count, problems = fix_pack.fix_pack(src, dst, fixes, log=lines.append)
        expect(problems == [], "materials run: no warnings (%s)" % problems)
        doc, chunks = fix_pack.read_model(os.path.join(dst, "box.glb"))
        mats = {m["name"]: m for m in doc["materials"]}
        expect(all("emissiveTexture" not in mats[n] for n in ("Body", "Frame", "Glass")),
               "an emission picture with no emissiveFactor is unwired")
        expect("emissiveTexture" in mats["Lamp"] and mats["Lamp"]["emissiveFactor"] == [1, 1, 1],
               "a real emission (factor 1) is kept")
        expect(mats["Body"]["alphaMode"] == "OPAQUE" and "alphaCutoff" not in mats["Body"],
               "BLEND with alpha full on every pixel -> OPAQUE")
        expect(mats["Plain"]["alphaMode"] == "OPAQUE", "BLEND with no picture and an opaque colour -> OPAQUE")
        expect(mats["Frame"]["alphaMode"] == "MASK" and mats["Frame"]["alphaCutoff"] == 0.5,
               "BLEND with 1.5% of pixels below full -> MASK 0.5")
        expect(mats["Leaves"]["alphaMode"] == "BLEND", "BLEND with 25% below full stays BLEND")
        expect(mats["Glass"]["alphaMode"] == "BLEND", "Glass stays BLEND (keep_blend; and 100% below full)")
        # Kept: the opaque picture (Body's and Lamp's, the same bytes: once), Frame's, Glass's, Leaves' and
        # Lamp's emission; the 3 unwired emission pictures are gone.
        expect(len(doc["images"]) == 5 and len(doc["textures"]) == 5,
               "the unwired emission pictures are dropped, a shared one kept once (%d images)" % len(doc["images"]))
        src_doc, src_chunks = fix_pack.read_model(os.path.join(src, "box.glb"))
        expect(len(fix_pack.bin_chunk(chunks)) < len(fix_pack.bin_chunk(src_chunks)), "and the BIN shrinks")
        body_tex = mats["Body"]["pbrMetallicRoughness"]["baseColorTexture"]["index"]
        expect(fix_pack.image_bytes(doc, chunks, doc["textures"][body_tex]["source"], dst) == opaque,
               "a kept picture's bytes are intact after the rebuild")
        expect(open(os.path.join(dst, "solid.glb"), "rb").read() == open(os.path.join(src, "solid.glb"), "rb").read(),
               "an unlisted model with nothing to fix is copied byte for byte")
        doc, chunks = fix_pack.read_model(os.path.join(dst, "plain.glb"))
        _sd, schunks = fix_pack.read_model(os.path.join(src, "plain.glb"))
        expect([m["alphaMode"] for m in doc["materials"]] == ["OPAQUE", "OPAQUE"] and chunks == schunks,
               "an unlisted BLEND model is made OPAQUE, its BIN unchanged")

        # The merged ending: the straight plus a cap at the far edge, both at the tile centre.
        doc, chunks = fix_pack.read_model(os.path.join(dst, "pipe-ending-up.glb"))
        lo, hi = bounds(os.path.join(dst, "pipe-ending-up.glb"))
        expect(close(lo, [-0.45, 0.05, -0.5]) and close(hi, [0.45, 0.95, 0.5]), "merged ending spans the tile (%s %s)" % (lo, hi))
        expect(len(doc["scenes"][0]["nodes"]) == 2 and len(doc["meshes"]) == 2, "merged ending: two roots, two meshes")
        cap_root = doc["nodes"][doc["scenes"][0]["nodes"][1]]
        caps = [n for n in doc["nodes"] if n.get("mesh") == 1]
        expect(len(caps) == 1, "the cap's mesh is in the file once")
        # Where the cap went: the ending-up's cap must sit at the south edge (z 0.386..0.5).
        root = fix_pack.node_matrix(cap_root)
        acc = doc["accessors"][doc["meshes"][1]["primitives"][0]["attributes"]["POSITION"]]
        zs = sorted(root[2][0] * x + root[2][1] * y + root[2][2] * z + root[2][3]
                    for x in (acc["min"][0], acc["max"][0]) for y in (acc["min"][1], acc["max"][1])
                    for z in (acc["min"][2], acc["max"][2]))
        expect(abs(zs[0] - 0.386) < 1e-4 and abs(zs[-1] - 0.5) < 1e-4, "ending-up: the cap closes the south edge (z %.3f..%.3f)" % (zs[0], zs[-1]))
        expect(len(doc["materials"]) == 1 and len(doc["images"]) == 1,
               "merged ending: the shared material and picture kept once (%d, %d)" % (len(doc["materials"]), len(doc["images"])))
        expect(doc["materials"][0]["alphaMode"] == "OPAQUE" and "emissiveTexture" not in doc["materials"][0],
               "merged ending: its material cleaned too")
        views_end = max(v["byteOffset"] + v["byteLength"] for v in doc["bufferViews"])
        expect(doc["buffers"][0]["byteLength"] == len(fix_pack.bin_chunk(chunks)) >= views_end,
               "merged ending: the BIN holds every buffer view")
        doc_r, _ = fix_pack.read_model(os.path.join(dst, "pipe-ending-right.glb"))
        lo, hi = bounds(os.path.join(dst, "pipe-ending-right.glb"))
        expect(close(lo, [-0.5, 0.05, -0.45]) and close(hi, [0.5, 0.95, 0.45]), "ending-right lies east-west (%s %s)" % (lo, hi))
        rot = fix_pack.node_matrix(doc_r["nodes"][doc_r["scenes"][0]["nodes"][1]])
        xs = sorted(rot[0][0] * x + rot[0][1] * y + rot[0][2] * z + rot[0][3]
                    for x in (acc["min"][0], acc["max"][0]) for y in (acc["min"][1], acc["max"][1])
                    for z in (acc["min"][2], acc["max"][2]))
        expect(abs(xs[0] + 0.5) < 1e-4 and abs(xs[-1] + 0.386) < 1e-4, "ending-right: the cap closes the west edge (x %.3f..%.3f)" % (xs[0], xs[-1]))
        doc_s, _ = fix_pack.read_model(os.path.join(dst, "pipe-straight-vertical-single.glb"))
        expect(len(doc_s["scenes"][0]["nodes"]) == 3, "the single: the straight and two caps")
        expect(not os.path.exists(os.path.join(dst, "cap.glb")), "a part-only model (out []) is not written")
        doc_v, chunks_v = fix_pack.read_model(os.path.join(dst, "pipe-straight-vertical.glb"))
        expect(len(doc_v["meshes"]) == 1, "the plain straight has no cap")

        # Ores: renamed, centred on their own box in x and z, y kept.
        lo, hi = bounds(os.path.join(dst, "coal-1.glb"))
        expect(close([(lo[0] + hi[0]) / 2, lo[1], (lo[2] + hi[2]) / 2], [0, 0, 0]), "coal-1 centred in x, z, on the ground (%s %s)" % (lo, hi))
        expect(not os.path.exists(os.path.join(dst, "rock.glb")), "the rock renamed")


def extension_tests():
    # An extension that keeps its own bufferView or picture source (draco, meshopt, webp, basisu) isn't remapped by
    # merge_into or compact: refused with a clear error naming the file, and no broken file written.
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "export")
        dst = os.path.join(tmp, "export (fixed)")
        os.makedirs(src)
        make_glb(os.path.join(src, "tube.glb"), (0, 0, 0), (-0.45, 0, -0.5), (0.45, 0.9, 0.5))
        make_glb(os.path.join(src, "cap.glb"), (0, 0, 0), (-0.45, 0, -0.5), (0.45, 0.9, -0.4))
        plain, plain_chunks = fix_pack.read_model(os.path.join(src, "tube.glb"))
        for ext in fix_pack.UNREMAPPED_EXTENSIONS:
            doc = dict(plain, extensionsUsed=[ext])
            for what, run in (("merge_into (the model)", lambda: fix_pack.merge_into(json.loads(json.dumps(doc)), plain_chunks,
                                                                                      json.loads(json.dumps(plain)), plain_chunks)),
                              ("merge_into (the part)", lambda: fix_pack.merge_into(json.loads(json.dumps(plain)), plain_chunks,
                                                                                     json.loads(json.dumps(doc)), plain_chunks)),
                              ("compact", lambda: fix_pack.compact(json.loads(json.dumps(doc)), plain_chunks))):
                try:
                    run()
                    said = None
                except ValueError as e:
                    said = str(e)
                expect(said is not None and ext in said, "%s refuses %s (%s)" % (what, ext, said))
        expect(fix_pack.merge_into(json.loads(json.dumps(plain)), plain_chunks, json.loads(json.dumps(plain)), plain_chunks)
               is not None, "merge_into still takes a file with no such extension")
        cap, cap_chunks = fix_pack.read_model(os.path.join(src, "cap.glb"))
        cap["extensionsUsed"] = ["EXT_meshopt_compression"]
        fix_pack.write_model(os.path.join(src, "cap.glb"), cap, cap_chunks)
        fixes = {"files": {"tube": {"out": [{"name": "pipe-ending-up", "add": [{"model": "cap"}]}]},
                           "cap": {"out": []}}}
        try:
            fix_pack.fix_pack(src, dst, fixes, log=lambda line: None)
            said = None
        except ValueError as e:
            said = str(e)
        expect(said is not None and "tube.glb + cap" in said and "EXT_meshopt_compression" in said,
               "fix_pack stops on a part using EXT_meshopt_compression, naming the file (%s)" % said)
        expect(not os.path.exists(os.path.join(dst, "pipe-ending-up.glb")), "and writes no broken merged file")


def check_tests():
    """check.py: the drill's chute and bit allowed, items checked as items, numbered ores known."""
    known = check.known_prototypes()
    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, "items"))
        drill = os.path.join(tmp, "electric-mining-drill.glb")
        make_glb(drill, (0, 0, 0), (-1.5, -0.227, -1.757), (1.5, 1.9, 1.5))
        _n, problems, _notes, _s = check.check(drill, known)
        expect(problems == [], "check.py: the drill's 0.26 chute and 0.23 bit allowed (%s)" % problems)
        make_glb(drill, (0, 0, 0), (-1.5, -0.5, -2.2), (1.5, 1.9, 1.5))
        _n, problems, _notes, _s = check.check(drill, known)
        expect(len(problems) == 2, "check.py: but not a drill 0.7 over and 0.5 under (%s)" % problems)
        wet = os.path.join(tmp, "electric-mining-drill-wet.glb")
        make_glb(wet, (0, 0, 0), (-1.5, 0, -1.42), (1.5, 0.95, 1.5))
        expect(check.check(wet, known)[1] == [], "check.py: electric-mining-drill-wet known")
        for name in ("pipe-straight-vertical-window", "coal-2", "iron-ore-3"):
            path = os.path.join(tmp, name + ".glb")
            make_glb(path, (0, 0, 0), (-0.45, 0, -0.5), (0.45, 0.9, 0.5))
            expect(check.check(path, known)[1] == [], "check.py: %s known" % name)
        path = os.path.join(tmp, "coal-ore-2.glb")
        make_glb(path, (0, 0, 0), (-0.1, 0, -0.1), (0.1, 0.1, 0.1))
        expect(any("unknown" in p for p in check.check(path, known)[1]), "check.py: coal-ore-2 still unknown")
        item = os.path.join(tmp, "items", "iron-plate.glb")
        make_glb(item, (0, 0, 0), (-0.125, 0, -0.125), (0.125, 0.025, 0.125))
        name, problems, _notes, _s = check.check(item, known)
        expect(name == "items/iron-plate" and problems == [], "check.py: items/iron-plate checked as an item (%s)" % problems)
        make_glb(item, (0, 0, -0.9), (-0.125, 0, -0.125), (0.125, 0.025, 0.125))
        expect(any("centred" in p for p in check.check(item, known)[1]), "check.py: an item off the origin fails")
        bad = os.path.join(tmp, "items", "flux-capacitor.glb")
        make_glb(bad, (0, 0, 0), (-0.1, 0, -0.1), (0.1, 0.1, 0.1))
        expect(any("unknown item" in p for p in check.check(bad, known)[1]), "check.py: an unknown item name fails")


def triangles(doc, chunks, meshes=None):
    """[(a, b, c) positions per triangle] over every primitive of every node's mesh (node transforms left out),
    or of the meshes listed."""
    out = []
    for i, mesh in enumerate(doc.get("meshes", [])):
        if meshes is not None and i not in meshes:
            continue
        for prim in mesh["primitives"]:
            pos = fix_pack.read_accessor(doc, chunks, prim["attributes"]["POSITION"])
            idx = [v[0] for v in fix_pack.read_accessor(doc, chunks, prim["indices"])] if "indices" in prim else list(range(len(pos)))
            out += [tuple(tuple(round(c, 5) for c in pos[i]) for i in idx[t:t + 3]) for t in range(0, len(idx) - 2, 3)]
    return out


def mesh_triangles(doc, chunks, index):
    return triangles(doc, chunks, [index])


def has_back_faces(tris):
    """Whether every triangle has a twin wound the other way round (the same corners, reversed)."""
    keys = {}
    for a, b, c in tris:
        k = min((a, b, c), (b, c, a), (c, a, b))
        keys[k] = keys.get(k, 0) + 1
    return all(keys.get(min((a, c, b), (c, b, a), (b, a, c)), 0) > 0 for a, b, c in tris)


def inside_tests():
    """"inside": every triangle gets a back face (reversed, its normal turned over, UVs kept) and the rest of
    the file stays readable; a model without it keeps its triangles."""
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "export")
        os.makedirs(src)
        # Two triangles with normals and UVs, one material, one node.
        pos = [(0, 0, 0), (1, 0, 0), (1, 0, 1), (0, 0, 1)]
        nor = [(0, 1, 0)] * 4
        uv = [(0, 0), (1, 0), (1, 1), (0, 1)]
        binary = (b"".join(struct.pack("<3f", *v) for v in pos) + b"".join(struct.pack("<3f", *v) for v in nor)
                  + b"".join(struct.pack("<2f", *v) for v in uv) + struct.pack("<6H", 0, 2, 1, 0, 3, 2) + b"\0\0")
        doc = {"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
               "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2}, "indices": 3, "material": 0}]}],
               "materials": [{"name": "Shell", "doubleSided": True}],
               "buffers": [{"byteLength": len(binary)}],
               "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 48}, {"buffer": 0, "byteOffset": 48, "byteLength": 48},
                               {"buffer": 0, "byteOffset": 96, "byteLength": 32}, {"buffer": 0, "byteOffset": 128, "byteLength": 12}],
               "accessors": [{"bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3", "min": [0, 0, 0], "max": [1, 0, 1]},
                             {"bufferView": 1, "componentType": 5126, "count": 4, "type": "VEC3"},
                             {"bufferView": 2, "componentType": 5126, "count": 4, "type": "VEC2"},
                             {"bufferView": 3, "componentType": 5123, "count": 6, "type": "SCALAR"}]}
        fix_pack.write_model(os.path.join(src, "shell.glb"), doc, [(b"BIN\0", binary)])
        fix_pack.write_model(os.path.join(src, "plain.glb"), doc, [(b"BIN\0", binary)])
        dst = os.path.join(tmp, "fixed")
        lines = []
        _count, problems = fix_pack.fix_pack(src, dst, {"files": {"shell": {"inside": True}}}, log=lines.append)
        expect(problems == [] and any("inside added (2 back faces)" in l for l in lines), "inside: logged (%s)" % lines)
        out, chunks = fix_pack.read_model(os.path.join(dst, "shell.glb"))
        tris = triangles(out, chunks)
        prim = out["meshes"][0]["primitives"][0]
        normals = fix_pack.read_accessor(out, chunks, prim["attributes"]["NORMAL"])
        uvs = fix_pack.read_accessor(out, chunks, prim["attributes"]["TEXCOORD_0"])
        expect(len(tris) == 4 and has_back_faces(tris), "inside: 2 triangles become 4, each with its back face (%s)" % tris)
        expect(normals == [(0, 1, 0)] * 4 + [(0, -1, 0)] * 4 and uvs == uv + uv,
               "inside: the back faces' normals turned over, their UVs the same (%s, %s)" % (normals, uvs))
        expect(len(out["accessors"]) == 4 and len(out["bufferViews"]) == 4 and out["buffers"][0]["byteLength"] == len(fix_pack.bin_chunk(chunks)),
               "inside: the old accessors and bytes dropped (%d accessors, %d views)" % (len(out["accessors"]), len(out["bufferViews"])))
        plain = triangles(*fix_pack.read_model(os.path.join(dst, "plain.glb")))
        expect(len(plain) == 2 and not has_back_faces(plain), "a model without inside keeps its 2 triangles, one side")
        # "inside" on an added part (a pipe's cap): that part alone gets back faces, the model it is added to doesn't,
        # and the part's other uses (here, added again without it) keep one side.
        dst = os.path.join(tmp, "parts")
        lines = []
        _count, problems = fix_pack.fix_pack(src, dst, {"files": {
            "plain": {"out": [{"name": "capped", "add": [{"model": "shell", "inside": True}]},
                              {"name": "bare", "add": [{"model": "shell"}]}]},
            "shell": {"out": []}}}, log=lines.append)
        expect(problems == [] and any(l.startswith("capped") and "+ shell with an inside (2 back faces)" in l for l in lines),
               "inside on a part: logged (%s)" % lines)
        doc, chunks = fix_pack.read_model(os.path.join(dst, "capped.glb"))
        body, part = mesh_triangles(doc, chunks, 0), mesh_triangles(doc, chunks, 1)
        expect(len(body) == 2 and not has_back_faces(body) and len(part) == 4 and has_back_faces(part),
               "inside on a part: the part's 2 triangles become 4 with back faces, the model's 2 stay one side (%d, %d)" % (len(body), len(part)))
        doc, chunks = fix_pack.read_model(os.path.join(dst, "bare.glb"))
        part = mesh_triangles(doc, chunks, 1)
        expect(len(part) == 2 and not has_back_faces(part), "the same part added without inside keeps one side (%d)" % len(part))
        # A model with an OPAQUE surface and a BLEND glass surface (like pipe-alt): OPAQUE gets back faces, BLEND stays single-sided.
        pos_g = pos + [(0, 0.5, 0), (1, 0.5, 0), (1, 0.5, 1), (0, 0.5, 1)]
        nor_g = nor + [(0, 1, 0)] * 4
        uv_g = uv + uv
        bin_g = (b"".join(struct.pack("<3f", *v) for v in pos_g) + b"".join(struct.pack("<3f", *v) for v in nor_g)
                 + b"".join(struct.pack("<2f", *v) for v in uv_g)
                 + struct.pack("<6H", 0, 2, 1, 0, 3, 2)
                 + struct.pack("<6H", 4, 6, 5, 4, 7, 6))
        doc_g = {
            "asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
            "meshes": [{"primitives": [
                {"attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2}, "indices": 3, "material": 0},
                {"attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2}, "indices": 4, "material": 1},
            ]}],
            "materials": [{"name": "Body", "doubleSided": True}, {"name": "Glass", "alphaMode": "BLEND", "doubleSided": True}],
            "buffers": [{"byteLength": len(bin_g)}],
            "bufferViews": [
                {"buffer": 0, "byteOffset": 0, "byteLength": 96},
                {"buffer": 0, "byteOffset": 96, "byteLength": 96},
                {"buffer": 0, "byteOffset": 192, "byteLength": 64},
                {"buffer": 0, "byteOffset": 256, "byteLength": 12},
                {"buffer": 0, "byteOffset": 268, "byteLength": 12},
            ],
            "accessors": [
                {"bufferView": 0, "componentType": 5126, "count": 8, "type": "VEC3", "min": [0, 0, 0], "max": [1, 0.5, 1]},
                {"bufferView": 1, "componentType": 5126, "count": 8, "type": "VEC3"},
                {"bufferView": 2, "componentType": 5126, "count": 8, "type": "VEC2"},
                {"bufferView": 3, "componentType": 5123, "count": 6, "type": "SCALAR"},
                {"bufferView": 4, "componentType": 5123, "count": 6, "type": "SCALAR"},
            ],
        }
        src_g = os.path.join(tmp, "glass_src")
        dst_g = os.path.join(tmp, "glass_dst")
        os.makedirs(src_g)
        fix_pack.write_model(os.path.join(src_g, "pipe_win.glb"), doc_g, [(b"BIN\0", bin_g)])
        lines = []
        _count, problems = fix_pack.fix_pack(src_g, dst_g, {"files": {"pipe_win": {"inside": True}}}, log=lines.append)
        expect(problems == [] and any("inside added (2 back faces)" in l for l in lines), "inside skips BLEND: logged (%s)" % lines)
        out_g, chunks_g = fix_pack.read_model(os.path.join(dst_g, "pipe_win.glb"))
        prims_g = out_g["meshes"][0]["primitives"]
        idx_opaque = fix_pack.read_accessor(out_g, chunks_g, prims_g[0]["indices"])
        idx_blend = fix_pack.read_accessor(out_g, chunks_g, prims_g[1]["indices"])
        expect(len(idx_opaque) == 12 and len(idx_blend) == 6,
               "inside skips BLEND: opaque doubled (%d indices) while BLEND kept single-sided (%d indices)" % (len(idx_opaque), len(idx_blend)))


def source_triangles(_entries, src, name, skip_materials=()):
    doc, _chunks = fix_pack.read_model(os.path.join(src, name + ".glb"))
    mats = doc.get("materials", [])
    kept, skipped = 0, 0
    for mesh in doc.get("meshes", []):
        for prim in mesh["primitives"]:
            idx = prim.get("indices")
            tris = (doc["accessors"][idx]["count"] if idx is not None else doc["accessors"][prim["attributes"]["POSITION"]]["count"]) // 3
            m = prim.get("material")
            if m is not None and mats[m].get("name", "") in skip_materials:
                skipped += tris
            else:
                kept += tris
    return kept, skipped


def base_pictures(path):
    """{material name: sha256 of its base colour picture} for a model's textured materials."""
    doc, chunks = fix_pack.read_model(path)
    found = {}
    for m in doc.get("materials", []):
        ref = m.get("pbrMetallicRoughness", {}).get("baseColorTexture")
        if ref is not None:
            source = doc["textures"][ref["index"]]["source"]
            found[m.get("name")] = hashlib.sha256(fix_pack.image_bytes(doc, chunks, source, "")).hexdigest()
    return found


def real_pack_tests(src, fixed):
    """Every pipe file of the fixed copy against the modeller's export and the list: its triangles are its
    source's (with each added part's), twice over with an inside (except keep_blend glass), and its base colour
    pictures its source's; pipe-to-ground's open end has one."""
    fixes = fix_pack.load_fixes(fix_pack.DEFAULT_FIXES)
    keep_blend = set((fixes.get("materials") or {}).get("keep_blend", []))
    checked = 0
    for name, entry in fixes["files"].items():
        if not name.startswith(("pipe", "ppe")) or not os.path.isfile(os.path.join(src, name + ".glb")):
            continue
        for out in entry.get("out", [{"name": name}]):
            kept, skipped = source_triangles(fixes["files"], src, name, keep_blend if entry.get("inside") else ())
            want = kept * (2 if entry.get("inside") else 1) + skipped
            for a in out.get("add", []):
                ak, ask = source_triangles(fixes["files"], src, a["model"])
                want += (ak + ask) * (2 if a.get("inside") else 1)
            path = os.path.join(fixed, out["name"] + ".glb")
            got = len(triangles(*fix_pack.read_model(path))) if os.path.isfile(path) else -1
            insides = [a["model"] for a in out.get("add", []) if a.get("inside")]
            expect(got == want, "the fixed %s: %d triangles, its source's %d%s%s" % (
                out["name"], got, want, " (with an inside)" if entry.get("inside") else "",
                " (%s with an inside)" % ", ".join(insides) if insides else ""))
            # Each added part's meshes follow the model's own, in order: those with an inside have back faces.
            if os.path.isfile(path) and out.get("add"):
                doc, chunks = fix_pack.read_model(path)
                first = len(fix_pack.read_model(os.path.join(src, name + ".glb"))[0]["meshes"])
                for a in out["add"]:
                    n = len(fix_pack.read_model(os.path.join(src, a["model"] + ".glb"))[0]["meshes"])
                    tris = triangles(doc, chunks, range(first, first + n))
                    expect(bool(tris) and has_back_faces(tris) == bool(a.get("inside")),
                           "the fixed %s: its %s%s drawn from both sides%s" % (out["name"], a["model"],
                           " turned %g" % a["turn"] if a.get("turn") else "", "" if a.get("inside") else " is not"))
                    first += n
            # His pictures as he made them: every base colour picture the source's, byte for byte.
            if os.path.isfile(path):
                expect(base_pictures(path) == base_pictures(os.path.join(src, name + ".glb")),
                       "the fixed %s: its base colour pictures are %s's, unchanged" % (out["name"], name))
            checked += 1
    ptg = os.path.join(fixed, "pipe-to-ground.glb")
    expect(os.path.isfile(ptg) and has_back_faces(triangles(*fix_pack.read_model(ptg))),
           "the fixed pipe-to-ground: every triangle drawn from both sides (its open end has an inside)")
    print("  %d pipe files of %s checked against %s" % (checked, fixed, src))


def rest_turn_tests():
    """keep_rest_turn: rollers stood across the belt (-90 about y) whose keys spin them about z only."""
    yaw = [0.0, -math.sqrt(0.5), 0.0, math.sqrt(0.5)]
    keys = [[0.0, 0.0, math.sin(a / 2), math.cos(a / 2)] for a in (-0.21, 1.0, math.pi)]
    with tempfile.TemporaryDirectory() as tmp:
        src, dst = os.path.join(tmp, "src"), os.path.join(tmp, "dst")
        os.makedirs(src)
        pos = b"".join(struct.pack("<3f", *v) for v in [(-0.1, -0.1, -0.4), (0.1, -0.1, -0.4), (0.1, 0.1, 0.4)])
        times = struct.pack("<3f", 0, 0.5, 1)
        rots = b"".join(struct.pack("<4f", *k) for k in keys)
        binary = pos + times + rots
        doc = {
            "asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [2]}],
            "nodes": [{"name": "Roller1", "mesh": 0, "rotation": yaw, "translation": [-0.5, 0.13, -0.5]},
                      {"name": "Roller2", "mesh": 0, "rotation": yaw, "translation": [0.5, 0.13, 0]},
                      {"name": "Body", "children": [0, 1]}],
            "meshes": [{"primitives": [{"attributes": {"POSITION": 0}}]}],
            "buffers": [{"byteLength": len(binary)}],
            "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 36},
                            {"buffer": 0, "byteOffset": 36, "byteLength": 12},
                            {"buffer": 0, "byteOffset": 48, "byteLength": 48}],
            "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3",
                           "min": [-0.1, -0.1, -0.4], "max": [0.1, 0.1, 0.4]},
                          {"bufferView": 1, "componentType": 5126, "count": 3, "type": "SCALAR", "min": [0], "max": [1]},
                          {"bufferView": 2, "componentType": 5126, "count": 3, "type": "VEC4"}],
            # Both rollers' actions read the same keys, as in Vasillo's splitter.
            "animations": [{"name": n, "samplers": [{"input": 1, "output": 2}],
                            "channels": [{"sampler": 0, "target": {"node": i, "path": "rotation"}}]}
                           for i, n in enumerate(("Roller1", "Roller2"))],
        }
        fix_pack.write_model(os.path.join(src, "splitter.glb"), doc, [(b"BIN\0", binary)])
        fixes = {"files": {"splitter": {"keep_rest_turn": ["Roller1", "Roller2"]}}}
        _count, problems = fix_pack.fix_pack(src, dst, fixes, log=lambda _l: None)
        expect(problems == [], "keep_rest_turn: no warnings (%s)" % problems)
        out, chunks = fix_pack.read_model(os.path.join(dst, "splitter.glb"))
        for anim in out["animations"]:
            got = fix_pack.read_accessor(out, chunks, anim["samplers"][0]["output"])
            want = [fix_pack.quat_mul(yaw, k) for k in keys]
            expect(all(close(g, w) for g, w in zip(got, want)) and len(got) == 3,
                   "keep_rest_turn: %s's keys are rest * key (%s)" % (anim["name"], [list(map(lambda c: round(c, 3), g)) for g in got]))
            # The roller's axle (local z) still across the belt (along x) at every key, not along it.
            axle = [abs(c) for c in fix_pack.rotate(list(got[0]), [0, 0, 1])]
            expect(axle[0] > 0.99, "keep_rest_turn: %s's axle along x at its first key (%s)" % (anim["name"], axle))
        expect(out["animations"][0]["samplers"][0]["output"] == out["animations"][1]["samplers"][0]["output"],
               "keep_rest_turn: the shared keys turned once, still shared")
        body = fix_pack.bin_chunk(chunks)
        expect(rots not in body and len(body) == len(binary), "keep_rest_turn: the old keys gone from the BIN (%d bytes)" % len(body))
        expect([n.get("rotation") for n in out["nodes"][:2]] == [yaw, yaw], "keep_rest_turn: the rest turns unchanged")
        # Run again on the fixed copy: keys that keep the rest turn already are left, with a warning.
        again = os.path.join(tmp, "again")
        _count, problems = fix_pack.fix_pack(dst, again, fixes, log=lambda _l: None)
        expect(len(problems) == 2 and all("already keep" in p for p in problems),
               "keep_rest_turn: keys that already keep it left, warned (%s)" % problems)
        _doc2, chunks2 = fix_pack.read_model(os.path.join(again, "splitter.glb"))
        expect(fix_pack.bin_chunk(chunks2) == body, "keep_rest_turn: nothing turned twice")
        _count, problems = fix_pack.fix_pack(src, os.path.join(tmp, "x"), {"files": {"splitter": {"keep_rest_turn": ["Body", "Nope"]}}},
                                             log=lambda _l: None)
        expect(len(problems) == 2, "keep_rest_turn: no rest turn, no such node warned (%s)" % problems)
    # The real list: the splitter's four rollers.
    real = fix_pack.load_fixes(fix_pack.DEFAULT_FIXES)["files"]["splitter"].get("keep_rest_turn", [])
    expect(sorted(real) == sorted("Belt_Splitter_%s_Roller%d" % (s, i) for s in ("Left", "Right") for i in (1, 2)),
           "vasillo.json: the splitter's four rollers keep their rest turn (%s)" % real)


def pack_json_tests():
    """"pack_json": its keys over the source's pack.json in the copy (a new one without), the note left out;
    the source untouched; vasillo.json asks for "shading": "pbr" (the owner's per-pack decision)."""
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "M")
        os.makedirs(src)
        make_glb(os.path.join(src, "box.glb"), (0, 0, 0), (-0.5, 0, -0.5), (0.5, 0.5, 0.5))
        with open(os.path.join(src, "pack.json"), "w", encoding="utf-8") as f:
            json.dump({"name": "M", "shading": "factorio"}, f)
        before = open(os.path.join(src, "pack.json"), "rb").read()
        fixes = {"files": {}, "pack_json": {"shading": "pbr", "note": "why"}}
        fix_pack.fix_pack(src, os.path.join(tmp, "out"), fixes, log=lambda *a: None)
        with open(os.path.join(tmp, "out", "pack.json"), encoding="utf-8") as f:
            got = json.load(f)
        expect(got == {"name": "M", "shading": "pbr"}, "pack_json: its keys over the source's pack.json (%s)" % got)
        expect(open(os.path.join(src, "pack.json"), "rb").read() == before, "pack_json: the source's pack.json untouched")
        os.remove(os.path.join(src, "pack.json"))
        count, problems = fix_pack.fix_pack(src, os.path.join(tmp, "out2"), fixes, log=lambda *a: None)
        with open(os.path.join(tmp, "out2", "pack.json"), encoding="utf-8") as f:
            got = json.load(f)
        expect(got == {"shading": "pbr"} and count == 2 and not problems,
               "pack_json: a new pack.json when the source has none (%s, %d files, %s)" % (got, count, problems))
        fix_pack.fix_pack(src, os.path.join(tmp, "out3"), {"files": {}}, log=lambda *a: None)
        expect(not os.path.exists(os.path.join(tmp, "out3", "pack.json")), "pack_json: none written without the key")
    real = fix_pack.load_fixes(fix_pack.DEFAULT_FIXES)
    expect((real.get("pack_json") or {}).get("shading") == "pbr", "vasillo.json: his copy's pack.json says shading pbr")


def drop_and_diff_tests():
    """drop_shells and add[].diff: drop a disconnected shell inside a box and merge only unique triangles."""
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "export")
        dst = os.path.join(tmp, "fixed")
        os.makedirs(src)

        def write_tris_glb(path, prim_specs):
            pos, nor, views, accessors, prims = [], [], [], [], []
            binary = bytearray()

            def add_view(raw, target=None):
                binary.extend(b"\0" * (-len(binary) % 4))
                v = {"buffer": 0, "byteOffset": len(binary), "byteLength": len(raw)}
                if target is not None:
                    v["target"] = target
                views.append(v)
                binary.extend(raw)
                return len(views) - 1

            for mat_idx, tris in prim_specs:
                p_list, n_list, i_list = [], [], []
                for tri in tris:
                    base = len(p_list)
                    p_list.extend(tri)
                    n_list.extend([(0.0, 1.0, 0.0)] * 3)
                    i_list.extend([base, base + 1, base + 2])
                pv = add_view(b"".join(struct.pack("<3f", *v) for v in p_list), 34962)
                nv = add_view(b"".join(struct.pack("<3f", *v) for v in n_list), 34962)
                iv = add_view(struct.pack("<%dH" % len(i_list), *i_list), 34963)
                lo = [min(v[k] for v in p_list) for k in range(3)]
                hi = [max(v[k] for v in p_list) for k in range(3)]
                pa = len(accessors)
                accessors.append({"bufferView": pv, "componentType": 5126, "count": len(p_list), "type": "VEC3", "min": lo, "max": hi})
                na = len(accessors)
                accessors.append({"bufferView": nv, "componentType": 5126, "count": len(n_list), "type": "VEC3"})
                ia = len(accessors)
                accessors.append({"bufferView": iv, "componentType": 5123, "count": len(i_list), "type": "SCALAR"})
                prims.append({"attributes": {"POSITION": pa, "NORMAL": na}, "indices": ia, "material": mat_idx})
            binary.extend(b"\0" * (-len(binary) % 4))
            doc = {"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}],
                   "nodes": [{"name": "Mesh", "mesh": 0}], "meshes": [{"primitives": prims}],
                   "materials": [{"name": "Wall"}, {"name": "Light"}],
                   "accessors": accessors, "bufferViews": views, "buffers": [{"byteLength": len(binary)}]}
            fix_pack.write_model(path, doc, [(b"BIN\0", bytes(binary))])

        body_tri = [(-0.2, 0.0, -0.2), (0.2, 0.0, -0.2), (0.0, 0.5, 0.2)]
        south_shell = [(-0.1, 0.0, 0.48), (0.1, 0.0, 0.48), (0.0, 0.2, 0.52)]
        cap_tri = [(-0.2, 0.0, 0.35), (0.2, 0.0, 0.35), (0.0, 0.4, 0.5)]
        light_tri = [(-0.05, 0.9, 0.4), (0.05, 0.9, 0.4), (0.0, 1.0, 0.45)]
        write_tris_glb(os.path.join(src, "single.glb"), [(0, [body_tri, south_shell])])
        write_tris_glb(os.path.join(src, "end.glb"), [(0, [body_tri])])
        write_tris_glb(os.path.join(src, "side.glb"), [(0, [body_tri, cap_tri]), (1, [light_tri])])
        fixes = {"files": {
            "single": {"out": [{"name": "single-gate-e", "turn": 270,
                                "drop_shells": [[[-1, -1, 0.46], [1, 3, 1]]],
                                "add": [{"model": "side", "diff": "end", "turn": 270}]}]},
            "end": {"out": []},
            "side": {"out": []},
        }}
        _count, problems = fix_pack.fix_pack(src, dst, fixes, log=lambda _l: None)
        expect(problems == [], "drop_shells + diff: no warnings (%s)" % problems)
        out_path = os.path.join(dst, "single-gate-e.glb")
        out_doc, out_chunks = fix_pack.read_model(out_path)
        tris = triangles(out_doc, out_chunks)
        expect(len(tris) == 3, "drop_shells dropped south_shell (1) and diff added cap + light (2) -> 3 tris (%d)" % len(tris))
        lo, hi = bounds(out_path)
        expect(close([lo[0], hi[0]], [-0.2, 0.5]), "turned 270: gate cap spans x=-0.2..0.5 (%s %s)" % (lo, hi))


def subfolder_tests():
    """Subfolder exports (Items/<name>.glb): base name matches entry, centre applies, items/<name> writes to dst/items/."""
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "export")
        dst = os.path.join(tmp, "fixed")
        os.makedirs(os.path.join(src, "Items"))
        make_glb(os.path.join(src, "Items", "grenade.glb"), (0.3, 0.1, -0.2), (-0.1, 0, -0.1), (0.1, 0.2, 0.1))
        make_glb(os.path.join(src, "Items", "extra.glb"), (0, 0, 0), (-0.1, 0, -0.1), (0.1, 0.2, 0.1))
        fixes = {"materials": {"alpha_by_picture": True},
                 "files": {"grenade": {"centre": True, "out": [{"name": "items/grenade"}]}}}
        _count, problems = fix_pack.fix_pack(src, dst, fixes, log=lambda _l: None)
        expect(problems == [], "subfolder: no warnings (%s)" % problems)
        out_item = os.path.join(dst, "items", "grenade.glb")
        expect(os.path.isfile(out_item) and not os.path.exists(os.path.join(dst, "Items", "items", "grenade.glb")),
               "subfolder Items/grenade writes to items/grenade.glb")
        lo, hi = bounds(out_item)
        expect(close([(lo[0] + hi[0]) / 2, lo[1], (lo[2] + hi[2]) / 2], [0, 0.1, 0]),
               "subfolder grenade centred in x, z with y kept (%s %s)" % (lo, hi))
        expect(os.path.isfile(os.path.join(dst, "Items", "extra.glb")), "unlisted subfolder file keeps its path")


def main():
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "Modeller export")
        dst = os.path.join(tmp, "Modeller export (fixed)")
        os.makedirs(src)
        # A pipe piece 3 tiles east of the origin, reaching the north edge only.
        make_glb(os.path.join(src, "pipe-cap.glb"), (3, 0, 0), (-0.2, 0, -0.5), (0.2, 0.5, 0.1))
        make_glb(os.path.join(src, "ppe-cross.glb"), (0, 0, 0), (-0.5, 0, -0.5), (0.5, 0.5, 0.5))
        make_glb(os.path.join(src, "iron-plate.glb"), (0, 0, -0.9), (-0.1, 0, -0.1), (0.1, 0.03, 0.1))
        make_glb(os.path.join(src, "belt.glb"), (0, 0, 0), (-0.4, 0, -0.5), (0.4, 0.2, 0.5))
        make_glb(os.path.join(src, "spinner.glb"), (2, 0, 0), (-0.2, 0, -0.2), (0.2, 0.2, 0.2), animated=True)
        make_glb(os.path.join(src, "inserter.glb"), (0, 0, 0), (-0.2, 0, -0.2), (0.2, 0.2, 0.2))
        with open(os.path.join(src, "pack.json"), "w", encoding="utf-8") as f:
            json.dump({"name": "Modeller"}, f)
        before = {f: open(os.path.join(src, f), "rb").read() for f in os.listdir(src)}
        fixes = {"files": {
            "pipe-cap": {"offset": [-3, 0, 0], "out": [{"name": "pipe-ending-up"},
                                                       {"name": "pipe-ending-right", "turn": 90},
                                                       {"name": "pipe-ending-down", "turn": 180}]},
            "ppe-cross": {"out": [{"name": "pipe-cross"}]},
            "iron-plate": {"offset": [0, 0, 0.9], "out": [{"name": "items/iron-plate"}]},
            "belt": {"mask": ["Surface"]},
            "spinner": {"offset": [-2, 0, 0], "out": [{"name": "spinner", "turn": 90}]},
        }}
        lines = []
        count, problems = fix_pack.fix_pack(src, dst, fixes, log=lines.append)
        expect(problems == [], "no warnings (%s)" % problems)
        expect(count == 9, "9 files written (%d)" % count)

        # Rename.
        expect(os.path.exists(os.path.join(dst, "pipe-cross.glb")), "ppe-cross renamed to pipe-cross")
        expect(not os.path.exists(os.path.join(dst, "ppe-cross.glb")), "no ppe-cross left in the copy")
        # Items move (and its re-centre).
        item = os.path.join(dst, "items", "iron-plate.glb")
        expect(os.path.exists(item) and not os.path.exists(os.path.join(dst, "iron-plate.glb")),
               "iron-plate moved into items/")
        lo, hi = bounds(item)
        expect(close([(lo[0] + hi[0]) / 2, (lo[2] + hi[2]) / 2], [0, 0]), "the item centred on the origin")
        # Re-centre: the cap's mesh was at x 2.8..3.2.
        lo, hi = bounds(os.path.join(dst, "pipe-ending-up.glb"))
        expect(close(lo, [-0.2, 0, -0.5]) and close(hi, [0.2, 0.5, 0.1]), "re-centred: %s %s" % (lo, hi))
        # Turns, clockwise from above: north -> east -> south.
        lo, hi = bounds(os.path.join(dst, "pipe-ending-right.glb"))
        expect(close(lo, [-0.1, 0, -0.2]) and close(hi, [0.5, 0.5, 0.2]), "turned 90: reaches east (%s %s)" % (lo, hi))
        lo, hi = bounds(os.path.join(dst, "pipe-ending-down.glb"))
        expect(close(lo, [-0.2, 0, -0.1]) and close(hi, [0.2, 0.5, 0.5]), "turned 180: reaches south (%s %s)" % (lo, hi))
        root = check.read_glb(os.path.join(dst, "pipe-ending-right.glb"))["nodes"][0]
        expect(close(root["rotation"], [0, -0.70710678, 0, 0.70710678]), "the turn is on the root node")
        # MASK, on the named material only.
        doc, chunks = fix_pack.read_model(os.path.join(dst, "belt.glb"))
        mats = {m["name"]: m for m in doc["materials"]}
        expect(mats["Surface"].get("alphaMode") == "MASK" and mats["Surface"].get("alphaCutoff") == 0.5,
               "Surface is Alpha Clip at 0.5")
        expect(mats["Other"].get("alphaMode") == "BLEND", "Other keeps BLEND")
        # The mesh data byte for byte.
        _sdoc, schunks = fix_pack.read_model(os.path.join(src, "belt.glb"))
        expect(chunks == schunks, "the BIN chunk unchanged")
        # An animated root keeps its animation: the fix goes on a new root above it.
        doc, _ = fix_pack.read_model(os.path.join(dst, "spinner.glb"))
        top = doc["nodes"][doc["scenes"][0]["nodes"][0]]
        expect(top.get("children") == [0] and doc["nodes"][0]["translation"] == [2, 0, 0],
               "an animated root is held by a new root, itself unchanged")
        lo, hi = bounds(os.path.join(dst, "spinner.glb"))
        expect(close([(lo[0] + hi[0]) / 2, (lo[2] + hi[2]) / 2], [0, 0]), "and the new root re-centres it")
        # Unlisted files copied unchanged, the source untouched.
        expect(open(os.path.join(dst, "inserter.glb"), "rb").read() == before["inserter.glb"], "inserter copied as it is")
        expect(os.path.exists(os.path.join(dst, "pack.json")), "pack.json carried over")
        expect({f: open(os.path.join(src, f), "rb").read() for f in os.listdir(src)} == before, "the source untouched")
        # An output inside the source is refused.
        try:
            fix_pack.fix_pack(src, os.path.join(src, "fixed"), fixes, log=lines.append)
            expect(False, "an output inside the source is refused")
        except ValueError:
            expect(True, "an output inside the source is refused")
        # A listed model missing from the source is a warning.
        _count, problems = fix_pack.fix_pack(src, os.path.join(tmp, "again"),
                                             {"files": {"gone": {}, "belt": {"mask": ["Nope"]}}}, log=lines.append)
        expect(len(problems) == 2, "a missing model and a missing material warned (%s)" % problems)

    # The real list: every pipe name it writes is one of Zenith's pipe shapes.
    fixes = fix_pack.load_fixes(fix_pack.DEFAULT_FIXES)
    lib = open(os.path.join(HERE, "..", "..", "client", "scripts", "world", "model_library.gd"), encoding="utf-8").read()
    block = re.search(r"const PIPE_SHAPES := \[(.*?)\]", lib, re.S).group(1)
    shapes = {"pipe-" + s for s in re.findall(r'"([a-z-]+)"', block)}
    written = {o["name"] for e in fixes["files"].values() for o in e.get("out", [])}
    windows = {"pipe-straight-vertical-window", "pipe-straight-horizontal-window"}
    pipes = {n for n in written if n.startswith("pipe-")} - {"pipe-to-ground"} - windows
    expect(pipes == shapes, "vasillo.json writes all 16 pipe shapes (%d; missing %s, extra %s)"
           % (len(pipes), sorted(shapes - pipes), sorted(pipes - shapes)))

    expect(windows <= written and "pipe-alt" not in written, "pipe-alt written as the two window straights only")
    names = {k: [o["name"] for o in e.get("out", [{"name": k}])] for k, e in fixes["files"].items()}
    expect(names["electric-mining-drill-liquid"] == ["electric-mining-drill-wet"], "the drill's fluid part is -wet")
    ores = [n for k in names if "ore" in k or k.startswith(("coal", "stone-")) for n in names[k]
            if not n.startswith("items/") and k != "stone-brick"]
    expect(sorted(ores) == sorted("%s-%d" % (o, i) for o in ("iron-ore", "copper-ore", "coal", "stone", "uranium-ore")
                                  for i in (1, 2, 3)),
           "the 15 ores named iron-ore-N, copper-ore-N, coal-N, stone-N, uranium-ore-N (%s)" % sorted(ores))
    expect(all(fixes["files"][k].get("centre") for k in names if names[k] and names[k][0] in ores), "every ore centred on its box")
    # His items (0.2.2's "Items Added" push): each centred into items/<name>; one sulfur heap is the sulfur item.
    items = [k for k in names if names[k] and names[k][0].startswith("items/")]
    new_items = ["advanced-circuit", "automation-science-pack", "chemical-science-pack", "copper-cable",
                 "electronic-circuit", "iron-gear-wheel", "logistic-science-pack", "military-science-pack", "plastic-bar",
                 "processing-unit"]
    expect(all(names.get(k) == ["items/" + k] and fixes["files"][k].get("centre") for k in new_items)
           and fixes["files"]["sulfur-1"].get("centre"), "his 10 new items and the sulfur centred into items/<name>")
    expect(all(names.get("sulfur-%d" % i) == ["items/sulfur-%d" % i] for i in (1, 2, 3)),
           "sulfur-1, -2 and -3 are items/sulfur-N")
    expect(len(items) == 28, "28 items written to items/ (%d)" % len(items))
    newest_items = ["atomic-bomb", "engine-unit", "explosive-rocket", "firearm-magazine", "flamethrower-ammo",
                    "grenade", "piercing-rounds-magazine", "piercing-shotgun-shell", "rocket", "shotgun-shell",
                    "uranium-rounds-magazine"]
    expect(all(names.get(k) == ["items/" + k] and fixes["files"][k].get("centre") for k in newest_items),
           "his 11 new items centred into items/<name>")
    wall_block = re.search(r"const WALL_SHAPES := \[(.*?)\]", lib, re.S).group(1)
    wall_shapes = ({"stone-wall"}
                   | {"stone-wall-" + s for s in re.findall(r'"([a-z-]+)"', wall_block)}
                   | {"stone-wall-%s-fill" % s for s in ("es", "nes", "esw", "nesw")}
                   | {"stone-wall-gate-%s" % d for d in ("n", "e", "s", "w")}
                   | {"stone-wall-gate-single-%s" % d for d in ("n", "e", "s", "w")}
                   | {"stone-wall-gate-ns", "stone-wall-gate-ew"})
    walls_written = {n for n in written if n.startswith("stone-wall")}
    expect(walls_written == wall_shapes, "vasillo.json writes all 31 wall shapes (%d; missing %s, extra %s)"
           % (len(walls_written), sorted(wall_shapes - walls_written), sorted(walls_written - wall_shapes)))
    expect(names.get("wall-gate") == ["gate"]
           and any(a["model"] == "wall-gate-gap" for a in fixes["files"]["wall-gate"]["out"][0].get("add", []))
           and fixes["files"]["wall-gate-gap"].get("out") == []
           and names.get("wall-gate-side") == ["stone-wall-gate-s", "stone-wall-gate-w", "stone-wall-gate-n", "stone-wall-gate-e"],
           "wall-gate merges wall-gate-gap into gate; wall-gate-side writes stone-wall-gate-{s,w,n,e}")
    # The owner's rule: rock isn't metal. Every ore, coal, stone, sulfur and uranium file gets metal 0, as an entity and an item.
    rocks = [k for k in names if k.startswith(("iron-ore-", "copper-ore-", "coal-", "stone-", "uranium-ore-", "sulfur-"))
             and k != "stone-brick"]
    expect(len(rocks) == 18 and all(fixes["files"][k].get("metal") == 0 for k in rocks), "metal 0 on all 18 rock entries")
    expect(all(("items/" + k) in names[k] for k in rocks), "each rock also written as items/<name>")
    recoloured = [k for k, v in fixes.get("recolour", {}).items() if isinstance(v, dict)]
    expect(recoloured == [], "no material recoloured: his ores and pipes keep his pictures as he made them (%s)" % recoloured)
    endings = {o["name"]: o for o in fixes["files"]["pipe"]["out"]}
    expect(all(any(a["model"] == "pipe-cap" for a in endings.get("pipe-ending-" + d, {}).get("add", []))
               for d in ("up", "right", "down", "left"))
           and len(endings["pipe-straight-vertical-single"].get("add", [])) == 2,
           "the endings are pipe + a cap, the single pipe + two caps")
    expect(fixes["files"]["pipe-cap"].get("out") == [], "pipe-cap itself is not written")
    expect(fixes["files"]["pipe-to-ground"].get("inside") is True,
           "pipe-to-ground gets an inside (its tube is single-sided, its north end open)")
    expect(fixes["files"]["pipe-alt"].get("inside") is True,
           "pipe-alt gets an inside (its tube shows through its glass window)")
    caps = [o["name"] for o in fixes["files"]["pipe"]["out"] if any(a["model"] == "pipe-cap" for a in o.get("add", []))]
    expect(len(caps) == 5 and all(a.get("inside") for o in fixes["files"]["pipe"]["out"] for a in o.get("add", []) if a["model"] == "pipe-cap"),
           "every pipe-cap added (%s) has an inside" % caps)

    inside_tests()
    args = sys.argv[1:]
    real = {k: args[args.index(k) + 1] for k in ("--source", "--fixed") if k in args and args.index(k) + 1 < len(args)}
    if len(real) == 2:
        real_pack_tests(real["--source"], real["--fixed"])
    else:
        print("SKIP: the real pack (--source <modeller's export> --fixed <its fixed copy>)")

    materials_tests()
    recolour_tests()
    metal_tests()
    extension_tests()
    rest_turn_tests()
    check_tests()
    pack_json_tests()
    subfolder_tests()
    drop_and_diff_tests()
    print("FIX PACK FAILS: %d" % len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
