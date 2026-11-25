-- Characters' corpses (`character-corpse`): what a dead character's things lie in, as Factorio has them.
--
-- The client sees them as entities (chunk snapshots, `add` as one appears, `del` when it goes), so it
-- draws, selects and mines them; mining one (or emptying it) takes the things back, and Factorio removes
-- an emptied corpse itself. They are no static type (registry.lua leaves them out with the effects), so
-- they are looked up on their own, like remnants, and each one sent is registered for on_object_destroyed:
-- mined, emptied or expired, its going sends `del` and takes its map marker away.
--
-- The map marker: Factorio marks where a player died; the bridge's own character has no player, so nothing
-- did (the owner's "I need to be able to see my corpse"). A corpse with no chart tag on it gets one (the
-- skull signal), removed with the corpse.
--
-- Map setting f3d-character-corpses (on): off is the old behaviour (corpses not sent, no markers).
-- storage.f3d_corpses (shared by every client, not storage.f3d): {reg = {[registration number] = {si, x,
-- y (1/256 tiles), p (prototype id), tag (LuaCustomChartTag or nil)}}, scanned}. It changes only in
-- events and on_tick, from what the game has.

local registry = require("scripts.registry")
local transport = require("scripts.transport")

local M = {}

M.TYPE = "character-corpse"
local MARK_ICON = { type = "virtual", name = "signal-skull" }

-- world.lua requires this module, so it hands itself over (M.bind) rather than being required back.
local world_module
local function world()
  return world_module
end

function M.bind(world)
  world_module = world
end

function M.on()
  local ok, v = pcall(function() return settings.global["f3d-character-corpses"].value end)
  return not ok or v ~= false
end

local function state()
  local s = storage.f3d_corpses
  if not s then
    s = { reg = {} }
    storage.f3d_corpses = s
  end
  return s
end

-- Whose map the marker goes on: a corpse is the neutral force's (2.1.24), so its player's force, else
-- the player force (on_post_entity_died's `force` is the killer's).
local function force_of(c)
  local ok, index = pcall(function() return c.character_corpse_player_index end)
  local player = ok and index and game.get_player(index)
  if player then
    return player.force
  end
  if c.force.name ~= "neutral" then
    return c.force
  end
  return game.forces.player
end

-- A chart tag on the corpse, unless one is there already (Factorio's own for a player's death).
local function mark(c)
  local p = c.position
  local area = { { p.x - 1, p.y - 1 }, { p.x + 1, p.y + 1 } }
  local force = force_of(c)
  local ok, tags = pcall(force.find_chart_tags, c.surface, area)
  if ok and tags and #tags > 0 then
    return nil
  end
  local spec = { position = { x = p.x, y = p.y }, text = "" }
  if prototypes.virtual_signal[MARK_ICON.name] then
    spec.icon = MARK_ICON
  end
  local ok2, tag = pcall(force.add_chart_tag, c.surface, spec)
  return ok2 and tag or nil
end

-- Registers a corpse (once) and marks it on the map. True when it was new.
function M.track(c)
  if not (c and c.valid and c.type == M.TYPE) then
    return false
  end
  local s = state()
  local reg = script.register_on_object_destroyed(c)
  if s.reg[reg] then
    return false
  end
  local p = c.position
  local W = world()
  s.reg[reg] = { si = c.surface.index, x = W.fixed(p.x), y = W.fixed(p.y), p = registry.entity_id(c.name), tag = mark(c) }
  return true
end

-- Those in an area of a surface (a chunk snapshot's strip), registered as they are sent.
function M.in_area(surface, area)
  if not M.on() then
    return {}
  end
  local found = surface.find_entities_filtered({ area = area, type = M.TYPE })
  for _, c in pairs(found) do
    M.track(c)
  end
  return found
end

-- on_post_entity_died (tracker.lua's handler): a character died; its corpse is sent as it appears.
function M.on_post_entity_died(event)
  if not M.on() then
    return
  end
  local ok, t = pcall(function() return event.prototype.type end)
  if not (ok and t == "character") then
    return
  end
  local surface = game.get_surface(event.surface_index)
  if not (surface and event.position) then
    return
  end
  local W = world()
  local found = surface.find_entities_filtered({ position = event.position, radius = 2, type = M.TYPE })
  for _, c in pairs(found) do
    if M.track(c) then
      W.bump(surface.index, c.position)
      if W.is_subscribed(surface, c.position) then
        local p = c.position
        transport.send_reliable_priority({ t = "add", e = W.record(c) }, math.floor(p.x / 32), math.floor(p.y / 32))
      end
    end
  end
end

-- Every corpse on the map, once a save is loaded with this (the owner's from before), so each has its
-- marker even far from the client's view.
function M.tick()
  if not M.on() then
    return
  end
  local s = state()
  if s.scanned then
    return
  end
  s.scanned = true
  for _, surface in pairs(game.surfaces) do
    for _, c in pairs(surface.find_entities_filtered({ type = M.TYPE })) do
      M.track(c)
    end
  end
end

-- control.lua's on_object_destroyed handler: a corpse sent went (mined, emptied, expired).
function M.on_object_destroyed(event)
  local s = storage.f3d_corpses
  local rec = s and s.reg[event.registration_number]
  if not rec then
    return
  end
  s.reg[event.registration_number] = nil
  if rec.tag and rec.tag.valid then
    rec.tag.destroy()
  end
  local surface = game.get_surface(rec.si)
  if not surface then
    return
  end
  local W = world()
  local at = { x = rec.x / 256, y = rec.y / 256 }
  W.bump(surface.index, at)
  if storage.f3d and W.is_subscribed(surface, at) then
    transport.send_reliable_priority({ t = "del", u = 0, p = rec.p, x = rec.x, y = rec.y },
      math.floor(rec.x / 8192), math.floor(rec.y / 8192))
  end
end

return M
