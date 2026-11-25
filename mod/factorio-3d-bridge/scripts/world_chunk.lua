-- Entity record serialization and wire-signature helpers for world.lua.
-- Reads game entities and writes `storage.f3d.stock_ghosts` for rolling stock ghosts.

local registry = require("scripts.registry")
local transport = require("scripts.transport")
local alt_mode = require("scripts.alt_mode")
local belt_switch = require("scripts.belt_switch")
local entity_ui = require("scripts.entity_ui")
local perf = require("scripts.perf")

local M = {}

local function fixed(v)
  return math.floor(v * 256 + 0.5)
end

-- Which sides a pipe connects on, as a bitmask: 1 north, 2 east, 4 south, 8 west. Only ordinary
-- connections to something (a pipe-to-ground's underground side isn't one).
local function pipe_mask(entity)
  local mask = 0
  local p = entity.position
  -- 2.1 has no LuaEntity.fluidbox: fluid boxes are counted by fluids_count.
  for i = 1, entity.fluids_count do
    for _, c in pairs(entity.get_fluid_box_pipe_connections(i) or {}) do
      if c.target and c.connection_type == "normal" then
        local dx, dy = c.target_position.x - p.x, c.target_position.y - p.y
        if math.abs(dy) >= math.abs(dx) then
          mask = bit32.bor(mask, dy < 0 and 1 or 4)
        else
          mask = bit32.bor(mask, dx > 0 and 2 or 8)
        end
      end
    end
  end
  return mask
end

-- Types whose colour the player sets (the client tints their paint with it).
local PAINTED = { locomotive = true, ["cargo-wagon"] = true, ["fluid-wagon"] = true, ["artillery-wagon"] = true,
  ["train-stop"] = true, ["character-corpse"] = true }

-- Lightweight lamp colour hint for chunk snapshots (same encoding as movers.lua's `lc`),
-- returning 0xRRGGBB or -1 for Factorio's plain white.
local function lamp_color_rgb(e)
  local c
  local okb, cb = pcall(function() return e.get_control_behavior() end)
  if okb and cb then
    local okc, v = pcall(function() return cb.use_colors and cb.color or nil end)
    c = okc and v or nil
  end
  if type(c) ~= "table" then
    local okc, v = pcall(function() return e.color end)
    c = okc and v or nil
  end
  if type(c) ~= "table" then
    return -1
  end
  local r, g, b = tonumber(c.r or c[1]) or 1, tonumber(c.g or c[2]) or 1, tonumber(c.b or c[3]) or 1
  local scale = (r > 1 or g > 1 or b > 1) and 1 or 255
  local function part(v)
    return math.max(0, math.min(255, math.floor(v * scale + 0.5)))
  end
  local R, G, B = part(r), part(g), part(b)
  if R == 255 and G == 255 and B == 255 then
    return -1
  end
  return R * 65536 + G * 256 + B
end

-- Snapshot hint for distant lamps past `focus.r`: bit 0 powered/connected, bit 1 Always on, plus
-- optional `lc` (0xRRGGBB) when non-white. Omitted on unpowered/unplugged/disabled lamps.
local function lamp_extra(entity)
  local status = entity.status
  local net = entity.electric_network_id
  local st = defines.entity_status
  local powered = net ~= nil and status ~= st.no_power and status ~= st.not_plugged_in_electric_network
    and status ~= st.disabled_by_control_behavior
  if not powered then
    return nil
  end
  local oka, ao = pcall(function() return entity.always_on end)
  local out = { lp = (oka and ao == true) and 3 or 1 }
  local okc, col = pcall(lamp_color_rgb, entity)
  if okc and col and col >= 0 then
    out.lc = col
  end
  return out
end

-- Snapshot hint for distant rail signals past `focus.r`: 1 green, 2 yellow, 3 red, 4 blue
-- (same encoding as movers.lua's `st`), so signals glow and tint accurately at any view distance.
local sig_state_names, chain_state_names
local function signal_colour(entity)
  if not sig_state_names then
    sig_state_names = {}
    for k, v in pairs(defines.signal_state or {}) do
      sig_state_names[v] = k
    end
  end
  local ok, state = pcall(function() return sig_state_names[entity.signal_state] end)
  if ok and state == "reserved" then
    return 2
  end
  if entity.type == "rail-chain-signal" then
    if not chain_state_names then
      chain_state_names = {}
      for k, v in pairs(defines.chain_signal_state or {}) do
        chain_state_names[v] = k
      end
    end
    local ok2, chain = pcall(function() return chain_state_names[entity.chain_signal_state] end)
    if ok2 and chain == "partially_open" then
      return 4
    elseif ok2 and chain == "none_open" then
      return 3
    end
  end
  if ok and (state == "closed" or state == "reserved_by_circuit_network") then
    return 3
  end
  return 1
end

local function extra_of_type(entity, t)
  if registry.is_pipe(t) then
    local ok, mask = pcall(pipe_mask, entity)
    return ok and { pc = mask } or nil
  end
  if t == "transport-belt" then
    return { s = string.sub(entity.belt_shape, 1, 1) }
  elseif t == "underground-belt" then
    return { u = string.sub(entity.belt_to_ground_type, 1, 1) }
  elseif t == "linked-belt" then
    return { u = string.sub(entity.linked_belt_type, 1, 1) }
  elseif t == "corpse" or t == "rail-remnants" then
    -- What the remnants were (the client draws its model broken).
    local of = registry.remnant_of(entity.name)
    return of and { rm = of } or nil
  elseif t == "resource" then
    return { a = entity.amount }
  elseif t == "entity-ghost" then
    if entity.ghost_type == "underground-belt" then
      return { gh = registry.entity_id(entity.ghost_name), u = string.sub(entity.belt_to_ground_type, 1, 1) }
    end
    return { gh = registry.entity_id(entity.ghost_name) }
  elseif t == "tile-ghost" then
    return { tg = registry.tile_id(entity.ghost_name) }
  elseif t == "train-stop" then
    return { n = entity.backer_name }
  elseif t == "cliff" then
    -- Which piece of a cliff chain this is ("west-to-east", "none-to-north", ...).
    return { co = entity.cliff_orientation }
  elseif t == "lamp" then
    local ok, lp = pcall(lamp_extra, entity)
    return ok and lp or nil
  elseif t == "rail-signal" or t == "rail-chain-signal" then
    local ok, sg = pcall(signal_colour, entity)
    local out = (ok and sg and sg >= 1 and sg <= 4) and { sg = sg } or nil
    -- On elevated rails (el = 1): the client stands it at the elevated track's height.
    local okl, elevated = pcall(function() return entity.rail_layer == defines.rail_layer.elevated end)
    if okl and elevated then
      out = out or {}
      out.el = 1
    end
    return out
  end
  return nil
end

local function quality_of(entity)
  return entity.quality.name
end

-- Marked for deconstruction (d = 1) or for an upgrade (up = the target's prototype id).
local function marks(entity)
  local out
  if entity.to_be_deconstructed() then
    out = { d = 1 }
  end
  if entity.to_be_upgraded() then
    out = out or {}
    out.up = registry.entity_id(entity.get_upgrade_target().name)
  end
  return out
end

-- Copper and circuit wires from this entity, by the unit numbers at their other end:
-- {w = copper, r = red, g = green}, or nil without any. 2.x keeps wires on wire connectors.
local WIRE_KEYS
local function wires(entity)
  if not WIRE_KEYS then
    WIRE_KEYS = { [defines.wire_type.copper] = "w", [defines.wire_type.red] = "r", [defines.wire_type.green] = "g" }
  end
  local out
  for _, connector in pairs(entity.get_wire_connectors(false)) do
    local key = WIRE_KEYS[connector.wire_type]
    for _, connection in pairs(connector.connections) do
      local unit = connection.target.owner.unit_number
      if key and unit then
        out = out or {}
        out[key] = out[key] or {}
        table.insert(out[key], unit)
      end
    end
  end
  return out
end

-- The entity's wires as a string, to notice when one is added or removed (no event for that).
function M.wire_signature(entity)
  local ok, w = pcall(wires, entity)
  if not ok or not w then
    return ""
  end
  local parts = {}
  for _, key in ipairs({ "w", "r", "g" }) do
    local units = w[key] or {}
    table.sort(units)
    parts[#parts + 1] = key .. table.concat(units, ",")
  end
  return table.concat(parts, ";")
end

-- Quality (2.x) only when it isn't normal, so most records stay short.
local function quality_extra(entity)
  local q = quality_of(entity)
  return q ~= "normal" and { q = q } or nil
end

-- Quality, marks and, for entities with a unit number, wires: the client draws a wire when
-- either end lists the other.
local function all_extras(entity, has_unit)
  local out = quality_extra(entity) or {}
  for k, v in pairs(marks(entity) or {}) do
    out[k] = v
  end
  if has_unit then
    for k, v in pairs(wires(entity) or {}) do
      out[k] = v
    end
  end
  return out
end

-- What a record carries beyond its id, place and direction; painted things add their colour.
local function extra(entity, t)
  local x = extra_of_type(entity, t)
  if PAINTED[t] then
    -- The colour the player gave it (H21: trains and stops were drawn in their models' grey).
    local ok, c = pcall(function()
      -- A stop nobody painted still wears its prototype's red, as Factorio draws it.
      return entity.color or (t == "train-stop" and entity.prototype.color) or nil
    end)
    if ok and c then
      x = x or {}
      x.col = entity_ui.color_out(c)
    end
  end
  return x
end

-- Ghosts of rolling stock (issue #13). Their `direction` stays north whichever way they face, so
-- the record gets the nearest of 16 directions to their orientation. And a train the robots build
-- is a mover, never `add`ed, so the client can't drop its ghost on seeing it built there, as it
-- does for buildings: the ghost is registered for on_object_destroyed when it is sent, and its
-- going sends `del` (tracker.on_object_destroyed). Kept per client, in storage.f3d.stock_ghosts.
local STOCK = { locomotive = true, ["cargo-wagon"] = true, ["fluid-wagon"] = true, ["artillery-wagon"] = true }

local function stock_ghost(entity, rec)
  local ok, orientation = pcall(function() return entity.orientation end)
  if ok and type(orientation) == "number" then
    rec[5] = math.floor(orientation * 16 + 0.5) % 16
  end
  local s = storage.f3d
  local ok_reg, reg = pcall(script.register_on_object_destroyed, entity)
  if s and ok_reg and reg then
    s.stock_ghosts = s.stock_ghosts or {}
    s.stock_ghosts[reg] = { u = rec[1], p = rec[2], x = rec[3], y = rec[4], s = entity.surface.index }
  end
end

-- records_by_prototype (perf.lua): what a record needs of its entity's prototype, read once a name
-- ({type, id, natural}; from prototypes alone, so module-local is fine), not entity.type five or six
-- times a record. Natural entities (trees, rocks, ore, cliffs, fish: most of a chunk away from a base)
-- have no quality, upgrade or wires to read: only their deconstruction mark.
local NATURAL = { tree = true, ["simple-entity"] = true, resource = true, cliff = true, fish = true }
local proto_info = {}

local function info_of(entity)
  local name = entity.name
  local info = proto_info[name]
  if not info then
    local t = entity.type
    info = { t, registry.entity_id(name), NATURAL[t] or false }
    proto_info[name] = info
  end
  return info
end

local function natural_record(entity, info)
  local p = entity.position
  local t = info[1]
  local rec = { entity.unit_number or 0, info[2], fixed(p.x), fixed(p.y), entity.direction or 0 }
  local x = extra_of_type(entity, t)
  local ok, marked = pcall(entity.to_be_deconstructed)
  if ok and marked then
    x = x or {}
    x.d = 1
  end
  if x then
    rec[6] = x
  end
  return rec
end

-- [unit_number or 0, prototype id, x, y, direction, extra?]
-- Entities without a unit number (trees, rocks, ore) are identified by prototype + position.
local record_of
function M.record(entity)
  if perf.on("records_by_prototype") then
    local info = info_of(entity)
    if info[3] then
      return natural_record(entity, info)
    end
    return record_of(entity, info[1], info[2])
  end
  return record_of(entity, entity.type, registry.entity_id(entity.name))
end

record_of = function(entity, t, id)
  local p = entity.position
  local rec = { entity.unit_number or 0, id, fixed(p.x), fixed(p.y), entity.direction or 0 }
  if t == "entity-ghost" and STOCK[entity.ghost_type] then
    stock_ghost(entity, rec)
  end
  local x = extra(entity, t)
  -- Quality, marks and wires (2.x API) in one protected call: a record is made for every entity
  -- in a chunk snapshot, so this is the bridge's busiest path. If it fails, each is tried alone
  -- so one missing API doesn't lose the others.
  local ok, more = pcall(all_extras, entity, rec[1] ~= 0)
  if not ok then
    more = {}
    for _, f in ipairs({ quality_extra, marks, rec[1] ~= 0 and wires or nil }) do
      local ok2, part = pcall(f, entity)
      if ok2 and part then
        for k, v in pairs(part) do
          more[k] = v
        end
      end
    end
  end
  if more and next(more) then
    x = x or {}
    for k, v in pairs(more) do
      x[k] = v
    end
  end
  -- Alt-mode's icon (issue #9): with the record, so every loaded machine has it, no scanning.
  -- and its machine or pump arrows (part 2, extra.fa).
  if rec[1] ~= 0 and alt_mode.TYPES[t] then
    local icon, arrows = alt_mode.state(entity)
    if icon then
      x = x or {}
      x.ai = icon
    end
    if arrows then
      x = x or {}
      x.fa = arrows
      -- Which fluid each connection takes or gives (L10).
      x.fc = alt_mode.connections(entity)
    end
    alt_mode.recorded(entity, icon, x, arrows)
  end
  if rec[1] ~= 0 and belt_switch.TYPES[t] then
    belt_switch.recorded(entity, x)
  end
  if x then
    rec[6] = x
  end
  return rec
end

-- A record as JSON text (chunk_text, perf.lua): its five numbers (integers all) by table.concat, its
-- extras key by key (transport.json_object). Read by the client as what helpers.table_to_json wrote,
-- at a tenth of the cost.
local concat = table.concat
function M.record_text(rec)
  local x = rec[6]
  if x then
    return "[" .. concat(rec, ",", 1, 5) .. "," .. transport.json_object(x) .. "]"
  end
  return "[" .. concat(rec, ",", 1, 5) .. "]"
end

return M
