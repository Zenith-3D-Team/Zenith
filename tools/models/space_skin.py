#!/usr/bin/env python3
"""Skins for Space Age's creatures: each vertex's colour sampled from Factorio's own pictures, as
creature_skin.py does for Nauvis's enemies.

    python tools/models/space_skin.py                    # every model below: writes the .glb files
    python tools/models/space_skin.py demolisher-head    # some of them
    python tools/models/space_skin.py --score            # colour scores against the sprites, nothing written
    python tools/models/space_skin.py --score --before DIR  # the same for the .glb files in DIR (older copies)
    python tools/models/space_skin.py --shots DIR [--before DIR2]   # sprite | before | after pictures

The models (creature_hull.py's measures, gleba.py, vulcanus.py) had one colour per patch from
part_colors.py, and the pentapods' legs their material's palette colour. Here every triangle is
coloured from the pixels that land on it, from every picture Factorio draws it with:

- demolishers' head, segment and tail: 32 of their 128 directions;
- strafers' and stompers' torsos (each tier its own model): 32 of their 64 directions, the legs left
  out (Factorio draws them as separate entities), the render lined up by its centre first (the
  torso floats at its bobbing height);
- their legs: Factorio draws each part (thigh, knee, shin, foot) as a picture stretched along the
  leg, 32 of them for the ways it lights it. So a leg's colour follows the picture down its length:
  each vertex takes the picture's row at its place along its part (top: the hip's end), the mean
  across the middle of the row over every lighting, Factorio's light divided out;
- the wriggler: its run's frames in its 16 directions, posed as the client poses it at that frame
  (creature_gait.py's fitted walk; the phase from art-src/turntable/anim, else searched); its strike
  pose (creature_pose.py, the same triangles) takes the same skin, its corpse its last dying frame's;
- the small Gleba spawner, the spawner's corpse and the stomper's shells: their one picture,
  unturned (as the client draws them), the shells at their true north-south length (stretch 1.346).
  Not the big spawner: its heap and sacs don't lie where the picture's do (its sacs are smaller and
  elsewhere, the heap under them), so its pixels coloured the heap with the dark cracks between the
  picture's sacs (dE 18.5 -> 23.5): it keeps part_colors.py's colour per patch.

Factorio tints these with `tint_as_overlay` (an overlay blend of the tint, not a multiply): a
near-grey on the main picture and the tier's colour on a mask layer over it, half or more
see-through. Every tier of a pentapod and a shell is its own model, so its own tints are blended
in here as Factorio blends them, and the colour stored. The wriggler is one model for its three
tiers (creature_models.gd ALIASES), so it keeps the mask as Factorio draws it: the colour under the
mask as part colours, the mask's shade and cover in COLOR_0 (skin_mode 2, as worms and spawners),
and each tier's tint fitted to what the overlay gives over the mask's pixels (an overlay of a dark
picture is about a multiply by twice the tint) into client/data/creature_skins.json. The others go
there too with mode "colour" (no tiers), so part_colors.py leaves them to this.

Light: Factorio's painted-in light (part_colors.SHADE) is divided out and the colours graded as
part_colors grades them. Each triangle keeps the mean of its samples less the furthest third.
Only numbers end up in the repo; --shots pictures show Factorio's sprites (keep them out of it).
Plain Python: numpy, scipy, pillow, trimesh.
"""

import json
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import creature_gait as cg  # noqa: E402
import creature_score as cs  # noqa: E402
import creature_skin as sk  # noqa: E402
import packs  # noqa: E402
import part_colors as pc  # noqa: E402
import turntable as tt  # noqa: E402
import turntable_anim as ta  # noqa: E402

SKINS_JSON = sk.SKINS_JSON
STRETCH = 1.346      # sprite_projection's stretch for the shells (1 / sin 48 degrees)
LEG_COLUMNS = 0.35   # a leg picture's row is read this far either side of its middle (share of its width)
LUMA = sk.LUMA
TIERS = ("small", "medium", "big")


def tint_of(t):
    """Factorio's colour (0-1, or 0-255 when any part is over 1, alpha too) as RGBA 0-1."""
    if t is None:
        return None
    if isinstance(t, dict):
        t = [t.get("r", 0), t.get("g", 0), t.get("b", 0), t.get("a", 1)]
    t = np.array(list(t) + [1.0] * (4 - len(t)), float)[:4]
    if t.max() > 1.0:
        t /= 255.0
    return t


def overlay(b, t):
    """Factorio's tint_as_overlay: an overlay blend of the tint over the picture (sRGB)."""
    return np.where(b < 0.5, 2.0 * b * t, 1.0 - 2.0 * (1.0 - b) * (1.0 - t))


def _src_file(ly):
    return cs._file(ly.get("filename") or (ly.get("filenames") or [""])[0]
                    or (ly.get("stripes") or [{}])[0].get("filename", ""))


def is_mask(ly):
    name = os.path.basename(_src_file(ly))
    return "mask" in name or "-tint-" in name


def drawn_layers(anim, d, f):
    """cs.frame_layers with each layer's tint, overlay and mask flags (same order)."""
    out = []
    for src, ly in zip(cs._layers(anim), cs.frame_layers(anim, d, f)):
        ly = dict(ly)
        ly["tint"] = tint_of(src.get("tint"))
        ly["overlay"] = bool(src.get("tint_as_overlay"))
        ly["mask"] = is_mask(src)
        out.append(ly)
    return out


def layer_picture(ly, tinted=True):
    """(rgb straight 0-1, alpha) of one layer on the canvas, tinted as Factorio tints it."""
    if not ly.get("scale"):
        return None
    c = tt.frame_canvas([ly])
    a = c[..., 3].copy()
    rgb = np.clip(c[..., :3] / np.maximum(a, 1e-6)[..., None], 0.0, 1.0)  # a lone layer comes premultiplied
    t = ly.get("tint")
    if tinted and t is not None:
        rgb = overlay(rgb, t[:3]) if ly["overlay"] else rgb * t[:3]
        a = a * t[3]
    return rgb, a


def composite(pictures):
    """Pictures (rgb, alpha) drawn over each other in order: (rgb straight, alpha)."""
    pictures = [p for p in pictures if p is not None]
    if not pictures:
        z = np.zeros((tt.CANVAS, tt.CANVAS))
        return np.zeros((tt.CANVAS, tt.CANVAS, 3)), z
    acc = np.zeros(pictures[0][0].shape)
    alpha = np.zeros(pictures[0][1].shape)
    for rgb, a in pictures:
        acc = rgb * a[..., None] + acc * (1.0 - a[..., None])
        alpha = a + alpha * (1.0 - a)
    return acc / np.maximum(alpha, 1e-6)[..., None], alpha


# --------------------------------------------------------------------------------------- models

def specs(raw):
    """model -> how it is sampled: kind (turn, walk, single), anim, dirs, frames, mode (colour or
    mask), and per kind: exclude (nodes left out), centre, stretch, legs (the tier's spider-leg)."""
    su, sg, c, s, u, se = (raw["spider-unit"], raw["segment"], raw["corpse"], raw["unit-spawner"], raw["unit"],
                           raw["simple-entity"])
    out = {
        "demolisher-head": {"kind": "turn", "anim": raw["segmented-unit"]["big-demolisher"]["animation"], "step": 4},
        "demolisher-segment": {"kind": "turn", "anim": cs.scaled(sg["big-demolisher-segment-x1_52"]["animation"], 1.52),
                               "step": 4},
        "demolisher-tail": {"kind": "turn", "anim": cs.scaled(sg["big-demolisher-tail-x0_64"]["animation"], 0.64),
                            "step": 4},
        "gleba-spawner-small": {"kind": "single", "anim": s["gleba-spawner-small"]["graphics_set"]["animations"]},
        "gleba-spawner-corpse": {"kind": "single", "anim": c["gleba-spawner-corpse"]["animation"]},
        "big-wriggler-pentapod": {"kind": "walk", "anim": u["big-wriggler-pentapod"]["run_animation"], "mode": "mask",
                                  "materials": ["flesh_olive", "chitin_wriggler_leg"],
                                  "tiers": [t + "-wriggler-pentapod" + p for t in TIERS for p in ("", "-premature")],
                                  "copies": ["big-wriggler-pentapod-attack"]},
        # Its corpse (creature_pose.py's fall) from the last dying frame in every direction, the
        # mask kept for the family's tints.
        "big-wriggler-pentapod-corpse": {"kind": "turn", "anim": c["big-wriggler-pentapod-corpse"]["animation"],
                                         "mode": "mask", "materials": ["flesh_olive", "chitin_wriggler_leg"],
                                         "family": "big-wriggler-pentapod", "last": True},
    }
    for t in TIERS:
        st = su[t + "-stomper-pentapod"]["graphics_set"]
        sf = su[t + "-strafer-pentapod"]["graphics_set"]
        out[t + "-stomper-pentapod"] = {"kind": "turn", "anim": st["animation"], "step": 2, "exclude": "anim_leg",
                                        "centre": True, "legs": raw["spider-leg"][t + "-stomper-pentapod-leg"]}
        out[t + "-strafer-pentapod"] = {"kind": "turn", "anim": {"layers": [sf["base_animation"], sf["animation"]]},
                                        "step": 2, "exclude": "anim_leg", "centre": True,
                                        "legs": raw["spider-leg"][t + "-strafer-pentapod-leg"]}
        pics = se[t + "-stomper-shell"]["pictures"]
        out[t + "-stomper-shell"] = {"kind": "single", "anim": pics[0] if isinstance(pics, list) else pics,
                                     "stretch": STRETCH}
    for k, v in out.items():
        v.setdefault("mode", "colour")
        anim = v["anim"]
        nd = cs.direction_count(anim)
        v["ndirs"] = nd
        v["dirs"] = list(range(0, nd, v.get("step", 1))) if v["kind"] != "single" else [0]
        nf = cs.frame_count(anim)
        v["frames"] = list(range(0, nf, 2)) if v["kind"] == "walk" else [nf - 1 if v.get("last") else 0]
    return out


def tri_nodes(glb):
    """The node name of each of part_colors.Model's triangles (its traversal order)."""
    doc = glb.doc
    names = []

    def visit(index):
        node = doc["nodes"][index]
        if "mesh" in node:
            for prim in doc["meshes"][node["mesh"]]["primitives"]:
                if prim.get("mode", 4) != 4:
                    continue
                a = prim["attributes"]
                n = (doc["accessors"][prim["indices"]]["count"] if "indices" in prim
                     else doc["accessors"][a["POSITION"]]["count"]) // 3
                names.extend([str(node.get("name", ""))] * n)
        for child in node.get("children", []):
            visit(child)

    for root in doc["scenes"][doc.get("scene", 0)]["nodes"]:
        visit(root)
    return np.array(names)


# --------------------------------------------------------------------------------------- sampling

class Skin(sk.Skin):
    """creature_skin's Skin, sampled from Factorio's tinted composite (overlay tints and all)."""

    def __init__(self, name, path=None):
        self.name = name
        self.glb = pc.Glb(path or packs.model_path(name))
        self.model = pc.Model(self.glb)
        self.rest = self.model.tris.copy()
        self.T = len(self.model.tris)
        self.nodes = tri_nodes(self.glb)
        self.samples = []
        self.fits = []
        self.mask_rgb = []  # the mask's own pixels (sRGB) where it covers, for the tiers' tints

    def render_tris(self, tris, exclude=None):
        if exclude:
            tris = tris.copy()
            tris[np.char.startswith(self.nodes, exclude)] += 1e4  # off the canvas
        return tris

    def picture(self, anim, d, f, mode):
        """(full alpha, base rgb, base alpha, [mask (rgb, alpha)]) of one frame."""
        lys = drawn_layers(anim, d, f)
        full = composite([layer_picture(ly) for ly in lys])
        if mode == "mask":
            base = composite([layer_picture(ly) for ly in lys if not ly["mask"]])
            masks = [layer_picture(ly, tinted=False) for ly in lys if ly["mask"]]
            return full[1], base[0], base[1], [m for m in masks if m is not None]
        return full[1], full[0], full[1], []

    def sample_at(self, tris, phi, picture, centre=False, normals=None):
        full_a, base_rgb, base_a, masks = picture
        cam = tt.Camera(anchor=0.0, size=tt.CANVAS)
        _m, _rgb, fid = tt.render(tris, np.full((self.T, 3), 0.5), cam, phi)
        sprite = full_a > 0.5
        if centre:
            ys, xs = np.nonzero(fid >= 0)
            ty, tx = np.nonzero(sprite)
            if len(ys) and len(ty):
                fid = np.roll(np.roll(fid, int(round(ty.mean() - ys.mean())), 0), int(round(tx.mean() - xs.mean())), 1)
        best, dx, dy = sk.align(fid >= 0, sprite)
        fid = np.roll(np.roll(fid, dy, 0), dx, 1)
        from scipy import ndimage
        inner = ndimage.binary_erosion(fid >= 0, iterations=1)
        ok = inner & (full_a > 0.9)
        src = self.rest if normals is None else normals
        e1 = src[:, 1] - src[:, 0]
        e2 = src[:, 2] - src[:, 0]
        n = np.cross(e1, e2)
        flip = np.einsum("ij,ij->i", np.cross(self.rest[:, 1] - self.rest[:, 0], self.rest[:, 2] - self.rest[:, 0]),
                         self.model.normal) < 0
        n[flip] *= -1
        n /= np.maximum(np.linalg.norm(n, axis=1), 1e-12)[:, None]
        c, s = math.cos(phi), math.sin(phi)
        nw = np.stack([n[:, 0] * c - n[:, 2] * s, n[:, 1], n[:, 0] * s + n[:, 2] * c], axis=1)
        facing = nw @ pc.VIEW
        t = fid[ok]
        keep = facing[t] > sk.FACING
        ys, xs = np.nonzero(ok)
        ys, xs, t = ys[keep], xs[keep], t[keep]
        light = pc.shade(nw[t])
        b = sk.srgb_to_linear(base_rgb[ys, xs]) / light[:, None]
        cols = [np.zeros(len(t))] * 4
        for k, (mrgb, ma) in enumerate(masks[:2]):
            cols[2 * k] = (sk.srgb_to_linear(mrgb[ys, xs]) @ LUMA) / light
            cols[2 * k + 1] = ma[ys, xs]
            if k == 0:
                cover = ma[ys, xs] > 0.8
                self.mask_rgb.append(mrgb[ys, xs][cover])
        self.samples.append((t, facing[t] ** 2, b, cols[0], cols[1], cols[2], cols[3], []))
        self.fits.append(best)
        return best


def walk_pose(model):
    """(rig, x) for the client's walk of a walking model, with creature_gait's fitted bend (its
    phase from art-src/turntable/anim/<model>_knees.json, else searched by the silhouettes)."""
    rig = cg.WalkRig(model, cg.groups_of(ta.RIGS[model]))
    x = rig.x0.copy()
    path = os.path.join(ta.OUT, model + "_knees.json")
    if os.path.exists(path):
        return rig, np.array(json.load(open(path))["x"], float), True
    limbs = ta.RIGS[model]["limbs"]
    g = max(rig.groups) + 1
    for i, l in enumerate(limbs):
        b = l.get("bend", [0.0, 0.0, 0.0])
        x[1] = b[1]
        x[6 + rig.groups[i]] = b[0]
        x[6 + g + rig.groups[i]] = b[2]
    body = ta.RIGS[model].get("body")
    if body:
        x[5] = body[1]
    return rig, x, False


def search_phase(skin, model, spec, rig, x):
    """The walk's phase that lines up with the sprite's frames (silhouettes, a few frames)."""
    flat = skin.rest.reshape(-1, 3)
    uv = skin.model.uv.reshape(-1, 2)
    cam = tt.Camera(anchor=0.0, size=tt.CANVAS)
    nf = cs.frame_count(spec["anim"])
    best = None
    for ph in np.linspace(-math.pi, math.pi, 17)[:-1]:
        y = x.copy()
        y[0] = ph
        y[4] = rig.stand(flat, uv, y)
        score = []
        for f in (0, nf // 3, 2 * nf // 3):
            tris = rig.pose(flat, uv, y, 2 * math.pi * f / nf).reshape(-1, 3, 3)
            for d in (0, 4, 8, 12):
                sprite = tt.frame_canvas(cs.frame_layers(spec["anim"], d, f))[..., 3] > 0.5
                m = tt.render(tris, np.full((len(tris), 3), 0.5), cam, 2 * math.pi * d / spec["ndirs"])[0]
                score.append(sk.align(m, sprite, 4)[0])
        s = float(np.mean(score))
        if best is None or s > best[0]:
            best = (s, ph)
    x = x.copy()
    x[0] = best[1]
    print("  %s: walk phase %.2f fits its frames (IoU %.3f)" % (model, best[1], best[0]))
    return x


def sample_model(name, spec, path=None):
    skin = Skin(name, path)
    mode = spec["mode"]
    if spec["kind"] == "walk":
        rig, x, known = walk_pose(name)
        if not known:
            x = search_phase(skin, name, spec, rig, x)
            # Kept beside creature_gait's, out of the repo, so the scores pose it the same way.
            os.makedirs(ta.OUT, exist_ok=True)
            with open(os.path.join(ta.OUT, name + "_knees.json"), "w") as f:
                json.dump({"x": [float(v) for v in x], "names": rig.names}, f)
        flat = skin.rest.reshape(-1, 3)
        uv = skin.model.uv.reshape(-1, 2)
        x[4] = rig.stand(flat, uv, x)
        nf = cs.frame_count(spec["anim"])
        for f in spec["frames"]:
            tris = rig.pose(flat, uv, x, 2 * math.pi * f / nf).reshape(-1, 3, 3)
            for d in spec["dirs"]:
                skin.sample_at(tris, 2 * math.pi * d / spec["ndirs"], skin.picture(spec["anim"], d, f, mode),
                               normals=tris)
        return skin
    tris = skin.render_tris(skin.rest, spec.get("exclude"))
    if spec.get("stretch"):
        tris = tris.copy()
        tris[..., 2] *= spec["stretch"]
    for d in spec["dirs"]:
        phi = 2 * math.pi * d / spec["ndirs"] if spec["kind"] == "turn" else 0.0
        skin.sample_at(tris, phi, skin.picture(spec["anim"], d, spec["frames"][0], mode), centre=spec.get("centre", False),
                       normals=tris)
    return skin


# --------------------------------------------------------------------------------------- legs

def leg_parts(legs):
    """{our material suffix: [Factorio's layers of that part]} for a pentapod's spider-leg."""
    gs = legs["graphics_set"]

    def layers(p):
        return [ly for ly in (p or {}).get("layers", []) if ly.get("scale")]
    up, lo = gs["upper_part"], gs["lower_part"]
    out = {"thigh": layers(up.get("middle")), "shin": layers(lo.get("middle")), "knee": layers(gs.get("joint"))}
    hip = layers(up.get("top_end"))
    if hip:
        out["hip"] = hip
    foot = layers(lo.get("bottom_end")) or layers(gs.get("foot"))
    if foot:
        out["foot"] = foot
    return out


def leg_profile(layers, rows=48):
    """A part's colour down its length (rows x 3, linear, Factorio's light in it): every lighting
    direction's picture, tinted and drawn as Factorio draws them, each row's middle averaged."""
    dirs = max(ly.get("direction_count", 1) for ly in layers)
    acc = np.zeros((rows, 3))
    wsum = np.zeros(rows)
    for d in range(dirs):
        pics = []
        for ly in layers:
            img = tt.sheet(cs._file(ly["filename"]))
            w, h = ly["width"], ly["height"]
            line = ly.get("line_length") or dirs
            x0, y0 = (d % line) * w + ly.get("x", 0), (d // line) * h + ly.get("y", 0)
            crop = img[y0:y0 + h, x0:x0 + w].astype(float) / 255.0
            rgb, a = crop[..., :3], crop[..., 3]
            t = tint_of(ly.get("tint"))
            if t is not None:
                rgb = overlay(rgb, t[:3]) if ly.get("tint_as_overlay") else rgb * t[:3]
                a = a * t[3]
            pics.append((rgb, a))
        hmax = max(p[0].shape[0] for p in pics)
        wmax = max(p[0].shape[1] for p in pics)
        pics = [(np.pad(r, ((0, hmax - r.shape[0]), (0, wmax - r.shape[1]), (0, 0))),
                 np.pad(a, ((0, hmax - a.shape[0]), (0, wmax - a.shape[1])))) for r, a in pics]
        rgb, a = composite(pics)
        lin = sk.srgb_to_linear(rgb)
        # The middle of each row, where the part's alpha is solid.
        cols = np.arange(wmax)
        for r in range(hmax):
            on = a[r] > 0.9
            if not on.any():
                continue
            xs = cols[on]
            mid, half = (xs.min() + xs.max()) / 2.0, (xs.max() - xs.min()) / 2.0
            sel = on & (np.abs(cols - mid) <= max(1.0, half * LEG_COLUMNS * 2))
            k = min(rows - 1, int(r * rows / hmax))
            acc[k] += lin[r, sel].sum(axis=0)
            wsum[k] += sel.sum()
    known = wsum > 0
    prof = acc / np.maximum(wsum, 1)[:, None]
    if known.any():
        idx = np.arange(rows)
        for ch in range(3):
            prof[:, ch] = np.interp(idx, idx[known], prof[known, ch])
    return prof


def cylinder_light():
    """Factorio's painted-in light averaged over a leg's visible side (a cylinder lying across the
    view, every way round), what a row's middle carries."""
    vals, ws = [], []
    for heading in np.linspace(0, math.pi, 8, endpoint=False):
        axis = np.array([math.cos(heading), -0.35, math.sin(heading)])
        axis /= np.linalg.norm(axis)
        u = np.cross(axis, [0.0, 1.0, 0.0])
        u /= np.linalg.norm(u)
        v = np.cross(axis, u)
        for th in np.linspace(0, 2 * math.pi, 48, endpoint=False):
            n = math.cos(th) * u + math.sin(th) * v
            f = float(n @ pc.VIEW)
            if f > 0.6:  # the row's middle: facing the camera
                vals.append(pc.shade(n[None])[0])
                ws.append(f)
    return float(np.average(vals, weights=ws))


def leg_corners(skin, legs):
    """(T, 3, 3) colours per corner for the leg nodes' triangles (NaN elsewhere), each part's
    picture laid down its length; None without legs."""
    m = skin.model
    T = len(m.tris)
    out = np.full((T, 3, 3), np.nan)
    parts = leg_parts(legs)
    profiles = {k: leg_profile(v) for k, v in parts.items()}
    light = cylinder_light()
    centre = np.zeros(3)
    for node in sorted(set(n for n in skin.nodes if n.startswith("anim_leg"))):
        sel = np.nonzero(skin.nodes == node)[0]
        pts = m.tris[sel].reshape(-1, 3)
        mid = pts.mean(axis=0)
        _u, _s, vt = np.linalg.svd(pts - mid, full_matrices=False)
        axis = vt[0]
        s = (pts - mid) @ axis
        ends = [mid + axis * s.min(), mid + axis * s.max()]
        upper = node.startswith("anim_leg_upper")
        # The top of a part's picture: the hip's end for the thigh (nearer the body's middle),
        # the knee's for the shin (the higher end).
        if upper:
            top_first = np.linalg.norm((ends[0] - centre)[[0, 2]]) < np.linalg.norm((ends[1] - centre)[[0, 2]])
        else:
            top_first = ends[0][1] > ends[1][1]
        if not top_first:
            axis = -axis
        along = ((m.tris[sel] - mid) @ axis)  # (n, 3) per corner
        for mat_index in np.unique(m.material[sel]):
            mname = m.material_names[mat_index]
            part = next((k for k in profiles if mname.endswith("_" + k)), None)
            if part is None:
                continue
            ts = sel[m.material[sel] == mat_index]
            a = along[m.material[sel] == mat_index]
            lo, hi = a.min(), a.max()
            t = (a - lo) / max(hi - lo, 1e-6)
            prof = profiles[part]
            k = np.clip(t * (len(prof) - 1), 0, len(prof) - 1)
            i0 = np.floor(k).astype(int)
            i1 = np.minimum(i0 + 1, len(prof) - 1)
            fr = (k - i0)[..., None]
            col = prof[i0] * (1 - fr) + prof[i1] * fr
            out[ts] = col / light
    return out


# --------------------------------------------------------------------------------------- writing

def tier_tints(raw, spec, skin):
    """{tier: [[tint 1 (linear), 1], [0, 0, 0, the mask's alpha]]}: each tier's overlay over the
    mask's own pixels, fitted as a multiply of the mask's shade (skin_mode 2)."""
    m = np.concatenate(skin.mask_rgb) if skin.mask_rgb else np.zeros((0, 3))
    if len(m) > 20000:
        m = m[np.linspace(0, len(m) - 1, 20000).astype(int)]
    lum = sk.srgb_to_linear(m) @ LUMA
    out = {}
    for tier in spec["tiers"]:
        proto = raw["unit"].get(tier)
        if proto is None:
            continue
        mask = next(ly for ly in cs._layers(proto["run_animation"]) if is_mask(ly))
        t = tint_of(mask.get("tint"))
        target = sk.srgb_to_linear(overlay(m, t[:3]))
        k = (target * lum[:, None]).sum(axis=0) / max(float((lum * lum).sum()), 1e-9)
        out[tier] = [[round(float(v), 4) for v in k] + [1.0], [0.0, 0.0, 0.0, round(float(t[3]), 4)]]
    return out


def write_skin(skin, spec, legs=None, check=False):
    vals = skin.gather()
    m = skin.model
    store = sk.grade(vals[:, 0:3])
    corners, filled = sk.vertex_field(m, store, skin.seen, None)
    extra = None
    masked = np.zeros(len(m.tris), bool)
    if spec["mode"] == "mask":
        mats = [m.material_names.index(n) for n in m.material_names if any(n.startswith(p) for p in spec["materials"])]
        masked = np.isin(m.material, mats)
        extra = np.stack([vals[:, 3] * pc.EXPOSURE, vals[:, 4], np.zeros(len(vals))], axis=1)
        extra[~masked] = 0.0
        extra = sk.vertex_field(m, extra, skin.seen, None)[0]
    if legs is not None:
        lc = leg_corners(skin, legs)
        on = ~np.isnan(lc[:, 0, 0])
        if on.any():
            corners[on] = sk.grade(lc[on].reshape(-1, 3)).reshape(-1, 3, 3)
            filled[on] = True
    # A material no picture saw (an underside): its old colour.
    if not filled.all():
        old = stored_corners(skin.glb, m)
        corners = np.where(filled[..., None], corners, old)
    print("%-26s %4d pictures, fit %.2f-%.2f, %3.0f%% of triangles seen%s" % (
        skin.name, len(skin.fits), min(skin.fits), max(skin.fits), float(skin.seen.mean()) * 100,
        ", legs from their pictures" if legs is not None else ""))
    if check:
        return corners, extra
    owed = np.ones(m.n_patches)
    colour = np.zeros((m.n_patches, 3))
    np.add.at(colour, m.patch, corners.mean(axis=1))
    colour /= np.maximum(np.bincount(m.patch, minlength=m.n_patches), 1)[:, None]
    m.tint[:] = 1.0
    pc.write(m, colour, owed, corners)
    if extra is not None:
        sk.write_mask_colour(skin.glb.path, extra)
    return corners, extra


def copy_skin(corners, extra, source, name):
    """A pose model of a walking one (creature_pose.py: the same triangles in the same order) takes
    its skin."""
    path = packs.model_path(name)
    if not os.path.exists(path):
        return
    glb = pc.Glb(path)
    m = pc.Model(glb)
    if len(m.tris) != len(corners) or not np.array_equal(m.material, source.material):
        print("%-26s triangles differ from %s, left as it is" % (name, source.glb.path))
        return
    colour = np.zeros((m.n_patches, 3))
    np.add.at(colour, m.patch, corners.mean(axis=1))
    colour /= np.maximum(np.bincount(m.patch, minlength=m.n_patches), 1)[:, None]
    m.tint[:] = 1.0
    pc.write(m, colour, np.ones(m.n_patches), corners)
    if extra is not None:
        sk.write_mask_colour(path, extra)
    print("%-26s skin copied from %s" % (name, os.path.basename(source.glb.path)))


def stored_corners(glb, m=None):
    """(T, 3, 3) the colours a model draws per corner now (linear): its part colours mixed with its
    material's palette colour by their share, as the shader mixes them."""
    m = m or pc.Model(glb)
    out = np.zeros((len(m.tris), 3, 3))
    for k, (_mi, _pi, prim) in enumerate(m.prims):
        sel = np.nonzero(m.prim_of == k)[0]
        a = prim["attributes"]
        pal = m.palette[prim.get("material", 0)] if m.palette else np.full(3, 0.7)
        if "TEXCOORD_4" not in a or "TEXCOORD_5" not in a:
            out[sel] = pal
            continue
        p4, p5 = glb.accessor(a["TEXCOORD_4"]), glb.accessor(a["TEXCOORD_5"])
        rgb = np.concatenate([p4, p5[:, :1]], axis=1) * pc.RANGE
        share = np.clip(p5[:, 1] / 0.25, 0.0, 1.0)[:, None]
        col = pal * (1 - share) + rgb * share
        out[sel] = col[m.corner_vert[sel]]
    return out


def mask_corners(glb, m):
    """(T, 3, 2) COLOR_0's (shade, cover) per corner (skin_mode 2's mask): (1, 1, 1), where the mask
    doesn't reach, as none (the client takes the blue off red and green)."""
    out = np.zeros((len(m.tris), 3, 2))
    for k, (_mi, _pi, prim) in enumerate(m.prims):
        sel = np.nonzero(m.prim_of == k)[0]
        a = prim["attributes"]
        if "COLOR_0" not in a:
            continue
        col = glb.accessor(a["COLOR_0"])
        blue = col[:, 2] if col.shape[1] > 2 else 0.0
        r, g = np.maximum(col[:, 0] - blue, 0.0), np.maximum(col[:, 1] - blue, 0.0)
        v = np.stack([4.0 * r ** 2, g], axis=1)
        out[sel] = v[m.corner_vert[sel]]
    return out


# --------------------------------------------------------------------------------------- scores

# The wriggler's legs were drawn in the big tier's carapace colour before its skin (creature_models.gd
# ALIASES, sRGB), not their part colours.
OLD_FLAT = {"big-wriggler-pentapod": {"chitin": (0.315, 0.143, 0.097)}}


def drawn(name, spec, path, tier_tint=None, old=False):
    """(T, 3) each triangle's colour as the client draws it (linear), big tier."""
    glb = pc.Glb(path)
    m = pc.Model(glb)
    col = stored_corners(glb, m).mean(axis=1)
    if old:
        for frag, srgb in OLD_FLAT.get(name, {}).items():
            on = np.isin(m.material, [i for i, n in enumerate(m.material_names) if frag in n])
            col[on] = sk.srgb_to_linear(np.array(srgb))
    elif spec["mode"] == "mask" and tier_tint is not None:
        mk = mask_corners(glb, m).mean(axis=1)
        mats = [i for i, n in enumerate(m.material_names) if any(n.startswith(p) for p in spec["materials"])]
        on = np.isin(m.material, mats)
        a = np.clip(mk[:, 1] * tier_tint[1][3], 0, 1)[:, None]
        mixed = col * (1 - a) + mk[:, 0:1] * np.array(tier_tint[0][:3]) * a
        col = np.where(on[:, None], mixed, col)
    return m, col


def render_look(m, col, tris, phi, normals=None):
    """The model's colours lit by Factorio's painted-in light from Factorio's camera: (mask, rgb linear, fid)."""
    cam = tt.Camera(anchor=0.0, size=tt.CANVAS)
    _mk, _rgb, fid = tt.render(tris, np.full((len(tris), 3), 0.5), cam, phi)
    src = normals if normals is not None else tris
    n = np.cross(src[:, 1] - src[:, 0], src[:, 2] - src[:, 0])
    flip = np.einsum("ij,ij->i", np.cross(m.tris[:, 1] - m.tris[:, 0], m.tris[:, 2] - m.tris[:, 0]), m.normal) < 0
    n[flip] *= -1
    n /= np.maximum(np.linalg.norm(n, axis=1), 1e-12)[:, None]
    c, s = math.cos(phi), math.sin(phi)
    nw = np.stack([n[:, 0] * c - n[:, 2] * s, n[:, 1], n[:, 0] * s + n[:, 2] * c], axis=1)
    lit = col * pc.shade(nw)[:, None]
    on = fid >= 0
    rgb = np.zeros(fid.shape + (3,))
    rgb[on] = lit[fid[on]]
    return on, rgb, fid


def posed_views(name, spec, m, nodes, exclude=True):
    """[(tris, phi, (d, f))] the pictures a model is compared on (every 4th of its directions, the
    walk at three frames)."""
    out = []
    tris = m.tris.copy()
    if exclude and spec.get("exclude"):
        tris[np.char.startswith(nodes, spec["exclude"])] += 1e4
    if spec.get("stretch"):
        tris[..., 2] *= spec["stretch"]
    if spec["kind"] == "walk":
        rig, x, _known = walk_pose(name)
        flat, uv = m.tris.reshape(-1, 3), m.uv.reshape(-1, 2)
        x[4] = rig.stand(flat, uv, x)
        nf = cs.frame_count(spec["anim"])
        for f in (0, nf // 3, 2 * nf // 3):
            p = rig.pose(flat, uv, x, 2 * math.pi * f / nf).reshape(-1, 3, 3)
            for d in range(0, spec["ndirs"], 4):
                out.append((p, 2 * math.pi * d / spec["ndirs"], (d, f)))
        return out
    nd = spec["ndirs"]
    dirs = range(0, nd, max(1, nd // 8)) if spec["kind"] == "turn" else [0]
    for d in dirs:
        out.append((tris, 2 * math.pi * d / nd if spec["kind"] == "turn" else 0.0, (d, spec["frames"][0])))
    return out


def colour_score(name, spec, path, tint=None, old=False, keep=None):
    """{bright, dE, corr}: the model's look against the sprite's over the pixels both cover, after
    lining them up. bright: mean luminance, model over sprite; dE: mean CIE76 colour difference;
    corr: how the pixels' luminance goes together (a colour per part: low)."""
    m, col = drawn(name, spec, path, tint, old)
    nodes = tri_nodes(pc.Glb(path))
    lm, ls, de, pairs = [], [], [], []
    for tris, phi, (d, f) in posed_views(name, spec, m, nodes):
        on, rgb, _fid = render_look(m, col, tris, phi)
        lys = drawn_layers(spec["anim"], d, f)
        srgb, sa = composite([layer_picture(ly) for ly in lys])
        sprite = sa > 0.5
        if spec.get("centre"):
            ys, xs = np.nonzero(on)
            ty, tx = np.nonzero(sprite)
            dy, dx = int(round(ty.mean() - ys.mean())), int(round(tx.mean() - xs.mean()))
            on, rgb = np.roll(np.roll(on, dy, 0), dx, 1), np.roll(np.roll(rgb, dy, 0), dx, 1)
        _b, dx, dy = sk.align(on, sprite)
        on, rgb = np.roll(np.roll(on, dy, 0), dx, 1), np.roll(np.roll(rgb, dy, 0), dx, 1)
        both = on & (sa > 0.9)
        a = rgb[both]
        b = sk.srgb_to_linear(srgb[both])
        if keep is not None:
            keep.append((d, f, rgb, on, srgb, sa))
        if len(a) < 50:
            continue
        la, lb = a @ LUMA, b @ LUMA
        lm.append(la)
        ls.append(lb)
        de.append(np.linalg.norm(pc.to_lab(a) - pc.to_lab(b), axis=1))
    la, lb = np.concatenate(lm), np.concatenate(ls)
    return {"bright": round(float(la.mean() / max(lb.mean(), 1e-9)), 3), "dE": round(float(np.concatenate(de).mean()), 2),
            "corr": round(float(np.corrcoef(la, lb)[0, 1]), 3)}


def shots(name, spec, out_dir, before_dir, tint=None):
    """sprite | before | after, four of the model's pictures side by side."""
    from PIL import Image
    rows = []
    paths = []
    if before_dir and os.path.exists(os.path.join(before_dir, name + ".glb")):
        paths.append(("before", os.path.join(before_dir, name + ".glb"), True))
    paths.append(("after", packs.model_path(name), False))
    views = {}
    for label, path, old in paths:
        keep = []
        colour_score(name, spec, path, tint, old, keep)
        views[label] = keep
    pick = list(range(len(views["after"])))[:: max(1, len(views["after"]) // 4)][:4]
    bg = np.array([0.25, 0.25, 0.28])
    tiles = []
    for i in pick:
        d, f, _rgb, _on, srgb, sa = views["after"][i]
        col = [srgb * sa[..., None] + bg * (1 - sa[..., None])]
        for label, _p, _o in paths:
            _d, _f, rgb, on, _s, _a = views[label][i]
            col.append(np.where(on[..., None], pc.linear_to_srgb(rgb), bg))
        tiles.append(col)
    alpha = np.zeros(tiles[0][0].shape[:2], bool)
    for i in pick:
        alpha |= views["after"][i][5] > 0.05
        alpha |= views["after"][i][3]
    ys, xs = np.nonzero(alpha)
    y0, y1, x0, x1 = max(ys.min() - 8, 0), ys.max() + 8, max(xs.min() - 8, 0), xs.max() + 8
    for col in tiles:
        rows.append(np.concatenate([c[y0:y1, x0:x1] for c in col], axis=1))
    img = np.concatenate(rows, axis=0)
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, name + ".png")
    Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8)).save(path)
    return path


# --------------------------------------------------------------------------------------- main

def write_table(entries):
    table = json.load(open(SKINS_JSON, encoding="utf-8")) if os.path.exists(SKINS_JSON) else {}
    table.update(entries)
    with open(SKINS_JSON, "w", encoding="utf-8", newline="\n") as f:
        f.write("{\n" + ",\n".join("  %s: %s" % (json.dumps(k), json.dumps(table[k], separators=(", ", ": ")))
                                   for k in sorted(table)) + "\n}\n")


def main(argv):
    def opt(flag):
        return argv[argv.index(flag) + 1] if flag in argv else None
    check = "--check" in argv
    score_only = "--score" in argv
    before = opt("--before")
    shot_dir = opt("--shots")
    skip = {before, shot_dir}
    tt.CANVAS = 1024
    raw = cs.data_raw()
    table = specs(raw)
    names = [a for a in argv if not a.startswith("--") and a not in skip] or list(table)
    old_table = json.load(open(SKINS_JSON, encoding="utf-8")) if os.path.exists(SKINS_JSON) else {}
    entries = {}
    for name in names:
        spec = table[name]
        # Scores of older copies read those; pictures and the rest the models in the repo.
        path = os.path.join(before, name + ".glb") if before and score_only and not shot_dir else packs.model_path(name)
        if not os.path.exists(path):
            print("%s: no model" % name)
            continue
        if score_only or shot_dir:
            fam = spec.get("family", name)
            tint = old_table.get(fam, {}).get("tiers", {}).get(fam)
            if score_only:
                print("%-26s %s" % (name, colour_score(name, spec, path, tint, old=bool(before))))
            if shot_dir:
                print("  ", shots(name, spec, shot_dir, before, tint))
            continue
        skin = sample_model(name, spec)
        corners, extra = write_skin(skin, spec, spec.get("legs"), check)
        if not check:
            for pose in spec.get("copies", []):
                copy_skin(corners, extra, skin.model, pose)
        if spec.get("family"):
            continue  # a pose model sampled on its own: its family's entry has the tiers
        entry = {"mode": spec["mode"]}
        if spec["mode"] == "mask":
            entry["materials"] = spec["materials"]
            entry["tiers"] = tier_tints(raw, spec, skin)
        entries[name] = entry
    if entries and not check:
        write_table(entries)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
