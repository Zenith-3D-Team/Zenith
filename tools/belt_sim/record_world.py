#!/usr/bin/env python3
"""Records what tools/bs_offline.py needs besides a belt recording (record.py) to play the bridge's
belt_sim.lua against a game offline: the belts round a square once (unit number, name, type, shape,
place, direction, speed, neighbours, an underground's other end, circuit connection, status, a
splitter's settings, each line's length and where its line positions 0, half way and its end lie), the
inserters and mining drills there (their pickup and drop targets), and over one or more windows of
ticks every change of an inserter's hand (how many it holds) and a drill's mining progress, and of a
circuit-connected belt's status. At each window's first tick the front item of every lane too, to
check that a recording made in another run of the same save is of the same game (Factorio is
deterministic: a copy of a save played to the same tick holds the same items).

    python tools/belt_sim/record_world.py --rcon-port 35062 --password-file <file> --script-output <dir>
        --area=-310,-60,40,40 --window 23029400:23030400 [--window ...] [--speed 8] --out world.json

Use a copy of a save: it uses /c and sets game.speed while it waits (back to 1 at the end).
The file: {"area", "belts": [...], "actors": [...], "targets": [...], "windows": [{"from", "to",
"snap": [[unit, line, count, front uid], ...], "acts": [[tick, actor index, value, ...], ...],
"bst": [[tick, belt index, status, ...], ...]}]}. Values: an inserter's held count, a drill's
(mining_progress + bonus_mining_progress) * 10000 rounded.
"""

import argparse
import json
import pathlib
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import rcon  # noqa: E402

LUA = r"""
local s = game.get_surface("%(surface)s")
local area = {{%(x0)f, %(y0)f}, {%(x1)f, %(y1)f}}
local windows = {%(windows)s}
local speed = %(speed)f
local BELT = {"transport-belt", "underground-belt", "splitter", "loader", "loader-1x1", "linked-belt", "lane-splitter"}
local function fx(v) return math.floor(v * 256 + 0.5) end
local function pos(p) return {fx(p.x), fx(p.y)} end
local function unit_of(e) return (e and e.valid and e.unit_number) or 0 end
local belts, bents, actors, aents, targets, tseen = {}, {}, {}, {}, {}, {}
local cbelts = {}
local function target(e)
  if not (e and e.valid and e.unit_number) then return 0 end
  if not tseen[e.unit_number] then
    tseen[e.unit_number] = true
    targets[#targets + 1] = {e.unit_number, e.name, e.type, pos(e.position)}
  end
  return e.unit_number
end
local function statics()
  for _, e in pairs(s.find_entities_filtered({area = area, type = BELT})) do
    local r = {u = e.unit_number, n = e.name, t = e.type, p = pos(e.position), d = e.direction,
      v = fx(e.prototype.belt_speed), st = e.status or 0, cb = 0, i = {}, o = {}, un = 0, sh = ""}
    if e.type == "transport-belt" then r.sh = e.belt_shape
    elseif e.type == "underground-belt" then r.sh = e.belt_to_ground_type
      local ok, other = pcall(function() return e.underground_belt_neighbour end)
      if ok then r.un = unit_of(other) end
    elseif e.type == "loader" or e.type == "loader-1x1" then r.sh = e.loader_type end
    local ok, nb = pcall(function() return e.belt_neighbours end)
    if ok and nb then
      for _, x in pairs(nb.inputs or {}) do r.i[#r.i + 1] = unit_of(x) end
      for _, x in pairs(nb.outputs or {}) do r.o[#r.o + 1] = unit_of(x) end
    end
    local cok, cb = pcall(function() return e.get_control_behavior() end)
    if cok and cb then r.cb = 1 cbelts[#cbelts + 1] = {#belts + 1, e} end
    if e.type == "splitter" or e.type == "lane-splitter" then
      local flt = e.splitter_filter
      r.sp = {e.splitter_input_priority, e.splitter_output_priority, flt and flt.name and (type(flt.name) == "table" and flt.name.name or flt.name) or ""}
    end
    r.l = {}
    for i = 1, e.get_max_transport_line_index() do
      local l = e.get_transport_line(i)
      local len = l.line_length
      r.l[i] = {fx(len), pos(l.get_line_item_position(0)), pos(l.get_line_item_position(len / 2)), pos(l.get_line_item_position(len))}
    end
    belts[#belts + 1] = r
    bents[#bents + 1] = e
  end
  for _, e in pairs(s.find_entities_filtered({area = area, type = {"inserter", "mining-drill"}})) do
    local r = {u = e.unit_number, n = e.name, t = e.type, p = pos(e.position), d = e.direction, pk = 0, dr = target(e.drop_target)}
    if e.type == "inserter" then r.pk = target(e.pickup_target) end
    actors[#actors + 1] = r
    aents[#aents + 1] = e
  end
end
local function val(e)
  if e.type == "inserter" then
    local st = e.held_stack
    return st.valid_for_read and st.count or 0
  end
  return math.floor((e.mining_progress + e.bonus_mining_progress) * 10000 + 0.5)
end
local out, wi, cur, last, lastst = {}, 1, nil, {}, {}
game.speed = speed
script.on_nth_tick(1, function()
  local w = windows[wi]
  if not w then return end
  local t = game.tick
  if t < w[1] then
    if t >= w[1] - 120 then game.speed = 1 end
    return
  end
  if not cur then
    if #belts == 0 then statics() end
    local snap = {}
    for _, e in ipairs(bents) do
      if e.valid then
        for i = 1, e.get_max_transport_line_index() do
          local c = e.get_transport_line(i).get_detailed_contents()
          snap[#snap + 1] = {e.unit_number, i, #c, c[1] and c[1].unique_id or 0}
        end
      end
    end
    cur = {from = w[1], to = w[2], snap = snap, acts = {}, bst = {}}
    last, lastst = {}, {}
  end
  local row = {t}
  for j, e in ipairs(aents) do
    if e.valid then
      local v = val(e)
      if v ~= last[j] then row[#row + 1] = j row[#row + 1] = v last[j] = v end
    end
  end
  if #row > 1 then cur.acts[#cur.acts + 1] = row end
  local srow = {t}
  for _, c in ipairs(cbelts) do
    local e = c[2]
    if e.valid then
      local v = e.status or 0
      if v ~= lastst[c[1]] then srow[#srow + 1] = c[1] srow[#srow + 1] = v lastst[c[1]] = v end
    end
  end
  if #srow > 1 then cur.bst[#cur.bst + 1] = srow end
  if t >= w[2] then
    out[#out + 1] = cur
    cur = nil
    wi = wi + 1
    if windows[wi] then game.speed = speed else
      game.speed = 1
      helpers.write_file("%(file)s", helpers.table_to_json({area = area, belts = belts, actors = actors, targets = targets, windows = out}), false)
      script.on_nth_tick(1, nil)
    end
  end
end)
rcon.print("recording the world from tick " .. game.tick .. ": " .. #windows .. " window(s)")
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--rcon-port", type=int, default=rcon.PORT)
    ap.add_argument("--password-file", default=str(rcon.DEFAULT_PASSWORD_FILE))
    ap.add_argument("--script-output", default=str(ROOT / "server" / "data" / "script-output"))
    ap.add_argument("--area", required=True, help="x0,y0,x1,y1")
    ap.add_argument("--window", action="append", required=True, help="from:to (ticks), in order; repeatable")
    ap.add_argument("--speed", type=float, default=8.0, help="game.speed while waiting for a window")
    ap.add_argument("--out", required=True)
    ap.add_argument("--surface", default="nauvis")
    ap.add_argument("--timeout", type=float, default=1800)
    a = ap.parse_args()
    pw = pathlib.Path(a.password_file).read_text().strip()
    x0, y0, x1, y1 = (float(v) for v in a.area.split(","))
    wins = [tuple(int(v) for v in w.split(":")) for w in a.window]
    name = "belt_world_%d.json" % int(time.time() * 1000)
    path = pathlib.Path(a.script_output) / name
    now = rcon.run("/sc rcon.print(game.tick)", port=a.rcon_port, password=pw).strip()
    print("game at tick %s" % now, flush=True)
    if now.isdigit() and int(now) > wins[0][0]:
        raise SystemExit("the game is past the first window's start (%s > %d)" % (now, wins[0][0]))
    lua = LUA % dict(x0=x0, y0=y0, x1=x1, y1=y1, file=name, surface=a.surface, speed=a.speed,
                     windows=", ".join("{%d, %d}" % w for w in wins))
    text = "/sc " + " ".join(l.strip() for l in lua.splitlines() if l.strip() and not l.strip().startswith("--"))
    print(rcon.run(text, port=a.rcon_port, password=pw, timeout=120).strip(), flush=True)
    deadline = time.time() + a.timeout
    while time.time() < deadline:
        if path.exists():
            time.sleep(2.0)
            try:
                data = json.loads(path.read_text())
            except ValueError:
                continue
            pathlib.Path(a.out).write_text(json.dumps(data, separators=(",", ":")))
            print("wrote %s: %d belts, %d inserters and drills, %d windows" % (a.out, len(data["belts"]), len(data["actors"]),
                                                                               len(data["windows"])))
            path.unlink()
            return
        time.sleep(2.0)
    raise SystemExit("no world recording from the game")


if __name__ == "__main__":
    main()
