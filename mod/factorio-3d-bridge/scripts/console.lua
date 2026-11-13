-- The client's console: the console commands the bridge runs for the character it plays (`cmd`,
-- answered with `cmdr`), and the `zenith` remote interface that the client's Lua commands over
-- RCON use for `game.player` (RCON has no player of its own).
--
-- Lua itself never runs from a packet: anything on localhost can send UDP, and /c is for admins.
-- Lua commands go over RCON (a password) or into Factorio itself (Ctrl+F9).

local transport = require("scripts.transport")
local puppet = require("scripts.puppet")
local platforms = require("scripts.platforms")

local M = {}

-- Commands of the mod's own (/f3d-status...), filled in by session.lua: name -> fn(cmd).
M.extra = {}
-- While a command runs for the client, session.reply adds its lines here instead of printing.
M.capture = nil
-- The player whose machine the packet being handled came in on (on_udp_packet_received's
-- player_index, set by session.on_packet for each packet), 0 for the server itself. Event data, so
-- the same on every peer.
M.from_player = 0

-- In a multiplayer game console commands are for admins (owner's rule), from Zenith's console
-- (`cmd`) and the mod's own commands in Factorio's (control.lua). What counts is who sent it: a
-- packet that came in on a player's machine (or a command typed by a player) is that player's, and
-- they must be an admin. A packet that came in on the server itself (a Zenith beside a headless
-- server, whatever character it plays) is from the server's own machine, whose console and RCON
-- are its owner's anyway.
function M.allowed(player_index)
  local idx = tonumber(player_index) or 0
  if idx == 0 or not game.is_multiplayer() then
    return true
  end
  local p = game.get_player(idx)
  return p ~= nil and p.admin == true
end

-- The kit /cheat all gives the bridge's character. Factorio's own kit is chosen inside the
-- engine and isn't listed anywhere the mod can read, so this one is ours: armour, its equipment
-- and robots to fill it.
local CHEAT_KIT = {
  { "power-armor-mk2", 1 }, { "fusion-reactor-equipment", 2 }, { "exoskeleton-equipment", 4 },
  { "personal-roboport-mk2-equipment", 2 }, { "battery-mk2-equipment", 2 }, { "energy-shield-mk2-equipment", 2 },
  { "personal-laser-defense-equipment", 2 }, { "construction-robot", 50 }, { "night-vision-equipment", 1 },
}

local function words_of(text)
  local w = {}
  for word in string.gmatch(text or "", "%S+") do
    w[#w + 1] = word
  end
  return w
end

-- The LuaPlayer whose character the client plays, if any: the owner while connected, the player
-- in single-player. The bridge's own character on a new map (or a stand-in while the owner is
-- away) has none.
function M.player()
  local c = puppet.get()
  return c and puppet.player_of(c) or nil
end

-- The name the console calls the character by: its player's, the player it stands in for, or nil.
local function name_of(c)
  local p = c and puppet.player_of(c) or puppet.held_for()
  return p and p.name or nil
end

---------------------------------------------------------------------------------------------
-- The commands

local commands = {}

local function seconds_text(ticks)
  local s = math.floor(ticks / 60)
  local parts = {}
  local units = { { 86400, "day" }, { 3600, "hour" }, { 60, "minute" }, { 1, "second" } }
  for _, u in ipairs(units) do
    local n = math.floor(s / u[1])
    s = s - n * u[1]
    if n > 0 then
      parts[#parts + 1] = n .. " " .. u[2] .. (n == 1 and "" or "s")
    end
  end
  if #parts == 0 then
    return "0 seconds"
  end
  if #parts == 1 then
    return parts[1]
  end
  return table.concat(parts, ", ", 1, #parts - 1) .. " and " .. parts[#parts]
end

function commands.version()
  return { tostring(script.active_mods["base"] or "?") }
end

function commands.seed()
  local nauvis = game.surfaces["nauvis"] or game.surfaces[1]
  return { tostring(nauvis.map_gen_settings.seed) }
end

function commands.time()
  return { seconds_text(game.ticks_played) }
end

-- Factorio's line: "[planet=nauvis] Nauvis - Evolution factor: 0.0001. (Time 100%) ...", each
-- part's share of the factor.
function commands.evolution(words)
  local c = puppet.get()
  local surface = words[1] and game.surfaces[words[1]] or (c and c.surface) or game.surfaces[1]
  if not surface then
    return { "No surface " .. tostring(words[1]) }
  end
  local enemy = game.forces["enemy"]
  local ok, factor, t, p, k = pcall(function()
    return enemy.get_evolution_factor(surface), enemy.get_evolution_factor_by_time(surface),
      enemy.get_evolution_factor_by_pollution(surface), enemy.get_evolution_factor_by_killing_spawners(surface)
  end)
  if not ok then
    return { "No evolution on " .. surface.name }
  end
  local sum = t + p + k
  local function share(x)
    return string.format("%d%%", sum > 0 and math.floor(x / sum * 100 + 0.5) or 0)
  end
  local okp, lp = pcall(function() return surface.planet end)
  local planet = okp and lp and string.format("[planet=%s] ", lp.name) or ""
  -- Factorio writes the planet's locale name, which the mod can't read as text; for the five
  -- planets it is their name with a capital.
  local name = okp and lp and (surface.name:sub(1, 1):upper() .. surface.name:sub(2)) or surface.name
  return { string.format("%s%s - Evolution factor: %.4f. (Time %s) (Pollution %s) (Spawner kills %s)",
    planet, name, factor, share(t), share(p), share(k)) }
end

function commands.players(words)
  local only_online = words[1] == "online" or words[1] == "o"
  local list = {}
  for _, p in pairs(game.players) do
    if p.connected or not only_online then
      list[#list + 1] = "  " .. p.name .. (p.connected and " (online)" or "")
    end
  end
  local lines = { string.format("Players (%d):", #list) }
  if words[1] == "count" or words[1] == "c" then
    return lines
  end
  for _, l in ipairs(list) do
    lines[#lines + 1] = l
  end
  return lines
end

function commands.admins(words)
  local only_online = words[1] == "online" or words[1] == "o"
  local lines = {}
  for _, p in pairs(game.players) do
    if p.admin and (p.connected or not only_online) then
      lines[#lines + 1] = "  " .. p.name .. (p.connected and " (online)" or "")
    end
  end
  table.insert(lines, 1, string.format("Admins (%d):", #lines))
  return lines
end

-- A save holds the game still for everyone (seconds on a big base), and anything on localhost can
-- send this: one a minute at most.
local SAVE_EVERY = 3600

commands["server-save"] = function()
  if not game.is_multiplayer() then
    return { "Only a multiplayer game saves on the server" }
  end
  local last = storage.f3d_server_save
  if last and game.tick - last < SAVE_EVERY then
    return { string.format("Saved %d seconds ago: once a minute at most from here", math.floor((game.tick - last) / 60)) }
  end
  storage.f3d_server_save = game.tick
  game.server_save()
  return { "Saving the map on the server" }
end

-- Factorio's /cheat for the character the bridge plays: research everything and cheat mode
-- (a player's setting: only when a player plays the character); `all` also gives a kit;
-- `off` ends cheat mode; a planet or platform name moves the character there.
function commands.cheat(words)
  local c = puppet.get()
  if not c then
    return { "No character to cheat for" }
  end
  local arg = words[1]
  local player = M.player() or puppet.held_for()
  if arg == "off" then
    if not player then
      return { "The bridge's own character has no cheat mode to turn off" }
    end
    player.cheat_mode = false
    return { "Cheat mode off" }
  end
  if arg and arg ~= "all" then
    local planet = game.planets and game.planets[arg]
    local ok, err
    if planet then
      ok, err = platforms.descend(c, arg)
    else
      local p = platforms.by_name(c.force, arg)
      if not p then
        return { "No planet or platform called " .. arg }
      end
      ok, err = platforms.board(c, p)
    end
    return { ok and ("Moved to " .. arg) or err }
  end
  c.force.research_all_technologies()
  local lines = { "Researched every technology" }
  if player then
    player.cheat_mode = true
    lines[#lines + 1] = "Cheat mode on for " .. player.name
  else
    lines[#lines + 1] = "Cheat mode is a player's: the bridge's own character has none, so crafting still takes time"
  end
  if arg == "all" then
    local given = 0
    for _, kit in ipairs(CHEAT_KIT) do
      if prototypes.item[kit[1]] then
        given = given + c.insert({ name = kit[1], count = kit[2] })
      end
    end
    lines[#lines + 1] = string.format("Gave the character %d items: power armour MK2, equipment and robots", given)
  end
  return lines
end

---------------------------------------------------------------------------------------------
-- /f3d-debug: the client's debug menu (debug_menu.gd): the time of day, the day/night cycle, the
-- game's speed, pausing, and moving the character to a spot. Every reply carries the state (`dbg`,
-- M.debug_state), so the menu shows what the game has, not what it asked for.

-- game.speed's range here; past these the client's drawn clock can't keep up anyway.
local SPEED_MIN, SPEED_MAX = 0.05, 16

local function debug_surface()
  local c = puppet.get()
  return c and c.valid and c.surface or game.surfaces["nauvis"] or game.surfaces[1]
end

-- A screenshot's hold (`/f3d-debug hold on|off`, the client's shot_pause.gd): the game slowed to
-- Factorio's slowest speed instead of tick-paused, so the bridge still ticks (about once every 1.7 s),
-- reads the client's packets and can let it go again; works in single-player too, where nothing
-- else could resume a tick-paused game. The speed before is kept and comes back on `hold off`, and by
-- itself HOLD_TICKS game ticks after the last `hold on` (about 50 s), so a client that crashed or
-- left never leaves the game slowed. A player who changes the speed meanwhile keeps theirs.
local HOLD_SPEED = 0.01
local HOLD_TICKS = 30

local function release_hold()
  local h = storage.f3d_hold
  storage.f3d_hold = nil
  if h and game.speed == HOLD_SPEED then
    game.speed = h.speed
  end
end

-- Each tick (control.lua), with or without a client: the hold's watchdog.
function M.hold_tick()
  local h = storage.f3d_hold
  if h and (game.tick >= h.ends or game.speed ~= HOLD_SPEED) then
    release_hold()
  end
end

-- {dt time of day (0 noon, 0.5 midnight), fz 1 frozen, sp speed, pa 1 paused, hd 1 held for a
-- screenshot, ad 1 always day, s surface, x, y the character and sx, sy its force's spawn there
-- (1/256 tiles)}
function M.debug_state()
  local surface = debug_surface()
  local state = { dt = math.floor(surface.daytime * 1000 + 0.5) / 1000, fz = surface.freeze_daytime and 1 or 0,
    sp = game.speed, pa = game.tick_paused and 1 or 0, hd = storage.f3d_hold and 1 or 0,
    ad = surface.always_day and 1 or 0, s = surface.name }
  local c = puppet.get()
  if c and c.valid then
    state.x, state.y = math.floor(c.position.x * 256 + 0.5), math.floor(c.position.y * 256 + 0.5)
    local spawn = c.force.get_spawn_position(surface)
    state.sx, state.sy = math.floor(spawn.x * 256 + 0.5), math.floor(spawn.y * 256 + 0.5)
  end
  return state
end

local function on_off(word)
  if word == "on" or word == "1" then
    return true
  elseif word == "off" or word == "0" then
    return false
  end
  return nil
end

commands["f3d-debug"] = function(words)
  local what = words[1]
  local surface = debug_surface()
  if what == nil or what == "state" then
    return { string.format("Time of day %.3f%s, speed %gx%s, on %s", surface.daytime, surface.freeze_daytime and " (frozen)" or "",
      game.speed, game.tick_paused and ", paused" or "", surface.name) }
  elseif what == "daytime" then
    local v = tonumber(words[2])
    if not v or v ~= v or math.abs(v) > 1e6 then
      return { "/f3d-debug daytime <0-1>: 0 is noon, 0.5 midnight" }
    end
    surface.daytime = v - math.floor(v)
    return { string.format("Time of day on %s: %.3f", surface.name, surface.daytime) }
  elseif what == "freeze" then
    local on = on_off(words[2])
    if on == nil then
      on = not surface.freeze_daytime
    end
    surface.freeze_daytime = on
    return { (on and "The day/night cycle on %s is frozen" or "The day/night cycle on %s runs"):format(surface.name) }
  elseif what == "speed" then
    local v = tonumber(words[2])
    if not v or v ~= v then
      return { string.format("/f3d-debug speed <%g-%g>: 1 is normal", SPEED_MIN, SPEED_MAX) }
    end
    game.speed = math.max(SPEED_MIN, math.min(SPEED_MAX, v))
    return { string.format("Game speed %gx", game.speed) }
  elseif what == "pause" then
    local on = on_off(words[2])
    if on == nil then
      on = not game.tick_paused
    end
    game.tick_paused = on
    return { on and "The game is paused" or "The game runs" }
  elseif what == "hold" then
    if on_off(words[2]) == false then
      release_hold()
      return { "The game runs" }
    elseif game.tick_paused then
      return { "The game is paused already" }
    end
    if not storage.f3d_hold then
      storage.f3d_hold = { speed = game.speed }
      game.speed = HOLD_SPEED
    end
    storage.f3d_hold.ends = game.tick + HOLD_TICKS
    return { "The game is held for a screenshot" }
  elseif what == "teleport" then
    local c = puppet.get()
    local x, y = tonumber(words[2]), tonumber(words[3])
    if not c or not c.valid then
      return { "No character to move" }
    elseif not x or not y or x ~= x or y ~= y or math.abs(x) > 1e6 or math.abs(y) > 1e6 then
      return { "/f3d-debug teleport <x> <y>: tiles on the character's surface" }
    elseif puppet.vehicle(c) then
      return { "Get out of the vehicle first" }
    end
    local spot = c.surface.find_non_colliding_position("character", { x = x, y = y }, 32, 0.5)
    if not spot or not c.teleport(spot) then
      return { string.format("Nowhere free to stand near %.0f, %.0f", x, y) }
    end
    return { string.format("Moved the character to %.1f, %.1f", spot.x, spot.y) }
  end
  return { "/f3d-debug [state | daytime <0-1> | freeze [on | off] | speed <x> | pause [on | off] | hold [on | off] | teleport <x> <y>]" }
end

---------------------------------------------------------------------------------------------
-- {id, text}: one console line from the client ("/cheat all"). Answered with {t = "cmdr", id,
-- l = lines, ok = 0 when the bridge doesn't know the command, na = 1 when the sender may not run
-- console commands here, dbg = M.debug_state() after /f3d-debug}.

function M.run(cmd)
  local text = tostring(cmd.text or ""):gsub("^%s*/", "")
  local words = words_of(text)
  local name = table.remove(words, 1) or ""
  local reply = { t = "cmdr", id = math.floor(tonumber(cmd.id) or 0) }
  local fn = commands[name]
  if not M.allowed(M.from_player) then
    reply.l = { "Console commands are for admins in a multiplayer game" }
    reply.na = 1
  elseif fn then
    local ok, lines = pcall(fn, words)
    reply.l = ok and lines or { "Error: " .. tostring(lines) }
    if name == "f3d-debug" then
      local got, state = pcall(M.debug_state)
      if got then
        reply.dbg = state
      end
    end
  elseif M.extra[name] then
    M.capture = {}
    local ok, err = pcall(M.extra[name], { name = name, parameter = table.concat(words, " ") ~= "" and table.concat(words, " ") or nil })
    reply.l = M.capture
    M.capture = nil
    if not ok then
      reply.l[#reply.l + 1] = "Error: " .. tostring(err)
    end
  else
    reply.l = {}
    reply.ok = 0
  end
  transport.send_reliable(reply)
end

---------------------------------------------------------------------------------------------
-- remote.call("zenith", ...): for the client's Lua commands over RCON.

function M.register_remote()
  remote.add_interface("zenith", {
    -- The LuaPlayer playing the client's character, or nil.
    player = function() return M.player() end,
    -- The client's character (LuaEntity), or nil.
    character = function() return puppet.get() end,
    -- The name of the player the character is, or stands in for (nil: the bridge's own).
    name = function() return name_of(puppet.get()) end,
  })
end

return M
