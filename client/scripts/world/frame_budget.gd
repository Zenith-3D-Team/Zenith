extends RefCounted
## The main thread's sliced work (messages, chunk builds, terrain, models, clutter, far lanes,
## wires, far merging...) asks here how long it may run this frame (grant) and says what it used
## and how much it still has queued (spent).
##
## Each of those systems had a slice of its own (HANDLE_USEC, REBUILD_USEC, FINISH_USEC...),
## sensible alone; but while the character moves every queue has work, so every system spent its
## whole slice every frame and the frame became their sum. With `shared` on they share one
## allowance a frame instead (POOL_*), handed out by priority: a system gets what is left of the
## pool after what the higher ones still to run this frame want (their last use), so the near
## chunks and the character's surroundings come first and far clutter, far belts, wires and
## merging take what remains. A system with work waiting that got nothing for STARVE_FRAMES frames
## gets MIN_SLICE, so everything keeps draining. With `shared` off each system gets its own slice
## as before (and the numbers are still recorded, for --stutter-probe).

const Switches := preload("res://scripts/switches.gd")

## [priority (lower first), the system's own slice in µs (its old constant, and its most from the
## pool), its floor: what it gets whenever it asks, pool or deadline (the near work always moves:
## the old code did at least one message, one build, one chunk freed a frame)].
const SYSTEMS := {
	&"messages": [0, 4000, 1000],  # bridge.gd: messages handled (they feed everything else)
	&"states": [1, 2000, 300],  # world.gd: machines' states (`st`) applied, a busy base's 1,600 in 10-25 ms
	&"terrain": [1, 3000, 500],  # world.gd: finished terrain meshes put in (holes in the ground)
	&"blueprint": [1, 3000, 1000],  # blueprint_preview.gd: a held blueprint laid out and checked at the cursor
	&"build": [2, 6000, 1500],  # world.gd: chunks' buildings built, nearest first
	&"hydrate": [2, 2500, 500],  # world.gd: chunks replayed from the disk cache, a step at a time (--optimistic-slice)
	&"models": [3, 4000, 500],  # model_library.gd: models made on workers finished here
	&"unload": [4, 2500, 800],  # world.gd: unloaded chunks taken apart
	&"shadows": [5, 1000, 300],  # world.gd: chunks' shadow tiers set
	&"lods": [5, 2000, 600],  # world.gd: chunks' levels of detail looked at, band by band
	&"belt_lods": [5, 800, 0],  # belt_lods.gd: belt stand-ins checked across tracked chunks
	&"pick": [5, 1500, 0],  # world.gd: the index of what is under the mouse
	&"decoratives": [6, 3000, 0],  # decoratives.gd: clutter built on workers put in
	&"cliff_wall": [6, 1500, 0],  # cliff_wall.gd: chunks' generated cliff walls put in (--cliff-wall=on)
	&"lanes": [6, 2000, 0],  # belt_lanes.gd: far belt icons put in
	&"wires": [7, 1500, 0],  # wires.gd: chunks' wires drawn again
	&"pipelines": [6, 2000, 300],  # pipeline_marks.gd: fluid pipelines found for their visualization (N9)
	&"far_decide": [7, 1000, 0],  # far_chunks.gd: annulus far/coarse visibility diff & slice
	&"far_collect": [8, 1000, 0],  # far_chunks.gd: far chunks' entities gathered for merging
	&"far_install": [8, 1500, 0],  # far_chunks.gd: finished merges put in
	&"lod_install": [8, 1200, 0],  # distant_horizon.gd: finished LOD section meshes put in
	&"anim_migrate": [9, 300, 0],  # anim.gd: groups moved onto the newer clock
	&"mover_migrate": [9, 300, 0],  # mover_records.gd: the same for movers' records
}

## The frame the sliced work aims for when no FPS cap says otherwise.
const TARGET_USEC := 16667
## What the frame needs besides the sliced work and the other scripts: the renderer's CPU side, the
## UI canvas, deferred calls (docs/PERFORMANCE-AUDIT.md: about 5 ms on the owner's save).
const RESERVE_USEC := 5000
## The pool is what is left under the target after the frame's other work, within these.
const POOL_MIN := 3000
const POOL_MAX := 6000
## Standing (no work in the higher systems) the pool may grow to this, so a backlog drains fast.
const POOL_IDLE := 10000
## The near systems (priority up to NEAR_PRIORITY) leave this much of the pool to the rest while
## any of those has work waiting, so far clutter, lanes, wires and merging keep moving while the
## character walks (and new chunks always wait).
const NEAR_PRIORITY := 3
const LOW_RESERVE := 1000
const STARVE_FRAMES := 20
const MIN_SLICE := 500
## A slice that ran this far past what it was granted counts as an overrun.
const OVERRUN_SLACK := 1000

static var shared := true
## --frame-budget-belts=first|off (first; the owner: belt logic is the last thing culled for performance): the
## belts' sliced work (belt_lanes.gd's far icons, `lanes`) ranks with the messages (priority 0) and has a floor, so
## under a tight frame the near chunks' builds, terrain, models, shadows, levels of detail, decoratives, wires and
## far merging wait before it; off: its place in SYSTEMS (6, no floor), as before. (The pool's size still counts
## it by its place in SYSTEMS: far icons waiting don't make a standing frame "busy".) The `bs` messages and the
## belt job's results don't wait in the pool at all (bridge.gd --belt-messages-first; belt_items.gd).
static var belts_first := true
const BELTS_FIRST := {&"lanes": [0, 2000, 500]}
## --far-priority=legacy: keep uncovered far-chunk merging at priority 8 with a 0 floor (can starve behind terrain/build).
static var far_priority_boost := not Switches.has("--far-priority=legacy")
## Set by far_chunks.gd while uncovered far chunks (no full MultiMeshes and no merged mesh yet) await collect/install.
static var far_urgent := false
const FAR_URGENT := [2, 2000, 600]
## --budget-hard-cap=off: allow lower-priority systems to keep stacking guaranteed floors past the frame pool ceiling.
static var hard_cap := Switches.on("--budget-hard-cap")
## P4 (owner: "it takes like 5 seconds after looking away from a dense area to gain FPS"): the systems whose work
## takes drawing away (levels of detail, belt stand-ins, shadow tiers, far merging's decide pass, gathering and
## putting in) get these floors whenever they have work waiting, past the pool's hard cap and the frame's deadline.
## In a frame already over TARGET_USEC (first person over a busy base: 40-50 ms) the deadline left them nothing and
## the hard cap kept their floors out, so each had one MIN_SLICE about every STARVE_FRAMES frames: after a run, 348
## chunks' levels of detail and 275 far chunks waited 10 s and more, drawn in full meanwhile (5,800 draw calls
## instead of 2,400). At most REDUCE_TOTAL µs a frame together (a floor times the grant's `scale`). `--unload-fast=off`: as before.
static var reduce_floors := Switches.on("--unload-fast")
const REDUCERS := {&"lods": 600, &"belt_lods": 300, &"shadows": 300, &"far_decide": 400, &"far_collect": 400, &"far_install": 400}
const REDUCE_TOTAL := 2500
static var _reduce_used := 0
static var _starve_granted_frame := -1
## Spikes part B (R&D run-spikes, step 6). `--budget-spent=off`: grants don't take off the frame's other scripts'
## time already spent past their usual share (_other_over).
static var spent_aware := Switches.on("--budget-spent")
## `--budget-predict=off`: slices check only the clock between items, not the next item's typical cost (item_est).
static var predict := Switches.on("--budget-predict")
## How fast an item's typical cost falls back after a slow one (note_item).
const ITEM_EMA := 0.1
static var _item_ema := {}  # "system" or "system:kind" -> µs
## For tests: the frame's other scripts' time so far, instead of the clock's.
static var test_spent_other_usec := -1


## A system's [priority, slice, floor]: SYSTEMS', or with belts_first the belts' own.
static func _sys(system: StringName) -> Array:
	if belts_first and BELTS_FIRST.has(system):
		return BELTS_FIRST[system]
	if far_priority_boost and far_urgent and (system == &"far_collect" or system == &"far_install"):
		return FAR_URGENT
	return SYSTEMS[system]

## A screenshot settling (addon_host.gd): the interface is hidden and nobody plays meanwhile, so the
## sliced work may make frames of up to BOOST_TARGET_USEC, each system BOOST times its slice, and the
## backlog of full detail's wider view (1,681 chunks at view distance 20) drains that much faster.
static var boost := false
const BOOST_TARGET_USEC := 50000
const BOOST := 6
## Forced on or off from the command line (--frame-budget=shared|separate).
static var _arg_checked := false

static var _frame := -1
static var pool := POOL_MAX
## When this frame's scripts started (the first system to ask: Bridge, an autoload, runs first),
## for the deadline: a frame whose other scripts already took most of it (a fight's effects, a
## burst of input) leaves the sliced work only what is left before TARGET_USEC - RESERVE_USEC.
static var _frame_start := 0
## For the UI test: no deadline.
static var test_no_deadline := false
## This frame: system -> µs used, µs granted (the most of the frame's grants), whether it ran.
static var used := {}
static var granted := {}
## The last reported work waiting per system (items, chunks, messages...).
static var queued := {}
## What each system used the last frame it ran with work waiting (for the reservations).
static var _last_use := {}
static var _starved := {}  # system -> frames in a row it was granted nothing with work waiting
static var used_total := 0
## Overruns so far by system (for --stutter-probe and the UI test).
static var overruns := {}
## Grants raised to the system's own slice because its work had waited too long (`behind`), so far by
## system (for --stutter-probe).
static var catchups := {}
## The other scripts' time a frame (Godot's process time minus the sliced work), smoothed.
static var _other_ema := 6000.0
static var _last_frame_used := 0
## For the UI test: a frame's other work fixed, instead of Godot's measured process time.
static var test_other_usec := -1
## The frame's other scripts are measured from the first system's ask to the frame's last script
## (frame_end(), from a node world.gd adds at the last process priority), less the sliced work.
## Godot's Performance.TIME_PROCESS, used before, is the slowest whole process step of the last
## second, the renderer's sync and draw included (Godot 4.7.2 main.cpp, Main::iteration: the most
## process_ticks since the last report, set once a second): any frame over about 8.7 ms in the last
## second held the pool at POOL_MIN, and the renderer counted twice beside RESERVE_USEC. On the
## owner's base the pool was 3.000 ms in every one of 7,162 frames (client-cpu.md 5).
## `--frame-budget-measure=godot` measures it from TIME_PROCESS again.
static var measure_frame := not Switches.has("--frame-budget-measure=godot")
static var _end_usec := 0
static var _end_frame := -1
## The last frame's other scripts as measured, µs (for probes; -1 before any).
static var other_usec := -1


## The frame's scripts are done (world.gd's FrameEnd node, last of all to process).
static func frame_end() -> void:
	_end_frame = Engine.get_process_frames()
	_end_usec = Time.get_ticks_usec()


static func _check_arg() -> void:
	_arg_checked = true
	for arg in Switches.args():
		if arg.begins_with("--frame-budget="):
			shared = arg.get_slice("=", 1) != "separate"
		elif arg.begins_with("--frame-budget-belts="):
			belts_first = arg.get_slice("=", 1) != "off"
		elif arg.begins_with("--budget-hard-cap="):
			hard_cap = arg.get_slice("=", 1) != "off"


## Starts a new frame's books when the frame changed (the first system to ask in a frame).
static func _roll() -> void:
	var f := Engine.get_process_frames()
	if f == _frame:
		return
	if not _arg_checked:
		_check_arg()
	var other := 0.0
	var sampled := true
	if test_other_usec >= 0:
		other = float(test_other_usec)
	elif not measure_frame:
		other = Performance.get_monitor(Performance.TIME_PROCESS) * 1.0e6 - _last_frame_used
	elif _frame >= 0 and _end_frame == _frame and _end_usec > _frame_start:
		# The frame that ended: its scripts from the first ask to the last, less its sliced work.
		other = float(_end_usec - _frame_start - used_total)
		other_usec = int(other)
	else:
		sampled = false  # no world drawing (the menu): the last measure stands
	_frame = f
	_frame_start = Time.get_ticks_usec()
	if sampled:
		_other_ema = lerpf(_other_ema, maxf(other, 0.0), 0.1)
	var target := _target()
	var busy := false
	for s in queued:
		if int(queued[s]) > 0 and int(SYSTEMS[s][0]) <= 3:
			busy = true
	pool = clampi(int(target - RESERVE_USEC - _other_ema), POOL_MIN, (POOL_MAX if busy else POOL_IDLE) * (BOOST if boost else 1))
	_last_frame_used = used_total
	used_total = 0
	_reduce_used = 0
	used.clear()
	granted.clear()


## How long `system` may run now, in µs. 0: nothing this frame (it does nothing, not even one item).
## `scale` multiplies its own slice (messages with a backlog take twice theirs, as the pool allows).
## `behind`: its work has waited too long (bridge.gd's messages, --message-catchup): it gets at least
## its own slice (not times `scale`), whatever the pool has left and past the frame's deadline. With
## the pool at POOL_MIN (the frame's other scripts at 9 ms or more: loading or walking a big base) the
## messages otherwise get POOL_MIN less LOW_RESERVE, 2 ms, backlog or not, and at a lower frame rate
## that was fewer than the bridge sends (bridge.gd).
static func grant(system: StringName, scale := 1, behind := false) -> int:
	_roll()
	var own := int(_sys(system)[1]) * scale * (BOOST if boost else 1)
	if not shared:
		granted[system] = own
		return own
	var prio := int(_sys(system)[0])
	# Kept for the higher systems that haven't run yet this frame and have work waiting.
	var reserve := 0
	var low_waits := false
	for s in SYSTEMS:
		var sy := _sys(s)
		var p := int(sy[0])
		if p < prio and not used.has(s) and int(queued.get(s, 0)) > 0:
			reserve += mini(int(_last_use.get(s, sy[1])), int(sy[1]))
		elif p > NEAR_PRIORITY and int(queued.get(s, 0)) > 0:
			low_waits = true
	if prio <= NEAR_PRIORITY and low_waits:
		reserve += LOW_RESERVE
	var left := pool - used_total - reserve
	if not test_no_deadline:
		left = mini(left, _frame_start + _target() - RESERVE_USEC - Time.get_ticks_usec() - reserve)
	if spent_aware:
		left -= _other_over()
	var g := mini(left, own)
	var is_starved := false
	if g < MIN_SLICE:
		g = 0
		if int(queued.get(system, 0)) > 0:
			var n := int(_starved.get(system, 0)) + 1
			_starved[system] = n
			if n >= STARVE_FRAMES:
				is_starved = true
				g = MIN_SLICE
	var reducer := reduce_floors and REDUCERS.has(system) and int(queued.get(system, 0)) > 0 and _reduce_used < REDUCE_TOTAL
	if hard_cap and not behind and prio > 4 and system != &"pipelines":
		var cap_left := maxi(pool - used_total, 0)
		if is_starved and g >= MIN_SLICE:
			if _starve_granted_frame == _frame or used_total >= pool + MIN_SLICE:
				g = 0
			else:
				_starve_granted_frame = _frame
		else:
			var fl := mini(int(_sys(system)[2]) * scale, cap_left)
			if fl >= MIN_SLICE:
				g = maxi(g, fl)
			if g > cap_left:
				g = cap_left if cap_left >= MIN_SLICE else 0
	else:
		g = maxi(g, int(_sys(system)[2]) * scale)
	if reducer:
		# Never less than the old floors: raised after them to its floor whatever the pool and the deadline
		# say (REDUCERS), within REDUCE_TOTAL for them all (only what the raise added counts).
		var rf := mini(int(REDUCERS[system]) * scale, REDUCE_TOTAL - _reduce_used)
		var add := maxi(rf - g, 0)
		g += add
		_reduce_used += add
	if behind:
		var slice := int(_sys(system)[1]) * (BOOST if boost else 1)
		if g < slice:
			g = slice
			catchups[system] = int(catchups.get(system, 0)) + 1
	if g > 0:
		_starved.erase(system)
	granted[system] = maxi(int(granted.get(system, 0)), g)
	return g


## The frame's unbudgeted scripts (everything since the first ask that wasn't sliced work) past what the pool was
## sized for (their smoothed time a whole frame, _other_ema): a frame whose other scripts already ran long (a burst of
## messages' side effects, the hover panel, inserters) has that much less for the sliced work, whatever the pool's
## clamp (POOL_MAX kept 6 ms for them while the other scripts already took 10, so the frame was their sum: 20-30 ms).
## The floors and the reducing systems' raise (REDUCERS) are applied after it, so they stay.
## `--budget-spent=off`: as before (only the pool and the frame's deadline).
static func _other_over() -> int:
	if test_spent_other_usec < 0 and (test_no_deadline or test_other_usec >= 0):
		return 0  # the UI test's frames: no clock
	var spent_other := test_spent_other_usec if test_spent_other_usec >= 0 else Time.get_ticks_usec() - _frame_start - used_total
	return maxi(spent_other - int(_other_ema), 0)


## Before another item of a sliced system's queue: what one of them typically costs (a smoothed cost of the last
## ones, note_item()), for the slice's clock check, so the slice stops before an item that would take it past its
## grant instead of after (the slices checked the clock only between items: belt lanes' chunks +3.3 ms past theirs,
## LOD installs +4.5, wires 58 times a minute +1.4, messages up to +7.1, R&D run-spikes). 0 with `--budget-predict=off`
## (the clock alone, as before). `kind`: a kind of item within the system (a message type), "" for all.
static func item_est(system: StringName, kind := "") -> int:
	if not predict:
		return 0
	return int(_item_ema.get(_item_key(system, kind), 0.0))


## An item of `system` (of `kind`) took `usec` µs.
static func note_item(system: StringName, usec: int, kind := "") -> void:
	if not predict:
		return
	var k := _item_key(system, kind)
	var was := float(_item_ema.get(k, -1.0))
	# Rises at once halfway to a slow item, falls slowly: one big chunk's install is warning enough.
	_item_ema[k] = float(usec) if was < 0.0 else (lerpf(was, float(usec), 0.5) if usec > was else lerpf(was, float(usec), ITEM_EMA))


## Whether a slice that began at `start` with `allow` µs and has done `done` items may start another of `est` µs:
## at least one item a frame (the floor's progress), then only while it fits.
static func fits(start: int, allow: int, done: int, est: int) -> bool:
	if done <= 0:
		return true
	return Time.get_ticks_usec() - start + est <= allow


static func _item_key(system: StringName, kind: String) -> String:
	return String(system) if kind == "" else "%s:%s" % [system, kind]


## The frame the sliced work aims for: TARGET_USEC, an FPS cap's under 60, or BOOST_TARGET_USEC.
static func _target() -> int:
	if boost:
		return BOOST_TARGET_USEC
	if Engine.max_fps >= 30 and Engine.max_fps < 60:
		return int(1.0e6 / Engine.max_fps)
	return TARGET_USEC


## `system` ran for `usec` µs and has `waiting` left (0 when its queue is empty).
static func spent(system: StringName, usec: int, waiting: int) -> void:
	_roll()
	used[system] = int(used.get(system, 0)) + usec
	used_total += usec
	queued[system] = waiting
	if waiting > 0 or usec > 0:
		_last_use[system] = usec
	var g := int(granted.get(system, int(_sys(system)[1])))
	if usec > g + OVERRUN_SLACK:
		overruns[system] = int(overruns.get(system, 0)) + 1


## Only the work waiting changed (a system with nothing to do this frame).
static func waiting(system: StringName, n: int) -> void:
	queued[system] = n


## This frame's books for --stutter-probe: {system: [µs used, µs granted, waiting]}, and "pool".
static func snapshot() -> Dictionary:
	var out := {"pool": pool}
	for s in SYSTEMS:
		var u := int(used.get(s, 0))
		var q := int(queued.get(s, 0))
		if u > 0 or q > 0:
			out[s] = [u, int(granted.get(s, 0)), q]
	return out


## For tests: everything back to its start.
static func reset() -> void:
	_frame = -1
	_starve_granted_frame = -1
	_reduce_used = 0
	far_urgent = false
	used.clear()
	granted.clear()
	queued.clear()
	_last_use.clear()
	_starved.clear()
	overruns.clear()
	catchups.clear()
	used_total = 0
	_last_frame_used = 0
	_other_ema = 6000.0
	_item_ema.clear()
	test_spent_other_usec = -1
	_end_frame = -1
	other_usec = -1
	pool = POOL_MAX
