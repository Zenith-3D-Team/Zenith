-- The Factorio side of Zenith's Sprint add-on (addons-src/sprint). The add-on sends {on = true}
-- on the channel "zenith-sprint" while its key is held (again every half second) and {on = false}
-- when it is let go; this mod adds its own bonus to that client's character's running speed and
-- takes it off again on "off", when the character is gone, or when nothing was heard for TIMEOUT
-- ticks (a lost message, a Zenith that crashed).
--
-- As every mod that talks to Zenith must: the bridge's event id comes from it in on_init and
-- on_load (it isn't saved), the handlers are registered whenever the bridge is there, the game
-- changes only in the event and on_nth_tick, and every field of a message is checked (a message is
-- input from that client's player and no more trusted than that).

local CHANNEL = "zenith-sprint"
local TIMEOUT = 90

local function bridge()
  local z = remote.interfaces["zenith"]
  return z and z.on_message and z.character
end

-- Takes the bonus off one character: only what this mod added, so other mods' changes stay.
local function stop(unit)
  local s = storage.sprints[unit]
  storage.sprints[unit] = nil
  if s and s.entity.valid then
    s.entity.character_running_speed_modifier = s.entity.character_running_speed_modifier - s.bonus
  end
end

local function on_message(e)
  if e.channel ~= CHANNEL or type(e.data) ~= "table" or type(e.data.on) ~= "boolean" then
    return
  end
  local c = remote.call("zenith", "character", e.client)
  if not (c and c.valid and c.type == "character" and c.unit_number) then
    return
  end
  local unit = c.unit_number
  if not e.data.on then
    stop(unit)
    return
  end
  local s = storage.sprints[unit]
  if not s then
    local bonus = settings.global["zenith-sprint-bonus"].value
    c.character_running_speed_modifier = c.character_running_speed_modifier + bonus
    s = { entity = c, bonus = bonus }
    storage.sprints[unit] = s
  end
  s.ends = game.tick + TIMEOUT
end

local function register()
  if bridge() then
    script.on_event(remote.call("zenith", "on_message"), on_message)
  end
end

script.on_init(function()
  storage.sprints = {}
  register()
end)
script.on_load(register)
script.on_configuration_changed(function()
  storage.sprints = storage.sprints or {}
end)

-- Always registered (the same on every peer), whether anyone sprints or not.
script.on_nth_tick(15, function()
  for unit, s in pairs(storage.sprints) do
    if not s.entity.valid or game.tick >= s.ends then
      stop(unit)
    end
  end
end)
