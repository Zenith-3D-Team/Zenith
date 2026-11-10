#!/usr/bin/env python3
"""Belt items' truth test: the client's own model of straight runs (belt_items.gd: Plain,
_move_plains, _chains; belt_items.lua's `br`) measured tick by tick against the game.

    python tools/belt_truth.py survey [--at -272,-14] [--radius 24]
        the straight runs round a point (two looks a few seconds apart): length, tier, items, stacks,
        whether they moved, inserters' targets, side-loads, what is behind and in front
    python tools/belt_truth.py record --out DIR --runs "x,y;x,y;..." [--seconds 25] [--warmup 20]
        a stand-in client asks for belt items as the real one does (hello z, b, bl, bg, br; bfar as
        tools/belt_bench.py) and keeps every `bi` it gets (DIR/stream.jsonl, from the handshake on);
        after the warm-up the game records, every tick, every lane of each run given (a belt anywhere
        on it: the straight run of belts of one kind facing one way through it) and the lanes either
        side, each item's unique id, line position (exact, in 1/256) and stack size (DIR/truth.jsonl,
        DIR/lanes.json); the belts round them for the replay (DIR/belts.json); the mod's own view of
        each run belt (watched or plain) at the end
    godot --headless --path client res://tests/belt_truth_replay.tscn -- --dir=DIR
        replays DIR/stream.jsonl through belt_items.gd and writes where each item is: at each update's
        tick as the client's model has it then (its record at that tick: DIR/model.json), and where it
        is drawn every frame (DIR/drawn.json)
    python tools/belt_truth.py oracle DIR
        DIR/stream_oracle.jsonl: the same stream with every item on the recorded lanes where the game
        had it on the update's tick (the mod reads lanes over the ticks before it and carries their
        items on); replayed (the replay's --stream=stream_oracle.jsonl --out=oracle) and compared
        (--name oracle), what is left is the client's own model
    python tools/belt_truth.py compare DIR [--lane-report N] [--json out.json]
        per lane and per tick, the game's items against the client's, matched by order along the run
        (not by id: the client's items on a plain lane keep the ids they came with): counts, offsets,
        items missing or extra, queues in the wrong place, items handed across a belt edge wrongly;
        the first tick each lane differs and how the error grows

Use a copy of the save: it uses /c. The recording slows the server; keep it short (20-30 s).
"""

import argparse
import bisect
import collections
import json
import math
import pathlib
import socket
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import rcon  # noqa: E402

MOD = "__factorio-3d-bridge__"
LANE_KEYS = 8
DIRS = {0: (0, -1), 4: (1, 0), 8: (0, 1), 12: (-1, 0)}

# --- Lua ---------------------------------------------------------------------------------------

SURVEY_LUA = r"""
local s = game.surfaces.nauvis
local area = {{%(x0)f, %(y0)f}, {%(x1)f, %(y1)f}}
local out = {belts = {}, ins = {}}
local types = {"transport-belt", "underground-belt", "splitter", "loader", "loader-1x1", "lane-splitter", "linked-belt"}
for _, e in pairs(s.find_entities_filtered({area = area, type = types})) do
  local nb = e.belt_neighbours
  local ins, outs = {}, {}
  for _, b in pairs(nb.inputs or {}) do ins[#ins + 1] = b.unit_number end
  for _, b in pairs(nb.outputs or {}) do outs[#outs + 1] = b.unit_number end
  local lanes = {}
  for i = 1, e.get_max_transport_line_index() do
    local l = e.get_transport_line(i)
    local ids = {}
    for _, it in pairs(l.get_detailed_contents()) do ids[#ids + 1] = it.unique_id end
    lanes[i] = {#l, l.get_item_count(), ids}
  end
  out.belts[#out.belts + 1] = {e.unit_number, e.name, e.type, e.position.x, e.position.y, e.direction,
    e.type == "transport-belt" and e.belt_shape or (e.type == "underground-belt" and e.belt_to_ground_type or ""), ins, outs, lanes}
end
for _, e in pairs(s.find_entities_filtered({area = {{%(x0)f - 3, %(y0)f - 3}, {%(x1)f + 3, %(y1)f + 3}}, type = {"inserter", "mining-drill"}})) do
  local p, d = e.type == "inserter" and e.pickup_target or nil, e.drop_target
  out.ins[#out.ins + 1] = {e.unit_number, e.name, e.position.x, e.position.y, p and p.unit_number or 0, d and d.unit_number or 0}
end
helpers.write_file("%(file)s", helpers.table_to_json(out), false)
rcon.print("survey " .. #out.belts .. " belts")
"""

# The runs through the seeds, the lanes either side, the belts round them; then every tick each
# lane's items (unique id, line position in 1/256, stack size), written a second at a time.
RECORD_LUA = r"""
local s = game.surfaces.nauvis
local seeds = {%(seeds)s}
local DIR = {[0] = {0, -1}, [4] = {1, 0}, [8] = {0, 1}, [12] = {-1, 0}}
local function straight(e) return e and e.valid and e.type == "transport-belt" and e.belt_shape == "straight" end
local function cont(a, b)
  if not (straight(a) and straight(b) and a.direction == b.direction and a.name == b.name) then return false end
  local d = DIR[a.direction]
  if not d then return false end
  return math.abs(b.position.x - a.position.x - d[1]) < 0.01 and math.abs(b.position.y - a.position.y - d[2]) < 0.01
end
local function fwd(e) for _, o in pairs(e.belt_neighbours.outputs or {}) do if cont(e, o) then return o end end end
local function back(e) for _, i in pairs(e.belt_neighbours.inputs or {}) do if cont(i, e) then return i end end end
local function shape(e)
  if e.type == "transport-belt" then return e.belt_shape end
  if e.type == "underground-belt" then return e.belt_to_ground_type end
  return ""
end
local rec = {runs = {}, lanes = {}, ents = {}, ins = {}, lines = {}}
local done = {}
local function add(e, run, m, role)
  if not (e and e.valid) or done[e.unit_number] then return end
  done[e.unit_number] = true
  rec.ents[#rec.ents + 1] = {e.unit_number, e.name, e.type, e.position.x, e.position.y, e.direction, shape(e), run, m, role, e.prototype.belt_speed}
  for i = 1, e.get_max_transport_line_index() do
    local l = e.get_transport_line(i)
    local len = l.line_length
    local pts = {}
    local n = math.max(2, math.ceil(len / 0.0625))
    for k = 0, n do
      local p = l.get_line_item_position(len * k / n)
      pts[#pts + 1] = math.floor(p.x * 256 + 0.5)
      pts[#pts + 1] = math.floor(p.y * 256 + 0.5)
    end
    rec.lanes[#rec.lanes + 1] = {#rec.lanes + 1, e.unit_number, i, run, m, role, len, pts}
    rec.lines[#rec.lines + 1] = l
  end
end
local box = {math.huge, math.huge, -math.huge, -math.huge}
for r, xy in ipairs(seeds) do
  local e = s.find_entities_filtered({position = xy, type = "transport-belt", limit = 1})[1]
  if e and straight(e) then
    local visit = {[e.unit_number] = true}
    while true do local o = fwd(e) if not o or visit[o.unit_number] then break end e = o visit[e.unit_number] = true end
    local list = {}
    local seen = {}
    local cur = e
    while cur and not seen[cur.unit_number] do seen[cur.unit_number] = true list[#list + 1] = cur cur = back(cur) end
    rec.runs[#rec.runs + 1] = {r, #list, list[1].name, list[1].direction}
    for m, b in ipairs(list) do add(b, r, m - 1, "run") end
    for _, o in pairs(list[1].belt_neighbours.outputs or {}) do add(o, r, -1, "ahead") end
    for m, b in ipairs(list) do
      for _, i in pairs(b.belt_neighbours.inputs or {}) do if not seen[i.unit_number] then add(i, r, m - 1, m == #list and "behind" or "side") end end
    end
    for _, b in ipairs(list) do
      box[1], box[2] = math.min(box[1], b.position.x), math.min(box[2], b.position.y)
      box[3], box[4] = math.max(box[3], b.position.x), math.max(box[4], b.position.y)
    end
  end
end
local units = {}
for _, e in ipairs(rec.ents) do units[e[1]] = e[10] end
for _, e in pairs(s.find_entities_filtered({area = {{box[1] - 4, box[2] - 4}, {box[3] + 4, box[4] + 4}}, type = {"inserter", "mining-drill"}})) do
  local p, d = e.type == "inserter" and e.pickup_target or nil, e.drop_target
  local pu, du = p and p.unit_number or 0, d and d.unit_number or 0
  if units[pu] or units[du] then rec.ins[#rec.ins + 1] = {e.unit_number, e.name, e.position.x, e.position.y, pu, du} end
end
local belts = {}
local M = %(margin)d
for _, e in pairs(s.find_entities_filtered({area = {{box[1] - M, box[2] - M}, {box[3] + M, box[4] + M}}, type = {"transport-belt", "underground-belt", "splitter"}})) do
  belts[#belts + 1] = {e.name, e.type, e.position.x, e.position.y, e.direction, string.sub(shape(e), 1, 1)}
end
local lines = rec.lines
rec.lines = nil
rec.from, rec.to = game.tick + 1, game.tick + %(ticks)d
helpers.write_file("%(name)s_lanes.json", helpers.table_to_json(rec), false)
helpers.write_file("%(name)s_belts.json", helpers.table_to_json({belts = belts, box = box}), false)
helpers.write_file("%(name)s_truth.jsonl", "", false)
local from, to = rec.from, rec.to
local buf = {}
local frac = 0
script.on_nth_tick(1, function()
  local t = game.tick
  if t < from or t > to then return end
  local row = {}
  for j, l in ipairs(lines) do
    if l.valid then
      local c = l.get_detailed_contents()
      if #c > 0 then
        row[#row + 1] = j
        row[#row + 1] = #c
        for _, it in ipairs(c) do
          local p = it.position * 256
          local q = math.floor(p + 0.5)
          if math.abs(p - q) > frac then frac = math.abs(p - q) end
          row[#row + 1] = it.unique_id
          row[#row + 1] = q
          row[#row + 1] = it.stack.count
        end
      end
    end
  end
  buf[#buf + 1] = '{"t":' .. t .. ',"l":[' .. table.concat(row, ",") .. ']}'
  if #buf >= 60 or t == to then
    helpers.write_file("%(name)s_truth.jsonl", table.concat(buf, "\n") .. "\n", true)
    buf = {}
  end
  if t == to then
    helpers.write_file("%(name)s_truth.jsonl", '{"done":' .. t .. ',"frac":' .. frac .. '}\n', true)
  end
end)
rcon.print("recording " .. #rec.runs .. " runs, " .. #rec.lanes .. " lanes, ticks " .. from .. " to " .. to .. ", " .. #belts .. " belts round them")
"""

# The mod's record of each run belt (straight runs: f3d.bw, unit -> {watched, behind, in front}).
WATCH_LUA = (f"/c {MOD} local bw = storage.f3d and storage.f3d.bw or {{}} local out = {{}} "
             "for _, u in ipairs({%s}) do local w = bw[u] out[#out + 1] = w and {u, w[1] and 1 or 0, w[2], w[3]} or {u, -1, 0, 0} end "
             "rcon.print(helpers.table_to_json(out))")

PIN_LUA = (f"/c {MOD} local p = package.loaded['{MOD}/scripts/puppet.lua'].get() if p then "
           "p.character_running_speed_modifier = -1 local x, y = %s "
           "if math.abs(p.position.x - x) + math.abs(p.position.y - y) > 0.5 then p.teleport({x, y}, game.surfaces.nauvis) end end")


def sc(lua):
    """One /sc command from a multi-line Lua text (no comments in it: the lines are joined)."""
    return "/sc " + " ".join(l.strip() for l in lua.splitlines() if l.strip())


# --- survey -------------------------------------------------------------------------------------

def survey(args):
    x, y = (float(v) for v in args.at.split(","))
    r = args.radius
    out = pathlib.Path(args.script_output)
    looks = []
    for n in range(2):
        name = "belt_truth_survey_%d.json" % n
        print(rcon.run(sc(SURVEY_LUA % {"x0": x - r, "y0": y - r, "x1": x + r, "y1": y + r, "file": name}),
                       port=args.rcon_port, timeout=60).strip())
        time.sleep(1.0)
        looks.append(json.loads((out / name).read_text()))
        if n == 0:
            time.sleep(args.gap)
    a, b = looks
    belts = {e[0]: e for e in a["belts"]}
    later = {e[0]: e for e in b["belts"]}
    targets = {}
    for e in a["ins"]:
        if e[4]:
            targets.setdefault(e[4], set()).add("pick")
        if e[5]:
            targets.setdefault(e[5], set()).add("drop")

    def straight(e):
        return e[2] == "transport-belt" and e[6] == "straight"

    def cont(p, q):
        d = DIRS.get(p[5])
        return straight(p) and straight(q) and q[5] == p[5] and q[1] == p[1] and d is not None \
            and abs(q[3] - p[3] - d[0]) < 0.01 and abs(q[4] - p[4] - d[1]) < 0.01

    fwd, back = {}, {}
    for u, e in belts.items():
        for o in e[8]:
            if o in belts and cont(e, belts[o]):
                fwd[u] = o
                back[o] = u
    rows = []
    for u, e in belts.items():
        if not straight(e) or u in fwd:
            continue
        run = [u]
        while run[-1] in back:
            run.append(back[run[-1]])
        if len(run) < args.min_length:
            continue
        front, last = belts[run[0]], belts[run[-1]]
        lanes = [belts[v][9] for v in run]
        items = sum(l[i][1] for l in lanes for i in range(2))
        stacks = sum(l[i][0] for l in lanes for i in range(2))
        moved = sum(1 for v in run for i in range(2) if v in later and later[v][9][i][2] != belts[v][9][i][2])
        full = [sum(1 for l in lanes if l[i][0] == 4) for i in range(2)]
        tg = ["%d:%s" % (m, "+".join(sorted(targets[v]))) for m, v in enumerate(run) if v in targets]
        side = [m for m, v in enumerate(run) if len(belts[v][7]) > 1]

        def kind(v):
            return (belts[v][2].replace("transport-belt", "belt") + ":" + belts[v][6]) if v in belts else "?"
        rows.append((math.hypot(front[3] - x, front[4] - y), len(run), front[1].split("-")[0], front[5],
                     last[3], last[4], front[3], front[4], items, stacks, moved, full, tg, side,
                     [kind(v) for v in last[7] if v not in run], [kind(v) for v in front[8]]))
    rows.sort()
    print("dist len tier     dir  back -> front            items stacks lanes-moved full-belts targets side behind ahead")
    for row in rows[:args.limit]:
        print("%5.1f %3d %-8s %2d (%6.1f,%6.1f)->(%6.1f,%6.1f) %5d %5d %4d %-9s %s %s %s %s" % (
            row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7], row[8], row[9], row[10],
            row[11], ",".join(row[12]) or "-", row[13] or "-", row[14], row[15]))


# --- record -------------------------------------------------------------------------------------

def record(args):
    password = pathlib.Path(args.password_file).read_text().strip()
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    so = pathlib.Path(args.script_output)

    def cmd(c, timeout=60.0):
        return rcon.run(c, port=args.rcon_port, password=password, timeout=timeout)

    cmd("/sc rcon.print(1)")  # the first /sc in a save only warns about achievements
    cmd("/sc rcon.print(1)")
    stop = {"stop": False, "pos": None}
    pin = PIN_LUA % args.at

    def pinning():
        while not stop["stop"]:
            try:
                cmd(pin, timeout=20.0)
            except Exception:
                pass
            time.sleep(1.0)
    cmd(pin)
    threading.Thread(target=pinning, daemon=True).start()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 32 * 1024 * 1024)
    sock.bind(("127.0.0.1", args.client_port))
    sock.settimeout(0.05)
    server = ("127.0.0.1", args.udp_port)
    hello = {"t": "hello", "v": 1, "sid": "belt-truth", "w": 1, "z": 1, "b": 1, "bl": 1, "bg": 1, "br": 1}
    if args.no_runs:
        hello.pop("br")
    stream = open(out / "stream.jsonl", "w", encoding="utf-8")
    counts = {"bi": 0, "all": 0}

    def receive():
        while not stop["stop"]:
            try:
                data, _ = sock.recvfrom(1 << 20)
            except (socket.timeout, ConnectionResetError):
                continue
            for line in data.split(b"\n"):
                if not line:
                    continue
                counts["all"] += 1
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                t = msg.get("t")
                if t == "bi":
                    counts["bi"] += 1
                    stream.write(line.decode("utf-8", "replace") + "\n")
                elif t == "me" and "x" in msg:
                    stop["pos"] = (msg["x"] / 256, msg["y"] / 256)

    threading.Thread(target=receive, daemon=True).start()

    def send(msg):
        sock.sendto(json.dumps(msg).encode(), server)

    def keep_alive(until, check=None):
        while time.monotonic() < until:
            send(hello)
            pos = stop["pos"]
            if pos:
                cx, cy = int(pos[0] // 32), int(pos[1] // 32)
                send({"t": "sub", "c": [[cx + dx, cy + dy] for dy in range(-args.view, args.view + 1)
                                        for dx in range(-args.view, args.view + 1)]})
                send({"t": "focus", "x": int(pos[0] * 256), "y": int(pos[1] * 256), "r": 96})
                send({"t": "bfar", "r": args.near, "n": args.near, "m": args.cap, "u": args.units})
            if check and check():
                return True
            time.sleep(1.0)
        return False

    name = "belt_truth_%d" % int(time.time())
    seeds = ", ".join("{%s}" % s.strip() for s in args.runs.split(";") if s.strip())

    def start_truth(seconds):
        print(cmd(sc(RECORD_LUA % {"seeds": seeds, "ticks": int(seconds * 60), "name": name, "margin": args.margin})).strip(), flush=True)
    if args.from_start:
        # The game recorded from before the client's hello: its first updates are compared too.
        start_truth(args.warmup + args.seconds)
    print("warming up %.0f s (stand-in client on UDP %d)" % (args.warmup, args.udp_port), flush=True)
    keep_alive(time.monotonic() + args.warmup)
    if stop["pos"] is None:
        print("no reply from the bridge: is the server running and the UDP port right?")
        sys.exit(1)
    if not args.from_start:
        start_truth(args.seconds)
    truth = so / (name + "_truth.jsonl")

    def finished():
        try:
            text = truth.read_text()
        except OSError:
            return False
        return '"done"' in text[-200:]
    ok = keep_alive(time.monotonic() + args.seconds * 30 + 120, finished)
    # The updates covering the last recorded ticks.
    keep_alive(time.monotonic() + 3.0)
    lanes = json.loads((so / (name + "_lanes.json")).read_text())
    units = sorted({e[0] for e in lanes["ents"] if e[9] == "run"})
    watch = json.loads(cmd(WATCH_LUA % ",".join(str(u) for u in units)).strip() or "[]")
    stop["stop"] = True
    send({"t": "bye"})
    time.sleep(0.3)
    stream.close()
    lanes["watch"] = watch
    (out / "lanes.json").write_text(json.dumps(lanes))
    (out / "belts.json").write_text((so / (name + "_belts.json")).read_text())
    (out / "truth.jsonl").write_text(truth.read_text())
    print("%s: %d bi messages, truth %s; %d lanes in %d runs" % (
        "done" if ok else "TIMED OUT", counts["bi"], truth.stat().st_size, len(lanes["lanes"]), len(lanes["runs"])))


# --- compare ------------------------------------------------------------------------------------

class Lane:
    """A recorded lane: its line (map points along it, 1/256 tile) and where it is in its run."""

    def __init__(self, rec, ent):
        self.j, self.unit, self.i, self.run, self.m, self.role, self.length = rec[:7]
        pts = rec[7]
        self.pts = [(pts[k] / 256, pts[k + 1] / 256) for k in range(0, len(pts), 2)]
        # A straight line needs only its ends (most lanes: locate() is the comparison's hot loop). Its
        # far end from the samples before it: get_line_item_position() clamps the line's own end to
        # 1/256 short of it (a straight lane's position 1 comes back 255/256 from position 0).
        (ax, ay), (bx, by) = self.pts[0], self.pts[-1]
        if all(abs((bx - ax) * (y - ay) - (by - ay) * (x - ax)) < 1e-6 for x, y in self.pts):
            n = len(self.pts) - 1
            if n >= 2:
                cx, cy = self.pts[n - 1]
                bx, by = ax + (cx - ax) * n / (n - 1), ay + (cy - ay) * n / (n - 1)
            self.pts = [(ax, ay), (bx, by)]
        self.key = self.unit * LANE_KEYS + self.i
        self.ent = ent
        self.type = ent[2]
        self.speed = ent[10]
        # Arc length along the points, scaled to line positions.
        self.cum = [0.0]
        for a, b in zip(self.pts, self.pts[1:]):
            self.cum.append(self.cum[-1] + math.hypot(b[0] - a[0], b[1] - a[1]))
        total = self.cum[-1] or 1.0
        self.cum = [c / total * self.length for c in self.cum]

    def locate(self, x, y):
        """(distance from the line, line position) of a map point."""
        best = (math.inf, 0.0)
        for k in range(len(self.pts) - 1):
            ax, ay = self.pts[k]
            bx, by = self.pts[k + 1]
            dx, dy = bx - ax, by - ay
            ll = dx * dx + dy * dy
            t = 0.0 if ll == 0 else max(0.0, min(1.0, ((x - ax) * dx + (y - ay) * dy) / ll))
            d = math.hypot(ax + dx * t - x, ay + dy * t - y)
            if d < best[0]:
                best = (d, self.cum[k] + (self.cum[k + 1] - self.cum[k]) * t)
        return best


class Runs:
    """The recorded lanes, by run and lane index (1, 2), with a lookup from map points."""

    def __init__(self, lanes_json):
        ents = {e[0]: e for e in lanes_json["ents"]}
        self.lanes = [Lane(r, ents[r[1]]) for r in lanes_json["lanes"]]
        self.by_j = {l.j: l for l in self.lanes}
        self.runs = {r[0]: r for r in lanes_json["runs"]}
        self.cells = {}
        for l in self.lanes:
            for (x, y) in l.pts:
                self.cells.setdefault((math.floor(x), math.floor(y)), set()).add(l.j)
        # Run lanes: (run, i) -> [lane at m = 0 (front), 1, ...]
        self.run_lanes = {}
        for l in self.lanes:
            if l.role == "run":
                self.run_lanes.setdefault((l.run, l.i), {})[l.m] = l
        self.watch = {w[0]: w for w in lanes_json.get("watch", [])}

    def locate(self, x, y, tol=0.15):
        """The lane a map point is on (nearest within tol, a lane whose line position range holds it)
        and its line position, or None."""
        best = None
        cands = set()
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                cands |= self.cells.get((math.floor(x) + dx, math.floor(y) + dy), set())
        for j in cands:
            l = self.by_j[j]
            d, s = l.locate(x, y)
            # A point where two lanes meet (an item standing at a belt's edge) is on the one it leaves,
            # at its position 0, as the game lists it.
            if d < tol and (best is None or (round(d, 3), s) < (round(best[0], 3), best[2])):
                best = (d, l, s)
        return best

    def run_pos(self, lane, s):
        """A run lane's line position as a place along its run: m + s, 0 at the run's front edge."""
        return lane.m + s


def load_truth(path):
    ticks = {}
    frac = None
    for line in pathlib.Path(path).read_text().splitlines():
        if not line.strip():
            continue
        r = json.loads(line)
        if "done" in r:
            frac = r.get("frac")
            continue
        lanes = {}
        l = r["l"]
        k = 0
        while k < len(l):
            j, n = l[k], l[k + 1]
            lanes[j] = [(l[k + 2 + 3 * q], l[k + 3 + 3 * q], l[k + 4 + 3 * q]) for q in range(n)]
            k += 2 + 3 * n
        ticks[r["t"]] = lanes
    return ticks, frac


def align(a, b, gap_cost=0.3):
    """Order-preserving matching of two sorted lists of places: pairs (i, j) and the unmatched,
    each unmatched costing gap_cost (an item further off than that is missing on one side and extra
    on the other)."""
    n, m = len(a), len(b)
    INF = float("inf")
    cost = [[INF] * (m + 1) for _ in range(n + 1)]
    back = [[None] * (m + 1) for _ in range(n + 1)]
    cost[0][0] = 0.0
    for i in range(n + 1):
        for j in range(m + 1):
            c = cost[i][j]
            if c == INF:
                continue
            if i < n and j < m:
                d = c + abs(a[i] - b[j])
                if d < cost[i + 1][j + 1]:
                    cost[i + 1][j + 1], back[i + 1][j + 1] = d, (i, j, "m")
            if i < n and c + gap_cost < cost[i + 1][j]:
                cost[i + 1][j], back[i + 1][j] = c + gap_cost, (i, j, "a")
            if j < m and c + gap_cost < cost[i][j + 1]:
                cost[i][j + 1], back[i][j + 1] = c + gap_cost, (i, j, "b")
    pairs, only_a, only_b = [], [], []
    i, j = n, m
    while (i, j) != (0, 0):
        pi, pj, kind = back[i][j]
        if kind == "m":
            pairs.append((pi, pj))
        elif kind == "a":
            only_a.append(pi)
        else:
            only_b.append(pj)
        i, j = pi, pj
    return pairs[::-1], only_a[::-1], only_b[::-1]


def compare(args):
    d = pathlib.Path(args.dir)
    runs = Runs(json.loads((d / "lanes.json").read_text()))
    truth, frac = load_truth(d / "truth.jsonl")
    suffix = ("_" + args.name) if args.name else ""
    model = json.loads((d / ("model%s.json" % suffix)).read_text())
    plains = {int(k) for k in model.get("plains", [])}
    tol = args.tol
    t_from, t_to = min(truth), max(truth)
    print("truth: ticks %d to %d (%d), %d lanes in %d runs; largest fraction of 1/256 in a line position: %s" % (
        t_from, t_to, len(truth), len(runs.lanes), len(runs.runs), frac))
    # The client's items at each update's tick, as its model has them then, by run lane.
    upd = [u for u in model["updates"] if t_from <= u[0] <= t_to]
    print("model: %d updates in the recording (of %d), ticks between them: %s" % (
        len(upd), len(model["updates"]), sorted({b[0] - a[0] for a, b in zip(upd, upd[1:])})))
    report = {"lanes": {}, "summary": {}}
    per_run_lane = {}  # (run, i) -> per update [(tick, game items, client items)], items (place, uid, stack)
    per_ent = {}  # a neighbour's unit -> per update [(tick, game points, client points)]
    for u in upd:
        tick = u[0]
        flat = u[1]
        sx, sy, sr = u[2], u[3], u[4]

        def inside(lane):
            # Belts whose centre is in the square the update read (a ring short of its edge).
            return max(abs(lane.ent[3] - sx), abs(lane.ent[4] - sy)) < sr - 1
        cl, cl_ent = {}, {}
        for k in range(0, len(flat), 4):
            uid, x, y, n = flat[k], flat[k + 1] / 1024, flat[k + 2] / 1024, flat[k + 3]
            hit = runs.locate(x, y)
            if hit is None or not inside(hit[1]):
                continue
            _, lane, s = hit
            if lane.role != "run":
                cl_ent.setdefault(lane.unit, []).append((x, y, uid, n))
                continue
            cl.setdefault((lane.run, lane.i), []).append((runs.run_pos(lane, s), uid, n, ring_of(lane, sx, sy)))
        tr, tr_ent = {}, {}
        for j, items in truth.get(tick, {}).items():
            lane = runs.by_j[j]
            if not inside(lane):
                continue
            for uid, p, n in items:
                if lane.role == "run":
                    tr.setdefault((lane.run, lane.i), []).append((runs.run_pos(lane, p / 256), uid, n, ring_of(lane, sx, sy)))
                else:
                    x, y = point_at(lane, p / 256)
                    tr_ent.setdefault(lane.unit, []).append((x, y, uid, n))
        for key in runs.run_lanes:
            if any(inside(l) for l in runs.run_lanes[key].values()):
                per_run_lane.setdefault(key, []).append((tick, sorted(tr.get(key, [])), sorted(cl.get(key, []))))
        for unit in set(tr_ent) | set(cl_ent):
            per_ent.setdefault(unit, []).append((tick, tr_ent.get(unit, []), cl_ent.get(unit, [])))
    # Per run lane: the first update they differ, and what differs.
    lines = []
    totals = {"updates": 0, "items": 0, "matched": 0, "missing": 0, "extra": 0, "off": 0, "count_diff": 0}
    bands = {}  # "near"/"far" (by the mod's distance tiers) -> [game items, matched, off, missing, extra, sum |offset|]

    def band(ring):
        return "near" if ring < args.near_tier else "far"
    for key in sorted(per_run_lane):
        rows = per_run_lane[key]
        lanes = runs.run_lanes[key]
        r = runs.runs[key[0]]
        belts = len(lanes)
        plain_n = sum(1 for l in lanes.values() if l.key in plains)
        label = "run %d lane %d (%s, %d belts, dir %d; %d lanes plain on the client)" % (key[0], key[1], r[2], belts, r[3], plain_n)
        first = None
        series = []
        examples = []
        for tick, a, b in rows:
            pa = [e[0] for e in a]
            pb = [e[0] for e in b]
            pairs, only_a, only_b = align(pa, pb)
            offs = [pb[j] - pa[i] for i, j in pairs]
            for item in a:
                bands.setdefault(band(item[3]), [0, 0, 0, 0, 0, 0.0])[0] += 1
            for i, j in pairs:
                rec = bands.setdefault(band(a[i][3]), [0, 0, 0, 0, 0, 0.0])
                rec[1] += 1
                rec[2] += 1 if abs(pb[j] - pa[i]) > tol else 0
                rec[5] += abs(pb[j] - pa[i])
            for i in only_a:
                bands.setdefault(band(a[i][3]), [0, 0, 0, 0, 0, 0.0])[3] += 1
            for j in only_b:
                bands.setdefault(band(b[j][3]), [0, 0, 0, 0, 0, 0.0])[4] += 1
            stack_diff = sum(1 for i, j in pairs if a[i][2] != b[j][2])
            worst = max((abs(o) for o in offs), default=0.0)
            bad = bool(only_a or only_b or worst > tol or stack_diff)
            totals["updates"] += 1
            totals["items"] += len(a)
            totals["matched"] += len(pairs)
            totals["missing"] += len(only_a)
            totals["extra"] += len(only_b)
            totals["off"] += sum(1 for o in offs if abs(o) > tol)
            totals["count_diff"] += 1 if len(a) != len(b) else 0
            series.append((tick, len(a), len(b), len(only_a), len(only_b), worst,
                           sum(offs) / len(offs) if offs else 0.0, stack_diff))
            if bad and first is None:
                first = tick
            if bad and len(examples) < args.examples:
                ex = {"tick": tick, "game": [round(p, 4) for p in pa], "client": [round(p, 4) for p in pb],
                      "missing": [round(pa[i], 3) for i in only_a], "extra": [round(pb[j], 3) for j in only_b],
                      "offsets": [round(o, 4) for o in offs], "stacks": [[a[i][2], b[j][2]] for i, j in pairs if a[i][2] != b[j][2]]}
                examples.append(ex)
        n_bad = sum(1 for s in series if s[3] or s[4] or s[5] > tol or s[7])
        mean_abs = [abs(s[6]) for s in series]
        # Growth: the share of updates that differ, and the worst offset, by thirds of the recording.
        thirds = []
        for q in range(3):
            part = series[q * len(series) // 3:(q + 1) * len(series) // 3]
            if part:
                thirds.append((round(100.0 * sum(1 for s in part if s[3] or s[4] or s[5] > tol or s[7]) / len(part)),
                               round(max(s[5] for s in part), 3), sum(s[3] for s in part), sum(s[4] for s in part)))
        report["lanes"][str(key)] = {"label": label, "first": first, "bad_updates": n_bad, "updates": len(series),
                                     "thirds": thirds, "examples": examples, "series": series}
        lines.append((key, label, first, n_bad, len(series), thirds, series))
    print()
    t_ref = max(t_from, model["updates"][0][0]) if model["updates"] else t_from
    print("per lane: the first update tick the client differs from the game (ticks after %s), updates that"
          " differ, and by thirds of the recording: %% differing, worst offset (tiles), items missing, extra" % (
              "the client's first update" if t_ref > t_from else "the recording's start"))
    for key, label, first, n_bad, n, thirds, series in lines:
        print("  %-78s first %6s  %4d/%-4d %s" % (label, "-" if first is None else first - t_ref, n_bad, n,
                                                  "  ".join("%3d%% %.3f m%d e%d" % t for t in thirds)))
    print()
    print("the lanes either side (each entity's items matched by place within 0.15 tile): updates that differ,"
          " items missing, extra")
    ents = {}
    for l in runs.lanes:
        ents[l.unit] = l
    for unit in sorted(per_ent, key=lambda u: (ents[u].run, ents[u].role, u)):
        rows = per_ent[unit]
        l = ents[unit]
        miss = extra = bad = 0
        first = None
        for tick, a, b in rows:
            ma, mb = near_match(a, b, 0.15)
            miss += len(a) - ma
            extra += len(b) - mb
            if ma < len(a) or mb < len(b):
                bad += 1
                first = tick if first is None else first
        print("  run %d %-6s %-26s %-9s first %6s  %4d/%-4d missing %4d extra %4d" % (
            l.run, l.role, l.ent[1], l.ent[6] or "", "-" if first is None else first - t_from, bad, len(rows), miss, extra))
    print()
    tot = totals
    print("all lanes: %d lane-updates, %d game items; matched %d (off by more than %.2f: %d), missing %d, extra %d;"
          " counts differ in %d lane-updates" % (tot["updates"], tot["items"], tot["matched"], tol, tot["off"],
                                               tot["missing"], tot["extra"], tot["count_diff"]))
    for k in sorted(bands):
        v = bands[k]
        print("  %s rings (%s %d): %d game items; matched %d, of which off by more than %.2f: %.1f%% (mean |offset| %.3f);"
              " missing %.1f%%, extra %.1f%% (of the game's)" % (k, "<" if k == "near" else ">=", args.near_tier, v[0], v[1],
                                                                 tol, 100.0 * v[2] / max(1, v[1]), v[5] / max(1, v[1]),
                                                                 100.0 * v[3] / max(1, v[0]), 100.0 * v[4] / max(1, v[0])))
    report["summary"] = totals
    report["bands"] = bands
    # Drawn: where the client draws items against where the game had them at the drawn tick.
    drawn_path = d / ("drawn%s.json" % suffix)
    if drawn_path.exists():
        drawn_summary(runs, truth, json.loads(drawn_path.read_text()), args, report, model["updates"])
    if args.json:
        pathlib.Path(args.json).write_text(json.dumps(report))
    if args.lane_report:
        for key, label, first, n_bad, n, thirds, series in lines:
            if first is None:
                continue
            ex = report["lanes"][str(key)]["examples"]
            print()
            print(label)
            for e in ex[:args.lane_report]:
                print("   t+%d game %s" % (e["tick"] - t_ref, e["game"]))
                print("        client %s" % e["client"])
                print("        missing %s extra %s offsets %s stacks %s" % (e["missing"], e["extra"], e["offsets"], e["stacks"]))


def near_match(a, b, r):
    """How many of a have an item of b within r, and how many of b have one of a (2D points)."""
    def count(p, q):
        n = 0
        for x, y, *_ in p:
            if any(math.hypot(x - qx, y - qy) <= r for qx, qy, *_ in q):
                n += 1
        return n
    return count(a, b), count(b, a)


def drawn_summary(runs, truth, drawn, args, report, updates):
    """The share of the game's items on the recorded lanes with no drawn item within 0.15 tile at
    the drawn tick (belt_path_check.py's measure), by lane kind: plain or watched on the client."""
    plains = set()
    frames = drawn["frames"]
    t_from, t_to = min(truth), max(truth)
    game_n = missing = 0
    drawn_n = phantom = 0
    by_role = {}
    sq_ticks = [u[0] for u in updates]
    for row in frames:
        dt = row[1]
        t = round(dt)
        if t < t_from or t > t_to or t not in truth:
            continue
        k = max(0, bisect.bisect_right(sq_ticks, t) - 1)
        sx, sy, sr = updates[k][2], updates[k][3], updates[k][4]
        pts = [(row[k + 1] / 1024, row[k + 2] / 1024) for k in range(2, len(row), 4)]
        grid = {}
        for x, y in pts:
            grid.setdefault((math.floor(x * 4), math.floor(y * 4)), []).append((x, y))
        # Drawn items on the recorded lanes with no game item within 0.15 (phantoms).
        game_grid = {}
        for j, items in truth[t].items():
            lane = runs.by_j[j]
            for uid, p, n in items:
                gx, gy = point_at(lane, p / 256)
                game_grid.setdefault((math.floor(gx * 4), math.floor(gy * 4)), []).append((gx, gy))
        for x, y in pts:
            hit = runs.locate(x, y)
            if hit is None or max(abs(hit[1].ent[3] - sx), abs(hit[1].ent[4] - sy)) >= sr - 1:
                continue
            drawn_n += 1
            cx, cy = math.floor(x * 4), math.floor(y * 4)
            if not any(math.hypot(qx - x, qy - y) <= 0.15 for ddx in (-1, 0, 1) for ddy in (-1, 0, 1)
                       for qx, qy in game_grid.get((cx + ddx, cy + ddy), [])):
                phantom += 1
        for j, items in truth[t].items():
            lane = runs.by_j[j]
            if max(abs(lane.ent[3] - sx), abs(lane.ent[4] - sy)) >= sr - 1:
                continue
            for uid, p, n in items:
                # The game's place (interpolated would need the next tick; the drawn tick is rounded).
                x, y = point_at(lane, p / 256)
                best = 9.0
                cx, cy = math.floor(x * 4), math.floor(y * 4)
                for ddx in (-1, 0, 1):
                    for ddy in (-1, 0, 1):
                        for qx, qy in grid.get((cx + ddx, cy + ddy), []):
                            best = min(best, math.hypot(qx - x, qy - y))
                role = lane.role + (" near" if ring_of(lane, sx, sy) < args.near_tier else " far")
                rec = by_role.setdefault(role, [0, 0])
                rec[0] += 1
                game_n += 1
                if best > 0.15:
                    missing += 1
                    rec[1] += 1
    print("drawn: of the game's items on the recorded lanes, with no drawn item within 0.15 tile at the drawn tick:"
          " %.2f%% of %d; by role: %s" % (100.0 * missing / max(1, game_n), game_n,
                                          ", ".join("%s %.2f%% of %d" % (k, 100.0 * v[1] / max(1, v[0]), v[0]) for k, v in sorted(by_role.items()))))
    print("drawn: of the items drawn on the recorded lanes, with no game item within 0.15 tile: %.2f%% of %d" % (
        100.0 * phantom / max(1, drawn_n), drawn_n))
    report["drawn"] = {"missing_pct": 100.0 * missing / max(1, game_n), "items": game_n, "by_role": by_role,
                       "phantom_pct": 100.0 * phantom / max(1, drawn_n), "drawn": drawn_n}


def ring_of(lane, sx, sy):
    """The ring (belt_items.lua: tiles from the focus, the larger axis) a lane's belt is in."""
    return math.floor(max(abs(lane.ent[3] - sx), abs(lane.ent[4] - sy)))


def point_at(lane, s):
    """The map point at line position s."""
    k = bisect.bisect_right(lane.cum, s) - 1
    k = max(0, min(len(lane.pts) - 2, k))
    a, b = lane.pts[k], lane.pts[k + 1]
    span = lane.cum[k + 1] - lane.cum[k]
    u = 0.0 if span == 0 else (s - lane.cum[k]) / span
    return a[0] + (b[0] - a[0]) * u, a[1] + (b[1] - a[1]) * u


def oracle(args):
    """The stream with the recorded lanes' items where the game had them on each update's tick; with
    --edges, also every watched lane of the recorded runs sent whole on every update (as if the mod
    checked the lanes either side of plain lanes every update, far or quiet)."""
    d = pathlib.Path(args.dir)
    lanes_json = json.loads((d / "lanes.json").read_text())
    runs = Runs(lanes_json)
    truth, _ = load_truth(d / "truth.jsonl")
    plains = set()
    kind = {}  # uid -> item id, from the stream
    for line in open(d / "stream.jsonl", encoding="utf-8"):
        m = json.loads(line)
        pl = m.get("pl") or []
        for j in range(0, len(pl), 8):
            plains.add(pl[j])
        l = m.get("l") or []
        z = m.get("z", 0) == 1
        uid = item = 0
        for i in range(0, len(l) - 3, 4):
            if z:
                uid += l[i]; item += l[i + 1]
            else:
                uid, item = l[i], l[i + 1]
            kind[uid] = item
    edges = [l for l in runs.lanes if l.role == "run" and l.key not in plains and l.type == "transport-belt"] if args.edges else []
    # --outside: a plain lane whose lane in front is outside the square at some update isn't plain (it is
    # sent as a watched lane, whole, every update): as if the mod made a lane plain only when the belt
    # in front is read too.
    squares = [(m["fx"] / 256, m["fy"] / 256, m["fr"]) for m in map(json.loads, open(d / "stream.jsonl", encoding="utf-8"))
               if "fr" in m and m.get("part", 1) == 1]
    unplain = set()
    if args.outside:
        for (run, i), by_m in runs.run_lanes.items():
            for mm, lane in by_m.items():
                ahead = by_m.get(mm - 1)
                if lane.key in plains and ahead is not None and any(ring_of(ahead, sx, sy) >= sr for sx, sy, sr in squares):
                    unplain.add(lane.key)
        edges += [l for l in runs.lanes if l.key in unplain]
    fixed = total = added = 0
    name = "stream_oracle_edges.jsonl" if args.edges else "stream_oracle.jsonl"
    if args.outside:
        name = name.replace(".jsonl", "_outside.jsonl")
    with open(d / name, "w", encoding="utf-8") as out:
        for line in open(d / "stream.jsonl", encoding="utf-8"):
            m = json.loads(line)
            k = m.get("k")
            l = m.get("l")
            if unplain and m.get("pl"):
                pl = m["pl"]
                m["pl"] = [v for j in range(0, len(pl), 8) if pl[j] not in unplain for v in pl[j:j + 8]]
            if m.get("pl"):
                # A plain lane's line position 1 where it is: the mod reads it 1/256 short (line_starts()).
                pl = m["pl"]
                for j in range(0, len(pl), 8):
                    for a in (0, 1):
                        dv = pl[j + 5 + a] - pl[j + 3 + a]
                        if abs(dv) == 255:
                            pl[j + 5 + a] = pl[j + 3 + a] + (256 if dv > 0 else -256)
            if k in truth and l is not None:
                where = {}
                for j, items in truth[k].items():
                    lane = runs.by_j[j]
                    for uid, pos, n in items:
                        where[uid] = point_at(lane, pos / 256)
                z = m.get("z", 0) == 1
                uid = item = x = y = 0
                flat = []
                for i in range(0, len(l) - 3, 4):
                    if z:
                        uid += l[i]; item += l[i + 1]; x += l[i + 2]; y += l[i + 3]
                    else:
                        uid, item, x, y = l[i:i + 4]
                    total += 1
                    if uid in where:
                        fixed += 1
                        x, y = round(where[uid][0] * 256), round(where[uid][1] * 256)
                    flat += [uid, item, x, y]
                if edges and m.get("part", 1) == 1 and "fr" in m:
                    sx, sy, sr = m["fx"] / 256, m["fy"] / 256, m["fr"]
                    ln = list(m.get("ln") or [])
                    st = list(m.get("st") or [])
                    by_j = truth[k]
                    common = collections.Counter(kind.values()).most_common(1)
                    for lane in edges:
                        if ring_of(lane, sx, sy) >= sr:
                            continue
                        items = by_j.get(lane.j, [])
                        ln += [lane.key, len(items)]
                        for uid, pos, n in items:
                            px, py = point_at(lane, pos / 256)
                            flat += [uid, kind.get(uid, common[0][0] if common else 1), round(px * 256), round(py * 256)]
                            if n > 1:
                                st += [uid, n]
                            added += 1
                    m["ln"] = ln
                    if st:
                        m["st"] = st
                m["l"] = flat
                m["z"] = 0
            out.write(json.dumps(m, separators=(",", ":")) + "\n")
    print("%s: %d of %d items sent in the recording put where the game had them; %d added on %d watched run lanes"
          " (%d plain lanes made watched)" % (name, fixed, total, added, len(edges), len(unplain)))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--rcon-port", type=int, default=rcon.PORT)
    common.add_argument("--password-file", default=str(rcon.DEFAULT_PASSWORD_FILE))
    common.add_argument("--script-output", default=str(ROOT / "server" / "data" / "script-output"))
    sv = sub.add_parser("survey", parents=[common])
    sv.add_argument("--at", default="-272,-14")
    sv.add_argument("--radius", type=float, default=24.0)
    sv.add_argument("--gap", type=float, default=3.0, help="seconds between the two looks")
    sv.add_argument("--min-length", type=int, default=4)
    sv.add_argument("--limit", type=int, default=60)
    rc = sub.add_parser("record", parents=[common])
    rc.add_argument("--out", required=True)
    rc.add_argument("--runs", required=True, help="x,y;x,y;...: a belt on each run")
    rc.add_argument("--at", default="-272,-14", help="where the bridge's character is held")
    rc.add_argument("--udp-port", type=int, default=34200)
    rc.add_argument("--client-port", type=int, default=0)
    rc.add_argument("--seconds", type=float, default=25.0)
    rc.add_argument("--warmup", type=float, default=20.0)
    rc.add_argument("--margin", type=int, default=16, help="tiles round the runs whose belts the replay indexes")
    rc.add_argument("--view", type=int, default=5, help="chunks subscribed round the character")
    rc.add_argument("--near", type=int, default=160)
    rc.add_argument("--cap", type=int, default=6000)
    rc.add_argument("--units", type=int, default=10000000)
    rc.add_argument("--no-runs", action="store_true", help="leave br out of the hello (every lane watched)")
    rc.add_argument("--from-start", action="store_true", help="record the game from before the client's hello (warm-up included)")
    cp = sub.add_parser("compare")
    cp.add_argument("dir")
    cp.add_argument("--tol", type=float, default=0.02, help="tiles: an offset over this differs")
    cp.add_argument("--examples", type=int, default=12)
    cp.add_argument("--lane-report", type=int, default=0, help="print this many examples for each lane that differs")
    cp.add_argument("--json", default="")
    cp.add_argument("--name", default="", help="compare model_<name>.json and drawn_<name>.json (the replay's --out)")
    cp.add_argument("--near-tier", type=int, default=16, help="rings: the mod checks watched lanes this far out or more less often")
    oc = sub.add_parser("oracle")
    oc.add_argument("dir")
    oc.add_argument("--edges", action="store_true", help="also send every watched lane of the recorded runs whole each update")
    oc.add_argument("--outside", action="store_true", help="and a plain lane whose lane in front leaves the square: watched, sent whole each update")
    a = ap.parse_args()
    if a.cmd == "oracle":
        oracle(a)
    elif a.cmd == "survey":
        survey(a)
    elif a.cmd == "record":
        record(a)
    else:
        compare(a)


if __name__ == "__main__":
    main()
