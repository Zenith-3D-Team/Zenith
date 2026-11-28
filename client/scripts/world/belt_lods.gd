extends RefCounted
## Belts far away drawn as stand-ins of a handful of triangles (docs/PERFORMANCE-AUDIT.md 4.1).
## Every belt tier, curve and underground end is Wube's printable belt, about 1,450 triangles a
## tile: at a busy base two thirds of the GPU's work, nearly all of it in triangles smaller than a
## pixel once the camera is pulled back. Where a tile is drawn smaller than FLAT_BELOW pixels at a
## chunk's nearest belt (from the camera's distance, field of view or orthographic size and the
## window's height up to MAX_LINES, so zooming, the field of view and the F6 view all count), the chunk's belts,
## undergrounds and splitters are drawn with their stand-ins instead, and in full again above
## FULL_ABOVE (the gap keeps a chunk at the edge from swapping back and forth).
##
## A stand-in is the model's top as flat cells on a few grid lines per kind (a straight belt: its
## two rails and its bed; a curve: those in arcs; an underground end: its hood in steps and the open
## bed; a splitter: a coarse grid), with walls down to whatever is lower beside them. Each cell
## takes the model's own surface (material) found on top there and its corners the model's own
## vertex data nearest them (part colours, occlusion, worn edges, the sprite's visibility), so the
## same materials draw it: the belt surface's slats and the tier's chevron scroll in the shader as
## on the full model, tiers keep their paint. The bed's top is the full model's (items on belts and
## far lane icons sit on it as before). Stand-ins cast no shadow; the full model's shadow stand-in
## (model_lods.gd) is hidden with it. They are made once per model on a worker thread; until then
## the full model is drawn.

const ModelLods := preload("res://scripts/world/model_lods.gd")
const MaterialRows := preload("res://scripts/world/material_rows.gd")
const FrameBudget := preload("res://scripts/world/frame_budget.gd")
const ViewPriority := preload("res://scripts/world/view_priority.gd")
const Switches := preload("res://scripts/switches.gd")

## Pixels a tile is drawn at, at a chunk's nearest belt, below which its belts go flat, and above
## which they are drawn in full again. The default camera draws its farthest ground at about 28 px a
## tile in a 1080-pixel window, so belts stay whole there; at 20 px the belt's rails are a pixel wide
## and its rollers half one.
const FLAT_BELOW := 20.0
const FULL_ABOVE := 24.0
## Mid-detail 3D belt LOD thresholds (pixels per tile at a chunk's nearest belt, scaled by lod_scale).
const MID_BELOW := 44.0
const MID_FULL_ABOVE := 52.0
const LOD_QUALITY_SCALE := {"low": 1.9, "medium": 1.0, "high": 0.85, "ultra": 0.70}
static var lod_scale := 1.0
## The tallest picture these thresholds count, in lines: a taller one is measured as if this tall,
## so 4K draws as many belt triangles as 1080p. Measured in real pixels, belts at 4K only went flat
## 171 tiles out, past the furthest default zoom, and stayed at 1,450 triangles a tile however far
## the camera went (docs/SHADER-PERFORMANCE-PLAN.md S4).
const MAX_LINES := 1080.0
## Entity types drawn with stand-ins far away.
const TYPES := {"transport-belt": true, "underground-belt": true, "linked-belt": true, "splitter": true, "lane-splitter": true}
## The keys of stand-in MultiMeshes in chunk_view.gd (_nodes[[model, MID / FLAT]]).
const MID := &"mid"
const FLAT := &"flat"
## Chunk belt LOD tiers (chunk_view.gd belt_lod).
const TIER_FULL := 0
const TIER_MID := 1
const TIER_FLAT := 2
## Jobs at once on worker threads.
const JOBS := 2
## Seconds between looks when the camera hasn't moved.
const CHECK_INTERVAL := 0.25
## Minimum deadband quantization step in tiles when `move_deadband` is active.
const DEADBAND_TILES := 4.0
## Minimum tracked belt chunks before time-slicing kicks in under FrameBudget.
const SLICE_MIN_CHUNKS := 64

## --no-belt-stand-ins: full belts everywhere (for comparing).
static var enabled := not (Switches.has("--no-belt-stand-ins"))
## --belt-mid-lod=off: disable 3D mid-detail belt LOD and restore 2-tier Full/Flat behavior.
static var mid_enabled := Switches.on("--belt-mid-lod")
## --belt-lods-every-frame: re-check belt stand-ins on every transform change instead of quantizing position.
static var move_deadband := not (Switches.has("--belt-lods-every-frame"))
## --belt-lods-slice=off: check every tracked belt chunk in a single frame instead of time-slicing.
static var slice_enabled := Switches.on("--belt-lods-slice")
## Mesh -> its stand-in (ArrayMesh, empty until its job is done), or null: none (not a mesh it can make).
static var _stand_ins := {}
static var _mid_stand_ins := {}
static var _ready := {}  # stand-in -> true once it has its shape
static var _queue: Array = []  # [Job, stand-in, source mesh]
static var _running: Array = []  # [task id, Job, stand-in, source mesh]
## Chunks with belts (chunk_view.gd track/untrack): ChunkView -> true.
static var _chunks := {}
static var _dirty := false
static var _timer := 0.0
static var _last_view := []
static var _pass_todo: Array = []
static var _pass_next := 0
static var _pass_by_cam := true
static var _pass_at := Vector3.ZERO
static var _pass_cam: Camera3D
static var _pass_pixels := 0.0
static var _pass_ortho := false
static var _pass_ref_focal := 0.0
static var _pass_zoom_px := INF


## The plan a stand-in is made on: "s" straight, "l"/"r" curves, "u" underground ends, "x" splitters.
static func kind_of(proto_type: String, extra: Dictionary) -> String:
	match proto_type:
		"transport-belt":
			return str(extra.get("s", "s"))
		"underground-belt", "linked-belt":
			return "u"
	return "x"


## The stand-in for `mesh`, or null while it is being made (coming()) or when there is none.
static func stand_in(mesh: Mesh, kind: String) -> ArrayMesh:
	if not enabled or mesh == null:
		return null
	return _get_or_queue(mesh, kind, FLAT, _stand_ins)


## The 3D mid-detail stand-in for `mesh`, or null while it is being made (coming_mid()) or disabled.
static func mid_stand_in(mesh: Mesh, kind: String) -> ArrayMesh:
	if not enabled or not mid_enabled or mesh == null:
		return null
	return _get_or_queue(mesh, kind, MID, _mid_stand_ins)


static func _get_or_queue(mesh: Mesh, kind: String, detail: StringName, cache: Dictionary) -> ArrayMesh:
	if cache.has(mesh):
		var out: ArrayMesh = cache[mesh]
		if out == null or not _ready.has(out):
			return null
		_same_materials(out, mesh as ArrayMesh)
		return out
	var job := _job_for(mesh as ArrayMesh, kind, detail)
	var out: ArrayMesh = null
	if job != null:
		out = ArrayMesh.new()
		_queue.append([job, out, mesh])
	cache[mesh] = out
	return null


## Whether a stand-in for `mesh` is still to come (asked, not made yet).
static func coming(mesh: Mesh) -> bool:
	var out: ArrayMesh = _stand_ins.get(mesh)
	if out != null and not _ready.has(out):
		return true
	return coming_mid(mesh)


## Whether a mid-detail stand-in for `mesh` is still to come (asked, not made yet).
static func coming_mid(mesh: Mesh) -> bool:
	if not mid_enabled:
		return false
	var out: ArrayMesh = _mid_stand_ins.get(mesh)
	return out != null and not _ready.has(out)


## A model's materials may be swapped after its stand-in was made (material_rows.gd edits): the
## stand-in follows.
static func _same_materials(out: ArrayMesh, mesh: ArrayMesh) -> void:
	var from: PackedInt32Array = out.get_meta(&"f3d_from", PackedInt32Array())
	for i in out.get_surface_count():
		if i < from.size() and from[i] < mesh.get_surface_count():
			var m := mesh.surface_get_material(from[i])
			if out.surface_get_material(i) != m:
				out.surface_set_material(i, m)


static func track(cv) -> void:
	if not _chunks.has(cv):
		_chunks[cv] = true
		_dirty = true


static func untrack(cv) -> void:
	_chunks.erase(cv)


static func apply_lod_quality(quality: String, custom_distance := 0.0) -> void:
	var want: float
	if custom_distance > 0.0:
		want = clampf(ModelLods.LOD_DIST_REF / custom_distance, 0.4, 3.2)
	elif ModelLods.old_low_lod and quality.to_lower() == "low":
		want = 1.0
	else:
		want = float(LOD_QUALITY_SCALE.get(quality.to_lower(), 1.0))
	if not is_equal_approx(lod_scale, want):
		lod_scale = want
		_dirty = true


## Each frame (far_chunks.gd): finishes stand-ins made on workers, and sets each chunk with belts
## flat or full by how big a tile is drawn at its nearest belt.
static func update(world, cam: Camera3D, delta: float) -> void:
	_poll(world)
	_timer += delta
	var by_cam: bool = true if world == null or world.get("lod_by_camera") == null else bool(world.get("lod_by_camera"))
	if by_cam and cam == null:
		return
	var vp := cam.get_viewport() if cam != null and cam.is_inside_tree() else null
	# Real pixels: a window's visible rect is in the interface's units, which the UI scale divides.
	var size := Vector2(1920, 1080)
	if vp != null:
		size = Vector2((vp as Window).size) if vp is Window else vp.get_visible_rect().size
	elif world != null and world.is_inside_tree():
		size = world.get_viewport().get_visible_rect().size
	var scale := 1.0
	if vp != null and vp.scaling_3d_mode != Viewport.SCALING_3D_MODE_FSR2:
		scale = vp.scaling_3d_scale
	var at := Vector3.ZERO
	var view: Array
	var zoom_q := 0.0
	if not by_cam:
		var f: Vector2 = world.focus() if world != null and world.has_method("focus") else Vector2.ZERO
		at = Vector3(f.x, 0.0, f.y)
		if ViewPriority.char_lod_zoom and cam != null:
			var cam_d := ViewPriority.camera_zoom_distance(cam, f)
			if cam_d >= 48.0:
				zoom_q = floorf(cam_d / 8.0) * 8.0
		view = [(at / DEADBAND_TILES).round(), size, scale, enabled, mid_enabled, false, lod_scale, ViewPriority.char_lod_zoom, zoom_q]
		if zoom_q > 0.0 and cam != null:
			view.append_array([cam.projection, roundi(cam.fov * 10.0), roundi(cam.size * 10.0)])
	elif move_deadband:
		at = cam.global_position
		var step := clampf(floorf(at.y * 0.08 / 2.0) * 2.0, DEADBAND_TILES, 12.0)
		view = [(at / step).round(), step, cam.projection, roundi(cam.fov * 10.0), roundi(cam.size * 10.0),
			cam.keep_aspect, size, scale, enabled, mid_enabled, true, lod_scale]
	else:
		at = cam.global_position
		view = [cam.global_transform, cam.projection, cam.fov, cam.size, size, scale, enabled, mid_enabled, true, lod_scale]
	var slicing := _pass_next < _pass_todo.size()
	if not slicing and not _dirty and _timer < CHECK_INTERVAL and view == _last_view:
		return
	if _dirty or view != _last_view or (not slicing and _timer >= CHECK_INTERVAL):
		_timer = 0.0
		_dirty = false
		_last_view = view
		_pass_todo = _chunks.keys()
		_pass_next = 0
		_pass_by_cam = by_cam
		_pass_at = at
		_pass_cam = cam
		var keep_w := cam != null and cam.keep_aspect == Camera3D.KEEP_WIDTH
		_pass_pixels = view_pixels(size, scale, keep_w)
		_pass_ortho = by_cam and cam.projection == Camera3D.PROJECTION_ORTHOGONAL
		_pass_ref_focal = _pass_pixels / maxf(2.0 * tan(deg_to_rad(35.0 * 0.5)), 0.001)
		if not ViewPriority.char_lod_zoom or cam == null or zoom_q <= 0.0:
			_pass_zoom_px = INF
		elif cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
			_pass_zoom_px = _pass_pixels / maxf(cam.size, 0.01)
		else:
			_pass_zoom_px = (_pass_pixels / maxf(2.0 * tan(deg_to_rad(clampf(cam.fov, 5.0, 170.0) * 0.5)), 0.001)) / maxf(zoom_q, 0.01)
	if _pass_next >= _pass_todo.size():
		_pass_todo = []
		_pass_next = 0
		_pass_cam = null
		FrameBudget.waiting(&"belt_lods", 0)
		return
	var use_slice := slice_enabled and not ModelLods.full_detail and _pass_todo.size() >= SLICE_MIN_CHUNKS
	var allow := 0x3fffffff
	if use_slice:
		allow = FrameBudget.grant(&"belt_lods")
		if FrameBudget.shared and allow <= 0:
			FrameBudget.waiting(&"belt_lods", _pass_todo.size() - _pass_next)
			return
	var t0 := Time.get_ticks_usec()
	var did := 0
	while _pass_next < _pass_todo.size():
		if use_slice and did > 0 and (did & 15) == 0 and Time.get_ticks_usec() - t0 >= allow:
			break
		var cv = _pass_todo[_pass_next]
		_pass_next += 1
		if not is_instance_valid(cv):
			_chunks.erase(cv)
			continue
		var px: float
		if not _pass_by_cam:
			var d := _pass_at.distance_to(_pass_at.clamp(cv.belt_bounds.position, cv.belt_bounds.end))
			px = minf(_pass_ref_focal / maxf(d, 0.01), _pass_zoom_px)
		else:
			if not is_instance_valid(_pass_cam):
				break
			px = tile_pixels(_pass_cam, _pass_at, _pass_pixels, cv.belt_bounds)
		cv.set_belt_lod(lod_at(px, cv.belt_lod, _pass_ortho) if enabled else TIER_FULL)
		did += 1
	if _pass_next >= _pass_todo.size():
		_pass_todo = []
		_pass_next = 0
		_pass_cam = null
	var rem := maxi(_pass_todo.size() - _pass_next, 0)
	if use_slice or did > 0:
		FrameBudget.spent(&"belt_lods", Time.get_ticks_usec() - t0, rem)


## The window's height (or width, for a camera keeping its width) as tile_pixels() counts it: the
## lines the world is really rendered at (`size` times the 3D scale, which Render scale and full
## screen's Resolution set), no more than MAX_LINES. The limit is on what is rendered, so 4K drawn at
## half scale is a 1080-line picture, not a 540-line one.
static func view_pixels(size: Vector2, scale: float, keep_width := false) -> float:
	var fit := minf(1.0, MAX_LINES / maxf(size.y * scale, 1.0))
	return (size.x if keep_width else size.y) * scale * fit


## Whether belts drawn at `px` pixels a tile go flat, from `was_flat`. An orthographic view has no
## gap: a tile is the same size wherever the camera is, so only zooming can cross the line, and
## Factorio's view (F6), which shows more ground in a bigger window, comes to 21.5 at 4K: with the
## gap belts flat when it was snapped to would stay flat there.
static func flat_at(px: float, was_flat: bool, orthographic: bool, scale := -1.0) -> bool:
	var s := lod_scale if scale <= 0.0 else clampf(scale, 0.4, 3.2)
	var fb := FLAT_BELOW * s
	var fa := FULL_ABOVE * s
	if px > (fb if orthographic else fa):
		return false
	return px < fb or was_flat


## Which belt LOD tier (0=full, 1=mid, 2=flat) to draw at `px` pixels a tile, from `was_tier`.
## Orthographic views use no hysteresis gap (matching flat_at). When `mid_enabled` is false,
## collapses to 2-tier Full/Flat via flat_at().
static func lod_at(px: float, was_tier: int, orthographic: bool, scale := -1.0) -> int:
	if not mid_enabled:
		return TIER_FLAT if flat_at(px, was_tier == TIER_FLAT, orthographic, scale) else TIER_FULL
	var s := lod_scale if scale <= 0.0 else clampf(scale, 0.4, 3.2)
	var fb := FLAT_BELOW * s
	var fa := FULL_ABOVE * s
	var mb := MID_BELOW * s
	var mfa := MID_FULL_ABOVE * s
	if orthographic:
		if px < fb:
			return TIER_FLAT
		if px < mb:
			return TIER_MID
		return TIER_FULL
	if px < fb:
		return TIER_FLAT
	if px > mfa:
		return TIER_FULL
	if was_tier == TIER_FLAT:
		return TIER_MID if px > fa else TIER_FLAT
	if was_tier == TIER_MID:
		return TIER_MID
	return TIER_MID if px < mb else TIER_FULL


## How many pixels tall one tile is drawn at the nearest point of `box`, for `pixels` from
## view_pixels().
static func tile_pixels(cam: Camera3D, at: Vector3, pixels: float, box: AABB) -> float:
	if cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		return pixels / maxf(cam.size, 0.001)
	var d := at.distance_to(at.clamp(box.position, box.end))
	return pixels / (2.0 * tan(deg_to_rad(cam.fov) * 0.5) * maxf(d, 0.01))


static func _poll(world) -> void:
	var done := false
	for i in range(_running.size() - 1, -1, -1):
		var entry: Array = _running[i]
		if not WorkerThreadPool.is_task_completed(entry[0]):
			continue
		WorkerThreadPool.wait_for_task_completion(entry[0])
		_running.remove_at(i)
		_commit(entry[1], entry[2], entry[3])
		done = true
	while _running.size() < JOBS and not _queue.is_empty():
		var next: Array = _queue.pop_front()
		_running.append([WorkerThreadPool.add_task((next[0] as Job).run, false, "belt stand-in"), next[0], next[1], next[2]])
	if not done:
		return
	if world == null:
		return
	for cv in _chunks.keys():
		if is_instance_valid(cv) and cv.belt_waiting:
			if world.has_method("redraw_view"):
				world.redraw_view(cv.coord)  # the stand-ins are read after the records' pass (chunk_view.gd)
			else:
				world.redraw(cv.coord)


## Quitting or leaving a game (main.gd _exit_tree): waits for the stand-ins being made on workers and puts them in
## (a task still running when Godot stops its renderer can wait for it for ever); the queue, not started, stays.
static func wait_running() -> void:
	for entry in _running:
		if int(entry[0]) >= 0:
			WorkerThreadPool.wait_for_task_completion(entry[0])
	for entry in _running:
		_commit(entry[1], entry[2], entry[3])
	_running.clear()


## Makes every stand-in asked for now, waiting for the workers (tests).
static func finish_all() -> void:
	while not _queue.is_empty() or not _running.is_empty():
		for entry in _running:
			WorkerThreadPool.wait_for_task_completion(entry[0])
			entry[0] = -1
		for entry in _running:
			_commit(entry[1], entry[2], entry[3])
		_running.clear()
		while _running.size() < JOBS and not _queue.is_empty():
			var next: Array = _queue.pop_front()
			_running.append([WorkerThreadPool.add_task((next[0] as Job).run, false, "belt stand-in"), next[0], next[1], next[2]])


static func _commit(job: Job, out: ArrayMesh, mesh: ArrayMesh) -> void:
	var from := PackedInt32Array()
	for s in job.out.size():
		var arrays: Array = job.out[s]
		if arrays.is_empty():
			continue
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, job.formats[s])
		out.surface_set_material(out.get_surface_count() - 1, mesh.surface_get_material(s))
		from.append(s)
	out.set_meta(&"f3d_from", from)
	out.resource_name = mesh.resource_name + (" (mid)" if job.detail == MID else " (far)")
	_ready[out] = true


## The job for a model, made from its arrays on the CPU (null: none kept, or bones).
## A modeller's textured belt gets none: a cell's corners copying the nearest vertex's UV smeared its
## texture over the steps, and its own models (a few hundred triangles a tile, not Wube's 1,450)
## have their own textured levels (model_lods.gd), which keep UV seams.
static func _job_for(mesh: ArrayMesh, kind: String, detail := FLAT) -> Job:
	if mesh == null or not mesh.has_meta(ModelLods.ARRAYS_META) or ModelLods.textured(mesh):
		return null
	var job := Job.new()
	job.kind = kind
	job.detail = detail
	job.box = mesh.get_aabb()
	for i in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(i) != Mesh.PRIMITIVE_TRIANGLES:
			return null
		var arrays := ModelLods.arrays_of(mesh, i)
		if arrays[Mesh.ARRAY_BONES] != null:
			return null
		job.surfaces.append(arrays)
		job.formats.append(mesh.surface_get_format(i) & ModelLods.CUSTOM_FORMATS)
		# Which of its materials (or rows of one merged material) are the moving belt surface.
		var material := mesh.surface_get_material(i)
		var belt := []
		var rows := MaterialRows.rows(material)
		for m in (rows if not rows.is_empty() else [material]):
			belt.append(m != null and str(m.resource_name).to_lower().contains("belt_surface"))
		job.belt_rows.append(belt)
	return job


## Builds one stand-in on a worker thread.
class Job:
	var kind := "s"
	var detail := FLAT
	var box := AABB()
	## Per source surface: its arrays, its custom formats, which of its rows are belt surface.
	var surfaces: Array = []
	var formats: Array = []
	var belt_rows: Array = []
	## Per source surface: the stand-in's arrays ([] when nothing of it is on top).
	var out: Array = []

	## The model's triangles in a coarse grid over the ground, to find what is on top quickly.
	const BUCKETS := 12
	var _tris: Array = []  # [a, b, c, surface, row, uva, uvb, uvc] (uvs null when none)
	var _buckets: Array = []
	var _corner_cache := {}  # [ci, cj, s, row] -> [height, uv_or_null]

	func run() -> void:
		_index()
		if detail == MID:
			_run_mid()
		else:
			_run_flat()
		surfaces = []
		_tris = []
		_buckets = []
		_corner_cache = {}

	func _run_flat() -> void:
		var grid := _grid()
		var corners: Array = grid[0]
		var nx := corners.size() - 1
		var nz: int = (corners[0] as Array).size() - 1
		var walls_along: bool = grid[1]
		# Each cell: [height, surface, row] or null (nothing there).
		var cells := _sample_grid(corners, nx, nz)
		var builders := _make_builders()
		for i in nx:
			for j in nz:
				var cell = cells[i][j]
				if cell == null:
					continue
				var h: float = cell[0]
				var b: Builder = builders[cell[1]]
				var p00: Vector2 = corners[i][j]
				var p10: Vector2 = corners[i + 1][j]
				var p11: Vector2 = corners[i + 1][j + 1]
				var p01: Vector2 = corners[i][j + 1]
				b.quad([_v3(p00, h), _v3(p10, h), _v3(p11, h), _v3(p01, h)], Vector3.UP, cell[2])
				# Walls where what is beside it is lower: across always, along only where asked
				# (a belt's ends meet the next belt's).
				var mid := (p00 + p10 + p11 + p01) * 0.25
				_wall(b, cell, p00, p01, mid, cells, i - 1, j)
				_wall(b, cell, p10, p11, mid, cells, i + 1, j)
				if walls_along or j > 0:
					_wall(b, cell, p00, p10, mid, cells, i, j - 1)
				if walls_along or j < nz - 1:
					_wall(b, cell, p01, p11, mid, cells, i, j + 1)
		_finish_builders(builders)

	func _run_mid() -> void:
		var grid := _mid_grid()
		var corners: Array = grid[0]
		var nx := corners.size() - 1
		var nz: int = (corners[0] as Array).size() - 1
		var walls_along: bool = grid[1]
		var cells := _sample_grid(corners, nx, nz)
		var builders := _make_builders()
		for i in nx:
			for j in nz:
				var cell = cells[i][j]
				if cell == null:
					continue
				var s: int = cell[1]
				var row: int = cell[2]
				var fallback: float = cell[0]
				var b: Builder = builders[s]
				var p00: Vector2 = corners[i][j]
				var p10: Vector2 = corners[i + 1][j]
				var p11: Vector2 = corners[i + 1][j + 1]
				var p01: Vector2 = corners[i][j + 1]
				var c00 := _corner_sample(i, j, s, row, p00, fallback, cells)
				var c10 := _corner_sample(i + 1, j, s, row, p10, fallback, cells)
				var c11 := _corner_sample(i + 1, j + 1, s, row, p11, fallback, cells)
				var c01 := _corner_sample(i, j + 1, s, row, p01, fallback, cells)
				var v00 := _v3(p00, c00[0])
				var v10 := _v3(p10, c10[0])
				var v11 := _v3(p11, c11[0])
				var v01 := _v3(p01, c01[0])
				var n := (v10 - v00).cross(v01 - v00).normalized()
				if n.length_squared() < 0.5:
					n = Vector3.UP
				elif n.y < 0.0:
					n = -n
				b.quad([v00, v10, v11, v01], n, row, [c00[1], c10[1], c11[1], c01[1]])
				var mid := (p00 + p10 + p11 + p01) * 0.25
				_wall_mid(b, cell, p00, p01, mid, c00[0], c01[0], i, j, i, j + 1, cells, i - 1, j)
				_wall_mid(b, cell, p10, p11, mid, c10[0], c11[0], i + 1, j, i + 1, j + 1, cells, i + 1, j)
				if walls_along or j > 0:
					_wall_mid(b, cell, p00, p10, mid, c00[0], c10[0], i, j, i + 1, j, cells, i, j - 1)
				if walls_along or j < nz - 1:
					_wall_mid(b, cell, p01, p11, mid, c01[0], c11[0], i, j + 1, i + 1, j + 1, cells, i, j + 1)
		_finish_builders(builders)

	func _sample_grid(corners: Array, nx: int, nz: int) -> Array:
		var cells: Array = []
		for i in nx:
			var col: Array = []
			for j in nz:
				col.append(_sample_cell(corners[i][j], corners[i + 1][j], corners[i + 1][j + 1], corners[i][j + 1]))
			cells.append(col)
		return cells

	func _make_builders() -> Array:
		var builders: Array = []
		for s in surfaces.size():
			builders.append(Builder.new(surfaces[s]))
		return builders

	func _finish_builders(builders: Array) -> void:
		for s in surfaces.size():
			out.append((builders[s] as Builder).arrays())

	func _wall(b: Builder, cell: Array, e0: Vector2, e1: Vector2, mid: Vector2, cells: Array, ni: int, nj: int) -> void:
		var low := 0.0
		if ni >= 0 and ni < cells.size() and nj >= 0 and nj < (cells[0] as Array).size() and cells[ni][nj] != null:
			low = float(cells[ni][nj][0])
		var h: float = cell[0]
		if low >= h - 0.005:
			return
		var edge := e1 - e0
		var out2 := Vector2(edge.y, -edge.x).normalized()
		if out2.dot((e0 + e1) * 0.5 - mid) < 0.0:
			out2 = -out2
		b.quad([_v3(e0, low), _v3(e1, low), _v3(e1, h), _v3(e0, h)], Vector3(out2.x, 0.0, out2.y), cell[2])

	func _wall_mid(b: Builder, cell: Array, e0: Vector2, e1: Vector2, mid: Vector2,
			ha0: float, ha1: float, ci0: int, cj0: int, ci1: int, cj1: int,
			cells: Array, ni: int, nj: int) -> void:
		var hb0 := 0.0
		var hb1 := 0.0
		if ni >= 0 and ni < cells.size() and nj >= 0 and nj < (cells[0] as Array).size() and cells[ni][nj] != null:
			var ncell: Array = cells[ni][nj]
			if int(ncell[1]) == int(cell[1]) and int(ncell[2]) == int(cell[2]):
				return  # Same surface and row share corners: watertight without an internal wall.
			hb0 = float(_corner_sample(ci0, cj0, ncell[1], ncell[2], e0, float(ncell[0]), cells)[0])
			hb1 = float(_corner_sample(ci1, cj1, ncell[1], ncell[2], e1, float(ncell[0]), cells)[0])
		if hb0 >= ha0 - 0.005 and hb1 >= ha1 - 0.005:
			return
		var low0 := minf(hb0, ha0)
		var low1 := minf(hb1, ha1)
		var edge := e1 - e0
		var out2 := Vector2(edge.y, -edge.x).normalized()
		if out2.dot((e0 + e1) * 0.5 - mid) < 0.0:
			out2 = -out2
		var n3 := Vector3(out2.x, 0.0, out2.y)
		if ha0 - low0 > 0.002 and ha1 - low1 > 0.002:
			b.quad([_v3(e0, low0), _v3(e1, low1), _v3(e1, ha1), _v3(e0, ha0)], n3, cell[2])
		elif ha0 - low0 > 0.002:
			b.tri([_v3(e0, low0), _v3(e1, ha1), _v3(e0, ha0)], n3, cell[2])
		elif ha1 - low1 > 0.002:
			b.tri([_v3(e0, ha0), _v3(e1, low1), _v3(e1, ha1)], n3, cell[2])

	## Cached [height, uv_or_null] at grid corner `(ci, cj)` for material `(s, row)`.
	func _corner_sample(ci: int, cj: int, s: int, row: int, p: Vector2, fallback: float, cells: Array) -> Array:
		var key := [ci, cj, s, row]
		if _corner_cache.has(key):
			return _corner_cache[key]
		var is_b := _is_belt(s, row)
		var direct := _top_matching(p, s, row)
		var uv: Variant = direct[1] if not direct.is_empty() else null
		var h := NAN
		if is_b:
			var best_h := float(direct[0]) if not direct.is_empty() else -INF
			for off: Vector2 in [Vector2(0.025, 0.0), Vector2(-0.025, 0.0), Vector2(0.0, 0.025), Vector2(0.0, -0.025)]:
				var q := Vector2(clampf(p.x + off.x, box.position.x, box.end.x), clampf(p.y + off.y, box.position.z, box.end.z))
				var hit := _top_matching(q, s, row)
				if not hit.is_empty() and float(hit[0]) > best_h:
					best_h = float(hit[0])
					if uv == null:
						uv = hit[1]
			if best_h > -INF:
				h = best_h
		elif not direct.is_empty():
			h = float(direct[0])
		else:
			var hits: Array = []
			for off: Vector2 in [Vector2(0.035, 0.0), Vector2(-0.035, 0.0), Vector2(0.0, 0.035), Vector2(0.0, -0.035),
					Vector2(0.035, 0.035), Vector2(-0.035, 0.035), Vector2(0.035, -0.035), Vector2(-0.035, -0.035)]:
				var q := Vector2(clampf(p.x + off.x, box.position.x, box.end.x), clampf(p.y + off.y, box.position.z, box.end.z))
				var hit := _top_matching(q, s, row)
				if not hit.is_empty():
					hits.append(float(hit[0]))
					if uv == null:
						uv = hit[1]
			if not hits.is_empty():
				hits.sort()
				h = float(hits[hits.size() / 2])
		if is_nan(h):
			var sum := 0.0
			var n := 0
			for di in [-1, 0]:
				for dj in [-1, 0]:
					var ii: int = ci + di
					var jj: int = cj + dj
					if ii >= 0 and ii < cells.size() and jj >= 0 and jj < (cells[0] as Array).size():
						var c = cells[ii][jj]
						if c != null and int(c[1]) == s and int(c[2]) == row:
							sum += float(c[0])
							n += 1
			h = sum / float(n) if n > 0 else fallback
		var res := [h, uv]
		_corner_cache[key] = res
		return res

	static func _v3(p: Vector2, y: float) -> Vector3:
		return Vector3(p.x, y, p.y)

	## [corner points [i][j] (x across, z along), whether the ends get walls] for the kind.
	func _grid() -> Array:
		var x0 := box.position.x
		var x1 := box.end.x
		var z0 := box.position.z
		var z1 := box.end.z
		match kind:
			"s":
				# The rails, then the bed between them (as wide as the belt surface).
				var bed := _belt_half_width(0.415)
				return [_rect([x0, -bed, bed, x1], [z0, z1]), false]
			"l", "r":
				# Quarter rings about the curve's inner corner (as the shader's belt_shape).
				var side := 1.0 if kind == "l" else -1.0
				var centre := Vector2(-0.5 * side, -0.5)
				var bed := _belt_half_width(0.415)
				var radii := [0.5 - (0.5 - 0.02), 0.5 - bed, 0.5 + bed, maxf(x1 - x0, z1 - z0)]
				var cols: Array = []
				for r in radii:
					var col: Array = []
					for k in 7:
						var a := float(k) / 6.0 * PI * 0.5
						col.append(centre + Vector2(cos(a) * side, sin(a)) * float(r))
					cols.append(col)
				return [cols, false]
			"u":
				# Its cheeks, the hood rising in steps, the open bed and the lip.
				return [_rect([x0, x0 + 0.13, x1 - 0.13, x1], [z0, -0.3, -0.1, 0.1, 0.32, 0.43, z1]), true]
		# Splitters: a grid of cells about a quarter tile.
		var xs: Array = []
		var n := maxi(2, int(round((x1 - x0) / 0.25)))
		for k in n + 1:
			xs.append(lerpf(x0, x1, float(k) / n))
		var zs: Array = []
		var m := maxi(2, int(round((z1 - z0) / 0.25)))
		for k in m + 1:
			zs.append(lerpf(z0, z1, float(k) / m))
		return [_rect(xs, zs), true]

	## Higher-resolution 3D mid-detail grid [corners, walls_along] preserving rails, curves, hoods, and splitter housing.
	func _mid_grid() -> Array:
		var x0 := box.position.x
		var x1 := box.end.x
		var z0 := box.position.z
		var z1 := box.end.z
		match kind:
			"s":
				var bed := _belt_half_width(0.415)
				var rail_l := lerpf(x0, -bed, 0.5)
				var rail_r := lerpf(bed, x1, 0.5)
				var xs := [x0, rail_l, -bed, 0.0, bed, rail_r, x1]
				var zs: Array = []
				for k in 9:
					zs.append(lerpf(z0, z1, float(k) / 8.0))
				return [_rect(xs, zs), false]
			"l", "r":
				var side := 1.0 if kind == "l" else -1.0
				var centre := Vector2(-0.5 * side, -0.5)
				var bed := _belt_half_width(0.415)
				var r_out := maxf(x1 - x0, z1 - z0)
				var radii := [0.02, 0.5 - bed, 0.5, 0.5 + bed, lerpf(0.5 + bed, r_out, 0.5), r_out]
				var cols: Array = []
				for r in radii:
					var col: Array = []
					for k in 13:
						var a := float(k) / 12.0 * PI * 0.5
						col.append(centre + Vector2(cos(a) * side, sin(a)) * float(r))
					cols.append(col)
				return [cols, false]
			"u":
				var cheek := 0.13
				var xs := [x0, x0 + cheek, -0.24, 0.0, 0.24, x1 - cheek, x1]
				var zs := [z0, -0.40, -0.28, -0.15, -0.02, 0.12, 0.26, 0.36, 0.44, z1]
				return [_rect(xs, zs), true]
		var xs: Array = []
		var n := clampi(int(round((x1 - x0) / 0.20)), 4, 10)
		for k in n + 1:
			xs.append(lerpf(x0, x1, float(k) / n))
		var zs: Array = []
		var m := clampi(int(round((z1 - z0) / 0.20)), 3, 5)
		for k in m + 1:
			zs.append(lerpf(z0, z1, float(k) / m))
		return [_rect(xs, zs), true]

	## Half the width of the model's belt surface (its widest extent across), else `fallback`.
	func _belt_half_width(fallback: float) -> float:
		var w := 0.0
		for t: Array in _tris:
			if _is_belt(t[3], t[4]):
				for k in 3:
					w = maxf(w, absf((t[k] as Vector3).x))
		return w if w > 0.2 and w < 0.49 else fallback

	func _is_belt(s: int, row: int) -> bool:
		var rows: Array = belt_rows[s]
		return row >= 0 and row < rows.size() and bool(rows[row])

	static func _rect(xs: Array, zs: Array) -> Array:
		var out: Array = []
		for x in xs:
			var col: Array = []
			for z in zs:
				col.append(Vector2(float(x), float(z)))
			out.append(col)
		return out

	## A cell's [height, surface, row]: what is on top at nine points inside it, by majority; its
	## height their median (the belt surface's highest, so items sit on it as on the full model).
	## Null when fewer than four of the nine hit something.
	func _sample_cell(p00: Vector2, p10: Vector2, p11: Vector2, p01: Vector2) -> Variant:
		var hits: Array = []
		for u: float in [1.0 / 6.0, 0.5, 5.0 / 6.0]:
			for v: float in [1.0 / 6.0, 0.5, 5.0 / 6.0]:
				var p := p00.lerp(p10, u).lerp(p01.lerp(p11, u), v)
				var hit := _top(p)
				if not hit.is_empty():
					hits.append(hit)
		if hits.size() < 4:
			return null
		var votes := {}
		for hit: Array in hits:
			var key := Vector2i(hit[1], hit[2])
			votes[key] = int(votes.get(key, 0)) + 1
		var best := Vector2i(-1, -1)
		for key in votes:
			if best.x < 0 or votes[key] > votes[best]:
				best = key
		var heights: Array = []
		for hit: Array in hits:
			if Vector2i(hit[1], hit[2]) == best:
				heights.append(float(hit[0]))
		heights.sort()
		var h: float = heights[heights.size() - 1] if _is_belt(best.x, best.y) else heights[heights.size() / 2]
		return [h, best.x, best.y]

	## The highest triangle over a point: [height, surface, row], or [].
	func _top(p: Vector2) -> Array:
		var hit := _top_ex(p)
		return [hit[0], hit[1], hit[2]] if not hit.is_empty() else []

	## The highest triangle of material `(filter_s, filter_row)` over `p`: [height, uv_or_null], or [].
	func _top_matching(p: Vector2, filter_s: int, filter_row: int) -> Array:
		var hit := _top_ex(p, filter_s, filter_row)
		return [hit[0], hit[3]] if not hit.is_empty() else []

	func _top_ex(p: Vector2, filter_s := -1, filter_row := -1) -> Array:
		var bucket := _bucket_of(p)
		if bucket < 0:
			return []
		var best: Array = []
		for t: int in _buckets[bucket]:
			var tri: Array = _tris[t]
			if filter_s >= 0 and (int(tri[3]) != filter_s or int(tri[4]) != filter_row):
				continue
			var a: Vector3 = tri[0]
			var b: Vector3 = tri[1]
			var c: Vector3 = tri[2]
			var d := (b.x - a.x) * (c.z - a.z) - (c.x - a.x) * (b.z - a.z)
			if absf(d) < 1e-9:
				continue
			var l1 := ((p.x - a.x) * (c.z - a.z) - (c.x - a.x) * (p.y - a.z)) / d
			var l2 := ((b.x - a.x) * (p.y - a.z) - (p.x - a.x) * (b.z - a.z)) / d
			if l1 < -1e-5 or l2 < -1e-5 or l1 + l2 > 1.0 + 1e-5:
				continue
			var y := a.y + l1 * (b.y - a.y) + l2 * (c.y - a.y)
			if best.is_empty() or y > float(best[0]):
				var uv: Variant = null
				if tri[5] != null:
					var w1 := clampf(l1, 0.0, 1.0)
					var w2 := clampf(l2, 0.0, 1.0 - w1)
					var w0 := 1.0 - w1 - w2
					uv = (tri[5] as Vector2) * w0 + (tri[6] as Vector2) * w1 + (tri[7] as Vector2) * w2
				best = [y, tri[3], tri[4], uv]
		return best

	func _bucket_of(p: Vector2) -> int:
		var u := (p.x - box.position.x) / maxf(box.size.x, 0.001)
		var v := (p.y - box.position.z) / maxf(box.size.z, 0.001)
		if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
			return -1
		return mini(int(u * BUCKETS), BUCKETS - 1) * BUCKETS + mini(int(v * BUCKETS), BUCKETS - 1)

	func _index() -> void:
		_buckets = []
		for k in BUCKETS * BUCKETS:
			_buckets.append([])  # plain Arrays: a PackedInt32Array taken out of an Array is a copy
		for s in surfaces.size():
			var arrays: Array = surfaces[s]
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var idx = arrays[Mesh.ARRAY_INDEX]
			var uvs = arrays[Mesh.ARRAY_TEX_UV]
			var rows := Builder.row_of(arrays)
			var count: int = (idx as PackedInt32Array).size() if idx != null else verts.size()
			for t in range(0, count - 2, 3):
				var ia: int = idx[t] if idx != null else t
				var ib: int = idx[t + 1] if idx != null else t + 1
				var ic: int = idx[t + 2] if idx != null else t + 2
				var a := verts[ia]
				var b := verts[ib]
				var c := verts[ic]
				# Only faces that can be seen from above.
				if absf((b - a).cross(c - a).y) < 1e-7:
					continue
				var row := int(rows[ia]) if not rows.is_empty() else 0
				var n := _tris.size()
				if uvs != null:
					var uv_arr: PackedVector2Array = uvs
					_tris.append([a, b, c, s, row, uv_arr[ia], uv_arr[ib], uv_arr[ic]])
				else:
					_tris.append([a, b, c, s, row, null, null, null])
				var lo := Vector2(minf(a.x, minf(b.x, c.x)), minf(a.z, minf(b.z, c.z)))
				var hi := Vector2(maxf(a.x, maxf(b.x, c.x)), maxf(a.z, maxf(b.z, c.z)))
				var u0 := clampi(int((lo.x - box.position.x) / maxf(box.size.x, 0.001) * BUCKETS), 0, BUCKETS - 1)
				var u1 := clampi(int((hi.x - box.position.x) / maxf(box.size.x, 0.001) * BUCKETS), 0, BUCKETS - 1)
				var v0 := clampi(int((lo.y - box.position.z) / maxf(box.size.z, 0.001) * BUCKETS), 0, BUCKETS - 1)
				var v1 := clampi(int((hi.y - box.position.z) / maxf(box.size.z, 0.001) * BUCKETS), 0, BUCKETS - 1)
				for u in range(u0, u1 + 1):
					for v in range(v0, v1 + 1):
						(_buckets[u * BUCKETS + v] as Array).append(n)


## A stand-in's surface made from one of the model's: new corners, each copying the vertex data of
## the model's vertex nearest it (of the same material row, facing the same way where there is one).
class Builder:
	var src: Array
	var rows := PackedFloat32Array()
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var picks := PackedInt32Array()  # per new corner, the source vertex it copies
	## Per new corner, the shading (COLOR: the occlusion baked in) it takes instead of its pick's:
	## a top's is the average over the model's vertices under it, rails' crevices and rollers' gaps
	## and all, which a single vertex (often a bright ridge) doesn't stand for.
	var shading := PackedColorArray()
	var interp_uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	func _init(arrays: Array) -> void:
		src = arrays
		rows = row_of(arrays)

	## Each vertex's material row (merged materials' CUSTOM2.r), or empty with one material.
	static func row_of(arrays: Array) -> PackedFloat32Array:
		var out := PackedFloat32Array()
		var c2 = arrays[Mesh.ARRAY_CUSTOM2]
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if c2 == null or verts.is_empty():
			return out
		var stride: int = c2.size() / verts.size()
		if stride < 1:
			return out
		out.resize(verts.size())
		for k in verts.size():
			out[k] = float(c2[k * stride])
		return out

	func _emit_verts(p: Array, normal: Vector3, row: int, uvs_in: Array) -> int:
		var base := verts.size()
		var mean := _mean_shading(p, row) if normal.y > 0.5 else Color(-1, -1, -1, -1)
		var src_uv = src[Mesh.ARRAY_TEX_UV]
		for k in p.size():
			verts.append(p[k])
			normals.append(normal)
			var pick := _nearest(p[k], normal, row)
			picks.append(pick)
			shading.append(mean if mean.a >= 0.0 else _shading_of(pick))
			if src_uv != null:
				if k < uvs_in.size() and uvs_in[k] is Vector2:
					interp_uvs.append(uvs_in[k] as Vector2)
				else:
					interp_uvs.append((src_uv as PackedVector2Array)[pick])
		return base

	## A quad (corners in order round it) facing `normal`, of material row `row`.
	func quad(p: Array, normal: Vector3, row: int, uvs_in: Array = []) -> void:
		var base := _emit_verts(p, normal, row, uvs_in)
		# Godot's front faces wind clockwise seen from the front.
		var flip: bool = ((p[1] as Vector3) - p[0]).cross((p[2] as Vector3) - p[0]).dot(normal) > 0.0
		for t in [[0, 1, 2], [0, 2, 3]]:
			indices.append(base + t[0])
			indices.append(base + (t[2] if flip else t[1]))
			indices.append(base + (t[1] if flip else t[2]))

	## A single triangle facing `normal`, of material row `row`.
	func tri(p: Array, normal: Vector3, row: int, uvs_in: Array = []) -> void:
		var base := _emit_verts(p, normal, row, uvs_in)
		var flip: bool = ((p[1] as Vector3) - p[0]).cross((p[2] as Vector3) - p[0]).dot(normal) > 0.0
		indices.append(base)
		indices.append(base + (2 if flip else 1))
		indices.append(base + (1 if flip else 2))

	func _shading_of(k: int) -> Color:
		var c = src[Mesh.ARRAY_COLOR]
		return (c as PackedColorArray)[k] if c != null else Color.WHITE

	## The average COLOR of the model's vertices of this row inside the quad's box on the ground
	## (alpha -1: none there, or no COLOR).
	func _mean_shading(p: Array, row: int) -> Color:
		var c = src[Mesh.ARRAY_COLOR]
		if c == null:
			return Color(-1, -1, -1, -1)
		var lo := Vector2(INF, INF)
		var hi := -lo
		for q: Vector3 in p:
			lo = lo.min(Vector2(q.x, q.z))
			hi = hi.max(Vector2(q.x, q.z))
		var sv: PackedVector3Array = src[Mesh.ARRAY_VERTEX]
		var sum := Color(0, 0, 0, 0)
		var n := 0
		for k in sv.size():
			if not rows.is_empty() and int(rows[k] + 0.5) != row:
				continue
			var v := sv[k]
			if v.x < lo.x or v.x > hi.x or v.z < lo.y or v.z > hi.y:
				continue
			var col: Color = (c as PackedColorArray)[k]
			sum += col
			n += 1
		return sum / float(n) if n > 0 else Color(-1, -1, -1, -1)

	func _nearest(at: Vector3, normal: Vector3, row: int) -> int:
		var sv: PackedVector3Array = src[Mesh.ARRAY_VERTEX]
		var sn = src[Mesh.ARRAY_NORMAL]
		var best := 0
		var best_d := INF
		for pass_ in 2:
			for k in sv.size():
				if not rows.is_empty() and int(rows[k] + 0.5) != row:
					continue
				if pass_ == 0 and sn != null and (sn[k] as Vector3).dot(normal) < 0.5:
					continue
				var d := sv[k].distance_squared_to(at)
				if d < best_d:
					best_d = d
					best = k
			if best_d < INF:
				break
		return best

	## The surface's arrays: the source's arrays that are there, each corner's from its pick.
	func arrays() -> Array:
		if indices.is_empty():
			return []
		var out := []
		out.resize(Mesh.ARRAY_MAX)
		out[Mesh.ARRAY_VERTEX] = verts
		out[Mesh.ARRAY_NORMAL] = normals
		out[Mesh.ARRAY_INDEX] = indices
		var count := (src[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		for a in [Mesh.ARRAY_TANGENT, Mesh.ARRAY_COLOR, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2,
				Mesh.ARRAY_CUSTOM0, Mesh.ARRAY_CUSTOM1, Mesh.ARRAY_CUSTOM2, Mesh.ARRAY_CUSTOM3]:
			var from = src[a]
			if from == null or count == 0:
				continue
			var stride: int = from.size() / count
			var to = from.duplicate()
			to.resize(picks.size() * stride)
			for k in picks.size():
				for e in stride:
					to[k * stride + e] = from[picks[k] * stride + e]
			out[a] = to
		if out[Mesh.ARRAY_COLOR] != null:
			out[Mesh.ARRAY_COLOR] = shading
		if out[Mesh.ARRAY_TEX_UV] != null and interp_uvs.size() == verts.size():
			out[Mesh.ARRAY_TEX_UV] = interp_uvs
		return out
