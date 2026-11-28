"""Differential checks of blueprints, planners, rails and settings against the real game (bughunt planners).
Run: python tools/live_check.py --only plannerdiff"""
from __future__ import annotations

from . import live_lib

# (entity, [directions]): what a flipped blueprint must mirror geometrically.
FLIP_LIST = [
    ("storage-tank", [0, 4]), ("boiler", [0, 4, 8, 12]), ("steam-engine", [0, 4]), ("heat-exchanger", [0, 4, 8, 12]),
    ("pump", [0, 4, 8, 12]), ("pipe-to-ground", [0, 4, 8, 12]), ("electric-mining-drill", [0, 4, 8, 12]),
    ("burner-mining-drill", [0, 4, 8, 12]), ("oil-refinery", [0, 4, 8, 12]), ("chemical-plant", [0, 4, 8, 12]),
    ("assembling-machine-2", [0, 4, 8, 12]), ("long-handed-inserter", [0, 4, 8, 12]), ("arithmetic-combinator", [0, 4, 8, 12]),
    ("flamethrower-turret", [0, 4, 8, 12]), ("fast-splitter", [0, 4, 8, 12]), ("fast-underground-belt", [0, 4]),
    ("power-switch", [0]), ("nuclear-reactor", [0]),
    ("centrifuge", [0, 4]), ("steel-furnace", [0, 4]),
]

RECIPES = {"oil-refinery": "basic-oil-processing", "chemical-plant": "light-oil-cracking", "assembling-machine-2": "electric-engine-unit"}

FLIP_SETUP = """
local c = storage.f3d.puppet local s = c.surface local f = c.force
local ox, oy = OX, OY
local L = LIST
local rows = math.ceil(#L / 3)
for _, e in pairs(s.find_entities_filtered({ area = { { ox - 6, oy - 4 }, { ox + 80, oy + rows * 8 + 4 } } })) do if e.type ~= 'character' then e.destroy() end end
local t = {} for x = ox - 6, ox + 80 do for y = oy - 4, oy + rows * 8 + 4 do t[#t + 1] = { name = 'grass-1', position = { x, y } } end end s.set_tiles(t)
s.create_entity({ name = 'iron-chest', position = { ox - 1.5, oy + 0.5 }, force = f })
local out = {}
for i, it in ipairs(L) do
  local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
  local pr = prototypes.entity[it[1]]
  local w, h = pr.tile_width, pr.tile_height if it[2] % 8 == 4 then w, h = h, w end
  local x = ox + 4 + col * 8 + (w % 2 == 1 and 0.5 or 0)
  local y = oy + 4 + row * 8 + (h % 2 == 1 and 0.5 or 0)
  local e = s.create_entity({ name = it[1], position = { x, y }, direction = it[2], force = f, recipe = it[3] })
  if not e then out[#out + 1] = it[1] .. it[2] .. ':none' end
end
if not (storage.f3d.lib_cursor and storage.f3d.lib_cursor.valid) then storage.f3d.lib_cursor = game.create_inventory(1) end local st = storage.f3d.lib_cursor[1]
st.set_stack({ name = 'blueprint', count = 1 })
st.create_blueprint({ surface = s, force = f, area = { { ox - 3, oy - 1 }, { ox + 26, oy + rows * 8 + 1 } } })
rcon.print(#st.get_blueprint_entities() .. ' ' .. table.concat(out, ',') .. ' | ' .. tostring(st.is_blueprint_setup()))
"""

FLIP_COMPARE = """
local c = storage.f3d.puppet local s = c.surface local f = c.force
local ox, oy, mx = OX, OY, MX
local rows = ROWS
local function find(x0, x1) return s.find_entities_filtered({ area = { { x0, oy - 4 }, { x1, oy + rows * 8 + 4 } }, force = f }) end
for _, g in pairs(s.find_entities_filtered({ area = { { mx - 6, oy - 4 }, { mx + 30, oy + rows * 8 + 4 } }, type = 'entity-ghost' })) do g.revive() end
local a, b = find(ox - 3, ox + 26), find(mx - 6, mx + 30)
local function anchor(list) for _, e in pairs(list) do if e.name == 'iron-chest' then return e end end end
local A, B = anchor(a), anchor(b)
if not (A and B) then rcon.print('anchor missing ' .. #a .. ' ' .. #b) return end
local function r2(v) return math.floor(v * 100 + 0.5) / 100 end
local function sig(e, o, flip)
  local out = {}
  local function add(k, p) out[#out + 1] = k .. ':' .. r2(flip and -(p.x - o.position.x) or (p.x - o.position.x)) .. ',' .. r2(p.y - o.position.y) end
  local okf, fb = pcall(function() return e.fluidbox end)
  for i = 1, (okf and fb) and #fb or 0 do
    local ok, list = pcall(function() return fb.get_pipe_connections(i) end)
    if ok and list then for _, pc in pairs(list) do if pc.target_position then add('p' .. i .. (pc.flow_direction or ''), pc.target_position) end end end
  end
  if e.type == 'inserter' then add('pick', e.pickup_position) add('drop', e.drop_position) end
  if e.type == 'mining-drill' then add('drop', e.drop_position) end
  table.sort(out)
  return table.concat(out, ' ')
end
local bad = {}
local DIRS = { ['arithmetic-combinator'] = true, ['long-handed-inserter'] = true, ['fast-splitter'] = true, ['fast-underground-belt'] = true, ['pump'] = true }
for _, e in pairs(a) do
  if e.name ~= 'iron-chest' and e.type ~= 'character' then
    local rx, ry = e.position.x - A.position.x, e.position.y - A.position.y
    local match
    for _, m in pairs(b) do
      if m.name == e.name and math.abs((m.position.x - B.position.x) + rx) < 0.02 and math.abs((m.position.y - B.position.y) - ry) < 0.02 then match = m end
    end
    local key = e.name .. '/' .. e.direction
    if not match then bad[#bad + 1] = key .. ' position'
    else
      local want, got = sig(e, A, true), sig(match, B, false)
      if want ~= got then bad[#bad + 1] = key .. ' geometry want [' .. want .. '] got [' .. got .. ']' end
      if DIRS[e.name] and match.direction ~= (16 - e.direction) % 16 then bad[#bad + 1] = key .. ' direction ' .. match.direction end
    end
  end
end
for _, e in pairs(a) do if e.type ~= 'character' then e.destroy() end end
for _, e in pairs(b) do if e.type ~= 'character' then e.destroy() end end
rcon.print(#a .. '/' .. #b .. ' ' .. table.concat(bad, ' ## '))
"""


def lua_list(items):
    return "{ " + ", ".join("{ '%s', %d, %s }" % (n, d, ("'%s'" % r) if r else "nil") for n, d, r in items) + " }"


def check_flip_many(c, hello):
    """Flipped blueprints (H) of more machines than check_flips covers: pipe connections, hand and drop
    positions and directions of the pasted mirror against the original's geometry mirrored."""
    items = [(n, d, RECIPES.get(n)) for n, ds in FLIP_LIST for d in ds]
    if not live_lib.clean_spot(c, hello, half=14):
        live_lib.report(False, "flipmany: no clean spot found")
        return
    x, y = round(c.me["x"] / 256), round(c.me["y"] / 256)
    ox, oy = x - 12 + (x % 2), y - 12 + (y % 2)
    for part in range(0, len(items), 9):
        chunk = items[part:part + 9]
        rows = (len(chunk) + 2) // 3
        out = live_lib.mod_lua(FLIP_SETUP.replace("OX", str(ox)).replace("OY", str(oy)).replace("LIST", lua_list(chunk)).replace("\n", " "))
        live_lib.report(out.endswith("true"), "flipmany: layout built and made into a blueprint", out)
        mx = ox + 50
        c.send({"t": "blueprint", "i": -1, "x": (mx + 10) * 256, "y": (oy + 12) * 256, "d": 0, "bm": 1, "m": 1})
        c.pump(1.0, every=hello)
        res = live_lib.mod_lua(FLIP_COMPARE.replace("OX", str(ox)).replace("OY", str(oy)).replace("MX", str(mx)).replace("ROWS", str(rows)).replace("\n", " "))
        live_lib.report(res.partition(" ")[2].strip() == "", "flipmany: mirrored blueprint matches the original mirrored: " + ", ".join(n for n, _, _ in chunk), res[:1500])




POLE_LUA = """
local c = storage.f3d.puppet local s = c.surface local f = c.force
local ox, oy = OX, OY
for _, e in pairs(s.find_entities_filtered({ area = { { ox - 40, oy - 40 }, { ox + 40, oy + 40 } } })) do if e.type ~= 'character' then e.destroy() end end
local t = {} for x = ox - 40, ox + 40 do for y = oy - 40, oy + 40 do t[#t + 1] = { name = 'grass-1', position = { x, y } } end end s.set_tiles(t)
local function clear() for _, e in pairs(s.find_entities_filtered({ area = { { ox - 40, oy - 40 }, { ox + 40, oy + 40 } }, type = 'electric-pole' })) do e.destroy() end end
local function pole(n, x, y) local pr = prototypes.entity[n] local off = pr.tile_width % 2 == 1 and 0.5 or 0
  return s.create_entity({ name = n, position = { ox + x + off, oy + y + off }, force = f }) end
local function cn(e) return e.get_wire_connector(defines.wire_connector_id.pole_copper, true) end
local function lone(e) cn(e).disconnect_all() end
local function res(e) local o = {} for _, con in pairs(cn(e).connections) do local n = con.target.owner o[#o + 1] = string.format('%.1f,%.1f', n.position.x - ox, n.position.y - oy) end table.sort(o) return table.concat(o, ' ') end
local out = {}
local function case(label, new, nx, ny, existing, keep)
  clear()
  for _, p in pairs(existing) do local e = pole(p[1], p[2], p[3]) if e and not keep then lone(e) end end
  local e = pole(new, nx, ny)
  out[#out + 1] = label .. ' => ' .. (e and res(e) or 'not built')
end
case('big new, small at 5.5', 'big-electric-pole', 0, 0, { { 'small-electric-pole', 5, 0 } })
case('big new, small at 9.5', 'big-electric-pole', 0, 0, { { 'small-electric-pole', 9, 0 } })
case('small new, big at 20', 'small-electric-pole', 0, 0, { { 'big-electric-pole', 20, 0 } })
case('small new, big at 7', 'small-electric-pole', 0, 0, { { 'big-electric-pole', 7, 0 } })
case('medium new, small at 8', 'medium-electric-pole', 0, 0, { { 'small-electric-pole', 8, 0 } })
case('medium new, small at 7', 'medium-electric-pole', 0, 0, { { 'small-electric-pole', 7, 0 } })
case('small new, medium at 8.5', 'small-electric-pole', 0, 0, { { 'medium-electric-pole', 8, 0 } })
case('substation new, medium at 17', 'substation', 0, 0, { { 'medium-electric-pole', 17, 0 } })
case('substation new, substation at 17', 'substation', 0, 0, { { 'substation', 17, 0 } })
local ring = {} for i = 0, 7 do local a = i * math.pi / 4 ring[#ring + 1] = { 'small-electric-pole', math.floor(6 * math.cos(a) + 0.5), math.floor(6 * math.sin(a) + 0.5) } end
case('medium new, 8 lone small at radius 6', 'medium-electric-pole', 0, 0, ring)
case('medium new, 8 small at radius 6, kept wires', 'medium-electric-pole', 0, 0, ring, true)
case('triangle: new small, A(3,0) B(3,3) wired', 'small-electric-pole', 0, 0, { { 'small-electric-pole', 3, 0 }, { 'small-electric-pole', 3, 3 } }, true)
case('triangle: new small, A(3,0) B(3,3) lone', 'small-electric-pole', 0, 0, { { 'small-electric-pole', 3, 0 }, { 'small-electric-pole', 3, 3 } })
case('chain: new small, A(3,0) wired to B(6,0)', 'small-electric-pole', 0, 0, { { 'small-electric-pole', 3, 0 }, { 'small-electric-pole', 6, 0 } }, true)
clear()
rcon.print(table.concat(out, ' ;; '))
"""


def check_poles(c, hello):
    """Which poles a new pole connects to (the client's build preview draws these wires)."""
    if not live_lib.clean_spot(c, hello, half=14):
        live_lib.report(False, "poles: no clean spot found")
        return
    x, y = round(c.me["x"] / 256), round(c.me["y"] / 256)
    out = live_lib.mod_lua(POLE_LUA.replace("OX", str(x)).replace("OY", str(y)).replace("\n", " "))
    for line in out.split(" ;; "):
        print("INFO " + line)
    live_lib.report(bool(out), "poles: scenarios run", out[:200])




PLANNER_LUA = """
if not (storage.f3d.lib_cursor and storage.f3d.lib_cursor.valid) then storage.f3d.lib_cursor = game.create_inventory(1) end local st = storage.f3d.lib_cursor[1]
local out = {}
st.set_stack({ name = 'deconstruction-planner', count = 1 })
st.set_entity_filter(1, 'wooden-chest') st.set_entity_filter(2, 'tree-01') st.set_tile_filter(1, 'stone-path')
st.tile_selection_mode = defines.deconstruction_item.tile_selection_mode.always
st.entity_filter_mode = defines.deconstruction_item.entity_filter_mode.blacklist
out[#out + 1] = 'DECON ' .. st.export_stack()
st.set_stack({ name = 'upgrade-planner', count = 1 })
st.set_mapper(1, 'from', { type = 'entity', name = 'transport-belt' }) st.set_mapper(1, 'to', { type = 'entity', name = 'fast-transport-belt' })
st.set_mapper(2, 'from', { type = 'entity', name = 'inserter' }) st.set_mapper(2, 'to', { type = 'entity', name = 'fast-inserter' })
out[#out + 1] = 'UPG ' .. st.export_stack()
rcon.print(table.concat(out, ' ;; '))
"""

IMPORT_LUA = """
if not (storage.f3d.lib_cursor and storage.f3d.lib_cursor.valid) then storage.f3d.lib_cursor = game.create_inventory(1) end local st = storage.f3d.lib_cursor[1]
st.set_stack({ name = 'deconstruction-planner', count = 1 })
local ok, err = pcall(function() st.import_stack('STR') end)
local o = { tostring(ok), tostring(err), 'n=' .. tostring(st.entity_filter_count), 'mode=' .. tostring(st.entity_filter_mode), 'tsm=' .. tostring(st.tile_selection_mode) }
for i = 1, st.entity_filter_count do o[#o + 1] = i .. '=' .. tostring(st.get_entity_filter(i)) end
rcon.print(table.concat(o, ' '))
"""


def check_planner_data(c, hello):
    """Planner strings: the indices the game writes (0 or 1 based), the tile selection numbers, what an import keeps."""
    import json
    from .building_and_planners import bp_record, bp_string
    out = live_lib.mod_lua(PLANNER_LUA.replace("\n", " "))
    for part in out.split(" ;; "):
        kind, s = part.split(" ", 1)
        print("INFO " + kind + " " + json.dumps(bp_record(s)))
    base = {"item": "deconstruction-planner", "version": 562949954076673}
    for label, settings in (("0-based indices", {"entity_filters": [{"name": "wooden-chest", "index": 0}, {"name": "tree-01", "index": 1}]}),
                            ("1-based indices", {"entity_filters": [{"name": "wooden-chest", "index": 1}, {"name": "tree-01", "index": 2}]}),
                            ("item names", {"entity_filters": [{"name": "iron-plate", "index": 1}, {"name": "rail", "index": 2}, {"name": "straight-rail", "index": 3}, {"name": "rock-big", "index": 4}]})):
        s = bp_string({"deconstruction_planner": dict(base, settings=settings)})
        res = live_lib.mod_lua(IMPORT_LUA.replace("STR", s).replace("\n", " "))
        print("INFO import " + label + ": " + res)
    live_lib.report(True, "planner data printed")


def check_plannerdiff(c, hello):
    import os
    from .planner_more import check_marks, check_modes, check_signals, check_snap
    every = {"marks": check_marks, "modes": check_modes, "signals": check_signals, "snap": check_snap, "data": check_planner_data,
             "poles": check_poles, "flip": check_flip_many}
    for name in (os.environ.get("PD") or ",".join(every)).split(","):
        every[name](c, hello)
