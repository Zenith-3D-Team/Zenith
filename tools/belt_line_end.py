#!/usr/bin/env python3
"""A line of belts that ends, backed up from its end, with inserters taking from it: the owner's K19
("belt items all of a sudden jump around ... an item reaching the end"), made without Factorio.

    python tools/belt_line_end.py --out <dir> [--belts 22] [--ticks 3600] [--seed 1] [--toggles k=v,...]

Writes <dir>/rec.json (a recording as tools/belt_sim/record.py's: every lane's items every tick) and
<dir>/stream.jsonl (what the bridge sends a client that simulates belts and plays the inserters' hands:
`bs` and `ie`, one message a line, as the client's --belt-capture), for

    godot --headless --path client -s res://tests/belt_bs_replay.gd -- --stream=<dir>/stream.jsonl
        --truth=<dir>/rec.json --every-tick --ie-wire=0 --sim-dump=<dir>/sim.txt --belt-draw-dump=<dir>/draw.bin
    python tools/belt_jumps.py --truth <dir>/rec.json --sim <dir>/sim.txt --draw <dir>/draw.bin

(--ie-wire=0: the inserters' events reach the client's job with the update of their own tick or the next,
as on the wire; the replay's own order hands them over an update early, which hides the fault.)

The scene (Factorio's rules for a straight run, docs/BELT-RULES.md: an item moves its belt's step, never
closer than 64 to the one in front, the first stands at position 0 of the last belt):
  - `--belts` yellow belts in a row going west along y 10, belt b at x b, the run ending at x 0;
  - the north lane full of copper plates, standing (never taken);
  - the south lane backed up with iron plates from the end to `--queue` belts, more coming one at a time
    from an inserter that drops them on the last belt;
  - an inserter north of every third belt taking an iron plate from its belt every few seconds (the
    furnaces in the owner's video): those over the queue open a hole that the items behind close, those
    past its tail take passing items. Their hands turn round the inserter as the game's (a tenth of a
    tile a tick along the belt just after a take), so what the bridge reads at a check a tick or two
    late is where the game's hand would be. --pick any: a hand takes any item on its belt, not the one
    nearest the middle; --copper N: every N'th take is off the north lane, which is then fed from its
    far end too.
--hands-radius R: the bridge's f3d-detail-radius (24 by default, the fake's) set to R tiles. The bridge
plays only the inserters within R of the focus (the run's middle) as events: those further out send no
`ie` and their puts aren't handed over (`ho`), as live for inserters past the hands radius, so only the
bridge's own reads of their belts (`bs` `sl`/`pc`, its actors' checks) show their takes and puts. The
recording is the same; left out, the stream is as before. E46's stop-and-go lanes drawn standing:
--belts 40 --queue 36 --take 25 --feed 6 --ticks 2400 --hands-radius 4 (the middle two takers send `ie`),
replayed with --view=-4,4,52,13 (else the replay's view is the lanes' own box) and scored by
tools/belt_quirks.py --every 30 (a sample a tick moves no item the 0.25 tile its frozen check wants).
--taker-every N: a taking inserter at every N'th belt (3); 12 leaves long runs read by no inserter's checks.
The bridge is the worktree's own mod (control.lua under lupa against tools/mod_tests' fake Factorio and
bs_world.lua, as tools/bs_offline.py), its inserters' hands set each tick as the scene has them.
"""

import argparse
import json
import math
import pathlib
import random
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import bs_offline  # noqa: E402
import protocol  # noqa: E402

GAP = 64
STEP = 8
Y = 10
LANE = 60  # a lane's centre from the belt's (1/256)
SWING = 35  # ticks a hand takes between its ends (a basic inserter's half turn: inserters.lua travel())
TURN = 0.014  # turns a tick (the fake's basic inserter)
REACH = 0.035  # tiles a tick its arm grows or shrinks


def lane_y(line):
    return Y * 256 + 128 + (LANE if line == 2 else -LANE)


class Hand:
    """An inserter north of belt `b`: `take` True takes iron from the belt (drops in a furnace north of
    it), False drops iron on the belt (from a chest)."""

    def __init__(self, j, b, take, period, first, line=2, south=False):
        self.j, self.b, self.take = j, b, take
        self.period, self.next = period, first
        self.held = 0
        self.kind = line  # the item held (the recording's name index: 1 copper, 2 iron), as the lane's
        self.line = line  # the lane a feeder drops on
        self.takes = 0
        self.busy_until = 0
        self.leg = None  # (from, to, start tick, end tick)
        self.belt_pt = (b * 256 + 128, lane_y(line))
        self.other_pt = (b * 256 + 128, (Y + 2 if south else Y - 2) * 256 + 128)
        self.centre = (b * 256 + 128, (Y + 1 if south else Y - 1) * 256 + 128)
        self.at = self.belt_pt if take else self.other_pt  # where the hand is (1/256)

    def move(self, t):
        """The hand on its way: it turns round the inserter at TURN turns a tick, its arm changing by
        REACH tiles a tick, as the game's (so a hand that just took an item is already moving along the
        belt, a tenth of a tile a tick: what the bridge reads at a check a tick or two after the grab)."""
        if not self.leg:
            return
        a, z, t0, t1 = self.leg
        if t >= t1:
            self.at = z
            self.leg = None
            return
        cx, cy = self.centre
        a0, a1 = math.atan2(a[1] - cy, a[0] - cx), math.atan2(z[1] - cy, z[0] - cx)
        r0, r1 = math.hypot(a[0] - cx, a[1] - cy), math.hypot(z[0] - cx, z[1] - cy)
        way = (a1 - a0 + math.pi) % (2 * math.pi) - math.pi
        if abs(abs(way) - math.pi) < 0.05:
            way = math.pi  # (a half turn: always the same way round)
        n = t - t0
        turned = min(abs(way), n * TURN * 2 * math.pi) * (1 if way >= 0 else -1)
        grown = min(abs(r1 - r0), n * REACH * 256) * (1 if r1 >= r0 else -1)
        ang, r = a0 + turned, r0 + grown
        self.at = (round(cx + r * math.cos(ang)), round(cy + r * math.sin(ang)))


def make_scene(n_belts, ticks, seed, queue, t0, feed_gap, take_period, copper_every=0, pick="near", taker_every=3):
    """The recording, the world, each tick's hands ([actor, held, kind, place]) and what happened.
    copper_every N > 0: the north lane's plates are taken too (every N'th take of an inserter) and come
    again from an inserter south of the last belt but one, so that lane closes up from its far end; 0:
    it stands full for the whole run."""
    rng = random.Random(seed)
    names = ["copper-plate", "iron-plate"]
    lanes = []
    for b in range(n_belts):
        for line in (1, 2):
            y = lane_y(line)
            lanes.append([100 + b, "transport-belt", "transport-belt", "straight", 12, line, 256,
                          [b * 256, y], [b * 256 + 128, y], [b * 256 + 256, y], STEP, 1, []])
    belts = []
    for b in range(n_belts):
        ls = [[256, [b * 256, lane_y(line)], [b * 256 + 128, lane_y(line)], [b * 256 + 256, lane_y(line)]] for line in (1, 2)]
        belts.append({"u": 100 + b, "n": "transport-belt", "t": "transport-belt", "sh": "straight",
                      "p": [b * 256 + 128, Y * 256 + 128], "d": 12, "v": STEP, "st": 1, "cb": 0,
                      "i": [100 + b + 1] if b + 1 < n_belts else [], "o": [100 + b - 1] if b > 0 else [], "un": 0, "l": ls})
    hands = []
    actors, targets = [], []
    j = 0
    for b in range(2, n_belts - 3, taker_every):
        j += 1
        over_queue = b < queue
        hands.append(Hand(j, b, True, take_period + rng.randrange(-40, 41) + (0 if over_queue else 120), t0 + 30 + rng.randrange(0, take_period)))
        targets.append([700 + j, "stone-furnace", "furnace", [b * 256 + 128, (Y - 2) * 256 + 128]])
        actors.append({"u": 500 + j, "n": "inserter", "t": "inserter", "p": [b * 256 + 128, (Y - 1) * 256 + 128], "d": 0,
                       "pk": 100 + b, "dr": 700 + j})
    feeders = [(n_belts - 1, 2, False, feed_gap)]
    if copper_every > 0:
        feeders.append((n_belts - 2, 1, True, 40))
    for b, line, south, gap in feeders:
        j += 1
        h = Hand(j, b, False, gap, t0 + 10, line, south)
        hands.append(h)
        targets.append([700 + j, "wooden-chest", "container", [h.other_pt[0], h.other_pt[1]]])
        actors.append({"u": 500 + j, "n": "inserter", "t": "inserter", "p": [b * 256 + 128, (Y + 1 if south else Y - 1) * 256 + 128],
                       "d": 8, "pk": 700 + j, "dr": 100 + b})
    world = {"belts": belts, "actors": actors, "targets": targets, "windows": []}

    uid = 1
    items = {1: [], 2: []}  # line -> [uid, g] front first: g the place along the whole run, 0 its end
    for g in range(0, n_belts * 256, GAP):
        items[1].append([uid, g])
        uid += 1
    for g in range(0, queue * 256, GAP):
        items[2].append([uid, g])
        uid += 1
    rows, acts = [], []
    events = []
    for t in range(t0, t0 + ticks):
        # The belts move, then the inserters act: what a script reads on the next tick.
        if t > t0:
            for line in (1, 2):
                prev = None
                for it in items[line]:
                    lim = 0 if prev is None else prev + GAP
                    it[1] = min(it[1], max(it[1] - STEP, lim))
                    prev = it[1]
            for h in hands:
                h.move(t)
                if h.take:
                    if h.held and t >= h.busy_until:
                        h.held = 0
                        h.leg = (h.at, h.belt_pt, t, t + SWING)
                        h.busy_until = t + SWING
                        events.append((t, "dropped", h.j))
                    elif not h.held and t >= h.busy_until and t >= h.next:
                        line = 1 if copper_every > 0 and h.takes % copper_every == copper_every - 1 else 2
                        lane = items[line]
                        # (The item nearest the belt's middle; `any`: any item on the belt, as a hand that
                        # was chasing one takes it wherever it caught it.)
                        want = h.b * 256 + (128 if pick == "near" else rng.randrange(0, 256))
                        best = None
                        for k, it in enumerate(lane):
                            if h.b * 256 <= it[1] < h.b * 256 + 256 and (best is None or abs(it[1] - want) < abs(lane[best][1] - want)):
                                best = k
                        if best is not None:
                            u, g = lane.pop(best)
                            h.held, h.kind = 1, line
                            h.takes += 1
                            h.at = (g, lane_y(line))
                            h.leg = (h.at, h.other_pt, t, t + SWING)
                            h.busy_until = t + SWING
                            h.next = t + h.period + rng.randrange(-20, 21)
                            events.append((t, "took", h.j, u, g, line))
                else:
                    if not h.held and t >= h.busy_until and t >= h.next:
                        h.held = 1
                        h.leg = (h.at, h.belt_pt, t, t + SWING)
                        h.busy_until = t + SWING
                        h.next = t + h.period + rng.randrange(-h.period // 3, h.period // 3 + 1)
                    elif h.held and t >= h.busy_until:
                        lane = items[h.line]
                        g = h.b * 256 + 128
                        if all(abs(it[1] - g) >= GAP for it in lane):
                            k = 0
                            while k < len(lane) and lane[k][1] < g:
                                k += 1
                            lane.insert(k, [uid, g])
                            events.append((t, "put", h.j, uid, g, h.line))
                            uid += 1
                            h.held = 0
                            h.leg = (h.at, h.other_pt, t, t + SWING)
                            h.busy_until = t + SWING
        row = [t]
        for line in (1, 2):
            for u, g in items[line]:
                row += [(g // 256) * 2 + line, u, g % 256, 1, line]
        rows.append(row)
        acts.append([(h.j, h.held, h.kind, h.at) for h in hands])
    truth = {"sample": "tick", "lanes": lanes, "ticks": rows, "names": names, "rows": len(rows)}
    return truth, world, acts, events


def play(mod, truth, world, acts, out, toggles="", radius=160, quiet=False, bre=True, hands_radius=None):
    """The bridge's `bs` and `ie` for the scene, written a message a line."""
    h = bs_offline.Harness(mod)
    h.protos(world)
    h.load_mod()
    h.build(world, truth)
    g, F, H, bs = h.g, h.F, h.H, h.bs
    lua = h.lua
    set_hand = lua.eval("""function(j, x, y, belt_x, belt_y, other_x, other_y, take, held, name)
        local d = H.data_of(H.actors[j])
        d.held_stack_position = { x = x / 256, y = y / 256 }
        if held > 0 then
            d.held_stack = { valid_for_read = true, name = name, count = held, quality = { name = "normal" }, spoil_percent = 0,
                type = "item", health = 1 }
        else
            d.held_stack = { valid_for_read = false }
        end
        if take then
            d.pickup_position, d.drop_position = { x = belt_x / 256, y = belt_y / 256 }, { x = other_x / 256, y = other_y / 256 }
        else
            d.pickup_position, d.drop_position = { x = other_x / 256, y = other_y / 256 }, { x = belt_x / 256, y = belt_y / 256 }
        end
    end""")
    if hands_radius is not None:
        g.settings["global"]["f3d-detail-radius"].value = hands_radius
    for kv in [p for p in toggles.split(",") if p.strip()]:
        k, v = (s.strip() for s in kv.split("=", 1))
        opts = bs["OPTIONS"]
        if opts is not None and opts[k] is not None:
            for line in h.to_py(bs.option_command("%s %s" % (k, v))):
                if not quiet:
                    print(line)
        else:
            bs[k] = bs_offline.parse_value(v)
    rows = truth["ticks"]
    t0 = rows[0][0]
    xs = [p for m in truth["lanes"] for p in (m[7][0], m[9][0])]
    fx, fy = (min(xs) + max(xs)) / 512, Y + 0.5

    def fixed(v):
        return int(v * 256 + (0.5 if v >= 0 else -0.5))

    def hands(k):
        for j, held, kind, at in acts[k]:
            a = world["actors"][j - 1]
            take = a["pk"] < 500
            other = world["targets"][j - 1][3]
            # (A taker's pickup spot is the far lane's middle, as the game's; a feeder's drop spot its lane's.)
            belt = (a["p"][0], lane_y(2 if take else kind))
            set_hand(j, at[0], at[1], belt[0], belt[1], other[0], other[1], take, held, truth["names"][kind - 1])

    hello = {"t": "hello", "v": 1, "sid": "line-end", "w": 1, "b": 1, "bs": 1, "ie": 1, "ho": 1}

    def client_setup():
        h.send({"t": "focus", "x": fixed(fx), "y": fixed(fy), "r": 192})
        h.send({"t": "bfar", "r": radius, "n": radius, "m": 6000, "u": 10000000})

    F.on_init()
    H.set_row(lua.table_from(rows[0]))
    hands(0)
    g.game.tick = t0 - 400
    plain = dict(hello)
    for k in ("bs", "ie", "ho"):
        plain.pop(k, None)
    h.send(plain)
    ready = False
    for _ in range(300):
        F.tick()
        if any(m.get("t") == "ready" for m in h.take()):
            ready = True
            break
    if not ready:
        raise SystemExit("no handshake from the bridge")
    client_setup()
    for _ in range(5):
        F.tick()
    h.take()
    g.game.tick = t0 - 1
    h.send(hello)
    client_setup()
    bs.load_cap = 1e12
    fast = True
    n = {"bs": 0, "ie": 0}
    with open(out, "w", encoding="utf-8") as f:
        for k, r in enumerate(rows):
            t = r[0]
            H.set_row(lua.table_from(r))
            hands(k)
            g.game.tick = t - 1
            F.tick()
            for msg in h.take():
                kind = msg.get("t")
                if kind not in n:
                    continue
                n[kind] += 1
                f.write(json.dumps(msg, separators=(",", ":")) + "\n")
                if kind == "bs" and fast and not msg.get("ld"):
                    fast = False
                    bs.load_cap = None
            if t % 60 == 0:
                h.send(hello)
    if not quiet:
        print("bridge: %d ticks from %d, %d bs and %d ie messages -> %s" % (len(rows), t0, n["bs"], n["ie"], out))
    return n


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", required=True, help="a folder for rec.json and stream.jsonl")
    ap.add_argument("--mod", default=str(ROOT / "mod" / "factorio-3d-bridge"))
    ap.add_argument("--belts", type=int, default=22)
    ap.add_argument("--queue", type=int, default=12, help="belts backed up at the start")
    ap.add_argument("--ticks", type=int, default=3600)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--first", type=int, default=100000, help="the first tick")
    ap.add_argument("--feed", type=int, default=50, help="ticks between the items coming, about")
    ap.add_argument("--take", type=int, default=300, help="ticks between one inserter's takes, about")
    ap.add_argument("--copper", type=int, default=0, help="every N'th take is a copper plate off the north lane (0: never)")
    ap.add_argument("--pick", default="near", choices=["near", "any"],
                    help="which item a hand takes: the one nearest its belt's middle, or any on its belt")
    ap.add_argument("--toggles", default="", help="the bridge's /f3d-bs switches, name=value,...")
    ap.add_argument("--taker-every", type=int, default=3, help="an inserter taking north of every N'th belt")
    ap.add_argument("--hands-radius", type=int, default=None,
                    help="the bridge's f3d-detail-radius in tiles: inserters further from the focus send no ie (default: the fake's 24)")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args(argv)
    out = pathlib.Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    truth, world, acts, events = make_scene(a.belts, a.ticks, a.seed, a.queue, a.first, a.feed, a.take, a.copper, a.pick, a.taker_every)
    (out / "rec.json").write_text(json.dumps(truth, separators=(",", ":")))
    (out / "events.json").write_text(json.dumps(events))
    if not a.quiet:
        took = sum(1 for e in events if e[1] == "took")
        put = sum(1 for e in events if e[1] == "put")
        print("scene: %d belts, %d ticks, %d items put on, %d taken off, %d on the south lane at the end"
              % (a.belts, a.ticks, put, took, sum(1 for i in range(1, len(truth["ticks"][-1]), 5) if truth["ticks"][-1][i + 4] == 2)))
    play(a.mod, truth, world, acts, str(out / "stream.jsonl"), a.toggles, quiet=a.quiet, hands_radius=a.hands_radius)


if __name__ == "__main__":
    main()
