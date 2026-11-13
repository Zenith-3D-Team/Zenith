"""Patches the rail models' .glb files in place for what made them flicker far away and sparkle under lamps, without a
Blender rebuild (rails.py builds the same since): the light ballast stones lifted clear of the bed (their tops met the
bed's within millimetres) and nearer the bed's colour, the tie-plate bolts and the rails rougher (tiny shiny parts
caught highlights smaller than a pixel). Every model with those materials: straight, half-diagonal and curved rails,
their -ne turns and the elevated ones.

python tools/models/patch_rail_stones.py [--dry-run]
"""
import json
import pathlib
import struct
import sys

MODELS = pathlib.Path(__file__).resolve().parents[2] / "client" / "assets" / "models"
LIFT = 0.012  # tiles the light stones go up
COLOR = {"stone_ballast_light": [0.230, 0.195, 0.147, 1.0]}  # linear (rails.py #847a6b); the bed is 0.156, 0.117, 0.074
ROUGH = {"steel_light": 0.7, "steel_rail": 0.55}


def patch(path, dry):
    b = bytearray(path.read_bytes())
    magic, version, _ = struct.unpack("<III", b[:12])
    assert magic == 0x46546C67, path
    jlen, jtype = struct.unpack("<II", b[12:20])
    j = json.loads(b[20:20 + jlen])
    bin_start = 20 + jlen + 8
    names = [m.get("name") for m in j.get("materials", [])]
    if "stone_ballast_light" not in names:
        return False
    done = []
    for i, m in enumerate(j["materials"]):
        pbr = m.setdefault("pbrMetallicRoughness", {})
        if m.get("name") in COLOR:
            pbr["baseColorFactor"] = COLOR[m["name"]]
            done.append("colour " + m["name"])
        if m.get("name") in ROUGH:
            pbr["roughnessFactor"] = ROUGH[m["name"]]
            done.append("rough " + m["name"])
    light = names.index("stone_ballast_light")
    lifted = set()
    for mesh in j["meshes"]:
        for prim in mesh["primitives"]:
            if prim.get("material") != light:
                continue
            acc_i = prim["attributes"]["POSITION"]
            if acc_i in lifted:
                continue
            lifted.add(acc_i)
            acc = j["accessors"][acc_i]
            view = j["bufferViews"][acc["bufferView"]]
            stride = view.get("byteStride", 12)
            base = bin_start + view.get("byteOffset", 0) + acc.get("byteOffset", 0)
            for k in range(acc["count"]):
                o = base + k * stride + 4  # y
                y = struct.unpack_from("<f", b, o)[0]
                struct.pack_into("<f", b, o, y + LIFT)
            acc["min"][1] += LIFT
            acc["max"][1] += LIFT
            done.append("lifted %d stone vertices" % acc["count"])
    text = json.dumps(j, separators=(",", ":")).encode()
    text += b" " * ((4 - len(text) % 4) % 4)
    out = bytearray(struct.pack("<III", magic, version, 0)) + struct.pack("<II", len(text), jtype) + text + b[20 + jlen:]
    struct.pack_into("<I", out, 8, len(out))
    print(path.name, "; ".join(done))
    if not dry:
        path.write_bytes(bytes(out))
    return True


if __name__ == "__main__":
    dry = "--dry-run" in sys.argv
    n = sum(patch(p, dry) for p in sorted(MODELS.glob("*rail*.glb")))
    print(n, "models", "(dry run)" if dry else "patched")
