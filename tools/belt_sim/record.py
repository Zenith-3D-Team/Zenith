#!/usr/bin/env python3
"""Records every belt lane in a square of a running game, for tools/belt_sim/sim.py to check a
simulation of Factorio's belts against: each lane's items (unique id, line position in 1/256, stack
size, item), and once each lane's piece (entity, type, shape, direction, line index, length) and where
its line positions 0, half way and its end lie on the map.

    python tools/belt_sim/record.py --rcon-port 36292 --password-file <file> --script-output <dir>
        --area=-56,6,-24,38 --ticks 600 --out rec.json [--sample tick|updates|N[@phase]]

--sample says which ticks get a row:
  tick     every tick (the default, as it always was: sim.py steps a tick at a time and needs them all).
  updates  only the ticks the bridge sends a belt update on (`bs`/`bi`: its `bi` job ran that tick), read
           from the bridge's own storage through a remote interface this script adds to the bridge mod's
           Lua state for the recording (`f3d_rec`, removed after). A replay of a `bs` capture
           (client/tests/belt_bs_replay.gd) compares only at those ticks, and reading every lane every
           tick is heavy enough to slow the bridge (the client's Hold 60 UPS then stretches its updates).
  N[@phase] every N'th tick, on ticks where tick % N == phase (default phase 1: the bridge's `bi` job
           runs on such ticks at every rate level with its default interval of 6, so `6` catches every
           update without asking the bridge).

Use a copy of a save: it uses /c. The recording is one JSON object: {"lanes": [...], "ticks": [[tick,
lane index, uid, pos, count, item, ...], ...], "names": [...]} (items only for lanes that hold any),
plus "sample" (what --sample was), "rows" (how many ticks) and, with updates, "bridge_ticks" (the
bridge's update ticks seen while recording). Rows are written to the script-output file as they are
made (a few at a time), not built into one string at the end.
"""

import argparse
import pathlib
import shutil
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import rcon  # noqa: E402

# The bridge's last `bi` run (its update tick), from the bridge mod's own Lua state.
REMOTE = r"""
if remote.interfaces["f3d_rec"] then remote.remove_interface("f3d_rec") end
remote.add_interface("f3d_rec", {bi_last = function()
  local s = storage.f3d
  local j = s and s.rate_jobs and s.rate_jobs.bi
  return j and j.last or -1
end})
rcon.print("f3d_rec added")
"""
REMOTE_OFF = 'if remote.interfaces["f3d_rec"] then remote.remove_interface("f3d_rec") end'

LUA = r"""
local s = game.get_surface("%(surface)s")
%(build)s
local area = {{%(x0)f, %(y0)f}, {%(x1)f, %(y1)f}}
local ents = s.find_entities_filtered({area = area, type = {"transport-belt", "underground-belt", "splitter",
  "loader", "loader-1x1", "linked-belt", "lane-splitter"}})
local lanes, meta = {}, {}
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
  end
end
local file = "%(file)s"
local mode, every, phase = "%(mode)s", %(every)d, %(phase)d
local bridge = nil
if mode == "updates" then
  if not remote.interfaces["f3d_rec"] then
    rcon.print("no f3d_rec interface: is the bridge mod loaded?")
    return
  end
  bridge = function() return remote.call("f3d_rec", "bi_last") end
end
local names, name_ids = {}, {}
local buf, nrows, wrote = {}, 0, false
local bticks = {}
local function flush()
  if #buf > 0 then
    helpers.write_file(file, (wrote and ",\n" or "") .. table.concat(buf, ",\n"), true)
    wrote, buf = true, {}
  end
end
helpers.write_file(file, '{"sample":"%(sample)s","lanes":' .. helpers.table_to_json(meta) .. ',"ticks":[\n', false)
local t_end = game.tick + %(ticks)d
script.on_nth_tick(1, function()
  if feed then feed(game.tick) end
  local t = game.tick
  local take
  if mode == "tick" then take = true
  elseif mode == "every" then take = t %% every == phase %% every
  else take = bridge() == t end
  if take then
    if bridge then bticks[#bticks + 1] = t end
    local row = {t}
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
    buf[#buf + 1] = "[" .. table.concat(row, ",") .. "]"
    nrows = nrows + 1
    if #buf >= 20 then flush() end
  end
  if t >= t_end then
    flush()
    helpers.write_file(file, '\n],"names":' .. helpers.table_to_json(names) .. ',"rows":' .. nrows
      .. (bridge and (',"bridge_ticks":[' .. table.concat(bticks, ",") .. ']') or "") .. '}', true)
    helpers.write_file(file .. ".done", tostring(nrows), false)
    script.on_nth_tick(1, nil)
  end
end)
rcon.print("recording " .. #lanes .. " lanes from " .. game.tick .. " (" .. mode .. ")")
"""


def parse_sample(v):
    """--sample: ("tick", 1, 0), ("updates", 0, 0) or ("every", N, phase)."""
    if v in ("tick", "updates"):
        return v, 1, 0
    n, _, ph = v.partition("@")
    n = int(n)
    if n <= 1:
        return "tick", 1, 0
    return "every", n, int(ph) if ph else 1


def one_line(lua):
    # (Sent as one line: comment lines dropped, or they would swallow the rest of it.)
    return " ".join(l.strip() for l in lua.splitlines() if l.strip() and not l.strip().startswith("--"))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--rcon-port", type=int, default=rcon.PORT)
    ap.add_argument("--password-file", default=str(rcon.DEFAULT_PASSWORD_FILE))
    ap.add_argument("--script-output", default=str(ROOT / "server" / "data" / "script-output"))
    ap.add_argument("--area", default="-56,6,-24,38")
    ap.add_argument("--ticks", type=int, default=600)
    ap.add_argument("--out", required=True)
    ap.add_argument("--surface", default="nauvis")
    ap.add_argument("--sample", default="tick", help="tick (every tick, the default), updates (the bridge's update ticks), "
                    "or N[@phase] (every N'th tick)")
    ap.add_argument("--build", default="", help="a Lua file run first (with `s`, the surface): builds a scene to record, "
                    "and may set `feed` to a function(tick) called every tick before recording")
    a = ap.parse_args()
    mode, every, phase = parse_sample(a.sample)
    pw = pathlib.Path(a.password_file).read_text().strip()
    x0, y0, x1, y1 = (float(v) for v in a.area.split(","))
    name = "belt_sim_%d.json" % int(time.time() * 1000)
    path = pathlib.Path(a.script_output) / name
    done = pathlib.Path(a.script_output) / (name + ".done")
    rcon.run("/sc rcon.print(1)", port=a.rcon_port, password=pw)
    if mode == "updates":
        print(rcon.run("/sc __factorio-3d-bridge__ " + one_line(REMOTE), port=a.rcon_port, password=pw, timeout=30).strip(), flush=True)
    build = pathlib.Path(a.build).read_text() if a.build else "local feed = nil"
    lua = LUA % dict(x0=x0, y0=y0, x1=x1, y1=y1, ticks=a.ticks, file=name, surface=a.surface, build=build,
                     mode=mode, every=every, phase=phase, sample=a.sample)
    try:
        print(rcon.run("/sc " + one_line(lua), port=a.rcon_port, password=pw, timeout=60).strip(), flush=True)
        deadline = time.time() + a.ticks / 60.0 * 20 + 120
        while time.time() < deadline:
            if done.exists():
                time.sleep(0.5)
                rows = int(done.read_text().strip() or 0)
                out = pathlib.Path(a.out)
                out.unlink(missing_ok=True)
                shutil.move(str(path), str(out))
                done.unlink()
                print("wrote %s: %d ticks (%s)" % (a.out, rows, a.sample))
                return
            time.sleep(0.5)
        raise SystemExit("no recording from the game")
    finally:
        if mode == "updates":
            try:
                rcon.run("/sc __factorio-3d-bridge__ " + REMOTE_OFF, port=a.rcon_port, password=pw, timeout=10)
            except OSError:
                pass


if __name__ == "__main__":
    main()
