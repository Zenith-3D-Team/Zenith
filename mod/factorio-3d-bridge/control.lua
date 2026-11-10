-- Zenith bridge: streams the game to the 3D client over localhost UDP and applies its input.
-- Factorio must be launched with --enable-lua-udp <port>; the client sends to that port.

local transport = require("scripts.transport")
local world = require("scripts.world")
local tracker = require("scripts.tracker")
local movers = require("scripts.movers")
local belt_items = require("scripts.belt_items")
local ground_items = require("scripts.ground_items")
local fluids_power = require("scripts.fluids_power")
local inserters = require("scripts.inserters")
local sky = require("scripts.sky")
local puppet = require("scripts.puppet")
local driving = require("scripts.driving")
local screens = require("scripts.screens")
local combat = require("scripts.combat")
local turrets = require("scripts.turrets")
local shots = require("scripts.shots")
local inventory = require("scripts.inventory")
local crafting = require("scripts.crafting")
local research = require("scripts.research")
local map = require("scripts.map")
local trains = require("scripts.trains")
local logistics = require("scripts.logistics")
local platforms = require("scripts.platforms")
local planets = require("scripts.planets")
local space = require("scripts.space")
local collectors = require("scripts.collectors")
local ui_actions = require("scripts.ui_actions")
local equipment = require("scripts.equipment")
local players = require("scripts.players")
local alerts = require("scripts.alerts")
local enemies = require("scripts.enemies")
local session = require("scripts.session")
local console = require("scripts.console")
local profile = require("scripts.profile")
local budget = require("scripts.budget")
local requests = require("scripts.requests")
local alt_mode = require("scripts.alt_mode")
local gfx = require("scripts.gfx")
local mod_gui = require("scripts.mod_gui")

local zenith_button = require("scripts.zenith_button")
script.on_init(function()
  session.init_storage()
  zenith_button.update_all()
end)
script.on_load(session.on_load)
script.on_configuration_changed(function()
  session.each_client(session.init_storage)
  zenith_button.update_all()
end)

script.on_event(defines.events.on_udp_packet_received, session.on_packet)

-- In this order: queued world data goes first, so a fresh client gets its welcome before any
-- live state.
local STEPS = {
  { "transport", transport.flush }, { "tracker", tracker.tick }, { "puppet", puppet.tick },
  { "combat", combat.tick }, { "turrets", turrets.tick }, { "shots", shots.tick },
  { "driving", driving.tick }, { "screens", screens.tick },
  { "inventory", inventory.tick }, { "crafting", crafting.tick }, { "research", research.tick },
  { "map", map.tick }, { "trains", trains.tick }, { "logistics", logistics.tick }, { "platforms", platforms.tick },
  { "planets", planets.tick }, { "space", space.tick }, { "collectors", collectors.tick },
  { "world", world.tick }, { "movers", movers.tick }, { "belt_items", belt_items.tick }, { "belt_lanes", belt_items.far_tick },
  { "ground_items", ground_items.tick }, { "fluids_power", fluids_power.tick },
  { "inserters", inserters.tick }, { "sky", sky.tick }, { "ui_actions", ui_actions.tick }, { "alt_mode", alt_mode.tick },
  { "alerts", alerts.tick }, { "equipment", equipment.tick }, { "players", players.tick },
  { "enemies", enemies.tick }, { "requests", requests.tick }, { "gfx", gfx.tick }, { "mod_gui", mod_gui.tick },
}

local function serve()
  if not storage.f3d.client or not session.tick() then
    return
  end
  -- The tick's work budget (budget.lua): jobs that can be big take their slices from it.
  budget.begin()
  -- Belt items' share of this tick first, so the periodic jobs that may wait keep off it.
  budget.commit(belt_items.planned_units(), "bi")
  if session.handshaking() then
    profile.run("transport", transport.flush)
    profile.run("handshake", session.handshake_tick)
  else
    for _, step in ipairs(STEPS) do
      profile.run(step[1], step[2])
    end
  end
  budget.finish()
end

-- Lists made from prototypes alone (the handshake's dictionaries, Factoriopedia's index) cost 8-38
-- ms each the first time. They are made one a tick from the first ticks after loading, before a
-- client asks, so no request pays for them (budget.lua). Module-local, nothing in `storage`.
local registry = require("scripts.registry")
local tiles = require("scripts.tiles")
local pedia = require("scripts.pedia")
local WARM = {
  registry.entity_records,
  function() ui_actions.send_eprops(true) end,
  function() tiles.warm_item_uses(false) end,
  function() tiles.warm_item_uses(true) end,
  pedia.warm_lookups,
  pedia.warm_index,
}
local warmed = 0

script.on_event(defines.events.on_tick, function()
  if warmed < #WARM then
    warmed = warmed + 1
    profile.run("warm", WARM[warmed])
  end
  profile.run("poll", transport.poll)
  profile.run("bridge", function() session.each_client(serve) end)
  profile.run("transport", transport.end_tick)
  session.launch_tick()
  profile.end_tick()
end)

tracker.register()
puppet.register()
combat.register()
-- on_object_destroyed takes one handler: shots' projectiles and tracker's rolling stock ghosts.
script.on_event(defines.events.on_object_destroyed, function(event)
  shots.on_object_destroyed(event)
  tracker.on_object_destroyed(event)
end)
research.register()
map.register()
planets.register()
trains.register()
script.on_event(defines.events.on_console_chat, ui_actions.on_console_chat)

-- Factorio lets any player run a mod's command: in a multiplayer game these are for admins
-- (console.allowed). The server's own console and RCON have no player and always may.
local function admins_only(fn)
  return function(cmd)
    if cmd.player_index and not console.allowed(cmd.player_index) then
      local p = game.get_player(cmd.player_index)
      if p then
        p.print("[Zenith] /" .. tostring(cmd.name) .. " is for admins in a multiplayer game")
      end
      return
    end
    return fn(cmd)
  end
end
commands.add_command("f3d-status", { "command-help.f3d-status" }, admins_only(session.status_command))
commands.add_command("f3d-selftest", { "command-help.f3d-selftest" }, admins_only(session.selftest_command))
commands.add_command("f3d-platform", { "command-help.f3d-platform" }, admins_only(session.platform_command))
commands.add_command("f3d-player", { "command-help.f3d-player" }, admins_only(session.player_command))
commands.add_command("f3d-profile", { "command-help.f3d-profile" }, admins_only(session.profile_command))
commands.add_command("f3d-rate", { "command-help.f3d-rate" }, admins_only(session.rate_command))
-- game.player for the client's Lua commands over RCON (console.lua).
console.register_remote()

-- Several clients (session.lua): every game event reaches each client's state in turn.
for _, id in pairs(defines.events) do
  if id ~= defines.events.on_tick and id ~= defines.events.on_udp_packet_received then
    local handler = script.get_event_handler(id)
    if handler then
      script.on_event(id, function(event) session.each_client(handler, event) end)
    end
  end
end

-- The real game's "Show in Zenith" key (data.lua): the client playing that player's character
-- comes to the front.
local function show_in_zenith(event)
  log("[Zenith] Show in Zenith pressed by player " .. tostring(event.player_index) .. " at tick " .. game.tick)
  local raised = false
  session.each_client(function(e) raised = session.show_3d(e) or raised end, event)
  if not raised then
    session.ask_launch(event)  -- no Zenith to raise: the launcher beside Factorio starts one
  end
end
script.on_event("f3d-show-3d", show_in_zenith)
-- The bridge's own windows and buttons (the launcher help, the Zenith button): not per client, so
-- registered after the loop above.
script.on_event(defines.events.on_gui_click, function(event)
  if zenith_button.is_button(event.element) then
    return show_in_zenith(event)
  end
  session.on_gui_click(event)
end)
-- The Zenith button for each player, on top of what these events already do (puppet.lua).
local function also(id, fn)
  local before = script.get_event_handler(id)
  script.on_event(id, function(event)
    if before then
      before(event)
    end
    fn(event)
  end)
end
also(defines.events.on_player_created, zenith_button.on_player)
also(defines.events.on_player_joined_game, zenith_button.on_player)
also(defines.events.on_runtime_mod_setting_changed, zenith_button.on_player)
