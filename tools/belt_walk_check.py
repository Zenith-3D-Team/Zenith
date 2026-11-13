#!/usr/bin/env python3
"""How the client's belts look while the character walks: one live run with the stutter probe walking a
route, the game's belts recorded round the character as it goes, and the live draw scored against them
sample by sample, broken down by how long each lane has been in view.

    python tools/belt_walk_check.py --worktree <wt> --ports <udp>,<game>,<rcon> --at=-62,-26 [--size 60]
        [--route fast|stand75|...] [--sample 30] [--settle 60] [--hold60 on|off] [--keep <dir>] [--lock <file>]
        [--json <out>] [--shots-every 5]
    python tools/belt_walk_check.py --analyze --keep <dir>      (score a kept run again)

Built on tools/belt_view_check.py (imported, not changed): its server, lock, settings file, pinned camera,
draw-dump reader and live timing. What differs from a belt_view_check run:

- The client runs the stutter probe (`--stutter-probe=<probe.json>@<route>`, client/scripts/debug/stutter_probe.gd):
  after the probe's warm-up (set past --settle, so the first load is done) the bridge walks the character
  along the route (`fast`: two laps round where it joined at the character's own speed; `stand75`: stands,
  the control). The camera is belt_view_check's pinned top camera (straight down, orthographic, --size
  tiles high): camera_rig.gd keeps following the character with it, so the screen is always centred on
  the character, a frame or so behind.
- The recording (the game's belts) starts when the character moves (a standing route: when the probe's
  warm-up is over) and covers every belt lane within the route's reach (tools/belt_sim/record.py's Lua
  with a filter: each sample reads only the lanes within the view's half sizes plus --margin tiles of the
  character, whose place it notes), every --sample ticks, so the game stays near real speed.
- The score: as belt_view_check's section L (the records the GPU held when the drawn clock showed each
  recorded tick, placed as the shader places them, matched to the game's items one to one by place and
  item within 0.15 tile; phantoms, holes), but the bounds are the client's own ground view at the job
  that was on screen (the dump's `view`), clipped to what was recorded round the character, so the
  bounds move with the character. Each lane's time in view is tracked sample by sample: a lane in view
  at the recording's first sample counts as steady; one that comes in later is aged from the sample it
  came in on. Buckets: under 1 s, 1-3 s, 3-10 s, 10 s and more (steady).
- Images: side_walk_<shot>_<tick>.png (the client's screenshot on top, the game's items at the nearest
  sample as dots over the same bounds below) and a 2x crop of the middle band.
"""

import argparse
import bisect
import collections
import json
import math
import pathlib
import re
import shutil
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import belt_view_check as bvc  # noqa: E402
import rcon  # noqa: E402

AGE_BUCKETS = [(60, "under 1 s"), (180, "1-3 s"), (600, "3-10 s"), (1 << 60, "10 s and more")]
# Factorio's 16-way directions the probe walks in: (dx, dy) per tile.
DIRS = {0: (0, -1), 4: (1, 0), 8: (0, 1), 12: (-1, 0), 2: (1, -1), 6: (1, 1), 10: (-1, 1), 14: (-1, -1)}

# The recording: record.py's Lua, but each sample reads only the lanes within (hw, hh) tiles of the
# character (its place through the bridge's remote interface, added for the run as record.py's is) and
# notes where the character was. One JSON object as record.py's, plus "pos": [[tick, x*256, y*256], ...]
# and "near": [hw, hh].
REMOTE = r"""
if remote.interfaces["f3d_rec"] then remote.remove_interface("f3d_rec") end
remote.add_interface("f3d_rec", {pos = function()
  local p = %(puppet)s
  if p and p.valid then return {p.position.x, p.position.y} end
  return nil
end})
rcon.print("f3d_rec added")
"""
REMOTE_OFF = 'if remote.interfaces["f3d_rec"] then remote.remove_interface("f3d_rec") end'

LUA = r"""
local s = game.get_surface("%(surface)s")
local area = {{%(x0)f, %(y0)f}, {%(x1)f, %(y1)f}}
local ents = s.find_entities_filtered({area = area, type = {"transport-belt", "underground-belt", "splitter",
  "loader", "loader-1x1", "linked-belt", "lane-splitter"}})
local lanes, meta, mx, my = {}, {}, {}, {}
for _, e in pairs(ents) do
  for i = 1, e.get_max_transport_line_index() do
    local l = e.get_transport_line(i)
    lanes[#lanes + 1] = l
    local len = l.line_length
    local function at(q)
      local p = l.get_line_item_position(q)
      return {math.floor(p.x * 256 + 0.5), math.floor(p.y * 256 + 0.5)}
    end
    local shape = ""
    if e.type == "transport-belt" then shape = e.belt_shape
    elseif e.type == "underground-belt" then shape = e.belt_to_ground_type
    elseif e.type == "loader" or e.type == "loader-1x1" then shape = e.loader_type end
    local speed = e.prototype.belt_speed
    local split = {}
    if e.type == "splitter" or e.type == "lane-splitter" then
      local flt = e.splitter_filter
      split = {e.splitter_input_priority, e.splitter_output_priority, flt and flt.name and flt.name.name or (flt and flt.name) or ""}
    end
    meta[#meta + 1] = {e.unit_number, e.name, e.type, shape, e.direction, i, math.floor(len * 256 + 0.5),
      at(0), at(len / 2), at(len), math.floor(speed * 256 + 0.5), e.status or 0, split}
    mx[#mx + 1] = e.position.x
    my[#my + 1] = e.position.y
  end
end
local file = "%(file)s"
local every, phase = %(every)d, %(phase)d
local hw, hh = %(hw)f, %(hh)f
local names, name_ids = {}, {}
local buf, nrows, wrote = {}, 0, false
local pos = {}
local function flush()
  if #buf > 0 then
    helpers.write_file(file, (wrote and ",\n" or "") .. table.concat(buf, ",\n"), true)
    wrote, buf = true, {}
  end
end
helpers.write_file(file, '{"sample":"%(sample)s","lanes":' .. helpers.table_to_json(meta) .. ',"ticks":[\n', false)
local t_end = game.tick + %(ticks)d
script.on_nth_tick(1, function()
  local t = game.tick
  if t %% every == phase %% every then
    local c = remote.call("f3d_rec", "pos")
    local row = {t}
    if c then
      pos[#pos + 1] = "[" .. t .. "," .. math.floor(c[1] * 256 + 0.5) .. "," .. math.floor(c[2] * 256 + 0.5) .. "]"
      local x0, x1, y0, y1 = c[1] - hw, c[1] + hw, c[2] - hh, c[2] + hh
      for j, l in ipairs(lanes) do
        if mx[j] >= x0 and mx[j] <= x1 and my[j] >= y0 and my[j] <= y1 and l.valid then
          for _, it in ipairs(l.get_detailed_contents()) do
            local n = it.stack.name
            local id = name_ids[n]
            if not id then names[#names + 1] = n id = #names name_ids[n] = id end
            row[#row + 1] = j
            row[#row + 1] = it.unique_id
            row[#row + 1] = math.floor(it.position * 256 + 0.5)
            row[#row + 1] = it.stack.count
            row[#row + 1] = id
          end
        end
      end
    end
    buf[#buf + 1] = "[" .. table.concat(row, ",") .. "]"
    nrows = nrows + 1
    if #buf >= 4 then flush() end
  end
  if t >= t_end then
    flush()
    helpers.write_file(file, '\n],"names":' .. helpers.table_to_json(names) .. ',"rows":' .. nrows
      .. ',"near":[' .. hw .. ',' .. hh .. '],"pos":[' .. table.concat(pos, ",") .. ']}', true)
    helpers.write_file(file .. ".done", tostring(nrows), false)
    script.on_nth_tick(1, nil)
  end
end)
rcon.print("recording " .. #lanes .. " lanes from " .. game.tick .. " (every " .. every .. ")")
"""


def one_line(lua):
    return " ".join(l.strip() for l in lua.splitlines() if l.strip() and not l.strip().startswith("--"))


# ---------------------------------------------------------------- the route

def probe_routes(wt):
    """The stutter probe's ROUTES ({name: [[direction, seconds], ...]}) read from its script."""
    text = (pathlib.Path(wt) / "client" / "scripts" / "debug" / "stutter_probe.gd").read_text(encoding="utf-8", errors="replace")
    m = re.search(r"const ROUTES := \{(.*?)\n\}", text, re.S)
    out = {}
    if not m:
        return out
    for name, body in re.findall(r'"(\w+)":\s*\[((?:\[[^\]]*\],?\s*)+)\]', m.group(1), re.S):
        legs = [[int(float(a)), float(b)] for a, b in re.findall(r"\[\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*\]", body)]
        out[name] = legs
    return out


def route_reach(legs, speed):
    """How far the route goes from where it starts, (min x, min y, max x, max y) in tiles at `speed`
    tiles a second, and its seconds."""
    x = y = 0.0
    lo = [0.0, 0.0]
    hi = [0.0, 0.0]
    secs = 0.0
    for d, s in legs:
        dx, dy = DIRS.get(int(d), (0, 0))
        n = math.hypot(dx, dy) or 1.0
        x += dx / n * speed * s
        y += dy / n * speed * s
        lo = [min(lo[0], x), min(lo[1], y)]
        hi = [max(hi[0], x), max(hi[1], y)]
        secs += s
    return (lo[0], lo[1], hi[0], hi[1]), secs


def moving_route(legs):
    return any(int(d) >= 0 for d, _ in legs)


# ---------------------------------------------------------------- the score

def kinds_from_stream(stream, truth, most=400000):
    """{the bridge's item id: the recording's item name}: by the items both have (the capture's `sl` lists
    name each item's id, the recording its name), each id the name most of its items have."""
    item_of = {}
    with open(stream, encoding="utf-8", errors="replace") as f:
        for line in f:
            if '"sl"' not in line:
                continue
            try:
                m = json.loads(line)
            except ValueError:
                continue
            sl = m.get("sl") if isinstance(m, dict) else None
            if not sl:
                continue
            i = 0
            while i + 2 < len(sl):
                n = int(sl[i + 2])
                for j in range(n):
                    item_of[int(sl[i + 3 + j * 4])] = int(sl[i + 4 + j * 4])
                i += 3 + n * 4
            if len(item_of) > most:
                break
    names = truth.get("names") or []
    votes = collections.defaultdict(collections.Counter)
    for row in truth["ticks"]:
        for i in range(1, len(row) - 4, 5):
            uid = int(row[i + 1])
            sid = item_of.get(uid)
            if sid is not None:
                idx = int(row[i + 4])
                votes[sid][names[idx - 1] if 1 <= idx <= len(names) else "#%d" % idx] += 1
    return {sid: c.most_common(1)[0][0] for sid, c in votes.items()}


def stream_squares(path):
    """[(k, fx, fy, fr)] per update of a `bs` capture that names its square (tiles), in order."""
    out, seen = [], set()
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if '"fr"' not in line:
                continue
            try:
                m = json.loads(line)
            except ValueError:
                continue
            if not isinstance(m, dict) or m.get("t") != "bs" or "fr" not in m:
                continue
            k = int(m.get("k", 0))
            if k in seen:
                continue
            seen.add(k)
            out.append((k, float(m.get("fx", 0)) / 256.0, float(m.get("fy", 0)) / 256.0, float(m["fr"])))
    return out


def lane_points(truth):
    """{lane key: [(x, y) tiles of its exit, middle, entry]}."""
    out = {}
    for m in truth["lanes"]:
        key = int(m[0]) * 8 + int(m[5])
        out[key] = [(float(m[i][0]) / 256.0, float(m[i][1]) / 256.0) for i in (7, 8, 9)]
    return out


def in_bounds(pts, b):
    x0, y0, x1, y1 = b
    return any(x0 <= x <= x1 and y0 <= y <= y1 for x, y in pts)


def age_bucket(age):
    for lim, name in AGE_BUCKETS:
        if age < lim:
            return name
    return AGE_BUCKETS[-1][1]


def score_walk_tick(game, drawn, placer, names, kinds, bounds, bucket_of, tol=0.15):
    """One recorded tick, as belt_view_check.score_live_tick, with every count also by the lane's time in
    view (bucket_of: {lane key: bucket name}; a drawn record on a lane not in it: "not recorded").
    Returns (Counter of the whole, {bucket: Counter})."""
    import numpy as np
    uids, ids, x, z, shown = drawn
    x0, y0, x1, y1 = bounds
    inside = shown & (x >= x0) & (x <= x1) & (z >= y0) & (z <= y1)
    c = collections.Counter()
    by = collections.defaultdict(collections.Counter)
    cell = 1.0 / tol
    grid = collections.defaultdict(list)
    drawn_pos = {}
    drawn_lane = {}
    for i in np.nonzero(inside)[0].tolist():
        uid = int(uids[i])
        name = kinds.get(int(ids[i, 1]), "?%d" % int(ids[i, 1]))
        drawn_pos[uid] = (float(x[i]), float(z[i]))
        drawn_lane[i] = int(ids[i, 3])
        grid[(name, int(math.floor(x[i] * cell)), int(math.floor(z[i] * cell)))].append(i)
    c["drawn"] = len(drawn_pos)
    for i, key in drawn_lane.items():
        by[bucket_of.get(key, "not recorded")]["drawn"] += 1
    taken = set()
    seen = set()
    per_lane = collections.defaultdict(list)
    for uid, key, item, pos, count in game:
        name = names[item - 1] if 1 <= item <= len(names) else "#%d" % item
        gx, gy = placer[key](pos)
        if not (x0 <= gx <= x1 and y0 <= gy <= y1):
            continue
        bk = bucket_of.get(key, "not recorded")
        c["game"] += 1
        by[bk]["game"] += 1
        per_lane[key].append((pos, uid))
        d = drawn_pos.get(uid)
        if d is None:
            c["id not drawn"] += 1
        elif math.hypot(d[0] - gx, d[1] - gy) <= tol:
            c["id right"] += 1
            by[bk]["id right"] += 1
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
            c["seen"] += 1
            by[bk]["seen"] += 1
    c["phantoms"] = c["drawn"] - len(taken)
    for i, key in drawn_lane.items():
        if i not in taken:
            by[bucket_of.get(key, "not recorded")]["phantoms"] += 1
    for key, gs in per_lane.items():
        gs.sort()
        bk = bucket_of.get(key, "not recorded")
        run = 0
        for pos, uid in gs + [(None, None)]:
            if uid is not None and uid not in seen:
                run += 1
                continue
            if run >= 2:
                c["holes"] += 1
                c["hole items"] += run
                by[bk]["holes"] += 1
                by[bk]["hole items"] += run
            run = 0
    return c, by


def char_at(truth):
    """f(tick) -> (x, y) tiles: where the character was, between the recording's samples."""
    pos = sorted((int(p[0]), float(p[1]) / 256.0, float(p[2]) / 256.0) for p in truth.get("pos") or [])
    ticks = [p[0] for p in pos]

    def f(t):
        if not pos:
            return None
        i = bisect.bisect_left(ticks, t)
        if i <= 0:
            return pos[0][1:]
        if i >= len(pos):
            return pos[-1][1:]
        a, b = pos[i - 1], pos[i]
        g = (t - a[0]) / float(max(1, b[0] - a[0]))
        return a[1] + (b[1] - a[1]) * g, a[2] + (b[2] - a[2]) * g
    return f


def score_walk(truth, dump, apply_path, cam, size, kinds, at=None, squares=()):
    """The live draw against the game at every recorded sample, the bounds the client's own view at the
    job on screen (clipped to what was recorded round the character), each lane aged by its time in
    view. Returns the report's dict, or None when no sample was drawn."""
    applies = bvc.read_apply(apply_path)
    if not applies:
        return None
    rows = bvc.truth_rows(truth)
    names = truth.get("names") or []
    placer = bvc.lane_placer(truth)
    pts = lane_points(truth)
    where = char_at(truth) if truth.get("pos") else (lambda t: at)  # (no places noted: a belt_view_check run's files)
    near = truth.get("near") or [1e9, 1e9]
    dmax, run = [], -1e18
    for a in applies:
        run = max(run, a["drawn"])
        dmax.append(run)
    want = collections.defaultdict(list)
    ticks = sorted(rows)
    first_drawn = applies[0]["drawn"]
    for t in ticks:
        i = bisect.bisect_right(dmax, t) - 1
        if i < 0 or t < first_drawn or t > dmax[-1]:
            continue
        want[int(applies[i]["n"])].append(t)
    sq_ticks = [q[0] for q in squares]
    state = bvc.DrawState(bvc.lane_cells(placer, {int(m[0]) * 8 + int(m[5]): int(m[6]) for m in truth["lanes"]}))
    total = collections.Counter()
    by_age = collections.defaultdict(collections.Counter)
    per_tick = []
    hdrs = []
    entered = {}
    first_sample = True
    offsets = []
    clipped = 0
    for h, ids, recs, gone, paths in bvc.dump_frames(dump):
        hdrs.append(h)
        state.apply(ids, recs, gone, paths)
        n = int(h["n"])
        for t in want.get(n, ()):
            c = where(t)
            v = h.get("view")
            if v and c is not None:
                b = (float(v[0]), float(v[1]), float(v[0]) + float(v[2]), float(v[1]) + float(v[3]))
                offsets.append(((b[0] + b[2]) / 2 - c[0], (b[1] + b[3]) / 2 - c[1]))
            elif c is not None:
                b, _ = bvc.view_bounds(cam, c, size)
            else:
                continue
            rec_b = (c[0] - near[0], c[1] - near[1], c[0] + near[0], c[1] + near[1])
            nb = (max(b[0], rec_b[0]), max(b[1], rec_b[1]), min(b[2], rec_b[2]), min(b[3], rec_b[3]))
            if nb != b:
                clipped += 1
            b = nb
            # Lanes in view now: aged from the sample they came in on; the first sample's count as steady.
            now = {key for key, p in pts.items() if in_bounds(p, b)}
            for key in list(entered):
                if key not in now:
                    del entered[key]
            for key in now:
                if key not in entered:
                    entered[key] = -1e18 if first_sample else t
            first_sample = False
            bucket_of = {key: age_bucket(t - e) for key, e in entered.items()}
            cnt, by = score_walk_tick(rows[t], state.drawn_at(t), placer, names, kinds, b, bucket_of)
            total.update(cnt)
            for k, v in by.items():
                by_age[k].update(v)
            ages = collections.Counter(bucket_of.values())
            # The bridge's square at this tick (its last update at or before it): how far the view's
            # corners reach past it (negative: inside), so a loaded edge (`fr`) closing in shows.
            sq = None
            i = bisect.bisect_right(sq_ticks, t) - 1
            if i >= 0:
                _, fx, fy, fr = squares[i]
                over = max(abs(b[0] - fx), abs(b[2] - fx), abs(b[1] - fy), abs(b[3] - fy)) - fr
                sq = [round(fx, 1), round(fy, 1), fr, round(over, 1)]
            per_tick.append({"tick": t, "game": cnt["game"], "seen": cnt["seen"], "drawn": cnt["drawn"], "phantoms": cnt["phantoms"],
                             "holes": cnt["holes"], "lanes": len(now), "new": ages.get("under 1 s", 0), "square": sq,
                             "at": [round(c[0], 1), round(c[1], 1)], "bounds": [round(x, 1) for x in b],
                             "by_age": {k: [v["game"], v["seen"]] for k, v in by.items()}})
    if not per_tick:
        return None
    rep = {"ticks": [per_tick[0]["tick"], per_tick[-1]["tick"]], "samples": len(per_tick), "counts": dict(total),
           "by_age": {k: dict(v) for k, v in by_age.items()}, "per_tick": per_tick,
           "timing": bvc.live_timing(hdrs, applies), "clipped": clipped,
           "view_offset": [sum(o[0] for o in offsets) / len(offsets), sum(o[1] for o in offsets) / len(offsets)] if offsets else None,
           "not_scored": [t for t in ticks if t not in {p["tick"] for p in per_tick}]}
    rep["visible_pct"] = 100.0 * total["seen"] / max(1, total["game"])
    rep["phantom_pct"] = 100.0 * total["phantoms"] / max(1, total["drawn"])
    rep["id_pct"] = 100.0 * total["id right"] / max(1, total["game"])
    g = max(1, total["game"])
    rep["share_new"] = {}
    acc = 0
    for lim, name in AGE_BUCKETS[:-1]:
        acc += by_age.get(name, {}).get("game", 0)
        rep["share_new"]["within %d s" % (lim // 60)] = 100.0 * acc / g
    return rep


def format_report(rep, run, info):
    L = []
    L.append("Belt walk check at %s, route %s: %d samples, ticks %d-%d" % (
        ",".join("%.0f" % v for v in (info.get("at") or (0, 0))), info.get("route"), rep["samples"], rep["ticks"][0], rep["ticks"][1]))
    L.append("   updates' p while scored: %s; before: %s; `ld` while scored: %d" % (
        " ".join("%d x%d" % kv for kv in run["p_compared"].items()) or "-",
        " ".join("%d x%d" % kv for kv in run["p_before"].items()) or "-", run["ld_during"]))
    L.append("   bridge rate level at the recording's start and end: %s; Hold 60 UPS: %s" % (
        "%s, %s" % tuple(run["rate"]) if run.get("rate") else "?", run.get("hold60")))
    L.append("   client: %s; recorder: every %s ticks over %s x %s tiles round the character, %d rows, %d ticks in %d s (about %.0f UPS)" % (
        info.get("client"), info.get("sample"), info.get("near", ["?"])[0] * 2 if info.get("near") else "?",
        info.get("near", ["?", "?"])[1] * 2 if info.get("near") else "?", rep["samples"] + len(rep["not_scored"]),
        info.get("ticks", 0), info.get("seconds", {}).get("recording", 0), info.get("ticks", 0) / max(1.0, float(info.get("seconds", {}).get("recording", 1)))))
    if info.get("walked"):
        L.append("   the character walked %.0f tiles over x %.0f..%.0f, y %.0f..%.0f" % tuple(info["walked"]))
    if rep.get("view_offset"):
        L.append("   the client's view centre against the character at the sample's tick: %+.1f, %+.1f tiles (mean); bounds clipped to the recording %d times" % (
            rep["view_offset"][0], rep["view_offset"][1], rep["clipped"]))
    c = collections.Counter(rep["counts"])
    L.append("")
    L.append("L. Live draw while %s (the client's records when the drawn clock showed each sample, in the client's own view)" % (
        "walking" if info.get("moving") else "standing"))
    L.append("   visible %.1f%% (%d of %d item-samples, by place)   phantoms %.1f%% (%d of %d drawn)   by id %.1f%%" % (
        rep["visible_pct"], c["seen"], c["game"], rep["phantom_pct"], c["phantoms"], c["drawn"], rep["id_pct"]))
    L.append("   holes (>= 2 game items in a row unmatched): %d, %d items" % (c["holes"], c["hole items"]))
    L.append("   items on lanes that came into view within the last: %s" % "; ".join(
        "%s %.1f%%" % kv for kv in rep["share_new"].items()))
    L.append("   by the lane's time in view:   lane age        game items  visible   phantoms (of drawn)   holes")
    for _, name in AGE_BUCKETS + [(0, "not recorded")]:
        b = rep["by_age"].get(name)
        if not b:
            continue
        b = collections.Counter(b)
        L.append("                                 %-14s %10d  %5.1f%%   %5.1f%% (%d)   %d (%d items)" % (
            name, b["game"], 100.0 * b["seen"] / max(1, b["game"]), 100.0 * b["phantoms"] / max(1, b["drawn"]), b["drawn"],
            b["holes"], b["hole items"]))
    tm = rep["timing"]
    L.append("   client: %d jobs, %d with updates (%d updates, %d merged): %.1f ms a job (worst %.0f), %d records a job, other jobs %.1f ms;" % (
        tm["jobs"], tm["update_jobs"], tm["updates"], tm["merged"], tm["update_ms"][0], tm["update_ms"][1], tm["update_recs"], tm["other_ms"]))
    L.append("   skipped %d; results drawn late %d (most %.1f ticks); drawn clock behind the newest update %.1f ticks (most %.0f), margin %.1f" % (
        tm["skipped"], tm["late"], tm["late_most"], tm["behind"][0], tm["behind"][1], tm["margin"][0]))
    L.append("")
    L.append("   sample by sample (tick: visible% of game items in view, lanes in view, lanes under 1 s, character, the bridge's")
    L.append("   square: its loaded edge fr and how far the view's corners reach past it, negative inside):")
    for p in rep["per_tick"]:
        sq = p.get("square")
        L.append("     %d: %5.1f%% of %5d, drawn %5d, phantoms %4d, lanes %4d (new %3d), at %s%s" % (
            p["tick"], 100.0 * p["seen"] / max(1, p["game"]), p["game"], p["drawn"], p["phantoms"], p["lanes"], p["new"], p["at"],
            ", fr %.0f (view past it %+.0f)" % (sq[2], sq[3]) if sq else ""))
    return "\n".join(L)


# ---------------------------------------------------------------- the images

COLOURS = {
    "copper-plate": (255, 140, 60), "iron-plate": (170, 200, 255), "steel-plate": (120, 150, 190),
    "iron-gear-wheel": (190, 190, 190), "electronic-circuit": (80, 230, 80), "plastic-bar": (250, 250, 250),
    "low-density-structure": (240, 240, 120), "stone-brick": (200, 160, 120), "transport-belt": (240, 220, 40),
    "inserter": (240, 220, 40), "logistic-science-pack": (255, 60, 200), "copper-cable": (255, 90, 90),
    "engine-unit": (200, 120, 200),
}


def side_images(keep, truth, rep, shots, t_end, secs, name):
    """For each screenshot taken while the recording ran: the client's picture on top, the game's items at
    the nearest sample as dots over the sample's bounds below, and a 2x crop of the middle band."""
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        return []
    rows = bvc.truth_rows(truth)
    placer = bvc.lane_placer(truth)
    pts = lane_points(truth)
    names = truth.get("names") or []
    by_tick = {p["tick"]: p for p in rep["per_tick"]}
    ticks = sorted(by_tick)
    if not ticks:
        return []
    ups = (ticks[-1] - ticks[0]) / max(1.0, float(secs))
    made = []
    for shot in shots:
        shot = pathlib.Path(shot)
        back = t_end - shot.stat().st_mtime
        want = ticks[-1] - back * ups
        tick = min(ticks, key=lambda k: abs(k - want))
        if abs(tick - want) > 120:
            continue
        p = by_tick[tick]
        B = p["bounds"]
        img = Image.open(shot).convert("RGB")
        W, H = img.size
        SX, SY = W / max(1e-6, B[2] - B[0]), H / max(1e-6, B[3] - B[1])

        def to_px(x, y):
            return (x - B[0]) * SX, (y - B[1]) * SY
        dots = Image.new("RGB", (W, H), (18, 18, 22))
        d = ImageDraw.Draw(dots)
        for key, pp in pts.items():
            if in_bounds(pp, B):
                d.line([to_px(*pp[0]), to_px(*pp[1]), to_px(*pp[2])], fill=(45, 45, 55), width=3)
        for uid, key, item, pos, count in rows[tick]:
            x, y = placer[key](pos)
            px, py = to_px(x, y)
            col = COLOURS.get(names[item - 1] if 1 <= item <= len(names) else "", (255, 255, 255))
            d.ellipse([px - 1.6, py - 1.6, px + 1.6, py + 1.6], fill=col)
        d.text((8, 8), "%s: game tick %d (%s, about %.0f UPS); visible %.0f%%, lanes %d (%d new)" % (
            name, tick, shot.name, ups, 100.0 * p["seen"] / max(1, p["game"]), p["lanes"], p["new"]), fill=(230, 230, 230))
        side = Image.new("RGB", (W, 2 * H + 4))
        side.paste(img, (0, 0))
        side.paste(dots, (0, H + 4))
        n = shot.stem.split("_")[-1]
        out = keep / ("side_walk_%s_%d.png" % (n, tick))
        side.save(out)
        crop = (W * 3 // 16, H * 5 // 18, W * 13 // 16, H * 13 // 18)
        c1, c2 = img.crop(crop), dots.crop(crop)
        c1 = c1.resize((c1.width * 2, c1.height * 2), Image.NEAREST)
        c2 = c2.resize((c2.width * 2, c2.height * 2), Image.NEAREST)
        cs = Image.new("RGB", (c1.width, 2 * c1.height + 4))
        cs.paste(c1, (0, 0))
        cs.paste(c2, (0, c1.height + 4))
        cs.save(keep / ("side_walk_%s_%d_crop.png" % (n, tick)))
        made.append(str(out))
    return made


# ---------------------------------------------------------------- the live run

def record_walk(wt, ports, area, ticks, every, phase, hw, hh, out):
    """The recording (above): starts it and waits for the game to finish it."""
    pw = (pathlib.Path(wt) / "server" / "data" / "rcon-password.txt").read_text().strip()
    script_out = pathlib.Path(wt) / "server" / "data" / "script-output"
    name = "belt_walk_%d.json" % int(time.time() * 1000)
    path = script_out / name
    done = script_out / (name + ".done")
    x0, y0, x1, y1 = area
    print(rcon.run("/sc __factorio-3d-bridge__ " + one_line(REMOTE % {"puppet": bvc.PUPPET}), port=ports[2], password=pw, timeout=30).strip(), flush=True)
    lua = LUA % dict(x0=x0, y0=y0, x1=x1, y1=y1, ticks=ticks, file=name, surface="nauvis", every=every, phase=phase,
                     hw=hw, hh=hh, sample="%d@%d" % (every, phase))
    try:
        print(rcon.run("/sc " + one_line(lua), port=ports[2], password=pw, timeout=120).strip(), flush=True)
        deadline = time.time() + ticks / 60.0 * 20 + 120
        while time.time() < deadline:
            if done.exists():
                time.sleep(0.5)
                rows = int(done.read_text().strip() or 0)
                out.unlink(missing_ok=True)
                shutil.move(str(path), str(out))
                done.unlink()
                return rows
            time.sleep(0.5)
        raise SystemExit("no recording from the game")
    finally:
        try:
            rcon.run("/sc __factorio-3d-bridge__ " + REMOTE_OFF, port=ports[2], password=pw, timeout=10)
        except OSError:
            pass


def live(a, wt, ports, out, lock):
    wt = pathlib.Path(wt)
    godot = bvc.godot_exe(a.godot)
    save_src = pathlib.Path(a.save) if a.save else wt / "server" / "saves" / "zt.zip"
    save = wt / "server" / "saves" / "walkcheck.zip"
    save.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(save_src, save)
    bvc.sync_mod(wt)
    cfg = out / "settings.cfg"
    bvc.settings_file(cfg, "automatic", a.hold60)
    stream, truth, dump, probe = out / "stream.jsonl", out / "truth.json", out / "draw.bin", out / "probe.json"
    for f in (stream, truth, dump, probe, pathlib.Path(str(dump) + ".apply.jsonl")):
        f.unlink(missing_ok=True)
    cam = bvc.camera_arg("top", a.size)
    routes = probe_routes(wt)
    legs = routes.get(a.route)
    if legs is None:
        raise SystemExit("no route %r in stutter_probe.gd (have %s)" % (a.route, ", ".join(sorted(routes))))
    reach, route_secs = route_reach(legs, a.speed)
    moving = moving_route(legs)
    (vb0, vb1, vb2, vb3), _ = bvc.view_bounds(cam, (0.0, 0.0), a.size)
    hw, hh = (vb2 - vb0) / 2 + a.margin, (vb3 - vb1) / 2 + a.margin
    at = a.at
    area = (at[0] + reach[0] - hw - 4, at[1] + reach[1] - hh - 4, at[0] + reach[2] + hw + 4, at[1] + reach[3] + hh + 4)
    seconds = a.seconds if a.seconds > 0 else max(10.0, route_secs - 4.0)
    ticks = int(seconds * a.ups_guess)
    warm = a.settle + a.warm_extra
    info = {"client": "Zenith, windowed (Belt updates automatic; time of day held at 0; stutter probe route %s, warm-up %d s)" % (a.route, warm),
            "hold60": a.hold60, "camera": cam, "route": a.route, "legs": legs, "moving": moving, "sample": a.sample,
            "near": [hw, hh], "area": list(area), "ticks": ticks, "size": a.size, "server": "started", "speed_guess": a.speed}
    if a.bs:
        info["client"] += "; bridge /f3d-bs " + ", ".join(a.bs)
    client = server = None
    t_start = time.time()
    t_rec = t_end = time.time()
    shot_times = list(range(20, int(warm + seconds * 1.6 + 60), a.shots_every))
    lock.acquire()
    t_locked = time.time()
    try:
        server = bvc.start_server(wt, save, ports, out)
        print("server started in %.0f s" % (time.time() - t_locked), flush=True)
        for opt in a.bs:
            name, _, value = opt.partition("=")
            print(bvc.rc_quiet(wt, ports[2], "/f3d-bs %s %s" % (name.strip(), value.strip() or "default")).strip(), flush=True)
        info["bs"] = list(a.bs)
        bvc.teleport(wt, ports[2], at)
        t_client = time.time()
        args = [godot, "--path", str(wt / "client"), "--", "--factorio-port=%d" % ports[0], "--port=%d" % a.client_port,
                "--settings-file=%s" % cfg, "--camera=%s" % cam, "--sky=@0", "--belt-capture=%s" % stream,
                "--belt-draw-dump=%s" % dump, "--stutter-probe=%s@%s" % (probe, a.route), "--probe-warmup=%d" % warm]
        args.extend(a.client_arg)
        for t in shot_times:
            args.append("--screenshot=%s@%d" % (out / ("shot_%03d.png" % t), t))
        (out / "cmd.txt").write_text(" ".join(args))
        client = subprocess.Popen(args, cwd=str(wt), stdout=open(out / "client.out", "w"), stderr=subprocess.STDOUT)
        while True:
            time.sleep(1)
            if client.poll() is not None:
                raise SystemExit("FAIL: the client stopped: see %s" % (out / "client.out"))
            if bvc.first_bs(stream):
                break
            if time.time() - t_client > a.first_bs:
                raise SystemExit("FAIL: no `bs` update captured in %d s" % a.first_bs)
        bvc.teleport(wt, ports[2], at)
        at = bvc.puppet_at(wt, ports[2]) or at
        info["at"] = list(at)
        print("joined after %.0f s; character at %s; settling at least %d s (the probe walks after %d s)" % (
            time.time() - t_client, at, a.settle, warm), flush=True)
        t_settle = time.time()
        while True:
            gone = time.time() - t_settle
            loading = bvc.stream_loading(stream)
            if gone >= a.settle and loading is False:
                break
            if gone >= a.settle_max:
                raise SystemExit("FAIL: first load didn't finish in %d s" % a.settle_max)
            if client.poll() is not None:
                raise SystemExit("FAIL: the client stopped: see %s" % (out / "client.out"))
            time.sleep(1)
        print("settled after %.0f s" % (time.time() - t_settle), flush=True)
        (out / "status.txt").write_text(bvc.rc_quiet(wt, ports[2], "/f3d-status"))
        # The recording starts as the character sets off (a standing route: when the warm-up is over).
        t_go = time.time()
        while True:
            if client.poll() is not None:
                raise SystemExit("FAIL: the client stopped before walking: see %s" % (out / "client.out"))
            if moving:
                p = bvc.puppet_at(wt, ports[2])
                if p and math.hypot(p[0] - at[0], p[1] - at[1]) >= 1.5:
                    break
            elif time.time() - t_client >= warm + 10:
                break
            if time.time() - t_go > warm + 60:
                raise SystemExit("FAIL: the character didn't set off within %d s of settling" % (warm + 60))
            time.sleep(0.25)
        print("%s after %.0f s; recording %d ticks" % ("walking" if moving else "standing", time.time() - t_settle, ticks), flush=True)
        t_rec = time.time()
        rows = record_walk(wt, ports, area, ticks, a.sample, 1, hw, hh, truth)
        t_end = time.time()
        print("recorded %d rows in %.0f s" % (rows, t_end - t_rec), flush=True)
        with open(out / "status.txt", "a") as f:
            f.write(bvc.rc_quiet(wt, ports[2], "/f3d-status"))
        # The probe quits the client itself at the route's end; wait for that a while (its summary).
        t_wait = time.time()
        while client.poll() is None and time.time() - t_wait < a.tail_wait:
            time.sleep(1)
        info["client_quit"] = client.poll() is not None
    finally:
        if client is not None:
            bvc.kill_tree(client.pid)
        bvc.stop_server(wt)
        if server is not None:
            bvc.kill_tree(server.pid)
        for _ in range(30):
            try:
                save.unlink(missing_ok=True)
                break
            except PermissionError:
                time.sleep(1)
        lock.release()
    kept = []
    for t in shot_times:
        f = out / ("shot_%03d.png" % t)
        if not f.exists():
            continue
        if t_rec - 3 <= f.stat().st_mtime <= t_end + 1:
            kept.append(str(f))
        else:
            f.unlink()
    info["shots"] = kept
    info["seconds"] = {"live": round(time.time() - t_start), "lock": round(time.time() - t_locked), "recording": round(t_end - t_rec)}
    info["t_end"] = t_end
    (out / "run.json").write_text(json.dumps(info))
    print("done in %.0f s, %d screenshots" % (time.time() - t_start, len(kept)), flush=True)
    return info


def analyze(out, info, a):
    truth = json.loads((out / "truth.json").read_text())
    stream = out / "stream.jsonl"
    dump = out / "draw.bin"
    kinds = kinds_from_stream(stream, truth)
    rep = score_walk(truth, dump, pathlib.Path(str(dump) + ".apply.jsonl"), info.get("camera"), float(info.get("size") or a.size), kinds,
                     tuple(info.get("at") or a.at), stream_squares(stream))
    if rep is None:
        raise SystemExit("no recorded sample was drawn by the client (%s)" % dump)
    run = bvc.run_info(stream, out / "status.txt", out / "settings.cfg", tuple(rep["ticks"]))
    pos = truth.get("pos") or []
    if pos:
        xs = [float(p[1]) / 256.0 for p in pos]
        ys = [float(p[2]) / 256.0 for p in pos]
        walked = sum(math.hypot(xs[i + 1] - xs[i], ys[i + 1] - ys[i]) for i in range(len(xs) - 1))
        info["walked"] = [walked, min(xs), max(xs), min(ys), max(ys)]
    text = format_report(rep, run, info)
    images = side_images(out, truth, rep, info.get("shots") or [], info.get("t_end") or (out / "truth.json").stat().st_mtime,
                         info.get("seconds", {}).get("recording", 1), out.name)
    rep["images"] = images
    rep["run"] = run
    rep["info"] = info
    return rep, text


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--worktree", default=str(ROOT))
    ap.add_argument("--ports", default="35400,35401,35402")
    ap.add_argument("--client-port", type=int, default=0)
    ap.add_argument("--at", default="-62,-26")
    ap.add_argument("--size", type=float, default=60)
    ap.add_argument("--route", default="fast", help="the stutter probe's route (stutter_probe.gd ROUTES): fast, stand75, ...")
    ap.add_argument("--speed", type=float, default=30.0, help="tiles a second the character is expected to walk (sizes the recorded area)")
    ap.add_argument("--ups-guess", type=float, default=50.0, help="game ticks a second expected (sizes the recording in ticks)")
    ap.add_argument("--seconds", type=float, default=0, help="seconds of route to record (default: the route's length less 4)")
    ap.add_argument("--sample", type=int, default=30, help="ticks between samples of the game's belts")
    ap.add_argument("--margin", type=float, default=24.0, help="tiles read round the view at each sample")
    ap.add_argument("--settle", type=float, default=60)
    ap.add_argument("--settle-max", type=float, default=180)
    ap.add_argument("--warm-extra", type=float, default=25, help="the probe's warm-up is --settle plus this (seconds after the world is ready)")
    ap.add_argument("--first-bs", type=float, default=60)
    ap.add_argument("--hold60", choices=["off", "on"], default="on")
    ap.add_argument("--save", default="")
    ap.add_argument("--shots-every", type=int, default=5)
    ap.add_argument("--tail-wait", type=float, default=40)
    ap.add_argument("--client-arg", action="append", default=[])
    ap.add_argument("--bs", action="append", default=[], help="a bridge switch set once the server is up: name=value (/f3d-bs name value)")
    ap.add_argument("--godot", default="")
    ap.add_argument("--lock", default="")
    ap.add_argument("--keep", default="")
    ap.add_argument("--json", default="")
    ap.add_argument("--analyze", action="store_true", help="score the files in --keep again, no live run")
    a = ap.parse_args()
    ports = [int(p) for p in a.ports.split(",")]
    a.client_port = a.client_port or ports[0] + 3
    a.at = tuple(float(v) for v in a.at.split(","))
    out = pathlib.Path(a.keep) if a.keep else pathlib.Path(__file__).resolve().parent / ("walk_check_%d" % int(time.time()))
    out.mkdir(parents=True, exist_ok=True)
    if a.analyze:
        info = json.loads((out / "run.json").read_text()) if (out / "run.json").exists() else {"camera": bvc.camera_arg("top", a.size), "size": a.size}
    else:
        lock = bvc.Lock(a.lock, "belt_walk_check %s" % a.worktree)
        try:
            info = live(a, a.worktree, ports, out, lock)
        finally:
            lock.release()
    rep, text = analyze(out, info, a)
    print(text)
    for im in rep["images"]:
        print("image: %s" % im)
    (out / "report.txt").write_text(text + "\n" + "\n".join("image: %s" % im for im in rep["images"]) + "\n", encoding="utf-8")
    if a.json:
        pathlib.Path(a.json).write_text(json.dumps(rep, indent=1, default=lambda o: dict(o) if isinstance(o, collections.Counter) else str(o)))


if __name__ == "__main__":
    main()
