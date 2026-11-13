-- The wall round each step of the bridge's tick and each event handler: one bad read logs and
-- skips that step instead of stopping the player's game. It hides nothing: the step's name and the
-- error go to Factorio's log (again every LOG_EVERY ticks while it keeps failing), to the client
-- as a `msg`, and stay in /f3d-status.
--
-- A step that fails part-way stays part-way: Lua can't undo what it wrote to `storage`, and the
-- game's own changes stand. In multiplayer that is safe because every peer runs the same step on
-- the same state and fails at the same line, so `storage` ends the same on each. What must not
-- happen is the barrier itself telling peers apart, so it writes nothing to `storage` and nothing
-- depends on what it keeps: counts and messages live here (a peer that joined later has fewer).
-- An error only one peer hits (a module-local cache) is the determinism bug it always was: that
-- peer desyncs and is sent the map again, where before it stopped.
--
-- Nothing is rolled back or switched off: a failed step runs again next tick. A job it left half
-- done either moves on or keeps failing, loudly, and a client's next handshake starts it over.

local transport = require("scripts.transport")

local M = {}

-- Tests turn this on so an error still fails them: the fake API's strict reads are the whole point
-- of tools/mod_tests.
M.rethrow = false

local LOG_EVERY = 600
local MAX_TEXT = 2000

local seen = {}   -- step -> {n, first, last, logged, held, text}
local order = {}  -- steps in the order they first failed

local function traced(err)
  local text = tostring(err)
  if debug and debug.traceback then
    return debug.traceback(text, 2)
  end
  return text
end

local function first_line(text)
  return text:match("^[^\n]*"):sub(1, 300)
end

local function note(step, text)
  local f = seen[step]
  if not f then
    f = { n = 0, first = game.tick, held = 0 }
    seen[step] = f
    order[#order + 1] = step
  end
  f.n = f.n + 1
  f.last = game.tick
  f.text = text:sub(1, MAX_TEXT)
  if f.logged and game.tick - f.logged < LOG_EVERY then
    f.held = f.held + 1
    return
  end
  local more = f.held > 0 and (" (and " .. f.held .. " more times since the last report)") or ""
  f.logged, f.held = game.tick, 0
  log("[Zenith] ERROR in step '" .. step .. "' at tick " .. game.tick .. more .. ": " .. f.text)
  -- (Sending touches no game state; the client being served when it failed hears of it.)
  pcall(transport.send_now, { t = "msg", text = "Bridge error in " .. step .. ": " .. first_line(f.text) })
end

-- Runs fn(...) once. Returns its first result, or nil if it failed.
function M.call(step, fn, ...)
  local ok, result = xpcall(fn, traced, ...)
  if ok then
    return result
  end
  note(step, tostring(result))
  if M.rethrow then
    error(result, 0)
  end
  return nil
end

-- Forgets a step's failures: live_check's barrier check fails steps on purpose, and a later check
-- in the same run must still see a real failure as the only one.
function M.forget(step)
  if seen[step] then
    seen[step] = nil
    for i, name in ipairs(order) do
      if name == step then
        table.remove(order, i)
        break
      end
    end
  end
end

-- Lines for /f3d-status.
function M.report()
  local lines = {}
  for _, step in ipairs(order) do
    local f = seen[step]
    lines[#lines + 1] = string.format("[Zenith] ERROR: step '%s' failed %d time(s), first at tick %d, last at tick %d: %s",
      step, f.n, f.first, f.last, first_line(f.text))
  end
  return lines
end

return M
