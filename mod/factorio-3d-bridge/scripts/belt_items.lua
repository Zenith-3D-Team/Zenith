-- Items on belts near the client's camera, a few times a second. Positions come from the game
-- (`get_line_item_position`), so curves, splitters and undergrounds need no geometry here; the
-- client glides each item, tracked by its `unique_id`, between updates.
--
-- This is the bridge's busiest module on a big base: reading every item near the focus, and
-- writing them out, in the tick an update was due cost 40-75 ms on the owner's save at its
-- busiest belts (5,600 items), the server's worst tick. So an update is read over several ticks,
-- a few milliseconds a tick (a round): belts are found a band of rings at a time from the focus
-- outwards, their items read and the message text written as they go, timed to end on the tick
-- the update is sent. Each item is carried on from the tick it was read to the update's tick at
-- the speed it moved between its last two reads, so the update is one moment of the game.
--
-- Lanes that didn't change aren't read again (for a client that says `bl` in its hello). On a busy
-- base most lanes are backed up: on the owner's save at its busiest belts 86% of 3,352 lanes held
-- the same items in the same places between two reads seconds apart, 11% were empty and only 3-5%
-- moved (2.1.23). Reading a lane's items costs about 11 us; its count (`#line`) and its front and
-- back items' positions (`get_item_position`) about 2. So each lane is checked that cheaply first,
-- and read in full only when the check differs from the last read, or once more after a change to
-- see that it has settled, or every LANE_REFRESH updates; the client keeps a lane's items until it
-- is sent again (`ln`) or dropped (`dl`). (Factorio itself stores a lane as the gaps between its
-- items and touches only what changes: FFF #176.)
--
-- Multiplayer: what decides when and how much is read (the round: where it got to, its belts,
-- the counts; each lane's last check, storage.f3d.bl) lives in storage and changes only from
-- on_tick, from game reads. What is sent (the items read so far, their last positions, the text)
-- is module-local: a peer that loaded mid-round only sends less, and only the host sends at all.

local spoilage = require("scripts.spoilage")
local registry = require("scripts.registry")
local transport = require("scripts.transport")
local world = require("scripts.world")
local map = require("scripts.map")
local rate = require("scripts.rate")
local tracker = require("scripts.tracker")

local M = {}

local floor = math.floor
local ceil = math.ceil

-- Items a `bi` part holds (a field for tests).
M.items_per_message = 300
-- A fully compressed 48x48 area is ~18k items. Past this the square is made smaller rather than
-- stalling the game: belts are read from the focus outwards, ring by ring, and the update stops at
-- the last whole ring, saying so in `fr`, so the far lane icons take over from there. (Cut short
-- in the order Factorio lists belts, whole patches of a dense base went bare: items neither drawn
-- nor shown as far icons.)
M.max_items = 6000
-- Every lane checked counts one towards the cap as well as its items: a sparse area of empty belts
-- costs a check a lane, and the moving area may reach as far as the client draws belt items.
M.lane_weight = 1
-- The cap's edge holds still (owner: the two zones went back and forth standing still, as the count
-- near the cap moved by a few items each update): the last update's edge is kept while its rings
-- hold up to KEEP times the cap, and it grows only by rings that fit within GROW times the cap.
local KEEP, GROW = 1.25, 0.85
-- A belt line that moved on by whole slots looks the same to the cheap check on every belt (the
-- items shuffled forward one place each), so every lane is held; when one of them is read in full
-- later (a refresh, a change) it lists items the client still has on the lane behind, which then
-- showed one item short until its own read (owner: items "stop and jump", lines not moving together
-- "over time"). So a lane read in full whose front or back item is another one than at its last
-- full read has the same lane of the belts either side (belt_neighbours) read in full too, in the
-- same update, and so on along the line as far as the items shifted. At most FORCE_MAX such lanes an update.
local FORCE_MAX = 4000
-- Factorio's utility constant max_belt_stack_size: a stack inserter puts up to 4 items in one place.
local MAX_STACK = 4

-- How much is read a tick, in work units of 1.5-2.5 us (2.1.23, the owner's save at its busiest
-- belts): an item read is one, written out three more, one more off a straight belt (the game is
-- asked for its position); a belt and each of its transport lines cost a few (API calls), and a
-- belt found one. A round takes as many ticks as its units fill. Only what the game holds is
-- counted, never what this peer happens to have written, so every peer reads the same slices.
M.units_per_tick = 1000
local BELT_UNITS = 2
local LINE_UNITS = 2
local OFF_STRAIGHT_UNITS = 1
local WRITE_UNITS = 3
local FIND_UNITS = 5  -- per find_entities_filtered call, besides 1 per belt found
-- Belts are found a band of this many rings at a time, so a round cut short (the cap, or time)
-- never looked for the belts it doesn't read.
local BAND = 4
-- On the tick an update is due, whatever is left of the round is read up to this many times a
-- tick's units; past it the square shrinks to the last whole ring read (`fr`), as at the cap.
local DUE_BURST = 2
-- A lane checked by its count and end items costs about this many units (#line and two
-- get_item_position, about 2 us in 2.1.23).
local CHECK_UNITS = 1
-- Every lane is read in full at least every this many updates even when it looks the same (on a
-- busy base updates come every 12-30 ticks: 15-30 s): the
-- client may have missed it (bi isn't resent), or its items changed kind without moving.
M.lane_refresh = 64
-- Lane keys: unit number * LANE_KEYS + line index (a splitter has 8 lines).
local LANE_KEYS = 8
-- An item moving faster than this (tiles a tick) between two reads was moved some other way.
local FASTEST = 0.2
-- A lane flowing full looks exactly the same whenever its items moved a whole number of item gaps
-- (0.25 on a full lane) since the last check: a turbo belt every 2 ticks, red every 4, yellow and
-- blue every 8. Checked every 12 or 24 ticks, full belts that flowed were held still on the client
-- (seen in 2.1.23). So rounds start a tick earlier every other update (the time between two checks
-- of a lane is then odd: never a whole number of gaps at these speeds), and a check whose time is
-- a whole number of gaps anyway (a round read over several ticks, other mods' speeds) reads the
-- lane in full rather than trusting it. BLIND is how near a whole number of gaps counts.
M.lane_jitter = true
local GAP = 0.25
local BLIND = 0.02

-- Belt groups (for a client that says `bg` in its hello, with `bl`). A packed lane (its items one
-- kind, its stacks one size, normal quality and not spoiling, a gap of GROUP_GAPS apart from one
-- end of the belt to the other: in 2.1.24 a straight belt's lane is one position long, items
-- coming in at 1 and leaving at 0 as positions fall) looks the same however far it has moved, but
-- for where along it is. On a busy base most moving lanes are packed and creep, stopping and
-- starting as what they feed takes items; read in full, each one cost a read and an item list
-- every update. Such a lane is sent once as a group (`bi` bg: where it is, its kind, stack, gap
-- and speed) and the client draws and moves its items itself. After that the cheap check is all
-- that is read while it stays packed the same way (packed_as; when it moved, every item's kind
-- too, as a different one may have come in): one number when it moved (`bi` bm: its front item's
-- place), nothing when it didn't. Anything else (it thins out or backs up unevenly, an inserter
-- takes an item, another kind comes along, a lane refresh) reads it in full again, and it is sent
-- as items, which ends the group, unless it is still packed.
local GROUP_GAPS = { 0.25, 0.5 }
-- How near (line positions) a place must be to the one it is meant to be at. Belt positions are
-- whole 1/256ths; this allows for float rounding only.
local PHASE = 1 / 512
-- How near (line positions) a group's move must be to its belt's speed for it to count as flowing.
local FLOW_SLACK = 3 / 256
-- How many groups (10 numbers each) or moves (3) a `bi` part carries.
local GROUPS_PER_PART = 150
local MOVES_PER_PART = 400
local PLAINS_PER_PART = 150
-- Quiet lanes. Most of a busy base's lanes are backed up and hold still, or are groups that didn't
-- move, update after update, and each check costs as much as the last (2.1.24, the owner's save at
-- its busiest belts: about 1,300 of 1,480 lanes checked an update). A lane unchanged at its last
-- quiet_after checks isn't checked again until quiet_ticks after its last one: with Smooth belt
-- items' updates every 6 ticks, every other update; with updates that far apart or more (a busy
-- server, `rate`), every one as before. A change there shows at most quiet_ticks later. Never on
-- its refresh round. (Fields for tests; 0 ticks: every lane checked every update.)
M.quiet_after = 3
M.quiet_ticks = 12
-- Reading an item's kind, count and quality (stack API calls) in units, for a lane that may
-- become a group or a group that moved.
local GROUP_ITEM_UNITS = 2

-- The gap and stack size of a lane checked as n stacks, front at p1 and back at pn (line
-- positions), total items, if it is packed end to end at one of GROUP_GAPS with stacks of one
-- size; else nil.
local function packed_gap(n, p1, pn, total)
  if n < 2 or total % n ~= 0 or total > n * MAX_STACK then
    return nil
  end
  local spaced = (pn - p1) / (n - 1)
  for _, gap in ipairs(GROUP_GAPS) do
    local d = spaced - gap
    if d <= PHASE and d >= -PHASE and n * gap > 1 - PHASE and n * gap < 1 + PHASE and p1 < gap - PHASE then
      return gap, total / n
    end
  end
  return nil
end

-- Whether a lane is still packed as its group was.
local function packed_as(group, n, p1, pn, total)
  local gap, stack = packed_gap(n, p1, pn, total)
  return gap == group[1] and stack == group[4] and n == group[3]
end

-- Underground belts also hold the items travelling under the ground. Those belong to the
-- entrance's lines 3 and 4, which aren't read at all (read_belt: their items are out of sight from
-- the entrance's middle on, and one at the very edge of its tile was put on the belt it passes
-- under: truth-findings 7); anything else outside the entity is dropped.
local function inside(box, x, y)
  return x >= box.left_top.x - 0.05 and x <= box.right_bottom.x + 0.05
    and y >= box.left_top.y - 0.05 and y <= box.right_bottom.y + 0.05
end

-- unique_id -> {item id, spoils, quality, x, y, tick read, speed x, speed y, carried, stack, lane
-- key, read on an underground's entrance (never carried on: it goes under, out of sight)}: an item
-- keeps its id while it rides (verified in 2.1.23), and spoiling turns it into a new item. Rebuilt
-- every update from the items seen, so it stays small. The last place an item was read, and when,
-- gives how it moves.
local known = {}
-- Lane key -> the unique ids its last full read sent (kept in `known` while it is held), and
-- lanes whose items have a quality or spoil: those are always read in full for what is sent (bq
-- and bf are whole lists every update), though counted as the check decided.
local lane_uids = {}
local lane_special = {}
-- Unique id -> the plain lane (`br`) it was in at that lane's last read: the client moves it on
-- itself, so it is never carried on (emit), and once it is read on a watched lane it is sent
-- from there.
local plain_kept = {}
-- Unit number -> the belt's LuaTransportLines, for the belts the last round and this one read (a
-- belt not read in a round is forgotten: gone, or out of the square).
local line_cache = {}
local next_cache = {}
-- Lanes checked, held and read in full (for quality or spoiling items, or settling, or changed),
-- and items read, since loading: module-local, for /c probes.
M.counts = { checked = 0, held = 0, blind = 0, special = 0, full = 0, items = 0, belts = 0, group = 0, grouped = 0, moved = 0, regrouped = 0, quiet = 0,
  plain = 0, plain_read = 0, far = 0, far_skipped = 0, plain_checked = 0, resent = 0 }

-- A straight belt's lines run straight along it, so an item's map position is where its line
-- starts plus its position along the belt. Where the lines start, relative to the belt's centre
-- and turned with it, is read from the game on the first straight belt of each update (the
-- same for every straight belt), instead of asking for every item.
local DIR = {}
for d = 0, 15, 4 do
  local a = d / 16 * 2 * math.pi
  DIR[d] = { math.floor(math.sin(a) + 0.5), math.floor(-math.cos(a) + 0.5) }
end

-- {along, across, step} of line i in the belt's own frame (forward, right): where position 0 is,
-- and how far forward one unit of position goes. Both are read, not assumed: in 2.1.23 a line's
-- positions don't run the way the fake API had them.
local function line_starts(belt)
  local d = DIR[belt.direction]
  if not d then
    return nil
  end
  local c = belt.position
  local starts = {}
  for i = 1, 2 do
    local line = belt.get_transport_line(i)
    -- (The step from position 0.5, twice over: the game clamps position 1 to 255/256 of the lane,
    -- which put every plain lane's items 1/256 short a lane: truth-findings 6.)
    local p0, p1 = line.get_line_item_position(0), line.get_line_item_position(0.5)
    local dx, dy = p0.x - c.x, p0.y - c.y
    starts[i] = { dx * d[1] + dy * d[2], -dx * d[2] + dy * d[1], 2 * ((p1.x - p0.x) * d[1] + (p1.y - p0.y) * d[2]) }
  end
  return starts
end

-- For tools/busy_base.py and live_check.py: the positions the shortcut above gives for a
-- straight belt's items next to the game's own, [[x, y, game x, game y], ...].
function M.check_straight(belt)
  local starts = line_starts(belt)
  local d = DIR[belt.direction]
  local c = belt.position
  local out = {}
  for i = 1, 2 do
    local line = belt.get_transport_line(i)
    local s = starts[i]
    for _, item in pairs(line.get_detailed_contents()) do
      local g = line.get_line_item_position(item.position)
      local sx = c.x + d[1] * s[1] - d[2] * s[2]
      local sy = c.y + d[2] * s[1] + d[1] * s[2]
      out[#out + 1] = { sx + d[1] * s[3] * item.position, sy + d[2] * s[3] * item.position, g.x, g.y }
    end
  end
  return out
end

---------------------------------------------------------------------------------------------
-- Straight runs (for a client that says `br` in its hello, with `bl`).
--
-- On a busy base two lanes in three are plain: a straight belt in a line of straight belts facing
-- one way, which nothing puts items on or takes them off but the belts either side (the owner's
-- save round its main belts, 2.1.24: 14,324 of 21,566 lanes within 160 tiles; Factorio itself joins
-- such lines into one transport-line segment). What a plain lane holds follows from what came in at
-- the belt behind and what the belt in front let through: items move at the belt's speed and stop a
-- gap behind the item in front. So such a lane is read in full once, when it comes into the square,
-- and sent with where it is and which lanes are either side (`bi` pl); the client moves its items
-- from then on and the lane isn't checked again. Every other lane is watched and checked as before:
-- inserters' and drills' pickup and drop belts, the belt after an inserter's pickup belt (what left
-- the pickup belt can then only have gone on), side-loaded belts, the ends of a run (another tier,
-- a curve, a splitter, an underground, a loader or nothing), and curves, splitters, undergrounds,
-- loaders themselves. What is sent there (the lane's items whenever its check changes) says what
-- came in or went out at that place, and a run's end lane held unchanged is the end blocked. A
-- plain lane is read again every plain_refresh updates (by its key, a few each update): drift (a
-- player taking items off it by hand, a guess of the client's) is put right there.
--
-- What is plain is kept in storage (f3d.bw: unit number -> {watched, unit behind, unit in front}),
-- worked out from game reads the first time a round reads the belt, and forgotten round anything
-- built, mined, rotated or destroyed (tracker.listeners: players', robots', platforms', scripts')
-- once the next tick comes, so it is worked out again. Which belts inserters and drills use is
-- read a chunk at a time (f3d.bt: chunk -> {unit number -> 1, or 2 for a pickup belt}).
M.plain_refresh = 256
-- And checked cheaply (count, front and back) every plain_check updates, which the client compares
-- with what it has there (`bi` pc): a lane it has otherwise is asked for again (`bre`).
M.plain_check = 16
-- Distance tiers: lanes this many rings out or more are checked about every far_ticks ticks (on
-- one update in far_every, by their key), the nearer ones every update.
M.near_tier = 16
M.far_ticks = 30
-- Plain lanes not checked count this much towards the cap (a watched lane counts its items and
-- lane_weight), about what keeping one costs against checking one: the same cap reaches further
-- for about the same time (0: twice as far on the owner's save, for 1.7 times the time; with groups
-- for the watched lanes, 0.5 reached 25 tiles, 1 22 for 2.7 ms a tick against main's 2.2 at 13).
M.plain_weight = 1
-- Plain lanes read for the first time an update, at most.
M.first_reads = 400
-- No plain lanes in a square reaching fewer rings than this (plain_here).
M.plain_min = 10
-- Inserters and drills this far outside a chunk can use its belts (a long-handed inserter reaches 2
-- tiles, a big drill drops 3.5 from its centre; modded ones a little more).
local REACH = 6
-- Working out a belt's record (belt_neighbours, then each neighbour's type, shape, direction,
-- place and name), and reading an inserter's or a drill's targets, in units.
local WATCH_UNITS = 6
local TARGET_UNITS = 2
-- Kinds whose building or removal can change what is plain round them.
local WATCH_TYPES = { ["inserter"] = true, ["mining-drill"] = true }

local function chunk_key(x, y)
  return (floor(x / 32) + 32768) * 65536 + (floor(y / 32) + 32768)
end

-- The chunk's belts that inserters and drills take from or put on: read once, kept in storage.
-- Returns them and the units it cost.
local function targets_of(surface, x, y)
  local s = storage.f3d
  s.bt = s.bt or {}
  local key = chunk_key(x, y)
  local t = s.bt[key]
  if t then
    return t, 0
  end
  t = {}
  local x0, y0 = floor(x / 32) * 32, floor(y / 32) * 32
  local found = surface.find_entities_filtered({ area = { { x0 - REACH, y0 - REACH }, { x0 + 32 + REACH, y0 + 32 + REACH } },
    type = { "inserter", "mining-drill" } })
  local function mark(e, flag)
    if e and e.valid and e.unit_number then
      local p = e.position
      if chunk_key(p.x, p.y) == key then
        t[e.unit_number] = math.max(t[e.unit_number] or 0, flag)
      end
    end
  end
  for _, e in pairs(found) do
    if e.type == "inserter" then
      mark(e.pickup_target, 2)
      mark(e.drop_target, 1)
    else
      mark(e.drop_target, 1)
    end
  end
  s.bt[key] = t
  return t, FIND_UNITS + #found * TARGET_UNITS
end

-- Whether belt b carries straight on from belt a: both straight transport belts of one kind facing
-- the same way, b on the next tile in front of a.
local function continues(a, b, d)
  if not (a and b and a.valid and b.valid) or b.type ~= "transport-belt" or b.belt_shape ~= "straight"
    or b.direction ~= a.direction or b.name ~= a.name then
    return false
  end
  local pa, pb = a.position, b.position
  local dx, dy = pb.x - pa.x - d[1], pb.y - pa.y - d[2]
  return dx < 0.01 and dx > -0.01 and dy < 0.01 and dy > -0.01
end

-- A belt's record, {watched, unit behind, unit in front (0: none carrying straight on)}, and the
-- units it cost.
local function watch_of(belt, surface)
  if belt.type ~= "transport-belt" or belt.belt_shape ~= "straight" then
    return { true, 0, 0 }, 2
  end
  local d = DIR[belt.direction]
  if not d then
    return { true, 0, 0 }, 2
  end
  local units = WATCH_UNITS
  local nb = belt.belt_neighbours
  local ins, outs = nb.inputs or {}, nb.outputs or {}
  local up = #ins == 1 and continues(ins[1], belt, d) and ins[1] or nil
  local down = #outs == 1 and continues(belt, outs[1], d) and outs[1] or nil
  local rec = { true, up and up.unit_number or 0, down and down.unit_number or 0 }
  if not (up and down) then
    return rec, units
  end
  local p, q = belt.position, up.position
  local here, u1 = targets_of(surface, p.x, p.y)
  local behind, u2 = targets_of(surface, q.x, q.y)
  units = units + u1 + u2
  rec[1] = here[belt.unit_number] ~= nil or behind[up.unit_number] == 2
  return rec, units
end

-- tracker.listeners: something was built, changed or removed. Belts, inserters and drills round it
-- are worked out again on the next tick (a removed one is gone by then).
local function touched(entity)
  local s = storage.f3d
  if not (s and s.bw and entity and entity.valid) then
    return
  end
  local t = entity.type
  if not (WATCH_TYPES[t] or t == "transport-belt" or t == "underground-belt" or t == "splitter" or t == "lane-splitter"
    or t == "loader" or t == "loader-1x1" or t == "linked-belt") then
    return
  end
  local p = entity.position
  s.bw_dirty = s.bw_dirty or {}
  s.bw_dirty[#s.bw_dirty + 1] = { entity.surface.index, p.x, p.y, entity.unit_number or 0 }
end
tracker.listeners[#tracker.listeners + 1] = touched

-- The dirty places' belts and target chunks forgotten (from on_tick).
local function forget_touched(s)
  local dirty = s.bw_dirty
  if not dirty then
    return
  end
  s.bw_dirty = nil
  local si = world.surface().index
  local types = registry.belt_types()
  for _, at in ipairs(dirty) do
    s.bw[at[4]] = nil
    if at[1] == si then
      local x, y = at[2], at[3]
      if s.bc then
        for cx = floor((x - 2) / 32), floor((x + 2) / 32) do
          for cy = floor((y - 2) / 32), floor((y + 2) / 32) do
            s.bc[chunk_key(cx * 32, cy * 32)] = nil
          end
        end
      end
      if s.bt then
        for cx = floor((x - REACH) / 32), floor((x + REACH) / 32) do
          for cy = floor((y - REACH) / 32), floor((y + REACH) / 32) do
            s.bt[chunk_key(cx * 32, cy * 32)] = nil
          end
        end
      end
      if #types > 0 then
        local r = REACH + 1.5
        for _, belt in pairs(world.surface().find_entities_filtered({ area = { { x - r, y - r }, { x + r, y + r } }, type = types })) do
          if belt.unit_number then
            s.bw[belt.unit_number] = nil
          end
        end
      end
    end
  end
end

---------------------------------------------------------------------------------------------
-- A round.
--
-- storage.f3d.bi = {m, dues, last, work, round}: m, how many of the job's due ticks (rate.lua) an
-- update takes (more on a big base); dues, due ticks since the last update; last, its tick; work,
-- the last round's units. round = {start, si, fx, fy, r, target (the tick it is meant to be sent
-- on), band (the next band's first ring), last_band, belts and rings (the band being read), i
-- (next belt), ring (being read), ring_items, items (read so far: the cap's count), units, cut
-- (fr when cut short), short (cut short for time), done}.

-- What a round has read, for sending: module-local, keyed by the round's start tick. Items are
-- [unique id, item id, x, y] in `raw` (x, y as read) with their speed and read tick in vx, vy, at,
-- written as text at the target tick into `bodies`, 300 at a time, as they are read; `mark`, the
-- counts where the ring being read began (what a cut goes back to).
local pay = nil
-- Whether the last update sent qualities (one empty `bq` clears them): only what is sent.
local bq_sent = false

local function payload(round)
  return pay and pay.id == round.start and pay or nil
end

-- Straight runs (`br`): each chunk's belts, kept in storage (f3d.bc: chunk -> {{belt, unit number,
-- x, y}, ...}), found once and forgotten round anything built or removed (forget_touched), so a
-- round looks up its belts there instead of searching for them, and never asks the game anything
-- of a belt it needn't read: a plain belt whose lanes the client moves, a far one not due.
-- (Looking at a plain lane cost 3.4 us on the owner's save, a far one held 3.9, the search and each
-- belt read 2-4 more: two thirds of belt items' time with 2,200 plain lanes in the square.)
local CHUNK_REFRESH = 600
local function chunk_belts(surface, cx, cy)
  local s = storage.f3d
  s.bc = s.bc or {}
  local key = chunk_key(cx * 32, cy * 32)
  local list = s.bc[key]
  -- (Searched again every CHUNK_REFRESH ticks or so, by the chunk's key: belts something built or
  -- removed without an event.)
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
      if q.x >= x0 and q.x < x0 + 32 and q.y >= y0 and q.y < y0 + 32 then
        list[#list + 1] = { belt, belt.unit_number or 0, q.x, q.y, belt.get_max_transport_line_index() }
        units = units + 2
      end
    end
  end
  s.bc[key] = list
  return list, units
end

-- Whether a belt (its chunk_belts entry) is read this round: a watched one near or due, a plain one
-- whose lanes have no record yet (a new lane or one forgotten), or due its sample. A belt not read
-- has its lanes kept (round.keep, by ring), counted towards the cap that ring as read_belt would.
-- Whether a belt (its watch record) is next to a plain one: its lanes are a chain's front or back,
-- what the client's chain waits on or takes in from, so they are looked at every update (never held
-- as far or quiet: a turbo item crosses a belt in 8 ticks, and one never listed in the lane in front
-- waited at the chain's front for good; truth-findings 2).
local function next_to_plain(w, bw)
  local up, down = w[2] ~= 0 and bw[w[2]], w[3] ~= 0 and bw[w[3]]
  return (up and not up[1]) or (down and not down[1]) or false
end

-- The plain belt in front of a chain of plain belts (its head): a chain's lanes are read again
-- together (sampled, or asked for again), so the client can let go of what a sending doesn't list
-- (truth-findings 5: one lane at a time, it couldn't tell an item gone on from a phantom). Worked
-- out once a belt and kept in its watch record (w[4]); a chain cut by something built has two.
local function chain_head(unit, bw)
  local w = bw[unit]
  if not w then
    return unit
  end
  if w[4] then
    return w[4]
  end
  local walked, at, head = {}, unit, unit
  for _ = 1, 512 do
    local r = bw[at]
    if not r or r[1] then
      break
    end
    walked[#walked + 1] = r
    head = at
    if r[4] then
      head = r[4]
      break
    end
    at = r[3]
    if at == 0 then
      break
    end
  end
  for _, r in ipairs(walked) do
    r[4] = head
  end
  return head
end

-- The units of the plain chain a plain belt is in, front to back (at most 512).
local function chain_units(unit, bw)
  local head = chain_head(unit, bw)
  local out, at = {}, head
  for _ = 1, 512 do
    local r = bw[at]
    if not r or r[1] then
      break
    end
    out[#out + 1] = at
    at = r[2]
    if at == 0 then
      break
    end
  end
  return out
end

-- Whether a plain belt is far enough inside the square to be plain this round: the lane in front of
-- the one at its edge is never read (truth-findings 2b), so that lane is watched.
local function plain_here(round, ring, was_plain)
  -- (A lane plain already stays so to the last ring but one; one watched becomes plain only three
  -- rings in: walking, the edge moves a ring every few updates, and lanes flipping there were sent
  -- again each time, their chains made again.)
  local edge = round.plain_edge or round.prev or round.r
  -- (None in a square smaller than plain_min: the windowed client's Automatic cap often holds it at
  -- 5-7 tiles, where only its middle few rings could be plain and walking flipped them all again
  -- and again: game items with none drawn 2.1% a tile inside it against 0.5% with runs off.)
  return edge >= M.plain_min and ring < edge - (was_plain and 1 or 3)
end

-- Whether a lane's count and front item are as its record has them.
local function edge_same(line, rec)
  local n = #line
  if n ~= rec[1] then
    return false
  end
  return n == 0 or line.get_item_position(1) == rec[2]
end

local function wanted(round, e, ring, lanes, bw, surface)
  local unit = e[2]
  local w = unit ~= 0 and bw[unit]
  if not w then
    if unit == 0 or not e[1].valid then
      return true
    end
    -- (Worked out here, so a new plain belt waits its turn for its first read too.)
    local u
    w, u = watch_of(e[1], surface)
    bw[unit] = w
    round.units = round.units + u
  end
  local base = unit * LANE_KEYS
  local r1 = lanes[base + 1]
  if not w[1] and plain_here(round, ring, r1 and r1[14]) then
    for i = 1, 2 do
      local rec = lanes[base + i]
      if not (rec and rec[14]) then
        -- Read for the first time: at most first_reads lanes an update, the rest the next ones
        -- (all at once, a square coming into view sent thousands: a 909 ms job on the client).
        local n = round.first_plain or 0
        if n >= M.first_reads then
          return false
        end
        round.first_plain = n + 2
        return true
      end
      if (chain_head(unit, bw) + round.count) % M.plain_refresh == 0 or (base + i + round.count) % M.plain_check == 0
        or lane_special[base + i] then
        return true
      end
    end
    M.counts.plain = M.counts.plain + 2
    return false, base + 1, base + 2, M.plain_weight * 2
  end
  local every = round.far_every
  if not (every and ring >= M.near_tier) or (unit + round.count) % every == 0 or next_to_plain(w, bw) then
    return true
  end
  -- Far and not due: kept if each of its lanes has a record and was looked at within a refresh.
  local count = e[5]
  if not count then
    return true
  end
  local weight = 0
  for i = 1, count do
    local rec = lanes[base + i]
    if not (rec and rec[6]) or (base + i + round.count) % M.lane_refresh == 0 or lane_special[base + i] then
      return true
    end
    weight = weight + (rec[1] + M.lane_weight) / every
  end
  M.counts.far = M.counts.far + count
  return false, base + 1, base + count, weight
end

-- The next band of rings from the chunks' belts (straight runs): the chunks round the square are
-- each sorted into rings once a round, as the bands reach them.
local function band_from_chunks(round, surface)
  local a = round.band
  local b = math.min(a + BAND, round.r)
  local last = b >= round.r
  local fx, fy = round.fx, round.fy
  local units = 0
  local s = storage.f3d
  local lanes, bw = s.bl, s.bw
  local by = round.by_ring
  if not by then
    by, round.by_ring, round.chunks_done, round.keep, round.keep_count = {}, {}, {}, {}, {}
    round.by_ring = by
  end
  local done, keep, keep_count = round.chunks_done, round.keep, round.keep_count
  local seen = map.view_filter()
  for cx = floor((fx - b) / 32), floor((fx + b) / 32) do
    for cy = floor((fy - b) / 32), floor((fy + b) / 32) do
      local ck = chunk_key(cx * 32, cy * 32)
      if not done[ck] then
        done[ck] = true
        local list, u = chunk_belts(surface, cx, cy)
        units = units + u + FIND_UNITS
        for _, e in ipairs(list) do
          local dx, dy = e[3] - fx, e[4] - fy
          local ring = floor(math.max(dx < 0 and -dx or dx, dy < 0 and -dy or dy))
          if ring < round.r + 2 and (not seen or seen(e[3], e[4])) then
            units = units + 0.25
            local read, k1, k2, weight = wanted(round, e, ring, lanes, bw, surface)
            if not read and not k1 then
              -- (A plain belt left for a later update's first reads.)
            elseif read then
              local list2 = by[ring]
              if not list2 then
                list2 = {}
                by[ring] = list2
              end
              list2[#list2 + 1] = e
            else
              local kl = keep[ring]
              if not kl then
                kl = {}
                keep[ring] = kl
              end
              kl[#kl + 1] = k1
              kl[#kl + 1] = k2
              keep_count[ring] = (keep_count[ring] or 0) + weight
            end
          end
        end
      end
    end
  end
  local belts, rings = {}, {}
  local top = last and round.r + 1 or b - 1
  for ring = a, top do
    for _, e in ipairs(by[ring] or {}) do
      belts[#belts + 1] = e[1]
      rings[#belts] = ring
    end
  end
  round.belts, round.rings, round.i = belts, rings, 1
  round.band, round.last_band = b, last
  return units
end

-- The lanes of the belts a round kept without reading them, in the rings it covers: kept (and
-- marked kept unread, so their items aren't carried on).
local function apply_keep(round, lanes)
  local keep = round.keep
  if not keep then
    return
  end
  local edge = round.cut or (round.r + 2)
  for ring, kl in pairs(keep) do
    if ring < edge then
      for j = 1, #kl, 2 do
        for key = kl[j], kl[j + 1] do
          local rec = lanes[key]
          if rec then
            rec[4], rec[17] = round.start, round.start
          end
        end
      end
    end
  end
end

-- The next band of rings: finds its belts (in up to four rectangles round the ones before) and
-- lists them nearest ring first. Returns the units it cost.
local function find_band(round, surface)
  if round.runs then
    return band_from_chunks(round, surface)
  end
  local types = registry.belt_types()
  local a = round.band
  local b = math.min(a + BAND, round.r)
  local last = b >= round.r
  local fx, fy = round.fx, round.fy
  local areas
  if a == 0 then
    areas = { { { fx - b, fy - b }, { fx + b, fy + b } } }
  else
    areas = {
      { { fx - b, fy - b }, { fx + b, fy - a } },
      { { fx - b, fy + a }, { fx + b, fy + b } },
      { { fx - b, fy - a }, { fx - a, fy + a } },
      { { fx + a, fy - a }, { fx + b, fy + a } },
    }
  end
  -- A belt is found by every rectangle its box touches, so it is kept only in the band its centre
  -- is in (the last band keeps what sticks out past the square, as one search of it did).
  local buckets, seen, top, units = {}, {}, a, 0
  for _, area in ipairs(areas) do
    units = units + FIND_UNITS
    if #types > 0 then
      -- The belts found go in storage (the round): the remote view's filter as the game is now, not
      -- its module-local cache (map.view_filter).
      for _, belt in pairs(map.view_only(surface.find_entities_filtered({ area = area, type = types }), true)) do
        units = units + 1
        local p = belt.position
        local dx, dy = p.x - fx, p.y - fy
        local ring = floor(math.max(dx < 0 and -dx or dx, dy < 0 and -dy or dy))
        local id = belt.unit_number
        if ring >= a and (last or ring < b) and not seen[id] then
          seen[id] = true
          local list = buckets[ring]
          if not list then
            list = {}
            buckets[ring] = list
            if ring > top then
              top = ring
            end
          end
          list[#list + 1] = belt
        end
      end
    end
  end
  local belts, rings = {}, {}
  for ring = a, top do
    for _, belt in ipairs(buckets[ring] or {}) do
      belts[#belts + 1] = belt
      rings[#belts] = ring
    end
  end
  round.belts, round.rings, round.i = belts, rings, 1
  round.band, round.last_band = b, last
  return units
end

-- Writes the next part's text: up to M.items_per_message items at the target tick, delta-coded
-- for a `z` client (transport.encode_groups, written straight from what was read).
local function write_part(p, target)
  local raw, vx, vy, at = p.raw, p.vx, p.vy, p.at
  local first = p.written + 1
  local last = math.min(#vx, p.written + M.items_per_message)
  local out, n = {}, 0
  local z, small = transport.compact(), transport.small
  local pu, pi, px, py = 0, 0, 0, 0
  local st, sts = p.st, nil
  for j = first, last do
    local m = j * 4
    local dt = target - at[j]
    local u, i = raw[m - 3], raw[m - 2]
    if st[j] then
      sts = sts or {}
      sts[#sts + 1] = u
      sts[#sts + 1] = st[j]
    end
    local x = floor((raw[m - 1] + vx[j] * dt) * 256 + 0.5)
    local y = floor((raw[m] + vy[j] * dt) * 256 + 0.5)
    if z and j > first then
      local du, di, dx, dy = u - pu, i - pi, x - px, y - py
      out[n + 1], out[n + 2], out[n + 3], out[n + 4] = small[du] or du, small[di] or di, small[dx] or dx, small[dy] or dy
    else
      out[n + 1], out[n + 2], out[n + 3], out[n + 4] = u, i, x, y
    end
    n = n + 4
    pu, pi, px, py = u, i, x, y
  end
  p.bodies[#p.bodies + 1] = table.concat(out, ",")
  -- Stacks of more than one item (a stack inserter's), by unique id; an item not listed is one.
  local tail = sts and (',"st":[' .. table.concat(sts, ",") .. "]") or ""
  if p.lanes then
    -- Which lane each run of this part's items came from: [key, count, ...] (0: none, an item
    -- carried on); lanes read with nothing to send since the part before come first, with count 0.
    -- (Only the first part had them, and lanes read later in the round, the lines read along their
    -- length at its end above all, were never told: the client kept their old items, a belt one
    -- short or doubled.)
    local lk, ln, m = p.lk, {}, 0
    local part = #p.bodies
    for x = (p.emptied_upto[part - 1] or 0) + 1, #p.emptied do
      ln[m + 1], ln[m + 2] = p.emptied[x], 0
      m = m + 2
    end
    p.emptied_upto[part] = #p.emptied
    local j = first
    while j <= last do
      local key, c = lk[j], 0
      while j <= last and lk[j] == key do
        c = c + 1
        j = j + 1
      end
      ln[m + 1], ln[m + 2] = key, c
      m = m + 2
    end
    p.tails[#p.bodies] = ',"ln":[' .. table.concat(ln, ",") .. "]" .. tail
  elseif tail ~= "" then
    p.tails[#p.bodies] = tail
  end
  p.written = last
end

-- Reads one belt's items into the round (and `p`, what is sent, when this peer has it). Returns
-- the items counted and the units spent.
local function read_belt(belt, p, now, round, lanes, force)
  local items, units, held, weight = 0, 0, 0, 0
  local unit = belt.unit_number
  -- A belt's line objects are kept from round to round (getting them cost about 2 us a line, as
  -- much as the check), and its kind, shape and place read only for a lane read in full.
  local lines = unit and line_cache[unit]
  if not lines then
    lines = {}
    for i = 1, belt.get_max_transport_line_index() do
      lines[i] = belt.get_transport_line(i)
    end
    -- Tiles (line positions) its items move a tick: a prototype's, the same on every peer.
    lines.v = belt.prototype.belt_speed
    if unit then
      line_cache[unit] = lines
    end
  end
  if unit then
    next_cache[unit] = lines
  end
  local known_belt, underground, box, d, c, starts = false, false, nil, nil, nil, nil
  local raw, vx, vy, at, seen = p and p.raw, p and p.vx, p and p.vy, p and p.at, p and p.seen
  -- Straight runs (`br`): whether its lanes are plain, worked out the first time (storage).
  local watch = nil
  if round.runs and unit and lanes then
    local bw = storage.f3d.bw
    watch = bw[unit]
    if not watch then
      local u
      watch, u = watch_of(belt, world.surface())
      bw[unit] = watch
      units = units + u
    end
  end
  -- An underground's entrance: its lines 3 and 4 run under the ground, from its middle to the exit's
  -- (docs/BELT-RULES.md section 3), so their items are never seen and aren't read; the client carries
  -- an item that went in on under the ground itself, and it comes up on the exit's lines 1 and 2.
  local hidden_from = #lines == 4 and belt.type == "underground-belt" and belt.belt_to_ground_type == "input" and 3 or nil
  for i = 1, #lines do
    if hidden_from and i >= hidden_from then
      goto next_line
    end
    if force and not force[i] then
      weight = weight + M.lane_weight
      goto next_line
    end
    do
    units = units + LINE_UNITS
    weight = weight + M.lane_weight
    local line = lines[i]
    local key, full = nil, true
    local n, p1, pn, total = 0, -1, -1, 0
    local plain = watch and not watch[1] and plain_here(round, round.ring, lanes and lanes[unit * LANE_KEYS + i] and lanes[unit * LANE_KEYS + i][14])
    local edge = watch and lanes and next_to_plain(watch, storage.f3d.bw)
    if plain then
      -- A plain lane (see Straight runs): the client moves its items. Not checked, its items kept
      -- as the client has them (and never carried on), but for its first read and its samples. Lines
      -- that moved on (FORCE_MAX) don't read it: the client moves it on itself.
      key = unit * LANE_KEYS + i
      if force then
        goto next_line
      end
      local rec = lanes[key]
      if rec and rec[14] and (chain_head(unit, storage.f3d.bw) + round.count) % M.plain_refresh ~= 0
        and not (p and lane_special[key]) then
        weight = weight - M.lane_weight + M.plain_weight
        rec[4] = round.start
        local keys = round.ring_keys
        keys[#keys + 1] = key
        if (key + round.count) % M.plain_check == 0 then
          -- Its drift check: the cheap check only, sent (`pc`) for the client to compare with what it
          -- has there; it asks for the lane again (`bre`) when they differ.
          n = #line
          if n > 0 then
            p1 = line.get_item_position(1)
            pn = n > 1 and line.get_item_position(n) or p1
          end
          units = units + CHECK_UNITS
          M.counts.plain_checked = M.counts.plain_checked + 1
          if p then
            local q = p.checks
            q[#q + 1] = key
            q[#q + 1] = n
            q[#q + 1] = n > 0 and floor(p1 * 256 + 0.5) or 0
            q[#q + 1] = n > 0 and floor(pn * 256 + 0.5) or 0
            q[#q + 1] = math.max(0, (round.target or now) - now)
          end
        else
          units = units - LINE_UNITS
          M.counts.plain = M.counts.plain + 1
        end
        goto next_line
      end
      n = #line
      if n > 0 then
        p1 = line.get_item_position(1)
        pn = n > 1 and line.get_item_position(n) or p1
        total = line.get_item_count()
      end
      units = units + CHECK_UNITS
      rec = { n, p1, pn, round.start, true, now, total }
      rec[14] = true
      lanes[key] = rec
      local keys = round.ring_keys
      keys[#keys + 1] = key
      M.counts.plain_read = M.counts.plain_read + 1
    elseif lanes and unit then
      -- The cheap check first (storage: only game reads decide it).
      key = unit * LANE_KEYS + i
      -- Plain until now (something was built next to it): read in full and sent without pl, so
      -- the client checks it no longer moves its items itself.
      if watch and lanes[key] and lanes[key][14] then
        lanes[key] = nil
      end
      -- A quiet lane (unchanged at its last quiet_after checks: backed up, or a group that didn't
      -- move) isn't checked again within quiet_ticks of its last check (see M.quiet_ticks).
      -- (Decided from storage only. A lane with spoiling or quality items is still read for what is
      -- sent, bq and bf being whole lists every update, uncounted, as a held one is.)
      local quiet = lanes[key]
      -- Distance tiers (`br`): a lane near_tier rings out or more is checked on one update in
      -- far_every (by its key: a few each update), about every far_ticks; it is held meanwhile, and
      -- counts that share of itself towards the cap.
      local every = round.far_every
      local far = every and round.ring >= M.near_tier and quiet and quiet[6] and (unit + round.count) % every ~= 0
      local skip = quiet and not force and not quiet[16] and (far or ((quiet[12] or 0) >= M.quiet_after and quiet[6] and now - quiet[6] < M.quiet_ticks))
        and (key + round.count) % M.lane_refresh ~= 0
      if skip and edge then
        -- A chain's front or back lane, held as far or quiet otherwise: looked at every update, but
        -- only its count and front item (two calls, not four); checked as any lane when they differ.
        skip = edge_same(line, quiet)
        units = units + CHECK_UNITS / 2
      end
      if skip then
        quiet[4] = round.start
        local keys = round.ring_keys
        keys[#keys + 1] = key
        if far then
          held = held + quiet[1] / every
          weight = weight - M.lane_weight + M.lane_weight / every
          M.counts.far = M.counts.far + 1
        else
          held = held + quiet[1]
          M.counts.quiet = M.counts.quiet + 1
        end
        if p and lane_special[key] and not quiet[11] then
          full = "send"
          M.counts.special = M.counts.special + 1
        else
          if p and not quiet[11] then
            local seen, held_only = p.seen, p.held_only
            for _, uid in ipairs(lane_uids[key] or {}) do
              seen[uid] = known[uid]
              held_only[uid] = true
            end
          end
          goto next_line
        end
      else
      -- n counts stacks (2.1.23: a stack inserter's stack of up to 4 is one entry); the lane's
      -- items too, since an inserter taking part of a stack moves nothing.
      n = #line
      if n > 0 then
        p1 = line.get_item_position(1)
        pn = n > 1 and line.get_item_position(n) or p1
        total = line.get_item_count()
      end
      units = units + CHECK_UNITS
      local rec = lanes[key]
      -- rec: {count, front, back, round checked, settled, tick checked, items, first uid, last uid,
      -- round read in full, group, checks unchanged, ticks the check was before its update's tick}
      local group = rec and rec[11]
      if group then
        -- Held as a group (see GROUP_GAPS) while it is packed as it was. When it moved, another
        -- kind may have come in (the count and places look the same): every item's kind is read.
        -- A lane refresh (the client may have missed the group) reads its kinds and sends the
        -- group again rather than reading the lane in full.
        local ok = packed_as(group, n, p1, pn, total)
        local moved = ok and rec[2] ~= p1
        -- A full lane flowing at its belt's speed goes one gap every 8 ticks on a yellow belt (4
        -- on red, 2 on turbo: docs/BELT-RULES.md), so checked a whole number of gaps' travel after
        -- its last check it looks as if it stood. Quiet and far lanes are checked 12 and 24 ticks
        -- apart, so a flowing group seen so three times was taken as quiet and checked that way on,
        -- and held: the client drew it standing or ran it on by guess, and items went missing and
        -- came back (Zenith Test's busy belts, a yellow line held for 72 ticks while it flowed).
        -- A group last seen flowing is taken to flow on; one that wasn't is checked again next
        -- update (whose time since is odd: M.lane_jitter), not counted as unchanged.
        local blind = false
        if ok and not moved and rec[6] and now > rec[6] then
          local slots = (lines.v or 0) * (now - rec[6]) / group[1]
          local f = slots - floor(slots + 0.5)
          blind = slots > 0.5 and f < BLIND and f > -BLIND
          if blind and rec[15] then
            moved = true
          end
        end
        local refresh = (key + round.count) % M.lane_refresh == 0
        if moved or (ok and refresh) then
          units = units + n * GROUP_ITEM_UNITS
          local name = group[2]
          for j = 1, n do
            if line[j].name ~= name then
              ok = false
              break
            end
          end
        end
        if ok then
          -- Read `age` ticks before the update's tick (a round starts a tick early every other
          -- update, M.lane_jitter; more when it is read in slices): a group that moved is sent where
          -- it is on the update's tick, gone on at its belt's speed, as items read early are (the
          -- client draws the group on that tick: a third of its moves were a tick behind, up to
          -- 0.12 tiles on a turbo belt, back and forth), and the ticks since its last check are
          -- counted on the updates' ticks too.
          local age = (round.target or now) - now
          if age < 0 then
            age = 0
          end
          local since = now - (rec[6] or now) + age - (rec[13] or age)
          local front = p1
          -- Carried on only when it flows at its belt's speed (moved since its last check a whole
          -- number of gaps short of the belt's speed, as a lane that never stopped does). A full
          -- lane that creeps (stops and starts as what it feeds takes items: most of a busy base's)
          -- mostly stands: carried on at full speed, neighbouring belts of one line read a tick or
          -- three apart were sent that many ticks of travel apart and drawn with holes and bunches
          -- at the joins (Zenith Test's busy belts: 0.06-0.09 tiles apart on yellow belts).
          local flowing = false
          if moved and rec[6] then
            local gap = group[1]
            local d = (rec[2] - p1) % gap
            local off = ((lines.v or 0) * (now - rec[6]) - d) % gap
            flowing = off < FLOW_SLACK or off > gap - FLOW_SLACK
          end
          if moved or not blind then
            rec[15] = flowing or nil
          end
          rec[16] = (blind and not moved) or nil
          if flowing and age > 0 then
            front = p1 - (lines.v or 0) * age
            while front < 0 do
              front = front + group[1]
            end
          end
          rec[2], rec[3], rec[4], rec[6], rec[7], rec[13] = p1, pn, round.start, now, total, age
          rec[12] = (moved or refresh or blind) and 0 or (rec[12] or 0) + 1
          local keys = round.ring_keys
          keys[#keys + 1] = key
          local counts = M.counts
          counts.checked, counts.group = counts.checked + 1, counts.group + 1
          held = held + n
          if refresh then
            counts.regrouped = counts.regrouped + 1
            units = units + BELT_UNITS
            local dir = DIR[belt.direction]
            local s = p and dir and (p.starts or line_starts(belt))
            if s then
              p.starts = s
              local c, st = belt.position, s[i]
              local sx = c.x + dir[1] * st[1] - dir[2] * st[2]
              local sy = c.y + dir[2] * st[1] + dir[1] * st[2]
              local q = p.groups
              q[#q + 1] = { key, registry.item_id(group[2]), sx, sy, sx + dir[1] * st[3], sy + dir[2] * st[3], front, group[1], lines.v or 0, group[4] }
            end
          end
          if moved then
            counts.moved = counts.moved + 1
            if p then
              local mv = p.moves
              local m = #mv
              local f = floor(front * 256 + 0.5)
              if f >= floor(group[1] * 256 + 0.5) then
                f = 0
              end
              mv[m + 1], mv[m + 2], mv[m + 3] = key, f, since
            end
          end
          goto next_line
        end
        rec[11] = nil
      end
      local same = rec and rec[6] and rec[1] == n and rec[2] == p1 and rec[3] == pn and rec[7] == total
      local blind, unchanged = false, false
      if same and n > 0 then
        -- Would a lane flowing at its belt's speed look the same after this long? (Whole gaps on a
        -- full lane, or whole average gaps between its end items on one evenly filled.)
        local moved = (now - rec[6]) * (lines.v or 0)
        local slots = moved / GAP
        blind = slots - floor(slots + 0.5) < BLIND and slots - floor(slots + 0.5) > -BLIND
        if not blind and n > 1 and pn ~= p1 then
          slots = moved * (n - 1) / (pn > p1 and pn - p1 or p1 - pn)
          blind = slots - floor(slots + 0.5) < BLIND and slots - floor(slots + 0.5) > -BLIND
        end
      end
      local counts = M.counts
      counts.checked = counts.checked + 1
      if force then
        if not rec then
          rec = { n, p1, pn, 0, false }
          lanes[key] = rec
        end
      elseif blind then
        counts.blind = counts.blind + 1  -- read in full, settled or not as it was
      elseif same and rec[5] and (key + round.count) % M.lane_refresh ~= 0 then
        full = false
        unchanged = true
        held = held + n
        counts.held = counts.held + 1
      elseif same then
        rec[5] = true  -- read again unchanged: settled, held from the next update
      else
        -- Changed: a fresh record, keeping the end items of its last full read (FORCE_MAX).
        rec = { n, p1, pn, 0, false, nil, nil, rec and rec[8], rec and rec[9], rec and rec[10] }
        lanes[key] = rec
      end
      rec[4] = round.start
      rec[6] = now
      rec[7] = total
      local keys = round.ring_keys
      keys[#keys + 1] = key
      if not full and p then
        if lane_special[key] then
          full = "send"  -- read for what is sent only: counted as held
          M.counts.special = M.counts.special + 1
        else
          -- Its items stay as the client has them: kept in `known`, not carried on as missing
          -- (and written after all if a lane read in full later this update has them: held_only).
          local seen, held_only = p.seen, p.held_only
          for _, uid in ipairs(lane_uids[key] or {}) do
            seen[uid] = known[uid]
            held_only[uid] = true
          end
        end
      end
      -- How many checks in a row found it unchanged (held, or a group that didn't move).
      rec[12] = unchanged and (rec[12] or 0) + 1 or 0
      end
    end
    if full then
    if not known_belt then
      known_belt = true
      underground = belt.type == "underground-belt"
      box = underground and belt.selection_box
      if belt.type == "transport-belt" and belt.belt_shape == "straight" then
        d = DIR[belt.direction]
        if p and d and not p.starts then
          p.starts = line_starts(belt)
        end
        c = belt.position
      end
      starts = p and p.starts
    end
    local s = d and starts and starts[i]
    -- The start of this line on the map, and its direction.
    local sx, sy, fx, fy
    if s then
      sx = c.x + d[1] * s[1] - d[2] * s[2]
      sy = c.y + d[2] * s[1] + d[1] * s[2]
      fx, fy = d[1] * s[3], d[2] * s[3]
    end
    M.counts.full = M.counts.full + 1
    local sent_uids, special = key and p and {}, false
    local wrote_from = p and #p.raw
    local counted = full ~= "send"
    local first_uid, last_uid = 0, 0
    local held_only = p and p.held_only
    -- Could it be held as a group from now on (GROUP_GAPS)? Its items then say for sure.
    local gap, gstack
    if counted and round.groups and d and key and not plain then
      gap, gstack = packed_gap(n, p1, pn, total)
    end
    local gname, gi = nil, 0
    for _, item in pairs(line.get_detailed_contents()) do
      if first_uid == 0 then
        first_uid = item.unique_id
      end
      last_uid = item.unique_id
      if gap then
        -- One kind, stacks of one size, normal quality, nothing that spoils, evenly spaced.
        local st = item.stack
        local name = st.name
        units = units + GROUP_ITEM_UNITS
        local want = p1 + gi * gap
        if (gname and name ~= gname) or st.count ~= gstack or item.position - want > PHASE or want - item.position > PHASE
          or st.quality.name ~= "normal" or spoilage.spoils(name) then
          gap = nil
        end
        gname, gi = name, gi + 1
      end
      -- The hottest loop in the bridge: plain locals, few tables. (What is counted depends only
      -- on the game, never on `p`, so every peer's round goes the same way.)
      local x, y
      if s then
        x, y = sx + fx * item.position, sy + fy * item.position
      elseif not d then
        local q = line.get_line_item_position(item.position)
        x, y = q.x, q.y
        if counted then
          units = units + OFF_STRAIGHT_UNITS
        end
      end
      if not underground or inside(box, x, y) then
        if counted then
          items = items + 1
        end
        local uid = item.unique_id
        -- An item that moved on to a belt read later in the round is sent once, from its first read
        -- (one only kept with a held lane is written here: it moved on to this lane).
        if p and (not seen[uid] or held_only[uid]) then
          held_only[uid] = nil
          plain_kept[uid] = nil
          local k = known[uid]
          local ux, uy = 0, 0
          if not k then
            local name = item.stack.name
            -- An item's quality doesn't change while it rides, so it is read once too.
            k = { registry.item_id(name), spoilage.spoils(name), item.stack.quality.name }
          elseif k[6] then
            local dt = now - k[6]
            if dt > 0 and dt <= 240 then
              ux, uy = (x - k[4]) / dt, (y - k[5]) / dt
              if ux > FASTEST or ux < -FASTEST or uy > FASTEST or uy < -FASTEST then
                ux, uy = 0, 0
              end
            end
          end
          k[4], k[5], k[6], k[7], k[8], k[9], k[11], k[12] = x, y, now, ux, uy, nil, key, hidden_from
          local stack = item.stack.count
          k[10] = stack > 1 and (stack < MAX_STACK and stack or MAX_STACK) or nil
          seen[uid] = k
          local m = #raw
          raw[m + 1] = uid
          raw[m + 2] = k[1]
          raw[m + 3] = x
          raw[m + 4] = y
          local j = m / 4 + 1
          vx[j], vy[j], at[j] = ux, uy, now
          p.lk[j] = key or 0
          p.st[j] = k[10]
          if sent_uids then
            sent_uids[#sent_uids + 1] = uid
            special = special or k[2] or k[3] ~= "normal"
          end
          if k[2] then
            local fr = spoilage.freshness(item.stack)
            if fr then
              local fresh = p.fresh
              fresh[#fresh + 1] = uid
              fresh[#fresh + 1] = fr
            end
          end
          if k[3] ~= "normal" then
            p.quality[#p.quality + 1] = { uid, k[3] }
          end
        elseif sent_uids and seen[uid] then
          -- Read already this round (it moved on to this lane): it belongs here now.
          sent_uids[#sent_uids + 1] = uid
        end
      end
    end
    -- Flowing evenly: from now on a group, its items no longer read or sent one by one (the client
    -- moves them itself). Decided from game reads only; what is sent only where `p` is.
    local grouped = false
    local rec = key and lanes and lanes[key]
    if gap and gi == n and rec then
      grouped = true
      rec[11] = { gap, gname, n, gstack }
      M.counts.grouped = M.counts.grouped + 1
      if p and s then
        -- Its items were written above: taken out again, and not carried on next time.
        local raw, from_j = p.raw, wrote_from / 4 + 1
        for j = #raw / 4, from_j, -1 do
          local k = p.seen[raw[j * 4 - 3]]
          if k then
            k[9] = true
          end
          raw[j * 4 - 3], raw[j * 4 - 2], raw[j * 4 - 1], raw[j * 4] = nil, nil, nil, nil
          p.vx[j], p.vy[j], p.at[j], p.lk[j], p.st[j] = nil, nil, nil, nil, nil
        end
        sent_uids = {}
        -- Written out when the update is sent (emit: its tick decides where the items are).
        local q = p.groups
        q[#q + 1] = { key, registry.item_id(gname), sx, sy, sx + fx, sy + fy, p1, gap, lines.v or 0, gstack }
      end
    end
    -- Read in full: if its end items are other items than last time, the line moved on by whole
    -- slots and the lanes either side are read in full too (FORCE_MAX). From game reads only, and
    -- not for a lane read only for what is sent (full == "send": quality or spoiling items on a
    -- held lane): whether that read happens depends on `p` and lane_special, module-local, so a
    -- peer that loaded since would leave its record and the line alone.
    if rec and counted then
      -- (A new group's line flows on as one: nothing to force along it.)
      local shifted = not grouped and not plain and rec[8] ~= nil and (rec[8] ~= first_uid or rec[9] ~= last_uid)
      rec[8], rec[9], rec[10] = first_uid, last_uid, round.start
      -- (Not for a `br` client: what made this worth it, long backed-up lines held while they
      -- shuffled on, are plain lanes it moves itself; the rest, read along the line, were a fifth of
      -- belt items' time on the owner's save.)
      if shifted and not round.runs and (round.forced or 0) < FORCE_MAX then
        -- The belts either side (belt_neighbours: LuaTransportLine's input_lines and output_lines
        -- name the ends of the whole segment of straight belts in 2.1.23, skipping the belts between).
        local q = round.force_q or {}
        round.force_q = q
        -- A splitter's or an underground's lanes don't line up with a belt's by number (a belt's
        -- lane 1 feeds a splitter's 3; a splitter moves items from its lane 4 to its 6): with
        -- more than two lanes on either side, every lane of it is read (2.1.23, the owner's save).
        if #lines > 2 then
          for o = 1, #lines do
            if o ~= i then
              q[#q + 1] = { belt, o }
            end
          end
        end
        local ok, nb = pcall(function() return belt.belt_neighbours end)
        -- (A plain belt either side (`br`) isn't: the client moves its items on itself.)
        local bw = watch and storage.f3d.bw
        if ok and nb then
          for _, list in pairs({ nb.inputs or {}, nb.outputs or {} }) do
            for _, e in pairs(list) do
              local wr = bw and e.valid and bw[e.unit_number]
              local count = (wr and not wr[1]) and 0 or #lines > 2 and 8 or (e.valid and e.get_max_transport_line_index() or 0)
              if count > 2 then
                for o = 1, count do
                  q[#q + 1] = { e, o }
                end
              elseif count > 0 then
                q[#q + 1] = { e, i }
              end
            end
          end
        end
      end
    end
    -- A plain lane read: where it is and the lanes either side, for the client to move its items.
    if plain and p and s then
      local q = p.plains
      q[#q + 1] = { key, watch[2] * LANE_KEYS + i, watch[3] * LANE_KEYS + i, sx, sy, sx + fx, sy + fy, lines.v or 0 }
    end
    if sent_uids and plain then
      for _, uid in ipairs(lane_uids[key] or {}) do
        if plain_kept[uid] == key then
          plain_kept[uid] = nil
        end
      end
      for _, uid in ipairs(sent_uids) do
        plain_kept[uid] = key
      end
    end
    if sent_uids then
      lane_uids[key] = sent_uids
      lane_special[key] = special or nil
      if #p.raw == wrote_from and not grouped then
        p.emptied[#p.emptied + 1] = key
      end
    end
    end
    end
    ::next_line::
  end
  -- What counts towards the cap: its items (stacks), held ones too, and a weight a lane (plain
  -- lanes not checked: plain_weight).
  return items + held + weight, units + items * (1 + WRITE_UNITS)
end

-- Ends the round at the start of ring `ring`: what was read of it is dropped, and `fr` says the
-- square reaches only that far.
local function cut(round, ring)
  -- Lanes still queued along lines that moved on are read on the ticks left (read), not all on
  -- the due tick (on the owner's save 500-2,400 lanes, 3-26 ms in one tick).
  round.cut, round.done = ring, not (round.force_q and #round.force_q > 0)
  -- What of the ring was read before it went over (at least what it holds), for the next round.
  round.edge_need = round.items - round.ring_items
  round.items = round.ring_items
  -- Lanes checked in the ring that is dropped are read in full next time: the client won't have
  -- what they hold now.
  local lanes = storage.f3d.bl
  if lanes then
    for _, key in ipairs(round.ring_keys) do
      lanes[key] = nil
    end
  end
  local p = payload(round)
  if not p then
    return
  end
  local n = p.mark[1]
  for j = n * 4 + 1, #p.raw do
    p.raw[j] = nil
  end
  for j = n + 1, #p.vx do
    p.vx[j], p.vy[j], p.at[j], p.lk[j], p.st[j] = nil, nil, nil, nil, nil
  end
  for j = p.mark[4] + 1, #p.emptied do
    p.emptied[j] = nil
  end
  for j = p.mark[2] + 1, #p.fresh do
    p.fresh[j] = nil
  end
  for j = p.mark[3] + 1, #p.quality do
    p.quality[j] = nil
  end
  for j = (p.mark[5] or 0) + 1, #p.groups do
    p.groups[j] = nil
  end
  for j = (p.mark[6] or 0) + 1, #p.moves do
    p.moves[j] = nil
  end
  for j = (p.mark[7] or 0) + 1, #p.plains do
    p.plains[j] = nil
  end
  -- Parts already written that reach into the dropped ring are written again.
  if p.written > n then
    local keep = floor(n / M.items_per_message)
    for j = keep + 1, #p.bodies do
      p.bodies[j], p.tails[j], p.emptied_upto[j] = nil, nil, nil
    end
    if (p.emptied_upto[keep] or 0) > #p.emptied then
      p.emptied_upto[keep] = #p.emptied
    end
    p.written = keep * M.items_per_message
  end
end

-- Writes out every whole part read (all that is left with `all`).
local function write_parts(p, target, all)
  while #p.vx - p.written >= M.items_per_message or (all and #p.vx > p.written) do
    write_part(p, target)
  end
end

-- One lane queued by a line that moved on (read_belt's FORCE_MAX): {belt, line index}, read in
-- full if it is within the square and wasn't read in full this round. Returns what read_belt does,
-- or 0, 0.
local function force_lane(entry, p, now, round)
  local belt, i = entry[1], entry[2]
  if not (belt and belt.valid and belt.unit_number) or i > belt.get_max_transport_line_index() then
    return 0, 0
  end
  local pos = belt.position
  local dx, dy = pos.x - round.fx, pos.y - round.fy
  local ring = floor(math.max(dx < 0 and -dx or dx, dy < 0 and -dy or dy))
  if ring >= (round.cut or round.r) then
    return 0, 0
  end
  local lanes = storage.f3d.bl
  if not lanes then
    return 0, 0
  end
  local rec = lanes[belt.unit_number * LANE_KEYS + i]
  if rec and rec[10] == round.start then
    return 0, 0  -- read in full already this round
  end
  round.forced = (round.forced or 0) + 1
  if round.forced > FORCE_MAX then
    return 0, 0
  end
  return read_belt(belt, p, now, round, lanes, { [i] = true })
end

-- Reads belts (finding the next band's when one runs out) until `budget` units are spent or the
-- round is done.
local function read(round, budget, now, surface)
  local p = payload(round)
  -- The client's Belt updates (-1: Unlimited, every belt within its distance), else the mod's own.
  local cap = storage.f3d.bi_cap or M.max_items
  if cap < 0 then
    cap = math.huge
  end
  local spent = 0
  while spent < budget do
    if round.cut or round.i > #round.belts then
      if round.cut or round.last_band then
        -- Lanes along lines that moved on, read in full before the update goes (see FORCE_MAX).
        local q = round.force_q
        if q and #q > 0 then
          local nl = table.remove(q)
          spent = spent + BELT_UNITS
          round.units = round.units + BELT_UNITS
          local n, units = force_lane(nl, p, now, round)
          round.items = round.items + n
          round.units = round.units + units
          spent = spent + units
          if p then
            write_parts(p, round.target)
          end
          goto continue
        end
        round.done = true
        return
      end
      local units = find_band(round, surface)
      round.units = round.units + units
      spent = spent + units
    else
      local ring = round.rings[round.i]
      if ring ~= round.ring then
        round.ring, round.ring_items, round.ring_keys = ring, round.items, {}
        if p then
          p.mark = { #p.raw / 4, #p.fresh, #p.quality, #p.emptied, #p.groups, #p.moves, #p.plains }
        end
        -- The ring the last update stopped at, which held too much to grow into then: left out
        -- again before it is read (its lanes are read in full each time, never sent: on the
        -- owner's save 108 of 264 lanes read in full an update), unless the rings inside it now
        -- hold less.
        -- (The ring's belts kept unread count towards the cap as they would read.)
        local kc = round.keep_count
        if kc and kc[ring] then
          round.items = round.items + kc[ring]
          kc[ring] = nil
        end
        local need = round.prev and ring == round.prev and storage.f3d.bi.edge_need
        if need and round.items + need > cap * GROW then
          cut(round, ring)
          round.edge_need = need
          return
        end
      end
      local belt = round.belts[round.i]
      round.i = round.i + 1
      spent = spent + BELT_UNITS
      round.units = round.units + BELT_UNITS
      if belt.valid then
        local n, units = read_belt(belt, p, now, round, storage.f3d.bl)
        round.items = round.items + n
        round.units = round.units + units
        spent = spent + units
        local limit = cap
        if round.prev then
          limit = ring < round.prev and cap * KEEP or cap * GROW
        end
        if round.items > limit then
          -- Back to the last whole ring: everything inside it, nothing of this one.
          cut(round, ring)
          return
        end
        -- Written out as they come (a cut writes again what it drops): their cost is counted
        -- with their reading, so the text is spread over the round's ticks too.
        if p then
          write_parts(p, round.target)
        end
      end
    end
    ::continue::
  end
end

-- On the tick an update is due and the round isn't finished: the ring being read is left out
-- unless it was just finished.
local function cut_short(round)
  round.short = true
  local next_ring = round.i <= #round.belts and round.rings[round.i] or round.band
  if next_ring ~= round.ring then
    round.cut, round.done = next_ring, true
  else
    cut(round, round.ring)
  end
end

-- Sends the round as one update, stamped `now`. What was written out for another tick (the
-- `rate` level changed the job's ticks meanwhile) is written again.
local function emit(round, now, period, lanes_left)
  local p = payload(round)
  pay = nil
  line_cache, next_cache = next_cache, {}
  if not p then
    return -- loaded mid-round: nothing to send this time
  end
  local k = now
  if round.target ~= now then
    p.bodies, p.tails, p.written, p.emptied_upto = {}, {}, 0, {}
  end
  -- An item that moved from a belt read later in the round on to one read earlier was read on
  -- neither. Missing from an update, the client would stop it for one and then jump it on, so an
  -- item read last time and not this time is carried on along its way, once, where it would be.
  -- (An item taken off the belt goes on for one update too, and then is gone.)
  local edge = floor(round.cut or round.r)
  local seen, raw, vx, vy, at = p.seen, p.raw, p.vx, p.vy, p.at
  -- (`br`: nor one last read on a lane with a plain lane in front, which it went on into: the
  -- client moves it on there.)
  local bw = round.runs and storage.f3d.bw
  local lanes_now = storage.f3d.bl
  for uid, c in pairs(known) do
    local w = bw and c[11] and bw[floor(c[11] / LANE_KEYS)]
    local into = w and w[3] ~= 0 and bw[w[3]]
    local kept = bw and c[11] and lanes_now and lanes_now[c[11]]
    -- (Nor one last read on an underground's entrance: not read again, it went under the ground,
    -- and carried on it would be put over the gap, on the belt it passes under: truth-findings 7.)
    if not seen[uid] and not c[9] and not c[12] and c[6] and c[7] and not plain_kept[uid] and not (into and not into[1])
      and not (kept and kept[17] == round.start) then
      local dt = k - c[6]
      local x, y = c[4] + c[7] * dt, c[5] + c[8] * dt
      if math.abs(x - round.fx) < edge and math.abs(y - round.fy) < edge then
        c[9] = true
        seen[uid] = c
        local m = #raw
        raw[m + 1], raw[m + 2], raw[m + 3], raw[m + 4] = uid, c[1], c[4], c[5]
        local j = m / 4 + 1
        vx[j], vy[j], at[j] = c[7], c[8], c[6]
        p.lk[j] = 0
        p.st[j] = c[10]
      end
    end
  end
  write_parts(p, k, true)
  if p.lanes and #p.emptied > (p.emptied_upto[#p.bodies] or 0) then
    -- Lanes read with nothing to send after the last part: one more part, with no items.
    local ln = {}
    for x = (p.emptied_upto[#p.bodies] or 0) + 1, #p.emptied do
      ln[#ln + 1] = p.emptied[x] .. ",0"
    end
    p.bodies[#p.bodies + 1] = ""
    p.tails[#p.bodies] = ',"ln":[' .. table.concat(ln, ",") .. "]"
    p.emptied_upto[#p.bodies] = #p.emptied
  end
  known = seen
  -- The lanes that became groups this update, GROUPS_PER_PART to a part, and the groups that moved,
  -- MOVES_PER_PART to a part (more parts if need be). `bg`: [lane key, item id, x, y where line
  -- position 0 is, x, y where 1 is (1/256 tile), its front item's line position (1/256, below one
  -- gap), the gap (1/256), the belt's speed (line positions a tick, 1/65536), stack size]: its
  -- items are a gap apart from there to the end. Positions fall as items go, from 1 where they come
  -- in to 0. `bm`: [lane key, its front item's line position (1/256) on the update's tick, ticks
  -- since its last check (what the move took at most; both on the updates' ticks), ...].
  local groups, moves, plains = p.groups, p.moves, p.plains
  local parts = math.max(math.ceil(#groups / GROUPS_PER_PART), math.ceil(#moves / 3 / MOVES_PER_PART),
    math.ceil(#plains / PLAINS_PER_PART), #p.checks > 0 and 1 or 0)
  for part = 1, parts do
    if part > #p.bodies then
      p.bodies[part] = ""
    end
    local flat = {}
    for j = (part - 1) * GROUPS_PER_PART + 1, math.min(part * GROUPS_PER_PART, #groups) do
      local g = groups[j]
      local m = #flat
      flat[m + 1], flat[m + 2] = g[1], g[2]
      flat[m + 3], flat[m + 4] = floor(g[3] * 256 + 0.5), floor(g[4] * 256 + 0.5)
      flat[m + 5], flat[m + 6] = floor(g[5] * 256 + 0.5), floor(g[6] * 256 + 0.5)
      flat[m + 7], flat[m + 8] = floor(g[7] * 256 + 0.5), floor(g[8] * 256 + 0.5)
      flat[m + 9], flat[m + 10] = floor(g[9] * 65536 + 0.5), g[10]
    end
    local tail = p.tails[part] or ""
    if #flat > 0 then
      tail = tail .. ',"bg":[' .. table.concat(flat, ",") .. "]"
    end
    local from, to = (part - 1) * MOVES_PER_PART * 3 + 1, math.min(part * MOVES_PER_PART * 3, #moves)
    if to >= from then
      tail = tail .. ',"bm":[' .. table.concat(moves, ",", from, to) .. "]"
    end
    -- `pl`: [lane key, the lane behind's key, the lane in front's key, x, y where line position 0 is,
    -- x, y where 1 is (1/256 tile), the belt's speed (line positions a tick, 1/65536), ...]: plain
    -- lanes read this update (their items are in ln as any lane's), which the client moves itself.
    local pf = {}
    for j = (part - 1) * PLAINS_PER_PART + 1, math.min(part * PLAINS_PER_PART, #plains) do
      local q = plains[j]
      local m = #pf
      pf[m + 1], pf[m + 2], pf[m + 3] = q[1], q[2], q[3]
      pf[m + 4], pf[m + 5] = floor(q[4] * 256 + 0.5), floor(q[5] * 256 + 0.5)
      pf[m + 6], pf[m + 7] = floor(q[6] * 256 + 0.5), floor(q[7] * 256 + 0.5)
      pf[m + 8] = floor(q[8] * 65536 + 0.5)
    end
    if #pf > 0 then
      tail = tail .. ',"pl":[' .. table.concat(pf, ",") .. "]"
    end
    -- `pc`: [lane key, its stacks, front and back items' line positions (1/256), ticks it was read
    -- before the update's tick, ...]: plain lanes' drift checks, all in the first part.
    if part == 1 and #p.checks > 0 then
      tail = tail .. ',"pc":[' .. table.concat(p.checks, ",") .. "]"
    end
    p.tails[part] = tail
  end
  if p.lanes then
    -- Lanes no longer read (out of the square, their belt gone): the client drops their items.
    local dropped = {}
    for key, rec in pairs(lanes_left or {}) do
      dropped[#dropped + 1] = key
    end
    table.sort(dropped)
    for _, key in ipairs(dropped) do
      for _, uid in ipairs(lane_uids[key] or {}) do
        if plain_kept[uid] == key then
          plain_kept[uid] = nil
        end
      end
      lane_uids[key], lane_special[key] = nil, nil
    end
    p.tails[1] = (p.tails[1] or ',"ln":[]') .. ',"dl":[' .. table.concat(dropped, ",") .. "]"
  end
  -- Like `mv`, every update is the full list, split into parts that share the tick `k`. Each part
  -- says which square it covers, so the client hands over to the far lane icons exactly where
  -- these items stop rather than round its own focus, which runs ahead while panning, and
  -- `p`, the ticks between updates, so the client draws items far enough behind to glide evenly,
  -- and `w`, the work units the update took (w / p a tick; with what a round cut short for time
  -- would have needed), which Moving belt items' Automatic keeps within its share of the tick.
  transport.send_parts("bi", k, p.bodies,
    ',"fx":' .. world.fixed(round.fx) .. ',"fy":' .. world.fixed(round.fy) .. ',"fr":' .. floor(round.cut or round.r) .. ',"p":' .. period
      .. ',"w":' .. floor(round.need or round.units),
    p.tails)
  -- Quality (Space Age) only where some item has one, plus one empty list to clear it.
  local quality, fresh = p.quality, p.fresh
  if #quality > 0 or bq_sent then
    transport.send_now({ t = "bq", l = quality })
  end
  bq_sent = #quality > 0
  -- Only where something spoils, so other bases send nothing extra.
  local per = 600  -- numbers a part: 300 items
  local parts = math.ceil(#fresh / per)
  for part = 1, parts do
    local slice = {}
    for i = (part - 1) * per + 1, math.min(part * per, #fresh) do
      slice[#slice + 1] = fresh[i]
    end
    transport.send_now({ t = "bf", part = part, parts = parts, l = slice })
  end
end

-- Tiles round the focus within which every item is sent: the client's choice (`bfar` n) if it
-- made one, as it asked (owner: the setting goes as far as it says, no other cap than its own Belt
-- updates); else the map setting, within the focus radius.
local function near_radius()
  local s = storage.f3d
  if s.near_r then
    return s.near_r
  end
  return math.min(settings.global["f3d-detail-radius"].value, s.focus.r)
end

-- Units read a tick: the client's choice (`bfar` u) if it made one. Smooth belt items (a u of
-- SMOOTH_FROM or more) wants an update every interval: each round is spread evenly over the
-- interval's ticks, sized by what the last round needed (b.work), never less than the mod's own
-- slice. (It read the whole round in one tick, which on the owner's save was a 50-90 ms tick
-- every 12-24 ticks; the game caught up to 59 UPS but its ticks came unevenly.)
local SMOOTH_FROM = 1000000
local function smooth()
  local u = storage.f3d.bi_units
  return u ~= nil and u >= SMOOTH_FROM
end
local function units_per_tick()
  local u = storage.f3d.bi_units
  if smooth() then
    local b = storage.f3d.bi
    local period = rate.period("bi", settings.global["f3d-detail-interval"].value)
    -- Half as much again: a round bigger than the last still ends before its due tick.
    return math.max(M.units_per_tick, ceil(((b and b.work) or 0) * 1.5 / math.max(1, period - 1)))
  end
  return u or M.units_per_tick
end
M.read_units = function() return units_per_tick() end  -- for tests

-- Belt units per work-budget unit (budget.lua): measured on the owner's save, belt items' share
-- of 60 such units a tick took 3.7 ms, a budget unit being ~20 us.
M.UNITS_PER_BUDGET_UNIT = 20

-- What reading belts will take this tick, in work-budget units: charged before the tick's other
-- jobs ask for room (budget.admit), so they keep off it. From storage alone.
function M.planned_units()
  local b = storage.f3d.bi
  if not b or near_radius() <= 0 then
    return 0
  end
  return math.floor(units_per_tick() / M.UNITS_PER_BUDGET_UNIT)
end

-- How many ticks a round of `work` units takes.
local function ticks_for(work)
  if smooth() then
    -- Started a whole interval ahead whatever the headroom in its share.
    return math.max(1, rate.period("bi", settings.global["f3d-detail-interval"].value) - 1)
  end
  return math.max(1, ceil(work / units_per_tick()))
end

-- For tests: the round in progress, or nil.
function M.round()
  return storage.f3d.bi and storage.f3d.bi.round
end

function M.tick()
  local r = near_radius()
  local s = storage.f3d
  if r <= 0 then
    s.bi, pay = nil, nil
    return
  end
  local interval = settings.global["f3d-detail-interval"].value
  local b = s.bi
  if not b then
    b = { m = 1, dues = 0, work = 0 }
    s.bi = b
  end
  -- Lanes are kept for a client that keeps them (`bl` in its hello), and plain lanes known for one
  -- that moves them itself (`br`). A client that starts or stops saying br has every lane read again.
  if s.client and s.client.bl then
    s.bl = s.bl or {}
    local runs = s.client.br or nil
    if runs ~= s.bl_runs then
      s.bl, s.bl_runs = {}, runs
    end
    if runs then
      s.bw = s.bw or {}
      forget_touched(s)
    else
      s.bw, s.bt, s.bw_dirty, s.bc = nil, nil, nil, nil
    end
  else
    s.bl, s.bw, s.bt, s.bw_dirty, s.bl_runs, s.bc = nil, nil, nil, nil, nil, nil
  end
  local now = game.tick
  -- The job's ticks: every detail interval, stretched by the client's `rate` level. An update is
  -- sent on every m-th of them, m as many as a round of this size needs.
  local period = rate.period("bi", interval)
  if rate.due("bi", interval) then
    b.dues = b.dues + 1
  end
  local due = b.dues >= b.m
  local surface = world.surface()
  local round = b.round
  -- (A round saved by a bridge before 0.1.2, the public 0.1.1 among them, has no ring_keys or
  -- count, which reading with kept lanes indexes: it starts over.)
  if round and (round.si ~= surface.index or not round.ring_keys) then
    round, b.round = nil, nil
  end
  -- A round starts as late as it can and still be read by the tick it is due; with lanes kept, a
  -- tick earlier every other update (M.lane_jitter: the time between a lane's checks is then odd).
  local target = b.last and b.last + b.m * period
  local early = (s.bl and M.lane_jitter and (b.count or 0) % 2 == 1) and 1 or 0
  if not round and (due or (target and now >= target - ticks_for(b.work) + 1 - early)) then
    local f = s.focus
    round = { start = now, si = surface.index, fx = f.x, fy = f.y, r = r, target = due and now or target,
      band = 0, belts = {}, rings = {}, i = 1, ring = -1, ring_items = 0, items = 0, units = 0,
      ring_keys = {}, count = b.count or 0, prev = b.fr, groups = s.bl ~= nil and s.client.bg or nil,
      runs = s.bw ~= nil or nil, plain_edge = b.plain_edge, far_every = s.bw and math.max(1, floor(M.far_ticks / (b.m * period) + 0.5)) or nil }
    b.round = round
    pay = { id = now, raw = {}, vx = {}, vy = {}, at = {}, bodies = {}, written = 0, lk = {}, st = {}, tails = {}, emptied = {},
      lanes = s.bl ~= nil, groups = {}, moves = {}, plains = {}, checks = {},
      fresh = {}, quality = {}, seen = {}, held_only = {}, emptied_upto = {}, mark = { 0, 0, 0, 0, 0, 0, 0 } }
  end
  if round and not round.done then
    -- On its due tick what is left is read up to DUE_BURST slices, smooth or not; past that the
    -- square stops at the last whole ring read (cut short), and the next round, sized from what this
    -- one would have needed, catches up in a round or two. (Smooth read whatever was left: running
    -- from an empty stretch, where a round is small and Automatic grows its cap, into the busy belts
    -- of Zenith Test, one due tick read 50,000 units, 374 ms.)
    local burst = units_per_tick() * DUE_BURST
    read(round, due and burst or units_per_tick(), now, surface)
    if due and not round.done then
      cut_short(round)
    end
  elseif round and not due and payload(round) then
    -- Read ahead of time: the last part is written now rather than on the tick it is sent.
    write_parts(pay, round.target, true)
  end
  if not due then
    return
  end
  -- What the next round will need, from this one. It takes more due ticks at once when it needs
  -- them; fewer only once it fits well within them, so m doesn't flip back and forth (each change
  -- moves the client's glide). A round cut short for time would have needed more: it is taken as
  -- needing up to twice what it read (by the area it covered), so m catches up in a few rounds.
  local work = round.units
  if round.short and round.cut < round.r then
    work = ceil(round.units * math.min(2, (round.r * round.r) / math.max(1, round.cut * round.cut)))
  end
  -- What the update needed, for `bi` w: a round cut short for time would have needed more.
  local short_of = work - round.units
  local need = smooth() and 1 or ceil(ticks_for(work) / period)
  if smooth() then
    b.m = 1
  elseif need > b.m then
    b.m = need
  elseif need < b.m and ticks_for(work * 1.1) <= (b.m - 1) * period then
    b.m = b.m - 1
  end
  -- Lanes not checked this round are forgotten (and the client told to drop them), but those it
  -- kept unread (straight runs).
  local left = nil
  if s.bl then
    apply_keep(round, s.bl)
    left = {}
    for key, rec in pairs(s.bl) do
      if rec[4] ~= round.start then
        left[key] = true
      end
    end
    for key in pairs(left) do
      s.bl[key] = nil
    end
  end
  -- Lanes along lines that moved on, not read yet (the cap or time ended the round first): read
  -- now, so the update has whole lines (FORCE_MAX).
  local q = round.force_q
  if q and #q > 0 then
    local p = payload(round)
    while #q > 0 do
      local _, units = force_lane(table.remove(q), p, now, round)
      round.units = round.units + units
    end
    if p then
      write_parts(p, round.target)
    end
  end
  round.need = round.units + short_of
  emit(round, now, b.m * period, left)
  b.round, b.dues, b.last, b.work = nil, 0, now, work
  -- The square it covered, where far lane icons needn't be read (far_tick).
  b.sq = { round.fx, round.fy, floor(round.cut or round.r) }
  -- Where this update stopped, if the cap stopped it: the next keeps it unless well past the cap.
  b.fr = round.cut and not round.short and floor(round.cut) or nil
  b.edge_need = b.fr and round.edge_need or nil
  -- Where plain lanes stop (plain_here): it follows the square's edge out only when that moved two
  -- rings or more, so the lanes there don't flip between plain and watched (each flip sent them
  -- again), and in at once: a plain lane at the last ring has its lane in front outside the square,
  -- which the client doesn't have (its chain ran on into it: the windowed client's cap moves often).
  -- (A round cut short for time leaves it as it was; one that reached its radius has none.)
  local e = b.fr
  if not round.cut then
    b.plain_edge = nil
  elseif e and (not b.plain_edge or e < b.plain_edge or e - b.plain_edge >= 2) then
    b.plain_edge = e
  end
  b.count = (b.count or 0) + 1
end


---------------------------------------------------------------------------------------------
-- Belts far away (`bfar`): past the detail radius the client draws each lane as one icon of what
-- it carries, as Factorio's zoomed-out view reads. The client sets how far (`bfar` command, r in
-- tiles, 0 off). Subscribed chunks within r of the focus are read far_belts_per_tick belts a tick
-- (fewer at a slower `rate`), round and round, and a chunk is sent only when what its lanes carry changed:
-- {t = "bfar", cx, cy, l = [x, y (1/256 tile), direction, lane 1 item id, lane 2 item id, ...],
-- c = [lane 1 count, lane 2 count, ...]}, 0 for an empty lane; an empty l clears the chunk. The
-- counts (items on that lane of that belt, at most 4) let the client draw a full belt full,
-- and h how high to pile them when there are more items than that (stack inserters' stacks). By
-- items, not stacks: counted by stacks, a lane of a few stacks of 4 drew a few icons with holes
-- between them, which from afar read as gaps on a full belt (owner: "we didn't have gaps in 0.1.1").

-- What a far lane carries changes slowly and is drawn small, so a round over the chunks starts at
-- most every FAR_ROUND_TICKS, reading far_belts_per_tick belts a tick. A belt costs about 12-25 us
-- (two get_contents) on the owner's save, and a busy chunk holds 700: read whole in one tick (and
-- written out at its end), one chunk cost up to 48 ms. So a chunk is read over as many ticks as it
-- needs too.
M.far_belts_per_tick = 100
local FAR_ROUND_TICKS = 180
local FAR_MIN_BELTS = 10
-- Finding a chunk's belts costs about a twentieth of reading them.
local FAR_FIND_PER_BELT = 20
-- Chunks this far past r are read too (a chunk's half diagonal is 23): the round is fixed round the
-- focus where it began, and while the camera pans chunks coming into r must already be there.
local FAR_MARGIN = 48

-- The round in progress (queue, next; cur, the chunk being read: {key, c, belts, i, l, counts, piles,
-- stacked}) and what each chunk last sent, per client (storage.f3d is the client being served),
-- changed only from on_tick and commands.
local function far_state()
  local s = storage.f3d
  s.far = s.far or { queue = {}, next = 1, sent = {} }
  return s.far
end

-- A full lane holds 4 items (or stacks) a belt.
local FAR_MAX_COUNT = 4

-- The item a lane carries most of, by id (0: empty), how many icons it gets (its items, at most
-- FAR_MAX_COUNT) and how high they are piled (the items over those icons, rounded up: 1 to MAX_STACK).
local function lane_item(line)
  local best, most, all = nil, 0, 0
  for _, it in pairs(line.get_contents()) do
    all = all + it.count
    if it.count > most then
      best, most = it.name, it.count
    end
  end
  local icons = math.min(all, FAR_MAX_COUNT)
  local pile = icons > 0 and math.min(MAX_STACK, ceil(all / icons)) or 1
  return best and registry.item_id(best) or 0, icons, pile
end

-- Starts reading a chunk: its belts. Returns the chunk and the belts it holds.
local function far_find(surface, types, key, c)
  local x0, y0 = c[1] * 32, c[2] * 32
  local found = surface.find_entities_filtered({ area = { { x0, y0 }, { x0 + 32, y0 + 32 } }, type = types })
  local belts = {}
  for _, belt in pairs(found) do
    local p = belt.position
    if p.x >= x0 and p.x < x0 + 32 and p.y >= y0 and p.y < y0 + 32 then
      belts[#belts + 1] = belt
    end
  end
  return { key = key, c = c, belts = belts, i = 1, l = {}, counts = {}, piles = {} }, #found
end

-- Reads up to `budget` of the chunk's belts; returns how many it read. Each belt's numbers are
-- written as text as it is read: turning a busy chunk's 5,000 numbers into text at its end cost
-- 7 ms in one tick (2.1.23, the owner's save).
local function far_read(cur, budget)
  -- A chunk half read in a save from before piles (0.1.1) has none: the save keeps its client, and
  -- this runs for it until that client times out or says hello again (far_reset).
  cur.piles = cur.piles or {}
  local belts, l, counts, piles = cur.belts, cur.l, cur.counts, cur.piles
  local small = transport.small
  local read = 0
  while read < budget and cur.i <= #belts do
    local belt = belts[cur.i]
    cur.i = cur.i + 1
    read = read + 1
    if belt.valid then
      local p = belt.position
      local a, na, ha = lane_item(belt.get_transport_line(1))
      local b, nb, hb = lane_item(belt.get_transport_line(2))
      if a ~= 0 or b ~= 0 then
        l[#l + 1] = world.fixed(p.x) .. "," .. world.fixed(p.y) .. "," .. small[belt.direction] .. ","
          .. (small[a] or a) .. "," .. (small[b] or b)
        counts[#counts + 1] = small[na] .. "," .. small[nb]
        piles[#piles + 1] = small[ha] .. "," .. small[hb]
        cur.stacked = cur.stacked or ha > 1 or hb > 1
      end
    end
  end
  return read
end

-- A chunk read whole: sent if what its lanes carry changed.
local function far_finish(cur, far_sent)
  local l, counts = table.concat(cur.l, ","), table.concat(cur.counts, ",")
  -- How high each lane's stacks are piled, only where some are (a stack inserter's).
  local h = cur.stacked and #cur.piles == #cur.counts and (',"h":[' .. table.concat(cur.piles, ",") .. "]") or ""
  local sig = l .. ";" .. counts .. h
  if sig ~= (far_sent[cur.key] or ";") then
    far_sent[cur.key] = sig
    transport.send_text("bfar", ',"cx":' .. cur.c[1] .. ',"cy":' .. cur.c[2] .. ',"l":[' .. l .. '],"c":[' .. counts .. "]" .. h)
  end
end

-- {r, n, m, u}: how far (tiles) the client draws belt lanes, 0 stopping them; n, optional, how far
-- every item may be sent moving (MAX_NEAR at most; without n the map setting f3d-detail-radius,
-- within the focus radius); m, optional, the most items (stacks) and lanes an update reads before
-- it stops at the last whole ring (the client's Belt updates; 0: no cap, every belt within n;
-- without m, M.max_items): items move as far out as m allows and the far lane icons start there;
-- u, optional, the units of belt items read a tick (units_per_tick).
local MAX_NEAR = 640
local MIN_CAP, MAX_CAP = 200, 100000

-- `bre` {l = [lane key, ...]}: plain lanes the client has otherwise than their drift check says:
-- forgotten, so the next round reads them in full again (as new: sent with pl).
function M.resend(cmd)
  local lanes = storage.f3d.bl
  if not (lanes and type(cmd.l) == "table") then
    return
  end
  local bw = storage.f3d.bw or {}
  for j, key in ipairs(cmd.l) do
    if j > 256 then
      break
    end
    local rec = type(key) == "number" and lanes[key]
    if rec and rec[14] then
      -- Its whole chain, both lanes (see chain_head).
      for _, unit in ipairs(chain_units(floor(key / LANE_KEYS), bw)) do
        for i = 1, 2 do
          local r = lanes[unit * LANE_KEYS + i]
          if r and r[14] then
            lanes[unit * LANE_KEYS + i] = nil
            M.counts.resent = M.counts.resent + 1
          end
        end
      end
    end
  end
end

function M.set_far(cmd)
  local s = storage.f3d
  s.far_r = math.max(0, math.min(1024, math.floor(tonumber(cmd.r) or 0)))
  local n = tonumber(cmd.n)
  s.near_r = n and math.max(0, math.min(MAX_NEAR, math.floor(n))) or nil
  local m = tonumber(cmd.m)
  if m == 0 then
    s.bi_cap = -1  -- Unlimited
  else
    s.bi_cap = m and m > 0 and math.max(MIN_CAP, math.min(MAX_CAP, math.floor(m))) or nil
  end
  local u = tonumber(cmd.u)
  s.bi_units = u and u > 0 and math.max(100, math.min(10000000, math.floor(u))) or nil
  local far = far_state()
  far.queue, far.next, far.started, far.cur = {}, 1, nil, nil
end

function M.far_tick()
  local s = storage.f3d
  local r = s.far_r or 0
  local types = registry.belt_types()
  if r <= 0 or #types == 0 or not s.subs then
    return
  end
  local far = far_state()
  if far.next > #far.queue and not far.cur then
    if far.started and game.tick - far.started < FAR_ROUND_TICKS * rate.factor("lanes") then
      return
    end
    far.started = game.tick
    -- The next round: subscribed chunks within r, nearest first; forget chunks no longer subscribed
    -- (the client dropped them, so they are sent again when they come back).
    local f = s.focus
    far.queue, far.next = {}, 1
    -- Chunks whose every belt is inside the square the last belt items update covered (bi fx, fy,
    -- fr, less a tile) aren't read: their items move there, and the client draws no icons inside
    -- it. Forgotten as sent, so they are sent again once the square leaves them.
    local sq = s.bi and s.bi.sq
    for key, c in pairs(s.subs) do
      local dx, dy = c[1] * 32 + 16 - f.x, c[2] * 32 + 16 - f.y
      local x0, y0 = c[1] * 32, c[2] * 32
      if sq and x0 + 0.5 > sq[1] - sq[3] + 1 and x0 + 31.5 < sq[1] + sq[3] - 1
        and y0 + 0.5 > sq[2] - sq[3] + 1 and y0 + 31.5 < sq[2] + sq[3] - 1 then
        far.sent[key] = nil
        M.counts.far_skipped = M.counts.far_skipped + 1
      elseif dx * dx + dy * dy <= (r + FAR_MARGIN) * (r + FAR_MARGIN) then
        far.queue[#far.queue + 1] = { key, c, dx * dx + dy * dy }
      end
    end
    -- Nearest first; the key breaks ties so every peer sorts the same.
    table.sort(far.queue, function(a, b) return a[3] < b[3] or (a[3] == b[3] and a[1] < b[1]) end)
    for key in pairs(far.sent) do
      if not s.subs[key] then
        far.sent[key] = nil
      end
    end
  end
  local surface = world.surface()
  -- Slowed down (rate.lua): rounds start less often and read fewer belts a tick.
  local per = M.far_belts_per_tick
  local budget = math.max(math.min(FAR_MIN_BELTS, per), math.floor(per / rate.factor("lanes")))
  while budget > 0 do
    local cur = far.cur
    if cur then
      budget = budget - far_read(cur, budget)
      if cur.i > #cur.belts then
        far.cur = nil
        -- A chunk the client dropped meanwhile is left for when it comes back.
        if s.subs[cur.key] then
          far_finish(cur, far.sent)
        end
      end
    elseif far.next <= #far.queue then
      local entry = far.queue[far.next]
      far.next = far.next + 1
      if s.subs[entry[1]] then
        local found
        far.cur, found = far_find(surface, types, entry[1], entry[2])
        budget = budget - math.max(1, ceil(found / FAR_FIND_PER_BELT))
      end
    else
      return
    end
  end
end

-- A new world (handshake, surface change, resync): everything is sent again, and a round of belt
-- items in progress starts over.
function M.far_reset()
  storage.f3d.far = nil
  storage.f3d.bi = nil
  storage.f3d.bl = nil
  storage.f3d.bw, storage.f3d.bt, storage.f3d.bw_dirty, storage.f3d.bc = nil, nil, nil, nil
  pay = nil
  plain_kept = {}
end

return M
