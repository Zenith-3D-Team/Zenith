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
hidden part, a splitter's or lane splitter's input or output). A lane goes on into the lane whose
entry end is where its exit end is (position 0, where items leave; positions fall as items go), or
side-loads onto the lane its exit lies across, or (a splitter's input) into its splitter's outputs.
A lane whose exit leads nowhere recorded (out of the square) has its front item moved as the game
moved it: everything behind is the simulation's.

tick() steps build()'s order: each lane after the lanes its items may go on into (step_lane()), and a
Splitter (docs/BELT-RULES.md section 6) once all four of its outputs have moved: it steps its inputs
side by side, in the order its inputs' turn says (step_side()), placing their front items by its
output turn, priorities and filter.
"""

import argparse
import collections
import json

GAP = 64
SPLIT_BUFFER = 51  # a splitter input's end lies this far into its outputs


class Splitter:
    """A splitter's state and rules (docs/BELT-RULES.md section 6). Its belts are halves 0 (lines 1-2 in,
    5-6 out) and 1 (lines 3-4, 7-8); a side is a lane side (0: lines 1, 3, 5, 7; 1: lines 2, 4, 6, 8):
    items never change side. Per side it keeps two turns, measured on the lab scenes:
    - out_turn: the half whose output the next item goes to. An item going into the output it was
      meant for, or into the other because that one was full, leaves the turn at the half it didn't
      go to: items alternate between the outputs, inputs' items taken together.
    - in_turn: the half whose input goes first in a tick: the one whose item didn't go last. Two inputs
      wanting the one free place take turns (the lab: line 1, line 3, line 1, ... every 8 ticks).
    The game shows neither (no LuaEntity field), so both start unknown: the first item to cross on a
    side tells them (the reference looks at what the game did; the client at the first lanes the
    bridge reads after a crossing)."""

    def __init__(self, unit, ls, names):
        self.unit = unit
        self.ins = [[ls.get(1), ls.get(2)], [ls.get(3), ls.get(4)]]
        self.outs = [[ls.get(5), ls.get(6)], [ls.get(7), ls.get(8)]]
        self.out_turn = [None, None]
        self.in_turn = [None, None]
        any_lane = next(L for L in ls.values())
        inp, outp, flt = (any_lane.prio + ["none", "none", ""])[:3]
        # Which half is the left belt, looking the way items go (an output or input priority names it).
        o5, o7 = ls.get(5), ls.get(7)
        left = 0
        if o5 is not None and o7 is not None:
            vx, vy = o5.exit[0] - o5.entry[0], o5.exit[1] - o5.entry[1]
            lx, ly = vy, -vx  # left of the way items go (y grows south)
            left = 0 if (o5.exit[0] * lx + o5.exit[1] * ly) > (o7.exit[0] * lx + o7.exit[1] * ly) else 1
        self.in_prio = {"left": left, "right": 1 - left}.get(inp)
        self.out_prio = {"left": left, "right": 1 - left}.get(outp)
        self.filter = flt or ""
        self.names = names
        self.crossed = 0  # items that crossed (step_side: whether its turn was seen)

    def inputs(self, side):
        """The side's two inputs in the order the game takes their items this tick."""
        first = self.in_prio if self.in_prio is not None else (self.in_turn[side] or 0)
        return [self.ins[first][side], self.ins[1 - first][side]]

    def targets(self, half, side, item):
        """The outputs an item may go into, in the order tried."""
        a, b = self.outs[0][side], self.outs[1][side]
        if self.filter:
            # A filter sends the matching items to the priority side only and every other item to the
            # other side only; a full output makes them wait.
            hit = self.names[item - 1] == self.filter if self.names else str(item) == self.filter
            fh = self.out_prio if self.out_prio is not None else 0
            return [self.outs[fh if hit else 1 - fh][side]]
        if self.out_prio is not None:
            return [self.outs[self.out_prio][side], self.outs[1 - self.out_prio][side]]
        t = self.out_turn[side]
        t = 0 if t is None else t
        return [self.outs[t][side], self.outs[1 - t][side]]

    def went(self, half, side, out_half):
        self.crossed += 1
        self.out_turn[side] = 1 - out_half
        self.in_turn[side] = 1 - half


class Lane:
    __slots__ = ("j", "unit", "name", "type", "shape", "dir", "line", "length", "exit", "mid", "entry",
                 "step", "status", "next", "kind", "items", "side", "split", "half", "sside", "prio", "succ", "prevs")

    def __init__(self, j, m):
        self.j = j
        (self.unit, self.name, self.type, self.shape, self.dir, self.line, self.length, self.exit,
         self.mid, self.entry, self.step, self.status) = m[:12]
        sp = m[12] if len(m) > 12 and m[12] else ["none", "none", ""]
        self.prio = sp  # a splitter's input priority, output priority, filter (record.py)
        # The pieces the game says items go on into (record.py's meta since the splitter work: an
        # underground entrance's partner, belt_neighbours' outputs); None in older recordings.
        self.succ = set(m[13]) if len(m) > 13 and isinstance(m[13], list) else None
        self.next = None   # the lane items go on into when they leave this one at 0
        self.prevs = []    # the lanes whose next this is
        self.side = None   # or (lane, position) where it side-loads onto another lane
        self.split = None  # a splitter's input: its Splitter
        self.half = None   # and which of its belts it is (0: lines 1-2, 1: lines 3-4)
        self.sside = None  # and its lane side (0: lines 1, 3; 1: lines 2, 4)
        self.items = []    # [pos, uid, count, item], front (smallest pos) first
        self.kind = self.type if self.type != "transport-belt" else ("curve" if self.shape in ("left", "right") else "straight")
        if self.type == "underground-belt" and self.line > 2:
            self.kind = "underground hidden"


def near(a, b, d=4):
    return abs(a[0] - b[0]) <= d and abs(a[1] - b[1]) <= d


def build(lanes, names=None):
    """Each lane's next; and the order to step them in: a lane after the lane in front of it."""
    by_entry = collections.defaultdict(list)
    for L in lanes:
        by_entry[(L.entry[0] // 32, L.entry[1] // 32)].append(L)
    lane_of = {(L.unit, L.line): L for L in lanes}
    for A in lanes:
        if A.type == "underground-belt" and A.shape == "input" and A.line <= 2:
            # An entrance's visible half goes on into its own hidden line under the ground (lines 3-4),
            # never into another piece that happens to lie there (undergrounds of other pairs weave
            # through the same tiles on Zenith Test).
            A.next = lane_of.get((A.unit, A.line + 2))
            if A.next is not None:
                continue
        cx, cy = A.exit[0] // 32, A.exit[1] // 32
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for B in by_entry.get((cx + dx, cy + dy), []):
                    if B is A or not near(A.exit, B.entry):
                        continue
                    if B.type == "underground-belt" and B.line > 2:
                        # Only an entrance's own visible half feeds its hidden line, and an exit's lines
                        # 3-4 (its back half, a segment of their own) take nothing from the belt.
                        continue
                    if A.succ is not None and B.unit not in A.succ:
                        continue  # the game's own neighbour (record.py's meta) when recorded
                    A.next = B
    # Splitters: inputs are lines 1-4 (two belts' two lanes), outputs 5-8; an item leaving an input
    # goes on into the output of either belt on its own side, 51 steps into it (position 77).
    # A lane splitter is a splitter of one side: its lanes 1 and 2 are its two inputs (halves 0 and 1),
    # 3 and 4 its outputs, 179 and 128 long as a splitter's, by the same rules (lab: both lanes fed,
    # lane 1's items went to lane 4 and lane 2's to lane 3 every time; one lane fed, 4, 3, 4, 3, ...).
    by_unit = collections.defaultdict(dict)
    for L in lanes:
        if L.type == "splitter":
            by_unit[L.unit][L.line] = L
        elif L.type == "lane-splitter":
            by_unit[L.unit][{1: 1, 2: 3, 3: 5, 4: 7}.get(L.line, 0)] = L
    splitters = {}
    for u, ls in by_unit.items():
        sp = splitters[u] = Splitter(u, ls, names)
        for k in range(1, 5):
            L = ls.get(k)
            if L is not None:
                L.next = None
                L.split = sp
                L.half = (k - 1) // 2
                L.sside = (k - 1) % 2
    for L in lanes:
        if L.next is not None:
            L.next.prevs.append(L)
    # Side-loads: a straight lane whose exit is level with the middle of a lane of the belt in front
    # of it, across that lane: it joins there (only the nearer of that belt's two lanes takes it).
    by_unit = collections.defaultdict(list)
    for L in lanes:
        by_unit[L.unit].append(L)
    for A in lanes:
        if A.next is not None or A.split is not None:
            continue  # (a splitter's outputs side-load like belts; its inputs go into its outputs)
        best = None
        for B in lanes:
            if B.unit == A.unit or not ((B.type == "transport-belt" and B.length == 256) or
                                        (B.type == "underground-belt" and B.line <= 2)):
                continue  # (a straight belt, or an underground's visible half: Zenith Test side-loads
                # an express splitter onto a yellow entrance, its item joining the near lane at 117)
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
        if isinstance(x, Splitter):
            return outs_of.get(x.unit, [])
        if x.next is not None:
            return [x.next]
        if x.side is not None:
            return [x.side[0]]
        if x.split is not None:
            return [x.split]  # (its splitter steps it, with the other inputs: below)
        return []
    outs_of = collections.defaultdict(list)
    for L in lanes:
        if (L.type == "splitter" and L.line > 4) or (L.type == "lane-splitter" and L.line > 2):
            outs_of[L.unit].append(L)
    order, state = [], {}
    for L in lanes + list(splitters.values()):
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
    # (A splitter's inputs aren't in the order themselves: their Splitter is, after all four of its
    # outputs, and steps them.)
    return [x for x in order if not (isinstance(x, Lane) and x.split is not None)]


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
# --crossings-from-game N (the cross round, docs/BELT-SIM-PLAN.md): every N ticks each splitter's output lanes
# (and with --xinputs its inputs) are set to the game's at that tick, items placed by id wherever the
# simulation had them, as the client does with the bridge's `sl` of those lanes in `/f3d-bs crossings game`.
# XHOLD: between those reads no item crosses a splitter (it waits at its input's end); else the simulation
# crosses as it does and the read corrects it. XSTATS counts what the reads had to move.
XGAME = [0]
XHOLD = [False]
XINPUTS = [False]
XNOBACK = [False]  # predict: an item the simulation crossed before the game did stays on its output
XRECROSS = [False]  # predict: an input a read put an item back onto may cross again before the next read
XHELD = set()  # ids of input lanes held till the next read (an item was put back onto them)
XSTATS = collections.Counter()
# --split-wake (docs/BELT-RULES.md section 6, the client's split_wake): an output that stood last tick takes
# nothing this tick from a splitter side that let an item through one or two ticks ago (three, while its
# other output moves) unless it had room before its own move. MOVED: id(lane) -> whether its items moved
# last tick; LAST_X: (unit, side) -> the tick an item last crossed there.
SPLIT_WAKE = [False]
MOVED = {}
LAST_X = {}


def tick(order, game_next, given):
    """One tick of every lane, in build()'s order: lanes in front first; a splitter's inputs once all
    four of its outputs have moved, side by side, in the order its in_turn says."""
    TICK[0] += 1
    now = TICK[0]
    done = set()
    snap = {}
    if SPLIT_WAKE[0]:
        for x in order:
            if isinstance(x, Lane) and x.type in ("splitter", "lane-splitter"):
                snap[id(x)] = (x, [(it[0], it[1]) for it in x.items])
    for x in order:
        if isinstance(x, Splitter):
            for side in (0, 1):
                step_side(x, side, now, done, game_next, given)
        else:
            step_lane(x, now, done, game_next, given)
    for x in order:
        if isinstance(x, Lane):
            x.items.sort()
        else:
            for L in x.ins[0] + x.ins[1]:
                if L is not None:
                    L.items.sort()
    if SPLIT_WAKE[0]:
        MOVED.clear()
        for k, (L, before) in snap.items():
            MOVED[k] = before != [(it[0], it[1]) for it in L.items]


def step_side(sp, side, now, done, game_next, given):
    """A splitter side's two inputs. While its in_turn isn't known (the first ticks of a recording),
    both orders are tried and the one that does what the game did is kept."""
    if sp.in_turn[side] is not None or sp.in_prio is not None:
        for L in sp.inputs(side):
            if L is not None:
                step_lane(L, now, done, game_next, given)
        return
    lanes = [L for L in (sp.ins[0][side], sp.ins[1][side], sp.outs[0][side], sp.outs[1][side]) if L is not None]
    saved = [(L, [list(it) for it in L.items]) for L in lanes]
    out_turn = list(sp.out_turn)
    for first in (0, 1):
        if first == 1:
            for L, its in saved:
                L.items = [list(it) for it in its]
            sp.out_turn = list(out_turn)
        sp.in_turn[side] = first
        before = sp.crossed
        for L in sp.inputs(side):
            if L is not None:
                step_lane(L, now, done, game_next, given)
        if all(it[1] not in game_next or (game_next[it[1]][0] is L and game_next[it[1]][1] == it[0])
               for L in lanes for it in L.items):
            break
    if sp.crossed == before:
        sp.in_turn[side] = None  # (nothing crossed: still not known)


def fallback_ok(L, it, prio):
    """With an output priority, may an item the priority output (prio) has no room for go into the
    other output this tick? Measured (lab scenes splitters3, 4, 6; Zenith Test's turbo splitters):
    - nothing follows it on its input's transport line: at once (Zenith Test's lone items);
    - the item behind it stood 64 behind it all last tick (its line has stopped): it goes on a whole
      step (77 - 32 = 45 on turbo), the lab at every phase of the item behind;
    - the priority output's hindmost standing further back than 64 (Zenith Test: at 91; the lab's at
      64 never did this), the item behind comes within 64 of it this tick: it goes just far enough,
      64 ahead of the item behind (71 = 77 - 6 with the item behind moving from 90 to 58). Not always:
      on a second recording of Zenith Test 6 of 23 such items waited for their line to stop instead,
      the same tick for tick as some that didn't (not found in anything recorded: the game's own
      update order or sleeping lines, likely). sim.py takes the more common way.
    (it: the front item after this tick's move, it[4] where it was before.)"""
    if len(L.items) > 1 and L.items[1] is not it:
        nxt = L.items[1]
        if nxt[4] - it[4] <= GAP:
            return True
        if prio.items and prio.items[-1][0] + GAP > prio.length and nxt[0] - GAP < 0:
            it[0] = nxt[0] - GAP
            return True
        return False
    x = L
    for _ in range(64):
        if len(x.prevs) != 1:
            break
        x = x.prevs[0]
        if x.items:
            return False
    return True


def step_lane(L, now, done, game_next, given):
    """One tick of one lane's items (see tick())."""
    if True:
        done.add(id(L))
        if not L.items:
            return
        for it in L.items:
            while len(it) < 7:
                # [pos, uid, count, item, pos before this tick's move, tick it last moved, held by a
                # priority input's squash]
                it.append((it[0], -1, False)[len(it) - 4])
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
                # (it[6]: put in closer than 64 by a splitter's priority input: stands till it is 64.)
                lim = ahead[0] + (GAP if it[6] else min(GAP, it[0] - ahead[1]))
            else:
                lim = limit
            if L.next is None and L.side is None and L.split is None and moved and moved[-1][0] < 0:
                # The item in front left the square this tick: where it went (and so how far this one
                # may follow) isn't recorded, so this one too does what the game did.
                g = game_next.get(it[1])
                if g is not None and g[0] is L:
                    lim = g[1]
                    given.add(it[1])
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
            elif it[0] < 0 and L.split is not None and XGAME[0] and (XHOLD[0] or id(L) in XHELD):
                it[0] = 0  # (crossings come from the game's reads: it waits)
                stay.append(it)
            elif it[0] < 0 and L.split is not None:
                sp, side = L.split, L.sside
                if sp.out_turn[side] is None and sp.out_prio is None and not sp.filter:
                    # Its turn not known yet (the game's own state can't be read): the way the game
                    # sent this item says it.
                    g = game_next.get(it[1])
                    for h in (0, 1):
                        if g is not None and g[0] is sp.outs[h][side]:
                            sp.out_turn[side] = h
                went = False
                tries = sp.targets(L.half, side, it[3])
                for k, o in enumerate(tries):
                    if o is None:
                        continue
                    if k == 1 and sp.out_prio is not None and tries[0] is not None and not fallback_ok(L, it, tries[0]):
                        break
                    # An input's end lies 51 steps into the outputs: an item leaving it is at 77 there,
                    # on by what is left of its step; behind an item already there (after that
                    # output's move this tick), 64 behind it; never on the output's back edge (128) or
                    # past it, else it tries the other output, else it waits at 0.
                    at = o.length - SPLIT_BUFFER + it[0]
                    if o.items:
                        at = max(at, o.items[-1][0] + GAP)
                        if (SPLIT_WAKE[0] and at < o.length and sp.in_prio is None and sp.out_prio is None and not sp.filter
                                and not MOVED.get(id(o), True)):
                            lx = now - LAST_X.get((sp.unit, side), -100)
                            oo = sp.outs[1][side] if o is sp.outs[0][side] else sp.outs[0][side]
                            b = o.items[-1]
                            if (1 <= lx <= 2 or (lx == 3 and oo is not None and MOVED.get(id(oo), False))) and                                     (b[4] if len(b) > 5 and b[5] == now else b[0]) + GAP >= o.length:
                                continue
                    hold = False
                    if at >= o.length and sp.in_prio == L.half and (not o.items or o.items[-1][0] < o.length - 1):
                        # The priority input's item goes in anyway, at the output's back (127), however
                        # close the item in front (15 seen), and stands there until it is 64 behind it
                        # (lab, input priority: it never waits while the output's back is free).
                        at, hold = o.length - 1, True
                    if at < o.length:
                        it[0] = at
                        it[4] = at
                        it[5] = now
                        it[6] = hold
                        o.items.append(it)
                        o.items.sort()
                        went = True
                        LAST_X[(sp.unit, side)] = now
                        sp.went(L.half, side, 0 if o is sp.outs[0][side] else 1)
                        break
                if not went:
                    it[0] = 0
                    stay.append(it)
            elif it[0] < 0 and L.side is not None:
                B, j = L.side
                at = j - 1 + it[0]  # (the game lands it a step past the point level with the side lane: 59 for 68 moving 8)
                # Where an item of the main lane (after its move this tick) is in the way, the side item
                # goes in 64 behind it instead, and behind the next one if that is in the way too:
                # Zenith Test's packed side-loads joined at the back of the main lane's queue every
                # time (52 joins: nominal 172 with items at 47..175 landed at 239 = 175 + 64).
                for q in B.items:
                    if at - GAP < q[0] < at + GAP - 3:
                        at = q[0] + GAP
                # But never further back than the side lane's own width: up to 60 past the point (the
                # side belt's lane runs 60 either side of it); beyond, it waits (a downstream lane at 68
                # with the main lane's queue reaching 252 waited for 600 ticks).
                if at <= j + 60 and at < B.length:
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


def apply_turns(splitters, lanes, game_next, now):
    """--xmode turns: the read only says which output each crossed item took (a compact crossing log):
    an item the simulation sent to the other output is moved across at its own position; one the game
    crossed that the simulation still holds on an input goes in at the output's back; the side's turn is
    set from the game's newest crossing. Nothing else moves."""
    where = {}
    for L in lanes:
        for it in L.items:
            where[it[1]] = L
    for sp in splitters:
        for side in (0, 1):
            outs = [sp.outs[0][side], sp.outs[1][side]]
            ins = [sp.ins[0][side], sp.ins[1][side]]
            newest = None
            for h, o in enumerate(outs):
                if o is None:
                    continue
                for u, (GL, p, n, it) in game_next.items():
                    if GL is not o:
                        continue
                    if newest is None or p > newest[0]:
                        newest = (p, h)
                    w = where.get(u)
                    if w is None or w is o:
                        continue
                    if w is outs[1 - h]:
                        rec = next(x for x in w.items if x[1] == u)
                        w.items.remove(rec)
                        o.items.append(rec)
                        o.items.sort()
                        XSTATS["moved to the other output"] += 1
                        where[u] = o
                    elif w in ins:
                        rec = next(x for x in w.items if x[1] == u)
                        at = o.length - SPLIT_BUFFER
                        if o.items:
                            at = max(at, o.items[-1][0] + GAP)
                        if at < o.length:
                            w.items.remove(rec)
                            rec[0] = at
                            rec[4] = at
                            rec[5] = now
                            o.items.append(rec)
                            o.items.sort()
                            where[u] = o
                            XSTATS["crossed late (put in)"] += 1
                            # (the line behind it closes up on its next tick)
                        else:
                            XSTATS["crossed late (no room)"] += 1
            if newest is not None and sp.out_prio is None and not sp.filter:
                sp.out_turn[side] = 1 - newest[1]


def apply_crossings(splitters, lanes, game_next, now):
    """A read of every splitter's output lanes (and inputs, with --xinputs) as the game has them at this
    tick: each read lane gets exactly the game's items, each taken from wherever the simulation had it
    (an input it hadn't crossed from, the other output); an item the simulation had on a read output but
    the game has on an input of the same splitter (crossed too early) goes back to that input, at its end
    when the input isn't read. Items the game has elsewhere (gone on downstream) are left where they are."""
    where = {}
    for L in lanes:
        for it in L.items:
            where[it[1]] = L
    by_lane = collections.defaultdict(list)
    read = []
    for sp in splitters:
        for row in sp.outs:
            read.extend(o for o in row if o is not None)
        if XINPUTS[0]:
            for row in sp.ins:
                read.extend(o for o in row if o is not None)
    read_ids = {id(L) for L in read}
    for u, (L, p, n, it) in game_next.items():
        if id(L) in read_ids:
            by_lane[id(L)].append([p, u, n, it, p, now, False])
    back = collections.defaultdict(list)  # input lane -> items carried back to its end
    keep_early = set()
    for sp in splitters:
        ins = {id(L): L for row in sp.ins for L in row if L is not None}
        outs = {id(L) for row in sp.outs for L in row if L is not None}
        for row in sp.outs:
            for o in row:
                if o is None:
                    continue
                want = {it[1] for it in by_lane.get(id(o), ())}
                for it in o.items:
                    if it[1] in want:
                        continue
                    g = game_next.get(it[1])
                    if g is None:
                        continue  # (taken off: the game's takes see to it)
                    GL = g[0]
                    if id(GL) in ins and id(GL) not in read_ids:
                        if XNOBACK[0]:
                            XSTATS["left on the output (crossed early)"] += 1
                            keep_early.add(it[1])
                            continue
                        XSTATS["back to input (crossed early)"] += 1
                        back[id(GL)].append((GL, it))
                    elif id(GL) in read_ids:
                        XSTATS["moved to " + ("the other output" if id(GL) in outs else "an input (read)")] += 1
                    else:
                        XSTATS["left (game has it on)"] += 1
    taken = set()
    for L in read:
        for it in by_lane.get(id(L), ()):
            taken.add(it[1])
    carried = {it[1] for lst in back.values() for _, it in lst}
    for L in lanes:
        if any(it[1] in taken or it[1] in carried for it in L.items):
            L.items = [it for it in L.items if it[1] not in taken and it[1] not in carried]
    for L in read:
        new = sorted(by_lane.get(id(L), ()))
        for it in new:
            w = where.get(it[1])
            if w is None:
                XSTATS["new (not in the simulation)"] += 1
            elif w is not L:
                XSTATS["moved onto " + ("an output" if L.split is None else "an input")] += 1
            else:
                XSTATS["already on the lane"] += 1
        if (L.type == "splitter" and L.line > 4) or (L.type == "lane-splitter" and L.line > 2):
            for a, b in zip(new, new[1:]):
                if b[0] - a[0] < GAP:
                    b[6] = True
        L.items = new + L.items  # (what is left of L.items the game has elsewhere: left)
        L.items.sort()
        if keep_early and L.split is None:
            # (An item left on the output ahead of the game: the read's items behind it keep their gap.)
            lim = None
            for it in L.items:
                if lim is not None and it[0] < lim:
                    it[0] = lim
                    it[4] = lim
                lim = it[0] + GAP
    XHELD.clear()
    for lid, lst in back.items():
        GL = lst[0][0]
        for _, it in lst:
            it[0] = 0
            it[4] = 0
            it[5] = now
            it[6] = False
            GL.items.append(it)
        GL.items.sort()
        if not XRECROSS[0]:
            XHELD.add(id(GL))  # (as the client holds an `sh` lane: the game's order isn't letting it through)
        space_back(GL, now)


def space_back(L, now, hops=8):
    """Items behind one put at L's end stand a gap behind it; those pushed past L's back end go onto the
    lane feeding it (when one does), and so on back (the client's _carry_back)."""
    lim = None
    over = []
    keep = []
    for it in L.items:
        if lim is not None and it[0] < lim:
            it[0] = lim
            it[4] = lim
        lim = it[0] + GAP
        if it[0] >= L.length and len(L.prevs) == 1 and hops > 0:
            over.append(it)
        else:
            if it[0] >= L.length:
                it[0] = L.length - 1  # (nowhere to go: at the back edge)
            keep.append(it)
    L.items = keep
    if over:
        P = L.prevs[0]
        for it in over:
            it[0] -= L.length
            it[4] = it[0]
            it[5] = now
            P.items.append(it)
            XSTATS["pushed back onto the feeder"] += 1
        P.items.sort()
        space_back(P, now, hops - 1)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("rec")
    ap.add_argument("--mode", default="step", choices=["step", "free"])
    ap.add_argument("--explain", type=int, default=0)
    ap.add_argument("--only", default="", help="explain only items off on these lanes (comma-separated)")
    ap.add_argument("--lanes", type=int, default=0, help="list the N lanes with the most items off")
    ap.add_argument("--split-wake", action="store_true", help="an awake splitter goes before the belts that start moving "
                    "(docs/BELT-RULES.md section 6; the client's split_wake)")
    ap.add_argument("--crossings-from-game", type=int, default=0, metavar="N",
                    help="every N ticks the splitters' output lanes are set to the game's (the bridge's `sl` at that latency)")
    ap.add_argument("--xmode", default="predict", choices=["predict", "hold", "turns"],
                    help="between those reads: cross as the rules say (predict) or wait at the input's end (hold)")
    ap.add_argument("--xinputs", action="store_true", help="the inputs are read too (as `sh`/`sl` do)")
    ap.add_argument("--xnoback", action="store_true", help="predict: an item crossed before the game did stays on its output")
    ap.add_argument("--xrecross", action="store_true", help="predict: an input an item was put back onto may cross again before the next read")
    ap.add_argument("--ticks", type=int, default=0, help="only the first N ticks")
    ap.add_argument("--near", type=int, default=38, help="an item within this (1/256) counts as drawn in place (0.15 tile)")
    a = ap.parse_args()
    SPLIT_WAKE[0] = a.split_wake
    XGAME[0] = a.crossings_from_game
    XHOLD[0] = a.xmode == "hold"
    XINPUTS[0] = a.xinputs
    XRECROSS[0] = a.xrecross
    XNOBACK[0] = a.xnoback
    only = {int(v) for v in a.only.split(",") if v}
    import os
    import pickle
    if os.path.exists(a.rec + ".pk"):
        # (The fronts round's cache: lanes' meta, {tick: {uid: (lane, pos, count, item)}}, names.)
        metas, rows, names = pickle.load(open(a.rec + ".pk", "rb"))
        d = {"lanes": metas, "names": names, "rows": rows}
    else:
        d = json.load(open(a.rec))
    lanes = [Lane(j + 1, m) for j, m in enumerate(d["lanes"])]
    order = build(lanes, d.get("names"))
    splitters = [x for x in order if isinstance(x, Splitter)]
    kinds = collections.Counter(L.kind for L in lanes)
    print("%d lanes (kinds %s); lanes going on into none recorded: %d; side-loads: %s" % (
        len(lanes), dict(kinds), sum(1 for L in lanes if L.next is None and L.side is None),
        [(L.j, L.side[0].j, L.side[1]) for L in lanes if L.side]))
    if "rows" in d:
        tick_no = sorted(d["rows"])
        ticks = [d["rows"][k] for k in tick_no]

        def state(row):
            return {u: (lanes[j - 1], p, n, it) for u, (j, p, n, it) in row.items()}
    else:
        ticks = d["ticks"]
        tick_no = [row[0] for row in ticks]

        def state(row):
            out = {}
            for i in range(1, len(row), 5):
                out[row[i + 1]] = (lanes[row[i] - 1], row[i + 2], row[i + 3], row[i + 4])
            return out
    if a.ticks:
        ticks = ticks[:a.ticks + 1]
    # The bus: straight lanes the game keeps packed (on average 3 or more items of 4 over the run).
    full = collections.Counter()
    for row in ticks:
        for u, (L, p, n, it) in state(row).items():
            full[L.j] += 1
    bus = {j for j, c in full.items() if lanes[j - 1].kind == "straight" and lanes[j - 1].length == 256
           and c >= len(ticks) * 3}
    print("bus lanes (straight, kept packed): %d" % len(bus))

    def load(st):
        for L in lanes:
            L.items = []
        for u, (L, p, n, it) in st.items():
            L.items.append([p, u, n, it])
        for L in lanes:
            L.items.sort()
            if (L.type == "splitter" and L.line > 4) or (L.type == "lane-splitter" and L.line > 2):
                # An item closer than 64 behind the one in front on a splitter's output can only be a
                # priority input's, standing till it is 64 behind (tick()); the game says nothing else.
                for a, b in zip(L.items, L.items[1:]):
                    if b[0] - a[0] < GAP:
                        b.extend([b[0], -1, True])

    right = wrong = 0
    by_kind, tot_kind = collections.Counter(), collections.Counter()
    ctx = collections.Counter()
    off_lane = collections.Counter()
    shown = put = took = 0
    started = False
    near_ok = bus_ticks = bus_holes = bus_sim = lost = 0
    prev_game = None
    for t in range(len(ticks) - 1):
        game_now, game_next = state(ticks[t]), state(ticks[t + 1])
        if not started or a.mode == "step":
            load(game_now)
            started = True
        given = set()
        tick(order, game_next, given)
        if XGAME[0] and (t + 1) % XGAME[0] == 0:
            if a.xmode == "turns":
                apply_turns(splitters, lanes, game_next, TICK[0])
            else:
                apply_crossings(splitters, lanes, game_next, TICK[0])
        where = {}
        sim_on = collections.defaultdict(list)
        for L in lanes:
            for it in L.items:
                where[it[1]] = (L, it[0])
                if L.j in bus:
                    sim_on[L.j].append(it[0])
                if L.j in bus:
                    sim_on[L.j].append(it[0])
        for u, (L, p, n, it) in game_next.items():
            if L.j in bus:
                bus_ticks += 1
                if not any(abs(q - p) <= a.near for q in sim_on[L.j]):
                    bus_holes += 1
        bus_sim += sum(len(v) for v in sim_on.values())
        for u, (L, p, n, it) in game_next.items():
            if u not in where or u in given:
                continue
            tot_kind[L.kind] += 1
            SL, sp = where[u]
            if SL is L and abs(sp - p) <= a.near:
                near_ok += 1
            if SL is L and sp == p:
                right += 1
            else:
                wrong += 1
                by_kind[L.kind] += 1
                off_lane[L.j] += 1
                nx = L.next.kind + "/%d" % L.next.step if L.next else ("split" if L.split else ("side" if L.side else "none"))
                ctx[(L.kind + "/%d" % L.step, nx, "sim ahead" if (SL is L and sp < p) else ("sim behind" if SL is L else "other lane"))] += 1
                if shown < a.explain and (not only or L.j in only):
                    shown += 1
                    print("  tick %d item %d: game on lane %d (%s %s, line %d) at %d; simulated on lane %d (%s) at %d" % (
                        tick_no[t + 1], u, L.j, L.kind, L.name, L.line, p, SL.j, SL.kind, sp))
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
                if prev_game is not None and u in prev_game:
                    lost += 1  # (the game had it last tick too: the simulation had lost it)
                changed = True
        prev_game = game_next
        if changed:
            for L in lanes:
                L.items.sort()
    print("mode %s: %d item-ticks where the game has them, %d not (%.3f%%); put on %d, taken off %d" % (
        a.mode, right, wrong, 100.0 * wrong / max(1, right + wrong), put, took))
    print("  within %d on the game's lane: %.3f%%; items the simulation lost (put back by the game): %d; "
          "bus lanes: %d game item-ticks, %d with no simulated item within %d (%.3f%%), simulated items %.2f%% of the game's" % (
              a.near, 100.0 * near_ok / max(1, right + wrong), lost, bus_ticks, bus_holes, a.near,
              100.0 * bus_holes / max(1, bus_ticks), 100.0 * bus_sim / max(1, bus_ticks)))
    if XGAME[0]:
        print("  crossings from the game every %d ticks, %s%s: %s" % (
            XGAME[0], a.xmode, " + inputs" if XINPUTS[0] else "", dict(XSTATS)))
    for k, n in ctx.most_common(12):
        print("  wrong on %-24s into %-24s %-11s %d" % (k[0], k[1], k[2], n))
    for j, n in off_lane.most_common(a.lanes):
        L = lanes[j - 1]
        print("  lane %d (%s %s unit %d line %d, step %d, next %s): %d" % (
            j, L.kind, L.name, L.unit, L.line, L.step, L.next.j if L.next else "-", n))
    for k in sorted(tot_kind, key=lambda k: -by_kind[k]):
        print("  %-20s %8d item-ticks, %6.3f%% not where the game has them" % (k, tot_kind[k], 100.0 * by_kind[k] / tot_kind[k]))


if __name__ == "__main__":
    main()
