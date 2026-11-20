-- Fluid pipelines over Factorio's extent limit (owner's L11: a refinery sat starved behind a pipeline too
-- long, and nothing in Zenith said so). Factorio 2.x merges connected pipes, pipes to ground and storage
-- tanks into fluid segments; a segment whose extent box is wider or taller than the limit (UtilityConstants'
-- default_pipeline_extent, 320 tiles, unless a fluid box sets less) moves no fluid until a pump splits it.
-- Every entity of it then has the status pipeline_overextended (read in 2.1.24: all 331 pipes of a
-- 340-tile line), its entity info says "Pipeline overextended" and "Pipeline extent: 333/320", and the
-- alert bar has "Pipeline has been overextended." with Factorio's red fluid icon over one entity of it.
--
-- Which entity carries the icon isn't in the API. In the owner's video it stood on a pipe to ground about
-- 320 tiles in from the far end of the line, where a pump would split it into parts within the limit;
-- spot() picks the segment's entity nearest that line on each side past the limit.
--
-- Read-only, from prototypes and the game's state: the same on every peer.

local registry = require("scripts.registry")

local M = {}

-- The types whose entities report the status (its description: "Used by pipes, pipes to ground, and
-- storage tanks"), with the infinity pipe of the editor.
M.TYPES = { "pipe", "pipe-to-ground", "storage-tank", "infinity-pipe" }
M.SET = {}
for _, t in ipairs(M.TYPES) do
  M.SET[t] = true
end

-- How far either side of the line spot() looks for the segment's entities (a pipe to ground's jump).
local SPOT_SLACK = 12

local status_value
local limit_value
local present

-- defines.entity_status.pipeline_overextended, or false where the game hasn't got it.
function M.status()
  if status_value == nil then
    local ok, v = pcall(function() return defines.entity_status.pipeline_overextended end)
    status_value = ok and v or false
  end
  return status_value
end

-- The limit in tiles: UtilityConstants' default_pipeline_extent (320 in 2.1). A fluid box's own
-- max_pipeline_extent is data-stage only.
function M.limit()
  if not limit_value then
    local ok, v = pcall(function() return prototypes.utility_constants.default_pipeline_extent end)
    limit_value = ok and type(v) == "number" and v > 0 and v or 320
  end
  return limit_value
end

-- The pipe types this game has (find_entities_filtered refuses unknown ones).
function M.types()
  if not present then
    present = {}
    for _, t in ipairs(M.TYPES) do
      if registry.has_type(t) then
        present[#present + 1] = t
      end
    end
  end
  return present
end

function M.overextended(e)
  local st = M.status()
  return st and e.status == st or false
end

function M.segment(e)
  local ok, id = pcall(function() return e.get_fluid_segment_id(1) end)
  return ok and id or nil
end

-- The segment's extent box as left, top, right, bottom, or nil (no segment).
local function box(e)
  local ok, bb = pcall(function() return e.get_fluid_segment_extent_bounding_box(1) end)
  if not (ok and type(bb) == "table") then
    return nil
  end
  local lt, rb = bb.left_top or bb[1], bb.right_bottom or bb[2]
  if not (lt and rb) then
    return nil
  end
  return lt.x or lt[1], lt.y or lt[2], rb.x or rb[1], rb.y or rb[2]
end

-- The pipeline's extent in tiles (its box's longer side, whole tiles as Factorio counts them: a lone pipe
-- 1, a line of 340 pipes 340), or nil.
function M.extent(e)
  local l, t, r, b = box(e)
  if not l then
    return nil
  end
  return math.max(1, math.ceil(math.max(r - l, b - t) - 0.01))
end

-- The entity of e's overextended segment its alert is about (see the header); e itself when the segment
-- isn't over the limit or none is found.
function M.spot(e)
  local l, t, r, b = box(e)
  local limit = M.limit()
  if not l then
    return e
  end
  local area, along, cut
  if r - l > limit then
    cut, along = r - limit, "x"
    area = { { cut - SPOT_SLACK, t - 1 }, { cut + SPOT_SLACK, b + 1 } }
  elseif b - t > limit then
    cut, along = b - limit, "y"
    area = { { l - 1, cut - SPOT_SLACK }, { r + 1, cut + SPOT_SLACK } }
  else
    return e
  end
  local seg = M.segment(e)
  local best, best_d = e, math.huge
  local found = e.surface.find_entities_filtered({ area = area, type = M.types(), force = e.force })
  for _, o in pairs(found) do
    if M.segment(o) == seg then
      local p = o.position
      local d = math.abs((along == "x" and p.x or p.y) - cut)
      if d < best_d then
        best, best_d = o, d
      end
    end
  end
  return best
end

return M
