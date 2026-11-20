#!/usr/bin/env python3
"""client/tests/fixtures/metal_box_paint.glb and metal_box_metal.glb: two one-tile boxes with the same
grey base colour picture (sRGB 128) and a metallic-roughness picture each (roughness 0.6), the metal
channel black (paint) in one and white (full metal) in the other, metallicFactor 1. For the
texture metal checks (model_textures_test.gd, ui_test.gd _texture_metal_look): a modeller's picture's
metal drawn as paint (looks.gd texture_metal). Run again only to change the fixtures."""
import json
import os
import struct
import zlib

FIXTURES = os.path.join(os.path.dirname(__file__), "..", "..", "client", "tests", "fixtures")


def png(rgb, size=4):
    """A size x size PNG of one colour (RGB 0-255)."""
    raw = b"".join(b"\x00" + bytes(rgb) * size for _ in range(size))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def box():
    pos, nrm, uv, idx = [], [], [], []
    y0, y1 = 0.0, 1.0
    faces = [((0, 1, 0), [(-.5, y1, -.5), (.5, y1, -.5), (.5, y1, .5), (-.5, y1, .5)]),
             ((0, -1, 0), [(-.5, y0, .5), (.5, y0, .5), (.5, y0, -.5), (-.5, y0, -.5)]),
             ((0, 0, 1), [(-.5, y0, .5), (-.5, y1, .5), (.5, y1, .5), (.5, y0, .5)]),
             ((0, 0, -1), [(.5, y0, -.5), (.5, y1, -.5), (-.5, y1, -.5), (-.5, y0, -.5)]),
             ((1, 0, 0), [(.5, y0, .5), (.5, y1, .5), (.5, y1, -.5), (.5, y0, -.5)]),
             ((-1, 0, 0), [(-.5, y0, -.5), (-.5, y1, -.5), (-.5, y1, .5), (-.5, y0, .5)])]
    for n, quad in faces:
        b = len(pos)
        for p, t in zip(quad, [(0, 1), (0, 0), (1, 0), (1, 1)]):
            pos.append(p)
            nrm.append(n)
            uv.append(t)
        idx += [b, b + 2, b + 1, b, b + 3, b + 2]
    return pos, nrm, uv, idx


def write(path, metal):
    pos, nrm, uv, idx = box()
    blobs = [b"".join(struct.pack("<3f", *p) for p in pos), b"".join(struct.pack("<3f", *n) for n in nrm),
             b"".join(struct.pack("<2f", *t) for t in uv), b"".join(struct.pack("<I", i) for i in idx),
             png((128, 128, 128)), png((255, 153, 255 if metal else 0))]
    data = b""
    views = []
    for blob in blobs:
        views.append({"buffer": 0, "byteOffset": len(data), "byteLength": len(blob)})
        data += blob
        data += b"\x00" * (-len(data) % 4)
    n = len(pos)
    accessors = [
        {"bufferView": 0, "componentType": 5126, "count": n, "type": "VEC3",
         "min": [-.5, 0.0, -.5], "max": [.5, 1.0, .5]},
        {"bufferView": 1, "componentType": 5126, "count": n, "type": "VEC3"},
        {"bufferView": 2, "componentType": 5126, "count": n, "type": "VEC2"},
        {"bufferView": 3, "componentType": 5125, "count": len(idx), "type": "SCALAR"},
    ]
    doc = {
        "asset": {"version": "2.0", "generator": "tools/models/make_metal_fixture.py"},
        "scene": 0, "scenes": [{"nodes": [0]}],
        "nodes": [{"name": "body", "mesh": 0}],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2}, "indices": 3,
                                    "material": 0}]}],
        "materials": [{"name": "Metal" if metal else "Paint", "pbrMetallicRoughness": {
            "baseColorTexture": {"index": 0}, "metallicRoughnessTexture": {"index": 1},
            "metallicFactor": 1.0, "roughnessFactor": 1.0}}],
        "images": [{"bufferView": 4, "mimeType": "image/png"}, {"bufferView": 5, "mimeType": "image/png"}],
        "textures": [{"source": 0}, {"source": 1}],
        "buffers": [{"byteLength": len(data)}], "bufferViews": views, "accessors": accessors,
    }
    text = json.dumps(doc, separators=(",", ":")).encode()
    text += b" " * (-len(text) % 4)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(text) + 8 + len(data)))
        f.write(struct.pack("<II", len(text), 0x4E4F534A) + text)
        f.write(struct.pack("<II", len(data), 0x004E4942) + data)


if __name__ == "__main__":
    write(os.path.join(FIXTURES, "metal_box_paint.glb"), False)
    write(os.path.join(FIXTURES, "metal_box_metal.glb"), True)
