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
const GameClock := preload("res://scripts/world/game_clock.gd")
const MomentHold := preload("res://scripts/world/moment_hold.gd")
const BeltPaths := preload("res://scripts/world/belt_paths.gd")
const BeltRecords := preload("res://scripts/world/belt_records.gd")
const BeltSim := preload("res://scripts/world/belt_sim.gd")
const ViewPriority := preload("res://scripts/world/view_priority.gd")
const BeltLattice := preload("res://scripts/world/belt_lattice.gd")

## The C++ simulation's class (the same API as belt_sim.gd), used when its extension is loaded.
const NATIVE_SIM := "BeltSimNative"
## The C++ records' side of a job (Job._apply_changes to _write; belt_draw_native.cpp), used with the
## C++ simulation when loaded and --belt-draw-native isn't off: the same records as the GDScript path
## (tools/belt_draw_diff.py), at a fraction of the cost (a job at -62,-26 took about a second in GDScript,
## 80% of it planning and writing 60-100k records).
const NATIVE_DRAW := "BeltDrawNative"
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
## --belt-draw-margin=N: the most ticks the drawn clock is held behind the game's for the jobs (the
## margin grows to 1.5 jobs' ticks). 30 as before: a job longer than 20 ticks (a third of a second
## at 60 UPS; -62,-26's take about a second) then ends past the drawn clock, and its records are
## drawn stale, items standing at their ends while the game's go on. 120 (the default): two seconds
## behind at most, the records still fresh when drawn.
static var margin_max := 120.0
## --belt-job-high=off: the job goes to the worker pool as a low-priority task, as before. On (the
## default): a high-priority one. Godot gives low-priority tasks a share of the threads (0.3: one on a
## 4-thread PC), which the belt job shares with models' levels of detail, decoratives, terrain and far
## chunks; queued behind them (main's heavier levels of detail and decoratives), a job's result came
## about twice its own time late, the next stepped more ticks, and the drawn clock sat 120 ticks behind.
static var job_high := true
## Tiles from the camera to the items' square within which item models cast shadows, by Settings >
## Graphics > Shadows (sun_shadows.gd QUALITY "items": Low 30, Medium 45, High 60, Ultra 80). It was a
## fixed 16, so items lost their shadows a step out from the closest zoom; now they keep them from the
## default zoom (about 30) to about twice it. Past that an item's shadow is a pixel or two and every
## item's triangles go through the shadow pass for it.
static var shadows_within := 60.0
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
## The simulation is stepped this many ticks past where the drawn clock will be (when the updates
## reach that far): a record is written from the motion the simulation has worked out, and an item's
## motion over a tick is only known once that tick is stepped (a lane read, an item put on or moved
## onto another line get their motion when their line is stepped next), so without it such items were
## drawn from their old records until the next job. Changes that start after the drawn tick wait for
## the next job (State.later): the records they replace hold till then. (Job.ahead: --belt-sim-ahead=N.)
const AHEAD := 24
## (view) Records are written only for items whose motion can show on screen: within this many tiles
## of the camera's ground view (plus the item's reach); the view it was planned for is kept this much
## wider, so a camera panning a little doesn't plan every parked item again each job; and the ground
## the camera sees is taken to end this far from it (a low camera sees to the horizon).
const VIEW_MARGIN := 4.0
const VIEW_KEEP := 10.0
const VIEW_FAR := 160.0
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
	var key := 0  # its kind: item_id, or ItemCards.icon_key() past the Items in 3D cap
	var c := 1.0  # cosine and sine of its turn
	var s := 0.0
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


## A pile's copy: the k'th above its item, in a slot of its own; its record points at the item's.
class Layer:
	var it: Item
	var k := 1
	var slot := -1
	var stamp := 0


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
	## Lane key -> its meta [kind, length, step, x0, y0, xm, ym, x1, y1] and, for curves, its arc
	## [centre x, centre y, radius, angle at 0, angle turned to its length].
	var lanes := {}
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
	var kept := {}  # Item -> chunk: kept standing for its chunk's far icons
	var held_chunks := {}
	var asked := {}  # lane key -> msec it was last asked for
	var last_read := {}  # lane key -> its last read's items (`sl`; for `sh`)
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
		sim = ClassDB.instantiate(NATIVE_SIM) if ClassDB.class_exists(NATIVE_SIM) and not force_gd else BeltSim.new()
		if draw_native and not (sim is BeltSim) and ClassDB.class_exists(NATIVE_DRAW):
			draw = ClassDB.instantiate(NATIVE_DRAW)
			draw.set_sim(sim)
		if lattice_native and not (sim is BeltSim) and ClassDB.class_exists(NATIVE_LATTICE):
			lattice = ClassDB.instantiate(NATIVE_LATTICE)
			lattice.set_sim(sim)
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
		sim.hold_inputs = Job.hold
		sim.split_wake = Job.split_wake


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
	## --belt-sim-hold=off: the bridge's `sh` (splitter inputs that stood as their last read left them)
	## ignored. On: such a lane is put back as that read had it and its items don't cross into the
	## outputs until its next read (BeltSim.hold_input).
	static var hold := true
	## --belt-sim-split-wake=off: splitters let items through whenever the belt rules say (BeltSim.split_wake).
	static var split_wake := true
	## --belt-sim-ask-unknown=off: a lane read (`sl`) or checked (`pc`) whose meta (`lm`) never came is left
	## out (as before). On: it is asked for again (`bre`, at most every ASK_AGAIN_MSEC), which the bridge
	## answers with its meta. The bridge sends a lane's meta once, when it loads it: an update lost (UDP, or
	## dropped before the world was ready) left such lanes unsimulated for good.
	static var ask_unknown := true
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
	var later_n := 0  # State.later.size(), kept.size(), lanes.size() after the job (either path)
	var kept_n := 0
	var lanes_n := 0

	func run() -> void:
		var t0 := Time.get_ticks_usec()
		var sim := state.sim
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
			var to := mini(floori(fold_tick) + ahead, state.data_tick)
			if to - int(sim.tick) > MAX_BEHIND and int(sim.tick) >= 0 and to - state.skipped_at > SKIP_EVERY:
				state.skipped_at = to
				sim.skip_to(to)
				skipped = true
				for key in state.lanes:
					resend.append(key)
			elif to > int(sim.tick):
				sim.step_to(to)
		ticks = int(sim.tick) - t_start
		var ch: Dictionary = sim.take_changes()
		sim_usec = Time.get_ticks_usec() - ts
		if state.draw != null:
			_run_native(ch)
		else:
			var ta := Time.get_ticks_usec()
			var view_moved := _set_view()
			_apply_changes(ch)
			if view_moved:
				_replan_parked()
			var tr := Time.get_ticks_usec()
			apply_usec = tr - ta
			_renew()
			renew_usec = Time.get_ticks_usec() - tr
			_keep_or_drop()
			if model_cap != state.capped_at or (model_cap >= 0 and (state.square != state.capped_square or state.cap_jobs >= CAP_EVERY or _cam_moved())):
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
			count = state.items.size()
			held_chunks = state.held_chunks.duplicate()
			for uid in (state.items.keys() if watch_all else watch):
				var it: Item = state.items.get(uid)
				if it != null:
					positions[uid] = [it.from, it.step, it.path, it.t_from, it.t_to, it.hidden]
			later_n = state.later.size()
			kept_n = state.kept.size()
			lanes_n = state.lanes.size()
			if dump != null and paths != null:
				dump_paths = state.path_tex
		if BeltLattice.on or state.lattice.has_drawn():
			_lattice()
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
	## both records paths.
	func _lattice() -> void:
		if int(state.sim.tick) < 0 or state.records.base < 0.0:
			return
		var tl := Time.get_ticks_usec()
		var lr: Dictionary
		if state.lattice is BeltLattice:
			lr = state.lattice.update(state, state.sim, int(state.sim.tick), view, view_all, known, model_cap, full, dump != null)
		else:
			lr = state.lattice.update(int(state.sim.tick), view, view_all, known, model_cap, full, dump != null, state.records.base,
				state.height, BeltLattice.on, BeltLattice.world, BeltLattice.piles, BeltLattice.unison)
		lat_written = lr["written"]
		lat_pages = lr["pages"]
		lat_mask = lr["mask"]
		lat_lanes = state.lattice.lanes_n
		for kk in lr["unknown"]:
			if not unknown.has(kk):
				unknown.append(kk)
		if dump != null:
			dump_ids.append_array(lr["dump_ids"])
			dump_recs.append_array(lr["dump_recs"])
			dump_gone.append_array(lr["dump_gone"])
		lat_usec = Time.get_ticks_usec() - tl

	## (--belt-draw-native) The job from the changes on in BeltDrawNative (belt_draw_native.cpp: the same
	## as _set_view .. _write below, item for item); its results into this job's fields.
	func _run_native(ch: Dictionary) -> void:
		var params := {"fold": fold_tick, "lead": lead, "now_msec": now_msec, "full": full, "model_cap": model_cap,
			"square": state.square, "base": state.records.base, "height": state.height, "dump": dump != null,
			"coalesce": coalesce, "view_cull": view_cull, "lead_on": lead_on, "gone_order": gone_order, "early": early,
			"view_all": view_all, "view": view, "known": known, "far_built": far_built, "watch": watch, "watch_all": watch_all,
			"pile_one": pile_one, "cam_led": cam_led, "cam_pos": cam_pos, "cam_dir": cam_dir, "cam_planes": cam_planes}
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

	func _park(it: Item) -> void:
		if it.slot >= 0:
			_unplace(it)
		it.parked = true
		it.renew = -1.0
		state.renewing.erase(it)
		it.path = PackedFloat32Array()
		_mark(it)  # (its path's run is let go)

	func _unpark(it: Item) -> void:
		it.parked = false
		_place(it)
		var n := it.count
		it.count = 1
		_set_count(it, n)

	## (view) The view moved: parked items now in it get their records, from where their motion has them.
	func _replan_parked() -> void:
		var now := floori(fold_tick)
		for it: Item in state.items.values():
			if not it.parked:
				continue
			var d := mini(it.v * (now - it.t0), it.reach) if it.v > 0 and now > it.t0 else 0
			var at := _advance(it.lane, it.pos, d) if d > 0 else Vector2i(it.lane, it.pos)
			if not _in_view(at.x, at.y, it.reach - d):
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
		for msg: Dictionary in msgs:
			var sl = msg.get("sl")
			if not (sl is Array):
				continue
			var a2: Array = sl
			var i := 0
			while i + 2 < a2.size():
				var key := int(a2[i])
				var at := int(a2[i + 1])
				if not read_at.has(key) or at < int(read_at[key]):
					read_at[key] = at
				i += 3 + clampi(int(a2[i + 2]), 0, (a2.size() - i - 3) / 4) * 4

	## One part of an update (`bs`): lanes' meta first, then their items, checks, drops, switches.
	func _handle(msg: Dictionary) -> void:
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
		var lm = msg.get("lm")
		if lm is Array:
			var a: Array = lm
			for i in range(0, a.size() - 11, 12):
				var key := int(a[i])
				var meta := PackedInt32Array([int(a[i + 1]), int(a[i + 2]), int(a[i + 3]), int(a[i + 4]), int(a[i + 5]),
					int(a[i + 6]), int(a[i + 7]), int(a[i + 8]), int(a[i + 9])])
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
					sim.set_lane_at(at, key, meta[0], meta[1], meta[2], Vector2i(meta[3], meta[4]), Vector2i(meta[5], meta[6]),
						Vector2i(meta[7], meta[8]), int(a[i + 10]), -nxt if nxt < -1 else maxi(nxt, 0), nxt < 0)
				else:
					sim.set_lane(key, meta[0], meta[1], meta[2], Vector2i(meta[3], meta[4]), Vector2i(meta[5], meta[6]),
						Vector2i(meta[7], meta[8]), int(a[i + 10]), -nxt if nxt < -1 else maxi(nxt, 0))
					sim.set_out_edge(key, nxt < 0)
		var dl = msg.get("dl")
		if dl is Array:
			for key in dl:
				dropped[int(key)] = true
				sim.drop_lane(int(key))
				if state.draw != null:
					state.draw.drop_lane(int(key))
				state.lanes.erase(int(key))
				state.last_read.erase(int(key))
				state.arcs.erase(int(key))
				state.lattice.drop(int(key))
		var sl = msg.get("sl")
		if sl is Array:
			var a2: Array = sl
			var i := 0
			var oracle: Dictionary = sim.oracle
			if oracle.size() > ORACLE_MAX:
				oracle.clear()
			while i + 2 < a2.size():
				var key := int(a2[i])
				var at := int(a2[i + 1])
				var n := clampi(int(a2[i + 2]), 0, (a2.size() - i - 3) / 4)  # (never more than the list holds)
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
		if sh is Array and hold:
			var a7: Array = sh
			for i in range(0, a7.size() - 1, 2):
				var key := int(a7[i])
				if state.last_read.has(key):
					sim.hold_input(key, int(a7[i + 1]), state.last_read[key])
		# ew: a lane leading out that only moved on: its new wall, [key, tick, front uid, its position, ...].
		var ew = msg.get("ew")
		if ew is Array:
			var a6: Array = ew
			for i in range(0, a6.size() - 3, 4):
				sim.set_wall(int(a6[i]), int(a6[i + 1]), int(a6[i + 2]), int(a6[i + 3]))
		var pc = msg.get("pc")
		if pc is Array:
			var a3: Array = pc
			# (pu: packed lanes' front and back items' ids, [key, front uid, back uid, ...].)
			var ids := {}
			var pu = msg.get("pu")
			if pu is Array:
				var a5: Array = pu
				for i in range(0, a5.size() - 2, 3):
					ids[int(a5[i])] = [int(a5[i + 1]), int(a5[i + 2])]
			for i in range(0, a3.size() - 4, 5):
				if ask_unknown and not state.lanes.has(int(a3[i])):
					_ask(int(a3[i]))
				var u: Array = ids.get(int(a3[i]), [0, 0])
				sim.check_lane(int(a3[i]), int(a3[i + 1]), int(a3[i + 2]), int(a3[i + 3]), int(a3[i + 4]), int(u[0]), int(u[1]))
				if state.lanes.has(int(a3[i])):
					state.lattice.note_check(int(a3[i]), (state.lanes[int(a3[i])] as PackedInt32Array)[1], int(a3[i + 2]),
						int(a3[i + 3]), int(a3[i + 4]))
		var of = msg.get("of")
		if of is Array:
			var a4: Array = of
			for i in range(0, a4.size() - 1, 2):
				sim.set_off(int(a4[i]), int(a4[i + 1]) == 1, k)
		# (qu: items' quality names; quality marks come from `bq`, not drawn from here.)

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
		var f := clampf(pos / float(maxi(m[1], 1)), 0.0, 1.0)
		var x: float
		var y: float
		if m[0] == BeltSim.CURVE and state.arcs.has(key) and not (state.arcs[key] as PackedFloat64Array).is_empty():
			var arc: PackedFloat64Array = state.arcs[key]
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
		if not state.later.is_empty():
			var later := state.later
			state.later = []
			for e: Array in later:
				if int(e[2]) > now or held.has(e[1]):
					if early and int(e[0]) == 0 and not held.has(e[1]) and _apply_early(e[1], e[3], e[4], e[5], e[6], e[2], e[7], e[8], e[9], now):
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
			if ticks[i] > now or not held.is_empty() and held.has(uid):
				if early and not held.has(uid) and _apply_early(uid, items[i], stacks[i], keys[i], poss[i], ticks[i], speeds[i], reaches[i], runs[i], now):
					continue
				held[uid] = true
				state.later.append([0, uid, ticks[i], items[i], stacks[i], keys[i], poss[i], speeds[i], reaches[i], runs[i]])
				continue
			_apply_one(uid, items[i], stacks[i], keys[i], poss[i], ticks[i], speeds[i], reaches[i], runs[i])
		while gi < ng:
			_go_or_hold(gone[gi], gone_ticks[gi] if timed else now, now, held)
			gi += 1
		for key in ch["mismatch"]:
			var last: int = state.asked.get(key, -ASK_AGAIN_MSEC)
			if now_msec - last >= ASK_AGAIN_MSEC:
				state.asked[key] = now_msec
				resend.append(key)

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
		if t > now or not held.is_empty() and held.has(uid):
			held[uid] = true
			state.later.append([1, uid, t])
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
				return
		_remove(uid)

	## (early) A change after the drawn tick taken now when nothing shows early: a start of an item whose
	## record stands where the change starts from (applied as it is: the record stands there till t0), or a
	## continuation of a moving item's record (it reaches the change's lane and place at the change's tick
	## at the same speed): the item goes on from where its record has it now, the rest of its reach and the
	## change's beyond, through the lanes ahead, instead of standing at the cut till the next job. Items of
	## another look (item, stack) or out of view are left to the next job. Returns true when taken.
	func _apply_early(uid: int, item: int, stack: int, key: int, pos: int, t0: int, v: int, reach: int, _run: int, now: int) -> bool:
		var it: Item = state.items.get(uid)
		if it == null or it.parked or it.item_id != item or it.count != clampi(stack, 1, MAX_STACK) or state.kept.has(it):
			return false
		if it.v <= 0:
			if v > 0 and it.lane == key and it.pos == pos and it.t0 <= now:
				_apply_one(uid, item, stack, key, pos, t0, v, reach, _run)
				early_n += 1
				return true
			return false
		if v != it.v:
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
		if not _in_view(it.lane, it.pos, it.reach):
			_park(it)
			parked += 1
			return true
		_plan(it)
		early_n += 1
		return true

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
			state.items[uid] = it
		elif it.item_id != item:
			it.item_id = item
			_rekey(it, item)
		state.kept.erase(it)
		_set_count(it, stack)
		it.lane = key
		it.pos = pos
		it.t0 = t0
		it.v = v
		it.reach = reach
		it.run = run
		if not _in_view(key, pos, reach):
			if not it.parked:
				_park(it)
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
				if it.key != it.item_id:
					_rekey(it, it.item_id)
			return
		var c := Vector2(state.square.x, state.square.y)
		var uids: Array = []
		var dists := PackedFloat32Array()
		var models := PackedByteArray()
		for uid in state.items:
			var it: Item = state.items[uid]
			var look: Array = known.get(it.item_id, [])
			if not look.is_empty() and not bool(look[1]):
				if it.key != it.item_id:
					_rekey(it, it.item_id)
				continue
			var model := it.key == it.item_id
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
				_rekey(it, it.item_id if want[i] == 1 else ItemCards.icon_key(it.item_id))

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
				dirty[r / BeltRecords.PER_PAGE] = true
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
			d[o + 15] = 0.0
			dirty[r / BeltRecords.PER_PAGE] = true
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

## world.gd (main.gd sets it; lanes come from the bridge now, so nothing is read from it).
var world = null

## The bridge sent `bi`: it is older than `bs` and nothing near is drawn from it (handle(); once a
## connection, main.gd shows the player a message).
signal old_bridge
var old_bridge_seen := false

var _cards := ItemCards.new()
var _lat_cards := ItemCards.new()  # (--belt-draw-lattice) the lattice's kinds, records from f3d_belt_lattice
var _lat_records: Texture2DArray = null
var _lat_mask: ImageTexture = null


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
var _job: Job = null
var _task := -1
var _known := {}  # item id -> [lift, turns, pile step], kinds item_cards.gd has dressed
var _dressing := {}  # item id -> true: kinds made, their looks still being read
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
const Probing := preload("res://scripts/debug/probing.gd")


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
			Job.ahead = maxi(0, int(a.substr(17)))
		elif a.begins_with("--belt-draw-gone-order="):
			Job.gone_order = a.substr(23) != "off"
		elif a.begins_with("--belt-draw-lead="):
			Job.lead_on = a.substr(17) != "off"
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
		elif a.begins_with("--belt-sim-hold="):
			Job.hold = a.substr(16) != "off"
		elif a.begins_with("--belt-sim-split-wake="):
			Job.split_wake = a.substr(22) != "off"
		elif a.begins_with("--belt-sim-ask-unknown="):
			Job.ask_unknown = a.substr(23) != "off"
		elif a.begins_with("--belt-draw-coalesce="):
			Job.coalesce = a.substr(21) != "off"
		elif a.begins_with("--belt-draw-early="):
			Job.early = a.substr(18) != "off"
		elif a.begins_with("--belt-draw-view="):
			Job.view_cull = a.substr(17) != "off"
		elif a.begins_with("--belt-draw-margin="):
			margin_max = maxf(DRAW_MARGIN, float(a.substr(19)))
		elif a.begins_with("--belt-draw-native="):
			State.draw_native = a.substr(19) != "off"
		elif a.begins_with("--belt-sim-native="):
			State.force_gd = a.substr(18) == "off"
		elif a.begins_with("--belt-draw-pile="):
			Job.pile_one = a.substr(17) != "off"
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
		elif a.begins_with("--belt-capture-thread="):
			capture_thread = a.substr(22) == "on"


static func flags_text() -> String:
	return "ahead %d, gone order %s, lead %s, head move %s, read apply %s, read conserve %s, read forward %s, shift keep %s, read skip same %s, hold %s, split wake %s, coalesce %s, view %s, margin %.0f, native draw %s, pile %s, lattice %s%s, lattice unison %s, early %s, job %s" % [Job.ahead,
		"on" if Job.gone_order else "off", "on" if Job.lead_on else "off", "on" if State.head_move else "off",
		"on" if Job.read_apply else "off", "on" if Job.read_conserve else "off", "on" if Job.read_forward else "off", "on" if Job.shift_keep else "off",
		"on" if Job.read_skip_same else "off", "on" if Job.hold else "off",
		"on" if Job.split_wake else "off", "on" if Job.coalesce else "off", "on" if Job.view_cull else "off", margin_max,
		"on" if State.draw_native and ClassDB.class_exists(NATIVE_DRAW) else "off", "one" if Job.pile_one else "each",
		("world" if BeltLattice.world else "sim") if BeltLattice.on else "off",
		(", lattice piles " + ("on" if BeltLattice.piles else "off") + ", lattice native " + ("on" if State.lattice_native
			and ClassDB.class_exists(NATIVE_LATTICE) else "off")) if BeltLattice.on else "",
		"on" if BeltLattice.unison else "off", "on" if Job.early else "off",
		"high" if job_high else "low"]


func _ready() -> void:
	_clock.ease = 0.5
	_cards.name = "Cards"
	_cards.casts_shadow = false
	add_child(_cards)
	_lat_cards.name = "LatticeCards"
	_lat_cards.casts_shadow = false
	_lat_cards.record_tex = 1
	add_child(_lat_cards)
	_bench = "--item-bench" in OS.get_cmdline_user_args()
	# A movie's frame stands for 1/60 s while workers take real time: jobs would land late on its clock.
	_sync = _sync or "--belt-items-sync" in OS.get_cmdline_user_args() or Engine.get_write_movie_path() != ""
	Job.debug = "--belt-sim-debug" in OS.get_cmdline_user_args()
	read_flags(OS.get_cmdline_user_args())
	if State.force_gd and not (_state.sim is BeltSim):
		_state = State.new()  # (--belt-sim-native=off: the first was made before the flags were read)
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
	_state = State.new()
	_state.height = height
	old_bridge_seen = false
	_inbox.clear()
	_cards.reset()
	_lat_cards.reset()
	_lat_records = null
	RenderingServer.global_shader_parameter_set("f3d_belt_lattice_on", 0.0)
	_known.clear()
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


func count() -> int:
	return _count


## The square round which the items drawn now are simulated (bs fx, fy, fr): centre x, y and half
## side in tiles, or z < 0 before it is known. belt_lanes.gd draws lane icons outside it.
func covered() -> Vector3:
	return _square


func handle(msg: Dictionary) -> void:
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
		var want := clampf(_job_ticks * margin_jobs + 1.0, DRAW_MARGIN, margin_max)
		_margin = move_toward(_margin, want, step * (0.5 if want > _margin else 0.05))
	if _clock.tick >= 0.0:
		var drawn := _clock.tick - _clock.gap - _margin
		var least := _drawn + MIN_PACE * step
		if _drawn >= 0.0 and drawn < least and drawn > _drawn - 60.0 and least <= _clock.tick - _clock.gap:
			drawn = least
			_margin = _clock.tick - _clock.gap - drawn
		_drawn = drawn
	_cards.begin()
	_lat_cards.begin()
	if _epoch != _cards.epoch:
		_epoch = _cards.epoch
		_wait()
		_known.clear()
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
		_state.height = belt.get_aabb().end.y + 0.02


func _look(item_id: int) -> Array:
	return [_cards.lift(item_id), _cards.turns(item_id), _cards.pile_step(item_id)]


## Kinds item_cards.gd has dressed since they were made: their looks taken again, every slot written
## again (a full job reads each kind's look anew). Taken only when made, a model still read on a
## thread kept a card's look for good (no lift, a card's pile step).
func _dressed() -> void:
	for item_id in _dressing.keys():
		if _cards.dressed(item_id) and _lat_cards.dressed(item_id):
			_dressing.erase(item_id)
			_known[item_id] = _look(item_id)
			_rewrite = true


func _start(delta: float) -> void:
	var job := Job.new()
	job.state = _state
	job.msgs = _inbox
	_inbox = []
	job.full = _rewrite
	_rewrite = false
	job.known = _known.duplicate()
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
		job.far_built = lanes.built_chunks()
	var vr := _view_rect()
	if vr.size.x > 0.0:
		job.view = vr
		job.view_all = false
	# Where the drawn clock will be when this job's result is drawn.
	job.fold_tick = _drawn + (0.0 if _sync else maxf(delta * _clock.rate, _job_ticks))
	job.lead = clampf(job.fold_tick - _drawn + 1.0, 2.0, 8.0)
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
## height, each cut VIEW_FAR tiles out when it reaches no further (or looks up). Empty with no camera.
func _view_rect() -> Rect2:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return Rect2()
	var vp := get_viewport().get_visible_rect().size
	var y := _state.height
	var o := cam.global_position
	var r := Rect2(Vector2(o.x, o.z), Vector2.ZERO)
	for c in [Vector2.ZERO, Vector2(vp.x, 0.0), Vector2(0.0, vp.y), vp]:
		var ro := cam.project_ray_origin(c)
		var n := cam.project_ray_normal(c)
		var hit: Vector3
		if n.y < -1e-4 and (y - ro.y) / n.y <= VIEW_FAR:
			hit = ro + n * ((y - ro.y) / n.y)
		else:
			var h := Vector2(n.x, n.z)
			h = h.normalized() if h.length() > 1e-6 else Vector2(1.0, 0.0)
			hit = Vector3(ro.x + h.x * VIEW_FAR, y, ro.z + h.y * VIEW_FAR)
		r = r.expand(Vector2(hit.x, hit.z))
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
		lanes.hand_over(job.square, job.held_chunks, unknown_items.keys())
	_prof("handover", t1)
	_positions = job.positions
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
	_bench_worker_usec += job.usec
	_bench_jobs += 1
	if not _sync:
		var took := ((job.done_usec if job.done_usec > 0 else Time.get_ticks_usec()) - job.started_usec) / 1000000.0 * _clock.rate
		_job_ticks = took if took > _job_ticks else lerpf(_job_ticks, took, 0.1)


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
		if _lat_mask == null:
			_lat_mask = ImageTexture.create_from_image(job.lat_mask)
			RenderingServer.global_shader_parameter_set("f3d_belt_mask", _lat_mask)
		else:
			_lat_mask.update(job.lat_mask)
	RenderingServer.global_shader_parameter_set("f3d_belt_lattice_on", 1.0 if job.lat_lanes > 0 and _lat_mask != null else 0.0)


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
## per record [where (with its lift), cosine of its turn], or null where nothing is drawn (tests).
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
		if d[o + 13] < 0.5 and d[o + 14] > 0.5 and d[o + 15] > 0.0:
			g = fposmod((t - d[o + 3]) / d[o + 15], 1.0)
		var at := Vector3(d[o], d[o + 1], d[o + 2]) + Vector3(d[o + 4], d[o + 5], d[o + 6]) * g
		out.append([at + Vector3(0.0, d[o + 10] + lift_k, 0.0), own_c if k > 0.5 else d[o + 8]])
	return out


## The simulation (tests, probes; only while no job runs).
func sim() -> RefCounted:
	return _state.sim


## Whether an item (by unique id) is drawn from here, on either path (tests; only while no job runs).
func has_item(uid: int) -> bool:
	if _state.draw != null:
		return _state.draw.has_item(uid)
	return _state.items.has(uid)


func _bench_report(delta: float) -> void:
	_bench_frames += 1
	_bench_time += delta
	_bench_worst = maxf(_bench_worst, delta)
	if _bench_time < 5.0:
		return
	var vp := get_viewport().get_viewport_rid()
	print("item-bench: %d items, %d kinds, frame %.2f ms avg, %.2f ms worst, %.0f FPS, belt items %.2f ms/frame, worker %.2f ms/job (%d jobs), render cpu %.2f ms, gpu %.2f ms" % [
		_count, _cards.kind_count(), _bench_time * 1000.0 / _bench_frames, _bench_worst * 1000.0,
		_bench_frames / _bench_time, _bench_usec / 1000.0 / _bench_frames,
		_bench_worker_usec / 1000.0 / maxi(_bench_jobs, 1), _bench_jobs,
		RenderingServer.viewport_get_measured_render_time_cpu(vp), RenderingServer.viewport_get_measured_render_time_gpu(vp)])
	_bench_frames = 0
	_bench_time = 0.0
	_bench_worst = 0.0
	_bench_usec = 0
	_bench_worker_usec = 0
	_bench_jobs = 0
