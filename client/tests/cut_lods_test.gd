extends SceneTree
## Levels of detail ready at a camera cut (view_ahead.gd, `--cut-lods=old`): a viewpoint announced ahead
## (api.world.prepare_view) puts the chunks there at the levels a camera standing there would get, and
## unmerges far chunks there, before the camera moves; a cut seen (a jump past JUMP_TILES) picks every
## chunk's levels in one frame without the switch cap or cross-fades. The old behaviour (off) is checked
## to lag, so the test fails without the change.
##
##   godot --headless --audio-driver Dummy --path client --script res://tests/cut_lods_test.gd

const TestEnv := preload("res://tests/test_env.gd")
const ViewAhead := preload("res://scripts/world/view_ahead.gd")
const ChunkView := preload("res://scripts/world/chunk_view.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const FrameBudget := preload("res://scripts/world/frame_budget.gd")

const MODELS := 20  # more than world.gd's LOD_SWITCH_CAP (16) switches in one chunk
const FAR_CHUNK := Vector2i(10, 0)  # 320 tiles east

var World: Script
var fails := 0
var _meshes: Array[ArrayMesh] = []


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)
	else:
		print("  ok: ", what)


func _initialize() -> void:
	TestEnv.isolate("cut-lods-test")
	_run.call_deferred()


func _run() -> void:
	print("--- cut_lods_test ---")
	World = load("res://scripts/world/world.gd")
	var on_was := ViewAhead.on
	# Each system its own slice: a script's calls here can share one process frame, whose shared pool runs dry.
	var shared_was := FrameBudget.shared
	FrameBudget.shared = false
	_unit()
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.fov = 50.0
	cam.make_current()
	# The pixel's size per tile of distance as world.gd works it out, so a level switches at ~60 tiles.
	var height := ModelLods.counted_lines(root.get_visible_rect().size.y)
	var per_tile := ModelLods.lod_threshold * 2.0 * tan(deg_to_rad(cam.fov) * 0.5) / height
	var err := per_tile * 50.0
	for i in MODELS:
		var m := _tri_mesh()
		var lod := _tri_mesh()
		ModelLods._levels[m] = [[lod, err]]
		_meshes.append(m)

	for mode_on: bool in [true, false]:
		ViewAhead.on = mode_on
		ViewAhead.reset()
		var tag := "new" if mode_on else "old"
		var w: Node = _world()
		var a = _chunk(w, Vector2i.ZERO)
		var b = _chunk(w, FAR_CHUNK)
		w._held[FAR_CHUNK] = true  # past the square sent, kept (api.world.hold_chunks, as the trailer's shots)
		cam.global_position = Vector3(16.0, ChunkView.LOD_HEIGHT + 1.0, 16.0)
		cam.look_at(Vector3(16.0, 0.0, -16.0), Vector3.UP)
		for i in 4:
			w._update_lods(0.016)
		check(_levels(a) == 0 and _levels(b) == MODELS,
			"%s: before, near chunk at full level, the far one at its coarse level (%d, %d coarse)" % [tag, _levels(a), _levels(b)])

		# 1. Announced ahead: the far chunk at the level a camera there gets, the camera not moved.
		var there := Vector3(FAR_CHUNK.x * 32.0 + 16.0, ChunkView.LOD_HEIGHT + 1.0, 16.0)
		ViewAhead.prepare("test", there, there + Vector3(0.0, -10.0, -20.0), 5.0)
		var frames := 0
		while _levels(b) != 0 and frames < 30:
			w._update_lods(0.016)
			frames += 1
		var want := ModelLods.level_for(ModelLods._levels[_meshes[0]], 1, 1.0 * per_tile)
		if mode_on:
			check(want == 0 and _levels(b) == 0 and _levels(a) == 0,
				"new: announced viewpoint's chunk at the level a camera there gets (%d) before the camera moves, in %d frames; near chunk kept (%d)" % [want, frames, _levels(a)])
		else:
			check(_levels(b) == MODELS, "old: announcing changes nothing (%d coarse after %d frames)" % [_levels(b), frames])
		ViewAhead.release("test")
		for i in 4:
			w._update_lods(0.016)
		check(_levels(b) == MODELS, "%s: let go, the far chunk back at its coarse level (%d)" % [tag, _levels(b)])

		# 2. A cut seen: the camera jumps to the far chunk; one frame picks every level, no cross-fades.
		ViewAhead.cut_now(cam.global_position)
		ViewAhead._frame = -1  # the next frame (a script's first frames can share a process frame number)
		cam.global_position = there
		w.cut_frame = ViewAhead.cut_now(cam.global_position)
		w._update_lods(0.016)
		var fades := _fades(b)
		if mode_on:
			check(w.cut_frame and _levels(b) == 0 and fades == 0,
				"new: the frame of the cut picks all %d models' levels at once without fades (%d coarse, %d fading, %d us)" % [MODELS, _levels(b), fades, w.cut_usec])
		else:
			check(not w.cut_frame and _levels(b) > 0,
				"old: the frame of the cut still has %d of %d models coarse (switch cap 16 a frame)" % [_levels(b), MODELS])
		w.cut_frame = false
		w.queue_free()
		await process_frame

	# 3. Far merges: a chunk far from the camera merges; announced ahead it is whole again, camera not moved.
	for mode_on: bool in [true, false]:
		ViewAhead.on = mode_on
		ViewAhead.reset()
		var tag := "new" if mode_on else "old"
		var w: Node = _world()
		var b = _chunk(w, FAR_CHUNK)
		var fc = w.far_chunks
		fc.merge_from = 100.0
		cam.global_position = Vector3(16.0, 30.0, 16.0)
		w.set_focus(Vector2(16.0, 16.0))
		fc._check_timer = 1.0
		fc._decide(0.0, false)
		while fc._pass_next < fc._pass_todo.size():
			fc._decide_slice(0, false)
		check(b.far.far, "%s: a chunk 320 tiles off merges far" % tag)
		var there := Vector3(FAR_CHUNK.x * 32.0 + 16.0, 30.0, 16.0)
		ViewAhead.prepare("test", there, there + Vector3(0.0, -30.0, -10.0), 5.0)
		fc._decide(0.0, false)
		while fc._pass_next < fc._pass_todo.size():
			fc._decide_slice(0, false)
		if mode_on:
			check(not b.far.far, "new: announced there, the chunk is whole before the camera moves")
		else:
			check(b.far.far, "old: announcing changes nothing for far merges")
		ViewAhead.release("test")
		# A cut without announcing: settle_now unmerges in the cut's frame, whatever the budget.
		fc._check_timer = 1.0
		fc._decide(0.0, false)
		while fc._pass_next < fc._pass_todo.size():
			fc._decide_slice(0, false)
		check(b.far.far, "%s: let go, merged again" % tag)
		# A whole chunk with a merged mesh and nothing hidden behind it (cliffs alone: the wall draws them).
		var stand := MeshInstance3D.new()
		b.add_child(stand)
		b.far.node = stand
		b.far.covers = true
		b.far.full = true
		b.far.hidden = []
		cam.global_position = there
		fc.settle_now()
		check(not b.far.far, "%s: settle_now at a cut unmerges the chunk the camera cut to in that frame" % tag)
		if mode_on:
			check(not b.far.covers, "new: a whole chunk with nothing hidden behind its merged mesh drops it when near")
		else:
			check(b.far.covers, "old: the merged mesh of a whole chunk with nothing hidden stays when near (the wall hidden)")
		w.queue_free()
		await process_frame

	ViewAhead.on = on_was
	FrameBudget.shared = shared_was
	ViewAhead.reset()
	for m in _meshes:
		ModelLods._levels.erase(m)
	cam.queue_free()
	print("cut_lods_test: ", "FAILED %d" % fails if fails > 0 else "all passed")
	TestEnv.clean()
	quit(1 if fails > 0 else 0)


func _unit() -> void:
	ViewAhead.on = true
	ViewAhead.reset()
	var g := ViewAhead.generation
	ViewAhead.prepare("a", Vector3(100, 20, 0), Vector3(110, 0, 0), 5.0)
	check(ViewAhead.active() and ViewAhead.generation == g + 1 and ViewAhead.points() == [Vector3(100, 20, 0)],
		"prepare: active, one point, generation moved")
	ViewAhead.prepare("a", Vector3(103, 20, 0), Vector3(110, 0, 0), 5.0)
	check(ViewAhead.generation == g + 1, "announced again within MOVE_AGAIN: same generation")
	ViewAhead.prepare("a", Vector3(130, 20, 0), Vector3(140, 0, 0), 5.0)
	check(ViewAhead.generation == g + 2 and ViewAhead.looks() == [Vector2(140, 0)], "moved past MOVE_AGAIN: looked at again")
	var near := ViewAhead.nearest(Vector3.ZERO, Vector3(128, 0, 0), Vector3(160, 12, 32))
	check(near == Vector3(130, 20, 0), "nearest picks the announced camera for a chunk round it (%s)" % near)
	ViewAhead.prepare("a", Vector3(130, 20, 0), Vector3(140, 0, 0), 0.0)
	OS.delay_msec(5)
	check(not ViewAhead.active(), "a viewpoint runs out after its seconds")
	ViewAhead.prepare("a", Vector3(1, 2, 3), Vector3.ZERO, 5.0)
	ViewAhead.release("a")
	check(not ViewAhead.active(), "release lets it go")
	ViewAhead.on = false
	ViewAhead.prepare("a", Vector3(1, 2, 3), Vector3.ZERO, 5.0)
	check(not ViewAhead.active(), "--cut-lods=old: announcing is ignored")
	ViewAhead.on = true


func _tri_mesh() -> ArrayMesh:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)])
	arr[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m


func _world() -> Node:
	var w: Node = World.new()
	root.add_child(w)
	w.set_process(false)
	w.far_chunks.set_process(false)
	w.behind_cull.set_process(false)
	w.surface_index = 1
	w.lod_by_camera = true
	return w


## A chunk drawing MODELS models with levels, built as world.gd builds one (ChunkPrepJob, apply_prepared).
func _chunk(w: Node, c: Vector2i):
	var cv := ChunkView.new()
	cv.coord = c
	w.add_child(cv)
	var prep := ChunkView.ChunkPrepJob.new()
	prep.coord = c
	prep.serial = cv.build_serial
	prep.wanted = {}
	prep.wants = []
	for m in _meshes:
		var want = cv._want(m, m, [Transform3D.IDENTITY], [], null, false, [], null, false)
		var has_lods := cv._want_has_lods(want)
		want.use_buf = false
		want.pack_lod_buf = has_lods
		want.stride = 12
		want.mesh_box = ChunkView._mesh_box(want.mesh)
		prep.wants.append(want)
		prep.wanted[m] = true
	prep.run()
	cv.apply_prepared(prep, {})
	w.chunks[c] = cv
	w._row_add(c, cv)
	return cv


## How many of the chunk's models are drawn at a coarser level than their own.
func _levels(cv) -> int:
	var n := 0
	for mmi in cv._lods:
		if (cv._lods[mmi] as ChunkView.LodState).level > 0:
			n += 1
	return n


func _fades(cv) -> int:
	var n := 0
	for mmi in cv._lods:
		if (cv._lods[mmi] as ChunkView.LodState).fade != null:
			n += 1
	return n
