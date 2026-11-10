-- "Show in Zenith" as a button in the real game's top-left row of mod buttons (mod-gui's button flow,
-- where Informatron and the others put theirs), with Zenith's square gear logo: the same as Ctrl+F9
-- there (control.lua). Each player can hide it (map setting "Zenith button", per player).

local factorio_mod_gui = require("mod-gui")

local M = {}

M.NAME = "f3d-zenith-button"
M.SETTING = "f3d-zenith-button"

local function wanted(player)
  local ok, v = pcall(function() return player.mod_settings[M.SETTING].value end)
  return not ok or v ~= false
end

-- Adds or removes the player's button as their setting says.
function M.update(player)
  if not (player and player.valid) then
    return
  end
  local flow = factorio_mod_gui.get_button_flow(player)
  local button = flow[M.NAME]
  if wanted(player) then
    if not (button and button.valid) then
      flow.add({ type = "sprite-button", name = M.NAME, sprite = "f3d-zenith-gear",
        style = factorio_mod_gui.button_style, tooltip = { "f3d-launch.button" } })
    end
  elseif button and button.valid then
    button.destroy()
  end
end

function M.update_all()
  for _, player in pairs(game.players) do
    M.update(player)
  end
end

-- on_player_created, on_player_joined_game, on_runtime_mod_setting_changed (its own setting).
function M.on_player(event)
  if event.setting and event.setting ~= M.SETTING then
    return
  end
  if event.player_index then
    M.update(game.get_player(event.player_index))
  end
end

function M.is_button(element)
  return element and element.valid and element.name == M.NAME
end

return M
