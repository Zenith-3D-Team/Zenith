#!/usr/bin/env python3
"""client/tests/fixtures/pbr_ref/: the standard PBR reference set (pbr-standard step 1). One-tile spheres, plates
and a tube, one per .glb, each testing one glTF material input the way a modeller's pack ("shading": "pbr") uses
it. model_textures_test.gd (_pbr_reference) loads every one through ModelLibrary and checks the shader parameters
each must set; ui_test.gd (_pbr_reference, in a window) draws each through Zenith and through Godot's own
StandardMaterial3D at the same place and compares the pictures. Our own geometry and 4-pixel pictures, no outside
assets. The folder has a .gdignore: Godot doesn't import them, the tests read them as files. Run again only to
change the set:
    python tools/models/make_pbr_reference.py
"""
import json
import math
import os
import struct
import zlib

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "client", "tests", "fixtures", "pbr_ref")
ROUGHS = [0.1, 0.3, 0.5, 0.7, 1.0]
GREY = 0.5  # the spheres' base colour (linear), factor or picture


def png(pixels, w, h, alpha=False):
    """A w x h PNG from rows of (r, g, b[, a]) 0-255 pixels, top row first."""
    raw = b""
    for y in range(h):
        raw += b"\x00" + b"".join(bytes(p[:4] if alpha else p[:3]) for p in pixels[y * w:(y + 1) * w])

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6 if alpha else 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def flat(rgb, size=4, alpha=False):
    return png([rgb] * size * size, size, size, alpha)


def sphere(r=0.4, cy=0.45, seg=16, rings=10):
    pos, nrm, uv, idx = [], [], [], []
    for j in range(rings + 1):
        v = j / rings
        th = v * math.pi
        for i in range(seg + 1):
            u = i / seg
            ph = u * 2.0 * math.pi
            n = (math.sin(th) * math.cos(ph), math.cos(th), -math.sin(th) * math.sin(ph))
            pos.append((n[0] * r, cy + n[1] * r, n[2] * r))
            nrm.append(n)
            uv.append((u, v))
    for j in range(rings):
        for i in range(seg):
            a = j * (seg + 1) + i
            b = a + seg + 1
            idx += [a, b, a + 1, a + 1, b, b + 1]
    return pos, nrm, uv, idx


def plate(size=0.8, y=0.05, uv_max=1.0, mirror=False):
    """A quad facing up; U runs east (+X) unless mirrored, V runs south (+Z, down the picture)."""
    h = size / 2.0
    pos = [(-h, y, -h), (h, y, -h), (h, y, h), (-h, y, h)]
    nrm = [(0.0, 1.0, 0.0)] * 4
    us = [uv_max, 0.0] if mirror else [0.0, uv_max]
    uv = [(us[0], 0.0), (us[1], 0.0), (us[1], uv_max), (us[0], uv_max)]
    return pos, nrm, uv, [0, 2, 1, 0, 3, 2]


def tube(r=0.35, h=0.8, seg=20):
    """An open cylinder (no caps): its inside shows from the game's camera only if back faces are drawn."""
    pos, nrm, uv, idx = [], [], [], []
    for i in range(seg + 1):
        u = i / seg
        a = u * 2.0 * math.pi
        n = (math.cos(a), 0.0, -math.sin(a))
        for y in (0.0, h):
            pos.append((n[0] * r, y, n[2] * r))
            nrm.append(n)
            uv.append((u, 1.0 - y / h))
    for i in range(seg):
        a = i * 2
        idx += [a, a + 2, a + 1, a + 1, a + 2, a + 3]
    return pos, nrm, uv, idx


def write(name, geo, material, images=(), samplers=None, textures=None, colors=None, uv1=None, extensions=()):
    pos, nrm, uv, idx = geo
    blobs = [b"".join(struct.pack("<3f", *p) for p in pos), b"".join(struct.pack("<3f", *n) for n in nrm),
             b"".join(struct.pack("<2f", *t) for t in uv), b"".join(struct.pack("<I", i) for i in idx)]
    attrs = {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2}
    n = len(pos)
    accessors = [
        {"bufferView": 0, "componentType": 5126, "count": n, "type": "VEC3",
         "min": [min(p[k] for p in pos) for k in range(3)], "max": [max(p[k] for p in pos) for k in range(3)]},
        {"bufferView": 1, "componentType": 5126, "count": n, "type": "VEC3"},
        {"bufferView": 2, "componentType": 5126, "count": n, "type": "VEC2"},
        {"bufferView": 3, "componentType": 5125, "count": len(idx), "type": "SCALAR"},
    ]
    if colors is not None:
        attrs["COLOR_0"] = len(accessors)
        accessors.append({"bufferView": len(blobs), "componentType": 5126, "count": n, "type": "VEC4"})
        blobs.append(b"".join(struct.pack("<4f", *c) for c in colors))
    if uv1 is not None:
        attrs["TEXCOORD_1"] = len(accessors)
        accessors.append({"bufferView": len(blobs), "componentType": 5126, "count": n, "type": "VEC2"})
        blobs.append(b"".join(struct.pack("<2f", *t) for t in uv1))
    first_image = len(blobs)
    blobs += list(images)
    data = b""
    views = []
    for blob in blobs:
        views.append({"buffer": 0, "byteOffset": len(data), "byteLength": len(blob)})
        data += blob
        data += b"\x00" * (-len(data) % 4)
    doc = {
        "asset": {"version": "2.0", "generator": "tools/models/make_pbr_reference.py"},
        "scene": 0, "scenes": [{"nodes": [0]}],
        "nodes": [{"name": "body", "mesh": 0}],
        "meshes": [{"primitives": [{"attributes": attrs, "indices": 3, "material": 0}]}],
        "materials": [material],
        "buffers": [{"byteLength": len(data)}], "bufferViews": views, "accessors": accessors,
    }
    if images:
        doc["images"] = [{"bufferView": first_image + k, "mimeType": "image/png"} for k in range(len(images))]
        doc["textures"] = textures if textures is not None else [{"source": k} for k in range(len(images))]
        if samplers:
            doc["samplers"] = samplers
    if extensions:
        doc["extensionsUsed"] = list(extensions)
    text = json.dumps(doc, separators=(",", ":")).encode()
    text += b" " * (-len(text) % 4)
    with open(os.path.join(OUT, name + ".glb"), "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(text) + 8 + len(data)))
        f.write(struct.pack("<II", len(text), 0x4E4F534A) + text)
        f.write(struct.pack("<II", len(data), 0x004E4942) + data)


def pbr(**kw):
    m = {"baseColorFactor": [GREY, GREY, GREY, 1.0]}
    m.update(kw)
    return m


def main():
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, ".gdignore"), "w") as f:
        f.write("")
    white = flat((255, 255, 255))
    sph = sphere()
    # 1, 2: metal 0 and 1 by roughness, as factors only, then as pictures with factors 1 (the same numbers).
    for metal in (0, 1):
        for r in ROUGHS:
            tag = "m%d_r%03d" % (metal, round(r * 100))
            write("factor_" + tag, sph, {"name": "factor-" + tag, "pbrMetallicRoughness": pbr(
                metallicFactor=float(metal), roughnessFactor=r)})
            write("picture_" + tag, sph, {"name": "picture-" + tag, "pbrMetallicRoughness": pbr(
                baseColorTexture={"index": 0}, metallicRoughnessTexture={"index": 1},
                metallicFactor=1.0, roughnessFactor=1.0)},
                images=[white, flat((255, round(r * 255), 255 * metal))])
    # 3: a grey sRGB 128 picture times a factor (0.5, 1, 1).
    write("base_tint", sph, {"name": "base-tint", "pbrMetallicRoughness": {
        "baseColorTexture": {"index": 0}, "baseColorFactor": [0.5, 1.0, 1.0, 1.0],
        "metallicFactor": 0.0, "roughnessFactor": 0.7}}, images=[flat((128, 128, 128))])
    # 4: normal maps on a plate: every texel leans towards +U (east): (0.7, 0, 0.72) in tangent space.
    lean = flat((217, 128, 219))
    for name, scale, mirror in [("normal_east", 1.0, False), ("normal_east_half", 0.5, False), ("normal_mirrored", 1.0, True)]:
        mat = {"name": name.replace("_", "-"), "pbrMetallicRoughness": {
            "baseColorTexture": {"index": 0}, "metallicFactor": 0.0, "roughnessFactor": 0.8},
            "normalTexture": {"index": 1}}
        if scale != 1.0:
            mat["normalTexture"]["scale"] = scale
        write(name, plate(mirror=mirror), mat, images=[flat((188, 188, 188)), lean])
    # 5: occlusion red 0.5, strength 1 and 0.5, packed in the metallic-roughness picture and separate.
    for packed in (True, False):
        for s in (1.0, 0.5):
            name = "occ_%s_s%02d" % ("packed" if packed else "separate", round(s * 10))
            mat = {"name": name.replace("_", "-"), "pbrMetallicRoughness": {
                "baseColorTexture": {"index": 0}, "metallicRoughnessTexture": {"index": 1},
                "metallicFactor": 1.0, "roughnessFactor": 1.0},
                "occlusionTexture": {"index": 1 if packed else 2}}
            if s != 1.0:
                mat["occlusionTexture"]["strength"] = s
            images = [white, flat((128, 178, 0))]
            if not packed:
                images[1] = flat((255, 178, 0))
                images.append(flat((128, 128, 128)))
            write(name, sph, mat, images=images)
    # 6: emission: a factor, a half-black picture, strength 2 by the extension.
    write("emit_factor", sph, {"name": "emit-factor", "pbrMetallicRoughness": {"baseColorTexture": {"index": 0},
        "metallicFactor": 0.0, "roughnessFactor": 0.7}, "emissiveFactor": [1.0, 0.5, 0.0]},
        images=[flat((60, 60, 60))])
    half = png([(255, 255, 255) if x < 2 else (0, 0, 0) for y in range(4) for x in range(4)], 4, 4)
    write("emit_half_black", sph, {"name": "emit-half-black", "pbrMetallicRoughness": {"baseColorTexture": {"index": 0},
        "metallicFactor": 0.0, "roughnessFactor": 0.7}, "emissiveFactor": [1.0, 1.0, 1.0],
        "emissiveTexture": {"index": 1}}, images=[flat((60, 60, 60)), half])
    write("emit_strength2", sph, {"name": "emit-strength2", "pbrMetallicRoughness": {"baseColorTexture": {"index": 0},
        "metallicFactor": 0.0, "roughnessFactor": 0.7}, "emissiveFactor": [1.0, 0.5, 0.0],
        "extensions": {"KHR_materials_emissive_strength": {"emissiveStrength": 2.0}}},
        images=[flat((60, 60, 60))], extensions=["KHR_materials_emissive_strength"])
    # 7: alpha: MASK across a gradient (left half kept at cutoff 0.5), BLEND at 0.5, an open tube double-sided.
    grad = png([(200, 120, 60, round(255 * (3 - x) / 3)) for y in range(4) for x in range(4)], 4, 4, alpha=True)
    write("alpha_mask", sph, {"name": "alpha-mask", "alphaMode": "MASK", "alphaCutoff": 0.5,
        "pbrMetallicRoughness": {"baseColorTexture": {"index": 0}, "metallicFactor": 0.0, "roughnessFactor": 0.7}},
        images=[grad])
    write("alpha_blend", sph, {"name": "alpha-blend", "alphaMode": "BLEND",
        "pbrMetallicRoughness": {"baseColorTexture": {"index": 0}, "metallicFactor": 0.0, "roughnessFactor": 0.7}},
        images=[flat((200, 120, 60, 128), alpha=True)])
    write("tube_double", tube(), {"name": "tube-double", "doubleSided": True,
        "pbrMetallicRoughness": {"baseColorTexture": {"index": 0}, "metallicFactor": 0.0, "roughnessFactor": 0.7}},
        images=[flat((188, 188, 188))])
    # 8: samplers: a 2-pixel checker as NEAREST, a CLAMP wrap over UVs to 2.
    checker = png([(230, 230, 230) if (x + y) % 2 == 0 else (30, 30, 30) for y in range(2) for x in range(2)], 2, 2)
    write("nearest_checker", plate(uv_max=4.0), {"name": "nearest-checker", "pbrMetallicRoughness": {
        "baseColorTexture": {"index": 0}, "metallicFactor": 0.0, "roughnessFactor": 0.8}},
        images=[checker], samplers=[{"magFilter": 9728, "minFilter": 9728}], textures=[{"source": 0, "sampler": 0}])
    stripe = png([(230, 60, 60) if x < 2 else (60, 60, 230) for y in range(4) for x in range(4)], 4, 4)
    write("clamp", plate(uv_max=2.0), {"name": "clamp", "pbrMetallicRoughness": {
        "baseColorTexture": {"index": 0}, "metallicFactor": 0.0, "roughnessFactor": 0.8}},
        images=[stripe], samplers=[{"wrapS": 33071, "wrapT": 33071}], textures=[{"source": 0, "sampler": 0}])
    # 9: a texture transform on the base colour, one on the normal map only, occlusion on a second UV set, COLOR_0.
    tt = {"KHR_texture_transform": {"scale": [2.0, 2.0]}}
    write("uv_transform", plate(), {"name": "uv-transform", "pbrMetallicRoughness": {
        "baseColorTexture": {"index": 0, "extensions": tt}, "metallicFactor": 0.0, "roughnessFactor": 0.8}},
        images=[stripe], extensions=["KHR_texture_transform"])
    write("uv_transform_normal", plate(), {"name": "uv-transform-normal", "pbrMetallicRoughness": {
        "baseColorTexture": {"index": 0}, "metallicFactor": 0.0, "roughnessFactor": 0.8},
        "normalTexture": {"index": 1, "extensions": tt}}, images=[flat((188, 188, 188)), lean],
        extensions=["KHR_texture_transform"])
    p = plate()
    write("occ_uv1", p, {"name": "occ-uv1", "pbrMetallicRoughness": {"baseColorTexture": {"index": 0},
        "metallicFactor": 0.0, "roughnessFactor": 0.8}, "occlusionTexture": {"index": 1, "texCoord": 1}},
        images=[flat((188, 188, 188)), flat((128, 128, 128))], uv1=[(t[0] * 0.5, t[1] * 0.5) for t in p[2]])
    write("vertex_colors", sph, {"name": "vertex-colors", "pbrMetallicRoughness": {"baseColorTexture": {"index": 0},
        "metallicFactor": 0.0, "roughnessFactor": 0.7}}, images=[white],
        colors=[(0.2 + 0.8 * (q[0] + 0.4) / 0.8, 0.5, 1.0 - 0.8 * (q[0] + 0.4) / 0.8, 1.0) for q in sph[0]])


if __name__ == "__main__":
    main()
