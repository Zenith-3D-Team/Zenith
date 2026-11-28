-- Run-time switches (`/f3d-bs`) and derived area/budget/rate helpers for belt_sim.lua.
-- `storage.f3d_bs` is mutated only from `option_command`; `storage.f3d.bs` bound fields only from `bound` (on_tick).

local budget = require("scripts.budget")

local M = {}

local floor = math.floor

-- Belt units per work-budget unit (belt_items.lua's).
local UNITS_PER_BUDGET_UNIT = 20
M.UNITS_PER_BUDGET_UNIT = UNITS_PER_BUDGET_UNIT

-- Numbers a `bs` part holds, about (a lane's items are never split); fewer under a small send_cap.
local PART_NUMBERS = 4000

-- The bridge's own bound constants (see `bound`).
local BOUND_SHARE = 0.6
local BOUND_OVER, BOUND_UNDER = 3, 30
local BOUND_CUT, BOUND_ROOM = 0.85, 0.6

M.OPTIONS = { feed_edges = true, full_area = true, inputs_first = true, line_rereads = true, bound = 0.6,
  actor_backoff = true, drift_far = true, bre_cap = 192, quiet_backoff = true, pc_ids = false, hold_inputs = true,
  area = "square", trace_near = 48, trace_hops = 200, trace_down = 8, checkpoints = false, crossings = "hints",
  own_rate = true, period_max = 6, drift_watched = false, walk_load = 1200, walk_near = 96, send_cap = 30000,
  extra_spread = true, quiet_first = true, watch_nosort = true, scan_step = true, scan_step_wide = true,
  scan_step_min = 12, drop_margin = 16, take_slice = true, load_budget = true, edge_budget = true,
  far_load_cap = true, two_call = true,
  far_tier = false, far_ring = 96, far_units = 1200, target_spots = true, drill_tails = true, built_now = true,
  lane_next = true, near_spool = true,
  ins_driven = false, ins_ho = true, ins_window = 20, quiet_pc = true, quiet_pc_max = 3600,
  two_call_full = 16, settled_flow_only = true, watch_lean = true, scan_incremental = true, wake_strict = true }
M.OPTION_ORDER = { "feed_edges", "full_area", "inputs_first", "line_rereads", "bound", "actor_backoff", "drift_far",
  "bre_cap", "quiet_backoff", "pc_ids", "hold_inputs", "area", "trace_near", "trace_hops", "trace_down",
  "checkpoints", "crossings", "own_rate", "period_max", "drift_watched", "walk_load", "walk_near", "send_cap",
  "extra_spread", "quiet_first", "watch_nosort", "scan_step", "scan_step_wide", "scan_step_min", "drop_margin",
  "take_slice", "load_budget", "edge_budget", "far_load_cap", "two_call", "far_tier", "far_ring",
  "far_units", "target_spots", "drill_tails", "built_now", "lane_next", "near_spool", "ins_driven", "ins_ho",
  "ins_window", "quiet_pc", "quiet_pc_max", "two_call_full", "settled_flow_only", "watch_lean", "scan_incremental",
  "wake_strict" }
-- The values a word switch takes.
M.OPTION_VALUES = { area = { square = true, trace = true }, crossings = { sim = true, game = true, hints = true } }

local O = {}
M.O = O

function M.read_options()
  local set = storage.f3d_bs or {}
  for _, k in ipairs(M.OPTION_ORDER) do
    local v = set[k]
    if v == nil then
      v = M.OPTIONS[k]
    end
    O[k] = v
  end
end

-- (ins_driven) Whether inserters' belts are read on their hands' takes and puts: it needs the actors' checks.
function M.ins_driven()
  return O.ins_driven and O.inputs_first and not O.checkpoints
end

-- Numbers a part holds under the send_cap in force (O is read at each tick's start).
function M.part_numbers()
  local cap = tonumber(O.send_cap) or 0
  if cap > 0 and cap < 30000 then
    return math.max(400, floor(cap / 7.5))
  end
  return PART_NUMBERS
end

-- The bytes a tick send_cap allows (no cap: everything at once).
function M.send_cap()
  local cap = tonumber(O.send_cap) or 0
  return cap > 0 and cap or math.huge
end

-- `/f3d-bs [name value]`: sets a switch (on/off, a number for bound, `default` for its default) and
-- says them all. Returns the lines to print.
function M.option_command(param, bs)
  -- (`/f3d-bs counts`: what has been read and checked since loading, bs.counts, for measuring.)
  if tostring(param or ""):match("^%s*counts%s*$") then
    local keys = {}
    for k in pairs(bs.counts) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = k .. "=" .. tostring(bs.counts[k])
    end
    return { "[Zenith] bs counts " .. game.tick .. ": " .. table.concat(parts, " ") }
  end
  -- (`/f3d-bs reads`: the full lane reads by cause since loading, watched belts' and the rest's, and drift checks.)
  if tostring(param or ""):match("^%s*reads%s*$") then
    local parts = {}
    for _, c in ipairs(bs.READ_CAUSES) do
      local w, u = bs.counts["rw_" .. c] or 0, bs.counts["ru_" .. c] or 0
      if w + u > 0 then
        parts[#parts + 1] = c .. "=" .. w .. "/" .. u
      end
    end
    return { "[Zenith] bs reads " .. game.tick .. " (watched/unwatched): " .. table.concat(parts, " ")
      .. "; pc=" .. bs.counts.pc .. " pc_quiet=" .. (bs.counts.pc_quiet or 0) .. " woken=" .. (bs.counts.woken or 0) }
  end
  local name, value = tostring(param or ""):match("^%s*([%w_]+)%s+(%S+)")
  local out = {}
  if name then
    if M.OPTIONS[name] == nil then
      out[#out + 1] = "[Zenith] /f3d-bs: no switch " .. name
    else
      local v
      if value == "default" then
        v = nil
      elseif type(M.OPTIONS[name]) == "string" then
        if M.OPTION_VALUES[name][value] then
          v = value
        else
          local words = {}
          for w in pairs(M.OPTION_VALUES[name]) do
            words[#words + 1] = w
          end
          table.sort(words)
          out[#out + 1] = "[Zenith] /f3d-bs " .. name .. ": " .. table.concat(words, ", ") .. " or default"
          value = nil
        end
      elseif type(M.OPTIONS[name]) == "number" then
        v = tonumber(value) or (value == "off" and 0) or nil
        if v == nil then
          out[#out + 1] = "[Zenith] /f3d-bs " .. name .. ": a number, off or default"
        else
          v = math.max(0, math.min(name == "bound" and 10 or 100000, floor(v * 1000 + 0.5) / 1000))
        end
      elseif value == "on" or value == "1" or value == "true" then
        v = true
      elseif value == "off" or value == "0" or value == "false" then
        v = false
      else
        out[#out + 1] = "[Zenith] /f3d-bs " .. name .. ": on, off or default"
        value = nil
      end
      if value and (v ~= nil or value == "default") then
        storage.f3d_bs = storage.f3d_bs or {}
        storage.f3d_bs[name] = v
      end
    end
  end
  M.read_options()
  local parts = {}
  for _, k in ipairs(M.OPTION_ORDER) do
    local v = O[k]
    parts[#parts + 1] = k .. " " .. (v == true and "on" or v == false and "off" or tostring(v))
      .. ((storage.f3d_bs or {})[k] == nil and "" or " (set)")
  end
  out[#out + 1] = "[Zenith] belt simulation switches: " .. table.concat(parts, ", ")
  return out
end

-- The client's belt item distance (`bfar` n), else the map setting: every belt within it is
-- simulated, whatever the client's Belt updates (`bfar` m) or its entity distance (the focus radius).
function M.wanted_radius()
  local s = storage.f3d
  if s.near_r then
    return s.near_r
  end
  if not O.full_area then
    return math.min(settings.global["f3d-detail-radius"].value, s.focus.r)
  end
  return settings.global["f3d-detail-radius"].value
end

-- area trace: the belts loaded are those traced from the near square (see M.OPTIONS).
function M.trace_on()
  return O.area == "trace"
end

-- The near square's half side now: trace_near, cut by the bound (bs.cut) while the work runs over.
function M.near_now()
  local n = floor(tonumber(O.trace_near) or 48)
  local b = storage.f3d.bs
  if b and b.cut and b.cut < n then
    return b.cut
  end
  return math.max(1, n)
end

-- What the trace depends on besides the near square (a scan is made again when it changes).
function M.trace_key()
  return floor(tonumber(O.trace_hops) or 0) * 100000 + floor(tonumber(O.trace_down) or 0)
end

function M.cap(max_items)
  if O.full_area then
    return math.huge
  end
  local c = storage.f3d.bi_cap or max_items
  if c < 0 then
    return math.huge
  end
  return c
end

function M.bound_units(bound_override)
  if bound_override then
    return bound_override
  end
  local share = tonumber(O.bound) or BOUND_SHARE
  if share <= 0 then
    return math.huge
  end
  -- (A share of the budget, but never of less than its default: Hold 60 UPS shrinks the budget while
  -- the game runs slow, which cut the square to 16 tiles on Zenith Test at 57-59 UPS; the update rate
  -- levels it takes lower the belts' work a tick first.)
  return math.max(1000, floor(math.max(budget.limit(), budget.DEFAULT) * share * UNITS_PER_BUDGET_UNIT))
end

function M.radius()
  local r = M.wanted_radius()
  local b = storage.f3d.bs
  -- (area trace: the bound cuts the near square, not the scan's; near_now.)
  if b and b.cut and b.cut < r and not M.trace_on() then
    return b.cut
  end
  return r
end

-- On an update's tick: the update's work a tick against the bound; the square cut or grown.
function M.bound(b, units, period, loading, bs)
  local cost = units / math.max(1, period)
  b.cost = b.cost and b.cost + (cost - b.cost) * 0.5 or cost
  if loading then
    b.over, b.under = 0, 0
    return
  end
  local cap = M.bound_units(bs.bound)
  b.over = b.cost > cap and (b.over or 0) + 1 or 0
  b.under = b.cost < cap * BOUND_ROOM and (b.under or 0) + 1 or 0
  -- (area trace: the near square is what is cut and grown; the belts traced from it follow.)
  local want = M.trace_on() and math.max(1, floor(tonumber(O.trace_near) or 48)) or M.wanted_radius()
  local cur = math.min(b.cut or want, want)
  if b.over >= BOUND_OVER and cur > bs.bound_min then
    b.cut = math.max(bs.bound_min, floor(cur * BOUND_CUT))
    b.over, b.under = 0, 0
    bs.counts.cuts = (bs.counts.cuts or 0) + 1
  elseif b.under >= BOUND_UNDER and b.cut then
    local grown = cur + math.max(8, floor(cur * (1 - BOUND_CUT)))
    b.cut = grown < want and grown or nil
    b.over, b.under = 0, 0
  end
end

-- The rate.lua job the updates' ticks follow (M.OPTIONS own_rate): their own, `bs`, or the glided
-- belt items', `bi`, as before.
function M.rate_job()
  return O.own_rate and "bs" or "bi"
end

-- The longest period the updates are stretched to (period_max), for their own job only.
function M.rate_cap()
  if O.own_rate then
    return floor(tonumber(O.period_max) or 0)
  end
  return nil
end

return M
