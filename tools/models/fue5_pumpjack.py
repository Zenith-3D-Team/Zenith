#!/usr/bin/env python3
"""Puts FUE5's pumpjack's oil outlet where Factorio's pumpjack has its output (owner's L8), on the
converted .glb.

    python tools/models/fue5_pumpjack.py

Run after `fue5.py pumpjack`; a file already done is left alone. Plain Python, no Blender.

Factorio's north-facing pumpjack puts its oil out at the north-east tile, northwards (its
output_fluid_box: positions {1, -1}, {1, 1}, {-1, 1}, {-1, -1} for north, east, south, west, read in
2.1.24). FUE5's model has its outlet (the red box and the flange) at the south-west tile, pointing
west: the mirror image of Factorio's base, so no quarter turn puts it right (each one leaves the
outlet on the right corner pointing the wrong way, or the wrong corner). Mirrored across the
north-west to south-east diagonal (x and z swapped, Godot's x east and z south) it is Factorio's
north layout, and turned with the entity (the client turns this one model to each direction) every
direction's outlet lands on Factorio's: north-east north, south-east east, south-west south,
north-west west. The walking beam then runs north-south facing north and east-west facing east;
Factorio's beam is drawn east-west in every direction, which one turned model can't do either way.

The swap is a reflection: normals are swapped the same way and every triangle's winding reversed, so
faces keep facing out. The occlusion baked per vertex (COLOR_0, bake_glb.py) goes with its vertex.
The result stays under FUE5's licence (CC BY-NC-SA 3.0, packs/fue5/README.md).
"""

import json
import os
import struct

import numpy as np

import packs

PATH = packs.fue5_path("pumpjack")
MARK = "zenith_transposed"


def read(path):
    b = open(path, "rb").read()
    n = struct.unpack("<I", b[12:16])[0]
    return json.loads(b[20:20 + n]), bytearray(b[20 + n + 8:])


def write(path, doc, blob):
    js = json.dumps(doc, separators=(",", ":")).encode()
    js += b" " * ((4 - len(js) % 4) % 4)
    blob = bytes(blob)
    blob += b"\0" * ((4 - len(blob) % 4) % 4)
    total = 12 + 8 + len(js) + 8 + len(blob)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total))
        f.write(struct.pack("<II", len(js), 0x4E4F534A) + js)
        f.write(struct.pack("<II", len(blob), 0x004E4942) + blob)


def view(doc, blob, i):
    """The accessor's data as a writable numpy array over the blob, and the accessor."""
    a = doc["accessors"][i]
    v = doc["bufferViews"][a["bufferView"]]
    k = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[a["type"]]
    dt = {5126: np.float32, 5125: np.uint32, 5123: np.uint16, 5121: np.uint8}[a["componentType"]]
    start = v.get("byteOffset", 0) + a.get("byteOffset", 0)
    stride = v.get("byteStride", 0)
    if stride and stride != k * np.dtype(dt).itemsize:
        raise SystemExit("interleaved buffers aren't handled")
    arr = np.frombuffer(blob, dt, a["count"] * k, start).reshape(-1, k)
    return arr, a


def transpose(doc, blob):
    for node in doc.get("nodes", []):
        t = node.get("translation", [0, 0, 0])
        if "rotation" in node or "matrix" in node or "scale" in node or t[0] != t[2]:
            raise SystemExit("a node with its own transform: transpose it too before using this")
    for mesh in doc["meshes"]:
        for prim in mesh["primitives"]:
            attrs = prim["attributes"]
            pos, acc = view(doc, blob, attrs["POSITION"])
            pos[:, [0, 2]] = pos[:, [2, 0]]
            if "min" in acc and "max" in acc:
                acc["min"] = [acc["min"][2], acc["min"][1], acc["min"][0]]
                acc["max"] = [acc["max"][2], acc["max"][1], acc["max"][0]]
            if "NORMAL" in attrs:
                nrm, _ = view(doc, blob, attrs["NORMAL"])
                nrm[:, [0, 2]] = nrm[:, [2, 0]]
            if "TANGENT" in attrs:
                tan, _ = view(doc, blob, attrs["TANGENT"])
                tan[:, [0, 2]] = tan[:, [2, 0]]
                tan[:, 3] = -tan[:, 3]
            if prim.get("mode", 4) != 4 or "indices" not in prim:
                raise SystemExit("only indexed triangle lists are handled")
            idx, _ = view(doc, blob, prim["indices"])
            tri = idx.reshape(-1, 3)
            tri[:, [1, 2]] = tri[:, [2, 1]]


def main():
    doc, blob = read(PATH)
    extras = doc.setdefault("asset", {}).setdefault("extras", {})
    if extras.get(MARK):
        print("pumpjack.glb: already done")
        return
    transpose(doc, blob)
    extras[MARK] = 1
    write(PATH, doc, blob)
    print("pumpjack.glb: outlet moved to Factorio's (x and z swapped)")


if __name__ == "__main__":
    main()
