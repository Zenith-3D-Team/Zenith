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

-- The planets whose prototype has lightning (Fulgora), which the runtime API can't tell: planets.lua
-- looks for lightning every 12 ticks only on those (the 0.2.1 hotfix: elsewhere it was a 3.4 ms search
-- of the focus square every 12 ticks for nothing). Without this list every surface is looked at as before.
local ok_planets, planets = pcall(function()
  local lightning = {}
  for name, planet in pairs(data.raw.planet or {}) do
    if type(planet) == "table" and planet.lightning_properties then
      lightning[#lightning + 1] = name
    end
  end
  table.sort(lightning)
  return { type = "mod-data", name = "zenith-planets", data_type = "zenith-planets", data = { lightning = lightning } }
end)
if ok_planets then
  data:extend({ planets })
else
  log("[factorio-3d-bridge] planet list not made: " .. tostring(planets))
end

-- Each minable entity's own mining_sound (J11), which the runtime API doesn't give: the sound Factorio
-- plays at each swing of the character's hand mining it. Kept as the file its first variation plays
-- with "__mod__/" made "mod/" and a variation's "-1.ogg" taken off ("base/sound/axe-mining-stone"), the
-- way the client finds a sound's variations in the player's install; ui_actions.lua sends it in
-- `eprops` (`ms`). Entities without one play Factorio's default: wood for trees, the ore sound else.
-- With them each entity's repair_sound (K13, `eprops` `rsd`), what a repair pack mending it plays.
local ok_mining, mining = pcall(function()
  return require("scripts.mining_sounds").prototype(data.raw)
end)
if ok_mining then
  data:extend({ mining })
else
  log("[factorio-3d-bridge] mining sound list not made: " .. tostring(mining))
end

-- The character's steps from the prototypes (step 5 task 3a): each tile's, rail's, resource's and
-- decorative's walking_sound, the belts' and heat pipes' utility sounds and armours' step sounds, which
-- the runtime API doesn't give. session.lua sends them as `steps` (scripts/step_sounds.lua). Its own
-- pcall: a fault here leaves the client's own table, and the other lists as they are.
local ok_steps, steps = pcall(function()
  return require("scripts.step_sounds").prototype(data.raw)
end)
if ok_steps then
  data:extend({ steps })
else
  log("[factorio-3d-bridge] step sound list not made: " .. tostring(steps))
end
