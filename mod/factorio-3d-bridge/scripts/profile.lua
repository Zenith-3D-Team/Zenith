-- What the bridge costs per tick, module by module: `/f3d-profile` turns timing on, and
-- `/f3d-status` then shows each module's average over the last 10 seconds.
--
-- Measuring only: the timers live here, not in `storage`, and nothing they read changes the
-- game, so peers that differ (one profiling, one not) still stay in sync.

local M = {}

local WINDOW = 600 -- ticks averaged in a report

local enabled = false
local order = {}   -- module names in the order they first ran
local timers = {}  -- name -> LuaProfiler for one call
local totals = {}  -- name -> LuaProfiler summed over the current window
local last = nil   -- name -> LuaProfiler, average per tick over the last full window
local ticks = 0

-- Trace mode (`/f3d-profile trace N`): for N ticks, every module's and packet's time is written to
-- the log, one line each ("f3dtrace <tick> name Duration: x ms"), so single slow ticks can be found
-- (a profiler can't be read as a number, only printed). tools/request_spikes.py and
-- tools/bench/compare_builds.py read the lines back.
local trace_left = 0
local trace_tick = {}  -- this tick's {name, profiler} in order

-- At most ten minutes: each traced tick writes a line to the log, and Zenith's console can ask.
local MAX_TRACE = 36000

function M.trace(n)
  trace_left = math.max(0, math.min(MAX_TRACE, math.floor(tonumber(n) or 0)))
  trace_tick = {}
  return trace_left
end

function M.tracing()
  return trace_left > 0
end

function M.toggle()
  enabled = not enabled
  order, timers, totals, last, ticks = {}, {}, {}, nil, 0
  return enabled
end

-- Runs fn (one module's tick) once and, while profiling or tracing, times it for both.
function M.run(name, fn, ...)
  local tracing = trace_left > 0
  if not enabled and not tracing then
    return fn(...)
  end
  local t
  if enabled then
    t = timers[name]
    if not t then
      t = helpers.create_profiler(true)
      timers[name] = t
      totals[name] = helpers.create_profiler(true)
      order[#order + 1] = name
    end
    -- reset, not restart: restart carries on from the last call's time, so every call would add
    -- all the ones before it.
    t.reset()
  else
    t = helpers.create_profiler()
  end
  fn(...)
  t.stop()
  if enabled then
    totals[name].add(t)
  end
  if tracing then
    -- The trace keeps its own copy: the module's timer is reset on its next call this tick.
    local copy = helpers.create_profiler(true)
    copy.add(t)
    trace_tick[#trace_tick + 1] = { name, copy }
  end
end

-- A section inside a module (belt_sim.lua's scan, loads, checks...), timed like a module of its own
-- while profiling or tracing: `local t = profile.start()` ... `profile.stop("name", t)`. Nil (and
-- nothing timed) otherwise, so it costs a call when off. Its time is also inside its module's.
function M.start()
  if not enabled and trace_left <= 0 then
    return nil
  end
  return helpers.create_profiler()
end

function M.stop(name, t)
  if not t then
    return
  end
  t.stop()
  if enabled then
    local total = totals[name]
    if not total then
      total = helpers.create_profiler(true)
      totals[name] = total
      if not timers[name] then
        timers[name] = true
        order[#order + 1] = name
      end
    end
    total.add(t)
  end
  if trace_left > 0 then
    trace_tick[#trace_tick + 1] = { name, t, true }
  end
end

-- Call once per tick, after the modules ran.
function M.end_tick()
  if trace_left > 0 then
    trace_left = trace_left - 1
    local total = helpers.create_profiler(true)
    for _, row in ipairs(trace_tick) do
      if not row[3] then
        total.add(row[2])  -- (a section's time is inside its module's already)
      end
      log({ "", "f3dtrace ", game.tick, " ", row[1], " ", row[2] })
    end
    log({ "", "f3dtrace ", game.tick, " TOTAL ", total })
    trace_tick = {}
  end
  if not enabled then
    return
  end
  ticks = ticks + 1
  if ticks < WINDOW then
    return
  end
  for _, total in pairs(totals) do
    total.divide(WINDOW)
  end
  last, totals, ticks = totals, {}, 0
  for name in pairs(last) do
    totals[name] = helpers.create_profiler(true)
  end
end

-- Lines for /f3d-status (localised strings: a profiler only prints itself).
function M.report()
  if not enabled then
    return { "[Zenith] profiling off (/f3d-profile turns it on)" }
  end
  if not last then
    return { "[Zenith] profiling: the first average is ready after " .. WINDOW .. " ticks" }
  end
  local lines = {}
  for _, name in ipairs(order) do
    if last[name] then
      lines[#lines + 1] = { "", "[Zenith] ", name, ": ", last[name], " per tick" }
    end
  end
  return lines
end

return M
