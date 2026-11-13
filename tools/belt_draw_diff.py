"""Two --belt-draw-dump files of the same capture, job by job: the records each path wrote for the GPU
(the GDScript path, --belt-draw-native=off, against BeltDrawNative), by item. Exits 1 on any difference.

    python tools/belt_draw_diff.py gd.bin native.bin [--jobs N] [--show N]

A record's path code (texel 2, w) is a run in the paths' texture, allotted in each path's own order,
so the two are compared by the path's points, not the code. Everything else is compared exactly
(float32 as written). The dumps come from tests/belt_bs_replay.gd --belt-draw-dump=<file> (or the
client's --belt-draw-dump)."""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import belt_view_check as b  # noqa: E402


def records_of(ids, recs, paths):
    """uid -> (ids tuple, record tuple with the path code replaced by its points)."""
    out = {}
    if ids is None:
        return out
    for i in range(ids.shape[0]):
        row = ids[i].tolist()
        r = recs[i].tolist()
        code = r[11]
        pts = ()
        if code > 0.5:
            c = int(code + 0.5) - 1
            first = c // 64
            pieces = c - first * 64 + 1
            if paths is not None:
                pts = tuple(paths[first * 4:(first + pieces + 1) * 4].tolist())
            else:
                pts = ("no paths", c)
            r[11] = 1.0
        out[row[0]] = (tuple(row), tuple(r), pts)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--jobs", type=int, default=0, help="compare only the first N jobs")
    ap.add_argument("--show", type=int, default=5, help="examples a job")
    args = ap.parse_args()
    fa = b.dump_frames(args.a)
    fb = b.dump_frames(args.b)
    paths_a = paths_b = None
    n = 0
    total = 0
    recs_a = recs_b = 0
    for (ha, ia, ra, ga, pa), (hb, ib, rb, gb, pb) in zip(fa, fb):
        n += 1
        if args.jobs and n > args.jobs:
            break
        if pa is not None:
            paths_a = pa
        if pb is not None:
            paths_b = pb
        A = records_of(ia, ra, paths_a)
        B = records_of(ib, rb, paths_b)
        recs_a += len(A)
        recs_b += len(B)
        diffs = []
        for uid in sorted(set(A) | set(B)):
            if uid not in A:
                diffs.append("uid %d only in b: %s" % (uid, B[uid][0]))
            elif uid not in B:
                diffs.append("uid %d only in a: %s" % (uid, A[uid][0]))
            elif A[uid] != B[uid]:
                xa, xb = A[uid], B[uid]
                what = []
                if xa[0] != xb[0]:
                    what.append("ids a %s b %s" % (xa[0], xb[0]))
                if xa[1] != xb[1]:
                    ks = [k for k in range(16) if xa[1][k] != xb[1][k]]
                    what.append("rec floats %s: a %s b %s" % (ks, [xa[1][k] for k in ks], [xb[1][k] for k in ks]))
                if xa[2] != xb[2]:
                    what.append("path a %d pts b %d pts, max |d| %.3g" % (len(xa[2]) // 4, len(xb[2]) // 4,
                        max([abs(p - q) for p, q in zip(xa[2], xb[2])] + [0.0]) if len(xa[2]) == len(xb[2]) else float("nan")))
                diffs.append("uid %d: %s" % (uid, "; ".join(what)))
        sa = set(ga.tolist()) if ga is not None else set()
        sb = set(gb.tolist()) if gb is not None else set()
        if sa != sb:
            diffs.append("gone: only a %s, only b %s" % (sorted(sa - sb)[:8], sorted(sb - sa)[:8]))
        head = []
        for k in ("changes", "coalesced", "renewed", "gone", "recs", "items", "parked", "unparked", "kept", "later", "asked"):
            if ha.get(k) != hb.get(k):
                head.append("%s a %s b %s" % (k, ha.get(k), hb.get(k)))
        if diffs or head:
            total += len(diffs)
            print("job %d (fold %.1f): %d record differences%s" % (n, float(ha.get("fold", -1)), len(diffs),
                ("; header: " + ", ".join(head)) if head else ""))
            for d in diffs[:args.show]:
                print("  " + d)
    print("%d jobs compared, %d records a / %d b, %d differences" % (n, recs_a, recs_b, total))
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
