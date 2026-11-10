#!/usr/bin/env python3
"""Records every belt lane in a square of a running game every tick, for tools/belt_sim/sim.py to
check a simulation of Factorio's belts against: each lane's items (unique id, line position in
1/256, stack size, item), and once each lane's piece (entity, type, shape, direction, line index,
length) and where its line positions 0, half way and its end lie on the map.

    python tools/belt_sim/record.py --rcon-port 36292 --password-file <file> --script-output <dir>
        --area=-56,6,-24,38 --ticks 600 --out rec.json

Use a copy of a save: it uses /c. The recording is one JSON object: {"lanes": [...], "ticks": [[tick,
lane index, uid, pos, count, item, ...], ...]} (items only for lanes that hold any).
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
%(build)s
local area = {{%(x0)f, %(y0)f}, {%(x1)f, %(y1)f}}
local ents = s.find_entities_filtered({area = area, type = {"transport-belt", "underground-belt", "splitter",
  "loader", "loader-1x1", "linked-belt", "lane-splitter"}})
local lanes, meta = {}, {}
local items = {}
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
    if e.type == "splitter" then
      local flt = e.splitter_filter
      split = {e.splitter_input_priority, e.splitter_output_priority, flt and flt.name and flt.name.name or (flt and flt.name) or ""}
    end
    meta[#meta + 1] = {e.unit_number, e.name, e.type, shape, e.direction, i, math.floor(len * 256 + 0.5),
      at(0), at(len / 2), at(len), math.floor(speed * 256 + 0.5), e.status or 0, split}
  end
end
local rows = {}
local names, name_ids = {}, {}
local t_end = game.tick + %(ticks)d
script.on_nth_tick(1, function()
  if feed then feed(game.tick) end
  local row = {game.tick}
  for j, l in ipairs(lanes) do
    if l.valid then
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
  rows[#rows + 1] = "[" .. table.concat(row, ",") .. "]"
  if game.tick >= t_end then
    helpers.write_file("%(file)s", '{"lanes":' .. helpers.table_to_json(meta) .. ',"names":' .. helpers.table_to_json(names)
      .. ',"ticks":[' .. table.concat(rows, ",\n") .. ']}', false)
    script.on_nth_tick(1, nil)
  end
end)
rcon.print("recording " .. #lanes .. " lanes from " .. game.tick)
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--rcon-port", type=int, default=rcon.PORT)
    ap.add_argument("--password-file", default=str(rcon.DEFAULT_PASSWORD_FILE))
    ap.add_argument("--script-output", default=str(ROOT / "server" / "data" / "script-output"))
    ap.add_argument("--area", default="-56,6,-24,38")
    ap.add_argument("--ticks", type=int, default=600)
    ap.add_argument("--out", required=True)
    ap.add_argument("--surface", default="nauvis")
    ap.add_argument("--build", default="", help="a Lua file run first (with `s`, the surface): builds a scene to record, "
                    "and may set `feed` to a function(tick) called every tick before recording")
    a = ap.parse_args()
    pw = pathlib.Path(a.password_file).read_text().strip()
    x0, y0, x1, y1 = (float(v) for v in a.area.split(","))
    name = "belt_sim_%d.json" % int(time.time() * 1000)
    path = pathlib.Path(a.script_output) / name
    rcon.run("/sc rcon.print(1)", port=a.rcon_port, password=pw)
    build = pathlib.Path(a.build).read_text() if a.build else "local feed = nil"
    lua = LUA % dict(x0=x0, y0=y0, x1=x1, y1=y1, ticks=a.ticks, file=name, surface=a.surface, build=build)
    # (Sent as one line: comment lines dropped, or they would swallow the rest of it.)
    text = "/sc " + " ".join(l.strip() for l in lua.splitlines() if l.strip() and not l.strip().startswith("--"))
    print(rcon.run(text, port=a.rcon_port, password=pw, timeout=60).strip(), flush=True)
    deadline = time.time() + a.ticks / 60.0 * 20 + 120
    while time.time() < deadline:
        if path.exists():
            time.sleep(2.0)
            try:
                data = json.loads(path.read_text())
            except ValueError:
                continue
            pathlib.Path(a.out).write_text(json.dumps(data))
            print("wrote %s: %d lanes, %d ticks" % (a.out, len(data["lanes"]), len(data["ticks"])))
            path.unlink()
            return
        time.sleep(1.0)
    raise SystemExit("no recording from the game")


if __name__ == "__main__":
    main()
