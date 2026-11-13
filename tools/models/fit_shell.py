#!/usr/bin/env python3
"""Measures a dead stomper's shell from Factorio's picture (stomper-corpse-head.png, its first
frame) for gleba.py: its outline without the spikes, and where its knobs, pits, cracks and spikes
are. Writes tools/models/stomper_shell_data.py, numbers only, in tiles at stomper_scale 1 on
Factorio's screen (x right, u up, about the picture's middle).

    python tools/models/fit_shell.py [--debug OUT.png]

Plain Python: numpy and pillow. The picture is read from the player's install, never committed.
"""

import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE)))
import factorio_install  # noqa: E402

PICTURE = "data/space-age/graphics/entity/stomper/stomper-corpse-head.png"
FRAME = (398, 332)
PPT = 64.0   # pixels a tile at stomper_scale 1 (the picture is drawn at scale 0.5 * stomper_scale)
OUT = os.path.join(HERE, "stomper_shell_data.py")
BINS = 96


def filtered(a, f):
    return np.asarray(Image.fromarray((a * 255).astype(np.uint8)).filter(f), dtype=np.float64) / 255.0


def erode(m, k):
    return filtered(m.astype(float), ImageFilter.MinFilter(2 * k + 1)) > 0.5


def dilate(m, k):
    return filtered(m.astype(float), ImageFilter.MaxFilter(2 * k + 1)) > 0.5


def blur(a, r):
    return filtered(np.clip(a, 0, 1), ImageFilter.GaussianBlur(r))


def components(m):
    """[list of (row, col)] of the mask's 4-connected pieces."""
    seen = np.zeros(m.shape, bool)
    out = []
    for r, c in zip(*np.nonzero(m)):
        if seen[r, c]:
            continue
        stack, piece = [(r, c)], []
        seen[r, c] = True
        while stack:
            y, x = stack.pop()
            piece.append((y, x))
            for ny, nx in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
                if 0 <= ny < m.shape[0] and 0 <= nx < m.shape[1] and m[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    stack.append((ny, nx))
        out.append(piece)
    return out


def peaks(a, mask, radius, threshold):
    """Local maxima of `a` inside `mask`, strongest first, none nearer than `radius`."""
    ys, xs = np.nonzero(mask & (a > threshold))
    order = np.argsort(-a[ys, xs])
    kept = []
    for i in order:
        y, x = int(ys[i]), int(xs[i])
        if all((y - q[0]) ** 2 + (x - q[1]) ** 2 >= radius * radius for q in kept):
            kept.append((y, x))
    return kept


def main():
    path = os.path.join(factorio_install.install(), PICTURE)
    img = np.asarray(Image.open(path).convert("RGBA"), dtype=np.float64)[:FRAME[1], :FRAME[0]] / 255.0
    alpha, rgb = img[..., 3], img[..., :3]
    # As compare.py: what is black and see-through is the picture's baked-in shadow.
    solid = (alpha > 0.5) & ~((rgb.max(axis=2) <= 6 / 255) & (alpha < 0.97))
    biggest = max(components(solid), key=len)
    solid = np.zeros_like(solid)
    solid[tuple(np.array(biggest).T)] = True
    body = dilate(erode(solid, 9), 9) & solid
    ys, xs = np.nonzero(body)
    cy, cx = ys.mean(), xs.mean()

    def to_tiles(row, col):
        return ((col - FRAME[0] / 2) / PPT, (FRAME[1] / 2 - row) / PPT)

    # The outline: the body's furthest pixel per direction about its middle.
    radii = [0.0] * BINS
    edge = body & ~erode(body, 1)
    for y, x in zip(*np.nonzero(edge)):
        a = math.atan2(cy - y, x - cx) % (2 * math.pi)
        k = int(a / (2 * math.pi) * BINS) % BINS
        radii[k] = max(radii[k], math.hypot(x - cx, y - cy) / PPT)
    for k in range(BINS):
        if radii[k] == 0.0:
            radii[k] = radii[k - 1]
    radii = [(radii[k - 1] + 2 * radii[k] + radii[(k + 1) % BINS]) / 4 for k in range(BINS)]

    # Relief: light against its neighbourhood (Factorio's light comes from the top left).
    lum = rgb.mean(axis=2)
    inner = erode(body, 3)
    fine = blur(lum, 2) - blur(lum, 14)
    fine = np.where(inner, fine, 0.0)
    knobs = peaks(fine, inner, 11, 0.045)
    knob_rows = []
    for y, x in knobs:
        # Its radius: how far out the bright stays at more than half its peak, along four rays.
        reach = []
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            r = 1
            while r < 22 and 0 <= y + dy * r < FRAME[1] and 0 <= x + dx * r < FRAME[0] and fine[y + dy * r, x + dx * r] > fine[y, x] * 0.45:
                r += 1
            reach.append(r)
        knob_rows.append((*to_tiles(y, x), max(4, float(np.mean(reach))) / PPT, float(fine[y, x])))
    dark = blur(lum, 1.2) < 0.085
    dark &= erode(body, 5)
    pits, grooves = [], []
    for piece in components(dark):
        if len(piece) < 10:
            continue
        p = np.array(piece, dtype=float)
        spread = np.linalg.eigvalsh(np.cov(p.T))
        long_ = math.sqrt(max(spread[1], 0.01))
        wide = math.sqrt(max(spread[0], 0.01))
        if long_ < 2.2 * wide and len(piece) < 220:
            pits.append((*to_tiles(p[:, 0].mean(), p[:, 1].mean()), math.sqrt(len(piece) / math.pi) / PPT))
        else:
            # A crack: dots along it (they overlap into a groove), branches included.
            pts = [tuple(q) for q in p.tolist()]
            kept = []
            for q in pts[:: max(1, len(pts) // 600)]:
                if all((q[0] - k[0]) ** 2 + (q[1] - k[1]) ** 2 >= 25 for k in kept):
                    kept.append(q)
            grooves += [to_tiles(*q) for q in kept]

    spikes = []
    rest = solid & ~dilate(body, 1)
    for piece in components(rest):
        if len(piece) < 22:
            continue
        p = np.array(piece, dtype=float)
        d = np.hypot(p[:, 1] - cx, p[:, 0] - cy)
        tip, root = p[d.argmax()], p[d.argmin()]
        width = len(piece) / max(1.0, float(np.linalg.norm(tip - root)))
        spikes.append((*to_tiles(*root), *to_tiles(*tip), width / PPT))

    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write('"""A stomper shell, measured from Factorio\'s picture by fit_shell.py: numbers only, in tiles at\n'
                'stomper_scale 1 on Factorio\'s screen (x right, u up, about the picture\'s middle)."""\n\n')
        f.write("CENTRE = (%.4f, %.4f)\n" % to_tiles(cy, cx))
        f.write("OUTLINE = %s  # radius per direction, counter-clockwise from east\n" % [round(r, 4) for r in radii])
        for name, rows, note in (("KNOBS", knob_rows, "x, u, radius, brightness"), ("PITS", pits, "x, u, radius"),
                                 ("GROOVES", grooves, "x, u"), ("SPIKES", spikes, "root x, u, tip x, u, width")):
            f.write("%s = [  # %s\n" % (name, note))
            for row in rows:
                f.write("    (%s),\n" % ", ".join("%.3f" % v for v in row))
            f.write("]\n")
    print("outline %d, knobs %d, pits %d, groove dots %d, spikes %d -> %s" % (BINS, len(knob_rows), len(pits), len(grooves), len(spikes), OUT))
    if "--debug" in sys.argv:
        out = Image.fromarray((np.clip(rgb * alpha[..., None], 0, 1) * 255).astype(np.uint8)).resize((FRAME[0] * 3, FRAME[1] * 3))
        d = ImageDraw.Draw(out)

        def px(x, u):
            return ((x * PPT + FRAME[0] / 2) * 3, (FRAME[1] / 2 - u * PPT) * 3)
        for x, u, r, _ in knob_rows:
            a, b = px(x, u)
            d.ellipse([a - r * PPT * 3, b - r * PPT * 3, a + r * PPT * 3, b + r * PPT * 3], outline=(0, 255, 0))
        for x, u, r in pits:
            a, b = px(x, u)
            d.ellipse([a - r * PPT * 3, b - r * PPT * 3, a + r * PPT * 3, b + r * PPT * 3], outline=(255, 0, 0))
        for x, u in grooves:
            a, b = px(x, u)
            d.ellipse([a - 2, b - 2, a + 2, b + 2], fill=(255, 255, 0))
        for x0, u0, x1, u1, _ in spikes:
            d.line([px(x0, u0), px(x1, u1)], fill=(0, 200, 255), width=2)
        out.save(sys.argv[sys.argv.index("--debug") + 1])


if __name__ == "__main__":
    main()
