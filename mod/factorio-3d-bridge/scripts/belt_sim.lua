-- Belts for a client that simulates them itself (`bs` in its hello; docs/BELT-SIM-PLAN.md). The
-- client runs its own copy of Factorio's belt rules in step with the game, so the bridge sends each
-- lane once, as it is (its meta `lm` and its items `sl`, read on a tick it names), and after that
-- only what the belts themselves can't explain:
--
-- * Watched lanes, which something besides the belts touches: inserters' pickup and drop belts and
--   the belt behind a pickup belt, mining drills' drop belts, the belts next to loaders, splitters
--   and loaders themselves (until the client simulates them), belts with a circuit connection, and
--   the square's outermost ring (items leave it and come in from outside). Each is checked cheaply
--   every update (its count, front and back positions, items) and read in full when that changed,
--   sent in `sl` with the tick it was read on.
-- * Drift checks (`pc`): every other lane's cheap check about every PC_EVERY updates, which the
--   client compares with its own state at that tick; it asks again (`bre`) for lanes that differ.
-- * Anything built, mined, rotated or destroyed near a belt (tracker.listeners): those belts are
--   worked out again and their lanes sent again with `lm` and `sl`.
-- * Belts switched off or on by the circuit network (`of`).
-- * Lanes leaving the square, or whose belt is gone (`dl`).
--
-- The square grows ring by ring from the focus, its first loads nearest first, under a share of the
-- work budget (budget.lua) a tick and the client's cap (`bfar` m: items + lanes). Each update says
-- the square every lane of which is loaded (`fx`, `fy`, `fr`), the ticks between updates (`p`) and
-- the work it took (`w`). Nothing is carried forward: every read and check names its own tick.
-- With `/f3d-bs area trace` (M.OPTIONS) the square is only the scan's bound: what is loaded is the
-- near square (what the player sees), the belts feeding it back to their origins and the belts it
-- feeds a few belts on, so a belt that doesn't feed what is seen isn't loaded; fr is the near square.
--
-- Multiplayer: what is read and when (the scan, each belt's and lane's record, the queues) lives in
-- storage.f3d.bs and changes only from on_tick and events, from game reads. What is sent (the
-- message text being built) is module-local: a peer that loaded mid-update only sends less.

local registry = require("scripts.registry")
local transport = require("scripts.transport")
local world = require("scripts.world")
local map = require("scripts.map")
local rate = require("scripts.rate")
local tracker = require("scripts.tracker")
local budget = require("scripts.budget")
local profile = require("scripts.profile")

local M = {}

local floor = math.floor
local ceil = math.ceil

-- Lane keys: unit number * LANE_KEYS + line index (a splitter has 8 lines).
local LANE_KEYS = 8

-- What is sent is written as text where it is read (S): the small integers most of a `bs` part is
-- (positions, counts, item ids) from NUM, the big ones (unique ids, lane keys, the tick) memoised in
-- STR, emptied once it holds STR_MAX (keys and the tick recur every update, an item's id while it is
-- on the watched lanes). tostring of a number is the dear part of writing one, and a loop in Lua
-- over the numbers at send time cost as much again. Module-local: the same text on every peer.
local NUM = {}
for v = -1, 8192 do
  NUM[v] = tostring(v)
end
local STR, str_n = {}, 0
local STR_MAX = 60000
local function S(v)
  local s = NUM[v]
  if s then
    return s
  end
  s = STR[v]
  if not s then
    if str_n >= STR_MAX then
      STR, str_n = {}, 0
    end
    s = tostring(v)
    STR[v] = s
    str_n = str_n + 1
  end
  return s
end
-- Watched lanes unchanged at their last quiet_after checks are checked every quiet_ticks (0: every
-- update), and a watched lane whose items all moved on alike (nothing came or went) isn't sent
-- (skip_flow): the client simulates that. (Fields for tests.)
M.quiet_after = 3
M.quiet_ticks = 12
-- An input spot an inserter or drill uses (an actor, checked itself every update: its hand, its
-- progress) is checked at once when one acted; quiet, it is checked again only every spot_quiet_ticks
-- otherwise, as a safety net. (Fields for tests.)
M.spot_quiet_ticks = 60
-- A lane read again for the client (`bre`) is read with the packed run it belongs to: at most this
-- many belts ahead and behind. (Tests: 0 turns it off.)
M.run_belts = 6
M.skip_flow = true
-- Each unwatched lane's drift check comes about every this many updates (by its belt's place in
-- the scan: a few each update).
M.pc_every = 32
-- A watched belt that changed has the belts it feeds read too (tails); one that settled, those round
-- it (settle_around). (Fields for tests.)
M.tails = true
-- Packed lanes at their end checked by their front item's id too (front_moved).
M.identity = true
M.identity_ticks = 12
-- Work units an update for reads made for accuracy alone (extra_left).
M.extra_units = 2000
-- Lanes leading out that only moved on send their wall alone (`ew`).
M.edge_walls = true
-- First loads' units a tick, instead of the budget's share (tests).
M.load_cap = nil
M.settle_around = true
-- Inserters and drills this far outside a chunk can use its belts (a long-handed inserter reaches 2
-- tiles, a big drill drops 3.5 from its centre; modded ones a little more).
local REACH = 6
-- Work units of ~2 us (as belt_items.lua's): a lane checked (count, front, back, items), a line
-- object, an item read and written, a lane's meta (three positions, its kind), a belt worked out
-- (its neighbours and targets), a belt found or ranked in a scan.
local CHECK_UNITS = 3
local ITEM_UNITS = 4
local META_UNITS = 4
local WATCH_UNITS = 6
local TARGET_UNITS = 2
local FIND_UNITS = 5
local SCAN_UNITS = 0.25
local SKIP_UNITS = 0.05
-- Belt units per work-budget unit (belt_items.lua's).
local UNITS_PER_BUDGET_UNIT = 20
-- First loads take at most this share of the work budget a tick, and at least LOAD_MIN units.
local LOAD_SHARE = 0.5
local LOAD_MIN = 400
-- Steady work (checks, re-reads) a tick, at least; spread over the update's ticks from what the
-- last update took. On the due tick what is left is done up to DUE_BURST of that.
M.units_per_tick = 600
local DUE_BURST = 3
-- A scan is made again whenever the focus moves a tile, anything is built or removed, the radius or
-- cap changes, and at least every SCAN_EVERY updates (belts appearing without an event).
local SCAN_EVERY = 64
-- Numbers a `bs` part holds, about (a lane's items are never split); fewer under a small send_cap.
local PART_NUMBERS = 4000
-- Lanes a `bre` may ask for at once.
local BRE_MAX = 512
-- Lanes asked for again that may wait for their turn (bre_cap) at once.
local BRE_KEEP = 2048

-- What has been read and checked, since loading: module-local, for /c probes and tests.
M.counts = { checked = 0, changed = 0, quiet = 0, flow = 0, scan_moved = 0, scan_dirty = 0, scan_other = 0, read = 0, loaded = 0, meta = 0, pc = 0, dl = 0, of = 0, scans = 0, items = 0 }

-- Run-time switches (`/f3d-bs`, docs/RUNNING.md): each fix here can be turned off, the old behaviour
-- back, to test them one by one. feed_edges: lanes fed from outside what is sent checked on every
-- update's tick, never quiet; full_area: every belt within the belt item distance (off: the client's
-- Belt updates cap and the focus radius bound it, as before); inputs_first: inserters and drills
-- checked themselves, waking their belts, input spots first, the accuracy extras outside the steady
-- limit; line_rereads: `bre` lanes read in groups on one tick with their packed runs; bound: the share
-- of the work budget the belts' work a tick may take before the square is cut (0: never cut). One set
-- for every client, in storage.f3d_bs, changed only by the command; read into O at each tick's start.
-- Cost switches (each off: as before): actor_backoff: idle inserters checked less often, drills about
-- when their progress comes round (actor_check); drift_far: drift checks every pc_every updates within
-- DRIFT_NEAR tiles, half as often to twice that, a quarter as often beyond (make_queue); bre_cap: at most
-- this many lanes the client asked for again read an update, in the order asked, the rest waiting
-- their turn (at most BRE_KEEP; 0: all at once); quiet_backoff: watched lanes that stood for long checked less often (quiet_for).
-- pc_ids: every packed lane's drift check carries its front and back items' ids (`pu`), outside the
-- extra_units share (off: only while that share has room, as before: almost never at 160 tiles, so a
-- packed lane the client had a whole gap or more off by its ids, its places right, never showed). Off
-- by default: live at -62,-26 it changed nothing seen (visible 90.3 / 90.3%, Hold 60 UPS 92.1 / 92.7%).
-- hold_inputs: a splitter's input lane found unchanged at its check, as the client's last read of it left
-- it (a packed one by its front and back items' ids too), is sent in `sh`: the client holds its items
-- there (they don't cross into the outputs) until its next read, and puts back any it moved meanwhile.
-- The game's own update order holds a backed-up balancer's input a tick or more where the rules let
-- its item go (docs/BELT-RULES.md section 6); unseen, the client's balancers drained where the game's
-- stood and nothing sent it again (a watched lane is sent only when the game's changes).
-- area (the owner's design, docs/BELT-SIM-PLAN.md's trace round): `square` loads every belt within the
-- belt item distance; `trace` loads the belts within trace_near tiles of the focus (what the player sees
-- at the client's normal zoom: about 107 x 60 tiles), the belts feeding those traced back to their
-- origins (at most trace_hops belts back: an origin is a belt nothing loaded feeds, where the actors
-- that put items on it are checked), and the belts they feed trace_down belts on (where the line is
-- cut the exit lane's wall is watched every update, `ew`). Everything else within the belt item
-- distance is left out: the scan square (fr still says the square every belt of which is loaded, now
-- trace_near at most) stays the scan's bound. checkpoints: the lanes where our copy of the belt rules
-- is known to differ from the game by a tick (a splitter's inputs, a lane an inserter takes from, an
-- underground entrance an inserter drops on) are checked every update, never quiet, packed ones by
-- their ids, instead of trusting the simulation there between quiet checks. crossings sim|game (the
-- cross round): with game, every splitter's output lanes (lines 5-8, a lane splitter's 3-4) are checked
-- on every update, never quiet, a packed one by its ids, and read whenever anything but an even flow
-- happened, so the client gets each crossing within an update of the game making it (as `sl`); with sim
-- (the default) they are watched as any other lane (quiet when standing, read when changed).
-- own_rate: the updates follow their own rate.lua job (`bs`: tier 3, at most 12 ticks), so the client's
-- `rate` levels 1-2 (Hold 60 UPS's first steps) leave them at every f3d-detail-interval ticks and level 3
-- doubles them once; off, they follow the glided belt items' job (`bi`: tier 1, 12, 24, 48 ticks), as
-- before, which under Hold 60 UPS read every input spot only once in 24-48 ticks and left the owner's
-- bus with gaps along every lane (rate.lua's top).
-- drift_watched: watched belts' lanes (an inserter's or drill's belt, the belt behind a pickup belt, a
-- splitter, a loader, a wired belt) get drift checks (`pc`) in the same turns as the rest; off, as
-- before, they have none: a watched lane is sent only when the game's changes, so one the client got
-- wrong while the game's stood (a backed-up bus) stayed wrong, nothing telling the client to ask again.
-- Off by default: on the tick1 recording at -62,-26 (the offline harness, 600 ticks after a fast first
-- load, bre answered) it sent a third more drift checks and asks for nothing (by place 95.42 / 95.49% off,
-- phantoms 2.21 / 2.17%).
-- walk_load (the walk round): while the square every belt of which is loaded reaches less than walk_near
-- tiles from the focus (walking, a jump: what the player sees isn't all loaded yet), first loads get at
-- least walk_load units a tick instead of their share of the work budget (LOAD_MIN at Hold 60 UPS's
-- budget floor). Walking laps at -62,-26 with the character's own speed, the bridge loaded about 14
-- lanes a tick, under what the view brought in along the bus: the loaded square fell to 4-8 tiles and
-- the view showed a third of the bus. 0: as before.
-- send_cap (the perfbridge round): an update's parts are sent over the ticks that follow its due tick,
-- about this many bytes a tick (one part at least), oldest first, instead of all on the due tick. Every
-- part is about 28 KB and Windows gives the client's UDP socket 64 KB: of two or more sent in one tick
-- all but the first two were lost whenever the client didn't read between them (0.1-1% of parts at
-- -62,-26, always an update's last parts), and the due tick carried their whole text cost (bse.text,
-- 7-16 ms). The parts' tick `k` is the update's still. Under a cap below 30000 the parts are made
-- smaller with it (about cap / 7.5 numbers: a number is ~7 bytes), so a tick's bytes stay near the
-- cap. 0: all on the due tick, as before.
-- extra_spread (the perfbridge2 round): the reads made for accuracy alone (extra_units an update: the
-- packed runs round asked lanes, tails, reads round a settled belt) are spread over the update's ticks,
-- extra_units / (period - 1) a tick at most, the rest of the queue waiting a tick (never on the due
-- tick). Off: they land wherever their step comes, which for the asked lanes' runs was all on the
-- round's first tick (bs.bre 6-11 ms there at -62,-26, the update's worst tick after the due one).
M.OPTIONS = { feed_edges = true, full_area = true, inputs_first = true, line_rereads = true, bound = 0.6,
  actor_backoff = true, drift_far = true, bre_cap = 192, quiet_backoff = true, pc_ids = false, hold_inputs = true,
  area = "square", trace_near = 48, trace_hops = 200, trace_down = 8, checkpoints = false, crossings = "sim",
  own_rate = true, drift_watched = false, walk_load = 1200, walk_near = 96, send_cap = 30000, extra_spread = true }
M.OPTION_ORDER = { "feed_edges", "full_area", "inputs_first", "line_rereads", "bound", "actor_backoff", "drift_far",
  "bre_cap", "quiet_backoff", "pc_ids", "hold_inputs", "area", "trace_near", "trace_hops", "trace_down",
  "checkpoints", "crossings", "own_rate", "drift_watched", "walk_load", "walk_near", "send_cap", "extra_spread" }
-- The values a word switch takes.
M.OPTION_VALUES = { area = { square = true, trace = true }, crossings = { sim = true, game = true } }
local O = {}
local function read_options()
  local set = storage.f3d_bs or {}
  for _, k in ipairs(M.OPTION_ORDER) do
    local v = set[k]
    if v == nil then
      v = M.OPTIONS[k]
    end
    O[k] = v
  end
end

-- Numbers a part holds under the send_cap in force (O is read at each tick's start).
local function part_numbers()
  local cap = tonumber(O.send_cap) or 0
  if cap > 0 and cap < 30000 then
    return math.max(400, floor(cap / 7.5))
  end
  return PART_NUMBERS
end

-- `/f3d-bs [name value]`: sets a switch (on/off, a number for bound, `default` for its default) and
-- says them all. Returns the lines to print.
function M.option_command(param)
  -- (`/f3d-bs counts`: what has been read and checked since loading, M.counts, for measuring.)
  if tostring(param or ""):match("^%s*counts%s*$") then
    local keys = {}
    for k in pairs(M.counts) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = k .. "=" .. tostring(M.counts[k])
    end
    return { "[Zenith] bs counts " .. game.tick .. ": " .. table.concat(parts, " ") }
  end
  local name, value = tostring(param or ""):match("^%s*([%w_]+)%s+(%S+)")
  local out = {}
  if name then
    if M.OPTIONS[name] == nil then
      out[#out + 1] = "[Zenith] /f3d-bs: no switch " .. name
    else
      local v
      if value == "default" then
        v = nil
      elseif type(M.OPTIONS[name]) == "string" then
        if M.OPTION_VALUES[name][value] then
          v = value
        else
          local words = {}
          for w in pairs(M.OPTION_VALUES[name]) do
            words[#words + 1] = w
          end
          table.sort(words)
          out[#out + 1] = "[Zenith] /f3d-bs " .. name .. ": " .. table.concat(words, ", ") .. " or default"
          value = nil
        end
      elseif type(M.OPTIONS[name]) == "number" then
        v = tonumber(value) or (value == "off" and 0) or nil
        if v == nil then
          out[#out + 1] = "[Zenith] /f3d-bs " .. name .. ": a number, off or default"
        else
          v = math.max(0, math.min(name == "bound" and 10 or 100000, floor(v * 1000 + 0.5) / 1000))
        end
      elseif value == "on" or value == "1" or value == "true" then
        v = true
      elseif value == "off" or value == "0" or value == "false" then
        v = false
      else
        out[#out + 1] = "[Zenith] /f3d-bs " .. name .. ": on, off or default"
        value = nil
      end
      if value and (v ~= nil or value == "default") then
        storage.f3d_bs = storage.f3d_bs or {}
        storage.f3d_bs[name] = v
      end
    end
  end
  read_options()
  local parts = {}
  for _, k in ipairs(M.OPTION_ORDER) do
    local v = O[k]
    parts[#parts + 1] = k .. " " .. (v == true and "on" or v == false and "off" or tostring(v))
      .. ((storage.f3d_bs or {})[k] == nil and "" or " (set)")
  end
  out[#out + 1] = "[Zenith] belt simulation switches: " .. table.concat(parts, ", ")
  return out
end

local function chunk_key(x, y)
  return (floor(x / 32) + 32768) * 65536 + (floor(y / 32) + 32768)
end

local function state()
  local s = storage.f3d
  local b = s.bs
  -- (A save from before lanes leading out were kept, or before input spots woke their belts:
  -- everything is sent again.)
  if b and not (b.oset and b.iset and b.actors and b.alist and b.aseen and b.wake and b.bre) then
    b = nil
  end
  if not b then
    b = { belts = {}, lanes = {}, count = 0, work = 0, wset = {}, cset = {}, oset = {}, iset = {}, bre = {}, reload = {},
      actors = {}, alist = {}, aseen = {}, wake = {} }
    s.bs = b
  end
  return b
end

-- The actors' list: each once, in the order they came (loads go nearest first); one gone stays
-- listed until the list is made again, and is passed over.
local function enlist(list, seen, unit)
  if not seen[unit] then
    seen[unit] = true
    list[#list + 1] = unit
  end
end

---------------------------------------------------------------------------------------------
-- Belts by chunk, and what inserters and drills use: kept in storage, forgotten round anything built
-- or removed.

-- Each chunk's belts (bs.bc: chunk -> {tick, {belt, unit number, x, y}, ...}), searched again every
-- CHUNK_REFRESH ticks or so (by the chunk's key: belts something built without an event).
local CHUNK_REFRESH = 600
local function chunk_belts(b, surface, cx, cy)
  b.bc = b.bc or {}
  local key = chunk_key(cx * 32, cy * 32)
  local list = b.bc[key]
  if list and game.tick - list.tick < CHUNK_REFRESH + key % CHUNK_REFRESH then
    return list, 0
  end
  list = { tick = game.tick }
  local types = registry.belt_types()
  local units = FIND_UNITS
  if #types > 0 then
    local x0, y0 = cx * 32, cy * 32
    for _, belt in pairs(surface.find_entities_filtered({ area = { { x0, y0 }, { x0 + 32, y0 + 32 } }, type = types })) do
      local q = belt.position
      if belt.unit_number and q.x >= x0 and q.x < x0 + 32 and q.y >= y0 and q.y < y0 + 32 then
        list[#list + 1] = { belt, belt.unit_number, q.x, q.y }
        units = units + 1
      end
    end
  end
  b.bc[key] = list
  return list, units
end

local BELTISH = { ["transport-belt"] = true, ["underground-belt"] = true, ["splitter"] = true, ["lane-splitter"] = true,
  ["loader"] = true, ["loader-1x1"] = true, ["linked-belt"] = true }
local LOADERS = { ["loader"] = true, ["loader-1x1"] = true }

-- What an actor's check reads: an inserter's hand (how many it holds), a drill's mining progress and
-- its productivity bonus's (they go round when it drops what it mined).
local function held_count(e)
  local stack = e.held_stack
  return stack.valid_for_read and stack.count or 0
end
local function drill_progress(e)
  local m = e.mining_progress
  return m + e.bonus_mining_progress, m
end

-- The actor's value now, or nil when it is gone (or can't be read); a drill's mining progress alone
-- second.
local function actor_value(a)
  local ok, v, m = pcall(a[4] and drill_progress or held_count, a[1])
  if ok then
    return v, m
  end
  return nil
end

-- The chunk's belts that inserters and drills take from (2) or put on (1): read once, kept. Those
-- inserters and drills (actors) go in bs.actors: {entity, pickup belt's unit number or false, drop
-- belt's or false, a drill, value at its last check}, listed in bs.alist.
local function targets_of(b, surface, x, y)
  b.bt = b.bt or {}
  local key = chunk_key(x, y)
  local t = b.bt[key]
  if t then
    return t, 0
  end
  t = {}
  local x0, y0 = floor(x / 32) * 32, floor(y / 32) * 32
  local found = surface.find_entities_filtered({ area = { { x0 - REACH, y0 - REACH }, { x0 + 32 + REACH, y0 + 32 + REACH } },
    type = { "inserter", "mining-drill" } })
  local function mark(e, flag)
    if e and e.valid and e.unit_number and BELTISH[e.type] then
      local p = e.position
      if chunk_key(p.x, p.y) == key then
        t[e.unit_number] = math.max(t[e.unit_number] or 0, flag)
        return e.unit_number, true
      end
      return e.unit_number, false
    end
    return false, false
  end
  local units = FIND_UNITS + #found * TARGET_UNITS
  for _, e in pairs(found) do
    local drill = e.type ~= "inserter"
    local pick, here1 = false, false
    if not drill then
      pick, here1 = mark(e.pickup_target, 2)
    end
    local drop, here2 = mark(e.drop_target, 1)
    local u = e.unit_number
    if u and (here1 or here2) then
      local a = { e, pick, drop, drill }
      a[5] = actor_value(a)
      b.actors[u] = a
      enlist(b.alist, b.aseen, u)
      -- (t.a: the actors this chunk listed, forgotten with it: take_scan.)
      t.a = t.a or {}
      t.a[#t.a + 1] = u
      units = units + TARGET_UNITS
    end
  end
  b.bt[key] = t
  return t, units
end

-- tracker.listeners: something was built, changed or removed. Belts, inserters, drills and loaders
-- round it are worked out again on the next tick (a removed one is gone by then).
local function touched(entity)
  local s = storage.f3d
  local b = s and s.bs
  if not (b and entity and entity.valid) then
    return
  end
  local t = entity.type
  if not (BELTISH[t] or t == "inserter" or t == "mining-drill") then
    return
  end
  local p = entity.position
  b.dirty = b.dirty or {}
  b.dirty[#b.dirty + 1] = { entity.surface.index, p.x, p.y, entity.unit_number or 0, BELTISH[t] or false }
end
tracker.listeners[#tracker.listeners + 1] = touched

-- The dirty places (from on_tick): chunk lists and targets round them forgotten, and loaded belts
-- near them marked to be worked out again and sent again (lm and sl). A scan follows.
local function forget_touched(b)
  local dirty = b.dirty
  if not dirty then
    return 0
  end
  b.dirty = nil
  M.counts.dirty = (M.counts.dirty or 0) + #dirty
  local si = world.surface().index
  local units = 0
  for _, at in ipairs(dirty) do
    if at[1] == si then
      local x, y = at[2], at[3]
      if b.bc then
        for cx = floor((x - 2) / 32), floor((x + 2) / 32) do
          for cy = floor((y - 2) / 32), floor((y + 2) / 32) do
            b.bc[chunk_key(cx * 32, cy * 32)] = nil
          end
        end
      end
      if b.bt then
        for cx = floor((x - REACH) / 32), floor((x + REACH) / 32) do
          for cy = floor((y - REACH) / 32), floor((y + REACH) / 32) do
            b.bt[chunk_key(cx * 32, cy * 32)] = nil
          end
        end
      end
      local types = registry.belt_types()
      if #types > 0 then
        local r = REACH + 1.5
        local found = world.surface().find_entities_filtered({ area = { { x - r, y - r }, { x + r, y + r } }, type = types })
        units = units + FIND_UNITS + #found
        for _, belt in pairs(found) do
          local u = belt.unit_number
          if u and b.belts[u] then
            b.reload[#b.reload + 1] = u
          end
        end
      end
      -- (A belt built or removed changes the scan; an inserter or drill only its neighbours' records.)
      if at[5] then
        b.rescan = true
      end
    end
  end
  return units
end

---------------------------------------------------------------------------------------------
-- Lanes: their kind and meta, the cheap check, the full read.

local function kind_of(belt, i)
  local t = belt.type
  if t == "transport-belt" then
    return belt.belt_shape == "straight" and 1 or 2
  elseif t == "underground-belt" then
    if i <= 2 then
      return 3
    end
    return belt.belt_to_ground_type == "input" and 4 or 8
  elseif t == "splitter" then
    return i <= 4 and 5 or 6
  elseif t == "lane-splitter" then
    -- (One side of a splitter: lines 1-2 its inputs, 3-4 its outputs; the client tells it from a
    -- splitter by an output among lines 1-4.)
    return i <= 2 and 5 or 6
  elseif LOADERS[t] then
    return 7
  end
  return 8
end

local PRIORITY = { none = 0, left = 1, right = 2 }

-- A splitter's priorities and filter: input + 3 * output + 9 * filter item id.
local function splitter_extra(belt)
  local ok, v = pcall(function()
    local inp = PRIORITY[belt.splitter_input_priority] or 0
    local out = PRIORITY[belt.splitter_output_priority] or 0
    local flt = belt.splitter_filter
    local name = flt and (type(flt.name) == "table" and flt.name.name or flt.name)
    local id = type(name) == "string" and registry.item_id(name) or 0
    return inp + 3 * out + 9 * (id or 0)
  end)
  return ok and v or 0
end

-- The key items on lane i go on into when the game says so for certain: an underground entrance's
-- visible lines 1-2 into its own hidden lines 3-4 (key + 2), its hidden lines into its exit's lines
-- 1-2, the same side (2.1.24, Zenith Test: an entrance's line 1 ends where its line 3 starts, and
-- line 3 ends where the exit's line 1 starts). Else 0 (the client joins lanes by geometry).
local function next_of(belt, unit, i, kind)
  if kind == 3 and belt.belt_to_ground_type == "input" then
    return unit * LANE_KEYS + i + 2
  elseif kind == 4 then
    -- (2.1: underground_belt_neighbour; 2.0: neighbours.)
    local ok, exit = pcall(function() return belt.underground_belt_neighbour end)
    if not ok then
      ok, exit = pcall(function() return belt.neighbours end)
    end
    if ok and exit and exit.valid and exit.unit_number then
      return exit.unit_number * LANE_KEYS + i - 2
    end
  end
  return 0
end

local function fixed(v)
  return floor(v * 256 + 0.5)
end

-- Whether line i of a belt is one its items leave the belt by (not one leading on inside it: an
-- underground entrance's visible lines, a splitter's inputs).
local function exit_line(belt, i)
  local t = belt.type
  if t == "underground-belt" then
    return i > 2 or belt.belt_to_ground_type ~= "input"
  elseif t == "splitter" then
    return i > 4
  elseif t == "lane-splitter" then
    return i > 2
  end
  return true
end

-- The lane's meta, 12 integers into `out`. `edge`: the belt leads out of what is sent (bs.oset): its
-- exit lines' next is -1.
-- A lane's meta but its last number, as text, by lane key: the line's geometry doesn't change while
-- the belt stands (rotated or replaced, the belt is loaded again: load_belt forgets its lanes' metas).
-- m[12]: the lane it goes on into (next_of), a number; m[13]: whether items leave the belt by it.
-- Module-local, like line_cache (a `bre` lane sent again cost seven calls for its meta).
local meta_cache = {}

local function write_meta(out, belt, unit, i, line, step, edge)
  local key = unit * LANE_KEYS + i
  local m = meta_cache[key]
  local kind
  if m then
    kind = m[0]
  else
    kind = kind_of(belt, i)
    local len = line.line_length
    local p0 = line.get_line_item_position(0)
    local pm = line.get_line_item_position(len / 2)
    local p1 = line.get_line_item_position(len)
    m = { S(key), S(kind), S(fixed(len)), S(step), S(fixed(p0.x)), S(fixed(p0.y)), S(fixed(pm.x)), S(fixed(pm.y)),
      S(fixed(p1.x)), S(fixed(p1.y)), "0", next_of(belt, unit, i, kind), exit_line(belt, i) }
    m[0] = kind
    meta_cache[key] = m
  end
  local n = #out
  for j = 1, 10 do
    out[n + j] = m[j]
  end
  -- (A splitter's priorities and filter are read each time: set from its GUI, no event.)
  out[n + 11] = (kind == 5 or kind == 6) and S(splitter_extra(belt)) or "0"
  local nk = m[12]
  if edge and m[13] then
    -- (Leading out of what is sent: minus the lane it goes on into when the game says, else -1.)
    nk = nk > 0 and -nk or -1
  end
  out[n + 12] = S(nk)
end

-- Line objects by unit number: module-local (getting one costs about as much as a check); the
-- units are counted whether it was kept or not, so every peer counts the same.
local line_cache = {}

local function lines_of(belt, unit)
  local lines = line_cache[unit]
  if not lines then
    local t = belt.type
    -- (input: how many of its lines are a splitter's inputs.)
    -- (len: each line's length, read once (catch_up_fn asked for it at every read).)
    lines = { v = floor(belt.prototype.belt_speed * 256 + 0.5), input = t == "splitter" and 4 or t == "lane-splitter" and 2 or 0, len = {} }
    for i = 1, belt.get_max_transport_line_index() do
      lines[i] = belt.get_transport_line(i)
    end
    line_cache[unit] = lines
  end
  return lines
end

-- Line i's length (tiles), from the cache.
local function line_len(lines, i)
  local len = lines.len[i]
  if not len then
    len = lines[i].line_length
    lines.len[i] = len
  end
  return len
end

-- {count, front, back, items} of a line, as the cheap check reads it.
local function check_line(line)
  local n = #line
  if n == 0 then
    return 0, -1, -1, 0
  end
  local p1 = line.get_item_position(1)
  local pn = n > 1 and line.get_item_position(n) or p1
  return n, fixed(p1), fixed(pn), line.get_item_count()
end

-- The item id of a lane's items when they are all one kind of item of normal quality (its totals:
-- one call), else nil. (Not where a line has no totals: tests' fake worlds.)
local has_totals = nil
local function one_kind(line)
  if has_totals == nil then
    has_totals = pcall(function() return line.get_contents end) or false
  end
  if not has_totals then
    return nil
  end
  local c = line.get_contents()
  local k = c[1]
  if k and not c[2] and (k.quality == nil or k.quality == "normal") then
    return registry.item_id(k.name)
  end
  return nil
end

-- What is sent this update (module-local; see the header), by client state: storage.f3d is swapped
-- per client (session.serve) and two clients' rounds start on the same ticks, so one keyed by the
-- tick alone sent the first client both clients' lanes and the second nothing. lm and sl lanes by
-- key once each.
local pays = setmetatable({}, { __mode = "k" })

local function payload(b)
  local round = b.round
  local pay = pays[storage.f3d]
  if pay and round and pay.id == round.start then
    return pay
  end
  return nil
end

local function new_payload(id)
  return { id = id, lm = {}, sl = {}, qu = {}, pc = {}, dl = {}, of = {}, ew = {}, sh = {}, sent = {} }
end

-- Reads lane i of a belt in full (and its meta with `meta`): its record in storage, what is sent
-- into `p`. Returns the units it cost.
local function read_lane(b, belt, unit, i, lines, meta, p, n, p1, pn, total)
  local line = lines[i]
  local key = unit * LANE_KEYS + i
  local now = game.tick
  if not n then
    n, p1, pn, total = check_line(line)
  end
  local rec = b.lanes[key]
  if not rec then
    rec = {}
    b.lanes[key] = rec
  end
  -- rec: {count, front, back, items, tick read in full, tick checked, checks unchanged in a row}
  -- rec: ..., [8] changed since it was last sent settled (watch_lane), [9] its length (1/256), [10]
  -- and [11] the front and back items' unique ids
  rec[1], rec[2], rec[3], rec[4], rec[5], rec[6], rec[7] = n, p1, pn, total, now, now, 0
  -- rec[14]: the client's last read of it is the lane as it is (hold_inputs).
  rec[14] = true
  local br = b.belts[unit]
  if br then
    br[13] = nil
  end
  if not rec[9] then
    rec[9] = fixed(line_len(lines, i))
  end
  M.counts.read = M.counts.read + 1
  local units = CHECK_UNITS + n * ITEM_UNITS
  if meta then
    units = units + META_UNITS
    M.counts.meta = M.counts.meta + 1
  end
  -- (A lane is sent once a tick: read again on a later tick of the same update, it goes again, the
  -- client applying each at its own tick.)
  if p and p.sent[key] ~= now then
    p.sent[key] = now
    if meta then
      write_meta(p.lm, belt, unit, i, line, lines.v, b.oset[unit])
    end
    local sl = p.sl
    local m = #sl
    local at = m + 3
    -- (The count stays a number: emit walks the list by it.)
    sl[m + 1], sl[m + 2], sl[m + 3] = S(key), S(now), n
    m = at
    local qu = p.qu
    local contents = line.get_detailed_contents()
    rec[10] = contents[1] and contents[1].unique_id or nil
    rec[11] = contents[#contents] and contents[#contents].unique_id or nil
    -- One kind of item, normal, none stacked (most lanes): its id from the lane's totals, nothing
    -- read item by item but its id and place.
    -- (A lane of one item too, perfbridge2: its totals are one call where its stack's name, count
    -- and quality were four.)
    local one = n >= 1 and total == n and one_kind(line)
    if one then
      one = S(one)
      for _, item in pairs(contents) do
        sl[m + 1], sl[m + 2], sl[m + 3], sl[m + 4] = S(item.unique_id), one, S(fixed(item.position)), "1"
        m = m + 4
      end
    else
      for _, item in pairs(contents) do
        local st = item.stack
        local c = st.count
        sl[m + 1], sl[m + 2], sl[m + 3], sl[m + 4] = S(item.unique_id), S(registry.item_id(st.name)), S(fixed(item.position)), NUM[c > 4 and 4 or c]
        m = m + 4
        local q = st.quality.name
        if q ~= "normal" then
          qu[#qu + 1] = S(item.unique_id)
          qu[#qu + 1] = q
        end
      end
    end
    -- (The count is what was listed: the same as the check's on one tick, but the list is what the
    -- client gets.)
    sl[at] = (m - at) / 4
    M.counts.items = M.counts.items + n
  elseif n > 0 then
    local contents = line.get_detailed_contents()
    rec[10] = contents[1] and contents[1].unique_id or nil
    rec[11] = contents[#contents] and contents[#contents].unique_id or nil
  else
    rec[10], rec[11] = nil, nil
  end
  return units
end

-- Works out a belt's record: whether it is watched (see the header), whether it has a circuit
-- connection. Returns the record and the units it cost.
local function belt_record(b, belt, unit, x, y)
  local surface = world.surface()
  local t = belt.type
  local rec = { belt, x, y }
  rec[14] = t
  local units = WATCH_UNITS
  local watched = not (t == "transport-belt" or t == "underground-belt")
  local here, u1 = targets_of(b, surface, x, y)
  units = units + u1
  -- rec[11]: inserters or drills use it (1 drop, 2 pickup, 3 the belt behind a pickup belt).
  if here[unit] then
    watched = true
    rec[11] = here[unit]
    rec[12] = true
  end
  -- rec[7], rec[8]: the unit numbers of the belts it feeds and that feed it (an underground's other
  -- end too).
  local outs, ins = {}, {}
  rec[7], rec[8] = outs, ins
  if t == "underground-belt" then
    local uok, other = pcall(function() return belt.underground_belt_neighbour end)
    if uok and other and other.valid and other.unit_number then
      local list = belt.belt_to_ground_type == "input" and outs or ins
      list[#list + 1] = other.unit_number
    end
  end
  local ok, nb = pcall(function() return belt.belt_neighbours end)
  if ok and nb then
    for _, e in pairs(nb.inputs or {}) do
      if e.valid then
        if e.unit_number then
          ins[#ins + 1] = e.unit_number
        end
        if LOADERS[e.type] then
          watched = true
          rec[12] = true
        end
      end
    end
    for _, e in pairs(nb.outputs or {}) do
      if e.valid then
        if e.unit_number then
          outs[#outs + 1] = e.unit_number
        end
        if LOADERS[e.type] then
          watched = true
          rec[12] = true
        elseif e.unit_number then
          local q = e.position
          local there, u2 = targets_of(b, surface, q.x, q.y)
          units = units + u2
          if there[e.unit_number] == 2 then
            watched = true  -- the belt behind a pickup belt: hands chase items there
            rec[11] = rec[11] or 3
            rec[12] = true
          end
        end
      end
    end
  end
  local cok, behavior = pcall(function() return belt.get_control_behavior() end)
  if cok and behavior then
    watched = true
    rec[5] = true
    rec[12] = true
  end
  if LOADERS[t] then
    rec[12] = true
  end
  rec[4] = watched
  return rec, units
end

local OFF = nil
local function off_status()
  if OFF == nil then
    local ok, v = pcall(function() return defines.entity_status.disabled_by_control_behavior end)
    OFF = ok and v or false
  end
  return OFF
end

-- Whether a circuit-connected belt is switched off.
local function is_off(belt)
  local off = off_status()
  if not off then
    return false
  end
  local ok, st = pcall(function() return belt.status end)
  return ok and st == off
end

-- Whether a belt feeds one that isn't loaded (its items leave what is sent: `lm` next -1).
local function leads_out(b, rec)
  for _, u in ipairs(rec[7]) do
    if not b.belts[u] then
      return true
    end
  end
  return false
end

-- Whether a belt is fed by one that isn't loaded (what comes in from it is news to the client:
-- watched, as the square's outer ring is).
local function leads_in(b, rec)
  for _, u in ipairs(rec[8]) do
    if not b.belts[u] then
      return true
    end
  end
  return false
end

-- Reads a belt's exit lines in full again (no meta). Returns the units.
local function read_exits(b, belt, unit, p)
  local lines = lines_of(belt, unit)
  local units = 0
  for i = 1, #lines do
    if exit_line(belt, i) and b.lanes[unit * LANE_KEYS + i] then
      units = units + read_lane(b, belt, unit, i, lines, false, p)
    end
  end
  return units
end

-- Reads a loaded belt's lanes in full again (those not read this tick), and those of the belts it
-- leads into while what came in at its back up to `dt` ticks ago can have got that far (at most
-- CATCH_DEPTH belts on). Returns the units.
local CATCH_DEPTH = 8
-- A changed watched belt's tail: at most this many belts on (the client's carrying on from an item's
-- last read is a few ticks; a long tail through splitters cost more than it fixed).
local TAIL_DEPTH = 2
local function catch_up_fn(b, unit, dt, p, depth)
  local rec = b.belts[unit]
  if not (rec and rec[1].valid) or depth > CATCH_DEPTH then
    return 0
  end
  local belt = rec[1]
  local lines = lines_of(belt, unit)
  local now = game.tick
  local units, cross = 0, math.huge
  for i = 1, #lines do
    local lr = b.lanes[unit * LANE_KEYS + i]
    if lr and lr[5] ~= now then
      units = units + read_lane(b, belt, unit, i, lines, false, p)
    end
    if lines.v > 0 then
      cross = math.min(cross, floor(line_len(lines, i) * 256 / lines.v))
    end
  end
  if dt > cross then
    for _, u in ipairs(rec[7] or {}) do
      units = units + catch_up_fn(b, u, dt - cross, p, depth + 1)
    end
  end
  return units
end

-- Loads a belt (all its lanes, meta and items) or loads it again. Returns the units.
local function load_belt(b, belt, unit, x, y, p)
  local old = b.belts[unit]
  local rec, units = belt_record(b, belt, unit, x, y)
  if old then
    rec[6] = old[6]
  end
  b.belts[unit] = rec
  b.wver = (b.wver or 0) + 1
  b.wset[unit] = rec[4] or nil
  b.cset[unit] = rec[5] or nil
  b.oset[unit] = leads_out(b, rec) or nil
  b.iset[unit] = leads_in(b, rec) or nil
  local lines = lines_of(belt, unit)
  -- (Loaded again after an event: the belt may have turned; its lines' geometry is read again.)
  if old then
    for i = 1, LANE_KEYS do
      meta_cache[unit * LANE_KEYS + i] = nil
    end
  end
  for i = 1, #lines do
    units = units + read_lane(b, belt, unit, i, lines, true, p)
  end
  -- Loaded belts that led into this one led out of what was sent: the client held their fronts
  -- where they were last read. Read again now (where the game has them as this one comes), and from
  -- here on they lead into it.
  if not old then
    -- Loaded belts it leads into missed what came in from it since they were last checked (read in
    -- full, or found unchanged): read again, and on as far as that can have gone.
    local now = game.tick
    for _, u in ipairs(rec[7]) do
      local r = b.belts[u]
      if r and b.iset[u] and not leads_in(b, r) then
        b.iset[u] = nil
      end
      if r then
        local since = now
        for i = 1, LANE_KEYS do
          local lr = b.lanes[u * LANE_KEYS + i]
          if lr and lr[6] < since then
            since = lr[6]
          end
        end
        if since < now then
          local r0 = M.counts.read
          units = units + catch_up_fn(b, u, now - since, p, 0)
          M.counts.r_catch = (M.counts.r_catch or 0) + M.counts.read - r0
        end
      end
    end
    for _, u in ipairs(rec[8]) do
      local r = b.belts[u]
      if r and b.oset[u] then
        if r[1].valid then
          local r0 = M.counts.read
          units = units + read_exits(b, r[1], u, p)
          M.counts.r_exits = (M.counts.r_exits or 0) + M.counts.read - r0
        end
        if not leads_out(b, r) then
          b.oset[u] = nil
        end
      end
    end
  end
  if rec[5] then
    local off = is_off(belt)
    if off ~= (rec[6] or false) and p then
      p.of[#p.of + 1] = S(unit)
      p.of[#p.of + 1] = off and "1" or "0"
    end
    rec[6] = off
  end
  M.counts.loaded = M.counts.loaded + 1
  return units
end

-- Drops a loaded belt: its lanes leave (`dl`).
local function drop_belt(b, unit, p)
  local rec = b.belts[unit]
  if not rec then
    return
  end
  b.belts[unit], b.wset[unit], b.cset[unit], b.oset[unit], b.iset[unit] = nil, nil, nil, nil, nil
  if b.wake then
    b.wake[unit] = nil
  end
  b.wver = (b.wver or 0) + 1
  -- The loaded belts it fed are fed from outside what is sent now: watched.
  for _, u in ipairs(rec[7] or {}) do
    if b.belts[u] then
      b.iset[u] = true
    end
  end
  -- The loaded belts feeding it lead out of what is sent now: sent again (their `lm` next -1).
  for _, u in ipairs(rec[8] or {}) do
    if b.belts[u] and not b.oset[u] then
      b.oset[u] = true
      b.reload[#b.reload + 1] = u
    end
  end
  line_cache[unit] = nil
  for i = 1, LANE_KEYS do
    local key = unit * LANE_KEYS + i
    meta_cache[key] = nil
    if b.lanes[key] then
      b.lanes[key] = nil
      M.counts.dl = M.counts.dl + 1
      if p then
        p.dl[#p.dl + 1] = S(key)
      end
    end
  end
end

-- The cheap check of a loaded lane against its record: read in full when it changed. Returns the units.
-- A packed lane can move on a whole gap and look the same to the cheap check: its front item
-- leaving, the next taking its place, one more coming in at the back (a packed line leading out of
-- the square moving on a gap at a time), or an inserter taking one from a packed, standing line
-- and the items behind closing up, one more coming in at the back. Its front and back items' ids
-- tell.
local GAP = 64
-- Returns whether they moved, and the front and back ids now.
-- The reads made for accuracy alone (ids of packed lanes, tails, reads round a settled belt) share
-- extra_units an update, so they cost about the same whatever the square's size (lanes leading out
-- are checked whatever this says: their walls).
local function extra_left(b)
  local r = b.round
  return not r or (r.x or 0) < M.extra_units
end
local function extra_spend(b, units)
  local r = b.round
  if r then
    r.x = (r.x or 0) + units
  end
end

local function front_moved(line, rec)
  M.counts.identity = (M.counts.identity or 0) + 1
  local contents = line.get_detailed_contents()
  local first, last = contents[1], contents[#contents]
  local fu, bu = first and first.unique_id, last and last.unique_id
  return fu ~= rec[10] or bu ~= rec[11], fu, bu
end

-- How long a quiet lane goes unchecked: spot_quiet_ticks at an input spot (its inserters and drills
-- wake it), else quiet_ticks, twice that once it stood for 2 * quiet_after checks and four times at
-- 4 * quiet_after (quiet_backoff: splitters' and loaders' lanes, circuit belts, the outer ring that
-- stand backed up for minutes).
-- checkpoints: whether lane i is one where our copy of the belt rules is known to go a tick from the
-- game's (docs/BELT-SIM-PLAN.md, the fronts round): a splitter's input (an item crossing a tick early),
-- a lane an inserter takes from (its front), an underground entrance an inserter drops on.
local function checkpoint_lane(brec, belt, i, lines)
  if lines.input >= i then
    return true
  end
  local used = brec and brec[11]
  if used == 2 then
    return true
  end
  return used == 1 and belt.type == "underground-belt"
end

-- crossings game: whether lane i is a splitter's output (checked every update, never quiet: what crossed
-- shows there).
local function crossing_lane(i, lines)
  return O.crossings == "game" and lines.input > 0 and i > lines.input
end

local function quiet_for(brec, rec)
  if O.inputs_first and brec and brec[12] and brec[11] then
    return M.spot_quiet_ticks
  end
  local qt = M.quiet_ticks
  if O.quiet_backoff then
    local c = rec[7] or 0
    local qa = M.quiet_after
    if c >= 4 * qa then
      return qt * 4
    elseif c >= 2 * qa then
      return qt * 2
    end
  end
  return qt
end

local function watch_lane(b, belt, unit, i, lines, p)
  local key = unit * LANE_KEYS + i
  local rec = b.lanes[key]
  if not rec then
    return 0
  end
  local now = game.tick
  -- (A lane leading out is never quiet nor left out for having only flowed: the client's wall
  -- moves only when it is sent.)
  local edge = b.oset[unit] and exit_line(belt, i)
  -- (An inserter's or drill's belt: what they take or put is what the cheap check can miss.)
  local brec = b.belts[unit]
  local handled = brec and brec[11]
  -- (A lane fed from outside what is sent: what comes in at its back is news to the client. Never
  -- quiet, never left out for having only flowed, a packed one checked by its ids too.)
  local fed = O.feed_edges and b.iset[unit]
  -- (An input spot whose inserter or drill acted since its last check.)
  local woke = O.inputs_first and b.wake[unit]
  -- (A checkpoint: checked every update, a packed one by its ids, as a lane fed from outside is.)
  local cp = O.checkpoints and checkpoint_lane(brec, belt, i, lines)
  if cp then
    M.counts.checkpoints = (M.counts.checkpoints or 0) + 1
  end
  -- (crossings game: a splitter's output, checked every update by its ids: what crossed shows there.)
  if not cp and crossing_lane(i, lines) then
    cp = true
    M.counts.crossings = (M.counts.crossings or 0) + 1
  end
  local quiet_ticks = quiet_for(brec, rec)
  -- A quiet lane (unchanged at its last quiet_after checks: most watched lanes are backed up) is
  -- checked again only quiet_ticks after its last check: a change there is sent at most that much
  -- later, with the tick it was read on.
  if not edge and not fed and not woke and not cp and quiet_ticks > 0 and (rec[7] or 0) >= M.quiet_after and now - rec[6] < quiet_ticks then
    M.counts.quiet = M.counts.quiet + 1
    return 0.5
  end
  local n, p1, pn, total = check_line(lines[i])
  M.counts.checked = M.counts.checked + 1
  if brec then
    brec[13] = nil
  end
  local same = n == rec[1] and p1 == rec[2] and pn == rec[3] and total == rec[4]
  local extra = 0
  local shifted, sfu, sbu = false, nil, nil
  -- (At most every identity_ticks a lane, but every update for a lane leading out: its wall.)
  if same and n > 0 and pn - p1 == GAP * (n - 1) and M.identity and (edge or ((fed or woke or cp) and n > 1) or (handled and now - (rec[12] or -1e9) >= M.identity_ticks and extra_left(b))) then
    rec[12] = now
    if edge then
      M.counts.identity_edge = (M.counts.identity_edge or 0) + 1
    end
    extra = n * ITEM_UNITS
    if not edge and not fed and not woke and not cp then
      extra_spend(b, extra + CHECK_UNITS)
    end
    shifted, sfu, sbu = front_moved(lines[i], rec)
    same = not shifted
  end
  -- (hold_inputs: a splitter's input as the client last had it; a packed one only by its ids too, as a
  -- lane flowing a whole gap between checks looks the same.)
  local hold = same and O.hold_inputs and rec[14] and n > 0 and lines.input >= i
  if hold and not shifted and n > 1 and pn - p1 == GAP * (n - 1) and rec[12] ~= now then
    rec[12] = now
    extra = extra + n * ITEM_UNITS
    shifted, sfu, sbu = front_moved(lines[i], rec)
    same = not shifted
    hold = same
  end
  if same then
    local c = (rec[7] or 0) + 1
    rec[6], rec[7] = now, c
    -- Settled (unchanged at quiet_after checks running) after changing: read and sent once more. The
    -- client simulated it on from the reads made while it changed, each on a tick of its own, while
    -- the lanes round it were read on others; once it stands its last state goes, which nothing else
    -- would send (it no longer changes).
    if c == M.quiet_after and rec[8] then
      M.counts.settled = (M.counts.settled or 0) + 1
      local u = read_lane(b, belt, unit, i, lines, false, p, n, p1, pn, total)
      rec[7], rec[8] = c, nil
      return CHECK_UNITS + extra + u, 2
    end
    if hold and p and p.sent[key] ~= now then
      M.counts.held = (M.counts.held or 0) + 1
      local sh = p.sh
      local m = #sh
      sh[m + 1], sh[m + 2] = S(key), S(now)
    end
    return CHECK_UNITS + extra
  end
  -- Every item moved on the same way and nothing came or went: what the client simulates itself,
  -- not sent (in 2.1 a lane's items move on as one; an inserter's take or put changes the count or
  -- breaks the even shift).
  if M.skip_flow and not edge and not fed and n == rec[1] and total == rec[4] and p1 - rec[2] == pn - rec[3] and p1 < rec[2] then
    M.counts.flow = M.counts.flow + 1
    rec[2], rec[3], rec[6], rec[7], rec[8], rec[14] = p1, pn, now, 0, true, nil
    return CHECK_UNITS
  end
  -- A lane leading out whose items only moved on alike (or, packed, a whole gap on: its front item
  -- left, one more came in at the back): its new wall is all the client needs (`ew`), the line behind
  -- following it there; a full read only when items came or went otherwise.
  if edge and M.edge_walls and ((n == rec[1] and total == rec[4] and p1 - rec[2] == pn - rec[3] and p1 < rec[2] and rec[10])
      or (shifted and sfu)) then
    M.counts.walls = (M.counts.walls or 0) + 1
    if shifted then
      rec[10], rec[11] = sfu, sbu
    end
    rec[1], rec[2], rec[3], rec[4], rec[6], rec[7], rec[8], rec[14] = n, p1, pn, total, now, 0, true, nil
    if p and p.sent[key] ~= now then
      p.sent[key] = now
      local ew = p.ew
      local m = #ew
      ew[m + 1], ew[m + 2], ew[m + 3], ew[m + 4] = S(key), S(now), S(rec[10]), S(p1)
    end
    return CHECK_UNITS + extra
  end
  M.counts.changed = M.counts.changed + 1
  -- (1: items came or went, 3: they only moved otherwise.)
  local came = n ~= rec[1] or total ~= rec[4]
  local u = read_lane(b, belt, unit, i, lines, false, p, n, p1, pn, total)
  rec[8] = true
  return CHECK_UNITS + extra + u, came and 1 or 3
end

-- Whether a belt's lanes hold an item within two gaps of where items come in (a packed line goes on
-- behind it).
local function full_back(b, unit)
  for i = 1, LANE_KEYS do
    local lr = b.lanes[unit * LANE_KEYS + i]
    if lr and lr[1] > 0 and lr[9] and lr[3] >= lr[9] - 128 then
      return true
    end
  end
  return false
end

local SETTLE_DEPTH = 1
local catch_up = catch_up_fn
-- The packed line behind a belt (the belts feeding it as far back as their lanes are full at the
-- back, at most SETTLE_DEPTH), read again. Returns the units.
local function read_run(b, unit, p)
  local rec = b.belts[unit]
  local units = 0
  local seen = { [unit] = true }
  local function up(u, depth)
    local r = b.belts[u]
    if not r or seen[u] or depth > SETTLE_DEPTH then
      return
    end
    seen[u] = true
    units = units + catch_up(b, u, 0, p, 0)
    if full_back(b, u) then
      for _, w in ipairs(r[8] or {}) do
        up(w, depth + 1)
      end
    end
  end
  if full_back(b, unit) then
    for _, u in ipairs(rec[8] or {}) do
      up(u, 1)
    end
  end
  return units
end

-- A watched belt settled: the belts it feeds, and the packed line behind it, read once more: what
-- the client's simulation did with the items moving across their ends while they changed (a
-- splitter's turns, a take near the front) shows there, and a packed line standing behind a belt is
-- moved by nothing else. Returns the units.
local function settle_around(b, unit, p)
  local rec = b.belts[unit]
  local units = 0
  for _, u in ipairs(rec[7] or {}) do
    units = units + catch_up(b, u, 0, p, 0)
  end
  return units + read_run(b, unit, p)
end

-- A packed run goes on across a belt's front (a lane's front item within a gap of its exit, its
-- items a gap apart) or its back (its back item within a gap of its entry), by its lanes' records.
-- (RUN_SLACK: the client's PACK_SLACK, how far over a gap packed items may be and still move as one.)
local RUN_SLACK = 8
local function packed_at(b, unit, front)
  for i = 1, LANE_KEYS do
    local lr = b.lanes[unit * LANE_KEYS + i]
    if lr and lr[1] > 0 and lr[3] - lr[2] <= (GAP + RUN_SLACK) * (lr[1] - 1) then
      if front and lr[2] < GAP + RUN_SLACK then
        return true
      elseif not front and lr[9] and lr[3] > lr[9] - GAP - RUN_SLACK then
        return true
      end
    end
  end
  return false
end

-- A lane read again: the packed run it belongs to read on the same tick, ahead (the belts it feeds,
-- on while the run goes on across their fronts) and behind (the belts feeding it, on while it goes on
-- across their backs), at most M.run_belts belts each way. The client moves a read's packed run
-- with it; read whole, it replaces the run. Returns the units.
local function read_runs(b, unit, ahead, behind, p)
  if M.run_belts <= 0 then
    return 0
  end
  local units = 0
  local r0 = M.counts.read
  local function walk(field, front)
    local seen = { [unit] = true }
    local layer = { unit }
    for _ = 1, M.run_belts do
      local nxt = {}
      for _, v in ipairs(layer) do
        local rec = b.belts[v]
        if rec and packed_at(b, v, front) then
          for _, w in ipairs(rec[field] or {}) do
            if not seen[w] and b.belts[w] then
              seen[w] = true
              units = units + catch_up(b, w, 0, p, 0)
              nxt[#nxt + 1] = w
            end
          end
        end
      end
      if #nxt == 0 then
        return
      end
      layer = nxt
    end
  end
  if ahead then
    walk(7, true)
  end
  if behind then
    walk(8, false)
  end
  M.counts.r_run = (M.counts.r_run or 0) + M.counts.read - r0
  return units
end

-- A drift check of every lane of a belt (`pc`). (A watched belt's (drift_watched) last check stays as its
-- own checks left it: their quiet turns go by it.)
local function drift_check(b, belt, unit, p)
  local lines = lines_of(belt, unit)
  local units = 0
  local now = game.tick
  for i = 1, #lines do
    local key = unit * LANE_KEYS + i
    local rec = b.lanes[key]
    if rec and rec[5] ~= now then
      local n, p1, pn = check_line(lines[i])
      units = units + CHECK_UNITS
      M.counts.pc = M.counts.pc + 1
      if not b.wset[unit] then
        rec[6] = now
      end
      -- A packed lane: its front and back items' ids too (`pu`), the only way a lane the client has
      -- a whole gap off shows.
      local fu, bu = 0, 0
      if n > 0 and pn - p1 == GAP * (n - 1) and M.identity and (O.pc_ids or extra_left(b)) then
        local contents = lines[i].get_detailed_contents()
        units = units + n * ITEM_UNITS
        if not O.pc_ids then
          extra_spend(b, n * ITEM_UNITS)
        end
        -- (As text; 0, a number, where the lane isn't packed: emit tells them apart by it.)
        fu = contents[1] and S(contents[1].unique_id) or 0
        bu = contents[#contents] and S(contents[#contents].unique_id) or 0
      end
      if p then
        local pc = p.pc
        local m = #pc
        pc[m + 1], pc[m + 2], pc[m + 3], pc[m + 4], pc[m + 5], pc[m + 6], pc[m + 7] = S(key), S(now), S(n), S(p1), S(pn), fu, bu
      end
    end
  end
  return units
end

---------------------------------------------------------------------------------------------
-- The scan: the square's belts by ring, nearest first.
--
-- bs.scan = {fx, fy, r, tick, ents, units, xs, ys, rings, first (ring -> index of its first belt),
-- n, idx (unit -> index)}; bs.scanning, one being made.

-- The client's belt item distance (`bfar` n), else the map setting: every belt within it is
-- simulated, whatever the client's Belt updates (`bfar` m) or its entity distance (the focus radius).
local function wanted_radius()
  local s = storage.f3d
  if s.near_r then
    return s.near_r
  end
  if not O.full_area then
    return math.min(settings.global["f3d-detail-radius"].value, s.focus.r)
  end
  return settings.global["f3d-detail-radius"].value
end

-- area trace: the belts loaded are those traced from the near square (see M.OPTIONS).
local function trace_on()
  return O.area == "trace"
end

-- The near square's half side now: trace_near, cut by the bound (bs.cut) while the work runs over.
local function near_now()
  local n = floor(tonumber(O.trace_near) or 48)
  local b = storage.f3d.bs
  if b and b.cut and b.cut < n then
    return b.cut
  end
  return math.max(1, n)
end

-- What the trace depends on besides the near square (a scan is made again when it changes).
local function trace_key()
  return floor(tonumber(O.trace_hops) or 0) * 100000 + floor(tonumber(O.trace_down) or 0)
end

-- (full_area off.) The client's cap (`bfar` m: items + lanes), its edge holding still: kept while the
-- rings inside it hold up to KEEP times the cap, grown again only once they hold less than GROW times
-- it; belts more than DROP rings past it dropped.
local KEEP, GROW, DROP = 1.25, 0.85, 2
M.max_items = 6000
local function cap()
  if O.full_area then
    return math.huge
  end
  local c = storage.f3d.bi_cap or M.max_items
  if c < 0 then
    return math.huge
  end
  return c
end

-- The bridge's own bound: the belts' work a tick (everything but first loads, input spots and lanes
-- fed from outside included) kept within BOUND_SHARE of the work budget (budget.lua: the client's,
-- which Hold 60 UPS shrinks while the game runs slow). Over it for BOUND_OVER updates running, the
-- square is cut from the outside (to BOUND_CUT of its side, never under M.bound_min tiles: the client is
-- told by fr, and what is inside stays whole); well under it (BOUND_ROOM) for BOUND_UNDER updates, it
-- grows back a step. bs.cut: the radius cut to, nil when whole. M.bound: units a tick instead (tests).
-- (The budget's share is of its default at least: bound_units.)
local BOUND_SHARE = 0.6
local BOUND_OVER, BOUND_UNDER = 3, 30
local BOUND_CUT, BOUND_ROOM = 0.85, 0.6
M.bound_min = 16
M.bound = nil

local function bound_units()
  if M.bound then
    return M.bound
  end
  local share = tonumber(O.bound) or BOUND_SHARE
  if share <= 0 then
    return math.huge
  end
  -- (A share of the budget, but never of less than its default: Hold 60 UPS shrinks the budget while
  -- the game runs slow, which cut the square to 16 tiles on Zenith Test at 57-59 UPS; the update rate
  -- levels it takes lower the belts' work a tick first.)
  return math.max(1000, floor(math.max(budget.limit(), budget.DEFAULT) * share * UNITS_PER_BUDGET_UNIT))
end

local function radius()
  local r = wanted_radius()
  local b = storage.f3d.bs
  -- (area trace: the bound cuts the near square, not the scan's; near_now.)
  if b and b.cut and b.cut < r and not trace_on() then
    return b.cut
  end
  return r
end

-- On an update's tick: the update's work a tick against the bound; the square cut or grown.
local function bound(b, units, period, loading)
  local cost = units / math.max(1, period)
  b.cost = b.cost and b.cost + (cost - b.cost) * 0.5 or cost
  if loading then
    b.over, b.under = 0, 0
    return
  end
  local cap = bound_units()
  b.over = b.cost > cap and (b.over or 0) + 1 or 0
  b.under = b.cost < cap * BOUND_ROOM and (b.under or 0) + 1 or 0
  -- (area trace: the near square is what is cut and grown; the belts traced from it follow.)
  local want = trace_on() and math.max(1, floor(tonumber(O.trace_near) or 48)) or wanted_radius()
  local cur = math.min(b.cut or want, want)
  if b.over >= BOUND_OVER and cur > M.bound_min then
    b.cut = math.max(M.bound_min, floor(cur * BOUND_CUT))
    b.over, b.under = 0, 0
    M.counts.cuts = (M.counts.cuts or 0) + 1
  elseif b.under >= BOUND_UNDER and b.cut then
    local grown = cur + math.max(8, floor(cur * (1 - BOUND_CUT)))
    b.cut = grown < want and grown or nil
    b.over, b.under = 0, 0
  end
end

local function new_scan(f, r)
  local sc = { fx = f.x, fy = f.y, r = r, tick = game.tick, chunks = {}, ci = 1, by = {}, top = -1 }
  if trace_on() then
    sc.near, sc.tkey = near_now(), trace_key()
  end
  return sc
end

-- The unit numbers of the belts that feed a belt and of those it feeds (an underground's other end
-- among them).
local function neighbours_of(belt)
  local ins, outs = {}, {}
  if belt.type == "underground-belt" then
    local ok, other = pcall(function() return belt.underground_belt_neighbour end)
    if ok and other and other.valid and other.unit_number then
      local list = belt.belt_to_ground_type == "input" and outs or ins
      list[#list + 1] = other.unit_number
    end
  end
  local ok, nb = pcall(function() return belt.belt_neighbours end)
  if ok and nb then
    for _, e in pairs(nb.inputs or {}) do
      if e.valid and e.unit_number then
        ins[#ins + 1] = e.unit_number
      end
    end
    for _, e in pairs(nb.outputs or {}) do
      if e.valid and e.unit_number then
        outs[#outs + 1] = e.unit_number
      end
    end
  end
  return ins, outs
end

-- area trace, over a finished scan: the belts within sc.near of the focus, then (breadth first, up to
-- `limit` units; the trace goes on next tick where it stopped) the belts feeding them back to their
-- origins, at most trace_hops belts back, then the belts those all feed trace_down belts on. sc.sel:
-- unit number -> true for every belt to load. tr: {q (indices), qi, h (index -> hops), phase, order}.
-- Returns the units spent and whether it finished.
local function trace_step(sc, limit)
  local tr = sc.tr
  local spent = 0
  if not tr then
    tr = { q = {}, qi = 1, h = {}, phase = 1, order = {} }
    sc.tr = tr
    sc.sel = {}
    local stop = sc.first[sc.near] or sc.first[sc.top + 1] or 1
    if sc.near > sc.top then
      stop = sc.n + 1
    end
    for j = 1, stop - 1 do
      tr.q[#tr.q + 1] = j
      tr.h[j] = 0
      tr.order[#tr.order + 1] = j
      sc.sel[sc.units[j]] = true
    end
    spent = spent + #tr.q * SCAN_UNITS
  end
  local hops = floor(tonumber(O.trace_hops) or 0)
  local down = floor(tonumber(O.trace_down) or 0)
  local idx, ents = sc.idx, sc.ents
  while spent < limit do
    if tr.qi > #tr.q then
      if tr.phase == 1 then
        -- Downstream from everything traced so far.
        tr.phase, tr.q, tr.qi = 2, {}, 1
        for _, j in ipairs(tr.order) do
          tr.q[#tr.q + 1] = j
          tr.h[j] = 0
        end
        tr.order = nil
        if down <= 0 then
          break
        end
      else
        break
      end
    end
    local j = tr.q[tr.qi]
    tr.qi = tr.qi + 1
    local h = tr.h[j]
    local bound = tr.phase == 1 and hops or down
    if (bound <= 0 or h < bound) and ents[j].valid then
      spent = spent + TARGET_UNITS
      local ins, outs = neighbours_of(ents[j])
      for _, u in ipairs(tr.phase == 1 and ins or outs) do
        local k = idx[u]
        if k and not sc.sel[u] then
          sc.sel[u] = true
          tr.h[k] = h + 1
          tr.q[#tr.q + 1] = k
          if tr.order then
            tr.order[#tr.order + 1] = k
          end
        end
      end
    else
      spent = spent + SKIP_UNITS
    end
  end
  local done = tr.phase == 2 and (tr.qi > #tr.q or down <= 0)
  if done then
    local n = 0
    for _ in pairs(sc.sel) do
      n = n + 1
    end
    sc.nsel = n
    M.counts.traced = n
    sc.tr = nil
  end
  return spent, done
end

-- Scans up to `limit` units: returns the units spent and whether it finished. Once a scan has been
-- taken, at most SCAN_FINDS a tick of its chunks are searched afresh (chunk_belts' lists expire
-- together, CHUNK_REFRESH after a load: a scan again then found 10-20 chunks on one tick, 30-85 ms
-- at -62,-26); the first scan reads as many as the units allow.
local SCAN_FINDS = 2
local function scan_step(b, sc, limit)
  local surface = world.surface()
  local spent = 0
  local finds, most = 0, b.scan and SCAN_FINDS or math.huge
  if not sc.list then
    -- The chunks the square touches.
    local list = {}
    for cx = floor((sc.fx - sc.r) / 32), floor((sc.fx + sc.r) / 32) do
      for cy = floor((sc.fy - sc.r) / 32), floor((sc.fy + sc.r) / 32) do
        list[#list + 1] = { cx, cy }
      end
    end
    sc.list = list
  end
  -- (The remote view's filter as the game is now, not its module-local cache: what is read goes in
  -- storage.)
  local seen = map.view_filter(true)
  while spent < limit and sc.ci <= #sc.list do
    local c = sc.list[sc.ci]
    sc.ci = sc.ci + 1
    local belts, u = chunk_belts(b, surface, c[1], c[2])
    spent = spent + u + FIND_UNITS
    if u > 0 then
      finds = finds + 1
    end
    for _, e in ipairs(belts) do
      local dx, dy = e[3] - sc.fx, e[4] - sc.fy
      local ring = floor(math.max(dx < 0 and -dx or dx, dy < 0 and -dy or dy))
      if ring < sc.r and (not seen or seen(e[3], e[4])) then
        local bucket = sc.by[ring]
        if not bucket then
          bucket = {}
          sc.by[ring] = bucket
          if ring > sc.top then
            sc.top = ring
          end
        end
        bucket[#bucket + 1] = e
        spent = spent + SCAN_UNITS
      end
    end
    if finds >= most then
      break
    end
  end
  if sc.ci <= #sc.list then
    return spent, false
  end
  if not sc.ents then
    -- Flattened nearest ring first, with where each ring starts.
    local ents, units, xs, ys, rings, first = {}, {}, {}, {}, {}, {}
    for ring = 0, sc.top do
      first[ring] = #ents + 1
      for _, e in ipairs(sc.by[ring] or {}) do
        local j = #ents + 1
        ents[j], units[j], xs[j], ys[j], rings[j] = e[1], e[2], e[3], e[4], ring
      end
    end
    first[sc.top + 1] = #ents + 1
    local idx = {}
    for j = 1, #ents do
      idx[units[j]] = j
    end
    sc.ents, sc.units, sc.xs, sc.ys, sc.rings, sc.first, sc.n, sc.idx = ents, units, xs, ys, rings, first, #ents, idx
    sc.by, sc.chunks = nil, nil
    spent = spent + #ents * SCAN_UNITS
  end
  -- (area trace: the belts to load, traced from the near square.)
  if sc.near and not sc.nsel then
    local u, done = trace_step(sc, limit - spent)
    spent = spent + u
    if not done then
      return spent, false
    end
  end
  sc.list = nil
  return spent, true
end

-- A finished scan taken: loaded belts outside it dropped; the load pointer back to its start.
local function take_scan(b, sc, p)
  local inside = sc.idx
  local c = cap()
  local keep = sc.r
  local edge = nil
  if c < math.huge then
    -- Items + lanes of the loaded lanes, ring by ring, and the cap's edge kept or moved.
    local cum, total = {}, 0
    for ring = 0, sc.top do
      for j = sc.first[ring], sc.first[ring + 1] - 1 do
        local unit = sc.units[j]
        if b.belts[unit] then
          for i = 1, LANE_KEYS do
            local rec = b.lanes[unit * LANE_KEYS + i]
            if rec then
              total = total + rec[1] + 1
            end
          end
        end
      end
      cum[ring] = total
    end
    edge = b.edge
    if edge then
      if (cum[edge - 1] or total) > c * KEEP then
        edge = nil
        for ring = 0, sc.top do
          if cum[ring] > c then
            edge = ring + 1
            break
          end
        end
      elseif (cum[edge - 1] or total) < c * GROW then
        edge = nil
      end
    end
    keep = math.min(sc.r, (edge or sc.r) + DROP)
  end
  b.edge = edge
  local drop = {}
  local sel = sc.sel
  for unit in pairs(b.belts) do
    local j = inside[unit]
    if not j or sc.rings[j] >= keep or (sel and not sel[unit]) then
      drop[#drop + 1] = unit
    end
  end
  table.sort(drop)
  for _, unit in ipairs(drop) do
    drop_belt(b, unit, p)
  end
  -- The chunk caches outside the square (its belts, bs.bc; the belts inserters and drills use, bs.bt)
  -- and the actors those listed are forgotten: they only grew as the focus moved, every actor checked
  -- every update. (A chunk either side too: a neighbour's targets are looked up where it stands.
  -- Found again when the square comes back. Order-free: the same whatever pairs gives.)
  local cx0, cx1 = floor((sc.fx - sc.r) / 32) - 1, floor((sc.fx + sc.r) / 32) + 1
  local cy0, cy1 = floor((sc.fy - sc.r) / 32) - 1, floor((sc.fy + sc.r) / 32) + 1
  local function outside(key)
    local cx, cy = floor(key / 65536) - 32768, key % 65536 - 32768
    return cx < cx0 or cx > cx1 or cy < cy0 or cy > cy1
  end
  if b.bc then
    for key in pairs(b.bc) do
      if outside(key) then
        b.bc[key] = nil
      end
    end
  end
  if b.bt then
    local gone, kept = {}, {}
    for key, t in pairs(b.bt) do
      if outside(key) then
        b.bt[key] = nil
        for _, u in ipairs(t.a or {}) do
          gone[#gone + 1] = u
        end
      else
        for _, u in ipairs(t.a or {}) do
          kept[u] = true
        end
      end
    end
    local pruned = false
    for _, u in ipairs(gone) do
      if not kept[u] then
        b.actors[u] = nil
        pruned = true
      end
    end
    -- (The actors' list and its seen set made again without them: one found again when the square
    -- comes back is then listed again by enlist; still in aseen it would be in bs.actors but never
    -- checked.)
    if pruned then
      local list, seen = {}, {}
      for _, u in ipairs(b.alist) do
        if b.actors[u] then
          enlist(list, seen, u)
        end
      end
      b.alist, b.aseen = list, seen
    end
  end
  b.scan, b.load_i, b.load_total = sc, 1, 0
  b.wver = (b.wver or 0) + 1
  M.counts.scans = M.counts.scans + 1
  return #drop
end

-- The unit numbers of the belts a belt feeds (an underground entrance's exit too).
local function outputs_of(belt)
  local outs = {}
  if belt.type == "underground-belt" and belt.belt_to_ground_type == "input" then
    local ok, other = pcall(function() return belt.underground_belt_neighbour end)
    if ok and other and other.valid and other.unit_number then
      outs[#outs + 1] = other.unit_number
    end
  end
  local ok, nb = pcall(function() return belt.belt_neighbours end)
  if ok and nb then
    for _, e in pairs(nb.outputs or {}) do
      if e.valid and e.unit_number then
        outs[#outs + 1] = e.unit_number
      end
    end
  end
  return outs
end

-- Loads the scan's belt j0 after the unloaded belts of the scan it leads into, and those after the
-- ones they lead into (depth first, within the ring `stop`), so that a lane is loaded after the one
-- it feeds: a lane whose next isn't loaded yet leads out of what is sent, which the client can only
-- hold where it was read, while one whose feeder isn't loaded yet only misses what comes in, which
-- the feeder's load reads again. Up to `limit` units (at least one belt). Returns the units spent
-- and whether j0 was loaded.
local function load_chain(b, sc, j0, stop, limit, p)
  local spent = 0
  local order, seen = {}, { [j0] = true }
  local stack = { { j0 } }
  while #stack > 0 do
    local top = stack[#stack]
    if not top[2] then
      local kids = {}
      top[2], top[3] = kids, 1
      local belt = sc.ents[top[1]]
      if belt.valid then
        spent = spent + TARGET_UNITS
        for _, u in ipairs(outputs_of(belt)) do
          local j = sc.idx and sc.idx[u]
          if j and not seen[j] and not b.belts[u] and sc.rings[j] < stop and sc.ents[j].valid and (not sc.sel or sc.sel[u]) then
            seen[j] = true
            kids[#kids + 1] = j
          end
        end
      end
    end
    local kids = top[2]
    if top[3] <= #kids then
      stack[#stack + 1] = { kids[top[3]] }
      top[3] = top[3] + 1
    else
      stack[#stack] = nil
      order[#order + 1] = top[1]
    end
  end
  for x, j in ipairs(order) do
    if x > 1 and spent >= limit then
      return spent, false
    end
    local unit = sc.units[j]
    local belt = sc.ents[j]
    if not b.belts[unit] and belt.valid then
      spent = spent + load_belt(b, belt, unit, sc.xs[j], sc.ys[j], p)
    end
  end
  return spent, true
end

-- Loads belts nearest first, up to `limit` units: the next unloaded belts of the scan (each after
-- those it leads into within CHAIN_RINGS rings further out: load_chain). Returns the units spent.
local CHAIN_RINGS = 4
local function load_step(b, limit, p)
  local sc = b.scan
  if not sc then
    return 0
  end
  local spent = 0
  local c = cap()
  local stop = math.min(sc.r, b.edge or sc.r)
  local j = b.load_i or 1
  -- (With the cap: items + lanes of the loaded lanes passed so far, ring by ring.)
  local total = b.load_total or 0
  while j <= sc.n and spent < limit do
    local ring = sc.rings[j]
    if ring >= stop then
      break
    end
    local unit = sc.units[j]
    spent = spent + SKIP_UNITS
    if not b.belts[unit] and sc.ents[j].valid and (not sc.sel or sc.sel[unit]) then
      -- (The belts it leads into a few rings further out at most: a main line's whole length first
      -- held the near rings back for seconds.)
      local u, done = load_chain(b, sc, j, O.full_area and math.min(stop, ring + CHAIN_RINGS) or stop, limit - spent, p)
      spent = spent + u
      if not done then
        break
      end
    end
    if c < math.huge and b.belts[unit] then
      for i = 1, LANE_KEYS do
        local rec = b.lanes[unit * LANE_KEYS + i]
        if rec then
          total = total + rec[1] + 1
        end
      end
    end
    j = j + 1
    if total > c and (j > sc.n or sc.rings[j] ~= ring) then
      b.edge = ring + 1
      break
    end
  end
  b.load_i, b.load_total = j, total
  return spent
end

-- The first ring with a belt not loaded yet (or the radius): every lane inside it is loaded.
local function loaded_edge(b)
  local sc = b.scan
  if not sc then
    return 0
  end
  local fr = math.min(sc.r, b.edge or sc.r)
  local sel = sc.sel
  for j = b.load_i or 1, sc.n do
    local ring = sc.rings[j]
    if ring >= fr then
      break
    end
    local unit = sc.units[j]
    if not b.belts[unit] and (not sel or sel[unit]) then
      return ring
    end
  end
  -- (Belts before load_i that were dropped or reloaded are loaded again or gone; a belt before it
  -- not loaded is one that wasn't valid.)
  return fr
end

---------------------------------------------------------------------------------------------
-- An update.
--
-- bs.round = {start, steps: the steady work's queue (reloads, `bre` lanes, watched belts, drift
-- checks), i, units, scan (one being made)}.

-- Drift checks' bands of rings {from, to, how many times pc_every apart} (drift_far), and without it.
local DRIFT_NEAR = 48
local DRIFT_BANDS = { { 0, DRIFT_NEAR, 1 }, { DRIFT_NEAR, 2 * DRIFT_NEAR, 2 }, { 2 * DRIFT_NEAR, math.huge, 4 } }
local DRIFT_ONE = { { 0, math.huge, 1 } }

-- The watched belts in the order they are checked (input spots first, then nearest first: the
-- scan's order, so the reads for accuracy alone (extra_units) go where the player is looking before
-- they run out), with those fed from outside what is sent when feed_edges is off. Kept in storage
-- and sorted again only when a belt was loaded or dropped or a scan taken (bs.wver): sorting every
-- update cost more than the checks themselves at 160 tiles.
local function watch_order(b)
  local c = b.wcache
  if c and c.ver == (b.wver or 0) and c.fe == O.feed_edges and c.inf == O.inputs_first then
    return c.list
  end
  local w = {}
  for unit in pairs(b.wset) do
    w[#w + 1] = unit
  end
  if not O.feed_edges then
    for unit in pairs(b.iset) do
      if not b.wset[unit] then
        w[#w + 1] = unit
      end
    end
  end
  local sc0 = b.scan
  local order = sc0 and sc0.idx
  if order then
    -- (Sort keys worked out once, not in the comparison.)
    local big = math.huge
    local belts = b.belts
    local spot = O.inputs_first
    local key = {}
    for _, u in ipairs(w) do
      local r = belts[u]
      key[u] = ((spot and not (r and r[12])) and 1e9 or 0) + (order[u] or 5e8)
    end
    table.sort(w, function(x, y)
      local kx, ky = key[x], key[y]
      if kx ~= ky then
        return kx < ky
      end
      return x < y
    end)
  else
    table.sort(w)
  end
  b.wcache = { ver = b.wver or 0, fe = O.feed_edges, inf = O.inputs_first, list = w }
  return w
end

-- The steady work's queue: segments {kind, list} worked through in order (1 belts touched by events,
-- loaded again whole; 2 groups of lanes the client asked for again; 7 inserters and drills; 3
-- watched belts, then the outermost ring's; 4 drift checks), lists of unit numbers (groups for 2):
-- no table a step.
local function make_queue(b, fr)
  local tb = profile.start()
  local q = {}
  -- Belts touched by events: loaded again whole (lm and sl).
  if #b.reload > 0 then
    q[#q + 1] = { 1, b.reload }
    b.reload = {}
  end
  -- Lanes the client asked for again, in groups read each on one tick: the lanes of belts next to
  -- each other (the client moves a read's packed run with it, but for items another read set on the
  -- same tick: lanes of one run read a tick apart tore it, the later read moving the earlier one's
  -- items).
  -- (In the order they were asked for, at most bre_cap an update: the rest wait in bs.breq.)
  local asked = {}
  if not b.breq and next(b.bre) then
    -- (A save from before the queue: its asked lanes queued by key.)
    local old = {}
    for key in pairs(b.bre) do
      old[#old + 1] = key
    end
    table.sort(old)
    b.breq, b.breh = old, 1
  end
  local queue = b.breq or {}
  local head = b.breh or 1
  local cap_n = tonumber(O.bre_cap) or 0
  local last = #queue
  if cap_n > 0 and last - head + 1 > cap_n then
    last = head + cap_n - 1
  end
  for k = head, last do
    local key = queue[k]
    asked[#asked + 1] = key
    b.bre[key] = nil
  end
  head = last + 1
  if head > #queue then
    queue, head = {}, 1
  elseif head > 1024 then
    local rest = {}
    for k = head, #queue do
      rest[#rest + 1] = queue[k]
    end
    queue, head = rest, 1
  end
  b.breq, b.breh = queue, head
  M.counts.bre_held = (M.counts.bre_held or 0) + #queue - head + 1
  table.sort(asked)
  local group_of, groups = {}, {}
  for _, key in ipairs(asked) do
    local unit = floor((key - 1) / LANE_KEYS)
    local g = group_of[unit]
    if not O.line_rereads then
      g = { 2 }
      groups[#groups + 1] = g
    elseif not g then
      local rec = b.belts[unit]
      for _, list in ipairs(rec and { rec[7] or {}, rec[8] or {} } or {}) do
        for _, u in ipairs(list) do
          g = g or group_of[u]
        end
      end
    end
    if not g then
      g = { 2 }
      groups[#groups + 1] = g
    end
    group_of[unit] = g
    g[#g + 1] = key
  end
  if #groups > 0 then
    q[#q + 1] = { 2, groups }
  end
  M.counts.bre_lanes = (M.counts.bre_lanes or 0) + #asked
  profile.stop("bsq.bre", tb)
  local tq = profile.start()
  -- Inserters and drills that use belts (a call or two each): one that acted wakes its belts.
  local live = 0
  for _, unit in ipairs(b.alist) do
    if b.actors[unit] then
      live = live + 1
    end
  end
  if #b.alist > 2 * live + 64 then
    local list, seen = {}, {}
    for _, unit in ipairs(b.alist) do
      if b.actors[unit] then
        enlist(list, seen, unit)
      end
    end
    b.alist, b.aseen = list, seen
  end
  if O.inputs_first and #b.alist > 0 then
    -- (The list as it is now: actors found later in this update wait for the next.)
    local list = {}
    for k, unit in ipairs(b.alist) do
      list[k] = unit
    end
    q[#q + 1] = { 7, list }
  end
  profile.stop("bsq.actors", tq)
  tq = profile.start()
  -- Input spots, then the other watched belts, then the outermost ring's (those fed from outside
  -- what is sent are checked on the update's tick: check_edges).
  local w = watch_order(b)
  if #w > 0 then
    q[#q + 1] = { 3, w }
  end
  profile.stop("bsq.sort", tq)
  tq = profile.start()
  local sc = b.scan
  -- (area trace: no outermost ring; every belt leading out of or fed from outside what is loaded is
  -- in bs.oset or bs.iset, checked on the update's tick.)
  if sc and not sc.sel and fr > 0 and sc.first[fr - 1] then
    local ring = {}
    local wset, iset, fe = b.wset, b.iset, O.feed_edges
    for j = sc.first[fr - 1], (sc.first[fr] or sc.n + 1) - 1 do
      local unit = sc.units[j]
      if b.belts[unit] and not wset[unit] and not iset[unit] then
        ring[#ring + 1] = unit
      end
    end
    if #ring > 0 then
      q[#q + 1] = { 3, ring }
    end
  end
  profile.stop("bsq.ring", tq)
  tq = profile.start()
  -- Drift checks: the scan's belts on this update's turn.
  if sc then
    local list = {}
    -- (By bands of rings, each its own stride: drift_far.)
    local bands = O.drift_far and DRIFT_BANDS or DRIFT_ONE
    for _, band in ipairs(bands) do
      local r0, r1 = band[1], math.min(band[2], sc.top + 1)
      if r0 <= sc.top then
        local j0, j1 = sc.first[r0], sc.first[r1] - 1
        local stride = M.pc_every * band[3]
        local turn = b.count % stride
        for j = j0 + (turn - (j0 - 1)) % stride, j1, stride do
          local unit = sc.units[j]
          if b.belts[unit] and (O.drift_watched or not b.wset[unit]) and not b.oset[unit] and not b.iset[unit] then
            list[#list + 1] = unit
          end
        end
      end
    end
    if #list > 0 then
      q[#q + 1] = { 4, list }
    end
  end
  profile.stop("bsq.drift", tq)
  return q
end

-- An inserter or drill that uses a belt, checked: its hand holding more or less than at its last
-- check, a drill's progress gone round: it took from or put on its belts, which are woken (their
-- lanes checked when their turn comes, never quiet then, packed ones by their ids). Returns the units.
local ACTOR_UNITS = 1.5
-- actor_backoff: an inserter whose hand held the same at ACTOR_IDLE checks running is checked every
-- other update, at 2 * ACTOR_IDLE every ACTOR_SKIP'th (a hand that moves again is checked every update
-- from then on); a drill is passed over until about an update before its progress comes round, from
-- how fast it went, at most ACTOR_SKIP updates. a[6]: checks unchanged in a row; a[7]: the update
-- (bs.count) it is checked again at; a[8]: the tick of a drill's last check.
local ACTOR_IDLE, ACTOR_SKIP, DRILL_SKIP = 4, 2, 4
local function actor_check(b, unit, period)
  local a = b.actors[unit]
  if not a then
    return 0
  end
  local backoff = O.actor_backoff
  if backoff and a[7] and b.count < a[7] then
    M.counts.actors_skipped = (M.counts.actors_skipped or 0) + 1
    return 0.2
  end
  a[7] = nil
  local v, mp = actor_value(a)
  if v == nil then
    b.actors[unit] = nil
    return 1
  end
  local was, was_mp = a[5], a[9]
  a[5], a[9] = v, mp
  M.counts.actors = (M.counts.actors or 0) + 1
  local now = game.tick
  if was == nil or v == was or (a[4] and v > was) then
    if backoff then
      if a[4] then
        -- (A drill: ticks until its progress comes round, at the rate it went since its last check.)
        local last = a[8]
        if last and mp and was_mp and mp > was_mp and now > last then
          local rate = (mp - was_mp) / (now - last)
          local eta = (1 - mp) / rate
          local skip = floor(eta / math.max(1, period)) - 1
          if skip > 0 then
            a[7] = b.count + math.min(DRILL_SKIP, skip)
          end
        end
      end
      if not a[7] and v == was then
        -- (An inserter's hand or a drill's progress standing: the same backoff.)
        local idle = (a[6] or 0) + 1
        a[6] = idle
        a[7] = idle >= ACTOR_IDLE and b.count + ACTOR_SKIP or nil
      else
        a[6] = 0
      end
    end
    a[8] = now
    return ACTOR_UNITS
  end
  a[6], a[7], a[8] = 0, nil, now
  M.counts.acted = (M.counts.acted or 0) + 1
  for k = 2, 3 do
    local u = a[k]
    if u and b.belts[u] then
      b.wake[u] = true
      -- (A pickup belt's feeder too: a hand chases an item across the belt's back edge.)
      if k == 2 then
        for _, w in ipairs(b.belts[u][8] or {}) do
          if b.belts[w] and b.belts[w][12] then
            b.wake[w] = true
          end
        end
      end
    end
  end
  return ACTOR_UNITS
end

local STEP_NAMES = { "bs.reload", "bs.bre", "bs.watch", "bs.drift", nil, nil, "bs.actor" }
local function do_step(b, kind, v, p, period)
  if kind == 7 then
    return actor_check(b, v, period)
  elseif kind == 2 then
    -- A group of asked lanes, read on this tick with the packed runs round them (while the reads
    -- for accuracy have room).
    local units, extra, units_of = 0, 0, {}
    for x = 2, #v do
      local key = v[x]
      local unit, i = floor((key - 1) / LANE_KEYS), (key - 1) % LANE_KEYS + 1
      local rec = b.belts[unit]
      if rec and rec[1].valid then
        local lines = lines_of(rec[1], unit)
        if lines[i] then
          units = units + read_lane(b, rec[1], unit, i, lines, true, p)
          if not units_of[unit] then
            units_of[unit] = true
            units_of[#units_of + 1] = unit
          end
        end
      else
        units = units + 1
      end
    end
    for _, unit in ipairs(units_of) do
      if O.line_rereads and extra_left(b) then
        local x = read_runs(b, unit, true, true, p)
        extra_spend(b, x)
        extra = extra + x
      end
    end
    return units, extra
  end
  local rec = b.belts[v]
  if not rec then
    return 1
  end
  local belt = rec[1]
  if not belt.valid then
    drop_belt(b, v, p)
    return 1
  end
  if kind == 1 then
    return load_belt(b, belt, v, rec[2], rec[3], p)
  elseif kind == 3 then
    local now = game.tick
    -- Every lane quiet until rec[13] (worked out at its last check; a read or check of one of its
    -- lanes since clears it): passed over as a whole, as each lane would be.
    local due = rec[13]
    -- (crossings game: a splitter is never passed over whole, whatever its lanes' last check said.)
    if due and O.crossings == "game" then
      local t = rec[14] or belt.type
      if t == "splitter" or t == "lane-splitter" then
        due = nil
      end
    end
    if due and now < due and not b.wake[v] then
      M.counts.quiet_belts = (M.counts.quiet_belts or 0) + 1
      rec[9] = now
      return 0.5
    end
    local lines = lines_of(belt, v)
    local units = 0
    local changed, settled = false, false
    for i = 1, #lines do
      local u, ev = watch_lane(b, belt, v, i, lines, p)
      units = units + u
      changed = changed or ev == 1 or ev == 3
      settled = settled or ev == 2
    end
    -- (Only belts whose every lane can be quiet: not leading out, not fed from outside, no circuit.)
    if not (b.oset[v] or (O.feed_edges and b.iset[v]) or rec[5]) then
      if M.quiet_ticks > 0 then
        due = math.huge
        local qa = M.quiet_after
        for i = 1, #lines do
          local lr = b.lanes[v * LANE_KEYS + i]
          if lr then
            local qt = quiet_for(rec, lr)
            if qt > 0 and (lr[7] or 0) >= qa and not (O.checkpoints and checkpoint_lane(rec, belt, i, lines)) and not crossing_lane(i, lines) then
              local d = lr[6] + qt
              if d < due then
                due = d
              end
            else
              due = now
            end
          end
        end
        rec[13] = due > now and due or nil
      end
    end
    -- Changed: the belts it feeds read too, as far as the client can have carried an item on since
    -- the last check (one an inserter took there that the client still had is gone from them; one
    -- dropped there that ran on shows).
    local last = rec[9] or now
    rec[9] = now
    -- (Only where an inserter, a drill or a splitter put or took items: elsewhere the client's
    -- simulation already carries them as the game does.)
    local t = rec[14] or belt.type
    b.wake[v] = nil
    -- (On this tick, as the lane's own read: a read a tick later would move this one's items. Apart
    -- from the units the steady limit counts, so every input spot is checked first.)
    local extra = 0
    if changed and M.tails and (rec[11] or t == "splitter" or t == "lane-splitter") and extra_left(b) then
      local r0 = M.counts.read
      for _, u in ipairs(rec[7] or {}) do
        extra = extra + catch_up(b, u, math.max(1, now - last), p, CATCH_DEPTH - TAIL_DEPTH + 1)
      end
      M.counts.r_tail = (M.counts.r_tail or 0) + M.counts.read - r0
    end
    if settled and M.settle_around and (rec[11] or t == "splitter" or t == "lane-splitter") and extra_left(b) then
      local r0 = M.counts.read
      extra = extra + settle_around(b, v, p)
      M.counts.r_settle = (M.counts.r_settle or 0) + M.counts.read - r0
    end
    extra_spend(b, extra)
    if rec[5] then
      local off = is_off(belt)
      units = units + 1
      if off ~= (rec[6] or false) then
        M.counts.of = M.counts.of + 1
        if p then
          p.of[#p.of + 1] = S(v)
          p.of[#p.of + 1] = off and "1" or "0"
        end
      end
      rec[6] = off
    end
    if not O.inputs_first then
      return units + extra
    end
    return units, extra
  end
  return drift_check(b, belt, v, p)
end

-- On the update's tick: the lanes leading out of what is sent, checked and read in full where they
-- changed (the client's walls are then where the game's fronts are at the update's tick); every lane
-- of the belts fed from outside it, the same (what came in is then the game's at the update's
-- tick). Returns the units.
local function check_edges(b, p)
  local list = {}
  for unit in pairs(b.oset) do
    list[#list + 1] = unit
  end
  table.sort(list)
  local units = 0
  local fed = {}
  for unit in pairs(O.feed_edges and b.iset or {}) do
    fed[#fed + 1] = unit
  end
  table.sort(fed)
  local t = profile.start()
  for _, unit in ipairs(fed) do
    local rec = b.belts[unit]
    if rec and rec[1].valid then
      local belt = rec[1]
      local lines = lines_of(belt, unit)
      for i = 1, #lines do
        units = units + watch_lane(b, belt, unit, i, lines, p)
      end
      M.counts.feeds = (M.counts.feeds or 0) + 1
    end
  end
  profile.stop("bs.feed", t)
  t = profile.start()
  for _, unit in ipairs(list) do
    local rec = b.belts[unit]
    if rec and rec[1].valid then
      local belt = rec[1]
      local lines = lines_of(belt, unit)
      for i = 1, #lines do
        if exit_line(belt, i) then
          units = units + watch_lane(b, belt, unit, i, lines, p)
        end
      end
    end
  end
  profile.stop("bs.edge", t)
  return units
end

-- The text of one part: its fields' ranges written as JSON lists. The lists hold the numbers' text
-- already (S, where they are written), so each range is one table.concat in C, no loop over the
-- numbers here (the perfbridge2 round: that loop was most of bse.text, 6-10 ms an update at -62,-26).
local PART_FIELDS = { "lm", "sl", "ew", "sh", "pc", "pu", "dl", "of" }
local part_pieces = {}
local function part_text(head, k, part)
  local text = { head, ',"part":', k }
  local pieces = part_pieces
  for _, field in ipairs(PART_FIELDS) do
    local ranges = part[field]
    if #ranges > 0 then
      local n = 0
      for r = 1, #ranges, 3 do
        n = n + 1
        pieces[n] = table.concat(ranges[r], ",", ranges[r + 1], ranges[r + 2])
      end
      text[#text + 1] = ',"' .. field .. '":[' .. table.concat(pieces, ",", 1, n) .. "]"
    end
  end
  local ranges = part.qu
  if #ranges > 0 then
    local q = {}
    for r = 1, #ranges, 3 do
      local list = ranges[r]
      for y = ranges[r + 1], ranges[r + 2], 2 do
        q[#q + 1] = list[y] .. ',"' .. list[y + 1] .. '"'
      end
    end
    text[#text + 1] = ',"qu":[' .. table.concat(q, ",") .. "]"
  end
  return table.concat(text)
end

-- The spool (send_cap): parts waiting to be sent, oldest first, each {head, part number, the part's
-- ranges, the update's tick}. Module-local: only what is sent depends on it, never storage, and a
-- peer that loaded the save mid-update sends less.
local spool = {}
local SPOOL_LONG = 12

-- The bytes a tick send_cap allows (no cap: everything at once).
local function send_cap()
  local cap = tonumber(O.send_cap) or 0
  return cap > 0 and cap or math.huge
end

-- Sends the spool's next parts: at least one, then more while the tick's bytes stay under `cap`; with
-- more than SPOOL_LONG parts waiting (updates coming faster than the cap sends them), two at least.
local function spool_step(cap)
  if #spool == 0 then
    return
  end
  local bytes, sent = 0, 0
  while #spool > 0 do
    local item = spool[1]
    -- (bse.text: the part's text; bse.send: handing it to transport, a datagram when the batch fills.)
    local te = profile.start()
    local text = part_text(item[1], item[2], item[3])
    profile.stop("bse.text", te)
    te = profile.start()
    -- (The part's `k` is its update's tick, not this one's.)
    transport.send_text_at("bs", item[4], text)
    profile.stop("bse.send", te)
    bytes, sent = bytes + #text, sent + 1
    table.remove(spool, 1)
    if bytes >= cap and not (#spool > SPOOL_LONG and sent < 2) then
      break
    end
  end
  M.counts.spooled = (M.counts.spooled or 0) + sent
end

-- How many parts wait in the spool (tests).
function M.spooled()
  return #spool
end

-- Writes the update as `bs` parts. Each part's fields are kept as ranges of the update's lists
-- (nothing copied), written straight into the part's text.
local function emit(b, p, period, fr, work, loading)
  local te = profile.start()
  local sc = b.scan
  local parts = {}
  local cur, size = nil, 0
  local most = part_numbers()
  local function new_part()
    cur = { lm = {}, sl = {}, qu = {}, pc = {}, pu = {}, dl = {}, of = {}, ew = {}, sh = {} }
    parts[#parts + 1] = cur
    size = 0
  end
  new_part()
  -- (A range: list, from, to; one after another in the part's field.)
  local function add(field, list, from, to)
    if size > 0 and size + (to - from + 1) > most then
      new_part()
    end
    local out = cur[field]
    local m = #out
    out[m + 1], out[m + 2], out[m + 3] = list, from, to
    size = size + (to - from + 1)
  end
  local dl, of, lm = p.dl, p.of, p.lm
  for x = 1, #dl, 64 do
    add("dl", dl, x, math.min(#dl, x + 63))
  end
  for x = 1, #of, 2 do
    add("of", of, x, x + 1)
  end
  -- Each lane's meta goes in the part with (or before) its items: metas first, by key.
  for x = 1, #lm, 12 do
    add("lm", lm, x, x + 11)
  end
  local sl, x = p.sl, 1
  while x <= #sl do
    local n = sl[x + 2]
    add("sl", sl, x, x + 2 + n * 4)
    x = x + 3 + n * 4
  end
  local qu = p.qu
  for y = 1, #qu, 2 do
    add("qu", qu, y, y + 1)
  end
  local ew = p.ew
  for y = 1, #ew, 4 do
    add("ew", ew, y, y + 3)
  end
  local sh = p.sh
  for y = 1, #sh, 64 do
    add("sh", sh, y, math.min(#sh, y + 63))
  end
  -- (pc 7 wide here: the last two its packed lane's front and back ids, 0 when not packed, sent in
  -- `pu` in the same part.)
  local pc = p.pc
  local pu = {}
  for y = 1, #pc, 7 do
    add("pc", pc, y, y + 4)
    if pc[y + 5] ~= 0 then
      local m = #pu
      pu[m + 1], pu[m + 2], pu[m + 3] = pc[y], pc[y + 5], pc[y + 6]
      local out = cur.pu
      local k = #out
      out[k + 1], out[k + 2], out[k + 3] = pu, m + 1, m + 3
      size = size + 3
    end
  end
  profile.stop("bse.build", te)
  local head = ',"parts":' .. #parts .. ',"p":' .. period .. ',"w":' .. floor(work)
    .. ',"fx":' .. world.fixed(sc and sc.fx or 0) .. ',"fy":' .. world.fixed(sc and sc.fy or 0) .. ',"fr":' .. fr
    .. (loading and ',"ld":1' or "")
  -- (send_cap: the parts join the spool, sent over the ticks from this one; off, all now.)
  local n = #spool
  for k = 1, #parts do
    spool[n + k] = { head, k, parts[k], game.tick }
  end
  spool_step(send_cap())
end

-- Steady units a tick: spread over the update's ticks from what the last one took.
local function steady_units(b, period)
  return math.max(M.units_per_tick, ceil((b.work or 0) * 1.5 / math.max(1, period - 1)))
end

-- The rate.lua job the updates' ticks follow (M.OPTIONS own_rate): their own, `bs`, or the glided
-- belt items', `bi`, as before.
local function rate_job()
  return O.own_rate and "bs" or "bi"
end

function M.planned_units()
  read_options()
  local b = storage.f3d.bs
  if not b then
    return 0
  end
  local period = rate.period(rate_job(), settings.global["f3d-detail-interval"].value)
  return floor(steady_units(b, period) / UNITS_PER_BUDGET_UNIT)
end

function M.tick()
  read_options()
  local s = storage.f3d
  local r = radius()
  if r <= 0 then
    s.bs, pays[s] = nil, nil
    spool = {}
    return
  end
  -- (send_cap: the last update's parts still waiting go first, under the cap.)
  spool_step(send_cap())
  local b = state()
  local interval = settings.global["f3d-detail-interval"].value
  local job = rate_job()
  local period = rate.period(job, interval)
  local due = rate.due(job, interval)
  local surface = world.surface()
  if b.si ~= surface.index then
    M.reset()
    b = state()
    b.si = surface.index
  end
  -- A new round: the steady work's queue; a new scan when one is wanted and none is being made.
  local round = b.round
  if round and round.v ~= 2 then
    -- (A round from a save made before the queue was segments: started again.)
    round, b.round = nil, nil
  end
  if not round then
    round = { v = 2, start = game.tick, units = 0, loaded = 0, fast = 0 }
    b.round = round
    pays[s] = new_payload(round.start)
    local t0 = profile.start()
    round.units = round.units + forget_touched(b)
    profile.stop("bsq.forget", t0)
    t0 = profile.start()
    local f = s.focus
    local sc = b.scan
    local moved = sc and (math.abs(sc.fx - f.x) >= 1 or math.abs(sc.fy - f.y) >= 1)
    -- (area trace: a scan again when the switch, the near square or the trace's bounds changed.)
    local tr = trace_on()
    local retrace = sc and ((tr and (sc.near ~= near_now() or sc.tkey ~= trace_key())) or (not tr and sc.near ~= nil))
    if not b.scanning and (b.rescan or not sc or moved or retrace or sc.r ~= r or b.count - (b.scan_count or -SCAN_EVERY) >= SCAN_EVERY or b.cap_was ~= cap()) then
      if moved then
        M.counts.scan_moved = M.counts.scan_moved + 1
      elseif b.rescan then
        M.counts.scan_dirty = M.counts.scan_dirty + 1
      end
      b.scanning = new_scan(f, r)
      b.rescan, b.scan_count, b.cap_was = nil, b.count, cap()
    end
    local te = profile.start()
    local fr0 = loaded_edge(b)
    profile.stop("bsq.edge", te)
    round.q, round.i, round.j = make_queue(b, fr0), 1, nil
    profile.stop("bs.queue", t0)
  end
  local p = payload(b)
  local fast = 0
  local steady = steady_units(b, period)
  local limit = due and steady * DUE_BURST or steady
  local spent = 0
  -- The scan (over as many ticks as it takes), then the steady queue.
  if b.scanning then
    local t = profile.start()
    local u, done = scan_step(b, b.scanning, limit)
    spent = spent + u
    if done then
      take_scan(b, b.scanning, p)
      b.scanning = nil
    end
    profile.stop("bs.scan", t)
  end
  local q = round.q
  -- (extra_spread: the reads for accuracy alone (runs round asked lanes, tails, reads round a settled
  -- belt) stop for the tick once they took their share of extra_units, the rest of the queue waiting a
  -- tick; without it the asked lanes' runs all landed on the round's first tick. Not on the due tick:
  -- what is left of the round is done then.)
  local xcap = math.huge
  if O.extra_spread and not due then
    -- (Twice an even share: at an even one the asked lanes' groups, a run each, took a tick apiece and held
    -- the watched belts' checks back to the due tick (live, round 1).)
    xcap = ceil(2 * M.extra_units / math.max(1, period - 1))
  end
  local xtick = 0
  -- (Timed by segment: /f3d-profile's bs.* lines.)
  while round.i <= #q and spent < limit and xtick < xcap do
    local seg = q[round.i]
    local kind, list = seg[1], seg[2]
    local j = round.j or 1
    local tk = profile.start()
    while j <= #list and spent < limit and xtick < xcap do
      local u, x = do_step(b, kind, list[j], p, period)
      spent = spent + u
      round.extra = (round.extra or 0) + (x or 0)
      xtick = xtick + (x or 0)
      j = j + 1
    end
    profile.stop(STEP_NAMES[kind], tk)
    if j > #list then
      round.i, round.j = round.i + 1, nil
    else
      round.j = j
    end
  end
  -- First loads beside it, under their share of the work budget.
  local load_limit = M.load_cap or math.max(LOAD_MIN, floor(budget.left("bsload", LOAD_SHARE) * UNITS_PER_BUDGET_UNIT))
  -- (walk_load: more while the view's reach isn't all loaded, b.thin from the last update.)
  if b.thin and not M.load_cap then
    load_limit = math.max(load_limit, floor(tonumber(O.walk_load) or 0))
  end
  local tl = profile.start()
  local loaded = load_step(b, load_limit, p)
  profile.stop("bs.load", tl)
  budget.spend(loaded / UNITS_PER_BUDGET_UNIT, "bsload")
  round.units = round.units + fast + spent + loaded + (round.extra or 0)
  round.extra = 0
  round.loaded = round.loaded + loaded
  if not due then
    return
  end
  -- (What the steady queue didn't get to waits for the next update: the watched belts are listed
  -- again then, the rest of the drift checks come round again.)
  local r0 = M.counts.read
  round.units = round.units + check_edges(b, p)
  M.counts.r_edges = (M.counts.r_edges or 0) + M.counts.read - r0
  local fr = loaded_edge(b)
  -- (w: the work but first loads, spread under the work budget's share. ld: lanes inside the square
  -- still to load, or no scan yet.)
  local sc = b.scan
  local edge = sc and math.min(sc.r, b.edge or sc.r)
  local unloaded = sc == nil or fr < edge
  local loading = unloaded or b.scanning ~= nil
  -- (walk_load: the square loaded whole reaches less than walk_near tiles; the trace's own cap on fr
  -- below doesn't count, its traced belts beyond the near square still loading do.)
  b.thin = unloaded and fr < (tonumber(O.walk_near) or 0) or nil
  -- (area trace: fr is the near square, every belt of which is loaded, at most; the traced belts
  -- beyond it still loading keep `ld`.)
  if sc and sc.near and fr > sc.near then
    fr = sc.near
  end
  if p then
    local t = profile.start()
    emit(b, p, period, fr, round.units - round.loaded, unloaded)
    profile.stop("bs.emit", t)
  end
  bound(b, round.units - round.loaded, period, loading)
  b.sq = b.scan and { b.scan.fx, b.scan.fy, fr } or nil
  b.work = round.units - round.loaded - round.fast
  b.round, pays[s] = nil, nil
  b.count = b.count + 1
end

-- `bre` {l = [lane key, ...]}: lanes the client has otherwise than their drift check says: read in
-- full (with their meta) in the next update.
function M.resend(cmd)
  local b = storage.f3d.bs
  -- (b.bre: a save from an older shape, made again at the next tick.)
  if not (b and b.bre and type(cmd.l) == "table") then
    return
  end
  for j, key in ipairs(cmd.l) do
    if j > BRE_MAX then
      break
    end
    if type(key) == "number" and key > 0 and key == floor(key) and not b.bre[key] then
      -- (Waiting lanes beyond BRE_KEEP are dropped: the client asks again when it still differs.)
      local queue = b.breq or {}
      b.breq = queue
      if #queue - (b.breh or 1) + 1 < BRE_KEEP then
        b.bre[key] = true
        queue[#queue + 1] = key
      end
    end
  end
end

-- The square the last update covered {fx, fy, fr} (far lanes aren't read inside it), or nil.
function M.square()
  local b = storage.f3d.bs
  return b and b.sq
end

-- Whether a belt outside that square is loaded all the same (area trace: one traced from the near
-- square), so the far lanes leave it out: its items are drawn moving.
function M.hidden(unit)
  if O.area ~= "trace" then
    return false
  end
  local b = storage.f3d.bs
  return b ~= nil and b.belts[unit] ~= nil
end

-- A new world (handshake, surface change, resync): everything is sent again.
function M.reset()
  storage.f3d.bs = nil
  pays[storage.f3d] = nil
  line_cache = {}
  meta_cache = {}
  spool = {}
end

return M
