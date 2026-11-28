-- Building from the character's inventory, as a player does: snapped to the grid (rails to their
-- two-tile grid), fast-replace (a faster belt over a belt, the same belt turned), rolling stock
-- put on the nearest rail, and the quality of the stack it is built from.

local registry = require("scripts.registry")
local transport = require("scripts.transport")
local tracker = require("scripts.tracker")
local as_player = require("scripts.as_player")
local puppet = require("scripts.puppet")
local map = require("scripts.map")
local space = require("scripts.space")
local perf = require("scripts.perf")

local M = {}

local REACH_SLACK = 1.5 -- reach is measured to the entity's edge in-game; we measure to its centre
local RAIL_SEARCH = 3   -- how far from the cursor rolling stock looks for a rail
local ROLLING_STOCK = {
  locomotive = true, ["cargo-wagon"] = true, ["fluid-wagon"] = true, ["artillery-wagon"] = true,
}

local function distance(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

-- Odd sizes centre on a tile, even sizes on a tile corner, like the game. Rails sit on a two-tile
-- grid with their centres on odd coordinates.
local function snap(v, size, grid)
  if grid == 2 then
    return math.floor(v / 2) * 2 + 1
  end
  if size % 2 == 1 then
    return math.floor(v) + 0.5
  end
  return math.floor(v + 0.5)
end

local function grid_size(proto)
  local ok, g = pcall(function() return proto.build_grid_size end)
  return ok and g or 1
end

-- An underground belt becomes the exit of the nearest underground of its kind behind it facing the
-- same way (or its ghost), when that one is an entrance; otherwise an entrance, as when a player
-- builds one.
-- create_entity makes every underground an entrance unless told (checked in 2.1.23).
local BEHIND = { [0] = { 0, 1 }, [4] = { -1, 0 }, [8] = { 0, -1 }, [12] = { 1, 0 } }
local function underground_type(surface, proto, position, direction)
  local back = BEHIND[direction]
  local ok, reach = pcall(function() return proto.max_underground_distance end)
  if not back or not ok or not reach then
    return "input"
  end
  for i = 1, reach do
    local at = { x = position.x + back[1] * i, y = position.y + back[2] * i }
    local other = surface.find_entities_filtered({ name = proto.name, position = at })[1]
      or surface.find_entities_filtered({ ghost_name = proto.name, position = at })[1]
    if other and other.direction == direction then
      return other.belt_to_ground_type == "input" and "output" or "input"
    end
  end
  return "input"
end

-- The quality to build with: the one asked for if the character has it, else normal, else the
-- first the character has (by name, so every peer picks the same).
local function pick_quality(inventory, item_name, wanted)
  local have = {}
  for _, it in pairs(inventory.get_contents()) do
    if it.name == item_name and it.count > 0 then
      have[it.quality or "normal"] = true
    end
  end
  if wanted and have[wanted] then
    return wanted
  end
  if have.normal then
    return "normal"
  end
  local names = {}
  for q in pairs(have) do
    names[#names + 1] = q
  end
  table.sort(names)
  return names[1]
end

local function quality_name(e)
  local ok, q = pcall(function() return e.quality.name end)
  return ok and q or "normal"
end

-- L7: Factorio builds out of the cursor's stack, so the stack the client's hand holds the item from (`hs`,
-- a main inventory slot) is the one that empties (and its quality the one built), and the client's hand
-- moves on to the next stack when it has; without it any stack of the item pays (puppet.take_held).

-- Rolling stock goes on the nearest straight rail, facing along it (the client's direction picks
-- which way along).
local function on_rail(surface, position, direction)
  local types = registry.rail_types()
  if #types == 0 then
    return nil
  end
  local best, best_d = nil, RAIL_SEARCH
  for _, rail in pairs(surface.find_entities_filtered({
    area = { { position.x - RAIL_SEARCH, position.y - RAIL_SEARCH }, { position.x + RAIL_SEARCH, position.y + RAIL_SEARCH } },
    type = types,
  })) do
    local d = distance(position, rail.position)
    if d <= best_d then
      best, best_d = rail, d
    end
  end
  if not best then
    return nil
  end
  local axis = best.direction % 8
  local facing = direction
  if axis ~= direction % 8 then
    facing = axis
  end
  return { x = best.position.x, y = best.position.y }, facing
end

-- Rail signals and train stops snap to the track as a player's cursor does: Factorio puts a signal
-- on the side of the rail the cursor is on, facing along it, and turns a stop to the rail, whatever
-- direction the client holds (create_entity takes the position and direction as given and refuses
-- all but one side and way). The spots round the cursor are tried nearest first with the game's
-- own placement check; a stop must also join a rail when one is near (it stands free otherwise).
local RAIL_SNAP = { ["rail-signal"] = true, ["rail-chain-signal"] = true, ["train-stop"] = true }
local ALL_RAIL_TYPE_LIST = {
  "straight-rail", "half-diagonal-rail", "curved-rail-a", "curved-rail-b",
  "legacy-straight-rail", "legacy-curved-rail",
  "elevated-straight-rail", "elevated-half-diagonal-rail", "elevated-curved-rail-a", "elevated-curved-rail-b",
  "rail-ramp",
}
local cached_all_rail_types
local function all_rail_types()
  if cached_all_rail_types then
    return cached_all_rail_types
  end
  local present = {}
  for _, p in pairs(prototypes.entity) do
    present[p.type] = true
  end
  local list = {}
  for _, t in ipairs(ALL_RAIL_TYPE_LIST) do
    if present[t] then
      list[#list + 1] = t
    end
  end
  cached_all_rail_types = list
  return list
end

local function can_snap_spot(surface, proto, x, y, d, force, check_type, stop, ghost)
  if not surface.can_place_entity({ name = proto.name, position = { x = x, y = y },
      direction = d, force = force, build_check_type = check_type }) then
    return false
  end
  if not stop then
    return true
  end
  if ghost then
    local g = surface.create_entity({ name = "entity-ghost", inner_name = proto.name,
      position = { x = x, y = y }, direction = d, force = force })
    if not g then
      return false
    end
    local ok, rail = pcall(function() return g.connected_rail end)
    g.destroy()
    return ok and rail ~= nil
  end
  local e = surface.create_entity({ name = proto.name, position = { x = x, y = y }, direction = d, force = force })
  if not e then
    return false
  end
  local ok, rail = pcall(function() return e.connected_rail end)
  e.destroy()
  return ok and rail ~= nil
end

local STOP_DIRS = { 0, 4, 8, 12 }
local SIGNAL_DIRS = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }

local function snap_to_rail(surface, proto, at, wanted, force, ghost)
  local stop = proto.type == "train-stop"
  local types = stop and registry.rail_types() or all_rail_types()
  if #types == 0 then
    return nil
  end
  local near = surface.find_entities_filtered({
    area = { { at.x - 4, at.y - 4 }, { at.x + 4, at.y + 4 } }, type = types, limit = 1,
  })
  if #near == 0 then
    if not ghost then
      return nil
    end
    local near_ghost = surface.find_entities_filtered({
      area = { { at.x - 4, at.y - 4 }, { at.x + 4, at.y + 4 } }, type = "entity-ghost", limit = 1,
    })
    if #near_ghost == 0 then
      return nil
    end
  end
  local check_type = ghost and defines.build_check_type.manual_ghost or defines.build_check_type.manual
  local ex, ey = snap(at.x, proto.tile_width, 1), snap(at.y, proto.tile_height, 1)
  if can_snap_spot(surface, proto, ex, ey, wanted, force, check_type, stop, ghost) then
    return { x = ex, y = ey }, wanted
  end
  local spots = {}
  local r = stop and 3 or 2
  local dirs = stop and STOP_DIRS or SIGNAL_DIRS
  for dx = -r, r do
    for dy = -r, r do
      local x, y = snap(at.x + dx, proto.tile_width, 1), snap(at.y + dy, proto.tile_height, 1)
      for _, d in ipairs(dirs) do
        local dist = distance(at, { x = x, y = y }) + (d == wanted and 0 or 0.01)
        spots[#spots + 1] = { x = x, y = y, d = d, dist = dist }
      end
    end
  end
  table.sort(spots, function(a, b)
    if a.dist ~= b.dist then return a.dist < b.dist end
    if a.x ~= b.x then return a.x < b.x end
    if a.y ~= b.y then return a.y < b.y end
    return a.d < b.d
  end)
  local seen = {}
  for _, sp in ipairs(spots) do
    local key = sp.x .. "," .. sp.y .. "," .. sp.d
    if not seen[key] then
      seen[key] = true
      if can_snap_spot(surface, proto, sp.x, sp.y, sp.d, force, check_type, stop, ghost) then
        return { x = sp.x, y = sp.y }, sp.d
      end
    end
  end
  return nil
end

-- The entity of the same prototype standing exactly there, if any.
local function same_entity(surface, proto, position)
  for _, e in pairs(surface.find_entities_filtered({
    area = { { position.x - 0.1, position.y - 0.1 }, { position.x + 0.1, position.y + 0.1 } },
    name = proto.name,
  })) do
    if e.position.x == position.x and e.position.y == position.y then
      return e
    end
  end
  return nil
end

-- A ghost of this entity standing exactly there, if any.
local function ghost_at(surface, proto, position)
  for _, g in pairs(surface.find_entities_filtered({
    area = { { position.x - 0.1, position.y - 0.1 }, { position.x + 0.1, position.y + 0.1 } },
    type = "entity-ghost",
  })) do
    if g.ghost_name == proto.name and g.position.x == position.x and g.position.y == position.y then
      return g
    end
  end
  return nil
end

-- What a fast-replace would remove: the entities under the new one's footprint (w x h tiles) of the
-- same fast-replaceable group. Under the whole footprint, not its middle (J9): a splitter stands on a
-- tile edge between the two belts it replaces, and a search round that point found neither (or one,
-- whose neighbour then went without its removal sent or its items given back).
local function replaced_entities(surface, proto, position, w, h)
  local group = proto.fast_replaceable_group
  local out = {}
  if not group or group == "" then
    return out
  end
  local hx, hy = math.max(w / 2 - 0.1, 0.1), math.max(h / 2 - 0.1, 0.1)
  for _, e in pairs(surface.find_entities_filtered({
    area = { { position.x - hx, position.y - hy }, { position.x + hx, position.y + hy } },
  })) do
    if e.prototype.fast_replaceable_group == group then
      out[#out + 1] = e
    end
  end
  return out
end

-- Items go to the character; what doesn't fit is spilled at its feet, as the game does.
local function give(c, stack)
  local inserted = c.insert(stack)
  if inserted < stack.count then
    stack.count = stack.count - inserted
    pcall(function() c.surface.spill_item_stack({ position = c.position, stack = stack }) end)
  end
end

---------------------------------------------------------------------------------------------

-- M2 (the owner: placing undergrounds over belts should remove the belts between them). Factorio's own rule, its
-- tips and tricks ("Fast replace belt & underground belt", base.cfg): "Any belts in between the entrance and exit of
-- the underground belt will be mined automatically. This fast replace feature also applies to pipe and
-- pipe-to-ground." What its developers have said of when (forum answers): only "simple" belts, the underground's
-- way and straight, with "no incoming side connections"; every tile between holding a pipe and none of them with a
-- perpendicular connection. So all or none: a gap, a curve, a belt the other way, a splitter, a ghost or a side-load
-- anywhere between and nothing goes. A player's build does it; a script's create_entity doesn't, with or without
-- `character` (measured in 2.1.24: the run stayed both ways), so for its player-less character the bridge mines them
-- into the character itself, items and all, as LuaControl.mine_entity does (measured: a belt's items come too; full,
-- forced, they spill), and says each at once.
local UNDERGROUND = { ["underground-belt"] = true, ["pipe-to-ground"] = true }

local function on(e)
  return e and e.valid and e or nil
end

-- The other end of an underground belt or pipe-to-ground as the game connected it, or nil. (2.1's
-- underground_belt_neighbour, 2.0's neighbours; a pipe-to-ground's underground pipe connection's target.)
local function partner_of(e)
  if e.type == "underground-belt" then
    local ok, other = pcall(function() return e.underground_belt_neighbour end)
    if not ok then
      ok, other = pcall(function() return e.neighbours end)
    end
    return ok and on(other) or nil
  end
  local ok, conns = pcall(function() return e.get_fluid_box_pipe_connections(1) end)
  for _, conn in pairs(ok and conns or {}) do
    if conn.connection_type == "underground" and on(conn.target) then
      return conn.target
    end
  end
  return nil
end

-- What stands on the tile at `at` of `type` (one, or nil when none or several).
local function only_one(surface, at, type)
  local found = surface.find_entities_filtered({ position = at, type = type })
  if #found ~= 1 then
    return nil
  end
  return found[1]
end

-- A plain belt of the run: the run's way, straight, fed by nothing but `behind` (the belt before it in the run, or
-- the entrance, which feeds nothing on the surface).
local function plain_belt(b, way, behind)
  if b.direction ~= way or b.belt_shape ~= "straight" then
    return false
  end
  for _, input in pairs(b.belt_neighbours.inputs) do
    if not (input.valid and input.unit_number == behind.unit_number) then
      return false
    end
  end
  return true
end

-- A plain pipe of the run: whatever it connects to lies on the run's line (`horizontal`: its row).
local function plain_pipe(p, at, horizontal)
  local ok, conns = pcall(function() return p.get_fluid_box_pipe_connections(1) end)
  if not ok then
    return false
  end
  for _, conn in pairs(conns or {}) do
    if conn.target then
      local t = conn.target_position
      if (horizontal and t.y ~= at.y) or (not horizontal and t.x ~= at.x) then
        return false
      end
    end
  end
  return true
end

-- The belts (pipes) between `e`, just built, and its other end when every tile between holds a plain one of the
-- character's force; nil when there is none between or anything breaks the run.
local function run_between(c, e)
  local other = partner_of(e)
  if not other then
    return nil
  end
  local belt = e.type == "underground-belt"
  -- Walked from the entrance (a belt's input end) to the exit; a pipe's either way.
  local from, to = e, other
  if belt and e.belt_to_ground_type ~= "input" then
    from, to = other, e
  end
  local a, b = from.position, to.position
  local dx, dy = b.x - a.x, b.y - a.y
  if (dx ~= 0) == (dy ~= 0) then
    return nil
  end
  local n = math.floor(math.abs(dx + dy) + 0.5)
  local sx, sy = dx > 0 and 1 or dx < 0 and -1 or 0, dy > 0 and 1 or dy < 0 and -1 or 0
  local list, behind = {}, from
  for i = 1, n - 1 do
    local at = { x = a.x + sx * i, y = a.y + sy * i }
    local x = only_one(e.surface, at, belt and "transport-belt" or "pipe")
    if not (x and x.force == c.force) then
      return nil
    end
    if belt then
      if not plain_belt(x, from.direction, behind) then
        return nil
      end
    elseif not plain_pipe(x, at, sy == 0) then
      return nil
    end
    list[i] = x
    behind = x
  end
  return #list > 0 and list or nil
end

-- After the character built `e` (not over another underground, `upgrade`: that completes no new pair): the plain run
-- between its ends mined into the character, as Factorio's player build does.
local function clear_between(c, e, upgrade)
  if upgrade or not (perf.on("under_clear") and e and e.valid and UNDERGROUND[e.type]) then
    return
  end
  local ok, list = pcall(run_between, c, e)
  if not ok then
    log("[factorio-3d-bridge] under_clear: " .. tostring(list))
    return
  end
  if list then
    puppet.mine_for_build(c, list)
  end
end

---------------------------------------------------------------------------------------------

-- Whether a tile under the footprint is one the entity can't stand on (empty space round a
-- platform, water): the script check below doesn't look at tiles (2.1.23 answers true over space).
local function on_bad_tiles(surface, proto, position, direction)
  local ok, mask = pcall(function() return proto.collision_mask end)
  local layers = ok and mask and mask.layers
  if not layers or next(layers) == nil then
    return false
  end
  local w, h = proto.tile_width, proto.tile_height
  if direction == defines.direction.east or direction == defines.direction.west then
    w, h = h, w
  end
  local okc, n = pcall(function()
    return surface.count_tiles_filtered({
      area = { { position.x - w / 2 + 0.1, position.y - h / 2 + 0.1 }, { position.x + w / 2 - 0.1, position.y + h / 2 - 0.1 } },
      collision_mask = layers, limit = 1,
    })
  end)
  return okc and n > 0
end

-- Factorio's manual check, and where the force hasn't charted the chunk (a headless server charts
-- nothing by itself) the script check, which leaves out what manual checks for: the tiles and the
-- surface's conditions (a chest needs gravity, so not on a platform) are checked here instead.
-- Without them ghosts went onto empty space or broke a platform's rules and never got built (F6).
local function can_place(surface, proto, position, direction, force, check)
  local spec = { name = proto.name, position = position, direction = direction, force = force, build_check_type = check }
  if surface.can_place_entity(spec) then
    return true
  end
  if force.is_chunk_charted(surface, { math.floor(position.x / 32), math.floor(position.y / 32) }) then
    return false
  end
  if space.cant_build(surface, proto) or on_bad_tiles(surface, proto, position, direction) then
    return false
  end
  spec.build_check_type = defines.build_check_type.script
  return surface.can_place_entity(spec)
end

-- Why Factorio refused to build `proto` at `position`, in its words where the bridge can tell: the planet's conditions
-- (Space Age), or a drill with a fluid input whose mining area holds a resource that needs fluid (uranium ore) while the
-- force can't mine with fluid yet ("Uranium mining not researched.", 2.1.24's cant-build-reason: refused even with other
-- ore beside it, allowed once researched). Otherwise "Can't place that there".
local function refusal(surface, proto, position, force)
  local planet = space.cant_build(surface, proto)
  if planet then
    return planet
  end
  if proto.type == "mining-drill" and not force.mining_with_fluid then
    local okr, r = pcall(function() return proto.mining_drill_radius end)
    local okc, cats = pcall(function() return proto.resource_categories end)
    local okf, boxes = pcall(function() return proto.fluidbox_prototypes end)
    local wet = false
    for _, box in ipairs(okf and boxes or {}) do
      local okd, flow = pcall(function() return box.production_type end)
      wet = wet or not (okd and flow == "output")
    end
    if okr and r and okc and type(cats) == "table" and wet then
      local area = { { position.x - r, position.y - r }, { position.x + r, position.y + r } }
      for _, res in pairs(surface.find_entities_filtered({ area = area, type = "resource" })) do
        local rp = res.prototype
        local okm, fluid = pcall(function() return rp.mineable_properties.required_fluid end)
        if okm and fluid and cats[rp.resource_category] then
          return "Uranium mining not researched."
        end
      end
    end
  end
  return "Can't place that there"
end

local function footprint_box(proto, position, direction)
  local w, h = proto.tile_width, proto.tile_height
  if direction == defines.direction.east or direction == defines.direction.west then
    w, h = h, w
  end
  local hx, hy = math.max(w / 2 - 0.05, 0.05), math.max(h / 2 - 0.05, 0.05)
  return { { position.x - hx, position.y - hy }, { position.x + hx, position.y + hy } }
end

local function destroy_colliding_ghosts(surface, proto, position, direction, force)
  if string.sub(proto.type or "", 1, 9) == "elevated-" or (proto.tile_width or 0) <= 0 or (proto.tile_height or 0) <= 0 then
    return
  end
  local box = footprint_box(proto, position, direction)
  for _, g in pairs(surface.find_entities_filtered({ area = box, type = "entity-ghost", force = force })) do
    if g.valid and string.sub(g.ghost_type or "", 1, 9) ~= "elevated-" then
      local removal = tracker.removal_message(g)
      local gp = g.position
      g.destroy()
      if removal then
        transport.send_reliable_priority(removal, math.floor(gp.x / 32), math.floor(gp.y / 32))
      end
    end
  end
end

-- A ghost of the entity for robots to build (Shift+click, or a pipette with none in the
-- inventory), like a player's; no reach limit and no item needed. Super-forced (Ctrl+Shift+click)
-- marks what stands in the way for deconstruction and puts the ghost there anyway, as 2.x does.
local function build_ghost(c, proto, position, direction, mirror, super)
  local surface = puppet.surface(c)
  if ghost_at(surface, proto, position) or same_entity(surface, proto, position) then
    return
  end
  if not map.check_charted(c, position) then
    return
  end
  local spec = { name = "entity-ghost", inner_name = proto.name, position = position, direction = direction,
    force = c.force, raise_built = true }
  if mirror then
    spec.mirror = true
  end
  if proto.type == "underground-belt" then
    spec.type = underground_type(surface, proto, position, direction)
  end
  if super and not can_place(surface, proto, position, direction, c.force, defines.build_check_type.manual_ghost) then
    local w, h = proto.tile_width or 0, proto.tile_height or 0
    if direction == defines.direction.east or direction == defines.direction.west then
      w, h = h, w
    end
    if w > 0 and h > 0 then
      local area = { { position.x - w / 2 + 0.1, position.y - h / 2 + 0.1 },
        { position.x + w / 2 - 0.1, position.y + h / 2 - 0.1 } }
      tracker.deconstructing(surface, area, c.force, function()
        surface.deconstruct_area({ area = area, force = c.force })
      end)
    end
    if surface.create_entity(spec) then
      return
    end
  end
  if not can_place(surface, proto, position, direction, c.force, defines.build_check_type.manual) then
    return puppet.message(refusal(surface, proto, position, c.force))
  end
  destroy_colliding_ghosts(surface, proto, position, direction, c.force)
  if not surface.create_entity(spec) then
    puppet.message(refusal(surface, proto, position, c.force))
  end
end

-- {item, x, y (fixed cursor position), d, q? (quality), ghost? (1: a ghost), sf? (1: super-forced
-- ghost), m? (1: flipped), hs? (the main inventory slot the client's hand holds it from: that stack
-- pays, L7)}: places one of the item's entity.
function M.build(cmd)
  local c = puppet.get()
  if not c then
    return
  end
  local item_name = tostring(cmd.item or "")
  local item = prototypes.item[item_name]
  local proto = item and registry.place_result(item)
  if not proto then
    return puppet.message("Can't build " .. item_name)
  end
  local inventory = c.get_main_inventory()
  local quality = inventory and pick_quality(inventory, item_name,
    (cmd.q and tostring(cmd.q)) or puppet.held_quality(inventory, cmd.hs, item_name) or nil)
  local held = quality and puppet.held_stack(inventory, cmd.hs, item_name, quality) or nil
  if not quality and cmd.ghost ~= 1 then
    return puppet.message("You have no " .. item_name)
  end
  local fx, fy = tonumber(cmd.x), tonumber(cmd.y)
  if not fx or not fy then
    return
  end
  local direction = math.floor(tonumber(cmd.d) or 0) % 16
  local w, h = proto.tile_width, proto.tile_height
  if direction == defines.direction.east or direction == defines.direction.west then
    w, h = h, w
  end
  local grid = grid_size(proto)
  local position = { x = snap(fx / 256, w, grid), y = snap(fy / 256, h, grid) }
  local surface = puppet.surface(c)
  if ROLLING_STOCK[proto.type] then
    position, direction = on_rail(surface, { x = fx / 256, y = fy / 256 }, direction)
    if not position then
      return puppet.message("Rolling stock goes on rails")
    end
  end
  if RAIL_SNAP[proto.type] then
    local at, facing = snap_to_rail(surface, proto, { x = fx / 256, y = fy / 256 }, direction, c.force, cmd.ghost == 1)
    if at then
      position, direction = at, facing
    end
  end
  if cmd.ghost == 1 then
    return build_ghost(c, proto, position, direction, cmd.m == 1, cmd.sf == 1)
  end
  if distance(c.position, position) > c.build_distance + REACH_SLACK then
    return puppet.message("Out of reach")
  end

  -- With a player to act as, build from their cursor, so Factorio raises on_built_entity for other
  -- mods and applies its own rules (fast-replace, ghosts, undergrounds); see as_player.lua.
  local same_first = same_entity(surface, proto, position)
  if not (same_first and quality_name(same_first) == quality) and not ROLLING_STOCK[proto.type] then
    local built = as_player.build(c, item_name, quality, position, direction, cmd.m == 1, surface, held)
    if built ~= nil then
      if not built then
        puppet.message(refusal(surface, proto, position, c.force))
      end
      return
    end
  end

  -- Building over a ghost of it fills the ghost in (keeping its settings), like a player does.
  local ghost = ghost_at(surface, proto, position)
  if ghost then
    local removal = tracker.removal_message(ghost)
    local ok, collided, revived = pcall(function() return ghost.revive({ raise_revive = true }) end)
    if ok and revived then
      if removal then
        transport.send_reliable_priority(removal, math.floor(position.x / 32), math.floor(position.y / 32))
      end
      -- What lay in the way (array[ItemWithQualityCount] in 2.1) goes to the character.
      for _, it in pairs(collided or {}) do
        give(c, { name = it.name, count = it.count, quality = it.quality })
      end
      puppet.take_held(inventory, cmd.hs, item_name, 1, quality)
      clear_between(c, revived, false)
      return
    end
  end

  -- The same entity already there: turn it (like building a belt over itself), costing nothing.
  local same = same_entity(surface, proto, position)
  if same and quality_name(same) == quality then
    if same.direction ~= direction and same.rotatable and same.force == c.force then
      same.direction = direction
      tracker.changed(same)
    end
    return
  end

  local olds = replaced_entities(surface, proto, position, w, h)
  local build_dir = direction

  local spec = { name = proto.name, position = position, direction = build_dir, force = c.force, raise_built = true }
  if cmd.m == 1 then
    spec.mirror = true
  end
  if proto.type == "underground-belt" then
    spec.type = underground_type(surface, proto, position, build_dir)
  end
  if quality ~= "normal" then
    spec.quality = quality
  end
  -- Fast-replace first: can_place_entity also answers true where the entity would replace what
  -- stands there (2.1), but create_entity without fast_replace then builds nothing.
  local entity
  local upgrade = false
  if #olds > 0 and surface.can_fast_replace({ name = proto.name, position = position, direction = build_dir, force = c.force }) then
    -- Fast-replace without a player: the old entities' items are ours to hand back, and their
    -- removal ours to report (the game raises no destroy event for them).
    local gone = {}
    for i, old in ipairs(olds) do
      gone[i] = { old = old, removal = tracker.removal_message(old), quality = quality_name(old),
        products = old.prototype.mineable_properties.products or {} }
      upgrade = upgrade or UNDERGROUND[old.type] == true
    end
    spec.fast_replace = true
    -- M2: an underground over a belt (a pipe-to-ground over a pipe) as the character's own fast-replace: the game
    -- hands the belt and the items on it to the character (2.1.24, measured), where spill = false deleted the items.
    local as_character = perf.on("under_clear") and UNDERGROUND[proto.type] and not upgrade
    if as_character then
      spec.character = c
    else
      spec.spill = false
    end
    destroy_colliding_ghosts(surface, proto, position, build_dir, c.force)
    entity = surface.create_entity(spec)
    if entity then
      for _, g in ipairs(gone) do
        if not g.old.valid then
          if g.removal then
            transport.send_reliable_priority(g.removal, math.floor(g.removal.x / 8192), math.floor(g.removal.y / 8192))
          end
          for _, product in pairs(as_character and {} or g.products) do
            if product.type == "item" then
              local stack = { name = product.name, count = product.amount or product.amount_min or 1 }
              if g.quality ~= "normal" then
                stack.quality = g.quality
              end
              give(c, stack)
            end
          end
        end
      end
    end
  elseif surface.can_place_entity({
    name = proto.name, position = position, direction = build_dir, force = c.force,
    build_check_type = defines.build_check_type.manual,
  }) then
    destroy_colliding_ghosts(surface, proto, position, build_dir, c.force)
    entity = surface.create_entity(spec)
  else
    -- Space Age: the planet's pressure, gravity or magnetic field may be what forbids it.
    return puppet.message(refusal(surface, proto, position, c.force))
  end
  if not entity then
    return puppet.message("Can't place that there")
  end
  puppet.take_held(inventory, cmd.hs, item_name, 1, quality)
  clear_between(c, entity, upgrade)
end

return M
