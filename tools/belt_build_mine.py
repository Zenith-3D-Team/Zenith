#!/usr/bin/env python3
"""A belt built at a line's end and a belt mined out of a moving line: the owner's K16 ("extend") and
K22 ("mine"), made without Factorio, as tools/belt_line_end.py makes its K19.

    python tools/belt_build_mine.py --scene extend|mine --out <dir> [--belts 22] [--ticks 2400] [--seed 1]
        [--at TICK] [--toggles k=v,...]

Writes <dir>/rec.json (a recording as tools/belt_sim/record.py's: every lane's items every tick; the
lanes of a belt built later and of one mined are in its lane list from the start, empty before it is
built and after it is mined), <dir>/stream.jsonl (the bridge's `bs` and `ie`, one message a line, as the
client's --belt-capture) and <dir>/events.json (the builds and mines: tick, unit, x), for

    godot --headless --path client -s res://tests/belt_bs_replay.gd -- --stream=<dir>/stream.jsonl
        --truth=<dir>/rec.json --every-tick --ie-wire=0 --sim-dump=<dir>/sim.txt --belt-draw-dump=<dir>/draw.bin
    python tools/belt_jumps.py --truth <dir>/rec.json --sim <dir>/sim.txt --draw <dir>/draw.bin

The scenes (Factorio's rules for a straight run, docs/BELT-RULES.md, as belt_line_end.py: each tick,
front to back, an item moves its belt's step unless that would bring it closer than 64 to the one in
front; the front one stands at position 0 of the last belt; a line leading into a belt outside the
recording runs off its end), `--belts` yellow belts in a row going west along y 10, belt b at x b
(unit 100 + b), the run ending at x 0, inserters at its far end putting items on from chests:
  - extend (K16): the line backed up (packed, standing) from its end, the north lane full of copper,
    the south lane's iron to `--queue` belts, an inserter on each lane's far end keeping it backed up.
    At --at a belt is built at the line's end (x -1), and --builds - 1 more, --every ticks apart (x -2,
    ...): the packed line moves on onto it and backs up again at the new end.
  - mine (K22): the line flowing (moving, not backed up), fed by three inserters on each lane at its
    far end, leading at x 0 into a belt outside the recording (the world's, hidden as tools/bs_offline.py
    hides them: the bridge never loads it, so the line leads out of what it sends). At --at the belt at
    --mine-x is mined: its items leave the game then, the belt behind it ends there (its items back up
    at its end), the belts in front run on and empty from the back.
In the fake world at that tick, before the bridge's on_tick: a belt built is made (bs_world.lua's
H.add_belt, after which the surface's searches find it), its own and its neighbours' belt_neighbours
set, and script_raised_built raised with it; a belt mined has script_raised_destroy raised with it, is
destroyed (the searches leave out entities no longer valid) and its neighbours' belt_neighbours lose
it. The bridge (the worktree's own mod under lupa against tools/mod_tests' fake Factorio and
bs_world.lua, as tools/bs_offline.py) should then send the new belt's lanes (lm, sl) and drop the mined
one's (dl) at once (belt_sim.lua's built_now): what it sent around each event is printed.
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

GAP = ble.GAP
STEP = ble.STEP
Y = ble.Y
lane_y = ble.lane_y
NAMES = ["copper-plate", "iron-plate"]


def unit_of(b):
    return 100 + b


def world_belt(b):
    ls = [[256, [b * 256, lane_y(line)], [b * 256 + 128, lane_y(line)], [b * 256 + 256, lane_y(line)]] for line in (1, 2)]
    return {"u": unit_of(b), "n": "transport-belt", "t": "transport-belt", "sh": "straight",
            "p": [b * 256 + 128, Y * 256 + 128], "d": 12, "v": STEP, "st": 1, "cb": 0, "i": [], "o": [], "un": 0, "l": ls}


def lane_meta(b, line):
    y = lane_y(line)
    return [unit_of(b), "transport-belt", "transport-belt", "straight", 12, line, 256,
            [b * 256, y], [b * 256 + 128, y], [b * 256 + 256, y], STEP, 1, []]


def segments(present, leads_out):
    """Belt x -> (the x of the end of its run of belts, whether that end leads out of the recording)."""
    out = {}
    for b in sorted(present):
        lo = b
        while lo - 1 in present:
            lo -= 1
        out[b] = (lo, leads_out and lo == 0)
    return out


def make_scene(scene, n_belts, ticks, seed, first, at, builds=2, every=120, mine_x=10, queue=16, feed=50, spacing=192,
               source=False):
    """The recording, the world, each tick's hands ([actor, held, kind, place]) and the events
    ({tick, kind, unit, x, ...}) the play raises."""
    rng = random.Random(seed)
    if scene == "extend":
        built = [-1 - k for k in range(builds)]
        events = [{"tick": at + k * every, "kind": "build", "unit": unit_of(x), "x": x} for k, x in enumerate(built)]
        lane_belts = list(range(-builds, n_belts))
        leads_out = False
    else:
        if not 1 <= mine_x <= n_belts - 2:
            raise SystemExit("--mine-x must be a belt with belts on both sides (1 to %d)" % (n_belts - 2))
        events = [{"tick": at, "kind": "mine", "unit": unit_of(mine_x), "x": mine_x}]
        lane_belts = list(range(0, n_belts))
        leads_out = True
    lanes = [lane_meta(b, line) for b in lane_belts for line in (1, 2)]
    index = {(b, line): k + 1 for k, (b, line) in enumerate((b, line) for b in lane_belts for line in (1, 2))}

    belts = []
    for b in range(n_belts):
        w = world_belt(b)
        w["i"] = [unit_of(b + 1)] if b + 1 < n_belts else []
        w["o"] = [unit_of(b - 1)] if b > 0 else []
        belts.append(w)
    if scene == "mine":
        # The belt the line leads into, outside the recording (hidden: never loaded, its items not recorded).
        w = world_belt(-1)
        w["i"] = [unit_of(0)]
        belts[0]["o"] = [unit_of(-1)]
        belts.append(w)
    if source:
        # (--source) A packed belt outside the recording leading into the far end: the line comes in packed.
        w = world_belt(n_belts)
        w["o"] = [unit_of(n_belts - 1)]
        belts[n_belts - 1]["i"] = [unit_of(n_belts)]
        belts.append(w)

    hands, actors, targets = [], [], []
    feeders = []
    if source:
        pass
    elif scene == "extend":
        feeders = [(n_belts - 1, 2, False, feed), (n_belts - 1, 1, True, feed)]
    else:
        for b in (n_belts - 1, n_belts - 2, n_belts - 3):
            feeders += [(b, 2, False, feed), (b, 1, True, feed)]
    for j, (b, line, south, gap) in enumerate(feeders, 1):
        h = ble.Hand(j, b, False, gap, first + 10 + rng.randrange(0, gap), line, south)
        hands.append(h)
        targets.append([700 + j, "wooden-chest", "container", [h.other_pt[0], h.other_pt[1]]])
        actors.append({"u": 500 + j, "n": "inserter", "t": "inserter", "p": [b * 256 + 128, (Y + 1 if south else Y - 1) * 256 + 128],
                       "d": 8, "pk": 700 + j, "dr": unit_of(b)})
    world = {"belts": belts, "actors": actors, "targets": targets, "windows": []}

    uid = 1
    items = {1: [], 2: []}  # line -> [uid, g] front first: g the place along the whole run, 0 the end of belt 0
    if scene == "extend":
        for g in range(0, n_belts * 256, GAP):
            items[1].append([uid, g])
            uid += 1
        for g in range(0, queue * 256, GAP):
            items[2].append([uid, g])
            uid += 1
    else:
        for line, off in ((1, spacing // 2), (2, 0)):
            for g in range(off, (n_belts - 3) * 256, spacing):
                items[line].append([uid, g])
                uid += 1
    present = set(range(n_belts))
    at_tick = {}
    for e in events:
        at_tick.setdefault(e["tick"], []).append(e)
    rows, acts = [], []
    ran_off = 0
    puts = 0
    for t in range(first, first + ticks):
        # The belts move as they stood after the last tick's events, then the inserters act; then this
        # tick's builds and mines (a player's, before the scripts' on_tick): what a script reads now.
        if t > first:
            seg = segments(present, leads_out)
            for line in (1, 2):
                prev, prev_lo = None, None
                for it in items[line]:
                    lo, free = seg[it[1] // 256]
                    if prev is not None and prev_lo == lo:
                        lim = prev + GAP
                    else:
                        lim = -10 ** 9 if free else lo * 256
                    it[1] = min(it[1], max(it[1] - STEP, lim))
                    prev, prev_lo = it[1], lo
                if leads_out:
                    k = len(items[line])
                    items[line] = [it for it in items[line] if it[1] >= 0]
                    ran_off += k - len(items[line])
                if source:
                    # (--source) The packed belt behind comes in a gap behind the last item, once there is room.
                    lane = items[line]
                    back = lane[-1][1] if lane else n_belts * 256 - GAP
                    while back + GAP < n_belts * 256:
                        back += GAP
                        lane.append([uid, back])
                        uid += 1
                        puts += 1
            for h in hands:
                h.move(t)
                if not h.held and t >= h.busy_until and t >= h.next:
                    h.held = 1
                    h.leg = (h.at, h.belt_pt, t, t + ble.SWING)
                    h.busy_until = t + ble.SWING
                    h.next = t + h.period + rng.randrange(-h.period // 3, h.period // 3 + 1)
                elif h.held and t >= h.busy_until:
                    lane = items[h.line]
                    g = h.b * 256 + 128
                    if all(abs(it[1] - g) >= GAP for it in lane):
                        k = 0
                        while k < len(lane) and lane[k][1] < g:
                            k += 1
                        lane.insert(k, [uid, g])
                        uid += 1
                        puts += 1
                        h.held = 0
                        h.leg = (h.at, h.other_pt, t, t + ble.SWING)
                        h.busy_until = t + ble.SWING
        for e in at_tick.get(t, ()):
            x = e["x"]
            if e["kind"] == "build":
                present.add(x)
            else:
                present.discard(x)
                gone = 0
                for line in (1, 2):
                    k = len(items[line])
                    items[line] = [it for it in items[line] if not x * 256 <= it[1] < x * 256 + 256]
                    gone += k - len(items[line])
                e["items"] = gone
        row = [t]
        for line in (1, 2):
            for u, g in items[line]:
                row += [index[(g // 256, line)], u, g % 256, 1, line]
        rows.append(row)
        acts.append([(h.j, h.held, h.kind, h.at) for h in hands])
    truth = {"sample": "tick", "lanes": lanes, "ticks": rows, "names": NAMES, "rows": len(rows)}
    stats = {"puts": puts, "ran_off": ran_off, "end": {line: len(items[line]) for line in (1, 2)}}
    return truth, world, acts, events, stats


def neighbours_after(scene, n_belts, events, upto):
    """Each belt's (inputs, outputs) by unit after the events up to tick `upto`, for those that changed."""
    present = set(range(n_belts))
    for e in events:
        if e["tick"] <= upto:
            (present.add if e["kind"] == "build" else present.discard)(e["x"])
    out = {}
    for b in present:
        ins = [unit_of(b + 1)] if b + 1 in present else []
        outs = [unit_of(b - 1)] if b - 1 in present else ([unit_of(-1)] if scene == "mine" and b == 0 else [])
        out[unit_of(b)] = (ins, outs)
    return out


def lanes_of(msg):
    """(lm keys, [(sl key, read tick, items)], dl keys) of a `bs` message."""
    lm = [int(v) for v in msg.get("lm", [])[0::12]]
    sl, i, reads = msg.get("sl", []), 0, []
    while i < len(sl):
        n = int(sl[i + 2])
        reads.append((int(sl[i]), int(sl[i + 1]), n))
        i += 3 + 4 * n
    return lm, reads, [int(v) for v in msg.get("dl", [])]


def report(events, log, n_belts, quiet=False):
    """What the bridge sent of each event's belt and its neighbours, from its tick on."""
    out = []
    for k, e in enumerate(events):
        t0 = e["tick"]
        t1 = events[k + 1]["tick"] if k + 1 < len(events) else t0 + 120
        t1 = min(t1, t0 + 120)
        u = e["unit"]
        keys = {u * 8 + 1, u * 8 + 2}
        near = [unit_of(e["x"] - 1), unit_of(e["x"] + 1)]
        near_keys = {v * 8 + i for v in near for i in (1, 2)}
        r = {"tick": t0, "kind": e["kind"], "unit": u, "lm": 0, "sl": 0, "sl_items": 0, "dl": 0, "first_lm": None,
             "first_sl": None, "first_dl": None, "near_lm": 0, "near_sl": 0, "before": 0, "later": 0}
        for t, msg in log:
            lm, reads, dl = lanes_of(msg)
            if t < t0:
                # (A built belt's lanes before it was built: there should be none.)
                if e["kind"] == "build":
                    r["before"] += sum(1 for v in lm if v in keys) + sum(1 for v in reads if v[0] in keys)
                continue
            if e["kind"] == "mine" and t >= t1:
                # (A mined belt's lanes after its window: there should be none.)
                r["later"] += sum(1 for v in lm if v in keys) + sum(1 for v in reads if v[0] in keys)
            if t >= t1:
                continue
            for v in lm:
                if v in keys:
                    r["lm"] += 1
                    r["first_lm"] = t - t0 if r["first_lm"] is None else r["first_lm"]
                elif v in near_keys:
                    r["near_lm"] += 1
            for key, rt, n in reads:
                if key in keys:
                    r["sl"] += 1
                    r["sl_items"] += n
                    r["first_sl"] = t - t0 if r["first_sl"] is None else r["first_sl"]
                elif key in near_keys:
                    r["near_sl"] += 1
            for v in dl:
                if v in keys:
                    r["dl"] += 1
                    r["first_dl"] = t - t0 if r["first_dl"] is None else r["first_dl"]
        out.append(r)
        if not quiet:
            if e["kind"] == "build":
                print("bridge, belt %d built at x %d on tick %d: in the %d ticks from it, lm %d lanes (first +%s), sl %d reads"
                      " (first +%s, %d items); its neighbours' lanes lm %d, sl %d; its lanes sent before it was built: %d"
                      % (u, e["x"], t0, t1 - t0, r["lm"], r["first_lm"], r["sl"], r["first_sl"], r["sl_items"], r["near_lm"],
                         r["near_sl"], r["before"]))
            else:
                print("bridge, belt %d mined at x %d on tick %d (%d items on it): in the %d ticks from it, dl %d lanes (first +%s),"
                      " lm %d, sl %d of it; its neighbours' lanes lm %d, sl %d; its lanes sent later: %d"
                      % (u, e["x"], t0, e.get("items", 0), t1 - t0, r["dl"], r["first_dl"], r["lm"], r["sl"], r["near_lm"],
                         r["near_sl"], r["later"]))
    return out


def play(mod, scene, truth, world, acts, events, out, toggles="", radius=160, quiet=False):
    """The bridge's `bs` and `ie` for the scene, written a message a line; the events raised at their
    ticks. Returns the counts and the `bs` messages by tick."""
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
    # (A mined belt is destroyed, but bs_world's search index keeps it: searches leave out what isn't valid.)
    lua.eval("""function()
        local s = game.get_surface("nauvis")
        local inner = s.find_entities_filtered
        s.find_entities_filtered = function(f)
            local out = {}
            for _, e in ipairs(inner(f)) do
                if e.valid then out[#out + 1] = e end
            end
            return out
        end
    end""")()
    # A belt's neighbours by unit number (belt_neighbours as bs_world's H.link_belts sets them).
    set_links = lua.eval("""function(u, ins, outs)
        local e = H.by_unit[u]
        if not (e and e.valid) then return end
        local a, b = {}, {}
        for _, v in ipairs(ins) do if H.by_unit[v] and H.by_unit[v].valid then a[#a + 1] = H.by_unit[v] end end
        for _, v in ipairs(outs) do if H.by_unit[v] and H.by_unit[v].valid then b[#b + 1] = H.by_unit[v] end end
        H.data_of(e).belt_neighbours = { inputs = a, outputs = b }
    end""")
    forget = lua.eval("function(u) H.by_unit[u] = nil end")
    n_belts = len([b for b in world["belts"] if b["u"] >= 100])

    def raise_event(e):
        u = e["unit"]
        if e["kind"] == "build":
            w = world_belt(e["x"])
            w["lines"] = json.loads(json.dumps(w.pop("l")))
            w.pop("i")
            w.pop("o")
            ent = H.add_belt(lua.table_from(w, recursive=True))
            for v, (ins, outs) in neighbours_after(scene, n_belts, events, e["tick"]).items():
                set_links(v, lua.table_from(ins), lua.table_from(outs))
            F["raise"]("script_raised_built", lua.table_from({"entity": ent}))
        else:
            ent = H.by_unit[u]
            F["raise"]("script_raised_destroy", lua.table_from({"entity": ent}))
            ent.destroy()
            forget(u)
            for v, (ins, outs) in neighbours_after(scene, n_belts, events, e["tick"]).items():
                set_links(v, lua.table_from(ins), lua.table_from(outs))

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
            other = world["targets"][j - 1][3]
            belt = (a["p"][0], lane_y(kind))
            set_hand(j, at[0], at[1], belt[0], belt[1], other[0], other[1], False, held, truth["names"][kind - 1])

    hello = {"t": "hello", "v": 1, "sid": "build-mine", "w": 1, "b": 1, "bs": 1, "ie": 1, "ho": 1}

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
    at_tick = {}
    for e in events:
        at_tick.setdefault(e["tick"], []).append(e)
    log = []
    with open(out, "w", encoding="utf-8") as f:
        for k, r in enumerate(rows):
            t = r[0]
            H.set_row(lua.table_from(r))
            hands(k)
            # (A player's build or mine comes before the scripts' on_tick of its tick.)
            if t in at_tick:
                g.game.tick = t
                for e in at_tick[t]:
                    raise_event(e)
            g.game.tick = t - 1
            F.tick()
            for msg in h.take():
                kind = msg.get("t")
                if kind not in n:
                    continue
                n[kind] += 1
                f.write(json.dumps(msg, separators=(",", ":")) + "\n")
                if kind == "bs":
                    log.append((t, msg))
                    if fast and not msg.get("ld"):
                        fast = False
                        bs.load_cap = None
            if t % 60 == 0:
                h.send(hello)
    if not quiet:
        print("bridge: %d ticks from %d, %d bs and %d ie messages -> %s" % (len(rows), t0, n["bs"], n["ie"], out))
        c = h.to_py(bs.counts)
        if isinstance(c, dict):
            print("bridge counts: built_loaded %s, built_gone %s, built_replaced %s, dl %s" % (
                c.get("built_loaded", 0), c.get("built_gone", 0), c.get("built_replaced", 0), c.get("dl", 0)))
    return n, log


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--scene", required=True, choices=["extend", "mine"])
    ap.add_argument("--out", required=True, help="a folder for rec.json, stream.jsonl and events.json")
    ap.add_argument("--mod", default=str(ROOT / "mod" / "factorio-3d-bridge"))
    ap.add_argument("--belts", type=int, default=22)
    ap.add_argument("--ticks", type=int, default=2400)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--first", type=int, default=100000, help="the first tick")
    ap.add_argument("--at", type=int, default=0, help="the tick of the (first) build or the mine (default: --first + 600)")
    ap.add_argument("--builds", type=int, default=2, help="(extend) belts built at the line's end, one after another")
    ap.add_argument("--every", type=int, default=120, help="(extend) ticks between the builds")
    ap.add_argument("--mine-x", type=int, default=10, help="(mine) the x of the belt mined")
    ap.add_argument("--queue", type=int, default=16, help="(extend) belts the south lane is backed up at the start")
    ap.add_argument("--feed", type=int, default=50, help="ticks between one inserter's puts, about")
    ap.add_argument("--spacing", type=int, default=192, help="(mine) the items' spacing on the line at the start (1/256)")
    ap.add_argument("--source", action="store_true",
                    help="no inserters: a packed belt outside the recording feeds the far end (the line flows packed)")
    ap.add_argument("--toggles", default="", help="the bridge's /f3d-bs switches, name=value,...")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args(argv)
    out = pathlib.Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    at = a.at or a.first + 600
    truth, world, acts, events, stats = make_scene(a.scene, a.belts, a.ticks, a.seed, a.first, at, a.builds, a.every, a.mine_x,
                                                   a.queue, a.feed, a.spacing, a.source)
    (out / "rec.json").write_text(json.dumps(truth, separators=(",", ":")))
    if not a.quiet:
        print("scene %s: %d belts, %d ticks from %d, %d items put on%s, at the end %d on the north lane and %d on the south"
              % (a.scene, a.belts, a.ticks, a.first, stats["puts"], ", %d ran off the end" % stats["ran_off"] if a.scene == "mine" else "",
                 stats["end"][1], stats["end"][2]))
        for e in events:
            print("  tick %d: belt %d %s at x %d%s" % (e["tick"], e["unit"], "built" if e["kind"] == "build" else "mined", e["x"],
                                                      " (%d items on it)" % e["items"] if "items" in e else ""))
    n, log = play(a.mod, a.scene, truth, world, acts, events, str(out / "stream.jsonl"), a.toggles, quiet=a.quiet)
    bridge = report(events, log, a.belts, quiet=a.quiet)
    (out / "events.json").write_text(json.dumps({"scene": a.scene, "events": events, "bridge": bridge}, indent=1))


if __name__ == "__main__":
    main()
