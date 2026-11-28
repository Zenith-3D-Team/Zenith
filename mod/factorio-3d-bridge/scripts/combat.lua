-- Combat: the character shoots while the client holds a key (the game aims and fires through
-- `shooting_state`, as for a player), its guns and ammo go to the client's HUD, and the client
-- hears about damaged entities near the camera (health bars) and deaths (effects).

local registry = require("scripts.registry")
local transport = require("scripts.transport")
local world = require("scripts.world")
local tracker = require("scripts.tracker")
local puppet = require("scripts.puppet")
local alerts = require("scripts.alerts")
local turrets = require("scripts.turrets")
local perf = require("scripts.perf")

local M = {}

local HOLD_TICKS = 30      -- a shoot command lasts this long unless the client repeats it
local FIRING_TICKS = 20    -- `me.sh` stays 1 this long after the ammo last went down
local HEALTH_INTERVAL = 10
local GUNS_INTERVAL = 10
local PAIRS_PER_MESSAGE = 400
local HIT_FX_TICKS = 3     -- at most one `afx` per unit this often
local ATTACK_TICKS = 20    -- at most one `atk` per attacking unit this often (a biter bites every 35)
local ATTACK_KEEP = 600    -- `atk` times older than this are dropped once the table holds ATTACK_PRUNE
local ATTACK_PRUNE = 256

-- Within the live-update square around the client's camera.
local function near_focus(entity)
  local s = storage.f3d
  if not s.client or entity.surface.index ~= s.surface_index then
    return false
  end
  local f, p = s.focus, entity.position
  return math.abs(p.x - f.x) <= f.r and math.abs(p.y - f.y) <= f.r
end

local function inventories(c)
  return c.get_inventory(defines.inventory.character_guns), c.get_inventory(defines.inventory.character_ammo)
end

local function selected_gun(c)
  local ok, i = pcall(function() return c.selected_gun_index end)
  return ok and i or nil
end

-- N3: the armed vehicle the character sits in (a car, tank or spidertron with guns), its guns
-- (LuaEntityPrototype.indexed_guns, in slot order) and its ammo inventory, or nil. Factorio's
-- tool bar shows these instead of the character's while it drives or rides.
local VEHICLE_AMMO = { car = "car_ammo", ["spider-vehicle"] = "spider_ammo" }
local function armed_vehicle(c)
  local v = puppet.vehicle(c)
  local inv_name = v and v.valid and VEHICLE_AMMO[v.type]
  if not inv_name then
    return nil
  end
  local ok, guns = pcall(function()
    local out = {}
    for i, g in ipairs(v.prototype.indexed_guns or {}) do
      out[i] = g.name
    end
    return out
  end)
  if not (ok and guns and #guns > 0) then
    return nil
  end
  local oka, ammo = pcall(function() return v.get_inventory(defines.inventory[inv_name]) end)
  return v, guns, oka and ammo or nil
end
M.armed_vehicle = armed_vehicle

-- (`/f3d-perf vehicle_ammo`) What the character shoots with: in an armed vehicle the vehicle's
-- selected gun (the game fires it for the driver's shooting_state: the car's rounds go down, checked
-- in 2.1.24), else its own. Returns the ammo inventory, the selected slot, the gun's name and the
-- vehicle (nil on foot).
local weapon_tick, weapon_of, weapon_was = -1, nil, nil
local function read_weapon(c)
  if perf.on("vehicle_ammo") then
    local v, vguns, vammo = armed_vehicle(c)
    if v then
      local ok, i = pcall(function() return v.selected_gun_index end)
      i = ok and i or 1
      return vammo, i, vguns[i], v
    end
  end
  local guns, ammo = inventories(c)
  local i = selected_gun(c)
  local g = guns and i and i >= 1 and i <= #guns and guns[i]
  return ammo, i, g and g.valid_for_read and g.name or nil, nil
end

-- read_weapon once a tick (tick_shooting asks three or four times); a cache of this tick's game state only,
-- never in storage, so every peer reads the same.
local function weapon(c)
  if weapon_tick ~= game.tick or weapon_of ~= c then
    weapon_tick, weapon_of, weapon_was = game.tick, c, { read_weapon(c) }
  end
  return weapon_was[1], weapon_was[2], weapon_was[3], weapon_was[4]
end

-- The ammo stack of the gun in use, or nil.
local function ammo_stack(c)
  local ammo, i = weapon(c)
  local stack = ammo and i and i >= 1 and i <= #ammo and ammo[i]
  return stack and stack.valid_for_read and stack or nil
end

-- Bullets left with the selected gun: magazines and the rounds in the one in use. It only
-- matters that it goes down when the character fires.
local function ammo_left(c)
  local stack = ammo_stack(c)
  if not stack then
    return 0
  end
  local ok, rounds = pcall(function() return stack.ammo end)
  return stack.count * 1000 + (ok and rounds or 0)
end

---------------------------------------------------------------------------------------------
-- Commands

-- m = 0 shoots at enemies near the character (Factorio's Space), 1 at the aim point (C), -1 stops.
function M.shoot(cmd)
  local s = storage.f3d
  local m = tonumber(cmd.m) or -1
  -- The aim point is used every tick while held (aim_target, shooting_state): finite, on the map.
  local x, y = world.fixed_in(cmd.x), world.fixed_in(cmd.y)
  if m < 0 or not x or not y then
    s.shooting = nil
    return
  end
  local sh = s.shooting or { fired_tick = -FIRING_TICKS }
  sh.selected = m == 1
  sh.x, sh.y = x / 256, y / 256
  sh.until_tick = game.tick + HOLD_TICKS
  s.shooting = sh
end

-- i: the gun slot to use (1-based). Empty slots are ignored.
function M.gun(cmd)
  local c = puppet.get()
  local i = math.floor(tonumber(cmd.i) or 0)
  local v, vguns
  if c then
    v, vguns = armed_vehicle(c)
  end
  if v then
    -- Driving: Tab and the tool bar pick the vehicle's gun, as in Factorio.
    if i >= 1 and i <= #vguns then
      pcall(function() v.selected_gun_index = i end)
      storage.f3d.guns_sig = nil
    end
    return
  end
  local guns = c and inventories(c)
  if guns and i >= 1 and i <= #guns and guns[i].valid_for_read then
    pcall(function() c.selected_gun_index = i end)
    storage.f3d.guns_sig = nil
  end
end

---------------------------------------------------------------------------------------------
-- Events

-- Damage cues are also used for creature blood, fire hits and ground scorch/fire marks.
-- Keep these sparse and local; the client pools their sprite cards.
local function is_valid_entity(obj)
  if not obj then return false end
  local ok, valid = pcall(function() return obj.valid end)
  return ok and valid == true
end

local function cause_position(event)
  local attacker = nil
  local ok_c, cause = pcall(function() return event.cause end)
  if ok_c and is_valid_entity(cause) then
    attacker = cause
  else
    local ok_s, source = pcall(function() return event.source end)
    if ok_s and is_valid_entity(source) then
      attacker = source
    end
  end
  if attacker then
    local ok_p, pos = pcall(function() return attacker.position end)
    if ok_p and pos then
      local ok_x, x = pcall(function() return pos.x or pos[1] end)
      local ok_y, y = pcall(function() return pos.y or pos[2] end)
      if ok_x and ok_y and type(x) == "number" and type(y) == "number" then
        return world.fixed(x), world.fixed(y)
      end
    end
  end
  return nil, nil
end

local function damage_type_name(event)
  local ok_dt, dt = pcall(function() return event.damage_type end)
  if ok_dt and dt then
    local ok_name, name = pcall(function() return dt.name end)
    if ok_name and type(name) == "string" and name ~= "" then
      return name
    end
  end
  return nil
end

local function entity_max_health(e)
  local ok_mh, mh = pcall(function() return e.max_health end)
  if ok_mh and type(mh) == "number" and mh > 0 then
    return mh
  end
  local ok_p, proto = pcall(function() return e.prototype end)
  if ok_p and proto then
    local ok_pmh, pmh = pcall(function() return proto.max_health end)
    if ok_pmh and type(pmh) == "number" and pmh > 0 then
      return pmh
    end
  end
  return nil
end

local function damage_amount(event, e)
  local ok_fd, fd = pcall(function() return event.final_damage_amount end)
  if not (ok_fd and type(fd) == "number" and fd >= 0) then
    return nil
  end
  local mh = entity_max_health(e)
  if mh and mh > 0 then
    return math.max(0, math.floor(fd / mh * 1000 + 0.5))
  end
  return nil
end

local function remaining_health(e)
  local ok_h, h = pcall(function() return e.health end)
  if not (ok_h and type(h) == "number") then
    return nil
  end
  local mh = entity_max_health(e)
  if mh and mh > 0 then
    return math.max(0, math.min(1000, math.floor(h / mh * 1000 + 0.5)))
  end
  return nil
end

local function source_name(event)
  local ok_s, source = pcall(function() return event.source end)
  if ok_s and is_valid_entity(source) then
    local ok_n, n = pcall(function() return source.name end)
    if ok_n and type(n) == "string" and n ~= "" then
      return n
    end
  end
  return nil
end

local function died_source_name(event)
  local ok_c, cause = pcall(function() return event.cause end)
  if ok_c and is_valid_entity(cause) then
    local ok_n, n = pcall(function() return cause.name end)
    if ok_n and type(n) == "string" and n ~= "" then
      return n
    end
  end
  local ok_s, source = pcall(function() return event.source end)
  if ok_s and is_valid_entity(source) then
    local ok_n, n = pcall(function() return source.name end)
    if ok_n and type(n) == "string" and n ~= "" then
      return n
    end
  end
  return nil
end

local function is_enemy_turret(e)
  local ok_t, t = pcall(function() return e.type end)
  if not (ok_t and t == "turret") then
    return false
  end
  local ok_f, f = pcall(function() return e.force end)
  if ok_f and f then
    local ok_fn, fname = pcall(function() return f.name end)
    if ok_fn and fname == "enemy" then
      return true
    end
  end
  local ok_n, n = pcall(function() return e.name end)
  if ok_n and type(n) == "string" and string.find(n, "worm", 1, true) ~= nil then
    return true
  end
  return false
end

local function is_damage_fx_target(e)
  local ok_t, t = pcall(function() return e.type end)
  if not (ok_t and type(t) == "string") then
    return false
  end
  if t == "unit" or t == "spider-unit" or t == "character" or t == "unit-spawner" then
    return true
  end
  return is_enemy_turret(e)
end

local function should_cache_last_hit(e)
  local ok_t, t = pcall(function() return e.type end)
  if not (ok_t and type(t) == "string") then
    return false
  end
  if t == "unit" or t == "spider-unit" or t == "unit-spawner" then
    return true
  end
  return is_enemy_turret(e)
end

-- `atk`: an enemy unit's own attack landed (a biter's bite on anything: a building, a wall, the
-- character), so the client can play its attack roar (Factorio's attack_parameters.sound). Only melee:
-- the unit is the damage's source as well as its cause (a spitter's acid comes from its stream, whose
-- start the client hears from `pj`). Near the focus, at most once per ATTACK_TICKS per attacker.
local function attack_cue(event)
  local ok_c, cause = pcall(function() return event.cause end)
  if not (ok_c and is_valid_entity(cause)) then
    return
  end
  local ok_t, t = pcall(function() return cause.type end)
  if not (ok_t and t == "unit") then
    return
  end
  local ok_s, source = pcall(function() return event.source end)
  if ok_s and is_valid_entity(source) then
    local ok_st, st = pcall(function() return source.type end)
    if not (ok_st and st == "unit") then
      return
    end
  end
  if not near_focus(cause) then
    return
  end
  local ok_u, un = pcall(function() return cause.unit_number end)
  if not (ok_u and un) then
    return
  end
  local s = storage.f3d
  local ticks = s.attack_ticks
  if not ticks then
    ticks = {}
    s.attack_ticks = ticks
    s.attack_count = 0
  end
  local last = ticks[un]
  if last and game.tick - last < ATTACK_TICKS then
    return
  end
  if not last then
    s.attack_count = (s.attack_count or 0) + 1
    if s.attack_count > ATTACK_PRUNE then
      local n = 0
      for k, v in pairs(ticks) do
        if game.tick - v > ATTACK_KEEP then
          ticks[k] = nil
        else
          n = n + 1
        end
      end
      s.attack_count = n + 1
    end
  end
  ticks[un] = game.tick
  local p = cause.position
  transport.send_now({ t = "atk", u = un, p = registry.entity_id(cause.name), x = world.fixed(p.x), y = world.fixed(p.y) })
end

function M.on_damaged(event)
  alerts.on_damaged(event)
  local e = event.entity
  turrets.on_hit(event)
  attack_cue(event)
  -- Damage cues are also used for creature blood, fire hits and ground scorch/fire marks.
  -- Keep these sparse and local; the client pools their sprite cards.
  if e.valid and near_focus(e) and is_damage_fx_target(e) then
    local p = e.position
    local dmg = damage_amount(event, e)
    local hp = remaining_health(e)
    local src = source_name(event)
    if e.unit_number and should_cache_last_hit(e) then
      local s = storage.f3d
      s.last_hit = s.last_hit or {}
      s.last_hit[e.unit_number] = { tick = game.tick, dmg = dmg, src = src }
    end
    local ok_s, source = pcall(function() return event.source end)
    source = (ok_s and is_valid_entity(source)) and source or nil
    local source_name_str = ""
    local source_type = ""
    if source then
      pcall(function() source_name_str = source.name or "" end)
      pcall(function() source_type = source.type or "" end)
    end
    local burning = source_type == "fire" or string.find(source_name_str, "flame", 1, true) ~= nil
    local s = storage.f3d
    s.hit_fx_ticks = s.hit_fx_ticks or {}
    local hit_key = e.unit_number or ("character:" .. math.floor(p.x) .. ":" .. math.floor(p.y))
    if game.tick - (s.hit_fx_ticks[hit_key] or -HIT_FX_TICKS) >= HIT_FX_TICKS then
      s.hit_fx_ticks[hit_key] = game.tick
      local msg = {
        t = "afx",
        fx = burning and "burn" or "blood",
        u = e.unit_number or 0,
        x = world.fixed(p.x),
        y = world.fixed(p.y),
      }
      local cx, cy = cause_position(event)
      if cx and cy then
        msg.cx, msg.cy = cx, cy
      end
      local dt = damage_type_name(event)
      if dt then
        msg.dt = dt
      end
      if dmg ~= nil then
        msg.dmg = dmg
      end
      if hp ~= nil then
        msg.hp = hp
      end
      if src ~= nil then
        msg.src = src
      end
      transport.send_now(msg)
    end
  end
  if e.valid and e.unit_number and near_focus(e) then
    storage.f3d.damaged[e.unit_number] = e
  end
end

function M.on_died(event)
  alerts.on_died(event)
  local e = event.entity
  if e.type == "character" then
    puppet.on_died(e)
  end
  tracker.removed(e)
  local lh = nil
  if e.unit_number then
    storage.f3d.damaged[e.unit_number] = nil
    if storage.f3d.hit_fx_ticks then
      storage.f3d.hit_fx_ticks[e.unit_number] = nil
    end
    if storage.f3d.attack_ticks and storage.f3d.attack_ticks[e.unit_number] then
      storage.f3d.attack_ticks[e.unit_number] = nil
      storage.f3d.attack_count = math.max(0, (storage.f3d.attack_count or 1) - 1)
    end
    if storage.f3d.last_hit then
      lh = storage.f3d.last_hit[e.unit_number]
      storage.f3d.last_hit[e.unit_number] = nil
    end
    turrets.on_removed(e.unit_number)
  end
  if near_focus(e) then
    local p = e.position
    local msg = {
      t = "died",
      u = e.unit_number or 0,
      p = registry.entity_id(e.name),
      x = world.fixed(p.x),
      y = world.fixed(p.y),
    }
    local cx, cy = cause_position(event)
    if cx and cy then
      msg.cx, msg.cy = cx, cy
    end
    local dt = damage_type_name(event)
    if dt then
      msg.dt = dt
    end
    local src = died_source_name(event)
    local dmg = nil
    if lh and (game.tick - lh.tick <= 2) then
      dmg = lh.dmg
      if not src then
        src = lh.src
      end
    end
    if dmg ~= nil then
      msg.dmg = dmg
    end
    if src ~= nil then
      msg.src = src
    end
    transport.send_now(msg)
  end
end

function M.register()
  script.on_event(defines.events.on_entity_damaged, M.on_damaged)
  script.on_event(defines.events.on_entity_died, M.on_died)
end

---------------------------------------------------------------------------------------------

-- The damageable entity of an enemy of the character's force (LuaForce::is_enemy, as the game
-- targets: not a neutral or friendly force's) closest to the aim point, within AIM_RADIUS tiles.
local AIM_RADIUS = 1.5
local function aim_target(c, x, y)
  local best, best_d
  for _, e in pairs(c.surface.find_entities_filtered({ position = { x, y }, radius = AIM_RADIUS })) do
    if e.valid and e ~= c and e.force ~= c.force and c.force.is_enemy(e.force) and e.health then
      local p = e.position
      local d = (p.x - x) ^ 2 + (p.y - y) ^ 2
      if not best_d or d < best_d then
        best, best_d = e, d
      end
    end
  end
  return best
end

-- The selected gun's name and attack parameters (cached per gun: they come from prototypes).
local gun_params = {}
local function selected_gun_params(c)
  local _, _, name = weapon(c)
  if not name then
    return nil
  end
  if gun_params[name] == nil then
    local ok, ap = pcall(function() return prototypes.item[name].attack_parameters end)
    gun_params[name] = ok and ap and { type = ap.type, range = ap.range or 15 } or false
  end
  return name, gun_params[name]
end

local function ammo_name(c)
  local stack = ammo_stack(c)
  return stack and stack.name or nil
end

-- Each shot the character fires (its ammo went down this tick), so the client can draw the
-- muzzle flash, casing and hit Factorio would: a headless server makes none of them (only when
-- visible). The target is the selected enemy, or the one nearest the character within the gun's
-- range, as the game picks for shooting_enemies. Flamethrowers fire every tick: their streams
-- come in `pj` instead.
local function send_shot(c, sh, state)
  local gun, params = selected_gun_params(c)
  if not gun or (params and params.type == "stream") then
    return
  end
  -- A vehicle's shots are turrets.lua's: `ts` counts its rounds and the client's turrets.gd draws
  -- each from the vehicle's gun (flash, hit, recoil, sound); a `shot` too would draw them twice.
  local _, _, _, vehicle = weapon(c)
  if vehicle then
    return
  end
  local target
  if state == defines.shooting.shooting_selected then
    local ok, sel = pcall(function() return c.selected end)
    target = ok and sel and sel.valid and sel.position
  end
  if not target then
    local enemy = c.surface.find_nearest_enemy({ position = c.position, max_distance = params and params.range or 15, force = c.force })
    target = enemy and enemy.position
  end
  target = target or { x = sh.x, y = sh.y }
  transport.send_now({ t = "shot", u = c.unit_number, g = gun, a = sh.ammo_name or ammo_name(c) or "",
    x = world.fixed(target.x), y = world.fixed(target.y) })
end

local function tick_shooting(c, s)
  local sh = s.shooting
  if sh and game.tick > sh.until_tick then
    s.shooting = nil
    sh = nil
  end
  if not sh then
    if s.shot then
      c.shooting_state = { state = defines.shooting.not_shooting, position = c.position }
      s.shot = nil
    end
    return
  end
  -- shooting_selected fires at the character's `selected` entity, which only a player sets, so
  -- select the enemy under the aim point ourselves (writable on a player-less character, checked
  -- in 2.1.23; in hybrid mode through the player if the character refuses, see /f3d-selftest).
  -- With nothing there, shoot at the nearest enemies instead.
  local state = defines.shooting.shooting_enemies
  if sh.selected then
    local target = aim_target(c, sh.x, sh.y)
    local player = target and puppet.player_of(c)
    if target and (pcall(function() c.selected = target end) or (player and pcall(function() player.selected = target end))) then
      state = defines.shooting.shooting_selected
    end
  end
  c.shooting_state = { state = state, position = { x = sh.x, y = sh.y } }
  s.shot = true
  local left = ammo_left(c)
  if left == 0 and not sh.warned then
    sh.warned = true
    puppet.message("Out of ammo")
  end
  if sh.ammo and left < sh.ammo then
    sh.fired_tick = game.tick
    send_shot(c, sh, state)
  end
  sh.ammo = left
  sh.ammo_name = ammo_name(c)
  sh.firing = game.tick - sh.fired_tick <= FIRING_TICKS
end

-- Rounds left in the magazine in use and the magazine's size (LuaItemStack.ammo,
-- LuaItemPrototype.magazine_size), for the ammo slot's green bar.
local function rounds_of(stack)
  local ok, rounds = pcall(function() return stack.ammo end)
  local ok2, size = pcall(function() return stack.prototype.magazine_size end)
  return ok and math.floor(rounds or 0) or 0, ok2 and math.floor(size or 0) or 0
end

-- The vehicle's guns, as send_guns' list: each of its guns over its ammo slot.
local function vehicle_guns(v, guns, ammo)
  local list, parts = {}, {}
  for i, name in ipairs(guns) do
    local a = ammo and i <= #ammo and ammo[i] or nil
    local rec = { name, "", 0, 0, 0 }
    if a and a.valid_for_read then
      rec[2], rec[3] = a.name, a.count
      rec[4], rec[5] = rounds_of(a)
    end
    list[i] = rec
    parts[i] = table.concat(rec, "/")
  end
  local ok, sel = pcall(function() return v.selected_gun_index end)
  return list, parts, ok and sel or 1
end

-- [[gun, ammo, magazines, rounds, magazine size], ...] per gun slot ("" for empty), and the
-- selected slot; in an armed vehicle its guns, with `v` its unit number (N3).
local function send_guns(c, s)
  local v, vguns, vammo = armed_vehicle(c)
  if v then
    local list, parts, sel = vehicle_guns(v, vguns, vammo)
    local sig = "v" .. tostring(v.unit_number) .. ":" .. sel .. ":" .. table.concat(parts, ",")
    if sig ~= s.guns_sig then
      s.guns_sig = sig
      transport.send_reliable_priority({ t = "guns", sel = sel, l = list, v = v.unit_number or 0 })
    end
    return
  end
  local guns, ammo = inventories(c)
  if not (guns and ammo) then
    return
  end
  local list, parts = {}, {}
  for i = 1, #guns do
    local g = guns[i]
    local a = i <= #ammo and ammo[i] or nil
    local rec = {
      g.valid_for_read and g.name or "",
      a and a.valid_for_read and a.name or "",
      a and a.valid_for_read and a.count or 0,
    }
    if a and a.valid_for_read then
      rec[4], rec[5] = rounds_of(a)
    else
      rec[4], rec[5] = 0, 0
    end
    list[i] = rec
    parts[i] = table.concat(rec, "/")
  end
  local sel = selected_gun(c) or 1
  local sig = sel .. ":" .. table.concat(parts, ",")
  if sig ~= s.guns_sig then
    s.guns_sig = sig
    transport.send_reliable_priority({ t = "guns", sel = sel, l = list })
  end
end

-- Every damaged entity near the camera with its health, as a full list each time; an entity
-- that healed, died or left the area drops out.
local MAX_DAMAGED = 1500 -- damaged entities remembered (trees and walls never heal): past it the far ones go
local function send_health(s)
  local flat = {}
  local kept, far = 0, {}
  for unit, e in pairs(s.damaged) do
    -- Kept while it is still damaged, near the focus or not: one the camera left and came back to
    -- still shows its bar (Factorio draws a damaged entity's bar whenever it is on screen).
    local ratio = e.valid and e.get_health_ratio()
    if ratio and ratio < 1 then
      kept = kept + 1
      if near_focus(e) then
        flat[#flat + 1] = unit
        flat[#flat + 1] = math.floor(ratio * 1000 + 0.5)
      else
        far[#far + 1] = unit
      end
    else
      s.damaged[unit] = nil
    end
  end
  for i = 1, math.min(#far, kept - MAX_DAMAGED) do
    s.damaged[far[i]] = nil
  end
  local per = PAIRS_PER_MESSAGE * 2
  local parts = math.max(1, math.ceil(#flat / per))
  for part = 1, parts do
    local slice = {}
    for i = (part - 1) * per + 1, math.min(part * per, #flat) do
      slice[#slice + 1] = flat[i]
    end
    transport.send_now({ t = "hp", part = part, parts = parts, l = slice })
  end
end

function M.tick()
  local s = storage.f3d
  local c = puppet.get()
  if c then
    tick_shooting(c, s)
    if game.tick % GUNS_INTERVAL == 0 then
      send_guns(c, s)
    end
  end
  if game.tick % HEALTH_INTERVAL == 0 then
    send_health(s)
    -- Units hit that never die here (gone home into their spawner, walked off, a character that
    -- lived) would keep their entry for good: only the last HIT_FX_TICKS matter.
    for key, at in pairs(s.hit_fx_ticks or {}) do
      if game.tick - at >= HIT_FX_TICKS then
        s.hit_fx_ticks[key] = nil
      end
    end
    for u, lh in pairs(s.last_hit or {}) do
      if game.tick - lh.tick > 2 then
        s.last_hit[u] = nil
      end
    end
  end
end

-- After a handshake or when the client leaves.
function M.reset()
  local s = storage.f3d
  s.shooting = nil
  s.guns_sig = nil
  s.damaged = {}
  s.hit_fx_ticks = nil
  s.last_hit = nil
  s.attack_ticks = nil
  s.attack_count = nil
  local c = s.puppet
  if s.shot and c and c.valid then
    c.shooting_state = { state = defines.shooting.not_shooting, position = c.position }
  end
  s.shot = nil
end

return M
