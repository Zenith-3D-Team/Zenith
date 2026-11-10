-- Every prototype's graphics as file names and numbers, for Zenith to read from the mods' own files
-- (scripts/gfx_extract.lua, docs/MOD-GRAPHICS-PLAN.md). Runs after every mod's data and updates;
-- a mod that changes graphics in its own data-final-fixes after this one is missed. A failure here
-- only costs the list (the client falls back to its own indexes), never the game.
local ok, result = pcall(function()
  return require("scripts.gfx_extract").prototype(data.raw)
end)
if ok then
  data:extend({ result })
  log(string.format("[factorio-3d-bridge] graphics list: %d parts, %d bytes, fingerprint %s",
    result.data.n, result.data.b, result.data.fp))
else
  log("[factorio-3d-bridge] graphics list not made: " .. tostring(result))
end
