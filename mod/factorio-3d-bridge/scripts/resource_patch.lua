-- Factorio's map view shows a resource patch under the mouse as one (owner's L6: "I can't mouse over and
-- see resource deposits"): the patch outlined in white and its total, an ore's amount summed, an infinite
-- resource's (crude oil's) yields added up ("Crude oil combined yield 1234%"). ResourceEntityPrototype's
-- resource_patch_search_radius says how far apart resources of one kind may lie and still count as one
-- patch (3 tiles; crude oil 12, Space Age's vents 16).
--
-- `rpatch` {q, x, y (1/256 tiles), si?}, queued under the work budget (requests.lua): the force's charted
-- resource there and the rest of its patch, found tile by tile from it (every tile within the search
-- radius of one already in, a chunk's resources read once each), at most MAX_TILES of them. Answered with
-- `rpatch` {q, n (its name), a (the amounts summed), c (how many), y? (an infinite one's yields summed, in
-- percent of its normal amount), more? (1: stopped at MAX_TILES), o: the tiles its entities cover as rows
-- [y, x, length, x, length, ...]} or {q} for none. Reads only.

local transport = require("scripts.transport")
local puppet = require("scripts.puppet")
local world = require("scripts.world")

local M = {}

-- In 2.1.24 a patch's tiles cost about 5 microseconds each (711 of iron ore 3.7 ms, 318 of uranium 1.6 ms),
-- all in the tick the ask is answered in: a bigger patch is summed to this many and said to be more.
M.MAX_TILES = 10000
-- Rows of the outline at most (a patch's tiles past them are summed, not drawn).
local MAX_ROWS = 600
-- Numbers in the outline at most, so the answer stays well inside one datagram.
local MAX_NUMBERS = 6000

local function surface_of(cmd, c)
  local si = tonumber(cmd and cmd.si)
  local surface = si and game.get_surface(math.floor(si))
  return surface or (c and c.surface) or world.surface()
end

-- A tile's key: x and y kept apart in one number (2^21 tiles either way of the origin).
local SPAN = 4194304
local HALF = 2097152

local function key(x, y)
  return (x + HALF) * SPAN + (y + HALF)
end

function M.answer(cmd)
  local q = math.floor(tonumber(cmd.q) or 0)
  local c = puppet.get()
  local x, y = tonumber(cmd.x), tonumber(cmd.y)
  local msg = c and x and y and M.patch(surface_of(cmd, c), c.force, x / 256, y / 256) or {}
  msg.t, msg.q = "rpatch", q
  transport.send_now(msg)
end

-- The patch at (px, py) tiles on `surface` that `force` has charted: {n, a, c, y?, more?, o}, or nil.
function M.patch(surface, force, px, py)
  local found = surface.find_entities_filtered({ position = { px, py }, type = "resource" })
  if #found == 0 then
    found = surface.find_entities_filtered({ area = { { px - 0.5, py - 0.5 }, { px + 0.5, py + 0.5 } }, type = "resource" })
  end
  local start = found[1]
  local function charted(cx, cy)
    local ok, v = pcall(function() return force.is_chunk_charted(surface, { cx, cy }) end)
    return ok and v
  end
  if not (start and start.valid and charted(math.floor(start.position.x / 32), math.floor(start.position.y / 32))) then
    return nil
  end
  local name = start.name
  local proto = start.prototype
  local radius = math.max(1, math.floor(proto.resource_patch_search_radius or 3))
  local infinite = proto.infinite_resource
  local normal = proto.normal_resource_amount or 1
  if not (normal and normal > 0) then
    normal = 1
  end
  -- The tiles an entity covers (its collision box, a crude oil well three by three).
  local box = proto.collision_box
  local lx, ly = box.left_top.x, box.left_top.y
  local rx, ry = box.right_bottom.x, box.right_bottom.y

  local by_tile = {}   -- key -> entity, for the resources of this name read so far
  local chunks = {}    -- chunk key -> true once read
  local function load(cx, cy)
    local k = key(cx, cy)
    if chunks[k] then
      return
    end
    chunks[k] = true
    if not charted(cx, cy) then
      return
    end
    for _, e in pairs(surface.find_entities_filtered({ area = { { cx * 32, cy * 32 }, { cx * 32 + 32, cy * 32 + 32 } }, name = name })) do
      local p = e.position
      by_tile[key(math.floor(p.x), math.floor(p.y))] = e
    end
  end
  -- The chunks within r tiles of a tile, read (a tile's ring is looked up without a chunk check each).
  local function load_around(tx, ty, r)
    for cy = math.floor((ty - r) / 32), math.floor((ty + r) / 32) do
      for cx = math.floor((tx - r) / 32), math.floor((tx + r) / 32) do
        load(cx, cy)
      end
    end
  end
  local sx, sy = math.floor(start.position.x), math.floor(start.position.y)
  load(math.floor(sx / 32), math.floor(sy / 32))
  local queue = { sx, sy }
  local seen = { [key(sx, sy)] = true }
  local head = 1
  local total, count, yield = 0, 0, 0
  local more = false
  local cover = {}     -- y -> {x -> true}
  local rows = 0
  while head < #queue do
    local tx, ty = queue[head], queue[head + 1]
    head = head + 2
    local e = by_tile[key(tx, ty)]
    if e and e.valid then
      local amount = e.amount
      total = total + amount
      count = count + 1
      if infinite then
        yield = yield + amount / normal
      end
      local p = e.position
      for cyy = math.floor(p.y + ly + 0.01), math.floor(p.y + ry - 0.01) do
        local row = cover[cyy]
        if not row then
          if rows < MAX_ROWS then
            row = {}
            cover[cyy] = row
            rows = rows + 1
          end
        end
        if row then
          for cxx = math.floor(p.x + lx + 0.01), math.floor(p.x + rx - 0.01) do
            row[cxx] = true
          end
        end
      end
      if count >= M.MAX_TILES then
        more = true
        break
      end
      -- Inside a patch every neighbour is ore and the search radius finds nothing they don't: the wider
      -- ring only for tiles at its edge.
      load_around(tx, ty, 1)
      local inside = true
      for dy = -1, 1 do
        for dx = -1, 1 do
          if inside and (dx ~= 0 or dy ~= 0) and not by_tile[key(tx + dx, ty + dy)] then
            inside = false
          end
        end
      end
      local r = inside and 1 or radius
      if r > 1 then
        load_around(tx, ty, r)
      end
      for dy = -r, r do
        for dx = -r, r do
          local nx, ny = tx + dx, ty + dy
          local k = key(nx, ny)
          if not seen[k] then
            if by_tile[k] then
              seen[k] = true
              queue[#queue + 1] = nx
              queue[#queue + 1] = ny
            end
          end
        end
      end
    end
  end
  -- The covered tiles as runs a row, top to bottom.
  local ys = {}
  for ty in pairs(cover) do
    ys[#ys + 1] = ty
  end
  table.sort(ys)
  local outline = {}
  local numbers = 0
  for _, ty in ipairs(ys) do
    if numbers > MAX_NUMBERS then
      break
    end
    local xs = {}
    for tx in pairs(cover[ty]) do
      xs[#xs + 1] = tx
    end
    table.sort(xs)
    local row = { ty }
    local i = 1
    while i <= #xs do
      local j = i
      while j < #xs and xs[j + 1] == xs[j] + 1 do
        j = j + 1
      end
      row[#row + 1] = xs[i]
      row[#row + 1] = j - i + 1
      i = j + 1
    end
    outline[#outline + 1] = row
    numbers = numbers + #row
  end
  local msg = { n = name, a = math.floor(total + 0.5), c = count, o = outline }
  if infinite then
    msg.y = math.floor(yield * 100 + 0.5)
  end
  if more then
    msg.more = 1
  end
  return msg
end

return M
