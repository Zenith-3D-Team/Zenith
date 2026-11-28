-- Alt-mode's icons (issue #9): what each machine is set to make or let through, an assembler's or
-- furnace's recipe, an inserter's, loader's, splitter's, storage chest's or drill's filters, a
-- requester or buffer chest's first four requests.
--
-- They ride on the entity records (`extra.ai`, world.lua), so every building the client has loaded
-- has its icon from the moment it arrives, with no scanning and no limit. What changes them:
--   * with an event: building (a new record), Shift+paste and the bridge's own settings (tracker
--     sends `upd`), a player closing the entity's window in the real game (on_gui_closed), the
--     screen the client has open (screens.lua checks its entity twice a second);
--   * without one: a furnace picks its recipe from what is put in, and a circuit network can set
--     an assembler's recipe or an inserter's, loader's or splitter's filters. Those entities (a
--     furnace, or one with a red or green wire) are watched: each record of one puts it in
--     storage.f3d.altw, and a few of them a tick are read again under the work budget, `aiu`
--     carrying what changed. Scripts changing the rest are seen when the chunk is next sent.
--
-- Everything here runs from events and on_tick, and what it keeps (storage.f3d.altw) only from
-- the records the client is sent, so it stays the same on every peer.
--
-- Also the chests' contents (J6, at the end): Factorio's Alt-mode draws over a container what is in
-- it. Nothing tells a mod when that changes, so they are read in rounds, only while the client has
-- Alt-mode on. The same rounds read the modules in machines and the science packs in labs (K1, K2),
-- which robots and inserters change without an event too.

local transport = require("scripts.transport")
local budget = require("scripts.budget")
local rate = require("scripts.rate")
local perf = require("scripts.perf")

local M = {}

local CHUNK = 32
-- Read again per tick at most (the work budget may allow fewer): with a few thousand watched
-- machines each is looked at every few seconds.
local WATCH_PER_TICK = 24
-- A watched machine's look costs about as much as a record (budget.lua's units).
local WATCH_PRICE = 2
-- A round over the watched machines starts at most this often.
local ROUND_TICKS = 120

local TYPES = {
  ["assembling-machine"] = true, furnace = true, ["rocket-silo"] = true, inserter = true, loader = true,
  ["loader-1x1"] = true, splitter = true, ["lane-splitter"] = true, ["logistic-container"] = true,
  ["mining-drill"] = true,
}
M.TYPES = TYPES
-- Their recipe or filters can change with no event if the circuit network sets them.
local CIRCUIT_SET = {
  ["assembling-machine"] = true, inserter = true, loader = true, ["loader-1x1"] = true, splitter = true,
  ["lane-splitter"] = true, ["mining-drill"] = true, ["logistic-container"] = true,
}

-- Module-local pcall/sort helpers so hot loops allocate zero closures.
local function get_name_field(obj) return obj.name end
local function get_filter_slot_count(e) return e.filter_slot_count end
local function get_filter_at(e, i) return e.get_filter(i) end
local function get_logistic_sections(e) return e.get_logistic_sections() end
local function get_sections(point) return point.sections end
local function get_section_active(section) return section.active end
local function get_recipe(e) return e.get_recipe() end
local function get_previous_recipe(e) return e.previous_recipe end
local function get_force_recipe(e, name) return e.force.recipes[name] end
local function get_splitter_filter(e) return e.splitter_filter end
local function get_first_filter(e) return e.filter_slot_count > 0 and e.get_filter(1) end
local function get_fluids_count(e) return e.fluids_count end
local function get_fluid_filter(e, i) return e.get_fluid_filter(i) end
local function get_fluid_at(e, i) return e.get_fluid(i) end
local function get_fluid_box_conns(e, i) return e.get_fluid_box_pipe_connections(i) end
local function get_ghost_prototype(e) return e.ghost_prototype end
local function get_prototype(e) return e.prototype end
local function get_mining_drill_radius(proto) return proto.mining_drill_radius end
local function get_resource_categories(proto) return proto.resource_categories end
local function get_fluidbox_prototypes(proto) return proto.fluidbox_prototypes end
local function get_production_type(box) return box.production_type end
local function get_pipe_connections(box) return box.pipe_connections end
local function get_required_fluid(proto) return proto.mineable_properties.required_fluid end
local function get_resource_category(proto) return proto.resource_category end
local function find_resources(surface, area) return surface.find_entities_filtered({ area = area, type = "resource" }) end
local function get_define_inv(name) return defines.inventory[name] end
local function get_selection_box(proto) return proto.selection_box end
local function get_icon_draw_spec(proto) return proto.icon_draw_specification end
local function get_icons_pos(proto) return proto.icons_positioning end
local function get_module_inv_size(proto) return proto.module_inventory_size end
local function get_entity_inv(e, inv_id) return e.get_inventory(inv_id) end
local function get_module_inv(e) return e.get_module_inventory() end
local function inv_is_empty(inv) return inv.is_empty() end
local function get_inv_contents(inv) return inv.get_contents() end

local sort_counts
local function cmp_top_names(a, b)
  if sort_counts[a] ~= sort_counts[b] then
    return sort_counts[a] > sort_counts[b]
  end
  return a < b
end

local function signal_name(f)
  if type(f) ~= "table" then
    return nil
  end
  local name = f.name
  if type(name) ~= "string" and name ~= nil then -- a prototype (LuaObjects aren't tables)
    local ok, n = pcall(get_name_field, name)
    name = ok and n or nil
  end
  return type(name) == "string" and name or nil
end

-- Every filter set on the entity, in slot order: Alt-mode shows them all, shrunk to fit.
local function filter_names(e)
  local names = {}
  local ok, n = pcall(get_filter_slot_count, e)
  for i = 1, ok and n or 0 do
    local ok_f, f = pcall(get_filter_at, e, i)
    local name = ok_f and signal_name(f)
    if name then
      names[#names + 1] = name
    end
  end
  return names
end

-- A requester or buffer chest's requested items, the first `n` different ones in the order of its
-- active sections (owner: a mixed chest shows its first four, each a quarter of the icon). (Read
-- here, not through logistics.lua: world.lua requires this file, and logistics.lua world.lua.)
local function requested_names(e, n)
  local names, seen = {}, {}
  -- A chest's LuaLogisticSections (logistics.lua reads chests the same way).
  local ok, point = pcall(get_logistic_sections, e)
  if not (ok and point) then
    return names
  end
  local ok2, sections = pcall(get_sections, point)
  for _, section in pairs(ok2 and sections or {}) do
    local ok3, active = pcall(get_section_active, section)
    if not ok3 or active ~= false then
      for _, f in pairs(section.filters or {}) do
        local v = f.value
        local name = v and (v.type == nil or v.type == "item") and v.name
        if name and not seen[name] then
          seen[name] = true
          names[#names + 1] = name
          if #names >= n then
            return names
          end
        end
      end
    end
  end
  return names
end

local function entity_type(e)
  return e.type == "entity-ghost" and e.ghost_type or e.type
end

local function entity_proto(e)
  if e.type == "entity-ghost" then
    local ok, p = pcall(get_ghost_prototype, e)
    return ok and p or nil
  end
  local ok, p = pcall(get_prototype, e)
  return ok and p or nil
end

-- The recipe a crafting machine shows: its own, or for a furnace with none (it picks its recipe from
-- what is put in, and drops it whenever the input runs out between crafts) the last one it made.
-- Factorio's Alt-mode keeps that icon until the furnace takes another recipe (owner's J2; its
-- changelog: "Fixed that furnace alt-mode didn't show the last recipe, same as map view "Recipe
-- Icons" option"). 2.x: previous_recipe is {name, quality}, each a prototype or its name.
local function shown_recipe(e)
  local ok, recipe = pcall(get_recipe, e)
  if ok and recipe then
    return recipe
  end
  if e.type ~= "furnace" then
    return nil
  end
  local ok_p, prev = pcall(get_previous_recipe, e)
  if not (ok_p and type(prev) == "table") then
    return nil
  end
  local name = prev.name
  if type(name) ~= "string" then
    local ok_n, n = pcall(get_name_field, name)
    name = ok_n and n or nil
  end
  if type(name) ~= "string" then
    return nil
  end
  local ok_r, r = pcall(get_force_recipe, e, name)
  return ok_r and r or nil
end
M.shown_recipe = shown_recipe

-- [icon type, name, more?] for an entity's Alt-mode icon (more: the other filters' item names),
-- or nil.
function M.icon(e)
  local t = entity_type(e)
  if t == "assembling-machine" or t == "furnace" or t == "rocket-silo" then
    local recipe = shown_recipe(e)
    if recipe then
      return { "recipe", recipe.name }
    end
  elseif t == "inserter" or t == "loader" or t == "loader-1x1" then
    local names = filter_names(e)
    if #names > 0 then
      local first = table.remove(names, 1)
      return { "item", first, #names > 0 and names or nil }
    end
  elseif t == "splitter" or t == "lane-splitter" then
    local ok, f = pcall(get_splitter_filter, e)
    local name = ok and signal_name(f)
    if name then
      return { "item", name }
    end
  elseif t == "logistic-container" or t == "mining-drill" then
    local ok, f = pcall(get_first_filter, e)
    local name = ok and signal_name(f)
    if name then
      return { "item", name }
    end
    if t == "logistic-container" then
      local names = requested_names(e, 4)
      if #names > 0 then
        local first = table.remove(names, 1)
        return { "item", first, #names > 0 and names or nil }
      end
    end
  end
  if e.type == "entity-ghost" then
    local ok, reqs = pcall(function() return e.item_requests end)
    if ok and type(reqs) == "table" then
      local names, seen = {}, {}
      for k, v in pairs(reqs) do
        local name = type(k) == "string" and k or (type(v) == "table" and v.name)
        if type(name) == "string" and not seen[name] then
          seen[name] = true
          names[#names + 1] = name
          if #names >= 4 then
            break
          end
        end
      end
      if #names > 0 then
        local first = table.remove(names, 1)
        return { "item", first, #names > 0 and names or nil }
      end
    end
  end
  return nil
end

-- Alt-mode's machine arrows (issue #9 part 2, Factorio's "Show machine arrows in Alt-mode"): the
-- client draws them at the prototype's fluid connections (`eprops` fb). A crafting machine shows
-- only those its recipe uses, as Factorio does (checked in 2.1.23: with any fluid ingredient every
-- input connection, with any fluid product every output one), so its record carries `fa`, a mask:
-- 1 the recipe takes fluid, 2 it makes fluid. 2.1 has no LuaEntity.fluidbox, so it comes from the
-- recipe. Other machines (boilers, pumps) show all their connections and need nothing here.
local CRAFTERS = { ["assembling-machine"] = true, furnace = true }
M.CRAFTERS = CRAFTERS

-- Whether a mining drill prototype has a fluid input (electric mining drill yes; pumpjack output-only and
-- burner drill none).
local function drill_has_fluid_input(proto)
  if not proto then
    return false
  end
  local okb, boxes = pcall(get_fluidbox_prototypes, proto)
  if not (okb and type(boxes) == "table") then
    return false
  end
  for _, box in pairs(boxes) do
    local okp, ptype = pcall(get_production_type, box)
    if not (okp and ptype == "output") then
      local okc, conns = pcall(get_pipe_connections, box)
      if okc and type(conns) == "table" and next(conns) ~= nil then
        for _, conn in pairs(conns) do
          if conn.flow_direction ~= "output" then
            return true
          end
        end
      else
        return true
      end
    end
  end
  return false
end

-- A ghost mining drill has no live fluidbox (`fluids_count` 0), so detect whether its mining area holds a
-- resource requiring fluid (uranium ore's sulfuric acid), matching building.lua's refusal rule.
local function ghost_drill_fluid(e)
  local proto = entity_proto(e)
  if not drill_has_fluid_input(proto) then
    return nil
  end
  local okr, r = pcall(get_mining_drill_radius, proto)
  if not (okr and type(r) == "number" and r > 0) then
    return nil
  end
  local okc, cats = pcall(get_resource_categories, proto)
  if not (okc and type(cats) == "table") then
    return nil
  end
  local surface = e.surface
  local pos = e.position
  if not (surface and surface.valid and pos) then
    return nil
  end
  local area = { { pos.x - r, pos.y - r }, { pos.x + r, pos.y + r } }
  local okf, resources = pcall(find_resources, surface, area)
  if not (okf and type(resources) == "table") then
    return nil
  end
  for _, res in pairs(resources) do
    local okrp, rp = pcall(get_prototype, res)
    if okrp and rp then
      local okm, fluid = pcall(get_required_fluid, rp)
      if okm and fluid then
        local okcat, rcat = pcall(get_resource_category, rp)
        if okcat and cats[rcat] then
          return type(fluid) == "string" and fluid or true
        end
      end
    end
  end
  return nil
end

-- A mining drill takes fluid in while it has a fluid box (uranium ore's sulfuric acid; Factorio draws the electric
-- drill's three fluid connectors with its `wet_mining_graphics_set`): `fa` 1, as a crafter whose recipe takes fluid,
-- so the client draws its `-wet` model (model_library.gd wet_model). Read from the drill's own box, as the game keeps
-- it (2.1.24: `fluids_count` 1 over uranium, kept when the ore runs out and with one uranium tile in an iron drill's
-- area; 0 over iron alone), and for ghost drills from fluid-requiring resources in their mining area.
local function drill_arrows(e)
  if e.type == "entity-ghost" then
    return ghost_drill_fluid(e) and 1 or nil
  end
  local ok, count = pcall(get_fluids_count, e)
  if ok and type(count) == "number" and count > 0 then
    return 1
  end
  return nil
end

function M.arrows(e)
  local t = entity_type(e)
  if t == "mining-drill" then
    return drill_arrows(e)
  end
  if not CRAFTERS[t] then
    return nil
  end
  local recipe = shown_recipe(e)
  if not recipe then
    return nil
  end
  local mask = 0
  for _, i in pairs(recipe.ingredients) do
    if i.type == "fluid" then
      mask = 1
      break
    end
  end
  for _, p in pairs(recipe.products) do
    if p.type == "fluid" then
      mask = mask + 2
      break
    end
  end
  return mask > 0 and mask or nil
end

-- Which fluid goes in or out at each of a crafting machine's connections (L10: the owner couldn't tell
-- an oil refinery's). Factorio draws each connection's arrow and its fluid's icon while the machine is
-- selected or in Alt-mode (PipeConnectionDefinition::hide_connection_info). 2.1 makes a crafting
-- machine's fluid storages from its recipe (an oil refinery on basic oil processing has two, read in
-- 2.1.24), each filtered to its fluid, so they are read from the entity, turned and mirrored as it
-- stands: [[dx, dy, way, flow, fluid], ...] for its ordinary connections, (dx, dy) the connection's
-- tile from the entity's centre (tiles), way the direction its pipe leaves by (0, 4, 8, 12), flow "i",
-- "o" or "b", fluid its name ("" when nothing says). nil when it has none or `fluid_icons` is off.
local FLOW_LETTER = { input = "i", output = "o", ["input-output"] = "b" }

local function hundredths(v)
  return math.floor(v * 100 + 0.5) / 100
end

local function ghost_connections(e)
  local proto = entity_proto(e)
  if not proto then
    return nil
  end
  local okb, boxes = pcall(function() return proto.fluidbox_prototypes end)
  if not (okb and type(boxes) == "table") then
    return nil
  end
  local t = entity_type(e)
  local is_crafter = CRAFTERS[t] == true
  local drill_fluid = t == "mining-drill" and ghost_drill_fluid(e) or nil
  if t == "mining-drill" and drill_has_fluid_input(proto) and not drill_fluid then
    return nil
  end
  local recipe = shown_recipe(e)
  local ing_fluids, prod_fluids = {}, {}
  if recipe then
    for _, ing in pairs(recipe.ingredients or {}) do
      if ing.type == "fluid" and ing.name then
        ing_fluids[#ing_fluids + 1] = ing.name
      end
    end
    for _, prod in pairs(recipe.products or {}) do
      if prod.type == "fluid" and prod.name then
        prod_fluids[#prod_fluids + 1] = prod.name
      end
    end
  end
  local has_in = #ing_fluids > 0
  local has_out = #prod_fluids > 0
  if is_crafter and not has_in and not has_out then
    return nil
  end
  local dir = e.direction or 0
  local q = math.floor(dir / 4) % 4
  local okm, mir = pcall(function() return e.mirroring == true end)
  local mirror = okm and mir == true
  local out = {}
  local in_i, out_i = 0, 0
  for _, box in pairs(boxes) do
    local okf, bf = pcall(function() return box.filter end)
    local fixed_fluid = okf and bf and bf.name or nil
    local okpt, ptype = pcall(function() return box.production_type end)
    local box_fluid = fixed_fluid
    if not box_fluid and okpt then
      if ptype == "input" or ptype == "input-output" then
        in_i = in_i + 1
        box_fluid = ing_fluids[in_i] or ing_fluids[1]
        if not box_fluid and ptype == "input-output" then
          out_i = out_i + 1
          box_fluid = prod_fluids[out_i] or prod_fluids[1]
        end
      elseif ptype == "output" then
        out_i = out_i + 1
        box_fluid = prod_fluids[out_i] or prod_fluids[1]
      end
    end
    for _, conn in pairs(box.pipe_connections or {}) do
      local pos = conn.positions and conn.positions[1] or conn.position
      if conn.connection_type == "normal" and not conn.hide_connection_info and pos then
        local flow = FLOW_LETTER[conn.flow_direction] or "b"
        local used = not is_crafter
          or (flow == "i" and has_in)
          or (flow == "o" and has_out)
          or (flow == "b" and (has_in or has_out))
        if used then
          local ox = type(pos) == "table" and (pos.x or pos[1] or 0) or 0
          local oy = type(pos) == "table" and (pos.y or pos[2] or 0) or 0
          local cd = conn.direction or 0
          if mirror then
            ox = -ox
            cd = (16 - cd) % 16
          end
          if q == 1 then
            ox, oy = -oy, ox
          elseif q == 2 then
            ox, oy = -ox, -oy
          elseif q == 3 then
            ox, oy = oy, -ox
          end
          local way = (cd + q * 4) % 16
          local fname = box_fluid
          if not fname then
            if type(drill_fluid) == "string" then
              fname = drill_fluid
            elseif conn.flow_direction == "input" then
              fname = ing_fluids[1]
            elseif conn.flow_direction == "output" then
              fname = prod_fluids[1]
            else
              fname = ing_fluids[1] or prod_fluids[1]
            end
          end
          out[#out + 1] = { hundredths(ox), hundredths(oy), way, flow, fname or "" }
        end
      end
    end
  end
  return #out > 0 and out or nil
end

function M.connections(e)
  if not perf.on("fluid_icons") then
    return nil
  end
  if e.type == "entity-ghost" then
    return ghost_connections(e)
  end
  local t = entity_type(e)
  local fa = CRAFTERS[t] and M.arrows(e) or nil
  if CRAFTERS[t] and not fa then
    return nil
  end
  local ok, n = pcall(get_fluids_count, e)
  if not (ok and type(n) == "number") then
    return nil
  end
  local p = e.position
  local out = {}
  for i = 1, n do
    local okf, filter = pcall(get_fluid_filter, e, i)
    local name = okf and filter and filter.name or nil
    if not name then
      local okg, fluid = pcall(get_fluid_at, e, i)
      name = okg and fluid and fluid.name or nil
    end
    local okc, conns = pcall(get_fluid_box_conns, e, i)
    for _, c in pairs(okc and conns or {}) do
      local at, to = c.position, c.target_position
      local flow = FLOW_LETTER[c.flow_direction] or "b"
      local used = not fa
        or (flow == "i" and bit32.band(fa, 1) ~= 0)
        or (flow == "o" and bit32.band(fa, 2) ~= 0)
        or (flow == "b" and fa ~= 0)
      if c.connection_type == "normal" and at and to and used then
        local dx, dy = to.x - at.x, to.y - at.y
        local way
        if math.abs(dx) > math.abs(dy) then
          way = dx > 0 and 4 or 12
        else
          way = dy > 0 and 8 or 0
        end
        out[#out + 1] = { hundredths(at.x - p.x), hundredths(at.y - p.y), way, flow, name or "" }
      end
    end
  end
  return #out > 0 and out or nil
end

-- The icon as one string, to see whether it changed ("" for none).
function M.signature(icon, arrows)
  local s = ""
  if icon then
    s = icon[1] .. ":" .. icon[2]
    if icon[3] then
      s = s .. ":" .. table.concat(icon[3], ",")
    end
  end
  if arrows then
    s = s .. "|" .. arrows
  end
  return s
end

-- What Alt-mode shows over the entity: its icon and its arrows (either may be nil), and their signature.
function M.state(e)
  local t = entity_type(e)
  local icon = TYPES[t] and M.icon(e) or nil
  local arrows = (CRAFTERS[t] or t == "mining-drill") and M.arrows(e) or nil
  return icon, arrows, M.signature(icon, arrows)
end

local function chunk_key(p)
  return math.floor(p.x / CHUNK) .. "," .. math.floor(p.y / CHUNK)
end

-- (gc_lean) Forward declaration so M.recorded can mark the cached list dirty without global lookup.
-- inv_cache is a module-local read cache only (inventory handles, never decides what goes in storage);
-- the cached entity list lives in storage (altc.lc_meta.list) so every peer reuses the same one.
local inv_cache = {}
local inv_cache_si, inv_cache_client
local ALT_RESCAN_TICKS = 180
local mark_list_dirty

-- world.record calls this for each record it makes of an Alt-mode type, with its icon and extra
-- (wires in r / g): a furnace, or one a circuit network may set, is watched from then on. Only
-- for a client's own records (storage.f3d has its subscriptions).
function M.recorded(e, icon, extra, arrows)
  local s = storage.f3d
  local unit = e.unit_number
  if not (s and s.subs and unit) then
    return
  end
  if e.type == "furnace" or (CIRCUIT_SET[e.type] and extra and (extra.r or extra.g)) then
    s.altw = s.altw or {}
    s.altw[unit] = { e = e, v = M.signature(icon, arrows), k = chunk_key(e.position) }
  elseif s.altw and s.altw[unit] then
    s.altw[unit] = nil -- its wires went: an event or the chunk's next sending tells the rest
  end
  if mark_list_dirty then
    mark_list_dirty(s, e, unit)
  end
end

-- An `aiu` fa row: [unit, fluid mask, connections?] (M.connections, only with a mask).
function M.fa_row(e, arrows)
  local conns = arrows and M.connections(e) or nil
  if conns then
    return { e.unit_number, arrows, conns }
  end
  return { e.unit_number, arrows or 0 }
end

local function row(unit, icon)
  if not icon then
    return { unit, "" }
  end
  return { unit, icon[1], icon[2], icon[3] }
end

-- The entity's icon now, sent if it differs from what the client was last told (an event that may
-- have changed it: a window closed in the real game, the open screen's commands). `known` is the
-- signature the caller kept, or nil to send it whatever it was.
function M.check(e, known)
  local s = storage.f3d
  if not (s and s.client and e and e.valid and e.unit_number and TYPES[entity_type(e)]) then
    return known
  end
  -- world.is_subscribed, here: world requires this module, and `require` at run time stops the game.
  if e.surface.index ~= s.surface_index or not s.subs[chunk_key(e.position)] then
    return known
  end
  local icon, arrows, v = M.state(e)
  local w = s.altw and s.altw[e.unit_number]
  if w then
    w.v = v
  end
  if v ~= known then
    local p = e.position
    transport.send_reliable_priority({ t = "aiu", l = { row(e.unit_number, icon) }, fa = { M.fa_row(e, arrows) } },
      math.floor(p.x / CHUNK), math.floor(p.y / CHUNK))
  end
  return v
end

---------------------------------------------------------------------------------------------
-- Where Alt-mode puts a prototype's icons (K1, K2), for `eprops` (ui_actions.lua): Factorio 2.1
-- draws an entity's own icon by its icon_draw_specification (a shift from its centre and a scale),
-- and the contents of some of its inventories as rows of small icons by its icons_positioning, one
-- IconSequencePositioning per inventory: the modules in a machine, a drill, a lab or a beacon, and
-- the science packs in a lab. A machine with module slots and no icons_positioning gets Factorio's
-- documented defaults for its modules (shift {0, 0.7}, scale 0.5, separation 1.1, first row of
-- several -0.1, up to its selection box's width / 0.75 icons a row and width / 1.5 rows).
-- An ammo turret's ammo and a locomotive's fuel are drawn the same way (K1's leftover): 2.1's gun
-- turret lists its turret_ammo inventory ({0, -0.25}) and its locomotive its fuel ({0, 0.3}, three a
-- row), the only two in 2.1's data; one without an entry gets the defaults, as a machine's modules do
-- (the old AmmoTurretPrototype::entity_info_icon_shift drew every ammo turret's ammo).
-- Prototypes only, so the module-level caches are the same on every peer.

local SEQUENCE_TYPES = { ["assembling-machine"] = true, furnace = true, ["rocket-silo"] = true,
  ["mining-drill"] = true, lab = true, beacon = true }
M.SEQUENCE_TYPES = SEQUENCE_TYPES
-- The types whose other inventory Alt-mode shows (`/f3d-perf alt_ammo_fuel`): the kind its row has in
-- `isq` and the inventory's defines.inventory name.
-- A cargo wagon's load (kind "c", `/f3d-perf alt_ammo_fuel` too) shows its most-stacked kinds in one row.
local STOCK_TYPES = { ["ammo-turret"] = { "a", "turret_ammo" }, locomotive = { "f", "fuel" },
  ["cargo-wagon"] = { "c", "cargo_wagon" } }
local WAGON_SHOWN = 4
-- The module inventory's defines.inventory name by type: crafter_modules is 2.1's, the rest 2.0's.
local MODULE_INVENTORIES = {
  ["assembling-machine"] = { "crafter_modules", "assembling_machine_modules" },
  furnace = { "crafter_modules", "furnace_modules" },
  ["rocket-silo"] = { "crafter_modules", "rocket_silo_modules", "assembling_machine_modules" },
  ["mining-drill"] = { "mining_drill_modules" },
  lab = { "lab_modules" },
  beacon = { "beacon_modules" },
}

local function define_of(name)
  local ok, v = pcall(get_define_inv, name)
  return ok and v or nil
end

local function num(v, default)
  return type(v) == "number" and v or default
end

local function thousandths(v)
  return math.floor(v * 1000 + 0.5) / 1000
end

-- A Vector ({x, y} or {x =, y =}) as two numbers, 0, 0 when it isn't one.
local function vec_xy(v)
  if type(v) ~= "table" then
    return 0, 0
  end
  return num(v.x or v[1], 0), num(v.y or v[2], 0)
end

local function box_width(proto)
  local ok, b = pcall(get_selection_box, proto)
  if not (ok and type(b) == "table") then
    return 0
  end
  local lt, rb = b.left_top or b[1], b.right_bottom or b[2]
  if type(lt) ~= "table" or type(rb) ~= "table" then
    return 0
  end
  return num(rb.x or rb[1], 0) - num(lt.x or lt[1], 0)
end

-- Those whose own Alt-mode icon the client draws (TYPES, containers' contents, machines'), the
-- only ones whose icon_draw_specification it needs.
local SPEC_TYPES = { container = true, ["infinity-container"] = true, ["linked-container"] = true }
for t in pairs(TYPES) do
  SPEC_TYPES[t] = true
end
for t in pairs(SEQUENCE_TYPES) do
  SPEC_TYPES[t] = true
end

-- [shift x, shift y, scale] of the prototype's icon_draw_specification, nil when it is the default
-- ({0, 0}, 1) or the client draws no icon of its own over it.
function M.draw_spec(proto)
  if not SPEC_TYPES[proto.type] then
    return nil
  end
  local ok, s = pcall(get_icon_draw_spec, proto)
  if not (ok and type(s) == "table") then
    return nil
  end
  local sx, sy = vec_xy(s.shift)
  local scale = num(s.scale, 1)
  if sx == 0 and sy == 0 and scale == 1 then
    return nil
  end
  return { thousandths(sx), thousandths(sy), thousandths(scale) }
end

local sequences_cache = {}

-- One `isq` row from an IconSequencePositioning (`p`; {} for Factorio's defaults).
local function sequence_entry(kind, p, width)
  local sx, sy = 0, 0.7
  if p.shift ~= nil then
    sx, sy = vec_xy(p.shift)
  end
  return { kind, thousandths(sx), thousandths(sy), thousandths(num(p.scale, 0.5)),
    math.max(1, math.floor(num(p.max_icons_per_row, width / 0.75) + 1e-6)),
    math.max(1, math.floor(num(p.max_icon_rows, width / 1.5) + 1e-6)),
    thousandths(num(p.separation_multiplier, 1.1)), thousandths(num(p.multi_row_initial_height_modifier, -0.1)) }
end

-- An ammo turret's or a locomotive's one row: its icons_positioning entry for that inventory, else
-- the defaults.
local function stock_sequences(proto, stock)
  if stock[1] == "c" then -- no icons_positioning of its own: a row along the wagon, over its middle
    return { sequence_entry("c", { shift = { 0, 0 }, scale = 0.5, max_icons_per_row = WAGON_SHOWN, max_icon_rows = 1 },
      box_width(proto)) }
  end
  local index = define_of(stock[2])
  local ok, list = pcall(get_icons_pos, proto)
  if index and ok and type(list) == "table" then
    for _, p in ipairs(list) do
      if type(p) == "table" and p.inventory_index == index then
        return { sequence_entry(stock[1], p, box_width(proto)) }
      end
    end
  end
  return { sequence_entry(stock[1], {}, box_width(proto)) }
end

-- [[kind, shift x, shift y, scale, icons a row, rows, separation, first row's lift], ...]: kind "m"
-- the modules, "l" a lab's science packs, "a" a turret's ammo, "f" a locomotive's fuel; nil when
-- Alt-mode shows none of them.
local function sequences(proto)
  local t = proto.type
  if STOCK_TYPES[t] then
    return stock_sequences(proto, STOCK_TYPES[t])
  end
  if not SEQUENCE_TYPES[t] then
    return nil
  end
  local ok_m, slots = pcall(get_module_inv_size, proto)
  local has_modules = ok_m and type(slots) == "number" and slots > 0
  if not has_modules and t ~= "lab" then
    return nil
  end
  local modules = {}
  for _, n in ipairs(MODULE_INVENTORIES[t]) do
    local d = define_of(n)
    if d then
      modules[d] = true
    end
  end
  local lab_input = t == "lab" and define_of("lab_input") or nil
  local width = box_width(proto)
  local out = {}
  local ok, list = pcall(get_icons_pos, proto)
  if ok and type(list) == "table" then
    for _, p in ipairs(list) do
      local index = type(p) == "table" and p.inventory_index or nil
      if has_modules and index and modules[index] then
        out[#out + 1] = sequence_entry("m", p, width)
      elseif lab_input and index == lab_input then
        out[#out + 1] = sequence_entry("l", p, width)
      end
    end
  elseif has_modules then
    out[1] = sequence_entry("m", {}, width)
  end
  return #out > 0 and out or nil
end

function M.sequences(proto)
  local v = sequences_cache[proto.name]
  if v == nil then
    v = sequences(proto) or false
    sequences_cache[proto.name] = v
  end
  return v or nil
end

-- The items an inventory shows in Alt-mode, slot by slot (Factorio draws one icon a module, one a
-- lab's pack slot, no counts): a name, or {name, quality} when not normal. `each`: one per item of
-- a stack (a module slot holds one in the game). Up to 32.
local function shown_items(inv, each)
  local out = {}
  if not inv then
    return out
  end
  local oke, empty = pcall(inv_is_empty, inv)
  if oke and empty then
    M.counts.empty_skips = M.counts.empty_skips + 1
    return out
  elseif not oke and inv.is_empty() then
    return out
  end
  for i = 1, #inv do
    local stack = inv[i]
    if stack.valid_for_read then
      local q = stack.quality
      q = type(q) == "string" and q or (q and q.name)
      local item = (q and q ~= "normal") and { stack.name, q } or stack.name
      for _ = 1, each and math.min(stack.count, 32) or 1 do
        out[#out + 1] = item
      end
      if #out >= 32 then
        break
      end
    end
  end
  return out
end

-- (gc_lean) Module-local inventory handle cache and entity list cache helpers.
-- Called only from commands and events (every peer the same): empties the read cache and the
-- storage list. contents_tick's own module-state checks call clear_inv_cache, which leaves storage be.
local function clear_inv_cache()
  inv_cache = {}
end

local function clear_caches(s)
  clear_inv_cache()
  local target = s or storage.f3d
  if target and target.altc then
    target.altc.lc_meta = nil
  end
end

local function prune_inv_cache()
  for _, bucket in pairs(inv_cache) do
    for unit, c in pairs(bucket) do
      if not (c.e and c.e.valid and c.inv and c.inv.valid) then
        bucket[unit] = nil
      end
    end
  end
end

local function cached_inv(e, key, getter, arg)
  if not perf.on("gc_lean") then
    inv_cache = {}
    M.counts.inv_gets = M.counts.inv_gets + 1
    local ok, inv = pcall(getter, e, arg)
    return ok and inv or nil
  end
  local unit = e.unit_number
  if unit then
    local bucket = inv_cache[key]
    if not bucket then
      bucket = {}
      inv_cache[key] = bucket
    end
    local c = bucket[unit]
    if c and c.e == e and e.valid and c.inv and c.inv.valid then
      return c.inv
    end
    M.counts.inv_gets = M.counts.inv_gets + 1
    local ok, inv = pcall(getter, e, arg)
    if ok and inv and inv.valid then
      bucket[unit] = { e = e, inv = inv }
      return inv
    end
    bucket[unit] = nil
    return ok and inv or nil
  end
  M.counts.inv_gets = M.counts.inv_gets + 1
  local ok, inv = pcall(getter, e, arg)
  return ok and inv or nil
end

-- What Alt-mode shows in a machine (K1, K2): its modules and its other inventory (a lab's science
-- packs, a turret's ammo, a locomotive's fuel: one icon a filled slot), each a list as shown_items
-- makes it (empty for none), or nil, nil for an entity without such icons.
function M.machine_icons(e)
  local seq = M.sequences(e.prototype)
  if not seq then
    return nil, nil
  end
  local stock = STOCK_TYPES[e.type]
  if stock then
    local inv_id = define_of(stock[2])
    local inv = inv_id and cached_inv(e, stock[2], get_entity_inv, inv_id) or nil
    if stock[1] == "c" then
      return {}, inv and M.top_names(inv, WAGON_SHOWN) or {}
    end
    local ok, held = pcall(shown_items, inv, false)
    return {}, ok and held or {}
  end
  local want_m, want_l
  for _, s in ipairs(seq) do
    want_m = want_m or s[1] == "m"
    want_l = want_l or s[1] == "l"
  end
  local mods, packs = {}, {}
  if want_m then
    local minv = cached_inv(e, "mod", get_module_inv)
    local ok, m = pcall(shown_items, minv, true)
    if ok and m then
      mods = m
    end
  end
  if want_l then
    local linv = cached_inv(e, "lab", get_entity_inv, defines.inventory.lab_input)
    local ok, l = pcall(shown_items, linv, false)
    if ok and l then
      packs = l
    end
  end
  return mods, packs
end

local function items_sig(list)
  local parts = {}
  for i, it in ipairs(list) do
    parts[i] = type(it) == "table" and (it[1] .. "@" .. it[2]) or it
  end
  return table.concat(parts, ",")
end

---------------------------------------------------------------------------------------------
-- Chests' contents (J6). Factorio's Alt-mode shows "additional information about built entities
-- such as recipes in assembling machines and container contents" (its show-info control's words):
-- over a chest the icons of what is in it, up to four kinds in the one icon's room. Here the kinds
-- it holds most of, most first; no counts, as Factorio draws none.
--
-- While the client says Alt-mode is on (`altc` {on 1, g}), the chests in its focus square are read
-- in rounds under the work budget, a round at most every CONTENTS_ROUND ticks (stretched by the
-- update rate, rate.lua's `ac`), and `ac` {g, l} carries the chests whose icons changed: [unit,
-- item, more items?], or [unit] when it shows none now (emptied, gone, out of the square or of the
-- client's chunks). storage.f3d.altc = {g, sent = {unit -> the names sent}, msent = {unit -> the
-- machine's icons sent}, due, round}; nil while off. Set from the client's command and on_tick,
-- like `focus`.
--
-- The machines (K1, K2; `/f3d-perf alt_machines`): those in the focus square whose prototype has
-- module slots, and labs, are read in the same rounds, `am` {g, l} carrying those whose icons
-- changed: [unit, modules, packs?] (each a list of items, a name or [name, quality]; modules 0
-- when there are none but packs), or [unit] when it shows none now. Ammo turrets and locomotives
-- too (`/f3d-perf alt_ammo_fuel`): their ammo or fuel where a lab's packs go, a locomotive read
-- where it is now (only when the client asks with `lf`: locomotive fuel icons are off by default); cargo wagons
-- likewise, their four most-stacked kinds.

local CONTAINER_TYPES = { "container", "logistic-container", "infinity-container", "linked-container" }
local CONTAINER_SET = {}
for _, t in ipairs(CONTAINER_TYPES) do
  CONTAINER_SET[t] = true
end
mark_list_dirty = function(s, e, unit, any_unit)
  local lc = s and s.altc and s.altc.lc_meta
  if lc and (CONTAINER_SET[e.type] or SEQUENCE_TYPES[e.type] or STOCK_TYPES[e.type]) then
    if any_unit or not (unit and lc.units and lc.units[unit]) then
      lc.dirty = true
    end
  end
end

function M.on_entity_changed(entity)
  if entity and entity.valid then
    mark_list_dirty(storage.f3d, entity, entity.unit_number, true)
  end
end
local CONTENTS_SHOWN = 4
local CONTENTS_PER_TICK = 32
-- A chest's read: its inventory's contents, about a record's worth (budget.lua's units).
local CONTENTS_PRICE = 2
-- A machine's: its module inventory slot by slot, a lab's packs too.
local MACHINE_PRICE = 3
-- The search of the focus square for chests (and for machines), at the start of a round.
local CONTENTS_FIND_PRICE = 20
local CONTENTS_ROUND = 60
local CONTENTS_ROUND_MOVE = 120
local MOVE_CADENCE_TILES = 4
-- Module-local counters for tests/probes (never in storage).
M.counts = { container_scans = 0, machine_scans = 0, rounds = 0, inv_gets = 0, empty_skips = 0, entity_reuses = 0 }
local container_types
local machine_names

local function present_container_types()
  if not container_types then
    local present = {}
    for _, proto in pairs(prototypes.entity) do
      present[proto.type] = true
    end
    container_types = {}
    for _, t in ipairs(CONTAINER_TYPES) do
      if present[t] then
        container_types[#container_types + 1] = t
      end
    end
  end
  return container_types
end

-- The names of the prototypes whose Alt-mode shows modules or science packs, and (`stock`, with
-- /f3d-perf alt_ammo_fuel) the ammo turrets and locomotives after them.
local function present_machine_names(stock, loco)
  if not machine_names then
    -- [1] machines and labs, [2] and the ammo turrets and cargo wagons, [3] and the locomotives too (the client's
    -- `lf`: locomotives' fuel icons are off unless it asks).
    machine_names = { {}, {}, {} }
    for name, proto in pairs(prototypes.entity) do
      if SEQUENCE_TYPES[proto.type] and M.sequences(proto) then
        for i = 1, 3 do
          machine_names[i][#machine_names[i] + 1] = name
        end
      elseif STOCK_TYPES[proto.type] then
        machine_names[3][#machine_names[3] + 1] = name
        if proto.type ~= "locomotive" then
          machine_names[2][#machine_names[2] + 1] = name
        end
      end
    end
    for i = 1, 3 do
      table.sort(machine_names[i])
    end
  end
  return machine_names[stock and (loco and 3 or 2) or 1]
end

-- The names of the kinds the chest holds most of (qualities together), most first, ties by name;
-- nil when it is empty.
function M.contents(e)
  local inv = cached_inv(e, "chest", get_entity_inv, defines.inventory.chest)
  return inv and M.top_names(inv, CONTENTS_SHOWN) or nil
end

-- The `n` kinds an inventory holds most of, most first (the chests' and the cargo wagons' icons).
function M.top_names(inv, n)
  if not inv then
    return nil
  end
  if perf.on("gc_lean") then
    local oke, empty = pcall(inv_is_empty, inv)
    if oke and empty == true then
      M.counts.empty_skips = M.counts.empty_skips + 1
      return nil
    end
  end
  local ok_c, list = pcall(get_inv_contents, inv)
  if not (ok_c and type(list) == "table") then
    return nil
  end
  local counts, names = {}, {}
  for _, it in pairs(list) do
    local name = it.name
    if type(name) ~= "string" then
      local ok_n, nn = pcall(get_name_field, name)
      name = ok_n and nn or nil
    end
    if type(name) == "string" and (it.count or 0) > 0 then
      if not counts[name] then
        names[#names + 1] = name
        counts[name] = 0
      end
      counts[name] = counts[name] + it.count
    end
  end
  if #names == 0 then
    return nil
  end
  sort_counts = counts
  table.sort(names, cmp_top_names)
  sort_counts = nil
  for i = #names, n + 1, -1 do
    names[i] = nil
  end
  return names
end

-- {on, g}: the client's Alt-mode on (1) or off (0); g, its count of turnings on, comes back in each
-- `ac` so it can tell a late answer to an earlier one. On again starts over: every chest is sent.
function M.contents_cmd(cmd)
  local s = storage.f3d
  if tonumber(cmd.on) == 1 then
    local g = math.floor(tonumber(cmd.g) or 0)
    local lf = tonumber(cmd.lf) == 1
    if perf.on("alt_cadence") and s.altc and s.altc.g == g and s.altc.lf == lf then
      return
    end
    clear_caches()
    s.altc = { g = g, sent = {}, msent = {}, due = game.tick, lf = lf }
  else
    clear_caches()
    s.altc = nil
  end
end

-- The client's world was dropped (a resync, another surface): everything is sent again.
function M.contents_forget()
  clear_caches()
  local c = storage.f3d.altc
  if c then
    c.sent, c.msent, c.round, c.due, c.last_fx, c.last_fy = {}, {}, nil, game.tick, nil, nil
  end
end

function M.reset()
  clear_caches()
end

local function machine_row(unit, modules, packs)
  if #modules == 0 and #packs == 0 then
    return { unit }
  end
  local row = { unit, #modules > 0 and modules or 0 }
  if #packs > 0 then
    row[3] = packs
  end
  return row
end

local function contents_row(unit, names)
  if not names then
    return { unit }
  end
  local row = { unit, names[1] }
  if #names > 1 then
    local more = {}
    for i = 2, #names do
      more[#more + 1] = names[i]
    end
    row[3] = more
  end
  return row
end

local function area_strips(f)
  local r = f.r
  if r <= 64 then
    return { { { f.x - r, f.y - r }, { f.x + r, f.y + r } } }, CONTENTS_FIND_PRICE
  end
  return {
    { { f.x - r, f.y - r }, { f.x + r, f.y } },
    { { f.x - r, f.y }, { f.x + r, f.y + r } },
  }, math.floor(CONTENTS_FIND_PRICE / 2)
end

local function append_unique(round, found)
  local added = round.added
  local list = round.list
  for _, e in ipairs(found) do
    local u = e.unit_number
    if not u or not added[u] then
      if u then
        added[u] = true
      end
      list[#list + 1] = e
    end
  end
end

local function contents_tick()
  local s = storage.f3d
  local c = s.altc
  if not c then
    return
  end
  local lean = perf.on("gc_lean")
  -- (M1) Module state (nil on a peer that just joined) only clears the module's read cache: storage
  -- is never written from it. The storage list is checked against storage (lc.si, lc.client).
  if lean then
    if s.surface_index ~= inv_cache_si or s.client ~= inv_cache_client then
      clear_inv_cache()
      inv_cache_si, inv_cache_client = s.surface_index, s.client
    end
  elseif inv_cache_si ~= nil or next(inv_cache) ~= nil then
    clear_inv_cache()
    inv_cache_si, inv_cache_client = nil, nil
  end
  local cadence = perf.on("alt_cadence")
  local round = c.round
  if not cadence and round and round.searches then
    c.round, round = nil, nil
  end
  if not round then
    if game.tick < (c.due or 0) then
      return
    end
    local surface = game.get_surface(s.surface_index)
    local types = present_container_types()
    if not (surface and surface.valid and #types > 0 and s.focus) then
      return
    end
    local am_on = perf.on("alt_machines")
    local af_on = perf.on("alt_ammo_fuel")
    local f = s.focus
    local lc = lean and c.lc_meta or nil
    if not lean then
      c.lc_meta = nil
    end
    if lc and not lc.dirty and lc.list and lc.si == surface.index and lc.client == s.client and lc.r == f.r
        and lc.lf == c.lf and lc.am_on == am_on and lc.af_on == af_on and lc.cadence == cadence
        and math.max(math.abs(f.x - lc.fx), math.abs(f.y - lc.fy)) < MOVE_CADENCE_TILES
        and (game.tick - lc.tick) < ALT_RESCAN_TICKS * rate.factor("ac") then
      -- (M1) The list kept in storage: the same on every peer, a joiner's included.
      local reuse_list = lc.list
      M.counts.entity_reuses = M.counts.entity_reuses + 1
      round = { i = 1, seen = {}, list = reuse_list, moved = 0, r = f.r, reused = true }
      c.round = round
    else
      local machines = am_on and present_machine_names(af_on, c.lf) or {}
      if not cadence then
        local price = CONTENTS_FIND_PRICE * (#machines > 0 and 2 or 1)
        if not budget.can(price, "altc", 0.1) then
          return
        end
        budget.spend(price, "altc")
        local area = { { f.x - f.r, f.y - f.r }, { f.x + f.r, f.y + f.r } }
        round = { i = 1, seen = {}, list = surface.find_entities_filtered({ area = area, type = types }),
          si = surface.index, fx = f.x, fy = f.y, r = f.r, lf = c.lf, am_on = am_on, af_on = af_on, cadence = cadence }
        M.counts.container_scans = M.counts.container_scans + 1
        if #machines > 0 then
          -- After the chests, in the same round.
          for _, e in ipairs(surface.find_entities_filtered({ area = area, name = machines })) do
            round.list[#round.list + 1] = e
          end
          M.counts.machine_scans = M.counts.machine_scans + 1
        end
        c.round = round
      else
        local strips, find_price = area_strips(f)
        if not budget.can(find_price, "altc", 0.1) then
          return
        end
        budget.spend(find_price, "altc")
        local moved = c.last_fx and math.max(math.abs(f.x - c.last_fx), math.abs(f.y - c.last_fy)) or 0
        c.last_fx, c.last_fy = f.x, f.y
        local searches = {}
        for _, box in ipairs(strips) do
          searches[#searches + 1] = { "container", box }
        end
        if #machines > 0 then
          for _, box in ipairs(strips) do
            searches[#searches + 1] = { "machine", box }
          end
        end
        round = { i = 1, seen = {}, list = {}, added = {}, searches = searches, si = 2, find_tick = game.tick,
          find_price = find_price, moved = moved, r = f.r, surf_i = surface.index, fx = f.x, fy = f.y,
          lf = c.lf, am_on = am_on, af_on = af_on, cadence = cadence }
        append_unique(round, surface.find_entities_filtered({ area = searches[1][2], type = types }))
        M.counts.container_scans = M.counts.container_scans + 1
        c.round = round
      end
    end
  elseif cadence and round.si and round.si <= #round.searches and game.tick > (round.find_tick or -1) then
    local surface = game.get_surface(s.surface_index)
    local step = round.searches[round.si]
    local find_price = round.find_price or CONTENTS_FIND_PRICE
    if surface and surface.valid and budget.can(find_price, "altc", 0.1) then
      budget.spend(find_price, "altc")
      round.si = round.si + 1
      round.find_tick = game.tick
      if step[1] == "container" then
        local types = present_container_types()
        if #types > 0 then
          append_unique(round, surface.find_entities_filtered({ area = step[2], type = types }))
          M.counts.container_scans = M.counts.container_scans + 1
        end
      else
        local machines = perf.on("alt_machines") and present_machine_names(perf.on("alt_ammo_fuel"), c.lf) or {}
        if #machines > 0 then
          append_unique(round, surface.find_entities_filtered({ area = step[2], name = machines }))
          M.counts.machine_scans = M.counts.machine_scans + 1
        end
      end
    end
  end
  c.msent = c.msent or {}
  local searches_done = not round.searches or round.si > #round.searches
  local out, mout
  for _ = 1, CONTENTS_PER_TICK do
    local e = round.list[round.i]
    if e == nil then
      if not searches_done then
        break
      end
      -- The round is over: chests and machines not in it any more lose their icons.
      for unit in pairs(c.sent) do
        if not round.seen[unit] then
          c.sent[unit] = nil
          out = out or {}
          out[#out + 1] = { unit }
        end
      end
      for unit in pairs(c.msent) do
        if not round.seen[unit] then
          c.msent[unit] = nil
          mout = mout or {}
          mout[#mout + 1] = { unit }
        end
      end
      if lean and not round.reused then
        local units = round.added
        if not units then
          units = {}
          for _, ent in ipairs(round.list) do
            if ent.valid and ent.unit_number then
              units[ent.unit_number] = true
            end
          end
        end
        local meta = {
          si = round.surf_i or round.si,
          fx = round.fx,
          fy = round.fy,
          r = round.r,
          lf = round.lf,
          am_on = round.am_on,
          af_on = round.af_on,
          cadence = round.cadence,
          tick = game.tick,
          units = units,
          client = s.client,
          list = round.list,
          dirty = false,
        }
        c.lc_meta = meta
      end
      prune_inv_cache()
      local interval = CONTENTS_ROUND
      if cadence and (round.moved or 0) >= MOVE_CADENCE_TILES and (round.moved or 0) < (round.r or math.huge) then
        interval = CONTENTS_ROUND_MOVE
      end
      c.round = nil
      c.due = game.tick + interval * rate.factor("ac")
      M.counts.rounds = M.counts.rounds + 1
      break
    end
    local valid = e.valid
    if not valid and lean and c.lc_meta then
      c.lc_meta.dirty = true
    end
    local chest = not valid or CONTAINER_SET[e.type]
    local price = chest and CONTENTS_PRICE or MACHINE_PRICE
    if not budget.can(price, "altc", 0.1) then
      break
    end
    budget.spend(price, "altc")
    round.i = round.i + 1
    local unit = valid and e.unit_number
    if unit and s.subs[chunk_key(e.position)] then
      if chest then
        local names = M.contents(e)
        local sig = names and table.concat(names, ",") or nil
        if sig then
          round.seen[unit] = true
        end
        if sig ~= c.sent[unit] then
          c.sent[unit] = sig
          out = out or {}
          out[#out + 1] = contents_row(unit, names)
        end
      else
        local modules, packs = M.machine_icons(e)
        local sig
        if modules and (#modules > 0 or #packs > 0) then
          sig = items_sig(modules) .. "|" .. items_sig(packs)
          round.seen[unit] = true
        end
        if sig ~= c.msent[unit] then
          c.msent[unit] = sig
          mout = mout or {}
          mout[#mout + 1] = machine_row(unit, modules or {}, packs or {})
        end
      end
    end
  end
  if out then
    transport.send_reliable({ t = "ac", g = c.g, l = out })
  end
  if mout then
    transport.send_reliable({ t = "am", g = c.g, l = mout })
  end
end

-- A few watched machines a tick, a round at most every ROUND_TICKS: those whose icon changed are
-- sent in one `aiu`. Entries gone or no longer streamed are dropped when the round ends (clearing
-- keys behind the cursor while it walks would break `next`).
function M.tick()
  contents_tick()
  local s = storage.f3d
  local w = s.altw
  if not w or game.tick < (s.altw_due or 0) then
    return
  end
  if s.altw_cursor ~= nil and not w[s.altw_cursor] then
    s.altw_cursor = nil -- its entry went (M.recorded): start the round again
  end
  local out, fa
  for _ = 1, WATCH_PER_TICK do
    if not budget.can(WATCH_PRICE, "alt", 0.1) then
      break
    end
    local unit, entry = next(w, s.altw_cursor)
    if unit == nil then
      s.altw_cursor = nil
      for _, u in ipairs(s.altw_dead or {}) do
        w[u] = nil
      end
      s.altw_dead = nil
      s.altw_due = game.tick + ROUND_TICKS
      break
    end
    s.altw_cursor = unit
    budget.spend(WATCH_PRICE, "alt")
    local e = entry.e
    if not (e.valid and s.subs[entry.k]) then
      s.altw_dead = s.altw_dead or {}
      s.altw_dead[#s.altw_dead + 1] = unit
    else
      local icon, arrows, v = M.state(e)
      if v ~= entry.v then
        entry.v = v
        out = out or {}
        out[#out + 1] = row(unit, icon)
        fa = fa or {}
        fa[#fa + 1] = M.fa_row(e, arrows)
      end
    end
  end
  if out then
    transport.send_reliable({ t = "aiu", l = out, fa = fa })
  end
end

return M
