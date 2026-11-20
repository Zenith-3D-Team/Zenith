#!/usr/bin/env python3
"""A long straight run of fast belts whose front flows in bursts (E46's "batches of items jumping about one
update's travel on long straight runs"), made without Factorio, beside tools/belt_line_end.py.

    python tools/belt_bursts.py --out <dir> [--mode out|take] [--tier turbo] [--belts 70] [--ticks 2400]

Writes <dir>/rec.json (every lane's items every tick, as tools/belt_sim/record.py's), <dir>/events.json and
<dir>/stream.jsonl (what the bridge sends, `bs` and `ie`), replayed and scored as belt_line_end.py's:

    godot --headless --audio-driver Dummy --path client -s res://tests/belt_bs_replay.gd -- --stream=<dir>/stream.jsonl
        --truth=<dir>/rec.json --every-tick=60 --job-every=30 --ie-wire=0 --belt-draw-lattice=off
        --sim-dump=<dir>/sim.txt --belt-draw-dump=<dir>/draw.bin
    python tools/belt_quirks.py <dir> --every 30
    python tools/belt_jumps.py --truth <dir>/rec.json --sim <dir>/sim.txt --draw <dir>/draw.bin

(--belt-draw-lattice=off stands for a lane of mixed items, which the lattice doesn't draw; --job-every=30 is
a job every 30 ticks, as zoomed out on a busy base.)

The scene: `--belts` belts of `--tier` in a row going west along y 10, both lanes full of plates a gap apart
(copper north, iron south), moving at the tier's step (Factorio's rules for a straight run,
docs/BELT-RULES.md: never closer than 64 to the one in front).
  --mode out:  the run's last belt feeds one more belt west of it, which isn't recorded (the square's edge);
               a gate there lets items through for `--open` ticks (a random range) at a time, then holds them
               for `--shut`, each lane on its own: the front starts and stops, the run closing up behind it
               and opening again.
  --mode take: the run ends dead, backed up; `--takers` inserters at its first belts all take off the south
               lane on the same tick every `--period` ticks: the line moves up in steps.
               --release lo,hi: the run's last belt feeds one more (as `out`), its gate open from tick lo to hi
               of the run (both lanes): the backed-up line with the takes' holes in it is let go and flows (the
               owner's "gaps appear and items move past but the gap remains in the spot until it stops again").
               --f: the takes are F's (the character's pick-up, no inserters: the bridge's `pku` as the client
               turns it into an `ie` of picks by unit 0 with `hu`, pick_up.gd belt_takes), each off the lane
               after the last one's (north, south, ...), only within --take-window lo,hi ticks of the run.
--east: the run mirrored, going east (belt b from x -b - 1 to -b): a lane's exit point then lies on the cell edge
of the belt ahead's first cell (the lattice mask's floor), as the owner's belts going east or south.
--feed: a full belt behind the run's back (not recorded) feeds it, so with the end's gate open (--mode out
--open 99999,99999, or --release) the line stays packed and keeps moving; --feed-loose S: a share S of the fed items
come 1-12 (1/256) late, as a line fed by inserters or a merge is nearly packed (a read finds some gaps over 66).
--watch B,B: an idle inserter beside each of those belts (never taking): the bridge reads their lanes whenever they
change, so a moving line is read in its middle, as the owner's ring passing inserters.
--hands-radius R: the bridge's f3d-detail-radius (belt_line_end.py's). The bridge is the worktree's own mod,
under lupa against the fake Factorio (tools/bs_offline.py).
"""

import argparse
import json
import pathlib
import random
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import belt_line_end as ble  # noqa: E402

TIERS = {"yellow": ("transport-belt", 8), "red": ("fast-transport-belt", 16),
         "blue": ("express-transport-belt", 24), "turbo": ("turbo-transport-belt", 32)}
GAP = 64


def make_scene(a):
    name, step = TIERS[a.tier]
    ble.STEP = step
    y_belt = ble.Y
    rng = random.Random(a.seed)
    n = a.belts
    t0 = a.first
    names = ["copper-plate", "iron-plate"]

    ex = -1 if a.east else 1  # (--east: the run mirrored, belt b from x -b - 1 to -b, going east)

    def lane_pts(b, line):
        y = ble.lane_y(line)
        return [ex * b * 256, y], [ex * (b * 256 + 128), y], [ex * (b * 256 + 256), y]

    lanes, belts = [], []
    for b in range(n):
        for line in (1, 2):
            p0, p1, p2 = lane_pts(b, line)
            lanes.append([100 + b, name, "transport-belt", "straight", 12, line, 256, p0, p1, p2, step, 1, []])

    def belt(b, u):
        ls = [[256] + list(lane_pts(b, line)) for line in (1, 2)]
        return {"u": u, "n": name, "t": "transport-belt", "sh": "straight", "p": [ex * (b * 256 + 128), y_belt * 256 + 128],
                "d": 4 if a.east else 12, "v": step, "st": 1, "cb": 0, "i": [], "o": [], "un": 0, "l": ls}

    for b in range(n):
        w = belt(b, 100 + b)
        w["i"] = [100 + b + 1] if b + 1 < n else []
        w["o"] = [100 + b - 1] if b > 0 else []
        belts.append(w)
    rel = tuple(int(v) for v in a.release.split(",")) if a.release else None
    if a.feed:
        belts[-1]["i"] = [100 + n]
        w = belt(n, 100 + n)
        w["o"] = [100 + n - 1]
        belts.append(w)
    if a.mode == "out" or rel:
        belts[0]["o"] = [99]
        w = belt(-1, 99)
        w["i"] = [100]
        belts.append(w)
    hands, actors, targets = [], [], []
    win = tuple(int(v) for v in a.take_window.split(",")) if a.take_window else (0, 10 ** 9)
    if a.east and a.mode == "take" and not a.f:
        raise SystemExit("--east: the takes are F's only (--f)")
    if a.mode == "take":
        for j, b in enumerate(range(a.takers_from, a.takers_from + a.takers), start=1):
            hands.append(ble.Hand(j, b, True, a.period, t0 + max(60, win[0])))
            if a.f:
                continue
            targets.append([700 + j, "stone-furnace", "furnace", [b * 256 + 128, (y_belt - 2) * 256 + 128]])
            actors.append({"u": 500 + j, "n": "inserter", "t": "inserter", "p": [b * 256 + 128, (y_belt - 1) * 256 + 128],
                           "d": 0, "pk": 100 + b, "dr": 700 + j})
    for b in (int(v) for v in a.watch.split(",") if v.strip()):
        # (--watch) an idle inserter at belt b: the bridge watches its pickup belt and the one behind it, reading
        # them whenever their items change, as a moving line passing inserters (the owner's ring with inserters).
        j = len(actors) + 1  # (play() finds a hand's inserter at actors[j - 1])
        hands.append(ble.Hand(j, b, True, 10 ** 9, 10 ** 9))
        targets.append([700 + j, "stone-furnace", "furnace", [ex * (b * 256 + 128), (y_belt - 2) * 256 + 128]])
        actors.append({"u": 500 + j, "n": "inserter", "t": "inserter", "p": [ex * (b * 256 + 128), (y_belt - 1) * 256 + 128],
                       "d": 0, "pk": 100 + b, "dr": 700 + j})
    world = {"belts": belts, "actors": actors, "targets": targets, "windows": []}
    uid = 1
    items = {1: [], 2: []}
    for line in (1, 2):
        for g in range(0, n * 256, GAP):
            items[line].append([uid, g])
            uid += 1
    gate = {1: [False, t0 + 50], 2: [False, t0 + 90]}  # line -> [open, the tick it changes]
    feed_at = {1: n * 256, 2: n * 256}  # (--feed) line -> the feeding belt's next item's position
    lo_o, hi_o = (int(v) for v in a.open.split(","))
    lo_s, hi_s = (int(v) for v in a.shut.split(","))
    rows, acts, events = [], [], []
    for t in range(t0, t0 + a.ticks):
        if t > t0:
            for line in (1, 2):
                if a.mode == "out":
                    gt = gate[line]
                    if t >= gt[1]:
                        gt[0] = not gt[0]
                        gt[1] = t + (rng.randrange(lo_o, hi_o + 1) if gt[0] else rng.randrange(lo_s, hi_s + 1))
                        events.append((t, "open" if gt[0] else "shut", line))
                is_open = a.mode == "out" and gate[line][0] or (rel is not None and rel[0] <= t - t0 < rel[1])
                prev = None
                for it in items[line]:
                    lim = (-10 ** 9 if is_open else 0) if prev is None else prev + GAP
                    it[1] = min(it[1], max(it[1] - step, lim))
                    prev = it[1]
                items[line] = [it for it in items[line] if it[1] >= 0]
                if a.feed:
                    last = items[line][-1][1] if items[line] else -10 ** 9
                    feed_at[line] = max(feed_at[line] - step, last + GAP)
                    if feed_at[line] < n * 256:
                        items[line].append([uid, feed_at[line]])
                        uid += 1
                        feed_at[line] += GAP
                        if a.feed_loose and rng.random() < a.feed_loose:
                            feed_at[line] += rng.randrange(1, 13)
            for h in hands:
                h.move(t)
                if h.held and t >= h.busy_until:
                    h.held = 0
                    h.leg = (h.at, h.belt_pt, t, t + ble.SWING)
                    h.busy_until = t + ble.SWING
                elif not h.held and t >= h.busy_until and t >= h.next and t - t0 < win[1]:
                    line = 1 + h.takes % 2 if a.f else 2
                    lane = items[line]
                    want = h.b * 256 + 128
                    best = None
                    for k, it in enumerate(lane):
                        if h.b * 256 <= it[1] < h.b * 256 + 256 and (best is None or abs(it[1] - want) < abs(lane[best][1] - want)):
                            best = k
                    if best is not None:
                        u, g = lane.pop(best)
                        h.held, h.kind = 1, line
                        h.takes += 1
                        h.at = (g, ble.lane_y(line))
                        h.leg = (h.at, h.other_pt, t, t + ble.SWING)
                        h.busy_until = t + ble.SWING
                        h.next += h.period
                        events.append((t, "took", h.j, u, g, line))
        row = [t]
        for line in (1, 2):
            for u, g in items[line]:
                row += [(g // 256) * 2 + line, u, g % 256, 1, line]
        rows.append(row)
        acts.append([] if a.f else [(h.j, h.held, h.kind, h.at) for h in hands])
    truth = {"sample": "tick", "lanes": lanes, "ticks": rows, "names": names, "rows": len(rows)}
    return truth, world, acts, events, items


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", required=True, help="a folder for rec.json and stream.jsonl")
    ap.add_argument("--mod", default=str(ROOT / "mod" / "factorio-3d-bridge"))
    ap.add_argument("--mode", default="out", choices=["out", "take"])
    ap.add_argument("--tier", default="turbo", choices=sorted(TIERS))
    ap.add_argument("--belts", type=int, default=70)
    ap.add_argument("--ticks", type=int, default=2400)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--first", type=int, default=100000, help="the first tick")
    ap.add_argument("--takers", type=int, default=8, help="(take) inserters at the run's first belts")
    ap.add_argument("--takers-from", type=int, default=1, help="(take) the first taker's belt")
    ap.add_argument("--period", type=int, default=100, help="(take) ticks between their takes")
    ap.add_argument("--open", default="6,20", help="(out) ticks the gate stays open, lo,hi")
    ap.add_argument("--shut", default="60,150", help="(out) ticks it stays shut, lo,hi")
    ap.add_argument("--release", default="", help="(take) ticks of the run the end's gate is open, lo,hi (none: never)")
    ap.add_argument("--f", action="store_true", help="(take) the takes are F's pick-ups, not inserters'")
    ap.add_argument("--east", action="store_true", help="the run mirrored, going east (with --f for takes)")
    ap.add_argument("--take-window", default="", help="(take) ticks of the run the takes happen in, lo,hi")
    ap.add_argument("--hands-radius", type=int, default=None)
    ap.add_argument("--feed", action="store_true", help="a full belt (not recorded) feeds the run's back: a packed line that keeps moving")
    ap.add_argument("--feed-loose", type=float, default=0.0, help="(--feed) the share of fed items that come 1-12 (1/256) late: a line nearly packed")
    ap.add_argument("--watch", default="", help="belts with an idle inserter beside them, b,b,...: their lanes read whenever they change")
    ap.add_argument("--toggles", default="", help="the bridge's /f3d-bs switches, name=value,...")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args(argv)
    out = pathlib.Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    truth, world, acts, events, items = make_scene(a)
    (out / "rec.json").write_text(json.dumps(truth, separators=(",", ":")))
    (out / "events.json").write_text(json.dumps(events))
    if not a.quiet:
        print("scene %s: %d %s belts, %d ticks, %d events, items left %d/%d"
              % (a.mode, a.belts, a.tier, a.ticks, len(events), len(items[1]), len(items[2])))
    ble.play(a.mod, truth, world, acts, str(out / "stream.jsonl"), a.toggles, quiet=a.quiet, hands_radius=a.hands_radius)
    if a.f:
        add_f_takes(out / "stream.jsonl", events, -1 if a.east else 1)


def add_f_takes(path, events, ex=1):
    """Each take as the client's `ie` from F's `pku` (pick_up.gd belt_takes): [1, 0, tick, 1, item, 0, x, y,
    belt], `hu` the item's unique id, after the bridge's messages of its tick; the item's id as the bridge's
    `sl` reads name it."""
    lines = pathlib.Path(path).read_text(encoding="utf-8").splitlines()
    ids = {}  # line -> the bridge's item id
    for raw in lines:
        sl = json.loads(raw).get("sl") or []
        i = 0
        while i + 2 < len(sl):
            n = sl[i + 2]
            if n > 0:
                ids.setdefault(sl[i] % 8, sl[i + 4])
            i += 3 + 4 * n
        if len(ids) >= 2:
            break
    takes = {}
    for e in events:
        if e[1] == "took":
            t, _, j, u, g, line = e
            takes.setdefault(t, []).append((u, g, line, ids[line]))
    out = []
    pending = sorted(takes)
    for raw in lines:
        k = json.loads(raw).get("k", 0)
        while pending and pending[0] < k:
            out.append(_f_msg(pending[0], takes[pending.pop(0)], ex))
        out.append(raw)
    out += [_f_msg(t, takes[t], ex) for t in pending]
    pathlib.Path(path).write_text("\n".join(out) + "\n", encoding="utf-8")


def _f_msg(t, picks, ex=1):
    flat, hu = [], []
    for n, (u, g, line, item) in enumerate(picks, start=1):
        flat += [1, 0, t, n, item, 0, ex * g, ble.lane_y(line), 100 + g // 256]
        hu.append(u)
    return json.dumps({"t": "ie", "k": t, "n": 1, "p": 2, "l": flat, "hu": hu}, separators=(",", ":"))


if __name__ == "__main__":
    main()
