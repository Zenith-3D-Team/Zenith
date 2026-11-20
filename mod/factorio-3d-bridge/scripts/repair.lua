-- Repair packs (K13): with a repair tool in the hand, the left button held on a damaged building of
-- the character's force within reach repairs it, as Factorio does for a player. The client repeats
-- `repair` while the button is held on it (a command lasts HOLD_TICKS) and sends one without a
-- target when it lets go or the mouse leaves.
--
-- Factorio does the repairing for a player through LuaControl.repair_state, with the pack in the
-- player's cursor: the bridge's character has no player (and in hybrid mode the hand is Zenith's, not
-- the game's cursor), so the bridge repairs itself, from on_tick, as Factorio's numbers have it: a
-- tool's `speed` health for each unit of durability it uses (RepairToolPrototype), times the target
-- prototype's repair_speed_modifier (stone walls 2), one unit a tick (a normal pack's 300 last 5 s and
-- repair 600 health; quality packs last longer, not faster). The rate a tick is the one figure not
-- read from the game: `tools/live_check.py --only repair` prints whether repair_state works for a
-- player-less character and what it repairs a tick. All state in storage (s.repair).

local puppet = require("scripts.puppet")
local world = require("scripts.world")

local M = {}

local HOLD_TICKS = 30
-- Durability a tool uses a tick while it repairs.
local DURABILITY_PER_TICK = 1
-- What a repair pack never mends: characters heal on their own (Factorio's not-repairable flag
-- covers enemies and the rest).
local NEVER = { character = true, ["entity-ghost"] = true, ["tile-ghost"] = true, ["item-entity"] = true }

local function repair_tool(name)
  local item = type(name) == "string" and prototypes.item[name]
  if not (item and item.type == "repair-tool") then
    return nil
  end
  local ok, speed = pcall(function() return item.speed end)
  return item, ok and tonumber(speed) or 0
end

-- The top pack's full durability at its quality.
local function full_durability(stack)
  local ok, d = pcall(function() return stack.prototype.get_durability(stack.quality) end)
  if ok and tonumber(d) then
    return tonumber(d)
  end
  ok, d = pcall(function() return stack.prototype.durability end)
  return ok and tonumber(d) or 1
end

-- Health and max health, or nil for something without health.
local function health_of(e)
  local ok, h = pcall(function() return e.health end)
  if not (ok and tonumber(h)) then
    return nil
  end
  local okm, m = pcall(function() return e.max_health end)
  if not (okm and tonumber(m)) then
    okm, m = pcall(function() return e.prototype.get_max_health(e.quality) end)
  end
  if not (okm and tonumber(m)) then
    return nil
  end
  return tonumber(h), tonumber(m)
end

-- Whether the character may repair `e` at all (not whether it needs it).
local function repairable(c, e)
  if NEVER[e.type] or not e.unit_number then
    return false
  end
  local okf, no = pcall(function()
    local flags = e.prototype.flags
    return flags and flags["not-repairable"]
  end)
  if okf and no then
    return false
  end
  local okr, own = pcall(function() return e.force == c.force or c.force.get_friend(e.force) end)
  return okr and own and true or false
end

-- The stack of the tool the client holds: its held slot (`hs`) when that has it, else the first of
-- the item at that quality in the main inventory. nil when none is left.
local function tool_stack(c, r)
  local main = c.get_main_inventory()
  if not main then
    return nil
  end
  local function fits(stack)
    if not (stack and stack.valid_for_read and stack.name == r.item) then
      return false
    end
    local ok, q = pcall(function() return stack.quality.name end)
    return (ok and q or "normal") == r.quality
  end
  local held = puppet.held_stack(main, r.slot, r.item, r.quality)
  if held then
    return held
  end
  local ok, stack, index = pcall(main.find_item_stack, { name = r.item, quality = r.quality })
  if ok and stack and fits(stack) then
    r.slot = index
    return stack
  end
  return nil
end

-- Uses `use` durability from the stack: the top pack's, the next pack taking the rest when it runs
-- out. Returns what was used (less on the last pack).
local function drain(stack, use)
  local full = full_durability(stack)
  local ok, left = pcall(function() return stack.durability end)
  left = ok and tonumber(left) or full
  local have = left + (stack.count - 1) * full
  use = math.min(use, have)
  if use < left then
    stack.durability = left - use
  elseif stack.count > 1 then
    stack.count = stack.count - 1
    stack.durability = full - (use - left)
  else
    stack.clear()
  end
  return use
end

---------------------------------------------------------------------------------------------
-- Commands

-- `repair` {u, p, x, y, item, q?, hs?}: repair that entity with the item while the client repeats
-- it; without `u`, `x` and `y` it stops at once.
function M.cmd(cmd)
  local s = storage.f3d
  local c = puppet.get()
  if not c or cmd.x == nil or cmd.y == nil then
    s.repair = nil
    return
  end
  local item, speed = repair_tool(cmd.item)
  if not item or not (speed > 0) then
    s.repair = nil
    return
  end
  local e = puppet.find_target(c.surface, cmd)
  if not (e and e.valid and repairable(c, e)) then
    s.repair = nil
    return
  end
  local r = s.repair
  if r and r.entity.valid and r.entity == e and r.item == item.name then
    r.until_tick = game.tick + HOLD_TICKS
    return
  end
  if not puppet.can_reach(c, e) then
    s.repair = nil
    return puppet.message("Out of reach")
  end
  local okm, modifier = pcall(function() return e.prototype.repair_speed_modifier end)
  modifier = okm and tonumber(modifier) or 1
  local quality = type(cmd.q) == "string" and prototypes.quality[cmd.q] and cmd.q or "normal"
  local slot = math.floor(tonumber(cmd.hs) or 0)
  s.repair = {
    entity = e, item = item.name, quality = quality, slot = slot > 0 and slot or nil,
    per = speed * (modifier > 0 and modifier or 1), until_tick = game.tick + HOLD_TICKS,
  }
end

---------------------------------------------------------------------------------------------
-- Each tick

function M.tick()
  local s = storage.f3d
  local r = s.repair
  if not r then
    return
  end
  local c = puppet.get()
  if not c or game.tick > r.until_tick or not r.entity.valid then
    s.repair = nil
    return
  end
  local e = r.entity
  local health, max = health_of(e)
  if not health or health >= max then
    return -- mended: the button may stay down on it, nothing more happens
  end
  if not puppet.can_reach(c, e) then
    s.repair = nil
    return
  end
  local stack = tool_stack(c, r)
  if not stack then
    s.repair = nil
    return
  end
  local used = drain(stack, math.min(DURABILITY_PER_TICK, (max - health) / r.per))
  e.health = math.min(max, health + used * r.per)
  r.at = game.tick
  -- Its health bar rises with it (combat.lua's `hp`), also for one damaged before the bridge saw it.
  if s.damaged then
    s.damaged[e.unit_number] = e
  end
end

-- `me` while the character repairs: `rp` 1 and the target's place, for the swing and the repair
-- sound (puppet.lua's send_state calls it).
local function state_fields(_, s, msg)
  local r = s.repair
  if r and r.at and game.tick - r.at <= 2 and r.entity.valid then
    local p = r.entity.position
    msg.rp, msg.rx, msg.ry = 1, world.fixed(p.x), world.fixed(p.y)
  end
end

puppet.state_extras[#puppet.state_extras + 1] = state_fields

function M.reset()
  storage.f3d.repair = nil
end

return M
