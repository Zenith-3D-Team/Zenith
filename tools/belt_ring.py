#!/usr/bin/env python3
"""A ring of fast belts (the owner's ring where a read applied to a moving line made gaps and turn swaps), made
without Factorio, beside tools/belt_bursts.py.

    python tools/belt_ring.py --out <dir> [--belts 24] [--tier turbo] [--ticks 2400] [--puts 10,17] [--watch 5,12]

Two rows of `--belts` belts joined at each end by two right-turn curves (Factorio's curve lanes: the outer 295/256
long, the inner 106): row y 10 going west, row y 9 going east, clockwise round. Lanes follow Factorio's numbering
(line 1 the left lane, the outer one round right turns). The inner lane starts packed (every item a gap apart, the
slack in one place), the outer with a packed block and spaced items behind it, all moving at the tier's step
(docs/BELT-RULES.md: never closer than 64 to the one in front, round the ring).
  --puts B,B: an inserter south of each of those row-10 belts drops a plate on the outer lane every `--period`
              ticks (about) where there is room, as the owner's ring was fed;
  --watch B,B: an idle inserter south of each (never moving): the bridge reads those lanes whenever they change.
Writes <dir>/rec.json, events.json and stream.jsonl as belt_bursts.py does (the bridge is the worktree's own mod
under lupa against the fake Factorio, tools/bs_offline.py), replayed and scored as belt_bursts.py's.
"""

import argparse
import json
import pathlib
import random
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import belt_line_end as ble  # noqa: E402
import bs_offline  # noqa: E402

TIERS = {"yellow": ("transport-belt", 8), "red": ("fast-transport-belt", 16),
         "blue": ("express-transport-belt", 24), "turbo": ("turbo-transport-belt", 32)}
GAP = 64
Y = ble.Y  # row 10 goes west, row Y - 1 east
OUTER, INNER = 295, 106
# A right curve with its output south (dir 8), as recorded from the game: (length, exit, middle, entry) of each
# line, from the tile's top-left corner (1/256).
CURVE = {1: (OUTER, (188, 256), (133, 124), (1, 68)), 2: (INNER, (67, 256), (47, 209), (1, 189))}


def lane_y(line):
    """Row 10 (going west): line 1, the left lane, is the south one."""
    return Y * 256 + (188 if line == 1 else 68)


def turn(p, k):
    """Point p of a tile turned clockwise k quarter turns about its centre."""
    x, y = p
    for _ in range(k):
        x, y = 256 - y, x
    return x, y


def make_scene(a):
    name, step = TIERS[a.tier]
    ble.STEP = step
    ble.lane_y = lane_y  # (play() places a feeder's drop on its lane by this)
    rng = random.Random(a.seed)
    n = a.belts
    t0 = a.first
    names = ["copper-plate", "iron-plate"]
    # Each belt: unit, shape, dir, tile, and per line (length, exit, middle, entry) in 1/256.
    belts = []
    for b in range(n - 1, -1, -1):  # row 10, west, from its east end
        ls = {ln: (256, (b * 256, lane_y(ln)), (b * 256 + 128, lane_y(ln)), (b * 256 + 256, lane_y(ln))) for ln in (1, 2)}
        belts.append((100 + b, "straight", 12, ls))
    for unit, (tx, ty), k, d in ((200, (-1, Y), 2, 0), (201, (-1, Y - 1), 3, 4)):
        belts.append((unit, "right", d, {ln: (c[0],) + tuple((tx * 256 + q[0], ty * 256 + q[1]) for q in (turn(c[1], k), turn(c[2], k), turn(c[3], k)))
                                         for ln, c in CURVE.items()}))
    for x in range(n):  # row 9, east
        y9 = {1: (Y - 1) * 256 + 68, 2: (Y - 1) * 256 + 188}
        ls = {ln: (256, (x * 256 + 256, y9[ln]), (x * 256 + 128, y9[ln]), (x * 256, y9[ln])) for ln in (1, 2)}
        belts.append((300 + x, "straight", 4, ls))
    for unit, (tx, ty), k, d in ((202, (n, Y - 1), 0, 8), (203, (n, Y), 1, 12)):
        belts.append((unit, "right", d, {ln: (c[0],) + tuple((tx * 256 + q[0], ty * 256 + q[1]) for q in (turn(c[1], k), turn(c[2], k), turn(c[3], k)))
                                         for ln, c in CURVE.items()}))
    lanes, index = [], {}
    for unit, shape, d, ls in belts:
        for ln in (1, 2):
            length, p0, pm, p1 = ls[ln]
            index[(unit, ln)] = len(lanes) + 1
            lanes.append([unit, name, "transport-belt", shape, d, ln, length, list(p0), list(pm), list(p1), step, 1, []])
    truth0 = {"lanes": lanes}
    world = bs_offline.world_from_truth(truth0)
    # Each line's track round the ring: [(lane index, start, length)] in travel order.
    track = {}
    for ln in (1, 2):
        segs, s = [], 0
        for unit, _shape, _d, ls in belts:
            segs.append((index[(unit, ln)], s, ls[ln][0]))
            s += ls[ln][0]
        track[ln] = (segs, s)
    hands, actors, targets = [], [], []
    for b, put in [(int(v), True) for v in a.puts.split(",") if v.strip()] + [(int(v), False) for v in a.watch.split(",") if v.strip()]:
        j = len(actors) + 1  # (play() finds a hand's inserter at actors[j - 1])
        h = ble.Hand(j, b, not put, a.period if put else 10 ** 9, t0 + 60 + rng.randrange(0, a.period) if put else 10 ** 9, line=1, south=True)
        h.put = put
        h.s = (n - 1 - b) * 256 + 128  # (its drop point along line 1's track: row 10's belt b middle)
        hands.append(h)
        targets.append([700 + j, "wooden-chest" if put else "stone-furnace", "container" if put else "furnace", [b * 256 + 128, (Y + 2) * 256 + 128]])
        actors.append({"u": 500 + j, "n": "inserter", "t": "inserter", "p": [b * 256 + 128, (Y + 1) * 256 + 128],
                       "d": 0 if put else 8, "pk": 100 + b if not put else 700 + j, "dr": 100 + b if put else 700 + j})
    world["actors"], world["targets"] = actors, targets
    uid = 1
    items = {1: [], 2: []}  # line -> [[uid, s]] (s along the track, increasing in travel)
    T2 = track[2][1]
    for k in range(T2 // GAP):
        items[2].append([uid, k * GAP])
        uid += 1
    T1 = track[1][1]
    s = 0
    for k in range(a.block):
        items[1].append([uid, s])
        uid += 1
        s += GAP
    for k in range(a.spaced):
        s += a.spacing - GAP
        if s >= T1 - GAP:
            break
        items[1].append([uid, s])
        uid += 1
        s += GAP
    rows, acts, events = [], [], []

    def step_line(ln):
        lane = items[ln]
        T = track[ln][1]
        if not lane:
            return
        lane.sort(key=lambda it: it[1])
        m = len(lane)
        # (Round the ring the item with the most room ahead moves first, then each behind it up to a gap behind.)
        def ahead(k):
            return (lane[(k + 1) % m][1] - lane[k][1]) % T if m > 1 else T
        first = max(range(m), key=ahead)
        k = first
        for _ in range(m):
            room = ahead(k) - GAP if m > 1 else step
            mv = max(0, min(step, room))
            lane[k][1] = (lane[k][1] + mv) % T
            k = (k - 1) % m

    def lane_pos(ln, s):
        segs, T = track[ln]
        s %= T
        if s == 0:
            s = T
        for li, st, length in segs:
            # (A lane's position counts from its exit, 0 <= p < length as the game lists them: an item on the edge
            # between two lanes is the one it leaves at 0, not the next one at its length.)
            if st < s <= st + length:
                return li, st + length - s
        raise AssertionError(s)

    for t in range(t0, t0 + a.ticks):
        if t > t0:
            for ln in (1, 2):
                step_line(ln)
            for h in hands:
                if not h.put:
                    continue
                h.move(t)
                if not h.held and t >= h.busy_until and t >= h.next:
                    h.held = 1
                    h.leg = (h.at, h.belt_pt, t, t + ble.SWING)
                    h.busy_until = t + ble.SWING
                    h.next = t + a.period + rng.randrange(-a.period // 3, a.period // 3 + 1)
                elif h.held and t >= h.busy_until:
                    T = track[1][1]
                    if all(min((it[1] - h.s) % T, (h.s - it[1]) % T) >= GAP for it in items[1]):
                        items[1].append([uid, h.s])
                        events.append((t, "put", h.j, uid, h.s, 1))
                        uid += 1
                        h.held = 0
                        h.leg = (h.at, h.other_pt, t, t + ble.SWING)
                        h.busy_until = t + ble.SWING
        row = [t]
        for ln in (1, 2):
            on = []
            for u, s in items[ln]:
                li, p = lane_pos(ln, s)
                on.append((li, p, u))
            for li, p, u in sorted(on):  # (each lane's items front first, as the game lists them)
                row += [li, u, p, 1, ln]
        rows.append(row)
        acts.append([(h.j, h.held, h.kind, h.at) for h in hands])
    truth = {"sample": "tick", "lanes": lanes, "ticks": rows, "names": names, "rows": len(rows)}
    return truth, world, acts, events, items


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", required=True, help="a folder for rec.json and stream.jsonl")
    ap.add_argument("--mod", default=str(ROOT / "mod" / "factorio-3d-bridge"))
    ap.add_argument("--tier", default="turbo", choices=sorted(TIERS))
    ap.add_argument("--belts", type=int, default=24, help="belts in each row")
    ap.add_argument("--ticks", type=int, default=2400)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--first", type=int, default=100000, help="the first tick")
    ap.add_argument("--block", type=int, default=30, help="items in the outer lane's packed block")
    ap.add_argument("--spaced", type=int, default=20, help="spaced items behind it")
    ap.add_argument("--spacing", type=int, default=150, help="(1/256) between the spaced items")
    ap.add_argument("--puts", default="", help="row-10 belts with an inserter dropping on the outer lane, b,b,...")
    ap.add_argument("--period", type=int, default=60, help="(--puts) ticks between one inserter's drops, about")
    ap.add_argument("--watch", default="", help="row-10 belts with an idle inserter beside them, b,b,...")
    ap.add_argument("--toggles", default="", help="the bridge's /f3d-bs switches, name=value,...")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args(argv)
    out = pathlib.Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    truth, world, acts, events, items = make_scene(a)
    (out / "rec.json").write_text(json.dumps(truth, separators=(",", ":")))
    (out / "events.json").write_text(json.dumps(events))
    if not a.quiet:
        print("ring: 2x%d %s belts, %d ticks, %d events, items %d/%d" % (a.belts, a.tier, a.ticks, len(events), len(items[1]), len(items[2])))
    ble.play(a.mod, truth, world, acts, str(out / "stream.jsonl"), a.toggles, quiet=a.quiet)


if __name__ == "__main__":
    main()
