-- The bridge's work budget per tick. A big request from the client (a map view's charts, the chunks
-- after a jump or a join, another planet's remote view, Factoriopedia, the trains on the map...) must
-- never make one slow tick, so every job that can be big works through a queue in slices, and each
-- slice is paid for from this budget. When the tick's budget is spent, the rest waits for the next
-- tick.
--
-- Mods can't read a clock (it would differ between peers), so the budget is counted in work units:
-- one unit is about one entity read and painted into a chart (15-30 us on the laptop, measured on
-- the owner's save in 2.1.23; a chunk snapshot's record is two), TILES_PER_UNIT tiles read are one
-- unit, and other slices are priced the same way from what they read. Everything here lives in the client's state (storage.f3d.bud) and only
-- changes from on_tick and packets, so it is the same on every peer.
--
-- Once a second the client gets `wb`: the budget, the units used per tick (average and most), how
-- many ticks went over it (a job's last slice may run past what is left), and how long each queue
-- is. The client may set the budget with `budget` {u}; it is clamped to FLOOR..CEILING.

local transport = require("scripts.transport")
local profile = require("scripts.profile")
local photo = require("scripts.photo")

local M = {}

M.DEFAULT = 300
M.FLOOR = 50
M.CEILING = 20000
M.TILES_PER_UNIT = 16
local REPORT_TICKS = 60

-- name -> function() -> how long that queue is now (registered by the modules that own them).
local queues = {}
local queue_order = {}

function M.register_queue(name, fn)
  if not queues[name] then
    queue_order[#queue_order + 1] = name
  end
  queues[name] = fn
end

local function state()
  local s = storage.f3d
  local b = s.bud
  if not b then
    b = { limit = M.DEFAULT, used = 0, sum = 0, max = 0, n = 0, over = 0, jobs = {} }
    s.bud = b
  end
  return b
end

-- Called before the client's modules run each tick.
function M.begin()
  local b = state()
  b.used, b.load = 0, 0
  for k in pairs(b.jobs) do
    b.jobs[k] = 0
  end
end

-- The budget, units a tick.
function M.limit()
  return state().limit
end

-- Units left this tick. With `job` and `share` (0-1), also no more than that share of the budget
-- for this job, so one long queue can't starve the others.
function M.left(job, share)
  local b = state()
  local free = b.limit - b.used
  if job and share then
    free = math.min(free, math.floor(b.limit * share) - (b.jobs[job] or 0))
  end
  return free
end

-- Whether a slice of `price` units may run now: when it fits what is left, or, when it doesn't,
-- as the job's first slice this tick while anything is left (so a slice dearer than the whole
-- budget still moves; that tick goes over by at most that slice, and `wb` counts it).
function M.can(price, job, share)
  local left = M.left(job, share)
  if price <= left then
    return true
  end
  return left > 0 and (state().jobs[job] or 0) == 0
end

function M.spend(units, job)
  local b = state()
  units = math.max(0, math.floor(units or 0))
  b.used = b.used + units
  if job then
    b.jobs[job] = (b.jobs[job] or 0) + units
  end
end

-- How big one slice of a job may be: half the budget, so a tick fits about two, at least `least`.
function M.slice(least)
  return math.max(least or 25, math.floor(state().limit / 2))
end

-- The periodic jobs (rate.lua's with a `slack`: machine states, the wire check, fluids and power,
-- plants and spawners, trains, the movers' search...) share the tick with the queues above. Each
-- would run on its own ticks, and on the owner's save several landed on one tick now and then
-- (366 of 3,600 bridge ticks over 16.7 ms, each job cheap alone). So when one is due it asks
-- `admit` with what it is expected to cost: it runs if that fits PERIODIC times the budget (1.25: 2 left as many slow ticks on
-- the owner's save as before) beside
-- what this tick already holds (the queues' slices, belt items' share, `commit`), or if the tick
-- holds little; otherwise it waits for a lighter tick, at most its slack. Their units are kept
-- apart from the queues' (`load`), so the queues keep their whole budget. What it is expected to cost is learned:
-- after each run it says what it read (`learn`, entities found times its price), kept as a moving
-- average per job in storage, so it follows each base (and the client's budget, which Hold 60 UPS
-- shrinks on a slower PC, sets how full a tick may get). Deterministic: estimates come from game
-- state only.
M.PERIODIC = 1.25
local LEARN = 0.3

local function costs()
  local b = state()
  b.cost = b.cost or {}
  b.charged = b.charged or {}
  return b
end

-- What job `name` is expected to cost, in units (`default` until it has run).
function M.estimate(name, default)
  return costs().cost[name] or default or 25
end

-- Whether periodic job `name` may run this tick (`force`: its slack ran out). Charges its estimate.
function M.admit(name, default, force)
  local b = costs()
  local est = M.estimate(name, default)
  local cap = b.limit * M.PERIODIC
  local held = b.used + (b.load or 0)
  -- (A job dearer than a whole tick runs on a tick that holds little else.)
  if not force and held + est > cap and held > cap / 4 then
    return false
  end
  b.charged[name] = est
  M.commit(est, name)
  return true
end

-- Work this tick will do whatever happens (belt items' share): periodic jobs keep off it.
function M.commit(units, job)
  local b = state()
  units = math.max(0, math.floor(units or 0))
  b.load = (b.load or 0) + units
  if job then
    b.jobs[job] = (b.jobs[job] or 0) + units
  end
end

-- Job `name` just ran and read this many units' worth: the tick's figure is corrected to it and the
-- job's estimate moves towards it.
function M.learn(name, units)
  local b = costs()
  units = math.max(0, math.floor(units or 0))
  local charged = b.charged[name]
  if charged then
    b.charged[name] = nil
    local d = units - charged
    b.load = math.max(0, (b.load or 0) + d)
    b.jobs[name] = math.max(0, (b.jobs[name] or 0) + d)
  end
  local old = b.cost[name]
  b.cost[name] = old and math.floor(old + (units - old) * LEARN + 0.5) or units
end

-- Called after the client's modules ran: the tick's figures, and `wb` once a second.
function M.finish()
  local b = state()
  if profile.tracing() and b.used + (b.load or 0) > 0 then
    -- Beside /f3d-profile trace's times, to price the units (tools/request_spikes.py).
    local parts = {}
    for job, n in pairs(b.jobs) do
      if n > 0 then
        parts[#parts + 1] = job .. "=" .. n
      end
    end
    log("f3dunits " .. game.tick .. " " .. b.used .. " " .. table.concat(parts, " "))
  end
  b.sum = b.sum + b.used
  b.n = b.n + 1
  if b.used > b.max then
    b.max = b.used
  end
  if b.used > b.limit then
    b.over = b.over + 1
  end
  if b.n < REPORT_TICKS then
    return
  end
  local q = {}
  for _, name in ipairs(queue_order) do
    local ok, n = pcall(queues[name])
    q[name] = ok and math.floor(tonumber(n) or 0) or 0
  end
  -- ph: photo mode is on (photo.lua), so the client knows its screenshot is loading faster.
  transport.send_now({ t = "wb", b = b.limit, avg = math.floor(b.sum / b.n + 0.5), max = b.max, over = b.over,
    n = b.n, q = q, ph = photo.on() and 1 or nil })
  b.sum, b.n, b.max, b.over = 0, 0, 0, 0
end

-- `budget` {u}: the client sets the budget in units per tick (clamped).
function M.set(cmd)
  local u = tonumber(cmd.u)
  if not u or u ~= u then
    return
  end
  state().limit = math.max(M.FLOOR, math.min(M.CEILING, math.floor(u)))
end

-- Lines for /f3d-status.
function M.report()
  local b = storage.f3d and storage.f3d.bud
  if not b then
    return {}
  end
  local parts = {}
  for _, name in ipairs(queue_order) do
    local ok, n = pcall(queues[name])
    parts[#parts + 1] = name .. " " .. (ok and tostring(n) or "?")
  end
  return { string.format("[Zenith] work budget %d units a tick; queues: %s%s", b.limit, table.concat(parts, ", "),
    photo.on() and " (photo mode: a screenshot is loading its chunks)" or "") }
end

return M
