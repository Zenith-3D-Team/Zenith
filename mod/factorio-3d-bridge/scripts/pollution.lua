-- Pollution round the client's focus (`pol`), so the client can draw what Factorio's pollution does
-- to the land: trees greying and losing their leaves, lakes turning green, a smog over the worst of
-- it. One number a chunk (`surface.get_pollution`), a square of chunks round the focus, every few
-- seconds: pollution spreads and changes slowly, and a read is a lookup per chunk, so this is cheap.
-- Nothing on a space platform or with pollution switched off in the map settings: the client clears
-- it then.
--
-- Read-only: what this keeps in `storage` (rate.lua's schedule, the budget's learned cost) is written
-- only in on_tick from what the game has, so it is safe in multiplayer.

local transport = require("scripts.transport")
local world = require("scripts.world")
local rate = require("scripts.rate")
local map = require("scripts.map")
local puppet = require("scripts.puppet")

local M = {}

local INTERVAL = 300
local MOVE_INTERVAL = 30
local MOVE_CHUNKS = 4
-- Chunks either side of the focus' chunk: covers up to view_radius + 4 margin (max ±24 chunks),
-- keeping live pollution synchronized beyond full-detail chunk loading.
local MOST_CHUNKS = 24
local SWEEP_INTERVAL = 60
local SWEEP_BATCH = 96
local MAX_SPARSE = 80
-- Factorio's default for map_settings.pollution.min_pollution_to_damage_trees.
local DEFAULT_DAMAGE = 60

local function settings()
  local ok, p = pcall(function() return game.map_settings.pollution end)
  if not ok or not p then
    return true, DEFAULT_DAMAGE
  end
  local okd, md = pcall(function() return p.min_pollution_to_damage_trees end)
  return p.enabled ~= false, okd and tonumber(md) or DEFAULT_DAMAGE
end

function M.reset()
  local s = storage.f3d
  if not s then
    return
  end
  s.pol_last = nil
  s.pol_sweep = nil
end

local function in_square(cx, cy, sq)
  if not sq or (sq.w or 0) <= 0 then
    return false
  end
  return cx >= sq.cx and cx < sq.cx + sq.w and cy >= sq.cy and cy < sq.cy + sq.w
end

local function sweep_charted(surface, damage, last_sq)
  local s = storage.f3d
  local si = surface.index
  local sw = s.pol_sweep
  if not sw or sw.si ~= si then
    sw = { si = si, next_tick = 0, list = nil, idx = 1, sent = {} }
    s.pol_sweep = sw
  end
  if game.tick < (sw.next_tick or 0) then
    return
  end
  sw.next_tick = game.tick + SWEEP_INTERVAL * math.max(1, rate.factor("pol"))
  local c = puppet.get()
  local force = (c and c.force) or (game.forces and game.forces.player)
  if not sw.list or sw.idx > #sw.list then
    local list = {}
    local okc, iter = pcall(surface.get_chunks)
    if okc and iter then
      for ch in iter do
        if not force or map.chunk_charted(surface, force, ch.x, ch.y) then
          list[#list + 1] = { ch.x, ch.y }
        end
      end
    end
    sw.list = list
    sw.idx = 1
  end
  local list = sw.list
  local total = #list
  if total == 0 then
    return
  end
  local sparse = {}
  local sent = sw.sent
  local limit = math.min(total, sw.idx + SWEEP_BATCH - 1)
  local idx = sw.idx
  while idx <= limit do
    local ch = list[idx]
    local x, y = ch[1], ch[2]
    idx = idx + 1
    if not in_square(x, y, last_sq) then
      local okv, raw = pcall(surface.get_pollution, { x * 32 + 16, y * 32 + 16 })
      local v = (okv and raw) and math.floor(raw + 0.5) or 0
      local key = x .. "," .. y
      local prev = sent[key] or 0
      if v >= 1 then
        sparse[#sparse + 1] = x
        sparse[#sparse + 1] = y
        sparse[#sparse + 1] = v
        sent[key] = v
        if #sparse >= MAX_SPARSE * 3 then
          break
        end
      elseif prev > 0 then
        sparse[#sparse + 1] = x
        sparse[#sparse + 1] = y
        sparse[#sparse + 1] = 0
        sent[key] = nil
        if #sparse >= MAX_SPARSE * 3 then
          break
        end
      end
    end
  end
  sw.idx = idx
  if #sparse > 0 then
    transport.send_now({ t = "pols", si = si, md = math.floor(damage + 0.5), l = sparse })
  end
end

function M.tick()
  local s = storage.f3d
  local f = s.focus
  local surface = world.surface()
  local okp, platform = pcall(function() return surface.platform end)
  -- Only Nauvis' kind of pollution greys trees and greens lakes: Gleba's spores are another
  -- pollutant (2.0's LuaSurface.pollutant_type), and Vulcanus, Fulgora and Aquilo have none.
  local okt, kind = pcall(function()
    local k = surface.pollutant_type
    return k and k.name
  end)
  local other = okt and kind ~= nil and kind ~= "pollution"
  local enabled, damage = settings()
  local disabled = f.r <= 0 or (okp and platform) or other or not enabled

  local fx, fy = math.floor(f.x / 32), math.floor(f.y / 32)
  local last = s.pol_last
  local due = rate.due("pol", INTERVAL)
  local prompt = false
  if not due and f.r > 0 and not disabled then
    if not last or last.si ~= surface.index then
      prompt = true
    elseif math.max(math.abs(fx - last.fx), math.abs(fy - last.fy)) >= MOVE_CHUNKS
        and game.tick - last.tick >= MOVE_INTERVAL then
      prompt = true
    end
  end

  if due or prompt then
    if disabled then
      rate.read("pol", 0)
      s.pol_sweep = nil
      s.pol_last = { tick = game.tick, fx = fx, fy = fy, cx = 0, cy = 0, w = 0, si = surface.index }
      if due or (last and (last.w or 0) > 0) then
        transport.send_now({ t = "pol", si = surface.index, w = 0 })
      end
      return
    end
    local sub_r = s.sub_r or 10
    local n = math.min(MOST_CHUNKS, math.max(math.ceil(f.r / 32) + 2, sub_r + 4))
    local cx, cy = fx - n, fy - n
    local w = 2 * n + 1
    local l, any = {}, false
    for j = 0, w - 1 do
      local y = (cy + j) * 32 + 16
      for i = 0, w - 1 do
        local v = math.floor(surface.get_pollution({ (cx + i) * 32 + 16, y }) + 0.5)
        if v > 0 then
          any = true
        end
        l[#l + 1] = v
      end
    end
    rate.read("pol", w * w)
    s.pol_last = { tick = game.tick, fx = fx, fy = fy, cx = cx, cy = cy, w = any and w or 0, si = surface.index }
    if not any then
      transport.send_now({ t = "pol", si = surface.index, w = 0 })
    else
      transport.send_now({ t = "pol", si = surface.index, cx = cx, cy = cy, w = w, l = l, md = math.floor(damage + 0.5) })
    end
  elseif disabled then
    s.pol_sweep = nil
  end

  if not disabled then
    sweep_charted(surface, damage, s.pol_last)
  end
end

return M
