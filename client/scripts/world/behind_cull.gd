extends Node
## Chunks well outside what the camera sees are hidden (I18, owner: "direction based chunk culling"):
## the chunk's node, so its MultiMeshes, ground and merged far mesh leave the renderer's lists and
## the shadow passes, and are shown again as they were, nothing rebuilt, before the camera turns to
## them. Godot culls each MultiMesh by the view itself, but walks every one of them for the view and
## each shadow split; at a long view distance most of the square lies behind the camera or off its
## sides. world.gd builds the hidden chunks after the ones in view and skips their levels of detail.
##
## What stays drawn: the ground under the view's outline (the camera's frustum laid on the ground,
## out to the furthest loaded chunk) grown by MARGIN tiles, the ground whose casters can throw a
## shadow into the view (world.gd's shadow region), and KEEP_RINGS chunks round the focus; all as one
## convex outline. Each chunk row's drawn chunks are then one run, so a pass only touches the chunks
## whose row's run moved (the ends that came or went), not every chunk. The outline is worked out
## again when the camera moved more than MOVE tiles or turned more than TURN_DEGREES, or its lens or
## the window changed; the margin is wider than what those let through (at the far end it grows with
## the distance), so a chunk is shown before it can be seen. This node runs after every camera has moved for the frame
## (process_priority), so a quick turn shows the chunks the same frame.
##
## Off (everything shown) in the remote view (remote_fog.gd hides chunks there itself), while chunks
## are held (api.world.hold_chunks), while a screenshot loads its view (world.gd set_cover) and under
## full detail, in VR, and while another camera draws this world (a SubViewport with a camera: a train's
## view, the train overview's cards, an add-on's screenshot view); `--no-behind-cull` turns it off.

const ModelLods := preload("res://scripts/world/model_lods.gd")

const CHUNK := 32
const MARGIN := 64.0
const KEEP_RINGS := 2
const MOVE := 8.0
const TURN_DEGREES := 3.0
const HIDE_PER_FRAME := 8

## Off with `--no-behind-cull` (read once, here).
static var enabled := not OS.get_cmdline_user_args().has("--no-behind-cull") and not OS.get_cmdline_args().has("--no-behind-cull")
## --behind-cull-hide=all: hide every off-view chunk in one frame as before.
static var slice_hide := not OS.get_cmdline_user_args().has("--behind-cull-hide=all")

var world: Node3D
var _hidden := {}  # Vector2i -> ChunkView hidden here
var _to_hide := {}  # Vector2i -> ChunkView queued to hide a slice a frame
var _by_row := {}  # chunk row -> {chunk x: ChunkView}: the chunks world.gd made (added, removed)
var _runs := {}  # chunk row -> Vector2i(first, last) chunk x drawn under _hull (first > last: none)
var _hull := PackedVector2Array()
var _on := false
var _full := true
var _cam_at := Vector3(INF, INF, INF)
var _cam_back := Vector3.ZERO
var _cam_key: Array = []
var passes := 0  # outlines worked out (for probes)
var _views: Array = []  # WeakRefs to SubViewports added to the tree (_other_view_open)


func _init() -> void:
	process_priority = 1000
	name = "BehindCull"


## Whether world.gd's chunk `c` is hidden here (behind the camera, off its sides).
func hidden(c: Vector2i) -> bool:
	return _hidden.has(c) or _to_hide.has(c)


func hidden_count() -> int:
	return _hidden.size()


## world.gd made a chunk: hidden at once when it lies outside the outline.
func added(c: Vector2i, cv: Node3D) -> void:
	var row: Dictionary = _by_row.get(c.y, {})
	if row.is_empty():
		_by_row[c.y] = row
	row[c.x] = cv
	if not _runs.has(c.y):
		_runs[c.y] = _run(c.y)
	if _on and not _inside(c.x, _runs[c.y]):
		_hide(c, cv)


## world.gd let a chunk go (it hides and frees it itself).
func removed(c: Vector2i) -> void:
	_hidden.erase(c)
	_to_hide.erase(c)
	var row: Dictionary = _by_row.get(c.y, {})
	row.erase(c.x)
	if row.is_empty():
		_by_row.erase(c.y)
		_runs.erase(c.y)


## world.gd forgot its chunks (another surface, a new game).
func reset() -> void:
	_hidden.clear()
	_to_hide.clear()
	_by_row.clear()
	_runs.clear()
	_full = true


func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)


## SubViewports are watched as they come: one with a camera drawing this world (a train's view, the
## train overview's cards, an add-on's screenshot view) may look where the main camera doesn't.
func _on_node_added(n: Node) -> void:
	if n is SubViewport:
		_views.append(weakref(n))


## Whether another camera draws this world now: then nothing is hidden.
func _other_view_open() -> bool:
	var main_world: World3D = world.get_viewport().find_world_3d()
	for i in range(_views.size() - 1, -1, -1):
		var vp = (_views[i] as WeakRef).get_ref()
		if vp == null:
			_views.remove_at(i)
			continue
		var sub := vp as SubViewport
		if not sub.is_inside_tree() or sub.get_camera_3d() == null or sub.find_world_3d() != main_world:
			continue
		var holder := sub.get_parent()
		if holder is CanvasItem and not (holder as CanvasItem).is_visible_in_tree():
			continue
		return true
	return false


func _process(_delta: float) -> void:
	if world == null or not world.is_inside_tree():
		return
	var cam := world.get_viewport().get_camera_3d()
	var active: bool = enabled and cam != null and not world.remote_view and not world.hold and not world.has_cover() \
		and not ModelLods.full_detail and not world.get_viewport().use_xr and not _other_view_open()
	if not active:
		if _on:
			_on = false
			_show_all()
		return
	if not _on:
		_on = true
		_full = true
	var at := cam.global_position
	var back := cam.global_transform.basis.z
	var key := [cam.projection, cam.fov, cam.size, cam.near, cam.far, world.get_viewport().get_visible_rect().size,
		world.chunk_of(world.focus()), world.view_radius]
	if not _full and key == _cam_key and at.distance_to(_cam_at) < MOVE and back.dot(_cam_back) > cos(deg_to_rad(TURN_DEGREES)):
		_drain_hide()
		return
	_cam_key = key
	_cam_at = at
	_cam_back = back
	_hull = _outline(cam)
	passes += 1
	for y: int in _by_row.keys():
		var run := _run(y)
		var row: Dictionary = _by_row[y]
		if _full or not _runs.has(y):
			for x: int in row:
				_set_drawn(Vector2i(x, y), row[x], _inside(x, run))
		else:
			var was: Vector2i = _runs[y]
			if was != run:
				_settle(y, row, was, run)
		_runs[y] = run
	_full = false
	_drain_hide()


## The view's outline on the ground (x, z in tiles; a closed convex polygon, Geometry2D's).
func _outline(cam: Camera3D) -> PackedVector2Array:
	var size := cam.get_viewport().get_visible_rect().size
	var focus: Vector2 = world.focus()
	var reach: float = (int(world.loaded_reach()) + 1) * CHUNK * 1.5
	var far := minf(cam.far, reach + cam.global_position.distance_to(Vector3(focus.x, 0.0, focus.y)) + 64.0)
	var near := cam.near
	var points := PackedVector2Array()
	# The far end moves furthest between two outlines (TURN_DEGREES at `far`): its margin grows with it.
	var far_margin := maxf(MARGIN, far * sin(deg_to_rad(TURN_DEGREES)) * 1.5 + MOVE)
	for corner in [Vector2.ZERO, Vector2(size.x, 0.0), Vector2(0.0, size.y), size]:
		for depth in [near, far]:
			var p := cam.project_position(corner, depth)
			var m: float = MARGIN if depth == near else far_margin
			for d in [Vector2(-m, -m), Vector2(m, -m), Vector2(-m, m), Vector2(m, m)]:
				points.append(Vector2(p.x, p.z) + d)
	var keep := (KEEP_RINGS + 1) * CHUNK
	var focus_chunk: Vector2i = world.chunk_of(focus)
	var fc := Vector2(focus_chunk) * CHUNK + Vector2(CHUNK, CHUNK) * 0.5
	for d in [Vector2(-keep, -keep), Vector2(keep, -keep), Vector2(-keep, keep), Vector2(keep, keep)]:
		points.append(fc + d)
	points.append_array(world.shadow_outline())
	return Geometry2D.convex_hull(points)


## The chunk x run of row `y` inside _hull: Vector2i(first, last), first > last when none.
func _run(y: int) -> Vector2i:
	if _hull.size() < 4:
		return Vector2i(-0x3fffffff, 0x3fffffff)  # no outline yet: everything drawn
	var y0 := float(y * CHUNK)
	var y1 := y0 + CHUNK
	var lo := INF
	var hi := -INF
	for i in _hull.size() - 1:
		var a := _hull[i]
		var b := _hull[i + 1]
		if maxf(a.y, b.y) < y0 or minf(a.y, b.y) > y1:
			continue
		var xa := a.x
		var xb := b.x
		if a.y != b.y:
			xa = lerpf(a.x, b.x, clampf((y0 - a.y) / (b.y - a.y), 0.0, 1.0))
			xb = lerpf(a.x, b.x, clampf((y1 - a.y) / (b.y - a.y), 0.0, 1.0))
		lo = minf(lo, minf(xa, xb))
		hi = maxf(hi, maxf(xa, xb))
	if lo > hi:
		return Vector2i(1, 0)
	# Chunk x meets [lo, hi] when x * 32 <= hi and x * 32 + 32 >= lo.
	return Vector2i(ceili(lo / CHUNK) - 1, floori(hi / CHUNK))


static func _inside(x: int, run: Vector2i) -> bool:
	return x >= run.x and x <= run.y


## A row's run moved from `was` to `now`: only the chunks between the old and new ends change.
func _settle(y: int, row: Dictionary, was: Vector2i, now: Vector2i) -> void:
	var lo := mini(was.x, now.x)
	var hi := maxi(was.y, now.y)
	if was.x > was.y:
		lo = now.x
		hi = now.y
	elif now.x > now.y:
		lo = was.x
		hi = was.y
	# Fewer chunks in the row than cells to look at (a run out to the horizon): the row's chunks.
	if hi - lo + 1 > row.size() * 2:
		for x: int in row:
			if _inside(x, was) != _inside(x, now):
				_set_drawn(Vector2i(x, y), row[x], _inside(x, now))
		return
	for x in range(lo, hi + 1):
		if _inside(x, was) != _inside(x, now) and row.has(x):
			_set_drawn(Vector2i(x, y), row[x], _inside(x, now))


func _set_drawn(c: Vector2i, cv: Node3D, drawn: bool) -> void:
	if not is_instance_valid(cv):
		return
	if drawn:
		_to_hide.erase(c)
		if _hidden.has(c):
			_hidden.erase(c)
			cv.visible = true
			_shown(c)
	elif not _hidden.has(c) and cv.visible:
		if slice_hide:
			_to_hide[c] = cv
		else:
			_hide(c, cv)


func _drain_hide() -> void:
	if _to_hide.is_empty():
		return
	var n := 0
	for c: Vector2i in _to_hide.keys():
		var cv: Node3D = _to_hide[c]
		_to_hide.erase(c)
		if is_instance_valid(cv):
			_hide(c, cv)
			n += 1
			if slice_hide and n >= HIDE_PER_FRAME:
				break


func _hide(c: Vector2i, cv: Node3D) -> void:
	if not cv.visible:
		return  # hidden by someone else (being freed): not ours to show again
	cv.visible = false
	_hidden[c] = cv


func _show_all() -> void:
	_to_hide.clear()
	for c: Vector2i in _hidden:
		var cv = _hidden[c]
		if is_instance_valid(cv):
			cv.visible = true
			_shown(c)
	_hidden.clear()
	_runs.clear()


## A chunk shown again: world.gd picks its levels of detail (kept while hidden) without a fade.
func _shown(c: Vector2i) -> void:
	if world.has_method("chunk_shown"):
		world.chunk_shown(c)
