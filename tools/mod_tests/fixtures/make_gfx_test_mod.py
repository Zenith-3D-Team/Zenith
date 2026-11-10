#!/usr/bin/env python3
"""Draws the pictures of the fixture mod zenith-gfx-test (our own, simple shapes in loud colours,
so a test or a screenshot can tell them from anything Factorio has) and writes its files.

    python tools/mod_tests/fixtures/make_gfx_test_mod.py

Needs Pillow. The mod: an item with its icon, a tinted two-layer item, a 2x2 chest with its own
picture (and a shadow layer that must be left out), a floor tile with 4 variants, a decorative and
English names. tools/live_check.py --only modgfx puts it on the headless server; the client's
tests/mod_files_test.gd reads it as a folder and as a zip.
"""

import json
import os

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.join(HERE, "zenith-gfx-test")


def save(img, rel):
    path = os.path.join(MOD, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, optimize=True)


def icon(color, mark):
    img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse((4, 4, 59, 59), fill=color, outline=(20, 20, 20, 255), width=3)
    d.text((26, 22), mark, fill=(255, 255, 255, 255))
    return img


def main():
    save(icon((230, 0, 200, 255), "Z"), "graphics/icons/gizmo.png")
    save(icon((255, 255, 255, 255), "T"), "graphics/icons/tinted-base.png")
    mask = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    ImageDraw.Draw(mask).rectangle((8, 30, 56, 56), fill=(255, 255, 255, 255))
    save(mask, "graphics/icons/tinted-mask.png")
    save(icon((255, 140, 0, 255), "C"), "graphics/icons/crate.png")
    save(icon((0, 200, 255, 255), "F"), "graphics/icons/floor.png")
    # The chest: 2x2 tiles, drawn at scale 0.5 (64 px a tile) like Factorio's high-resolution
    # pictures, a little taller than its footprint.
    crate = Image.new("RGBA", (128, 160), (0, 0, 0, 0))
    d = ImageDraw.Draw(crate)
    d.rectangle((6, 34, 121, 153), fill=(255, 140, 0, 255), outline=(60, 30, 0, 255), width=4)
    d.polygon([(6, 34), (30, 8), (145 - 24, 8), (121, 34)], fill=(255, 200, 80, 255))
    for x in range(14, 120, 20):
        d.line((x, 40, x, 148), fill=(160, 70, 0, 255), width=4)
    save(crate, "graphics/entity/crate.png")
    shadow = Image.new("RGBA", (160, 96), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rectangle((20, 10, 150, 90), fill=(0, 0, 0, 160))
    save(shadow, "graphics/entity/crate-shadow.png")
    # The spinner: a 2x2 machine whose middle turns through 4 frames (red, green, blue, yellow
    # blades), on a still grey base, and a 2-frame white light it shows only while working.
    spin = Image.new("RGBA", (4 * 128, 128), (0, 0, 0, 0))
    d = ImageDraw.Draw(spin)
    for f, c in enumerate([(230, 0, 0), (0, 200, 0), (0, 60, 255), (255, 220, 0)]):
        ox = f * 128
        d.rectangle((ox + 8, 8, ox + 119, 119), fill=(110, 110, 110, 255), outline=(40, 40, 40, 255), width=4)
        d.pieslice((ox + 24, 24, ox + 103, 103), f * 90, f * 90 + 120, fill=c + (255,))
    save(spin, "graphics/entity/spinner.png")
    lamp = Image.new("RGBA", (2 * 32, 32), (0, 0, 0, 0))
    d = ImageDraw.Draw(lamp)
    d.ellipse((4, 4, 27, 27), fill=(255, 255, 255, 255))
    d.ellipse((36, 4, 59, 27), fill=(120, 255, 255, 255))
    save(lamp, "graphics/entity/spinner-lamp.png")
    # The floor: 4 material variants of one tile each, 64 px (scale 0.5).
    floor = Image.new("RGBA", (256, 64), (0, 0, 0, 255))
    d = ImageDraw.Draw(floor)
    for v, c in enumerate([(0, 200, 255), (0, 170, 230), (0, 140, 210), (40, 220, 255)]):
        d.rectangle((v * 64, 0, v * 64 + 63, 63), fill=c + (255,))
        d.rectangle((v * 64 + 8, 8, v * 64 + 55, 55), outline=(255, 255, 255, 255), width=3)
        d.line((v * 64 + 8, 8 + v * 12, v * 64 + 55, 8 + v * 12), fill=(0, 60, 120, 255), width=3)
    save(floor, "graphics/terrain/floor.png")
    # The decorative: 4 variations in a row, 64 px each.
    peb = Image.new("RGBA", (256, 64), (0, 0, 0, 0))
    d = ImageDraw.Draw(peb)
    for v in range(4):
        for k in range(3 + v):
            x, y = v * 64 + 10 + k * 11, 20 + (k * 17) % 30
            d.ellipse((x, y, x + 12, y + 9), fill=(255, 255, 0, 255), outline=(90, 90, 0, 255))
    save(peb, "graphics/decorative/pebbles.png")
    with open(os.path.join(MOD, "info.json"), "w", newline="\n") as f:
        json.dump({"name": "zenith-gfx-test", "version": "1.0.0", "title": "Zenith graphics test",
                   "author": "Zenith", "factorio_version": "2.1", "dependencies": ["base"],
                   "description": "Test fixture: an item, a chest, a tile and a decorative with their own pictures."},
                  f, indent=2)
        f.write("\n")
    print("wrote", MOD)


if __name__ == "__main__":
    main()
