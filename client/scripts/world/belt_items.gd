extends Node3D
## Items on belts near the camera, run here by Factorio's own belt rules (docs/BELT-SIM-PLAN.md).
## The bridge (belt_sim.lua, `bs`; our hello says `bs`) sends each lane once with its items (`lm`
## meta, `sl` items read on a tick) and afterwards only the lanes something outside the belts
## changed (inserters, drills, splitters, the square's edge, builds), drift checks (`pc`) for the
## rest, belts switched off by circuits (`of`) and lanes no longer sent (`dl`). belt_sim.gd (or its
## C++ twin, when the extension is loaded: the same API) simulates every lane tick by tick from
## that, and says only when an item's motion changes; each change is one record for the GPU.
## (A bridge from before `bs` sends `bi` instead, which this ignores: no items are drawn near.)
##
## A record (belt_records.gd) is where an item is at t0 and where it gets to by t1: in a straight
## line along its lane and the straight lanes ahead of one speed (`run`), else along its lanes'
## points in the paths' texture (curves, undergrounds: hidden where it is under the ground, or still
## behind its lane's back), as far as its motion lasts (`reach`) or MAX_POINTS points; such a record
## is made again from where it is a little before it ends (Item.renew, Job.lead), across where it
## ends, so the next record is there before it is needed. An item going on along a straight run, or
## standing, writes nothing.
##
## The simulation is stepped to where the drawn clock will be when a job's result is drawn and a
## tick on (AHEAD; items are drawn one update behind the game, and `sl` lanes read on later ticks are
## applied when it gets there); what it says happens after the drawn tick waits for the next job, so a
## record starts at or before the drawn clock and nothing shows early.
##
## Splitters' turns can't be read from the game: the simulation learns them from the first
## crossings the bridge reports (a splitter's lanes are watched: the items an output lane is sent
## with tell it where they went, belt_sim.gd's oracle); until then a turn starts at its first output,
## and the bridge sends the output lanes again when they differ.
##
## The hand-over to the far lane icons (belt_lanes.gd) never leaves a belt bare (owner): an item on a
## lane dropped from the square stays, standing, until its chunk's far icons are made (at most
## KEEP_UPDATES jobs), and those icons stay hidden while it does; both change in the frame the job's
## result is drawn, as does the square the icons are hidden in (bs fx, fy, fr).
##
## A stack (a stack inserter puts up to 4 items in one place on a belt) is drawn as a pile: the item
## and up to three copies, each a step higher (the kind's pile_step()) and turned PILE_TURN more, each
## in a slot of its own. Only the item has a record of its motion; a copy's record points at it (texel
## 3) and holds the copy's own turn, written once when the copy is placed, and the shader lifts the
## copy by its step k: a pile that moves costs one record, not four.
##
## The work (decoding, simulating, writing records) runs on a worker thread (Job), on State only the
## job touches while it runs. The main thread queues messages, starts a job, uploads the record
## pages it wrote and gives the kinds' sizes to the MultiMeshes; every frame it only sets the clock.

const ProtoDB := preload("res://scripts/world/protos.gd")
const ItemCards := preload("res://scripts/world/item_cards.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ModelPacks := preload("res://scripts/world/model_packs.gd")
const GameClock := preload("res://scripts/world/game_clock.gd")
const InserterArms := preload("res://scripts/world/inserter_arms.gd")
const MomentHold := preload("res://scripts/world/moment_hold.gd")
const BeltPaths := preload("res://scripts/world/belt_paths.gd")
const BeltRecords := preload("res://scripts/world/belt_records.gd")
const BeltSim := preload("res://scripts/world/belt_sim.gd")
const WireDecode := preload("res://scripts/net/wire_decode.gd")
const ViewPriority := preload("res://scripts/world/view_priority.gd")
const BeltLattice := preload("res://scripts/world/belt_lattice.gd")
const LaneInset := preload("res://scripts/world/belt_lane_inset.gd")
const Probing := preload("res://scripts/debug/probing.gd")
const NativeLibrary := preload("res://scripts/native_library.gd")
const PickUp := preload("res://scripts/world/pick_up.gd")

## The C++ simulation's class (the same API as belt_sim.gd), used when its extension is loaded.
const NATIVE_SIM := "BeltSimNative"
## The C++ records' side of a job (Job._apply_changes to _write; belt_draw_native.cpp), used with the
## C++ simulation when loaded and --belt-draw-native isn't off: the same records as the GDScript path
## (tools/belt_draw_diff.py), at a fraction of the cost (a job at -62,-26 took about a second in GDScript,
## 80% of it planning and writing 60-100k records).
const NATIVE_DRAW := "BeltDrawNative"
## The most a job's lead (Job.lead) is, in ticks: a busy client's jobs (every 30 ticks) had their lead held at 8, so an
## item whose record ended before the next job (a straight run's end at a curve, a curve's exit) stood there up to 22
## ticks and jumped on (the owner's ring, tools/belt_ring.py: 20 jumps a second, 73% of the curve's items off their
## place). --belt-draw-lead-max=8: as before.
const LEAD_LONG := 32.0
const LEAD_OLD := 8.0
static var lead_max := LEAD_LONG
## (--belt-draw-lattice-native) The lattice (belt_lattice.gd) in C++, in the same library.
const NATIVE_LATTICE := "BeltLatticeNative"
## Just above a placeholder belt (0.15 tall), when there is no belt model.
const PLACEHOLDER_HEIGHT := 0.16
## Neighbouring items' cards overlap; at one height they fought over every pixel they share. Each item
## sits a step higher or lower by its id, so an overlap always resolves the same way.
const LAYER_STEP := 0.006
const LAYERS := 4
## Ticks behind one gap behind the game's clock items are drawn at, for messages a frame or two late,
## and for the job that works an update out (the margin grows to the ticks jobs take).
const DRAW_MARGIN := 2.0
const JOB_MARGIN_MAX := 30.0
static var margin_jobs := 1.5
## --inserter-handoff-margin=N (0): with the hand-off, the drawn clock is held N jobs' ticks further behind
## the game, so the job that learns of a take (its event comes a tick or two after it) is drawn before the
## take's tick and the item leaves the belt as the hand closes, not a job later.
static var handoff_margin := 0.0
## --belt-draw-margin=N: the most ticks the drawn clock is held behind the game's for the jobs (the
## margin grows to 1.5 jobs' ticks). 30 as before: a job longer than 20 ticks (a third of a second
## at 60 UPS; -62,-26's take about a second) then ends past the drawn clock, and its records are
## drawn stale, items standing at their ends while the game's go on. 120 (the default): two seconds
## behind at most, the records still fresh when drawn.
static var margin_max := 120.0
## --belt-draw-lead-lag=N (60): the most ticks the drawn clock is held further behind the game than before so
## the simulation's lead covers the job gap (Job.ahead_auto); 0: the lag as before (the lead then only as far
## as the newest update allows, about half a job's ticks). It needs about half a job's ticks and 7 more.
static var lead_lag := 60.0
## --belt-job-high=off: the job goes to the worker pool as a low-priority task, as before. On (the
## default): a high-priority one. Godot gives low-priority tasks a share of the threads (0.3: one on a
## 4-thread PC), which the belt job shares with models' levels of detail, decoratives, terrain and far
## chunks; queued behind them (main's heavier levels of detail and decoratives), a job's result came
## about twice its own time late, the next stepped more ticks, and the drawn clock sat 120 ticks behind.
static var job_high := true
## Tiles from the camera to the items' square within which item models cast shadows, by Settings >
## Graphics > Shadows (sun_shadows.gd QUALITY "items": Low 0, Medium 30, High 45, Ultra 60). It was a
## fixed 16, so items lost their shadows a step out from the closest zoom; now they keep them at the
## default zoom (about 30) from Medium up, a little further on High and Ultra. Past that an item's
## shadow is a pixel or two and every item's triangles go through the shadow pass for it (up to 20,500
## items of about 46 triangles; 0.2.0's 30/45/60/80 had every 3D item cast at the default zoom on Low).
static var shadows_within := 45.0
## Lanes are known this far past the square (an item's line can lead out of it).
const INDEX_MARGIN := 14.0
## The paths' texture: this many points a row, rows a power of two, at most MAX_ROWS (the code in a
## record must stay an exact float).
const PATH_WIDTH := 1024
const MAX_ROWS := 256
## A path's points: this far apart (tiles), at most this many (the code's 64 pieces).
const SPACING := 0.15
const MAX_POINTS := 64
## An item kept outside the square for its chunk's far icons goes after this many jobs anyway.
const KEEP_UPDATES := 40
## (removed_now) A removed belt's lanes are passed over in the bridge's updates this long after (or until its `dl`).
const REMOVED_KEEP_MSEC := 10000
## Items in 3D's cap is worked out again when the square moves, else every this many jobs (a job a frame).
const CAP_EVERY := 30
const MAX_STACK := 4
## A pile's copies turn this much more each (ItemCards.turn_for(unique id, copy): one rule for every
## item, lone or piled, near or far, so a pile never changes as it moves).
const PILE_TURN := ItemCards.PILE_TURN
## Tiles past the Items in 3D cap's edge a model stays a model (no flipping at the edge).
const CAP_SLACK := 1.5
## With the camera leading (view_led): Items in 3D's cap is worked out again once the camera has
## moved this far (tiles) or turned this much (the cosine of about 5 degrees) since.
const VIEW_STEP := 2.0
const VIEW_TURN := 0.996
## A finished job's result waits for the drawn clock to reach its fold tick (within FOLD_SLACK
## ticks), at most HOLD_USEC: drawn sooner, its records would start ahead of the clock.
const FOLD_SLACK := 0.25
const MIN_PACE := 0.25
const HOLD_USEC := 400000
## A lane whose drift check failed is asked for again (`bre`) at most this often (ms).
const ASK_AGAIN_MSEC := 3000
## (--belt-sim-ask=view) A lane the lattice draws whose count is wrong, at most this often (front, back and
## ids drifting on a full lane are what the lattice ignores: never for those alone); one out of the planned
## view this often at first, doubling to ASK_OUT_MAX_MSEC while it keeps failing.
const ASK_LATTICE_MSEC := 30000
const ASK_OUT_MSEC := 12000
const ASK_OUT_MAX_MSEC := 60000
## A tick (or msec) no clock reaches.
const NEVER := 1 << 62
## (park_lat) How far lattice lanes go on past a ring of them (no end ahead).
const LAT_FAR := 1 << 40
## The counters that walk every slot and item (slots in use, those the lattice's mask hides, parked items
## by why) are taken every this many jobs.
const GAUGE_EVERY := 16
## The simulation is stepped this many ticks past where the drawn clock will be (when the updates
## reach that far): a record is written from the motion the simulation has worked out, and an item's
## motion over a tick is only known once that tick is stepped (a lane read, an item put on or moved
## onto another line get their motion when their line is stepped next), so without it such items were
## drawn from their old records until the next job. Changes that start after the drawn tick wait for
## the next job (State.later): the records they replace hold till then. (Job.ahead: --belt-sim-ahead=N.)
const AHEAD := 24
## (ahead_auto) Ticks past the last job gap the simulation runs ahead of the drawn tick at least.
const AHEAD_MARGIN := 6
## (view) Records are written only for items whose motion can show on screen: within this many tiles
## of the camera's ground view (plus the item's reach); the view it was planned for is kept this much
## wider, so a camera panning a little doesn't plan every parked item again each job; and the ground
## the camera sees is taken to end this far from it (a low camera sees to the horizon).
const VIEW_MARGIN := 4.0
const VIEW_KEEP := 10.0
const VIEW_FAR := 160.0
## --belt-draw-view-ground=off: the view is cut VIEW_FAR along each corner ray, as before. On (the
## default): each ray is followed to the ground however far it goes (up to VIEW_GROUND_FAR) and the view
## is cut to the simulated square instead (no simulated item lies outside it). Zoomed out over -62,-26
## (camera 140 tiles out at 40 degrees) the view cut at 160 tiles ended 31 tiles north of the character
## while the screen showed 112. The belts in between are inside the square, where lane icons are left
## out, so they were drawn empty: the mid-range gap, 6.25% of the game's items on screen within the
## 128-tile belt distance (12.4% at 64-96 tiles, 46% at 96-128), 0.09% with it on.
static var view_ground := true
const VIEW_GROUND_FAR := 4000.0
## --belt-draw-view-lead=on: the job's view stretched ahead of the camera's own motion as far as it goes in two
## jobs' time (the job, and its result's time on screen), VIEW_LEAD_MAX tiles at most. Off (the default): the
## camera's ground view as the job starts, as before. Walking close up at -62,-26 (the camera 12 tiles out, the
## character running some 30 tiles a second, jobs of 0.1-1.3 s) the screen's leading edge ran past the records
## planned for it in two runs of three: 1.65% and 2.37% of the game's items on screen had neither an item nor an
## icon (5.6% of those 32-64 tiles out), 0.02% in the third; on, 0.12% and 0.04%. But on, 14-22% more records
## a job and more counted jumps (32 -> 58, 30 -> 49 a second): left off until the gap is caught again.
static var view_lead := false
const VIEW_LEAD_MAX := 48.0
var _lead_pos := Vector2.ZERO
var _lead_usec := 0
var _lead_vel := Vector2.ZERO
## Ticks a job may step at most: further behind, the simulation jumps ahead and every lane is asked
## for again (Job.run()).
const MAX_BEHIND := 180
## And at most once in this many ticks (asking for every lane again makes the next jobs heavier).
const SKIP_EVERY := 600
## Uids remembered for the splitters' turns (the oracle): cleared past this many.
const ORACLE_MAX := 20000
## (probes) How often reads applied after their tick are reported (Job.stale_reads).
const STALE_REPORT_MSEC := 10000


class Item:
	var uid := 0
	var item_id := 0
	var key := 0  # its kind: item_id with its model's variant (Job._model_key), or ItemCards.icon_key() past the Items in 3D cap
	var c := 1.0  # cosine and sine of its turn
	var s := 0.0
	var num := -1  # (turn_id) the number its turn is from (-1: its uid's)
	## Its record: at `from` on tick t_from, `from` + `step` (or along `path`) on t_to, standing after.
	var from := Vector3.ZERO
	var step := Vector3.ZERO
	var t_from := 0.0
	var t_to := 0.0
	var path := PackedFloat32Array()
	var hidden := false  # standing under the ground
	var slot := -1
	var count := 1
	var layers: Array = []
	var code := 0.0
	var code_at := -1
	var path_at := -1  # its run in the paths' texture (State.path_tex), and the run's size
	var path_cap := 0
	var dirty := false
	var stamp := 0
	## Its motion as the simulation last said: on lane `lane` at line position `pos` on tick `t0`,
	## moving `v` (1/256 a tick) at most `reach` along its line.
	var lane := 0
	var pos := 0
	var t0 := 0
	var v := 0
	var reach := 0
	var run := 0  # how far of that its straight run goes
	var renew := -1.0  # the drawn tick at which its record is made again (-1: it lasts)
	var target := Vector3.ZERO  # where its motion record starts (probes)
	var kept := 0
	## (view) Out of the camera's view: its motion is kept, but it has no slot and no record.
	var parked := false
	## (park_lat) Parked because its motion lies on lanes the lattice draws, all along.
	var lat := false
	## (later_tick) Changes of it wait (State.waiting); ver changes whenever anything Job._apply_early reads
	## of it may have.
	var waits := false
	var ver := 0
	## (--inserter-handoff) The tick an inserter's hand took it (its record's texel 3 w: the shader hides it
	## from then, exactly as the hand closes; it goes from the records in the job whose drawn tick is past
	## it, as any item gone), -1 none.
	var hide_at := -1.0
	## (--inserter-handoff) The tick a hand put it on its belt: made at once (the job before), its record's
	## texel 3 w (negative) keeps it hidden till then, so it shows as the hand lets go, not a job later.
	var show_at := -1.0


## A pile's copy: the k'th above its item, in a slot of its own; its record points at the item's.
class Layer:
	var it: Item
	var k := 1
	var slot := -1
	var stamp := 0


## (later_tick) One item's waiting changes in order (from `head`), and when the first was last tried early.
class Waiting:
	var q: Array = []
	var head := 0
	var tried := -2  # the item's ver at the first's last failed try (-1: no item then; -2: not tried)
	var retry_at := NEVER  # (a start waiting for the item's t0) tried again once the drawn tick is there
	var filed := -NEVER  # the tick it was last filed under in State.due


class Kind:
	var slots := []
	var free: Array[int] = []
	var fresh := []
	var emptied: Array[int] = []
	var base := -1
	var cap := 0
	var told := Vector3i(-1, -1, -1)
	var lift := Vector3.ZERO  # item_cards.gd's lift() and pile_step() for this kind, once known
	var pile := 0.07
	var known := false


## Everything the jobs work on. The main thread reads it only while no job runs.
class State:
	var sim: RefCounted
	var items := {}  # unique id -> Item
	var kinds := {}
	var height := PLACEHOLDER_HEIGHT
	var square := Vector3(0.0, 0.0, -1.0)
	var period := 0
	var data_tick := -1  # the newest update's tick
	var last_fold := -1.0  # (ahead_auto) the last job's drawn tick: the gap to this one's is the lead's floor
	## Lane key -> its meta [kind, length, step, x0, y0, xm, ym, x1, y1] and, for curves, its arc
	## [centre x, centre y, radius, angle at 0, angle turned to its length].
	var lanes := {}
	var lanes_raw := {}  # lane key -> its meta as the bridge sent it (lanes holds it moved to lane_inset, belt_lane_inset.gd)
	var lane_inset := LaneInset.DEFAULT
	var arcs := {}
	var records := BeltRecords.new()
	var dirty: Array = []
	var pathed := {}  # Item -> true: drawn along a path
	## The paths' points (the paths' texture): each path in a run of its own, a power of two of points
	## (path_free by size), written when its item's path changes; uploaded when any did.
	var path_tex := PackedFloat32Array()
	var path_top := 0
	var path_free := {}
	var path_dirty := false
	var renewing := {}  # Item -> true: records to make again
	## What happened after the drawn tick, for the next job, in order: changes [0, uid, tick, item,
	## stack, key, pos, speed, reach, run] and items gone [1, uid, tick].
	var later: Array = []
	## (later_tick, --belt-draw-later-tick) The same kept by item (uid -> Waiting) and by tick (tick -> uids
	## whose first waiting change takes effect, or is tried again, then): a job takes only the items filed up
	## to the drawn tick, those whose item changed since their first was tried (retry: uids), or every one when
	## the lanes' links may have moved; the list walked every waiting change every job (half the worker's time
	## at the owner's base, with about 35,000 waiting).
	var waiting := {}
	var due := {}
	## (turn_id) uid -> the simulation's number for the item (belt_sim.gd _num), from its changes.
	var nums := {}
	var retry: Array = []
	var ver_seq := 0
	var later_n := 0
	var lanes_moved := true  # a lane's meta changed, or one was dropped, since the last job
	var links_seen := -1
	## Lanes the lattice draws (its update's lanes added and removed), and for each how far lattice lanes go
	## on past its exit (1/256): an item whose motion ends within that is hidden by the mask all along
	## (park_lat parks it; the counters count it). lat_items: items parked for it.
	var lat := {}
	var lat_ahead := {}
	var lat_ahead_dirty := false
	var lat_items := {}
	## (ask view) Lattice lanes whose checks failed in places or ids alone since last asked (asked the moment
	## they leave the lattice); out-of-view lanes' intervals now (ms).
	var lat_pend := {}
	var out_every := {}
	var jobs_n := 0
	var gauges := [0, 0, 0, 0]  # slots in use, of them on lattice lanes all along, parked out of view, for the lattice
	var kept := {}  # Item -> chunk: kept standing for its chunk's far icons
	var held_chunks := {}
	var asked := {}  # lane key -> msec it was last asked for
	var last_read := {}  # lane key -> its last read's items (`sl`; for `sh`)
	## (replace_at) [tick, lane key]: lanes the bridge dropped (`dl`) in the update that brought a lane of the same
	## place (`lm`, read on that tick): dropped when the simulation reaches that tick, as the new one takes over.
	var drop_at: Array = []
	## (removed_now) Lanes of belts Zenith took away -> msec: the bridge's reads and checks of them still on their
	## way are passed over (they would put the items back till its `dl`), until that `dl` or REMOVED_KEEP_MSEC.
	var removed_keys := {}
	## (--inserter-handoff) The `ie` records handled (each comes a few times): "kind:unit:tick:a" -> tick;
	## and each hand's count as its last record said (a take's size: what a pick added).
	var ie_seen := {}
	var ie_swept := 0
	var hand_count := {}
	var peeks := {}  # Vector2i(inserter, tick) -> PackedInt64Array: the uids its take was guessed to take (Job.peek_u)
	var debug_msec := 0
	var skipped_at := -1000000000
	var capped_square := Vector3(0.0, 0.0, -2.0)
	var cap_jobs := 0
	var capped_at := -2
	var capped_cam := false  # and whether the camera led it, from where, facing which way
	var capped_cam_pos := Vector3.INF
	var capped_cam_dir := Vector3.ZERO
	## (view) The ground rectangle (x, z tiles) the parked items were last judged against: the camera's
	## view grown by VIEW_KEEP; when the view leaves it, the parked items in the new one are planned.
	var planned_view := Rect2()
	var planned_any := false

	## --belt-sim-native=off (and tests): belt_sim.gd even when the C++ one is loaded. Where the C++
	## crashes, belt_sim.gd's twin of the same line stops with a script error and its backtrace instead.
	static var force_gd := false
	## --belt-draw-head-move=off: the simulation's records as they were (belt_sim.gd head_move).
	static var head_move := true
	## --belt-draw-native=off: the job's records made in GDScript (as before) even when BeltDrawNative is
	## loaded. On (the default): `draw` holds the items, kinds, records and paths instead of this State.
	static var draw_native := true
	var draw: RefCounted = null
	## (--belt-draw-lattice) Lanes full of one kind drawn as a lattice: belt_lattice.gd, or its C++ twin
	## (BeltLatticeNative, --belt-draw-lattice-native, the default when loaded with the C++ simulation): the
	## same calls (note_read, note_check, drop, lanes_n, has_drawn), but set_lane for the lanes' meta and
	## update() with the job's values in place of this State.
	var lattice: RefCounted = BeltLattice.new()
	## --belt-draw-lattice-native=off: the lattice made in GDScript (belt_lattice.gd) even when
	## BeltLatticeNative is loaded. On (the default): the C++ twin; GDScript lattice jobs took 25-70 ms a job
	## at -62,-26 (half a second on a replan), 1-3 ms in C++.
	static var lattice_native := true

	func _init() -> void:
		NativeLibrary.ensure()  # a State can be made before Bridge's _ready (belt_items' own, a test's)
		sim = ClassDB.instantiate(NATIVE_SIM) if ClassDB.class_exists(NATIVE_SIM) and not force_gd else BeltSim.new()
		if draw_native and not (sim is BeltSim) and ClassDB.class_exists(NATIVE_DRAW):
			draw = ClassDB.instantiate(NATIVE_DRAW)
			draw.set_sim(sim)
			if draw.has_method("set_small_pages"):
				draw.set_small_pages(BeltRecords.small)
		if lattice_native and not (sim is BeltSim) and ClassDB.class_exists(NATIVE_LATTICE):
			lattice = ClassDB.instantiate(NATIVE_LATTICE)
			lattice.set_sim(sim)
			if lattice.has_method("set_small_pages"):
				lattice.set_small_pages(BeltRecords.small)
			if lattice.has_method("set_item_turns"):
				lattice.set_item_turns(BeltLattice.item_turns)
		# A lane leading nowhere loaded stops its items at its end: at the square's edge the game's are
		# often backed up behind what is outside (a lane that doesn't change is never sent again, and
		# running off would drain it and everything behind it); the bridge sends an edge lane again
		# whenever its items change. One that leads on later (the lane in front loaded since: the first
		# load comes over many updates) is asked for again, as what it held meanwhile was a guess.
		sim.edge_mode = BeltSim.EDGE_STOP
		sim.ask_on_link = true
		sim.head_move = head_move
		sim.read_bound = Job.read_apply
		sim.read_conserve = Job.read_conserve
		sim.read_forward = Job.read_forward
		sim.shift_keep = Job.shift_keep
		sim.read_skip_same = Job.read_skip_same
		sim.take_first = Job.take_first
		# (set(): a library built before the switch has no such property and runs as before.)
		sim.set("take_line", Job.take_line)
		sim.set("take_edge", Job.take_edge)
		sim.set("rescue_seen", Job.rescue_seen)
		sim.set("ug_guard", Job.ug_guard)
		sim.hold_inputs = Job.hold
		sim.split_wake = Job.split_wake
		sim.set("dead_walls", Job.dead_walls)

	## The waiting changes, each item's in its order (tests: the list, or later_tick's by item; an item's
	## own order is all that counts).
	func later_entries() -> Array:
		if waiting.is_empty():
			return later
		var out: Array = []
		for uid in waiting:
			var w: Waiting = waiting[uid]
			out.append_array(w.q.slice(w.head))
		return out


## One job: the messages queued since the last, applied on a worker thread.
class Job:
	var state: State
	var msgs: Array = []
	var fold_tick := 0.0  # where the drawn clock will be when its result is drawn
	## Ticks till the next job's result is drawn, about, and a tick: a record that ends sooner is made
	## again now, and one made goes on at least twice that far (else it would end with nothing after
	## it till the next job).
	var lead := 2.0
	var started_usec := 0
	var done_usec := 0
	var full := false
	var known := {}
	var model_cap := -1
	## The camera drawing, when it leads Items in 3D's cap (view_led, view_priority.gd): its place, facing,
	## and frustum without the far plane. Off: nearest the square's centre, as before. (Not `view`, the
	## camera's ground rectangle the records are planned for.)
	var cam_led := false
	var cam_pos := Vector3.ZERO
	var cam_dir := Vector3.FORWARD
	var cam_planes: Array[Plane] = []
	var watch: Array = []
	var watch_all := false
	var far_built = null  # chunks whose far icons are made (belt_lanes.gd), or null: far icons off
	var now_msec := 0
	# Results
	var began := false
	var last_tick := -1
	var written: Array = []
	var pages := {}
	var clock_base := -1.0
	var records_written := 0
	var unknown: Array = []
	var count := 0
	var positions := {}
	var square := Vector3(0.0, 0.0, -1.0)
	var paths: Image = null
	var usec := 0
	var sim_usec := 0
	var write_usec := 0
	var handle_usec := 0  # decoding and handing the messages to the simulation
	var ticks := 0  # ticks the simulation stepped
	var apply_usec := 0  # the changes made into records (_plan)
	var renew_usec := 0
	var cap_usec := 0
	var changes := 0
	var coalesced := 0  # changes not applied: a later change of the item in the same job (coalesce)
	var early_n := 0  # (early) changes after the drawn tick taken now
	var early_stop_n := 0  # (early_stop) records cut to end at a stop waiting
	var ahead_used := 0  # the lead this job stepped the simulation by (ahead, or the job gap's)
	var renewed := 0
	var skipped := false
	var resend: Array = []
	var unknown_asked := 0  # (ask_unknown) lanes asked for again this job for want of their meta
	var held_chunks := {}
	var dropped := {}  # lane keys dropped in this job (their items may wait for far icons)
	var _plan_depth := 0
	var gone_n := 0
	static var debug := false  # --belt-sim-debug: the simulation's state every 2 s
	## Toggles (read_flags(), docs/RUNNING.md), to compare with the drawing as it was: ticks the
	## simulation runs past the drawn tick (--belt-sim-ahead=N); items gone and changes in the
	## simulation's order (--belt-draw-gone-order=off: changes, then every item gone); records made
	## again before they end, across where they end (--belt-draw-lead=off: when they have ended).
	static var ahead := AHEAD
	## (early; --belt-draw-early=off: as before) A change after the drawn tick that the records can take
	## now without showing anything early is taken now, not held for the next job: a start (the item stands
	## where it starts from, and a record standing there till t0 then moving is just that), or a continuation
	## (the item's record reaches the change's place at its tick at the same speed: a line's end, a ring's
	## cut; the record is made again from where the item is now, across it). Held, the item was drawn
	## standing at the cut (or standing where it started) until the next job's result was drawn, a job
	## later: at -62,-26 a job is about 26 ticks, so items bunched at a loop's cut and jumped 0.8 tile, and
	## a run starting between jobs stood then jumped. The simulation is stepped AHEAD ticks past the drawn
	## tick (never past the newest update) so such changes are known in time.
	static var early := true
	## (early_stop; --belt-draw-early-stop=off: as before) A moving item's record runs on to its line's end
	## (the simulation's reach); a stop after the drawn tick it runs into was held till the next job, so the
	## item was drawn running past the stop and pulled back a job's travel then (on a fast run whose front
	## flows in bursts, batches of items a job). Now the record is cut to end where the stop is: the item
	## stands there from about the stop's tick, and the stop itself waits for its tick as before.
	static var early_stop := true
	## (ahead_auto; --belt-sim-ahead=N for a fixed lead, 24 as before) The simulation runs at least as far
	## past the drawn tick as the last job gap and AHEAD_MARGIN, so what happens before the next job's
	## drawn tick is known in this one (a 24-tick lead under a 30-tick gap left the last ticks' stops and
	## starts to a job late). Never past the newest update's tick, as before: the drawn clock's lag behind
	## the game is the clock's margin's, not this.
	static var ahead_auto := true
	## --inserter-handoff-slack=N (3): with the hand-off, the simulation is stepped at most to N ticks short
	## of the newest update (never short of the drawn tick), so the hands' events for those ticks are in.
	static var handoff_slack := 3
	static var gone_order := true
	static var lead_on := true
	## Reads applied as of their tick (--belt-sim-read-apply=off: as before): a lane's meta takes effect
	## at its first read's tick (BeltSim.set_lane_at), and a read never leaves an item past its line's
	## back end (BeltSim.read_bound). (An update's parts already come to one job together: _flush_parts.)
	static var read_apply := true
	## (--belt-sim-read-conserve=off: as before) reads take off only what the game no longer has
	## between their own items (BeltSim.read_conserve).
	static var read_conserve := true
	## (--belt-sim-read-forward=off: as before) items a read leaves past its line's front go on into the
	## next line (a splitter's output, the next lane) instead of going (BeltSim.read_forward).
	static var read_forward := true
	## (--belt-sim-shift-keep=off: as before) a read's packed-run shift stops at an item it would bring
	## into the lane where the read hasn't it, which stays (BeltSim.shift_keep).
	static var shift_keep := true
	## --belt-sim-read-skip-same=off: a read that finds the lane exactly as the simulation has it is applied
	## all the same, as before (the line rebuilt, every item's record written again). On (the default): it is
	## skipped (BeltSim.read_skip_same); at -62,-26 half the bridge's reads were such, and applying reads was
	## 80% of the simulation's time.
	static var read_skip_same := true
	## --belt-sim-take-first=off: an inserter's take (`ie`) and the read of its lane on the same tick (or a tick or
	## two before the pick's stamp) are applied in the order they came, as before: the read first pushed the
	## taken item back to the start of the belt, and the items behind it (K9). On (the default): the read makes
	## the take first (BeltSim.take_first).
	static var take_first := true
	## --belt-sim-take-line=off: as before, an inserter's take on the tick the bridge read the lanes round it came
	## after those reads, found its belt read and the item moved a step onto the next belt, and did nothing: the
	## taken item stayed and long runs then jumped a quarter tile with every read until they agreed again
	## (K19). On (the default): a tick's takes before its reads, of the item the belt's next read hasn't
	## (BeltSim.take_line).
	static var take_line := true
	## --belt-sim-rescue-seen=off: as before, a read put every item it hasn't behind (or ahead of) its own
	## back out of its lane as one the game's has yet to reach: past the bridge's hands radius (no `ie`) an
	## item an inserter took was put back by each read without it and lived on as a phantom (line-end scene,
	## phantoms 0.72% -> 7.93%). On (the default): not when the lane it would go into was read without it,
	## or it would go behind where it was last read, or after RESCUE_STRIKES rescues (BeltSim.rescue_seen).
	static var rescue_seen := true
	## --belt-sim-take-edge=off: a take looks for its item only on its belt's own lanes, as before: one made
	## late at the belt's front edge found nothing (the item had run on onto the next belt) and the next lane's
	## read put it back at that lane's entry, a phantom. On (the default): past the front edge too, as far as
	## the lanes ran since the take (BeltSim.take_edge).
	static var take_edge := true
	## --belt-sim-ug-guard=off: an underground's hidden lane with no next from the bridge links by geometry like a
	## belt, side-loading onto a belt beside its exit (BeltSim.ug_guard), as before.
	static var ug_guard := true
	## --belt-sim-hold=off: the bridge's `sh` (splitter inputs that stood as their last read left them)
	## ignored. On: such a lane is put back as that read had it and its items don't cross into the
	## outputs until its next read (BeltSim.hold_input).
	static var hold := true
	## --belt-sim-dead-walls=on: a lane leading nowhere in the simulation that the bridge didn't say leads out
	## is walled by two reads finding its front where it was, as a lane leading out (BeltSim.dead_walls). Off
	## (the default): its front runs to its end, as before.
	static var dead_walls := false
	## --belt-sim-split-wake=off: splitters let items through whenever the belt rules say (BeltSim.split_wake).
	static var split_wake := true
	## --belt-sim-ask-unknown=off: a lane read (`sl`) or checked (`pc`) whose meta (`lm`) never came is left
	## out (as before). On: it is asked for again (`bre`, at most every ASK_AGAIN_MSEC), which the bridge
	## answers with its meta. The bridge sends a lane's meta once, when it loads it: an update lost (UDP, or
	## dropped before the world was ready) left such lanes unsimulated for good.
	static var ask_unknown := true
	## --belt-sim-replace-at=off: a lane the bridge drops (`dl`) goes the moment its update comes, as before. On
	## (the default; with read_apply): one dropped in the update that brings a lane of the same place (exit and
	## entry: a belt fast-replaced, say yellow by red, whose items stay where they are in the game) goes at that
	## lane's read tick, when the simulation gets there: before, the update came a few ticks ahead of the
	## simulation, so the replaced belt's items left the simulation then, stood in the drawing and came back on
	## the new lanes at their read, a few ticks further on (K16).
	static var replace_at := true
	var new_geo := {}  # (replace_at) Vector4i(exit, entry) -> the lane key this job's messages set (`lm`) there
	var replaced_n := 0  # (replace_at) lanes dropped on a replacing lane's read tick, not at once, this job
	var removed_lanes_n := 0  # (removed_now) lanes of removed belts taken out this job, and their items
	var removed_items_n := 0
	## --belt-draw-coalesce=off: every change the simulation emitted in the job's ticks is made into a
	## record, one after another (as before). On (the default): only an item's last change at or before
	## the drawn tick is (the earlier ones would be overwritten before anything is drawn); a job that
	## stepped many ticks (the client behind: 258 ticks, 806,000 changes for 65,000 items at -62,-26)
	## applied twelve changes an item and spent 75% of its time doing so.
	static var coalesce := true
	var read_at := {}  # (read_apply) lane key -> the tick of its first read in this job's messages
	## --belt-draw-view=off: every item gets a record wherever it is (as before). On (the default): an
	## item whose motion can't show on screen (its record would lie VIEW_MARGIN tiles and its reach
	## outside the camera's ground view) is parked: its motion kept, no slot, no record, until a change
	## or the camera brings it in (at -62,-26 the camera sees about a tenth of the simulated square).
	static var view_cull := true
	## --belt-draw-pile=off: each copy of a pile gets a full record of its own, written again whenever its
	## item moves (as before). On (the default): a copy's record only points at its item's (texel 3).
	static var pile_one := true
	## --belt-draw-dump-parks=off: the draw dump (--belt-draw-dump) leaves a parked item's record out, as before, so
	## its readers kept drawing the record the GPU had hidden, standing where its motion ended, and counted its next
	## record a jump. On (the default): a park is dumped as the record's going (dump_gone).
	static var dump_parks := true
	## --belt-draw-later-tick=off: the changes after the drawn tick wait in one list (State.later), every one
	## looked at (and tried early) every job, as before. On (the default): kept by item and tick
	## (State.waiting, due): a job takes the items whose first waiting change is due and tries early only those
	## whose item changed since their last try (or all when the lanes' links may have moved); the same takes,
	## item by item, as the list's.
	static var later_tick := true
	## --belt-draw-park-lattice=on: an item whose motion lies on lanes the lattice draws all along (its place
	## and its reach ahead) is parked as one out of view is: its motion kept, no slot, no record (the mask
	## hid it in every frame of that motion). Off (the default for now): drawn and masked, as before.
	static var park_lat := false
	## --belt-sim-ask=view (the default): lanes asked for again by what shows (lattice lanes only when their
	## count is wrong, out of view rarely). Live on the owner's base: 45-75% fewer asks, the job 15-25% cheaper,
	## as many of the game's items drawn and fewer phantoms (art-src/perf-plans/after.md 6).
	## --belt-sim-ask=all: every failing lane every ASK_AGAIN_MSEC, as before.
	static var ask_view := true
	## --belt-sim-ask-near=off: a job's asks in the simulation's order. On (the default): nearest the view's
	## middle first (the bridge reads them in the order asked, bre_cap an update).
	static var ask_near := true
	var view := Rect2()  # the camera's ground view (x, z tiles), from the main thread
	var view_all := true  # no camera (tests, replays): everything is in view
	var parked := 0  # items parked after this job
	var unparked := 0  # items planned again as the view moved
	var first_tick := -1  # the earliest read tick in the job's lanes (for starting the simulation)
	static var _writes := 0
	## (probes) Reads handled after the simulation had passed their tick (applied as if read then), and
	## the most ticks one was late, since the last report (printed every STALE_REPORT_MSEC when any, with
	## --belt-sim-debug).
	static var stale_reads := 0
	static var stale_most := 0
	static var stale_msec := 0
	## --belt-draw-dump=<file>: what each job writes for the GPU, as written (tools/belt_view_check.py
	## scores it against the game): a JSON line per job (its cost and what it took), then the records
	## of the items it wrote (uid, item, count, lane, pos, t0, v, reach as int64; the 16 floats of each record
	## as the GPU gets them), the uids gone, and the paths' texture when it was made again. The main
	## thread writes <file>.apply.jsonl: when each job's result was drawn and where the drawn clock was.
	static var dump: FileAccess = null
	static var dump_apply: FileAccess = null
	static var dump_n := 0
	var dump_no := -1
	var dump_ids := PackedInt64Array()
	var dump_recs := PackedFloat32Array()
	var dump_gone := PackedInt64Array()
	var dump_updates := {}
	var dump_usec := 0
	var dump_paths := PackedFloat32Array()  # the paths' texture when it was made again
	## (--belt-draw-lattice, belt_lattice.gd) its kinds' runs, record pages and mask, for the main thread.
	var lat_written: Array = []
	var lat_pages := {}
	var lat_mask: Image = null
	var lat_lanes := 0
	var lat_usec := 0
	## (--inserter-handoff) What the inserters' takes and puts did in this job's ticks, for the arms:
	## [why (BeltSim.HAND_*), inserter, tick, uid, x, z (the item's place then, tiles; NAN unknown)].
	var hands: Array = []
	## (drop_show_now) Out: [item id, where] for each drop asked to show (`zp`) that lands on a lane drawn, and
	## [item id, the put's tick, where] for each put with no inserter the bridge told (`ie` kind 6, unit 0).
	var drops: Array = []
	var drop_puts: Array = []
	var holes: Array = []  # [lane, tick, line position] of the items taken: their lattice's hole (BeltLattice.hole)
	var _puts := {}  # uid -> tick: the items hands put on belts in this job's changes (Item.show_at)
	## (handoff) The items a take still to come will take (BeltSim.peek_take, as the messages are handled):
	## uid, the take's tick, the inserter. Their records hide on that tick at once (the take itself may come
	## only after the drawn clock passes it); the take on its tick puts right a wrong guess.
	var peek_u := PackedInt64Array()
	var peek_t := PackedInt64Array()
	var peek_i := PackedInt64Array()
	## (--pickup-hide-now) The belt items F took (`pku`, by the game's unique ids): their records hide in this
	## job, as they start flying to the character, not when the drawn clock reaches the take.
	var now_u := PackedInt64Array()
	var ie_n := 0  # `ie` records handed to the simulation (takes, puts)
	var later_n := 0  # State.later.size(), kept.size(), lanes.size() after the job (either path)
	var kept_n := 0
	var lanes_n := 0
	## The lattice's update (run before the records' side): the lanes it began and stopped drawing, its kinds
	## not dressed yet and its dump, merged into this job's after the records' side.
	var lat_add := PackedInt64Array()
	var lat_del := PackedInt64Array()
	var lat_unknown: Array = []
	var lat_dump: Array = []
	## (Counters, belt_items.gd stats: join.belt_stats.) Early tries; items whose waiting changes were looked
	## at (later_tick); asks by why (in view, the lattice's, out of view) and asks not made for their
	## interval; items parked for the lattice and planned again; waiting items; the gauges (State.gauges).
	var early_tries := 0
	var drained := 0
	var ask_view_n := 0
	var ask_lat_n := 0
	var ask_out_n := 0
	var ask_held_n := 0
	var lat_parks := 0
	var lat_unparks := 0
	var lat_lanes_n := 0
	var waiting_n := -1
	var gauges := [0, 0, 0, 0]
	## (A4) The kinds' looks and the far icons' chunks changed since the last job (given to the native
	## records only then).
	var known_new := true
	var far_new := true
	## (later_tick) This job: the lanes' links may have moved since the last; a start waiting for its
	## item's t0 (_apply_early sets it: when to try again).
	var graph_now := true
	var _early_wait := NEVER
	## Lanes dropped in this job's messages, as they were: [meta, arc] (an item parked on the lattice's lanes
	## there stands where it is for the far icons' hand-over).
	var dropped_meta := {}

	func run() -> void:
		var t0 := Time.get_ticks_usec()
		var sim := state.sim
		# (removed_now) Belts Zenith took away: their lanes out of the simulation before anything else, their items
		# gone at the drawn tick (not the simulation's, a lead ahead), their lanes' meta forgotten once drawn.
		var pre := {}
		var rm_keys: Array = []
		if not state.removed_keys.is_empty():
			_prune_removed()
		for msg: Dictionary in msgs:
			if msg.get("t") == "brm":
				for u in msg.get("u", PackedInt64Array()):
					for line in range(1, 9):
						var key := int(u) * 8 + line
						if state.lanes.has(key) and not rm_keys.has(key):
							rm_keys.append(key)
						elif not state.lanes.has(key):
							state.removed_keys[key] = now_msec  # (its meta may still be on its way)
		if not rm_keys.is_empty():
			if int(sim.tick) >= 0:
				pre = _remove_lanes(rm_keys)
			else:
				# (Nothing stepped yet: nothing drawn to take away.)
				for key: int in rm_keys:
					_drop_now(key)
					state.removed_keys[key] = now_msec
				rm_keys = []
		if read_apply:
			_read_ticks()
		for msg: Dictionary in msgs:
			_handle(msg)
		var ts := Time.get_ticks_usec()
		handle_usec = ts - t0
		var t_start := maxi(int(sim.tick), 0)
		if state.data_tick >= 0:
			if int(sim.tick) < 0:
				# (From the first lanes' read tick: the first load is applied exactly.)
				sim.step_to(first_tick if first_tick >= 0 else state.data_tick)
			# Up to where the drawn clock will be and AHEAD, never past the newest update's tick. Too far behind
			# (a slow PC, a stall): a job would step ever longer stretches and fall further behind each
			# time; the simulation jumps there instead, its items standing, and every lane is asked for
			# again (in the bridge's next updates).
			var lead_t := ahead
			if ahead_auto and state.last_fold >= 0.0 and fold_tick > state.last_fold:
				lead_t = maxi(ahead, ceili(fold_tick - state.last_fold) + AHEAD_MARGIN)
			ahead_used = lead_t
			if fold_tick >= 0.0:
				state.last_fold = fold_tick
			var to := mini(floori(fold_tick) + lead_t, state.data_tick)
			if handoff_slack > 0 and InserterArms.wants_handoff():
				# (--inserter-handoff) A few ticks short of the newest update, never short of the drawn tick:
				# the hands' events for those ticks (`ie`, every 2 ticks, each sent again twice) come after
				# the update that covers them as often as before it, and a take the simulation learns after
				# stepping past its tick goes from the drawing only a job late.
				to = maxi(mini(to, state.data_tick - handoff_slack), mini(floori(fold_tick) + 1, state.data_tick))
			if to - int(sim.tick) > MAX_BEHIND and int(sim.tick) >= 0 and to - state.skipped_at > SKIP_EVERY:
				state.skipped_at = to
				for e: Array in state.drop_at:
					_drop_now(int(e[1]))
				state.drop_at = []
				sim.skip_to(to)
				skipped = true
				for key in state.lanes:
					resend.append(key)
			elif to > int(sim.tick):
				_step_to(to)
		ticks = int(sim.tick) - t_start
		var ch: Dictionary = sim.take_changes()
		if not pre.is_empty():
			ch = _merge_changes(pre, ch)
		if not peek_u.is_empty():
			ch["peek_uid"] = peek_u
			ch["peek_tick"] = peek_t
			ch["peek_ins"] = peek_i
		if not now_u.is_empty():
			ch["now_uid"] = now_u
		sim_usec = Time.get_ticks_usec() - ts
		_take_holes(ch)
		# (The lattice first: the records' side parks and counts the items on the lanes it draws.)
		if BeltLattice.on or state.lattice.has_drawn():
			_lattice()
		if state.draw != null:
			_run_native(ch)
			_hands(ch, false)
		else:
			var ta := Time.get_ticks_usec()
			graph_now = state.lanes_moved or int(sim.links_ver) != state.links_seen or sim.links_pending()
			state.lanes_moved = false
			var view_moved := _set_view()
			_relattice()
			_apply_changes(ch)
			_hands(ch, true)
			if view_moved:
				_replan_parked()
			var tr := Time.get_ticks_usec()
			apply_usec = tr - ta
			_renew()
			renew_usec = Time.get_ticks_usec() - tr
			_keep_or_drop()
			if known_new or model_cap != state.capped_at or (model_cap >= 0 and (state.square != state.capped_square or state.cap_jobs >= CAP_EVERY or _cam_moved())):
				state.capped_square = state.square
				state.capped_at = model_cap
				state.capped_cam = cam_led
				state.capped_cam_pos = cam_pos
				state.capped_cam_dir = cam_dir
				state.cap_jobs = 0
				var tc := Time.get_ticks_usec()
				_cap_models()
				cap_usec = Time.get_ticks_usec() - tc
			state.cap_jobs += 1
			var tw := Time.get_ticks_usec()
			_write()
			write_usec = Time.get_ticks_usec() - tw
			state.links_seen = int(sim.links_ver)
			# (Walking every item in GDScript costs; only for probes here.)
			if state.jobs_n % GAUGE_EVERY == 0 and (Probing.on or dump != null):
				_gauges()
			state.jobs_n += 1
			gauges = state.gauges.duplicate()
			count = state.items.size()
			held_chunks = state.held_chunks.duplicate()
			var now_t := floori(fold_tick)
			for uid in (state.items.keys() if watch_all else watch):
				var it: Item = state.items.get(uid)
				if it == null:
					continue
				if it.lat:
					# (Parked on the lattice's lanes: no record; where its motion has it, in a straight line.)
					var d := mini(it.v * (now_t - it.t0), it.reach) if it.v > 0 and now_t > it.t0 else 0
					var a := _advance(it.lane, it.pos, d) if d > 0 else Vector2i(it.lane, it.pos)
					var q := _point(a.x, a.y)
					var from := Vector3(q.x, q.y, q.z)
					var step := Vector3.ZERO
					var t_to := float(now_t)
					if it.v > 0 and it.reach > d:
						var b := _advance(it.lane, it.pos, it.reach)
						var r := _point(b.x, b.y)
						step = Vector3(r.x, r.y, r.z) - from
						t_to = float(it.t0) + float(it.reach) / float(it.v)
					positions[uid] = [from, step, PackedFloat32Array(), float(now_t), t_to, false]
				else:
					positions[uid] = [it.from, it.step, it.path, it.t_from, it.t_to, it.hidden]
			later_n = state.later_n if later_tick else state.later.size()
			waiting_n = state.waiting.size() if later_tick else -1
			lat_lanes_n = state.lat.size()
			kept_n = state.kept.size()
			lanes_n = state.lanes.size()
			if dump != null and paths != null:
				dump_paths = state.path_tex
		_lattice_merge()
		if not rm_keys.is_empty():
			_forget_lanes(rm_keys)
		square = state.square
		if debug and stale_reads > 0 and now_msec - stale_msec > STALE_REPORT_MSEC:
			stale_msec = now_msec
			print("belt-sim: %d lane reads applied after their tick (at most %d ticks late; read apply %s)" % [stale_reads,
				stale_most, "on" if read_apply else "off"])
			stale_reads = 0
			stale_most = 0
		if debug and now_msec - state.debug_msec > 2000:
			state.debug_msec = now_msec
			print("belt-sim: tick %d data %d fold %.1f, lanes %d, %s, items %d, changes %d, gone %d, asked %d, kept %d%s" % [
				int(state.sim.tick), state.data_tick, fold_tick, lanes_n, state.sim.stats(), count,
				changes, gone_n, resend.size(), kept_n, "" if state.draw == null else " (native draw)"])
			if state.sim.has_method("debug_links"):
				print("belt-sim: links %s" % [state.sim.debug_links()])
		clock_base = state.records.base
		usec = Time.get_ticks_usec() - t0
		if dump != null:
			_dump_write()

	## (--belt-draw-lattice) The packed lanes' lattice after the simulation (belt_lattice.gd): the same for
	## both records paths, which it runs before (its lanes added and removed go to them: lat_add, lat_del).
	func _lattice() -> void:
		if int(state.sim.tick) < 0 or state.records.base < 0.0:
			return
		var tl := Time.get_ticks_usec()
		# (The holes' records go to the dump with the lattice's own, after the records side's: written to the
		# job's dump here they were lost when that side set its own, and a dump showed no take's hole.)
		var hole_ids := PackedInt64Array()
		var hole_recs := PackedFloat32Array()
		# (The C++ lattice's switches before its holes: close and settle say what a take does.)
		if not (state.lattice is BeltLattice) and state.lattice.has_method("set_close"):
			state.lattice.set_settle(BeltLattice.settle)
			state.lattice.set_close(BeltLattice.close)
			state.lattice.set_mask_inner(BeltLattice.mask_inner)
			if state.lattice.has_method("set_mask_own"):
				state.lattice.set_mask_own(BeltLattice.mask_own)
			if state.lattice.has_method("set_mask_open"):
				state.lattice.set_mask_open(BeltLattice.mask_open)
			if state.lattice.has_method("set_handover"):
				state.lattice.set_handover(BeltLattice.handover)
			if state.lattice.has_method("set_turn_id"):
				state.lattice.set_turn_id(BeltLattice.turn_id)
				state.lattice.set_edge_shut(BeltLattice.edge_shut)
			state.lattice.set_sim_full(BeltLattice.sim_full)
			if state.lattice.has_method("set_tail"):
				state.lattice.set_tail(BeltLattice.tail)
			if state.lattice.has_method("set_start"):
				state.lattice.set_start(BeltLattice.start)
				state.lattice.set_start_stops(BeltLattice.start_stops)
		for h: Array in holes:
			var hr: Dictionary = state.lattice.hole(int(h[0]), int(h[1]), int(h[2]), dump != null)
			if dump != null:
				hole_ids.append_array(hr["dump_ids"])
				hole_recs.append_array(hr["dump_recs"])
		var lr: Dictionary
		# (When these records are first drawn: a lane's items are matched to the old lattice's as drawn then.)
		if state.lattice is BeltLattice:
			state.lattice.shown = fold_tick
		elif state.lattice.has_method("set_shown"):
			state.lattice.set_shown(fold_tick)
		if state.lattice is BeltLattice:
			state.lattice.drawn_tick = floori(fold_tick)
			lr = state.lattice.update(state, state.sim, int(state.sim.tick), view, view_all, known, model_cap, full, dump != null)
		else:
			# (A library built before the switch has no such method and runs as before.)
			if state.lattice.has_method("set_settle"):
				state.lattice.set_settle(BeltLattice.settle)
				state.lattice.set_drawn_tick(floori(fold_tick))
			if state.lattice.has_method("set_creep"):
				state.lattice.set_creep(BeltLattice.creep)
			if state.lattice.has_method("set_creep_flow"):
				state.lattice.set_creep_flow(BeltLattice.creep_flow)
			if state.lattice.has_method("set_creep_step"):
				state.lattice.set_creep_step(BeltLattice.creep_step)
			lr = state.lattice.update(int(state.sim.tick), view, view_all, known, model_cap, full, dump != null, state.records.base,
				state.height, BeltLattice.on, BeltLattice.world, BeltLattice.piles, BeltLattice.unison, BeltLattice.world_all,
				BeltLattice.standing_obs)
		lat_written = lr["written"]
		lat_pages = lr["pages"]
		lat_mask = lr["mask"]
		lat_lanes = state.lattice.lanes_n
		lat_add = lr.get("added", PackedInt64Array())
		lat_del = lr.get("removed", PackedInt64Array())
		lat_unknown = lr["unknown"]
		if dump != null:
			# (A lane's slots written again in the update come after its holes: the newer record stands; a
			# hole in a lane the update stopped drawing isn't written: its slot went with the lane.)
			var went := {}
			for u in (lr["dump_gone"] as PackedInt64Array):
				went[u] = true
			var ids := PackedInt64Array()
			var recs := PackedFloat32Array()
			for k in hole_ids.size() / 8:
				if not went.has(hole_ids[k * 8]):
					ids.append_array(hole_ids.slice(k * 8, k * 8 + 8))
					recs.append_array(hole_recs.slice(k * BeltRecords.FLOATS, (k + 1) * BeltRecords.FLOATS))
			ids.append_array(lr["dump_ids"])
			recs.append_array(lr["dump_recs"])
			lat_dump = [ids, recs, lr["dump_gone"]]
		lat_usec = Time.get_ticks_usec() - tl

	## The lattice's kinds not dressed yet and its dump, after the records side's (in that order, as when the
	## lattice ran after it).
	func _lattice_merge() -> void:
		for kk in lat_unknown:
			if not unknown.has(kk):
				unknown.append(kk)
		if dump != null and not lat_dump.is_empty():
			dump_ids.append_array(lat_dump[0])
			dump_recs.append_array(lat_dump[1])
			dump_gone.append_array(lat_dump[2])

	## (--belt-draw-native) The job from the changes on in BeltDrawNative (belt_draw_native.cpp: the same
	## as _set_view .. _write below, item for item); its results into this job's fields.
	func _run_native(ch: Dictionary) -> void:
		var params := {"fold": fold_tick, "lead": lead, "now_msec": now_msec, "full": full, "model_cap": model_cap,
			"square": state.square, "base": state.records.base, "height": state.height, "dump": dump != null,
			"coalesce": coalesce, "view_cull": view_cull, "lead_on": lead_on, "gone_order": gone_order, "early": early, "early_stop": early_stop,
			"view_all": view_all, "view": view, "watch": watch, "watch_all": watch_all,
			"pile_one": pile_one, "dump_parks": dump_parks, "cam_led": cam_led, "cam_pos": cam_pos, "cam_dir": cam_dir, "cam_planes": cam_planes,
			"later_tick": later_tick, "park_lat": park_lat, "ask": 1 if ask_view else 0, "ask_near": ask_near,
			"lat_add": lat_add, "lat_del": lat_del, "turn_id": BeltLattice.turn_id and BeltLattice.item_turns}
		# (The looks and the far icons' chunks only when they changed: the native side keeps the last.)
		if known_new:
			params["known"] = known
		if far_new:
			params["far_built"] = far_built
		var res: Dictionary = state.draw.run_job(ch, params)
		apply_usec = int(res.get("apply_usec", 0))
		renew_usec = int(res.get("renew_usec", 0))
		cap_usec = int(res.get("cap_usec", 0))
		write_usec = int(res.get("write_usec", 0))
		written = res.get("written", [])
		unknown = res.get("unknown", [])
		records_written += int(res.get("records_written", 0))
		changes = int(res.get("changes", 0))
		coalesced = int(res.get("coalesced", 0))
		early_n = int(res.get("early", 0))
		early_stop_n = int(res.get("early_stop", 0))
		renewed = int(res.get("renewed", 0))
		gone_n = int(res.get("gone_n", 0))
		parked = int(res.get("parked", 0))
		unparked = int(res.get("unparked", 0))
		resend.append_array(Array(res.get("resend", PackedInt64Array())))
		positions = res.get("positions", {})
		held_chunks = res.get("held_chunks", {})
		count = int(res.get("count", 0))
		kept_n = int(res.get("kept", 0))
		later_n = int(res.get("later", 0))
		lanes_n = int(res.get("lanes", 0))
		early_tries = int(res.get("early_tries", 0))
		drained = int(res.get("drained", 0))
		waiting_n = int(res.get("waiting", -1))
		ask_view_n = int(res.get("ask_view", 0))
		ask_lat_n = int(res.get("ask_lat", 0))
		ask_out_n = int(res.get("ask_out", 0))
		ask_held_n = int(res.get("ask_held", 0))
		lat_parks = int(res.get("lat_parks", 0))
		lat_unparks = int(res.get("lat_unparks", 0))
		lat_lanes_n = int(res.get("lat_lanes", 0))
		gauges = [int(res.get("slots", 0)), int(res.get("slots_hidden", 0)), int(res.get("parked_view", 0)),
			int(res.get("parked_lat", 0))]
		paths = res.get("paths")
		pages = res.get("pages", {})
		if dump != null:
			dump_ids = res.get("dump_ids", PackedInt64Array())
			dump_recs = res.get("dump_recs", PackedFloat32Array())
			dump_gone = res.get("dump_gone", PackedInt64Array())
			dump_paths = res.get("path_tex", PackedFloat32Array())

	## (view) The ground the records are planned for: the camera's view grown by VIEW_KEEP, set again when
	## the view leaves it. Returns whether it was set again (the parked items are looked at then).
	func _set_view() -> bool:
		if not view_cull or view_all:
			return false
		if state.planned_any and state.planned_view.encloses(view):
			return false
		state.planned_view = view.grow(VIEW_KEEP)
		state.planned_any = true
		return true

	## (view) Whether an item at line position `pos` of lane `key` with `reach` to go can show in the
	## planned view.
	func _in_view(key: int, pos: int, reach: int) -> bool:
		if not view_cull or view_all:
			return true
		var p := _point(key, float(pos))
		return state.planned_view.grow(VIEW_MARGIN + float(maxi(reach, 0)) / 256.0).has_point(Vector2(p.x, p.z))

	## (lattice) Whether a motion from line position `pos` of lane `key` over `reach` stays on lanes the
	## lattice draws: the lanes ahead of its lane's exit that the lattice draws go on that far.
	func _on_lat(key: int, pos: int, reach: int) -> bool:
		var ahead = state.lat_ahead.get(key)
		return ahead != null and maxi(reach, 0) <= pos + int(ahead)

	## Why an item's motion isn't drawn: 0 it is, 1 out of the planned view, 2 (park_lat) on the lattice's lanes
	## all along, so its mask hides it there anyway.
	func _hide_why(key: int, pos: int, reach: int, v: int) -> int:
		if not _in_view(key, pos, reach):
			return 1
		if park_lat and not state.lat_ahead.is_empty() and _on_lat(key, pos, reach if v > 0 else 0):
			return 2
		return 0

	func _set_lat(it: Item, on: bool) -> void:
		if it.lat == on:
			return
		it.lat = on
		if on:
			state.lat_items[it] = true
		else:
			state.lat_items.erase(it)

	## (later_tick) Something _apply_early reads of the item may have changed: its waiting changes are tried again.
	func _touch(it: Item) -> void:
		state.ver_seq += 1
		it.ver = state.ver_seq
		if it.waits:
			state.retry.append(it.uid)

	func _park(it: Item) -> void:
		if it.slot >= 0:
			# (dump_parks) Its record hidden, as the GPU's: the draw dump says so (as gone), so what reads it
			# (tools/belt_view_check.py's DrawState) doesn't keep drawing the old record until the next one.
			if dump != null and dump_parks:
				dump_gone.append(it.uid)
			_unplace(it)
		it.parked = true
		it.renew = -1.0
		state.renewing.erase(it)
		it.path = PackedFloat32Array()
		_mark(it)  # (its path's run is let go)
		_touch(it)

	func _unpark(it: Item) -> void:
		it.parked = false
		_set_lat(it, false)
		_place(it)
		var n := it.count
		it.count = 1
		_set_count(it, n)
		_touch(it)

	## (view) The view moved: parked items now in it get their records, from where their motion has them.
	func _replan_parked() -> void:
		var now := floori(fold_tick)
		for it: Item in state.items.values():
			if not it.parked:
				continue
			var d := mini(it.v * (now - it.t0), it.reach) if it.v > 0 and now > it.t0 else 0
			var at := _advance(it.lane, it.pos, d) if d > 0 else Vector2i(it.lane, it.pos)
			var why := _hide_why(at.x, at.y, it.reach - d, it.v)
			if why != 0:
				_set_lat(it, why == 2)
				continue
			if d > 0:
				it.lane = at.x
				it.pos = at.y
				it.reach -= d
				var m: PackedInt32Array = state.lanes.get(it.lane, PackedInt32Array())
				it.run = it.pos + int(state.sim.run_of(it.lane)) if not m.is_empty() and m[0] == BeltSim.STRAIGHT else 0
				it.t0 = now
			_unpark(it)
			_plan(it)
			unparked += 1

	## The lattice's update (run before this) added and removed lanes (lat_add, lat_del): how far lattice
	## lanes go on past each worked out again; (ask view) lanes leaving it whose checks failed in places alone
	## asked for now; (park_lat) items no longer on its lanes all along planned again from their motion as
	## _replan_parked does (an item on a lane dropped from the square stands where it is, for the far icons'
	## hand-over), and placed items now on them all along let go of their slots. With graph_now (the lanes'
	## links may have moved) every lane is looked at.
	func _relattice() -> void:
		for key in lat_del:
			state.lat.erase(key)
		for key in lat_add:
			state.lat[key] = true
		var changed := not lat_add.is_empty() or not lat_del.is_empty()
		if not changed and not (graph_now and not state.lat.is_empty()):
			return
		state.lat_ahead_dirty = true  # (worked out when parking or the counters need it)
		for key in lat_del:
			if state.lat_pend.has(key):
				state.lat_pend.erase(key)
				if not state.lat.has(key) and state.lanes.has(key) and not dropped.has(key):
					state.asked[key] = now_msec
					resend.append(key)
					ask_lat_n += 1
		if not park_lat:
			return
		_lat_ahead()
		var now := floori(fold_tick)
		if not lat_del.is_empty() or graph_now:
			for it: Item in state.lat_items.keys():
				if dropped.has(it.lane) or dropped_meta.has(it.lane):
					_stand_dropped(it, now)
					continue
				var d := mini(it.v * (now - it.t0), it.reach) if it.v > 0 and now > it.t0 else 0
				var at := _advance(it.lane, it.pos, d) if d > 0 else Vector2i(it.lane, it.pos)
				var why := _hide_why(at.x, at.y, it.reach - d, it.v)
				if why == 2:
					continue
				_set_lat(it, false)
				if why == 1:
					continue  # (out of view: parked as anything out of it is)
				if d > 0:
					it.lane = at.x
					it.pos = at.y
					it.reach -= d
					var m: PackedInt32Array = state.lanes.get(it.lane, PackedInt32Array())
					it.run = it.pos + int(state.sim.run_of(it.lane)) if not m.is_empty() and m[0] == BeltSim.STRAIGHT else 0
					it.t0 = now
				_unpark(it)
				_plan(it)
				lat_unparks += 1
		if not lat_add.is_empty() or graph_now:
			var cand: Array[Item] = []
			for kk in state.kinds:
				for e in (state.kinds[kk] as Kind).slots:
					if e is Item and not (e as Item).parked and state.lat.has((e as Item).lane):
						cand.append(e)
			for it: Item in cand:
				var d := mini(it.v * (now - it.t0), it.reach) if it.v > 0 and now > it.t0 else 0
				var at := _advance(it.lane, it.pos, d) if d > 0 else Vector2i(it.lane, it.pos)
				if not _on_lat(at.x, at.y, it.reach - d if it.v > 0 else 0):
					continue
				_park(it)
				_set_lat(it, true)
				lat_parks += 1

	## For each lane the lattice draws, how far (1/256) lattice lanes go on past its exit: its next's length
	## and that one's own, to the first lane that isn't the lattice's (a ring of them: LAT_FAR).
	func _lat_ahead() -> void:
		state.lat_ahead_dirty = false
		var ahead := {}
		state.lat_ahead = ahead
		for start in state.lat:
			if ahead.has(start):
				continue
			var path: Array[int] = []
			var on_path := {}
			var k: int = start
			var tail := 0
			var last := 0
			var none := false
			while true:
				on_path[k] = path.size()
				path.append(k)
				var nx: int = state.sim.next_of(k)
				if nx == 0 or not state.lanes.has(nx) or not state.lat.has(nx):
					last = path.size() - 1
					tail = 0
					break
				if ahead.has(nx):
					last = path.size() - 1
					tail = mini(LAT_FAR, (state.lanes[nx] as PackedInt32Array)[1] + int(ahead[nx]))
					break
				if on_path.has(nx):
					var s: int = on_path[nx]
					for j in range(s, path.size()):
						ahead[path[j]] = LAT_FAR
					none = s == 0
					last = 0 if none else s - 1
					tail = LAT_FAR
					break
				k = nx
			if none:
				continue
			ahead[path[last]] = tail
			for j in range(last - 1, -1, -1):
				var nxt := path[j + 1]
				var m: PackedInt32Array = state.lanes.get(nxt, PackedInt32Array())
				ahead[path[j]] = mini(LAT_FAR, (m[1] if not m.is_empty() else 0) + int(ahead[nxt]))

	## (park_lat) An item parked on the lattice's lanes whose lane was dropped from the square in this job's
	## messages: placed standing where its motion has it now (the dropped lanes' meta as they were), so its
	## going keeps it for the far icons (_go) and the belt is never bare; out of view it stays parked (it goes).
	func _stand_dropped(it: Item, now: int) -> bool:
		_set_lat(it, false)
		var d := mini(it.v * (now - it.t0), it.reach) if it.v > 0 and now > it.t0 else 0
		var k := it.lane
		var p := it.pos
		var left := d
		var stuck := false
		var guard := 0
		while left > p and guard < 4096:
			left -= p
			var nx: int = state.sim.next_of(k)
			var nm := _meta_any(nx) if nx != 0 else PackedInt32Array()
			if nm.is_empty():
				stuck = true
				break
			k = nx
			p = nm[1]
			guard += 1
		var m := _meta_any(k)
		if m.is_empty():
			return false
		var arc: PackedFloat64Array = state.arcs.get(k, PackedFloat64Array())
		if arc.is_empty() and dropped_meta.has(k):
			arc = dropped_meta[k][1]
		var q := _point_m(m, arc, float(0 if stuck else p - left))
		if view_cull and not view_all and not state.planned_view.grow(VIEW_MARGIN).has_point(Vector2(q.x, q.z)):
			return false
		_unpark(it)
		it.v = 0
		it.from = Vector3(q.x, q.y, q.z)
		it.step = Vector3.ZERO
		it.path = PackedFloat32Array()
		it.t_from = fold_tick
		it.t_to = fold_tick
		it.hidden = q.w < 0.5
		it.renew = -1.0
		state.renewing.erase(it)
		_mark(it)
		lat_unparks += 1
		return true

	## A lane's meta, or (a lane dropped in this job's messages) what it was.
	func _meta_any(key: int) -> PackedInt32Array:
		var m: PackedInt32Array = state.lanes.get(key, PackedInt32Array())
		if m.is_empty() and dropped_meta.has(key):
			m = dropped_meta[key][0]
		return m

	## The counters that walk every slot and item (State.gauges): slots in use and those of items on lattice
	## lanes all along (which the mask hides), parked items out of view and for the lattice.
	func _gauges() -> void:
		if state.lat_ahead_dirty:
			_lat_ahead()
		var slots := 0
		var hidden := 0
		for kk in state.kinds:
			for e in (state.kinds[kk] as Kind).slots:
				if not (e is Item):
					continue
				var it: Item = e
				var n := 1 + it.layers.size()
				slots += n
				if not state.lat_ahead.is_empty() and _on_lat(it.lane, it.pos, it.reach if it.v > 0 else 0):
					hidden += n
		var pv := 0
		var pl := 0
		for it: Item in state.items.values():
			if it.parked:
				if it.lat:
					pl += 1
				else:
					pv += 1
		state.gauges = [slots, hidden, pv, pl]

	## (--belt-draw-dump) This job's line and blobs (Job.dump); on the worker, jobs one after another.
	func _dump_write() -> void:
		var td := Time.get_ticks_usec()
		dump_no = dump_n
		dump_n += 1
		var ks: Array = dump_updates.keys()
		ks.sort()
		var hdr := {"n": dump_no, "fold": fold_tick, "sim": int(state.sim.tick), "data": state.data_tick, "base": state.records.base,
			"ms": usec / 1000.0, "sim_ms": sim_usec / 1000.0, "handle_ms": handle_usec / 1000.0, "apply_ms": apply_usec / 1000.0,
			"renew_ms": renew_usec / 1000.0, "write_ms": write_usec / 1000.0, "cap_ms": cap_usec / 1000.0,
			"recs": records_written, "changes": changes, "coalesced": coalesced, "early": early_n, "renewed": renewed, "gone": gone_n, "ticks": ticks, "skipped": skipped,
			"msgs": msgs.size(), "updates": ks, "items": count, "lanes": lanes_n, "asked": resend.size(),
			"later": later_n, "kept": kept_n, "full": full, "parked": parked, "unparked": unparked,
			"early_tries": early_tries, "drained": drained, "waiting": waiting_n, "lat_parks": lat_parks, "lat_unparks": lat_unparks,
			"asks": [ask_view_n, ask_lat_n, ask_out_n, ask_held_n, unknown_asked], "gauges": gauges,
			"view": [view.position.x, view.position.y, view.size.x, view.size.y] if not view_all else null,
			"native": state.draw != null, "lat_lanes": lat_lanes, "lat_ms": lat_usec / 1000.0,
			"lat_native": not (state.lattice is BeltLattice), "lat_slots": state.lattice.slots_n,
			# (The simulation's own counters, cumulative: stepping, relinking, loads and checks (usec), line steps,
			# why lines were stepped next tick; tools/belt_view_check.py takes their differences.)
			"sim_us": [state.sim.us_step, state.sim.us_relink, state.sim.us_queue] if "us_step" in state.sim else null,
			"line_steps": state.sim.n_line_steps if "n_line_steps" in state.sim else null,
			"why": Array(state.sim.why_tick) if "why_tick" in state.sim else null,
			"ni": dump_ids.size() / 8, "ng": dump_gone.size(), "paths": dump_paths.size() if paths != null else 0}
		dump.store_line(JSON.stringify(hdr))
		if not dump_ids.is_empty():
			dump.store_buffer(dump_ids.to_byte_array())
			dump.store_buffer(dump_recs.to_byte_array())
		if not dump_gone.is_empty():
			dump.store_buffer(dump_gone.to_byte_array())
		if paths != null:
			dump.store_buffer(dump_paths.to_byte_array())
		dump.flush()
		dump_usec = Time.get_ticks_usec() - td

	## (read_apply) The tick of each lane's first read in the job's messages: its meta (`lm`) takes effect
	## then, not when the message comes (BeltSim.set_lane_at).
	func _read_ticks() -> void:
		read_at.clear()
		new_geo.clear()
		# (replace_at: the places of the lanes set, when some lane is dropped; the parts of an update come together.)
		var drops := false
		if replace_at:
			for msg: Dictionary in msgs:
				drops = drops or msg.get("dl") is Array or msg.get("dl") is PackedInt64Array
		for msg: Dictionary in msgs:
			var lm = msg.get("lm")
			if drops and (lm is Array or lm is PackedInt64Array):
				var a = lm
				for i in range(0, a.size() - 11, 12):
					new_geo[Vector4i(int(a[i + 4]), int(a[i + 5]), int(a[i + 8]), int(a[i + 9]))] = int(a[i])
			var sl = msg.get("sl")
			if not (sl is Array or sl is PackedInt64Array):
				continue
			var a2 = sl
			var i := 0
			while i + 2 < a2.size():
				var key := int(a2[i])
				var at := int(a2[i + 1])
				if not read_at.has(key) or at < int(read_at[key]):
					read_at[key] = at
				i += 3 + clampi(int(a2[i + 2]), 0, (a2.size() - i - 3) / 4) * 4

	## (--inserter-handoff) An `ie` message (inserters.lua: [kind, unit, tick, a, b, c, hand x, hand y, belt]
	## x n, delta-coded with z 1): a hand's pick from a belt (picked, with its belt) becomes the simulation's
	## take of the items nearest the hand on that tick (as many as the pick added to the hand), an item put
	## on a belt (placed: [6, unit, tick, lane, line position, uid, item, stack, belt]) its put; each record
	## once (the mod sends each a few times).
	## (drop_show_now) Where a Z drop at (x, y) (1/256 tile) lands: the nearest place on a lane drawn within DROP_REACH,
	## as the game puts it on the lane nearest the spot (its lanes taken as the simulation takes a hand's: by their
	## exit, middle and entry). None off the belts.
	const DROP_REACH := 154  # (0.6 tile, as the bridge's PLACE_NEAR)
	func _drop_place(msg: Dictionary) -> void:
		var x := float(msg.get("x", 0))
		var y := float(msg.get("y", 0))
		var best_d := float(DROP_REACH * DROP_REACH)
		var best_key := 0
		var best_pos := 0.0
		for key: int in state.lanes:
			var m: PackedInt32Array = state.lanes[key]
			if absf(m[5] - x) > 512.0 or absf(m[6] - y) > 512.0 or m[0] == BeltSim.UG_HIDDEN:
				continue
			var half := float(maxi(m[1], 1)) * 0.5
			for s in 2:
				var ax := float(m[3] if s == 0 else m[5])
				var ay := float(m[4] if s == 0 else m[6])
				var dx := float(m[5] if s == 0 else m[7]) - ax
				var dy := float(m[6] if s == 0 else m[8]) - ay
				var ll := dx * dx + dy * dy
				var f := clampf(((x - ax) * dx + (y - ay) * dy) / ll, 0.0, 1.0) if ll > 0.0 else 0.0
				var qx := ax + dx * f - x
				var qy := ay + dy * f - y
				var d2 := qx * qx + qy * qy
				if d2 < best_d:
					best_d = d2
					best_key = key
					best_pos = half * (float(s) + f)
		if best_key != 0:
			var p := _point(best_key, best_pos)
			drops.append([int(msg.get("i", 0)), Vector3(p.x, p.y, p.z)])

	func _handle_ie(msg: Dictionary) -> void:
		var list = msg.get("l")
		if not (list is Array):
			return
		var a: Array = list
		var deltas := int(msg.get("z", 0)) == 1
		var v := PackedInt64Array([0, 0, 0, 0, 0, 0, 0, 0, 0])
		var sim := state.sim
		var k := int(msg.get("k", 0))
		var hu = msg.get("hu")
		if hu is Array:
			for u in hu:
				now_u.append(int(u))
		var i := 0
		while i + 8 < a.size():
			for j in 9:
				v[j] = v[j] + int(a[i + j]) if deltas else int(a[i + j])
			i += 9
			var kind := v[0]
			var unit := v[1]
			var t := v[2]
			var seen := "%d:%d:%d:%d" % [kind, unit, t, v[3] if kind != InserterArms.EV_PLACED else v[5]]
			if state.ie_seen.has(seen):
				continue
			state.ie_seen[seen] = t
			if kind == InserterArms.EV_PICKED:
				var last: int = state.hand_count.get(unit, -1)
				state.hand_count[unit] = v[3]
				if v[8] != 0:
					var n := v[3] - last if last >= 0 and v[3] > last else 1
					sim.take_at(t, v[8], v[4], n, v[6], v[7], unit)
					ie_n += 1
					if t > int(sim.tick) and int(sim.tick) >= 0:
						for pu in sim.peek_take(t, v[8], v[4], n, v[6], v[7]):
							peek_u.append(pu)
							peek_t.append(t)
							peek_i.append(unit)
			elif kind == InserterArms.EV_PLACED:
				sim.put_at(t, v[3], v[5], v[6], v[7], v[4], unit)
				ie_n += 1
				if unit == 0:  # (drop_show_now: a Z drop the bridge put, found where it went)
					var q := _point(v[3], float(v[4]))
					drop_puts.append([v[6], t, Vector3(q.x, q.y, q.z)])
			elif kind == InserterArms.EV_GONE:
				state.hand_count.erase(unit)
			else:
				state.hand_count[unit] = v[3]
		if k - state.ie_swept >= 300:
			state.ie_swept = k
			for key: String in state.ie_seen.keys():
				if int(state.ie_seen[key]) < k - 600:
					state.ie_seen.erase(key)

	## (--inserter-handoff) The holes the simulation's takes leave in the lattice's lanes (`holes`), from the
	## changes before the lattice's update, which runs ahead of the records' side.
	func _take_holes(ch: Dictionary) -> void:
		var hw: PackedInt32Array = ch.get("hand_why", PackedInt32Array())
		if hw.is_empty():
			return
		var ht: PackedInt64Array = ch["hand_tick"]
		var hk: PackedInt64Array = ch["hand_key"]
		var hp: PackedInt32Array = ch["hand_pos"]
		var hi: PackedInt64Array = ch["hand_ins"]
		var now := floori(fold_tick)
		for j in hw.size():
			if hw[j] != BeltSim.HAND_TAKEN:
				continue
			if PickUp.hide_now and hi[j] == 0 and ht[j] > now:
				# (--pickup-hide-now) F's take (no inserter): its hole from the drawn tick, where the item was then
				# (a moving lane's an earlier, further-back place), so it goes as it starts flying.
				var v := _lattice_speed(int(hk[j]))
				if v >= 0:
					holes.append([hk[j], now, hp[j] + v * (ht[j] - now)])
					continue
			holes.append([hk[j], ht[j], hp[j]])

	## A lane's lattice speed (1/256 tile a tick, 0 standing), -1 when the lattice doesn't draw it.
	func _lattice_speed(key: int) -> int:
		var lat = state.lattice
		if lat == null:
			return -1
		if lat.has_method("drawn_speed"):
			return int(lat.drawn_speed(key))
		var ln = lat.drawn.get(key)
		return -1 if ln == null else maxi(0, int(ln.v))

	## (--inserter-handoff) The simulation's takes and puts: a taken item's record hides on the take's tick
	## (the shader; it goes from the records as any item gone, in the job whose drawn tick passes it), and
	## each is told to the arms (where the item is then) for the hand to meet it.
	func _hands(ch: Dictionary, hide: bool) -> void:
		# (Only a take after the drawn tick hides a record: one at or before it went from the records in this
		# job already, and an item there now under that uid is one a read put back since: the game kept it.)
		var now := floori(fold_tick)
		if hide:
			# (--pickup-hide-now) F's takes hide from now (before the peeks, which would wait for the take's tick).
			var nu: PackedInt64Array = ch.get("now_uid", PackedInt64Array())
			for u in nu:
				var nit: Item = state.items.get(u)
				if nit != null and float(now) > state.records.base and (nit.hide_at < 0.0 or nit.hide_at > float(now)):
					nit.hide_at = float(now)
					_mark(nit)
			var pu: PackedInt64Array = ch.get("peek_uid", PackedInt64Array())
			for j in pu.size():
				var pit: Item = state.items.get(pu[j])
				if pit != null and pit.hide_at < 0.0 and int(ch["peek_tick"][j]) > now:
					pit.hide_at = float(ch["peek_tick"][j])
					_mark(pit)
				var pk := Vector2i(int(ch["peek_ins"][j]), int(ch["peek_tick"][j]))
				var lst: PackedInt64Array = state.peeks.get(pk, PackedInt64Array())
				lst.append(pu[j])
				state.peeks[pk] = lst
		var hu: PackedInt64Array = ch.get("hand_uid", PackedInt64Array())
		if hu.is_empty():
			return
		var ht: PackedInt64Array = ch["hand_tick"]
		var hi: PackedInt64Array = ch["hand_ins"]
		var hk: PackedInt64Array = ch["hand_key"]
		var hp: PackedInt32Array = ch["hand_pos"]
		var hw: PackedInt32Array = ch["hand_why"]
		for j in hu.size():
			var x := NAN
			var z := NAN
			if hw[j] == BeltSim.HAND_TAKEN or hw[j] == BeltSim.HAND_PUT:
				var p := _point(int(hk[j]), float(hp[j]))
				x = p.x
				z = p.z
			hands.append([hw[j], hi[j], ht[j], hu[j], x, z])
			if hide and hw[j] == BeltSim.HAND_TAKEN and ht[j] > now:
				var it: Item = state.items.get(hu[j])
				if it != null and it.hide_at < 0.0:
					it.hide_at = float(ht[j])
					_mark(it)
		if hide and not state.peeks.is_empty():
			# (A guess the take didn't make: shown again.)
			var taken := {}
			for j in hu.size():
				var pk := Vector2i(int(hi[j]), int(ht[j]))
				if state.peeks.has(pk):
					var got: PackedInt64Array = taken.get(pk, PackedInt64Array())
					if hw[j] == BeltSim.HAND_TAKEN:
						got.append(hu[j])
					taken[pk] = got
			for pk: Vector2i in taken:
				for p in (state.peeks[pk] as PackedInt64Array):
					if not (taken[pk] as PackedInt64Array).has(p):
						var wit: Item = state.items.get(p)
						if wit != null and wit.hide_at == float(pk.y):
							wit.hide_at = -1.0
							_mark(wit)
				state.peeks.erase(pk)
			if state.peeks.size() > 512:
				for pk: Vector2i in state.peeks.keys():
					if pk.y < now - 600:
						state.peeks.erase(pk)

	## One part of an update (`bs`): lanes' meta first, then their items, checks, drops, switches.
	func _handle(msg: Dictionary) -> void:
		if msg.get("t") == "zp":
			_drop_place(msg)
			return
		if msg.get("t") == "ie":
			if InserterArms.handoff:
				_handle_ie(msg)
			return
		if msg.get("t") != "bs":
			return
		var sim := state.sim
		var k := int(msg.get("k", 0))
		began = true
		if dump != null:
			dump_updates[k] = true
		last_tick = maxi(last_tick, k)
		state.data_tick = maxi(state.data_tick, k)
		if state.records.base < 0.0:
			state.records.base = float(k) - 600.0
		if msg.has("p"):
			state.period = int(msg["p"])
		if msg.has("fr"):
			state.square = Vector3(int(msg.get("fx", 0)) / 256.0, int(msg.get("fy", 0)) / 256.0, int(msg.get("fr", 0)))
		# (A binary part's lists are PackedInt64Array in the same layout: wire_decode.gd.)
		var lm = msg.get("lm")
		if (lm is Array or lm is PackedInt64Array):
			var a = lm
			for i in range(0, a.size() - 11, 12):
				var key := int(a[i])
				if not state.removed_keys.is_empty() and state.removed_keys.has(key):
					continue  # (removed_now: a belt Zenith took away, read before it went)
				var raw := PackedInt32Array([int(a[i + 1]), int(a[i + 2]), int(a[i + 3]), int(a[i + 4]), int(a[i + 5]),
					int(a[i + 6]), int(a[i + 7]), int(a[i + 8]), int(a[i + 9])])
				state.lanes_raw[key] = raw
				var meta := LaneInset.shifted(raw, state.lane_inset)  # (drawn; the simulation below keeps raw)
				if not state.lanes.has(key) or (state.lanes[key] as PackedInt32Array) != meta:
					state.lanes_moved = true
				dropped_meta.erase(key)
				if not state.drop_at.is_empty():
					# (Sent again: no longer dropped later.)
					state.drop_at = state.drop_at.filter(func(e: Array) -> bool: return int(e[1]) != key)
				state.lanes[key] = meta
				if meta[0] == BeltSim.CURVE:
					state.arcs[key] = _arc(meta)
				if state.draw != null:
					state.draw.set_lane(key, meta)
				if not (state.lattice is BeltLattice):
					state.lattice.set_lane(key, meta, state.arcs.get(key, PackedFloat64Array()))
				# (next < 0: the lane leads out of what is sent, into -next when the bridge knows it, -1
				# otherwise; till that lane comes its front follows the bridge's reads.)
				var nxt := int(a[i + 11])
				var at: int = read_at.get(key, -1) if read_apply else -1
				if at >= 0:
					sim.set_lane_at(at, key, raw[0], raw[1], raw[2], Vector2i(raw[3], raw[4]), Vector2i(raw[5], raw[6]),
						Vector2i(raw[7], raw[8]), int(a[i + 10]), -nxt if nxt < -1 else maxi(nxt, 0), nxt < 0)
				else:
					sim.set_lane(key, raw[0], raw[1], raw[2], Vector2i(raw[3], raw[4]), Vector2i(raw[5], raw[6]),
						Vector2i(raw[7], raw[8]), int(a[i + 10]), -nxt if nxt < -1 else maxi(nxt, 0))
					sim.set_out_edge(key, nxt < 0)
		var dl = msg.get("dl")
		if (dl is Array or dl is PackedInt64Array):
			for key in dl:
				if not state.removed_keys.is_empty() and state.removed_keys.erase(int(key)):
					_drop_now(int(key))  # (removed_now: gone already; nothing of it left to stand)
					continue
				if not new_geo.is_empty() and _drop_later(int(key)):
					continue
				_drop_now(int(key))
		var sl = msg.get("sl")
		if (sl is Array or sl is PackedInt64Array):
			var a2 = sl
			var i := 0
			var oracle: Dictionary = sim.oracle
			if oracle.size() > ORACLE_MAX:
				oracle.clear()
			while i + 2 < a2.size():
				var key := int(a2[i])
				var at := int(a2[i + 1])
				var n := clampi(int(a2[i + 2]), 0, (a2.size() - i - 3) / 4)  # (never more than the list holds)
				if not state.removed_keys.is_empty() and state.removed_keys.has(key):
					i += 3 + n * 4  # (removed_now: a belt Zenith took away)
					continue
				first_tick = at if first_tick < 0 else mini(first_tick, at)
				var items := PackedInt64Array()
				items.resize(n * 4)
				var out := state.lanes.has(key) and (state.lanes[key] as PackedInt32Array)[0] == BeltSim.SPLIT_OUT
				for j in n:
					var b := i + 3 + j * 4
					items[j * 4] = int(a2[b])
					items[j * 4 + 1] = int(a2[b + 1])
					items[j * 4 + 2] = int(a2[b + 2])
					items[j * 4 + 3] = int(a2[b + 3])
					if out:
						# (Where a splitter sent it: the simulation learns the splitter's turn from it.)
						oracle[int(a2[b])] = [key, int(a2[b + 2])]
				if int(sim.tick) > at:
					stale_reads += 1
					stale_most = maxi(stale_most, int(sim.tick) - at)
				if ask_unknown and not state.lanes.has(key):
					_ask(key)
				sim.load_lane(key, at, items)
				sim.set_wall(key, at, items[0] if n > 0 else 0, int(items[2]) if n > 0 else 0)
				if state.lanes.has(key):
					state.lattice.note_read(key, (state.lanes[key] as PackedInt32Array)[1], items)
				if hold and state.lanes.has(key) and (state.lanes[key] as PackedInt32Array)[0] == BeltSim.SPLIT_IN:
					state.last_read[key] = items
				i += 3 + n * 4
		# sh: splitter inputs found as their last read left them, [key, tick, ...]: put back so, and held.
		var sh = msg.get("sh")
		if (sh is Array or sh is PackedInt64Array) and hold:
			var a7 = sh
			for i in range(0, a7.size() - 1, 2):
				var key := int(a7[i])
				if state.last_read.has(key):
					sim.hold_input(key, int(a7[i + 1]), state.last_read[key])
		# ew: a lane leading out that only moved on: its new wall, [key, tick, front uid, its position, ...].
		var ew = msg.get("ew")
		if (ew is Array or ew is PackedInt64Array):
			var a6 = ew
			for i in range(0, a6.size() - 3, 4):
				sim.set_wall(int(a6[i]), int(a6[i + 1]), int(a6[i + 2]), int(a6[i + 3]))
		var pc = msg.get("pc")
		if (pc is Array or pc is PackedInt64Array):
			var a3 = pc
			# (pu: packed lanes' front and back items' ids, [key, front uid, back uid, ...].)
			var ids := {}
			var pu = msg.get("pu")
			if (pu is Array or pu is PackedInt64Array):
				var a5 = pu
				for i in range(0, a5.size() - 2, 3):
					ids[int(a5[i])] = [int(a5[i + 1]), int(a5[i + 2])]
			for i in range(0, a3.size() - 4, 5):
				if not state.removed_keys.is_empty() and state.removed_keys.has(int(a3[i])):
					continue  # (removed_now)
				if ask_unknown and not state.lanes.has(int(a3[i])):
					_ask(int(a3[i]))
				var u: Array = ids.get(int(a3[i]), [0, 0])
				sim.check_lane(int(a3[i]), int(a3[i + 1]), int(a3[i + 2]), int(a3[i + 3]), int(a3[i + 4]), int(u[0]), int(u[1]))
				if state.lanes.has(int(a3[i])):
					state.lattice.note_check(int(a3[i]), (state.lanes[int(a3[i])] as PackedInt32Array)[1], int(a3[i + 2]),
						int(a3[i + 3]), int(a3[i + 4]))
		var of = msg.get("of")
		if (of is Array or of is PackedInt64Array):
			var a4 = of
			for i in range(0, a4.size() - 1, 2):
				sim.set_off(int(a4[i]), int(a4[i + 1]) == 1, k)
		# (qu: items' quality names; quality marks come from `bq`, not drawn from here.)

	## (replace_at) A lane dropped where this job's messages set another of the same place, read after the
	## simulation's tick: dropped then (State.drop_at). Returns whether it waits.
	func _drop_later(key: int) -> bool:
		var m: PackedInt32Array = state.lanes.get(key, PackedInt32Array())
		if m.is_empty():
			return false
		var nk: int = new_geo.get(Vector4i(m[3], m[4], m[7], m[8]), 0)
		if nk == 0 or nk == key:
			return false
		var at: int = read_at.get(nk, -1)
		if at <= int(state.sim.tick):
			return false
		state.drop_at.append([at, key])
		replaced_n += 1
		return true

	## A lane the bridge no longer sends: out of the simulation, the drawing and the lattice; its items go.
	func _drop_now(key: int) -> void:
		dropped[key] = true
		# (sim_full) A lane gone inside the square is a belt removed: the lane it led into is fed no more.
		if BeltLattice.sim_full and _in_square(key):
			_feed_gone(key)
		state.sim.drop_lane(key)
		if state.draw != null:
			state.draw.drop_lane(key)
		if state.lanes.has(key):
			state.lanes_moved = true
			dropped_meta[key] = [state.lanes[key], state.arcs.get(key, PackedFloat64Array())]
		state.lanes.erase(key)
		state.last_read.erase(key)
		state.arcs.erase(key)
		state.lattice.drop(key)

	## (sim_full) The lattice told that the lanes lane `key` led into, on along their run (BeltSim.next_of, to a
	## splitter or the run's end), are fed by it no more (BeltLattice.feed_gone).
	func _feed_gone(key: int) -> void:
		if not state.lattice.has_method("feed_gone"):
			return
		var t := int(state.sim.tick)
		var seen := {key: true}
		var nx := int(state.sim.next_of(key))
		for _i in 256:
			if nx == 0 or seen.has(nx):
				return
			seen[nx] = true
			state.lattice.feed_gone(nx, t)
			nx = int(state.sim.next_of(nx))

	## (sim_full) Whether lane `key`'s exit lies inside the bridge's square (`fx`, `fy`, `fr`: every belt there
	## is loaded), two tiles in from its edge: a lane dropped there is a belt gone, not one left behind.
	func _in_square(key: int) -> bool:
		var m: PackedInt32Array = state.lanes.get(key, PackedInt32Array())
		if m.size() < 5 or state.square.z <= 2.0:
			return false
		return absf(m[3] / 256.0 - state.square.x) < state.square.z - 2.0 and absf(m[4] / 256.0 - state.square.y) < state.square.z - 2.0

	## (removed_now) A removed belt's lanes out of the simulation and the lattice now: the changes the simulation had
	## not given yet (none, normally: the last job took them), then the items it dropped with them, gone at the drawn
	## tick. Not marked dropped (`dropped`), so the drawing removes those items rather than standing them for far
	## icons; their meta goes after the job (_forget_lanes). The bridge's later reads of them are passed over
	## (State.removed_keys).
	func _remove_lanes(keys: Array) -> Dictionary:
		var sim := state.sim
		var before: Dictionary = sim.take_changes()
		for key: int in keys:
			if BeltLattice.sim_full:
				_feed_gone(key)
			sim.drop_lane(key)
			state.lattice.drop(key)
			state.removed_keys[key] = now_msec
		if not state.drop_at.is_empty():
			state.drop_at = state.drop_at.filter(func(e: Array) -> bool: return not keys.has(int(e[1])))
		var rm: Dictionary = sim.take_changes()
		var gt: PackedInt64Array = rm.get("gone_tick", PackedInt64Array())
		var now := floori(fold_tick)
		for i in gt.size():
			gt[i] = now
		rm["gone_tick"] = gt
		removed_lanes_n += keys.size()
		removed_items_n += (rm.get("gone", PackedInt64Array()) as PackedInt64Array).size()
		return _merge_changes(before, rm)

	## (removed_now) The removed lanes' meta forgotten, once this job has drawn their items' going.
	func _forget_lanes(keys: Array) -> void:
		for key: int in keys:
			if state.draw != null:
				state.draw.drop_lane(key)
			if state.lanes.has(key):
				state.lanes_moved = true
			state.lanes.erase(key)
			state.last_read.erase(key)
			state.arcs.erase(key)

	## (removed_now) Removed lanes the bridge hasn't said are gone (`dl`) forgotten after REMOVED_KEEP_MSEC.
	func _prune_removed() -> void:
		var old: Array = []
		for key: int in state.removed_keys:
			if now_msec - int(state.removed_keys[key]) > REMOVED_KEEP_MSEC:
				old.append(key)
		for key: int in old:
			state.removed_keys.erase(key)

	## Two take_changes() results as one, a's first (b's gone_at counted past a's changes).
	static func _merge_changes(a: Dictionary, b: Dictionary) -> Dictionary:
		var n := 0
		if a.has("uid"):
			n = (a["uid"] as PackedInt64Array).size()
		var out := {}
		for k in b:
			var vb = b[k]
			if str(k) == "gone_at" and n > 0:
				var ga := PackedInt32Array(vb)
				for i in ga.size():
					ga[i] += n
				vb = ga
			if a.has(k):
				var m = a[k].duplicate()
				m.append_array(vb)
				out[k] = m
			else:
				out[k] = vb
		for k in a:
			if not out.has(k):
				out[k] = a[k]
		return out

	## The simulation stepped to `to`, the lanes waiting to be dropped (replace_at) dropped on their ticks on the way.
	func _step_to(to: int) -> void:
		var sim := state.sim
		if state.drop_at.is_empty():
			sim.step_to(to)
			return
		state.drop_at.sort_custom(func(x: Array, y: Array) -> bool: return int(x[0]) < int(y[0]) or int(x[0]) == int(y[0]) and int(x[1]) < int(y[1]))
		var rest: Array = []
		for e: Array in state.drop_at:
			if int(e[0]) <= to:
				if int(e[0]) > int(sim.tick):
					sim.step_to(int(e[0]))
				_drop_now(int(e[1]))
			else:
				rest.append(e)
		state.drop_at = rest
		if to > int(sim.tick):
			sim.step_to(to)

	## A curve lane's circle through its three points: [cx, cy, r, angle at its exit, angle turned
	## to its entry] (1/256 tile, radians).
	static func _arc(m: PackedInt32Array) -> PackedFloat64Array:
		var ax := float(m[3])
		var ay := float(m[4])
		var bx := float(m[5])
		var by := float(m[6])
		var cx := float(m[7])
		var cy := float(m[8])
		var d := 2.0 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
		if absf(d) < 1e-6:
			return PackedFloat64Array()
		var a2 := ax * ax + ay * ay
		var b2 := bx * bx + by * by
		var c2 := cx * cx + cy * cy
		var ux := (a2 * (by - cy) + b2 * (cy - ay) + c2 * (ay - by)) / d
		var uy := (a2 * (cx - bx) + b2 * (ax - cx) + c2 * (bx - ax)) / d
		var a0 := atan2(ay - uy, ax - ux)
		var a1 := atan2(cy - uy, cx - ux)
		return PackedFloat64Array([ux, uy, Vector2(ax - ux, ay - uy).length(), a0, wrapf(a1 - a0, -PI, PI)])

	## Where line position `pos` of lane `key` is (tiles; y the items' height), and whether it shows.
	func _point(key: int, pos: float) -> Vector4:
		var m: PackedInt32Array = state.lanes.get(key, PackedInt32Array())
		if m.is_empty():
			return Vector4(0.0, state.height, 0.0, 0.0)
		return _point_m(m, state.arcs.get(key, PackedFloat64Array()) if m[0] == BeltSim.CURVE else PackedFloat64Array(), pos)

	## _point from a lane's meta and (a curve's) arc.
	func _point_m(m: PackedInt32Array, arc: PackedFloat64Array, pos: float) -> Vector4:
		var f := clampf(pos / float(maxi(m[1], 1)), 0.0, 1.0)
		var x: float
		var y: float
		if m[0] == BeltSim.CURVE and not arc.is_empty():
			var a := arc[3] + arc[4] * f
			x = arc[0] + cos(a) * arc[2]
			y = arc[1] + sin(a) * arc[2]
		else:
			x = lerpf(float(m[3]), float(m[7]), f)
			y = lerpf(float(m[4]), float(m[8]), f)
		return Vector4(x / 256.0, state.height, y / 256.0, 0.0 if m[0] == BeltSim.UG_HIDDEN else 1.0)

	## Lane and position `d` (1/256) on from (key, pos) along the line: [key, pos], or [0, 0] past
	## its end.
	func _advance(key: int, pos: int, d: int) -> Vector2i:
		var k := key
		var p := pos
		var left := d
		var guard := 0
		while left > p and guard < 4096:
			left -= p
			var nx: int = state.sim.next_of(k)
			if nx == 0 or not state.lanes.has(nx):
				return Vector2i(k, 0)
			k = nx
			p = (state.lanes[k] as PackedInt32Array)[1]
			guard += 1
		return Vector2i(k, p - left)

	## The simulation's changes: each item's new motion, one record each; the items gone; the lanes
	## to ask for again.
	func _apply_changes(ch: Dictionary) -> void:
		var uids: PackedInt64Array = ch["uid"]
		if BeltLattice.turn_id:
			var nums: PackedInt64Array = ch.get("num", PackedInt64Array())
			if nums.size() == uids.size():
				for i in uids.size():
					if nums[i] >= 0:
						state.nums[uids[i]] = nums[i]
		_puts.clear()
		var hw: PackedInt32Array = ch.get("hand_why", PackedInt32Array())
		if not hw.is_empty():
			var hu: PackedInt64Array = ch["hand_uid"]
			var ht: PackedInt64Array = ch["hand_tick"]
			for j in hw.size():
				if hw[j] == BeltSim.HAND_PUT:
					_puts[hu[j]] = ht[j]
		changes = uids.size()
		var items: PackedInt32Array = ch["item"]
		var stacks: PackedInt32Array = ch["stack"]
		var keys: PackedInt64Array = ch["key"]
		var poss: PackedInt32Array = ch["pos"]
		var ticks: PackedInt64Array = ch["tick"]
		var speeds: PackedInt32Array = ch["speed"]
		var reaches: PackedInt32Array = ch["reach"]
		var runs: PackedInt32Array = ch["run"]
		var gone: PackedInt64Array = ch["gone"]
		var gone_ticks: PackedInt64Array = ch.get("gone_tick", PackedInt64Array())
		var gone_at: PackedInt32Array = ch.get("gone_at", PackedInt32Array())
		gone_n = gone.size()
		# In the simulation's order (an item can go and come back, or come and go, in one job's ticks);
		# what happened after the drawn tick (the simulation runs AHEAD of it) waits for the next job,
		# with whatever happens to that item after it: the record it replaces holds till then.
		var now := floori(fold_tick)
		var held := {}
		# (coalesce) Each item's last change at or before the drawn tick is the only one applied; the
		# changes after the drawn tick wait as before. Only those are walked, in order.
		var idx := PackedInt32Array()
		if coalesce:
			var last_i := {}
			for i in uids.size():
				if ticks[i] > now:
					idx.append(i)
				else:
					last_i[uids[i]] = i
			coalesced = uids.size() - idx.size() - last_i.size()
			for v in last_i.values():
				idx.append(v)
			idx.sort()
		if later_tick:
			_drain_due(now)
		elif not state.later.is_empty():
			var later := state.later
			state.later = []
			for e: Array in later:
				if int(e[2]) > now or held.has(e[1]):
					if early and int(e[0]) == 0 and not held.has(e[1]):
						early_tries += 1
						if _apply_early(e[1], e[3], e[4], e[5], e[6], e[2], e[7], e[8], e[9], now):
							continue
					held[e[1]] = true
					state.later.append(e)
				elif int(e[0]) == 0:
					_apply_one(e[1], e[3], e[4], e[5], e[6], e[2], e[7], e[8], e[9])
				else:
					_go(e[1])
		var gi := 0
		var ng := gone.size()
		var timed := gone_order and gone_ticks.size() == ng and gone_at.size() == ng
		var n_walk := idx.size() if coalesce else uids.size()
		for w in n_walk:
			var i := idx[w] if coalesce else w
			while timed and gi < ng and gone_at[gi] <= i:
				_go_or_hold(gone[gi], gone_ticks[gi], now, held)
				gi += 1
			var uid: int = uids[i]
			var h := _held(uid, held)
			if ticks[i] > now or h:
				var tried := false
				_early_wait = NEVER
				if early and not h:
					early_tries += 1
					tried = true
					if _apply_early(uid, items[i], stacks[i], keys[i], poss[i], ticks[i], speeds[i], reaches[i], runs[i], now):
						continue
				_hold([0, uid, ticks[i], items[i], stacks[i], keys[i], poss[i], speeds[i], reaches[i], runs[i]], held, tried, _early_wait)
				continue
			_apply_one(uid, items[i], stacks[i], keys[i], poss[i], ticks[i], speeds[i], reaches[i], runs[i])
		while gi < ng:
			_go_or_hold(gone[gi], gone_ticks[gi] if timed else now, now, held)
			gi += 1
		_ask_mismatches(ch)

	## Whether changes of the item wait (taken after them, in order).
	func _held(uid: int, held: Dictionary) -> bool:
		if later_tick:
			return not state.waiting.is_empty() and state.waiting.has(uid)
		return not held.is_empty() and held.has(uid)

	## A change (or a going, [1, uid, tick]) to wait for the next jobs: in the list, or (later_tick) behind the
	## item's others, its first filed by tick (`tried`: it was just tried early and wasn't taken; retry_at: a
	## start, tried again once the drawn tick reaches the item's t0).
	func _hold(e: Array, held: Dictionary, tried: bool, retry_at: int) -> void:
		if not later_tick:
			held[e[1]] = true
			state.later.append(e)
			return
		state.later_n += 1
		var uid: int = e[1]
		var w: Waiting = state.waiting.get(uid)
		if w == null:
			w = Waiting.new()
			state.waiting[uid] = w
		var first := w.head >= w.q.size()
		w.q.append(e)
		if not first:
			return
		var it: Item = state.items.get(uid)
		if it != null:
			it.waits = true
		w.tried = (it.ver if it != null else -1) if tried else -2
		w.retry_at = retry_at if tried else NEVER
		_file(uid, w)

	## (later_tick) Files the item under the tick its first waiting change takes effect at (or is tried again).
	func _file(uid: int, w: Waiting) -> void:
		if w.head >= w.q.size():
			return
		var t := mini(int(w.q[w.head][2]), w.retry_at)
		if t != w.filed:
			var lst: Array = state.due.get(t, [])
			lst.append(uid)
			state.due[t] = lst
			w.filed = t

	## (later_tick) The waiting changes this job can take: those of the items filed up to the drawn tick and of
	## the items that changed since their first was tried; of every waiting item when the lanes' links may
	## have moved (a lane set or dropped, a relink since the last job or one pending: an early take walks the
	## lanes ahead). Anything else would be tried as it was last time and stay. Same takes as the list's, item
	## by item.
	func _drain_due(now: int) -> void:
		var work: Array = []
		var ticks_due: Array = []
		for t in state.due:
			if int(t) <= now:
				ticks_due.append(t)
		for t in ticks_due:
			for uid in state.due[t]:
				var wt: Waiting = state.waiting.get(uid)
				if wt != null and wt.filed == int(t):
					wt.filed = -NEVER
			work.append_array(state.due[t])
			state.due.erase(t)
		var all := graph_now and early
		if all:
			work = state.waiting.keys()
		else:
			work.append_array(state.retry)
			var seen := {}
			for uid in work:
				seen[uid] = true
			work = seen.keys()
		# (By uid, as the C++ twin: the order hands out slots, so both compact a kind in the same job.)
		work.sort()
		state.retry = []
		var lv := int(state.sim.links_ver)
		for uid in work:
			_drain(uid, now, all)
		drained += work.size()
		if early and not all and int(state.sim.links_ver) != lv:
			# (Links worked out again on the way: every first change tried again, with them.)
			work = state.waiting.keys()
			work.sort()
			for uid in work:
				_drain(uid, now, true)
			drained += work.size()

	## (later_tick) One item's waiting changes, in order: those due taken, then the first tried early (when
	## anything it reads may have changed since its last try), until one stays.
	func _drain(uid: int, now: int, all: bool) -> void:
		var w: Waiting = state.waiting.get(uid)
		if w == null:
			return
		while w.head < w.q.size():
			var e: Array = w.q[w.head]
			if int(e[2]) <= now:
				w.head += 1
				state.later_n -= 1
				w.tried = -2
				w.retry_at = NEVER
				if int(e[0]) == 0:
					_apply_one(e[1], e[3], e[4], e[5], e[6], e[2], e[7], e[8], e[9])
				else:
					_go(e[1])
				continue
			if early and int(e[0]) == 0:
				var it: Item = state.items.get(uid)
				if it == null:
					w.tried = -1
				elif all or it.ver != w.tried or now >= w.retry_at:
					early_tries += 1
					_early_wait = NEVER
					if _apply_early(e[1], e[3], e[4], e[5], e[6], e[2], e[7], e[8], e[9], now):
						w.head += 1
						state.later_n -= 1
						w.tried = -2
						w.retry_at = NEVER
						continue
					w.tried = it.ver
					w.retry_at = _early_wait
			break
		if w.head >= w.q.size():
			var it: Item = state.items.get(uid)
			if it != null:
				it.waits = false
			state.waiting.erase(uid)
			return
		if w.head >= 32 and w.head * 2 >= w.q.size():
			w.q = w.q.slice(w.head)
			w.head = 0
		if w.retry_at <= now:
			w.retry_at = NEVER  # (not tried, no item: nothing to try again for)
		_file(uid, w)

	## The lanes whose drift check failed, asked for again (`bre`), each at most every ASK_AGAIN_MSEC, as
	## before; (ask_view, --belt-sim-ask=view) a lane the lattice draws only when its count is wrong (every
	## ASK_LATTICE_MSEC at most; asked the moment it leaves the lattice), one out of the planned view every
	## ASK_OUT_MSEC, doubling to ASK_OUT_MAX_MSEC while it keeps failing. (ask_near) Nearest the view's middle
	## first: the bridge reads them in the order asked, bre_cap an update.
	func _ask_mismatches(ch: Dictionary) -> void:
		var mism: PackedInt64Array = ch["mismatch"]
		if mism.is_empty():
			return
		var mn: PackedInt32Array = ch.get("mismatch_n", PackedInt32Array())
		var c := Vector2(state.square.x, state.square.y) if view_all else view.get_center()
		var out: Array = []  # [distance squared, key]
		for i in mism.size():
			var key: int = mism[i]
			var count := mn[i] != 0 if i < mn.size() else true
			var m: PackedInt32Array = state.lanes.get(key, PackedInt32Array())
			var cls := 0  # 0 in view, 1 the lattice's, 2 out of view
			if state.lat.has(key):
				cls = 1
			elif not m.is_empty() and not _in_view(key, m[1] / 2, 0):
				cls = 2
			var every := ASK_AGAIN_MSEC
			if ask_view:
				if cls == 1:
					if not count:
						state.lat_pend[key] = true
						ask_held_n += 1
						continue
					every = ASK_LATTICE_MSEC
				elif cls == 2:
					every = int(state.out_every.get(key, ASK_OUT_MSEC))
				else:
					state.out_every.erase(key)
			var last: int = state.asked.get(key, -LAT_FAR)
			if now_msec - last < every:
				ask_held_n += 1
				continue
			state.asked[key] = now_msec
			if ask_view and cls == 2:
				# (Failing again after a quiet spell: from ASK_OUT_MSEC again.)
				var fresh: bool = not state.out_every.has(key) or now_msec - last > 2 * every
				state.out_every[key] = ASK_OUT_MSEC if fresh else mini(every * 2, ASK_OUT_MAX_MSEC)
			if cls == 1:
				state.lat_pend.erase(key)
				ask_lat_n += 1
			elif cls == 2:
				ask_out_n += 1
			else:
				ask_view_n += 1
			var d2 := 0.0
			if not m.is_empty():
				var p := _point(key, m[1] * 0.5)
				var dx := float(p.x) - float(c.x)
				var dz := float(p.z) - float(c.y)
				d2 = dx * dx + dz * dz
			out.append([d2, key])
		if ask_near:
			out.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0] or x[0] == y[0] and x[1] < y[1])
		for e: Array in out:
			resend.append(e[1])

	## A lane to ask the bridge for again (`bre`), at most every ASK_AGAIN_MSEC.
	func _ask(key: int) -> void:
		var last: int = state.asked.get(key, -ASK_AGAIN_MSEC)
		if now_msec - last >= ASK_AGAIN_MSEC:
			state.asked[key] = now_msec
			resend.append(key)
			unknown_asked += 1

	## An item gone on tick t: now, or in the next job if that is after the drawn tick (or something
	## that happened to it before is waiting).
	func _go_or_hold(uid: int, t: int, now: int, held: Dictionary) -> void:
		# (A lane dropped in this job's messages: its items go now, whatever tick the simulation, stepped
		# ahead of the drawn clock, was at; a run-off at a later tick waits.)
		if t > now and not dropped.is_empty():
			var it: Item = state.items.get(uid)
			if it != null and dropped.has(it.lane):
				t = now
		if t > now or _held(uid, held):
			_hold([1, uid, t], held, false, NEVER)
			return
		_go(uid)

	## An item gone: its lane left the square, it stands where it is until its chunk's far icons exist;
	## else it goes.
	func _go(uid: int) -> void:
		var it: Item = state.items.get(uid)
		if it == null:
			return
		if it.parked:
			_remove(uid)  # (out of view: nothing to keep standing)
			return
		var at := _at(it, fold_tick)
		var sq := state.square
		var outside := sq.z >= 0.0 and (absf(at.x - sq.x) > sq.z or absf(at.z - sq.y) > sq.z)
		if (dropped.has(it.lane) or outside) and far_built != null:
			var c := Vector2i(floori(at.x / 32.0), floori(at.z / 32.0))
			if not (far_built as Dictionary).has(c):
				it.v = 0
				it.from = at
				it.step = Vector3.ZERO
				it.path = PackedFloat32Array()
				it.t_from = fold_tick
				it.t_to = fold_tick
				it.renew = -1.0
				state.renewing.erase(it)
				state.kept[it] = c
				_mark(it)
				_touch(it)
				return
		_remove(uid)

	## (early) A change after the drawn tick taken now when nothing shows early: a start of an item whose
	## record stands where the change starts from (applied as it is: the record stands there till t0), or a
	## continuation of a moving item's record (it reaches the change's lane and place at the change's tick
	## at the same speed): the item goes on from where its record has it now, the rest of its reach and the
	## change's beyond, through the lanes ahead, instead of standing at the cut till the next job. Items of
	## another look (item, stack) or out of view are left to the next job. Returns true when taken; not
	## taken only for want of time (a start whose item stands there from a later tick), _early_wait says
	## that tick.
	func _apply_early(uid: int, item: int, stack: int, key: int, pos: int, t0: int, v: int, reach: int, _run: int, now: int) -> bool:
		var it: Item = state.items.get(uid)
		if it == null and _puts.has(uid) and int(_puts[uid]) == t0:
			# (--inserter-handoff) An item a hand puts on its belt: made now, hidden till the put's tick.
			_apply_one(uid, item, stack, key, pos, t0, v, reach, _run)
			var nit: Item = state.items.get(uid)
			if nit != null:
				nit.show_at = float(t0)
				_mark(nit)
			early_n += 1
			return true
		if it == null or it.parked or it.item_id != item or it.count != clampi(stack, 1, MAX_STACK) or state.kept.has(it):
			return false
		if it.v <= 0:
			if v > 0 and it.lane == key and it.pos == pos:
				if it.t0 <= now:
					_apply_one(uid, item, stack, key, pos, t0, v, reach, _run)
					early_n += 1
					return true
				_early_wait = it.t0
			return false
		if v != it.v:
			if v == 0 and early_stop:
				_cut_at_stop(it, key, pos, t0, now)
			return false
		var d := it.v * (t0 - it.t0)
		if d <= 0:
			return false
		# (d past the record's reach: it ends at the line's end a little before t0, the item crossing within
		# the tick; the change's place is exactly that far on along the lanes.)
		var at := _advance(it.lane, it.pos, d)
		if at.x != key or at.y != pos:
			return false
		var d0 := clampi(it.v * (now - it.t0), 0, d)
		var from := _advance(it.lane, it.pos, d0)
		it.lane = from.x
		it.pos = from.y
		it.t0 = maxi(it.t0, now) if d0 > 0 else it.t0
		it.reach = (d - d0) + reach
		var m: PackedInt32Array = state.lanes.get(it.lane, PackedInt32Array())
		it.run = it.pos + int(state.sim.run_of(it.lane)) if not m.is_empty() and m[0] == BeltSim.STRAIGHT else 0
		var why := _hide_why(it.lane, it.pos, it.reach, it.v)
		if why != 0:
			_park(it)
			_set_lat(it, why == 2)
			parked += 1
			return true
		_plan(it)
		early_n += 1
		return true

	## (early_stop) A stop after the drawn tick that a moving item's record runs into (the item stands at
	## (key, pos) from t0, having got there within the tick before): the record is made again from where the
	## item is now, ending at the stop, instead of running on past it to its line's end till the next job.
	## The stop itself stays waiting (applied at its tick, it stands the item where it already is). Made
	## once: cut already, the record ends there.
	func _cut_at_stop(it: Item, key: int, pos: int, t0: int, now: int) -> void:
		var ds := it.v * (t0 - it.t0)
		if ds <= 0:
			return
		# (The stop lies within the last tick's travel before ds: on the same lane a subtraction, across a
		# lane's end or at a dead end (where _advance stops at 0) found a step at a time.)
		var at := _advance(it.lane, it.pos, ds)
		var k := -1
		if at.y > 0 and at.x == key and pos >= at.y and pos - at.y < it.v:
			k = pos - at.y
		else:
			for j in it.v:
				var a2 := _advance(it.lane, it.pos, ds - j)
				if a2.x == key and a2.y == pos:
					k = j
					break
		if k < 0:
			return
		ds -= k
		if ds >= it.reach:
			return
		var d0 := clampi(it.v * (now - it.t0), 0, ds)
		var from := _advance(it.lane, it.pos, d0)
		it.lane = from.x
		it.pos = from.y
		it.t0 = maxi(it.t0, now) if d0 > 0 else it.t0
		it.reach = ds - d0
		var m: PackedInt32Array = state.lanes.get(it.lane, PackedInt32Array())
		it.run = it.pos + int(state.sim.run_of(it.lane)) if not m.is_empty() and m[0] == BeltSim.STRAIGHT else 0
		early_stop_n += 1
		var why := _hide_why(it.lane, it.pos, it.reach, it.v)
		if why != 0:
			_park(it)
			_set_lat(it, why == 2)
			parked += 1
			return
		_plan(it)

	## One change: the item's new motion, and its record.
	func _apply_one(uid: int, item: int, stack: int, key: int, pos: int, t0: int, v: int, reach: int, run: int) -> void:
		var it: Item = state.items.get(uid)
		if it == null:
			it = Item.new()
			it.uid = uid
			it.item_id = item
			it.key = item
			var a := ItemCards.turn_for(uid)
			it.c = cos(a)
			it.s = sin(a)
			it.parked = true
			it.waits = later_tick and not state.waiting.is_empty() and state.waiting.has(uid)
			state.items[uid] = it
		elif it.item_id != item:
			it.item_id = item
			_rekey(it, item)
		state.kept.erase(it)
		if BeltLattice.turn_id and BeltLattice.item_turns:
			# (turn_id) Turned by its number along its run, as the lattice's slot that has it (belt_lattice.gd _seed).
			var nm: int = state.nums.get(uid, -1)
			if nm >= 0 and nm != it.num:
				it.num = nm
				var na := ItemCards.lattice_turn(nm, BeltLattice.TURN_RUN)
				it.c = cos(na)
				it.s = sin(na)
		if it.key >= 0:
			var mk := _model_key(it)
			if mk != it.key:
				_rekey(it, mk)
		_set_count(it, stack)
		it.lane = key
		it.pos = pos
		it.t0 = t0
		it.v = v
		it.reach = reach
		it.run = run
		_touch(it)
		var why := _hide_why(key, pos, reach, v)
		if why != 0:
			if not it.parked:
				_park(it)
			_set_lat(it, why == 2)
			parked += 1
			return
		if it.parked:
			_unpark(it)
		_plan(it)

	## An item's record from its motion: standing; in a straight line as far as its straight run
	## goes; or along its lanes' points.
	func _plan(it: Item) -> void:
		var p0 := _point(it.lane, it.pos)
		it.from = Vector3(p0.x, p0.y, p0.z)
		it.target = it.from
		it.t_from = float(it.t0)
		it.renew = -1.0
		state.renewing.erase(it)
		it.path = PackedFloat32Array()
		it.hidden = p0.w < 0.5
		_mark(it)
		_touch(it)
		# Past its lane's back end (a read pushed it back off the line): in the game it is on a lane
		# behind, outside what is sent; hidden until it gets to the lane's entry, then on along it.
		var lm: PackedInt32Array = state.lanes.get(it.lane, PackedInt32Array())
		if not lm.is_empty() and it.pos > lm[1]:
			it.hidden = true
			it.step = Vector3.ZERO
			var behind := it.pos - lm[1]
			if it.v <= 0 or it.reach <= behind:
				it.t_to = it.t_from
				return
			if not lead_on:
				# (As before: hidden at the entry till it gets there, then made again.)
				it.t_to = it.t_from + float(behind) / float(it.v)
				it.renew = it.t_to
				state.renewing[it] = true
				return
			_plan_path(it, mini(it.reach, behind + ceili(it.v * 2.0 * lead)))
			return
		if it.v <= 0 or it.reach <= 0:
			it.step = Vector3.ZERO
			it.t_to = it.t_from
			return
		# Straight: its straight run (lanes of one speed and direction ahead, the simulation's `run`)
		# reaches as far as its motion does.
		if not it.hidden and it.run >= it.reach and _straight_kind(it.lane):
			var dir := _dir(it.lane)
			var d := float(it.reach) / 256.0
			it.step = Vector3(dir.x * d, 0.0, dir.y * d)
			it.t_to = it.t_from + float(it.reach) / float(it.v)
			return
		# Otherwise the record covers what is cheap to draw, and is made again where that ends (Item.renew):
		# to the end of its straight run, while it is under the ground (hidden), or across the curve it
		# is on (points SPACING apart along the curve). (Paths through whole lines cost tens of points
		# a change, most of a job on Zenith Test.)
		var meta: PackedInt32Array = state.lanes.get(it.lane, PackedInt32Array())
		var kind := meta[0] if not meta.is_empty() else BeltSim.OTHER
		var d: int
		if not it.hidden and it.run > 0 and kind == BeltSim.STRAIGHT:
			d = mini(it.run, it.reach)
		else:
			d = mini(it.pos, it.reach)
		if lead_on and d > 0 and d < it.reach and float(d) / float(it.v) < lead:
			# That ends before the next job could make it again: on across where it ends.
			_plan_path(it, mini(it.reach, maxi(d + ceili(it.v * lead), ceili(it.v * 2.0 * lead))))
			return
		if d <= 0:
			# At its lane's end: on from the next lane's entry.
			var nx: int = state.sim.next_of(it.lane)
			if nx == 0 or not state.lanes.has(nx) or _plan_depth > 8:
				it.step = Vector3.ZERO
				it.t_to = it.t_from
				return
			it.lane = nx
			it.pos = (state.lanes[nx] as PackedInt32Array)[1]
			_plan_depth += 1
			_plan(it)
			_plan_depth -= 1
			return
		it.t_to = it.t_from + float(d) / float(it.v)
		if kind == BeltSim.CURVE and not it.hidden:
			var n := clampi(ceili(d / (SPACING * 256.0)), 1, MAX_POINTS - 1)
			var path := PackedFloat32Array()
			path.resize((n + 1) * 4)
			for j in n + 1:
				var q := _point(it.lane, it.pos - float(d) * j / n)
				path[j * 4] = q.x - it.from.x
				path[j * 4 + 1] = 0.0
				path[j * 4 + 2] = q.z - it.from.z
				path[j * 4 + 3] = q.w
			it.path = path
			it.step = Vector3.ZERO
		else:
			var dir := _dir(it.lane)
			var dd := float(d) / 256.0
			it.step = Vector3(dir.x * dd, 0.0, dir.y * dd)
		if d < it.reach:
			it.renew = it.t_to
			state.renewing[it] = true

	## A record along the item's line for `dist` (1/256) from where it is, through the lanes ahead:
	## points SPACING apart (at most MAX_POINTS), each with where it shows (w >= 0.5: on a lane, not
	## under the ground). Where that changes between two points their w are set so that the shader's
	## blend of them crosses 0.5 just there: the item shows or hides at the lane's entry or end, not
	## half a point early or late.
	func _plan_path(it: Item, dist: int) -> void:
		var n := clampi(ceili(dist / (SPACING * 256.0)), 1, MAX_POINTS - 1)
		var piece := float(dist) / n
		var path := PackedFloat32Array()
		path.resize((n + 1) * 4)
		var shows := PackedByteArray()
		shows.resize(n + 1)
		var at := PackedInt32Array()  # each point's lane position, and lane
		at.resize(n + 1)
		var keys := PackedInt64Array()
		keys.resize(n + 1)
		var any := false
		for j in n + 1:
			var q := _advance(it.lane, it.pos, roundi(piece * j))
			var m: PackedInt32Array = state.lanes.get(q.x, PackedInt32Array())
			var w := _point(q.x, q.y)
			var on := w.w > 0.5 and not m.is_empty() and q.y <= m[1]
			if not m.is_empty() and q.y > m[1]:
				# (Past the lane's back: on the line its entry continues, so that it comes in at the entry.)
				var inner := _point(q.x, float(maxi(m[1] - 32, 0)))
				var back := Vector2(w.x - inner.x, w.z - inner.z).normalized() * (float(q.y - m[1]) / 256.0)
				w.x += back.x
				w.z += back.y
			path[j * 4] = w.x - it.from.x
			path[j * 4 + 1] = 0.0
			path[j * 4 + 2] = w.z - it.from.z
			path[j * 4 + 3] = 1.0 if on else 0.0
			shows[j] = 1 if on else 0
			at[j] = q.y
			keys[j] = q.x
			any = any or on
		for j in n:
			if shows[j] == shows[j + 1]:
				continue
			# Where between the two it changes: at its lane's entry (from past its back) or end.
			var m: PackedInt32Array = state.lanes.get(keys[j], PackedInt32Array())
			var b := float(at[j] - m[1]) if not m.is_empty() and at[j] > m[1] else float(at[j])
			var f := clampf(b / piece, 0.0, 1.0)
			if shows[j] == 1:
				path[j * 4 + 3] = 0.5 + f
				path[(j + 1) * 4 + 3] = f - 0.5
			else:
				path[j * 4 + 3] = 0.5 - f
				path[(j + 1) * 4 + 3] = 1.5 - f
		it.t_to = it.t_from + float(dist) / float(it.v)
		it.step = Vector3.ZERO
		it.hidden = not any
		it.path = path if any else PackedFloat32Array()
		if dist < it.reach:
			it.renew = it.t_to
			state.renewing[it] = true

	func _straight_kind(key: int) -> bool:
		var m: PackedInt32Array = state.lanes.get(key, PackedInt32Array())
		return not m.is_empty() and m[0] != BeltSim.CURVE and m[0] != BeltSim.UG_HIDDEN

	func _dir(key: int) -> Vector2:
		var m: PackedInt32Array = state.lanes.get(key, PackedInt32Array())
		if m.is_empty():
			return Vector2.ZERO
		return Vector2(m[3] - m[7], m[4] - m[8]).normalized()

	## Records whose motion goes on past their end are made again from where their item is now.
	func _renew() -> void:
		if state.renewing.is_empty():
			return
		var now := floori(fold_tick)
		for it: Item in state.renewing.keys():
			if it.renew < 0.0 or fold_tick + (lead if lead_on else 0.0) < it.renew:
				continue
			var d := it.v * (now - it.t0)
			if d >= it.reach or it.v <= 0:
				state.renewing.erase(it)
				continue
			if d <= 0:
				continue
			var at := _advance(it.lane, it.pos, d)
			it.lane = at.x
			it.pos = at.y
			it.reach -= d
			var m: PackedInt32Array = state.lanes.get(it.lane, PackedInt32Array())
			it.run = it.pos + int(state.sim.run_of(it.lane)) if not m.is_empty() and m[0] == BeltSim.STRAIGHT else 0
			it.t0 = now
			_plan(it)
			renewed += 1

	## Items kept for their chunk's far icons go once the icons exist (or after KEEP_UPDATES).
	func _keep_or_drop() -> void:
		state.held_chunks = {}
		if state.kept.is_empty():
			return
		for it: Item in state.kept.keys():
			var c: Vector2i = state.kept[it]
			it.kept += 1
			if it.kept > KEEP_UPDATES or far_built == null or (far_built as Dictionary).has(c):
				state.kept.erase(it)
				_remove(it.uid)
			else:
				state.held_chunks[c] = true

	## Where an item's record has it at tick t (straight or along its path).
	func _at(it: Item, t: float) -> Vector3:
		var g := 1.0 if it.t_to <= it.t_from else clampf((t - it.t_from) / (it.t_to - it.t_from), 0.0, 1.0)
		if it.path.is_empty():
			return it.from + it.step * g
		var o := BeltPaths.path_at(it.path, g)
		return it.from + Vector3(o.x, o.y, o.z)

	func _remove(uid: int) -> void:
		state.nums.erase(uid)
		var it: Item = state.items.get(uid)
		if it == null:
			return
		if dump != null:
			dump_gone.append(uid)
		_unplace(it)
		state.items.erase(uid)
		state.pathed.erase(it)
		_free_path(it)
		state.renewing.erase(it)
		state.kept.erase(it)
		state.lat_items.erase(it)

	func _free_path(it: Item) -> void:
		if it.path_at < 0:
			return
		var list: Array = state.path_free.get(it.path_cap, [])
		list.append(it.path_at)
		state.path_free[it.path_cap] = list
		it.path_at = -1
		it.path_cap = 0

	func _mark(it: Item) -> void:
		if not it.dirty:
			it.dirty = true
			state.dirty.append(it)

	func _set_count(it: Item, n: int) -> void:
		n = clampi(n, 1, MAX_STACK)
		it.count = n
		if it.slot < 0 or it.layers.size() == n - 1:
			return
		var kind: Kind = state.kinds[it.key]
		while it.layers.size() > n - 1:
			var gone: Layer = it.layers.pop_back()
			kind.slots[gone.slot] = null
			kind.free.append(gone.slot)
			kind.emptied.append(gone.slot)
			gone.slot = -1
		while it.layers.size() < n - 1:
			var layer := Layer.new()
			layer.it = it
			layer.k = it.layers.size() + 1
			_put(kind, layer)
			it.layers.append(layer)

	func _place(it: Item) -> void:
		var kind: Kind = state.kinds.get(it.key)
		if kind == null:
			kind = Kind.new()
			state.kinds[it.key] = kind
		_put(kind, it)

	## The camera leading the cap turned it on or off, moved or turned enough since the cap was worked out.
	func _cam_moved() -> bool:
		if cam_led != state.capped_cam:
			return true
		return cam_led and (cam_pos.distance_squared_to(state.capped_cam_pos) > VIEW_STEP * VIEW_STEP or cam_dir.dot(state.capped_cam_dir) < VIEW_TURN)

	## Settings → Items in 3D: the model_cap items nearest the square's centre stay models, the others
	## of items that have a model are drawn as their icons; near the edge within CAP_SLACK they keep
	## their look, so they don't flip back and forth. With the camera leading (cam_led): only items in
	## its view count, nearest the camera first, so an add-on's camera away from the character, first
	## person or the remote view spend the models on what is on screen; items behind it or off to the
	## side are icons.
	func _cap_models() -> void:
		if model_cap < 0:
			for uid in state.items:
				var it: Item = state.items[uid]
				var mk := _model_key(it)
				if it.key != mk:
					_rekey(it, mk)
			return
		var c := Vector2(state.square.x, state.square.y)
		var uids: Array = []
		var dists := PackedFloat32Array()
		var models := PackedByteArray()
		for uid in state.items:
			var it: Item = state.items[uid]
			var look: Array = known.get(it.item_id, [])
			var mk := _model_key(it)
			if not look.is_empty() and not bool(look[1]):
				if it.key != mk:
					_rekey(it, mk)
				continue
			var model := it.key >= 0
			if model and it.key != mk:
				_rekey(it, mk)
			uids.append(uid)
			models.append(1 if model else 0)
			if cam_led:
				# A model already keeps its look a little further outside the view too.
				dists.append(ViewPriority.view_distance_sq(it.from, cam_pos, cam_planes, ViewPriority.MARGIN + (CAP_SLACK if model else 0.0)))
			else:
				dists.append(c.distance_squared_to(Vector2(it.from.x, it.from.z)))
		if uids.is_empty():
			return
		var want := ViewPriority.choose(dists, models, model_cap, CAP_SLACK)
		for i in uids.size():
			if want[i] != models[i]:
				var it: Item = state.items[uids[i]]
				_rekey(it, _model_key(it) if want[i] == 1 else ItemCards.icon_key(it.item_id))

	## The kind an item is drawn as a model by: its item with the variant of its model (the main thread's look
	## of it, known's 4th: how many) that who it is picks, as its turn is (its number along its run, else its
	## unique id; ItemCards.lattice_variant, as a packed lane's slots), so it keeps it while it travels.
	func _model_key(it: Item) -> int:
		var look: Array = known.get(it.item_id, [])
		var n := int(look[3]) if look.size() > 3 else 0
		if n < 2:
			return it.item_id
		var v := ItemCards.lattice_variant(it.num, BeltLattice.TURN_RUN, n) if it.num >= 0 else ItemCards.lattice_variant(it.uid, 0, n)
		return it.item_id + v * ItemCards.VARIANT_STEP

	func _rekey(it: Item, key: int) -> void:
		if it.parked:
			it.key = key
			return
		var n := it.count
		_unplace(it)
		it.key = key
		_place(it)
		it.count = 1
		_set_count(it, n)
		_mark(it)

	func _put(kind: Kind, e) -> void:
		if kind.free.is_empty():
			e.slot = kind.slots.size()
			kind.slots.append(e)
		else:
			e.slot = kind.free.pop_back()
			kind.slots[e.slot] = e
		kind.fresh.append(e)

	func _unplace(it: Item) -> void:
		var kind: Kind = state.kinds.get(it.key)
		if kind == null:
			return
		for e in [it] + it.layers:
			if e.slot < 0:
				continue
			kind.slots[e.slot] = null
			kind.free.append(e.slot)
			kind.emptied.append(e.slot)
			e.slot = -1
		it.layers = []

	## Writes the records: new slots whole, emptied ones hidden, items whose motion changed, and every
	## item along a path (the paths' texture is made again each job).
	func _write() -> void:
		var recs := state.records
		_writes += 1
		var writing := _writes
		var batch: Array = []
		for it: Item in state.dirty:
			if it.path.is_empty() or state.items.get(it.uid) != it:
				state.pathed.erase(it)
				_free_path(it)
				continue
			state.pathed[it] = true
			# Its points into a run of the paths' texture (its own if it fits).
			var k := it.path.size() / 4
			if it.path_at < 0 or it.path_cap < k:
				_free_path(it)
				var cap := 8
				while cap < k:
					cap *= 2
				var list: Array = state.path_free.get(cap, [])
				if not list.is_empty():
					it.path_at = list.pop_back()
				elif state.path_top + cap <= PATH_WIDTH * MAX_ROWS:
					it.path_at = state.path_top
					state.path_top += cap
					if state.path_tex.size() < state.path_top * 4:
						var rows := 1
						while rows * PATH_WIDTH < state.path_top:
							rows *= 2
						state.path_tex.resize(rows * PATH_WIDTH * 4)
				it.path_cap = cap if it.path_at >= 0 else 0
			it.code = 0.0
			if it.path_at >= 0:
				var o := it.path_at * 4
				for q in it.path.size():
					state.path_tex[o + q] = it.path[q]
				it.code = 1.0 + it.path_at * 64 + (k - 2)
				state.path_dirty = true
			it.code_at = writing
		for item_id in state.kinds:
			var kind: Kind = state.kinds[item_id]
			var look: Array = known.get(item_id, [])
			if full:
				kind.known = false
			if not kind.known and not look.is_empty():
				kind.known = true
				kind.lift = look[0]
				kind.pile = float(look[2]) if look.size() > 2 else 0.07
				kind.fresh = kind.slots.filter(func(e) -> bool: return e != null)
			_compact(kind)
			var n := kind.slots.size()
			if n > kind.cap or kind.base < 0:
				var cap := BeltRecords.MIN_RUN
				while cap < maxi(n, kind.cap * 2):
					cap *= 2
				var base := recs.alloc(cap)
				if kind.base >= 0:
					recs.copy(kind.base, base, kind.cap)
					recs.release(kind.base, kind.cap)
				for i in range(kind.cap, cap):
					recs.hide(base + i)
				kind.base = base
				kind.cap = cap
			if not kind.known:
				unknown.append(item_id)
				continue
			for i in kind.emptied:
				if i < kind.cap:
					recs.hide(kind.base + i)
			kind.emptied.clear()
			for e in kind.fresh:
				if e.slot >= 0:
					batch.append(e)
			kind.fresh.clear()
			var told := Vector3i(kind.base, n, kind.cap)
			if full or told != kind.told:
				kind.told = told
				written.append([item_id, kind.base, n, kind.cap])
		for it: Item in state.dirty:
			it.dirty = false
			if it.slot < 0:
				continue
			var kind: Kind = state.kinds.get(it.key)
			if kind == null or not kind.known:
				continue
			batch.append(it)
			if not pile_one:
				batch.append_array(it.layers)
			# (Else its pile's copies point at its record: nothing to write when it moves.)
		state.dirty = []
		_records(batch, writing)
		if state.path_dirty and not state.path_tex.is_empty():
			state.path_dirty = false
			paths = Image.create_from_data(PATH_WIDTH, state.path_tex.size() / 4 / PATH_WIDTH, false, Image.FORMAT_RGBAF,
				state.path_tex.to_byte_array())
		pages = recs.take_pages()

	## Slots' records: an item's motion, turn and lift; a pile's copy (Layer) only points at its item's
	## record (texel 3: the item's slot from its own, its step k in the pile, the kind's pile step) and
	## holds its own turn (texel 2), written once when it is placed: the shader lifts it by k.
	func _records(batch: Array, writing: int) -> void:
		var recs := state.records
		var d := recs.data
		recs.data = PackedFloat32Array()
		var base := recs.base
		var dirty := recs.dirty
		var per_page := recs.per_page
		var n := 0
		for e in batch:
			if e.slot < 0 or e.stamp == writing:
				continue
			e.stamp = writing
			n += 1
			var it: Item = e if e is Item else (e as Layer).it
			var kind: Kind = state.kinds[it.key]
			var r: int = kind.base + e.slot
			var o := r * BeltRecords.FLOATS
			if e is Layer and pile_one:
				# (Its own turn in texel 2: ItemCards.turn_for(uid, k), cards and blocks too.)
				for q in BeltRecords.FLOATS:
					d[o + q] = 0.0
				var a := atan2(it.s, it.c) + PILE_TURN * (e as Layer).k
				d[o + 8] = cos(a)
				d[o + 9] = sin(a)
				d[o + 12] = float(it.slot - e.slot)
				d[o + 13] = float((e as Layer).k)
				d[o + 14] = kind.pile
				dirty[r / per_page] = true
				continue
			# Every item turns, models, icon cards and blocks alike (ItemCards.turn_for): a lone card
			# left square stood straight beside turned models and the far icons (owner).
			var c := it.c
			var s := it.s
			var lift := kind.lift.y + LAYER_STEP * (it.uid % LAYERS)
			if e is Layer:
				# (--belt-draw-pile=off: the copy's own record, a step higher and turned PILE_TURN more each.)
				lift += kind.pile * (e as Layer).k
				var a := atan2(it.s, it.c) + PILE_TURN * (e as Layer).k
				c = cos(a)
				s = sin(a)
			var code := 0.0
			if it.hidden:
				code = BeltRecords.HIDDEN
			elif not it.path.is_empty():
				code = it.code
			d[o] = it.from.x
			d[o + 1] = it.from.y
			d[o + 2] = it.from.z
			d[o + 3] = it.t_from - base
			d[o + 4] = it.step.x
			d[o + 5] = it.step.y
			d[o + 6] = it.step.z
			d[o + 7] = it.t_to - base
			d[o + 8] = c
			d[o + 9] = s
			d[o + 10] = lift
			d[o + 11] = code
			d[o + 12] = 0.0
			d[o + 13] = 0.0
			d[o + 14] = 0.0
			d[o + 15] = it.hide_at - base if it.hide_at >= 0.0 else (base - it.show_at if it.show_at >= 0.0 else 0.0)
			dirty[r / per_page] = true
			if dump != null and e is Item:
				dump_ids.append_array(PackedInt64Array([it.uid, it.item_id, it.count, it.lane, it.pos, it.t0, it.v, it.reach]))
				dump_recs.append_array(d.slice(o, o + BeltRecords.FLOATS))
		records_written += n
		recs.data = d

	func _compact(kind: Kind) -> void:
		while not kind.slots.is_empty() and kind.slots.back() == null:
			kind.slots.pop_back()
		var n := kind.slots.size()
		if kind.free.size() > 64 and kind.free.size() * 2 > n:
			var packed := []
			for e in kind.slots:
				if e != null:
					e.slot = packed.size()
					packed.append(e)
			kind.slots = packed
			kind.fresh = packed.duplicate()
			kind.free.clear()
			kind.emptied.clear()
			return
		if kind.free.size() > 0:
			var kept: Array[int] = []
			for i in kind.free:
				if i < n:
					kept.append(i)
			kind.free = kept


var protos: ProtoDB:
	set(value):
		protos = value
		_cards.protos = value
		_lat_cards.protos = value
		_drop_cards.protos = value

## world.gd (main.gd sets it; lanes come from the bridge now, so nothing is read from it).
var world = null

## (The debug menu's update overlays, update_overlay.gd) Called with each job once it is applied: no job runs
## then, the one moment the main thread may read the simulation's and the lattice's state. Reads only. Unset
## (the default) it costs one check a job.
var debug_tap: Callable

## The bridge sent `bi`: it is older than `bs` and nothing near is drawn from it (handle(); once a
## connection, main.gd shows the player a message).
signal old_bridge
var old_bridge_seen := false

var _cards := ItemCards.new()
var _lat_cards := ItemCards.new()  # (--belt-draw-lattice) the lattice's kinds, records from f3d_belt_lattice
var _lat_records: Texture2DArray = null
var _lat_mask: ImageTexture = null
## The lattice's mask image as its last job left it (tests: a texture made headless keeps its first image).
var _lat_mask_img: Image = null


## Item kinds whose model or icon is still being read (full_detail.gd waits for them).
func looks_pending() -> int:
	return _cards._loading.size() + _lat_cards._loading.size()

var _state := State.new()
## belt_lanes.gd (main.gd sets it): the far icons this layer hands over to.
var lanes: Node = null
## The camera drawing leads Items in 3D's cap (main.gd, view_priority.gd camera_led()): an add-on's
## camera, first person, the remote view. Only which items are models changes, never how they move.
var view_led := false
var _paths: ImageTexture = null
var _records: Texture2DArray = null
var _record_pages := 0
var _clock_base := -1.0
var _paths_image: Image = null
var _inbox: Array = []
## A big update comes in many parts, spread over frames by the bridge's message handling: they go to
## a job together, once all have come (or the next update does).
var _parts: Array = []
var _parts_tick := -1
## (K22, --belt-sim-removed-now=off: as before) Belts Zenith has taken away (`mnd`, `del`: main.gd), unit -> the
## tile it stood on, and the tiles a belt was built on meanwhile (`add`). The next job takes a removed belt's lanes
## out of the simulation and its items out of the drawing there and then (an internal `brm` message, first in the
## job); one with a belt built on its tile since is left to the bridge's `bs` (a fast-replace: `add` and `del`
## come together, the game keeps the items and the new lanes take them over, replace_at). Before, the lanes stayed
## until the bridge's `dl`, and a dropped lane's items stood up to KEEP_UPDATES jobs for far icons that never come
## inside the square: a belt mined with items left them drawn for a while.
static var removed_now := true
## --belt-drop-show-now=on (the default) | off: an item Zenith's Z drops on a belt (player_input.gd predict_drop) is
## shown at once where it lands, standing on the nearest lane drawn, until the drawn clock (about half a second behind
## the game) reaches the tick the bridge says it was put on (`ie` kind 6 with no inserter, drop_put): the simulated
## item shows there from that tick (the hands' put path), so it takes over in place. One the bridge doesn't confirm
## (out of reach, the belt full there, an older bridge) goes after DROP_SHOW_MSEC. Off: as before, the item shows
## when the drawn clock reaches the put (or the lane's next read).
static var drop_show_now := true
const DROP_SHOW_MSEC := 1500
## Drops shown ahead of the game: [item id, where (Vector3), the put's tick or -1 till the bridge says, msec made].
var _drops: Array = []
var _drop_cards := ItemCards.new()
var _removed := {}
var _built_tiles := {}
var _job: Job = null
var _task := -1
var _known := {}  # item id -> [lift, turns, pile step], kinds item_cards.gd has dressed
var _dressing := {}  # item id -> true: kinds made, their looks still being read
## (A4) _known's changes counted; the copy the jobs read and the count it was made at; the far icons' chunks
## as last listed and belt_lanes.gd's count of their changes then (-2: far icons off).
var _known_ver := 0
var _known_copy = null
var _known_sent := -1
var _far_copy = null
var _far_ver := -3
## --belt-draw-skip-same=off: every job gets a fresh copy of the looks and of the far icons' chunks, the far
## icons are handed the square every result and the lattice's switch set every result, as before. On (the
## default): only when they changed.
static var skip_same := true
var _ho_last: Array = []  # what lanes.hand_over was last given
var _lat_on_set := -1.0
var _rewrite := false
## Items are drawn on the game's clock (the messages' ticks, run on at its measured rate), one gap
## between updates and a margin for the jobs behind it.
var _clock := GameClock.new()
var _drawn := -1.0
var _job_ticks := 1.0
var _margin := DRAW_MARGIN
var _count := 0
var _square := Vector3(0.0, 0.0, -1.0)
var _positions := {}
var _watch := {}
var _hands: Array = []  # (--inserter-handoff) Job.hands not yet taken by the arms
var watch_all := false
var _epoch := -1
var _height_known := false
## --belt-items-sync: jobs run on the main thread at once (tests).
var _sync := false
var _held_job: Job = null
## --belt-capture=<file>: every `bs` message, a line each (tests/belt_bs_replay.gd replays them).
var _capture: FileAccess = null
## (--belt-capture) --belt-capture-thread=on writes the capture on a thread of its own: JSON.stringify of
## a first load's 28 KB updates costs the main thread 2-3 ms each, 5.5 s over a join (--stutter-probe, bs
## handling), which the thread takes off it. Off (the default) writes inline: on this 4-core PC the thread
## made the join worse (three joins at -62,-26 with it: 50-59 frames over 33 ms, the worst belt job
## 1.3-2.2 s, the first load done at 69-89 s; two inline: 30-37, 0.77-0.88 s, 53-57 s).
static var capture_thread := false
var _capture_thread: Thread = null
var _capture_queue: Array = []
var _capture_mutex := Mutex.new()
var _capture_sem := Semaphore.new()
var _capture_stop := false
var _bench := false
var _bench_frames := 0
var _bench_contact := 0  # frames of them with the items' rims drawn (--belt-item-contact=flip)
var _bench_time := 0.0
var _bench_worst := 0.0
var _bench_usec := 0
var _bench_worker_usec := 0
var _bench_jobs := 0
## Totals for probes.
var stats := {"frames": 0, "main_usec": 0, "jobs": 0, "worker_usec": 0, "worst_job_usec": 0, "sim_usec": 0,
	"write_usec": 0, "changes": 0, "renewed": 0, "records_written": 0, "pages": 0, "upload_usec": 0, "asked": 0}
## When the bridge's first load ended (the first `bs` update without `ld` after ones with it), in
## ticks msec; 0 while it hasn't (--stutter-probe's JOIN line).
var load_done_msec := 0
var _load_seen := false


## Main-thread time by part of _apply into world.prof (--stutter-probe shows them as w_bi_<key>; kept
## only while it runs).
func _prof(key: String, t0: int) -> void:
	if Probing.on and world != null and "prof" in world:
		world.prof["bi_" + key] = int(world.prof.get("bi_" + key, 0)) + Time.get_ticks_usec() - t0


## The drawing's toggles from the command line (Job.ahead, gone_order, lead_on, State.head_move: all
## on by default; docs/RUNNING.md). The replays read the same.
static func read_flags(args: PackedStringArray) -> void:
	for a in args:
		if a.begins_with("--belt-sim-ahead="):
			Job.ahead_auto = a.substr(17) == "auto"
			Job.ahead = AHEAD if Job.ahead_auto else maxi(0, int(a.substr(17)))
		elif a.begins_with("--belt-draw-gone-order="):
			Job.gone_order = a.substr(23) != "off"
		elif a.begins_with("--belt-draw-lead="):
			Job.lead_on = a.substr(17) != "off"
		elif a.begins_with("--belt-draw-lead-max="):
			lead_max = maxf(2.0, float(a.substr(21)))
		elif a.begins_with("--belt-draw-head-move="):
			State.head_move = a.substr(22) != "off"
		elif a.begins_with("--belt-sim-read-apply="):
			Job.read_apply = a.substr(22) != "off"
		elif a.begins_with("--belt-sim-read-conserve="):
			Job.read_conserve = a.substr(25) != "off"
		elif a.begins_with("--belt-sim-read-forward="):
			Job.read_forward = a.substr(24) != "off"
		elif a.begins_with("--belt-sim-shift-keep="):
			Job.shift_keep = a.substr(22) != "off"
		elif a.begins_with("--belt-sim-read-skip-same="):
			Job.read_skip_same = a.substr(26) != "off"
		elif a.begins_with("--belt-sim-take-first="):
			Job.take_first = a.substr(22) != "off"
		elif a.begins_with("--belt-sim-take-line="):
			Job.take_line = a.substr(21) != "off"
		elif a.begins_with("--belt-sim-rescue-seen="):
			Job.rescue_seen = a.substr(23) != "off"
		elif a.begins_with("--belt-sim-take-edge="):
			Job.take_edge = a.substr(21) != "off"
		elif a.begins_with("--belt-sim-ug-guard="):
			Job.ug_guard = a.substr(20) != "off"
		elif a.begins_with("--belt-sim-hold="):
			Job.hold = a.substr(16) != "off"
		elif a.begins_with("--belt-sim-dead-walls="):
			Job.dead_walls = a.substr(22) == "on"
		elif a.begins_with("--belt-sim-split-wake="):
			Job.split_wake = a.substr(22) != "off"
		elif a.begins_with("--belt-sim-ask-unknown="):
			Job.ask_unknown = a.substr(23) != "off"
		elif a.begins_with("--belt-sim-replace-at="):
			Job.replace_at = a.substr(22) != "off"
		elif a.begins_with("--belt-sim-removed-now="):
			removed_now = a.substr(23) != "off"
		elif a.begins_with("--belt-drop-show-now="):
			drop_show_now = a.substr(21) != "off"
		elif a.begins_with("--belt-draw-coalesce="):
			Job.coalesce = a.substr(21) != "off"
		elif a.begins_with("--belt-draw-early="):
			Job.early = a.substr(18) != "off"
		elif a.begins_with("--belt-draw-lead-lag="):
			lead_lag = maxf(0.0, float(a.substr(21)))
		elif a.begins_with("--belt-draw-early-stop="):
			Job.early_stop = a.substr(23) != "off"
		elif a.begins_with("--belt-draw-view="):
			Job.view_cull = a.substr(17) != "off"
		elif a.begins_with("--belt-draw-view-ground="):
			view_ground = a.substr(24) != "off"
		elif a.begins_with("--belt-draw-view-lead="):
			view_lead = a.substr(22) != "off"
		elif a.begins_with("--belt-draw-margin="):
			margin_max = maxf(DRAW_MARGIN, float(a.substr(19)))
		elif a.begins_with("--belt-draw-native="):
			State.draw_native = a.substr(19) != "off"
		elif a.begins_with("--belt-sim-native="):
			State.force_gd = a.substr(18) == "off"
		elif a.begins_with("--belt-draw-pile="):
			Job.pile_one = a.substr(17) != "off"
		elif a.begins_with("--belt-draw-dump-parks="):
			Job.dump_parks = a.substr(23) != "off"
		elif a.begins_with("--belt-job-high="):
			job_high = a.substr(16) != "off"
		elif a.begins_with("--belt-draw-lattice-pile="):
			BeltLattice.piles = a.substr(25) != "off"
		elif a.begins_with("--belt-draw-lattice-native="):
			State.lattice_native = a.substr(27) != "off"
		elif a.begins_with("--belt-draw-lattice="):
			BeltLattice.on = a.substr(20) != "off"
			BeltLattice.world = a.substr(20) != "sim"
		elif a.begins_with("--belt-draw-lattice-unison="):
			BeltLattice.unison = a.substr(27) != "off"
		elif a.begins_with("--belt-draw-lattice-settle="):
			BeltLattice.settle = a.substr(27) != "off"
		elif a.begins_with("--belt-draw-lattice-creep="):
			BeltLattice.creep = a.substr(26) == "on" or a.substr(26) == "flow"
			BeltLattice.creep_flow = a.substr(26) != "on"
			BeltLattice.creep_step = a.substr(26) == "step"
		elif a.begins_with("--belt-draw-lattice-world="):
			BeltLattice.world_all = a.substr(26) != "straight"
		elif a.begins_with("--belt-draw-lattice-standing="):
			BeltLattice.standing_obs = a.substr(29) != "world"
		elif a.begins_with("--belt-draw-lattice-turns="):
			BeltLattice.item_turns = a.substr(26) != "slot"
		elif a.begins_with("--belt-draw-lattice-mask="):
			BeltLattice.mask_inner = a.substr(25) != "ends"
			BeltLattice.mask_own = a.substr(25) == "own"
		elif a.begins_with("--belt-draw-lattice-open="):
			BeltLattice.mask_open = a.substr(25) != "off"
		elif a.begins_with("--belt-draw-handover="):
			BeltLattice.handover = a.substr(21) != "old"
		elif a.begins_with("--belt-draw-turn-id="):
			BeltLattice.turn_id = a.substr(20) != "old"
		elif a.begins_with("--belt-draw-edge-shut="):
			BeltLattice.edge_shut = a.substr(22) != "off"
		elif a.begins_with("--belt-draw-lattice-close="):
			BeltLattice.close = a.substr(26) != "off"
		elif a.begins_with("--belt-draw-lattice-sim-full="):
			BeltLattice.sim_full = a.substr(29) != "off"
		elif a.begins_with("--belt-draw-lattice-tail="):
			BeltLattice.tail = a.substr(25) != "off"
		elif a.begins_with("--belt-draw-lattice-start="):
			BeltLattice.start = a.substr(26) != "off"
			BeltLattice.start_stops = a.substr(26) == "stops"
		elif a.begins_with("--belt-capture-thread="):
			capture_thread = a.substr(22) == "on"
		elif a.begins_with("--belt-draw-later-tick="):
			Job.later_tick = a.substr(23) != "off"
		elif a.begins_with("--belt-draw-park-lattice="):
			Job.park_lat = a.substr(25) == "on"
		elif a.begins_with("--belt-sim-ask="):
			Job.ask_view = a.substr(15) != "all"
		elif a.begins_with("--belt-sim-ask-near="):
			Job.ask_near = a.substr(20) != "off"
		elif a.begins_with("--belt-draw-skip-same="):
			skip_same = a.substr(22) != "off"
		elif a.begins_with("--belt-draw-small-pages="):
			BeltRecords.small = a.substr(24) != "off"
		elif a.begins_with("--inserter-handoff-slack="):
			Job.handoff_slack = maxi(0, int(a.substr(25)))
		elif a.begins_with("--inserter-handoff-margin="):
			handoff_margin = maxf(0.0, float(a.substr(26)))
	InserterArms.read_flags(args)
	_ahead_fixed = AHEAD if Job.ahead_auto else Job.ahead
	for l: Array in LIVE:
		_live_start[l[0]] = live_in_use(l[0])


## (debug menu, Simulation tab: debug_menu.gd) The belt fixes a tester switches off and on while playing,
## [id, name, what it does]. Only switches a job reads afresh each time and that leave nothing half done when
## flipped: not take_first or take_line (the simulation queues takes and reads for them, which would be left
## waiting), nor the lattice's creep (a lane sliding at its share isn't unwound); those need a restart.
## Nothing is saved.
const LIVE := [
	["early_stop", "Early stop", "A moving item's record ends where a stop after the drawn tick is, instead of running past it and being pulled back a job later (--belt-draw-early-stop)"],
	["ahead_auto", "Longer lead", "The simulation runs at least a job gap past the drawn tick, the drawn clock a little further behind the game for it (--belt-sim-ahead=auto, --belt-draw-lead-lag); off: a fixed lead (24 ticks, or the command line's)"],
	["rescue_seen", "Rescue seen", "A read doesn't put back an item the game no longer has where the lane was read without it: no phantoms from inserters' takes (--belt-sim-rescue-seen)"],
	["early", "Early changes", "A start or continuation after the drawn tick taken now instead of a job later: no bunching at a loop's cut (--belt-draw-early)"],
	["take_edge", "Take past the edge", "A take finds its item past its belt's front edge too, where it ran on onto the next belt (--belt-sim-take-edge)"],
	["lattice_open", "Open lattice ends", "A moving packed lane beside one drawn from the simulation lets that lane's items show in its end cell: no gap standing at the join while the line moves (--belt-draw-lattice-open)"],
	["handover", "Clean handover", "At an open lattice end each item is drawn once, by its slot or by the simulation, not both (--belt-draw-handover)"],
	["edge_shut", "Shut edge ends", "A packed lane leading out of the loaded square keeps its exit drawn by its slots, not the simulation's items stopped there as a guess (--belt-draw-edge-shut)"],
	["turn_id", "Items keep their turn", "Each item is numbered along its run and turned by its number, in packed lanes and out of them, so it keeps one turn where they meet (--belt-draw-turn-id; items already drawn take it at their next change)"],
	["lattice_tail", "Tails let go", "A packed lane whose line's tail has gone onto it, nothing close behind, is drawn from the simulation at once, not full till the bridge's next check (--belt-draw-lattice-tail)"],
	["lead_long", "Long lead", "A busy client's records that end before its next job (at a curve, a run's end) are made again in time: its lead up to 32 ticks, not 8, so no items stand at curves (--belt-draw-lead-max)"],
]
## The switches the simulation itself holds (BeltSim and BeltSimNative alike), set on it between jobs.
const LIVE_SIM := ["rescue_seen", "take_edge"]
## (ahead_auto off) The fixed lead: the command line's --belt-sim-ahead=N, else AHEAD.
static var _ahead_fixed := AHEAD
## Changes from the menu waiting for the next job's start (_take_live): a running job (on a worker thread)
## reads the statics and its simulation's switches, so they change only between jobs, on the main thread.
static var _live := {}
## Each switch as the command line set it (read_flags).
static var _live_start := {}


## A switch's value: the one waiting for the next job, else the one in use (at first the command line's).
static func live_on(id: String) -> bool:
	return bool(_live[id]) if _live.has(id) else live_in_use(id)


## A switch's value as the command line set it (as the jobs use it now, before read_flags).
static func live_started(id: String) -> bool:
	return bool(_live_start[id]) if _live_start.has(id) else live_in_use(id)


## A switch's value as the jobs use it now.
static func live_in_use(id: String) -> bool:
	match id:
		"early_stop": return Job.early_stop
		"ahead_auto": return Job.ahead_auto
		"rescue_seen": return Job.rescue_seen
		"early": return Job.early
		"take_edge": return Job.take_edge
		"lattice_open": return BeltLattice.mask_open
		"handover": return BeltLattice.handover
		"turn_id": return BeltLattice.turn_id
		"edge_shut": return BeltLattice.edge_shut
		"lattice_tail": return BeltLattice.tail
		"lead_long": return lead_max > LEAD_OLD
	return false


## A switch changed (the debug menu): taken at the next job's start.
static func set_live(id: String, on: bool) -> void:
	_live[id] = on


## (main thread, no job running) The waiting switches into the statics a job reads, and into this
## simulation's own (a State made later takes them from the statics).
func _take_live() -> void:
	if _live.is_empty():
		return
	for id: String in _live:
		var on: bool = _live[id]
		match id:
			"early_stop": Job.early_stop = on
			"ahead_auto":
				Job.ahead_auto = on
				Job.ahead = AHEAD if on else _ahead_fixed
			"rescue_seen": Job.rescue_seen = on
			"early": Job.early = on
			"take_edge": Job.take_edge = on
			"lattice_open": BeltLattice.mask_open = on
			"handover": BeltLattice.handover = on
			"turn_id": BeltLattice.turn_id = on
			"edge_shut": BeltLattice.edge_shut = on
			"lattice_tail": BeltLattice.tail = on
			"lead_long": lead_max = LEAD_LONG if on else LEAD_OLD
		if id in LIVE_SIM and _state != null and _state.sim != null:
			# (set(): a library built before the switch has no such property and runs as before.)
			_state.sim.set(id, on)
	_live.clear()


static func flags_text() -> String:
	return ("ahead auto (at least %d, lag +%.0f at most), " % [Job.ahead, lead_lag] if Job.ahead_auto else "ahead %d, " % Job.ahead) + "early stop %s, " % ("on" if Job.early_stop else "off") + "gone order %s, lead %s, head move %s, read apply %s, read conserve %s, read forward %s, shift keep %s, read skip same %s, take first %s, take line %s, take edge %s, rescue seen %s, ug guard %s, hold %s, dead walls %s, split wake %s, coalesce %s, view %s, margin %.0f, native draw %s, pile %s, lattice %s%s, lattice unison %s, lattice settle %s, early %s, job %s" % [
		"on" if Job.gone_order else "off", "on" if Job.lead_on else "off", "on" if State.head_move else "off",
		"on" if Job.read_apply else "off", "on" if Job.read_conserve else "off", "on" if Job.read_forward else "off", "on" if Job.shift_keep else "off",
		"on" if Job.read_skip_same else "off", "on" if Job.take_first else "off", "on" if Job.take_line else "off", "on" if Job.take_edge else "off", "on" if Job.rescue_seen else "off", "on" if Job.ug_guard else "off", "on" if Job.hold else "off",
		"on" if Job.dead_walls else "off", "on" if Job.split_wake else "off", "on" if Job.coalesce else "off", "on" if Job.view_cull else "off", margin_max,
		"on" if State.draw_native and ClassDB.class_exists(NATIVE_DRAW) else "off", "one" if Job.pile_one else "each",
		(("world " + ("all" if BeltLattice.world_all else "straight")) if BeltLattice.world else "sim") if BeltLattice.on else "off",
		(", lattice standing " + ("obs" if BeltLattice.standing_obs else "world") + ", lattice piles " + ("on" if BeltLattice.piles else "off")
			+ ", lattice turns " + ("item" if BeltLattice.item_turns else "slot")
			+ ", lattice mask " + ("own" if BeltLattice.mask_own else "entry" if BeltLattice.mask_inner else "ends") + ", lattice open " + ("on" if BeltLattice.mask_open else "off") + ", handover " + ("new" if BeltLattice.handover else "old") + ", turn id " + ("new" if BeltLattice.turn_id else "old") + ", edge shut " + ("on" if BeltLattice.edge_shut else "off") + ", lattice close " + ("on" if BeltLattice.close else "off")
			+ ", lattice sim full " + ("on" if BeltLattice.sim_full else "off") + ", lattice tail " + ("on" if BeltLattice.tail else "off") + ", lattice start " + (("stops" if BeltLattice.start_stops else "on") if BeltLattice.start else "off") + ", lattice creep " + (("flow" if BeltLattice.creep_flow else "on") if BeltLattice.creep else ("step" if BeltLattice.creep_step else "off"))
			+ ", lattice native " + ("on" if State.lattice_native and ClassDB.class_exists(NATIVE_LATTICE) else "off")) if BeltLattice.on else "",
		"on" if BeltLattice.unison else "off", "on" if BeltLattice.settle else "off", "on" if Job.early else "off",
		"high" if job_high else "low"] + ", later %s, park lattice %s, ask %s%s, skip same %s, pages %s, replace at %s, removed now %s" % [
		"tick" if Job.later_tick else "list", "on" if Job.park_lat else "off", "view" if Job.ask_view else "all",
		" near" if Job.ask_near else "", "on" if skip_same else "off", "64 KB" if BeltRecords.small else "256 KB",
		"on" if Job.replace_at else "off", "on" if removed_now else "off"] 		+ ", " + InserterArms.flags_text() + (" (slack %d, margin %.1f jobs)" % [Job.handoff_slack,
		handoff_margin] if InserterArms.wants_handoff() else "")


func _ready() -> void:
	_clock.ease = 0.5
	_cards.name = "Cards"
	_cards.contact = true  # a soft rim on the belt under each item (item_contact.gdshader)
	_cards.casts_shadow = false
	_cards.render_layers = ItemCards.BELT_LAYER
	add_child(_cards)
	_lat_cards.name = "LatticeCards"
	_lat_cards.contact = true
	_lat_cards.casts_shadow = false
	_lat_cards.render_layers = ItemCards.BELT_LAYER
	_lat_cards.record_tex = 1
	add_child(_lat_cards)
	_drop_cards.name = "DropCards"
	_drop_cards.contact = true
	_drop_cards.casts_shadow = false
	_drop_cards.render_layers = ItemCards.BELT_LAYER
	add_child(_drop_cards)
	_bench = "--item-bench" in OS.get_cmdline_user_args()
	# A movie's frame stands for 1/60 s while workers take real time: jobs would land late on its clock.
	_sync = _sync or "--belt-items-sync" in OS.get_cmdline_user_args() or Engine.get_write_movie_path() != ""
	Job.debug = "--belt-sim-debug" in OS.get_cmdline_user_args()
	read_flags(OS.get_cmdline_user_args())
	if State.force_gd and not (_state.sim is BeltSim) or _state.records.rows != BeltRecords.new().rows:
		_state = State.new()  # (--belt-sim-native=off, --belt-draw-small-pages: the first was made before the flags were read)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--belt-capture="):
			_capture = FileAccess.open(a.substr(15), FileAccess.WRITE)
		elif a.begins_with("--belt-draw-dump="):
			Job.dump = FileAccess.open(a.substr(17), FileAccess.WRITE)
			Job.dump_apply = FileAccess.open(a.substr(17) + ".apply.jsonl", FileAccess.WRITE)
	if _bench:
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)


func _exit_tree() -> void:
	_wait(false)
	_capture_close()


## Queues a message for the capture file (written on _capture_thread), or writes it now.
func _capture_line(msg: Dictionary) -> void:
	# (A binary part's packed lists written as its JSON has them: the capture reads the same either way.)
	msg = WireDecode.plain(msg)
	if not capture_thread:
		_capture.store_line(JSON.stringify(msg))
		return
	if _capture_thread == null:
		_capture_thread = Thread.new()
		_capture_thread.start(_capture_run)
	_capture_mutex.lock()
	_capture_queue.append(msg)
	_capture_mutex.unlock()
	_capture_sem.post()


## The capture thread: writes queued messages as JSON until told to stop (the queue is drained first).
func _capture_run() -> void:
	while true:
		_capture_sem.wait()
		_capture_mutex.lock()
		var batch := _capture_queue
		_capture_queue = []
		var stop := _capture_stop
		_capture_mutex.unlock()
		for m in batch:
			_capture.store_line(JSON.stringify(m))
		if stop and batch.is_empty():
			break
	_capture.flush()


func _capture_close() -> void:
	if _capture_thread == null:
		return
	_capture_mutex.lock()
	_capture_stop = true
	_capture_mutex.unlock()
	_capture_sem.post()
	_capture_thread.wait_to_finish()
	_capture_thread = null


func reset() -> void:
	_parts = []
	_parts_tick = -1
	_wait(false)
	var height := _state.height
	var inset := _state.lane_inset  # (read once from the belt's pack in _find_height: a new State would drop it for good)
	_state = State.new()
	_state.height = height
	_state.lane_inset = inset
	old_bridge_seen = false
	_inbox.clear()
	_removed.clear()
	_built_tiles.clear()
	_cards.reset()
	_lat_cards.reset()
	_drop_cards.reset()
	_drops.clear()
	_lat_records = null
	RenderingServer.global_shader_parameter_set("f3d_belt_lattice_on", 0.0)
	_lat_on_set = 0.0
	_known.clear()
	_known_ver += 1
	# (A new State: its records start with no looks and no far icons' chunks.)
	_known_sent = -1
	_known_copy = null
	_far_copy = null
	_far_ver = -3
	_ho_last = []
	_dressing.clear()
	_positions.clear()
	_count = 0
	_square = Vector3(0.0, 0.0, -1.0)
	_clock = GameClock.new()
	_clock.ease = 0.5
	_drawn = -1.0
	_records = null
	_record_pages = 0
	_clock_base = -1.0


## (drop_show_now) Zenith's Z with `item_id` held, over (x, y) (tiles; player_input.gd): shown at once where it lands
## on a belt, ahead of the drawn clock, until the simulated item takes over (the bridge's put, drop_put). Only for a
## bridge that tells such puts (the hello's `ho`); nothing when no lane drawn is under it.
func predict_drop(item_id: int, x: float, y: float) -> void:
	if not drop_show_now or item_id <= 0 or not InserterArms.wants_handoff() or _drawn < 0.0:
		return
	_inbox.append({"t": "zp", "i": item_id, "x": roundi(x * 256.0), "y": roundi(y * 256.0)})


## The drops shown ahead (tests): [item id, where, the put's tick or -1, msec made].
func drops_shown() -> Array:
	return _drops


## (drop_show_now) A job's drops placed and the bridge's puts with no inserter: each put takes the oldest drop of its
## item not yet told (moved to exactly where the game put it), which then goes when the drawn clock reaches the put.
func _drops_heard(placed: Array, puts: Array) -> void:
	var now := Time.get_ticks_msec()
	for d: Array in placed:
		_drops.append([int(d[0]), d[1], -1, now])
	for p: Array in puts:
		for d: Array in _drops:
			if int(d[0]) == int(p[0]) and int(d[2]) < 0:
				d[1] = p[2]
				d[2] = int(p[1])
				break
	_drops_due(true)


## Drops whose put the drawn clock has reached, or the bridge never told, go; the rest drawn (on a change).
func _drops_due(changed := false) -> void:
	var now := Time.get_ticks_msec()
	var keep: Array = []
	for d: Array in _drops:
		var put := int(d[2])
		if put >= 0 and _drawn >= float(put) or now - int(d[3]) > (DROP_SHOW_MSEC * 4 if put >= 0 else DROP_SHOW_MSEC):
			changed = true
		else:
			keep.append(d)
	_drops = keep
	if not changed:
		return
	var groups := {}
	for d: Array in _drops:
		var id := int(d[0])
		if not groups.has(id):
			groups[id] = []
		groups[id].append(d[1])
	_drop_cards.draw(groups)


## The game tick the items are drawn at (the clock less the update gap and the jobs' margin), -1
## before the first update; inserter_arms.gd draws the arms at the same tick.
func drawn_tick() -> float:
	return _drawn


## Where items ride on the belts drawn (their base above the ground: the belt model's top), for an
## inserter's grip to close on them there (inserter_arms.gd --inserter-grip).
func item_height() -> float:
	return _state.height


func count() -> int:
	return _count


## The square round which the items drawn now are simulated (bs fx, fy, fr): centre x, y and half
## side in tiles, or z < 0 before it is known. belt_lanes.gd draws lane icons outside it.
func covered() -> Vector3:
	return _square


func handle(msg: Dictionary) -> void:
	if msg.get("t") == "ie":
		# (--inserter-handoff: the hands' picks and puts, for the simulation; captured with the updates.)
		if _capture != null:
			_capture_line(msg)
		_inbox.append(msg)
		return
	if msg.get("t") != "bs":
		# `bi`, from a bridge older than `bs` (main's 0.1.4 mod, which doesn't know our hello's `bs`):
		# not drawn. Said once a connection (main.gd tells the player), else the belts stand empty in silence.
		if msg.get("t") == "bi" and not old_bridge_seen:
			old_bridge_seen = true
			push_warning("belt-items: the bridge sends `bi` (a mod older than `bs`): no items on belts are drawn near; update the mod")
			old_bridge.emit()
		return
	if _capture != null:
		_capture_line(msg)
	_clock.heard(float(msg.get("k", 0)), float(msg.get("p", 0)))
	# What the update cost the server a tick (`w` over `p`): Moving belt items' Automatic keeps it
	# within its share (belt_lanes.gd).
	if msg.has("w") and int(msg.get("part", 1)) == 1:
		# (The flag can drop for an update and come back: the last `ld` to no-`ld` edge counts.)
		if int(msg.get("ld", 0)) == 1:
			_load_seen = true
			load_done_msec = 0
		elif _load_seen and load_done_msec == 0:
			load_done_msec = Time.get_ticks_msec()
		if lanes != null:
			lanes.call("heard_work", float(msg["w"]) / maxf(1.0, float(msg.get("p", 1))), int(msg.get("ld", 0)) == 1)
	var parts := int(msg.get("parts", 1))
	if parts <= 1:
		_flush_parts()
		_inbox.append(msg)
		return
	var k := int(msg.get("k", 0))
	if k != _parts_tick:
		_flush_parts()
		_parts_tick = k
	_parts.append(msg)
	if _parts.size() >= parts:
		_flush_parts()


## (removed_now) A belt Zenith takes away (`mnd` with g 1, `del`; x, y its place in 1/256 tile): its lanes and
## their items leave in the next job.
func belt_removed(unit: int, x: int, y: int) -> void:
	if removed_now and unit > 0:
		_removed[unit] = Vector2i(floori(x / 256.0), floori(y / 256.0))


## (removed_now) A belt built (`add`) at x, y (1/256 tile): a belt removed on its tiles before the next job was
## replaced, its items kept. A splitter (centred on a tile's edge) covers both tiles either side.
func belt_built(x: int, y: int) -> void:
	if not removed_now:
		return
	for d: Vector2i in [Vector2i(-125, -125), Vector2i(125, -125), Vector2i(-125, 125), Vector2i(125, 125)]:
		_built_tiles[Vector2i(floori((x + d.x) / 256.0), floori((y + d.y) / 256.0))] = true


func _flush_parts() -> void:
	if not _parts.is_empty():
		_inbox.append_array(_parts)
		_parts = []
	_parts_tick = -1


func _wait(apply := true) -> void:
	if _held_job != null:
		if apply:
			_apply(_held_job)
		_held_job = null
	if _task < 0:
		return
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	if apply:
		_apply(_job)
	_job = null


## Item models cast shadows only with the camera nearer than shadows_within to the items' square.
func _update_shadows() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam != null and _square.z >= 0.0:
		_cards.casts_shadow = cam.global_position.distance_to(Vector3(_square.x, 0.0, _square.y)) < shadows_within
		_lat_cards.casts_shadow = _cards.casts_shadow


func _process(delta: float) -> void:
	var start := Time.get_ticks_usec()
	_update_shadows()
	_clock.advance(delta)
	var step := 0.0 if MomentHold.on else delta * _clock.rate  # a screenshot's moment: items stand still
	if not _sync:
		var want := clampf(_job_ticks * (margin_jobs + (handoff_margin if InserterArms.wants_handoff() else 0.0)) + 1.0, DRAW_MARGIN, margin_max)
		if Job.ahead_auto and lead_lag > 0.0:
			# (ahead_auto) Room for the job's lead: the newest update at least a job gap and AHEAD_MARGIN past
			# where the job's result is drawn (fold = drawn + a job's ticks), so the stops and starts before the
			# next job's drawn tick are known; at most lead_lag ticks more behind the game than before.
			var room := 2.0 * _job_ticks + AHEAD_MARGIN + 1.0
			want = clampf(maxf(want, minf(room, want + lead_lag)), DRAW_MARGIN, margin_max)
		_margin = move_toward(_margin, want, step * (0.5 if want > _margin else 0.05))
	if _clock.tick >= 0.0:
		var drawn := _clock.tick - _clock.gap - _margin
		var least := _drawn + MIN_PACE * step
		if _drawn >= 0.0 and drawn < least and drawn > _drawn - 60.0 and least <= _clock.tick - _clock.gap:
			drawn = least
			_margin = _clock.tick - _clock.gap - drawn
		_drawn = drawn
	if not _drops.is_empty():
		_drops_due()  # (with this frame's drawn tick, the one the records show at)
	_cards.begin()
	_lat_cards.begin()
	if _epoch != _cards.epoch:
		_epoch = _cards.epoch
		_wait()
		_known.clear()
		_known_ver += 1
		_dressing.clear()
		_rewrite = true
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		var now := Time.get_ticks_usec()
		if _job.done_usec == 0:
			_job.done_usec = now
		if _drawn >= _job.fold_tick - FOLD_SLACK or now - _job.done_usec >= HOLD_USEC or _clock.tick < 0.0:
			_wait()
	if _held_job != null and (_drawn >= _held_job.fold_tick - FOLD_SLACK or _clock.tick < 0.0):
		var held := _held_job
		_held_job = null
		_apply(held)
	if _task < 0 and not _height_known:
		_find_height()
	if not _dressing.is_empty():
		_dressed()
	# A job when messages wait, a look was made, or the clock moved on (the simulation steps along).
	if _task < 0 and _held_job == null and (not _inbox.is_empty() or _rewrite or (_state.data_tick >= 0 and _drawn >= 0.0)):
		_start(delta)
	if _clock_base >= 0.0:
		RenderingServer.global_shader_parameter_set("f3d_belt_clock", _drawn - _clock_base)
	var spent := Time.get_ticks_usec() - start
	stats["frames"] += 1
	stats["main_usec"] += spent
	if _bench:
		_bench_usec += spent
		_bench_report(delta)


## Items in the old protocol's way (a client-side flow, a replay): no longer: the simulation is the one
## source of items. Kept as no-ops for callers from before.
func set_motion(_uid: int, _item_id: int, _at: Vector3, _tick: float, _speed: float, _stop: Vector3, _count := 1) -> void:
	pass


func remove_item(_uid: int) -> void:
	pass


## Items ride just above the belt surface: the top of the belt model, read on a worker thread.
func _find_height() -> void:
	if not ModelLibrary.ready("transport-belt"):
		return
	_height_known = true
	var belt := ModelLibrary.mesh_for("transport-belt")
	if belt != null:
		var pack := ModelPacks.pack_of(ModelLibrary.source_of("transport-belt"))
		var h := LaneInset.item_height(pack, belt.get_aabb().end.y, 0.02)
		if not is_equal_approx(h, _state.height):
			_state.height = h
			_rewrite = true
	_set_lane_inset(LaneInset.wanted(ModelPacks.pack_of(ModelLibrary.source_of("transport-belt"))))


## The lane offset the belt's pack asks for (pack.json "belt_lane_offset"): lanes already loaded are drawn at it
## from now on (no job runs here), the rest as they come.
func _set_lane_inset(v: float) -> void:
	if is_equal_approx(v, _state.lane_inset):
		return
	_state.lane_inset = v
	for key in _state.lanes.keys():
		var raw: PackedInt32Array = _state.lanes_raw.get(key, PackedInt32Array())
		if raw.is_empty():
			continue
		var meta := LaneInset.shifted(raw, v)
		_state.lanes[key] = meta
		if meta[0] == BeltSim.CURVE:
			_state.arcs[key] = Job._arc(meta)
		if _state.draw != null:
			_state.draw.set_lane(key, meta)
		if not (_state.lattice is BeltLattice):
			_state.lattice.set_lane(key, meta, _state.arcs.get(key, PackedFloat64Array()))
	_state.lanes_moved = true
	_rewrite = true


func _look(item_id: int) -> Array:
	return [_cards.lift(item_id), _cards.turns(item_id), _cards.pile_step(item_id), _cards.variant_count(item_id)]


## Kinds item_cards.gd has dressed since they were made: their looks taken again, every slot written
## again (a full job reads each kind's look anew). Taken only when made, a model still read on a
## thread kept a card's look for good (no lift, a card's pile step).
func _dressed() -> void:
	for item_id in _dressing.keys():
		if _cards.dressed(item_id) and _lat_cards.dressed(item_id):
			_dressing.erase(item_id)
			_known[item_id] = _look(item_id)
			_known_ver += 1
			_rewrite = true


func _start(delta: float) -> void:
	_take_live()
	var job := Job.new()
	job.state = _state
	# (removed_now) Belts taken away since the last job, but those with a belt built on their tile since.
	if not _removed.is_empty():
		var gone := PackedInt64Array()
		for u: int in _removed:
			if not _built_tiles.has(_removed[u]):
				gone.append(u)
		if not gone.is_empty():
			_inbox.push_front({"t": "brm", "u": gone})
		_removed.clear()
	_built_tiles.clear()
	job.msgs = _inbox
	_inbox = []
	job.full = _rewrite
	_rewrite = false
	# (A4, --belt-draw-skip-same) The looks copied, and the far icons' chunks listed, only when they changed:
	# a job only reads them, so the last copy serves (and the native records keep theirs).
	if not skip_same or _known_sent != _known_ver or _known_copy == null:
		_known_copy = _known.duplicate()
		_known_sent = _known_ver
		job.known_new = true
	else:
		job.known_new = false
	job.known = _known_copy
	job.model_cap = ItemCards.model_cap
	var cam := get_viewport().get_camera_3d() if view_led and is_inside_tree() else null
	if cam != null:
		job.cam_led = true
		job.cam_pos = cam.global_position
		job.cam_dir = -cam.global_transform.basis.z
		job.cam_planes = ViewPriority.planes(cam)
	job.watch = _watch.keys()
	job.watch_all = watch_all
	job.now_msec = Time.get_ticks_msec()
	_watch.clear()
	if lanes != null and is_instance_valid(lanes) and lanes.distance > 0:
		var ver: int = lanes.chunks_ver if "chunks_ver" in lanes else -1
		if not skip_same or ver < 0 or ver != _far_ver or _far_copy == null:
			_far_copy = lanes.built_chunks()
			_far_ver = ver
			job.far_new = true
		else:
			job.far_new = false
		job.far_built = _far_copy
	else:
		job.far_new = not skip_same or _far_copy != null or _far_ver != -2
		_far_copy = null
		_far_ver = -2
	var vr := _view_rect()
	if vr.size.x > 0.0:
		job.view = vr
		job.view_all = false
	# Where the drawn clock will be when this job's result is drawn.
	job.fold_tick = _drawn + (0.0 if _sync else maxf(delta * _clock.rate, _job_ticks))
	job.lead = clampf(job.fold_tick - _drawn + 1.0, 2.0, lead_max)
	if _drawn < 0.0:
		job.fold_tick = -1.0
	job.started_usec = Time.get_ticks_usec()
	_job = job
	if _sync:
		job.run()
		_job = null
		_apply(job)
	else:
		_task = WorkerThreadPool.add_task(job.run, job_high, "belt items")


## (view) The ground rectangle (x, z tiles) the camera sees: its four corner rays meeting the items'
## height, each cut VIEW_FAR tiles out when it reaches no further (or looks up); with view_ground,
## VIEW_GROUND_FAR, and the rectangle cut to the simulated square. Empty with no camera.
func _view_rect() -> Rect2:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return Rect2()
	var vp := get_viewport().get_visible_rect().size
	var y := _state.height
	var o := cam.global_position
	var far := VIEW_GROUND_FAR if view_ground else VIEW_FAR
	var r := Rect2(Vector2(o.x, o.z), Vector2.ZERO)
	for c in [Vector2.ZERO, Vector2(vp.x, 0.0), Vector2(0.0, vp.y), vp]:
		var ro := cam.project_ray_origin(c)
		var n := cam.project_ray_normal(c)
		var hit: Vector3
		if n.y < -1e-4 and (y - ro.y) / n.y <= far:
			hit = ro + n * ((y - ro.y) / n.y)
		else:
			var h := Vector2(n.x, n.z)
			h = h.normalized() if h.length() > 1e-6 else Vector2(1.0, 0.0)
			hit = Vector3(ro.x + h.x * far, y, ro.z + h.y * far)
		r = r.expand(Vector2(hit.x, hit.z))
	if view_lead:
		# (view_lead) The camera's ground speed, smoothed over the jobs; the view joined with itself that far on.
		var now := Time.get_ticks_usec()
		var at := Vector2(o.x, o.z)
		var gone_s := (now - _lead_usec) / 1.0e6
		if _lead_usec > 0 and gone_s > 0.0 and gone_s < 2.0:
			_lead_vel = _lead_vel.lerp((at - _lead_pos) / gone_s, 0.5)
		else:
			_lead_vel = Vector2.ZERO
		_lead_pos = at
		_lead_usec = now
		var ahead := 2.0 * maxf(_job_ticks, 1.0) / maxf(_clock.rate, 1.0)
		var shift := (_lead_vel * ahead).limit_length(VIEW_LEAD_MAX)
		if shift.length() > 0.5:
			r = r.merge(Rect2(r.position + shift, r.size))
	if view_ground and _square.z >= 0.0:
		# (view_ground) Cut to the simulated square: the loaded edge, or the client's belt item distance
		# while the square still loads out to it, with the records' margin.
		var half := _square.z
		if lanes != null and is_instance_valid(lanes):
			half = maxf(half, float(lanes.near))
		half += INDEX_MARGIN
		var cut := r.intersection(Rect2(_square.x - half, _square.y - half, 2.0 * half, 2.0 * half))
		# (A view wholly outside the square: a sliver there, which nothing is in; an empty rectangle
		# would mean no camera, everything in view.)
		return cut if cut.has_area() else Rect2(r.get_center(), Vector2(0.01, 0.01))
	return r


func _apply(job: Job) -> void:
	var t_apply := Time.get_ticks_usec()
	_upload(job.pages)
	_clock_base = job.clock_base
	if Job.dump_apply != null and job.dump_no >= 0:
		# (When the job's result is drawn: the records it wrote show from here, at the drawn clock.)
		Job.dump_apply.store_line(JSON.stringify({"n": job.dump_no, "usec": t_apply, "started": job.started_usec,
			"done": job.done_usec if job.done_usec > 0 else t_apply, "drawn": _drawn, "clock": _clock.tick, "gap": _clock.gap,
			"rate": _clock.rate, "margin": _margin, "job_ticks": _job_ticks, "fold": job.fold_tick, "late": _drawn - job.fold_tick,
			"dump_ms": job.dump_usec / 1000.0, "upload_ms": (Time.get_ticks_usec() - t_apply) / 1000.0, "pages": (job.pages.get("pages", []) as Array).size()}))
		Job.dump_apply.flush()
	_prof("upload", t_apply)
	var sq := job.square
	var aabb := AABB(Vector3(sq.x - sq.z - INDEX_MARGIN, -16.0, sq.y - sq.z - INDEX_MARGIN), Vector3(2.0 * (sq.z + INDEX_MARGIN), 96.0, 2.0 * (sq.z + INDEX_MARGIN))) \
		if sq.z >= 0.0 else AABB(Vector3(-1.0e5, -16.0, -1.0e5), Vector3(2.0e5, 96.0, 2.0e5))
	var t1 := Time.get_ticks_usec()
	for w: Array in job.written:
		_cards.put_records(int(w[0]), int(w[1]), int(w[2]), int(w[3]), aabb)
	if sq != _square:
		_cards.set_bounds(aabb)
		_lat_cards.set_bounds(aabb)
	_prof("records", t1)
	t1 = Time.get_ticks_usec()
	_apply_lattice(job, aabb)
	_prof("lattice", t1)
	t1 = Time.get_ticks_usec()
	for item_id in job.unknown:
		_cards.prepare(item_id)
		_lat_cards.prepare(item_id)
		_known[item_id] = _look(item_id)
		_known_ver += 1
		if not (_cards.dressed(item_id) and _lat_cards.dressed(item_id)):
			_dressing[item_id] = true
	_prof("prepare", t1)
	t1 = Time.get_ticks_usec()
	_rewrite = _rewrite or not job.unknown.is_empty()
	_count = job.count
	_square = job.square
	if lanes != null and is_instance_valid(lanes):
		var unknown_items := {}
		for key in job.unknown:
			unknown_items[ItemCards.item_of(int(key))] = true
		# (skip_same: the same square, held chunks and kinds as last time set every icon material's
		# parameters to what they are.)
		var ho := [job.square, job.held_chunks, unknown_items.keys()]
		if not skip_same or ho != _ho_last:
			_ho_last = ho
			lanes.hand_over(job.square, job.held_chunks, ho[2])
	_prof("handover", t1)
	_positions = job.positions
	if not (job.drops.is_empty() and job.drop_puts.is_empty()):
		_drops_heard(job.drops, job.drop_puts)
	if not job.hands.is_empty():
		_hands.append_array(job.hands)
		if _hands.size() > 4096:
			_hands = _hands.slice(_hands.size() - 4096)
	stats["ie"] = int(stats.get("ie", 0)) + job.ie_n
	t1 = Time.get_ticks_usec()
	if job.paths != null:
		_paths_image = job.paths
		if _paths == null or _paths.get_width() != job.paths.get_width() or _paths.get_height() != job.paths.get_height():
			_paths = ImageTexture.create_from_image(job.paths)
			_cards.set_paths(_paths)
		else:
			_paths.update(job.paths)
	_prof("paths", t1)
	if not job.resend.is_empty():
		stats["asked"] += job.resend.size()
		var bridge := get_node_or_null("/root/Bridge")  # (the autoload; none in scripts run with -s)
		for i in range(0, job.resend.size(), 512):
			if bridge != null:
				bridge.send({"t": "bre", "l": job.resend.slice(i, i + 512)})
	stats["jobs"] += 1
	stats["worker_usec"] += job.usec
	stats["sim_usec"] += job.sim_usec
	stats["handle_usec"] = int(stats.get("handle_usec", 0)) + job.handle_usec
	stats["apply_usec"] = int(stats.get("apply_usec", 0)) + job.apply_usec
	stats["renew_usec"] = int(stats.get("renew_usec", 0)) + job.renew_usec
	stats["cap_usec"] = int(stats.get("cap_usec", 0)) + job.cap_usec
	stats["ticks"] = int(stats.get("ticks", 0)) + job.ticks
	stats["replaced"] = int(stats.get("replaced", 0)) + job.replaced_n
	stats["removed_lanes"] = int(stats.get("removed_lanes", 0)) + job.removed_lanes_n
	stats["removed_items"] = int(stats.get("removed_items", 0)) + job.removed_items_n
	var sim = _state.sim
	if "us_step" in sim:
		stats["sim_step_usec"] = sim.us_step
		stats["sim_relink_usec"] = sim.us_relink
		stats["sim_queue_usec"] = sim.us_queue
		stats["line_steps"] = sim.n_line_steps
		stats["why_tick"] = sim.why_tick
	stats["write_usec"] += job.write_usec
	stats["changes"] += job.changes
	stats["renewed"] += job.renewed
	if job.skipped:
		stats["skips"] = int(stats.get("skips", 0)) + 1
	stats["records_written"] += job.records_written
	stats["worst_job_usec"] = maxi(stats["worst_job_usec"], job.usec)
	# (0.2.1's counters: sums over the jobs, and the last job's levels.)
	var sums := {"early": job.early_n, "early_stop": job.early_stop_n, "early_tries": job.early_tries, "drained": job.drained, "ask_view": job.ask_view_n,
		"ask_lat": job.ask_lat_n, "ask_out": job.ask_out_n, "ask_held": job.ask_held_n, "ask_unknown": job.unknown_asked,
		"lat_parks": job.lat_parks, "lat_unparks": job.lat_unparks}
	for k: String in sums:
		stats[k] = int(stats.get(k, 0)) + int(sums[k])
	stats["later"] = job.later_n
	stats["later_max"] = maxi(int(stats.get("later_max", 0)), job.later_n)
	stats["waiting"] = job.waiting_n
	stats["slots"] = job.gauges[0]
	stats["slots_hidden"] = job.gauges[1]
	stats["parked_view"] = job.gauges[2]
	stats["parked_lat"] = job.gauges[3]
	stats["lat_lanes"] = job.lat_lanes_n
	stats["lat_slots"] = _state.lattice.slots_n
	stats["items"] = job.count
	_bench_worker_usec += job.usec
	_bench_jobs += 1
	if not _sync:
		var took := ((job.done_usec if job.done_usec > 0 else Time.get_ticks_usec()) - job.started_usec) / 1000000.0 * _clock.rate
		_job_ticks = took if took > _job_ticks else lerpf(_job_ticks, took, 0.1)
	if debug_tap.is_valid():
		debug_tap.call(job)


## (--belt-draw-lattice) The lattice's record pages (f3d_belt_lattice), kinds and mask (f3d_belt_mask).
func _apply_lattice(job: Job, aabb: AABB) -> void:
	var list: Array = job.lat_pages.get("pages", [])
	if not list.is_empty():
		if bool(job.lat_pages.get("all", false)) or _lat_records == null:
			var images: Array[Image] = []
			for e: Array in list:
				images.append(e[1])
			_lat_records = Texture2DArray.new()
			_lat_records.create_from_images(images)
			RenderingServer.global_shader_parameter_set("f3d_belt_lattice", _lat_records)
		else:
			for e: Array in list:
				_lat_records.update_layer(e[1], int(e[0]))
	for w: Array in job.lat_written:
		_lat_cards.put_records(int(w[0]), int(w[1]), int(w[2]), int(w[3]), aabb)
	if job.lat_mask != null:
		_lat_mask_img = job.lat_mask
		if _lat_mask == null:
			_lat_mask = ImageTexture.create_from_image(job.lat_mask)
			RenderingServer.global_shader_parameter_set("f3d_belt_mask", _lat_mask)
		else:
			_lat_mask.update(job.lat_mask)
	var on := 1.0 if job.lat_lanes > 0 and _lat_mask != null else 0.0
	if not skip_same or on != _lat_on_set:
		_lat_on_set = on
		RenderingServer.global_shader_parameter_set("f3d_belt_lattice_on", on)


func _upload(p: Dictionary) -> void:
	var list: Array = p.get("pages", [])
	if list.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	if bool(p.get("all", false)) or _records == null:
		var images: Array[Image] = []
		for e: Array in list:
			images.append(e[1])
		_records = Texture2DArray.new()
		_records.create_from_images(images)
		_record_pages = images.size()
		RenderingServer.global_shader_parameter_set("f3d_belt_records", _records)
	else:
		for e: Array in list:
			_records.update_layer(e[1], int(e[0]))
	stats["pages"] += list.size()
	stats["upload_usec"] += Time.get_ticks_usec() - t0


## Where an item (by unique id) is drawn now, or null (quality_marks.gd puts its quality there; under
## the ground it isn't drawn). Asked for once, it is known from the next job on.
func position_of(uid: int) -> Variant:
	_watch[uid] = true
	var p: Array = _positions.get(uid, [])
	if p.is_empty() or (p.size() > 5 and bool(p[5])):
		return null
	var path: PackedFloat32Array = p[2]
	var t0: float = p[3]
	var t1: float = p[4]
	var g := 1.0 if t1 <= t0 else clampf((_drawn - t0) / (t1 - t0), 0.0, 1.0)
	if path.is_empty():
		return (p[0] as Vector3) + (p[1] as Vector3) * g
	var o := BeltPaths.path_at(path, g)
	if o.w < 0.5:
		return null
	return (p[0] as Vector3) + Vector3(o.x, o.y, o.z)


## What the shaders draw for a kind now, worked out from its records as belt_path.gdshaderinc does:
## per slot [where (with its lift), cosine of its turn], or null where nothing is drawn (tests).
func drawn(key: int) -> Array:
	var out: Array = []
	if _task >= 0:
		return out
	if _state.draw != null:
		return _state.draw.drawn(key, _drawn - _clock_base)
	var kind: Kind = _state.kinds.get(key)
	if kind == null or kind.base < 0:
		return out
	var recs := _state.records
	var t := _drawn - _clock_base
	for slot in kind.slots.size():
		var o := (kind.base + slot) * BeltRecords.FLOATS
		var d := recs.data
		# (A pile's copy points at its item's record: k steps up, its own turn.)
		var k := d[o + 13]
		var lift_k := 0.0
		var own_c := 0.0
		if k > 0.5:
			lift_k = d[o + 14] * k
			own_c = d[o + 8]
			o += int(d[o + 12]) * BeltRecords.FLOATS
		var code := d[o + 11]
		if code < -0.5:
			out.append(null)
			continue
		var g := clampf((t - d[o + 3]) / (d[o + 7] - d[o + 3]), 0.0, 1.0) if d[o + 7] > d[o + 3] else 1.0
		var at := Vector3(d[o], d[o + 1], d[o + 2])
		if code < 0.5:
			at += Vector3(d[o + 4], d[o + 5], d[o + 6]) * g
		elif _paths_image != null:
			var c := int(code + 0.5) - 1
			var first := c / 64
			var pieces := c - first * 64 + 1
			var f := clampf(g, 0.0, 1.0) * pieces
			var i := mini(int(f), pieces - 1)
			var w := _paths_image.get_width()
			var p0 := _paths_image.get_pixel((first + i) % w, (first + i) / w)
			var p1 := _paths_image.get_pixel((first + i + 1) % w, (first + i + 1) / w)
			var p := p0.lerp(p1, f - i)
			if p.a < 0.5:
				out.append(null)
				continue
			at += Vector3(p.r, p.g, p.b)
		out.append([at + Vector3(0.0, d[o + 10] + lift_k, 0.0), own_c if k > 0.5 else d[o + 8]])
	return out


## (--belt-draw-lattice) What the shaders draw of a kind's lattice now, as belt_path.gdshaderinc does:
## per record [where (with its lift), cosine of its turn, who its item is and its run's seed (-1 and 0 for a
## slot's own turn): ItemCards.lattice_variant of those is the model variant drawn], or null where nothing is
## drawn (tests).
func drawn_lattice(key: int) -> Array:
	var out: Array = []
	if _task >= 0:
		return out
	var lat: RefCounted = _state.lattice
	if not (lat is BeltLattice):
		return lat.drawn_lattice(key, _drawn - _clock_base)
	var kd = lat.kinds.get(key)
	if kd == null or kd.base < 0:
		return out
	var d: PackedFloat32Array = lat.records.data
	var t := _drawn - _clock_base
	for slot in kd.top:
		var o: int = (kd.base + slot) * BeltRecords.FLOATS
		var k := d[o + 13]
		var lift_k := 0.0
		var own_c := 0.0
		if k > 0.5:
			lift_k = d[o + 14] * k
			own_c = d[o + 8]
			o += roundi(d[o + 12]) * BeltRecords.FLOATS
		if d[o + 11] < -0.5:
			out.append(null)
			continue
		var g := clampf((t - d[o + 3]) / (d[o + 7] - d[o + 3]), 0.0, 1.0) if d[o + 7] > d[o + 3] else 1.0
		var slid := 0
		if d[o + 13] < 0.5 and d[o + 14] > 0.5 and d[o + 15] > 0.0:
			# (A held clock, belt_lattice.gd close and start: from texel 1 w, texel 1 y periods on, 0 on and on.)
			var tq := clampf(t, d[o + 7], d[o + 7] + d[o + 5] * d[o + 15] if d[o + 5] > 0.0 else INF) if d[o + 7] > d[o + 3] else t
			var q := (tq - d[o + 3]) / d[o + 15]
			g = q - floorf(q)
			slid = floori(q)
			# (handover) Hidden where its item is the simulation's to draw (texel 3 y: belt_lattice.gd _hand_code).
			var hy := -d[o + 13]
			if hy > 0.5 and (g >= hy - 1.0 if hy < 2.5 else g < hy - 3.0):
				out.append(null)
				continue
		var at := Vector3(d[o], d[o + 1], d[o + 2]) + Vector3(d[o + 4], 0.0 if d[o + 13] < 0.5 and d[o + 14] > 0.5 else d[o + 5], d[o + 6]) * g
		var c := own_c if k > 0.5 else d[o + 8]
		var who := -1
		var run := 0
		if d[o + 13] < 0.5 and d[o + 14] > 1.5:
			# (Who the slot's item is now: belt_path.gdshaderinc's belt_lattice_turn.)
			who = roundi(d[o + 8]) + slid
			run = roundi(d[o + 9])
			c = cos(ItemCards.lattice_turn(who, run, roundi(k) if k > 0.5 else 0))
		out.append([at + Vector3(0.0, d[o + 10] + lift_k, 0.0), c, who, run])
	return out


## (--inserter-handoff) The inserters' takes and puts the jobs found since the last call (Job.hands), oldest
## first: [why (BeltSim.HAND_*), inserter, tick, uid, x, z].
func take_hands() -> Array:
	var h := _hands
	_hands = []
	return h


## The simulation (tests, probes; only while no job runs).
func sim() -> RefCounted:
	return _state.sim


## Whether an item (by unique id) is drawn from here, on either path (tests; only while no job runs).
func has_item(uid: int) -> bool:
	if _state.draw != null:
		return _state.draw.has_item(uid)
	return _state.items.has(uid)


## The drawn tick an item's record hides from (texel 3 w: an inserter's or F's take), -1 none (tests; only while
## no job runs; a library built before it says -1).
func hide_of(uid: int) -> float:
	if _state.draw != null:
		return float(_state.draw.hide_of(uid)) if _state.draw.has_method("hide_of") else -1.0
	var it: Item = _state.items.get(uid)
	return -1.0 if it == null else it.hide_at


func _bench_report(delta: float) -> void:
	_bench_frames += 1
	if ItemCards.contact_drawn():
		_bench_contact += 1
	_bench_time += delta
	_bench_worst = maxf(_bench_worst, delta)
	if _bench_time < 5.0:
		return
	var vp := get_viewport().get_viewport_rid()
	print("item-bench: %d items, %d kinds, frame %.2f ms avg, %.2f ms worst, %.0f FPS, belt items %.2f ms/frame, worker %.2f ms/job (%d jobs), render cpu %.2f ms, gpu %.2f ms, item contact %d%% of frames" % [
		_count, _cards.kind_count(), _bench_time * 1000.0 / _bench_frames, _bench_worst * 1000.0,
		_bench_frames / _bench_time, _bench_usec / 1000.0 / _bench_frames,
		_bench_worker_usec / 1000.0 / maxi(_bench_jobs, 1), _bench_jobs,
		RenderingServer.viewport_get_measured_render_time_cpu(vp), RenderingServer.viewport_get_measured_render_time_gpu(vp), 100 * _bench_contact / maxi(_bench_frames, 1)])
	_bench_frames = 0
	_bench_contact = 0
	_bench_time = 0.0
	_bench_worst = 0.0
	_bench_usec = 0
	_bench_worker_usec = 0
	_bench_jobs = 0
