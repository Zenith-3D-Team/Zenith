-- The graphics list (data-final-fixes.lua, scripts/gfx_extract.lua) for the client: the welcome
-- says its fingerprint and how many parts it has, and a client that has no copy for that
-- fingerprint asks (`gfx` {fp, need?}); the parts then go out a few a tick under the work budget
-- (budget.lua), unreliably, as text written at the data stage (transport.send_text): the client asks
-- again for the parts it missed. A second visit to the same modpack sends nothing.
--
-- The list itself is prototype data (prototypes.mod_data), the same on every peer; what is queued
-- lives in storage.f3d.gfx and changes only from packets and on_tick.

local budget = require("scripts.budget")
local transport = require("scripts.transport")

local M = {}

local NAME = "zenith-graphics"
local PRICE = 60  -- units a part (about 30 KB of text: one datagram)
local SHARE = 0.5

local function list()
  local all = prototypes.mod_data
  local ok, p = pcall(function() return all[NAME] end)
  return ok and p or nil
end

-- {fp, n} of the list, or nil when the data stage made none.
function M.info()
  local p = list()
  if not p then
    return nil
  end
  local ok, fp = pcall(p.get, "fp")
  local _, n = pcall(p.get, "n")
  if not ok or type(fp) ~= "string" or type(n) ~= "number" or n < 1 then
    return nil
  end
  return { fp = fp, n = n }
end

-- The welcome's fields: the game's mods and versions, and the list's fingerprint and parts.
function M.welcome_fields(msg)
  msg.mods = script.active_mods
  local info = M.info()
  if info then
    msg.gf = info.fp
    msg.gn = info.n
  end
  return msg
end

-- `gfx` {fp, need?}: the parts of the list with that fingerprint (all, or the numbers in need).
function M.ask(cmd)
  local info = M.info()
  if not info or cmd.fp ~= info.fp then
    return
  end
  local want = {}
  if type(cmd.need) == "table" and #cmd.need > 0 then
    for _, i in ipairs(cmd.need) do
      i = tonumber(i)
      if i and i >= 1 and i <= info.n and i % 1 == 0 then
        want[#want + 1] = i
      end
      if #want >= info.n then
        break
      end
    end
  else
    for i = 1, info.n do
      want[i] = i
    end
  end
  if #want > 0 then
    storage.f3d.gfx = { fp = info.fp, n = info.n, l = want, at = 1 }
  end
end

function M.length()
  local q = storage.f3d.gfx
  return q and (#q.l - q.at + 1) or 0
end

budget.register_queue("gfx", M.length)

function M.reset()
  storage.f3d.gfx = nil
end

function M.tick()
  local q = storage.f3d.gfx
  if not q then
    return
  end
  local p = list()
  -- (A queue saved with other mods than the game now has: its parts would be the new list's under
  -- the old list's fingerprint, which the client keeps. The prototypes are the same on every peer.)
  local info = p and M.info()
  if not (info and info.fp == q.fp) then
    storage.f3d.gfx = nil
    return
  end
  while q.at <= #q.l and budget.can(PRICE, "gfx", SHARE) do
    budget.spend(PRICE, "gfx")
    local i = q.l[q.at]
    q.at = q.at + 1
    local ok, text = pcall(p.get, "p" .. i)
    if ok and type(text) == "string" then
      transport.send_text("gfx", ',"fp":"' .. q.fp .. '","part":' .. i .. ',"parts":' .. q.n .. ',"d":' .. text)
    end
  end
  if q.at > #q.l then
    storage.f3d.gfx = nil
  end
end

return M
