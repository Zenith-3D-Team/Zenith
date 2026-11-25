-- The bridge's Lua garbage collector, paced by the tick (`/f3d-perf gc_pace`, docs/RUNNING.md).
--
-- Lua's own collector runs in steps taken while code allocates, whichever module happens to allocate
-- when a step falls due, and some of its steps are long (the start of its sweep, a sweep step freeing tens of
-- MB, the finalizers of the game's objects run at a cycle's end). Those landed in single ticks: with the
-- collector stopped 78% of the bridge's ticks over 16.7 ms went (the bridge UPS R&D). Here the automatic
-- collector is stopped and the work it owes is done once a tick, after the bridge's own work, in small steps
-- up to a budget of work and of memory freed (below).
--
-- Module-local only: nothing here reads or writes `storage` and nothing the bridge does depends on it, so
-- peers that collect at different times stay in sync. The switch itself is in storage.f3d_perf (set by the
-- command, an event every peer runs). Off: the collector restarted, as before.

local M = {}

-- A cycle starts once the heap is T.pause times what is live (the heap a cycle's end left, less what was made while it
-- swept: from the heap alone a long cycle set the next one's threshold from all it had not freed yet, 1.2 GB on
-- Zenith Test; 0: back to back). Each tick takes small steps (T.step KB of the collector's work each) until it has done
-- T.mult times the KB allocated since the last tick (smoothed: a burst is paid back over the next ticks; at
-- least T.floor_kb, at most T.burst times the average), or has freed T.free times that (at least T.free_min KB):
-- freeing is what costs (about 1 ms a MB, live, against 0.14 for marking), and the collector counts a step of
-- its sweep as far less work than it is (one step of 500 KB freed 50 MB of dead tables, 10-26 ms). The values
-- are module-local (`/c` can try others: measuring).
local T = { pause = 2, mult = 2, floor_kb = 256, burst = 3, step = 8, free = 2, free_min = 1024, most = 4000,
  sweep_calls = 0, sweep_free = 4 }
M.T = T
local EMA = 0.1
-- The heap past AHEAD times what cycles' ends left it (about what is live): the tick's budgets
-- double, and again for each further AHEAD (it fell behind).
local AHEAD = 1.5

local stopped = false
local last_kb = nil   -- the heap after the last tick's steps
local rate = 0        -- KB allocated a tick, smoothed
local base_kb = nil   -- about what is live: the heap a cycle's end left, smoothed (reset with the switch)
local sweep_kb = nil  -- KB allocated since this cycle's sweep began (its first step that freed), nil before
local waiting = false -- between cycles (T.pause > 0)

-- Sentinels: a table and one with a finalizer, made just before each step and kept until the next. Lua 5.2
-- starts its sweep (entersweep) by freeing at once every dead object at the head of its lists of objects, the
-- newest first: everything the bridge threw away while the cycle marked, 18-26 ms in one step. With the
-- newest object alive that starts nowhere, and the rest is swept in the steps after, as the others.
local GC_MT = { __gc = function() end }
local sentinel, sentinel_fin = nil, nil

-- Counts for /f3d-status (module-local; measuring only).
M.counts = { ticks = 0, steps = 0, cycles = 0, kb = 0, freed = 0 }

function M.stop()
  if stopped then
    collectgarbage("restart")
    stopped = false
  end
  last_kb, rate, base_kb, sweep_kb, waiting = nil, 0, nil, nil, false
end

-- The safety valve: with the collector stopped the heap must not run away when ticks stop (paused, a long load) or one
-- tick allocates far beyond the budget. Above CEIL_MULT times the paced base (or CEIL_KB, whichever is lower) the
-- collector is restarted; the next paced tick stops it again and takes over. One `count` call, module-local.
local CEIL_KB = 512 * 1024
local CEIL_MULT = 4
M.counts.rescues = 0

function M.ceiling()
  local c = CEIL_KB
  if base_kb and base_kb * CEIL_MULT < c then
    c = base_kb * CEIL_MULT
  end
  return c
end

-- Cheap check for code that runs between ticks (packets, commands). True if it restarted the collector.
function M.guard()
  if stopped and collectgarbage("count") > M.ceiling() then
    collectgarbage("restart")
    stopped = false
    M.counts.rescues = M.counts.rescues + 1
    return true
  end
  return false
end

-- Once a tick, after the bridge's work. `on`: the switch.
function M.tick(on)
  if not on then
    M.stop()
    return
  end
  M.counts.ticks = M.counts.ticks + 1
  local kb = collectgarbage("count")
  if not stopped then
    collectgarbage("stop")
    stopped = true
    last_kb = kb
    return
  end
  if M.guard() then
    -- (Over the ceiling: Lua's collector runs till the next tick, which stops it and paces again.)
    return
  end
  local grown = kb - (last_kb or kb)
  if grown < 0 then
    grown = 0
  end
  rate = rate + (grown - rate) * EMA
  if sweep_kb then
    sweep_kb = sweep_kb + grown
  end
  -- (T.pause > 0: the next cycle waits till the heap is that many times what is live.)
  if waiting then
    if kb < (base_kb or 0) * T.pause then
      last_kb = kb
      return
    end
    waiting = false
  end
  local work_max = math.max(T.floor_kb, math.min(grown, rate * T.burst)) * T.mult
  local free_max = math.max(T.free_min, rate * T.free)
  local over = base_kb and kb / base_kb or 1
  local ahead = math.max(AHEAD, T.pause * 1.25)
  while over > ahead do
    work_max, free_max, over = work_max * 2, free_max * 2, over / AHEAD
  end
  -- (Sweeping: steps of 0, each one step of Lua's sweep (40 objects) and 4 finalizers, the game objects' clean-up.
  -- Lua 5.2 runs 4 a call and all that are left when the cycle ends: in steps of 8 KB (20 sweep steps a call) most
  -- were left, 25-60 ms at a cycle's end on Zenith Test. One sweep step a call keeps up with them.)
  -- (T.sweep_calls 0, the default: measured on Zenith Test it made more cycles and no fewer slow ticks.)
  local sweeping = sweep_kb ~= nil and T.sweep_calls > 0
  local step = sweeping and 0 or T.step
  local most = sweeping and T.sweep_calls or T.most
  local work, freed, n = 0, 0, 0
  local done = false
  -- (Sweeping by single steps: up to T.sweep_free times the tick's freed budget, the calls' own cap first.)
  if sweeping then
    free_max = free_max * T.sweep_free
  end
  while (sweeping or work < work_max) and freed < free_max and n < most do
    sentinel, sentinel_fin = {}, setmetatable({}, GC_MT)
    local before = collectgarbage("count")
    done = collectgarbage("step", step)
    local after = collectgarbage("count")
    if after < before then
      freed = freed + before - after
      sweep_kb = sweep_kb or 0
    end
    work, n = work + step, n + 1
    if done then
      break
    end
  end
  M.counts.steps = M.counts.steps + n
  M.counts.kb = M.counts.kb + work
  M.counts.freed = M.counts.freed + freed
  if done then
    M.counts.cycles = M.counts.cycles + 1
    -- (What is live: the heap now less what was made while it swept, none of which this cycle could free.)
    local now = collectgarbage("count") - (sweep_kb or 0)
    sweep_kb = nil
    waiting = T.pause > 0
    -- (Down at once, up a quarter of the way a cycle: the live data grows as the square loads.)
    if not base_kb or now < base_kb then
      base_kb = now
    else
      base_kb = base_kb + (now - base_kb) * 0.25
    end
    if M.ends then
      M.ends[#M.ends + 1] = game.tick
    end
  end
  last_kb = collectgarbage("count")
end

function M.status()
  return string.format("gc_pace: %s, heap %.0f MB, after a cycle %.0f MB, %.0f KB a tick allocated, %d cycles, %d rescues",
    stopped and "on" or "off", collectgarbage("count") / 1024, (base_kb or 0) / 1024, rate, M.counts.cycles,
    M.counts.rescues)
end

return M
