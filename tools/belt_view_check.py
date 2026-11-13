#!/usr/bin/env python3
"""Whether a build's belts look right over the whole view: one live run, then a report with a PASS/FAIL.

    python tools/belt_view_check.py --worktree <wt> --ports <udp>,<game>,<rcon> [--at x,y] [--size 64]
        [--seconds 10] [--settle 40] [--settle-max 180] [--first-bs 60] [--settings automatic|unlimited]
        [--hold60 on|off] [--record updates|tick|N] [--camera top|free|<yaw,pitch,dist[,ortho]>]
        [--daytime 0..1|game] [--stand-in] [--reuse-server] [--stop-server] [--shots <dir>] [--json <out>] [--main <main wt>]
        [--lock <file>] [--keep <dir>] [--replay every-tick|update] [--replay-arg=<arg> ...] [--tail-wait 30]

It starts the worktree's headless server on a copy of its save (server/saves/zt.zip by default; with
--reuse-server the one it kept running from an earlier run, restarted only when the worktree's mod
changed), puts the bridge's character at --at (default: where it stands), starts the worktree's
windowed client with --belt-capture, a settings file of its own (Belt updates Automatic or Unlimited;
Hold the game at 60 UPS on, the owner's default, unless --hold60 off) and its camera pinned (--camera
top: straight down, north up, orthographic, --size tiles high, so every build's screenshots frame the
same ground) and the time of day held at noon (--daytime 0, the default: the client's --sky=@0, so
night lighting never hides the belts; --daytime game follows the game's clock), or with --stand-in tools/belt_bench.py --bs --capture instead (the bridge only: no Godot,
no screenshots). Joined once the capture has a `bs` line (FAIL after --first-bs s). It waits until the
capture's last update has no `ld` (the first load is done) and at least --settle seconds have gone
(FAIL "first load didn't finish" after --settle-max), records the game's belts over a --size square
round the character for --seconds (tools/belt_sim/record.py --sample updates: only the ticks the bridge
sends an update on, which is all the replay compares; `--record tick` reads every lane every tick as
before, which loads the server enough to slow the bridge), saves the client's view every 10 s, waits up
to --tail-wait s for the capture to reach the recording's last tick (it can trail the game), stops
the client (and the server, unless kept) and replays the capture through the build's own belt_items.gd
(client/tests/belt_bs_replay.gd --view-dump --drawn-check --every-tick: a job a tick, the drawn clock
behind the updates, as the client runs them; --replay update: a job an update at its tick, as before).
The report:

0. Visible, the headline, what the owner sees: of every game item in the square on a lane that shows
   (not an underground's hidden lines 3-4), the share matched one to one with a simulated item of the
   same item name on the same lane within 0.15 tile, over every compared update; phantoms, the
   simulated items on those lanes with no game item matched; holes, runs of >= 2 game items in a row
   along a lane unmatched; the deep lanes' items kept (4+ lanes back to an unsimulated feeder, or
   none); and the records drawn on another lane than the simulation's.
1. Coverage: the lanes in the recorded square and how many the client simulates, by ring round the
   character (0-8, 8-16, 16-32, 32+ tiles).
2. Items per simulated lane by how many lanes back its nearest feeder the client doesn't simulate is
   (0, 1-3, 4-10, 11+, none): the game's items against the simulation's, first and last update; "kept"
   is lane by lane, min(sim, game) summed over the bucket's lanes / its game items, so items piled up
   on one lane don't make up for a hole on another.
3. Items by id: on the right lane within 0.15 tile, on it but off, on another lane, missing; and
   simulated items the game doesn't have. First, middle and last update.
4. Drawn: what the items' records draw against the simulation (the replay's --drawn-check).
Sections 2 (but its deep lanes), 3 and 5 are diagnostics.
5. By id: of every game item in the square, simulated lane or not, the share whose own
   id is simulated on its lane within 0.15 tile, over every update. Beside it the share by place (any
   simulated item on the lane within 0.15 tile, which a packed lane nearly always has: not a gate) and
   the share on lanes not simulated.
6. PASS only if visible >= 97%, phantoms <= 2%, the deep lanes keep >= 98%, coverage >= 98% and (every
   tick) the records draw at most 0.05% of the item-frames on another lane than the simulation's. By
   id, an item on another lane of a balancer looks the same when another of its kind is in its place,
   so no by-id number is a gate. The exit code is 1 on FAIL.
The report's head gives the run's pace: the updates' `p` (ticks between updates) while compared and
before, when the first load (`ld`) ended, the bridge's rate level at the recording's start and end
(/f3d-status, status.txt beside the stream), Hold 60 UPS (settings.cfg beside it), the client, whether
the server was started or reused, and how the recorder sampled. Beside it lane_map.png: the recorded
lanes from above, each coloured by its state at the last update (right, off, other lane, hole, not
simulated) over the same ground as the pinned camera's screenshots.

--main <wt> runs the same spot on a checkout without the `bs` stream (main) for screenshots only.
--analyze --stream <bs.jsonl> --truth <rec.json> [--at x,y] skips the live part.
Live runs take about 4 GB for the server: --lock <file> waits for that file to be free (polling every
5 s) and holds it while a run's server and client are live (a kept server idles without it).
"""

import argparse
import bisect
import collections
import glob
import hashlib
import json
import math
import os
import pathlib
import re
import shutil
import subprocess
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import rcon  # noqa: E402

NEAR = 38  # 0.15 tile in 1/256
RINGS = [(0, 8, "0-8"), (8, 16, "8-16"), (16, 32, "16-32"), (32, 1e9, "32+")]
DEPTHS = ["0 (fed from outside)", "1-3", "4-10", "11+", "no outside feeder"]
PUPPET = "package.loaded['__factorio-3d-bridge__/scripts/puppet.lua'].get()"


# ---------------------------------------------------------------- the report (offline)

def lane_meta(truth):
    """{key: (exit p0, middle, entry p1)} in 1/256 tile, key = unit * 8 + line index."""
    return {int(m[0]) * 8 + int(m[5]): (tuple(m[7]), tuple(m[8]), tuple(m[9])) for m in truth["lanes"]}


def feeders_of(lanes):
    """Each lane's feeders: lanes whose exit lies within a 1/32 tile cell of its entry."""
    by_exit = collections.defaultdict(list)
    for k, (p0, _, _) in lanes.items():
        by_exit[(round(p0[0] / 8), round(p0[1] / 8))].append(k)
    out = {}
    for k, (_, _, p1) in lanes.items():
        cx, cy = round(p1[0] / 8), round(p1[1] / 8)
        out[k] = [f for dx in (-1, 0, 1) for dy in (-1, 0, 1) for f in by_exit.get((cx + dx, cy + dy), []) if f != k]
    return out


def depth(k, feeders, simulated):
    """Lanes back to the nearest feeder not simulated: 0 when this lane's own feeder isn't, 99 none."""
    seen, cur, n = {k}, [k], 0
    while cur and n < 40:
        nxt = []
        for c in cur:
            for f in feeders.get(c, []):
                if f not in simulated:
                    return n
                if f not in seen:
                    seen.add(f)
                    nxt.append(f)
        cur, n = nxt, n + 1
    return 99 if not cur else n


def depth_bucket(d):
    if d == 0:
        return DEPTHS[0]
    if d <= 3:
        return DEPTHS[1]
    if d <= 10:
        return DEPTHS[2]
    return DEPTHS[4] if d == 99 else DEPTHS[3]


def ring_of(mid, at):
    d = max(abs(mid[0] / 256.0 - at[0]), abs(mid[1] / 256.0 - at[1]))
    for lo, hi, name in RINGS:
        if lo <= d < hi:
            return name
    return RINGS[-1][2]


def coverage(lanes, simulated, at):
    rows = collections.OrderedDict((name, [0, 0]) for _, _, name in RINGS)
    for k, (_, mid, _) in lanes.items():
        r = rows[ring_of(mid, at)]
        r[0] += 1
        r[1] += k in simulated
    total = [sum(r[0] for r in rows.values()), sum(r[1] for r in rows.values())]
    return {"total": total, "rings": rows}


def depth_table(view, lanes, feeders):
    simulated = set(int(k) for k in view["lanes"])
    game = collections.Counter(int(v[0]) for v in view["game"].values())
    sim = collections.Counter(int(v[0]) for v in view["sim"].values())
    rows = collections.OrderedDict((b, [0, 0, 0, 0]) for b in DEPTHS)  # lanes, game, sim, kept lane by lane
    for k in simulated:
        if k not in lanes:
            continue
        r = rows[depth_bucket(depth(k, feeders, simulated))]
        r[0] += 1
        r[1] += game[k]
        r[2] += sim[k]
        r[3] += min(game[k], sim[k])
    return rows


def kept_pct(r):
    """A depth row's items kept, lane by lane: min(sim, game) per lane, summed, over the game's items."""
    return 100.0 * r[3] / max(1, r[1])


def by_id(view, lanes):
    simulated = set(int(k) for k in view["lanes"])
    sim = view["sim"]
    c = collections.Counter()
    for uid, (key, pos, *_) in view["game"].items():
        if int(key) not in simulated:
            continue
        s = sim.get(uid)
        if s is None:
            c["missing"] += 1
        elif int(s[0]) != int(key):
            c["other lane"] += 1
        elif abs(int(s[1]) - int(pos)) <= NEAR:
            c["right"] += 1
        else:
            c["same lane, off"] += 1
    game = view["game"]
    c["simulated, not in the game"] = sum(1 for uid, (key, *_) in sim.items() if uid not in game and int(key) in lanes)
    return c


def headline(view):
    """[game items, with a simulated item (any) on the same lane within 0.15 tile, on lanes not
    simulated, whose own id is simulated on its lane within 0.15 tile, matched by place but not by id]."""
    simulated = set(int(k) for k in view["lanes"])
    sim = view["sim"]
    per_lane = collections.defaultdict(list)
    for key, pos, *_ in sim.values():
        per_lane[int(key)].append(int(pos))
    for v in per_lane.values():
        v.sort()
    n = hit = off = hit_id = place_only = 0
    for uid, (key, pos, *_) in view["game"].items():
        key, pos = int(key), int(pos)
        n += 1
        if key not in simulated:
            off += 1
        s = sim.get(uid)
        own = key in simulated and s is not None and int(s[0]) == key and abs(int(s[1]) - pos) <= NEAR
        hit_id += own
        ps = per_lane.get(key)
        if ps:
            i = bisect.bisect_left(ps, pos - NEAR)
            if i < len(ps) and ps[i] <= pos + NEAR:
                hit += 1
                place_only += not own
    return [n, hit, off, hit_id, place_only]


def visible_lanes(truth):
    """The recorded lanes whose items show: all but an underground belt's lines 3-4 (an entrance's hidden
    line, an exit's unused ones)."""
    return {int(m[0]) * 8 + int(m[5]) for m in truth["lanes"] if not (m[2] == "underground-belt" and int(m[5]) > 2)}


def kind_map(views, names):
    """The bridge's item ids (the `sl` lists') to the recording's item names: by the items both have, each
    id the name most of its items have in the game. A view's game entry is [lane, pos, the recording's
    item index from 1]; a simulated one [lane, pos, the bridge's id, or minus the recording's index]."""
    votes = collections.defaultdict(collections.Counter)
    game_kind = {}
    for v in views:
        for uid, e in v["game"].items():
            if len(e) > 2:
                game_kind[uid] = e[2]
    for v in views:
        for uid, e in v["sim"].items():
            if len(e) > 2 and isinstance(e[2], int) and e[2] > 0 and uid in game_kind:
                votes[e[2]][game_kind[uid]] += 1
    out = {}
    for sid, c in votes.items():
        g = c.most_common(1)[0][0]
        out[sid] = names[g - 1] if isinstance(g, int) and 1 <= g <= len(names) else g
    return out


def item_name(e, names, kinds=None):
    """An entry's item name: a game entry's (kinds None) by the recording's index, a simulated one's by
    kind_map (minus an index: the recording's); a string is a name already; None with no item given."""
    if len(e) < 3:
        return None
    x = e[2]
    if isinstance(x, str):
        return x
    x = int(x)
    if kinds is None or x < 0:
        x = abs(x)
        return names[x - 1] if 1 <= x <= len(names) else "#%d" % x
    return kinds.get(x, "?%d" % x) if x else "?"


def visible(view, shows, names=(), kinds=None):
    """What the owner sees at one update, on the recorded lanes that show (`shows`): each game item
    matched one to one with a simulated item of the same item on the same lane within 0.15 tile
    (sorted along the lane, each game item takes the first free simulated item in reach: the most
    matches there are). Counter: game, seen, wrong kind (missed, but some simulated item is within
    0.15 tile on the lane), on unsimulated lanes, sim, phantoms (simulated with no game item matched),
    holes (runs of >= 2 game items in a row along a lane unmatched) and hole items (the items in them)."""
    simulated = set(int(k) for k in view["lanes"])
    c = collections.Counter()
    game_at = collections.defaultdict(list)  # (lane, name) -> [(pos, uid)]
    lane_game = collections.defaultdict(list)  # lane -> [(pos, uid)]
    for uid, e in view["game"].items():
        key = int(e[0])
        if key not in shows:
            continue
        game_at[(key, item_name(e, names))].append((int(e[1]), uid))
        lane_game[key].append((int(e[1]), uid))
        c["game"] += 1
        c["on unsimulated lanes"] += key not in simulated
    sim_at = collections.defaultdict(list)
    lane_sim = collections.defaultdict(list)
    for e in view["sim"].values():
        key = int(e[0])
        if key not in shows:
            continue
        sim_at[(key, item_name(e, names, kinds or {}))].append(int(e[1]))
        lane_sim[key].append(int(e[1]))
        c["sim"] += 1
    seen = set()
    for kk, gs in game_at.items():
        ss = sorted(sim_at.get(kk, ()))
        j = 0
        for pos, uid in sorted(gs):
            while j < len(ss) and ss[j] < pos - NEAR:
                j += 1
            if j < len(ss) and ss[j] <= pos + NEAR:
                seen.add(uid)
                j += 1
    c["seen"] = len(seen)
    c["phantoms"] = c["sim"] - c["seen"]
    for key, gs in lane_game.items():
        ss = sorted(lane_sim.get(key, ()))
        run = 0
        for pos, uid in sorted(gs) + [(None, None)]:
            if uid is not None and uid not in seen:
                run += 1
                i = bisect.bisect_left(ss, pos - NEAR)
                c["wrong kind"] += i < len(ss) and ss[i] <= pos + NEAR
                continue
            if run >= 2:
                c["holes"] += 1
                c["hole items"] += run
            run = 0
    return c


def visible_pcts(c):
    """(visible %, phantom %) of a visible() Counter."""
    return 100.0 * c["seen"] / max(1, c["game"]), 100.0 * c["phantoms"] / max(1, c["sim"])


def kept_over(rows, buckets):
    """Kept, lane by lane, over some depth buckets of depth_table()-like rows: (%, game items)."""
    game = sum(rows[b][1] for b in buckets)
    return 100.0 * sum(rows[b][3] for b in buckets) / max(1, game), game


DEEP = DEPTHS[2:]  # 4 or more lanes back to an unsimulated feeder, or none
DRAWN_OTHER_MAX = 0.05  # % of the game's item-frames on simulated lanes: ~0 (the old replay put 26% there)


def by_id_pct(c, kind):
    """A by-id kind's share of the game's items on simulated lanes."""
    n = sum(c.get(x, 0) for x in ("right", "same lane, off", "other lane", "missing"))
    return 100.0 * c.get(kind, 0) / max(1, n)


# ---------------------------------------------------------------- the run's pace (offline)

def stream_updates(path):
    """[(k, p, loading)], one per update of a `bs` capture in order (a cut-off line skipped)."""
    out, idx = [], {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                m = json.loads(line)
            except ValueError:
                continue
            if not isinstance(m, dict) or m.get("t") != "bs":
                continue
            k = int(m.get("k", 0))
            if k not in idx:
                idx[k] = len(out)
                out.append([k, int(m.get("p", 0)), False])
            if m.get("ld"):
                out[idx[k]][2] = True
    return [tuple(u) for u in out]


def stream_last_k(path, tail=1 << 20):
    """The `k` of the capture's last whole `bs` line, or None (reads the file's tail only)."""
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - tail))
            data = f.read()
    except OSError:
        return None
    lines = data.split(b"\n")
    if size > tail:
        lines = lines[1:]
    for line in reversed(lines):
        try:
            m = json.loads(line)
        except ValueError:
            continue
        if isinstance(m, dict) and m.get("t") == "bs":
            return int(m.get("k", 0))
    return None


def truth_last_tick(path):
    """The last recorded tick of a record.py recording, or None."""
    try:
        with open(path, encoding="utf-8") as f:
            ticks = json.load(f).get("ticks") or []
        return int(ticks[-1][0]) if ticks else None
    except (OSError, ValueError):
        return None


def stream_loading(path, tail=1 << 20):
    """Whether the capture's last update still loads (`ld`): True, False, or None with no update yet.
    Reads the file's tail only (the client is still writing it)."""
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - tail))
            data = f.read()
    except OSError:
        return None
    lines = data.split(b"\n")
    if size > tail:
        lines = lines[1:]  # cut through
    last_k, loading = None, False
    for line in lines:
        try:
            m = json.loads(line)
        except ValueError:
            continue
        if not isinstance(m, dict) or m.get("t") != "bs":
            continue
        k = int(m.get("k", 0))
        if k != last_k:
            last_k, loading = k, False
        loading = loading or bool(m.get("ld"))
    return None if last_k is None else loading


def rate_levels(status_text):
    """The bridge's rate level in each /f3d-status answer of a status.txt (0 when it names none)."""
    out = []
    for block in status_text.split("[Zenith] client on port")[1:]:
        m = re.search(r"rate level (\d+)", block)
        out.append(int(m.group(1)) if m else 0)
    return out


def hold60_of(cfg_text):
    """Hold the game at 60 UPS in a client settings file: "on" or "off" (on when not set: the default)."""
    m = re.search(r"^hold_ups\s*=\s*(\w+)", cfg_text, re.M)
    return "off" if m and m.group(1).lower() == "false" else "on"


def run_info(stream, status=None, cfg=None, ticks=None):
    """The run's pace for the report's head: `p` while compared and before, the first load's end, the
    rate level at the recording's start and end, Hold 60 UPS."""
    ups = stream_updates(stream)
    lo, hi = ticks if ticks else (min((u[0] for u in ups), default=0), max((u[0] for u in ups), default=0))
    during = [u for u in ups if lo <= u[0] <= hi]
    before = [u for u in ups if u[0] < lo]
    info = {
        "p_compared": dict(sorted(collections.Counter(u[1] for u in during).items())),
        "p_before": dict(sorted(collections.Counter(u[1] for u in before).items())),
        "ld_last_before": max((u[0] for u in before if u[2]), default=None),
        "ld_during": sum(1 for u in during if u[2]),
        "updates_before": len(before),
        "rate": None,
        "hold60": None,
    }
    if status and pathlib.Path(status).exists():
        lv = rate_levels(pathlib.Path(status).read_text(errors="replace"))
        if lv:
            info["rate"] = [lv[0], lv[-1]]
    if cfg and pathlib.Path(cfg).exists():
        info["hold60"] = hold60_of(pathlib.Path(cfg).read_text(errors="replace"))
    return info


def analyze(truth, views, drawn, at, run=None, every_tick=True, live=None, gate_by_id=False):
    """The report's numbers from a recording and the replay's view dump (lines of view.jsonl); run:
    run_info()'s pace, shown only; every_tick: the replay ran a job a tick (--every-tick, as the client
    does) rather than one an update at its tick: the drawn kinds are gated only then. live: score_live()'s
    numbers for the client's own draw (--belt-draw-dump): then PASS/FAIL comes from them (visible,
    phantoms) and coverage, and the replay's scores are diagnostics. gate_by_id: by id on packed lanes
    gates too (--gate-by-id on; off by default: a packed lane of one kind looks the same whichever of its
    items is where, the owner's concession "a lane the game has packed is drawn packed")."""
    lanes = lane_meta(truth)
    feeders = feeders_of(lanes)
    first, last = views[0], views[-1]
    middle = views[len(views) // 2]
    head = [0, 0, 0, 0, 0]
    names = truth.get("names") or []
    kinds = kind_map(views, names)
    shows = visible_lanes(truth)
    vis = collections.Counter()
    deep = collections.OrderedDict((b, [0, 0, 0, 0]) for b in DEPTHS)
    for v in views:
        for i, x in enumerate(headline(v)):
            head[i] += x
        vis.update(visible(v, shows, names, kinds))
        for b, r in depth_table(v, lanes, feeders).items():
            for i in range(4):
                deep[b][i] += r[i]
    rep = {
        "at": list(at),
        "updates": len(views),
        "ticks": [first["tick"], last["tick"]],
        "coverage_first": coverage(lanes, set(int(k) for k in first["lanes"]), at),
        "coverage": coverage(lanes, set(int(k) for k in last["lanes"]), at),
        "depth_first": depth_table(first, lanes, feeders),
        "depth_last": depth_table(last, lanes, feeders),
        "by_id": {"first": by_id(first, lanes), "middle": by_id(middle, lanes), "last": by_id(last, lanes)},
        "by_id_ticks": [first["tick"], middle["tick"], last["tick"]],
        "drawn": (drawn or {}).get("drawn", {}),
        "drawn_dc": (drawn or {}).get("dc", [0, 0, 0]),
        "headline": head,
        "headline_last": headline(last),
        "run": run or {},
        "replay": "every tick (a job a tick, as the client)" if every_tick else "a job an update, at its tick (--replay update)",
        "every_tick": every_tick,
        "visible": dict(vis),
        "visible_last": dict(visible(last, shows, names, kinds)),
        "depth_all": deep,
    }
    rep["visible_pct"], rep["phantom_pct"] = visible_pcts(vis)
    rep["visible_last_pct"], rep["phantom_last_pct"] = visible_pcts(rep["visible_last"])
    rep["deep_kept_pct"], rep["deep_game"] = kept_over(deep, DEEP)
    dk = rep["drawn"]
    rep["drawn_other_lane"] = int(dk.get("other lane", 0))
    rep["drawn_standing_while_moving"] = sum(int(v) for k, v in dk.items() if k.startswith("stood"))
    cov = rep["coverage"]["total"]
    rep["coverage_pct"] = 100.0 * cov[1] / max(1, cov[0])
    rep["headline_id_pct"] = 100.0 * head[3] / max(1, head[0])
    rep["headline_place_pct"] = 100.0 * head[1] / max(1, head[0])
    rep["unsimulated_pct"] = 100.0 * head[2] / max(1, head[0])
    worst = None
    for b, r in rep["depth_last"].items():
        if r[1] >= 20:  # too few items to call
            if worst is None or kept_pct(r) < worst[1]:
                worst = (b, kept_pct(r))
    rep["worst_depth"] = worst
    dcn = int(rep["drawn_dc"][0]) if rep["drawn_dc"] else 0
    rep["drawn_other_lane_pct"] = 100.0 * rep["drawn_other_lane"] / max(1, dcn)
    reasons = []
    rep["live"] = live
    if live:
        if live["counts"].get("game") and live["visible_pct"] < 97.0:
            reasons.append("live visible %.1f%% < 97%%" % live["visible_pct"])
        if live["phantom_pct"] > 2.0:
            reasons.append("live phantoms %.1f%% > 2%%" % live["phantom_pct"])
        if gate_by_id and live["counts"].get("packed", 0) >= 20 and live["strict_pct"] < STRICT_MIN:
            reasons.append("live by id on packed lanes %.1f%% < %.0f%%" % (live["strict_pct"], STRICT_MIN))
    else:
        if vis["game"] and rep["visible_pct"] < 97.0:
            reasons.append("visible %.1f%% < 97%%" % rep["visible_pct"])
        if rep["phantom_pct"] > 2.0:
            reasons.append("phantoms %.1f%% > 2%%" % rep["phantom_pct"])
        if rep["deep_game"] >= 20 and rep["deep_kept_pct"] < 98.0:
            reasons.append("deep lanes (4+ back to an unsimulated feeder, or none) keep %.1f%% < 98%% (lane by lane)"
                           % rep["deep_kept_pct"])
        if every_tick and rep["drawn_other_lane_pct"] > DRAWN_OTHER_MAX:
            reasons.append("drawn on another lane (records vs simulation, every tick): %d item-frames, %.3f%% > %.2f%%"
                           % (rep["drawn_other_lane"], rep["drawn_other_lane_pct"], DRAWN_OTHER_MAX))
    if rep["coverage_pct"] < 98.0:
        reasons.append("coverage %.1f%% < 98%%" % rep["coverage_pct"])
    rep["gate_by_id"] = bool(gate_by_id)
    rep["pass"] = not reasons
    rep["reasons"] = reasons
    return rep


def format_report(rep):
    out = []
    p = out.append
    p("Belt view check at %.1f, %.1f: %d updates compared, ticks %d-%d" % (rep["at"][0], rep["at"][1], rep["updates"], *rep["ticks"]))
    run = rep.get("run") or {}
    if run:
        def counts(c):
            return ", ".join("%s x%d" % (k, v) for k, v in c.items()) or "none"
        if run["ld_last_before"] is not None:
            ld = "last at tick %d" % run["ld_last_before"]
        else:
            ld = "none before the recording" if run["updates_before"] else "no update before the recording"
        p("   updates' p (ticks between updates) while compared: %s; before: %s" % (counts(run["p_compared"]), counts(run["p_before"])))
        p("   first load (`ld`): %s; updates with `ld` while compared: %d" % (ld, run["ld_during"]))
        hold = run.get("hold60") or "unknown (no settings.cfg)"
        hold = {"on": "on (the default)", "off": "off (a diagnostic, not the default)"}.get(hold, hold)
        p("   bridge rate level (/f3d-status) at the recording's start and end: %s; Hold 60 UPS: %s"
          % ("%d, %d" % tuple(run["rate"]) if run.get("rate") else "unknown (no answer)", hold))
        if run.get("client") or run.get("recorder"):
            p("   client: %s; server: %s; recorder (record.py --sample): %s"
              % (run.get("client") or "?", run.get("server") or "?", run.get("recorder") or "?"))
        if run.get("pace"):
            # (game.tick over wall time, polled every 2 s: the game's pace as the client's F4 line has it;
            # a heavy recording slows the server, and the client then has more wall time a tick than in play.)
            p("   game UPS (polled): settling (join, first load, settle) %s; while scored %s%s"
              % (pace_text(run["pace"].get("settling")), pace_text(run["pace"].get("scored")),
                 "; settled, the 20 s before the recording: %s" % pace_text(run["pace"]["settled"]) if run["pace"].get("settled") else ""))
    ct = run.get("capture_tail")
    if ct:
        p("   capture: last update %s, the recording's last tick %s (waited %s s after the recording)"
          % (ct.get("last_k"), ct.get("recorded_last"), ct.get("waited_s")))
    p("   replay: %s" % rep.get("replay", "?"))
    p("")
    lv = rep.get("live")
    if lv:
        lc = lv["counts"]
        tm = lv["timing"]
        p("L. Live draw (the client's own records, --belt-draw-dump, placed as the shader places them when the drawn")
        p("   clock showed each recorded tick, against the game's items in the screenshots' bounds; %d ticks %d-%d)"
          % (lv["updates"], *lv["ticks"]))
        p("   visible %.1f%% (%d of %d item-ticks, by place; last tick %.1f%%)   phantoms %.1f%% (%d of %d drawn)"
          % (lv["visible_pct"], lc.get("seen", 0), lc.get("game", 0), lv["visible_last_pct"], lv["phantom_pct"],
             lc.get("phantoms", 0), lc.get("drawn", 0)))
        p("   visible inside the bounds %.1f%% (a diagnostic: %d of the game's item-ticks lie on recorded lanes past the bounds,"
          " where nothing is drawn)" % (lv.get("visible_inside_pct", lv["visible_pct"]), lc.get("game outside", 0)))
        p("   by id %.1f%% (drawn within 0.15 tile; off %d, not drawn %d); on packed lanes by id %.1f%% (%d of %d; %s)"
          % (lv["id_pct"], lc.get("id off", 0), lc.get("id not drawn", 0), lv["strict_pct"], lc.get("packed right", 0), lc.get("packed", 0),
             "a gate: --gate-by-id on" if rep.get("gate_by_id") else "reported only, not a gate"))
        p("   holes (>= 2 game items in a row unmatched): %d, %d items" % (lc.get("holes", 0), lc.get("hole items", 0)))
        p("   by item: " + ", ".join("%s %.0f%% (%d)" % (k, 100.0 * v[1] / max(1, v[0]), v[0]) for k, v in lv["by_name"].items()))
        p("   client: %d jobs, %d with updates (%d updates, %d jobs with more than one): %.1f ms a job (worst %.0f), %.0f records"
          % (tm["jobs"], tm["update_jobs"], tm["updates"], tm["merged"], tm["update_ms"][0], tm["update_ms"][1], tm["update_recs"]))
        p("   (%.0f items) a job, other jobs %.1f ms; skipped %d; results drawn late %d (most %.1f ticks), waited %.1f ms;"
          % (tm["update_items"], tm["other_ms"], tm["skipped"], tm["late"], tm["late_most"], tm["wait_ms"]))
        p("   drawn clock behind the newest update %.1f ticks (most %.0f), margin %.1f (most %.1f); the dump itself %.2f ms a job (%.1f at updates)"
          % (tm["behind"][0], tm["behind"][1], tm["margin"][0], tm["margin"][1], tm["dump_ms"], tm["dump_update_ms"]))
        if lv.get("not_scored"):
            p("   recorded ticks the client never drew (no job's result spanned them): %d" % len(lv["not_scored"]))
        p("")
    if "visible" in rep:
        vc, vl = rep["visible"], rep["visible_last"]
        p("0. %sVisible (what shows: every game item in the square on a lane that shows, matched one to one with a" % ("Replay (a diagnostic): " if lv else ""))
        p("   simulated item of the same item on the same lane within 0.15 tile, at every compared update)")
        p("   visible %.1f%% (%d of %d item-updates; last update %.1f%%)   phantoms %.1f%% (%d of %d simulated; last %.1f%%)"
          % (rep["visible_pct"], vc.get("seen", 0), vc.get("game", 0), rep["visible_last_pct"],
             rep["phantom_pct"], vc.get("phantoms", 0), vc.get("sim", 0), rep["phantom_last_pct"]))
        p("   holes (>= 2 game items in a row unmatched): %d, %d items (last update %d, %d items); missed with another"
          % (vc.get("holes", 0), vc.get("hole items", 0), vl.get("holes", 0), vl.get("hole items", 0)))
        p("   item simulated there (a wrong kind or one taken): %d; on lanes not simulated: %d"
          % (vc.get("wrong kind", 0), vc.get("on unsimulated lanes", 0)))
        p("   deep lanes (4+ back to an unsimulated feeder, or none) keep %.1f%% (lane by lane, every update); drawn on"
          % rep["deep_kept_pct"])
        p("   another lane (records vs simulation%s): %d item-frames (%.3f%%)"
          % ("" if rep.get("every_tick", True) else ", a job an update: not gated", rep["drawn_other_lane"], rep["drawn_other_lane_pct"]))
        p("")
    p("1. Coverage (lanes in the recorded square, simulated by the client; last update, first in brackets)")
    for name, r in rep["coverage"]["rings"].items():
        f = rep["coverage_first"]["rings"][name]
        p("   %-6s tiles: %5d of %5d  %5.1f%%   (%d)" % (name, r[1], r[0], 100.0 * r[1] / max(1, r[0]), f[1]))
    t = rep["coverage"]["total"]
    p("   all        : %5d of %5d  %5.1f%%   (%d)" % (t[1], t[0], rep["coverage_pct"], rep["coverage_first"]["total"][1]))
    p("")
    p("2. Items per simulated lane, by lanes back to a feeder the client doesn't simulate")
    p("   %-22s %17s %17s" % ("", "first update", "last update"))
    p("   (kept: lane by lane, min(sim, game) summed over the lanes, over game)")
    p("   %-22s %5s %5s %5s %5s %5s %5s %5s" % ("depth", "lanes", "game", "sim", "kept", "game", "sim", "kept"))
    for b in DEPTHS:
        f, l = rep["depth_first"][b], rep["depth_last"][b]
        if f[0] or l[0]:
            p("   %-22s %5d %5d %5d %4.0f%% %5d %5d %4.0f%%" % (b, l[0], f[1], f[2], kept_pct(f), l[1], l[2], kept_pct(l)))
    p("")
    p("3. Game items on simulated lanes, by id (ticks %d, %d, %d; a diagnostic: another item of the same kind in its"
      % tuple(rep["by_id_ticks"]))
    p("   place looks the same)")
    kinds = ["right", "same lane, off", "other lane", "missing", "simulated, not in the game"]
    p("   %-28s %9s %9s %9s" % ("", "first", "middle", "last"))
    for kd in kinds:
        row = []
        for w in ("first", "middle", "last"):
            c = rep["by_id"][w]
            n = sum(c.get(x, 0) for x in kinds[:4])
            row.append("%d (%.0f%%)" % (c.get(kd, 0), 100.0 * c.get(kd, 0) / max(1, n)) if kd != kinds[4] else str(c.get(kd, 0)))
        p("   %-28s %9s %9s %9s" % (kd, *row))
    p("")
    dc = rep["drawn_dc"]
    p("4. Drawn against the simulation (item-frames over every update)")
    p("   by place, the game's items on simulated lanes: %d; none simulated within 0.15 tile %.2f%%, none drawn %.2f%%"
      % (dc[0], 100.0 * dc[1] / max(1, dc[0]), 100.0 * dc[2] / max(1, dc[0])))
    p("   drawn on another lane (records vs simulation): %d; drawn standing where the simulation moves it: %d"
      % (rep["drawn_other_lane"], rep["drawn_standing_while_moving"]))
    if rep["drawn"]:
        p("   all kinds: " + ", ".join("%s %s" % (k, v) for k, v in sorted(rep["drawn"].items(), key=lambda kv: -int(kv[1]))))
    p("")
    h, hl = rep["headline"], rep["headline_last"]
    p("5. Every game item in the square, by id (a diagnostic): %.1f%% are simulated (their own id) on their lane within 0.15 tile"
      % rep["headline_id_pct"])
    p("   (%d of %d item-updates); %.1f%% are on lanes the client doesn't simulate (drawn by the far view)"
      % (h[3], h[0], rep["unsimulated_pct"]))
    p("   by place (any simulated item on the lane within 0.15 tile; not a gate): %.1f%% (%d); at the last update"
      % (rep["headline_place_pct"], h[1]))
    p("   %d of its %d by-place hits are another item by id" % (hl[4], hl[1]))
    p("")
    p("6. %s%s" % ("PASS" if rep["pass"] else "FAIL", "" if rep["pass"] else ": " + "; ".join(rep["reasons"])))
    return "\n".join(out)


def read_views(path):
    views, drawn = [], None
    with open(path, encoding="utf-8") as f:
        for line in f:
            if not line.strip():
                continue
            d = json.loads(line)
            if "drawn" in d:
                drawn = d
            else:
                views.append(d)
    return views, drawn


# ---------------------------------------------------------------- the live draw (offline)
# The client's --belt-draw-dump: what each job wrote for the GPU (belt_items.gd Job.dump), and when
# each job's result was drawn (<dump>.apply.jsonl). Scored against the game at every recorded tick:
# the records in effect when the drawn clock showed that tick, placed as the shader places them.

ID_INTS = 8  # uid, item, count, lane, pos, t0, v, reach
REC_FLOATS = 16
PACKED_GAP = 80  # 1/256: a lane whose game items are at most this far apart in a row is packed
STRICT_MIN = 90.0  # % by id on packed lanes


def read_apply(path):
    """The client's apply lines ({n, usec, drawn, ...}), in order of time."""
    out = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if isinstance(d, dict) and "n" in d and "drawn" in d:
                out.append(d)
    out.sort(key=lambda d: d["usec"])
    return out


def dump_frames(path):
    """Yields (header, ids (n, 8) int64, recs (n, 16) float64 with absolute ticks, gone int64[], paths float64[]
    or None) per job of a --belt-draw-dump, in order; stops at a cut-off frame."""
    import numpy as np
    with open(path, "rb") as f:
        while True:
            line = f.readline()
            if not line:
                return
            try:
                h = json.loads(line)
            except ValueError:
                return
            ni, ng, npth = int(h.get("ni", 0)), int(h.get("ng", 0)), int(h.get("paths", 0))
            need = ni * ID_INTS * 8 + ni * REC_FLOATS * 4 + ng * 8 + npth * 4
            data = f.read(need)
            if len(data) < need:
                return
            o = 0
            ids = recs = gone = paths = None
            if ni:
                ids = np.frombuffer(data, dtype=np.int64, count=ni * ID_INTS, offset=o).reshape(ni, ID_INTS)
                o += ni * ID_INTS * 8
                recs = np.frombuffer(data, dtype=np.float32, count=ni * REC_FLOATS, offset=o).reshape(ni, REC_FLOATS).astype(np.float64)
                base = float(h.get("base", 0.0))
                recs[:, 3] += base
                recs[:, 7] += base
                o += ni * REC_FLOATS * 4
            if ng:
                gone = np.frombuffer(data, dtype=np.int64, count=ng, offset=o)
                o += ng * 8
            if npth:
                paths = np.frombuffer(data, dtype=np.float32, count=npth, offset=o).astype(np.float64)
            yield h, ids, recs, gone, paths


MASK_CELLS = 4  # belt_lattice.gd CELLS: the lattice mask's cells a tile


def lane_cells(placer, lengths):
    """{lane key: set of (cx, cz)}: the cells of the lattice mask a lane's centre line marks, as
    belt_lattice.gd's _mark (sampled every 8/256 of its length)."""
    out = {}

    def cells(key):
        c = out.get(key)
        if c is None:
            c = set()
            length = lengths.get(key, 0)
            if key in placer and length > 0:
                steps = max(1, length // 8)
                for j in range(steps + 1):
                    x, z = placer[key](length * j / steps)
                    c.add((math.floor(x * MASK_CELLS), math.floor(z * MASK_CELLS)))
            out[key] = c
        return c
    return cells


class DrawState:
    """The records the GPU holds, by item uid, as the dump's jobs build them up. With the lattice
    (--belt-draw-lattice, belt_lattice.gd): its slots (texel 3: z 1, w the period) slide a gap a period,
    and the other records whose place falls in a cell of a lattice lane (`cells`, lane_cells()) aren't
    drawn, as the shader does."""

    def __init__(self, cells=None):
        self.items = {}  # uid -> (ids row, rec row)
        self.paths = None
        self.cells = cells

    def apply(self, ids, recs, gone, paths):
        if gone is not None:
            for uid in gone.tolist():
                self.items.pop(uid, None)
        if ids is not None:
            for i in range(ids.shape[0]):
                self.items[int(ids[i, 0])] = (ids[i], recs[i])
        if paths is not None:
            self.paths = paths

    def drawn_at(self, t):
        """Where each item's record draws it at tick t: (uids int64[], ids (n, 8), x[], z[], shown bool[])."""
        import numpy as np
        n = len(self.items)
        if n == 0:
            return np.zeros(0, np.int64), np.zeros((0, ID_INTS), np.int64), np.zeros(0), np.zeros(0), np.zeros(0, bool)
        ids = np.stack([v[0] for v in self.items.values()])
        r = np.stack([v[1] for v in self.items.values()])
        t0, t1, code = r[:, 3], r[:, 7], r[:, 11]
        g = np.where(t1 > t0, np.clip((t - t0) / np.where(t1 > t0, t1 - t0, 1.0), 0.0, 1.0), 1.0)
        lattice = (r[:, 13] < 0.5) & (r[:, 14] > 0.5)
        period = r[:, 15]
        wrap = lattice & (period > 0.0)
        if wrap.any():
            q = (t - t0[wrap]) / period[wrap]
            g[wrap] = q - np.floor(q)
        shown = code > -0.5
        straight = code < 0.5
        x = r[:, 0] + r[:, 4] * g
        z = r[:, 2] + r[:, 6] * g
        on_path = shown & ~straight
        if on_path.any():
            tex = self.paths if self.paths is not None else np.zeros(0)
            c = np.rint(code[on_path]).astype(np.int64) - 1
            first = c // 64
            pieces = c - first * 64 + 1
            f = g[on_path] * pieces
            i = np.minimum(np.floor(f).astype(np.int64), pieces - 1)
            a = (first + i) * 4
            u = f - i
            ok = a + 7 < tex.size
            px = np.zeros(a.size)
            pz = np.zeros(a.size)
            pw = np.zeros(a.size)
            if ok.any():
                aa = a[ok]
                uu = u[ok]
                px[ok] = tex[aa] * (1 - uu) + tex[aa + 4] * uu
                pz[ok] = tex[aa + 2] * (1 - uu) + tex[aa + 6] * uu
                pw[ok] = tex[aa + 3] * (1 - uu) + tex[aa + 7] * uu
            idx = np.nonzero(on_path)[0]
            x[idx] = r[idx, 0] + px
            z[idx] = r[idx, 2] + pz
            shown[idx] = ok & (pw >= 0.5)
        if self.cells is not None and lattice.any():
            masked = set()
            for key in set(ids[lattice, 3].tolist()):
                masked |= self.cells(int(key))
            if masked:
                cx = np.floor(x * MASK_CELLS).astype(np.int64)
                cz = np.floor(z * MASK_CELLS).astype(np.int64)
                for i in np.nonzero(shown & ~lattice)[0].tolist():
                    if (int(cx[i]), int(cz[i])) in masked:
                        shown[i] = False
        return ids[:, 0], ids, x, z, shown


def lane_placer(truth):
    """{lane key: f(pos) -> (x, y) tiles}: along the lane's three points; a curve along the circle through them."""
    out = {}
    for m in truth["lanes"]:
        key = int(m[0]) * 8 + int(m[5])
        p0, mid, p1 = (tuple(float(v) / 256.0 for v in m[i]) for i in (7, 8, 9))
        length = max(1, int(m[6]))
        arc = None
        if m[2] == "transport-belt" and m[3] in ("left", "right"):
            ax, ay = p0
            bx, by = mid
            cx, cy = p1
            d = 2.0 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
            if abs(d) > 1e-9:
                a2, b2, c2 = ax * ax + ay * ay, bx * bx + by * by, cx * cx + cy * cy
                ux = (a2 * (by - cy) + b2 * (cy - ay) + c2 * (ay - by)) / d
                uy = (a2 * (cx - bx) + b2 * (ax - cx) + c2 * (bx - ax)) / d
                a0 = math.atan2(ay - uy, ax - ux)
                a1 = math.atan2(cy - uy, cx - ux)
                turn = (a1 - a0 + math.pi) % (2 * math.pi) - math.pi
                arc = (ux, uy, math.hypot(ax - ux, ay - uy), a0, turn)

        def place(pos, p0=p0, mid=mid, p1=p1, length=length, arc=arc):
            f = min(1.0, max(0.0, pos / float(length)))
            if arc is not None:
                a = arc[3] + arc[4] * f
                return arc[0] + math.cos(a) * arc[2], arc[1] + math.sin(a) * arc[2]
            if f <= 0.5:
                a, b, g = p0, mid, f * 2.0
            else:
                a, b, g = mid, p1, (f - 0.5) * 2.0
            return a[0] + (b[0] - a[0]) * g, a[1] + (b[1] - a[1]) * g
        out[key] = place
    return out


def truth_rows(truth):
    """{tick: [(uid, lane key, item index from 1, pos, count)]}, lanes that show only."""
    keys = [int(m[0]) * 8 + int(m[5]) for m in truth["lanes"]]
    shows = visible_lanes(truth)
    out = {}
    for row in truth["ticks"]:
        items = []
        for i in range(1, len(row) - 4, 5):
            key = keys[int(row[i]) - 1]
            if key in shows:
                items.append((int(row[i + 1]), key, int(row[i + 4]), int(row[i + 2]), int(row[i + 3])))
        out[int(row[0])] = items
    return out


def score_live_tick(game, drawn, placer, names, kinds, bounds, tol=0.15):
    """One recorded tick: the game's items (truth_rows' list) against what the records draw there
    (DrawState.drawn_at). Counter: game, seen (matched one to one by place, same item name, within tol),
    id right / off / not drawn, packed (game items on packed lanes) and packed right by id, drawn
    (shown within the view), phantoms, holes and hole items; by name: {name: [game, seen]}."""
    import numpy as np
    uids, ids, x, z, shown = drawn
    x0, y0, x1, y1 = bounds
    inside = shown & (x >= x0) & (x <= x1) & (z >= y0) & (z <= y1)
    c = collections.Counter()
    by_name = collections.defaultdict(lambda: [0, 0])
    cell = 1.0 / tol
    grid = collections.defaultdict(list)  # (name, cx, cz) -> [drawn index]
    drawn_pos = {}
    for i in np.nonzero(inside)[0].tolist():
        uid = int(uids[i])
        name = kinds.get(int(ids[i, 1]), "?%d" % int(ids[i, 1]))
        drawn_pos[uid] = (float(x[i]), float(z[i]))
        grid[(name, int(math.floor(x[i] * cell)), int(math.floor(z[i] * cell)))].append(i)
    c["drawn"] = len(drawn_pos)
    taken = set()
    seen = set()
    per_lane = collections.defaultdict(list)
    for uid, key, item, pos, count in game:
        name = names[item - 1] if 1 <= item <= len(names) else "#%d" % item
        gx, gy = placer[key](pos)
        c["game"] += 1
        out = not (x0 <= gx <= x1 and y0 <= gy <= y1)
        if out:
            c["game outside"] += 1  # (on a recorded lane, but past the screenshots' bounds: never drawn there)
        by_name[name][0] += 1
        per_lane[key].append((pos, uid))
        d = drawn_pos.get(uid)
        if d is None:
            c["id not drawn"] += 1
        elif math.hypot(d[0] - gx, d[1] - gy) <= tol:
            c["id right"] += 1
        else:
            c["id off"] += 1
        cx, cz = int(math.floor(gx * cell)), int(math.floor(gy * cell))
        best, bd = -1, tol
        for dx in (-1, 0, 1):
            for dz in (-1, 0, 1):
                for i in grid.get((name, cx + dx, cz + dz), ()):
                    if i in taken:
                        continue
                    dd = math.hypot(x[i] - gx, z[i] - gy)
                    if dd <= bd:
                        best, bd = i, dd
        if best >= 0:
            taken.add(best)
            seen.add(uid)
            if out:
                c["seen outside"] += 1
            c["seen"] += 1
            by_name[name][1] += 1
    c["phantoms"] = c["drawn"] - len(taken)
    # Packed lanes: by id (another item of the kind in its place looks the same, so only the id says
    # whether the lane holds the right items in the right order).
    for key, gs in per_lane.items():
        gs.sort()
        packed = len(gs) >= 3 and all(gs[i + 1][0] - gs[i][0] <= PACKED_GAP for i in range(len(gs) - 1))
        run = 0
        for pos, uid in gs + [(None, None)]:
            if uid is not None:
                if packed:
                    c["packed"] += 1
                    d = drawn_pos.get(uid)
                    gx, gy = placer[key](pos)
                    if d is not None and math.hypot(d[0] - gx, d[1] - gy) <= tol:
                        c["packed right"] += 1
                if uid not in seen:
                    run += 1
                    continue
            if run >= 2:
                c["holes"] += 1
                c["hole items"] += run
            run = 0
    return c, by_name


def live_timing(frames_hdr, applies):
    """The client's pace from the dump's job lines and apply lines: update jobs' ms (mean, max), records a
    job, merged (jobs with more than one update), skipped, late (the drawn clock past the fold tick at
    apply), the drawn clock behind the newest update (ticks) and the dump's own cost."""
    by_n = {int(h["n"]): h for h in frames_hdr}
    up = [h for h in frames_hdr if h.get("updates")]
    out = {
        "jobs": len(frames_hdr), "update_jobs": len(up),
        "update_ms": [sum(h["ms"] for h in up) / max(1, len(up)), max((h["ms"] for h in up), default=0.0)],
        "update_recs": sum(h["recs"] for h in up) / max(1, len(up)),
        "update_items": sum(h["ni"] for h in up) / max(1, len(up)),
        "other_ms": sum(h["ms"] for h in frames_hdr if not h.get("updates")) / max(1, len(frames_hdr) - len(up)),
        "merged": sum(1 for h in up if len(h["updates"]) > 1),
        "updates": sum(len(h["updates"]) for h in up),
        "skipped": sum(1 for h in frames_hdr if h.get("skipped")),
        "dump_ms": sum(a.get("dump_ms", 0.0) for a in applies) / max(1, len(applies)),
        "dump_update_ms": sum(a.get("dump_ms", 0.0) for a in applies if by_n.get(int(a["n"]), {}).get("updates")) / max(1, len(up)),
    }
    late = [a["drawn"] - a["fold"] for a in applies if a.get("fold", -1) >= 0]
    out["late"] = sum(1 for v in late if v > 0.5)
    out["late_most"] = max(late, default=0.0)
    behind = [by_n[int(a["n"])]["data"] - a["drawn"] for a in applies if int(a["n"]) in by_n and by_n[int(a["n"])]["data"] >= 0 and a["drawn"] >= 0]
    out["behind"] = [sum(behind) / max(1, len(behind)), max(behind, default=0.0)] if behind else [0.0, 0.0]
    waits = [(a["usec"] - a["done"]) / 1000.0 for a in applies if a.get("done")]
    out["wait_ms"] = sum(waits) / max(1, len(waits))
    out["margin"] = [sum(a["margin"] for a in applies) / max(1, len(applies)), max((a["margin"] for a in applies), default=0.0)]
    return out


def score_live(truth, dump, apply_path, bounds, kinds, every=1):
    """The live draw against the game at every recorded tick (every `every`'th): the records in effect
    when the drawn clock showed that tick, placed as the shader places them. Returns the report's
    "live" dict, or None when no recorded tick was drawn."""
    applies = read_apply(apply_path)
    if not applies:
        return None
    rows = truth_rows(truth)
    names = truth.get("names") or []
    placer = lane_placer(truth)
    # Each recorded tick: the last apply whose drawn clock was at or before it (what was on screen when
    # the clock got there: that job's records and the ones before).
    dmax, run = [], -1e18
    for a in applies:
        run = max(run, a["drawn"])
        dmax.append(run)
    want = collections.defaultdict(list)  # job n -> [ticks]
    all_ticks = sorted(rows)
    ticks = all_ticks[::every]
    if ticks and ticks[-1] != all_ticks[-1]:
        ticks.append(all_ticks[-1])
    first_drawn = applies[0]["drawn"]
    for t in ticks:
        i = bisect.bisect_right(dmax, t) - 1
        if i < 0 or t < first_drawn or t > dmax[-1]:
            continue
        want[int(applies[i]["n"])].append(t)
    state = DrawState(lane_cells(placer, {int(m[0]) * 8 + int(m[5]): int(m[6]) for m in truth["lanes"]}))
    total = collections.Counter()
    by_name = collections.defaultdict(lambda: [0, 0])
    per_tick = []
    hdrs = []
    last = None
    for h, ids, recs, gone, paths in dump_frames(dump):
        hdrs.append(h)
        state.apply(ids, recs, gone, paths)
        n = int(h["n"])
        for t in want.get(n, ()):
            c, bn = score_live_tick(rows[t], state.drawn_at(t), placer, names, kinds, bounds)
            total.update(c)
            for k, v in bn.items():
                by_name[k][0] += v[0]
                by_name[k][1] += v[1]
            per_tick.append((t, c["game"], c["seen"], c["id right"], c["drawn"], c["phantoms"]))
            last = (t, dict(c))
    if not per_tick:
        return None
    scored = {p[0] for p in per_tick}
    rep = {"ticks": [per_tick[0][0], per_tick[-1][0]], "updates": len(per_tick), "counts": dict(total),
           "last": last, "per_tick": per_tick, "timing": live_timing(hdrs, applies),
           "by_name": {k: v for k, v in sorted(by_name.items(), key=lambda kv: -kv[1][0])[:8]},
           "not_scored": [t for t in ticks if t not in scored]}
    rep["visible_pct"] = 100.0 * total["seen"] / max(1, total["game"])
    rep["phantom_pct"] = 100.0 * total["phantoms"] / max(1, total["drawn"])
    rep["id_pct"] = 100.0 * total["id right"] / max(1, total["game"])
    rep["strict_pct"] = 100.0 * total["packed right"] / max(1, total["packed"])
    rep["visible_last_pct"] = 100.0 * last[1]["seen"] / max(1, last[1]["game"])
    rep["visible_inside_pct"] = 100.0 * (total["seen"] - total["seen outside"]) / max(1, total["game"] - total["game outside"])
    return rep


# ---------------------------------------------------------------- the lane map (offline)

ORTHO_SCALE = 0.65  # camera_rig.gd: an orthographic camera's size per unit of distance
SHOT_PX = (1600, 900)  # the client's window (project.godot) when no screenshot says otherwise
LANE_COLOURS = collections.OrderedDict([
    ("right", (60, 200, 90)),
    ("right, empty", (30, 100, 45)),
    ("same lane, off", (230, 200, 40)),
    ("other lane", (200, 70, 230)),
    ("hole (missing)", (240, 50, 40)),
    ("unsimulated", (120, 120, 120)),
])


def camera_arg(spec, size):
    """--camera: "top" (the default) is straight down (as far as the client tilts, 85 degrees), north
    up, orthographic, framing --size tiles top to bottom; "free" leaves the client's own camera; else
    the client's --camera=<yaw>,<pitch>,<distance>[,ortho] as given. Returns the client's value or None."""
    if spec == "free":
        return None
    if spec == "top":
        return "0,85,%.2f,ortho" % (size / ORTHO_SCALE)
    return spec


def view_bounds(cam, at, size, px=SHOT_PX):
    """The map rectangle (x0, y0, x1, y1, tiles) a screenshot of `px` shows with the client's --camera
    value `cam` round the character at `at`: exact for an orthographic camera looking north (yaw 0),
    the client's clamps applied; otherwise the recorded square, widened to the picture's shape.
    Returns (bounds, exact)."""
    h = size / 2.0
    w = h * px[0] / float(px[1])  # (the square widened to the picture's shape, so it isn't stretched)
    square = (at[0] - w, at[1] - h, at[0] + w, at[1] + h)
    if not cam:
        return square, False
    parts = cam.split(",")
    if len(parts) < 4 or parts[3] != "ortho" or abs(float(parts[0])) > 1e-6:
        return square, False
    pitch = min(85.0, max(20.0, float(parts[1])))
    dist = min(400.0, max(6.0, float(parts[2])))
    screen_h = dist * ORTHO_SCALE  # the camera keeps its height: size is the screen's height
    ground_h = screen_h / math.sin(math.radians(pitch))
    ground_w = screen_h * px[0] / float(px[1])
    return (at[0] - ground_w / 2, at[1] - ground_h / 2, at[0] + ground_w / 2, at[1] + ground_h / 2), True


def lane_states(view, lanes):
    """{lane key: state} at one update: unsimulated, or by the worst of its game items by id (hole
    (missing) > other lane > same lane, off > right; "right, empty" with no game item)."""
    simulated = set(int(k) for k in view["lanes"])
    rank = {"right": 0, "same lane, off": 1, "other lane": 2, "hole (missing)": 3}
    worst = {}
    sim = view["sim"]
    for uid, (key, pos, *_) in view["game"].items():
        key = int(key)
        if key not in simulated:
            continue
        s = sim.get(uid)
        if s is None:
            kind = "hole (missing)"
        elif int(s[0]) != key:
            kind = "other lane"
        elif abs(int(s[1]) - int(pos)) <= NEAR:
            kind = "right"
        else:
            kind = "same lane, off"
        if rank[kind] > rank.get(worst.get(key), -1):
            worst[key] = kind
    out = {}
    for k in lanes:
        out[k] = "unsimulated" if k not in simulated else worst.get(k, "right, empty")
    return out


def lane_map(truth, view, at, size, cam, path, px=SHOT_PX):
    """A top-down PNG of the recorded lanes coloured by lane_states() at `view`, over the rectangle the
    screenshots show (view_bounds), `px` pixels like them. Returns {state: lanes}, or None without Pillow."""
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        return None
    lanes = lane_meta(truth)
    states = lane_states(view, lanes)
    (x0, y0, x1, y1), exact = view_bounds(cam, at, size, px)
    w, h = px
    sx, sy = w / (x1 - x0), h / (y1 - y0)

    def to_px(p):
        return ((p[0] / 256.0 - x0) * sx, (p[1] / 256.0 - y0) * sy)

    img = Image.new("RGB", (w, h), (24, 24, 28))
    d = ImageDraw.Draw(img)
    hs = size / 2.0
    d.rectangle([to_px((256 * (at[0] - hs), 256 * (at[1] - hs))), to_px((256 * (at[0] + hs), 256 * (at[1] + hs)))],
                outline=(90, 90, 110), width=1)
    width = max(1, int(round(0.3 * sx)))
    order = list(LANE_COLOURS)
    # Unsimulated first, so what is wrong draws on top.
    for k in sorted(lanes, key=lambda k: -order.index(states[k])):
        p0, mid, p1 = lanes[k]
        d.line([to_px(p1), to_px(mid), to_px(p0)], fill=LANE_COLOURS[states[k]], width=width)
    c = to_px((256 * at[0], 256 * at[1]))
    d.line([(c[0] - 8, c[1]), (c[0] + 8, c[1])], fill=(255, 255, 255))
    d.line([(c[0], c[1] - 8), (c[0], c[1] + 8)], fill=(255, 255, 255))
    counts = collections.Counter(states.values())
    y = 6
    d.rectangle([4, 4, 250, 10 + 14 * (len(LANE_COLOURS) + 1)], fill=(0, 0, 0))
    d.text((8, y), "tick %d%s" % (view["tick"], "" if exact else " (bounds: the recorded square)"), fill=(255, 255, 255))
    for name, col in LANE_COLOURS.items():
        y += 14
        d.rectangle([8, y + 2, 18, y + 10], fill=col)
        d.text((24, y), "%s: %d" % (name, counts.get(name, 0)), fill=(230, 230, 230))
    img.save(path)
    return dict(counts)


# ---------------------------------------------------------------- running things

def godot_exe(given):
    if given:
        return given
    hits = glob.glob(os.path.expandvars(r"%LOCALAPPDATA%\Microsoft\WinGet\Packages\GodotEngine*\**\Godot_v4.7.2-stable_win64_console.exe"), recursive=True)
    if not hits:
        raise SystemExit("Godot 4.7.2 not found: pass --godot")
    return hits[0]


def replay(godot, wt, stream, truth, out, log, every_tick=True, extra=()):
    """The capture through the build's own belt_items.gd: a job a tick with the drawn clock behind the
    updates as the client runs them (--every-tick), or every_tick False a job an update at its tick;
    extra: more of the replay's arguments (the drawing's toggles). The test script is this checkout's
    (the build checked may not have --view-dump), copied in under a temporary name."""
    tests = pathlib.Path(wt) / "client" / "tests"
    own = ROOT / "client" / "tests" / "belt_bs_replay.gd"
    name = "belt_bs_replay.gd"
    tmp = None
    if tests.resolve() != own.parent.resolve():
        name = "tmp_view_replay.gd"
        tmp = tests / name
        shutil.copyfile(own, tmp)
    try:
        with open(log, "w", encoding="utf-8", errors="replace") as lf:
            r = subprocess.run([godot, "--headless", "--path", str(pathlib.Path(wt) / "client"), "-s", "res://tests/" + name, "--",
                                "--stream=%s" % stream, "--truth=%s" % truth, "--drawn-check", "--view-dump=%s" % out]
                               + (["--every-tick"] if every_tick else []) + list(extra),
                               stdout=lf, stderr=subprocess.STDOUT, timeout=3600)
    finally:
        if tmp is not None:
            tmp.unlink(missing_ok=True)
    if r.returncode != 0 or not pathlib.Path(out).exists():
        raise SystemExit("the replay failed: see %s" % log)


class Lock:
    """The live runs' lock file, made exclusively (polled every `poll` s while another holds it).
    `held_s`: how long it was held, over every hold."""

    def __init__(self, path, who, poll=5.0):
        self.path, self.who, self.poll, self.held, self.since, self.held_s = path, who, poll, False, 0.0, 0.0

    def acquire(self):
        if not self.path or self.held:
            return self
        said = False
        while True:
            try:
                with open(self.path, "x") as f:
                    f.write(self.who)
                self.held, self.since = True, time.time()
                return self
            except FileExistsError:
                if not said:
                    try:
                        who = pathlib.Path(self.path).read_text(errors="replace").strip()[:80]
                    except OSError:
                        who = "?"
                    print("waiting for the lock %s (%s)" % (self.path, who), flush=True)
                    said = True
                time.sleep(self.poll)

    __enter__ = acquire

    def release(self):
        if self.held:
            pathlib.Path(self.path).unlink(missing_ok=True)
            self.held = False
            self.held_s += time.time() - self.since

    def __exit__(self, *a):
        self.release()


def kill_tree(pid):
    subprocess.run(["taskkill", "/F", "/T", "/PID", str(pid)], capture_output=True)


def server_pids(wt):
    """Every factorio.exe started from this worktree (its command line names the worktree's folders)."""
    import psutil
    w = str(pathlib.Path(wt).resolve()).lower()
    out = []
    for p in psutil.process_iter(["name", "cmdline"]):
        try:
            if (p.info["name"] or "").lower() == "factorio.exe" and w in " ".join(p.info["cmdline"] or []).lower():
                out.append(p)
        except psutil.Error:
            pass
    return out


def stop_server(wt):
    import psutil
    for p in server_pids(wt):
        try:
            p.kill()
        except psutil.Error:
            pass


def mod_hash(wt):
    """A hash of the worktree's mod/ (paths and contents)."""
    src = pathlib.Path(wt) / "mod" / "factorio-3d-bridge"
    h = hashlib.sha1()
    for f in sorted(src.rglob("*")):
        if f.is_file():
            h.update(str(f.relative_to(src)).replace("\\", "/").encode())
            h.update(f.read_bytes())
    return h.hexdigest()


def sync_mod(wt):
    src = pathlib.Path(wt) / "mod" / "factorio-3d-bridge"
    dst = pathlib.Path(wt) / "server" / "data" / "mods" / "factorio-3d-bridge"
    if dst.is_symlink() or not dst.exists() or any(
            not (dst / f.relative_to(src)).exists() or (dst / f.relative_to(src)).read_bytes() != f.read_bytes()
            for f in src.rglob("*") if f.is_file()):
        if dst.exists() and not dst.is_symlink():
            shutil.rmtree(dst)
        shutil.copytree(src, dst)
        print("copied the worktree's mod into server/data/mods", flush=True)


def start_server(wt, save, ports, log_dir):
    wt = pathlib.Path(wt)
    log = wt / "server" / "data" / "factorio-current.log"
    t0 = time.time()
    # Factorio moves the last log to factorio-previous.log when it starts (the file's time isn't kept
    # up to date while it writes, so the text tells the new log from the old).
    old = log.read_text(errors="replace") if log.exists() else None
    ps = subprocess.Popen(["powershell", "-ExecutionPolicy", "Bypass", "-File", str(wt / "server" / "run-server.ps1"),
                           "-Save", str(save), "-UdpPort", str(ports[0]), "-GamePort", str(ports[1]), "-RconPort", str(ports[2])],
                          stdout=open(pathlib.Path(log_dir) / "server.out", "w"), stderr=subprocess.STDOUT,
                          creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    while time.time() - t0 < 300:
        time.sleep(1)
        # (The script returns at once: factorio.exe is a windowed program, so the script doesn't wait.)
        try:
            text = log.read_text(errors="replace")
            if text != old:
                if "Starting RCON interface" in text:
                    return ps
                if "Error" in text and ("Goodbye" in text or "Quitting" in text):
                    raise SystemExit("the server stopped: see %s" % log)
        except OSError:
            pass
    raise SystemExit("the server didn't start in 5 minutes: see %s" % log)


def rc(wt, port, cmd, timeout=60):
    pw = (pathlib.Path(wt) / "server" / "data" / "rcon-password.txt").read_text().strip()
    return rcon.run(cmd, port=port, password=pw, timeout=timeout)


def rc_quiet(wt, port, cmd, timeout=10):
    """rc(), "" when the server doesn't answer in time (/f3d-status can go silent on this save)."""
    try:
        return rc(wt, port, cmd, timeout)
    except (OSError, ValueError):
        return ""


class TickPoller:
    """The game's pace while a live run goes: game.tick over wall time (`/sc rcon.print(game.tick)`, every
    `every` s) and the bridge's rate level (/f3d-status, every third poll), on a thread of its own, into
    `out` as JSON lines {"t": wall seconds, "tick": n, "rate": level or None}. The recorder's own wall time
    includes its set-up (a few seconds of RCON and Lua), so dividing the recorded ticks by it understated
    the game's pace by 10-20%; this measures it as the client's F4 line does."""

    def __init__(self, wt, port, out, every=2.0):
        self.wt, self.port, self.out, self.every = wt, port, out, every
        self.rows = []
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self._thread.start()
        return self

    def stop(self):
        self._stop.set()
        self._thread.join(self.every * 3)
        return self.rows

    def _run(self):
        n = 0
        with open(self.out, "a") as f:
            while not self._stop.wait(self.every):
                row = {"t": time.time(), "tick": None, "rate": None}
                t = rc_quiet(self.wt, self.port, "/sc rcon.print(game.tick)", 5).strip().splitlines()
                if t and t[-1].strip().isdigit():
                    row["tick"] = int(t[-1].strip())
                if n % 3 == 0:
                    lv = rate_levels(rc_quiet(self.wt, self.port, "/f3d-status", 5))
                    row["rate"] = lv[-1] if lv else None
                n += 1
                self.rows.append(row)
                f.write(json.dumps(row) + "\n")
                f.flush()


def pace_of(rows, t0, t1):
    """The game's UPS over the poll rows between wall times t0 and t1 (each pair of ticks over its wall
    time): {"ups": median, "p10", "min", "n", "levels": the rate levels seen, in order, without repeats},
    or None with fewer than two ticks."""
    sel = [r for r in rows if t0 <= r["t"] <= t1 and r.get("tick")]
    ups = sorted((b["tick"] - a["tick"]) / (b["t"] - a["t"]) for a, b in zip(sel, sel[1:]) if b["t"] > a["t"])
    if not ups:
        return None
    levels = []
    for r in rows:
        if t0 <= r["t"] <= t1 and r.get("rate") is not None and (not levels or levels[-1] != r["rate"]):
            levels.append(r["rate"])
    return {"ups": round(ups[len(ups) // 2], 1), "p10": round(ups[len(ups) // 10], 1), "min": round(ups[0], 1),
            "n": len(ups), "levels": levels}


def pace_text(pace):
    if not pace:
        return "unknown"
    s = "%.1f median (p10 %.1f, min %.1f, %d readings)" % (pace["ups"], pace["p10"], pace["min"], pace["n"])
    if pace.get("levels"):
        s += ", rate level %s" % "->".join(str(v) for v in pace["levels"])
    return s


def puppet_at(wt, port):
    r = rc(wt, port, "/c __factorio-3d-bridge__ local p = %s; rcon.print(p and (p.position.x .. ',' .. p.position.y) or 'none')" % PUPPET)
    r = r.strip().splitlines()[-1] if r.strip() else "none"
    try:
        return None if r == "none" else tuple(float(v) for v in r.split(","))
    except ValueError:
        return None


def teleport(wt, port, at):
    rc(wt, port, "/c __factorio-3d-bridge__ local p = %s; if p then p.teleport({%f, %f}) end" % (PUPPET, at[0], at[1]))


def settings_file(path, mode, hold60="on", extra=()):
    """The client's settings: Belt updates Automatic (-1) or Unlimited (0); Hold the game at 60 UPS; `extra`
    more [graphics] lines (--client-setting key=value, e.g. grass_3d="off")."""
    more = "".join("%s\n" % e for e in extra)
    path.write_text("[graphics]\n\nbelt_updates=%d\nhold_ups=%s\n%s\n[meta]\n\nbelt_auto=true\n"
                    % (-1 if mode == "automatic" else 0, "true" if hold60 == "on" else "false", more))


def serve_file(ports):
    """Where a kept server (--reuse-server) is written down: its worktree, ports, save copy, mod hash."""
    return pathlib.Path(os.environ.get("TEMP", ".")) / ("belt_view_check_serve_%d.json" % ports[2])


def server_alive(wt, ports):
    return bool(server_pids(wt)) and rc_quiet(wt, ports[2], "/sc rcon.print(game.tick)", 10).strip().isdigit()


def stop_kept(ports):
    """Stops the server --reuse-server kept on these ports, deletes its save copy. True if there was one."""
    sf = serve_file(ports)
    if not sf.exists():
        return False
    st = json.loads(sf.read_text())
    stop_server(st["worktree"])
    for _ in range(30):  # the server lets go of the save a moment after it is stopped
        try:
            pathlib.Path(st["save"]).unlink(missing_ok=True)
            break
        except PermissionError:
            time.sleep(1)
    sf.unlink(missing_ok=True)
    return True


def ensure_server(wt, ports, out, save_src):
    """--reuse-server: the server kept on these ports when it is this worktree's, running and on the
    same mod; else one started (the mod copied in first, a fresh copy of the save) and written down.
    Returns (process or None, "reused" or "started")."""
    sf = serve_file(ports)
    h = mod_hash(wt)
    if sf.exists():
        st = json.loads(sf.read_text())
        same = pathlib.Path(st["worktree"]).resolve() == pathlib.Path(wt).resolve() and st.get("ports") == list(ports)
        if same and st.get("mod") == h and server_alive(wt, ports):
            return None, "reused"
        why = "the mod changed" if same and st.get("mod") != h else "not running" if same else "another worktree's"
        print("the kept server goes (%s)" % why, flush=True)
        stop_kept(ports)
    sync_mod(wt)
    save = pathlib.Path(wt) / "server" / "saves" / "viewcheck-serve.zip"
    shutil.copyfile(save_src, save)
    proc = start_server(wt, save, ports, out)
    sf.write_text(json.dumps({"worktree": str(pathlib.Path(wt).resolve()), "ports": list(ports), "save": str(save),
                              "mod": h, "started": time.time()}))
    return proc, "started"


def first_bs(path):
    """Whether the capture has a `bs` line yet."""
    try:
        with open(path, "rb") as f:
            return b'"t":"bs"' in f.read(1 << 16)
    except OSError:
        return False


def live(a, wt, ports, out, shots, prefix, capture, lock):
    """One live run: the server (started, or the kept one), the character placed, the client (Zenith
    windowed, or with --stand-in tools/belt_bench.py), the recording. The lock is held from the
    server's start (or the client's, on a kept server) until the client is gone (and the server, unless
    kept). Returns (at, stream, truth, info)."""
    wt = pathlib.Path(wt)
    stand_in = a.stand_in and capture
    godot = None if stand_in else godot_exe(a.godot)
    save_src = pathlib.Path(a.save) if a.save else wt / "server" / "saves" / "zt.zip"
    if not save_src.exists():
        save_src = ROOT / "server" / "saves" / "zt.zip"
    reuse = a.reuse_server and capture
    save = None
    if not reuse:
        save = wt / "server" / "saves" / "viewcheck.zip"
        save.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(save_src, save)
        if capture:
            sync_mod(wt)
    cfg = out / ("%ssettings.cfg" % prefix)
    settings_file(cfg, a.settings, a.hold60, a.client_setting)
    stream = out / ("%sstream.jsonl" % prefix)
    truth = out / ("%struth.json" % prefix)
    for f in (stream, truth):
        f.unlink(missing_ok=True)
    cam = camera_arg(a.camera, a.size)
    info = {"client": "stand-in (tools/belt_bench.py --bs, bfar m %d n %d)" % (a.stand_in_cap, a.stand_in_near) if stand_in
            else "Zenith, windowed (Belt updates %s; %s)" % (
                a.settings, "the game's time of day" if a.daytime == "game" else "time of day held at %s" % a.daytime),
            "daytime": None if stand_in else a.daytime,
            "hold60": None if stand_in else a.hold60, "recorder": a.record if (capture or a.record_main) else None,
            "camera": cam or "the client's own", "server": "started"}  # (a stand-in's: the lane map's ground)
    client = server = poller = None
    t_start = time.time()
    shot_times = []
    t_client = t_rec = t_end = time.time()
    lock.acquire()
    t_locked = time.time()
    try:
        if reuse:
            server, info["server"] = ensure_server(wt, ports, out, save_src)
        else:
            server = start_server(wt, save, ports, out)
        print("%sserver %s in %.0f s" % (prefix, info["server"], time.time() - t_locked), flush=True)
        if a.at:
            teleport(wt, ports[2], a.at)
        t_client = time.time()
        if stand_in:
            args = [sys.executable, str(ROOT / "tools" / "belt_bench.py"), "--udp-port", str(ports[0]), "--rcon-port", str(ports[2]),
                    "--password-file", str(wt / "server" / "data" / "rcon-password.txt"), "--bs", "--capture", str(stream),
                    "--teleport", "%f,%f" % a.at if a.at else "", "--warmup", "100000", "--seconds", "1",
                    "--cap", str(a.stand_in_cap), "--near", str(a.stand_in_near)]
        else:
            args = [godot] + a.godot_arg + ["--path", str(wt / "client"), "--", "--factorio-port=%d" % ports[0], "--port=%d" % a.client_port,
                    "--settings-file=%s" % cfg]
            if cam:
                args.append("--camera=%s" % cam)
            args.extend(a.client_arg)
            if a.daytime != "game":
                args.append("--sky=@%s" % a.daytime)  # sky.gd: the game's planet, the time of day held
            if capture:
                args.append("--belt-capture=%s" % stream)
                if a.draw_dump == "on":
                    args.append("--belt-draw-dump=%s" % (out / ("%sdraw.bin" % prefix)))
            shot_times = list(range(15, int(a.settle_max + a.first_bs + a.seconds * 30), 10))
            for t in shot_times:
                args.append("--screenshot=%s@%d" % (out / ("%sshot_%03d.png" % (prefix, t)), t))
        client = subprocess.Popen(args, cwd=str(wt), stdout=open(out / ("%sclient.out" % prefix), "w"), stderr=subprocess.STDOUT)
        poller = TickPoller(wt, ports[2], out / ("%spoll.jsonl" % prefix)).start()
        # Joined: the capture's first `bs` line (no RCON: /f3d-status can go silent). A checkout
        # without `bs` (main): the bridge's /f3d-status naming the client.
        while True:
            time.sleep(1)
            if client.poll() is not None:
                raise SystemExit("6. FAIL: the client stopped: see %s" % (out / ("%sclient.out" % prefix)))
            if capture and first_bs(stream):
                break
            if not capture and "client on port %d" % a.client_port in rc_quiet(wt, ports[2], "/f3d-status"):
                break
            if time.time() - t_client > a.first_bs:
                raise SystemExit("6. FAIL: %s in %d s (--first-bs)" % (
                    "no `bs` update captured" if capture else "the client didn't join", a.first_bs))
        if a.at:
            teleport(wt, ports[2], a.at)  # again: a character the bridge takes over on joining
        at = puppet_at(wt, ports[2]) or a.at
        print("%sjoined after %.0f s; character at %s; settling at least %d s" % (prefix, time.time() - t_client, at, a.settle), flush=True)
        # Settled once the first load is done (the capture's last update has no `ld`) and --settle has
        # gone; a checkout without `bs` (main) waits --settle only.
        t_settle = time.time()
        while True:
            gone = time.time() - t_settle
            loading = stream_loading(stream) if capture else False
            if gone >= a.settle and loading is False:
                break
            if gone >= a.settle_max:
                raise SystemExit("6. FAIL: first load didn't finish in %d s (--settle-max): %s" % (
                    a.settle_max, "no `bs` update captured" if loading is None else "the capture's last update still has `ld`"))
            if client.poll() is not None:
                raise SystemExit("6. FAIL: the client stopped: see %s" % (out / ("%sclient.out" % prefix)))
            time.sleep(1)
        print("%ssettled after %.0f s" % (prefix, time.time() - t_settle), flush=True)
        (out / ("%sstatus.txt" % prefix)).write_text(rc_quiet(wt, ports[2], "/f3d-status"))
        t_rec = time.time()
        if capture or a.record_main:
            h = a.size / 2.0
            if a.record_bounds == "view":
                # (The screenshots' whole ground, so the live draw is scored over what the owner sees.)
                (bx0, by0, bx1, by1), _ = view_bounds(cam, at, a.size)
                area = "%f,%f,%f,%f" % (bx0, by0, bx1, by1)
            else:
                area = "%f,%f,%f,%f" % (at[0] - h, at[1] - h, at[0] + h, at[1] + h)
            info["area"] = [float(v) for v in area.split(",")]
            r = subprocess.run([sys.executable, str(ROOT / "tools" / "belt_sim" / "record.py"), "--rcon-port", str(ports[2]),
                                "--password-file", str(wt / "server" / "data" / "rcon-password.txt"),
                                "--script-output", str(wt / "server" / "data" / "script-output"),
                                "--area=" + area, "--ticks", str(int(a.seconds * 60)), "--out", str(truth),
                                "--sample", a.record],
                               capture_output=True, text=True)
            (out / ("%srecord.out" % prefix)).write_text(r.stdout + r.stderr)
            if r.returncode != 0:
                raise SystemExit("the recording failed: %s" % (r.stdout + r.stderr)[-400:])
        else:
            time.sleep(a.seconds)
        t_end = time.time()
        if capture:
            # The client's capture can trail the game: wait (up to --tail-wait s) for its updates to
            # reach the recording's last tick before the client goes, so the replay compares them all.
            last = truth_last_tick(truth)
            t_wait = time.time()
            while last is not None and time.time() - t_wait < a.tail_wait and client.poll() is None:
                k = stream_last_k(stream)
                if k is not None and k >= last:
                    break
                time.sleep(1)
            k = stream_last_k(stream)
            info["capture_tail"] = {"last_k": k, "recorded_last": last, "waited_s": round(time.time() - t_wait)}
            print("%scapture's last update %s, the recording's last tick %s (waited %.0f s)" % (
                prefix, k, last, time.time() - t_wait), flush=True)
        with open(out / ("%sstatus.txt" % prefix), "a") as f:
            f.write(rc_quiet(wt, ports[2], "/f3d-status"))
        time.sleep(2)
    finally:
        if poller is not None:
            rows = poller.stop()
            # The game's pace from the client's start to the recording (joining, the first load, settling)
            # and while scored (the recording's own wall time, its set-up included).
            # ... and the 20 s just before the recording: the settled pace, past the join's dip, no recorder.
            info["pace"] = {"settling": pace_of(rows, t_client, t_rec), "scored": pace_of(rows, t_rec, t_end),
                            "settled": pace_of(rows, t_rec - 20.0, t_rec)}
        if client is not None:
            kill_tree(client.pid)
        if not reuse:
            stop_server(wt)
            if server is not None:
                kill_tree(server.pid)
            for _ in range(30):  # the server lets go of the save a moment after it is stopped
                try:
                    save.unlink(missing_ok=True)
                    break
                except PermissionError:
                    time.sleep(1)
        lock.release()
    # The view while the recording ran (or the last before it ended).
    kept = []
    for t in shot_times:
        f = out / ("%sshot_%03d.png" % (prefix, t))
        if not f.exists():
            continue
        if t_rec - 12 <= f.stat().st_mtime <= t_end + 1:
            kept.append(f)
        else:
            f.unlink()
    info["shots"] = [str(f) for f in kept]
    if shots:
        shots.mkdir(parents=True, exist_ok=True)
        for i, f in enumerate(kept):
            shutil.copyfile(f, shots / ("%sview_%d.png" % (prefix, i + 1)))
    info["seconds"] = {"live": round(time.time() - t_start), "lock": round(time.time() - t_locked), "recording": round(t_end - t_rec)}
    (out / ("%srun.json" % prefix)).write_text(json.dumps(dict(info, at=list(at) if at else None, size=a.size, ticks=int(a.seconds * 60))))
    print("%sdone in %.0f s, %d screenshots" % (prefix, time.time() - t_start, len(kept)), flush=True)
    return at, stream, truth, info


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--worktree", default=str(ROOT))
    ap.add_argument("--ports", default="35040,35041,35042", help="the bridge's UDP port, the game port, RCON")
    ap.add_argument("--client-port", type=int, default=0, help="the client's own UDP port (default: the UDP port + 3)")
    ap.add_argument("--at", default="", help="x,y to put the character (default: where it stands)")
    ap.add_argument("--size", type=float, default=64)
    ap.add_argument("--seconds", type=float, default=10)
    ap.add_argument("--settle", type=float, default=40, help="seconds at least before recording, the first load done too")
    ap.add_argument("--settle-max", type=float, default=180, help="FAIL when the first load isn't done after this many seconds")
    ap.add_argument("--first-bs", type=float, default=60, help="FAIL when no `bs` update is captured this many seconds after the client starts")
    ap.add_argument("--hold60", choices=["off", "on"], default="on", help="the client's Hold the game at 60 UPS (on: the owner's "
                    "default; off: a diagnostic)")
    ap.add_argument("--settings", choices=["automatic", "unlimited"], default="automatic")
    ap.add_argument("--client-setting", action="append", default=[], help="another line for the client's settings.cfg "
                    "[graphics], key=value as Godot's ConfigFile writes it (repeatable; a diagnostic: grass_3d=\"off\")")
    ap.add_argument("--record", default="updates", help="record.py --sample: updates (the bridge's update ticks, the default), "
                    "tick (every tick, as before: heavier, slows the bridge), or N[@phase]")
    ap.add_argument("--camera", default="top", help="top (straight down, north up, orthographic, --size tiles high: the "
                    "default), free (the client's own), or the client's <yaw>,<pitch>,<distance>[,ortho]")
    ap.add_argument("--daytime", default="0", help="the client's time of day, held (0: noon, the default, so the "
                    "screenshots are always by day; 0.5: midnight), or game (the game's clock)")
    ap.add_argument("--stand-in", action="store_true", help="tools/belt_bench.py --bs --capture instead of Zenith: the bridge "
                    "only, no Godot, no screenshots")
    ap.add_argument("--stand-in-cap", type=int, default=6000, help="(--stand-in) bfar m, the bridge's belt cap")
    ap.add_argument("--stand-in-near", type=int, default=160, help="(--stand-in) bfar r and n")
    ap.add_argument("--reuse-server", action="store_true", help="keep the server running after the run and use it next time "
                    "(teleporting the character), restarted only when the worktree's mod changed")
    ap.add_argument("--stop-server", action="store_true", help="stop the server --reuse-server kept on --ports, and exit")
    ap.add_argument("--save", default="", help="the save (copied; default <worktree>/server/saves/zt.zip)")
    ap.add_argument("--shots", default="")
    ap.add_argument("--json", default="")
    ap.add_argument("--main", default="", help="a checkout without `bs` (main): the same spot, screenshots only "
                    "(with --reuse-server on --ports + 10)")
    ap.add_argument("--record-main", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--tail-wait", type=float, default=30, help="seconds at most to wait after the recording for the "
                    "capture to reach its last tick (the client's capture can trail the game)")
    ap.add_argument("--lock", default="", help="a lock file held while a run's server and client are live (made exclusively, "
                    "polled every 5 s)")
    ap.add_argument("--keep", default="", help="where the capture, recording and logs go (default: a temp folder)")
    ap.add_argument("--record-bounds", choices=["view", "square"], default="view", help="what the game's belts are recorded "
                    "over: view (the screenshots' whole ground, the default) or square (--size round the character)")
    ap.add_argument("--draw-dump", choices=["on", "off"], default="on", help="the client's --belt-draw-dump (draw.bin): the "
                    "live draw scored against the game (section L, the gate)")
    ap.add_argument("--dump", default="", help="(--analyze) the client's draw.bin (default: beside --stream)")
    ap.add_argument("--gate-by-id", choices=["on", "off"], default="off", help="on: the live draw FAILs when by id on packed "
                    "lanes is under 90%%; off (the default): it is reported only (a packed lane of one kind looks the same "
                    "whichever of its items is where)")
    ap.add_argument("--godot-arg", action="append", default=[], help="more for Godot itself, before --path, e.g. "
                    "--godot-arg=--gpu-profile (the render steps' times for --stutter-probe); repeatable")
    ap.add_argument("--client-arg", action="append", default=[], help="more for the client's command line, e.g. "
                    "--client-arg=--belt-draw-coalesce=off; repeatable (the replay doesn't get them)")
    ap.add_argument("--replay", choices=["every-tick", "update"], default="every-tick",
                    help="how the replay runs the client's job: every-tick (a job a tick, the drawn clock behind the "
                    "updates, as the client: the default) or update (a job an update at its tick, as before)")
    ap.add_argument("--replay-arg", action="append", default=[], help="more for the replay (belt_bs_replay.gd), e.g. "
                    "--replay-arg=--belt-draw-lead=off; repeatable")
    ap.add_argument("--godot", default="")
    ap.add_argument("--analyze", action="store_true", help="no live run: --stream and --truth given")
    ap.add_argument("--stream", default="")
    ap.add_argument("--truth", default="")
    ap.add_argument("--status", default="", help="(--analyze) /f3d-status answers (default: status.txt beside --stream)")
    ap.add_argument("--settings-file", default="", help="(--analyze) the client's settings (default: settings.cfg beside --stream)")
    a = ap.parse_args()
    ports = [int(p) for p in a.ports.split(",")]
    if a.stop_server:
        print("stopped the kept server" if stop_kept(ports) else "no kept server on these ports")
        return
    a.client_port = a.client_port or ports[0] + 3
    a.at = tuple(float(v) for v in a.at.split(",")) if a.at else None
    out = pathlib.Path(a.keep) if a.keep else pathlib.Path(os.environ.get("TEMP", ".")) / ("belt_view_check_%d" % int(time.time()))
    out.mkdir(parents=True, exist_ok=True)
    shots = pathlib.Path(a.shots) if a.shots else None
    t0 = time.time()
    lock = Lock(a.lock, "belt_view_check %s" % a.worktree)
    info = {}
    if a.analyze:
        stream, truth, at = pathlib.Path(a.stream), pathlib.Path(a.truth), a.at
        if at is None:
            with open(stream, encoding="utf-8") as f:
                for line in f:
                    m = json.loads(line)
                    if m.get("t") == "bs" and "fx" in m:
                        at = (m["fx"] / 256.0, m["fy"] / 256.0)
                        break
        rj = stream.parent / "run.json"
        if rj.exists():
            info = json.loads(rj.read_text())
    else:
        try:
            at, stream, truth, info = live(a, a.worktree, ports, out, shots, "", True, lock)
            if a.main:
                a.at = at
                mports = [p + 10 for p in ports] if a.reuse_server else ports
                ma = argparse.Namespace(**vars(a))
                ma.client_port = mports[0] + 3
                live(ma, a.main, mports, out, shots, "main_", False, lock)
        finally:
            lock.release()
    t_live = time.time() - t0
    views_path = out / "view.jsonl"
    every_tick = a.replay == "every-tick"
    replay(godot_exe(a.godot), a.worktree, stream, truth, views_path, out / "replay.out", every_tick, a.replay_arg)
    views, drawn = read_views(views_path)
    if not views:
        raise SystemExit("no update of the capture falls in the recording: see %s" % (out / "replay.out"))
    with open(truth, encoding="utf-8") as f:
        rec = json.load(f)
    status = pathlib.Path(a.status) if a.status else pathlib.Path(stream).parent / "status.txt"
    cfg = pathlib.Path(a.settings_file) if a.settings_file else pathlib.Path(stream).parent / "settings.cfg"
    run = run_info(stream, status, cfg, (views[0]["tick"], views[-1]["tick"]))
    if info:
        run["client"] = info.get("client")
        run["server"] = info.get("server")
        run["capture_tail"] = info.get("capture_tail")
        if info.get("hold60") is None and "stand-in" in str(info.get("client")):
            run["hold60"] = "n/a (stand-in)"
    run["recorder"] = "%s, %d rows" % (rec.get("sample", "tick (an older recording)"), len(rec["ticks"]))
    if len(views) < len(rec["ticks"]):
        cut = views[-1]["tick"] < int(rec["ticks"][-1][0])
        run["recorder"] += " (%d compared%s)" % (len(views), ": the capture ends first" if cut else "")
    rs = (info.get("seconds") or {}).get("recording")
    if rs:
        # (The wall time includes record.py's set-up, a few seconds of RCON and Lua, so the ticks over it
        # understate the game's pace; run["pace"], polled, is the measure.)
        run["recorder"] += ", %d ticks in %d s of wall time (its set-up included)" % (info.get("ticks") or int(a.seconds * 60), rs)
    run["pace"] = info.get("pace")
    dump = pathlib.Path(a.dump) if a.dump else pathlib.Path(stream).parent / "draw.bin"
    live_rep = None
    if dump.exists() and pathlib.Path(str(dump) + ".apply.jsonl").exists():
        size0 = float(info.get("size") or a.size)
        cam0 = info.get("camera") if info else camera_arg(a.camera, size0)
        cam0 = None if not cam0 or cam0.startswith("the client") else cam0
        bounds = tuple(info["area"]) if info.get("area") else view_bounds(cam0, at, size0)[0]
        live_rep = score_live(rec, dump, pathlib.Path(str(dump) + ".apply.jsonl"), bounds, kind_map(views, rec.get("names") or []))
        if live_rep is None:
            print("no recorded tick was drawn by the client: the live draw isn't scored (%s)" % dump)
    rep = analyze(rec, views, drawn, at, run, every_tick, live_rep, gate_by_id=a.gate_by_id == "on")
    if a.replay_arg:
        rep["replay"] += " " + " ".join(a.replay_arg)
    size = float(info.get("size") or a.size)
    cam = info.get("camera") if info else camera_arg(a.camera, size)
    cam = None if not cam or cam.startswith("the client") else cam
    px = SHOT_PX
    if info.get("shots"):
        try:
            from PIL import Image
            with Image.open(info["shots"][-1]) as im:
                px = im.size
        except (ImportError, OSError):
            pass
    lm = lane_map(rec, views[-1], at, size, cam, out / "lane_map.png", px)
    if lm is not None:
        rep["lane_map"] = {"file": str(out / "lane_map.png"), "lanes": lm}
        if shots:
            shots.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(out / "lane_map.png", shots / "lane_map.png")
    rep["seconds"] = {"live": round(t_live), "total": round(time.time() - t0), "lock": round(lock.held_s)}
    text = format_report(rep)
    print(text)
    if lm is not None:
        print("lane map (the last update, the screenshots' bounds): %s" % rep["lane_map"]["file"])
    print("(live part %d s, lock held %d s, all %d s; files in %s)" % (rep["seconds"]["live"], rep["seconds"]["lock"],
                                                                     rep["seconds"]["total"], out))
    if a.json:
        pathlib.Path(a.json).write_text(json.dumps(rep, indent=1, default=lambda o: dict(o) if isinstance(o, collections.Counter) else str(o)))
    sys.exit(0 if rep["pass"] else 1)


if __name__ == "__main__":
    main()
