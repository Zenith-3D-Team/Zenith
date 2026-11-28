-- Rail signal block lookup for junction/crossing tracks: given a list of rail unit numbers
-- (`rblk`), returns each rail's Factorio block id (`[[unit, block_id], ...]`) using the engine's
-- rail segment and block APIs. Simple straight/unbranched runs are solved client-side with zero
-- bridge traffic; the client only sends `rblk` for junctions or crossings.

local puppet = require("scripts.puppet")
local transport = require("scripts.transport")
local budget = require("scripts.budget")

local M = {}

local MAX_UNITS = 128
local SEARCH_RADIUS = 96
-- (S1) One query's walk is bounded: an unsignalled network is one block of thousands of rails.
-- A group takes in at most MAX_GROUP rails, a query explores at most MAX_STEPS segments (one
-- get_rail_segment_rails call marks its whole segment seen) and makes at most MAX_CALLS engine
-- calls, and each segment step is paid from the tick's budget like the other scans. Rails left
-- unsolved are left out of the answer; the client asks again for those after its cooldown.
M.MAX_GROUP = 512
M.MAX_STEPS = 64
M.MAX_CALLS = 2048
local STEP_PRICE = 4
M.counts = { calls = 0, steps = 0 }

local ALL_RAIL_TYPES = {
  "straight-rail", "half-diagonal-rail", "curved-rail-a", "curved-rail-b",
  "legacy-straight-rail", "legacy-curved-rail",
  "elevated-straight-rail", "elevated-half-diagonal-rail", "elevated-curved-rail-a", "elevated-curved-rail-b",
  "rail-ramp",
}

local cached_rail_types
local cached_rail_set

local function rail_types()
  if cached_rail_types then
    return cached_rail_types, cached_rail_set
  end
  local present = {}
  for _, proto in pairs(prototypes.entity) do
    present[proto.type] = true
  end
  local list, set = {}, {}
  for _, t in ipairs(ALL_RAIL_TYPES) do
    if present[t] then
      list[#list + 1] = t
      set[t] = true
    end
  end
  cached_rail_types = list
  cached_rail_set = set
  return list, set
end

local function try_call(fn, ...)
  local ok, res = pcall(fn, ...)
  if ok then
    return res
  end
  return nil
end

local function rail_directions()
  local dirs = {}
  local ok, rd = pcall(function() return defines.rail_direction end)
  if ok and type(rd) == "table" then
    if rd.front ~= nil then
      dirs[#dirs + 1] = rd.front
    end
    if rd.back ~= nil then
      dirs[#dirs + 1] = rd.back
    end
  end
  return dirs
end

local function segment_rails(rail, dirs)
  local out = {}
  if #dirs > 0 then
    for _, d in ipairs(dirs) do
      local list = try_call(function() return rail.get_rail_segment_rails(d) end)
      if type(list) == "table" then
        for _, r in pairs(list) do
          out[#out + 1] = r
        end
      end
    end
  end
  if #out == 0 then
    local list = try_call(function() return rail.get_rail_segment_rails() end)
    if type(list) == "table" then
      for _, r in pairs(list) do
        out[#out + 1] = r
      end
    end
  end
  return out
end

local function segment_overlaps(rail, dirs)
  local out = {}
  if #dirs > 0 then
    for _, d in ipairs(dirs) do
      local list = try_call(function() return rail.get_rail_segment_overlaps(d) end)
      if type(list) == "table" then
        for _, r in pairs(list) do
          out[#out + 1] = r
        end
      end
    end
  end
  if #out == 0 then
    local list = try_call(function() return rail.get_rail_segment_overlaps() end)
    if type(list) == "table" then
      for _, r in pairs(list) do
        out[#out + 1] = r
      end
    end
  end
  return out
end

local function same_block(a, b)
  local ok, res = pcall(function() return a.is_rail_in_same_rail_block_as(b) end)
  if ok then
    return res == true
  end
  return nil
end

local function find_rails(surface, s, c, wanted, missing_count)
  local by_unit = {}
  local types, type_set = rail_types()
  if #types == 0 or missing_count == 0 then
    return by_unit
  end

  local function collect_area(x0, y0, x1, y1)
    if missing_count <= 0 then
      return
    end
    local ok, list = pcall(surface.find_entities_filtered, {
      area = { { x0, y0 }, { x1, y1 } },
      type = types,
    })
    if not (ok and type(list) == "table") then
      return
    end
    for _, e in pairs(list) do
      if e.valid and type_set[e.type] then
        local u = e.unit_number
        if u and wanted[u] and not by_unit[u] then
          by_unit[u] = e
          missing_count = missing_count - 1
          if missing_count <= 0 then
            return
          end
        end
      end
    end
  end

  for u in pairs(wanted) do
    local e = try_call(game.get_entity_by_unit_number, u)
    if e and e.valid and e.surface == surface and type_set[e.type] then
      by_unit[u] = e
      missing_count = missing_count - 1
    end
  end

  if missing_count > 0 and s.focus then
    local r = math.max(tonumber(s.focus.r) or 32, SEARCH_RADIUS)
    local fx, fy = tonumber(s.focus.x) or c.position.x, tonumber(s.focus.y) or c.position.y
    collect_area(fx - r, fy - r, fx + r, fy + r)
  end

  if missing_count > 0 then
    local cx, cy = c.position.x, c.position.y
    collect_area(cx - SEARCH_RADIUS, cy - SEARCH_RADIUS, cx + SEARCH_RADIUS, cy + SEARCH_RADIUS)
  end

  if missing_count > 0 and s.subs then
    for _, chunk in pairs(s.subs) do
      local x0, y0 = chunk[1] * 32, chunk[2] * 32
      collect_area(x0, y0, x0 + 32, y0 + 32)
      if missing_count <= 0 then
        break
      end
    end
  end

  return by_unit
end

-- { u = [rail_unit, ...] } -> sends { t = "rblk", b = [[unit, block_id], ...] }.
function M.query(cmd)
  local c = puppet.get()
  local s = storage.f3d
  if not (c and s) then
    return
  end
  local surface = puppet.surface(c)
  if not (surface and surface.valid) then
    return
  end
  local units, wanted = {}, {}
  local raw = type(cmd.u) == "table" and cmd.u or {}
  for _, v in ipairs(raw) do
    if #units >= MAX_UNITS then
      break
    end
    local u = tonumber(v)
    if u then
      u = math.floor(u)
      if u > 0 and not wanted[u] then
        wanted[u] = true
        units[#units + 1] = u
      end
    end
  end
  if #units == 0 then
    transport.send_now({ t = "rblk", b = {} })
    return
  end

  local by_unit = find_rails(surface, s, c, wanted, #units)
  local found_units = {}
  for u in pairs(by_unit) do
    found_units[#found_units + 1] = u
  end
  table.sort(found_units)

  local dirs = rail_directions()
  local block_of = {}
  local steps, calls = 0, 0
  local function spent()
    return steps >= M.MAX_STEPS or calls >= M.MAX_CALLS
  end
  -- One segment step: its rails (one call a direction), its overlaps, each overlap's block check.
  -- (rel-031-fix3) A query's first step always runs: rblk comes in the packet event, outside the
  -- tick's budget.begin(), so `used` may still be the previous tick's full total; without this a
  -- busy tick before it emptied every answer. That one step is paid (spend) like the others.
  local function can_step()
    return not spent() and (steps == 0 or budget.can(STEP_PRICE, "rblk", 0.25))
  end

  for _, seed_u in ipairs(found_units) do
    if not block_of[seed_u] then
      if not can_step() then
        break
      end
      local seed = by_unit[seed_u]
      local group, count = { [seed_u] = seed }, 1
      local explored = {}  -- rails whose segment was listed already
      local queue = { seed }
      local head = 1
      while head <= #queue and count < M.MAX_GROUP do
        local cur = queue[head]
        head = head + 1
        local cu = cur.valid and cur.unit_number
        if cu and not explored[cu] then
          if not can_step() then
            break
          end
          steps = steps + 1
          budget.spend(STEP_PRICE, "rblk")
          explored[cu] = true
          calls = calls + math.max(1, #dirs)
          for _, r in ipairs(segment_rails(cur, dirs)) do
            local u = r and r.valid and r.unit_number
            if u then
              explored[u] = true
              if not group[u] and count < M.MAX_GROUP then
                group[u] = r
                count = count + 1
              end
            end
          end
          calls = calls + math.max(1, #dirs)
          for _, ov in ipairs(segment_overlaps(cur, dirs)) do
            local u = ov and ov.valid and ov.unit_number
            if u and not group[u] and not explored[u] and count < M.MAX_GROUP and calls < M.MAX_CALLS then
              calls = calls + 1
              if same_block(cur, ov) == true then
                group[u] = ov
                count = count + 1
                queue[#queue + 1] = ov
              end
            end
          end
        end
      end
      -- The requested rails checked straight against the seed (same block is exact and transitive),
      -- in case no overlap led to them: once a group, not once a rail walked.
      for _, other_u in ipairs(found_units) do
        if calls >= M.MAX_CALLS then
          break
        end
        if not block_of[other_u] and not group[other_u] then
          calls = calls + 1
          if same_block(seed, by_unit[other_u]) == true then
            group[other_u] = by_unit[other_u]
          end
        end
      end
      local min_u = seed_u
      for gu in pairs(group) do
        if gu < min_u then
          min_u = gu
        end
      end
      for gu in pairs(group) do
        block_of[gu] = min_u
      end
    end
  end
  M.counts.calls = M.counts.calls + calls
  M.counts.steps = M.counts.steps + steps

  local out = {}
  for _, u in ipairs(units) do
    if block_of[u] then
      out[#out + 1] = { u, block_of[u] }
    end
  end
  transport.send_now({ t = "rblk", b = out })
end

return M
