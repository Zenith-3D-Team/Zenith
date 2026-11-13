-- Belts and loaders switched off by the circuit or logistic network. In Factorio a belt's surface
-- runs all the time, carrying items or not; only a belt switched off stands still, so the client
-- draws every belt moving and needs telling just which ones are off.
--
-- Only an entity with a wire, or set to read the logistic network, can be switched off, and no
-- event says when it happens (docs/BELT-RULES.md), so those few are watched: each record of one puts
-- it in storage.f3d.beltw, and a few a tick are read again under the work budget. What changed goes
-- out as `st` rows, state OFF, or 0 for running again. A belt never told about counts as running.
--
-- A logistic condition on a belt with no wire is noticed as it is set: `configured`, from the
-- client's own screen, a settings paste and a player closing the belt's window in the real game.
--
-- Everything here runs from events and on_tick, and what it keeps only from the records the client
-- is sent, so it stays the same on every peer.

local transport = require("scripts.transport")
local budget = require("scripts.budget")

local M = {}

local CHUNK = 32
-- `st`'s state for a belt switched off (the client's Anim.SWITCHED_OFF).
M.OFF = 5
-- What a network can switch off. Undergrounds have no circuit connector; a splitter has, but its
-- conditions only set its priorities and filter (LuaSplitterControlBehavior, no enable or disable).
M.TYPES = { ["transport-belt"] = true, loader = true, ["loader-1x1"] = true }

-- Read again per tick at most (the work budget may allow fewer), and how many reads make a work
-- unit: one read is a single property, against about 20 us a unit.
local WATCH_PER_TICK = 200
local READS_PER_UNIT = 16
-- A round over the watched belts starts at most this often (a belt stops within half a second of
-- the items on it).
local ROUND_TICKS = 30
-- Belts off are told again this often, for a client that forgot them (a full resync).
local RETELL_TICKS = 600

local function chunk_key(p)
  return math.floor(p.x / CHUNK) .. "," .. math.floor(p.y / CHUNK)
end

-- By its status: in 2.1 a belt isn't an "updatable" entity, so disabled_by_control_behavior reads
-- false on one that is off (a loader's reads true; both have the status).
local function read_off(e)
  return e.status == defines.entity_status.disabled_by_control_behavior
end

local function read_logistic(e)
  local behavior = e.get_control_behavior()
  return behavior ~= nil and behavior.connect_to_logistic_network
end

local function watch(e, s)
  s.beltw = s.beltw or {}
  local was = s.beltw[e.unit_number]
  s.beltw[e.unit_number] = { e = e, off = was and was.off or false, k = chunk_key(e.position), si = e.surface.index }
end

-- world.record calls this for each record of a belt or loader, with its extra (wires in r / g). Only
-- for a client's own records (storage.f3d has its subscriptions).
function M.recorded(e, extra)
  local s = storage.f3d
  local unit = e.unit_number
  if not (s and s.subs and unit) then
    return
  end
  local switchable = extra and (extra.r or extra.g)
  if not switchable then
    local ok, logistic = pcall(read_logistic, e)
    switchable = ok and logistic
  end
  if switchable then
    watch(e, s)
  elseif s.beltw and s.beltw[unit] then
    -- Its wires went: nothing can switch it off now, and nothing would say it runs again.
    if s.beltw[unit].off then
      transport.send_reliable({ t = "st", l = { unit, 0 } })
    end
    s.beltw[unit] = nil
  end
end

-- The entity's circuit settings were just changed: one set to read the logistic network has no wire
-- to be noticed by, so it starts being watched here.
function M.configured(e)
  local s = storage.f3d
  if s and s.subs and e.valid and e.unit_number and M.TYPES[e.type] then
    local ok, logistic = pcall(read_logistic, e)
    if ok and logistic then
      watch(e, s)
    end
  end
end

-- A wire was added or removed at this pole or combinator (tracker.lua's look for them; no event says
-- so): a belt at the other end can now be switched off. A wire between two belts alone, drawn in
-- Factorio's window, is seen when the chunk is next sent.
function M.rewired(e)
  local s = storage.f3d
  for _, connector in pairs(e.get_wire_connectors(false)) do
    for _, connection in pairs(connector.connections) do
      local owner = connection.target.owner
      if owner.unit_number and M.TYPES[owner.type] then
        watch(owner, s)
      end
    end
  end
end

-- A few watched belts a tick, a round at most every ROUND_TICKS. Entries gone are dropped when the
-- round ends (clearing keys behind the cursor while it walks would break `next`); those no longer
-- streamed stay, so a chunk the client still has when it comes back (`same`) goes on being watched.
function M.tick()
  local s = storage.f3d
  local w = s.beltw
  if not w or game.tick < (s.beltw_due or 0) then
    return
  end
  if s.beltw_cursor ~= nil and not w[s.beltw_cursor] then
    s.beltw_cursor = nil -- its entry went (M.recorded): start the round again
  end
  if s.beltw_cursor == nil and game.tick >= (s.beltw_retell or 0) then
    s.beltw_retell = game.tick + RETELL_TICKS
    s.beltw_all = true
  end
  local out
  local reads = 0
  for _ = 1, WATCH_PER_TICK do
    if not budget.can(1, "beltw", 0.1) then
      break
    end
    local unit, entry = next(w, s.beltw_cursor)
    if unit == nil then
      s.beltw_cursor = nil
      s.beltw_all = nil
      for _, u in ipairs(s.beltw_dead or {}) do
        w[u] = nil
      end
      s.beltw_dead = nil
      s.beltw_due = game.tick + ROUND_TICKS
      break
    end
    s.beltw_cursor = unit
    local e = entry.e
    if not e.valid then
      s.beltw_dead = s.beltw_dead or {}
      s.beltw_dead[#s.beltw_dead + 1] = unit
    elseif entry.si == s.surface_index and s.subs[entry.k] then
      reads = reads + 1
      if reads % READS_PER_UNIT == 0 then
        budget.spend(1, "beltw")
      end
      local ok, off = pcall(read_off, e)
      off = ok and off == true
      if off ~= entry.off or (off and s.beltw_all) then
        entry.off = off
        out = out or {}
        out[#out + 1] = unit
        out[#out + 1] = off and M.OFF or 0
      end
    end
  end
  if out then
    transport.send_reliable({ t = "st", l = out })
  end
end

return M
