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
--   sent in `sl` with the tick it was read on. (ins_driven: one watched for inserters alone is read
--   only when a hand took or put there, as its inserter's check shows.)
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
local write = require("scripts.belt_sim_write")
local options = require("scripts.belt_sim_options")
local sim_read = require("scripts.belt_sim_read")
local sim_watch = require("scripts.belt_sim_watch")
local sim_scan = require("scripts.belt_sim_scan")

local M = {}
-- Helpers and cold constants kept in one table (Lua 5.2's 200-local limit).
local H = {}
local pays = setmetatable({}, { __mode = "k" })
H.pays = pays

local floor = math.floor
local ceil = math.ceil

-- Lane keys: unit number * LANE_KEYS + line index (a splitter has 8 lines).
local LANE_KEYS = write.LANE_KEYS
local S = write.S
local part_text = write.part_text
local part_bin = write.part_bin
local O = options.O
local ins_driven = options.ins_driven
local UNITS_PER_BUDGET_UNIT = options.UNITS_PER_BUDGET_UNIT
-- Watched lanes unchanged at their last quiet_after checks are checked every quiet_ticks (0: every
-- update), and a watched lane whose items all moved on alike (nothing came or went) isn't sent
-- (skip_flow): the client simulates that. (Fields for tests.)
M.quiet_after = 3
M.quiet_ticks = 12
-- An input spot an inserter or drill uses (an actor, checked itself every update: its hand, its
-- progress) is checked at once when one acted; quiet, it is checked again only every spot_quiet_ticks
-- otherwise, as a safety net. (Fields for tests.)
M.spot_quiet_ticks = 60
-- (ins_driven) An inserter at a belt watched for inserters alone is checked every update, never backed off (false:
-- backed off as the rest; a field for measuring).
M.ins_eager = true
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
-- Work units an update for crossing hints and their id checks (hint_left): their own share, so the
-- extra_units spent on pc_ids, tails and rereads first cannot starve them.
M.hint_units = 400
-- Lanes leading out that only moved on send their wall alone (`ew`).
M.edge_walls = true
-- First loads' units a tick, instead of the budget's share (tests).
M.load_cap = nil
M.settle_around = true
-- Inserters and drills this far outside a chunk can use its belts (a long-handed inserter reaches 2
-- tiles, a big drill drops 3.5 from its centre; modded ones a little more).
H.REACH = 6
-- Work units of ~2 us (as belt_items.lua's): a lane checked (count, front, back, items), a line
-- object, an item read and written, a lane's meta (three positions, its kind), a belt worked out
-- (its neighbours and targets), a belt found or ranked in a scan.
local CHECK_UNITS = 3
local ITEM_UNITS = 4
H.META_UNITS = 4
H.WATCH_UNITS = 6
local TARGET_UNITS = 2
local FIND_UNITS = 5
local SCAN_UNITS = 0.25
local SKIP_UNITS = 0.05
-- First loads take at most this share of the work budget a tick, and at least LOAD_MIN units.
H.LOAD_SHARE = 0.5
H.LOAD_MIN = 400
-- Steady work (checks, re-reads) a tick, at least; spread over the update's ticks from what the
-- last update took. On the due tick what is left is done up to DUE_BURST of that.
M.units_per_tick = 600
H.DUE_BURST = 3
-- A scan is made again whenever the focus moves a tile, anything is built or removed, the radius or
-- cap changes, and at least every SCAN_EVERY updates (belts appearing without an event).
H.SCAN_EVERY = 64
-- Lanes a `bre` may ask for at once.
H.BRE_MAX = 512
-- Lanes asked for again that may wait for their turn (bre_cap) at once.
H.BRE_KEEP = 2048

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
-- they are watched as any other lane (quiet when standing, read when changed). hints (the default, the
-- splitter crossing hints round, with the client's --belt-sim-split-hints): outputs watched as under sim (quiet
-- when standing), but whenever a splitter side's outputs changed, unless its lanes are all packed end to end with
-- one kind of item (split_packed: those the client draws alike whichever way they cross), a few `sx` records go
-- (bs.sx: the items on each output and at each input's front, by unique id; inputs never sent in full); an output
-- packed with mixed items is checked by its ids too, so a packed flow sends its hints and no sl. Hints and those
-- id checks come out of hint_units (their own bounded share, none once the square is cut), and go only to a client
-- that reads them (JSON, or binary wire version 5 or later): the client holds an item a hint still has at an
-- input's front and sends one into the output a hint has it on (docs/BELT-RULES.md section 6: the game's hidden
-- update order). The old way: `/f3d-bs crossings sim` with the client's --belt-sim-split-hints=off.
-- own_rate: the updates follow their own rate.lua job (`bs`: tier 3, at most 12 ticks), so the client's
-- `rate` levels 1-2 (Hold 60 UPS's first steps) leave them at every f3d-detail-interval ticks and level 3
-- doubles them once; off, they follow the glided belt items' job (`bi`: tier 1, 12, 24, 48 ticks), as
-- before, which under Hold 60 UPS read every input spot only once in 24-48 ticks and left the owner's
-- bus with gaps along every lane (rate.lua's top). period_max (the belt-rate round): the longest period
-- `bs` is stretched to under `rate`, in ticks: 6 (the default, the detail interval) means never stretched,
-- every level leaves the updates at 6 ticks; 0 is rate.lua's own max for `bs`, 12 at level 3, as before.
-- Measured live at -62,-26 (Hold 60 UPS, the belt-rate round): 6 ticks at every level gave phantoms 1.7-1.8%
-- in 4 of 5 runs (one 2.4) against 1.9-2.6% in 6 runs at 12 ticks (the owner's gate is 2%), visible 96.1-96.4%
-- either way (the visible gap there isn't the period), for 1-2.5 ms a tick of bridge (bs.watch 2.0-2.3 -> 3.0-3.2)
-- and about 1 UPS (46.3-48.5 against 47.9-48.6 while scored); the alerts' pass (rate.lua `al`) and the client's
-- ladder (its `updates` steps skipped) pay part of it. 0 is the knob for a server that needs the 1-2 ms more.
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
-- The 0.2.1 hotfix's housekeeping (bridge.md change 3; each off: as before): quiet_first: a watched belt
-- whose lanes are all quiet is passed over before its `valid` is read (do_step); watch_nosort: the
-- watched belts' order made without a Lua comparator (number sorts of scan indices, watch_order) and made
-- again only when the watched set, a spot or the scan changed, not whenever any belt loaded; the actors'
-- list walked to its length at the round's start instead of copied (make_queue); scan_step: a new scan
-- when the focus moved max(1, r / 32) tiles (11 at 352) instead of every tile (each scan walks the whole
-- square three times: 7.5 ms an update on laps); far_load_cap: first loads of belts past walk_near get
-- LOAD_MIN units a tick unless the work budget is idle, instead of half of it (0.98 ms a tick on laps,
-- nearly all for belts coming in at the far edge), once the client's square has been loaded whole
-- (b.whole): capped from the join on, a cached join's belts finished loading at 23-27 s instead of 9.6
-- with no better UPS meanwhile (art-src/perf-plans/after.md 2). two_call (on since that measurement: 0.35
-- ms a tick less, as many items drawn): a watched lane's check reads its count and front first, the full
-- check only when either changed (two_call_line). A save that set it keeps its own value (storage.f3d_bs
-- holds only what /f3d-bs set). far_tier (bridge.md change 8; off: it changes when far belts are read): the watched
-- belts and the inserters and drills using belts at far_ring tiles or more from the focus are checked in turn,
-- far_units belt units an update (1200), a cursor carrying on where the last update stopped (far_split), instead of
-- every one every update; within far_ring as before. Far watches skip downstream tail catch-up and `read_runs`,
-- and `bre` asked groups run nearest-first by scan index. The whole square stays loaded and simulated; a far input
-- spot is read every few updates, an actor just before its belt, so one that acted wakes its belt in the same
-- pass.
-- target_spots (on; off: as before): an inserter's or drill's belt is its pickup or drop target when the game
-- has that set and alive, else the belt on the tile of its pickup or drop spot (spot_belt). In 2.1 a drill has
-- no drop_target until it first puts something out (and a replaced target is a dead entity until then), and a
-- chunk's targets are read once and kept (bs.bt), so a drill placed before its belt, or a belt laid or replaced
-- under a drill, was never an input spot: its belt wasn't watched and its items reached the client only when
-- a drift check happened on one and the client asked again (a fresh world: a fifth of a drill's line drawn near
-- the drill, none of it under 650 ms hitches). An actor still without a target at an end is looked at again
-- every RETRY_TICKS (retry_targets), so one whose belt comes without an event is found too.
-- drill_tails (on; off: as before): a drill seen to have put out (its progress gone round) has its drop belt read
-- and the belts that one feeds, as far as an item can have gone since the drill's check before (the tails a changed
-- watched belt gets). A drill's item sits on its drop lane only until it runs off it (21 ticks on a yellow belt from
-- a burner or electric drill's spot) and the progress goes round a tick after the drop, so a check of the drop lane
-- alone found it empty whenever the drill's check came that late after the drop; the drill's period being a whole
-- number of updates, that was every drop of the run, and the client never heard of them but by drift checks.
-- built_now (on; off: as before, K16, K22): a belt built, rotated, replaced or removed is worked out on the next tick
-- (built_now()), not at the next round's scan of the whole square: one built inside the square is loaded there and
-- then (lm, sl, read on that tick), the loaded belts round it read again with it (its feeders and what it feeds,
-- an underground's other end, those forget_touched lists), a removed one's lanes leave (dl), and a loaded belt
-- under a new one whose entity is gone (a fast-replace raises nothing for it) is dropped. Before, a belt built
-- waited for the round's start, then for any scan in progress and a scan of its own, each reading at most
-- SCAN_FINDS chunks a tick whose lists had expired (empty ones too): at a belt item distance of 320 a new belt
-- reached the client 9-200 ticks after it was built, at 640 up to 550, and meanwhile the line it extended stood
-- in Zenith while it ran on in the game. A belt loaded so is kept by the scans that began before it was (it isn't
-- in them); the scan asked for finds it.
-- lane_next (on; off: as before, E31): each lane's `lm` next says whether that lane leads out of what is sent, from
-- the belt its own items leave into (a splitter's output lanes each by their half, found by where they end), and is
-- sent again (lm with sl, on that tick) whenever that changes: when the belt it feeds loads (its next no longer
-- negative) or leaves (negative, in the same tick as that belt's dl), and once a lane's next is found otherwise than
-- the client was told (a look at every drift check, each lane leading out and each watched belt checked: counts
-- next_fix). A lane read twice in one tick sends its meta with the second read too (a reload after a catch-up's read
-- lost its lm: a belt turned or its next changed kept its old meta in Zenith), and reloads a round didn't get to
-- wait for the next round instead of being dropped. Off: a belt leading out had every exit lane -1 (oset); a belt
-- loading read its feeders' lanes without their meta, so the -1 stayed (the chain's first loads leave every fourth
-- ring of a line going outwards loaded before its next, and the square's edge does the same at every step walked),
-- and one leaving had its feeders' -1 sent only at the next round's reload (the lanes said 0 meanwhile).
-- ins_driven (off until measured live; off: as before, the owner's idea): a belt watched for its inserters alone (an
-- inserter's pickup or drop belt, the belt behind a pickup belt; rec[16]: not a drill's drop belt, no splitter, loader,
-- loader's neighbour or circuit) gets no look an update. Its lanes are checked when one of its inserters' checks (the
-- actors', every update) finds the hand's count up (a take: the pickup belt and the belt behind it) or down (a put:
-- the drop belt) and read in full, but for a lane holding items that stands as its last read left it, the belts they
-- feed too as far as an item can have gone since the hand's check before (the tails a changed watched belt gets: an item
-- taken as it left the belt is on the next one in the client's simulation; event_belt), then watched as before for
-- ins_window updates (20; 0: not) or until its lanes settle (the reads while a hole closes up or a put runs on, and the
-- settled read: Zenith's lattice takes a packed lane's motion and phase from the bridge's reads; bs.iwin: unit -> the
-- last update of its window). Offline at 6 updates the busy line-end scene's phantoms were 0.24% (0.16% at 20,
-- 0.07% with the switch off) for about 5% less work. An inserter at such a belt is checked every update (no
-- actor_backoff: a take and a put between two backed-off checks would leave the count as it was). Those belts get
-- drift checks (`pc`) as unwatched ones do: the safety net for what a hand's count doesn't show. Offline, four
-- line-end scenes (tools/belt_line_end.py, every belt in them an inserter's): belt work 39-54% less, lane reads 50-74%
-- fewer; the client's simulation by id 99.86-100% (99.99-100% off); drawn, the game's items seen as often (98.8-99.6%),
-- phantoms 0.06-0.14% -> 0.15-0.21%.
-- The actors' checks are the bridge's own reads (in storage, the same on every peer), not inserters.lua's `ie`
-- events, which are module-local by design. Needs inputs_first (the actors' checks); off under checkpoints (which
-- checks pickup lanes every update). ins_ho (on; only under ins_driven): a put by an inserter inside inserters.lua's
-- square (the detail radius round the focus, no remote view) for a client taking `ie` and `ho` isn't read: the client
-- got the item itself (PLACED, its lane, place and id).
-- quiet_pc (on; off: as before, every unwatched lane's drift check each pc_every updates): an unwatched belt whose
-- drift check found nothing to change since its last (no full read of its lanes, no `bre` for them, nothing built,
-- changed or acting next to it) has its next drift check twice as far off, up to quiet_pc_max ticks (3600, a minute:
-- the owner's safety limit; near or far). Any touch puts it back to every turn (wake): a full read of one of its lanes
-- (asked, run, tail, settle, reload), a watched belt behind it that changed or was put on (its tails' belts), a wired
-- belt behind it switched on or off, a splitter behind it set again (tracker.configure_listeners). Offline a lane
-- nothing touches stays the game's for 30 minutes with no reads at all (belts-quiet-reads-rd); its drift checks were
-- 35-46% of a quiet line's belt work and 77% of its bytes. Kept in the belt's record (storage, game.tick), the same
-- on every peer.
-- near_spool (on; off: as before): belts built, replaced, rotated or removed on a non-`due` tick (`built_now`) emit
-- their live `lm`/`sl`/`dl`/`of` edits straight to the front of `spool` (after any in-progress multi-part update's
-- remaining parts, never splitting an already-started update) and flush within `send_cap` instead of waiting for the
-- next `due` tick, and multi-part `bs` updates pack near-ring belts (<= `walk_near` of `sc.fx, sc.fy`) into earlier
-- parts ahead of outer-ring parts.
-- Walking churn round (/f3d-bs):
-- scan_step_wide (on; off: old max(1, r / 32) step), scan_step_min (12): when scan_step and scan_step_wide are on,
-- uses step = min(max(1, bound_r / 2), max(scan_step_min, r / 12)), reducing full new_scan() cadence while walking
-- without leaving inner visible belts behind. Only scan_step_wide off restores the old r / 32 step (scan_step_min 0
-- clamps to 1 while scan_step_wide is on).
-- drop_margin (16; 0: off): extra ring of tiles past sc.r kept before dropping exiting belts when walking at full square.
-- take_slice (on; off: synchronous drop/prune and load_i = 1): slices take_scan() belt drops and chunk/actor cache
-- pruning across ticks, advances b.load_i past already-loaded inner belts, and derives b.edge from cum[ring] > cap
-- when skipping inner rings so the belt cap (`full_area off`) keeps holding.
-- load_budget (on; off: fixed walk_load / LOAD_MIN): load_limit_now() caps walk_load and far loads by budget.left() headroom with a near floor (200).
-- edge_budget (on; off: single-tick unbudgeted): check_edges() caps and slices edge checks across ticks under budget headroom.
M.OPTIONS = options.OPTIONS
M.OPTION_ORDER = options.OPTION_ORDER
M.OPTION_VALUES = options.OPTION_VALUES

-- `/f3d-bs [name value]`: sets a switch (on/off, a number for bound, `default` for its default) and
-- says them all. Returns the lines to print.
function M.option_command(param)
  return options.option_command(param, M)
end

local function chunk_key(x, y)
  return (floor(x / 32) + 32768) * 65536 + (floor(y / 32) + 32768)
end

-- The tile a place is on, as one number (bs.at).
local function tile_key(x, y)
  return (floor(x) + 2097152) * 4194304 + (floor(y) + 2097152)
end

local function state()
  local s = storage.f3d
  local b = s.bs
  -- (A save from before lanes leading out were kept, or before input spots woke their belts:
  -- everything is sent again.)
  -- (lane_next: or before each belt kept where its lanes' items go, bs.nref.)
  if b and not (b.oset and b.iset and b.actors and b.alist and b.aseen and b.wake and b.bre and b.nref) then
    b = nil
  end
  if not b then
    -- (nref: loaded belts whose lanes' next may have changed (a belt they feed left), their lanes looked at again
    -- before the tick ends: next_refresh.)
    b = { belts = {}, lanes = {}, count = 0, work = 0, wset = {}, cset = {}, oset = {}, iset = {}, bre = {}, reload = {},
      actors = {}, alist = {}, aseen = {}, wake = {}, nref = {} }
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
H.CHUNK_REFRESH = 600
local BELTISH = { ["transport-belt"] = true, ["underground-belt"] = true, ["splitter"] = true, ["lane-splitter"] = true,
  ["loader"] = true, ["loader-1x1"] = true, ["linked-belt"] = true }
local LOADERS = { ["loader"] = true, ["loader-1x1"] = true }
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

-- (target_spots) The belt on the tile of an inserter's pickup spot (drop false) or an inserter's or drill's
-- drop spot, or nil.
local function spot_belt(surface, e, drop)
  local ok, q = pcall(function() return drop and e.drop_position or e.pickup_position end)
  if not (ok and q) then
    return nil
  end
  local x, y = floor(q.x or q[1]), floor(q.y or q[2])
  for _, belt in pairs(surface.find_entities_filtered({ area = { { x + 0.3, y + 0.3 }, { x + 0.7, y + 0.7 } },
      type = registry.belt_types() })) do
    if belt.valid and belt.unit_number and BELTISH[belt.type] then
      return belt
    end
  end
  return nil
end

-- An actor's pickup (drop false) or drop target: the game's when it is set and alive, else (target_spots) the
-- belt on its spot. Second: whether it has none (no target, no belt on the spot: looked at again later); third:
-- whether its spot was looked at (a search: its units).
local function target_of(surface, e, drop)
  local t
  if drop then
    t = e.drop_target
  else
    t = e.pickup_target
  end
  if t and t.valid then
    return t, false, false
  end
  if not O.target_spots then
    return t, false, false
  end
  local belt = spot_belt(surface, e, drop)
  M.counts.spot_looks = (M.counts.spot_looks or 0) + 1
  if belt then
    M.counts.spot_targets = (M.counts.spot_targets or 0) + 1
  end
  return belt, belt == nil, true
end

-- Actors without a target looked at again (retry_targets): every RETRY_TICKS, at most RETRY_MAX a round (the rest
-- the round after). bs.retry: unit -> {entity, chunk key, tick it is due, pickup end open, drop end open};
-- bs.retry_q: due tick -> units (an entry is due on the tick it says: one moved since is passed over there), so a
-- round looks only at the ticks since the last (at -62,-26 the list held 96-250).
H.RETRY_TICKS = 300
H.RETRY_MAX = 64

local function retry_at(b, u, ent, due)
  ent[3] = due
  b.retry = b.retry or {}
  b.retry[u] = ent
  b.retry_q = b.retry_q or {}
  local list = b.retry_q[due]
  if not list then
    list = {}
    b.retry_q[due] = list
  end
  list[#list + 1] = u
end

-- The chunk's belts that inserters and drills take from (2) or put on (1): read once, kept. Those
-- inserters and drills (actors) go in bs.actors: {entity, pickup belt's unit number or false, drop
-- belt's or false, a drill, value at its last check}, listed in bs.alist. (target_spots: those without a
-- target at an end, belt or other, in bs.retry by unit: {entity, chunk key, tick to look again, pickup end
-- open, drop end open}.)
local function targets_of(b, surface, x, y)
  b.bt = b.bt or {}
  local key = chunk_key(x, y)
  local t = b.bt[key]
  if t then
    return t, 0
  end
  -- (t.d: the belts here a drill drops on; t.dv: the list says so, a chunk read before it doesn't. ins_driven.)
  t = { dv = true }
  local x0, y0 = floor(x / 32) * 32, floor(y / 32) * 32
  local found = surface.find_entities_filtered({ area = { { x0 - H.REACH, y0 - H.REACH }, { x0 + 32 + H.REACH, y0 + 32 + H.REACH } },
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
  local spots = O.target_spots
  for _, e in pairs(found) do
    local drill = e.type ~= "inserter"
    local pick, here1 = false, false
    local open_p, looked_p = false, false
    if not drill then
      local pt
      pt, open_p, looked_p = target_of(surface, e, false)
      pick, here1 = mark(pt, 2)
    end
    local dt, open_d, looked_d = target_of(surface, e, true)
    local drop, here2 = mark(dt, 1)
    if drill and here2 then
      t.d = t.d or {}
      t.d[drop] = true
    end
    -- (Units only for the spots looked at: an actor whose targets are set costs what it did.)
    if looked_p then
      units = units + TARGET_UNITS
    end
    if looked_d then
      units = units + TARGET_UNITS
    end
    local u = e.unit_number
    if spots and u then
      if open_p or open_d then
        retry_at(b, u, { e, key, 0, open_p, open_d }, game.tick + H.RETRY_TICKS)
      elseif b.retry then
        b.retry[u] = nil
      end
    end
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

-- (target_spots) The actors bs.retry holds whose look is due: one that has a belt at an end now (laid without
-- an event, or the game set its target since) is taken as touched, so its chunk's targets are read again and
-- the belts round it loaded again next round (forget_touched; a scan too when that belt isn't loaded). One whose
-- ends have targets now, or that is gone, leaves the list (take_scan drops those round chunks the square left).
-- Due ticks in order, units in order in each, so every peer looks at the same ones. Returns the units.
local function retry_targets(b)
  local r, q = b.retry, b.retry_q
  if not (r and q and O.target_spots) then
    return 0
  end
  local now = game.tick
  local from = b.retry_from or now
  b.retry_from = now + 1
  local ticks = {}
  if now - from > H.RETRY_TICKS then
    -- (Rounds missed: every due tick, by the queue's keys.)
    for t in pairs(q) do
      if t <= now then
        ticks[#ticks + 1] = t
      end
    end
    table.sort(ticks)
  else
    for t = from, now do
      if q[t] then
        ticks[#ticks + 1] = t
      end
    end
  end
  if #ticks == 0 then
    return 0
  end
  local surface = world.surface()
  local units, n = 0, 0
  for _, t in ipairs(ticks) do
    local list = q[t]
    q[t] = nil
    table.sort(list)
    for _, u in ipairs(list) do
      local ent = r[u]
      if ent and ent[3] == t then
        if n >= H.RETRY_MAX then
          -- (Past the round's most: the next round.)
          retry_at(b, u, ent, now + 1)
        else
          n = n + 1
          units = units + TARGET_UNITS
          local e = ent[1]
          if not e.valid then
            r[u] = nil
          else
            -- (Only the ends that had no target: one whose other end is a belt already isn't touched again.)
            local open, belt = false, nil
            for x, drop in ipairs({ false, true }) do
              if ent[3 + x] then
                local tg, none = target_of(surface, e, drop)
                units = units + TARGET_UNITS
                ent[3 + x] = none
                open = open or none
                if tg and BELTISH[tg.type] then
                  belt = belt or tg
                end
              end
            end
            if belt then
              -- (A belt not loaded yet came without an event: a scan to find it, as for one built.)
              M.counts.retry_found = (M.counts.retry_found or 0) + 1
              local p = e.position
              b.dirty = b.dirty or {}
              b.dirty[#b.dirty + 1] = { e.surface.index, p.x, p.y, u, not (belt.unit_number and b.belts[belt.unit_number]) }
              r[u] = nil
            elseif open then
              retry_at(b, u, ent, now + H.RETRY_TICKS)
            else
              r[u] = nil
            end
          end
        end
      end
    end
  end
  return units
end

-- tracker.listeners: something was built, changed or removed. Belts, inserters, drills and loaders
-- round it are worked out again on the next tick (a removed one is gone by then).
local function queue_bre(b, q)
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
    if b.scan and #groups > 1 then
      local idx = b.scan.idx
      local gidx = {}
      for _, g in ipairs(groups) do
        local best = math.huge
        for x = 2, #g do
          local j = idx[floor((g[x] - 1) / LANE_KEYS)]
          if j and j < best then
            best = j
          end
        end
        gidx[g] = best
      end
      table.sort(groups, function(a, c)
        local ia, ic = gidx[a], gidx[c]
        if ia ~= ic then
          return ia < ic
        end
        return a[2] < c[2]
      end)
    end
    q[#q + 1] = { 2, groups }
  end
  M.counts.bre_lanes = (M.counts.bre_lanes or 0) + #asked
end

local function queue_drift(b, sc, q)
  if not sc then
    return
  end
  local list = {}
  -- (By bands of rings, each its own stride: drift_far.)
  local bands = O.drift_far and H.DRIFT_BANDS or H.DRIFT_ONE
  -- (ins_driven: a belt watched for its inserters alone gets drift checks, as unwatched ones: the safety net.)
  local driven = ins_driven()
  -- (quiet_pc: an unwatched belt whose checks keep agreeing waits out its rec.qw; due on the last turn before
  -- that would be passed, so a check is never more than qw apart: quiet_due.)
  local quiet, now = O.quiet_pc, game.tick
  for _, band in ipairs(bands) do
    local r0, r1 = band[1], math.min(band[2], sc.top + 1)
    if r0 <= sc.top then
      local j0, j1 = sc.first[r0], sc.first[r1] - 1
      local stride = M.pc_every * band[3]
      local turn = b.count % stride
      for j = j0 + (turn - (j0 - 1)) % stride, j1, stride do
        local unit = sc.units[j]
        local r = b.belts[unit]
        if r and (O.drift_watched or not b.wset[unit] or (driven and r[16])) and not b.oset[unit] and not b.iset[unit] then
          if not (quiet and not b.wset[unit] and not H.quiet_due(r, now)) then
            list[#list + 1] = unit
          end
        end
      end
    end
  end
  if #list > 0 then
    q[#q + 1] = { 4, list }
  end
end

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
  queue_bre(b, q)
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
  -- (far_tier: the near ones every update, the far ones in turn: segment 9, worked in M.tick.)
  local ftier = O.far_tier and b.scan and H.far_split(b, H.watch_order(b))
  if ftier then
    if O.inputs_first and #ftier.near_a > 0 then
      q[#q + 1] = { 7, ftier.near_a }
    end
    if #ftier.near_w > 0 then
      q[#q + 1] = { 3, ftier.near_w }
    end
    if #ftier.units > 0 then
      q[#q + 1] = { 9, ftier.units }
    end
  elseif O.inputs_first and #b.alist > 0 then
    -- (The list as it is now: actors found later in this update wait for the next. watch_nosort: walked
    -- to its length now, not copied; enlist only adds at its end, and a list made anew leaves this one be.)
    if O.watch_nosort then
      q[#q + 1] = { 7, b.alist, #b.alist }
    else
      local list = {}
      for k, unit in ipairs(b.alist) do
        list[k] = unit
      end
      q[#q + 1] = { 7, list }
    end
  end
  profile.stop("bsq.actors", tq)
  tq = profile.start()
  -- Input spots, then the other watched belts, then the outermost ring's (those fed from outside
  -- what is sent are checked on the update's tick: check_edges).
  local w = not ftier and H.watch_order(b) or {}
  if #w > 0 then
    q[#q + 1] = { 3, w }
  end
  -- (ins_driven: the belts a hand took from or put on lately, watched as before for their window, by unit number.)
  if b.iwin and ins_driven() then
    local list = {}
    for u, last in pairs(b.iwin) do
      if b.count > last or not b.belts[u] then
        b.iwin[u] = nil
      else
        list[#list + 1] = u
      end
    end
    table.sort(list)
    if #list > 0 then
      q[#q + 1] = { 3, list }
      M.counts.ins_window = (M.counts.ins_window or 0) + #list
    end
  end
  profile.stop("bsq.sort", tq)
  tq = profile.start()
  local sc = b.scan
  -- (area trace: no outermost ring; every belt leading out of or fed from outside what is loaded is
  -- in bs.oset or bs.iset, checked on the update's tick.)
  if sc and not sc.sel and fr > 0 and sc.first[fr - 1] then
    local ring = {}
    local wset, iset, fe = b.wset, b.iset, O.feed_edges
    -- (ins_driven: a belt watched for its inserters alone is checked on the ring as unwatched ones are.)
    local driven = ins_driven()
    for j = sc.first[fr - 1], (sc.first[fr] or sc.n + 1) - 1 do
      local unit = sc.units[j]
      local r = b.belts[unit]
      if r and not (wset[unit] and not (driven and r[16])) and not iset[unit] then
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
  queue_drift(b, sc, q)
  profile.stop("bsq.drift", tq)
  return q
end

-- An inserter or drill that uses a belt, checked: its hand holding more or less than at its last
-- check, a drill's progress gone round: it took from or put on its belts, which are woken (their
-- lanes checked when their turn comes, never quiet then, packed ones by their ids); under ins_driven a
-- belt watched for inserters alone is read there and then instead (event_belt). Returns the units and
-- the extra units.
local ACTOR_UNITS = 1.5
-- actor_backoff: an inserter whose hand held the same at ACTOR_IDLE checks running is checked every
-- other update, at 2 * ACTOR_IDLE every ACTOR_SKIP'th (a hand that moves again is checked every update
-- from then on); a drill is passed over until about an update before its progress comes round, from
-- how fast it went, at most ACTOR_SKIP updates. a[6]: checks unchanged in a row; a[7]: the update
-- (bs.count) it is checked again at; a[8]: the tick of a drill's last check.
H.ACTOR_IDLE, H.ACTOR_SKIP, H.DRILL_SKIP = 4, 2, 4

-- (ins_driven) Lane i of a belt watched for its inserters alone, after a hand took or put there: read in full, but for
-- a lane holding items that stands as its last read left it (its count, front, back and totals, and its front and back
-- items' ids: a packed one moved a whole gap looks the same otherwise), which the hand left alone. An empty lane is
-- always read: it was empty at its last read too when an item came, was taken and went (the client may hold it).
-- Returns the units and whether it was read.
local function put_told(a)
  if not O.ins_ho then
    return false
  end
  local s = storage.f3d
  local c, f = s.client, s.focus
  if not (c and c.ie and c.ho and f) or s.remote_view then
    return false
  end
  if not a[10] then
    local q = a[1].position
    a[10], a[11] = q.x, q.y
  end
  local r = math.min(settings.global["f3d-detail-radius"].value, f.r or 0)
  return math.abs(a[10] - f.x) <= r and math.abs(a[11] - f.y) <= r
end

local function actor_check(b, unit, period, p)
  local a = b.actors[unit]
  if not a then
    return 0
  end
  local backoff = O.actor_backoff
  -- (ins_driven: an inserter at a belt watched for inserters alone is checked every update: its checks are all that
  -- reads that belt. M.ins_eager false: backed off as the rest, for measuring.)
  local driven = not a[4] and ins_driven()
  if driven and backoff and M.ins_eager then
    local r2, r3 = a[2] and b.belts[a[2]], a[3] and b.belts[a[3]]
    if (r2 and r2[16]) or (r3 and r3[16]) then
      backoff = false
    end
  end
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
            a[7] = b.count + math.min(H.DRILL_SKIP, skip)
          end
        end
      end
      if not a[7] and v == was then
        -- (An inserter's hand or a drill's progress standing: the same backoff.)
        local idle = (a[6] or 0) + 1
        a[6] = idle
        a[7] = idle >= H.ACTOR_IDLE and b.count + H.ACTOR_SKIP or nil
      else
        a[6] = 0
      end
    end
    a[8] = now
    return ACTOR_UNITS
  end
  local prev = a[8] or now
  a[6], a[7], a[8] = 0, nil, now
  M.counts.acted = (M.counts.acted or 0) + 1
  -- (ins_driven: the hand's count up is a take off its pickup belt, down a put on its drop belt. A belt watched for
  -- inserters alone is read now for the end that acted; any other is woken for both, as before.)
  local took, put = v > was, v < was
  local units, extra = ACTOR_UNITS, 0
  local dt = now - prev
  for k = 2, 3 do
    local u = a[k]
    local r = u and b.belts[u]
    if r then
      if driven and r[16] then
        if k == 2 and took then
          M.counts.ins_takes = (M.counts.ins_takes or 0) + 1
          local x1, x2 = H.event_belt(b, u, p, dt)
          units, extra = units + x1, extra + x2
        elseif k == 3 and put then
          if put_told(a) then
            M.counts.ins_told = (M.counts.ins_told or 0) + 1
          else
            M.counts.ins_puts = (M.counts.ins_puts or 0) + 1
            local x1, x2 = H.event_belt(b, u, p, dt)
            units, extra = units + x1, extra + x2
          end
        end
      else
        b.wake[u] = true
      end
      -- (drill_tails: what the drill put out may have run on past its drop belt since its check before.)
      if k == 3 and a[4] and O.drill_tails then
        b.dwake = b.dwake or {}
        b.dwake[u] = math.min(b.dwake[u] or prev, prev)
      end
      -- (A pickup belt's feeder too: a hand chases an item across the belt's back edge. ins_driven: one watched for
      -- inserters alone read on a take.)
      if k == 2 then
        for _, w in ipairs(r[8] or {}) do
          local rw = b.belts[w]
          if rw and rw[12] then
            if driven and rw[16] then
              if took then
                local x1, x2 = H.event_belt(b, w, p, dt)
                units, extra = units + x1, extra + x2
              end
            else
              b.wake[w] = true
            end
          end
        end
      end
    end
  end
  return units, extra
end

H.STEP_NAMES = { "bs.reload", "bs.bre", "bs.watch", "bs.drift", nil, nil, "bs.actor", nil, "bs.far" }
local function step_asked(b, v, p)
  local units, extra, units_of = 0, 0, {}
  for x = 2, #v do
    local key = v[x]
    local unit, i = floor((key - 1) / LANE_KEYS), (key - 1) % LANE_KEYS + 1
    local rec = b.belts[unit]
    if rec and rec[1].valid then
      local lines = H.lines_of(rec[1], unit)
      if lines[i] then
        units = units + H.read_lane(b, rec[1], unit, i, lines, true, p, nil, nil, nil, nil, "asked")
        if not units_of[unit] then
          units_of[unit] = true
          units_of[#units_of + 1] = unit
        end
      end
    else
      units = units + 1
    end
  end
  local far_edge = O.far_tier and b.scan and (tonumber(O.far_ring) or 96) or nil
  local sc_idx = far_edge and b.scan.idx
  local sc_rings = far_edge and b.scan.rings
  for _, unit in ipairs(units_of) do
    local j = sc_idx and sc_idx[unit]
    if O.line_rereads and H.extra_left(b) and not (j and sc_rings[j] >= far_edge) then
      local x = H.read_runs(b, unit, true, true, p)
      H.extra_spend(b, x)
      extra = extra + x
    end
  end
  return units, extra
end

local function step_watch(b, belt, v, rec, p, far)
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
  local lines = H.lines_of(belt, v)
  -- (lane_next: each lane's next as the client was told, looked at too.)
  local units = H.next_check(b, v, p, "next_fix")
  local changed, settled = false, false
  -- (crossings hints: a splitter's outputs as they were, to tell whether they changed.)
  local hint = lines.input > 0 and p and H.hints_active()
  if hint then
    for i = lines.input + 1, #lines do
      H.note_sig(b.lanes[v * LANE_KEYS + i], i)
    end
  end
  for i = 1, #lines do
    local u, ev = H.watch_lane(b, belt, v, i, lines, p)
    units = units + u
    changed = changed or ev == 1 or ev == 3
    settled = settled or ev == 2
  end
  if hint then
    -- (A side whose outputs changed, unless packed with one kind: its hints.)
    local sides = lines.input == 2 and 1 or 2
    for side = 0, sides - 1 do
      local _, _, o0, o1 = H.side_lines(lines, side)
      local moved = H.sig_changed(b.lanes[v * LANE_KEYS + o0], o0) or H.sig_changed(b.lanes[v * LANE_KEYS + o1], o1)
      if moved and not H.split_packed(b, v, lines, side) then
        -- (Under hint_units, their own share: hints never take the round over its bound, cut the square
        -- (bs.cut) or bring belt_lanes and bfar back. None left: the side goes without, as sim.)
        if H.hint_left(b) then
          local u = H.emit_hints(v, side, lines, p)
          H.hint_spend(b, u)
          units = units + u
        else
          M.counts.sx_skipped = (M.counts.sx_skipped or 0) + 1
        end
      end
    end
  end
  -- (Only belts whose every lane can be quiet: not leading out, not fed from outside, no circuit.)
  if not (b.oset[v] or (O.feed_edges and b.iset[v]) or rec[5]) then
    if M.quiet_ticks > 0 then
      due = math.huge
      local qa = M.quiet_after
      for i = 1, #lines do
        local lr = b.lanes[v * LANE_KEYS + i]
        if lr then
          local qt = H.quiet_for(rec, lr)
          if qt > 0 and (lr[7] or 0) >= qa and not (O.checkpoints and H.checkpoint_lane(rec, belt, i, lines)) and not H.crossing_lane(b, v, i, lines) then
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
  -- (ins_driven: a belt in its window whose lanes all settled leaves it.)
  if rec[13] and b.iwin and b.iwin[v] then
    b.iwin[v] = nil
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
  -- (drill_tails: a drill dropping here put out since its check before: the tails back to then.)
  local since = last
  local dsince = b.dwake and b.dwake[v]
  if dsince then
    b.dwake[v] = nil
    since = math.min(since, dsince)
  end
  -- (On this tick, as the lane's own read: a read a tick later would move this one's items. Apart
  -- from the units the steady limit counts, so every input spot is checked first.)
  local extra = 0
  if (changed or dsince) and O.quiet_pc and (rec[11] or t == "splitter" or t == "lane-splitter") then
    -- (quiet_pc: the belts its tails reach woken, read or not: a put or take there runs on into them.)
    H.wake_after(b, v, H.TAIL_DEPTH)
  end
  if not far and (changed or dsince) and M.tails and (rec[11] or t == "splitter" or t == "lane-splitter") and H.extra_left(b) then
    local r0, c0 = M.counts.read, H.set_cause("tail")
    for _, u in ipairs(rec[7] or {}) do
      extra = extra + H.catch_up(b, u, math.max(1, now - since), p, H.CATCH_DEPTH - H.TAIL_DEPTH + 1)
    end
    H.set_cause(c0)
    M.counts.r_tail = (M.counts.r_tail or 0) + M.counts.read - r0
    if dsince and not changed then
      M.counts.r_drill = (M.counts.r_drill or 0) + M.counts.read - r0
    end
  end
  if not far and settled and M.settle_around and (rec[11] or t == "splitter" or t == "lane-splitter") and H.extra_left(b) then
    local r0 = M.counts.read
    extra = extra + H.settle_around(b, v, p)
    M.counts.r_settle = (M.counts.r_settle or 0) + M.counts.read - r0
  end
  H.extra_spend(b, extra)
  if rec[5] then
    local off = H.is_off(belt)
    units = units + 1
    if off ~= (rec[6] or false) then
      M.counts.of = M.counts.of + 1
      -- (quiet_pc: the belts after it start or stop: woken.)
      H.wake_after(b, v, H.TAIL_DEPTH)
      if p then
        p.of[#p.of + 1] = S(v)
        p.of[#p.of + 1] = S(off and 1 or 0)
      end
    end
    rec[6] = off
  end
  if not O.inputs_first then
    return units + extra
  end
  return units, extra
end

local function do_step(b, kind, v, p, period, far)
  if kind == 7 then
    return actor_check(b, v, period, p)
  elseif kind == 2 then
    -- A group of asked lanes, read on this tick with the packed runs round them (while the reads
    -- for accuracy have room).
    return step_asked(b, v, p)
  end
  local rec = b.belts[v]
  if not rec then
    return 1
  end
  local belt = rec[1]
  -- (quiet_first: a watched belt whose every lane is quiet is passed over before its `valid` is read:
  -- one API call per watched belt per update for nothing. One gone without an event is found when its
  -- check comes up. A splitter under crossings game is never passed over whole: below, as before; under sim and
  -- hints one is when all its lanes were quiet (a packed output with mixed items still flowing never is: its
  -- id checks keep it unquiet, watch_lane). A record without its type (rec[14]) counts as a splitter: never
  -- passed over under game.)
  local st = rec[14]
  if kind == 3 and O.quiet_first and (O.crossings ~= "game" or (st ~= nil and st ~= "splitter" and st ~= "lane-splitter")) then
    local due = rec[13]
    if due and game.tick < due and not b.wake[v] then
      M.counts.quiet_belts = (M.counts.quiet_belts or 0) + 1
      rec[9] = game.tick
      return 0.5
    end
  end
  if not belt.valid then
    H.drop_belt(b, v, p)
    return 1
  end
  if kind == 1 then
    return H.load_belt(b, belt, v, rec[2], rec[3], p)
  elseif kind == 3 then
    return step_watch(b, belt, v, rec, p, far)
  end
  return H.drift_check(b, belt, v, p)
end

-- On the update's tick (and across ticks under edge_budget): the lanes leading out of what is sent,
-- checked and read in full where they changed (the client's walls are then where the game's fronts
-- are at the update's tick); every lane of the belts fed from outside it, the same (what came in
-- is then the game's at the update's tick). Returns the units.
do
  local function start_edge_queue(b)
    local fed = {}
    for unit in pairs(O.feed_edges and b.iset or {}) do
      fed[#fed + 1] = unit
    end
    table.sort(fed)
    local list = {}
    for unit in pairs(b.oset) do
      list[#list + 1] = unit
    end
    table.sort(list)
    return { fed = fed, fi = 1, list = list, li = 1, count = b.count }
  end

  local function edge_budget_cap()
    if M.edge_cap then
      return M.edge_cap
    end
    local head = math.max(0, floor(budget.left() * UNITS_PER_BUDGET_UNIT))
    return math.max(H.EDGE_MIN, math.min(H.EDGE_MAX, head))
  end

  function H.edge_step(b, p, cap, spend)
    local q = b.edge_q
    if not q then
      return 0
    end
    if cap == nil then
      cap = edge_budget_cap()
    end
    local units = 0
    local c0 = H.set_cause("edge")
    local t = profile.start()
    while q.fi <= #q.fed and units < cap do
      local unit = q.fed[q.fi]
      q.fi = q.fi + 1
      local rec = b.belts[unit]
      if O.feed_edges and b.iset[unit] and rec and rec[1].valid then
        local belt = rec[1]
        local lines = H.lines_of(belt, unit)
        for i = 1, #lines do
          units = units + H.watch_lane(b, belt, unit, i, lines, p)
        end
        M.counts.feeds = (M.counts.feeds or 0) + 1
      end
    end
    profile.stop("bs.feed", t)
    t = profile.start()
    while q.li <= #q.list and units < cap do
      local unit = q.list[q.li]
      q.li = q.li + 1
      local rec = b.belts[unit]
      if b.oset[unit] and rec and rec[1].valid then
        local belt = rec[1]
        local lines = H.lines_of(belt, unit)
        -- (lane_next: a lane leading out told otherwise is read with its meta first, its wall with it; then only
        -- the lanes leading out, as the client walls only those.)
        units = units + H.next_check(b, unit, p, "next_fix")
        for i = 1, #lines do
          if H.exit_line(belt, i) and (not O.lane_next or H.lane_out(b, rec, unit, i, belt)) then
            units = units + H.watch_lane(b, belt, unit, i, lines, p)
          end
        end
      end
    end
    profile.stop("bs.edge", t)
    H.set_cause(c0)
    if spend and units > 0 then
      budget.spend(units / UNITS_PER_BUDGET_UNIT, "bsedge")
    end
    if q.fi > #q.fed and q.li > #q.list then
      b.edge_q = nil
    else
      M.counts.edge_slices = (M.counts.edge_slices or 0) + 1
    end
    return units
  end

  function H.check_edges(b, p)
    if not O.edge_budget then
      b.edge_q = start_edge_queue(b)
      return H.edge_step(b, p, math.huge, false)
    end
    local cap = edge_budget_cap()
    local units = 0
    if b.edge_q then
      local prev_count = b.edge_q.count
      units = units + H.edge_step(b, p, cap, true)
      if not b.edge_q and prev_count ~= b.count and units < cap then
        b.edge_q = start_edge_queue(b)
        units = units + H.edge_step(b, p, cap - units, true)
      end
      return units
    end
    b.edge_q = start_edge_queue(b)
    return H.edge_step(b, p, cap, true)
  end
end

-- The spool (send_cap): parts waiting to be sent, oldest first, each {head, part number, the part's
-- ranges, the update's tick, the head's numbers for part_bin}. Module-local: only what is sent depends on it, never storage, and a
-- peer that loaded the save mid-update sends less.
local spool = {}
H.SPOOL_LONG = 12

-- Sends the spool's next parts: at least one, then more while the tick's bytes stay under `cap`; with
-- more than SPOOL_LONG parts waiting (updates coming faster than the cap sends them), two at least.
local function spool_step(cap)
  if #spool == 0 then
    return 0
  end
  local bytes, sent = 0, 0
  local bin = transport.binary(2)
  while #spool > 0 do
    local item = spool[1]
    -- (bse.text: the part's text, or its bytes (bse.bin); bse.send: handing it to transport, a datagram
    -- when the batch fills. The part's `k` is its update's tick, not this one's.)
    local te = profile.start()
    local body
    if bin then
      -- (32-bit, else 64-bit when some number doesn't fit, else the text as before.)
      local ok
      ok, body = pcall(part_bin, item[5], item[4], item[2], item[3], 4)
      if not ok then
        ok, body = pcall(part_bin, item[5], item[4], item[2], item[3], 8)
        M.counts.bin_wide = (M.counts.bin_wide or 0) + 1
      end
      if not ok then
        body = nil
        M.counts.bin_text = (M.counts.bin_text or 0) + 1
      end
      profile.stop("bse.bin", te)
    end
    local size
    if body then
      te = profile.start()
      transport.send_frame(transport.KIND_BS, "bs", body)
      size = #body
    else
      te = profile.start()
      local text = part_text(item[1], item[2], item[3])
      profile.stop("bse.text", te)
      te = profile.start()
      transport.send_text_at("bs", item[4], text)
      size = #text
    end
    profile.stop("bse.send", te)
    bytes, sent = bytes + size, sent + 1
    table.remove(spool, 1)
    if bytes >= cap and not (#spool > H.SPOOL_LONG and sent < 2) then
      break
    end
  end
  M.counts.spooled = (M.counts.spooled or 0) + sent
  return bytes
end

-- How many parts wait in the spool (tests).
function M.spooled()
  return #spool
end

-- Writes the update as `bs` parts. Each part's fields are kept as ranges of the update's lists
-- (nothing copied), written straight into the part's text.
local function emit(b, p, period, fr, work, loading, front, cap)
  local parts, head, scalars = write.build_parts(b, p, period, fr, work, loading, options.part_numbers(), O.near_spool, O.walk_near)
  -- (send_cap: the parts join the spool, sent over the ticks from this one; off, all now.)
  if front then
    local ins = 1
    if spool[1] and spool[1][2] > 1 then
      local head_k = spool[1][4]
      while ins <= #spool and spool[ins][4] == head_k and spool[ins][2] > 1 do
        ins = ins + 1
      end
    end
    for k = #parts, 1, -1 do
      table.insert(spool, ins, { head, k, parts[k], game.tick, scalars })
    end
  else
    local n = #spool
    for k = 1, #parts do
      spool[n + k] = { head, k, parts[k], game.tick, scalars }
    end
  end
  spool_step(cap or options.send_cap())
end

-- Whether the next belt to load lies past walk_near (far_load_cap): the near part is all loaded.
H.IDLE_SHARE = 0.75  -- of the budget left for the tick's queues: idle
-- (built_now) The belts touched since the last tick, worked out now: the places forgotten (forget_touched: chunk
-- lists and targets round them, the loaded belts there listed to read again, a scan asked for), each belt removed
-- dropped (dl), each built inside the square loaded (after dropping a loaded belt under it whose entity is gone:
-- a fast-replace), and the loaded belts listed read again with their meta (lm, sl). Up to `cap` units a tick:
-- what is left waits for the next tick (bs.fresh) or the round's queue (bs.reload). Returns the units.
M.built_units = 2400
local function built_now(b, p, cap)
  local fresh = b.fresh
  if not (fresh or b.dirty) then
    return 0
  end
  local units = 0
  if b.dirty then
    units = units + H.forget_touched(b)
  end
  local sc = b.scan
  local si = world.surface().index
  local now = game.tick
  local seen = sc and map.view_filter(true)
  local list, listed = {}, {}
  local function again(u)
    if u and b.belts[u] and not listed[u] then
      listed[u] = true
      list[#list + 1] = u
    end
  end
  local i = 1
  if fresh then
    -- (A belt touched twice since: its last entry.)
    local last = {}
    for k, f in ipairs(fresh) do
      last[f[2]] = k
    end
    while i <= #fresh and units < cap do
      local f = fresh[i]
      local e, u = f[1], f[2]
      if last[u] == i then
        units = units + 1
        if not e.valid then
          if b.belts[u] then
            H.drop_belt(b, u, p)
            M.counts.built_gone = (M.counts.built_gone or 0) + 1
          end
        elseif e.surface.index ~= si then
          -- (Another surface: not this client's square.)
        elseif b.belts[u] then
          again(u)
        elseif sc and not sc.sel then
          -- (area trace: what is loaded follows the trace; the scan asked for decides.)
          local x, y = f[3], f[4]
          local dx, dy = x - sc.fx, y - sc.fy
          local ring = floor(math.max(dx < 0 and -dx or dx, dy < 0 and -dy or dy))
          local lim = math.min(sc.r, b.edge or sc.r)
          if b.scanning and not b.scanning.near then
            local s2 = b.scanning
            local dx2, dy2 = x - s2.fx, y - s2.fy
            local ring2 = floor(math.max(dx2 < 0 and -dx2 or dx2, dy2 < 0 and -dy2 or dy2))
            if ring2 >= math.min(s2.r, b.edge or s2.r) then
              ring = math.huge
            end
          end
          if ring < lim and (not seen or seen(x, y)) then
            -- A loaded belt on its tiles whose entity is gone: what it replaced.
            local box = e.bounding_box
            local at = b.at
            if at then
              for tx = floor(box.left_top.x), math.ceil(box.right_bottom.x) - 1 do
                for ty = floor(box.left_top.y), math.ceil(box.right_bottom.y) - 1 do
                  local v = at[tile_key(tx, ty)]
                  local r = v and v ~= u and b.belts[v]
                  if r and not r[1].valid then
                    H.drop_belt(b, v, p)
                    M.counts.built_replaced = (M.counts.built_replaced or 0) + 1
                  end
                end
              end
            end
            units = units + H.load_belt(b, e, u, x, y, p)
            b.direct = b.direct or {}
            b.direct[u] = now
            M.counts.built_loaded = (M.counts.built_loaded or 0) + 1
            -- Its feeders and what it feeds: their records (what they lead into, what feeds them) and shapes.
            local rec = b.belts[u]
            for _, v in ipairs(rec[7]) do
              again(v)
            end
            for _, v in ipairs(rec[8]) do
              again(v)
            end
          end
        end
        local o = f[5]
        if o and o.valid then
          again(o.unit_number)
        end
      end
      i = i + 1
    end
    if i > #fresh then
      b.fresh = nil
    else
      local rest = {}
      for k = i, #fresh do
        rest[#rest + 1] = fresh[k]
      end
      b.fresh = rest
    end
  end
  -- The loaded belts round the places (and those a drop above made lead out of what is sent), then the rest.
  for _, u in ipairs(b.reload or {}) do
    again(u)
  end
  b.reload = {}
  local k = 1
  while k <= #list and units < cap do
    local u = list[k]
    local rec = b.belts[u]
    if rec then
      if rec[1].valid then
        units = units + H.load_belt(b, rec[1], u, rec[2], rec[3], p)
      else
        H.drop_belt(b, u, p)
      end
    end
    k = k + 1
  end
  for x = k, #list do
    b.reload[#b.reload + 1] = list[x]
  end
  M.counts.built_units = (M.counts.built_units or 0) + units
  return units
end

function M.load_limit_now()
  options.read_options()
  local b = storage.f3d.bs
  return b and H.load_limit_now(b) or 0
end

-- Steady units a tick: spread over the update's ticks from what the last one took.
local function steady_units(b, period)
  return math.max(M.units_per_tick, ceil((b.work or 0) * 1.5 / math.max(1, period - 1)))
end

function M.planned_units()
  options.read_options()
  local b = storage.f3d.bs
  if not b then
    return 0
  end
  local period = rate.period(options.rate_job(), settings.global["f3d-detail-interval"].value, nil, options.rate_cap())
  return floor(steady_units(b, period) / UNITS_PER_BUDGET_UNIT)
end

local function start_round(b, s, r)
  local round = { v = 2, start = game.tick, units = 0, loaded = 0, fast = 0 }
  b.round = round
  pays[s] = H.new_payload(round.start)
  local t0 = profile.start()
  if not O.built_now then
    b.fresh = nil
  end
  round.units = round.units + H.forget_touched(b)
  round.units = round.units + retry_targets(b)
  profile.stop("bsq.forget", t0)
  t0 = profile.start()
  local f = s.focus
  local sc = b.scan
  -- (scan_step: once it moved max(scan_step_min, r / 12) tiles with scan_step_wide, else max(1, r / 32).)
  local step = 1
  if O.scan_step then
    if O.scan_step_wide then
      local smin = math.max(1, floor(tonumber(O.scan_step_min) or 12))
      local bound_r = sc and sc.near and math.min(r, sc.near) or r
      step = math.min(math.max(1, floor(bound_r / 2)), math.max(smin, floor(r / 12)))
    else
      step = math.max(1, floor(r / 32))
    end
  end
  local moved = sc and (math.abs(sc.fx - f.x) >= step or math.abs(sc.fy - f.y) >= step)
  -- (area trace: a scan again when the switch, the near square or the trace's bounds changed.)
  local tr = options.trace_on()
  local retrace = sc and ((tr and (sc.near ~= options.near_now() or sc.tkey ~= options.trace_key())) or (not tr and sc.near ~= nil))
  if not b.scanning and (b.rescan or not sc or moved or retrace or sc.r ~= r or b.count - (b.scan_count or -H.SCAN_EVERY) >= H.SCAN_EVERY or b.cap_was ~= options.cap(M.max_items)) then
    if moved then
      M.counts.scan_moved = M.counts.scan_moved + 1
    elseif b.rescan then
      M.counts.scan_dirty = M.counts.scan_dirty + 1
    end
    b.scanning = H.new_scan(f, r)
    b.rescan, b.scan_count, b.cap_was = nil, b.count, options.cap(M.max_items)
  end
  local te = profile.start()
  local fr0 = H.loaded_edge(b)
  profile.stop("bsq.edge", te)
  round.q, round.i, round.j = make_queue(b, fr0), 1, nil
  profile.stop("bs.queue", t0)
  return round
end

local function finish_round(b, round, q, p, period)
  local r0 = M.counts.read
  round.units = round.units + H.check_edges(b, p)
  M.counts.r_edges = (M.counts.r_edges or 0) + M.counts.read - r0
  local fr = H.loaded_edge(b)
  -- (w: the work but first loads, spread under the work budget's share. ld: lanes inside the square
  -- still to load, or no scan yet.)
  local sc = b.scan
  local edge = sc and math.min(sc.r, b.edge or sc.r)
  local unloaded = sc == nil or fr < edge
  local loading = unloaded or b.scanning ~= nil
  -- (walk_load: the square loaded whole reaches less than walk_near tiles; the trace's own cap on fr
  -- below doesn't count, its traced belts beyond the near square still loading do.)
  b.thin = unloaded and fr < (tonumber(O.walk_near) or 0) or nil
  -- (far_load_cap from here on: this client's square has been loaded whole once. b goes with a handshake,
  -- a resync or a new surface, so each starts uncapped.)
  if not unloaded then
    b.whole = true
  end
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
  options.bound(b, round.units - round.loaded, period, loading, M)
  -- (lane_next: reloads the round didn't get to (its first segment) wait for the next round's; they were dropped,
  -- the lanes keeping their old meta.)
  if O.lane_next and q[1] and q[1][1] == 1 and round.i == 1 then
    local list = q[1][2]
    for j = round.j or 1, #list do
      b.reload[#b.reload + 1] = list[j]
    end
    M.counts.reload_kept = (M.counts.reload_kept or 0) + #list - (round.j or 1) + 1
  end
  b.sq = b.scan and { b.scan.fx, b.scan.fy, fr } or nil
  b.work = round.units - round.loaded - round.fast
end

function M.tick()
  H.pays = pays
  options.read_options()
  write.set_raw(transport.binary(2))
  local s = storage.f3d
  local r = options.radius()
  if r <= 0 then
    s.bs, pays[s] = nil, nil
    spool = {}
    return
  end
  -- (send_cap: the last update's parts still waiting go first, under the cap.)
  local bytes_top = spool_step(options.send_cap())
  local b = state()
  local interval = settings.global["f3d-detail-interval"].value
  local job = options.rate_job()
  local pmax = options.rate_cap()
  local period = rate.period(job, interval, nil, pmax)
  local due = rate.due(job, interval, nil, pmax)
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
    round = start_round(b, s, r)
  end
  local p = H.payload(b)
  local fast = 0
  -- (built_now: belts built, turned, replaced or removed since the last tick, on this tick. Counted as first
  -- loads are, outside the steady work the bound and the next round's share go by.)
  if O.built_now and (b.fresh or b.dirty) then
    local tb = profile.start()
    local built = built_now(b, p, M.built_units)
    profile.stop("bs.built", tb)
    round.units = round.units + built
    round.loaded = round.loaded + built
    if O.near_spool and not due and built > 0 and p and (#p.lm > 0 or #p.sl > 0 or #p.dl > 0 or #p.of > 0) then
      local live = { id = p.id, lm = p.lm, sl = p.sl, qu = p.qu, pc = {}, dl = p.dl, of = p.of, ew = {}, sh = {}, sx = {} }
      p.lm, p.sl, p.qu, p.dl, p.of = {}, {}, {}, {}, {}
      local fr_now = H.loaded_edge(b)
      local sc_now = b.scan
      local edge_now = sc_now and math.min(sc_now.r, b.edge or sc_now.r) or 0
      local unloaded_now = sc_now == nil or fr_now < edge_now
      local cap_left = math.max(1, options.send_cap() - bytes_top)
      emit(b, live, period, fr_now, 0, unloaded_now, true, cap_left)
    end
  end
  local steady = steady_units(b, period)
  local limit = due and steady * H.DUE_BURST or steady
  local spent = 0
  -- The scan (over as many ticks as it takes), then the steady queue.
  if b.scanning then
    local t = profile.start()
    -- (scan_incremental: the scan takes at most SCAN_SHARE of the tick's units, the steady queue the rest; it
    -- took what it needed first before, so a walk's scans held the watched belts' checks back.)
    -- (The first scan, nothing loaded yet, takes it all as before.)
    local scan_limit = O.scan_incremental and b.scan and math.max(64, floor(limit * 0.5)) or limit
    local u, done = H.scan_step(b, b.scanning, scan_limit)
    spent = spent + u
    if done then
      H.take_scan(b, b.scanning, p)
      b.scanning = nil
    end
    profile.stop("bs.scan", t)
  end
  if O.take_slice and (b.drop_q or b.prune) then
    H.prune_step(b, p)
  elseif not O.take_slice and (b.drop_q or b.prune) then
    while b.drop_q or b.prune do
      H.prune_step(b, p)
    end
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
    if kind == 9 then
      -- far_tier: the far actors and watched belts from the cursor on, far_units an update at most, each
      -- once at most an update.
      local ft = b.ft
      local n = ft and ft.units == list and #list or 0
      local cap = tonumber(O.far_units) or 1200
      local tk = profile.start()
      while n > 0 and (round.fdone or 0) < n and (round.fspent or 0) < cap and spent < limit and xtick < xcap do
        local k = ft.i
        if k > n then
          k = 1
        end
        ft.i = k + 1
        local u, x = do_step(b, ft.kinds[k], list[k], p, period, true)
        spent = spent + u
        round.fspent = (round.fspent or 0) + u
        round.fdone = (round.fdone or 0) + 1
        round.extra = (round.extra or 0) + (x or 0)
        xtick = xtick + (x or 0)
        M.counts.far_checks = (M.counts.far_checks or 0) + 1
      end
      profile.stop("bs.far", tk)
      if n == 0 or (round.fdone or 0) >= n or (round.fspent or 0) >= cap then
        round.i, round.j = round.i + 1, nil
      end
    else
      local last = seg[3] or #list
      local j = round.j or 1
      local tk = profile.start()
      while j <= last and spent < limit and xtick < xcap do
        local u, x = do_step(b, kind, list[j], p, period)
        spent = spent + u
        round.extra = (round.extra or 0) + (x or 0)
        xtick = xtick + (x or 0)
        j = j + 1
      end
      profile.stop(H.STEP_NAMES[kind], tk)
      if j > last then
        round.i, round.j = round.i + 1, nil
      else
        round.j = j
      end
    end
  end
  -- First loads beside it, under their share of the work budget (load_limit_now).
  local load_limit = H.load_limit_now(b)
  local tl = profile.start()
  local loaded = H.load_step(b, load_limit, p)
  profile.stop("bs.load", tl)
  budget.spend(loaded / UNITS_PER_BUDGET_UNIT, "bsload")
  round.units = round.units + fast + spent + loaded + (round.extra or 0)
  round.extra = 0
  round.loaded = round.loaded + loaded
  -- (lane_next: the lanes of belts whose next belt left this tick, with their new next in this tick's reads.)
  if O.lane_next and next(b.nref) then
    local tn = profile.start()
    round.units = round.units + H.next_refresh(b, p)
    profile.stop("bs.next", tn)
  end
  if not due then
    if O.edge_budget and b.edge_q then
      local r0 = M.counts.read
      round.units = round.units + H.edge_step(b, p, nil, true)
      M.counts.r_edges = (M.counts.r_edges or 0) + M.counts.read - r0
    end
    return
  end
  -- (What the steady queue didn't get to waits for the next update: the watched belts are listed
  -- again then, the rest of the drift checks come round again.)
  finish_round(b, round, q, p, period)
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
    if j > H.BRE_MAX then
      break
    end
    if type(key) == "number" and key > 0 and key == floor(key) and not b.bre[key] then
      -- (Waiting lanes beyond BRE_KEEP are dropped: the client asks again when it still differs.)
      local queue = b.breq or {}
      b.breq = queue
      if #queue - (b.breh or 1) + 1 < H.BRE_KEEP then
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

-- The square whose far lanes needn't be read (far_lanes, perf.lua): once every belt is loaded out to
-- walk_near and the square isn't cut, the whole square being simulated, {fx, fy, its radius}: the few
-- tiles of its edge still loading while walking don't bring the far ring back (their lanes come within
-- moments, 350 tiles away at the owner's settings). Joining, after a jump, cut by the bound or traced
-- (area trace): the square loaded, as M.square. Nil before the first update.
function M.covered()
  local b = storage.f3d.bs
  local sq = b and b.sq
  if not sq or b.thin or b.cut or O.area == "trace" or not b.scan then
    return sq
  end
  return { sq[1], sq[2], math.max(sq[3], math.min(b.scan.r, options.wanted_radius())) }
end

-- The watched belts in the order they are checked (tests).
function M.watch_list()
  options.read_options()
  local b = storage.f3d.bs
  return b and H.watch_order(b) or {}
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

-- The belts an inserter (or drill) uses, as the actors have them (targets_of): pickup belt's unit
-- number or false, drop belt's or false; nil when it isn't an actor (its belts aren't loaded, or
-- the client doesn't simulate belts). Read-only: inserters.lua says which belt a hand took from.
function M.actor_belts(unit)
  local b = storage.f3d.bs
  local a = b and b.actors and b.actors[unit]
  if not a then
    return nil
  end
  return a[2] or false, a[3] or false
end

-- A new world (handshake, surface change, resync): everything is sent again.
function M.reset()
  storage.f3d.bs = nil
  pays[storage.f3d] = nil
  sim_read.reset()
  sim_watch.reset()
  spool = {}
end

H.CHECK_UNITS = CHECK_UNITS
H.ITEM_UNITS = ITEM_UNITS
H.TARGET_UNITS = TARGET_UNITS
H.FIND_UNITS = FIND_UNITS
H.SCAN_UNITS = SCAN_UNITS
H.SKIP_UNITS = SKIP_UNITS
H.BELTISH = BELTISH
H.LOADERS = LOADERS
H.ACTOR_UNITS = ACTOR_UNITS
H.chunk_key = chunk_key
H.tile_key = tile_key
H.state = state
H.enlist = enlist
H.held_count = held_count
H.drill_progress = drill_progress
H.actor_value = actor_value
H.spot_belt = spot_belt
H.target_of = target_of
H.retry_at = retry_at
H.targets_of = targets_of
H.retry_targets = retry_targets
H.steady_units = steady_units

sim_read.init(M, H)
sim_watch.init(M, H)
sim_scan.init(M, H)

return M
