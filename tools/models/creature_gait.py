#!/usr/bin/env python3
"""Knees for the walking creatures, and the bend of their walk, fitted to Factorio's run sprites.

    python tools/models/creature_gait.py                    # biter and spitter: fit, write the rig
    python tools/models/creature_gait.py big-biter --check  # score the client's walk, write nothing
    python tools/models/creature_gait.py --knees            # only the knees' places (no fit)

The client's walking rig (factorio_material.gdshaderinc, rig_mode 1) turned each leg about its hip
only, so Wube's printed legs swung as straight sticks where Factorio's run sheets bend theirs at a
knee, held high, the foot reaching down. Each leg now also folds at a knee, as creature_pose.py's
PoseRig folds it for the attack and corpse poses (the outer part of the leg turned about the lift
axis, from 0.45 to 0.57 of the leg's reach from the hip), so the shader can blend a walking leg
into those poses and a dying biter's legs end where its corpse's lie.

The walk gets a rest bend per pair of legs (front, middle, back: the knee folded, the hip lifted
to hold the foot down) and a flex while a leg is lifted (it folds as it steps forward and
straightens to plant), found by searching for the values whose silhouettes overlap the sprite's 16
run frames best over its directions (turntable_anim.py's point splats; the gait's phases, swings
and lifts stay wube_rig.py's). Written into client/data/creature_rigs.json per limb: `knee` (the
knee's place in model space), `reach` (the leg's length from the hip) and `bend` (rest knee, flex,
rest lift, radians); wube_rig.py keeps them when it writes the rig again.

The sprites come from Factorio's install and stay in the git-ignored art-src/turntable/.
"""

import json
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import creature_pose as cp  # noqa: E402
import creature_score as cs  # noqa: E402
import packs  # noqa: E402
import turntable as tt  # noqa: E402
import turntable_anim as ta  # noqa: E402

RIGS_JSON = os.path.join(tt.REPO, "client", "data", "creature_rigs.json")
KNEE = cp.PoseRig.KNEE  # the knee, as a share of the leg's reach from the hip
KNEE_SPAN = 0.12        # ... and how much of the reach it folds over (PoseRig.pose)
WALKERS = ("big-biter", "big-spitter")
FIT_FRAMES = tuple(range(0, 16, 2))
FIT_DIRS = tuple(range(0, 16, 2))
PIVOT_Y = 0.9  # the body pitches about this height (tiles, at the model's size)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / max(e1 - e0, 1e-9), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def knees(model, rig):
    """[(knee point, reach)] per limb, from the model's vertices as creature_pose.write_posed reads
    them, so the shader's knee folds the leg where the attack and corpse models were folded."""
    src = cp._read_glb(packs.model_path(model))
    v = np.concatenate([s[1] for s in src])
    uv = np.concatenate([s[3] for s in src])
    limb = np.round(uv[:, 0]).astype(int) - 1
    w = uv[:, 1]
    out = []
    for i, l in enumerate(rig["limbs"]):
        sel = (limb == i) & (w > 0)
        j = np.asarray(l["joint"], float)
        if not sel.any():
            out.append((j, 0.0))
            continue
        q = v[sel] - j
        d = np.linalg.norm(q, axis=1)
        reach = float(d.max())
        near = np.abs(d - KNEE * reach) < 0.06 * reach
        knee = j + (q[near].mean(axis=0) if near.any() else q.mean(axis=0) * KNEE)
        out.append((knee, reach))
    return out


def leg(p, w, limb, knee, reach, swing, lift, kn):
    """One limb's points turned as the shader turns them (rig_mode 1): folded at the knee, lifted
    and swung about the hip by the vertex's weight. p: points relative to the hip."""
    a_l, a_s = np.asarray(limb["lift"], float), np.asarray(limb["swing"], float)
    if reach > 0 and np.any(kn != 0):
        k = knee - np.asarray(limb["joint"], float)
        t = smoothstep(KNEE * reach, (KNEE + KNEE_SPAN) * reach, np.linalg.norm(p, axis=1))
        p = k + ta.rodrigues(p - k, a_l, kn * t)
    p = ta.rodrigues(p, a_l, lift * w)
    return ta.rodrigues(p, a_s, swing * w)


class WalkRig:
    """The shader's walk with knees: per leg the gait's swing and lift (creature_rigs.json), a rest
    lift and knee per pair and a knee flex while lifted, plus the body's height and pitch."""

    def __init__(self, model, groups):
        self.rig = ta.RIGS[model]
        self.limbs = self.rig["limbs"]
        self.knees = knees(model, self.rig)
        self.groups = groups  # limb index -> group index
        g = max(groups) + 1
        # phase0, flex, swing scale, lift scale, body dy, body pitch, then rest knee and lift per
        # group. The gait's own swing and lift stay as they are (scales fixed at 1): a smaller swing
        # fits the silhouettes a little better only by stiffening the legs. The body's height isn't
        # free either: it stands on its feet (stand()).
        self.names = ["phase0", "flex", "swing_k", "lift_k", "body_dy", "body_pitch"] + \
            ["knee%d" % i for i in range(g)] + ["lift%d" % i for i in range(g)]
        self.x0 = np.array([0.0, 0.0, 1.0, 1.0, 0.0, 0.0] + [0.0] * (2 * g))
        self.step = np.array([0.8, 0.2, 0.0, 0.0, 0.0, 0.05] + [0.25] * (2 * g))
        self.lo = np.array([-math.pi, -1.0, 1.0, 1.0, 0.0, -0.3] + [-1.4] * (2 * g))
        self.hi = np.array([math.pi, 1.5, 1.0, 1.0, 0.0, 0.3] + [1.4] * (2 * g))
        self.ground = None  # the unbent model's lowest point

    def stand(self, pts, uv, x):
        """How far the body is raised so the walk's rest pose (bent, no gait) stands where the
        unbent model stood: its lowest point at the same height."""
        if self.ground is None:
            self.ground = float(pts[:, 1].min())
        rest = self.pose(pts, uv, x, 0.0, gait=0.0, dy=0.0)
        return self.ground - float(rest[:, 1].min())

    def bends(self, x):
        g = max(self.groups) + 1
        kn, li = x[6:6 + g], x[6 + g:6 + 2 * g]
        return [(float(kn[self.groups[i]]), float(x[1]), float(li[self.groups[i]])) for i in range(len(self.limbs))]

    def pose(self, pts, uv, x, t, gait=1.0, dy=None):
        p = pts.copy()
        limb = np.round(uv[:, 0]).astype(int) - 1
        w = uv[:, 1]
        bends = self.bends(x)
        for i, l in enumerate(self.limbs):
            sel = (limb == i) & (w > 0)
            if not sel.any():
                continue
            g = l["gait"]
            s, c = math.sin(t + x[0] + g[0]), max(0.0, math.cos(t + x[0] + g[0]))
            k0, flex, l0 = bends[i]
            j = np.asarray(l["joint"], float)
            q = leg(p[sel] - j, w[sel], l, self.knees[i][0], self.knees[i][1],
                    x[2] * g[1] * s * gait, l0 + x[3] * g[2] * c * gait, k0 + flex * c * gait)
            p[sel] = j + q
        piv = np.array([0.0, PIVOT_Y, 0.0])
        p = piv + ta.rodrigues(p - piv, (1.0, 0.0, 0.0), np.full(len(p), x[5]))
        p[:, 1] += x[4] if dy is None else dy
        return p


def groups_of(rig):
    """Pairs of legs by their letter (leg_la, leg_ra -> 0...)."""
    letters = sorted({l["name"][-1] for l in rig["limbs"]})
    if len(letters) > 3:  # the spitter's twelve: front, middle and back thirds
        return [min(2, letters.index(l["name"][-1]) * 3 // len(letters)) for l in rig["limbs"]]
    return [letters.index(l["name"][-1]) for l in rig["limbs"]]


class Fit:
    def __init__(self, model):
        raw = cs.data_raw()
        anim = raw["unit"][model]["run_animation"]
        self.model = model
        self.nframes = cs.frame_count(anim)
        self.ndirs = cs.direction_count(anim)
        self.anim = anim
        self._masks = {}
        pts, uv, _c, _t, _tc, _tu = ta.load_points(packs.model_path(model))
        self.pts, self.uv = pts, uv
        self.rig = WalkRig(model, groups_of(ta.RIGS[model]))
        self.fitter = ta.Fitter(self.rig, pts, uv, [], self.ndirs, 0.0)
        self._calibrate()

    def _calibrate(self):
        """Scale and place on the ground against every fitting frame at rest (the client's walk,
        no knees)."""
        f0 = self.fitter
        best = None
        x = self.rig.x0.copy()
        for scale in (0.95, 1.0, 1.05):
            f0.calib = np.array([scale, 0.0, 0.0])
            s = self.score(x)
            if best is None or s > best[0]:
                best = (s, f0.calib.copy())
        f0.calib = best[1]
        for step in (0.08, 0.03):
            for k in (1, 2):
                for sgn in (1, -1):
                    c = f0.calib.copy()
                    c[k] += sgn * step
                    old = f0.calib
                    f0.calib = c
                    s = self.score(x)
                    if s > best[0] + 1e-4:
                        best = (s, c)
                    else:
                        f0.calib = old

    def mask(self, f, d):
        """The run frame's silhouette at the fitting resolution (made once)."""
        if (f, d) not in self._masks:
            a = tt.frame_canvas(cs.frame_layers(self.anim, d, f))[..., 3]
            self._masks[f, d] = a.reshape(ta.SIZE, 2, ta.SIZE, 2).mean(axis=(1, 3)) > 0.5
        return self._masks[f, d]

    def score(self, x, frames=FIT_FRAMES, dirs=FIT_DIRS, each=False):
        out = []
        x = x.copy()
        x[4] = self.rig.stand(self.pts, self.uv, x)
        for f in frames:
            t = 2 * math.pi * f / self.nframes
            p = self.rig.pose(self.pts, self.uv, x, t)
            s, dx, dz = self.fitter.calib
            p = p * s
            p[:, 0] += dx
            p[:, 2] += dz
            p = p[p[:, 1] > -0.02]  # what dips under the ground, the ground hides
            for d in dirs:
                out.append(tt.iou(self.fitter.silhouette(p, d), self.mask(f, d)))
        return out if each else float(np.mean(out))

    def search(self, x):
        best = self.score(x)
        print("  %s: start %.3f" % (self.model, best))
        for scale in (1.0, 0.5, 0.25, 0.12):
            for _round in range(3):
                improved = False
                for k in range(len(x)):
                    for sgn in (1, -1):
                        y = x.copy()
                        y[k] = np.clip(y[k] + sgn * self.rig.step[k] * scale, self.rig.lo[k], self.rig.hi[k])
                        s = self.score(y)
                        if s > best + 1e-4:
                            x, best, improved = y, s, True
                if not improved:
                    break
            print("  step %.2f: %.3f" % (scale, best))
        return x, best


def write(model, rig, x=None):
    """The knees (and, with a fit, the walk's bend) into creature_rigs.json."""
    table = json.load(open(RIGS_JSON, encoding="utf-8"))
    entry = table[model]
    bends = rig.bends(x) if x is not None else None
    for i, l in enumerate(entry["limbs"]):
        knee, reach = rig.knees[i]
        l["knee"] = [round(float(c), 4) for c in knee]
        l["reach"] = round(float(reach), 4)
        if bends is not None:
            l["bend"] = [round(v, 4) for v in bends[i]]
        elif "bend" not in l:
            l["bend"] = [0.0, 0.0, 0.0]
    if x is not None:
        # The body's rest height (standing on its bent legs) and pitch about PIVOT_Y up.
        entry["body"] = [round(float(x[4]), 4), round(float(x[5]), 4), PIVOT_Y]
    import wube_rig
    wube_rig._write_table(table)


def main(argv):
    names = [a for a in argv if not a.startswith("--")] or list(WALKERS)
    for model in names:
        if "--knees" in argv:
            write(model, WalkRig(model, groups_of(ta.RIGS[model])))
            print("%s: knees written" % model)
            continue
        fit = Fit(model)
        x0 = fit.rig.x0.copy()
        base = fit.score(x0, frames=range(fit.nframes), dirs=range(fit.ndirs))
        print("%s: the client's walk (no knees), every frame and direction: IoU %.3f" % (model, base))
        if "--check" in argv:
            continue
        # The client's loop starts anywhere: first the phase that fits the sprite's frame 0.
        x0[0] = max(np.linspace(-math.pi, math.pi, 17)[:-1], key=lambda ph: fit.score(np.r_[ph, x0[1:]]))
        x, _ = fit.search(x0)
        x[4] = fit.rig.stand(fit.pts, fit.uv, x)
        after = fit.score(x, frames=range(fit.nframes), dirs=range(fit.ndirs))
        print("%s: with knees, every frame and direction: IoU %.3f -> %.3f" % (model, base, after))
        for n, v in zip(fit.rig.names, x):
            print("    %-11s %+.3f" % (n, v))
        write(model, fit.rig, x)
        # The fitted walk with its phase (which the client doesn't need), for the skins'
        # sampling (creature_skin.py, space_skin.py), kept out of the repo.
        os.makedirs(ta.OUT, exist_ok=True)
        with open(os.path.join(ta.OUT, model + "_knees.json"), "w") as f:
            json.dump({"x": [float(v) for v in x], "names": fit.rig.names}, f)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
