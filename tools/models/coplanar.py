"""Finds z-fighting in models: pairs of triangles that lie in the same plane (within a few millimetres) and overlap, so
the depth test picks a different one from frame to frame and the surface flickers, most far away, where a pixel's depth
covers more. Materials are double-sided in Zenith's models, so faces facing either way count.

python tools/models/coplanar.py [names...] [--all] [--eps 0.003] [--top 30]
prints each model's overlapping area (square tiles) and the material pairs it is between
"""
import argparse
import collections
import pathlib

import numpy as np
import trimesh

MODELS = pathlib.Path(__file__).resolve().parents[2] / "client" / "assets" / "models"


def triangles(path):
    sc = trimesh.load(path, force="scene")
    tris, mats = [], []
    for name, geom in sc.geometry.items():
        for node in sc.graph.geometry_nodes.get(name, []):
            m = geom.copy()
            m.apply_transform(sc.graph.get(node)[0])
            mat = getattr(getattr(m.visual, "material", None), "name", "?")
            tris.append(m.triangles)
            mats += [mat] * len(m.triangles)
    if not tris:
        return np.zeros((0, 3, 3)), []
    return np.concatenate(tris), mats


def inside(p, a, b, c):
    v0, v1, v2 = c - a, b - a, p - a
    d00, d01, d11 = (v0 * v0).sum(-1), (v0 * v1).sum(-1), (v1 * v1).sum(-1)
    d02, d12 = (v0 * v2).sum(-1), (v1 * v2).sum(-1)
    den = d00 * d11 - d01 * d01
    den = np.where(np.abs(den) < 1e-14, 1e-14, den)
    u = (d11 * d02 - d01 * d12) / den
    v = (d00 * d12 - d01 * d02) / den
    return (u > 0.02) & (v > 0.02) & (u + v < 0.98)


def fights(path, eps):
    t, mats = triangles(path)
    if len(t) == 0:
        return 0.0, {}
    n = np.cross(t[:, 1] - t[:, 0], t[:, 2] - t[:, 0])
    area = np.linalg.norm(n, axis=1) / 2
    ok = area > 1e-6
    n = n / np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-12)
    # One orientation per plane (double-sided), then the plane's offset.
    flip = (n[:, 0] < -1e-6) | ((np.abs(n[:, 0]) <= 1e-6) & ((n[:, 1] < -1e-6) | ((np.abs(n[:, 1]) <= 1e-6) & (n[:, 2] < 0))))
    n[flip] *= -1
    d = (n * t[:, 0]).sum(1)
    key = collections.defaultdict(list)
    for i in np.nonzero(ok)[0]:
        key[(tuple(np.round(n[i] * 50).astype(int)), int(round(d[i] / eps)))].append(i)
    # Neighbouring offset buckets too, so a pair straddling a bucket edge counts.
    seen = set()
    total = 0.0
    pairs = collections.Counter()
    for (nk, dk), idx in list(key.items()):
        cand = idx + key.get((nk, dk + 1), [])
        if len(cand) < 2:
            continue
        cand = np.array(cand)
        tc = t[cand]
        cent = tc.mean(1)
        for a_i in range(len(cand)):
            i = cand[a_i]
            if abs(d[i] - d[cand]).max() > eps * 2 and False:
                pass
            others = cand[a_i + 1:]
            if len(others) == 0:
                continue
            near = np.abs(d[others] - d[i]) < eps
            others = others[near]
            if len(others) == 0:
                continue
            # Overlap: a point inside both, from either triangle's centre and its corners pulled in.
            ti = t[i]
            pts_i = np.stack([ti.mean(0)] + [ti[k] * 0.6 + ti.mean(0) * 0.4 for k in range(3)])
            hit = np.zeros(len(others), bool)
            for p in pts_i:
                hit |= inside(p[None], t[others, 0], t[others, 1], t[others, 2])
            for k, j in enumerate(others):
                if hit[k]:
                    continue
                tj = t[j]
                pts_j = np.stack([tj.mean(0)] + [tj[q] * 0.6 + tj.mean(0) * 0.4 for q in range(3)])
                hit[k] = inside(pts_j, ti[0], ti[1], ti[2]).any()
            for j in others[hit]:
                pr = (i, j) if i < j else (j, i)
                if pr in seen:
                    continue
                seen.add(pr)
                a = min(area[i], area[j])
                total += a
                pairs[tuple(sorted((mats[i], mats[j])))] += a
    return total, pairs


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("names", nargs="*")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--eps", type=float, default=0.003)
    ap.add_argument("--top", type=int, default=30)
    a = ap.parse_args()
    files = sorted(MODELS.glob("*.glb")) if a.all else [MODELS / (n if n.endswith(".glb") else n + ".glb") for n in a.names]
    rows = []
    for f in files:
        try:
            total, pairs = fights(f, a.eps)
        except Exception as e:  # noqa: BLE001
            print(f.name, "error", e)
            continue
        rows.append((total, f.name, pairs))
    rows.sort(reverse=True)
    for total, name, pairs in rows[:a.top]:
        top = ", ".join("%s/%s %.4f" % (p[0], p[1], v) for p, v in pairs.most_common(4))
        print("%-40s %.4f sq tiles  %s" % (name, total, top))


if __name__ == "__main__":
    main()
