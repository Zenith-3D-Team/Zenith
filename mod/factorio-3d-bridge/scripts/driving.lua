-- Getting in and out of vehicles and driving them: Factorio's Enter key and WASD. The character
-- drives through `riding_state`, as a player does, so cars, tanks, spidertrons and trains all
-- behave as the game makes them.

local registry = require("scripts.registry")
local puppet = require("scripts.puppet")

local M = {}

local HOLD_TICKS = 30      -- a drive command lasts this long unless the client repeats it
local ENTER_DISTANCE = 5   -- from the character's centre to the vehicle's
-- The numbers the client sends, by their defines.riding names.
local ACCELERATION = { [0] = "nothing", [1] = "accelerating", [2] = "braking", [3] = "reversing" }
-- Below this speed (tiles a tick) a vehicle braking under "hold" counts as stopped.
local STOP_SPEED = 0.002
local DIRECTION = { [-1] = "left", [0] = "straight", [1] = "right" }

local function distance(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

-- Wagons have no seat: Enter never gets into them, even when one is nearer than the locomotive.
local SEATLESS = { ["cargo-wagon"] = true, ["fluid-wagon"] = true, ["artillery-wagon"] = true }

local function nearest_vehicle(c)
  local types = {}
  for _, t in pairs(registry.vehicle_types()) do
    if not SEATLESS[t] then
      types[#types + 1] = t
    end
  end
  if #types == 0 then
    return nil
  end
  local p, r = c.position, ENTER_DISTANCE
  local best, best_d = nil, r
  for _, v in pairs(c.surface.find_entities_filtered({ area = { { p.x - r, p.y - r }, { p.x + r, p.y + r } }, type = types })) do
    local d = distance(p, v.position)
    if d <= best_d then
      best, best_d = v, d
    end
  end
  return best
end

-- get_driver gives the character, or the player when a player sits in it (single-player).
local function is_driver(v, c)
  local d = v.get_driver()
  if d == nil then
    return false
  end
  if d == c then
    return true
  end
  local ok, character = pcall(function() return d.character end)
  return ok and character == c
end

local function stop_riding(c)
  c.riding_state = {
    acceleration = defines.riding.acceleration.nothing,
    direction = defines.riding.direction.straight,
  }
end

-- A burner vehicle with nothing burning and nothing to burn.
local function out_of_fuel(v)
  local ok, empty = pcall(function()
    local burner = v.burner
    return burner ~= nil and burner.remaining_burning_fuel <= 0 and burner.inventory.is_empty()
  end)
  return ok and empty
end

---------------------------------------------------------------------------------------------
-- Commands

-- Gets out of the vehicle the character is in, or into the nearest one: the driver's seat, or a
-- car's passenger seat if someone is driving.
-- Whether the tile under the character blocks it (water for a boat's driver: Factorio finds a player
-- a free spot when they get out, but not a script's character, which stayed standing in the water
-- and could be run over by its own boat).
local function on_blocking_tile(c)
  local ok, blocked = pcall(function()
    local pos = c.position
    local tile = c.surface.get_tile(math.floor(pos.x), math.floor(pos.y)).prototype.collision_mask.layers
    for layer in pairs(c.prototype.collision_mask.layers) do
      if tile[layer] then
        return true
      end
    end
    return false
  end)
  return ok and blocked
end

function M.enter()
  local s = storage.f3d
  local c = puppet.get()
  if not c then
    return
  end
  local v = puppet.vehicle(c)
  if v then
    s.drive = nil
    stop_riding(c)
    local driver = not (v.type == "car" and not is_driver(v, c))
    if driver then
      v.set_driver(nil)
    else
      v.set_passenger(nil)
    end
    if on_blocking_tile(c) then
      local spot = c.surface.find_non_colliding_position(c.name, c.position, 20, 0.5)
      if spot then
        c.teleport(spot)
      else
        -- Nowhere to stand within reach: back in the seat.
        if driver then
          v.set_driver(c)
        else
          v.set_passenger(c)
        end
        puppet.message("Nowhere to get out here")
        return
      end
    end
    s.me_now = true
    return
  end
  v = nearest_vehicle(c)
  if not v then
    return puppet.message("No vehicle nearby")
  end
  if v.force ~= c.force and v.force.name ~= "neutral" then
    return puppet.message("That vehicle belongs to someone else")
  end
  if not v.get_driver() then
    v.set_driver(c)
  elseif v.type == "car" and not v.get_passenger() then
    v.set_passenger(c)
  else
    return puppet.message("That vehicle is full")
  end
  if puppet.vehicle(c) ~= v then
    puppet.message("Can't get in")
  else
    s.me_now = true
  end
end

-- a: 0 nothing, 1 accelerate, 2 brake, 3 reverse; s: -1 left, 0 straight, 1 right. Both 0 stops.
-- h: 1 (optional, the client's "opposite key brakes and holds" option): holding the key opposite
-- to the motion (a 3 while going forward, a 1 while reversing) brakes to a stop and then stays
-- stopped until that key is let go; see M.tick. Old clients never send it.
function M.drive(cmd)
  local s = storage.f3d
  local a = math.floor(tonumber(cmd.a) or 0)
  local d = math.floor(tonumber(cmd.s) or 0)
  local h = (tonumber(cmd.h) or 0) == 1
  local prev = s.drive
  local was_going = prev and game.tick <= prev.until_tick
  if not (ACCELERATION[a] and DIRECTION[d]) or (a == 0 and d == 0) then
    if was_going or s.riding then
      s.me_now = true
    end
    s.drive = nil
    return
  end
  if not was_going or prev.a ~= a or prev.d ~= d then
    s.me_now = true
  end
  local drive = prev or {}
  if prev and (prev.a ~= a or prev.h ~= h) then
    drive.braking, drive.held = nil, nil -- another key (or none) than the one that braked: let go
  end
  drive.a, drive.d, drive.h = a, d, h
  drive.until_tick = game.tick + HOLD_TICKS
  s.drive = drive
end

---------------------------------------------------------------------------------------------

function M.tick()
  local s = storage.f3d
  local c = puppet.get()
  if not c then
    return
  end
  local drive = s.drive
  if drive and game.tick > drive.until_tick then
    s.drive = nil
    drive = nil
  end
  local v = puppet.vehicle(c)
  if not (v and drive) then
    if s.riding then
      stop_riding(c)
      s.riding = nil
    end
    return
  end
  local accel = drive.a
  if drive.h and (accel == 1 or accel == 3) and (v.type == "car" or v.type == "locomotive") then
    local ok, sp = pcall(function() return v.speed end)
    sp = ok and tonumber(sp) or 0
    local against = (accel == 3 and sp > STOP_SPEED) or (accel == 1 and sp < -STOP_SPEED)
    if drive.held then
      accel = 0 -- stopped by the brake: stay put until the key is let go
    elseif against then
      drive.braking = true
      accel = 2
    elseif drive.braking then
      drive.braking, drive.held = nil, true -- the brake got it to a stop
      accel = 0
    end
  else
    drive.braking, drive.held = nil, nil
  end
  c.riding_state = {
    acceleration = defines.riding.acceleration[ACCELERATION[accel]],
    direction = defines.riding.direction[DIRECTION[drive.d]],
  }
  s.riding = true
  if drive.a ~= 0 then
    if v.type == "locomotive" then
      -- A train only takes the driver's input in manual mode, as when a player starts driving.
      pcall(function()
        if not v.train.manual_mode then
          v.train.manual_mode = true
        end
      end)
    end
    if not drive.warned and out_of_fuel(v) then
      drive.warned = true
      puppet.message("No fuel")
    end
  end
end

-- After a handshake or when the client leaves. The character stays in its vehicle.
function M.reset()
  local s = storage.f3d
  s.drive = nil
  local c = s.puppet
  if s.riding and c and c.valid then
    stop_riding(c)
  end
  s.riding = nil
end

return M
