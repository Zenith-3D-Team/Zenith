-- How often the periodic jobs run, slowed down on the client's word (`rate` command, level 0-3):
-- when the server is under load the bridge sends its costliest updates less often rather than
-- sending less of the world, so the game keeps its speed and the client glides further between
-- updates ("the world may lag but the server won't"). The character's own updates (`me`) never
-- slow down.
--
-- Jobs are ranked by what they cost on the owner's save (/f3d-profile trace): the costliest (tier 1)
-- stretch from level 1, the next from level 2, the rest from level 3, each doubling its interval per
-- level past its first, up to its own longest period. A stretched job runs on a tick of its own
-- (`phase`), at every level, so jobs that used to land together on every 30th or 60th tick don't.
--
-- What the client glides (`mv`, `bi`, `ih`) says how far apart its updates are (`p`). Movers and
-- belt items are drawn behind the game's clock by about that much, so after a slow-down the client
-- has to draw them further behind: those (`ease`) keep their old rate for EASE_TICKS while already
-- saying the new one, and the client eases its delay in meanwhile instead of running out of
-- positions and stopping.
--
-- The belt simulation's updates (`bs`, belt_sim.lua) are not glided positions: each is a read of
-- every input spot (inserters' and drills' belts, splitters, the edge), checked once an update, and
-- the client simulates the belts in between from those reads. Stretching them saves the bridge
-- about as much as stretching `bi` did (the steady queue is one round an update), but every tick
-- added to the period is a tick longer the client's bus runs on stale inputs: at 48 ticks the owner's
-- copper bus showed gaps along every lane. So `bs` is its own job, slowed last (tier 3) and only to
-- 12 ticks (the client's own quiet check spacing): under Hold 60 UPS the client's next steps (the
-- minimap, the entity distance, the belt item distance `far`, which shrinks the square the bridge
-- reads) buy the UPS instead, a smaller picture the game's rather than a stale one.
-- Measured live at -62,-26 (the belt-rate round, docs/RUNNING.md "Update rates at the owner's belts"):
-- the 12 ticks are not the visible gap there (live visible 96.1-96.4% with `bs` at 6 ticks at every level, or
-- at 12) but they cost phantoms (1.9-2.6% in 6 runs against 1.7-1.8% in 4 of 5 runs at 6 ticks; the gate is 2%)
-- and buy the bridge 1-2.5 ms a tick (bs.watch 3.0 -> 2.0 ms) and about 1 UPS, so belt_sim.lua now caps the
-- period at the interval by default (`/f3d-bs period_max`, 6; 0 gives this table's 12 back). The game
-- ran at 46-48 UPS there because the bridge's Lua is ~10 ms of a ~21 ms tick (the game's own update is ~3 ms;
-- the client takes 2 of the 4 cores) and the recording's own reads, not because of any one job: the alerts'
-- pass (`al`) now stretches from level 2 too, and the client's ladder skips its `updates` steps (3000, 1500:
-- `bfar` m, the belt cap), which buy a `bs` client nothing (its square ignores the cap, belt_sim.lua full_area)
-- and cost 5 s each before `far` 96 shrinks the square (ups_governor.gd updates_steps).
--
-- Deterministic: the level lives in storage.f3d (set from a client command, like `focus`), each
-- job's last runs too (from on_tick), and everything else is worked out from them and game.tick.

local budget = require("scripts.budget")
local perf = require("scripts.perf")

local M = {}

M.MAX_LEVEL = 3
local EASE_TICKS = 120

-- tier: the level a job first slows down at. max: its longest period, in ticks. phase: the tick
-- (modulo its period) a stretched job runs on; odd, so off the 30th and 60th ticks where
-- crafting, research, trains and the rest land, and apart from each other.
-- slack: how many ticks the job may wait for a lighter tick (budget.admit); none, it runs on time.
-- price: units per entity it reads, a unit being ~20 us (calibrated on the owner's save, Zenith Test,
-- from /f3d-profile trace beside `f3dunits`), cost: what it is expected to cost before it has run once.
local JOBS = {
  bi = { tier = 1, max = 48, phase = 1, ease = true },  -- items on belts (glided): the costliest by far
  bs = { tier = 3, max = 12, phase = 1, ease = true },  -- the belt simulation's updates (reads of the input spots: see the top)
  lanes = { tier = 1 },   -- far belt lanes: only a factor on their rounds (M.factor), no period or tick
  mv = { tier = 1, max = 16, phase = 1, ease = true },  -- movers' positions (and how often they are searched)
  st = { tier = 2, max = 120, phase = 17, slack = 8, price = 0.28, cost = 500 },   -- machine working states
  wires = { tier = 2, max = 120, phase = 23, slack = 12, price = 0.9, cost = 460 }, -- tracker's look for changed wires
  seg = { tier = 2, max = 8, phase = 1 },     -- demolishers' segments (planets.lua)
  en = { tier = 2, max = 40, phase = 7, slack = 3, price = 0.2, cost = 10 },     -- enemies attacking
  life = { tier = 2, max = 240, phase = 43, slack = 20, price = 0.3, cost = 250 }, -- plants, spawners, frozen machines (planets.lua): ~30 ms a run on the owner's save
  al = { tier = 2 },      -- the alerts' pass over the force's machines (alerts.lua): only a factor on how often a pass starts
  ac = { tier = 2 },      -- Alt-mode's chest contents (alt_mode.lua): only a factor on how often a round starts
  fp = { tier = 3, max = 240, phase = 41, slack = 15, price = 0.14, cost = 380 },   -- fluids, heat, power (fluids_power.lua)
  tr = { tier = 3, max = 120, phase = 37, slack = 8, price = 5.8, cost = 150 },   -- trains
  ts = { tier = 3, max = 24, phase = 5 },     -- turrets' aim
  ih = { tier = 3, max = 24, phase = 3 },     -- inserter hands
  gi = { tier = 3, max = 120, phase = 29, slack = 6, price = 0.1, cost = 10 },   -- items on the ground
  rc = { tier = 3, max = 40, phase = 13, slack = 6, price = 0.1, cost = 10 },    -- robots' cargo
  rb = { tier = 3, max = 16, phase = 9 },                                        -- robot flight updates (event-driven + heartbeat)
  pol = { tier = 3, max = 1200, phase = 53, slack = 30, price = 0.02, cost = 15 }, -- chunks' pollution (pollution.lua)
}

function M.level()
  local s = storage.f3d
  return s and s.rate or 0
end

-- {l}: the client's slow-down level, 0 (normal) to MAX_LEVEL. While the level is held from the console
-- (`/f3d-rate <l> hold`, M.hold: for measuring one level) the client's word is kept but not followed.
function M.set(cmd)
  local s = storage.f3d
  local l = math.max(0, math.min(M.MAX_LEVEL, math.floor(tonumber(cmd.l) or 0)))
  if s.rate_hold then
    s.rate_asked = l
    return
  end
  local old = s.rate or 0
  if l ~= old then
    s.rate_from, s.rate_at = old, game.tick
  end
  s.rate = l > 0 and l or nil
end

-- `/f3d-rate <l> hold`: the level set and held against the client's `rate` commands (and a new client's
-- hello) until `/f3d-rate free`, which goes back to what the client last asked. For measuring.
function M.hold(l)
  local s = storage.f3d
  s.rate_asked = s.rate or 0
  s.rate_hold = nil
  M.set({ l = l })
  s.rate_hold = true
end

function M.free()
  local s = storage.f3d
  if s.rate_hold then
    s.rate_hold = nil
    M.set({ l = s.rate_asked or 0 })
    s.rate_asked = nil
  end
end

function M.held()
  local s = storage.f3d
  return s and s.rate_hold == true
end

-- (belts_last, perf.lua) Belt jobs that slow last whatever their place above: the far belt lanes' rounds at level 3,
-- as `bs` (the owner: belt logic is the last thing culled for performance). Off: their tier above.
local BELT_TIERS = { lanes = 3 }
local function tier_of(name)
  local t = BELT_TIERS[name]
  if t and perf.on("belts_last") then
    return t
  end
  return JOBS[name].tier
end

local function factor_at(name, level)
  local over = level - tier_of(name) + 1
  if over <= 0 then
    return 1
  end
  return math.floor(2 ^ over + 0.5)
end

-- How many times longer job `name` waits between runs at the current level: 1, 2, 4 or 8.
function M.factor(name)
  return factor_at(name, M.level())
end

-- `double`: the job doubles its own period too (belt items on a busy base), within its longest
-- (or twice its interval, as it always did). `cap`: the caller's own longest period in ticks (belt_sim.lua's
-- period_max switch for `bs`), never under the interval; nil or 0, the job's max.
local function period_at(name, interval, level, double, cap)
  local job = JOBS[name]
  local p = interval
  if factor_at(name, level) > 1 then
    p = math.max(interval, math.min(interval * factor_at(name, level), job.max))
  end
  if double then
    p = math.max(p, math.min(p * 2, math.max(job.max, interval * 2)))
  end
  if cap and cap > 0 then
    p = math.max(interval, math.min(p, cap))
  end
  return p
end

-- Ticks between runs of a job that runs every `interval` ticks at level 0, at the current level:
-- what its messages' `p` says.
function M.period(name, interval, double, cap)
  return period_at(name, interval, M.level(), double, cap)
end

-- Near-bubble counterpart to `M.period`: stays at level 0 (factor 1) while `near_rate` is on.
function M.period_near(name, interval, double, cap)
  if perf.on("near_rate") then
    return period_at(name, interval, 0, double, cap)
  end
  return M.period(name, interval, double, cap)
end

-- Whether a job with this period runs this tick at `level`.
local function on_ticks(name, interval, level, double, cap)
  local p = period_at(name, interval, level, double, cap)
  -- Every job on its own phase, at level 0 too: on main's ticks they all fell together once a
  -- second (the bridge budget's finding: 190-250 ms ticks on the owner's save).
  local phase = JOBS[name].phase
  return game.tick % p == phase % p, p
end

local function due_at(name, interval, double, cap, near)
  local s = storage.f3d
  local level = near and 0 or (s.rate or 0)
  local now, p = on_ticks(name, interval, level, double, cap)
  local t = game.tick
  if not near and not now and JOBS[name].ease and s.rate_at and (s.rate_from or 0) < (s.rate or 0)
      and t < s.rate_at + EASE_TICKS then
    now = on_ticks(name, interval, s.rate_from or 0, double, cap)
  end
  local job = JOBS[name]
  local key = near and (name .. "_near") or name
  if job.slack then
    -- Due now or waiting since: it runs when the tick has room for it, or its slack ran out.
    s.rate_wait = s.rate_wait or {}
    local since = s.rate_wait[key]
    if now and not since then
      since = t
    end
    if not since then
      return false
    end
    if not budget.admit(name, job.cost, t - since >= math.min(job.slack, p - 1)) then
      s.rate_wait[key] = since
      return false
    end
    s.rate_wait[key] = nil
  elseif not now then
    return false
  end
  s.rate_jobs = s.rate_jobs or {}
  local j = s.rate_jobs[key]
  s.rate_jobs[key] = { prev = j and j.last or t - p, last = t }
  return true
end

-- Whether job `name` (every `interval` ticks at level 0) runs this tick. For EASE_TICKS after a
-- slow-down an `ease` job also still runs on its old ticks, so no gap is ever longer than its `p`.
function M.due(name, interval, double, cap)
  return due_at(name, interval, double, cap, false)
end

-- Near-bubble counterpart to `M.due`: stays at level 0 cadence (still honoring `job.slack` via
-- `budget.admit`) while `near_rate` is on; delegates to `M.due` when off.
function M.due_near(name, interval, double, cap)
  if perf.on("near_rate") then
    return due_at(name, interval, double, cap, true)
  end
  return M.due(name, interval, double, cap)
end

-- Job `name` (one with a slack) read `count` entities this run: what it is expected to cost next.
function M.read(name, count)
  local job = JOBS[name]
  if job and job.slack then
    budget.learn(name, (count or 0) * job.price)
  end
end

-- Whether a multiple of `every` passed since the job's run before this one (due just said yes):
-- for work a job did on `game.tick % every == 0`, which a stretched job's ticks may never land on.
function M.crossed(name, every)
  local jobs = storage.f3d.rate_jobs
  local j = jobs and jobs[name]
  if not j then
    return false
  end
  return math.floor(j.last / every) ~= math.floor(j.prev / every)
end

-- A new world (handshake, resync): each job starts over.
function M.reset()
  storage.f3d.rate_jobs = nil
  storage.f3d.rate_wait = nil
end

return M
