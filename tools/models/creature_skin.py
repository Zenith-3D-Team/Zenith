#!/usr/bin/env python3
"""Skins for Nauvis's enemies: each vertex's colour sampled from Factorio's own sprites, in every
direction they are drawn from, in place of one colour per part.

    python tools/models/creature_skin.py                 # every family below: writes the .glb files
    python tools/models/creature_skin.py big-biter       # one family (its pose models too)
    python tools/models/creature_skin.py --check --debug DIR   # write nothing; sprite | skin pictures

part_colors.py gives each patch of a model one colour (its densest), which left the biter's plates,
the worm's ribs and the spawner's egg sacs flat. Here each triangle is coloured from the sprite's
pixels that land on it, from many pictures: the run's frames in its 16 directions with the model
posed as the client poses it at that frame (the legs by creature_gait.py's fitted walk), the worm
standing in its 16 attack directions, the corpses from their last dying frame in the directions of
their fall. Each picture is lined up on the model's silhouette (a nudge of up to ALIGN pixels), the
light Factorio painted in is divided out (part_colors.SHADE), and each triangle keeps the mean of
its samples less the furthest third (strays from parts that don't line up). Vertices take their
triangles' colours; ones no picture sees take their neighbours'.

Factorio draws a tier's carapace as mask layers, greyscale pictures each tinted by the tier's own
tint (enemy-constants.lua): two for biters and spitters, one for worms and spawners. So the
carapace isn't stored as a colour:
- `masks` (biters, spitters): mask 1's shade, mask 2's shade and how much mask 2 covers, per vertex;
  the client colours them with each tier's two tints (factorio_material.gdshaderinc skin_mode 1),
  every tier as Factorio draws it.
- `mask` (worms, spawners): the base colour as part colours, and the one mask's shade and cover in
  the vertex colour (COLOR_0's red: sqrt(shade / 4), green: cover; 8 bits are enough for those, not
  for the colour); the client lays the mask, tinted by the tier, over the colour (skin_mode 2).
The tints (each multiplied by its mask's own hue) go to client/data/creature_skins.json; the
shades and colours into the .glb (part_colors.write).

Plain Python: numpy, scipy, pillow, trimesh. The sprites are read from Factorio's install; only
numbers end up in the repo (--debug pictures show Factorio's sprites: keep them out of it).
"""

import json
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import creature_gait as cg  # noqa: E402
import creature_pose as cp  # noqa: E402
import creature_score as cs  # noqa: E402
import packs  # noqa: E402
import part_colors as pc  # noqa: E402
import turntable as tt  # noqa: E402
import turntable_anim as ta  # noqa: E402

SKINS_JSON = os.path.join(tt.REPO, "client", "data", "creature_skins.json")
ALIGN = 6           # pixels a picture may be nudged to line up with the model's silhouette
FACING = 0.25       # a triangle seen more edge-on than this isn't sampled
DROP = 0.33         # each triangle's furthest samples dropped
LUMA = np.array([0.2126, 0.7152, 0.0722])

# Family -> its walking or standing model, the tiers it is drawn for, the materials its masks colour.
FAMILIES = {
    "big-biter": {"mode": "masks", "materials": ["chitin_big"],
                  "tiers": ["small-biter", "medium-biter", "big-biter", "behemoth-biter"]},
    "big-spitter": {"mode": "masks", "materials": ["chitin_spitter"],
                    "tiers": ["small-spitter", "medium-spitter", "big-spitter", "behemoth-spitter"]},
    "big-worm-turret": {"mode": "mask", "materials": ["flesh_worm"],
                        "tiers": ["small-worm-turret", "medium-worm-turret", "big-worm-turret", "behemoth-worm-turret"]},
    "biter-spawner": {"mode": "mask", "materials": ["flesh_spawner_dome"],
                      "tiers": ["biter-spawner", "spitter-spawner"]},
}


def srgb_to_linear(c):
    return pc.srgb_to_linear(np.clip(c, 0.0, 1.0))


def tint_of(t):
    if t is None:
        return np.array([1.0, 1.0, 1.0, 1.0])
    if isinstance(t, dict):
        t = [t.get("r", 0), t.get("g", 0), t.get("b", 0), t.get("a", 1)]
    t = list(t) + [1.0] * (4 - len(t))
    t = np.array(t[:4], float)
    if t[:3].max() > 1.0:
        t[:3] /= 255.0
    return t


# --------------------------------------------------------------------------------------- pictures

def views(family, raw):
    """[(model, animation, frame, direction, pose)] pictures to sample each model from: pose is
    (walk params, phase) for a walking model, None for one drawn as it is."""
    u, c, t, s = raw["unit"], raw["corpse"], raw["turret"], raw["unit-spawner"]
    out = []
    if family in ("big-biter", "big-spitter"):
        fam = family.split("-")[1]
        run = u[family]["run_animation"]
        knees = json.load(open(os.path.join(ta.OUT, family + "_knees.json")))["x"]
        for f in range(0, cs.frame_count(run), 2):
            for d in range(cs.direction_count(run)):
                out.append((family, run, f, d, (np.array(knees), 2 * math.pi * f / cs.frame_count(run))))
        die = c["big-%s-corpse" % fam]["animation"]
        last = cs.frame_count(die) - 1
        for v in range(cp.CORPSE_VARIANTS):
            model = cp.corpse_model("big-%s-corpse" % fam, v)
            for d in range(v, 16, cp.CORPSE_VARIANTS):
                out.append((model, die, last, d, None))
    elif family == "big-worm-turret":
        attack = t[family]["starting_attack_animation"]
        for d in range(cs.direction_count(attack)):
            out.append((family, attack, 0, d, None))
        die = c["big-worm-corpse"]["animation"]
        out.append(("big-worm-turret-corpse", die, cs.frame_count(die) - 1, 0, None))
    elif family == "biter-spawner":
        idle = s[family]["graphics_set"]["animations"]
        out.append((family, idle, 0, 0, None))
        if "biter-spawner-corpse" in c:
            die = c["biter-spawner-corpse"]["animation"]
            out.append(("biter-spawner-corpse", die, cs.frame_count(die) - 1, 0, None))
    return out


def layers_of(anim, d, f):
    """The frame's drawn layers split as Factorio draws them: (base layers, mask layers in order)."""
    base, masks = [], []
    for ly in cs.frame_layers(anim, d, f):
        (masks if "mask" in os.path.basename(ly["file"]) else base).append(ly)
    return base, masks


def mask_tints(anim):
    """The tints of an animation's mask layers, in their order."""
    return [tint_of(ly.get("tint")) for ly in cs._layers(anim) if "mask" in os.path.basename(cs._file(ly.get("filename") or
            (ly.get("filenames") or [""])[0] or (ly.get("stripes") or [{}])[0].get("filename", "")))]


# --------------------------------------------------------------------------------------- sampling

class Skin:
    """One model's triangles (part_colors.Model) and the samples gathered for them."""

    def __init__(self, name):
        self.name = name
        self.glb = pc.Glb(packs.model_path(name))
        self.model = pc.Model(self.glb)
        m = self.model
        self.rest = m.tris.copy()
        self.T = len(m.tris)
        self.samples = []  # (tri, weight, base rgb (3), m1, a1, m2, a2)
        self.fits = []

    def posed(self, pose, family):
        """The triangles as the client draws them for this picture."""
        if pose is None:
            return self.rest
        x, phase = pose
        rig = cg.WalkRig(family, cg.groups_of(ta.RIGS[family]))
        flat = self.rest.reshape(-1, 3)
        uv = self.model.uv.reshape(-1, 2)
        x = x.copy()
        x[4] = rig.stand(flat, uv, x)
        return rig.pose(flat, uv, x, phase).reshape(-1, 3, 3)

    def sample(self, tris, anim, f, d, ndirs, turn=None):
        cam = tt.Camera(anchor=0.0, size=tt.CANVAS)
        phi = 2 * math.pi * (d if turn is None else turn) / ndirs
        _mask, _rgb, fid = tt.render(tris, np.full((self.T, 3), 0.5), cam, phi)
        base_l, mask_l = layers_of(anim, d, f)
        canvas = tt.frame_canvas(base_l + mask_l)
        base = tt.frame_canvas(base_l)
        masks = [tt.frame_canvas([ly]) for ly in mask_l]
        best, dx, dy = align(fid >= 0, canvas[..., 3] > 0.5)
        fid = np.roll(np.roll(fid, dy, 0), dx, 1)
        from scipy import ndimage
        inner = ndimage.binary_erosion(fid >= 0, iterations=1)
        ok = inner & (canvas[..., 3] > 0.9)
        # The world normal of each triangle as drawn, turned with the model, for Factorio's light.
        e1 = tris[:, 1] - tris[:, 0]
        e2 = tris[:, 2] - tris[:, 0]
        n = np.cross(e1, e2)
        flip = np.einsum("ij,ij->i", np.cross(self.rest[:, 1] - self.rest[:, 0], self.rest[:, 2] - self.rest[:, 0]),
                         self.model.normal) < 0
        n[flip] *= -1
        n /= np.maximum(np.linalg.norm(n, axis=1), 1e-12)[:, None]
        c, s = math.cos(phi), math.sin(phi)
        nw = np.stack([n[:, 0] * c - n[:, 2] * s, n[:, 1], n[:, 0] * s + n[:, 2] * c], axis=1)
        facing = nw @ pc.VIEW
        t = fid[ok]
        keep = facing[t] > FACING
        ys, xs = np.nonzero(ok)
        ys, xs, t = ys[keep], xs[keep], t[keep]
        light = pc.shade(nw[t])
        b = srgb_to_linear(base[ys, xs, :3]) / light[:, None]
        cols = [np.zeros(len(t))] * 4
        for k, mk in enumerate(masks[:2]):
            lum = (srgb_to_linear(mk[ys, xs, :3]) @ LUMA) / light
            cols[2 * k] = lum
            cols[2 * k + 1] = mk[ys, xs, 3]
        hue = [srgb_to_linear(mk[ys, xs, :3]) for mk in masks[:2]]
        self.samples.append((t, facing[t] ** 2, b, cols[0], cols[1], cols[2], cols[3], hue))
        self.fits.append(best)

    def gather(self):
        """Per triangle: (base rgb, m1, a1, m2, a2), the mean of its samples less the furthest; a
        mask's shade is its mean where it covers."""
        t = np.concatenate([s[0] for s in self.samples])
        w = np.concatenate([s[1] for s in self.samples])
        b = np.concatenate([s[2] for s in self.samples])
        m = np.stack([np.concatenate([s[k] for s in self.samples]) for k in range(3, 7)], axis=1)
        m[:, 0] *= m[:, 1]  # shades times their cover, divided back out below
        m[:, 2] *= m[:, 3]
        vals = np.concatenate([b, m], axis=1)
        out = np.zeros((self.T, 7))
        wsum = np.bincount(t, w, self.T)
        for k in range(7):
            out[:, k] = np.bincount(t, w * vals[:, k], self.T)
        mean = out / np.maximum(wsum, 1e-9)[:, None]
        # The furthest third of each triangle's samples (by colour) left out, then the mean again.
        dist = np.linalg.norm(vals[:, :3] - mean[t, :3], axis=1) + np.abs(vals[:, 3] - mean[t, 3])
        order = np.lexsort((dist, t))
        rank = np.empty(len(t))
        counts = np.bincount(t, minlength=self.T)
        starts = np.r_[0, np.cumsum(counts)[:-1]]
        rank[order] = np.arange(len(t)) - starts[t[order]]
        keep = rank < np.maximum(1, np.ceil(counts[t] * (1 - DROP)))
        wsum = np.bincount(t[keep], w[keep], self.T)
        for k in range(7):
            out[:, k] = np.bincount(t[keep], w[keep] * vals[keep, k], self.T)
        out /= np.maximum(wsum, 1e-9)[:, None]
        for k in (3, 5):
            covered = out[:, k + 1] > 1e-4
            out[:, k] = np.where(covered, out[:, k] / np.maximum(out[:, k + 1], 1e-4), 0.0)
        self.seen = wsum > 0
        self.values = out
        return out

    def hues(self):
        """Each mask's own colour per unit of its shade (linear), over the pixels it covers."""
        out = []
        for k in range(2):
            num, den = np.zeros(3), 0.0
            for s in self.samples:
                h = s[7][k] if k < len(s[7]) else None
                if h is None or len(h) == 0:
                    continue
                a = s[4 if k == 0 else 6]
                cover = a > 0.8
                num += h[cover].sum(axis=0)
                den += float((h[cover] @ LUMA).sum())
            out.append(num / den if den > 0 else np.ones(3))
        return out


def align(model, sprite, r=ALIGN):
    """(IoU, dx, dy): the nudge of up to r pixels that lines the model's silhouette up with the
    sprite's best (turntable.best_shift_iou, on the pictures' bounding box only)."""
    both = model | sprite
    ys, xs = np.nonzero(both)
    if len(ys) == 0:
        return 0.0, 0, 0
    y0, y1 = max(ys.min() - r - 1, 0), min(ys.max() + r + 2, both.shape[0])
    x0, x1 = max(xs.min() - r - 1, 0), min(xs.max() + r + 2, both.shape[1])
    m, s = model[y0:y1, x0:x1], sprite[y0:y1, x0:x1]
    best = (tt.iou(m, s), 0, 0)
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            v = tt.iou(np.roll(np.roll(m, dy, 0), dx, 1), s)
            if v > best[0]:
                best = (v, dx, dy)
    return best


def vertex_field(model, values, seen, materials_of):
    """(T, 3, k) values per corner: each vertex the mean of its seen triangles of the same material
    (by position, so material seams keep their own colours); unseen vertices from their
    neighbours."""
    T = len(model.tris)
    flat = model.tris.reshape(-1, 3)
    mat = np.repeat(model.material, 3)
    keys = np.concatenate([np.round(flat / 1e-4).astype(np.int64), mat[:, None]], axis=1)
    _, vid = np.unique(keys, axis=0, return_inverse=True)
    vid = vid.reshape(-1)
    V = vid.max() + 1
    k = values.shape[1]
    area = model.area
    wt = np.repeat(np.where(seen, area, 0.0), 3)
    acc = np.zeros((V, k))
    for j in range(k):
        acc[:, j] = np.bincount(vid, wt * np.repeat(values[:, j], 3), V)
    wv = np.bincount(vid, wt, V)
    known = wv > 0
    field = acc / np.maximum(wv, 1e-12)[:, None]
    # Edges between vertices (within a material), for filling and smoothing.
    tri_v = vid.reshape(-1, 3)
    a = np.concatenate([tri_v[:, 0], tri_v[:, 1], tri_v[:, 2]])
    b = np.concatenate([tri_v[:, 1], tri_v[:, 2], tri_v[:, 0]])
    from scipy.sparse import coo_matrix
    adj = coo_matrix((np.ones(len(a) * 2), (np.r_[a, b], np.r_[b, a])), shape=(V, V)).tocsr()
    adj.data[:] = 1.0
    filled = known.copy()
    for _ in range(400):
        if filled.all():
            break
        cnt = adj @ filled.astype(float)
        sm = adj @ (field * filled[:, None])
        grow = (~filled) & (cnt > 0)
        if not grow.any():
            break
        field[grow] = sm[grow] / cnt[grow][:, None]
        filled |= grow
    # A light smoothing over neighbours: samples a pixel or two off don't speckle.
    deg = np.asarray(adj.sum(axis=1)).ravel()
    for _ in range(2):
        field = 0.6 * field + 0.4 * (adj @ field) / np.maximum(deg, 1)[:, None]
    return field[vid].reshape(T, 3, k), filled[vid].reshape(T, 3)


# --------------------------------------------------------------------------------------- families

def tier_tints(raw, family):
    """{tier: [mask tints in order]} from the tiers' prototypes (the animation the family samples)."""
    out = {}
    spec = FAMILIES[family]
    for tier in spec["tiers"]:
        if family in ("big-biter", "big-spitter"):
            anim = raw["unit"][tier]["run_animation"]
        elif family == "big-worm-turret":
            anim = raw["turret"][tier]["starting_attack_animation"]
        else:
            anim = raw["unit-spawner"][tier]["graphics_set"]["animations"]
        out[tier] = mask_tints(anim)
    return out


def composite(values, tints):
    """Factorio's colour from base and masks (linear, approximately: its tints multiply sRGB)."""
    col = values[..., 0:3].copy()
    for k, t in enumerate(tints[:2]):
        shade, cover = values[..., 3 + 2 * k], values[..., 4 + 2 * k]
        tinted = shade[..., None] * srgb_to_linear(t[:3]) * HUES[k]
        a = np.clip(cover * t[3], 0.0, 1.0)[..., None]
        col = col * (1 - a) + tinted * a
    return col


HUES = [np.ones(3), np.ones(3)]


def grade(rgb):
    """part_colors' grading of sampled colours (its exposure, saturation and knee)."""
    flat = rgb.reshape(-1, 3)
    return pc.expose(pc.saturate(flat)).reshape(rgb.shape)


def run_family(family, raw, check=False, debug=None):
    spec = FAMILIES[family]
    skins = {}
    for model, anim, f, d, pose in views(family, raw):
        if not os.path.exists(packs.model_path(model)):
            continue
        sk = skins.get(model) or Skin(model)
        skins[model] = sk
        tris = sk.posed(pose, family)
        nd = cs.direction_count(anim)
        if nd > 1:
            sk.sample(tris, anim, f, d, nd)
        else:
            # One picture (a worm's or spawner's corpse): the model as the client draws it, unturned.
            sk.sample(tris, anim, f, d, 16, turn=0)
    tints = tier_tints(raw, family)
    main = skins[family]
    main.gather()
    global HUES
    HUES = main.hues()
    entry = {"mode": spec["mode"], "materials": spec["materials"], "tiers": {}}
    for tier, ts in tints.items():
        # Each tier's tints times its mask's own hue (linear); a one-mask family's cover in the second's alpha.
        t1 = srgb_to_linear(ts[0][:3]) * HUES[0]
        if spec["mode"] == "masks":
            t2, a2 = srgb_to_linear(ts[1][:3]) * HUES[1], float(ts[1][3])
        else:
            t2, a2 = np.zeros(3), float(ts[0][3])
        entry["tiers"][tier] = [[round(float(v), 4) for v in t1] + [1.0], [round(float(v), 4) for v in t2] + [a2]]
    for name, sk in skins.items():
        vals = sk.values if name == family else sk.gather()
        mats = [sk.model.material_names.index(m) for m in spec["materials"] if m in sk.model.material_names]
        masked = np.isin(sk.model.material, mats)
        store = grade(vals[:, 0:3])
        extra = None
        if spec["mode"] == "masks":
            # The carapace: (mask 1, mask 2, mask 2's cover); the rest its base colour.
            store[masked] = np.stack([vals[masked, 3] * pc.EXPOSURE, vals[masked, 5] * pc.EXPOSURE,
                                      vals[masked, 6]], axis=1)
        else:
            # The colour under the mask stays a colour; the mask's shade and cover go to COLOR_0.
            extra = np.stack([vals[:, 3] * pc.EXPOSURE, vals[:, 4], np.zeros(len(vals))], axis=1)
            extra[~masked] = 0.0
        corners, filled = vertex_field(sk.model, store, sk.seen, None)
        extra_corners = vertex_field(sk.model, extra, sk.seen, None)[0] if extra is not None else None
        seen = float(sk.seen.mean())
        print("%-28s %4d pictures, fit %.2f-%.2f, %3.0f%% of triangles seen" % (
            name, len(sk.fits), min(sk.fits), max(sk.fits), seen * 100))
        if debug:
            debug_image(sk, corners, masked, spec, tints, debug, extra_corners)
        if not check:
            owed = np.ones(sk.model.n_patches)
            colour = np.zeros((sk.model.n_patches, 3))
            np.add.at(colour, sk.model.patch, corners.mean(axis=1))
            colour /= np.maximum(np.bincount(sk.model.patch, minlength=sk.model.n_patches), 1)[:, None]
            # part_colors.write divides by COLOR_0's rgb (a nature model's shading): here that is the
            # mask's data, so as 1.
            sk.model.tint[:] = 1.0
            pc.write(sk.model, colour, owed, corners)
            write_mask_colour(sk.glb.path, extra_corners)
    # The attack models are the walking model posed: the same triangles in the same order.
    for pose_model in (family.replace("big-", "big-") + "-attack",):
        path = packs.model_path(pose_model)
        if family not in ("big-biter", "big-spitter") or not os.path.exists(path):
            continue
        sk = Skin(pose_model)
        if sk.T != main.T or not np.array_equal(sk.model.material, main.model.material):
            print("%s: triangles differ from %s, left as it is" % (pose_model, family))
            continue
        if not check:
            corners = _corners_of(main)
            owed = np.ones(sk.model.n_patches)
            colour = np.zeros((sk.model.n_patches, 3))
            np.add.at(colour, sk.model.patch, corners.mean(axis=1))
            colour /= np.maximum(np.bincount(sk.model.patch, minlength=sk.model.n_patches), 1)[:, None]
            pc.write(sk.model, colour, owed, corners)
            print("%-28s skin copied from %s" % (pose_model, family))
    return entry


def write_mask_colour(path, corners):
    """COLOR_0's rgb: (sqrt(shade / 4), cover, 0) of the mask per vertex where `corners` has it
    (factorio_material.gdshaderinc skin_mode 2), 1 elsewhere (and everywhere without them); the
    occlusion in its alpha kept. The client reads a masked material's (1, 1, 1) as no mask: it takes
    the blue off red and green (read as it was, shade 4 under full cover, it glowed in the tier's
    colour: --creature-glow=old)."""
    g = pc.Glb(path)
    m = pc.Model(g)
    for k, (_mi, _pi, prim) in enumerate(m.prims):
        attrs = prim["attributes"]
        if "COLOR_0" not in attrs:
            continue
        col = g.accessor(attrs["COLOR_0"])
        if col.shape[1] < 4:
            continue
        col[:, :3] = 1.0
        if corners is not None:
            sel = np.nonzero(m.prim_of == k)[0]
            acc = np.zeros((len(col), 2))
            hits = np.zeros(len(col))
            for c in range(3):
                np.add.at(acc, m.corner_vert[sel, c], corners[sel, c, :2])
                np.add.at(hits, m.corner_vert[sel, c], 1.0)
            v = acc / np.maximum(hits, 1)[:, None]
            on = (hits > 0) & (v[:, 1] > 1e-3)
            col[on, 0] = np.sqrt(np.clip(v[on, 0] / 4.0, 0.0, 1.0))
            col[on, 1] = np.clip(v[on, 1], 0.0, 1.0)
            col[on, 2] = 0.0
        g.overwrite(attrs["COLOR_0"], col)
    g.save()


def _corners_of(sk):
    """The per-corner stored values a model was just written with (read back from its .glb)."""
    g = pc.Glb(sk.glb.path)
    m = pc.Model(g)
    out = np.zeros((m.T if hasattr(m, "T") else len(m.tris), 3, 3))
    for k, (_mi, _pi, prim) in enumerate(m.prims):
        sel = np.nonzero(m.prim_of == k)[0]
        a = g.accessor(prim["attributes"]["TEXCOORD_4"])
        b = g.accessor(prim["attributes"]["TEXCOORD_5"])
        rgb = np.concatenate([a, b[:, :1]], axis=1) * pc.RANGE
        out[sel] = rgb[m.corner_vert[sel]]
    return out


def debug_image(sk, corners, masked, spec, tints, out_dir, extra=None):
    """The model's skin from Factorio's camera (four directions, each tier's look for a masked
    family) beside the sprite's pictures, relit as part_colors' debug pictures are."""
    from PIL import Image
    os.makedirs(out_dir, exist_ok=True)
    cam = tt.Camera(anchor=0.0, size=tt.CANVAS)
    looks = spec["tiers"]
    rows = []
    for tier in looks:
        tile = []
        col = corners.mean(axis=1)
        ts = tints[tier]
        t1 = srgb_to_linear(ts[0][:3]) * HUES[0]
        if spec["mode"] == "masks":
            t2 = srgb_to_linear(ts[1][:3]) * HUES[1]
            a = np.clip(col[:, 2] * ts[1][3], 0, 1)[:, None]
            mixed = col[:, 0:1] * t1 * (1 - a) + col[:, 1:2] * t2 * a
            col = np.where(masked[:, None], mixed, col)
        elif extra is not None:
            e = extra.mean(axis=1)
            a = np.clip(e[:, 1] * ts[0][3], 0, 1)[:, None]
            col = col * (1 - a) + e[:, 0:1] * t1 * a
        for d in (0, 4, 8, 12):
            phi = 2 * math.pi * d / 16
            _m, _rgb, fid = tt.render(sk.rest, np.full((sk.T, 3), 0.5), cam, phi)
            img = np.full((tt.CANVAS, tt.CANVAS, 3), 0.3)
            on = fid >= 0
            n = sk.model.normal
            c, s = math.cos(phi), math.sin(phi)
            nw = np.stack([n[:, 0] * c - n[:, 2] * s, n[:, 1], n[:, 0] * s + n[:, 2] * c], axis=1)
            lit = col[fid[on]] * (pc.shade(nw[fid[on]]) / pc.shade(np.array([0.0, 1.0, 0.0])))[:, None]
            img[on] = pc.linear_to_srgb(lit)
            h = tt.CANVAS // 2
            tile.append(img[h - 220:h + 120, h - 220:h + 220])
        rows.append(np.concatenate(tile, axis=1))
    Image.fromarray((np.clip(np.concatenate(rows, axis=0), 0, 1) * 255).astype(np.uint8)).save(
        os.path.join(out_dir, sk.name + "_skin.png"))


def main(argv):
    check = "--check" in argv
    debug = None
    if "--debug" in argv:
        debug = argv[argv.index("--debug") + 1]
    names = [a for a in argv if not a.startswith("--") and a != debug] or list(FAMILIES)
    raw = cs.data_raw()
    table = json.load(open(SKINS_JSON, encoding="utf-8")) if os.path.exists(SKINS_JSON) else {}
    for family in names:
        table[family] = run_family(family, raw, check, debug)
    if not check:
        with open(SKINS_JSON, "w", encoding="utf-8", newline="\n") as f:
            f.write("{\n" + ",\n".join("  %s: %s" % (json.dumps(k), json.dumps(table[k], separators=(", ", ": ")))
                                       for k in sorted(table)) + "\n}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
