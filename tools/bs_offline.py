#!/usr/bin/env python3
"""Plays a bridge's belt_sim.lua offline against a recording of the game, and writes the `bs` stream it
sends as a client capture (the client's --belt-capture format, one message a line), for
client/tests/belt_bs_replay.gd and tools/belt_view_check.py --analyze. No Factorio, no client.

    python tools/bs_offline.py --mod <worktree>/mod/factorio-3d-bridge --truth rec.json [--world world.json]
        --out stream.jsonl [--toggles k=v,...] [--focus x,y] [--radius N] [--cap N|auto|t:m,t:m...]
        [--rate L] [--budget U] [--client-hello '{...}']

The given worktree's control.lua runs under lupa (Lua 5.2) against tools/mod_tests' fake Factorio API
(the worktree's own fake_factorio.lua when it has one, so its mod's tests and this agree), with
tools/mod_tests/bs_world.lua on top: every belt of the recorded world (record_world.py: places,
neighbours, lines; else worked out from the recording's lane meta) with its lines holding, each tick,
the items record.py recorded there; the inserters and drills round them with their hands and progress
changing as record_world.py recorded (when the world file has a window over the recording's ticks).
The world file's belts outside the recording stay as the neighbours of those leading into them but
aren't found by any search (their items aren't recorded): the bridge never loads them, so what leads
into them leads out of what it sends, as at a live square's edge (--no-clip finds them, empty).
game.tick runs over the recording's ticks.

The harness plays a client as the real one starts: a hello with `b` and `bs` (bridge.gd), `focus` at
the character's place, `bfar` (belt_lanes.gd: distance, near = the belt item distance, m = the Belt
updates cap, u smooth), the `rate` level and work `budget` the live run had (Hold 60 UPS sets them),
and a hello every second (the keep-alive). It answers no `bre`: the replay (belt_bs_replay.gd) answers
the client's own `bre` from the recording two updates on, for live and offline captures alike, so the
two are scored the same way; the live bridge's own answers, which a live capture carries too, are
what is missing here (see --bre).

The cap (bfar m): a number (fixed), "auto" (Automatic as belt_lanes.gd works it out once a second from
the bridge's `w` alone: the frames and the game's UPS taken as fine), or a schedule "tick:m,tick:m"
(each from that tick on). Fast load (default on): the bridge's first loads are not paced (load_cap
unbounded) until its first update with the square loaded, standing in for the minutes a live client
has been connected before the recording starts, and then one more scan asked for (the cap changed by
one item), which drops the belts the first load's chains pulled in past the cap's edge, as a client
connected for minutes has them; --no-fast-load leaves the bridge's own pace, --no-settle-scan leaves
out the scan.

--toggles: name=value pairs set before the first tick; a name the bridge's /f3d-bs knows
(belt_sim.option_command) goes through it, any other sets belt_sim.lua's field of that name (numbers,
true/false, nil).
"""

import argparse
import json
import pathlib
import statistics
import sys
import time

from lupa import lua52

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import protocol  # noqa: E402

CLIENT_PORT = 34201


def parse_value(v):
    low = v.lower()
    if low in ("true", "on", "yes"):
        return True
    if low in ("false", "off", "no"):
        return False
    if low in ("nil", "none"):
        return None
    try:
        f = float(v)
        return int(f) if f.is_integer() else f
    except ValueError:
        return v


def as_list(v):
    # (table_to_json writes an empty table as {}.)
    return v if isinstance(v, list) else []


def world_from_truth(truth):
    """A world from the recording's lane meta alone: places from the lanes' middles, neighbours by
    where one belt's lanes end and another's start, no inserters or drills."""
    by_unit = {}
    for m in truth["lanes"]:
        u, name, typ, shape, d, i, ln, p0, pm, p1, v = m[:11]
        b = by_unit.setdefault(u, {"u": u, "n": name, "t": typ, "sh": shape, "d": d, "v": v, "st": m[11] if len(m) > 11 else 1,
                                   "cb": 0, "i": [], "o": [], "un": 0, "lines": {}})
        b["lines"][i] = [ln, p0, pm, p1]
        if len(m) > 12 and isinstance(m[12], list) and m[12]:
            b["sp"] = m[12]
    belts = []
    starts = {}
    for b in by_unit.values():
        lines = [b["lines"][i] for i in sorted(b["lines"])]
        b["l"] = lines
        mids = [l[2] for l in lines[:2]] if b["t"] != "splitter" else [l[2] for l in lines[:4]]
        x = sum(p[0] for p in mids) / len(mids)
        y = sum(p[1] for p in mids) / len(mids)
        if b["t"] in ("transport-belt", "underground-belt"):
            x, y = (int(x // 256) * 256 + 128), (int(y // 256) * 256 + 128)
        b["p"] = [x, y]
        del b["lines"]
        belts.append(b)
        for l in lines:
            starts.setdefault((round(l[3][0] / 16), round(l[3][1] / 16)), set()).add(b["u"])
    # A lane's exit (position 0) where another belt's lane enters (its line end): that belt is fed.
    for b in belts:
        for l in b["l"]:
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    for u in starts.get((round(l[1][0] / 16) + dx, round(l[1][1] / 16) + dy), ()):
                        if u != b["u"] and u not in b["o"]:
                            b["o"].append(u)
                            by_unit[u]["i"].append(b["u"])
    return {"belts": belts, "actors": [], "targets": [], "windows": []}


class Harness:
    def __init__(self, mod, fake=None):
        self.mod = pathlib.Path(mod)
        own = self.mod.parent.parent / "tools" / "mod_tests" / "fake_factorio.lua"
        self.fake = pathlib.Path(fake) if fake else (own if own.exists() else ROOT / "tools" / "mod_tests" / "fake_factorio.lua")
        self.lua = lua52.LuaRuntime(unpack_returned_tuples=True)
        g = self.lua.globals()
        g.F_to_json = lambda t: json.dumps(self.to_py(t), separators=(",", ":"))
        g.F_from_json = lambda text: self._from_json(text)
        self.lua.execute(self.fake.read_text(encoding="utf-8"))
        self.lua.execute((ROOT / "tools" / "mod_tests" / "bs_world.lua").read_text(encoding="utf-8"))
        self.g = g
        self.F = g.F
        self.H = g.H

    def _from_json(self, text):
        try:
            data = json.loads(text)
        except ValueError:
            return None
        return self.lua.table_from(data, recursive=True)

    def to_py(self, value):
        if lua52.lua_type(value) == "table":
            items = list(value.items())
            if not items:
                return []
            keys = [k for k, _ in items]
            if all(isinstance(k, (int, float)) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
                return [self.to_py(value[i]) for i in range(1, len(keys) + 1)]
            return {str(k): self.to_py(v) for k, v in items}
        if isinstance(value, float) and value.is_integer():
            return int(value)
        return value

    def protos(self, world):
        H = self.H
        for a in world["actors"]:
            if a["t"] == "inserter":
                H.add_proto(a["n"], "inserter", "inserter", None, None)
            else:
                size = 5 if "big" in a["n"] else 3 if "electric" in a["n"] else 2
                H.add_proto(a["n"], "inserter", "mining-drill", size, size)

    def load_mod(self):
        self.g.package.path = str(self.mod / "?.lua") + ";" + self.g.package.path
        self.lua.execute((self.mod / "control.lua").read_text(encoding="utf-8"))
        self.lua.execute('require = function(name) error("Require can not be used outside of control.lua parsing: " .. tostring(name)) end')
        self.bs = self.lua.eval('package.loaded["scripts.belt_sim"]')

    clip = True

    def build(self, world, truth):
        H, lua = self.H, self.lua
        for b in world["belts"]:
            w = dict(b)
            w["lines"] = json.loads(json.dumps(b["l"]))  # (lupa converts a list met twice as empty)
            del w["l"]
            w["i"], w["o"] = as_list(b.get("i")), as_list(b.get("o"))
            if "sp" in w and not isinstance(w["sp"], list):
                w["sp"] = []
            H.add_belt(lua.table_from(w, recursive=True))
        H.link_belts()
        units = {b["u"] for b in world["belts"]}
        for t in world["targets"]:
            if t[0] not in units:
                H.add_target(t[0], t[3][0], t[3][1])
        for a in world["actors"]:
            H.add_actor(lua.table_from(a, recursive=True))
        if self.clip:
            recorded = {m[0] for m in truth["lanes"]}
            H.hide(lua.table_from([b["u"] for b in world["belts"] if b["u"] not in recorded]))
        H.index_surface(self.g.game.get_surface("nauvis"))
        keys = [m[0] * 8 + m[5] for m in truth["lanes"]]
        H.set_lanes(lua.table_from(keys), lua.table_from(truth["names"]))

    def _has_surface_index(self):
        try:
            return self.g.game.surfaces[1] is not None
        except Exception:
            return False

    def send(self, msg):
        self.F.packet(json.dumps(msg), CLIENT_PORT)

    def take(self):
        out = []
        for item in self.F.take_sent().values():
            data = item[2]
            for msg in protocol.split_datagram(data):
                out.append(msg)
        return out


def cap_plan(spec):
    """(kind, value): ("fixed", m), ("auto", None) or ("schedule", [(tick, m), ...])."""
    if spec == "auto":
        return "auto", None
    if ":" in spec:
        return "schedule", sorted((int(t), int(m)) for t, m in (p.split(":") for p in spec.split(",")))
    return "fixed", int(spec)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--mod", required=True, help="<worktree>/mod/factorio-3d-bridge")
    ap.add_argument("--truth", required=True, help="tools/belt_sim/record.py's recording")
    ap.add_argument("--world", default="", help="tools/belt_sim/record_world.py's file (else worked out from --truth)")
    ap.add_argument("--out", required=True, help="the bs stream, one message a line")
    ap.add_argument("--fake", default="", help="the fake API (default: the mod's worktree's tools/mod_tests/fake_factorio.lua)")
    ap.add_argument("--toggles", default="", help="name=value,...")
    ap.add_argument("--focus", default="", help="x,y (default: the middle of the recording)")
    ap.add_argument("--radius", type=int, default=160, help="bfar n: the belt item distance (High's default 160)")
    ap.add_argument("--distance", type=int, default=0, help="bfar r (default: --radius)")
    ap.add_argument("--focus-r", type=int, default=192, help="focus r: the entity distance")
    ap.add_argument("--cap", default="6000", help="bfar m: a number, auto, or tick:m,tick:m")
    ap.add_argument("--rate", default="0", help="the client's rate level (0-3), or a schedule tick:level,tick:level")
    ap.add_argument("--budget", type=int, default=0, help="the client's work budget (units a tick; 0: the bridge's default)")
    ap.add_argument("--client-hello", default="", help="extra hello fields as JSON")
    ap.add_argument("--no-clip", action="store_true", help="the world file's belts outside the recording found too (they hold nothing)")
    ap.add_argument("--no-fast-load", action="store_true")
    ap.add_argument("--no-settle-scan", action="store_true", help="no scan asked for after the fast first load")
    ap.add_argument("--start", type=int, default=0, help="first recorded tick to play (default: the recording's first)")
    ap.add_argument("--ticks", type=int, default=0, help="ticks to play (default: all)")
    ap.add_argument("--bre", default="", help="a file of {\"tick\": t, \"l\": [keys]} lines sent as `bre` at those ticks")
    ap.add_argument("--stats", default="", help="write per-update numbers (JSON) here")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args(argv)
    t_start = time.time()

    truth = json.loads(pathlib.Path(a.truth).read_text())
    world = json.loads(pathlib.Path(a.world).read_text()) if a.world else world_from_truth(truth)
    for k in ("actors", "targets", "windows"):
        world[k] = as_list(world.get(k))
    rows = truth["ticks"]
    if a.start:
        rows = [r for r in rows if r[0] >= a.start]
    if a.ticks:
        rows = rows[:a.ticks]
    t0 = rows[0][0]
    window = None
    for win in world["windows"]:
        if win["from"] <= t0 <= win["to"]:
            window = win
    acts = {r[0]: r for r in as_list(window["acts"])} if window else {}
    bst = {r[0]: r for r in as_list(window["bst"])} if window else {}

    h = Harness(a.mod, a.fake or None)
    h.clip = not a.no_clip
    h.protos(world)
    h.load_mod()
    h.build(world, truth)
    t_built = time.time()
    g, F, H, bs = h.g, h.F, h.H, h.bs

    # The recorded world as it stood before the first tick played: hands and statuses up to t0.
    if window:
        for t in sorted(acts):
            if t < t0:
                H.set_actors(h.lua.table_from(acts[t]))
        for t in sorted(bst):
            if t < t0:
                H.set_status(h.lua.table_from(bst[t]))

    if a.focus:
        fx, fy = (float(v) for v in a.focus.split(","))
    else:
        xs = [p for m in truth["lanes"] for p in (m[7][0], m[9][0])]
        ys = [p for m in truth["lanes"] for p in (m[7][1], m[9][1])]
        fx, fy = (min(xs) + max(xs)) / 512, (min(ys) + max(ys)) / 512

    for kv in [p for p in a.toggles.split(",") if p.strip()]:
        k, v = kv.split("=", 1)
        k, v = k.strip(), v.strip()
        opts = bs["OPTIONS"]
        if opts is not None and opts[k] is not None:
            for line in h.to_py(bs.option_command("%s %s" % (k, v))):
                if not a.quiet:
                    print(line)
        else:
            bs[k] = parse_value(v)
    # (The character stands where the client looks: the bridge's searches round the focus.)
    g.game.tick = t0 - 2
    bre_at = {}
    if a.bre:
        for line in pathlib.Path(a.bre).read_text().splitlines():
            if line.strip():
                m = json.loads(line)
                bre_at.setdefault(int(m["tick"]), []).extend(m["l"])

    hello = {"t": "hello", "v": 1, "sid": "bs-offline", "w": 1, "z": 1, "b": 1, "bs": 1}
    if a.client_hello:
        hello.update(json.loads(a.client_hello))
    plan, cap_v = cap_plan(a.cap)
    cap_now = cap_v if plan == "fixed" else (6000 if plan == "auto" else a.cap and cap_v[0][1])
    distance = a.distance or a.radius
    rate_sched = sorted((int(t), int(v)) for t, v in (p.split(":") for p in a.rate.split(","))) if ":" in a.rate else []
    rate_now = rate_sched[0][1] if rate_sched else int(a.rate)

    def fixed(v):
        return int(v * 256 + (0.5 if v >= 0 else -0.5))

    def client_setup():
        h.send({"t": "focus", "x": fixed(fx), "y": fixed(fy), "r": a.focus_r})
        h.send({"t": "bfar", "r": distance, "n": a.radius, "m": cap_now, "u": 10000000})
        if rate_now:
            h.send({"t": "rate", "l": rate_now})
        if a.budget:
            h.send({"t": "budget", "u": a.budget})

    # The handshake first, as a client without `bs` (nothing of belt_sim.lua's runs), some ticks before
    # the recording; then the clock set to just before it and the hello again with `bs`.
    F.on_init()
    H.set_row(h.lua.table_from(rows[0]))
    g.game.tick = t0 - 400
    plain = dict(hello)
    plain.pop("bs", None)
    h.send(plain)
    ready = False
    for _ in range(300):
        F.tick()
        if any(m.get("t") == "ready" for m in h.take()):
            ready = True
            break
    if not ready:
        raise SystemExit("no handshake from the bridge")
    # (The rate and budget before the clock moves on: a rate change eases in over 120 ticks, which a
    # live client connected for minutes is long past.)
    client_setup()
    for _ in range(5):
        F.tick()
    h.take()
    g.game.tick = t0 - 1
    h.send(hello)
    client_setup()
    fast = not a.no_fast_load
    settle_scan = fast and not a.no_settle_scan
    nudge = False
    if fast:
        bs.load_cap = 1e12

    out = open(a.out, "w", encoding="utf-8")
    ups = []  # per update: tick, p, w, fr, ld, lm, sl lanes, sl items, ew, pc, dl, parts
    cur = None
    auto_cap = 6000.0
    auto_t = 0
    bridge_work = -1.0
    tick_ms = []
    n_msgs = 0
    sched = list(cap_v) if plan == "schedule" else []
    for r in rows:
        t = r[0]
        H.set_row(h.lua.table_from(r))
        if t in acts:
            H.set_actors(h.lua.table_from(acts[t]))
        if t in bst:
            H.set_status(h.lua.table_from(bst[t]))
        # (F.tick moves game.tick on to t, then raises on_tick: the bridge reads this row.)
        g.game.tick = t - 1
        if t in bre_at:
            h.send({"t": "bre", "l": bre_at[t]})
        c0 = time.perf_counter()
        F.tick()
        tick_ms.append((time.perf_counter() - c0) * 1000)
        for msg in h.take():
            if msg.get("t") != "bs":
                continue
            n_msgs += 1
            out.write(json.dumps(msg, separators=(",", ":")) + "\n")
            k = int(msg.get("k", t))
            if cur is None or cur["tick"] != k:
                cur = {"tick": k, "p": msg.get("p"), "w": msg.get("w"), "fr": msg.get("fr"), "ld": msg.get("ld", 0), "lm": 0, "sl": 0,
                       "items": 0, "ew": 0, "pc": 0, "dl": 0, "parts": 0, "cap": cap_now}
                ups.append(cur)
                if msg.get("w") is not None and msg.get("p"):
                    per = float(msg["w"]) / max(1.0, float(msg["p"]))
                    bridge_work = per if bridge_work < 0 else bridge_work + (per - bridge_work) * 0.25
                if fast and not msg.get("ld"):
                    fast = False
                    bs.load_cap = None
                    # A first load pulls in whole belt lines past the cap's edge (each belt after the
                    # ones it leads into); the next scan drops what lies more than 2 rings past it. A
                    # live client has been connected long enough for that scan: one is asked for now
                    # (the cap changes, by one item).
                    if settle_scan:
                        nudge = True
            cur["parts"] += 1
            cur["lm"] += len(msg.get("lm", [])) // 12
            sl, i = msg.get("sl", []), 0
            while i < len(sl):
                n = int(sl[i + 2])
                cur["sl"] += 1
                cur["items"] += n
                i += 3 + 4 * n
            cur["ew"] += len(msg.get("ew", [])) // 4
            cur["pc"] += len(msg.get("pc", [])) // 5
            cur["dl"] += len(msg.get("dl", []))
        # The client: a keep-alive hello every second, the cap as it would send it.
        if t % 60 == 0:
            h.send(hello)
        want = cap_now
        if plan == "schedule":
            for st, m in sched:
                if t >= st:
                    want = m
        elif plan == "auto":
            auto_t += 1
            if auto_t >= 60 and ups and not ups[-1]["ld"]:
                auto_t = 0
                sq = ups[-1]["fr"] or 0
                binding = sq < a.radius - 0.5
                if bridge_work > 1500 * 1.25:
                    auto_cap = max(auto_cap * 0.8, 1000.0)
                elif bridge_work * 1.2 <= 1500 and binding:
                    auto_cap = min(auto_cap * 1.2, 48000.0)
                want = max(500, min(100000, int(auto_cap)))
        if rate_sched:
            r_want = rate_now
            for st, v in rate_sched:
                if t >= st:
                    r_want = v
            if r_want != rate_now:
                rate_now = r_want
                h.send({"t": "rate", "l": rate_now})
        if nudge:
            nudge = False
            if want == cap_now:
                want = cap_now + 1
        if want != cap_now:
            cap_now = want
            h.send({"t": "bfar", "r": distance, "n": a.radius, "m": cap_now, "u": 10000000})
    out.close()
    t_end = time.time()
    counts = h.to_py(bs.counts)
    summary = {
        "mod": str(a.mod), "truth": str(a.truth), "world": str(a.world or "(from the recording)"),
        "ticks": len(rows), "first": t0, "last": rows[-1][0], "updates": len(ups), "messages": n_msgs,
        "seconds": {"build": round(t_built - t_start, 1), "play": round(t_end - t_built, 1), "all": round(t_end - t_start, 1)},
        "ms_per_tick": {"mean": round(statistics.mean(tick_ms), 2), "p99": round(sorted(tick_ms)[int(len(tick_ms) * 0.99) - 1], 2),
                        "max": round(max(tick_ms), 2)},
        "work_per_tick": round(sum((u["w"] or 0) for u in ups) / max(1, len(rows)), 1),
        "counts": counts,
        "belts": len(world["belts"]), "actors": len(world["actors"]), "window": bool(window),
    }
    if not a.quiet:
        print("bs offline: %d ticks from %d, %d updates, %d bs messages; build %.1f s, play %.1f s (%.2f ms a tick, p99 %.2f, max %.1f)"
              % (summary["ticks"], t0, len(ups), n_msgs, t_built - t_start, t_end - t_built, summary["ms_per_tick"]["mean"],
                 summary["ms_per_tick"]["p99"], summary["ms_per_tick"]["max"]))
        print("world: %d belts, %d inserters and drills%s" % (len(world["belts"]), len(world["actors"]),
                                                              ", hands and progress recorded" if window else ", no hands recorded"))
        print("bridge work (bs w) %.0f units a tick on average (steady work only; an indication, not a measurement)" % summary["work_per_tick"])
        print("  tick       p   fr ld    cap     w    lm    sl  items   ew   pc    dl")
        for u in ups:
            print("  %d %3s %4s %2s %6s %5s %5d %5d %6d %4d %4d %5d" % (u["tick"], u["p"], u["fr"], u["ld"] or "", u["cap"], u["w"], u["lm"],
                                                                     u["sl"], u["items"], u["ew"], u["pc"], u["dl"]))
    if a.stats:
        pathlib.Path(a.stats).write_text(json.dumps({"summary": summary, "updates": ups}, indent=1))
    return summary, ups


if __name__ == "__main__":
    main()
