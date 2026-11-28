extends RefCounted
## Building while the left button is held, as Factorio 2.x does it:
##   belts go along the line of the held belt's way through where the drag began, each facing the
##       held way (J25): dragged that way the line grows forward, dragged against it backwards (the
##       belts still face the held way, so a line can be built from its end). Going back over what
##       the drag built changes nothing (Factorio 2.0.61 removed such belts and 2.0.66 took that
##       back). A cursor off the line builds nothing; R while dragging turns the line at its last belt
##       towards the cursor (or a quarter round, Shift+R the other way, with the cursor on the line)
##       and builds out to the cursor, Factorio's "fast belt bending": going forward the last belt
##       turns the new way, going backwards it stays and the new belts flow into it. With "Smart belt
##       building" (Settings → Interface, on by default) an obstacle or a belt line crossing the way
##       is jumped with a pair of the belt's undergrounds once the cursor is past it and within the
##       underground's reach, the entrance upstream either way.
##       With "Lock belt building to straight line" off (Zenith's own; Factorio 2.x always locks)
##       belts follow the cursor and turn corners instead (the belt where the line turns points the
##       new way), holding their line while the mouse drifts less than TURN_SLACK tiles off it or
##       stays ahead within 45 degrees of it (I12); begun against the held way they go backwards
##       there too, the new belts flowing into the last at a corner.
##   pipes drag in a straight line and jump obstacles with a pair of pipes-to-ground;
##   walls follow the cursor's path tile by tile, round corners and in any shape (N5): no line lock,
##       which in Factorio is the belts' alone; a diagonal move fills its path as a staircase of
##       side-by-side tiles, so the wall stays joined (`--wall-drag=line`: along one line, as before);
##   electric poles follow the cursor's path at any angle (I13): when the cursor gets further than
##       the wire reaches from the last pole, the next goes on the furthest free spot of its path
##       still in reach of it (an existing pole the cursor crosses counts as the last one);
##   underground belts and pipes-to-ground go in pairs at their maximum reach: an entrance, its exit
##       as the cursor gets there (or the furthest free tile short of it), the next entrance on the
##       first free tile past it, and so on. The first piece waits for the line's direction, or for
##       the button to come up on a plain click, since it can't be turned reliably once built;
##   anything else is placed along the line, one footprint after another;
## and a faster belt (or anything of the same fast-replace kind) dragged over a line replaces it,
## which the mod's `build` does. Shift (or none to start with: the pipette's ghost cursor, or remote
## view) makes it all ghosts; a drag begun with items stays real and stops when they run out (I5:
## it used to turn into ghosts part way along).

const ProtoDB := preload("res://scripts/world/protos.gd")
const WorldMirror := preload("res://scripts/world/world.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const VisualTurns := preload("res://scripts/world/visual_turns.gd")
const Predicted := preload("res://scripts/world/predicted.gd")
const UndergroundPairs := preload("res://scripts/world/underground_pairs.gd")
const RailBlocks := preload("res://scripts/player/rail_blocks.gd")
const Switches := preload("res://scripts/switches.gd")

const DIRS := {Vector2i(0, -1): 0, Vector2i(1, 0): 4, Vector2i(0, 1): 8, Vector2i(-1, 0): 12}
const UNDERGROUND_TYPES := ["underground-belt", "pipe-to-ground"]
## Following the cursor (lock off), a belt drag turns only once the cursor is this many tiles off
## its line (and not further ahead along it than it is off): a hand drifting a tile while dragging
## keeps the line straight.
const TURN_SLACK := 2
## N5: walls follow the cursor's path; `--wall-drag=line` holds them to one line as before.
static var walls_follow := not (Switches.has("--wall-drag=line"))
## Pipes follow the cursor's path; `--pipe-drag=line` holds them to one line as before.
static var pipes_follow := not (Switches.has("--pipe-drag=line"))
## Cap stepped tiles per frame while preserving remaining drag path so fast drags don't spike.
const MAX_STEPS_PER_FRAME := 4

## player_input (world, hud, build_dir, _blocked, _remember); untyped to keep the scripts apart.
var pi: Node

var _active := false
var _item := ""
var _proto: ProtoDB.EntityProto = null
var _ghost := false
var _start := Vector2i.ZERO
## The line's axis once the cursor first moved off the start tile (Vector2i.ZERO before that).
var _axis := Vector2i.ZERO
## The tile last stepped onto (belts walk tile by tile to the cursor).
var _cur := Vector2i.ZERO
## The last tile built on, its direction, and whether anything was built yet.
var _last_built := Vector2i.ZERO
var _last_dir := 0
var _has_last := false
## An obstacle being jumped: the tile before it (where the entrance goes; going backwards the exit),
## the way things flow there, or none, and the way the drag goes.
var _gap_from := Vector2i.ZERO
var _gap_dir := -1
var _gap_step := Vector2i.ZERO
## Where the last piece of a line went (poles: the last pole; others: the last footprint).
var _line_last := Vector2i.ZERO
## Footprint lines: where the first one went (the cursor) and how many followed.
var _line_pos0 := Vector2.ZERO
var _line_k := 0
## Undergrounds: the first piece not sent yet, an entrance waiting for its exit and where it is, and
## how far along the line the drag has been (the cursor going back builds nothing).
var _first_waits := false
var _under_open := false
var _under_from := Vector2i.ZERO
var _under_along := 0
## Belts following the cursor: the way the line runs now (its first axis, then the way of its last
## corner).
var _heading := Vector2i.ZERO
## Belts: the way they flow (the held way; R turns it), and whether the line grows against it.
var _flow := Vector2i.ZERO
var _backward := false
## Belts on a locked line: where the line starts (the drag's start, or the belt R turned it at) and
## how far it has been built from there along the flow (ahead, >= 0) and against it (behind, <= 0).
var _line_from := Vector2i.ZERO
var _ahead := 0
var _behind := 0
## Poles: the tiles the cursor crossed since the last pole, in order (where the next may go).
var _path: Array[Vector2i] = []
## Walls following the cursor: the tiles this drag already built on (going back sends nothing).
var _walled := {}
## Out of items during a real drag: said once.
var _ran_out := false
## Commands sent during this drag, for tests: [cmd, ...].
var sent: Array = []
## Per-frame step cap state and queued waypoints for fast drags.
var _step_frame := -1
var _steps_in_frame := 0
var _queued_targets: Array[Vector2i] = []
var _pending_stop := false
var _pending_ground := Vector2.ZERO
var _last_rail_snap: Array = []
var _rail_start_ground := Vector2.ZERO


func _held_dir() -> int:
	if pi != null and pi.has_method("effective_build_dir"):
		return int(pi.effective_build_dir(_proto, _ghost))
	return int(pi.build_dir)


func _snap_rail_spot(at: Vector2, fallback_dir: int) -> Dictionary:
	if pi != null and pi.get("rail_blocks") != null and _proto != null and RailBlocks.is_rail_attachment(_proto.type):
		var eprops: Dictionary = pi.hud.ui.model.eprops if pi.hud != null else {}
		return pi.rail_blocks.snap_spot(pi.world, _proto, at, fallback_dir, _ghost, eprops)
	return {}


func begin(item: String, proto: ProtoDB.EntityProto, ground: Vector2, ghost: bool) -> void:
	_active = true
	_item = item
	_proto = proto
	_ghost = ghost
	_start = Vector2i(floori(ground.x), floori(ground.y))
	_cur = _start
	_axis = Vector2i.ZERO
	_has_last = false
	_gap_dir = -1
	sent = []
	_under_open = false
	_under_along = 0
	_heading = Vector2i.ZERO
	var dir := _held_dir()
	_flow = _vec(dir)
	_backward = false
	_line_from = _start
	_ahead = 0
	_behind = 0
	_path.clear()
	_walled = {_start: true}
	_ran_out = false
	_queued_targets.clear()
	_pending_stop = false
	_pending_ground = Vector2.ZERO
	_last_rail_snap = []
	_rail_start_ground = Vector2.ZERO
	_first_waits = _under_reach() > 0
	if _proto != null and RailBlocks.is_rail_attachment(_proto.type):
		_rail_start_ground = ground
		var rb := _snap_rail_spot(ground, dir)
		if not rb.is_empty() and bool(rb.get("snapped", false)):
			var spos: Vector2 = rb["pos"]
			var sdir := int(rb["dir"])
			_last_rail_snap = [spos, sdir]
			_send_at(_item, spos, sdir)
			_last_dir = sdir
		else:
			_send_at(_item, ground, dir)
			_last_dir = dir
		_last_built = _start
		_has_last = true
		_line_last = _start
		_line_k = 0
		_line_pos0 = ground
		return
	if _proto.type == "electric-pole":
		# A pole two tiles wide is centred on a grid corner, up to a tile from the cursor's tile:
		# the line and its wire reach are measured from where it really stands.
		var size := _size_for(dir)
		_start = Vector2i(floori(pi._snap(ground.x, size.x)), floori(pi._snap(ground.y, size.y)))
		_cur = _start
	# The first one goes exactly where a click puts it (the mod snaps it to the grid); clicking a belt
	# with another direction rotates/fast-replaces it to `dir`, while drag-crossing avoids perpendicular belts.
	if not _first_waits:
		_send_at(_item, ground, dir)
		_last_built = _start
		_last_dir = dir
		_has_last = true
	else:
		_last_built = _start
		_last_dir = dir
		_has_last = true
	_line_last = _start
	_line_k = 0
	_line_pos0 = ground


func end() -> void:
	if _active:
		if _pending_stop or not _queued_targets.is_empty():
			update(_pending_ground, -1)
		if _first_waits and str(pi.cursor_item) == _item:
			_first_waits = false
			_send_at(_item, _line_pos0, _held_dir())  # a plain click: as held
	_queued_targets.clear()
	_pending_stop = false
	_last_rail_snap = []
	_rail_start_ground = Vector2.ZERO
	_active = false


func active() -> bool:
	return _active


## Called every frame while the button is held, with the cursor's ground point.
## When `max_steps > 0`, caps stepped tiles per process frame and preserves remaining path.
func update(ground: Vector2, max_steps := -1) -> void:
	if not _active:
		return
	if _proto != null and RailBlocks.is_rail_attachment(_proto.type):
		if ground.distance_squared_to(_rail_start_ground) < 0.25:
			return
		var rb := _snap_rail_spot(ground, _held_dir())
		if not rb.is_empty() and bool(rb.get("snapped", false)) and bool(rb.get("valid", false)):
			var spos: Vector2 = rb["pos"]
			var sdir := int(rb["dir"])
			var snap_key := [spos, sdir]
			if snap_key != _last_rail_snap:
				if _last_rail_snap.size() == 2 and ground.distance_squared_to(_last_rail_snap[0] as Vector2) <= ground.distance_squared_to(spos) + 0.0001:
					return
				_last_rail_snap = snap_key
				_rail_start_ground = ground
				_send_at(_item, spos, sdir)
		return
	var budget := 1 << 20
	if max_steps > 0:
		var frame := Engine.get_process_frames()
		if frame != _step_frame:
			_step_frame = frame
			_steps_in_frame = 0
		budget = maxi(0, max_steps - _steps_in_frame)
		if budget <= 0:
			_pending_stop = true
			_pending_ground = ground
			if (_proto.type == "wall" and walls_follow) or ((_proto.type == "pipe" or _proto.type == "heat-pipe") and pipes_follow) or (_proto.type == "transport-belt" and not locked()):
				_queue_path_target(Vector2i(floori(ground.x), floori(ground.y)))
			return
	if _proto.type == "electric-pole" and _wire() > 0.0:
		_pending_stop = false
		_follow_poles(ground)
		return
	var tile := Vector2i(floori(ground.x), floori(ground.y))
	if tile == _cur and not _pending_stop and _queued_targets.is_empty():
		return
	if _axis == Vector2i.ZERO and tile != _start:
		var d := tile - _start
		_axis = Vector2i(signi(d.x), 0) if absi(d.x) >= absi(d.y) else Vector2i(0, signi(d.y))
	if _proto.type == "wall" and walls_follow:
		_step_queued_path(tile, ground, budget, max_steps > 0, _follow_walls)
		return
	if (_proto.type == "pipe" or _proto.type == "heat-pipe") and pipes_follow:
		_step_queued_path(tile, ground, budget, max_steps > 0, _follow_pipes)
		return
	if _proto.type == "transport-belt":
		if locked():
			var res := _belt_line(tile, budget)
			if max_steps > 0:
				_steps_in_frame += int(res[0])
			if bool(res[1]):
				_pending_stop = false
				_cur = tile
			else:
				_pending_stop = true
				_pending_ground = ground
		else:
			_step_queued_path(tile, ground, budget, max_steps > 0, _follow)
	else:
		var res := _along_line(tile, budget)
		if max_steps > 0:
			_steps_in_frame += int(res[0])
		if bool(res[1]):
			_pending_stop = false
		else:
			_pending_stop = true
			_pending_ground = ground


func _queue_path_target(tile: Vector2i) -> void:
	if _queued_targets.is_empty():
		if tile != _cur:
			_queued_targets.append(tile)
	elif _queued_targets[_queued_targets.size() - 1] != tile:
		_queued_targets.append(tile)


func _step_queued_path(tile: Vector2i, ground: Vector2, budget: int, track_frame: bool, stepper: Callable) -> void:
	_queue_path_target(tile)
	var left := budget
	while not _queued_targets.is_empty() and left > 0:
		var target: Vector2i = _queued_targets[0]
		var res: Array = stepper.call(target, left)
		var used := int(res[0])
		var done := bool(res[1])
		left -= used
		if track_frame:
			_steps_in_frame += used
		if done:
			_queued_targets.remove_at(0)
		else:
			break
	if _queued_targets.is_empty():
		_pending_stop = false
	else:
		_pending_stop = true
		_pending_ground = ground


## Belts held to one line (Factorio 2.x; Settings' "Lock belt building to straight line").
static func locked() -> bool:
	return bool(Settings.get_value("interface", "lock_belt_straight"))


## Belts on a locked line: every tile from the line's built end to the cursor's place on the line,
## ahead along the flow or behind it (see the top of this file). Back within what is built: nothing.
## Returns [steps_used, finished].
func _belt_line(tile: Vector2i, budget := 1 << 20) -> Array:
	if _flow == Vector2i.ZERO:
		return [0, true]
	var used := 0
	var along := _along_flow(tile - _line_from)
	if along > _ahead:
		_side(false)
		while _ahead < along and used < budget:
			_ahead += 1
			used += 1
			_step_belt(_line_from + _flow * _ahead, _flow, _flow)
		return [used, _ahead >= along]
	elif along < _behind:
		_side(true)
		while _behind > along and used < budget:
			_behind -= 1
			used += 1
			_step_belt(_line_from + _flow * _behind, -_flow, _flow)
		return [used, _behind <= along]
	return [0, true]


## The line grows on its other side now: a jump in progress is dropped, and the last belt is that
## side's end.
func _side(backward: bool) -> void:
	if backward == _backward:
		return
	_backward = backward
	_gap_dir = -1
	_last_built = _line_from + _flow * (_behind if backward else _ahead)
	_last_dir = int(DIRS[_flow])


func _along_flow(v: Vector2i) -> int:
	return v.x * _flow.x + v.y * _flow.y


## Belts following the cursor: one tile at a time towards the cursor along the line's heading,
## turning a corner only once the cursor has clearly left the line (see TURN_SLACK and the top of
## this file). Begun against the held way, the belts face back along the drag.
## Returns [steps_used, done].
func _follow(target: Vector2i, budget := 1 << 20) -> Array:
	if _heading == Vector2i.ZERO:
		_heading = _axis
		_backward = _axis == -_flow
	var used := 0
	var guard := 0
	while _cur != target and used < budget and guard < 64:
		guard += 1
		var step := follow_step(target - _cur, _heading)
		if step == Vector2i.ZERO:
			return [used, true]
		_heading = step
		_step_belt(_cur + step, step, -step if _backward else step)
		_cur += step
		used += 1
	return [used, _cur == target or guard >= 64]


## The belt drag's next step for the cursor `d` tiles from the last belt, running along `heading`:
## ahead while the cursor is ahead and less off the line than ahead of it (or under TURN_SLACK off
## it), sideways once it is TURN_SLACK or more off it, else none (it drifted, or went back: going back
## over the line changes nothing, as in Factorio).
static func follow_step(d: Vector2i, heading: Vector2i) -> Vector2i:
	var side := Vector2i(-heading.y, heading.x)
	var along := d.x * heading.x + d.y * heading.y
	var off := d.x * side.x + d.y * side.y
	if along > 0 and (absi(off) < TURN_SLACK or absi(off) <= along):
		return heading
	if absi(off) >= TURN_SLACK:
		return side * signi(off)
	return Vector2i.ZERO


## R (Shift+R: `reverse`) while a belt drag is on: Factorio's fast belt bending. The line turns at its
## last belt towards the cursor `ground` (with the cursor on the line, a quarter round: clockwise,
## or the other way with Shift), and is built out to the cursor at once. Going forward the last belt
## turns the new way; going backwards it stays and the new belts flow into it. The held way follows.
## False when no belt drag is on (R turns the held item as ever).
func rotate(reverse: bool, ground: Vector2) -> bool:
	if not _active or _proto == null or _proto.type != "transport-belt" or _flow == Vector2i.ZERO:
		return false
	var corner := _last_built if _has_last else _start
	var step := -_flow if _backward else _flow
	var tile := Vector2i(floori(ground.x), floori(ground.y))
	var side := Vector2i(-step.y, step.x)  # clockwise of the way the line grows (y is south)
	var off := (tile - corner).x * side.x + (tile - corner).y * side.y
	var turned: Vector2i
	if off != 0:
		turned = side * signi(off)
	else:
		turned = -side if reverse else side
	_flow = -turned if _backward else turned
	var dir := int(DIRS[_flow])
	pi.build_dir = dir
	_gap_dir = -1
	if not _backward:
		_place(corner, dir)  # the corner points the new way
	_last_built = corner
	_last_dir = dir
	_has_last = true
	_line_from = corner
	_ahead = 0
	_behind = 0
	_cur = corner
	_heading = turned
	_axis = turned
	_queued_targets.clear()
	_pending_stop = false
	update(ground)
	return true


func _wire() -> float:
	return float(pi.hud.ui.model.eprops.get(_proto.id, {}).get("wire", 0.0))


## Poles: the cursor's path is kept tile by tile (a fast mouse fills the tiles between frames), and
## whenever its newest tile is out of the wire's reach of the last pole, a pole goes on the furthest
## tile of the path that is in reach, free and not on the last pole. A pole the cursor crosses
## becomes the last one.
func _follow_poles(ground: Vector2) -> void:
	var dir := _held_dir()
	var size := _size_for(dir)
	var tile := Vector2i(floori(pi._snap(ground.x, size.x)), floori(pi._snap(ground.y, size.y)))
	if tile == _cur:
		return
	var from := _cur
	var steps := maxi(absi(tile.x - from.x), absi(tile.y - from.y))
	for i in range(1, steps + 1):
		var t := Vector2(from).lerp(Vector2(tile), float(i) / steps)
		_path.append(Vector2i(roundi(t.x), roundi(t.y)))
	_cur = tile
	var reach := floorf(_wire())
	var guard := 0
	while not _path.is_empty() and guard < 32:
		guard += 1
		var newest: Vector2i = _path[_path.size() - 1]
		if _is_pole(_aim(newest, size)):
			_line_last = newest
			_path.clear()
			return
		if Vector2(newest - _line_last).length() <= reach:
			return
		var placed := -1
		for k in range(_path.size() - 1, -1, -1):
			var p: Vector2i = _path[k]
			if Vector2(p - _line_last).length() > reach:
				continue
			if _overlaps(p, _line_last, size) or pi._blocked(_proto, _aim(p, size), size):
				continue
			placed = k
			break
		if placed < 0:
			# Nowhere free in reach: the wire can't go on from the last pole, so the line starts
			# again from where the cursor is now, as when a pole is clicked there.
			_line_last = newest
			_path.clear()
			return
		var at: Vector2i = _path[placed]
		_place(at, dir)
		_line_last = at
		_path = _path.slice(placed + 1)


## Walls: one tile at a time from the last tile to the cursor's, along whichever axis has further to
## go (a diagonal makes a staircase of tiles sharing sides, as Factorio fills a dragged wall), a wall
## on each tile not built on yet in this drag. Returns [steps_used, done].
func _follow_walls(target: Vector2i, budget := 1 << 20) -> Array:
	var used := 0
	var guard := 0
	while _cur != target and used < budget and guard < 256:
		guard += 1
		_cur += wall_step(target - _cur)
		used += 1
		if _walled.has(_cur):
			continue
		_walled[_cur] = true
		_place(_cur, _held_dir())
	return [used, _cur == target or guard >= 256]


## Pipes and heat-pipes: follow the cursor's path tile by tile without locking to a straight line
## (Bug #8), while jumping obstacles with pipes-to-ground when moving along a cardinal run.
## Returns [steps_used, done].
func _follow_pipes(target: Vector2i, budget := 1 << 20) -> Array:
	var used := 0
	var guard := 0
	while _cur != target and used < budget and guard < 256:
		guard += 1
		var step := wall_step(target - _cur)
		_cur += step
		used += 1
		var dir := int(DIRS.get(step, int(pi.build_dir)))
		if _walled.has(_cur):
			_gap_dir = -1
			continue
		_step_pipe(_cur, dir, step)
	return [used, _cur == target or guard >= 256]


## A wall drag's next step towards a cursor `d` tiles away: along the longer way, x on a tie.
static func wall_step(d: Vector2i) -> Vector2i:
	if absi(d.x) >= absi(d.y):
		return Vector2i(signi(d.x), 0)
	return Vector2i(0, signi(d.y))


static func _overlaps(a: Vector2i, b: Vector2i, size: Vector2i) -> bool:
	return absi(a.x - b.x) < size.x and absi(a.y - b.y) < size.y


## Straight-line entities: the cursor projected on the first line.
## Returns [steps_used, finished].
func _along_line(tile: Vector2i, budget := 1 << 20) -> Array:
	var along := (tile - _start).x * _axis.x + (tile - _start).y * _axis.y
	var target := _start + _axis * along
	if along < 0:
		return [0, true]  # Factorio doesn't build back past where the drag started
	var dir := int(DIRS.get(_axis, int(pi.build_dir)))
	var used := 0
	while _cur != target and used < budget:
		var next := _cur + _axis if (target - _cur).x * _axis.x + (target - _cur).y * _axis.y > 0 else _cur - _axis
		match _proto.type:
			"pipe", "heat-pipe":
				_step_pipe(next, dir, next - _cur)
			"electric-pole":
				_step_pole(next)
			"underground-belt", "pipe-to-ground":
				_step_under(next, dir)
			_:
				_step_footprint(next, dir)
		_cur = next
		used += 1
	return [used, _cur == target]


## One belt of a drag at `next`, the drag going `step` and the belt facing `flow` (the same way going
## forward, the other way going backwards).
func _step_belt(next: Vector2i, step: Vector2i, flow: Vector2i) -> void:
	var dir := int(DIRS[flow])
	pi.build_dir = dir
	if _gap_dir >= 0:
		_continue_gap(next, dir, _under_item("b"), step)
		return
	# Going forward the line turns: the belt where it turns points the new way (Factorio's corner).
	# Going backwards the new belt flows into it as it is.
	if step == flow and _has_last and _last_dir != dir and _last_built == next - step:
		_place(_last_built, dir)
	if _obstacle(next, dir):
		if bool(Settings.get_value("interface", "smart_belt_building")) and _under_item("b") != "" and _has_last:
			_gap_from = _last_built
			_gap_dir = dir
			_gap_step = step
		return
	_place(next, dir)


func _step_pipe(next: Vector2i, dir: int, step := Vector2i.ZERO) -> void:
	if step == Vector2i.ZERO:
		step = _vec(dir)
	if _gap_dir >= 0:
		if dir == _gap_dir and step == _gap_step:
			_continue_gap(next, dir, _under_item("p"), step)
			return
		_gap_dir = -1
	if _obstacle(next, dir):
		if _under_item("p") != "" and _has_last:
			_gap_from = _last_built
			_gap_dir = dir
			_gap_step = step
		return
	_place(next, dir)


## Past the obstacle: an underground (pipe-to-ground) pair when the free tile is within reach, the
## entrance replacing the last piece before it (going backwards the exit does, the entrance going
## past the obstacle, upstream).
func _continue_gap(next: Vector2i, dir: int, under_item: String, step: Vector2i) -> void:
	if dir != _gap_dir or step != _gap_step:
		_gap_dir = -1
		return
	if _obstacle(next, dir):
		return
	var under_proto: ProtoDB.EntityProto = pi.world.protos.placed_entity(under_item)
	var reach := 0
	if under_proto != null:
		reach = int(pi.hud.ui.model.eprops.get(under_proto.id, {}).get("under", 0.0))
	var dist := absi((next - _gap_from).x) + absi((next - _gap_from).y)
	_gap_dir = -1
	if under_proto == null or dist > reach:
		_place(next, dir)  # too far for the underground: the line starts again past it
		return
	if under_proto.type == "pipe-to-ground":
		# A pipe-to-ground's direction is its above-ground connection: back along the line at the
		# entrance, forward at the exit (checked in 2.1.23).
		_send(under_item, _gap_from, posmod(dir + 8, 16))
		_send(under_item, next, dir)
		_walled[next] = true
	elif step == _vec(dir):
		# The mod makes the second of a pair the exit (both face the way items go).
		_send(under_item, _gap_from, dir)
		_send(under_item, next, dir)
	else:
		# Going backwards the entrance is past the obstacle: sent first, so the one before it is the exit.
		_send(under_item, next, dir)
		_send(under_item, _gap_from, dir)
	_last_built = next
	_last_dir = dir
	_has_last = true


func _step_pole(next: Vector2i) -> void:
	var wire := float(pi.hud.ui.model.eprops.get(_proto.id, {}).get("wire", 0.0))
	if wire <= 0.0:
		_step_footprint(next, int(pi.build_dir))
		return
	var dir := int(pi.build_dir)
	var size := _size_for(dir)
	if _is_pole(_aim(next, size)):
		_line_last = next  # the wire goes on from a pole already standing on the line
		return
	if Vector2(next - _line_last).length() > floorf(wire):
		# Past the reach: the pole goes on the furthest free tile back towards the last one, not
		# overlapping it.
		var span := absi(_axis.x) * size.x + absi(_axis.y) * size.y
		var back := next - _axis
		while _along(back - _line_last) >= span and pi._blocked(_proto, _aim(back, size), size):
			back -= _axis
		if _along(back - _line_last) >= span:
			_place(back, dir)
			_line_last = back


## Undergrounds, one tile of the drag at a time (see the top of this file).
func _step_under(next: Vector2i, dir: int) -> void:
	var reach := _under_reach()
	if reach <= 0:
		_step_footprint(next, dir)
		return
	if _first_waits:
		_first_waits = false
		_entrance(_start, dir)
	var along := _along(next - _start)
	if along <= _under_along:
		return
	_under_along = along
	if not _under_open:
		if not _under_in_way(next):
			_entrance(next, dir)
		return
	if _along(next - _under_from) < reach:
		return
	var exit := next
	while exit != _under_from and _under_in_way(exit):
		exit -= _axis
	_under_open = false  # nowhere for an exit: the entrance stays alone and the line starts again
	if exit != _under_from:
		# The mod makes the second of a pair the exit; a pipe-to-ground's direction is its
		# above-ground connection, forward at the exit (see _continue_gap).
		_send(_item, exit, dir)
		_last_built = exit
		_last_dir = dir


func _entrance(tile: Vector2i, dir: int) -> void:
	if _proto.type == "underground-belt":
		pi.build_dir = dir
		_send(_item, tile, dir)
	else:
		_send(_item, tile, posmod(dir + 8, 16))  # connected back along the line
	_under_open = true
	_under_from = tile
	_last_built = tile
	_last_dir = dir


func _under_reach() -> int:
	if not UNDERGROUND_TYPES.has(_proto.type):
		return 0
	return int(pi.hud.ui.model.eprops.get(_proto.id, {}).get("under", 0.0))


## In the way of an underground piece: what player_input's build check calls blocked, but for the
## belt or pipe it would fast-replace.
func _under_in_way(tile: Vector2i) -> bool:
	var at := _aim(tile, Vector2i.ONE)
	if not pi._blocked(_proto, at, Vector2i.ONE):
		return false
	var r: WorldMirror.Rec = pi.world.pick(at)
	if r == null:
		return true
	var p: ProtoDB.EntityProto = pi.world.protos.entity(r.proto_id)
	return p == null or p.type != ("transport-belt" if _proto.type == "underground-belt" else "pipe")


func _is_pole(at: Vector2) -> bool:
	var r: WorldMirror.Rec = pi.world.pick(at)
	if r == null or r.extra.has("gh"):
		return false
	var p: ProtoDB.EntityProto = pi.world.protos.entity(r.proto_id)
	return p != null and p.type == "electric-pole"


## How many tiles along the line's axis `v` reaches.
func _along(v: Vector2i) -> int:
	return v.x * _axis.x + v.y * _axis.y


func _size_for(dir: int) -> Vector2i:
	var size: Vector2i = _proto.tile_size
	if dir == 4 or dir == 12:
		size = Vector2i(size.y, size.x)
	return size


func _step_footprint(next: Vector2i, dir: int) -> void:
	var size := _size_for(dir)
	var span := maxi(1, absi(_axis.x) * size.x + absi(_axis.y) * size.y)
	var along := (next - _start).x * _axis.x + (next - _start).y * _axis.y
	while (_line_k + 1) * span <= along:
		_line_k += 1
		_send_at(_item, _line_pos0 + Vector2(_axis * span * _line_k), _held_dir())


static func _vec(dir: int) -> Vector2i:
	for v in DIRS:
		if DIRS[v] == dir:
			return v
	return Vector2i.ZERO


## The belt's or pipe's own underground ("b" / "p" in `iuse`) if the character has some, or "".
func _under_item(kind: String) -> String:
	var u: Dictionary = pi.hud.ui.model.item_uses.get(_item, {})
	var under := str(u.get(kind, ""))
	if under == "" or (not _ghost and pi.items_left(under) <= 0):
		return ""
	return under


## An existing non-ghost transport-belt standing perpendicular to `dir` at `pos` (Bug #17).
func _perpendicular_belt_rec(pos: Vector2, dir: int) -> WorldMirror.Rec:
	if _proto == null or _proto.type != "transport-belt" or pi == null or pi.world == null:
		return null
	var r: WorldMirror.Rec = pi.world.pick(pos)
	if r == null or r.extra.has("gh"):
		return null
	var p: ProtoDB.EntityProto = pi.world.protos.entity(r.proto_id)
	if p != null and p.type == "transport-belt" and (r.dir % 8) != (dir % 8):
		return r
	return null


## In the way of the line: what player_input's build check calls blocked, and for belts any
## perpendicular belt crossing the line regardless of smart_belt_building (Bug #17).
func _obstacle(tile: Vector2i, dir: int) -> bool:
	var pos := Vector2(tile) + Vector2(0.5, 0.5)
	if pi._blocked(_proto, pos, Vector2i.ONE):
		return true
	if _perpendicular_belt_rec(pos, dir) != null:
		return true
	return false


func _place(tile: Vector2i, dir: int) -> void:
	_send(_item, tile, dir, _size_for(dir))
	if _proto != null and _proto.type in ["wall", "pipe", "heat-pipe"]:
		_walled[tile] = true
	_last_built = tile
	_last_dir = dir
	_has_last = true


func _send(item: String, tile: Vector2i, dir: int, size := Vector2i.ONE) -> void:
	_send_at(item, _aim(tile, size), dir)


## The mod snaps to the grid: aim at the footprint's centre.
static func _aim(tile: Vector2i, size: Vector2i) -> Vector2:
	var at := Vector2(tile) + Vector2(0.5, 0.5)
	if size.x % 2 == 0:
		at.x = float(tile.x)
	if size.y % 2 == 0:
		at.y = float(tile.y)
	return at


func _send_at(item: String, at: Vector2, dir: int) -> void:
	# J9: rounded down, so the mod snaps it where the preview stood (player_input.gd wire).
	var cmd := {"t": "build", "item": item, "x": pi.wire(at.x), "y": pi.wire(at.y), "d": dir}
	if _ghost:
		cmd["ghost"] = 1
	elif (pi.items_left(item) <= 0) if Predicted.spend_fix else (pi.hud.count_of(item) == 0 and item == _item):
		# A real drag that ran out (I5): it stops, as Factorio's does, instead of going on in ghosts.
		# L2: out means none left once the builds sent and not yet gone from the inventory shown are
		# counted (predicted.gd spend), so nothing past what the hand holds is sent or drawn. (An
		# underground pair's other item, `item` != `_item`, was checked by _under_item.)
		if not _ran_out and item == _item:
			_ran_out = true
			pi.hud.show_message("You have no %s" % item)
		return
	if pi._lmb_super:
		cmd["sf"] = 1  # Ctrl+Shift: super-forced, what's in the way is marked for deconstruction
	if pi.build_mirror:
		cmd["m"] = 1
	if pi.cursor_quality != "normal":
		cmd["q"] = pi.cursor_quality
	if not _ghost and item == str(pi.cursor_item):
		# L7: built out of the held stack's own slot, as Factorio builds from the cursor; once the
		# builds sent have used it up, out of the stack the cursor refills from (factorio_ui.gd).
		var hs: int = pi.hud.ui.build_slot()
		if hs > 0:
			cmd["hs"] = hs
	Bridge.send(cmd)
	sent.append(cmd)
	var proto: ProtoDB.EntityProto = pi.world.protos.placed_entity(item)
	var is_under := proto != null and UndergroundPairs.is_underground(proto.type)
	var under_pos := Vector2(pi._snap(at.x, 1), pi._snap(at.y, 1)) if is_under else Vector2.ZERO
	var check_cache := {}
	var will_place_under := is_under and _can_place_under(proto, under_pos, _ghost, check_cache)
	var look := _look_turned(item, dir)
	if not cmd.has("ghost"):
		pi._remember({"do": "build", "item": item, "x": at.x, "y": at.y, "d": dir})
		_spend(item, at, dir, check_cache)
		_predict_clear(item, at, dir, check_cache)
		_predict(item, at, dir, look != null, check_cache)
	if look != null:
		# K21: the game puts it down unturned (real or ghost); it keeps the cursor's turn once its `add` comes.
		VisualTurns.expect(look.id, Vector2(pi._snap(at.x, look.tile_size.x), pi._snap(at.y, look.tile_size.y)), dir)
	if will_place_under and pi.predicted != null:
		_record_sent_under(proto, under_pos, dir, _ghost)
	# Placing a pipe-to-ground flips the held cursor 180 degrees to face its connecting end.
	if will_place_under and _proto != null and _proto.type == "pipe-to-ground" and item == _item:
		pi.build_dir = posmod(dir + 8, 16)


func _cached_blocked(cache: Dictionary, proto: ProtoDB.EntityProto, pos: Vector2, size: Vector2i, replacing: bool) -> bool:
	var key := [proto.id, pos, size, replacing]
	if not cache.has(key):
		cache[key] = pi._blocked(proto, pos, size, replacing)
	return bool(cache[key])


func _cached_void(cache: Dictionary, pos: Vector2, size: Vector2i) -> bool:
	var key := ["void", pos, size]
	if not cache.has(key):
		cache[key] = pi._on_void(pos, size)
	return bool(cache[key])


## The building `item` places, when it is one Factorio can't turn (a furnace, a chest, a lab:
## visual_turns.gd) and the cursor has it turned: R turned the preview, so it is built turned for
## the look (K21). Null otherwise; those Factorio turns get the direction from the game.
func _look_turned(item: String, dir: int) -> ProtoDB.EntityProto:
	if posmod(dir, 16) == 0:
		return null
	var proto: ProtoDB.EntityProto = pi.world.protos.placed_entity(item)
	if proto == null:
		return null
	var x: Dictionary = pi.hud.ui.model.eprops.get(proto.id, {}).get("x", {})
	return proto if VisualTurns.eligible(proto, x) else null


## L2: a real build sent spends one of the item until the inventory shown has lost it
## (predicted.gd), where the client's own check says the game will take it: within the bridge's
## reach, not in the way (a build the game refuses spends nothing, and isn't counted against what
## is left).
func _spend(item: String, at: Vector2, dir: int, check_cache := {}) -> void:
	if pi.predicted == null or not Predicted.spend_fix:
		return
	var proto: ProtoDB.EntityProto = pi.world.protos.placed_entity(item)
	if proto == null:
		return
	var size := _snapped_size(proto, dir)
	at = Vector2(pi._snap(at.x, size.x), pi._snap(at.y, size.y))
	var reach: bool = pi._bridge_reach(at) if Predicted.spend_bridge_reach else pi._in_reach(at, size)
	if not reach or _cached_blocked(check_cache, proto, at, size, false) or _cached_void(check_cache, at, size):
		return
	pi.predicted.spend(item, proto, at)


static func _snapped_size(proto: ProtoDB.EntityProto, dir: int) -> Vector2i:
	var size: Vector2i = proto.tile_size
	if dir == 4 or dir == 12:
		size = Vector2i(size.y, size.x)
	return size


## Whether an underground (real or ghost) sent at `pos` will place a piece there, rather than
## being blocked, out of reach, or clicking an entity/ghost of the same prototype already at `pos`.
func _can_place_under(proto: ProtoDB.EntityProto, pos: Vector2, ghost: bool, check_cache := {}) -> bool:
	if proto == null or pi == null or pi.world == null:
		return false
	if pi.hud != null and pi.hud.ui != null and pi.hud.ui.model != null and pi.hud.ui.model.cant_build_reason(proto.id) != "":
		return false
	if _cached_void(check_cache, pos, Vector2i.ONE):
		return false
	if not ghost and not pi._bridge_reach(pos):
		return false
	if not (ghost and pi._lmb_super) and _cached_blocked(check_cache, proto, pos, Vector2i.ONE, true):
		return false
	var existing: WorldMirror.Rec = pi.world.pick(pos)
	if existing != null and existing.pos.distance_squared_to(pos) < 0.01:
		if existing.proto_id == proto.id or (existing.extra.has("gh") and int(existing.extra["gh"]) == proto.id):
			return false
	if pi.predicted != null:
		for s: WorldMirror.Rec in pi.predicted.sent_undergrounds():
			if s.proto_id == proto.id and s.pos.distance_squared_to(pos) < 0.01:
				return false
	return true


func _record_sent_under(proto: ProtoDB.EntityProto, pos: Vector2, dir: int, ghost: bool) -> void:
	var reach: int = pi._under_reach(proto)
	var sent_u: Array = pi.predicted.sent_undergrounds()
	var join := UndergroundPairs.held_join(pi.world, proto, pos, dir, reach, sent_u)
	pi.predicted.sent_underground(proto, pos, dir, join.is_empty() or bool(join["far"]), ghost)


## M2: an underground (pipe-to-ground) completing a pair over a plain run of belts (pipes): the game mines the run with
## the build, so it is hidden at once (predicted.gd clear_run), as the cursor marked it (underground_pairs.gd
## cleared); shown again if the game keeps it. Only where the client's own check says the build goes (in reach); the
## run is looked for before this build's own entity is in the world, as the cursor saw it.
func _predict_clear(item: String, at: Vector2, dir: int, check_cache := {}) -> void:
	if _ghost or pi.predicted == null or pi.hud.ui.remote or not UndergroundPairs.clear_on:
		return
	var proto: ProtoDB.EntityProto = pi.world.protos.placed_entity(item)
	if proto == null or not UndergroundPairs.is_underground(proto.type):
		return
	var size := _snapped_size(proto, dir)
	at = Vector2(pi._snap(at.x, size.x), pi._snap(at.y, size.y))
	if not pi._in_reach(at, size) or _cached_blocked(check_cache, proto, at, size, true):
		return
	var reach: int = pi._under_reach(proto)
	var sent_u: Array = pi.predicted.sent_undergrounds()
	var run := UndergroundPairs.cleared(pi.world, proto, at, dir, reach, sent_u)
	if not run.is_empty():
		pi.predicted.clear_run(run)


## Shows what was just built at once (the latency layer, FFF #83), where the client's own check
## says it can go: within reach and not in the way. The mod's answer replaces or drops it.
func _predict(item: String, at: Vector2, dir: int, look_turned := false, check_cache := {}) -> void:
	if pi.predicted == null or pi._lmb_super or pi.build_mirror or pi.hud.ui.remote:
		return
	var proto: ProtoDB.EntityProto = pi.world.protos.placed_entity(item)
	if proto == null:
		return
	var size := _snapped_size(proto, dir)
	# A click (and a line's later footprints) sends the exact cursor point, which the mod snaps to
	# the grid: drawn unsnapped, the prediction stood up to half a tile off the game's building and
	# never matched it, so both showed until it timed out.
	at = Vector2(pi._snap(at.x, size.x), pi._snap(at.y, size.y))
	if not pi._in_reach(at, size) or _cached_blocked(check_cache, proto, at, size, false) or _cached_void(check_cache, at, size):
		return
	# L2: with the spends counted, only what the hand could pay for was sent (see _send_at).
	if not Predicted.spend_fix and pi.hud.count_of(item) <= pi.predicted.pending_of(proto):
		return  # the inventory hasn't caught up: the last ones may be refused for want of items
	pi.predicted.build(proto, at, dir, look_turned)
