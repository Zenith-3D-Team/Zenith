-- Enemies notice the bridge's player-less character as they would a real player's.
--
-- Found in real 2.1.24 (live_check --only enemysight): a nest's own idle biters (spawner-owned) ignore a
-- character that has no player, from 50 tiles to 1, until it shoots; loose biters and worms see it. The
-- engine's sighting is tied to a player, which a headless server's bridge character doesn't have. So this
-- does for such a character what the engine was measured doing for a real player's on the same map and nest
-- (a real Factorio joined, 2.1.24; art-src/notes/stability/enemy-realplayer.md):
-- - Wake: a sleeping unit (no distraction, no attack of its own, in no unit group) wakes when the character is
--   within its own prototype's vision_distance (small biters 30; measured 27.2-29.4 from the nearest unit).
--   Out of vision nothing wakes (37 tiles for 20 s: nothing).
-- - The whole nest: when a unit with a spawner wakes, every sleeping unit of that spawner and of the spawners
--   within NEST_EXTRA of it wakes with it (14 of 14 within 0.6 s), not only those in vision; the engine's call
--   for help doesn't follow a scripted distraction, so it is done here. Another nest's units nearby, and units
--   attacking something else, are left alone. The spawners a wake covered are kept for FORGET_TICKS after the
--   last of their units it gave: a fresh unit of theirs (one just spawned, or back from a group) is given alone,
--   with no new search and no place under MAX_NESTS, so a spawning nest can't keep another nest from waking.
-- - Hold: while the character stands, each woken unit is kept on it for its own hold, spread over HOLD (about
--   half gone by 8-10 s), by re-giving the distraction when the engine's ends, until 15 s at most; past that the
--   engine's own tail keeps a few on it (a scripted one alone kept 3 of 12 at 40 s live), as a real player's
--   few at 30-40 s. The spread is by unit number, the same on every peer.
-- - Chase, no leash: while the character moves, every woken unit within its vision of it is kept on it (the
--   holds count from the last move), however far from its nest (none gave up within 400 tiles); they fall
--   off as they fall behind. The ones that had dropped off rejoin when it moves again, as measured.
-- - Worms are turrets, which see the player-less character on their own (the diagnostic: shot from 21.5 tiles,
--   their range), as for a real player; nothing done for them.
-- With a real player (hybrid single-player, an L13 claimed player) the engine does it and this does nothing.
-- - In a vehicle: a real player driving or riding a car, tank or spidertron near a nest wakes it and the biters
--   attack the vehicle (the engine's targets are military targets, and the vehicle is the one in reach; the
--   character inside can't be hit). So for the player-less character in such a vehicle the same vision, nest
--   wake, holds and chase are counted from the vehicle and the command's target is the vehicle; on getting in or
--   out, the units this woke whose distraction was on the old target are given the new one (the chase rule for
--   that pass). Trains (locomotives, wagons) are not military targets in Factorio's prototypes and biters don't
--   go for a train going by, so nothing is done for a character in one (nor anything for a vehicle that is not a
--   military target, not destructible, or that a real player shares: the engine sees that one). Switch
--   /f3d-perf enemy_sight_vehicle (on); off: nothing done in any vehicle, as before.
--
-- Switch: /f3d-perf enemy_sight (perf.lua); off: nothing done, as before.
--
-- Cost: every 30 ticks, for the character, one find_units over the square of the largest unit vision (60 by
-- 60 tiles on Nauvis) and a few reads per unit in it; one spawner search and one more find_units per nest
-- that wakes, at most MAX_NESTS a pass (none for a nest woken within FORGET_TICKS). Nothing while no enemy unit
-- is near.
--
-- Deterministic: what it decides by is in storage (storage.f3d.sight), changed only in on_tick; the holds come
-- from unit numbers. The module-local tables are derived from prototypes alone.

local puppet = require("scripts.puppet")
local perf = require("scripts.perf")

local M = {}

local INTERVAL = 30
local PHASE = 17 -- its own tick in the half second, off the other 30-tick jobs' 0

-- How long the woken are kept on a standing character, from the real player's two runs (14 and 13 small biters):
-- {share of them, seconds since the wake or the last move until the bridge stops giving it again}. The start
-- follows the real drop-off; re-giving ends by 15 s and the engine's own tail does the rest (below). A unit's own
-- share is its place in a low-discrepancy spread of unit numbers, so a nest's spread follows the curve.
M.HOLD = {
  { 0, 2.5 }, { 0.1, 3.5 }, { 0.2, 4.5 }, { 0.35, 6.5 }, { 0.5, 8.5 }, { 0.62, 10 }, { 0.7, 11 },
  { 0.85, 13 }, { 1, 15 },
}
-- The engine's distraction outlasts its last re-giving: most fall away within about 3 s, but some stay on far
-- longer by themselves (live, given once at the wake and never again: 12 on it, about 6 at 8 s, 4 at 10-17 s,
-- 3 still at 40 s). The shortest is taken off the hold so the first drop-off lands on the curve; the long tail
-- is left to the engine, which is why HOLD ends early.
M.FADE_TICKS = 180
-- The character moved (more than this in a pass) restarts the holds: the chase.
M.MOVED = 0.5
-- A waking unit's nest: the spawners within this much of its spawner (the cluster), and their sleeping units
-- within this much past its vision of its spawner.
M.NEST_EXTRA = 15
-- Nests woken in one pass, at most (each one find_entities_filtered and one find_units); the rest next pass.
M.MAX_NESTS = 4
-- The search's reach is the largest unit vision_distance, capped here.
local MAX_SEARCH = 100
-- Units in a unit group (LuaCommandable.parent_group) are left to the engine: a group moves on its own orders
-- (an attack, an expansion) and answers enemies as a group. A nest's idle biters are in none (seen live).
M.SKIP_GROUPED = true
-- Records of units not seen for this long are dropped, and of woken spawners none of whose units it gave for this
-- long.
local FORGET_TICKS = 600

-- Unit prototypes' vision, by name (prototypes only, the same on every peer).
local vision_of_name = {}
local search_radius = nil

local function proto_number(p, key)
  local ok, v = pcall(function() return p[key] end)
  return ok and type(v) == "number" and v or nil
end

local function vision(e)
  local v = vision_of_name[e.name]
  if not v then
    v = proto_number(e.prototype, "vision_distance") or 30
    vision_of_name[e.name] = v
  end
  return v
end

local function radius()
  if not search_radius then
    local r = 0
    local ok, units = pcall(function() return prototypes.get_entity_filtered({ { filter = "type", type = "unit" } }) end)
    if ok and units then
      for _, p in pairs(units) do
        r = math.max(r, proto_number(p, "vision_distance") or 0)
      end
    end
    search_radius = math.min(r > 0 and r or 30, MAX_SEARCH)
  end
  return search_radius
end

-- A unit's hold in ticks: its place in the spread of unit numbers (a Weyl sequence, even for consecutive
-- numbers) read off HOLD, less the engine's own fade.
function M.hold_ticks(unit_number)
  local q = (unit_number * 0.6180339887498949) % 1
  local h = M.HOLD
  local secs = h[#h][2]
  for i = 2, #h do
    if q <= h[i][1] then
      local a, b = h[i - 1], h[i]
      secs = a[2] + (b[2] - a[2]) * (q - a[1]) / (b[1] - a[1])
      break
    end
  end
  return math.max(0, math.floor(secs * 60 + 0.5) - M.FADE_TICKS)
end

local function dist(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function read(obj, key)
  local ok, v = pcall(function() return obj[key] end)
  if ok then
    return v
  end
  return nil
end

local function hittable(e)
  return read(e, "destructible") ~= false and (read(e, "health") or 1) > 0
end

-- Whether a seat's occupant (a character, or a LuaPlayer) has a real player.
local function real_occupant(o, c)
  if not o or o == c then
    return false
  end
  return read(o, "object_name") == "LuaPlayer" or puppet.player_of(o) ~= nil
end

-- What enemies would see of a real player's character here: the character on foot, the car, tank or spidertron it
-- drives or rides (a military target); nil when they would see nothing (or the engine already does).
local function sight_target(c)
  if not (c and c.valid) or puppet.player_of(c) or not hittable(c) or puppet.hub(c) then
    return nil
  end
  local surface = c.surface
  if read(surface, "peaceful_mode") or read(surface, "no_enemies_mode") then
    return nil
  end
  local v = puppet.vehicle(c)
  if not v then
    return c
  end
  if not (v.valid and perf.on("enemy_sight_vehicle") and read(v, "is_military_target") == true and hittable(v)) then
    return nil
  end
  for _, seat in ipairs({ "get_driver", "get_passenger" }) do
    local ok, o = pcall(function() return v[seat]() end)
    if ok and real_occupant(o, c) then
      return nil
    end
  end
  return v
end
M.sight_target = sight_target

-- A unit free to be woken: no distraction, a command that takes one and isn't an attack of its own, in no group.
local function asleep(cmd)
  if read(cmd, "distraction_command") ~= nil then
    return false
  end
  local own = read(cmd, "command")
  if own and (own.distraction == defines.distraction.none or own.type == defines.command.attack
      or own.type == defines.command.attack_area) then
    return false
  end
  return not (M.SKIP_GROUPED and read(cmd, "parent_group"))
end

function M.tick()
  if (game.tick + PHASE) % INTERVAL ~= 0 then
    return
  end
  local s = storage.f3d
  local t = perf.on("enemy_sight") and sight_target(puppet.get())
  if not t then
    s.sight = nil
    return
  end
  local now = game.tick
  local at = t.position
  local st = s.sight
  if not st then
    st = { x = at.x, y = at.y, moved = -1e9, units = {} }
    s.sight = st
  end
  st.nests = st.nests or {} -- (a sight table from before the woken spawners were kept)
  if dist(at, st) > M.MOVED then
    st.moved = now
  end
  st.x, st.y = at.x, at.y
  -- Into or out of a vehicle: the units on the old target are given the new one, and the chase rule runs this pass.
  local old_target = st.target
  local retarget = old_target ~= nil and old_target ~= t.unit_number
  st.target = t.unit_number
  if retarget then
    st.moved = now
  end
  local recs, woken = st.units, st.nests
  local command = { type = defines.command.attack, target = t, distraction = defines.distraction.by_enemy }

  -- Whether a unit this woke is still on the old target (or its distraction's target is gone).
  local function on_old(cmd)
    local d = read(cmd, "distraction_command")
    local tg = d and d.target
    if not tg then
      return false
    end
    return not tg.valid or tg.unit_number == old_target
  end

  local function give(cmd)
    return pcall(cmd.set_distraction_command, command)
  end

  -- A unit's spawner's number, or nil (a loose unit, or its spawner gone).
  local function spawner_key(cmd)
    local sp = read(cmd, "spawner")
    if sp and sp.valid then
      return sp.unit_number, sp
    end
    return nil
  end

  -- How many nests woke this pass; the spawners they covered go into woken (by number, the tick).
  local nest_count = 0
  local function wake_nest(u, v, key, sp)
    nest_count = nest_count + 1
    -- The nest is the spawner's cluster: it and the spawners within NEST_EXTRA of it (a nest of two or three
    -- spawners wakes together). A neighbouring nest's units in the circle are not its own and stay asleep.
    local p, r = sp.position, v + M.NEST_EXTRA
    local cluster = { [key] = true }
    local ok, near = pcall(t.surface.find_entities_filtered,
      { type = "unit-spawner", position = p, radius = M.NEST_EXTRA, force = u.force })
    if ok and near then
      for _, o in ipairs(near) do
        if o.valid and o.unit_number then
          cluster[o.unit_number] = true
        end
      end
    end
    for k in pairs(cluster) do
      woken[k] = now
    end
    for _, o in ipairs(t.surface.find_units({
      area = { { p.x - r, p.y - r }, { p.x + r, p.y + r } }, force = u.force, condition = "same",
    })) do
      local cmd, n = o.commandable, o.unit_number
      if cmd and n and not recs[n] and cluster[spawner_key(cmd) or false] and asleep(cmd)
          and dist(o.position, p) <= r and give(cmd) then
        recs[n] = { first = now, seen = now }
      end
    end
  end

  local r = radius()
  for _, u in ipairs(t.surface.find_units({
    area = { { at.x - r, at.y - r }, { at.x + r, at.y + r } }, force = t.force, condition = "enemy",
  })) do
    local cmd, n = u.commandable, u.unit_number
    if cmd and n then
      local rec = recs[n]
      if rec then
        rec.seen = now
      end
      local v = vision(u)
      if dist(u.position, at) <= v and (asleep(cmd) or (rec and retarget and on_old(cmd))) then
        if not rec then
          -- A fresh sighting: it and its nest, unless its nest woke lately (then it alone: a straggler, a new
          -- spawn). Past MAX_NESTS this pass, a unit of a nest not yet woken waits (no command, no record), so it
          -- is a fresh sighting again next pass and its nest wakes then.
          local key, sp = spawner_key(cmd)
          local new_nest = key and not woken[key]
          if not (new_nest and nest_count >= M.MAX_NESTS) and give(cmd) then
            recs[n] = { first = now, seen = now }
            if new_nest then
              wake_nest(u, v, key, sp)
            elseif key then
              woken[key] = now
            end
          end
        elseif st.moved == now or now - math.max(rec.first, st.moved) < M.hold_ticks(n) then
          -- Its distraction ended within its hold (standing) or while the character moves (the chase).
          give(cmd)
        end
      end
    end
  end
  for n, rec in pairs(recs) do
    if now - rec.seen > FORGET_TICKS then
      recs[n] = nil
    end
  end
  for k, t in pairs(woken) do
    if now - t > FORGET_TICKS then
      woken[k] = nil
    end
  end
end

return M
