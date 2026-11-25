-- Turns game events into add / remove / update deltas for chunks the client is watching.

local registry = require("scripts.registry")
local transport = require("scripts.transport")
local world = require("scripts.world")
local rate = require("scripts.rate")
local alt_mode = require("scripts.alt_mode")
local belt_switch = require("scripts.belt_switch")
local perf = require("scripts.perf")
local budget = require("scripts.budget")
local profile = require("scripts.profile")
local corpses = require("scripts.corpses")

local M = {}

local WIRE_INTERVAL = 30

-- Belt shapes depend on their neighbours, so a change to one belt can bend the ones next to it.
local BELT_TYPES = registry.BELT_SET

local function watched(entity)
  return entity and entity.valid and registry.is_static(entity.type) and world.is_subscribed(entity.surface, entity.position)
end

-- The wires the client was just sent with an entity's record, as the wire look's last look
-- (s.wire_sigs): without it the strips' first look at a new pole (up to 4 s later) was taken as the
-- start, so a wire a script, a blueprint or another player's hand changed in between was never sent
-- (live_check's two poles, disconnected and wired again by script, passed only when their strip came
-- round in time). Wired types from the prototypes alone (registry), the same on every peer.
local wired_set
local function note_wires(entity)
  local s = storage.f3d
  local unit = entity.unit_number
  if not (s.wire_sigs and unit) then
    return
  end
  if not wired_set then
    wired_set = {}
    for _, t in pairs(registry.wired_types()) do
      wired_set[t] = true
    end
  end
  if wired_set[entity.type] then
    s.wire_sigs[unit] = world.wire_signature(entity)
  end
end

local function send_entity(t, e)
  local p = e.position
  transport.send_reliable_priority({ t = t, e = world.record(e) }, math.floor(p.x / 32), math.floor(p.y / 32))
end

local function refresh_neighbour_belts(entity)
  local p = entity.position
  local belts = entity.surface.find_entities_filtered({
    area = { { p.x - 1.5, p.y - 1.5 }, { p.x + 1.5, p.y + 1.5 } },
    type = "transport-belt",
  })
  for _, belt in pairs(belts) do
    if belt ~= entity and watched(belt) then
      send_entity("upd", belt)
    end
  end
end

-- Pipes next to an entity with fluid boxes connect to it (or stop connecting when it goes), so
-- their records change. Removals are looked at next tick, once the entity is gone.
local function refresh_pipes_near(surface, box)
  local types = registry.pipe_types()
  if #types == 0 then
    return
  end
  local pipes = surface.find_entities_filtered({
    area = { { box.left_top.x - 1, box.left_top.y - 1 }, { box.right_bottom.x + 1, box.right_bottom.y + 1 } },
    type = types,
  })
  for _, pipe in pairs(pipes) do
    if watched(pipe) then
      send_entity("upd", pipe)
    end
  end
end

-- Only with a client: tracker.tick, which empties `pipe_refresh`, runs only then, and the list is
-- saved with the game (on a server nobody plays through, it grew with every pipe removed).
local function fluid_neighbours_changed(entity, later)
  if not (storage.f3d.client and entity and entity.valid and registry.is_fluid(entity.type)) then
    return
  end
  -- Only pipes the client watches are sent (watched: a client, its surface), and tick() only runs
  -- with a client: without this every fluid entity removed on a server with no client connected
  -- was queued in storage until the next handshake, and every one built anywhere searched its box.
  local s = storage.f3d
  if not (s.client and entity.surface.index == s.surface_index) then
    return
  end
  local b = entity.bounding_box
  if later then
    s.pipe_refresh[#s.pipe_refresh + 1] = {
      surface = entity.surface.index,
      box = { left_top = { x = b.left_top.x, y = b.left_top.y }, right_bottom = { x = b.right_bottom.x, y = b.right_bottom.y } },
    }
  else
    refresh_pipes_near(entity.surface, b)
  end
end

-- Functions called with each entity built, changed or removed (map.lua forgets its charts there).
M.listeners = {}
-- Functions called with an entity whose settings were set again (pasted, its window closed, Zenith's own screen):
-- belt_sim.lua wakes the belts after a splitter (quiet_pc).
M.configure_listeners = {}

function M.configured(entity)
  if entity and entity.valid then
    for _, f in ipairs(M.configure_listeners) do
      f(entity)
    end
  end
end

local function tell(entity)
  world.touched(entity)
  for _, f in ipairs(M.listeners) do
    f(entity)
  end
end

-- events_enqueue (perf.lua, the bridge UPS plan's step 5): a game event about an entity the client watches
-- (built, marked, cancelled, flipped, rotated, recoloured) only tells the listeners and queues the entity;
-- its record (`add` / `upd`), its wires, the belts and pipes beside it and the decoratives under it are read
-- from on_tick (M.tick), nearest the focus first, EVENT_PRICE units each from the work budget (at least
-- EVENT_LEAST a tick). A thousand deconstruction marks in one tick made a 132 ms tick on the megabase.
-- The queue lives in storage.f3d.evq {pend = {key -> item}, list = {item...}, seq, sorted}: one item an
-- entity (key: unit number, or surface:name:x,y for those without one), its kind "add" or "upd" ("add" wins).
-- Order per entity is kept: an entity removed while queued has its record sent first (M.removed, still
-- valid), then its `del`, and nothing of it stays queued; one gone without M.removed (died, revived ghost)
-- is invalid by the drain and skipped. A direct call (the client's own actions) sends at once and takes
-- the entity off the queue (an `add` still queued goes out as `add`). Written only from events and
-- on_tick; the order from the focus in storage and a sequence number, so the same on every peer.
-- Off: each event does all of it at once, as before.
local EVENT_PRICE = 2
local EVENT_SHARE = 0.5
local EVENT_LEAST = 8
local EVENT_SORT_MIN = 32  -- shorter queues go oldest first, unsorted

local function event_key(entity)
  local u = entity.unit_number
  if u then
    return u
  end
  local p = entity.position
  return entity.surface.index .. ":" .. entity.name .. ":" .. p.x .. "," .. p.y
end

local function event_queue()
  local s = storage.f3d
  local q = s.evq
  if not q then
    q = { pend = {}, list = {}, seq = 0, sorted = true }
    s.evq = q
  end
  return q
end

-- Takes an entity off the queue: its kind ("add" or "upd"), or nil when it wasn't queued.
local function take_pending(entity)
  local q = storage.f3d and storage.f3d.evq
  if not (q and entity and entity.valid) then
    return nil
  end
  local key = event_key(entity)
  local item = q.pend[key]
  if not item then
    return nil
  end
  q.pend[key] = nil
  item.done = true  -- left in the list, dropped when the drain reaches it
  return item.k
end

local function enqueue(entity, kind)
  local q = event_queue()
  local key = event_key(entity)
  local item = q.pend[key]
  if item then
    if kind == "add" then
      item.k = "add"
      item.e = entity
    end
    return
  end
  q.seq = q.seq + 1
  local p = entity.position
  item = { e = entity, k = kind, key = key, x = p.x, y = p.y, n = q.seq }
  q.pend[key] = item
  q.list[#q.list + 1] = item
  q.sorted = false
end

-- Entities queued (/f3d-status, the budget's `wb`, tests).
function M.event_queue_length()
  local q = storage.f3d and storage.f3d.evq
  if not q then
    return 0
  end
  local n = 0
  for _ in pairs(q.pend) do
    n = n + 1
  end
  return n
end
budget.register_queue("events", M.event_queue_length)

local added_work, changed_work

function M.added(entity)
  tell(entity)
  added_work(entity, take_pending(entity))
end

added_work = function(entity)
  fluid_neighbours_changed(entity, false)
  -- Building removes the decoratives under the entity: in every chunk its box reaches (a rocket
  -- silo by a chunk's edge cleared its neighbour's too, which wasn't sent again).
  if entity and entity.valid then
    world.decoratives_changed_in(entity.surface, entity.bounding_box)
  end
  if watched(entity) then
    send_entity("add", entity)
    note_wires(entity)
    if BELT_TYPES[entity.type] then
      refresh_neighbour_belts(entity)
    end
  end
end

local RECOLOURED = { locomotive = true, ["cargo-wagon"] = true, ["fluid-wagon"] = true, ["artillery-wagon"] = true,
  ["train-stop"] = true }

function M.changed(entity)
  tell(entity)
  changed_work(entity, take_pending(entity))
end

-- `pending`: what was still queued for it ("add": the client hasn't had it yet).
changed_work = function(entity, pending)
  fluid_neighbours_changed(entity, false)
  if watched(entity) then
    send_entity(pending == "add" and "add" or "upd", entity)
    note_wires(entity)
    if BELT_TYPES[entity.type] then
      refresh_neighbour_belts(entity)
    end
  end
end

-- An entity turned (the client's R, a player's in the game, undo): its record, and an underground
-- belt's other end's too. LuaEntity.rotate turns a connected pair together, both swapping entrance
-- and exit and facing the other way (measured in 2.1.24), and nothing tells of the other end (J23:
-- the client drew only the one turned).
local function rotated(entity, changed)
  changed(entity)
  if not (entity and entity.valid and entity.type == "underground-belt") then
    return
  end
  local ok, other = pcall(function() return entity.underground_belt_neighbour end)
  if not ok then
    ok, other = pcall(function() return entity.neighbours end) -- 2.0's name for it
  end
  if ok and other and other.valid then
    changed(other)
  end
end

function M.rotated(entity)
  rotated(entity, M.changed)
end

-- The events' side (events_enqueue): the listeners told now, the rest queued for M.tick. An entity the client
-- doesn't watch has nothing to queue (no record goes): the old path, which reads nothing more for it.
local function event_with(entity, kind)
  if not (perf.on("events_enqueue") and watched(entity)) then
    if kind == "add" then
      M.added(entity)
    else
      M.changed(entity)
    end
    return
  end
  tell(entity)
  enqueue(entity, kind)
end

function M.event_added(entity)
  event_with(entity, "add")
end

function M.event_changed(entity)
  event_with(entity, "upd")
end

function M.event_rotated(entity)
  rotated(entity, M.event_changed)
end

-- Queued entities' work, nearest the focus first, under the budget (from on_tick, before anything else
-- reads the deltas' order: tracker is the second step).
local function drain_events(s)
  local q = s.evq
  if not q or #q.list == 0 then
    return
  end
  local list = q.list
  local n = #list
  if not q.sorted and n > EVENT_SORT_MIN then
    -- Farthest first, so the nearest is taken off the end; ties by queue order (the oldest last, taken first).
    local f = s.focus
    local fx, fy = f.x, f.y
    for i = 1, n do
      local it = list[i]
      local dx, dy = it.x - fx, it.y - fy
      it.d = dx * dx + dy * dy
    end
    table.sort(list, function(a, b)
      if a.d ~= b.d then
        return a.d > b.d
      end
      return a.n > b.n
    end)
    q.sorted = true
  end
  local tp = profile.start()
  local done = 0
  local sorted = q.sorted
  -- (A sorted queue stays nearest first, taken from the end, however short it gets; an unsorted, short
  -- queue goes oldest first.)
  local i, last = sorted and n or 1, n
  while (sorted and i >= 1) or (not sorted and i <= last) do
    local it = list[i]
    if not it.done then
      if done >= EVENT_LEAST and not budget.can(EVENT_PRICE, "events", EVENT_SHARE) then
        break
      end
      it.done = true
      q.pend[it.key] = nil
      local e = it.e
      if e and e.valid then
        if it.k == "add" then
          added_work(e)
        else
          changed_work(e, nil)
        end
      end
      budget.spend(EVENT_PRICE, "events")
      done = done + 1
    end
    if sorted then
      list[i] = nil
    end
    i = sorted and i - 1 or i + 1
  end
  if sorted then
    -- Taken off the end: what is left is list[1..i].
    if next(q.pend) == nil then
      q.list, q.sorted = {}, true
    end
  else
    -- Taken from the front: keep list[i..last].
    local rest = {}
    for j = i, last do
      if not list[j].done then
        rest[#rest + 1] = list[j]
      end
    end
    q.list = rest
    if #rest == 0 then
      q.sorted = true
    end
  end
  profile.stop("tracker.events", tp)
end

-- The "del" message for an entity, built while it is still valid. Nil if the client can't see it.
function M.removal_message(entity)
  if not watched(entity) then
    return nil
  end
  local p = entity.position
  return {
    t = "del",
    u = entity.unit_number or 0,
    p = registry.entity_id(entity.name),
    x = world.fixed(p.x),
    y = world.fixed(p.y),
  }
end

-- (K22, /f3d-perf mined_tell) An entity the bridge itself is about to remove where Factorio raises nothing (a
-- player-less character's mining): what listens hears of it now, as M.removed's listeners do (the belt simulation
-- drops its lanes next tick). The removal message is the caller's, once it happened: should the mining fail, what
-- listened only works the place out again.
function M.removing(entity)
  if entity and entity.valid then
    tell(entity)
  end
end

-- (/f3d-perf mined_neighbours) An entity the bridge itself is about to remove where Factorio raises nothing (a
-- player-less character's mining): the pipes and belts beside it change shape once it is gone, so they are looked
-- at next tick, as M.removed has them. Should the mining fail, they are only sent again as they are.
function M.neighbours_change(entity)
  if not (entity and entity.valid) then
    return
  end
  fluid_neighbours_changed(entity, true)
  if BELT_TYPES[entity.type] and watched(entity) then
    local s = storage.f3d
    local p = entity.position
    s.belt_refresh[#s.belt_refresh + 1] = { surface = entity.surface.index, x = p.x, y = p.y }
  end
end

-- Called while the entity is still valid (before it is removed).
function M.removed(entity)
  -- (events_enqueue) Still queued: its record first, while it is valid, so its `del` comes after it.
  local pending = take_pending(entity)
  if pending == "add" then
    added_work(entity)
  elseif pending then
    changed_work(entity, nil)
  end
  tell(entity)
  local s = storage.f3d
  if s.wire_sigs and entity.valid and entity.unit_number then
    s.wire_sigs[entity.unit_number] = nil
    if s.wire_at then
      s.wire_at[entity.unit_number] = nil
    end
  end
  fluid_neighbours_changed(entity, true)
  local pos = entity.valid and entity.position or nil
  local msg = M.removal_message(entity)
  if msg then
    local cx = pos and math.floor(pos.x / 32) or math.floor(msg.x / 8192)
    local cy = pos and math.floor(pos.y / 32) or math.floor(msg.y / 8192)
    transport.send_reliable_priority(msg, cx, cy)
    -- Neighbouring belts only change shape once this one is gone, so look at them next tick.
    if BELT_TYPES[entity.type] then
      local s = storage.f3d
      local p = entity.position
      s.belt_refresh[#s.belt_refresh + 1] = { surface = entity.surface.index, x = p.x, y = p.y }
    end
  end
end

-- A rolling stock ghost the client was sent is gone (world.lua, stock_ghost): built by robots,
-- mined or cancelled, none of which the client otherwise hears of for a ghost of a mover.
function M.on_object_destroyed(event)
  local s = storage.f3d
  local g = s and s.stock_ghosts and s.stock_ghosts[event.registration_number]
  if not g then
    return
  end
  s.stock_ghosts[event.registration_number] = nil
  local surface = game.get_surface(g.s)
  if surface and world.is_subscribed(surface, { x = g.x / 256, y = g.y / 256 }) then
    transport.send_reliable_priority({ t = "del", u = g.u, p = g.p, x = g.x, y = g.y },
      math.floor(g.x / 8192), math.floor(g.y / 8192))
  end
end

-- Deconstructing an area (planner, shortcut, cut) deletes the ghosts in it at once and raises no
-- event for them, so `act` runs between a look at the ghosts before and after: those gone get `del`.
function M.deconstructing(surface, area, force, act)
  local before = {}
  for _, g in pairs(surface.find_entities_filtered({ area = area, type = { "entity-ghost", "tile-ghost" }, force = force })) do
    local msg = M.removal_message(g)
    if msg then
      local p = g.position
      before[#before + 1] = { g, msg, math.floor(p.x / 32), math.floor(p.y / 32) }
    end
  end
  act()
  for _, b in ipairs(before) do
    if not b[1].valid then
      transport.send_reliable_priority(b[2], b[3], b[4])
    end
  end
end

-- Wires added or removed between existing poles and combinators near the focus raise no event in
-- 2.x, so their wires are compared with the last look every half second; a change sends `upd`.
-- The last look is kept in storage (it decides what goes into the reliable stream).
local function watch_wires(s)
  local types = registry.wired_types()
  if #types == 0 then
    return
  end
  local f = s.focus
  local seen = {}
  local found = world.surface().find_entities_filtered({
    area = { { f.x - f.r, f.y - f.r }, { f.x + f.r, f.y + f.r } },
    type = types,
  })
  rate.read("wires", #found)
  for _, e in pairs(found) do
    local unit = e.unit_number
    if unit then
      local sig = world.wire_signature(e)
      local before = s.wire_sigs[unit]
      seen[unit] = sig
      if before and before ~= sig and watched(e) then
        send_entity("upd", e)
        pcall(belt_switch.rewired, e)
      end
    end
  end
  s.wire_sigs = seen
  s.wire_at, s.wire_in = nil, nil
end

-- wire_strips (perf.lua): the focus square in WIRE_STRIPS strips of rows, one each run, so each wire is
-- looked at every 4 s (8 x 30 ticks) instead of every half second; the whole square cost 13.5 ms (up to
-- 49) on one tick twice a second on the owner's base. The client's own wire tools send their change at
-- once (wiring.lua) and built or mined entities carry their wires in their records: what is left for
-- this look is another player's hand, a blueprint pasted over poles and scripts, now up to 4 s late.
-- An entity belongs to the strip its centre is in. Each strip's signatures are merged into
-- s.wire_sigs (unit -> signature); s.wire_at (unit -> strip) and s.wire_in (strip -> {unit = true})
-- forget the ones a strip no longer finds. All in storage, from on_tick.
local WIRE_STRIPS = 8

local function watch_wire_strip(s)
  local types = registry.wired_types()
  if #types == 0 then
    return
  end
  local strip = (s.wire_strip or 0) % WIRE_STRIPS + 1
  s.wire_strip = strip
  s.wire_at = s.wire_at or {}
  s.wire_in = s.wire_in or {}
  local f = s.focus
  local h = 2 * f.r / WIRE_STRIPS
  local ya = f.y - f.r + (strip - 1) * h
  local yb = strip == WIRE_STRIPS and f.y + f.r or ya + h
  local found = world.surface().find_entities_filtered({
    area = { { f.x - f.r, ya }, { f.x + f.r, yb } },
    type = types,
  })
  rate.read("wires", #found)
  local sigs, at = s.wire_sigs, s.wire_at
  local mine = {}
  for _, e in pairs(found) do
    local unit = e.unit_number
    local y = unit and e.position.y
    if unit and y >= ya and (y < yb or strip == WIRE_STRIPS) then
      local sig = world.wire_signature(e)
      local before = sigs[unit]
      sigs[unit], at[unit], mine[unit] = sig, strip, true
      if before and before ~= sig and watched(e) then
        send_entity("upd", e)
        pcall(belt_switch.rewired, e)
      end
    end
  end
  -- Gone from this strip, and not found in another since: forgotten (as the whole look's replace did).
  for unit in pairs(s.wire_in[strip] or {}) do
    if not mine[unit] and at[unit] == strip then
      sigs[unit], at[unit] = nil, nil
    end
  end
  s.wire_in[strip] = mine
end

function M.tick()
  local s = storage.f3d
  drain_events(s)
  if rate.due("wires", WIRE_INTERVAL) then
    if perf.on("wire_strips") then
      watch_wire_strip(s)
    else
      watch_wires(s)
    end
  end
  if #s.pipe_refresh > 0 then
    local pending = s.pipe_refresh
    s.pipe_refresh = {}
    for _, at in pairs(pending) do
      local surface = game.get_surface(at.surface)
      if surface then
        refresh_pipes_near(surface, at.box)
      end
    end
  end
  if #s.belt_refresh == 0 then
    return
  end
  local pending = s.belt_refresh
  s.belt_refresh = {}
  for _, at in pairs(pending) do
    local surface = game.get_surface(at.surface)
    if surface then
      local belts = surface.find_entities_filtered({
        area = { { at.x - 1.5, at.y - 1.5 }, { at.x + 1.5, at.y + 1.5 } },
        type = "transport-belt",
      })
      for _, belt in pairs(belts) do
        if watched(belt) then
          send_entity("upd", belt)
        end
      end
    end
  end
end

function M.register()
  local function on_added(event)
    M.event_added(event.entity or event.destination)
  end
  script.on_event({
    defines.events.on_built_entity,
    defines.events.on_robot_built_entity,
    defines.events.on_space_platform_built_entity,
    defines.events.script_raised_built,
    defines.events.script_raised_revive,
    defines.events.on_entity_cloned,
  }, on_added)

  script.on_event({
    defines.events.on_player_mined_entity,
    defines.events.on_robot_mined_entity,
    defines.events.on_space_platform_mined_entity,
    defines.events.script_raised_destroy,
    defines.events.on_resource_depleted,
  }, function(event)
    M.removed(event.entity)
  end)
  -- on_entity_died is registered by combat.lua, which also tells the client about the death.
  -- What a building leaves when destroyed: its remnants, sent like a new entity.
  -- A character's corpse too (corpses.lua).
  script.on_event(defines.events.on_post_entity_died, function(event)
    local ok, err = pcall(corpses.on_post_entity_died, event)
    if not ok then
      log("[factorio-3d-bridge] corpses: " .. tostring(err))
    end
    for _, corpse in pairs(event.corpses or {}) do
      if corpse.valid and registry.remnant_of(corpse.name) then
        world.bump(corpse.surface.index, corpse.position)
      end
      if corpse.valid and registry.remnant_of(corpse.name)
          and world.is_subscribed(corpse.surface, corpse.position) then
        send_entity("add", corpse)
      end
    end
  end)

  -- Alt-mode's icon (issue #9) after settings pasted in the real game or a player there closing the
  -- machine's window (where its recipe or filters are set). The bridge's own paste sends `upd`.
  script.on_event(defines.events.on_entity_settings_pasted, function(event)
    alt_mode.check(event.destination)
    if event.destination then
      belt_switch.configured(event.destination)
      M.configured(event.destination)
    end
    if event.destination and event.destination.valid then
      world.bump(event.destination.surface.index, event.destination.position)
    end
  end)
  -- A train or stop repainted, from Zenith's screen or in the real game (H21).
  script.on_event(defines.events.on_entity_color_changed, function(event)
    if event.entity and event.entity.valid and RECOLOURED[event.entity.type] then
      M.event_changed(event.entity)
    end
  end)
  script.on_event(defines.events.on_gui_closed, function(event)
    if event.entity then
      alt_mode.check(event.entity)
      belt_switch.configured(event.entity)
      M.configured(event.entity)
      if event.entity.valid then
        world.bump(event.entity.surface.index, event.entity.position)
      end
    end
  end)

  -- A player's R in the game: an underground pair turns together (M.rotated).
  script.on_event(defines.events.on_player_rotated_entity, function(event)
    M.event_rotated(event.entity)
  end)
  -- Marks for deconstruction and upgrade show in the record (extra.d, extra.up).
  script.on_event({
    defines.events.on_player_flipped_entity,
    defines.events.on_marked_for_deconstruction,
    defines.events.on_cancelled_deconstruction,
    defines.events.on_marked_for_upgrade,
    defines.events.on_cancelled_upgrade,
  }, function(event)
    M.event_changed(event.entity)
  end)

  local function on_tiles(event)
    local surface = game.get_surface(event.surface_index)
    if not surface then
      return
    end
    local positions = {}
    for _, t in pairs(event.tiles) do
      positions[#positions + 1] = t.position
    end
    world.tiles_changed(surface, positions)
  end
  script.on_event({
    defines.events.on_player_built_tile,
    defines.events.on_robot_built_tile,
    defines.events.on_space_platform_built_tile,
    defines.events.on_player_mined_tile,
    defines.events.on_robot_mined_tile,
    defines.events.on_space_platform_mined_tile,
    defines.events.script_raised_set_tiles,
  }, on_tiles)

  script.on_event(defines.events.on_chunk_generated, function(event)
    world.on_chunk_generated(event.surface, event.position)
  end)
end

return M
