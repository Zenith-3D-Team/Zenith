#!/usr/bin/env python3
"""A simulation of Factorio's belts (docs/BELT-RULES.md), checked against a recording of the game
(tools/belt_sim/record.py): started from the recording's first tick, stepped a tick at a time, and
given only what the game's inserters, machines and players did (items put on and taken off). Says
how many items are where the game has them every tick, and where they aren't, by kind of piece.

    python tools/belt_sim/sim.py rec.json [--mode free|step] [--explain 5]

--mode step: every tick starts from the game's own state (does one tick's rule hold?); free: the
simulation runs on by itself, only items put on and taken off coming from the game (what the client
would do).

Lanes are the game's own (LuaTransportLine: a belt's lane, an underground's visible half or its
hidden part, a splitter's input or output). A lane goes on into the lane whose entry end is where
its exit end is (position 0, where items leave; positions fall as items go). A lane whose exit leads
nowhere recorded (out of the square, into a splitter or a side-load for now) has its front item
moved as the game moved it: everything behind is the simulation's.
"""

import argparse
import collections
import json

GAP = 64
SPLIT_BUFFER = 51  # a splitter input's end lies this far into its outputs
SHARED = [True]  # a splitter's turn is shared by both its inputs on a side (--per-lane: each its own)
TURNS = {}  # (unit, side) -> the output the next item goes to, when shared


def turn_key(L):
    return (L.unit, (L.line - 1) % 2) if SHARED[0] else (L.unit, L.line)


def next_out(L):
    return TURNS.get(turn_key(L))


def went_into(L, o):
    """After an item went into output o: the next goes into the other one."""
    TURNS[turn_key(L)] = L.split[1] if o is L.split[0] else L.split[0]


class Lane:
    __slots__ = ("j", "unit", "name", "type", "shape", "dir", "line", "length", "exit", "mid", "entry",
                 "step", "status", "next", "kind", "items", "side", "split", "turn", "prio")

    def __init__(self, j, m):
        self.j = j
        (self.unit, self.name, self.type, self.shape, self.dir, self.line, self.length, self.exit,
         self.mid, self.entry, self.step, self.status) = m[:12]
        sp = m[12] if len(m) > 12 and m[12] else ["none", "none", ""]
        self.prio = sp  # a splitter's input priority, output priority, filter (record.py)
        self.next = None   # the lane items go on into when they leave this one at 0
        self.side = None   # or (lane, position) where it side-loads onto another lane
        self.split = None  # a splitter's input: its two outputs on the same side (this half's first)
        self.turn = None   # and which of them the next item goes to (None: not known yet)
        self.items = []    # [pos, uid, count, item], front (smallest pos) first
        self.kind = self.type if self.type != "transport-belt" else ("curve" if self.shape in ("left", "right") else "straight")
        if self.type == "underground-belt" and self.line > 2:
            self.kind = "underground hidden"


def near(a, b, d=4):
    return abs(a[0] - b[0]) <= d and abs(a[1] - b[1]) <= d


def build(lanes):
    """Each lane's next; and the order to step them in: a lane after the lane in front of it."""
    by_entry = collections.defaultdict(list)
    for L in lanes:
        by_entry[(L.entry[0] // 32, L.entry[1] // 32)].append(L)
    for A in lanes:
        cx, cy = A.exit[0] // 32, A.exit[1] // 32
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for B in by_entry.get((cx + dx, cy + dy), []):
                    if B is not A and near(A.exit, B.entry):
                        A.next = B
    # Splitters: inputs are lines 1-4 (two belts' two lanes), outputs 5-8; an item leaving an input
    # goes on into the output of either belt on its own side, 51 steps into it (position 77).
    by_unit = collections.defaultdict(dict)
    for L in lanes:
        if L.type == "splitter":
            by_unit[L.unit][L.line] = L
    for u, ls in by_unit.items():
        for k in range(1, 5):
            L = ls.get(k)
            if L is None:
                continue
            half, side = (k - 1) // 2, (k - 1) % 2
            own, other = ls.get(5 + 2 * half + side), ls.get(5 + 2 * (1 - half) + side)
            L.next = None
            L.split = [own, other]
    # Which output belt is on the left (looking the way items go): for an output priority.
    for u, ls in by_unit.items():
        o5, o7 = ls.get(5), ls.get(7)
        if o5 is None or o7 is None:
            continue
        vx, vy = o5.exit[0] - o5.entry[0], o5.exit[1] - o5.entry[1]
        lx, ly = vy, -vx  # left of the way items go (y grows south)
        left_is_5 = (o5.exit[0] * lx + o5.exit[1] * ly) > (o7.exit[0] * lx + o7.exit[1] * ly)
        for k in range(1, 9):
            L = ls.get(k)
            if L is not None:
                L.turn = left_is_5  # (kept here: whether lines 5-6 are the left output)
    # Side-loads: a straight lane whose exit is level with the middle of a lane of the belt in front
    # of it, across that lane: it joins there (only the nearer of that belt's two lanes takes it).
    by_unit = collections.defaultdict(list)
    for L in lanes:
        by_unit[L.unit].append(L)
    for A in lanes:
        if A.next is not None or A.split is not None or A.type == "splitter":
            continue
        best = None
        for B in lanes:
            if B.unit == A.unit or B.length != 256 or B.type != "transport-belt":
                continue
            ex, ey = B.exit
            nx, ny = B.entry
            vx, vy = ex - nx, ey - ny  # along B, the way items go
            n2 = vx * vx + vy * vy
            if n2 == 0:
                continue
            u = ((A.exit[0] - nx) * vx + (A.exit[1] - ny) * vy) / n2  # 0 at B's entry, 1 at its exit
            if not 0.05 < u < 0.95:
                continue
            px, py = nx + vx * u, ny + vy * u
            d = ((A.exit[0] - px) ** 2 + (A.exit[1] - py) ** 2) ** 0.5
            if d < 140 and (best is None or d < best[0]):
                best = (d, B, round((B.length - 1) * (1 - u)))
        if best is not None:
            A.side = (best[1], best[2])
    # The order to step lanes in: each after every lane its items may go on into (its next, the lane
    # it side-loads onto, both of a splitter input's outputs), so it sees their items where they are
    # this tick; a ring is started anywhere (ahead_limit takes care of it).
    def deps(x):
        if x.next is not None:
            return [x.next]
        if x.side is not None:
            return [x.side[0]]
        if x.split is not None:
            # (All four of its splitter's outputs: its inputs are stepped together, below.)
            return outs_of.get(x.unit, [])
        return []
    outs_of = collections.defaultdict(list)
    for L in lanes:
        if L.type == "splitter" and L.line > 4:
            outs_of[L.unit].append(L)
    order, state = [], {}
    for L in lanes:
        if id(L) in state:
            continue
        stack = [(L, 0)]
        while stack:
            x, i = stack.pop()
            if i == 0:
                if id(x) in state:
                    continue
                state[id(x)] = 1  # being visited
            ds = deps(x)
            if i < len(ds):
                stack.append((x, i + 1))
                y = ds[i]
                if id(y) not in state:
                    stack.append((y, 0))
            else:
                state[id(x)] = 2
                order.append(x)
    # A splitter's inputs together, by line (1 to 4), where the first of them came: when two want the
    # same room on an output in one tick, the lower line gets it (Zenith Test: line 2 before line 4).
    inputs = collections.defaultdict(list)
    for L in order:
        if L.split is not None:
            inputs[L.unit].append(L)
    out, placed = [], set()
    for L in order:
        if L.split is not None:
            if L.unit in placed:
                continue
            placed.add(L.unit)
            out.extend(sorted(inputs[L.unit], key=lambda x: x.line))
        else:
            out.append(L)
    return out


def ahead_limit(L, done):
    """Where (in L's positions) the front item of L may go: GAP behind the hindmost item ahead,
    through the lanes in front; 0 at the end of what is known; None when the lane in front is
    unknown and empty as far as we can see."""
    off = 0
    x = L.next
    while x is not None:
        off += x.length
        if x.items:
            # A lane in front not stepped yet this tick (a ring of belts, started somewhere): its
            # hindmost item as it will be once it moved its step.
            it = x.items[-1]
            if id(x) in done:
                back, old = it[0], it[4]
            else:
                back, old = it[0] - x.step, it[0]
            # (In L's positions: where it is now, and where it was before this tick's move.)
            return (back - off, old - off)
        if off > 4 * GAP:
            return -10 ** 9  # nothing near ahead
        x = x.next
    # Empty lanes in front as far as the recording goes: on to the end of the last of them (beyond,
    # the game's own items decide; an item that leaves the square is taken off there).
    return None if L.next is None else -off


TICK = [0]


def tick(order, game_next, given):
    TICK[0] += 1
    now = TICK[0]
    done = set()
    for L in order:
        done.add(id(L))
        if not L.items:
            continue
        for it in L.items:
            while len(it) < 6:
                it.append(it[0] if len(it) == 4 else -1)
        limit = ahead_limit(L, done)
        if L.side is not None or L.split is not None:
            limit = -10 ** 9  # (its front item joins the other lane below, or waits at 0)
        elif limit is None:
            limit = 0
            if L.next is None:
                # The front leads nowhere recorded: its front item does what the game did.
                u = L.items[0][1]
                g = game_next.get(u)
                given.add(u)
                if g is not None and g[0] is L:
                    limit = g[1]
                else:
                    limit = -10 ** 9  # it left the square (taken off below)
        # Each item moves its step, but never closes the gap to the item in front below 64, nor
        # below what it already was (an inserter or a side-load squashed it in closer: the game
        # keeps such a gap while the line flows, and only opens it).
        ahead = limit if isinstance(limit, tuple) else None
        if ahead is not None:
            limit = None
        moved = []
        for it in L.items:
            if it[5] == now:
                # Came onto this lane this tick from one stepped before it (a splitter's output
                # stepped after its input): it has moved already.
                ahead = (it[0], it[4])
                moved.append(it)
                continue
            it[5] = now
            it[4] = it[0]
            if ahead is not None:
                lim = ahead[0] + min(GAP, it[0] - ahead[1])
            else:
                lim = limit
            free = it[0] - L.step
            N = L.next
            if free < 0 and N is not None and N.step != L.step:
                # Onto a belt of another speed: the rest of the tick at its speed (an express item
                # 19 from the end goes 19, then 5/24 of a tick on yellow: 1; rounded down).
                free = -(((L.step - it[0]) * N.step) // L.step)
            new = max(free, lim)
            if new > it[0]:
                new = it[0]
            it[0] = new
            ahead = (new, it[4])
            moved.append(it)
        # Items past the exit go on into the next lane, at its back; side-loading ones join the other
        # lane where there is room (64 to the item in front, 61 to the one behind: the squash), else
        # wait at the end.
        stay = []
        for it in moved:
            if it[0] < 0 and L.next is not None:
                N = L.next
                it[0] += N.length
                it[4] += N.length
                N.items.append(it)
            elif it[0] < 0 and L.split is not None:
                # Into the output the splitter's turn says, where there is room, else the other.
                want = next_out(L)
                pr = L.prio[1] if L.prio else "none"
                if pr in ("left", "right"):
                    # An output priority: that output whenever it has room.
                    left_half = 0 if L.turn else 1
                    want_half = left_half if pr == "left" else 1 - left_half
                    half = (L.line - 1) // 2
                    want = L.split[0] if want_half == half else L.split[1]
                elif want is None:
                    # Not known yet (the game's own state can't be read): the way the game sent it.
                    g = game_next.get(it[1])
                    want = g[0] if g is not None and g[0] in L.split else L.split[0]
                tries = [want, L.split[1] if want is L.split[0] else L.split[0]]
                went = False
                for o in tries:
                    if o is None:
                        continue
                    # An input's end is the output's back edge: on by what is left of the step, never
                    # closer than 64 behind the output's hindmost item (3,005 crossings on Zenith Test
                    # landed exactly 64 behind it).
                    # (Its end lies 51 steps into the output: an item leaving it is at 77 there, on by
                    # what is left of its step; behind an item already there, 64 behind it.)
                    at = o.length - SPLIT_BUFFER + it[0]
                    if o.items:
                        at = max(at, o.items[-1][0] + GAP)
                    if at < o.length:  # (strictly: never on its back edge; the highest seen was 126)
                        it[0] = at
                        it[4] = at
                        o.items.append(it)
                        o.items.sort()
                        went = True
                        went_into(L, o)
                        break
                if not went:
                    it[0] = 0
                    stay.append(it)
            elif it[0] < 0 and L.side is not None:
                B, j = L.side
                at = j - 1 + it[0]  # (the game lands it a step past the point level with the side lane: 59 for 68 moving 8)
                if all(q[0] <= at - GAP or q[0] >= at + GAP - 3 for q in B.items):
                    it[0] = at
                    it[4] = at
                    B.items.append(it)
                    B.items.sort()
                else:
                    it[0] = 0
                    stay.append(it)
            else:
                stay.append(it)
        L.items = stay
        if L.side is not None or L.split is not None:
            # (Items behind one that waited at 0 stand a gap behind it.)
            lim = None
            for it in L.items:
                if lim is not None and it[0] < lim:
                    it[0] = lim
                lim = it[0] + GAP
    for L in order:
        L.items.sort()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("rec")
    ap.add_argument("--mode", default="step", choices=["step", "free"])
    ap.add_argument("--explain", type=int, default=0)
    ap.add_argument("--per-lane", action="store_true")
    a = ap.parse_args()
    SHARED[0] = not a.per_lane
    d = json.load(open(a.rec))
    lanes = [Lane(j + 1, m) for j, m in enumerate(d["lanes"])]
    order = build(lanes)
    kinds = collections.Counter(L.kind for L in lanes)
    print("%d lanes (kinds %s); lanes going on into none recorded: %d; side-loads: %s" % (
        len(lanes), dict(kinds), sum(1 for L in lanes if L.next is None and L.side is None),
        [(L.j, L.side[0].j, L.side[1]) for L in lanes if L.side]))
    ticks = d["ticks"]

    def state(row):
        out = {}
        for i in range(1, len(row), 5):
            out[row[i + 1]] = (lanes[row[i] - 1], row[i + 2], row[i + 3], row[i + 4])
        return out

    def load(st):
        for L in lanes:
            L.items = []
        for u, (L, p, n, it) in st.items():
            L.items.append([p, u, n, it])
        for L in lanes:
            L.items.sort()

    right = wrong = 0
    by_kind, tot_kind = collections.Counter(), collections.Counter()
    ctx = collections.Counter()
    shown = put = took = 0
    started = False
    for t in range(len(ticks) - 1):
        game_now, game_next = state(ticks[t]), state(ticks[t + 1])
        if not started or a.mode == "step":
            load(game_now)
            started = True
        given = set()
        tick(order, game_next, given)
        where = {}
        for L in lanes:
            for it in L.items:
                where[it[1]] = (L, it[0])
        for u, (L, p, n, it) in game_next.items():
            if u not in where or u in given:
                continue
            tot_kind[L.kind] += 1
            SL, sp = where[u]
            if SL is L and sp == p:
                right += 1
            else:
                wrong += 1
                by_kind[L.kind] += 1
                nx = L.next.kind + "/%d" % L.next.step if L.next else ("split" if L.split else ("side" if L.side else "none"))
                ctx[(L.kind + "/%d" % L.step, nx, "sim ahead" if (SL is L and sp < p) else ("sim behind" if SL is L else "other lane"))] += 1
                if shown < a.explain:
                    shown += 1
                    print("  tick %d item %d: game on lane %d (%s %s, line %d) at %d; simulated on lane %d (%s) at %d" % (
                        ticks[t + 1][0], u, L.j, L.kind, L.name, L.line, p, SL.j, SL.kind, sp))
        # What the game put on and took off: items it has that the simulation doesn't, and back.
        changed = False
        for L in lanes:
            keep = [it for it in L.items if it[1] in game_next]
            took += len(L.items) - len(keep)
            if len(keep) != len(L.items):
                L.items = keep
        for u, (L, p, n, it) in game_next.items():
            if u not in where:
                L.items.append([p, u, n, it])
                put += 1
                changed = True
        if changed:
            for L in lanes:
                L.items.sort()
    print("mode %s: %d item-ticks where the game has them, %d not (%.3f%%); put on %d, taken off %d" % (
        a.mode, right, wrong, 100.0 * wrong / max(1, right + wrong), put, took))
    for k, n in ctx.most_common(12):
        print("  wrong on %-24s into %-24s %-11s %d" % (k[0], k[1], k[2], n))
    for k in sorted(tot_kind, key=lambda k: -by_kind[k]):
        print("  %-20s %8d item-ticks, %6.3f%% not where the game has them" % (k, tot_kind[k], 100.0 * by_kind[k] / tot_kind[k]))


if __name__ == "__main__":
    main()
