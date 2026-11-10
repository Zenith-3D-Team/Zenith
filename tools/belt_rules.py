#!/usr/bin/env python3
"""Factorio's belt rules, measured black-box in the running game (docs/BELT-RULES.md): small rows of
belts built on a surface of their own (lab tiles, nothing else there), every item on their lanes
recorded every tick (unique id, line position in 1/256, stack size), the numbers worked out here.

    python tools/belt_rules.py [--rcon-port 34198] [--out rules.json] lengths speed gap line sideload splitter inserter
    python tools/belt_rules.py all

lengths   every lane's length and where it runs (straight, both curves, undergrounds, splitter)
speed     one item on a run of each tier: the step a tick, whether it is constant, ticks a tile
gap       a lane fed every tick: the gap between items, alone and in stacks
line      a long full run whose front is taken one item at a time: does it move as one line, where
          items bunch up when the front blocks, how a gap travels back
sideload  a belt fed from the side: where items join, which lane, when they wait
splitter  which output each item takes, with one output blocked, with an output priority
inserter  an inserter taking from a moving belt and one putting onto it: where, and when
compress  a run whose gaps no belt speed divides, closing up: which items move each tick, how far
under     every underground gap on every tier: the hidden lines' lengths
tiers     yellow belts into express ones: steps a tick on each, segment lengths
disabled  a belt switched off by a circuit condition: what stops

Use a copy of a save (it uses /c and makes a surface, zenith-belt-rules).
"""

import argparse
import collections
import json
import pathlib
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import rcon  # noqa: E402

TIERS = ["transport-belt", "fast-transport-belt", "express-transport-belt", "turbo-transport-belt"]
UNDER = {"transport-belt": "underground-belt", "fast-transport-belt": "fast-underground-belt",
         "express-transport-belt": "express-underground-belt", "turbo-transport-belt": "turbo-underground-belt"}
SPLIT = {"transport-belt": "splitter", "fast-transport-belt": "fast-splitter",
         "express-transport-belt": "express-splitter", "turbo-transport-belt": "turbo-splitter"}

# The surface, cleared round an area; put(name, x, y, dir, extra) builds; LINES and a recorder that writes
# each tick's items on them (lines[j] = LuaTransportLine) to <file> when the experiment's ticks are done.
PRELUDE = r"""
local s = game.get_surface("zenith-belt-rules")
if not s then
  s = game.create_surface("zenith-belt-rules", {width = 512, height = 512})
  s.generate_with_lab_tiles = true
  s.always_day = true
end
s.request_to_generate_chunks({0, 0}, 6)
s.force_generate_chunk_requests()
local f = game.forces.player
for _, e in pairs(s.find_entities_filtered({area = {{-200, -200}, {200, 200}}})) do e.destroy() end
local N, E, S, W = defines.direction.north, defines.direction.east, defines.direction.south, defines.direction.west
local function put(name, x, y, d, extra)
  local t = {name = name, position = {x, y}, direction = d, force = f}
  if extra then for k, v in pairs(extra) do t[k] = v end end
  local e = s.create_entity(t)
  if not e then error("could not place " .. name .. " at " .. x .. "," .. y) end
  return e
end
local lines, names = {}, {}
local function watch(e, label)
  for i = 1, e.get_max_transport_line_index() do
    lines[#lines + 1] = e.get_transport_line(i)
    names[#names + 1] = {label, i, e.name, e.type, e.position.x, e.position.y, e.direction}
  end
end
local rows = {}
local function record()
  local row = {}
  for j, l in ipairs(lines) do
    local c = l.get_detailed_contents()
    if #c > 0 then
      row[#row + 1] = j
      row[#row + 1] = #c
      for _, it in ipairs(c) do
        row[#row + 1] = it.unique_id
        row[#row + 1] = math.floor(it.position * 256 + 0.5)
        row[#row + 1] = it.stack.count
      end
    end
  end
  rows[#rows + 1] = '{"t":' .. game.tick .. ',"l":[' .. table.concat(row, ",") .. ']}'
end
local extra_out = {}
local function finish(file)
  local head = helpers.table_to_json({names = names, extra = extra_out})
  helpers.write_file(file, head .. "\n" .. table.concat(rows, "\n") .. "\n", false)
end
"""

LENGTHS = r"""
local out = {}
for k, tier in ipairs(TIERS) do
  local y = (k - 1) * 12
  local b = put(tier, 0.5, y + 0.5, E)
  watch(b, tier .. " straight")
  put(tier, 2.5, y + 0.5, E)
  local c = put(tier, 3.5, y + 0.5, N)
  watch(c, tier .. " curve " .. c.belt_shape)
  put(tier, 5.5, y + 0.5, E)
  local c2 = put(tier, 6.5, y + 0.5, S)
  watch(c2, tier .. " curve " .. c2.belt_shape)
  local ui = put(UNDER[tier], 0.5, y + 4.5, E, {type = "input"})
  local uo = put(UNDER[tier], 4.5, y + 4.5, E, {type = "output"})
  watch(ui, tier .. " underground in (gap 3)")
  watch(uo, tier .. " underground out (gap 3)")
  local sp = put(SPLIT[tier], 8.5, y + 5, E)
  watch(sp, tier .. " splitter")
end
for j, l in ipairs(lines) do
  local nm = names[j]
  local len = l.line_length
  local pts = {}
  for q = 0, 8 do
    local p = l.get_line_item_position(len * q / 8)
    pts[#pts + 1] = {math.floor((p.x - nm[5]) * 256 + 0.5), math.floor((p.y - nm[6]) * 256 + 0.5)}
  end
  local ok, seg = pcall(function() return l.total_segment_length end)
  out[#out + 1] = {nm[1], nm[2], len, ok and seg or -1, pts}
end
extra_out.lengths = out
record()
finish("%(file)s")
rcon.print("lengths " .. #out)
"""

# One item on a 20-belt run of each tier (facing east, nothing in front), on lane 1 and 2.
SPEED = r"""
local runs = {}
for k, tier in ipairs(TIERS) do
  local y = (k - 1) * 4 + 0.5
  local list = {}
  for x = 0, 19 do list[#list + 1] = put(tier, x + 0.5, y, E) end
  for m = #list, 1, -1 do watch(list[m], tier .. " " .. (#list - m)) end
  runs[#runs + 1] = list
end
local t0 = game.tick + 2
script.on_nth_tick(1, function()
  local t = game.tick
  if t == t0 then
    for _, list in ipairs(runs) do
      list[1].get_transport_line(1).insert_at_back({name = "iron-plate", count = 1})
      list[1].get_transport_line(2).insert_at(0.5, {name = "copper-plate", count = 1})
    end
  end
  if t >= t0 then record() end
  if t == t0 + %(ticks)d then finish("%(file)s") script.on_nth_tick(1, nil) end
end)
rcon.print("speed from " .. t0)
"""

# A lane fed at its back whenever it can be (every tick), 16 belts, nothing in front: the gap fed, the
# gap where it backs up; lane 2 in stacks of 4 (belt_stack_size 4).
GAP = r"""
local runs = {}
for k, tier in ipairs({"transport-belt", "turbo-transport-belt"}) do
  local y = (k - 1) * 4 + 0.5
  local list = {}
  for x = 0, 15 do list[#list + 1] = put(tier, x + 0.5, y, E) end
  for m = #list, 1, -1 do watch(list[m], tier .. " " .. (#list - m)) end
  runs[#runs + 1] = list
end
local t0 = game.tick + 2
local fed = {}
script.on_nth_tick(1, function()
  local t = game.tick
  if t >= t0 then
    for _, list in ipairs(runs) do
      local l1, l2 = list[1].get_transport_line(1), list[1].get_transport_line(2)
      if l1.can_insert_at_back() then l1.insert_at_back({name = "iron-plate", count = 1}) fed[#fed + 1] = {t, 1} end
      if l2.can_insert_at_back() then l2.insert_at_back({name = "iron-plate", count = 4}, 4) fed[#fed + 1] = {t, 2} end
    end
    record()
  end
  if t == t0 + %(ticks)d then extra_out.fed = fed finish("%(file)s") script.on_nth_tick(1, nil) end
end)
rcon.print("gap from " .. t0)
"""

# A 24-belt yellow run filled end to end (nothing in front: blocked at its front), fed at its back
# when there is room. Every 40 ticks its front item is taken (a slow consumer): which items move, on
# which ticks. Lane 2 starts sparse (an item every half tile) and bunches up at the front.
LINE = r"""
local list = {}
for x = 0, 23 do list[#list + 1] = put("%(tier)s", x + 0.5, 0.5, E) end
for m = #list, 1, -1 do watch(list[m], "%(tier)s " .. (#list - m)) end
for _, b in ipairs(list) do
  local l1 = b.get_transport_line(1)
  for q = 0, 3 do l1.insert_at(q * 0.25, {name = "iron-plate", count = 1}) end
  b.get_transport_line(2).insert_at(0.5, {name = "copper-plate", count = 1})
end
local segs = {}
for m, b in ipairs(list) do
  local l = b.get_transport_line(1)
  local ok, v = pcall(function() return l.total_segment_length end)
  segs[#segs + 1] = ok and v or -1
end
extra_out.segment_lengths = segs
local front = list[#list].get_transport_line(1)
local t0 = game.tick + 2
local taken = {}
script.on_nth_tick(1, function()
  local t = game.tick
  if t >= t0 then
    if (t - t0) %% 40 == 20 then
      local c = front.get_detailed_contents()
      local best = nil
      for _, it in ipairs(c) do if not best or it.position < best.position then best = it end end
      if best then
        front.remove_item({name = best.stack.name, count = 1})
        taken[#taken + 1] = {t, best.unique_id, math.floor(best.position * 256 + 0.5)}
      end
    end
    local back = list[1].get_transport_line(1)
    if back.can_insert_at_back() then back.insert_at_back({name = "iron-plate", count = 1}) end
    record()
  end
  if t == t0 + %(ticks)d then extra_out.taken = taken finish("%(file)s") script.on_nth_tick(1, nil) end
end)
rcon.print("line from " .. t0)
"""

# A main belt (12 belts, east) side-loaded at its 6th belt by a belt coming down from the north; both fed
# every tick they can be; the main belt's front taken off as it comes (free flowing), then from tick
# FREE on blocked (nothing taken) so it backs up.
SIDELOAD = r"""
local main = {}
for x = 0, 11 do main[#main + 1] = put("%(tier)s", x + 0.5, 0.5, E) end
local side = {}
for y = -6, -1 do side[#side + 1] = put("%(tier)s", 5.5, y + 0.5, S) end
for m = #main, 1, -1 do watch(main[m], "main " .. (#main - m)) end
for m = #side, 1, -1 do watch(side[m], "side " .. (#side - m)) end
local t0 = game.tick + 2
local front = main[#main]
local every = %(every)d
script.on_nth_tick(1, function()
  local t = game.tick
  if t >= t0 then
    for i = 1, 2 do
      local sl = side[1].get_transport_line(i)
      if sl.can_insert_at_back() then sl.insert_at_back({name = "copper-plate", count = 1}) end
      if every > 0 and (t - t0) %% every == 0 then
        local ml = main[1].get_transport_line(i)
        if ml.can_insert_at_back() then ml.insert_at_back({name = "iron-plate", count = 1}) end
      end
      if t - t0 < %(free)d then
        local fl = front.get_transport_line(i)
        for _, it in ipairs(fl.get_detailed_contents()) do
          if it.position < 0.05 then fl.remove_item({name = it.stack.name, count = it.stack.count}) end
        end
      end
    end
    record()
  end
  if t == t0 + %(ticks)d then finish("%(file)s") script.on_nth_tick(1, nil) end
end)
rcon.print("sideload from " .. t0)
"""

# One input belt (6 belts) into a splitter, two output belts (8 each), free flowing (their fronts taken
# off), both lanes fed every tick. From tick BLOCK the left output's front is no longer taken (it backs
# up); from tick PRIO the splitter's output priority is left.
SPLITTER = r"""
local inp = {}
for x = 0, 5 do inp[#inp + 1] = put("%(tier)s", x + 0.5, 0.5, E) end
local sp = put("%(split)s", 6.5, 1, E)
local left, right = {}, {}
for x = 7, 14 do left[#left + 1] = put("%(tier)s", x + 0.5, 0.5, E) right[#right + 1] = put("%(tier)s", x + 0.5, 1.5, E) end
watch(inp[#inp], "in")
watch(sp, "splitter")
watch(left[1], "left 0")
watch(right[1], "right 0")
watch(left[#left], "left end")
watch(right[#right], "right end")
local t0 = game.tick + 2
local fed = {}
script.on_nth_tick(1, function()
  local t = game.tick
  if t >= t0 then
    if t - t0 == %(prio)d then sp.splitter_output_priority = "left" end
    if t - t0 == %(unprio)d then sp.splitter_output_priority = "none" end
    for i = 1, 2 do
      local l = inp[1].get_transport_line(i)
      if l.can_insert_at_back() then l.insert_at_back({name = i == 1 and "iron-plate" or "copper-plate", count = 1}) end
      for side, list in pairs({left = left, right = right}) do
        if not (side == "left" and t - t0 >= %(block)d and t - t0 < %(unblock)d) then
          local fl = list[#list].get_transport_line(i)
          for _, it in ipairs(fl.get_detailed_contents()) do
            if it.position < 0.05 then fl.remove_item({name = it.stack.name, count = it.stack.count}) end
          end
        end
      end
    end
    record()
  end
  if t == t0 + %(ticks)d then finish("%(file)s") script.on_nth_tick(1, nil) end
end)
rcon.print("splitter from " .. t0)
"""

# A 10-belt run (east) fed on both lanes from its back every 8 ticks (sparse, moving), its front taken
# off; an inserter north of belt 4 takes from it into a chest; one north of belt 7 puts iron gear wheels
# from an infinity chest onto it. Powered by an electric energy interface. Each tick: the lanes, and
# each inserter's hand.
INSERTER = r"""
local run = {}
for x = 0, 9 do run[#run + 1] = put("%(tier)s", x + 0.5, 0.5, E) end
for m = #run, 1, -1 do watch(run[m], "run " .. (#run - m)) end
local eei = put("electric-energy-interface", 4, -6, N)
eei.power_production = 1e9
eei.electric_buffer_size = 1e9
put("medium-electric-pole", 5.5, -2.5, N)
local take = put("%(inserter)s", 4.5, -0.5, S)
local chest = put("wooden-chest", 4.5, -1.5, N)
local give = put("%(inserter)s", 7.5, -0.5, N)
local src = put("infinity-chest", 7.5, -1.5, N)
src.set_infinity_container_filter(1, {name = "iron-gear-wheel", count = 50, mode = "exactly"})
extra_out.inserters = {
  take = {take.pickup_position.x, take.pickup_position.y, take.drop_position.x, take.drop_position.y, take.direction},
  give = {give.pickup_position.x, give.pickup_position.y, give.drop_position.x, give.drop_position.y, give.direction}}
local t0 = game.tick + 2
local hands = {}
script.on_nth_tick(1, function()
  local t = game.tick
  if t >= t0 then
    if (t - t0) %% %(every)d == 0 then
      for i = 1, 2 do
        local l = run[1].get_transport_line(i)
        if l.can_insert_at_back() then l.insert_at_back({name = "iron-plate", count = 1}) end
      end
    end
    for i = 1, 2 do
      local fl = run[#run].get_transport_line(i)
      for _, it in ipairs(fl.get_detailed_contents()) do
        if it.position < 0.05 then fl.remove_item({name = it.stack.name, count = it.stack.count}) end
      end
    end
    local h1 = take.held_stack
    local h2 = give.held_stack
    hands[#hands + 1] = {t, h1.valid_for_read and h1.count or 0, h2.valid_for_read and h2.count or 0,
      take.held_stack_position.x, take.held_stack_position.y, give.held_stack_position.x, give.held_stack_position.y}
    record()
  end
  if t == t0 + %(ticks)d then extra_out.hands = hands finish("%(file)s") script.on_nth_tick(1, nil) end
end)
rcon.print("inserter from " .. t0)
"""


class Rec:
    """A recording: lane names and every tick's items {tick: {lane j: [(uid, pos, count)]}}."""

    def __init__(self, text):
        lines = text.splitlines()
        head = json.loads(lines[0])
        self.names = head["names"]
        self.extra = head.get("extra", {})
        self.ticks = {}
        for line in lines[1:]:
            if not line.strip():
                continue
            r = json.loads(line)
            lanes = {}
            l = r["l"]
            k = 0
            while k < len(l):
                j, n = l[k], l[k + 1]
                lanes[j] = [(l[k + 2 + 3 * q], l[k + 3 + 3 * q], l[k + 4 + 3 * q]) for q in range(n)]
                k += 2 + 3 * n
            self.ticks[r["t"]] = lanes
        self.by_label = {}
        for j, nm in enumerate(self.names, start=1):
            self.by_label[(nm[0], nm[1])] = j

    def where(self, t):
        """uid -> (lane j, pos, count) at tick t."""
        out = {}
        for j, items in self.ticks.get(t, {}).items():
            for uid, p, n in items:
                out[uid] = (j, p, n)
        return out


class Lab:
    def __init__(self, args):
        self.args = args
        self.password = pathlib.Path(args.password_file).read_text().strip()
        self.so = pathlib.Path(args.script_output)
        self.cmd("/sc rcon.print(1)")
        self.cmd("/sc rcon.print(1)")

    def cmd(self, c, timeout=60.0):
        return rcon.run(c, port=self.args.rcon_port, password=self.password, timeout=timeout)

    def run(self, body, ticks=0, **kw):
        name = "belt_rules_%d.json" % int(time.time() * 1000)
        path = self.so / name
        if path.exists():
            path.unlink()
        tiers = "local TIERS = {%s} local UNDER = {%s} local SPLIT = {%s}" % (
            ", ".join('"%s"' % t for t in TIERS), ", ".join('["%s"] = "%s"' % kv for kv in UNDER.items()),
            ", ".join('["%s"] = "%s"' % kv for kv in SPLIT.items()))
        lua = tiers + "\n" + PRELUDE + (body % dict(kw, file=name, ticks=ticks))
        text = "/sc " + " ".join(l.strip() for l in lua.splitlines() if l.strip() and not l.strip().startswith("--"))
        print("  " + self.cmd(text).strip(), flush=True)
        deadline = time.time() + ticks / 60.0 * 10 + 60
        while time.time() < deadline:
            if path.exists():
                time.sleep(0.5)
                try:
                    return Rec(path.read_text())
                except ValueError:
                    pass
            time.sleep(0.5)
        raise RuntimeError("no recording from the game: " + name)


# A 12-belt run going east, nothing in front: lane 1 starts with an item every 100 steps, lane 2
# every 70 (gaps no belt speed divides), so the line closes up where gaps aren't whole steps.
COMPRESS = r"""
local list = {}
for x = 0, 11 do list[#list + 1] = put("%(tier)s", x + 0.5, 0.5, E) end
for m = #list, 1, -1 do watch(list[m], "%(tier)s " .. (#list - m)) end
for m, b in ipairs(list) do
  local back = (#list - m) * 256
  for j = 0, 40 do
    local p = j * 100 - back
    if p >= 0 and p < 256 then b.get_transport_line(1).insert_at(p / 256, {name = "iron-plate", count = 1}) end
    local p2 = j * 70 - back
    if p2 >= 0 and p2 < 256 then b.get_transport_line(2).insert_at(p2 / 256, {name = "copper-plate", count = 1}) end
  end
end
local t0 = game.tick + 1
script.on_nth_tick(1, function()
  local t = game.tick
  if t >= t0 then record() end
  if t == t0 + %(ticks)d then finish("%(file)s") script.on_nth_tick(1, nil) end
end)
rcon.print("compress from " .. t0)
"""

# Every underground pair of every tier, each gap its belt allows: the hidden lines' lengths.
UNDERS = r"""
local out = {}
for k, tier in ipairs(TIERS) do
  local u = UNDER[tier]
  local reach = prototypes.entity[u].max_underground_distance
  for g = 0, reach - 1 do
    local y = (k - 1) * 40 + g * 3
    local ui = put(u, 0.5, y + 0.5, E, {type = "input"})
    local uo = put(u, g + 1.5, y + 0.5, E, {type = "output"})
    local l = {}
    for i = 1, ui.get_max_transport_line_index() do
      local ln = ui.get_transport_line(i)
      local ok, seg = pcall(function() return ln.total_segment_length end)
      l[#l + 1] = {math.floor(ln.line_length * 256 + 0.5), ok and seg or -1}
    end
    out[#out + 1] = {u, g, reach, l}
    ui.destroy() uo.destroy()
  end
end
extra_out.unders = out
record()
finish("%(file)s")
rcon.print("unders " .. #out)
"""

# 6 yellow belts into 6 express belts (east), fed at the back every tick: each item's step a tick on
# each part, and the segment lengths both report.
TIERS2 = r"""
local list = {}
for x = 0, 5 do list[#list + 1] = put("transport-belt", x + 0.5, 0.5, E) end
for x = 6, 11 do list[#list + 1] = put("express-transport-belt", x + 0.5, 0.5, E) end
for m = #list, 1, -1 do watch(list[m], (m <= 6 and "yellow " or "express ") .. (#list - m)) end
local segs = {}
for _, b in ipairs(list) do
  local ok, v = pcall(function() return b.get_transport_line(1).total_segment_length end)
  segs[#segs + 1] = ok and v or -1
end
extra_out.segment_lengths = segs
local t0 = game.tick + 1
script.on_nth_tick(1, function()
  local t = game.tick
  if t >= t0 then
    local back = list[1].get_transport_line(1)
    if back.can_insert_at_back() then back.insert_at_back({name = "iron-plate", count = 1}) end
    local fr = list[#list].get_transport_line(1)
    for _, it in ipairs(fr.get_detailed_contents()) do if it.position < 0.05 then fr.remove_item({name = "iron-plate", count = 1}) break end end
    record()
  end
  if t == t0 + %(ticks)d then finish("%(file)s") script.on_nth_tick(1, nil) end
end)
rcon.print("tiers from " .. t0)
"""

# 8 yellow belts (east), the 4th switched off by a circuit condition that is false (no wire: 0 > 0),
# items on lane 1 every 64 steps: what moves.
DISABLED = r"""
local list = {}
for x = 0, 7 do list[#list + 1] = put("transport-belt", x + 0.5, 0.5, E) end
for m = #list, 1, -1 do watch(list[m], "belt " .. (#list - m)) end
for _, b in ipairs(list) do for q = 0, 3 do b.get_transport_line(1).insert_at(q * 0.25 + 0.125, {name = "iron-plate", count = 1}) end end
local cc = put("constant-combinator", 3.5, 2.5, N)
cc.get_wire_connector(defines.wire_connector_id.circuit_red, true).connect_to(list[4].get_wire_connector(defines.wire_connector_id.circuit_red, true))
local cb = list[4].get_or_create_control_behavior()
cb.circuit_enable_disable = true
cb.circuit_condition = {first_signal = {type = "item", name = "iron-plate"}, comparator = ">", constant = 0}
extra_out.disabled_status = list[4].status
local t1 = game.tick + 3
local t0 = game.tick + 1
script.on_nth_tick(1, function()
  local t = game.tick
  if t >= t0 then record() end
  if t == t1 then extra_out.status_later = list[4].status end
  if t == t0 + %(ticks)d then finish("%(file)s") script.on_nth_tick(1, nil) end
end)
rcon.print("disabled from " .. t0)
"""


# --- the experiments ----------------------------------------------------------------------------

def lengths(lab, out):
    rec = lab.run(LENGTHS)
    rows = []
    print("lane lengths (line_length, total_segment_length) and where each runs: offsets from the entity's centre in 1/256 at 0, 1/2 and the end of the line")
    for label, i, length, seg, pts in rec.extra["lengths"]:
        print("  %-48s line %d: length %.6f (%d/256) segment %s  from %s via %s to %s" % (
            label, i, length, round(length * 256), seg, pts[0], pts[4], pts[8]))
        rows.append({"what": label, "line": i, "length": length, "length_256": round(length * 256), "segment": seg,
                     "start": pts[0], "mid": pts[4], "end": pts[8]})
    out["lengths"] = rows


def run_pos(rec, label_prefix, j):
    """(belt index from the back of the run, pos) for a lane named '<prefix> <m>' (m from the front)."""
    nm = rec.names[j - 1]
    return nm[0], nm[1]


def track(rec, uid):
    """[(tick, label, line, pos)] for an item."""
    out = []
    for t in sorted(rec.ticks):
        for j, items in rec.ticks[t].items():
            for u, p, n in items:
                if u == uid:
                    nm = rec.names[j - 1]
                    out.append((t, nm[0], nm[1], p))
    return out


def run_distance(label, pos, belts):
    """Distance along a run (1/256) of a lane named '<tier> <m>', m counted from the run's front."""
    m = int(label.rsplit(" ", 1)[1])
    return (belts - 1 - m) * 256 + (256 - pos)


def speed(lab, out):
    rec = lab.run(SPEED, ticks=300)
    res = {}
    print("one item on a 20-belt run of each tier: steps a tick (1/256), ticks a tile")
    first = min(rec.ticks)
    for tier in TIERS:
        for i in (1, 2):
            uids = [u for (j, items) in rec.ticks[first + 1].items() for (u, p, n) in items
                    if rec.names[j - 1][0].startswith(tier + " ") and rec.names[j - 1][1] == i]
            if not uids:
                continue
            tr = track(rec, uids[0])
            d = [(t, run_distance(lb, p, 20)) for t, lb, li, p in tr]
            steps = [b[1] - a[1] for a, b in zip(d, d[1:])]
            moving = [s for s in steps if s != 0]
            counter = collections.Counter(moving)
            stopped_at = tr[-1]
            res["%s lane %d" % (tier, i)] = {"steps": dict(counter), "first": tr[0], "last": stopped_at,
                                             "ticks_moving": len(moving)}
            print("  %-24s lane %d: steps %s over %d ticks; started at %s, ended standing at %s (line pos %d)" % (
                tier, i, dict(counter), len(moving), tr[0][1:], stopped_at[1:3], stopped_at[3]))
    out["speed"] = res


def gap(lab, out):
    rec = lab.run(GAP, ticks=900)
    res = {}
    print("a lane fed at its back whenever it can be: gaps between neighbours (1/256)")
    for tier in ("transport-belt", "turbo-transport-belt"):
        for i in (1, 2):
            # Moving gaps: at a tick early on, on the back belts; packed gaps: at the end, on the front belts.
            def gaps_at(t, front):
                ps = []
                for j, items in rec.ticks[t].items():
                    lb, li = rec.names[j - 1][0], rec.names[j - 1][1]
                    if lb.startswith(tier + " ") and li == i:
                        for u, p, n in items:
                            ps.append((run_distance(lb, p, 16), n))
                ps.sort()
                g = [b[0] - a[0] for a, b in zip(ps, ps[1:])]
                return g, collections.Counter(n for _, n in ps)
            early = min(rec.ticks) + 120
            late = max(rec.ticks)
            g1, n1 = gaps_at(early, False)
            g2, n2 = gaps_at(late, True)
            res["%s lane %d" % (tier, i)] = {"moving_gaps": dict(collections.Counter(g1)), "packed_gaps": dict(collections.Counter(g2)),
                                             "stacks": dict(n2)}
            print("  %-22s lane %d%s: while flowing %s; backed up %s; stack sizes %s" % (
                tier, i, " (stacks of 4)" if i == 2 else "", dict(collections.Counter(g1)), dict(collections.Counter(g2)), dict(n2)))
    fed = rec.extra.get("fed", [])
    out["gap"] = res


def line(lab, out, tier="transport-belt"):
    rec = lab.run(LINE, ticks=400, tier=tier)
    belts = 24
    ticks = sorted(rec.ticks)
    print("a %d-belt %s run, full and blocked at its front; its front item taken every 40 ticks" % (belts, tier))
    print("  total_segment_length of lane 1 of each belt (back to front): %s" % rec.extra.get("segment_lengths"))
    taken = rec.extra.get("taken", [])
    res = {"segments": rec.extra.get("segment_lengths"), "events": []}
    for t_take, uid, p in taken[:4]:
        # For each item on lane 1, the first tick after t_take it moved and how far it went in all.
        before = rec.where(t_take)
        start, moved = {}, {}
        for t in range(t_take + 1, t_take + 40):
            now, prev = rec.where(t), rec.where(t - 1)
            for u, (j, pos, n) in now.items():
                if rec.names[j - 1][1] != 1 or u not in prev:
                    continue
                if prev[u] != now[u] and u not in start:
                    start[u] = t
        dist = {}
        after = rec.where(t_take + 39)
        for u, (j, pos, n) in before.items():
            if rec.names[j - 1][1] != 1 or u not in after:
                continue
            lb = rec.names[j - 1][0]
            lb2 = rec.names[after[u][0] - 1][0]
            dist[u] = (run_distance(lb, pos, belts), run_distance(lb2, after[u][1], belts) - run_distance(lb, pos, belts))
        delays = collections.Counter(start[u] - t_take for u in start)
        went = collections.Counter(v[1] for v in dist.values())
        print("  took item %d at line pos %d on tick %d: items behind started moving %s ticks later (count: %s); each went %s (1/256)" % (
            uid, p, t_take, sorted(delays), dict(delays), dict(went)))
        res["events"].append({"tick": t_take, "start_delays": dict(delays), "went": dict(went)})
    # Lane 2: sparse at the start, nothing taken: where do items stop (bunching at the front)?
    first, last = ticks[0], ticks[-1]
    lane2 = []
    for j, items in rec.ticks[last].items():
        if rec.names[j - 1][1] == 2:
            for u, p, n in items:
                lane2.append(run_distance(rec.names[j - 1][0], p, belts))
    lane2.sort()
    gaps2 = collections.Counter(b - a for a, b in zip(lane2, lane2[1:]))
    print("  lane 2 (an item every half tile, nothing taken): at the end its items stand from %d to %d along the run (of %d), gaps %s" % (
        lane2[0] if lane2 else -1, lane2[-1] if lane2 else -1, belts * 256, dict(gaps2)))
    # When each lane-2 item stopped, and where.
    stops = []
    for u in {u for t in ticks for j, items in rec.ticks[t].items() if rec.names[j - 1][1] == 2 for u, p, n in items}:
        tr = [(t, run_distance(lb, p, belts)) for t, lb, li, p in track(rec, u)]
        for a, b in zip(tr, tr[1:]):
            if a[1] == b[1]:
                stops.append((b[1], b[0] - first))
                break
    stops.sort(reverse=True)
    print("  lane 2's items stopped (place along the run, tick): %s" % stops[:12])
    res["lane2_end"] = lane2
    res["lane2_stops"] = stops
    out["line_" + tier] = res


def sideload(lab, out, tier="transport-belt"):
    res = {}
    print("a %s belt side-loaded from the north at its 6th belt (main 6), the side belt fed every tick it can be" % tier)
    for every in (0, 16, 1):
        rec = lab.run(SIDELOAD, ticks=600, tier=tier, every=every, free=360)
        ticks = sorted(rec.ticks)
        t0 = ticks[0]
        origin, first_main, stood = {}, {}, {}
        for t in ticks:
            for j, items in rec.ticks[t].items():
                lb, li = rec.names[j - 1][0], rec.names[j - 1][1]
                for u, p, n in items:
                    origin.setdefault(u, (lb, li))
                    if lb.startswith("main") and u not in first_main:
                        first_main[u] = (t, lb, li, p)
                    if lb == "side 0" and p == 0:
                        stood[u] = stood.get(u, 0) + 1
        side_in = [(u, origin[u], first_main[u]) for u in first_main if origin[u][0].startswith("side")]
        where = collections.Counter((o[1], f[1], f[2], f[3]) for u, o, f in side_in)
        # Neighbours on the main lane at the tick a side item joined it: the gaps either side.
        gaps = collections.Counter()
        for u, o, f in side_in:
            t, lb, li, p = f
            places = sorted(run_distance(rec.names[j - 1][0].replace("main", "x"), q, 12)
                            for j, items in rec.ticks[t].items() if rec.names[j - 1][0].startswith("main") and rec.names[j - 1][1] == li
                            for uu, q, n in items)
            me = run_distance(lb.replace("main", "x"), p, 12)
            k = places.index(me)
            ahead = places[k + 1] - me if k + 1 < len(places) else None
            behind = me - places[k - 1] if k > 0 else None
            gaps[(min(ahead or 999, 999), min(behind or 999, 999))] += 1
        free = [w for u, o, w in side_in if w[0] - t0 < 360]
        waits = collections.Counter(min(v, 99) for u, v in stood.items() if origin[u][0].startswith("side"))
        label = {0: "main belt empty", 16: "main belt fed every 16 ticks", 1: "main belt fed every tick (packed)"}[every]
        print("  %s: %d side items joined (%d while the main belt flowed); joined at (side lane, main belt, main lane, line pos): %s" % (
            label, len(side_in), len(free), dict(where.most_common(4))))
        print("    gaps on the main lane when one joined (ahead, behind, 1/256): %s; ticks side items stood at the side belt's end: %s" % (
            dict(gaps.most_common(5)), dict(sorted(waits.items())[:8])))
        res[label] = {"joined": len(side_in), "joined_flowing": len(free), "where": {"%s/%s/%s/%s" % k: v for k, v in where.items()},
                      "gaps": {"%s/%s" % k: v for k, v in gaps.items()}, "waits": dict(waits)}
    out["sideload_" + tier] = res


def splitter(lab, out, tier="transport-belt"):
    rec = lab.run(SPLITTER, ticks=1500, tier=tier, split=SPLIT[tier], block=500, unblock=900, prio=1000, unprio=1300)
    first = min(rec.ticks)
    went = []  # (tick it reached an output, uid, input lane, side, output lane)
    seen = set()
    in_lane = {}
    for t in sorted(rec.ticks):
        for j, items in rec.ticks[t].items():
            lb, li = rec.names[j - 1][0], rec.names[j - 1][1]
            for u, p, n in items:
                if lb == "in":
                    in_lane[u] = li
                elif lb in ("left 0", "right 0") and u not in seen:
                    seen.add(u)
                    went.append((t - first, u, in_lane.get(u, 0), lb.split()[0], li))
    print("splitter (%s), both input lanes fed: which output each item took" % SPLIT[tier])
    res = {}
    for name, lo, hi in (("free", 60, 500), ("left blocked", 560, 900), ("unblocked", 960, 1000), ("left priority", 1060, 1300)):
        part = [w for w in went if lo <= w[0] < hi]
        by_lane = {}
        for i in (1, 2):
            seq = "".join("L" if w[3] == "left" else "R" for w in part if w[2] == i)
            by_lane[i] = seq
        print("  %-14s input lane 1: %s" % (name, by_lane[1][:48]))
        print("  %-14s input lane 2: %s" % ("", by_lane[2][:48]))
        same_lane = sum(1 for w in part if w[2] == w[4]) / max(1, len(part))
        res[name] = {"lane1": by_lane[1], "lane2": by_lane[2], "kept_lane": same_lane}
    out["splitter_" + tier] = res


def inserter(lab, out, tier="transport-belt", name="fast-inserter"):
    rec = lab.run(INSERTER, ticks=900, tier=tier, inserter=name, every=8)
    ins = rec.extra.get("inserters")
    hands = {h[0]: h for h in rec.extra.get("hands", [])}
    ticks = sorted(rec.ticks)
    print("%s taking from and putting onto a moving %s (10 belts, an item each lane every 8 ticks): %s" % (name, tier, ins))
    picks, drops = [], []
    for a, b in zip(ticks, ticks[1:]):
        wa, wb = rec.where(a), rec.where(b)
        ha, hb = hands.get(a), hands.get(b)
        for u, (j, p, n) in wa.items():
            if u not in wb:
                nm = rec.names[j - 1]
                if nm[0] != "run 0":  # not the run's front (taken off by the script)
                    picks.append((b, nm[0], nm[1], p, hb[1] if hb else -1, round(hb[3], 3) if hb else 0, round(hb[4], 3) if hb else 0))
        for u, (j, p, n) in wb.items():
            if u not in wa:
                nm = rec.names[j - 1]
                if nm[0] != "run 9":  # not fed at the back
                    drops.append((b, nm[0], nm[1], p))
    print("  taken off the belt (tick, belt, lane, line pos, hand count after, hand x, y): %s" % picks[:12])
    print("  put onto the belt (tick, belt, lane, line pos): %s" % drops[:12])
    print("  taken at (belt, lane, line pos): %s" % dict(collections.Counter((p[1], p[2], p[3]) for p in picks).most_common(12)))
    print("  put at (belt, lane, line pos): %s" % dict(collections.Counter((d[1], d[2], d[3]) for d in drops).most_common(8)))
    out["inserter_" + tier] = {"positions": ins, "picks": picks, "drops": drops}



def compress(lab, out, tier="transport-belt"):
    """Per tick, how far each item moved (1/256) and the gaps, front to back."""
    rec = lab.run(COMPRESS, ticks=200, tier=tier)
    belts = 12
    ticks = sorted(rec.ticks)
    res = {}
    for lane in (1, 2):
        rows = []
        prev = None
        for t in ticks:
            pos = {}
            for j, items in rec.ticks[t].items():
                if rec.names[j - 1][1] != lane:
                    continue
                for u, p, n in items:
                    pos[u] = run_distance(rec.names[j - 1][0], p, belts)
            if prev is not None and pos:
                order = sorted(pos, key=lambda u: -pos[u])  # front (furthest along the run) first
                steps = [pos[u] - prev[u] for u in order if u in prev]
                gaps = [pos[a] - pos[b] for a, b in zip(order, order[1:])]
                rows.append({"t": t - ticks[0], "steps": steps, "gaps": gaps, "front": pos[order[0]]})
            prev = pos
        res["lane%d" % lane] = rows
        print("  %s lane %d (spaced %d): tick: steps of each item front to back | gaps" % (tier, lane, 100 if lane == 1 else 70))
        for r in rows[:8] + rows[60:64] + rows[150:153]:
            print("    %3d: %s | %s" % (r["t"], r["steps"][:16], r["gaps"][:16]))
        if rows:
            last = rows[-1]
            print("    end: front at %s, gaps %s" % (last["front"], dict(collections.Counter(last["gaps"]))))
    out["compress_" + tier] = res


def under(lab, out):
    rec = lab.run(UNDERS)
    rows = rec.extra["unders"]
    print("  underground, gap (tiles between), reach: [line length (1/256), total_segment_length] per line")
    for u, g, reach, l in rows:
        print("    %-26s gap %2d (reach %2d): %s" % (u, g, reach, l))
    out["unders"] = rows


def tiers(lab, out):
    rec = lab.run(TIERS2, ticks=400)
    print("  segment lengths of lane 1, back to front: %s" % rec.extra.get("segment_lengths"))
    ticks = sorted(rec.ticks)
    steps = collections.defaultdict(collections.Counter)
    prev = {}
    for t in ticks:
        now = {}
        for j, items in rec.ticks[t].items():
            nm = rec.names[j - 1]
            if nm[1] != 1:
                continue
            for u, p, n in items:
                now[u] = (nm[0], p)
                if u in prev and prev[u][0] == nm[0]:
                    steps[nm[0].split()[0]][prev[u][1] - p] += 1
        prev = now
    for k, c in steps.items():
        print("    on %s belts, steps a tick: %s" % (k, dict(c.most_common(6))))
    out["tiers"] = {"segments": rec.extra.get("segment_lengths"), "steps": {k: dict(v) for k, v in steps.items()}}


def disabled(lab, out):
    rec = lab.run(DISABLED, ticks=120)
    print("  the switched-off belt's status: %s, 3 ticks on %s (defines.entity_status)" % (rec.extra.get("disabled_status"), rec.extra.get("status_later")))
    ticks = sorted(rec.ticks)
    first, last = rec.where(ticks[0]), rec.where(ticks[-1])
    moved = collections.Counter()
    for u, (j, p, n) in first.items():
        lb = rec.names[j - 1][0]
        still = u in last and last[u][0] == j and last[u][1] == p
        moved[(lb, "stood" if still else "moved")] += 1
    print("  items by belt (belt 7 is the back, belt 0 the front; belt 4 switched off): %s" % sorted(moved.items()))
    out["disabled"] = {str(k): v for k, v in moved.items()}

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rcon-port", type=int, default=rcon.PORT)
    ap.add_argument("--password-file", default=str(rcon.DEFAULT_PASSWORD_FILE))
    ap.add_argument("--script-output", default=str(ROOT / "server" / "data" / "script-output"))
    ap.add_argument("--out", default="")
    ap.add_argument("what", nargs="+")
    a = ap.parse_args()
    lab = Lab(a)
    out = {}
    todo = a.what if "all" not in a.what else ["lengths", "speed", "gap", "line", "sideload", "splitter", "inserter"]
    for w in todo:
        print("== " + w, flush=True)
        if w == "line":
            line(lab, out)
            line(lab, out, "turbo-transport-belt")
        elif w == "sideload":
            sideload(lab, out)
        elif w == "splitter":
            splitter(lab, out)
        elif w == "inserter":
            inserter(lab, out)
        elif w == "compress":
            compress(lab, out)
            compress(lab, out, "turbo-transport-belt")
        else:
            globals()[w](lab, out)
    if a.out:
        pathlib.Path(a.out).write_text(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
