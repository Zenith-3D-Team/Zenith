-- Taking over a save's own character on a headless server.
--
-- When a player disconnects, Factorio "logs off" their character: it leaves the world
-- (LuaPlayer::character is nil, get_associated_characters is empty), so nothing can walk or mine
-- with it. Its inventories, logistic requests, crafting queue and quickbar stay with the
-- LuaPlayer, which is a LuaControl and can still be read and written (checked in 2.1.23 on the
-- owner's save). So the bridge stands in for that player: its own character appears where the
-- player's was and the player's things move onto it. When the player connects again (with the
-- real game) everything moves back onto their character, and the bridge controls that one, as in
-- single-player.
--
-- Everything here runs from on_tick or from commands and events, and only touches storage, so
-- it stays deterministic in multiplayer.
--
-- A world Zenith made has no player of its own: the bridge plays its own character there. The player
-- who later joins with the client's own Factorio (Ctrl+F9) takes that character over (puppet.lua claim,
-- L13), and from then on is that world's player here, handed back and forth as a save's player is.

local perf = require("scripts.perf")

local M = {}

-- The armour last: see move_all.
local INVENTORIES = { "character_guns", "character_ammo", "character_trash", "character_main", "character_armor" }

-- Per-character bonuses a script may have set on the player's character (LuaControl).
local BONUSES = {
  "character_inventory_slots_bonus", "character_trash_slot_count_bonus", "character_crafting_speed_modifier",
  "character_mining_speed_modifier", "character_running_speed_modifier", "character_build_distance_bonus",
  "character_item_drop_distance_bonus", "character_reach_distance_bonus", "character_resource_reach_distance_bonus",
  "character_item_pickup_distance_bonus", "character_loot_pickup_distance_bonus",
  "character_maximum_following_robot_count_bonus", "character_health_bonus",
}

local function get(obj, key)
  local ok, v = pcall(function() return obj[key] end)
  if ok then
    return v
  end
  return nil
end

local function inventory(control, name)
  local id = defines.inventory[name]
  if not id then
    return nil
  end
  local ok, inv = pcall(control.get_inventory, id)
  return ok and inv or nil
end

-- Where things that don't fit go: on the ground at `at` (an entity), so nothing is lost.
local function spill(stack, at)
  if at and at.valid then
    pcall(function()
      at.surface.spill_item_stack({ position = at.position, stack = stack, enable_looted = true, allow_belts = false })
    end)
  end
end

-- Inserts a stack into `to` (its main inventory, or guns and ammo where they go) and spills
-- the rest at `ground`, then empties it.
local function give(stack, to, ground)
  local ok, n = pcall(to.insert, stack)
  n = ok and n or 0
  if n < stack.count then
    stack.count = stack.count - n
    spill(stack, ground)
  end
  stack.clear()
end

-- Moves one inventory's stacks slot for slot (swap_stack keeps armour grids, blueprints and
-- spoilage), then its slot filters. What doesn't fit goes into `to`'s main inventory or on the
-- ground at `ground`.
local function move_inventory(a, b, to, ground)
  local moved = 0
  for i = 1, #a do
    local ok = pcall(function()
      local stack = a[i]
      if stack.valid_for_read then
        local done = false
        if i <= #b and not b[i].valid_for_read then
          done = stack.swap_stack(b[i])
        end
        if not done then
          give(stack, to, ground)
        end
        moved = moved + 1
      end
    end)
    if not ok then
      log("[factorio-3d-bridge] couldn't move slot " .. i)
    end
  end
  local ok, filters = pcall(function() return a.supports_filters() end)
  if ok and filters then
    for i = 1, math.min(#a, #b) do
      -- The whole ItemFilter: a name alone would mean normal quality only (2.1), so a slot kept for
      -- a rare item, or for any quality, would change each time the things move.
      local okf, f = pcall(a.get_filter, i)
      if okf and f then
        local okb, set = pcall(b.set_filter, i, f)
        if okb and set ~= false then
          pcall(a.set_filter, i, nil)
        end
      end
    end
  end
  return moved
end

-- Copies logistic requests: every section (groups by name, so they stay linked to the group),
-- whether requests are on, and auto-trash.
function M.copy_requests(from, to)
  local oka, a = pcall(function() return from.get_requester_point() end)
  local okb, b = pcall(function() return to.get_requester_point() end)
  if not (oka and a and okb and b) then
    return false
  end
  pcall(function()
    for i = b.sections_count, 1, -1 do
      b.remove_section(i)
    end
  end)
  for _, sec in pairs(a.sections or {}) do
    pcall(function()
      local group = sec.group
      local new
      if group and group ~= "" then
        new = b.add_section(group)
      else
        new = b.add_section()
        new.filters = sec.filters
      end
      if new then
        new.active = sec.active
        new.multiplier = sec.multiplier
      end
    end)
  end
  pcall(function() b.enabled = a.enabled end)
  pcall(function() b.trash_not_requested = a.trash_not_requested end)
  return true
end

-- Cancels `from`'s crafting queue (refunding its ingredients) and returns what was queued, to
-- start again on the other character once the ingredients moved too.
local function take_queue(from)
  local queue = get(from, "crafting_queue")
  if not queue then
    return {}
  end
  local out = {}
  for _, item in ipairs(queue) do
    if not item.prerequisite then
      out[#out + 1] = { recipe = item.recipe, count = item.count }
    end
  end
  for _ = 1, 200 do
    local q = get(from, "crafting_queue")
    if not q or #q == 0 then
      break
    end
    local last = q[#q]
    if not pcall(from.cancel_crafting, { index = last.index, count = last.count }) then
      return {} -- left with the player; nothing is lost
    end
  end
  return out
end

local function restart_queue(to, queue)
  for _, item in ipairs(queue) do
    pcall(to.begin_crafting, { recipe = item.recipe, count = item.count, silent = true })
  end
end

-- Moves everything a character carries from one LuaControl to another: a player (connected or
-- not) or a character entity. `ground` is where overflow is spilled. Returns the number of
-- stacks moved.
function M.move_all(from, to, ground)
  for _, key in ipairs(BONUSES) do
    local v = get(from, key)
    if v ~= nil then
      pcall(function() to[key] = v end)
    end
  end
  local queue = take_queue(from)
  -- Armour adds main inventory slots, and taking it off a character whose extra slots are in use
  -- would lose their place. So `to` gets as many main slots as `from` for the move, the main
  -- inventory moves before the armour, and the bonus goes back afterwards (by then the extra
  -- slots past the armour's are empty).
  local bonus = get(to, "character_inventory_slots_bonus")
  local am, bm = inventory(from, "character_main"), inventory(to, "character_main")
  if bonus and am and bm and #am > #bm then
    pcall(function() to.character_inventory_slots_bonus = bonus + #am - #bm end)
  end
  local moved = 0
  for _, name in ipairs(INVENTORIES) do
    local a, b = inventory(from, name), inventory(to, name)
    if a and b then
      moved = moved + move_inventory(a, b, to, ground)
    end
  end
  if bonus then
    pcall(function() to.character_inventory_slots_bonus = bonus end)
  end
  M.copy_requests(from, to)
  restart_queue(to, queue)
  return moved
end

-- Puts whatever an unrelated character carries (an earlier bridge character in this save) into
-- `to`, then removes it.
function M.absorb(old, to)
  for _, name in ipairs(INVENTORIES) do
    local a = inventory(old, name)
    if a then
      for i = 1, #a do
        pcall(function()
          local stack = a[i]
          if stack.valid_for_read then
            give(stack, to, to)
          end
        end)
      end
    end
  end
  pcall(old.destroy)
end

---------------------------------------------------------------------------------------------
-- Whose character

-- Which player the bridge plays as: in single-player the player; on a server the f3d-player
-- setting or /f3d-player when set, otherwise the player who was online last among those with a
-- character (in a save played alone, that is its owner). nil on a new map nobody joined.
function M.choose(s)
  if not game.is_multiplayer() then
    return game.get_player(1)
  end
  if s.owner_pick == 0 then
    return nil
  end
  if s.owner_pick then
    return game.get_player(s.owner_pick)
  end
  local wanted = settings.global["f3d-player"] and settings.global["f3d-player"].value or ""
  if wanted ~= "" then
    local p = game.get_player(wanted)
    if p then
      return p
    end
  end
  -- The player who joined with the client's own Factorio and took its character over (L13).
  if s.zenith_owner then
    local p = game.get_player(s.zenith_owner)
    if p then
      return p
    end
  end
  local best, best_seen
  for _, p in pairs(game.players) do
    local controller = get(p, "controller_type")
    local seen = p.connected and game.tick or (get(p, "last_online") or 0)
    if controller == defines.controllers.character and (not best or seen > best_seen) then
      best, best_seen = p, seen
    end
  end
  return best
end

-- A line per player for /f3d-player.
function M.describe(s)
  local lines = {}
  for _, p in pairs(game.players) do
    local mark = (s.owner_index == p.index) and " (playing as)" or ""
    if s.zenith_owner == p.index then
      mark = mark .. " (joined with Zenith's Factorio)"
    end
    lines[#lines + 1] = string.format("[Zenith] %d %s, %s%s", p.index, p.name,
      p.connected and "connected" or "not connected", mark)
  end
  if #lines == 0 then
    lines[1] = "[Zenith] no players in this game: the bridge plays its own character"
  end
  return lines
end

---------------------------------------------------------------------------------------------
-- Joining a world Zenith made (L13)

-- Freeplay (base/script/freeplay/freeplay.lua) makes its crash site, the crashed ship with its fires
-- and the intro's cutscene, when its first player is created. On a map a headless server made for
-- Zenith that is the first time anyone joins from Factorio, long after the base round the spawn was
-- built: the ship landed in it and set it burning. So on a server where the bridge plays its own
-- character before any player was created, freeplay is told not to, through its own remote interface
-- (as mods do from on_init): nothing on the map changes, only what would have happened. A map whose
-- intro already ran (a player was created) is left alone, and single-player creates its player before
-- a client can connect, so it keeps its intro. True when freeplay was told.
function M.no_crash_site()
  if not (game.is_multiplayer() and perf.on("no_crash_site")) then
    return false
  end
  local fp = remote.interfaces["freeplay"]
  if not (fp and fp.set_disable_crashsite) then
    return false -- not freeplay (another scenario), or one without the switch
  end
  if fp.get_init_ran then
    local ok, ran = pcall(remote.call, "freeplay", "get_init_ran")
    if not ok or ran then
      return false
    end
  else
    for _ in pairs(game.players) do
      return false
    end
  end
  if fp.get_disable_crashsite then
    local ok, off = pcall(remote.call, "freeplay", "get_disable_crashsite")
    if ok and off then
      return false
    end
  end
  local ok = pcall(remote.call, "freeplay", "set_disable_crashsite", true)
  if ok then
    log("[Zenith] the bridge plays this server's world before anyone joined: freeplay's crash site is off")
  end
  return ok
end

-- What freeplay gave a new player (its created items), taken off the character it gave them to: a
-- player taking over the client's character isn't new to the world, and it had its kit already.
function M.drop_created_items(c)
  local fp = remote.interfaces["freeplay"]
  if not (fp and fp.get_created_items) then
    return
  end
  local ok, items = pcall(remote.call, "freeplay", "get_created_items")
  if not (ok and type(items) == "table") then
    return
  end
  for name, count in pairs(items) do
    if type(name) == "string" and tonumber(count) then
      pcall(c.remove_item, { name = name, count = tonumber(count) })
    end
  end
end

-- The quickbar the bridge kept for its own character (inventory.lua, storage) onto the player taking
-- that character over: its items into the player's slots where those are empty.
function M.copy_quickbar(qb, player)
  if not (qb and qb.items) then
    return
  end
  for i, name in pairs(qb.items) do
    if type(i) == "number" and type(name) == "string" and name ~= "" and prototypes.item[name] then
      local page, slot = math.ceil(i / 10), (i - 1) % 10 + 1
      local ok, now = pcall(player.get_quick_bar_slot, page, slot)
      if ok and not now then
        pcall(player.set_quick_bar_slot, page, slot, name)
      end
    end
  end
  if qb.page then
    pcall(player.set_active_quick_bar_page, 1, qb.page)
  end
end

return M
