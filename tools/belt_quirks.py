"""belt_quirks.py <run dir> [--json out] [--belt-distance 128]: the belt quirks a live run's files show, offline, from
the client's draw dump (draw.bin + .apply.jsonl, placed as the shader places them when the drawn clock showed
each tick: tools/belt_view_check.py's DrawState) against the game's recording (truth.json), inside the
client's own view (the dump's job view) and the recording's lanes. Each quirk in item-seconds (an item of
the game, or a drawn one, affected for a second) or events:

  frozen        lattice lanes not sliding (< 0.05 tile) while the game's items there moved >= 0.25 tile in
                the interval; simulated items drawn still (< 0.05) while the game moved them >= 0.25
  sliding       lattice lanes sliding > 0.25 tile in an interval while the game's items there stood (< 2% of
                the belt's speed); simulated items drawn moving > 0.25 tile while the game's stood
  missing       game items with no drawn item of their kind within 0.15 tile (belt_view_check's "visible"),
                split: on a lane drawn at all / on a lane with nothing drawn near any of its game items
                ("undrawn": by distance from the view's middle, under and over --belt-distance)
  phantom       drawn items with no game item matched (belt_view_check's phantoms)
  off belt      drawn items farther than 0.3 tile from every recorded lane's centre line
  wrong lane    game items drawn (by id) on the other lane of their belt
  jumps         at a job's apply, a simulated item's drawn place moving > 0.5 tile at once (events)
  lattice hops  a lattice lane rewritten with its slots shifted > 0.06 tile (events, slots)
  flicker       an item's record gone while drawn on screen (in view, not under the lattice's mask) and back
                within 60 ticks (events)

A replay's dump (tests/belt_bs_replay.gd --belt-draw-dump, no .apply.jsonl) works too, each job drawn at its fold
tick, with the recording as truth.json beside it (tools/belt_line_end.py's rec.json).

With the client's --belt-lanes-dump=lanes.jsonl beside draw.bin: the view scored above is cut to the square the
client simulated (the lane icons' near edge), and the gaps by distance are added: the game's items in the
camera's whole ground view, by band of tiles from the character, on a lane drawn with items, with lane icons,
or neither (and how many of those lay outside the job's own view).
"""
import argparse, bisect, collections, json, math, os, pathlib, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import belt_view_check as bvc  # noqa: E402
import numpy as np  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("run")
ap.add_argument("--json")
ap.add_argument("--belt-distance", type=float, default=128.0)
ap.add_argument("--every", type=int, default=1, help="score every Nth recorded sample")
a = ap.parse_args()
d = pathlib.Path(a.run)
truth = json.load(open(d / "truth.json"))
rows = bvc.truth_rows(truth)
names = truth.get("names") or []
placer = bvc.lane_placer(truth)
meta = {int(m[0]) * 8 + int(m[5]): m for m in truth["lanes"]}
SPEED = {"transport": 1.875, "fast": 3.75, "express": 5.625, "turbo": 7.5}


def tier_speed(k):
    m = meta.get(k)
    return SPEED.get(m[1].split("-")[0] if m else "transport", 1.875)


# Item kinds the dump names by id: as belt_view_check's (its own kinds map from the stream).
try:
    import belt_walk_check as bwc  # noqa: E402
    kinds = bwc.kinds_from_stream(d / "stream.jsonl", truth)
except Exception:  # noqa: BLE001
    kinds = {}
if not kinds:
    # Without the stream no drawn item has a kind, so every game item reads missing and every drawn one a phantom.
    print("warning: no item kinds from %s (copy the scene's stream.jsonl beside draw.bin): missing and phantom "
          "will read about 100%%" % (d / "stream.jsonl"), file=sys.stderr)
# Lane centre lines, sampled every 1/16 tile, in 0.25-tile cells (off belt, wrong lane).
CELL = 0.25
line_pts = collections.defaultdict(list)
for k, m in meta.items():
    L = max(1, int(m[6]))
    for j in range(0, L + 1, 16):
        x, y = placer[k](j)
        line_pts[(math.floor(x / CELL), math.floor(y / CELL))].append((x, y, k))
xs = [p[0] for v in line_pts.values() for p in v]
ys = [p[1] for v in line_pts.values() for p in v]
lanes_box = (min(xs), min(ys), max(xs), max(ys))


def near_line(x, y, r=0.3):
    """The lane keys whose centre line passes within r of (x, y), nearest first."""
    cx, cy = math.floor(x / CELL), math.floor(y / CELL)
    best = {}
    for dx in (-2, -1, 0, 1, 2):
        for dy in (-2, -1, 0, 1, 2):
            for px, py, k in line_pts.get((cx + dx, cy + dy), ()):
                dd = math.hypot(px - x, py - y)
                if dd <= r and dd < best.get(k, 9):
                    best[k] = dd
    return sorted(best, key=best.get)


def sibling(k):
    return k + 1 if k % 2 == 1 else k - 1


if (d / "draw.bin.apply.jsonl").exists():
    applies = bvc.read_apply(d / "draw.bin.apply.jsonl")
else:
    # (A replay's dump, tests/belt_bs_replay.gd --every-tick: no apply lines; each job drawn at its fold tick,
    # as tools/belt_jumps.py takes them.)
    applies = [{"n": int(h["n"]), "usec": int(h["n"]), "drawn": float(h.get("fold", -1))}
               for h, *_ in bvc.dump_frames(d / "draw.bin") if float(h.get("fold", -1)) >= 0]
apply_at = {int(x["n"]): float(x["drawn"]) for x in applies}
apply_u = {int(x["n"]): int(x["usec"]) for x in applies}
samples_u = {}
dmax, run = [], -1e18
for x in applies:
    run = max(run, x["drawn"])
    dmax.append(run)
want = collections.defaultdict(list)
all_ticks = sorted(rows)[::a.every]
for t in all_ticks:
    i = bisect.bisect_right(dmax, t) - 1
    if i < 0 or t < applies[0]["drawn"] or t > dmax[-1]:
        continue
    want[int(applies[i]["n"])].append(t)
cells = bvc.lane_cells(placer, {k: int(m[6]) for k, m in meta.items()})
state = bvc.DrawState(cells)
lat_ev = collections.defaultdict(list)
samples = {}
views = {}
ev = collections.Counter()
ev_where = collections.defaultdict(list)
gone_at = {}  # uid -> drawn tick its record went
jumps_at = collections.Counter()  # apply's drawn tick -> jumps there
FLICK = 60


def in_view(b, x, y, m=0.5):
    return b is None or (b[0] + m <= x <= b[2] - m and b[1] + m <= y <= b[3] - m)


def positions(st, uids_wanted, t):
    """{uid: (x, z)} where the records draw the given items at t (shown ones; the lattice's mask applied)."""
    sub = bvc.DrawState(None)
    sub.items = {u: st.items[u] for u in uids_wanted if u in st.items}
    sub.paths = st.paths
    if not sub.items:
        return {}
    uu, ii, x, z, shown = sub.drawn_at(t)
    return {int(uu[j]): (float(x[j]), float(z[j])) for j in np.nonzero(shown)[0].tolist()}


cur_view = None
T0, T1 = min(all_ticks), max(all_ticks)
masked = set()


def unmasked(p):
    return (math.floor(p[0] * bvc.MASK_CELLS), math.floor(p[1] * bvc.MASK_CELLS)) not in masked


for h, ids, recs, gone, paths in bvc.dump_frames(d / "draw.bin"):
    n = int(h["n"])
    if apply_at.get(n) is not None and T0 <= apply_at[n] <= T1:
        lk = {int(vv[0][3]) for vv in state.items.values() if vv[1][14] > 0.5 and vv[1][13] < 0.5}
        lmv = {int(vv[0][3]) for vv in state.items.values() if vv[1][14] > 0.5 and vv[1][13] < 0.5 and vv[0][6] > 0}
        lop = {int(vv[0][3]): int(vv[0][7]) for vv in state.items.values() if vv[1][14] > 0.5 and vv[1][13] < 0.5}
        masked = set()
        for k in lk:
            masked |= cells(k, k in lmv, lop.get(k, 0))  # (belt_view_check.lane_cells; its open ends, mask_open)
    v = h.get("view")
    if v:
        cur_view = (float(v[0]), float(v[1]), float(v[0]) + float(v[2]), float(v[1]) + float(v[3]))
    at = apply_at.get(n)
    lat_rows = None
    if ids is not None:
        lat_rows = (recs[:, 13] < 0.5) & (recs[:, 14] > 0.5)
    # Jumps: the job's simulated items already drawn, before and after, at the apply's drawn tick.
    inwin = at is not None and T0 <= at <= T1
    if inwin and ids is not None and (~lat_rows).any():
        upd = [int(u) for u in ids[~lat_rows, 0].tolist() if int(u) in state.items]
        if upd:
            before = positions(state, upd, at)
    else:
        upd = []
    # Lattice hops: the job's lattice lanes' slots before (old records) and after.
    hop_keys = []
    if inwin and ids is not None and lat_rows.any():
        hop_keys = sorted(set(int(k) for k in ids[lat_rows, 3].tolist()))
        old_slots = collections.defaultdict(list)
        lat_uids = [u for u, vv in state.items.items() if vv[1][14] > 0.5 and vv[1][13] < 0.5 and int(vv[0][3]) in set(hop_keys)]
        for u, p in positions(state, lat_uids, at).items():
            old_slots[int(state.items[u][0][3])].append(p)
    if gone is not None and inwin:
        went = [int(u) for u in gone.tolist() if u in state.items and not (state.items[u][1][14] > 0.5)]
        # (Where each was drawn as it went: a record that goes off screen, or under the lattice's mask, and comes
        # back isn't seen to flicker; a park, dumped as a going, comes back where the view brings it.)
        was = positions(state, went, at) if went else {}
        for u in went:
            q = was.get(u)
            if q is not None and in_view(cur_view, *q) and unmasked(q):
                gone_at[u] = at
            else:
                gone_at.pop(u, None)
    state.apply(ids, recs, gone, paths)
    if inwin and ids is not None:
        for u in ids[~lat_rows, 0].tolist():
            g = gone_at.pop(int(u), None)
            if g is not None and at - g <= FLICK:
                p = positions(state, [int(u)], at).get(int(u))
                if p is not None and in_view(cur_view, *p) and unmasked(p):
                    ev["flicker"] += 1
    if upd:
        after = positions(state, upd, at)
        for u, p in after.items():
            q = before.get(u)
            if q is not None and in_view(cur_view, *p) and unmasked(p) and unmasked(q) and math.hypot(p[0] - q[0], p[1] - q[1]) > 0.5:
                ev["jumps"] += 1
                jumps_at[round(at)] += 1
                if len(ev_where["jumps"]) < 40000:
                    ev_where["jumps"].append((at, u, round(q[0], 2), round(q[1], 2), round(p[0], 2), round(p[1], 2), int(state.items[u][0][3])))
    if hop_keys:
        new_slots = collections.defaultdict(list)
        lat_uids = [int(u) for u in ids[lat_rows, 0].tolist()]
        for u, p in positions(state, lat_uids, at).items():
            new_slots[int(state.items[u][0][3])].append(p)
        for k in hop_keys:
            o, nn = old_slots.get(k), new_slots.get(k)
            if not o or not nn or not in_view(cur_view, *nn[0]):
                continue
            dists = sorted(min(math.hypot(p[0] - q[0], p[1] - q[1]) for q in o) for p in nn)
            if dists[len(dists) // 2] > 0.06:
                ev["lattice hops"] += 1
                ev["lattice hop slots"] += len(nn)
    if ids is not None and lat_rows.any() and at is not None:
        seen_k = {}
        for j in np.nonzero(lat_rows)[0].tolist():
            seen_k.setdefault(int(ids[j, 3]), float(recs[j, 15]))
        for k, per in seen_k.items():
            lat_ev[k].append((at, 64.0 / per if per > 0 else 0.0))
    for t in want.get(n, ()):
        samples_u[t] = apply_u.get(n)
        uu, ii, x, z, shown = state.drawn_at(t)
        r = np.stack([vv[1] for vv in state.items.values()]) if state.items else np.zeros((0, 16))
        lat = (r[:, 13] < 0.5) & (r[:, 14] > 0.5) if len(r) else np.zeros(0, bool)
        dr = {int(uu[j]): (float(x[j]), float(z[j]), int(ii[j, 3])) for j in np.nonzero(shown & ~lat)[0].tolist()}
        slots = [(float(x[j]), float(z[j]), int(ii[j, 3]), int(ii[j, 1])) for j in np.nonzero(shown & lat)[0].tolist()]
        lanes = set(int(k) for k in ii[lat, 3].tolist())
        samples[t] = (dr, slots, lanes, (uu, ii, x, z, shown), lat)
        views[t] = cur_view
ticks = sorted(samples)
dt = (ticks[1] - ticks[0]) / 60.0 if len(ticks) > 1 else 1.0
print("samples %d (%d..%d) every %.2f s; dump events: %s" % (len(ticks), ticks[0], ticks[-1], dt, dict(ev)))


def slide(k, ta, tb):
    tot = 0.0
    e = lat_ev.get(k, [])
    for i, (t0, sp) in enumerate(e):
        t1 = e[i + 1][0] if i + 1 < len(e) else 1e18
        lo, hi = max(t0, ta), min(t1, tb)
        if hi > lo:
            tot += sp * (hi - lo)
    return tot / 256.0


# The square the client's items were simulated in at each sample (lanes.jsonl's icon square: its centre and
# near edge, the bs fr), when the client wrote one: the view the quirks are scored in is cut to it, since
# items past it are the lane icons' or nobody's (the gaps by distance below).
sq_at = {}
if (d / "lanes.jsonl").exists() and samples_u:
    pe = []
    with open(d / "lanes.jsonl", encoding="utf-8", errors="replace") as f:
        for line in f:
            if '"p"' in line:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                pe.append((e.get("u", 0), e["p"]))
    pe.sort(key=lambda v: v[0])
    pu = [v[0] for v in pe]
    for t in ticks:
        u = samples_u.get(t)
        i = bisect.bisect_right(pu, u) - 1 if u is not None else -1
        if i >= 0 and pe[i][1][2] > 0:
            cx, cy, near = pe[i][1][0], pe[i][1][1], pe[i][1][2]
            sq_at[t] = (cx - near, cy - near, cx + near, cy + near)
Q = collections.Counter()  # quirk -> item-seconds
Qn = collections.Counter()
Qs = collections.Counter()  # (split) "lattice lanes: missing", ... -> item-seconds
area = None
try:
    rj = json.load(open(d / "run.json"))
    area = rj.get("area")
except OSError:
    pass
gx_all = 0.0
views_scored = {}
# (The recorded lanes' box grown by the frozen and sliding checks' edge margin, half a tile: the lanes' own box,
# their centre lines', is no wider than a line, so on a scene of one straight run, as tools/belt_line_end.py's,
# nothing was ever inside it by half a tile and those checks counted nothing.)
box_m = (lanes_box[0] - 0.5, lanes_box[1] - 0.5, lanes_box[2] + 0.5, lanes_box[3] + 0.5)
for t in ticks:
    b = views[t]
    if b is not None:
        b = (max(b[0], box_m[0]), max(b[1], box_m[1]), min(b[2], box_m[2]), min(b[3], box_m[3]))
    else:
        b = box_m  # (no camera: a replay's job sees everything)
    if area:
        b = (max(b[0], area[0]), max(b[1], area[1]), min(b[2], area[2]), min(b[3], area[3]))
    if t in sq_at:
        q = sq_at[t]
        b = (max(b[0], q[0]), max(b[1], q[1]), min(b[2], q[2]), min(b[3], q[3]))
    views_scored[t] = b
    dr, slots, lanes, drawn, lat_rows_t = samples[t]
    # (Only the game's items inside the view: score_live_tick's holes count every recorded lane's runs,
    # those past the view's edge too, which a recording wider than the job's view made most of them.)
    in_rows = [r for r in rows[t] if in_view(b, *placer[r[1]](r[3]), 0)]
    c, _ = bvc.score_live_tick(in_rows, drawn, placer, names, kinds, b)
    Q["game items (in view)"] += (c["game"] - c["game outside"]) * dt
    Q["missing"] += (c["game"] - c["game outside"] - (c["seen"] - c["seen outside"])) * dt
    Q["phantom"] += c["phantoms"] * dt
    Q["holes (2+ missing in a row)"] += c["hole items"] * dt
    # Split: the lattice's lanes (their game items against its slots) and the rest (against item records),
    # so a lattice's quirks (another agent's: belt_lattice.gd) show apart from the simulation's own.
    if len(lat_rows_t) == len(drawn[4]):
        uu_, ii_, x_, z_, sh_ = drawn
        for part, rws, msk in (("lattice lanes", [r for r in in_rows if r[1] in lanes], sh_ & lat_rows_t),
                               ("item lanes", [r for r in in_rows if r[1] not in lanes], sh_ & ~lat_rows_t)):
            cp, _ = bvc.score_live_tick(rws, (uu_, ii_, x_, z_, msk), placer, names, kinds, b)
            Qs[part + ": game"] += (cp["game"] - cp["game outside"]) * dt
            Qs[part + ": missing"] += (cp["game"] - cp["game outside"] - (cp["seen"] - cp["seen outside"])) * dt
            Qs[part + ": phantom"] += cp["phantoms"] * dt
            Qs[part + ": holes"] += cp["hole items"] * dt
    # Undrawn lanes: game items on a lane none of whose game items has a drawn thing within 0.4 tile.
    uu, ii, x, z, shown = drawn
    inside = shown & (x >= b[0]) & (x <= b[2]) & (z >= b[1]) & (z <= b[3])
    grid = collections.defaultdict(list)
    for j in np.nonzero(inside)[0].tolist():
        grid[(math.floor(x[j] / 0.5), math.floor(z[j] / 0.5))].append((x[j], z[j]))
    per_lane = collections.defaultdict(list)
    for uid, key, item, pos, cnt in rows[t]:
        gx, gy = placer[key](pos)
        if in_view(b, gx, gy, 0):
            per_lane[key].append((gx, gy))
    cx, cy = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
    for key, pts in per_lane.items():
        hit = False
        for gx, gy in pts:
            for ddx in (-1, 0, 1):
                for ddy in (-1, 0, 1):
                    for px, pz in grid.get((math.floor(gx / 0.5) + ddx, math.floor(gy / 0.5) + ddy), ()):
                        if math.hypot(px - gx, pz - gy) <= 0.4:
                            hit = True
                            break
                    if hit:
                        break
                if hit:
                    break
            if hit:
                break
        if not hit:
            far = max(abs(pts[0][0] - cx), abs(pts[0][1] - cy)) > a.belt_distance
            Q["undrawn lanes' items (%s belt distance)" % ("past" if far else "within")] += len(pts) * dt
    # Off belt: drawn things in view farther than 0.3 tile from every recorded lane.
    off = 0
    for j in np.nonzero(inside)[0].tolist():
        if not near_line(float(x[j]), float(z[j]), 0.3):
            off += 1
    Q["off belt"] += off * dt
    # Wrong lane: game items drawn by id near their belt's other lane, not their own.
    for uid, key, item, pos, cnt in rows[t]:
        p = dr.get(uid)
        if p is None:
            continue
        gx, gy = placer[key](pos)
        if not in_view(b, gx, gy, 0) or math.hypot(p[0] - gx, p[1] - gy) <= 0.15:
            continue
        nl = near_line(p[0], p[1], 0.12)
        if nl and nl[0] == sibling(key) and key not in nl[:1]:
            Q["wrong lane"] += dt
# Frozen and sliding: intervals between samples, lanes drawn as a lattice at both ends, items by id.
run_of = {}  # lattice lane -> seconds frozen in a row so far
spans = collections.Counter()  # frozen lattice spans: >= 2, 5, 8 s


def close_span(k):
    sec = run_of.pop(k, 0.0)
    for lim in (2, 5, 8):
        if sec >= lim:
            spans[lim] += 1


for ta, tb in zip(ticks, ticks[1:]):
    ga = {u: (k, p) for u, k, it, p, c in rows[ta]}
    gb = {u: (k, p) for u, k, it, p, c in rows[tb]}
    da, db = samples[ta][0], samples[tb][0]
    la, lb = samples[ta][2], samples[tb][2]
    ba, bb = views_scored.get(ta, views[ta]), views_scored.get(tb, views[tb])
    flow = collections.defaultdict(list)
    for u, (ka, pa) in ga.items():
        if u not in gb:
            continue
        kb, pb = gb[u]
        xa, ya = placer[ka](pa)
        xb, yb = placer[kb](pb)
        if not (in_view(ba, xa, ya) and in_view(bb, xb, yb)):
            continue
        dg = math.hypot(xb - xa, yb - ya)
        if ka in la and ka in lb:
            flow[ka].append(dg)
            continue
        if u in da and u in db:
            dd = math.hypot(db[u][0] - da[u][0], db[u][1] - da[u][1])
            sp = tier_speed(ka) * (tb - ta) / 60.0
            if dg >= 0.25 and dd < 0.05:
                Q["frozen (items)"] += dt
            elif dg < 0.02 * sp and dd > 0.25:
                Q["sliding (items)"] += dt
    for k, ds in flow.items():
        gm = sum(ds) / len(ds)
        s = slide(k, ta, tb)
        sp = tier_speed(k) * (tb - ta) / 60.0
        if gm >= 0.25 and s < 0.05:
            Q["frozen (lattice)"] += len(ds) * dt
            run_of[k] = run_of.get(k, 0.0) + dt
        elif k in run_of:
            close_span(k)
        elif gm < 0.02 * sp and s > 0.25:
            Q["sliding (lattice)"] += len(ds) * dt
for k in list(run_of):
    close_span(k)

# Gaps by distance (needs the client's --belt-lanes-dump=lanes.jsonl beside draw.bin): the game's items
# inside the camera's whole ground view (the dump's "g", not the job's view, which belt_items.gd cuts at
# VIEW_FAR) and the recording's area, by band of distance (tiles, round) from the simulated square's centre (the character): on a
# lane with a drawn item near one of its game items (0.4 tile), else with a lane icon shown near one
# (0.6 tile: as the shader shows them, the square's belts and those past the far distance left out),
# else neither.
BAND = 32
bands = collections.defaultdict(collections.Counter)
lanes_file = d / "lanes.jsonl"
at_xy = None
try:
    at_xy = (json.load(open(d / "run.json")) or {}).get("at")
except (OSError, ValueError):
    pass
if lanes_file.exists() and samples_u:
    ev_l = []
    with open(lanes_file, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                ev_l.append(json.loads(line))
            except ValueError:
                pass
    ev_l.sort(key=lambda e: e.get("u", 0))
    chunks_l, params, held_l, unknown_l, ground = {}, None, set(), set(), None
    ei = 0

    def in_quad(q, x, y):
        s = 0
        for i in range(4):
            x0, y0, x1, y1 = q[2 * i], q[2 * i + 1], q[(2 * i + 2) % 8], q[(2 * i + 3) % 8]
            cr = (x1 - x0) * (y - y0) - (y1 - y0) * (x - x0)
            if cr != 0:
                if s == 0:
                    s = 1 if cr > 0 else -1
                elif (cr > 0) != (s > 0):
                    return False
        return True

    for t in ticks:
        u = samples_u.get(t)
        if u is None:
            continue
        while ei < len(ev_l) and ev_l[ei].get("u", 0) <= u:
            e = ev_l[ei]
            ei += 1
            if "c" in e:
                chunks_l[tuple(e["c"])] = {int(k): np.array(v, dtype=float).reshape(-1, 4) for k, v in e["i"].items()}
            elif "d" in e:
                chunks_l.pop(tuple(e["d"]), None)
            elif "p" in e:
                params = e["p"]
                hl = e.get("held") or []
                held_l = {(int(hl[i]), int(hl[i + 1])) for i in range(0, len(hl) - 1, 2)}
                unknown_l = {int(v) for v in e.get("unknown") or []}
            elif "g" in e:
                ground = e["g"]
        if ground is None:
            continue
        icon_grid = collections.defaultdict(list)
        if params is not None:
            pcx, pcy, pnear, pfar = params
            for c, by in chunks_l.items():
                if c in held_l:
                    continue
                for item, arr in by.items():
                    if item in unknown_l or not len(arr):
                        continue
                    keep = (np.maximum(np.abs(arr[:, 2] - pcx), np.abs(arr[:, 3] - pcy)) >= pnear) & \
                           (np.hypot(arr[:, 0] - pcx, arr[:, 1] - pcy) <= pfar)
                    for px, pz in arr[keep][:, :2].tolist():
                        icon_grid[(math.floor(px / 0.5), math.floor(pz / 0.5))].append((px, pz))
        uu, ii, x, z, shown = samples[t][3]
        grid = collections.defaultdict(list)
        for j in np.nonzero(shown)[0].tolist():
            grid[(math.floor(x[j] / 0.5), math.floor(z[j] / 0.5))].append((x[j], z[j]))

        def hit(g, gx, gy, r):
            for ddx in (-2, -1, 0, 1, 2):
                for ddy in (-2, -1, 0, 1, 2):
                    for px, pz in g.get((math.floor(gx / 0.5) + ddx, math.floor(gy / 0.5) + ddy), ()):
                        if math.hypot(px - gx, pz - gy) <= r:
                            return True
            return False

        per_lane = collections.defaultdict(list)
        for uid, key, item, pos, cnt in rows[t]:
            gx, gy = placer[key](pos)
            if area and not (area[0] <= gx <= area[2] and area[1] <= gy <= area[3]):
                continue
            if in_quad(ground, gx, gy):
                per_lane[key].append((gx, gy))
        # (From the simulated square's centre, which follows the character; before it is known, where it stood.)
        if params is not None:
            ox, oy = params[0], params[1]
        else:
            ox, oy = (at_xy if at_xy else ((area[0] + area[2]) / 2, (area[1] + area[3]) / 2))
        jv = views[t]
        for key, pts in per_lane.items():
            band = int(math.hypot(pts[0][0] - ox, pts[0][1] - oy) // BAND)
            bands[band]["game"] += len(pts) * dt
            if any(hit(grid, gx, gy, 0.4) for gx, gy in pts):
                bands[band]["items"] += len(pts) * dt
            elif any(hit(icon_grid, gx, gy, 0.6) for gx, gy in pts):
                bands[band]["icons"] += len(pts) * dt
            else:
                bands[band]["neither"] += len(pts) * dt
                # (Outside the job's view, belt_items.gd's: no records planned there.)
                if jv is not None and not in_view(jv, pts[0][0], pts[0][1], 0):
                    bands[band]["neither, out of the job's view"] += len(pts) * dt
    gtot = sum(b["game"] for b in bands.values())
    ntot = sum(b["neither"] for b in bands.values())
    print("whole ground view (lanes.jsonl): %.0f game item-s, neither an item nor an icon %.0f (%.2f%%); by band from the character:"
          % (gtot, ntot, 100 * ntot / max(1e-9, gtot)))
    print("    %-12s %12s %8s %8s %8s  %s" % ("tiles", "game item-s", "items", "icons", "neither", "(neither: out of the job's view)"))
    for band in sorted(bands):
        bb = bands[band]
        g = max(1e-9, bb["game"])
        print("    %4d-%-7d %12.0f %7.1f%% %7.1f%% %7.1f%%  (%.1f%%)" % (band * BAND, (band + 1) * BAND, bb["game"], 100 * bb["items"] / g,
              100 * bb["icons"] / g, 100 * bb["neither"] / g, 100 * bb["neither, out of the job's view"] / g))
    nb = sum(b["neither"] for k, b in bands.items() if (k + 1) * BAND <= a.belt_distance)
    gb = sum(b["game"] for k, b in bands.items() if (k + 1) * BAND <= a.belt_distance)
    print("    within --belt-distance %.0f: neither %.0f of %.0f item-s (%.2f%%)" % (a.belt_distance, nb, gb, 100 * nb / max(1e-9, gb)))
tot = Q["game items (in view)"]
secs = (ticks[-1] - ticks[0]) / 60.0 + dt
print("game items in view: %.0f item-s over %.0f s (%.0f items on average)" % (tot, secs, tot / max(1e-9, secs)))
rank = sorted(((k, v) for k, v in Q.items() if k != "game items (in view)"), key=lambda kv: -kv[1])
for k, v in rank:
    print("  %-44s %9.0f item-s  %5.2f%% of the game's" % (k, v, 100 * v / max(1e-9, tot)))
for part in ("item lanes", "lattice lanes"):
    g = max(1e-9, Qs[part + ": game"])
    print("  %s: %.0f game item-s; missing %.0f (%.2f%%), phantom %.0f (%.2f%%), holes %.0f (%.2f%%)" % (
        part, Qs[part + ": game"], Qs[part + ": missing"], 100 * Qs[part + ": missing"] / g, Qs[part + ": phantom"],
        100 * Qs[part + ": phantom"] / g, Qs[part + ": holes"], 100 * Qs[part + ": holes"] / g))
print("  frozen lattice spans (a lane drawn standing while the game's items there moved): >= 2 s %d, >= 5 s %d, >= 8 s %d"
      % (spans[2], spans[5], spans[8]))
if jumps_at:
    big = sum(v for v in jumps_at.values() if v >= 20)
    print("  jumps by apply: %d applies with any, the most %s; %d jumps (%.0f%%) in applies with 20 or more" % (
        len(jumps_at), jumps_at.most_common(3), big, 100.0 * big / max(1, ev["jumps"])))
for k in ("jumps", "lattice hops", "lattice hop slots", "flicker"):
    print("  %-44s %9d  (%.1f a second)" % (k, ev[k], ev[k] / max(1e-9, secs)))
if a.json:
    json.dump({"Q": Q, "Qs": Qs, "ev": ev, "secs": secs, "spans": spans, "jumps": ev_where["jumps"][::max(1, len(ev_where["jumps"]) // 400)][:400], "jumps_at": dict(jumps_at),
               "bands": {str(k * BAND): dict(v) for k, v in bands.items()}}, open(a.json, "w"))
