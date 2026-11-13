-- The connection to the 3D client: handshake, keep-alive, and dispatch of incoming commands.
--
-- All of this runs from on_udp_packet_received and on_tick, which every peer replays in the
-- same order, so the state it keeps in `storage` stays deterministic in multiplayer.

local registry = require("scripts.registry")
local transport = require("scripts.transport")
local world = require("scripts.world")
local puppet = require("scripts.puppet")
local screens = require("scripts.screens")
local profile = require("scripts.profile")
local building = require("scripts.building")
local planners = require("scripts.planners")
local history = require("scripts.history")
local combat = require("scripts.combat")
local turrets = require("scripts.turrets")
local collectors = require("scripts.collectors")
local shots = require("scripts.shots")
local driving = require("scripts.driving")
local inventory = require("scripts.inventory")
local crafting = require("scripts.crafting")
local research = require("scripts.research")
local map = require("scripts.map")
local trains = require("scripts.trains")
local logistics = require("scripts.logistics")
local planets = require("scripts.planets")
local platforms = require("scripts.platforms")
local selftest = require("scripts.selftest")
local ui_actions = require("scripts.ui_actions")
local equipment = require("scripts.equipment")
local wiring = require("scripts.wiring")
local players = require("scripts.players")
local tiles = require("scripts.tiles")
local capsules = require("scripts.capsules")
local rail_planner = require("scripts.rail_planner")
local space = require("scripts.space")
local alerts = require("scripts.alerts")
local pedia = require("scripts.pedia")
local force_info = require("scripts.force_info")
local spiders = require("scripts.spiders")
local belt_items = require("scripts.belt_items")
local movers = require("scripts.movers")
local console = require("scripts.console")
local modules = require("scripts.modules")
local rate = require("scripts.rate")
local photo = require("scripts.photo")
local budget = require("scripts.budget")
local requests = require("scripts.requests")
local gfx = require("scripts.gfx")
local mod_gui = require("scripts.mod_gui")
local belt_sim = require("scripts.belt_sim")
local barrier = require("scripts.barrier")

local M = {}

M.PROTOCOL = 1

local TIMEOUT = 600          -- drop the client after 10 s without a hello
local MAX_EXTRA = 7          -- clients beyond the first, on a server
local RECORDS_PER_MESSAGE = 80
local RESYNC_COOLDOWN = 120

function M.init_storage()
  storage.f3d = storage.f3d or {}
  local s = storage.f3d
  s.subs = s.subs or {}
  s.queue = s.queue or {}
  s.queued = s.queued or {}
  s.rseq = s.rseq or 0
  s.outbox = s.outbox or {}
  s.outbox_head = s.outbox_head or 1
  s.outbox_tail = s.outbox_tail or 0
  s.focus = s.focus or { x = 0, y = 0, r = 32 }
  s.working = s.working or {}
  s.belt_refresh = s.belt_refresh or {}
  s.pipe_refresh = s.pipe_refresh or {}
  s.wire_sigs = s.wire_sigs or {}
  s.surface_index = s.surface_index or 1
  s.handshake_tick = s.handshake_tick or 0
  s.resync_tick = s.resync_tick or 0
  s.damaged = s.damaged or {}
end

local function send_records(kind, records)
  local parts = math.max(1, math.ceil(#records / RECORDS_PER_MESSAGE))
  for part = 1, parts do
    local slice = {}
    for i = (part - 1) * RECORDS_PER_MESSAGE + 1, math.min(part * RECORDS_PER_MESSAGE, #records) do
      slice[#slice + 1] = records[i]
    end
    transport.send_reliable({ t = kind, part = part, parts = parts, l = slice })
  end
end

-- Starts the stream over: welcome, prototype dictionaries, then the client subscribes to chunks.
-- A full resync keeps the remote view of another surface (`keep_view`): clearing it there sent the
-- client back to the character's planet whenever packets were lost (H25: zooming into a planet
-- sometimes jumped back to Nauvis).
function M.handshake(keep_view)
  local s = storage.f3d
  if not (keep_view and s.view_si and game.get_surface(s.view_si)) then
    s.view_si, s.view_at, s.view_from = nil, nil, nil
  end
  s.remote_view = nil
  belt_items.far_reset()
  movers.reset()
  rate.reset()
  photo.reset()
  transport.reset()
  world.clear()
  puppet.reset()
  screens.reset()
  combat.reset()
  turrets.reset()
  collectors.reset()
  shots.reset()
  driving.reset()
  map.reset()
  ui_actions.reset()
  alerts.reset()
  requests.reset()
  s.working = {}
  s.belt_refresh = {}
  s.pipe_refresh = {}
  s.wire_sigs = {}
  s.handshake_tick = game.tick
  local c = puppet.get()
  local surface = world.surface()
  s.surface_index = surface.index
  local p = c and c.position or { x = 0, y = 0 }
  s.focus = { x = p.x, y = p.y, r = 32 }
  s.puppet_unit = c and c.unit_number or 0
  gfx.reset()
  transport.send_reliable(gfx.welcome_fields(M.surface_fields(surface, {
    t = "welcome",
    v = M.PROTOCOL,
    mod = script.active_mods["factorio-3d-bridge"],
    u = c and c.unit_number or 0,
    x = world.fixed(p.x),
    y = world.fixed(p.y),
    mp = game.is_multiplayer(),
    -- Square subscriptions (`sub` o, r, w) out to world.MAX_RADIUS: a client asks older bridges for a list.
    sq = world.MAX_RADIUS,
  })))
  -- The rest a stage a tick (handshake_tick): together they took 35 ms in one tick on the owner's
  -- save. Meanwhile only the transport and the stages run (control.lua), as before for one tick.
  s.hs_stage = 1
end

-- The handshake after the welcome, in order, with each stage's price in work units.
-- The name <-> id dictionaries, the entity records, eprops and item uses are made once per load
-- (control.lua's warm-up), so those stages' prices are their sending: building the messages'
-- slices. The tile, item, fluid and decorative records are listed from the dictionaries each time.
local HANDSHAKE_STAGES = {
  { 100, function() send_records("protos", registry.entity_records()) end },
  { 100, function(s)
    send_records("tprotos", registry.tile_records())
    send_records("iprotos", registry.item_records())
    send_records("fprotos", registry.fluid_records())
    if s.client and s.client.dc then
      send_records("dprotos", registry.decorative_records())
    end
  end },
  { 100, function()
    transport.send_reliable({ t = "ready" })
    ui_actions.send_eprops()
  end },
  { 100, function() tiles.item_uses() end },
  { 400, function(s)
    puppet.send_initial()
    inventory.send_initial()
    crafting.invalidate()
    research.send_initial()
    planners.send_initial()
    logistics.send_initial()
    map.send_initial()
    planets.send_initial()
    equipment.send_initial()
    players.send_initial()
    mod_gui.reset() -- the new client gets every mod window on mod_gui's next round
    s.plat_sent = nil -- platforms.tick sends the panel's data within a second
  end },
}

function M.handshaking()
  return storage.f3d.hs_stage ~= nil
end

-- Stages of the handshake while the budget allows (one always runs in its tick).
function M.handshake_tick()
  local s = storage.f3d
  while s.hs_stage do
    local stage = HANDSHAKE_STAGES[s.hs_stage]
    if not stage then
      s.hs_stage = nil
      return
    end
    if not budget.can(stage[1], "handshake") then
      return
    end
    budget.spend(stage[1], "handshake")
    s.hs_stage = s.hs_stage + 1
    if not HANDSHAKE_STAGES[s.hs_stage] then
      s.hs_stage = nil
    end
    stage[2](s)
  end
end

-- The surface's name and index, and on a platform its index (pf), else the planet's name.
function M.surface_fields(surface, msg)
  msg.surface = surface.name
  msg.si = surface.index
  local p = platforms.of_surface(surface)
  if p then
    msg.pf = p.index
  else
    msg.planet = platforms.planet_of(surface)
  end
  return msg
end

-- The character moved to another surface (a platform and back, or the player's own trip in
-- single-player), or the remote view looks at another one (`view`). Lighter than a handshake:
-- the prototypes stay, and so do the inventory, the quickbar and research; the world is dropped
-- and the client subscribes again. Everything reliable from the old surface was queued before the
-- `surface` message, so the client can drop the old world when it arrives.
function M.change_surface(c)
  local s = storage.f3d
  local surface = world.surface()
  local p = c.position
  if surface ~= c.surface and s.view_at then
    p = s.view_at
  end
  belt_items.far_reset()
  movers.reset()
  world.clear()
  screens.reset()
  combat.reset()
  turrets.reset()
  collectors.reset()
  shots.reset()
  driving.reset()
  map.reset()
  puppet.reset()
  s.working = {}
  s.belt_refresh = {}
  s.pipe_refresh = {}
  s.wire_sigs = {}
  s.surface_index = surface.index
  s.focus = { x = p.x, y = p.y, r = 32 }
  local msg = M.surface_fields(surface, { t = "surface", x = world.fixed(p.x), y = world.fixed(p.y) })
  if surface ~= c.surface then
    msg.view = 1
  end
  transport.send_reliable(msg)
  puppet.send_initial()
  platforms.send()
  planets.send_planet()
  planets.territories_soon()
end

---------------------------------------------------------------------------------------------
-- Several clients. The first client's state is storage.f3d, as it always was. On a server, a
-- hello from another port starts another client with a whole state of its own (and its own
-- character), kept in storage.f3d_extra by port; while it is served (its packets, its tick, each
-- game event) it is swapped in as storage.f3d, so every module works on "the client" unchanged.

local function extras()
  storage.f3d_extra = storage.f3d_extra or {}
  return storage.f3d_extra
end

-- Runs fn(...) with `state` as storage.f3d.
function M.serve(state, fn, ...)
  local primary = storage.f3d
  storage.f3d = state
  local ok, err = pcall(fn, ...)
  storage.f3d = primary
  if not ok then
    error(err, 0)
  end
end

-- Runs fn(...) for the first client's state (connected or not, as before), then for each other
-- client's.
function M.each_client(fn, ...)
  fn(...)
  for _, state in pairs(extras()) do
    M.serve(state, fn, ...)
  end
end

-- {player_index}: the player pressed "Show in Zenith" in the real game; the client playing their
-- character (single-player: the one client) is told to come to the front. True when one was.
-- A save keeps the client it was saved with: until the timeout drops it, a loaded game would send
-- `raise` to a Zenith that is gone and the key would do nothing. A live client says hello every
-- second, so one not heard from in 3 s isn't raised.
-- The tick goes on from the save's, though, so a client heard just before the save was made still
-- looks fresh after loading it. In single-player (one peer, so a module-local flag can't desync) a
-- loaded game raises no client until one says hello after the load.
M.RAISE_FRESH = 180
-- Ticks a raised Zenith has to say hello before it is taken for gone (it says hello every second).
M.RAISE_ANSWER = 90
local heard_since_load = true
function M.on_load()
  heard_since_load = false
end
function M.show_3d(event)
  local s = storage.f3d
  if s.client and game.tick - (s.client.last_seen or 0) <= M.RAISE_FRESH
      and (heard_since_load or game.is_multiplayer())
      and (not game.is_multiplayer() or puppet.owner() == game.get_player(event.player_index)) then
    log("[Zenith] Show in Zenith: raising the connected Zenith")
    transport.send_now({ t = "raise" })
    -- Say so, and watch that it answers: a live Zenith says hello within a second. One that
    -- doesn't (closed, hung) isn't waited for: the launcher is asked, so the key never looks dead.
    local player = game.get_player(event.player_index)
    if player and player.valid then
      player.print({ "f3d-launch.raising" })
    end
    s.client.raised = { tick = game.tick, player = event.player_index }
    return true
  end
  return false
end

-- Where Zenith's launcher listens (server/factorio-with-zenith.ps1, started with Factorio): asked to
-- start Zenith when "Show in Zenith" finds no client to raise. On a server the datagram goes from
-- the pressing player's own machine (for_player), where their launcher runs.
M.LAUNCH_PORT = 34209

-- Ticks the launcher has to answer (`launching`) before the player is told it isn't there. It answers
-- within milliseconds, and the button should explain itself at once when it can't start Zenith.
-- Without --enable-lua-udp Factorio takes send_udp and sends nothing (checked in 2.1.24), so this wait
-- is also how a game started without the launch options is found out.
M.LAUNCH_WAIT = 45
M.LAUNCH_HELP = "f3d-launch-help"
-- Zenith keeps the launcher in C:\ProgramData\Zenith on every PC (game_swap.gd), so the line is whole.
M.LAUNCH_LINE = 'powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\\ProgramData\\Zenith\\factorio-with-zenith.ps1" %command%'

M.DOWNLOAD_URL = "https://github.com/Zenith-3D-Team/Zenith/releases"

-- Nothing on screen would otherwise say why the button did nothing: a window with what is missing,
-- step by step. A player may have this mod from the portal and no Zenith yet, or Zenith and a
-- Factorio started without its launch options; the bridge can't tell those apart (a mod can't look
-- for a program), so with no launcher both steps show. why:
--   "none"   no launcher answered: Factorio wasn't started with Zenith's launch options;
--   "zenith" the launcher answered but has no Zenith to start (never opened here: moved = false;
--            moved or removed since it was last opened: moved = true).
function M.launch_help(index, why, moved)
  log("[Zenith] Show in Zenith: can't start Zenith (" .. tostring(why) .. "), showing what is missing")
  local player = game.get_player(index)
  if not (player and player.valid) then
    return
  end
  local screen = player.gui.screen
  if screen[M.LAUNCH_HELP] then
    screen[M.LAUNCH_HELP].destroy()
  end
  local frame = screen.add({ type = "frame", name = M.LAUNCH_HELP, direction = "vertical",
    caption = { "f3d-launch.title" } })
  frame.force_auto_center()
  local function text(key, bold)
    local label = frame.add({ type = "label", caption = { key } })
    label.style.single_line = false
    label.style.maximal_width = 560
    if bold then
      label.style.font = "default-bold"
    end
  end
  local function copy_box(value)
    local box = frame.add({ type = "textfield", text = value })
    box.style.width = 560
  end
  text("f3d-launch.intro")
  if why == "zenith" then
    text(moved and "f3d-launch.step1-moved" or "f3d-launch.step1", true)
    copy_box(M.DOWNLOAD_URL)
    text("f3d-launch.step2-done")
  else
    text("f3d-launch.step1", true)
    copy_box(M.DOWNLOAD_URL)
    text("f3d-launch.step2", true)
    copy_box(M.LAUNCH_LINE)
  end
  text("f3d-launch.copy")
  text("f3d-launch.then")
  text("f3d-launch.or")
  frame.add({ type = "button", name = M.LAUNCH_HELP .. "-close", caption = { "f3d-launch.close" } })
end

function M.ask_launch(event)
  log("[Zenith] Show in Zenith: no Zenith connected, asking the launcher on " .. M.LAUNCH_PORT)
  local data = helpers.table_to_json({ t = "launch", k = game.tick })
  if game.is_multiplayer() then
    -- Sent from that player's machine only: whether it failed there isn't known to every peer,
    -- so nothing here may depend on it (desync). The wait covers both.
    pcall(helpers.send_udp, M.LAUNCH_PORT, data, event.player_index)
  else
    pcall(helpers.send_udp, M.LAUNCH_PORT, data)  -- without --enable-lua-udp it sends nothing: the wait finds out
  end
  local s = storage.f3d
  s.launch_wait = s.launch_wait or {}
  s.launch_wait[event.player_index] = game.tick + M.LAUNCH_WAIT
end

-- The launcher answered: it is there, and starts (or brings forward) Zenith itself, or says it has
-- no Zenith to start (`need` "zenith").
function M.launch_answered(event, msg)
  local waits = storage.f3d.launch_wait
  if not waits then
    return
  end
  local index = tonumber(event.player_index) or 0
  if waits[index] then
    waits[index] = nil
  elseif index == 0 then
    -- Read by the server (or single-player): the host's own launcher.
    for i in pairs(waits) do
      waits[i] = nil
      index = i
      break
    end
  end
  local player = index > 0 and game.get_player(index)
  if not (player and player.valid) then
    return
  end
  if msg and msg.need == "zenith" then
    return M.launch_help(index, "zenith", msg.moved == 1)
  end
  local help = player.gui.screen[M.LAUNCH_HELP]
  if help then
    help.destroy()
  end
  -- Zenith takes a while to start and join a big save: say it's coming, or the key looks dead.
  player.print({ "f3d-launch.starting" })
end

-- Each tick while a player waits: read their own machine's packets (a joined player's launcher
-- answers there), and show the help once the wait is over.
function M.launch_tick()
  local waits = storage.f3d.launch_wait
  if not waits or next(waits) == nil then
    return
  end
  for index, due in pairs(waits) do
    if game.is_multiplayer() then
      pcall(helpers.recv_udp, index)
    end
    if game.tick >= due then
      waits[index] = nil
      M.launch_help(index, "none")
    end
  end
end

function M.on_gui_click(event)
  local e = event.element
  if e and e.valid and e.name == M.LAUNCH_HELP .. "-close" then
    local frame = e.parent
    if frame and frame.valid then
      frame.destroy()
    end
  end
end

local function drop_client()
  local s = storage.f3d
  local port = s.client and s.client.port
  if s.extra and port then
    -- Its character waits for the same client (session id) to come back.
    storage.f3d_parked = storage.f3d_parked or {}
    storage.f3d_parked_at = storage.f3d_parked_at or {}
    if s.puppet and s.puppet.valid then
      storage.f3d_parked[s.client.sid] = s.puppet
      storage.f3d_parked_at[s.client.sid] = game.tick
    end
    extras()[port] = nil
  end
  s.rate = nil
  s.photo_until = nil
  puppet.reset()
  screens.reset()
  combat.reset()
  turrets.reset()
  collectors.reset()
  shots.reset()
  driving.reset()
  map.reset()
  world.clear()
  transport.reset()
  s.belt_refresh = {}
  s.pipe_refresh = {}
  s.client = nil
end

-- What outlives a client when the bridge's version changes: the character and whose it is, what
-- the player made, and the script inventories (dropped, they would stay in the save for good).
-- Everything else in a client's state is its connection and its jobs, and a save keeps those half
-- done in the old version's shape (a research job half sent and 0.1.1's belt round each stopped the
-- game when a new bridge read them). Nothing else can be needed: a new client beside the first
-- starts with only `extra`, its character and what init_storage makes (add_client).
local KEPT_ACROSS_VERSIONS = {
  extra = true, puppet = true, own_character = true, held_for = true, owner_index = true, owner_checked = true,
  owner_pick = true, recheck = true, was_mp = true, death = true, respawn = true, trip = true,
  quickbar = true, hist = true, explored = true, hist_scratch = true, clipboard = true, lib_cursor = true,
}

local function start_clean()
  -- (The resets stop the character walking, shooting and riding. An old state may not have what
  -- they read, and failing here would refuse the save.)
  local ok, err = pcall(drop_client)
  if not ok then
    log("[Zenith] dropping a client from an older bridge: " .. tostring(err))
  end
  local s = storage.f3d
  for key in pairs(s) do
    if not KEPT_ACROSS_VERSIONS[key] then
      s[key] = nil
    end
  end
  M.init_storage()
end

-- A save loaded with other mods. On a new version of the bridge the save's clients and half-done
-- jobs are dropped, so the next hello starts a clean handshake; only `storage` changes, from what
-- the save holds, so every peer ends up the same.
function M.on_configuration_changed(data)
  M.each_client(M.init_storage)
  local change = data and data.mod_changes and data.mod_changes["factorio-3d-bridge"]
  if change and change.old_version and change.old_version ~= change.new_version then
    log("[Zenith] the bridge went from " .. tostring(change.old_version) .. " to " .. tostring(change.new_version)
      .. ": this save's clients and their unfinished work are dropped")
    M.each_client(start_clean)
    storage.f3d_extra = {}
  end
end

---------------------------------------------------------------------------------------------
-- Commands from the client

local handlers = {}

function handlers.hello(msg, port)
  local s = storage.f3d
  local sid = tostring(msg.sid or "")
  if not s.client or s.client.sid ~= sid or s.client.port ~= port then
    heard_since_load = true
    s.client = { sid = sid, port = port, last_seen = game.tick, z = msg.z == 1, dc = msg.dc == 1, b = msg.b == 1,
      bl = msg.bl == 1, bs = msg.bs == 1, bg = msg.bl == 1 and msg.bg == 1, br = msg.bl == 1 and msg.br == 1,
      v = tonumber(msg.v) or 0, mg = msg.mg ~= 0 }
    s.rate = nil -- a new client starts at full rate; it sends `rate` if it wants another
    s.bud = nil -- and with the default work budget, not one the last client set
    M.handshake()
    return
  end
  s.client.last_seen = game.tick
  heard_since_load = true
  s.client.v = tonumber(msg.v) or 0
  s.client.z = msg.z == 1
  s.client.b = msg.b == 1
  s.client.bl = msg.bl == 1
  -- A client that simulates belts itself (belt_sim.lua) gets `bs` instead of `bi`.
  s.client.bs = msg.bs == 1
  -- Belt groups (belt_items.lua) build on kept lanes: a client says both.
  s.client.bg = msg.bl == 1 and msg.bg == 1
  -- Straight runs (belt_items.lua): plain lanes moved by the client, also on kept lanes.
  s.client.br = msg.bl == 1 and msg.br == 1
  -- Mods' windows (mod_gui.lua): off only for a client that says so; one that doesn't say gets them.
  s.client.mg = msg.mg ~= 0
  -- Decoratives turned on in the client's settings: send the dictionary and resend the chunks.
  if msg.dc == 1 and not s.client.dc then
    s.client.dc = true
    send_records("dprotos", registry.decorative_records())
    world.resend_all()
  elseif msg.dc ~= 1 then
    s.client.dc = false
  end
  -- The client never got the welcome (lost packet): start over, at most every 2 seconds.
  if msg.w == 0 and game.tick - s.handshake_tick > 120 then
    M.handshake()
  end
end

function handlers.bye()
  drop_client()
end

-- A square (`o`, `r`, `w`, what the client sends) or a list (`c`, small ones: tests, older clients).
function handlers.sub(msg)
  if msg.w ~= nil then
    world.subscribe_square(msg.o, msg.r, msg.w, msg.h)
  elseif type(msg.c) == "table" then
    world.subscribe(msg.c, msg.h)
  end
end

function handlers.focus(msg)
  local s = storage.f3d
  -- On the map and finite: every tick's searches round the focus use them (world.fixed_in).
  local x, y, r = world.fixed_in(msg.x), world.fixed_in(msg.y), tonumber(msg.r)
  if x and y then
    local max_r = settings.global["f3d-max-focus-radius"].value
    s.focus = { x = x / 256, y = y / 256, r = math.max(8, math.min(r or 32, max_r)) }
  end
  -- rv = 1: the 3D remote view, which shows moving things only where radars see (map.view_filter).
  s.remote_view = tonumber(msg.rv) == 1 or nil
end

-- The client saw a gap in the reliable sequence. full = 1 restarts everything (it is missing
-- prototypes or the server went back in time); otherwise its chunks are sent again: the ones
-- listed in `c`, or all of them. A list is cheap and already-queued chunks aren't queued twice,
-- so it skips the cooldown; that lets a lossy link converge chunk by chunk.
function handlers.resync(msg)
  local s = storage.f3d
  if msg.full ~= 1 and type(msg.c) == "table" then
    world.resend(msg.c)
    return
  end
  if game.tick - s.resync_tick < RESYNC_COOLDOWN then
    return
  end
  s.resync_tick = game.tick
  if msg.full == 1 then
    M.handshake(true)
  else
    world.resend_all()
    belt_items.far_reset()
    movers.reset()
  end
end

handlers.walk = puppet.walk
handlers.mine = puppet.mine
handlers.mine_stop = puppet.mine_stop
handlers.pickup = puppet.pickup
handlers.build = function(cmd)
  if cmd.sf == 1 then
    return planners.superforced(cmd)
  end
  return building.build(cmd)
end
handlers.blueprint = planners.blueprint
handlers.decon = planners.decon
handlers.upgrade = planners.upgrade
handlers.rotate = planners.rotate
handlers.bp_get = planners.get
handlers.bp_set = planners.set
handlers.bp_page = planners.page
handlers.bp_lib = planners.library
handlers.bp_rec = planners.record
handlers.bp_del = planners.delete
handlers.undo = history.undo
handlers.redo = history.redo
handlers.craft = puppet.craft
handlers.shoot = combat.shoot
handlers.gun = combat.gun
handlers.enter = driving.enter
handlers.drive = driving.drive
handlers.open = screens.open
handlers.close = screens.close
handlers.set_recipe = screens.set_recipe
handlers.take = screens.take
handlers.put = screens.put
handlers.set_cb = screens.set_combinator
handlers.set_schedule = screens.set_schedule
handlers.train_go = screens.train_go
handlers.train_mode = screens.train_mode
handlers.set_stop = screens.set_stop
handlers.set_interrupts = screens.set_interrupts
handlers.train_temp = screens.train_temp
requests.add("trains_list", trains.list, 100)
handlers.trains_list = requests.handler("trains_list")
handlers.train_mode_id = trains.set_mode_by_id
handlers.set_requests = screens.set_requests
handlers.set_storage_filter = screens.set_storage_filter
handlers.set_chest_logistics = screens.set_chest_logistics
handlers.set_char_requests = logistics.set_char_requests
handlers.land = planets.land
handlers.move = inventory.move
handlers.xfer = inventory.xfer
handlers.sort = inventory.sort
handlers.inv_filter = inventory.set_filter
handlers.qb_set = inventory.qb_set
handlers.qb_sel = inventory.qb_sel
handlers.qb_page = inventory.qb_page
handlers.cancel_craft = crafting.cancel_craft
handlers.research = research.research
handlers.research_cancel = research.research_cancel
handlers.map = map.request
handlers.tag_add = map.add_tag
handlers.tag_del = map.remove_tag
handlers.unghost = map.unghost
handlers.mtr = map.trains
handlers.mrp = map.roboports
handlers.lpad = map.landing_pad
handlers.bfar = belt_items.set_far
handlers.bre = belt_items.resend
handlers.rate = rate.set
handlers.budget = budget.set
handlers.photo = photo.set

-- {si, x, y}: the remote view looks at another surface (a planet or one of the force's
-- platforms), so the world streamed is that surface's, round (x, y); si 0 (or the character's)
-- goes back. The tick sees the change and sends `surface` with `view` set.
function handlers.view(cmd)
  local s = storage.f3d
  local c = puppet.get()
  local si = math.floor(tonumber(cmd.si) or 0)
  local surface = si > 0 and game.get_surface(si) or nil
  local allowed = false
  if surface and c and surface ~= c.surface then
    local okp, platform = pcall(function() return surface.platform end)
    local okq, planet = pcall(function() return surface.planet end)
    allowed = (okp and platform ~= nil and platform.valid and platform.force == c.force) or (okq and planet ~= nil)
  end
  if allowed then
    s.view_si, s.view_from = si, c.surface.index
    s.view_at = { x = (world.fixed_in(cmd.x) or 0) / 256, y = (world.fixed_in(cmd.y) or 0) / 256 }
  else
    s.view_si, s.view_at, s.view_from = nil, nil, nil
  end
end

-- While the remote view shows another surface, what Factorio's remote view allows goes to that
-- surface (puppet.surface): ghosts, planners, rotating, settings, copy and paste, undo. Building
-- there only ever places ghosts. What needs the character's hands waits (opening buildings there
-- works: screens.lua takes the surface).
local VIEW_BLOCKED = {}
for _, t in ipairs({ "mine", "pickup", "shoot", "drop", "fast", "wire", "wire_clear", "throw" }) do
  VIEW_BLOCKED[t] = true
end
local REMOTE_OK = {}
for _, t in ipairs({ "build", "blueprint", "decon", "upgrade", "rotate", "undo", "redo", "paste_settings",
                     "flip", "copy", "paste", "tile", "tile_mine", "rails", "unghost", "modreq" }) do
  REMOTE_OK[t] = true
end
local GHOST_ONLY = { build = true, tile = true, rails = true }
-- Also refused while riding a rocket or pod, or sitting in a hub (dispatch).
local RIDE_BLOCKED = {}
for _, t in ipairs({ "walk", "enter", "ride", "plat_board" }) do
  RIDE_BLOCKED[t] = true
end
handlers.plat_go = platforms.go
handlers.plat_sched = platforms.set_schedule
handlers.plat_pause = platforms.pause
handlers.plat_board = platforms.board_command
handlers.set_inserter = screens.set_inserter
handlers.set_splitter = screens.set_splitter
handlers.set_switch = screens.set_switch
handlers.set_panel = screens.set_panel
handlers.set_bar = screens.set_bar
handlers.set_cc = screens.set_circuit
handlers.set_color = screens.set_color
handlers.set_lamp = screens.set_lamp
handlers.set_desc = screens.set_desc
handlers.set_speaker = screens.set_speaker
handlers.set_pump = screens.set_pump
handlers.set_targets = screens.set_targets
handlers.set_vehicle = screens.set_vehicle
handlers.set_artillery = screens.set_artillery
handlers.flush = screens.flush
handlers.set_train_group = screens.set_train_group
handlers.spider_go = spiders.go
handlers.spider_q = spiders.query
handlers.wire = wiring.wire
handlers.wire_clear = wiring.clear
handlers.drop = ui_actions.drop
handlers.fast = ui_actions.fast
handlers.paste_settings = planners.paste_settings
handlers.flip = ui_actions.flip
handlers.copy = ui_actions.copy
handlers.paste = ui_actions.paste
handlers.alt = ui_actions.alt
handlers.chat = ui_actions.chat
requests.add("stats", ui_actions.stats, 300)
handlers.stats = requests.handler("stats")
handlers.eq_put = equipment.put
handlers.eq_take = equipment.take
handlers.eq_move = equipment.move
handlers.eq_toggle = equipment.toggle
handlers.respawn = puppet.respawn
handlers.tile = tiles.place
handlers.tile_mine = tiles.mine
handlers.throw = capsules.throw
handlers.rails = rail_planner.build
space.add_handlers(handlers, screens)
-- set_section with u = 0 is the character's own sections; any other u is the open entity's.
local entity_section = handlers.set_section
handlers.set_section = function(cmd)
  if tonumber(cmd.u) == 0 then
    return logistics.set_char_section(cmd)
  end
  return entity_section(cmd)
end
handlers.set_char_color = logistics.set_char_color
handlers.gfx = gfx.ask
requests.add("pedia_index", pedia.index, 300)
handlers.pedia_index = requests.handler("pedia_index")
requests.add("pedia", pedia.page, 150)
handlers.pedia = requests.handler("pedia")
requests.add("lnets", logistics.networks, 300)
handlers.lnets = requests.handler("lnets")
requests.add("lnet", logistics.network, 150)
handlers.lnet = requests.handler("lnet")
requests.add("bonuses", force_info.bonuses, 300)
handlers.bonuses = requests.handler("bonuses")
requests.add("perms", force_info.permissions, 100)
handlers.perms = requests.handler("perms")
handlers.cmd = console.run
handlers.mpress = mod_gui.press
handlers.modreq = modules.request
requests.add("hinfo", modules.hover, 50)
handlers.hinfo = requests.handler("hinfo")

local function dispatch(handler, msg, port)
  local s = storage.f3d
  if msg.t ~= "hello" and not (s.client and s.client.port == port) then
    return
  end
  if s.view_si and VIEW_BLOCKED[msg.t] then
    transport.send_now({ t = "msg", text = "Not from another surface: that works where the character is" })
    return
  end
  if s.view_si and REMOTE_OK[msg.t] then
    s.act_si = s.view_si
    if GHOST_ONLY[msg.t] then
      msg.ghost = 1
    end
  end
  -- Riding a rocket or cargo pod nothing acts on the world; inside a platform's hub the platform
  -- is worked as from the remote view, as a player in a hub does: ghosts, not hands.
  local c = (RIDE_BLOCKED[msg.t] or VIEW_BLOCKED[msg.t] or REMOTE_OK[msg.t]) and puppet.get()
  if c then
    local pod, hub = puppet.pod(c), puppet.hub(c)
    if pod or (hub and (RIDE_BLOCKED[msg.t] or VIEW_BLOCKED[msg.t])) then
      if msg.t ~= "walk" then
        transport.send_now({ t = "msg", text = pod and "Not while flying" or "Not from inside the hub" })
      end
      return
    end
    if hub and GHOST_ONLY[msg.t] then
      msg.ghost = 1
    end
  end
  local ok, err = pcall(handler, msg, port)
  s.act_si = nil
  if not ok then
    log("[factorio-3d-bridge] error handling '" .. msg.t .. "': " .. tostring(err))
    transport.send_now({ t = "msg", text = "Bridge error: " .. tostring(err) })
  end
end

-- At most this many characters wait for their clients. The client makes a new session id each
-- time it starts, so a restarted client never takes its old character back; and a hello and a
-- bye from a new id each time made a character (with the starter kit) and a storage entry per
-- pair, forever. Past the cap a new client takes over the character that has waited longest.
local MAX_PARKED = 16

local function oldest_parked(parked, at)
  local best, best_tick
  for sid, c in pairs(parked) do
    local t = at[sid] or 0
    if c.valid and (not best or t < best_tick or (t == best_tick and sid < best)) then
      best, best_tick = sid, t
    end
  end
  return best
end

-- A new client next to the first: a fresh state, with its old character if it was here before.
local function add_client(msg, port)
  local state = { extra = true }
  storage.f3d_parked = storage.f3d_parked or {}
  storage.f3d_parked_at = storage.f3d_parked_at or {}
  local parked, at = storage.f3d_parked, storage.f3d_parked_at
  for sid, c in pairs(parked) do
    if not c.valid then
      parked[sid], at[sid] = nil, nil
    end
  end
  local sid = tostring(msg.sid or "")
  if not parked[sid] and table_size(parked) >= MAX_PARKED then
    sid = oldest_parked(parked, at) or sid
  end
  local c = parked[sid]
  parked[sid], at[sid] = nil, nil
  extras()[port] = state
  M.serve(state, function()
    M.init_storage()
    if c and c.valid then
      state.puppet = c
    end
    dispatch(handlers.hello, msg, port)
  end)
end

function M.on_packet(event)
  local ok_decode, msg = pcall(helpers.json_to_table, event.payload)
  if not ok_decode or type(msg) ~= "table" or type(msg.t) ~= "string" then
    return
  end
  if msg.t == "launching" then
    if event.source_port == M.LAUNCH_PORT then
      M.launch_answered(event, msg)
    end
    return
  end
  local handler = handlers[msg.t]
  if not handler then
    return
  end
  local port = event.source_port
  console.from_player = tonumber(event.player_index) or 0
  local extra = extras()[port]
  if extra then
    return M.serve(extra, dispatch, handler, msg, port)
  end
  local s = storage.f3d
  -- In single-player the game plays one character, so a new port takes over, as before.
  if msg.t == "hello" and s.client and s.client.port ~= port and game.is_multiplayer() then
    if table_size(extras()) < MAX_EXTRA then
      add_client(msg, port)
    end
    return
  end
  profile.run("pkt:" .. msg.t, dispatch, handler, msg, port)
end

-- Returns false when there is no live client this tick.
function M.tick()
  local s = storage.f3d
  if game.tick - s.client.last_seen > TIMEOUT then
    drop_client()
    return false
  end
  local raised = s.client.raised
  if raised then
    if s.client.last_seen > raised.tick then
      s.client.raised = nil
    elseif game.tick - raised.tick > M.RAISE_ANSWER then
      local player = game.get_player(raised.player)
      log("[Zenith] Show in Zenith: the connected Zenith didn't answer, asking the launcher")
      s.client.raised = nil  -- silent, it no longer counts as fresh, and the timeout drops it
      if player and player.valid then
        player.print({ "f3d-launch.raise-lost" })
        M.ask_launch({ player_index = raised.player })
      end
    end
  end
  -- A new character (a respawn after death) starts over, so the client's avatar is the new one.
  -- The same character on another surface (a space platform, or in single-player wherever the
  -- player went) only changes the world.
  local c = puppet.get()
  if c and s.view_si and c.surface.index ~= s.view_from then
    s.view_si, s.view_at, s.view_from = nil, nil, nil  -- the character went somewhere itself
  end
  if c and c.unit_number ~= s.puppet_unit then
    M.handshake()
  elseif c and world.surface().index ~= s.surface_index then
    M.change_surface(c)
  end
  return true
end

function M.status_command(cmd)
  local s = storage.f3d
  local lines = barrier.report()  -- first: a step failing is the news
  for port, state in pairs(extras()) do
    local c = state.puppet
    lines[#lines + 1] = string.format("[Zenith] another client on port %d, its character at %s", port,
      c and c.valid and string.format("%.1f, %.1f on %s", c.position.x, c.position.y, c.surface.name) or "none yet")
  end
  if s.client then
    local subs = 0
    for _ in pairs(s.subs) do
      subs = subs + 1
    end
    lines[#lines + 1] = string.format(
      "[Zenith] client on port %d, last seen %d ticks ago; %d chunks subscribed, %d queued, %d messages waiting",
      s.client.port, game.tick - s.client.last_seen, subs, #s.queue, transport.backlog())
    if rate.level() > 0 then
      lines[#lines + 1] = "[Zenith] slowed down to rate level " .. rate.level() .. " (the client's `rate`)"
    end
    -- The client's protocol (its hello's `v`): one of an incompatible release reads messages wrong.
    if s.client.v and s.client.v ~= M.PROTOCOL then
      lines[#lines + 1] = string.format("[Zenith] the client speaks protocol %s and this bridge %d: update the older one",
        tostring(s.client.v), M.PROTOCOL)
    end
  else
    lines[#lines + 1] = "[Zenith] no client connected. Is Factorio running with --enable-lua-udp <port>?"
  end
  local c = puppet.get()
  if c then
    lines[#lines + 1] = string.format("[Zenith] character at %.1f, %.1f on %s", c.position.x, c.position.y, c.surface.name)
    local held = puppet.held_for()
    local player = held or puppet.player_of(c)
    lines[#lines + 1] = player and string.format("[Zenith] playing as %s%s", player.name,
      held and " (standing in while they're not connected)" or "") or "[Zenith] playing the bridge's own character"
  end
  for _, line in ipairs(budget.report()) do
    lines[#lines + 1] = line
  end
  for _, line in ipairs(profile.report()) do
    lines[#lines + 1] = line
  end
  M.reply(cmd, lines)
end

function M.selftest_command(cmd)
  M.reply(cmd, selftest.run())
end

-- Without a player the command came from the server console or RCON (or the client's console,
-- through `cmd`: console.capture). rcon.print answers RCON,
-- and print reaches the console's stdout (plain strings only); game.print would only go to the
-- chat.
function M.reply(cmd, lines)
  if console.capture then
    -- Only text goes back (`cmdr` is JSON kept in the outbox): /f3d-profile's lines carry
    -- profilers, which only Factorio can print, so they stay in Factorio's console and RCON.
    local held = false
    for _, line in ipairs(lines) do
      if type(line) == "string" then
        console.capture[#console.capture + 1] = line
      else
        held = true
      end
    end
    if held then
      console.capture[#console.capture + 1] =
        "[Zenith] the profiler's times print only in Factorio: /f3d-status in its console or over RCON"
    end
    return
  end
  local player = cmd.player_index and game.get_player(cmd.player_index)
  for _, line in ipairs(lines) do
    if player then
      player.print(line)
    else
      rcon.print(line)
      if type(line) == "string" then
        print(line)
      end
    end
  end
end

function M.platform_command(cmd)
  -- `new` makes a platform and its surface out of nothing, for tests: from Factorio's console or
  -- RCON only. From Zenith's console (`cmd` over UDP, which anything on localhost can send) each
  -- packet made another surface, for good.
  if console.capture and tostring(cmd.parameter or ""):match("^%s*(%S+)") == "new" then
    M.reply(cmd, { "[Zenith] /f3d-platform new works from Factorio's console or RCON, not from Zenith's" })
    return
  end
  M.reply(cmd, platforms.console(cmd))
end

function M.player_command(cmd)
  M.reply(cmd, puppet.player_command(cmd))
end

-- /f3d-rate <0-3>: every client's slow-down level, as its `rate` command would set it (for
-- measuring; the client sets its own).
function M.rate_command(cmd)
  local l = tonumber(cmd.parameter) or 0
  M.each_client(rate.set, { l = l })
  M.reply(cmd, { "[Zenith] rate level " .. rate.level() })
end

-- /f3d-bs [name on|off|number|default]: the belt simulation's switches (belt_sim.lua), to test its
-- fixes one by one; with no arguments it says them.
function M.bs_command(cmd)
  M.reply(cmd, belt_sim.option_command(cmd.parameter))
end

function M.profile_command(cmd)
  local n = tostring(cmd.parameter or ""):match("^%s*trace%s*(%d*)")
  if n then
    local ticks = profile.trace(n ~= "" and n or 600)
    M.reply(cmd, { "[Zenith] tracing each module's time for " .. ticks .. " ticks into the log (f3dtrace lines)" })
    return
  end
  local on = profile.toggle()
  M.reply(cmd, { on and "[Zenith] profiling on: /f3d-status shows each module's time per tick after 10 s"
    or "[Zenith] profiling off" })
end

console.extra["f3d-status"] = M.status_command
console.extra["f3d-selftest"] = M.selftest_command
console.extra["f3d-platform"] = M.platform_command
console.extra["f3d-player"] = M.player_command
console.extra["f3d-profile"] = M.profile_command
console.extra["f3d-rate"] = M.rate_command
console.extra["f3d-bs"] = M.bs_command

return M
