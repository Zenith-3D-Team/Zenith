-- Modules where the hands can't reach, Factorio 2.x's way (owner's F6): a module held and clicked
-- on a building out of reach, on one seen from the remote view (another surface, a platform's hub)
-- or on a ghost asks for it, and the robots (or a platform's hub) bring it. A ghost keeps the
-- request in its insert plan; a building gets an item request proxy, as a player's does. All of it
-- works without a player in 2.1.23 (LuaEntity.insert_plan, item_request_proxy, create_entity of
-- an item-request-proxy with `modules`). Within reach the module goes straight in, as a click does.
--
-- {u, p, x, y (the target, as `open` finds it), item, q? (quality), s? (a module slot from the
-- machine screen, 1-based), clr? (1: take the requests back: slot s's, or all)}.
--
-- Also the hover panel's answer (`hinfo`, M.hover): modules and their effects, beacons, the
-- electricity Factorio's entity info shows, a roboport's links, what is inside (I2), how far a
-- craft and the burning fuel are (I26) and a crafter's ingredients and products a second (J15).

local entity_ui = require("scripts.entity_ui")
local puppet = require("scripts.puppet")
local transport = require("scripts.transport")
local world = require("scripts.world")
local alt_mode = require("scripts.alt_mode")
local pipelines = require("scripts.pipelines")

local M = {}

-- The module inventory a ghost's entity will have (a built one says so itself). crafter_modules is
-- 2.1's name; 2.0 had one per type.
local INVENTORY = {
  ["assembling-machine"] = { "crafter_modules", "assembling_machine_modules" },
  furnace = { "crafter_modules", "furnace_modules" },
  ["rocket-silo"] = { "crafter_modules", "assembling_machine_modules" },
  ["mining-drill"] = { "mining_drill_modules" },
  lab = { "lab_modules" },
  beacon = { "beacon_modules" },
}

local function try(fn)
  local ok, v = pcall(fn)
  if ok then
    return v
  end
  return nil
end

-- {speed, productivity, consumption, pollution, quality} in thousandths, or nil without effects.
local EFFECTS = { { "speed", "sp" }, { "productivity", "pr" }, { "consumption", "co" }, { "pollution", "po" }, { "quality", "q" } }
function M.effects_of(e)
  local fx = try(function() return e.effects end)
  if type(fx) ~= "table" then
    return nil
  end
  local out, any = {}, false
  for _, pair in ipairs(EFFECTS) do
    local v = fx[pair[1]]
    if type(v) == "table" then
      v = v.bonus -- 1.1's shape
    end
    if type(v) == "number" and v ~= 0 then
      out[pair[2]] = math.floor(v * 1000 + 0.5)
      any = true
    end
  end
  return any and out or nil
end

local function round(v)
  return math.floor(v + 0.5)
end

-- What Factorio's entity info shows under "Consumes electricity" (H20) for something that draws
-- power: {e (joules in its buffer), b (the buffer's size: the Electricity bar is e / b), mx (Max.
-- consumption: the most it uses with its modules and beacons, plus its drain, in watts), mn (Min.
-- consumption: its drain, watts)}; nil for generators, accumulators and what isn't electric.
function M.electricity(e)
  local size = try(function() return e.electric_buffer_size end)
  if type(size) ~= "number" or size <= 0 then
    return nil
  end
  local source = try(function() return e.prototype.electric_energy_source_prototype end)
  local priority = source and try(function() return source.usage_priority end) or ""
  if not (priority:find("input", 1, true) or priority == "lamp") then
    return nil
  end
  local drain = (try(function() return e.electric_drain end) or 0) * 60
  local quality = try(function() return e.quality end)
  local usage = try(function() return e.prototype.get_max_energy_usage(quality) end)
    or try(function() return e.prototype.energy_usage end) or 0
  -- Factorio stops a consumption bonus at -80%.
  local bonus = try(function() return e.consumption_bonus end) or 0
  return { e = round(e.energy), b = round(size), mx = round(usage * 60 * math.max(0.2, 1 + bonus) + drain), mn = round(drain) }
end

-- The roboports a roboport's logistic cell is joined to (H14: Factorio draws the links when one is
-- hovered): [x, y, ...] in 1/256 tiles, from LuaLogisticCell.neighbours, so the game's own rule
-- decides; nil when it has no cell.
function M.roboport_links(e)
  local cell = try(function() return e.logistic_cell end)
  local near = cell and try(function() return cell.neighbours end)
  if type(near) ~= "table" then
    return nil
  end
  local out = {}
  for _, n in pairs(near) do
    local owner = try(function() return n.owner end)
    if owner and owner.valid and owner.type == "roboport" then
      out[#out + 1] = world.fixed(owner.position.x)
      out[#out + 1] = world.fixed(owner.position.y)
    end
  end
  return out
end

-- The inventories the hover panel lists (I2), by entity type: {role, {defines.inventory names,
-- the first that exists}}. By type because the defines share numbers (chest and fuel are both 1),
-- so asking a furnace for its "chest" would hand back its fuel. Modules are `m`; fuel, burnt
-- results and a crafter's output are asked for by their own getters below.
local HOVER_INVENTORIES = {
  container = { { "chest", { "chest" } } },
  ["logistic-container"] = { { "chest", { "chest" } }, { "trash", { "logistic_container_trash" } } },
  ["linked-container"] = { { "chest", { "chest" } } },
  ["infinity-container"] = { { "chest", { "chest" } } },
  ["cargo-wagon"] = { { "cargo", { "cargo_wagon" } } },
  ["artillery-wagon"] = { { "ammo", { "artillery_wagon_ammo" } } },
  ["artillery-turret"] = { { "ammo", { "artillery_turret_ammo" } } },
  ["ammo-turret"] = { { "ammo", { "turret_ammo" } } },
  car = { { "trunk", { "car_trunk" } }, { "ammo", { "car_ammo" } } },
  ["spider-vehicle"] = { { "trunk", { "spider_trunk" } }, { "ammo", { "spider_ammo" } } },
  ["assembling-machine"] = { { "input", { "assembling_machine_input", "crafter_input" } } },
  furnace = { { "input", { "furnace_source", "crafter_input" } } },
  ["rocket-silo"] = { { "input", { "rocket_silo_input", "assembling_machine_input", "crafter_input" } } },
  lab = { { "input", { "lab_input" } } },
  roboport = { { "robots", { "roboport_robot" } }, { "repair", { "roboport_material" } } },
  ["space-platform-hub"] = { { "chest", { "hub_main" } } },
  ["cargo-landing-pad"] = { { "chest", { "cargo_landing_pad_main" } } },
}
local CRAFTERS = { ["assembling-machine"] = true, furnace = true, ["rocket-silo"] = true }
-- Kinds of item listed per inventory at most: a mixed chest of a hundred kinds stays one panel.
local HOVER_ITEMS = 30

local function define_of(names)
  for _, name in ipairs(names) do
    local index = try(function() return defines.inventory[name] end)
    if index then
      return index
    end
  end
  return nil
end

-- [[name, count, quality?], ...] totals per item, or nil when empty.
local function totals(inventory)
  if not inventory then
    return nil
  end
  local out = {}
  for _, it in pairs(try(function() return inventory.get_contents() end) or {}) do
    if #out >= HOVER_ITEMS then
      break
    end
    local row = { it.name, it.count }
    local quality = type(it.quality) == "string" and it.quality or (it.quality and it.quality.name)
    if quality and quality ~= "normal" then
      row[3] = quality
    end
    out[#out + 1] = row
  end
  return #out > 0 and out or nil
end

-- What is inside, as Factorio's entity info lists it (I2): [[role, [[name, count, quality?], ...]],
-- ...] in the panel's order, empty inventories left out; nil when there is nothing. Only the
-- hovered entity is read, about once a second (requests.lua's budget).
function M.hover_inventories(e)
  local out = {}
  local function add(role, inventory)
    local list = totals(inventory)
    if list then
      out[#out + 1] = { role, list }
    end
  end
  for _, pair in ipairs(HOVER_INVENTORIES[e.type] or {}) do
    local index = define_of(pair[2])
    add(pair[1], index and try(function() return e.get_inventory(index) end))
  end
  if CRAFTERS[e.type] then
    add("output", try(function() return e.get_output_inventory() end))
  end
  add("fuel", try(function() return e.get_fuel_inventory() end))
  add("burnt", try(function() return e.get_burnt_result_inventory() end))
  return #out > 0 and out or nil
end

-- A crafter's craft for the hover panel's bar (I26): `pr` how far (thousandths) and `ps` how much a
-- second of game time makes at 60 UPS (thousandths: its crafting speed with modules and beacons
-- over the recipe's time), so the client draws the bar on between answers.
local function crafting(msg, e)
  if not CRAFTERS[e.type] then
    return
  end
  local progress = try(function() return e.crafting_progress end)
  if type(progress) ~= "number" then
    return
  end
  msg.pr = math.max(0, math.min(1000, math.floor(progress * 1000 + 0.5)))
  msg.ps = M.progress_rate(e)
end

-- Thousandths of a craft a second of game time makes: crafting speed / the recipe's energy; nil
-- without a recipe.
function M.progress_rate(e)
  local recipe = try(function() return e.get_recipe() end)
  if not recipe and e.type == "furnace" then
    recipe = try(function() return e.previous_recipe end)
    local name = recipe and (type(recipe.name) == "string" and recipe.name or try(function() return recipe.name.name end))
    recipe = name and try(function() return e.force.recipes[name] end) or nil
  end
  local energy = recipe and try(function() return recipe.energy end)
  local speed = try(function() return e.crafting_speed end)
  if type(energy) ~= "number" or energy <= 0 or type(speed) ~= "number" then
    return nil
  end
  return math.floor(speed / energy * 1000 + 0.5)
end

-- What a crafting machine takes and makes a second, running flat out at its speed now (J15: Factorio's
-- entity info lists a machine's ingredients and products per second): {i = [[type, name, thousandths
-- a second], ...], o = [...]}, nil without a recipe (a furnace's last one counts, as its Alt-mode icon).
-- The crafting speed has its modules' and beacons' speed in it; each product gains the machine's
-- productivity (modules, beacons, the recipe's research), up to the recipe's cap, except the part
-- ignored_by_productivity, and counts at its probability, with extra_count_fraction.
function M.rates(e)
  if not CRAFTERS[e.type] then
    return nil
  end
  local recipe = alt_mode.shown_recipe(e)
  local energy = recipe and try(function() return recipe.energy end)
  local speed = try(function() return e.crafting_speed end)
  if type(energy) ~= "number" or energy <= 0 or type(speed) ~= "number" or speed <= 0 then
    return nil
  end
  local crafts = speed / energy
  local prod = try(function() return e.productivity_bonus end)
  prod = type(prod) == "number" and math.max(0, prod) or 0
  local cap = try(function() return recipe.prototype.maximum_productivity end)
  if type(cap) == "number" then
    prod = math.min(prod, cap)
  end
  local function per_second(amount)
    return math.floor(amount * crafts * 1000 + 0.5)
  end
  local i, o = {}, {}
  for _, x in ipairs(try(function() return recipe.ingredients end) or {}) do
    i[#i + 1] = { x.type or "item", x.name, per_second(x.amount or 0) }
  end
  for _, x in ipairs(try(function() return recipe.products end) or {}) do
    local amount = x.amount
    if not amount and x.amount_min then
      amount = (x.amount_min + (x.amount_max or x.amount_min)) / 2
    end
    amount = amount or 0
    local boosted = math.max(0, amount - (x.ignored_by_productivity or 0))
    local each = (amount + (x.extra_count_fraction or 0) + boosted * prod) * (x.probability or 1)
    o[#o + 1] = { x.type or "item", x.name, per_second(each) }
  end
  if #i == 0 and #o == 0 then
    return nil
  end
  return { i = i, o = o }
end

-- What Factorio's entity info shows for a machine with module slots or a beacon (G12), answering
-- the client's `hinfo` {q, u, p, x, y} for the entity under the mouse: `hinfo` {q, u, eff? (its
-- effects: a machine's from its modules and beacons; a beacon's its modules' sum, before the
-- distribution effectivity, as 2.1.23 reports it), m? (its modules
-- [[name, count, quality?], ...]), b? (beacons reaching a machine), n? (machines a beacon reaches),
-- de? (a beacon's distribution effectivity, thousandths), el? (its electricity, M.electricity),
-- rn? (a roboport's links to other roboports, M.roboport_links), ln? (a roboport's or logistic
-- chest's logistic network, filter or active requests), inv? (what is inside,
-- M.hover_inventories), pr? ps? (a crafter's progress and its rate), bn? (the burning fuel left,
-- thousandths), io? (a crafter's ingredients and products a second, M.rates), pl? ([extent, limit] of a
-- pipe's, pipe to ground's or storage tank's pipeline, tiles: Factorio's "Pipeline extent: 333/320", L11),
-- ox? (1: that pipeline is overextended), ra? (a resource's amount now, L6)}.
-- Reads only.
local function proto_name(v)
  if type(v) == "table" or type(v) == "userdata" then
    return try(function() return v.name end)
  end
  return type(v) == "string" and v or nil
end

local function logistic_requests(e)
  local secs = try(function() return e.get_logistic_sections() end)
  if not secs then
    return nil
  end
  local list = try(function() return secs.sections end)
  if type(list) ~= "table" then
    local first = try(function() return secs.get_section(1) end)
    list = first and { first } or {}
  end
  local req = {}
  for _, sec in ipairs(list) do
    local active = try(function() return sec.active end)
    if active ~= false then
      local mult = tonumber(try(function() return sec.multiplier end)) or 1
      for _, flt in pairs(try(function() return sec.filters end) or {}) do
        local v = flt and flt.value
        local vtype = v and v.type
        local iname = v and (vtype == nil or vtype == "item") and proto_name(v.name)
        if iname and iname ~= "" then
          local min_c = math.max(0, math.floor((tonumber(flt.min) or 0) * mult + 0.5))
          local max_v = tonumber(flt.max)
          local max_c = max_v and math.floor(max_v * mult + 0.5) or -1
          local rec = { iname, min_c, max_c }
          local q = proto_name(v.quality)
          if q and q ~= "" and q ~= "normal" then
            rec[4] = q
          end
          req[#req + 1] = rec
          if #req >= 12 then
            return req
          end
        end
      end
    end
  end
  return #req > 0 and req or nil
end

local function logistic_hover_info(e)
  local is_ghost = e.type == "entity-ghost"
  local etype = is_ghost and try(function() return e.ghost_prototype.type end) or e.type
  if etype ~= "roboport" and etype ~= "logistic-container" then
    return nil
  end
  local net = not is_ghost and try(function() return e.logistic_network end) or nil
  local valid_net = net and try(function() return net.valid end)
  local id = valid_net and (try(function() return net.network_id end) or 0) or 0
  if etype == "roboport" then
    if id == 0 then
      return { id = 0 }
    end
    local net_name = try(function() return net.custom_name end) or ""
    local cell = try(function() return e.logistic_cell end)
    local charging = cell and (try(function() return cell.charging_robot_count end)
      or try(function() return #cell.charging_robots end)) or 0
    local to_charge = cell and (try(function() return cell.to_charge_robot_count end)
      or try(function() return #cell.to_charge_robots end)) or 0
    return {
      id = id,
      name = net_name,
      log = {
        try(function() return net.available_logistic_robots end) or 0,
        try(function() return net.all_logistic_robots end) or 0,
      },
      con = {
        try(function() return net.available_construction_robots end) or 0,
        try(function() return net.all_construction_robots end) or 0,
      },
      ch = { charging, to_charge },
    }
  end
  local mode = is_ghost and try(function() return e.ghost_prototype.logistic_mode end)
    or try(function() return e.prototype.logistic_mode end)
    or ""
  local net_name = id ~= 0 and (try(function() return net.custom_name end) or "") or ""
  local ln = { id = id, name = net_name, mode = mode }
  if mode == "storage" then
    local flt = try(function() return e.get_filter(1) end)
    local fname = flt and proto_name(try(function() return flt.name end))
    if fname and fname ~= "" then
      ln.f = fname
      local fq = proto_name(try(function() return flt.quality end))
      if fq and fq ~= "" and fq ~= "normal" then
        ln.fq = fq
      end
    end
  elseif mode == "requester" or mode == "buffer" then
    ln.req = logistic_requests(e)
  end
  return ln
end

function M.hover(cmd)
  local q = math.floor(tonumber(cmd.q) or 0)
  local e = puppet.find_target(world.surface(), cmd)
  local msg = { t = "hinfo", q = q, u = math.floor(tonumber(cmd.u) or 0) }
  if e and e.valid and e.type == "resource" then
    msg.ra = try(function() return e.amount end)
  elseif e and e.valid and pipelines.SET[e.type] then
    local extent = pipelines.extent(e)
    if extent then
      msg.pl = { extent, pipelines.limit() }
    end
    msg.ox = pipelines.overextended(e) and 1 or nil
  elseif e and e.valid and e.type == "entity-ghost" then
    msg.ln = logistic_hover_info(e)
  elseif e and e.valid and e.type ~= "entity-ghost" then
    msg.el = M.electricity(e)
    msg.eff = M.effects_of(e)
    local inv = try(function() return e.get_module_inventory() end)
    if inv then
      local m = {}
      for _, it in pairs(try(function() return inv.get_contents() end) or {}) do
        local row = { it.name, it.count }
        local quality = type(it.quality) == "string" and it.quality or (it.quality and it.quality.name)
        if quality and quality ~= "normal" then
          row[3] = quality
        end
        m[#m + 1] = row
      end
      if #m > 0 then
        msg.m = m
      end
    end
    if e.type == "roboport" then
      msg.rn = M.roboport_links(e)
    elseif e.type == "fluid-wagon" then
      local fl = {}
      local n = try(function() return e.fluids_count end) or 0
      for i = 1, n do
        local fluid = try(function() return e.get_fluid(i) end)
        local cap = try(function() return e.get_fluid_capacity(i) end)
        if fluid and fluid.name then
          fl[#fl + 1] = {
            fluid = fluid.name,
            amount = math.floor((fluid.amount or 0) + 0.5),
            capacity = type(cap) == "number" and math.floor(cap + 0.5) or 0,
            temperature = math.floor((fluid.temperature or 15) + 0.5),
          }
        end
      end
      if #fl > 0 then
        msg.fl = fl
      end
    end
    msg.ln = logistic_hover_info(e)
    msg.inv = M.hover_inventories(e)
    crafting(msg, e)
    msg.io = M.rates(e)
    msg.bn = try(function() return entity_ui.burner_left(e) end)
    if e.type == "beacon" then
      local receivers = try(function() return e.get_beacon_effect_receivers() end)
      msg.n = receivers and #receivers or nil
      local de = try(function() return e.prototype.distribution_effectivity end)
      if type(de) == "number" then
        msg.de = math.floor(de * 1000 + 0.5)
      end
    else
      local beacons = try(function() return e.get_beacons() end)
      if beacons and #beacons > 0 then
        msg.b = #beacons
      end
    end
  end
  transport.send_now(msg)
end

local function inventory_index(e, proto)
  if e.type ~= "entity-ghost" then
    local inv = try(function() return e.get_module_inventory() end)
    if inv then
      return inv.index
    end
  end
  for _, name in ipairs(INVENTORY[proto.type] or {}) do
    local index = try(function() return defines.inventory[name] end)
    if index then
      return index
    end
  end
  return nil
end

local function slot_count(proto)
  return try(function() return proto.module_inventory_size end) or 0
end

-- Why the module can't go in there, or nil: every effect it raises must be one the machine (and
-- its recipe) allows, and its category one the machine takes.
local function refusal(item, proto, e)
  if item.type ~= "module" then
    return "That isn't a module"
  end
  local effects = try(function() return item.module_effects end) or {}
  local allowed = { try(function() return proto.allowed_effects end) }
  local recipe = e.type ~= "entity-ghost" and try(function() return e.get_recipe() end)
  if recipe then
    allowed[#allowed + 1] = try(function() return recipe.prototype.allowed_effects end)
  end
  for effect, v in pairs(effects) do
    if v > 0 then
      for _, a in pairs(allowed) do
        if a[effect] == false then
          return "That module's " .. effect .. " isn't allowed there"
        end
      end
    end
  end
  local cats = try(function() return proto.allowed_module_categories end)
  local cat = try(function() return item.category end)
  if cats and cat and not cats[cat] then
    return "That module doesn't fit there"
  end
  return nil
end

-- Where the requests are kept: the ghost itself, or the building's request proxy (nil: none yet).
local function holder(e)
  if e.type == "entity-ghost" then
    return e
  end
  local proxy = try(function() return e.item_request_proxy end)
  return proxy and proxy.valid and proxy or nil
end

-- The insert plan as {name, quality, inventory, stack (0-based)} rows, one per item.
local function rows_of(plans)
  local rows = {}
  for _, plan in pairs(plans or {}) do
    local id = plan.id or {}
    local name = id.name
    local quality = id.quality
    if type(quality) ~= "string" then
      quality = quality and quality.name or "normal"
    end
    for _, at in pairs(plan.items and plan.items.in_inventory or {}) do
      for _ = 1, at.count or 1 do
        rows[#rows + 1] = { name, quality, at.inventory, at.stack }
      end
    end
  end
  return rows
end

local function plans_of(rows)
  local plans, by = {}, {}
  for _, r in ipairs(rows) do
    local key = r[1] .. "/" .. r[2]
    local plan = by[key]
    if not plan then
      plan = { id = { name = r[1], quality = r[2] }, items = { in_inventory = {} } }
      by[key] = plan
      plans[#plans + 1] = plan
    end
    local list = plan.items.in_inventory
    list[#list + 1] = { inventory = r[3], stack = r[4], count = 1 }
  end
  return plans
end

local function read(e)
  local h = holder(e)
  return h and rows_of(try(function() return h.insert_plan end)) or {}
end

local function write(c, e, rows)
  local h = holder(e)
  local plans = plans_of(rows)
  if h then
    if #plans == 0 and h ~= e then
      h.destroy()
    else
      h.insert_plan = plans
    end
  elseif #plans > 0 then
    e.surface.create_entity({ name = "item-request-proxy", position = e.position, force = e.force, target = e, modules = plans })
  end
  local sc = storage.f3d.screen
  if sc and sc.entity == e then
    sc.due = game.tick
  end
end

-- For the machine screen (`gui` mrq): each module slot's requested module, "" where none is.
function M.slots(e)
  local proto = e.type == "entity-ghost" and e.ghost_prototype or e.prototype
  local index = inventory_index(e, proto)
  local n = slot_count(proto)
  if not index or n == 0 then
    return nil
  end
  local out, any = {}, false
  for i = 1, n do
    out[i] = ""
  end
  for _, r in ipairs(read(e)) do
    if r[3] == index and r[4] and r[4] >= 0 and r[4] < n then
      out[r[4] + 1] = r[1]
      any = true
    end
  end
  return any and out or nil
end

local function target(c, cmd)
  local sc = storage.f3d.screen
  if sc and sc.entity.valid and tonumber(cmd.u) == sc.unit and tonumber(cmd.u) ~= 0 then
    return sc.entity
  end
  return puppet.find_target(puppet.surface(c), cmd)
end

function M.request(cmd)
  local c = puppet.get()
  if not c then
    return
  end
  local e = target(c, cmd)
  if not (e and e.valid) then
    return puppet.message("Nothing there to put modules in")
  end
  if e.force ~= c.force then
    return puppet.message("That belongs to another force")
  end
  local ghost = e.type == "entity-ghost"
  local proto = ghost and e.ghost_prototype or e.prototype
  local index = inventory_index(e, proto)
  local n = slot_count(proto)
  if not index or n == 0 then
    return puppet.message("That has no module slots")
  end
  local slot = tonumber(cmd.s) and math.floor(tonumber(cmd.s)) - 1 or nil
  if slot and (slot < 0 or slot >= n) then
    return
  end
  local rows = read(e)
  if cmd.clr == 1 then
    local kept = {}
    for _, r in ipairs(rows) do
      if not (r[3] == index and (slot == nil or r[4] == slot)) then
        kept[#kept + 1] = r
      end
    end
    return write(c, e, kept)
  end
  local item = prototypes.item[tostring(cmd.item or "")]
  if not item then
    return
  end
  local why = refusal(item, proto, e)
  if why then
    return puppet.message(why)
  end
  local quality = type(cmd.q) == "string" and prototypes.quality[cmd.q] and cmd.q or "normal"
  local stack = { name = item.name, count = 1, quality = quality }
  local inv = not ghost and try(function() return e.get_module_inventory() end)
  -- Within the character's reach, on its own surface: the module goes in from the inventory.
  if inv and not slot and not storage.f3d.act_si and not puppet.hub(c) and e.surface == c.surface
      and puppet.can_reach(c, e) then
    local main = c.get_main_inventory()
    if main and main.get_item_count({ name = item.name, quality = quality }) > 0 then
      if inv.insert(stack) == 0 then
        return puppet.message("The module slots are full")
      end
      main.remove(stack)
      puppet.send_inventory_now()
      local sc = storage.f3d.screen
      if sc and sc.entity == e then
        sc.due = game.tick
      end
      return
    end
  end
  local taken = {}
  if inv then
    for i = 1, math.min(#inv, n) do
      if inv[i].valid_for_read then
        taken[i - 1] = "module"
      end
    end
  end
  for _, r in ipairs(rows) do
    if r[3] == index and r[4] then
      taken[r[4]] = taken[r[4]] or "request"
    end
  end
  if slot then
    if taken[slot] == "module" then
      return puppet.message("That slot has a module in it")
    end
    -- A request already in that slot is replaced.
    local kept = {}
    for _, r in ipairs(rows) do
      if not (r[3] == index and r[4] == slot) then
        kept[#kept + 1] = r
      end
    end
    rows = kept
  else
    for i = 0, n - 1 do
      if not taken[i] then
        slot = i
        break
      end
    end
    if not slot then
      return puppet.message("The module slots are full")
    end
  end
  rows[#rows + 1] = { item.name, quality, index, slot }
  write(c, e, rows)
  local asked = 0
  for _, r in ipairs(rows) do
    if r[3] == index then
      asked = asked + 1
    end
  end
  puppet.message(string.format("Module requested: %d of %d slots", asked, n))
end

return M
