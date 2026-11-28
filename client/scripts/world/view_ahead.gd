extends RefCounted
## Levels of detail ready when the camera cuts (`--cut-lods=old` for the behaviour before).
##
## The systems that pick a level by the distance to the camera switch under a per-frame budget, with a
## cross-fade or with hysteresis (models' levels: world.gd's bands, LOD_SWITCH_CAP and the `lods` budget;
## far merges: far_chunks.gd's decide pass, a slice a frame every CHECK_INTERVAL; the cliff wall's levels
## follow the far merges). After a hard cut to a place tens or hundreds of tiles away they were still set
## for the old place and caught up over the next frames: the first frame of a shot drew far stand-ins up
## close. Two ways out, both here:
##
## - A viewpoint announced ahead (api.world.prepare_view, a shot knows its cuts): until it is released or
##   runs out, those systems measure every chunk to the nearer of the camera and each announced point,
##   so the place the camera will cut to is at its levels (made under the usual budgets, no hitch) before
##   the camera gets there. The old place stays at its levels too, as long as the camera is there.
## - A cut seen (the camera moved more than JUMP_TILES in one frame) or announced (api.world.mark_cut):
##   that frame's levels are picked without the budgets and without cross-fades (one slower frame, hidden
##   by the cut itself), so the first frame drawn is right whatever was announced.

const Switches := preload("res://scripts/switches.gd")

## Off with `--cut-lods=old`: no announced viewpoints, no settle at a cut (the API calls are taken and ignored).
static var on := not Switches.has("--cut-lods=old")
## The camera moving further than this in one frame is a cut (tiles).
const JUMP_TILES := 32.0
## An announced viewpoint moving less than this keeps its generation (systems don't look again for it).
const MOVE_AGAIN := 8.0
## The most seconds a viewpoint is kept without being announced again.
const MAX_SECONDS := 30.0

## key -> [position: Vector3, look: Vector3, until_msec: int]
static var _points := {}
## Changes whenever the announced viewpoints do (added, moved by MOVE_AGAIN, released or run out).
static var generation := 0
static var _cut_asked := false
static var _frame := -1
static var _cut := false
static var _last_cam := Vector3.INF
## Cuts seen (tests, probes), and the process frame of the last one (systems run before world.gd in a frame
## see it the frame after).
static var cuts := 0
## This frame's cut_now() saw a cut, whether or not `on` (`--cut-shots`: the old behaviour's pictures too).
static var seen := false
static var last_cut_frame := -10


## Announces a viewpoint the camera will cut to: `pos` the camera, `look` what it looks at (tiles,
## Godot's axes), kept `seconds` (at most MAX_SECONDS) unless announced again or released first.
static func prepare(key: String, pos: Vector3, look: Vector3, seconds: float) -> void:
	if not on:
		return
	var until := Time.get_ticks_msec() + int(clampf(seconds, 0.0, MAX_SECONDS) * 1000.0)
	var was: Variant = _points.get(key)
	if was == null or (was[0] as Vector3).distance_to(pos) > MOVE_AGAIN or (was[1] as Vector3).distance_to(look) > MOVE_AGAIN:
		_points[key] = [pos, look, until]
		generation += 1
	else:
		was[2] = until


## Lets an announced viewpoint go (or every one, key "").
static func release(key: String) -> void:
	if key == "":
		if not _points.is_empty():
			_points.clear()
			generation += 1
		return
	if _points.erase(key):
		generation += 1


## The next frame is a cut, whether or not the camera moves far.
static func mark_cut() -> void:
	_cut_asked = true


static func active() -> bool:
	_expire()
	return on and not _points.is_empty()


## The announced cameras' places (none while off).
static func points() -> Array[Vector3]:
	var out: Array[Vector3] = []
	if not active():
		return out
	for k in _points:
		out.append(_points[k][0])
	return out


## The announced look points on the ground (x, z).
static func looks() -> Array[Vector2]:
	var out: Array[Vector2] = []
	if not active():
		return out
	for k in _points:
		var l: Vector3 = _points[k][1]
		out.append(Vector2(l.x, l.z))
	return out


static func _expire() -> void:
	if _points.is_empty():
		return
	var now := Time.get_ticks_msec()
	for k in _points.keys():
		if int(_points[k][2]) < now:
			_points.erase(k)
			generation += 1


## Whether this frame is a cut: the camera jumped since the last frame, or one was announced. Worked out
## once a frame (the first caller's camera), so every system asking this frame gets the same answer.
static func cut_now(camera_pos: Vector3) -> bool:
	var f := Engine.get_process_frames()
	if f == _frame:
		return _cut
	_frame = f
	var jumped := _last_cam != Vector3.INF and camera_pos != Vector3.INF and camera_pos.distance_to(_last_cam) > JUMP_TILES
	_last_cam = camera_pos
	seen = jumped or _cut_asked
	_cut = on and seen
	_cut_asked = false
	if _cut:
		cuts += 1
		last_cut_frame = f
	return _cut


## Whether a cut was seen this frame or the one before (for systems that run before world.gd's look).
static func cut_recent() -> bool:
	return Engine.get_process_frames() - last_cut_frame <= 1


## Of `at` and the announced cameras, the one nearest the box [lo, hi] (Godot's axes).
static func nearest(at: Vector3, lo: Vector3, hi: Vector3) -> Vector3:
	if _points.is_empty() or not on:
		return at
	var best := at
	var best_d := at.distance_squared_to(at.clamp(lo, hi))
	for p: Vector3 in points():
		var d := p.distance_squared_to(p.clamp(lo, hi))
		if d < best_d:
			best_d = d
			best = p
	return best


## Back as at start (a game ended, tests).
static func reset() -> void:
	_points.clear()
	generation += 1
	_cut_asked = false
	_cut = false
	_frame = -1
	_last_cam = Vector3.INF
