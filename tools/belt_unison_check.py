"""Unison: do the client's drawn items on a lane the game has full keep their 0.25-tile spacing, as the
game's do, when a backed-up run starts moving and on a full loop?

    python tools/belt_unison_check.py <truth.json> <draw.bin> [--every N] [--window 30] [--lanes KEY,...]
        [--json out.json] [--gap 0.375] [--show N]

Scored from an every-tick recording (tools/belt_sim/record.py --sample tick) and the client's own records
(--belt-draw-dump, with its .apply.jsonl), placed as the shader places them when the drawn clock showed each
recorded tick (tools/belt_view_check.py's DrawState), the lattice's slots and mask included. For every
recorded tick and every straight lane the game has full (at least 3 items, every gap at most FULL_GAP
1/256, any kinds), the items drawn along that lane (within SIDE tiles of its centre line) are sorted along
it and their spacing compared with 0.25 tile over the span the game's items cover:
  - deviation: the largest |spacing - 0.25| (tiles) on the lane that tick (a drawn item short of the
    span's ends counts as a gap to the end);
  - a gap: any drawn spacing over --gap tiles (default 0.375: a hole half an item wide, what the eye sees
    as a gap), or no drawn item at all.
The same over the WINDOW ticks after a full lane starts moving (its front stood the tick before and moves
now) and over lanes that are full and moving every tick scored (a loop). The game's own numbers (its items
measured the same way) are printed beside, about 0.
"""
import argparse
import bisect
import collections
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import belt_view_check as b  # noqa: E402

FULL_GAP = 66  # 1/256: a lane whose items are at most this far apart in a row is full (belt_lattice.gd)
SIDE = 0.11  # tiles: a drawn item this near a lane's centre line is on it (lanes are 0.46 apart)
SPACING = 0.25


def straight_lanes(truth):
    """{lane key: (exit (x, y), unit dir (x, y) from exit to entry, length tiles)} for straight lanes."""
    out = {}
    for m in truth["lanes"]:
        if m[3] != "straight" or m[2] == "underground-belt" and int(m[5]) > 2:
            continue
        key = int(m[0]) * 8 + int(m[5])
        p0 = (m[7][0] / 256.0, m[7][1] / 256.0)
        p1 = (m[9][0] / 256.0, m[9][1] / 256.0)
        dx, dy = p1[0] - p0[0], p1[1] - p0[1]
        length = math.hypot(dx, dy)
        if length < 1e-6:
            continue
        out[key] = (p0, (dx / length, dy / length), length, int(m[6]))
    return out


def full_lanes(items, lanes):
    """{lane key: (front pos, back pos, n)} for lanes full this tick (truth_rows' items)."""
    per = collections.defaultdict(list)
    for uid, key, item, pos, count in items:
        if key in lanes:
            per[key].append(pos)
    out = {}
    for key, ps in per.items():
        if len(ps) < 3:
            continue
        ps.sort()
        if all(ps[i + 1] - ps[i] <= FULL_GAP for i in range(len(ps) - 1)):
            out[key] = (ps[0], ps[-1], len(ps))
    return out


def spacing_of(along, lo, hi):
    """(largest deviation from SPACING, largest spacing) of sorted positions `along` (tiles along the lane)
    over the span [lo, hi] the game's items cover; nothing drawn: (hi - lo, hi - lo)."""
    pts = [p for p in along if lo - SPACING * 0.5 <= p <= hi + SPACING * 0.5]
    if not pts:
        return hi - lo, hi - lo
    gaps = [pts[i + 1] - pts[i] for i in range(len(pts) - 1)]
    dev = 0.0
    big = 0.0
    for g in gaps:
        big = max(big, g)
        dev = max(dev, abs(g - SPACING))
    # The ends: a drawn item short of the span's end by most of a spacing leaves a gap there (the game has
    # an item there); less is the whole run drawn a little along, not a gap.
    for g in (pts[0] - lo, hi - pts[-1]):
        if g > SPACING * 0.75:
            big = max(big, g)
            dev = max(dev, g - SPACING * 0.75)
    return dev, big


def project(lane, x, z):
    """Position along the lane (tiles from its exit) and distance from its centre line."""
    p0, d, length, _ = lane
    rx, rz = x - p0[0], z - p0[1]
    t = rx * d[0] + rz * d[1]
    side = abs(rx * d[1] - rz * d[0])
    return t, side


class Tally:
    def __init__(self):
        self.lane_ticks = 0
        self.gaps = 0
        self.dev_sum = 0.0
        self.dev_max = 0.0
        self.worst = []  # (dev, tick, key)

    def add(self, dev, big, gap_at, tick, key):
        self.lane_ticks += 1
        self.dev_sum += dev
        self.dev_max = max(self.dev_max, dev)
        if big > gap_at:
            self.gaps += 1
        if len(self.worst) < 400:
            self.worst.append((dev, tick, key))
            self.worst.sort(reverse=True)
        elif dev > self.worst[-1][0]:
            self.worst[-1] = (dev, tick, key)
            self.worst.sort(reverse=True)

    def row(self):
        n = max(1, self.lane_ticks)
        return {"lane_ticks": self.lane_ticks, "gap_pct": 100.0 * self.gaps / n, "dev_mean": self.dev_sum / n,
                "dev_max": self.dev_max}


def analyze(truth, dump, apply_path, every=1, window=30, gap_at=0.375, only=None, show=0, explain=False, ticks_in=None):
    applies = b.read_apply(apply_path) if os.path.exists(apply_path) else []
    rows = b.truth_rows(truth)
    lanes = straight_lanes(truth)
    if only:
        lanes = {k: v for k, v in lanes.items() if k in only}
    placer = b.lane_placer(truth)
    all_ticks = sorted(rows)
    # Full lanes per tick, and the ticks a full lane starts moving at.
    full = {t: full_lanes(rows[t], lanes) for t in all_ticks}
    starts = collections.defaultdict(list)  # tick -> [keys starting to move]
    moving = collections.defaultdict(set)  # tick -> keys full and moving
    for i in range(2, len(all_ticks)):
        t0, t1, t2 = all_ticks[i - 2], all_ticks[i - 1], all_ticks[i]
        for key, (f2, _, _) in full[t2].items():
            e1 = full[t1].get(key)
            e0 = full[t0].get(key)
            if e1 is None:
                continue
            if f2 < e1[0]:
                moving[t2].add(key)
                # (A start: moving now, not the tick before; a front item just taken off leaves a new front
                # further back, so "not moving" is the front not nearer, not the same.)
                if e0 is not None and e1[0] >= e0[0]:
                    starts[t2].append(key)
    # Windows after a start: tick -> keys in a window.
    in_window = collections.defaultdict(set)
    for t, keys in starts.items():
        i = bisect.bisect_left(all_ticks, t)
        for tt in all_ticks[i:i + window]:
            in_window[tt].update(keys)
    dmax, run = [], -1e18
    for a in applies:
        run = max(run, a["drawn"])
        dmax.append(run)
    want = collections.defaultdict(list)
    ticks = all_ticks[::every]
    if ticks_in:
        ticks = [t for t in ticks if ticks_in[0] <= t <= ticks_in[1]]
    first_drawn = applies[0]["drawn"] if applies else 0
    for t in ticks:
        i = bisect.bisect_right(dmax, t) - 1
        if i < 0 or t < first_drawn or t > dmax[-1]:
            continue
        want[int(applies[i]["n"])].append(t)
    # (No apply file: a replay's dump (tests/belt_bs_replay.gd --every-tick). A job's result is drawn at its
    # fold tick: the ticks from one job's fold up to the next's are drawn by the records up to that job.)
    by_fold = not applies
    prev_fold = None
    ticks_left = list(ticks)
    cells = b.lane_cells(placer, {int(m[0]) * 8 + int(m[5]): int(m[6]) for m in truth["lanes"]})
    state = b.DrawState(cells)
    tal = {k: Tally() for k in ("all", "all_game", "start", "start_game", "moving", "moving_game")}
    examples = []
    scored = 0
    for h, ids, recs, gone, paths in b.dump_frames(dump):
        ts = None
        if by_fold:
            fold = float(h.get("fold", -1.0))
            if prev_fold is not None and fold > prev_fold:
                ts = []
                while ticks_left and ticks_left[0] < fold:
                    t = ticks_left.pop(0)
                    if t >= prev_fold:
                        ts.append(t)
            if fold >= 0.0:
                prev_fold = fold if prev_fold is None else max(prev_fold, fold)
        if not by_fold:
            state.apply(ids, recs, gone, paths)
            n = int(h["n"])
            ts = want.get(n)
        if not ts:
            if by_fold:
                state.apply(ids, recs, gone, paths)
            continue
        for t in ts:
            fl = full[t]
            if not fl:
                continue
            scored += 1
            uids, idr, x, z, shown = state.drawn_at(t)
            # Drawn items by lane: those near a full lane's centre line.
            on = collections.defaultdict(list)
            who = collections.defaultdict(list)
            cell = {}
            for key in fl:
                p0, d, length, _ = lanes[key]
                for j in range(int(length) + 2):
                    cx = math.floor((p0[0] + d[0] * j) )
                    cz = math.floor((p0[1] + d[1] * j))
                    for ddx in (-1, 0, 1):
                        for ddz in (-1, 0, 1):
                            c = cell.setdefault((cx + ddx, cz + ddz), set())
                            c.add(key)
            import numpy as np
            idx = np.nonzero(shown)[0]
            for i in idx.tolist():
                c = cell.get((math.floor(x[i]), math.floor(z[i])))
                if not c:
                    continue
                for key in c:
                    along, side = project(lanes[key], float(x[i]), float(z[i]))
                    if side <= SIDE and -SPACING <= along <= lanes[key][2] + SPACING:
                        on[key].append(along)
                        if explain:
                            who[key].append((round(along, 3), int(uids[i]), [int(v) for v in idr[i, 1:].tolist()],
                                             round(float(state.items[int(uids[i])][1][3]), 2), round(float(state.items[int(uids[i])][1][7]), 2)))
            game_on = collections.defaultdict(list)
            for uid, key, item, pos, count in rows[t]:
                if key in fl:
                    game_on[key].append(pos / 256.0)
            for key, (front, back, cnt) in fl.items():
                lo, hi = front / 256.0, back / 256.0
                dev, big = spacing_of(sorted(on.get(key, [])), lo, hi)
                gdev, gbig = spacing_of(sorted(game_on[key]), lo, hi)
                groups = ["all"]
                if key in in_window.get(t, ()):
                    groups.append("start")
                if key in moving.get(t, ()):
                    groups.append("moving")
                for g in groups:
                    tal[g].add(dev, big, gap_at, t, key)
                    tal[g + "_game"].add(gdev, gbig, gap_at, t, key)
                if show and big > gap_at and len(examples) < show and "start" in groups:
                    examples.append({"tick": t, "lane": key, "game": sorted(round(v, 3) for v in game_on[key]),
                                     "drawn": sorted(round(v, 3) for v in on.get(key, [])),
                                     "who": sorted(who.get(key, []))})
        if by_fold:
            state.apply(ids, recs, gone, paths)
    rep = {k: v.row() for k, v in tal.items()}
    rep["ticks_scored"] = scored
    rep["starts"] = sum(len(v) for v in starts.values())
    rep["worst_start"] = tal["start"].worst[:20]
    rep["examples"] = examples
    return rep


def format_report(rep, gap_at):
    lines = []
    p = lines.append
    p("Unison: drawn spacing on lanes the game has full (straight lanes; %d recorded ticks scored; a gap: a drawn spacing over %.3f tile)"
      % (rep["ticks_scored"], gap_at))
    for name, label in (("all", "every full lane-tick"), ("start", "the %d ticks after a full lane starts moving (%d starts)"),
                        ("moving", "full lanes moving (a loop, a flowing bus)")):
        r = rep[name]
        g = rep[name + "_game"]
        if name == "start":
            label = label % (30, rep["starts"])
        p("   %s: %d lane-ticks" % (label, r["lane_ticks"]))
        p("      drawn: gaps %.2f%%, deviation mean %.3f, worst %.3f tile   game: gaps %.2f%%, deviation mean %.3f, worst %.3f"
          % (r["gap_pct"], r["dev_mean"], r["dev_max"], g["gap_pct"], g["dev_mean"], g["dev_max"]))
    for e in rep.get("examples", []):
        p("   e.g. tick %d lane %d: game %s" % (e["tick"], e["lane"], e["game"]))
        p("        drawn %s" % e["drawn"])
        for w in e.get("who", []):
            p("          at %.3f uid %d [item, count, lane, pos, t0, v, reach] %s record t0 %.2f t1 %.2f" % (w[0], w[1], w[2], w[3], w[4]))
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("truth")
    ap.add_argument("dump")
    ap.add_argument("--apply", default="", help="the dump's .apply.jsonl (default: beside it)")
    ap.add_argument("--every", type=int, default=1)
    ap.add_argument("--window", type=int, default=30)
    ap.add_argument("--gap", type=float, default=0.375)
    ap.add_argument("--lanes", default="", help="only these lane keys (comma-separated)")
    ap.add_argument("--show", type=int, default=0, help="print this many example lane-ticks with a gap after a start")
    ap.add_argument("--json", default="")
    ap.add_argument("--explain", action="store_true", help="with --show: each drawn item's record (ids, t0, t1)")
    ap.add_argument("--ticks", default="", help="score only recorded ticks A-B")
    a = ap.parse_args()
    truth = json.load(open(a.truth, encoding="utf-8"))
    only = {int(v) for v in a.lanes.split(",") if v} or None
    ticks_in = tuple(int(v) for v in a.ticks.split("-")) if a.ticks else None
    rep = analyze(truth, a.dump, a.apply or a.dump + ".apply.jsonl", a.every, a.window, a.gap, only, a.show, a.explain, ticks_in)
    print(format_report(rep, a.gap))
    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump(rep, f, indent=1)


if __name__ == "__main__":
    main()
