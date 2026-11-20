-- The character the 3D client controls.
--
-- Single-player (hybrid mode): the player's own character, with the Factorio window still open.
-- Server (headless mode): a character the bridge creates and owns; nobody needs to be connected.

local registry = require("scripts.registry")
local transport = require("scripts.transport")
local world = require("scripts.world")
local tracker = require("scripts.tracker")
local takeover = require("scripts.takeover")
local as_player = require("scripts.as_player")
local perf = require("scripts.perf")

local M = {}

-- What a new freeplay player starts with.
local STARTER_KIT = {
  { name = "iron-plate", count = 8 },
  { name = "wood", count = 1 },
  { name = "pistol", count = 1 },
  { name = "firearm-magazine", count = 10 },
  { name = "burner-mining-drill", count = 1 },
  { name = "stone-furnace", count = 1 },
}

local HOLD_TICKS = 30      -- a walk, mine or pickup command lasts this long unless the client repeats it
local REACH_SLACK = 1.5    -- reach is measured to the entity's edge in-game; we measure to its centre
local PICKUP_SLACK = 0.5   -- the same for picking up items on the ground
local PICKUPS_PER_TICK = 2 -- (/f3d-perf belt_pickup off: the ground only, as before)
-- F with belt_pickup (issue #18): every item in range a tick, as Factorio; this many at most (a bus's first tick).
local PICKS_PER_TICK = 16
-- The inventory and slots after a pick-up are sent at most this often (F held by a busy belt takes items every tick).
local PICK_REPORT_TICKS = 6
local STATE_INTERVAL = 2
local INVENTORY_INTERVAL = 30
local RECIPES_INTERVAL = 600

local function message(text)
  transport.send_now({ t = "msg", text = text })
end
M.message = message

-- A stack's quality's name ("normal" when it can't say).
local function stack_quality(st)
  local ok, q = pcall(function() return st.quality.name end)
  return ok and q or "normal"
end
M.stack_quality = stack_quality

-- L7: the stack in slot `hs` of the inventory (the main inventory slot the client's hand holds it from), or
-- nil: only while that slot holds the item in `quality` (normal when none is given). The one rule for every
-- command that spends from the hand (building, Z, Ctrl+click, tiles, capsules, as_player).
function M.held_stack(inventory, hs, item, quality)
  hs = math.floor(tonumber(hs) or 0)
  if not inventory or hs < 1 or hs > #inventory then
    return nil
  end
  local st = inventory[hs]
  if st and st.valid_for_read and st.name == item and stack_quality(st) == (quality or "normal") then
    return st
  end
  return nil
end

-- The quality of the stack in slot `hs` when it holds the item, else nil: what the hand holds, for
-- commands that carry no quality of their own (Z, tiles, capsules) or as a build's default.
function M.held_quality(inventory, hs, item)
  hs = math.floor(tonumber(hs) or 0)
  if not inventory or hs < 1 or hs > #inventory then
    return nil
  end
  local st = inventory[hs]
  if st and st.valid_for_read and st.name == item then
    return stack_quality(st)
  end
  return nil
end

-- L7: takes `count` of the item in `quality` (normal when none is given) out of an inventory as Factorio
-- spends the cursor's stack: off the held stack (M.held_stack) first, the rest off any stack of the item
-- in that quality. `hs` nil or 0, or something else there: any stack of it, as before.
function M.take_held(inventory, hs, item, count, quality)
  quality = quality or "normal"
  local left = count
  local st = M.held_stack(inventory, hs, item, quality)
  if st then
    local k = math.min(left, st.count)
    if k >= st.count then
      st.clear()
    else
      st.count = st.count - k
    end
    left = left - k
  end
  if left > 0 then
    local stack = { name = item, count = left }
    if quality ~= "normal" then
      stack.quality = quality
    end
    inventory.remove(stack)
  end
end

-- The player playing this character in single-player (hybrid mode), or nil for the bridge's own
-- player-less character on a server.
function M.player_of(c)
  local ok, p = pcall(function() return c.player end)
  return ok and p or nil
end

local function distance(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

-- Walking supports 8 of the 16 directions: the even ones.
local function walk_direction(d)
  return (math.floor(d / 2 + 0.5) * 2) % 16
end

local function create_character(surface, near, force)
  local position = surface.find_non_colliding_position("character", near, 32, 0.5) or near
  return surface.create_entity({ name = "character", position = position, force = force })
end

-- The player whose character the bridge plays (see takeover.lua), deciding once per game.
function M.owner()
  local s = storage.f3d
  if s.extra then
    return nil -- a second client plays a character of its own (session.lua)
  end
  if not game.is_multiplayer() then
    return game.get_player(1) -- single-player (hybrid mode): always the player
  end
  if not s.owner_checked then
    s.owner_checked = true
    local p = takeover.choose(s)
    s.owner_index = p and p.index or nil
  end
  return s.owner_index and game.get_player(s.owner_index) or nil
end

-- Decide again who to play as (after /f3d-player, the setting, or a player joining or leaving).
function M.recheck(choose_again)
  local s = storage.f3d
  s.recheck = true
  if choose_again then
    s.owner_checked = nil
  end
end

-- L13: the player who joins with this Zenith's own Factorio takes over the character the client
-- plays. The client's hello names the account its PC's Factorio plays under (`pn`, from
-- player-data.json; Ctrl+F9 starts that Factorio joined to the same server), so a player of that
-- name joining while the bridge plays its own character (a world Zenith made has no player of its
-- own) becomes the one it plays, as a save's player is: M.get hands them the character, and when
-- they leave the bridge stands in for them until they come back. Only the first client's character
-- (another client plays one of its own), never over a save's player or a /f3d-player choice, and
-- only that name: anyone else who joins gets a character of their own, as before. Everything comes
-- from events and the client's packets, so every peer decides the same. True when claimed.
function M.claim(index)
  local s = storage.f3d
  if s.extra or not game.is_multiplayer() or not perf.on("zenith_join") then
    return false
  end
  local name = s.client and s.client.pn
  if type(name) ~= "string" or name == "" then
    return false
  end
  local p = game.get_player(index)
  if not (p and p.valid and p.connected and p.name == name) then
    return false
  end
  if s.owner_pick == 0 or M.owner() then
    return false -- the bridge plays a save's player (or this one already), or was told to play none
  end
  local made = s.made_player
  s.zenith_owner = p.index
  s.owner_index = p.index
  s.owner_checked = true
  -- `new`: freeplay has just made them a character with its starting kit, which they had already.
  s.claimed = { index = p.index, new = made ~= nil and made.index == p.index and game.tick - made.tick <= 60 }
  s.recheck = true
  log("[Zenith] player " .. p.index .. " joined with this Zenith's Factorio: they take over its character")
  return true
end

-- The client's hello named its Factorio's account (a new session, or another name): a player of
-- that name already in the game (they joined before this Zenith connected) is claimed now.
function M.claim_named()
  local s = storage.f3d
  local name = s.client and s.client.pn
  if type(name) ~= "string" or name == "" then
    return false
  end
  local p = game.get_player(name)
  return p ~= nil and M.claim(p.index)
end

-- The player whose things the bridge's own character holds while they are away, or nil.
function M.held_for()
  local s = storage.f3d
  return s.held_for and game.get_player(s.held_for) or nil
end

-- A player claimed as this Zenith's (M.claim) gets the bridge's own character itself: its place,
-- health, inventories, armour, requests, crafting queue, the vehicle it sits in, and the client goes
-- on with the same entity. The character the game gave them on joining is emptied into it (without
-- freeplay's starting kit when they are new) and removed. "wait" while they can't take it yet (in a
-- cutscene or the remote view); false when the game refused, and the old way is used instead.
local function hand_over(player, own, fresh, new)
  local ok, kind = pcall(function() return player.controller_type end)
  if not ok or kind ~= defines.controllers.character then
    return "wait"
  end
  local done = pcall(player.set_controller, { type = defines.controllers.character, character = own })
  if not (done and player.character == own) then
    return false
  end
  if fresh and fresh.valid and fresh ~= own then
    if new then
      takeover.drop_created_items(fresh)
    end
    takeover.absorb(fresh, own)
  end
  takeover.copy_quickbar(storage.f3d.quickbar, player)
  return true
end

-- The character the client controls:
-- - the owner's own character while they are connected (single-player, hybrid mode, or a player
--   who joined the server with the real game); a stand-in's things move back onto it first;
-- - while the owner is away, the bridge's stand-in holding their things, where they were;
-- - with no owner (a new map), the bridge's own character with a starter kit, as before.
function M.get()
  local s = storage.f3d
  -- A save moving between a server and single-player decides again.
  local mp = game.is_multiplayer()
  if s.puppet and s.puppet.valid and (s.owner_checked or not mp) and not s.recheck and s.was_mp == mp then
    return s.puppet
  end
  s.recheck = nil
  s.was_mp = mp
  local owner = M.owner()
  local old = s.puppet and s.puppet.valid and s.puppet or nil
  s.puppet = nil
  if owner and not owner.connected and s.claimed and s.claimed.index == owner.index then
    -- Claimed (L13) but gone again before taking the character: the bridge goes on with its own.
    s.claimed, s.zenith_owner, s.owner_index = nil, nil, nil
    owner = nil
  end

  if owner and owner.connected then
    local c = owner.character
    if not c and old and s.held_for == owner.index then
      s.puppet = old -- they have no character yet (dead, or still in the menu): keep standing in
      return old
    end
    -- The player who joined with this Zenith's Factorio (L13) takes over the client's character.
    local claimed = s.claimed and s.claimed.index == owner.index and s.claimed or nil
    local handed = nil
    if claimed and old and old ~= c and not s.held_for and s.own_character == old then
      handed = hand_over(owner, old, c, claimed.new)
      if handed == "wait" then
        s.recheck = true -- looked at again on the next call
        s.puppet = old
        return old
      end
      if handed then
        c = old
      end
    end
    s.claimed = nil
    -- A player joining a new map takes over the bridge's own character's things and place too,
    -- so swapping between the real game and the client (C7) carries on where the client was.
    if not handed and old and c and old ~= c
        and (s.held_for == owner.index or (not s.held_for and s.own_character == old)) then
      takeover.move_all(old, c, c)
      pcall(c.teleport, old.position, old.surface)
      pcall(old.destroy)
    end
    if c then
      s.held_for = nil
      s.own_character = nil
      s.played_for = owner.index
    end
    s.puppet = c -- nil while dead: wait for the respawn
    return s.puppet
  end

  if owner then
    if old and s.held_for == owner.index then
      s.puppet = old
      return old
    end
    -- Their own character, which the bridge played while they were here, left the world with them
    -- (logged off): it isn't the bridge's to empty or remove, and comes back when they do.
    if old and s.played_for == owner.index then
      old = nil
    end
    if M.waiting_to_respawn() then
      return nil
    end
    -- Stand in for the owner where their character was (after a death: at the spawn).
    local surface = owner.physical_surface or game.get_surface(1)
    local at = owner.physical_position or { x = 0, y = 0 }
    surface, at = M.respawn_place(surface, at, owner.force)
    local c = create_character(surface, at, owner.force)
    if not c then
      s.puppet = old
      return old
    end
    takeover.move_all(owner, c, c)
    pcall(function() c.color = owner.color end)
    s.played_for = nil
    if old then
      local before = s.held_for and game.get_player(s.held_for)
      if before and not before.connected then
        takeover.move_all(old, before, old)
      end
      takeover.absorb(old, c)
    end
    s.held_for = owner.index
    s.puppet = c
    return c
  end

  -- No owner: the bridge's own character. Hand anything held for someone back first.
  s.played_for = nil
  if old and s.held_for then
    local before = game.get_player(s.held_for)
    if before and not before.connected then
      takeover.move_all(old, before, old)
    end
    s.held_for = nil
  end
  if old then
    s.puppet = old
    return old
  end
  if not game.is_multiplayer() then
    return nil
  end
  if M.waiting_to_respawn() then
    return nil
  end
  local surface = game.get_surface(settings.global["f3d-surface"].value) or game.get_surface(1)
  local force = game.forces.player
  local at = force.get_spawn_position(surface)
  surface, at = M.respawn_place(surface, at, force)
  local character = create_character(surface, at, force)
  if not character then
    return nil
  end
  if settings.global["f3d-starter-kit"].value then
    for _, stack in pairs(STARTER_KIT) do
      if prototypes.item[stack.name] then
        character.insert(stack)
      end
    end
  end
  s.own_character = character
  s.puppet = character
  return character
end

-- The surface a command works on: while the remote view shows another surface, what may be done
-- from there (ghosts, marks, rotating, settings: session.lua REMOTE_OK) goes to that surface, as
-- in Factorio's remote view; everything else to the character's own.
function M.surface(c)
  local si = storage.f3d.act_si
  local s = si and game.get_surface(si)
  if s and s.valid then
    return s
  end
  return c.surface
end

---------------------------------------------------------------------------------------------
-- Death and respawn
--
-- A player's character respawns by the game's own rules (LuaPlayer::ticks_to_respawn). The
-- bridge's own character (no player, or standing in for one who is away) has nobody to respawn
-- it, so the bridge does: after the character prototype's respawn time, at the force's spawn on
-- the planet it died on (Nauvis when it died on a space platform), as Factorio does for players.

local DEFAULT_RESPAWN_TICKS = 600
local DEAD_INTERVAL = 30

local function respawn_ticks(c)
  local ok, t = pcall(function() return c.prototype.respawn_time end)
  t = ok and tonumber(t) or nil
  if not t or t <= 0 then
    return DEFAULT_RESPAWN_TICKS
  end
  return t < 120 and math.floor(t * 60) or math.floor(t) -- seconds in data, ticks at runtime
end

-- on_entity_died (combat.lua): the character the client plays died.
function M.on_died(e)
  local s = storage.f3d
  if not (s.puppet and s.puppet.valid and s.puppet == e) then
    return
  end
  local surface = e.surface
  local ok, platform = pcall(function() return surface.platform end)
  if ok and platform then
    surface = game.get_surface(1)
  end
  s.mining, s.walk, s.pickup, s.mine_at = nil, nil, nil, nil
  local p = e.position
  s.death = { tick = game.tick, x = p.x, y = p.y, surface = e.surface.index }
  -- A connected player's character is respawned by the game; only the bridge's own waits here.
  if not M.player_of(e) then
    s.respawn = { tick = game.tick + respawn_ticks(e), surface = surface.index }
  end
end

-- True while the bridge's own character is dead and its respawn time hasn't run out.
function M.waiting_to_respawn()
  local r = storage.f3d.respawn
  return r ~= nil and game.tick < r.tick
end

-- Where a character the bridge creates goes: after a death the force's spawn on the planet it
-- died on (clearing the death), otherwise where it was asked to go.
function M.respawn_place(surface, at, force)
  local s = storage.f3d
  local r = s.respawn
  if not r then
    return surface, at
  end
  s.respawn = nil
  s.death = nil
  local there = game.get_surface(r.surface) or surface
  local ok, spawn = pcall(force.get_spawn_position, there)
  return there, ok and spawn or at
end

-- Ticks until the client's character respawns while it is dead, else nil; 0 means waiting for
-- the player to press Respawn (single-player).
function M.respawn_left()
  local s = storage.f3d
  if s.respawn then
    return math.max(0, s.respawn.tick - game.tick)
  end
  local owner = game.is_multiplayer() and M.owner() or game.get_player(1)
  if owner and owner.connected and not owner.character then
    local ok, left = pcall(function() return owner.ticks_to_respawn end)
    local ok2, controller = pcall(function() return owner.controller_type end)
    if ok and left then
      return left
    end
    if ok2 and controller == defines.controllers.ghost then
      return 0
    end
  end
  return nil
end

-- {t = "dead", left (ticks), x, y}: while the character is dead, every half second.
local function send_dead(s)
  local left = M.respawn_left()
  if not left then
    return
  end
  local msg = { t = "dead", left = left }
  if s.death then
    msg.x, msg.y = world.fixed(s.death.x), world.fixed(s.death.y)
  end
  transport.send_now(msg)
end

-- The client's Respawn button: a player waiting on it (single-player) respawns now; the bridge's
-- own character only once its time is up.
function M.respawn()
  local s = storage.f3d
  if s.respawn then
    if game.tick >= s.respawn.tick then
      M.get()
    end
    return
  end
  local owner = game.is_multiplayer() and M.owner() or game.get_player(1)
  if owner and owner.connected and not owner.character then
    local ok, left = pcall(function() return owner.ticks_to_respawn end)
    if not (ok and left and left > 0) then
      pcall(function() owner.ticks_to_respawn = nil end)
    end
  end
end

function M.reset()
  local s = storage.f3d
  s.walk = nil
  s.mining = nil
  s.mine_at = nil
  s.pickup = nil
  s.inv_sig = nil
  s.recipes_sig = nil
  local c = s.puppet
  if c and c.valid then
    c.walking_state = { walking = false, direction = c.direction }
  end
end

-- Finds the entity the client clicked: by unit number when it has one, otherwise by
-- prototype and exact position (the same identity the client uses).
function M.find_target(surface, cmd)
  local fx, fy = tonumber(cmd.x), tonumber(cmd.y)
  if not fx or not fy then
    return nil
  end
  local x, y = fx / 256, fy / 256
  local unit = tonumber(cmd.u) or 0
  local name = registry.entity_name(tonumber(cmd.p) or 0)
  -- With a unit number the match is exact, so search wider: a train or car may have moved on
  -- from where the client saw it.
  local r = unit > 0 and 3 or 0.05
  local found = surface.find_entities_filtered({ area = { { x - r, y - r }, { x + r, y + r } } })
  for _, e in pairs(found) do
    if unit > 0 then
      if e.unit_number == unit then
        return e
      end
    elseif e.name == name and world.fixed(e.position.x) == fx and world.fixed(e.position.y) == fy then
      return e
    end
  end
  return nil
end

---------------------------------------------------------------------------------------------
-- Commands

-- `walk` with `a` (thousandths of a turn clockwise from north) walks at any angle (owner's B7).
-- Factorio's character walks only 8 ways, so each tick steps one of the two 8-way directions either
-- side of the angle, whichever brings the sideways drift accumulated so far (`err`, in steps) back
-- towards the line: the path zig-zags a few hundredths of a tile about the line while the game's own
-- collisions and speed stay as they are. Against a wall a step that went nowhere makes the next
-- tick try the other direction either side of the angle, then the two beside those, so the
-- character slides along it (angle_step).
function M.walk(cmd)
  local s = storage.f3d
  local d = tonumber(cmd.d)
  local a = tonumber(cmd.a)
  -- One of the 16 directions or a stop: a huge d ("1e999" is inf) made walk_direction NaN, which
  -- the tick then wrote into walking_state, outside any pcall.
  if d and d >= 16 then
    d = -1
  end
  if a and a >= 0 and a < 1000 and (not d or d >= 0) then
    local w = s.walk
    local going = w and w.angle and game.tick <= w.until_tick
    s.walk = { dir = w and w.dir or walk_direction(math.floor(a * 16 / 1000 + 0.5)), angle = math.floor(a),
      err = going and w.err or 0, until_tick = game.tick + HOLD_TICKS,
      -- Where the character stood at the last step and what that step was, kept across the
      -- repeated walk commands, so a step a wall stopped is seen (angle_step).
      lx = going and w.lx or nil, ly = going and w.ly or nil,
      last = going and w.last or nil, stuck = going and w.stuck or nil, moved = going and w.moved or nil }
  elseif d and d >= 0 then
    s.walk = { dir = walk_direction(d), until_tick = game.tick + HOLD_TICKS }
  elseif s.walk then
    s.walk.until_tick = 0
  end
end

local function can_hand_mine(c, e)
  if not (e.valid and e.minable) then
    return false, "Can't mine that"
  end
  if e.force ~= c.force and e.force.name ~= "neutral" then
    return false, "Can't mine that"
  end
  local props = e.prototype.mineable_properties
  if not props.minable then
    return false, "Can't mine that"
  end
  if e.type == "resource" then
    if props.required_fluid or e.prototype.infinite_resource then
      return false, "This needs a mining drill"
    end
    for _, product in pairs(props.products or {}) do
      if product.type ~= "item" then
        return false, "This needs a pump or drill"
      end
    end
  end
  local reach = (e.type == "resource") and c.resource_reach_distance or c.reach_distance
  if distance(c.position, e.position) > reach + REACH_SLACK then
    return false, "Out of reach"
  end
  return true
end

-- Ghosts are removed at once by a right click, as in Factorio (I6): no mining time to wait out. So
-- is an item lying on the ground (J18: its mining time is 0.025 s, a tick or two).
local INSTANT_TYPES = { ["entity-ghost"] = true, ["tile-ghost"] = true, ["item-entity"] = true }
local finish_mining -- below

-- The item lying on the ground the client right-clicked (`mine` with `gi`): item-entities have no
-- unit number and no id in the registry, so it goes by where it lies (as `gi` sent it), the one
-- nearest that point within its selection box (0.17 tiles) and a little.
local function item_on_ground(surface, cmd)
  local fx, fy = tonumber(cmd.x), tonumber(cmd.y)
  if not fx or not fy then
    return nil
  end
  local at = { x = fx / 256, y = fy / 256 }
  local best, best_d
  for _, e in pairs(surface.find_entities_filtered({
    area = { { at.x - 0.25, at.y - 0.25 }, { at.x + 0.25, at.y + 0.25 } },
    type = "item-entity",
  })) do
    local d = distance(e.position, at)
    if not best_d or d < best_d then
      best, best_d = e, d
    end
  end
  return best
end

-- J26: a sweep. While the client holds the mining button it says where its cursor is from the
-- character as it draws it (`ox`, `oy`, 1/256 tiles): the camera follows the character, so a still
-- mouse is a fixed offset, and the point walks with the character, as Factorio's selection does.
-- Each tick the target is what is under that point (sweep), as Factorio's mining follows the
-- selected entity, measured in 2.1.24 with a player-less character's own mining (mining_state and
-- update_selected_entity): a new target starts from nothing, no target keeps the progress but mines
-- nothing (and lets the character walk), the same one again goes on from where it was; the
-- character stands while it mines and walks on between, so walking with the button held along a
-- line of belts mines every belt in turn. Vehicles, ghosts and items on the ground are left to the
-- client's own `mine` (it finds them by their unit or place).
local SWEEP_SKIP = {
  ["entity-ghost"] = true, ["tile-ghost"] = true, ["item-entity"] = true, character = true,
  ["character-corpse"] = true, car = true, ["spider-vehicle"] = true, locomotive = true,
  ["cargo-wagon"] = true, ["fluid-wagon"] = true, ["artillery-wagon"] = true,
}
local MAX_OFFSET = 64 -- tiles: further than any reach, a bad packet's

-- Selection priority by prototype name (resources under everything else, as the client picks).
local priorities = {}
local function priority_of(e)
  local p = priorities[e.name]
  if not p then
    local ok, v = pcall(function() return e.prototype.selection_priority end)
    p = (e.type == "resource") and -1 or (ok and v or 50)
    priorities[e.name] = p
  end
  return p
end

local function contains(e, at)
  local b = e.selection_box
  return at.x >= b.left_top.x and at.x <= b.right_bottom.x and at.y >= b.left_top.y and at.y <= b.right_bottom.y
end

-- The point the client's cursor is over now, or nil when it isn't holding the button.
local function sweep_point(c, s)
  local h = s.mine_at
  if not h then
    return nil
  end
  if game.tick > h.until_tick then
    s.mine_at = nil
    return nil
  end
  local p = c.position
  return { x = p.x + h.ox, y = p.y + h.oy }
end

-- What Factorio would select at `at` to mine: the highest selection priority there, then the
-- smallest selection box.
local function entity_at(c, at)
  local best, best_pri, best_area
  for _, e in pairs(c.surface.find_entities_filtered({ area = { { at.x - 0.6, at.y - 0.6 }, { at.x + 0.6, at.y + 0.6 } } })) do
    if not SWEEP_SKIP[e.type] and e.minable and contains(e, at) then
      local pri = priority_of(e)
      local b = e.selection_box
      local area = (b.right_bottom.x - b.left_top.x) * (b.right_bottom.y - b.left_top.y)
      if not best or pri > best_pri or (pri == best_pri and area < best_area) then
        best, best_pri, best_area = e, pri, area
      end
    end
  end
  return best
end

local function start_mining(s, e, until_tick)
  s.mining = {
    entity = e,
    progress = 0,
    time = math.max(e.prototype.mineable_properties.mining_time, 0.01),
    until_tick = until_tick,
  }
end

-- Each tick while the button is held: the target follows the point (see above).
local function sweep(c, s)
  local at = sweep_point(c, s)
  if not at then
    return
  end
  local m = s.mining
  if m and m.entity.valid and (SWEEP_SKIP[m.entity.type] or contains(m.entity, at)) then
    m.paused = nil
    return
  end
  local e = entity_at(c, at)
  if e and not INSTANT_TYPES[e.type] and can_hand_mine(c, e) then
    start_mining(s, e, s.mine_at.until_tick)
  elseif m and m.entity.valid then
    m.paused = true -- off it: Factorio keeps the progress for when the cursor comes back
  else
    s.mining = nil
  end
end

function M.mine(cmd)
  local s = storage.f3d
  local c = M.get()
  if not c then
    return
  end
  local ox, oy = tonumber(cmd.ox), tonumber(cmd.oy)
  local swept = ox and oy and ox == ox and oy == oy and math.abs(ox) <= MAX_OFFSET * 256 and math.abs(oy) <= MAX_OFFSET * 256
  if swept then
    s.mine_at = { ox = ox / 256, oy = oy / 256, until_tick = game.tick + HOLD_TICKS }
  end
  local e
  if cmd.gi == 1 then
    e = item_on_ground(c.surface, cmd)
  elseif cmd.n ~= 1 then
    e = M.find_target(c.surface, cmd)
  end
  local m = s.mining
  if not e then
    -- Nothing under the client's cursor (`n`), or what it saw is gone: in a sweep the point decides,
    -- and what is being mined goes on while the button is held.
    if swept and m and m.entity.valid then
      m.until_tick = game.tick + HOLD_TICKS
    elseif not swept then
      s.mining = nil
    end
    return
  end
  if m and m.entity.valid and m.entity == e then
    m.until_tick = game.tick + HOLD_TICKS
    return
  end
  -- The client's view is a few ticks behind: what it saw may be the belt before the one the point
  -- has reached. The one under the point stays.
  local at = swept and sweep_point(c, s)
  if at and m and m.entity.valid and not SWEEP_SKIP[m.entity.type] and contains(m.entity, at) and not contains(e, at) then
    m.until_tick = game.tick + HOLD_TICKS
    return
  end
  local ok, why = can_hand_mine(c, e)
  if not ok then
    s.mining = nil
    message(why)
    return
  end
  if INSTANT_TYPES[e.type] then
    s.mining = nil
    local done, reason = finish_mining(c, e)
    if not done then
      message(reason)
    end
    return
  end
  start_mining(s, e, game.tick + HOLD_TICKS)
end

function M.mine_stop()
  storage.f3d.mining = nil
  storage.f3d.mine_at = nil
end

-- Like holding F: picks up items on the ground and on belts near the character while the client repeats it
-- (tick_pick_items).
function M.pickup()
  local s = storage.f3d
  if s.pickup then
    s.pickup.until_tick = game.tick + HOLD_TICKS
  else
    s.pickup = { until_tick = game.tick + HOLD_TICKS }
  end
end

-- F let go: the pickup ends now, not HOLD_TICKS after the last `pickup` (clients from before never send it).
function M.pickup_stop()
  if perf.on("pickup_stop") then
    storage.f3d.pickup = nil
  end
end

-- Hand-mining one unit of ore: products go to the inventory, the patch shrinks by one.
local function mine_resource(c, e)
  local products = e.prototype.mineable_properties.products or {}
  for _, product in pairs(products) do
    local stack = { name = product.name, count = product.amount or product.amount_min or 1 }
    if not c.can_insert(stack) then
      return false, "Inventory full"
    end
  end
  for _, product in pairs(products) do
    c.insert({ name = product.name, count = product.amount or product.amount_min or 1 })
  end
  if e.amount > 1 then
    e.amount = e.amount - 1
    tracker.changed(e)
  else
    e.deplete() -- raises on_resource_depleted, which sends the removal
  end
  return true
end

-- What the character holds, by item (qualities summed): the main inventory, guns, ammo and trash, where
-- mined things land.
local HELD_INVENTORIES = { "character_main", "character_guns", "character_ammo", "character_trash" }
local function held(c)
  local out = {}
  for _, name in ipairs(HELD_INVENTORIES) do
    local ok, inv = pcall(function() return c.get_inventory(defines.inventory[name]) end)
    if ok and inv then
      for _, item in pairs(inv.get_contents()) do
        out[item.name] = (out[item.name] or 0) + item.count
      end
    end
  end
  return out
end

-- Mined things a `mnd` lists, at most (the client flies six).
local MINED_MAX = 8

-- Listeners called after the character mined something (inventory.lua sends its slots then).
M.mined_listeners = {}

-- J20: what the character just mined, said at once (`mnd`, unreliable, so not behind the chunk snapshots
-- in the reliable outbox the `del` waits in): where it was, whether it is gone, and the items it gave
-- (what the character holds now less what it held before; its own products first), for the client to
-- take it away and fly the items to the character in the frame it hears. The inventory is sent at once
-- too, not at its next 30-tick report.
local function mined_message(c, info, before)
  local after = held(c)
  local gained = {}
  for name, n in pairs(after) do
    local d = n - (before[name] or 0)
    if d > 0 then
      gained[#gained + 1] = { name, d }
    end
  end
  table.sort(gained, function(a, b)
    local pa, pb = info.products[a[1]] and 1 or 0, info.products[b[1]] and 1 or 0
    if pa ~= pb then
      return pa > pb
    end
    if a[2] ~= b[2] then
      return a[2] > b[2]
    end
    return a[1] < b[1]
  end)
  local l = {}
  for i = 1, math.min(#gained, MINED_MAX) do
    l[i] = gained[i]
  end
  local msg = { t = "mnd", u = info.u, p = info.p, x = info.x, y = info.y, g = info.e.valid and 0 or 1, l = l }
  if info.gi then
    msg.gi = 1
  end
  return msg
end

local function mined_after(c)
  M.send_inventory_now()
  for _, fn in ipairs(M.mined_listeners) do
    fn(c)
  end
end

local function say_mined(c, info, before)
  transport.send_now(mined_message(c, info, before))
  mined_after(c)
end

-- What `mnd` says of the entity, read before it is mined; nil when the switch is off.
local function mined_info(e)
  if not perf.on("mined_now") then
    return nil
  end
  local p = e.position
  local item = e.type == "item-entity"
  local products = {}
  local ok, props = pcall(function() return e.prototype.mineable_properties end)
  for _, product in pairs(ok and props and props.products or {}) do
    products[product.name] = true
  end
  if item then
    local okn, name = pcall(function() return e.stack.name end)
    if okn and name then
      products[name] = true
    end
  end
  return { e = e, u = e.unit_number or 0, p = item and 0 or registry.entity_id(e.name), x = world.fixed(p.x),
    y = world.fixed(p.y), gi = item, products = products }
end

-- `force`: mined even when what it gives doesn't fit, the rest spilled at the character's feet (a build's own
-- removals, M2).
local function finish_mining_now(c, e, force)
  if e.type == "resource" then
    return mine_resource(c, e)
  end
  -- As the player when there is one (as_player.lua): Factorio raises on_player_mined_entity, whose
  -- handler (tracker.lua) sends the removal.
  local mined = as_player.mine(c, e, force)
  if mined ~= nil then
    return mined, (not mined) and "Inventory full" or nil
  end
  local removal = tracker.removal_message(e)
  if perf.on("mined_tell") then
    tracker.removing(e)
  end
  if perf.on("mined_neighbours") then
    tracker.neighbours_change(e)
  end
  local done
  if force then
    done = c.mine_entity(e, true)
  else
    done = c.mine_entity(e)
  end
  if not done then
    return false, "Inventory full"
  end
  if removal and not e.valid then
    transport.send_reliable(removal)
  end
  return true
end

function finish_mining(c, e)
  local info = mined_info(e)
  local before = info and held(c)
  local done, reason = finish_mining_now(c, e)
  if done and info then
    local ok, err = pcall(say_mined, c, info, before)
    if not ok then
      log("[factorio-3d-bridge] mnd: " .. tostring(err))
    end
  end
  return done, reason
end

-- M2: entities a build of the character's takes away as Factorio's player build does (the belts or pipes between a
-- new underground pair, building.lua): each mined into the character with what it holds (a belt's items too),
-- forced, so what doesn't fit is spilled as Factorio spills it; each said at once as hand mining is (`mnd` then the
-- reliable `del`), the inventory once after them. How many went.
function M.mine_for_build(c, list)
  local n = 0
  for _, e in ipairs(list) do
    if e.valid then
      local info = mined_info(e)
      local before = info and held(c)
      if finish_mining_now(c, e, true) then
        n = n + 1
        if info then
          local ok, msg = pcall(mined_message, c, info, before)
          if ok then
            transport.send_now(msg)
          else
            log("[factorio-3d-bridge] mnd: " .. tostring(msg))
          end
        end
      end
    end
  end
  if n > 0 then
    local ok, err = pcall(mined_after, c)
    if not ok then
      log("[factorio-3d-bridge] mnd: " .. tostring(err))
    end
  end
  return n
end

function M.rotate(cmd)
  local c = M.get()
  if not c then
    return
  end
  local e = M.find_target(M.surface(c), cmd)
  if e and e.rotatable and e.force == c.force then
    -- by_player raises on_player_rotated_entity for other mods (as_player.lua).
    e.rotate({ reverse = cmd.rev == 1 or cmd.rev == true, by_player = as_player.by(c) })
    tracker.rotated(e) -- an underground's other end turns with it (J23)
  end
end

function M.craft(cmd)
  local c = M.get()
  if not c then
    return
  end
  local name = tostring(cmd.recipe or "")
  local recipe = c.force.recipes[name]
  if not (recipe and recipe.enabled) then
    return message("Recipe not available: " .. name)
  end
  local count = math.max(1, math.min(100, math.floor(tonumber(cmd.n) or 1)))
  -- The queue grows here, not by crafting: crafting.lua looks at it afresh (see count_crafts).
  storage.f3d.craft_seen = nil
  if c.begin_crafting({ recipe = name, count = count, silent = true }) == 0 then
    message("Missing ingredients for " .. name)
  end
end

---------------------------------------------------------------------------------------------
-- State sent to the client

-- LuaEntity::max_health is new in 2.0 (quality changes it); older builds only have the
-- prototype's.
local function max_health(c)
  local ok, v = pcall(function() return c.max_health end)
  if ok and v then
    return v
  end
  ok, v = pcall(function() return c.prototype.get_max_health() end)
  return ok and v or nil
end

-- The vehicle the character sits in, or nil.
function M.vehicle(c)
  local ok, v = pcall(function() return c.vehicle end)
  return ok and v or nil
end

-- The space platform hub the character sits in, or nil (2.1: LuaControl.hub). A character rides a
-- rocket up into one (space.ride) and stays inside it, as a player does.
function M.hub(c)
  local ok, hub = pcall(function() return c.hub end)
  return ok and hub and hub.valid and hub or nil
end

-- The cargo pod the character rides in, or nil (LuaControl.cargo_pod): up from a silo in its
-- rocket, or between a hub and a planet.
function M.pod(c)
  local ok, pod = pcall(function() return c.cargo_pod end)
  return ok and pod and pod.valid and pod or nil
end

local LEAVING = { awaiting_launch = true, ascending = true, surface_transition = true }

-- me.pod, ps, gx, gy, up: the pod, its state, and the point on the ground the flight is seen from.
-- Factorio draws a pod's height as a shift up the screen, so its position runs north of that point
-- as it climbs: leaving (up = 1), the point is where it set off (the silo or hub); arriving, where
-- it comes down (the hub it docks in, or the spot space.lua / planets.lua chose to land on).
local function pod_fields(c, s, msg)
  local pod = M.pod(c)
  if not pod then
    s.trip = nil  -- arrived
    return
  end
  local ok, state = pcall(function() return pod.cargo_pod_state end)
  state = ok and state or ""
  local ground
  if LEAVING[state] then
    local oko, origin = pcall(function() return pod.cargo_pod_origin end)
    if oko and origin and origin.valid and origin.surface == pod.surface then
      ground = origin.position
    end
    msg.up = 1
  else
    local okd, dest = pcall(function() return pod.cargo_pod_destination end)
    local station = okd and dest and dest.station
    if station and station.valid and station.surface == pod.surface then
      ground = station.position
    elseif s.trip and s.trip.land and s.trip.si == pod.surface.index then
      ground = s.trip.land
    end
    msg.up = 0
  end
  ground = ground or pod.position
  msg.pod = pod.unit_number or 0
  msg.ps = state
  msg.gx = world.fixed(ground.x)
  msg.gy = world.fixed(ground.y)
end

-- More of `me` from modules that need the puppet (repair.lua: `rp`), each f(c, s, msg); set at load.
M.state_extras = {}

-- In a vehicle the position is the vehicle's, which the camera follows.
local function send_state(c, s)
  local v = M.vehicle(c)
  local p = (v or c).position
  local msg = {
    t = "me",
    u = c.unit_number,
    x = world.fixed(p.x),
    y = world.fixed(p.y),
    d = c.direction,
    w = c.walking_state.walking and 1 or 0,
    hp = math.floor(c.health or 0),
    q = c.crafting_queue_size,
    sh = (s.shooting and s.shooting.firing) and 1 or 0,
  }
  -- An angled walk's angle: the client draws the character along it, not along the zig-zag.
  if s.walk and s.walk.angle and msg.w == 1 and not v then
    msg.a = s.walk.angle
  end
  -- Flying in mech armour (Space Age): the client lifts the body and draws take-off, hover and
  -- landing. Read under pcall: a game without these keys (older 2.x) throws on reading them.
  if not v then
    local okf, flying = pcall(function() return c.is_flying end)
    if okf and flying then
      msg.fl = 1
      local okh, height = pcall(function() return c.flight_height end)
      msg.fh = okh and height and math.floor(height * 1000 + 0.5) or 0
    end
  end
  local mhp = max_health(c)
  if mhp then
    msg.mhp = math.floor(mhp)
  end
  -- The armour's shields, over the health bar.
  local ok, grid = pcall(function() return c.grid end)
  if ok and grid and grid.valid and (grid.max_shield or 0) > 0 then
    msg.sd = math.floor(grid.shield + 0.5)
    msg.msd = math.floor(grid.max_shield + 0.5)
  end
  if v then
    msg.v = v.unit_number or 0
    msg.vs = math.floor(v.speed * 1000 + 0.5)
  end
  local hub = M.hub(c)
  if hub then
    msg.hub = hub.unit_number or 0
  end
  pod_fields(c, s, msg)
  if s.mining and s.mining.entity.valid and not s.mining.paused then
    local mp = s.mining.entity.position
    msg.m = math.floor(s.mining.progress / s.mining.time * 100)
    msg.mx = world.fixed(mp.x)
    msg.my = world.fixed(mp.y)
  end
  for _, add in ipairs(M.state_extras) do
    add(c, s, msg)
  end
  transport.send_now(msg)
end

-- An inventory's contents as [[name, count], ...] in the order they first appear, qualities summed.
function M.contents(inventory)
  local totals, order = {}, {}
  for _, item in pairs(inventory.get_contents()) do
    if not totals[item.name] then
      order[#order + 1] = item.name
      totals[item.name] = 0
    end
    totals[item.name] = totals[item.name] + item.count
  end
  local list = {}
  for _, name in pairs(order) do
    list[#list + 1] = { name, totals[name] }
  end
  return list
end

-- The main inventory's contents. Only sent when it changed.
local function send_inventory(c, s)
  local inventory = c.get_main_inventory()
  if not inventory then
    return
  end
  local list, parts = M.contents(inventory), {}
  for _, entry in pairs(list) do
    parts[#parts + 1] = entry[1] .. "=" .. entry[2]
  end
  local sig = table.concat(parts, ",")
  if sig ~= s.inv_sig then
    s.inv_sig = sig
    transport.send_reliable({ t = "inv", l = list })
  end
end

-- 2.1 has LuaRecipe::categories, 2.0 has LuaRecipe::category. Reading a key an object
-- doesn't have is an error, so ask for both safely.
function M.recipe_categories(recipe)
  local ok, cats = pcall(function() return recipe.categories end)
  if ok and cats then
    return cats
  end
  local ok2, cat = pcall(function() return recipe.category end)
  if ok2 and cat then
    return { cat }
  end
  return {}
end

-- character prototype name -> names of the visible recipes in its crafting categories, sorted.
-- Derived only from prototypes (like registry.lua), so a check only reads `enabled` for these
-- instead of every recipe of the force (over a thousand with Space Age).
local hand_recipes = {}

-- Factorio's parameter recipes (parameter-0..9, for blueprint parameters) sit in every crafting
-- category and aren't hidden, but nothing makes them and Factorio's choosers leave them out.
-- 2.1 says so on the prototype (`parameter`); a force's LuaRecipe through its `prototype`. The
-- prototype is read first: asking a LuaRecipe for `parameter` would throw (an error built and
-- caught for every recipe in a chooser), and the pcall only guards a version without the key.
function M.is_parameter(recipe)
  local proto = recipe
  if recipe.object_name == "LuaRecipe" then
    proto = recipe.prototype
  end
  local ok, p = pcall(function() return proto.parameter end)
  return ok and p == true
end

function M.hand_recipe_names(c)
  local proto = c.prototype
  local list = hand_recipes[proto.name]
  if not list then
    local hand = proto.crafting_categories or {}
    list = {}
    for name, recipe in pairs(prototypes.recipe) do
      if not recipe.hidden and not M.is_parameter(recipe) then
        for _, cat in pairs(M.recipe_categories(recipe)) do
          if hand[cat] then
            list[#list + 1] = name
            break
          end
        end
      end
    end
    table.sort(list)
    hand_recipes[proto.name] = list
  end
  return list
end

-- Names of the recipes this character can craft by hand right now.
local function send_recipes(c, s)
  local recipes = c.force.recipes
  local names = {}
  for _, name in ipairs(M.hand_recipe_names(c)) do
    local recipe = recipes[name]
    if recipe and recipe.enabled and not recipe.hidden then
      names[#names + 1] = name
    end
  end
  local sig = table.concat(names, ",")
  if sig ~= s.recipes_sig then
    s.recipes_sig = sig
    transport.send_reliable({ t = "recipes", l = names })
  end
end

---------------------------------------------------------------------------------------------

-- The 8-way direction (an even one of the 16) for this tick of an angled walk; see M.walk.
local function angle_step(w, c)
  local turn = w.angle / 1000 * 8 -- in eighths of a turn
  local lo = math.floor(turn) % 8
  local hi = (lo + 1) % 8
  local rad = w.angle / 1000 * 2 * math.pi
  -- Each candidate's sideways step off the line, as a fraction of a step (right of the line positive).
  local function side(eighth)
    return math.sin(eighth / 8 * 2 * math.pi - rad)
  end
  local slo, shi = side(lo), side(hi)
  local pick, step = lo, slo
  if math.abs(w.err + shi) < math.abs(w.err + slo) then
    pick, step = hi, shi
  end
  -- The drift is counted from the steps chosen, not the ground covered: a step a wall stopped
  -- would count as taken, and the next pick would go the same blocked way again and again. So
  -- when the last step went nowhere the next try goes round: the other direction either side of
  -- the angle, then the two beside those (east and west along a wall across a northward walk),
  -- and the line is measured again from where the character stands, so it doesn't turn back
  -- to the old line once past the wall.
  local p = c.position
  local still = w.lx and math.abs(p.x - w.lx) < 0.001 and math.abs(p.y - w.ly) < 0.001
  if w.lx and not still then
    w.moved = true  -- only once it has walked: a character that hasn't moved yet isn't blocked
  end
  if w.last and w.moved and still then
    w.stuck = (w.stuck or 0) + 1
    local tries = { (w.last == lo) and hi or lo, (hi + 1) % 8, (lo + 7) % 8 }
    pick = tries[(w.stuck - 1) % 3 + 1]
    w.err = 0
    step = 0
  else
    w.stuck = 0
  end
  w.err = w.err + step
  w.lx, w.ly, w.last = p.x, p.y, pick
  return pick * 2
end

-- While the character mines (an entity in reach, the client holding the button) it stands, as
-- Factorio's does (J10): the walk is kept while the client repeats it and goes on once mining
-- stops, or while the cursor is over nothing to mine (J26: a sweep walks to the next belt and
-- stops there). Picking up with F doesn't hold it. The angled walk measures its line afresh after.
local function mining_now(s)
  return s.mining ~= nil and s.mining.entity.valid and not s.mining.paused
end

local function tick_walk(c, s)
  if not s.walk then
    return
  end
  if game.tick <= s.walk.until_tick and mining_now(s) then
    c.walking_state = { walking = false, direction = s.walk.dir }
    s.walk.lx, s.walk.ly, s.walk.last, s.walk.moved = nil, nil, nil, nil
    return
  end
  if game.tick <= s.walk.until_tick then
    if s.walk.angle then
      s.walk.dir = angle_step(s.walk, c)
    end
    c.walking_state = { walking = true, direction = s.walk.dir }
  else
    c.walking_state = { walking = false, direction = s.walk.dir }
    s.walk = nil
  end
end

local function tick_mining(c, s)
  local m = s.mining
  if not m then
    return
  end
  if game.tick > m.until_tick or not m.entity.valid then
    s.mining = nil
    return
  end
  if m.paused then
    return
  end
  local ok, why = can_hand_mine(c, m.entity)
  if not ok then
    s.mining = nil
    message(why)
    return
  end
  local speed = (c.prototype.mining_speed or 0.5)
    * (1 + c.character_mining_speed_modifier + c.force.manual_mining_speed_modifier)
  m.progress = m.progress + speed / 60
  if m.progress >= m.time then
    local done, reason = finish_mining(c, m.entity)
    if not done then
      s.mining = nil
      message(reason)
    elseif m.entity.valid then
      m.progress = 0 -- ore patch: keep mining while the client holds the button
    else
      s.mining = nil
    end
  end
end

---------------------------------------------------------------------------------------------
-- F, "Pick up items" (issue #18). Factorio's control takes the items lying on the ground and those on belts
-- within the character's item_pickup_distance (1 tile for the base character, its bonus added), every item in
-- range each tick (the wiki's history of the character: since 0.5.0 it "picks all items in range ... instead of
-- 1 per tick"). The game does it for a player's picking_state; the bridge does it itself, for its player-less
-- character and in hybrid mode alike, nearest first: an item on the ground by mining its item-entity (as
-- before), an item on a belt by putting its stack in the character and taking it off its lane. What it took
-- is said at once (`pku`): where each was, and on a belt its lane and unique id, so the client takes it off its
-- simulated lane on the game's tick and flies it to the character; the lanes taken from are read in the next
-- belt update too (ui_actions.lua, J21's put_lanes), so the client's lane ends as the game has it.

local PICK_BELTS = { "transport-belt", "underground-belt", "splitter", "lane-splitter", "loader", "loader-1x1",
  "linked-belt" }
local LANE_KEYS = 8 -- belt_sim.lua's lane key: unit number * 8 + line index
local PICKED_MAX = 32 -- records a `pku` lists, at most (PICKS_PER_TICK of them a tick)

-- Listeners called with the belts F took items off this tick (ui_actions.lua reads their lanes again).
M.belt_listeners = {}

-- A line's items as read now: `list` in the game's order, `by` unique id -> {count, line position, name,
-- quality, the DetailedItemOnLine}. (The read's stacks stay good only until the line changes: names are kept.)
local function line_items(line)
  local list, by = {}, {}
  for _, item in pairs(line.get_detailed_contents()) do
    local st = item.stack
    local v = { st.count, item.position, st.name, st.quality.name, item }
    list[#list + 1] = item.unique_id
    by[item.unique_id] = v
  end
  return { list = list, by = by }
end

-- Whether a box (a belt's selection box) comes within r of pos.
local function box_near(b, pos, r)
  local dx = math.max(b.left_top.x - pos.x, 0, pos.x - b.right_bottom.x)
  local dy = math.max(b.left_top.y - pos.y, 0, pos.y - b.right_bottom.y)
  return dx * dx + dy * dy <= r * r
end

-- Everything F could take from where the character stands, nearest first: {d, e} for an item on the ground,
-- {d, ln, uid} for one on a belt (ln: its line, {line, items, belt, key}, read once here).
local function pick_candidates(c, pos, r)
  local out = {}
  local area = { { pos.x - r, pos.y - r }, { pos.x + r, pos.y + r } }
  for _, e in pairs(c.surface.find_entities_filtered({ area = area, type = "item-entity" })) do
    local p = e.position
    local d = distance(pos, p)
    if d <= r then
      out[#out + 1] = { d = d, e = e, x = p.x, y = p.y, key = 0, uid = 0 }
    end
  end
  -- (A tile wider: an area search goes by collision boxes, a little smaller than where a belt's items ride.)
  local belt_area = { { pos.x - r - 1, pos.y - r - 1 }, { pos.x + r + 1, pos.y + r + 1 } }
  for _, belt in pairs(c.surface.find_entities_filtered({ area = belt_area, type = PICK_BELTS })) do
    local unit = belt.unit_number
    local ok, n = pcall(function() return belt.get_max_transport_line_index() end)
    if unit and ok and n and box_near(belt.selection_box, pos, r) then
      -- An underground's lines 3 and 4 run under the ground (an entrance's tunnel), out of reach.
      if belt.type == "underground-belt" then
        n = math.min(n, 2)
      end
      for i = 1, n do
        local line = belt.get_transport_line(i)
        local items = line_items(line)
        local ln
        for _, uid in ipairs(items.list) do
          local at = line.get_line_item_position(items.by[uid][2])
          local d = distance(pos, at)
          if d <= r then
            ln = ln or { line = line, items = items, belt = belt, key = unit * LANE_KEYS + i }
            out[#out + 1] = { d = d, ln = ln, uid = uid, x = at.x, y = at.y, key = ln.key }
          end
        end
      end
    end
  end
  -- (Ties by lane and id, then place: the same order on every peer.)
  table.sort(out, function(a, b)
    if a.d ~= b.d then
      return a.d < b.d
    end
    if a.key ~= b.key then
      return a.key < b.key
    end
    if a.uid ~= b.uid then
      return a.uid < b.uid
    end
    if a.x ~= b.x then
      return a.x < b.x
    end
    return a.y < b.y
  end)
  return out
end

-- One item on a belt into the character: its stack (quality, freshness and all) put in the character, then
-- taken off its lane by that stack's reference, the lane read before and after so what is said is what the
-- game did. Should the reference not take it, the lane gives up that many of the item by name instead; what it
-- doesn't give up comes back out of the character (nothing is made). Returns the records {name, count, uid,
-- left, pos}, or nil when the inventory takes none of it.
local function take_from_belt(c, ln, uid)
  local before = ln.items
  local was = before.by[uid]
  if not was then
    return {} -- taken this tick already
  end
  local count, name, quality = was[1], was[3], was[4]
  if not c.can_insert({ name = name, quality = quality, count = 1 }) then
    return nil
  end
  local stack = was[5].stack
  local got = c.insert(stack)
  if got <= 0 then
    return nil
  end
  pcall(function()
    if got < count then
      stack.count = count - got
    else
      stack.clear()
    end
  end)
  local after = line_items(ln.line)
  local function removed()
    local n = 0
    for _, id in ipairs(before.list) do
      local now = after.by[id] and after.by[id][1] or 0
      n = n + math.max(before.by[id][1] - now, 0)
    end
    return n
  end
  local n = removed()
  if n == 0 then
    pcall(ln.line.remove_item, { name = name, quality = quality, count = got })
    after = line_items(ln.line)
    n = removed()
  end
  if n < got then
    c.remove_item({ name = name, quality = quality, count = got - n })
  end
  local out = {}
  for _, id in ipairs(before.list) do
    local v = before.by[id]
    local now = after.by[id] and after.by[id][1] or 0
    if now < v[1] then
      out[#out + 1] = { name = v[3], count = v[1] - now, uid = id, left = now, pos = v[2] }
    end
  end
  ln.items = after
  return out
end

-- The inventory and slots now (at most every PICK_REPORT_TICKS; else when that is up).
local function report_picks(c, p, now)
  if not now and p.reported and game.tick - p.reported < PICK_REPORT_TICKS then
    p.unreported = true
    return
  end
  p.reported = game.tick
  p.unreported = nil
  M.send_inventory_now()
  for _, fn in ipairs(M.mined_listeners) do
    fn(c)
  end
end

-- {t = "pku", k, l = [[item, count, x, y, lane key, unique id, left, item id], ...]}: what F took this tick.
local function say_picked(c, p, picked, belts)
  local l = {}
  for i = 1, math.min(#picked, PICKED_MAX) do
    local r = picked[i]
    l[i] = { r.name, r.count, world.fixed(r.x), world.fixed(r.y), r.key, r.uid, r.left, registry.item_id(r.name) or 0 }
  end
  transport.send_now({ t = "pku", k = game.tick, l = l })
  if #belts > 0 then
    for _, fn in ipairs(M.belt_listeners) do
      fn(belts)
    end
  end
  report_picks(c, p, false)
end

local function tick_pick_items(c, p)
  if p.unreported and game.tick - (p.reported or 0) >= PICK_REPORT_TICKS then
    report_picks(c, p, true)
  end
  if p.full then
    return
  end
  local pos = c.position
  local r = c.item_pickup_distance + PICKUP_SLACK
  local picked, belts, seen = {}, {}, {}
  local taken = 0
  for _, cand in ipairs(pick_candidates(c, pos, r)) do
    if taken >= PICKS_PER_TICK then
      break
    end
    if cand.e then
      local e = cand.e
      if e.valid then
        local name, count = e.stack.name, e.stack.count
        local ok = c.mine_entity(e)
        local left = e.valid and e.stack.count or 0
        if count - left > 0 then
          picked[#picked + 1] = { name = name, count = count - left, x = cand.x, y = cand.y, key = 0, uid = 0, left = left }
          taken = taken + 1
        end
        if not ok then
          p.full = true
          break
        end
      end
    else
      local got = take_from_belt(c, cand.ln, cand.uid)
      if not got then
        p.full = true
        break
      end
      for _, g in ipairs(got) do
        -- (Where the game had it this tick: the candidate's place, or for one the name took instead, its own.)
        local at = g.uid == cand.uid and cand or cand.ln.line.get_line_item_position(g.pos)
        picked[#picked + 1] = { name = g.name, count = g.count, x = at.x, y = at.y, key = cand.key, uid = g.uid,
          left = g.left }
      end
      if #got > 0 then
        taken = taken + 1
        local belt = cand.ln.belt
        if not seen[belt.unit_number] then
          seen[belt.unit_number] = true
          belts[#belts + 1] = belt
        end
      end
    end
  end
  if #picked > 0 then
    say_picked(c, p, picked, belts)
  end
  if p.full then
    message("Inventory full")
  end
end

-- Mining an item-entity puts its stack in the inventory, and mine_entity works without a
-- player, so that is how a player-less character picks up. Once the inventory is full it stops
-- trying (and says so once) until the client lets go. With belt_pickup off: the ground only, two a
-- tick, nothing said but the next `gi`, as before.
local function tick_pickup(c, s)
  local p = s.pickup
  if not p then
    return
  end
  if game.tick > p.until_tick then
    s.pickup = nil
    return
  end
  if perf.on("belt_pickup") then
    return tick_pick_items(c, p)
  end
  if p.full then
    return
  end
  local pos = c.position
  local r = c.item_pickup_distance + PICKUP_SLACK
  local found = c.surface.find_entities_filtered({
    area = { { pos.x - r, pos.y - r }, { pos.x + r, pos.y + r } },
    type = "item-entity",
  })
  local picked = 0
  for _, e in pairs(found) do
    if picked >= PICKUPS_PER_TICK then
      return
    end
    if distance(pos, e.position) <= r then
      if not c.mine_entity(e) then
        p.full = true
        message("Inventory full")
        return
      end
      picked = picked + 1
    end
  end
end

function M.tick()
  local s = storage.f3d
  local c = M.get()
  if not c then
    if game.tick % DEAD_INTERVAL == 0 then
      send_dead(s)
    end
    return
  end
  s.death = nil
  -- The sweep first, so the tick its point reaches something to mine the character stands (J26).
  sweep(c, s)
  tick_walk(c, s)
  tick_mining(c, s)
  tick_pickup(c, s)
  if game.tick % STATE_INTERVAL == 0 then
    send_state(c, s)
  end
  if game.tick % INVENTORY_INTERVAL == 0 then
    send_inventory(c, s)
  end
  if game.tick % RECIPES_INTERVAL == 0 then
    send_recipes(c, s)
  end
end

-- Reports the inventory now if it changed (after the client moved items in or out of a machine).
function M.send_inventory_now()
  local c = M.get()
  if c then
    send_inventory(c, storage.f3d)
  end
end

-- Whether the character can reach an entity to open it or move items in and out: the game's own
-- check (LuaControl::can_reach_entity, measured to the entity's edge) when it answers, otherwise
-- the same centre distance as mining.
function M.can_reach(c, e)
  local ok, reach = pcall(function() return c.can_reach_entity(e) end)
  if ok and type(reach) == "boolean" then
    return reach
  end
  return distance(c.position, e.position) <= c.reach_distance + REACH_SLACK
end

-- Force a full inventory and recipe report on the next tick they're due.
function M.invalidate()
  local s = storage.f3d
  s.inv_sig = nil
  s.recipes_sig = nil
end

-- A player joining or leaving may hand the character over (see M.get).
function M.register()
  local function again()
    M.recheck(false)
  end
  -- Who was just created (freeplay gave them its starting kit), for M.claim.
  script.on_event(defines.events.on_player_created, function(event)
    storage.f3d.made_player = { index = event.player_index, tick = game.tick }
  end)
  script.on_event(defines.events.on_player_joined_game, function(event)
    M.recheck(false)
    M.claim(event.player_index)
  end)
  script.on_event(defines.events.on_player_left_game, again)
  script.on_event(defines.events.on_player_respawned, again)
  script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
    if event.setting == "f3d-player" then
      storage.f3d.owner_pick = nil
      M.recheck(true)
    end
  end)
end

-- /f3d-player [name | index | none]: lists the players, or picks whose character to play.
function M.player_command(cmd)
  local s = storage.f3d
  local arg = cmd.parameter and cmd.parameter:match("^%s*(.-)%s*$") or ""
  if arg == "none" then
    s.owner_pick = 0
    M.recheck(true)
  elseif arg ~= "" then
    local p = game.get_player(tonumber(arg) or arg)
    if not p then
      return { "[Zenith] no player " .. arg }
    end
    s.owner_pick = p.index
    M.recheck(true)
  end
  if arg ~= "" then
    M.get()
  end
  return takeover.describe(s)
end

function M.send_initial()
  local c = M.get()
  if c then
    local s = storage.f3d
    if s.own_character == c then
      takeover.no_crash_site() -- the bridge plays this world before anyone joined it (L13)
    end
    M.invalidate()
    send_inventory(c, s)
    send_recipes(c, s)
  end
end

return M
