"""More differential checks of planners and building against the real game (bughunt planners): what an area takes,
absolute snapping, blueprint build modes, and rail signals and train stops beside a rail."""
from __future__ import annotations

import math

from . import live_lib

CURSOR = ("if not (storage.f3d.lib_cursor and storage.f3d.lib_cursor.valid) then storage.f3d.lib_cursor = game.create_inventory(1) end "
          "local st = storage.f3d.lib_cursor[1]")

MARKS_LUA = """
local c = storage.f3d.puppet local s = c.surface local f = c.force
local ox, oy = OX, OY
local R = { { ox - 6, oy - 6 }, { ox + 30, oy + 20 } }
local function wipe() for _, e in pairs(s.find_entities_filtered({ area = R })) do if e.type ~= 'character' then e.destroy() end end end
wipe()
local out = {}
CURSOR
local function mk(n, x, y, d) return s.create_entity({ name = n, position = { ox + x, oy + y }, direction = d or 0, force = f }) end
local am = mk('assembling-machine-1', 1.5, 1.5)
st.set_stack({ name = 'deconstruction-planner', count = 1 })
st.deconstruct_area({ surface = s, force = f, area = { { ox + 2.5, oy + 0.5 }, { ox + 4, oy + 1 } } })
out[#out + 1] = 'decon area touching only the edge of a 3x3: marked=' .. tostring(am.to_be_deconstructed())
am.cancel_deconstruction(f)
st.deconstruct_area({ surface = s, force = f, area = { { ox + 1.4, oy + 1.4 }, { ox + 1.4, oy + 1.4 } } })
out[#out + 1] = 'decon zero-size area on it: marked=' .. tostring(am.to_be_deconstructed())
am.cancel_deconstruction(f)
local belt = mk('transport-belt', 10.5, 1.5, 4)
local gh = s.create_entity({ name = 'entity-ghost', inner_name = 'transport-belt', position = { ox + 12.5, oy + 1.5 }, direction = 4, force = f })
st.set_stack({ name = 'upgrade-planner', count = 1 })
s.upgrade_area({ force = f, area = { { ox + 9, oy }, { ox + 14, oy + 3 } }, item = st })
out[#out + 1] = 'upgrade with an EMPTY planner: belt registered=' .. tostring(belt.is_registered_for_upgrade()) .. ' ghost=' .. tostring(gh.valid and gh.ghost_name)
st.set_mapper(1, 'from', { type = 'entity', name = 'assembling-machine-1' }) st.set_mapper(1, 'to', { type = 'entity', name = 'assembling-machine-2' })
local am2 = mk('assembling-machine-1', 20.5, 1.5)
s.upgrade_area({ force = f, area = { { ox + 21.9, oy + 0.5 }, { ox + 23, oy + 2 } }, item = st })
out[#out + 1] = 'upgrade area touching only the edge of a 3x3: registered=' .. tostring(am2.is_registered_for_upgrade())
wipe()
rcon.print(table.concat(out, ' ;; '))
""".replace("CURSOR", CURSOR)


def check_marks(c, hello):
    """What a planner's area takes in the game: the selection box overlapping it (not only the middle inside), and an
    empty upgrade planner upgrading everything with a next tier, ghosts too (so the client keeps highlighting all)."""
    if not live_lib.clean_spot(c, hello, half=14):
        live_lib.report(False, "marks: no clean spot found")
        return
    x, y = round(c.me["x"] / 256), round(c.me["y"] / 256)
    out = live_lib.mod_lua(MARKS_LUA.replace("OX", str(x)).replace("OY", str(y)).replace(chr(10), " "))
    for line in out.split(" ;; "):
        print("INFO " + line)
    live_lib.report(out.startswith("decon area touching only the edge of a 3x3: marked=true ;; decon zero-size area on it: marked=true")
                    and "EMPTY planner: belt registered=true" in out and out.endswith("registered=true"),
                    "marks: a planner's area takes what its selection box overlaps (3x3 machine by its edge, a click on a point); an empty upgrade planner upgrades", out[:400])


SNAP_LUA = """
local c = storage.f3d.puppet local s = c.surface local f = c.force
local ox, oy = OX, OY
CURSOR
st.set_stack({ name = 'blueprint', count = 1 })
st.set_blueprint_entities({ { entity_number = 1, name = 'wooden-chest', position = { x = 0.5, y = 0.5 } }, { entity_number = 2, name = 'wooden-chest', position = { x = 2.5, y = 1.5 } } })
st.blueprint_snap_to_grid = { x = GX, y = GY }
st.blueprint_absolute_snapping = true
st.blueprint_position_relative_to_grid = { x = RX, y = RY }
local o = {}
for _, p in pairs(PTS) do
  local g = st.build_blueprint({ surface = s, force = f, position = { ox + p[1], oy + p[2] }, build_mode = defines.build_mode.forced })
  local r = {} for _, e in pairs(g) do r[#r + 1] = string.format('%.1f,%.1f', e.position.x - ox, e.position.y - oy) e.destroy() end
  table.sort(r)
  o[#o + 1] = string.format('%.2f,%.2f=%s', p[1], p[2], table.concat(r, '+'))
end
rcon.print(table.concat(o, ' '))
""".replace("CURSOR", CURSOR)


def check_snap(c, hello):
    """Absolute snapping: where the game puts a blueprint for a cursor point, against where the client sends it (blueprint_anchor)."""
    if not live_lib.clean_spot(c, hello, half=14):
        live_lib.report(False, "snap: no clean spot found")
        return
    x, y = round(c.me["x"] / 256), round(c.me["y"] / 256)
    x, y = x - x % 8, y - y % 8
    pts = [(0.3, 0.3), (1.7, 0.4), (2.2, 2.9), (3.8, 3.8), (5.1, 1.2), (4.0, 4.0), (7.9, 6.1), (6.5, 6.5), (9.4, 2.2), (0.5, 7.5)]

    def run(grid, rel, points):
        lua = (SNAP_LUA.replace("OX", str(x)).replace("OY", str(y)).replace("GX", str(grid[0])).replace("GY", str(grid[1]))
               .replace("RX", str(rel[0])).replace("RY", str(rel[1]))
               .replace("PTS", "{ " + ", ".join("{ %s, %s }" % p for p in points) + " }"))
        return live_lib.mod_lua(lua.replace(chr(10), " "))

    for grid, rel in (((4, 4), (0, 0)), ((4, 4), (1, 1)), ((6, 2), (2, 1))):
        game = dict(kv.split("=") for kv in run(grid, rel, pts).split())
        bad = []
        for px, py in pts:
            # the client's blueprint_anchor: the middle of the grid cell under the point
            # (the grid is the world's: work in world coordinates, the cursor points are relative to x, y)
            cx = math.floor((px + x - rel[0]) / grid[0]) * grid[0] + rel[0]
            cy = math.floor((py + y - rel[1]) / grid[1]) * grid[1] + rel[1]
            ax, ay = cx + math.floor(grid[0] * 0.5 + 0.5) - x, cy + math.floor(grid[1] * 0.5 + 0.5) - y
            sent = run(grid, rel, [(ax, ay)]).split("=", 1)[1]
            key = "%.2f,%.2f" % (px, py)
            if sent != game[key]:
                bad.append(f"cursor ({px},{py}): game {game[key]}, via client anchor ({ax},{ay}) {sent}")
        live_lib.report(not bad, f"snap: the client's anchor for absolute snapping, grid {grid} offset {rel}, gives the game's placement", "; ".join(bad))


MODES_LUA = """
local c = storage.f3d.puppet local s = c.surface local f = c.force
local ox, oy = OX, OY
local R = { { ox - 6, oy - 6 }, { ox + 12, oy + 12 } }
local function wipe() for _, e in pairs(s.find_entities_filtered({ area = R })) do if e.type ~= 'character' then e.destroy() end end end
CURSOR
local out = {}
local modes = { { 'normal', defines.build_mode.normal }, { 'forced', defines.build_mode.forced }, { 'superforced', defines.build_mode.superforced } }
local cases = { { 'tree', 'tree-01' }, { 'rock', 'big-rock' }, { 'other chest', 'iron-chest' }, { 'belt over inserter', 'inserter' }, { 'same chest', 'wooden-chest' } }
for _, cs in ipairs(cases) do
  for _, m in ipairs(modes) do
    wipe()
    st.set_stack({ name = 'blueprint', count = 1 })
    local what = cs[1] == 'belt over inserter' and 'transport-belt' or 'wooden-chest'
    st.set_blueprint_entities({ { entity_number = 1, name = what, position = { x = 0.5, y = 0.5 } } })
    local old = s.create_entity({ name = cs[2], position = { ox + 5.5, oy + 5.5 }, force = f })
    local g = st.build_blueprint({ surface = s, force = f, position = { ox + 5.5, oy + 5.5 }, build_mode = m[2] })
    out[#out + 1] = cs[1] .. '/' .. m[1] .. ': ghosts=' .. #g .. ' old marked=' .. tostring(old and old.valid and old.to_be_deconstructed())
  end
end
wipe()
rcon.print(table.concat(out, ' ;; '))
""".replace("CURSOR", CURSOR)


def check_modes(c, hello):
    """Blueprint build modes against trees, rocks and buildings in the way (what a click, Ctrl+V and Shift+click do)."""
    if not live_lib.clean_spot(c, hello, half=14):
        live_lib.report(False, "modes: no clean spot found")
        return
    x, y = round(c.me["x"] / 256), round(c.me["y"] / 256)
    out = live_lib.mod_lua(MODES_LUA.replace("OX", str(x)).replace("OY", str(y)).replace(chr(10), " "))
    for line in out.split(" ;; "):
        print("INFO " + line)
    live_lib.report("tree/normal: ghosts=0" in out and "tree/forced: ghosts=1 old marked=true" in out,
                    "modes: a click places nothing over a tree, Shift+click marks it and places the ghost", out[:300])


def check_signals(c, hello):
    """Rail signals and train stops built the way the client sends them (`build` at a tile's middle) next to a
    straight rail: the side and direction building.lua's snap_to_rail picks (create_entity alone takes one side and way only)."""
    if not live_lib.clean_spot(c, hello, half=14):
        live_lib.report(False, "signals: no clean spot found")
        return
    x, y = round(c.me["x"] / 256), round(c.me["y"] / 256)
    ox, oy = x - 4 + (x % 2), y + (y % 2)
    setup = ("local c = storage.f3d.puppet local s = c.surface local f = c.force local ox, oy = %d, %d "
             "for _, e in pairs(s.find_entities_filtered({ area = { { ox - 8, oy - 8 }, { ox + 12, oy + 8 } } })) do if e.type ~= 'character' then e.destroy() end end "
             "for i = 0, 3 do s.create_entity({ name = 'straight-rail', position = { ox + i * 2 + 1, oy + 1 }, direction = 4, force = f }) end "
             "c.get_main_inventory().remove({ name = 'rail-signal', count = 1000 }) c.insert({ name = 'rail-signal', count = 50 }) "
             "c.get_main_inventory().remove({ name = 'train-stop', count = 1000 }) c.insert({ name = 'train-stop', count = 10 }) "
             "rcon.print('ok')") % (ox, oy)
    live_lib.mod_lua(setup)
    c.pump(1.0, every=hello)
    cells = {}
    for item in ("rail-signal", "train-stop"):
        for d in (0, 4):
            print(f"INFO {item} build dir {d}: per clicked tile what stood afterwards (position/direction relative to the rail's corner):")
            for ty in range(oy - 3, oy + 5):
                row = []
                for tx in range(ox - 1, ox + 9):
                    c.send({"t": "build", "item": item, "x": int((tx + 0.5) * 256), "y": int((ty + 0.5) * 256), "d": d})
                    texts = [m["text"] for m in live_lib.of_type(c.pump(0.2, every=hello), "msg")]
                    res = live_lib.mod_lua(
                        "local c = storage.f3d.puppet local s = c.surface local o = {} for _, e in pairs(s.find_entities_filtered({ name = '%s', area = { { %d, %d }, { %d, %d } } })) do "
                        "o[#o + 1] = string.format('%%.1f,%%.1f/%%d', e.position.x - %d, e.position.y - %d, e.direction) e.destroy() end "
                        "c.get_main_inventory().remove({ name = '%s', count = 1000 }) c.insert({ name = '%s', count = 50 }) rcon.print(table.concat(o, ' '))"
                        % (item, ox - 8, oy - 8, ox + 12, oy + 8, ox, oy, item, item))
                    row.append(res or (texts[0][:14] if texts else "-"))
                    cells[(item, d, tx - ox, ty - oy)] = res
                print(f"INFO   y {ty - oy:+d}: " + " | ".join(row))
    # The side of the track is the cursor's (north half of a horizontal rail, south half), whatever direction the client holds.
    want = {("rail-signal", 0, 3, -1): "3.5,-0.5/4", ("rail-signal", 0, 3, 2): "3.5,2.5/12", ("rail-signal", 4, 3, -2): "3.5,-0.5/4",
            ("rail-signal", 4, 3, 3): "3.5,2.5/12", ("train-stop", 0, 2, -1): "3.0,-1.0/12", ("train-stop", 0, 2, 2): "3.0,3.0/4",
            ("train-stop", 4, 2, 3): "3.0,3.0/4"}
    bad = {k: (cells.get(k), v) for k, v in want.items() if cells.get(k) != v}
    live_lib.report(not bad, "signals: a rail signal and a train stop built at a tile beside a horizontal rail snap to the cursor's side of it, facing along "
                    "the track, whichever direction was held", str(bad))
