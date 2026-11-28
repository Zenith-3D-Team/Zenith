extends SceneTree
## perf-render R2: chunk MultiMeshes filled from a buffer are never written instance by instance, nor have
## their mesh swapped while the old buffer is set (either makes Godot read the buffer back from the graphics
## card), and one filled instance by instance is emptied before it is filled from a buffer (no second CPU
## copy uploaded with every buffer). `--mm-writes=instance` (ChunkView.mm_buffer_writes = false) counts them.

const ChunkView := preload("res://scripts/world/chunk_view.gd")
const Probing := preload("res://scripts/debug/probing.gd")
const RobotSwarm := preload("res://scripts/world/robot_swarm.gd")

var passes := 0
var fails := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		passes += 1
	else:
		fails += 1
		print("FAIL: %s" % msg)


func _initialize() -> void:
	var probing_was := Probing.on
	var mode_was := ChunkView.mm_buffer_writes
	Probing.on = true
	_test_layout()
	for mode: bool in [true, false]:
		ChunkView.mm_buffer_writes = mode
		_test_flip_to_instances(mode)
		_test_flip_to_buffer(mode)
		_test_mesh_change(mode)
		_test_lod_switch(mode)
		_test_thinned_realloc(mode)
	ChunkView.mm_buffer_writes = mode_was
	_test_own_bounds()
	Probing.on = probing_was
	print("mm_buffer_writes_test: %d passed, %d failed" % [passes, fails])
	quit(1 if fails > 0 else 0)


func _xforms(n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append(Transform3D(Basis(Vector3.UP, 0.3 * i).scaled(Vector3(1.0 + i, 1.0, 0.5)), Vector3(i, 0.5 * i, -2.0 * i)))
	return out


func _colors(n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append(Color(0.1 * i, 0.2, 0.3 + 0.1 * i, 0.9))
	return out


## As chunk_view's _new_mmi makes them.
func _mm() -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	return mm


func _box(size: float) -> Mesh:
	var m := BoxMesh.new()
	m.size = Vector3.ONE * size
	return m


func _count(key: String) -> int:
	return int(ChunkView.counters.get(key, 0))


## The packed floats are the TRANSFORM_3D layout Godot reads (row-major 3x4, colour after, custom data last)
## for every format, and the stride the re-send checks against agrees.
func _test_layout() -> void:
	var xf := _xforms(3)
	var cols := _colors(3)
	for with_colors: bool in [false, true]:
		for custom: bool in [false, true]:
			var buf := ChunkView.ChunkPrepJob.pack_buffer_gd(xf, cols if with_colors else [], custom, false)
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = with_colors
			mm.use_custom_data = custom
			var stride := ChunkView._stride(mm)
			var ok := buf.size() == 3 * stride
			for i in 3:
				var o := i * stride
				var t: Transform3D = xf[i]
				var back := Transform3D(Vector3(buf[o], buf[o + 4], buf[o + 8]), Vector3(buf[o + 1], buf[o + 5], buf[o + 9]),
					Vector3(buf[o + 2], buf[o + 6], buf[o + 10]), Vector3(buf[o + 3], buf[o + 7], buf[o + 11]))
				ok = ok and back.is_equal_approx(t)
				if with_colors:
					ok = ok and Color(buf[o + 12], buf[o + 13], buf[o + 14], buf[o + 15]).is_equal_approx(cols[i])
				if custom:
					var c := o + stride - 4
					ok = ok and buf[c] == 0.0 and buf[c + 1] == 0.0 and buf[c + 2] == 0.0 and buf[c + 3] == 0.0
			check(ok, "packed buffer matches Transform3D/Color (colours %s, custom %s, stride %d)" % [with_colors, custom, stride])
			if ChunkView.ChunkPrepJob.chunk_native() != null:
				var nat := ChunkView.ChunkPrepJob.pack_buffer(xf, cols if with_colors else [], custom, false)
				check(nat == buf, "native pack_buffer matches the script's (colours %s, custom %s)" % [with_colors, custom])


func _cv() -> Node3D:
	var cv: Node3D = ChunkView.new()
	cv.coord = Vector2i.ZERO
	root.add_child(cv)
	return cv


## A key filled from a buffer, then instance by instance at the same count (a belt joining a circuit).
func _test_flip_to_instances(mode: bool) -> void:
	var cv := _cv()
	var mm := _mm()
	var mesh := _box(1.0)
	var xf := _xforms(4)
	var buf := ChunkView.ChunkPrepJob.pack_buffer_gd(xf, [], false, false)
	cv._fill_buffer(mm, mesh, 4, false, false, buf, AABB(Vector3.ZERO, Vector3.ONE))
	var was_buf := ChunkView._filled_by_buffer(mm)
	ChunkView.counters.clear()
	ChunkView._fill(mm, mesh, xf, [], false)
	var writes := _count("mm_buf_instance_writes")
	var flips := _count("mm_fill_flips")
	var ok_state: bool = mm.instance_count == 4 and not ChunkView._filled_by_buffer(mm) 		and int(mm.get_meta(ChunkView.MM_FILL, 0)) == ChunkView.FILL_INSTANCE and mm.mesh == mesh
	if mode:
		check(was_buf and ok_state and writes == 0 and flips == 1,
			"buffer -> instance fill: emptied first, no per-instance write on the old buffer (%d writes, %d flips)" % [writes, flips])
	else:
		check(was_buf and ok_state and writes == 4 and flips == 0,
			"--mm-writes=instance: buffer -> instance fill writes on the buffer as before (%d writes)" % writes)
	cv.free()


## A key filled instance by instance, then from a buffer at the same count.
func _test_flip_to_buffer(mode: bool) -> void:
	var cv := _cv()
	var mm := _mm()
	var mesh := _box(1.0)
	var xf := _xforms(3)
	ChunkView._fill(mm, mesh, xf, [], false)
	ChunkView.counters.clear()
	cv._fill_buffer(mm, mesh, 3, false, false, ChunkView.ChunkPrepJob.pack_buffer_gd(xf, [], false, false), AABB(Vector3.ZERO, Vector3.ONE))
	var flips := _count("mm_fill_flips")
	check(ChunkView._filled_by_buffer(mm) and mm.instance_count == 3 and flips == (1 if mode else 0),
		"instance -> buffer fill %s (%d flips)" % ["empties it first" if mode else "keeps the engine's copy (old)", flips])
	# Filled from a buffer again: nothing more to do.
	ChunkView.counters.clear()
	cv._fill_buffer(mm, mesh, 3, false, false, ChunkView.ChunkPrepJob.pack_buffer_gd(xf, [], false, false), AABB(Vector3.ZERO, Vector3.ONE))
	check(_count("mm_fill_flips") == 0 and _count("mm_buf_mesh_readbacks") == 0, "buffer -> buffer at the same mesh: no flip, no read-back")
	cv.free()


## A buffer-filled MultiMesh given another mesh at the same count (a stand-in or model made again).
func _test_mesh_change(mode: bool) -> void:
	var cv := _cv()
	var mm := _mm()
	var a := _box(1.0)
	var b := _box(2.0)
	var xf := _xforms(5)
	var buf := ChunkView.ChunkPrepJob.pack_buffer_gd(xf, [], false, false)
	cv._fill_buffer(mm, a, 5, false, false, buf, AABB(Vector3.ZERO, Vector3.ONE))
	ChunkView.counters.clear()
	cv._fill_buffer(mm, b, 5, false, false, buf, AABB(Vector3.ZERO, Vector3.ONE))
	var readbacks := _count("mm_buf_mesh_readbacks")
	check(mm.mesh == b and mm.instance_count == 5 and readbacks == (0 if mode else 1),
		"buffer-filled mesh swap: %d read-backs (%s)" % [readbacks, "new" if mode else "old"])
	# A smaller count re-allocates before the swap: no read-back either way.
	ChunkView.counters.clear()
	cv._fill_buffer(mm, a, 4, false, false, ChunkView.ChunkPrepJob.pack_buffer_gd(_xforms(4), [], false, false), AABB(Vector3.ZERO, Vector3.ONE))
	check(mm.mesh == a and mm.instance_count == 4 and _count("mm_buf_mesh_readbacks") == 0, "resized buffer-filled mesh swap: no read-back")
	# And through _fill (buffer -> instances with another mesh).
	ChunkView.counters.clear()
	ChunkView._fill(mm, b, _xforms(4), [], false)
	check(mm.mesh == b and _count("mm_buf_mesh_readbacks") == (0 if mode else 1) and _count("mm_buf_instance_writes") == (0 if mode else 4),
		"buffer -> instances with another mesh: %d read-backs, %d writes" % [_count("mm_buf_mesh_readbacks"), _count("mm_buf_instance_writes")])
	cv.free()


## A level-of-detail switch on a MultiMesh filled from a buffer re-sends the kept buffer, no touch.
func _test_lod_switch(mode: bool) -> void:
	var cv := _cv()
	cv.lod_snap = true  # no cross-fade copy: only the switch itself
	var model := _box(1.0)
	var coarse := _box(1.1)
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = _mm()
	cv.add_child(mmi)
	var xf := _xforms(6)
	var buf := ChunkView.ChunkPrepJob.pack_buffer_gd(xf, [], false, false)
	cv._fill_buffer(mmi.multimesh, model, 6, false, false, buf, AABB(Vector3.ZERO, Vector3.ONE))
	var st := ChunkView.LodState.new()
	st.model = model
	st.buffer = buf
	st.xforms = xf
	cv._lods[mmi] = st
	ChunkView.counters.clear()
	cv._switch_level(mmi, st, 1, [[coarse, 0.1]])
	var mm := mmi.multimesh
	var ok := st.level == 1 and mm.mesh == coarse and mm.instance_count == 6
	if mode:
		check(ok and _count("mm_buf_resends") == 1 and _count("mm_buf_mesh_readbacks") == 0 and _count("mm_buf_instance_writes") == 0
			and _count("lod_mesh_touches") == 0, "LOD switch on a buffer-filled MultiMesh re-sends the kept buffer (no read-back, no touch)")
		# No kept buffer: counted, as before.
		st.buffer = PackedFloat32Array()
		ChunkView.counters.clear()
		cv._switch_level(mmi, st, 0, [[coarse, 0.1]])
		check(mm.mesh == model and _count("mm_buf_mesh_readbacks") == 1, "LOD switch with no kept buffer is counted as a read-back")
	else:
		check(ok and _count("mm_buf_resends") == 0 and _count("mm_buf_mesh_readbacks") == 1,
			"--mm-writes=instance: LOD switch on a buffer-filled MultiMesh swaps the mesh as before")
	# Filled instance by instance (the LOD models' usual path): the touch as before, nothing counted.
	ChunkView._fill(mm, model, xf, [], false)
	st.level = 0
	ChunkView.counters.clear()
	cv._switch_level(mmi, st, 1, [[coarse, 0.1]])
	check(mm.mesh == coarse and _count("mm_buf_mesh_readbacks") == 0 and _count("mm_buf_instance_writes") == 0
		and _count("mm_buf_resends") == 0 and _count("lod_mesh_touches") == (1 if ChunkView.lod_mesh_touch else 0),
		"LOD switch on an instance-filled MultiMesh keeps the touch (%s)" % ("new" if mode else "old"))
	cv.free()


## A thinned MultiMesh (_thin: scattered ore's far shadow stand-in) re-allocated at the same count (a mesh
## swap, a LOD switch, a flip) gets its visible count sent again: the engine clipped it to 0 on the empty
## allocation (headless has no renderer to read, so the sends are counted).
func _test_thinned_realloc(mode: bool) -> void:
	var cv := _cv()
	var a := _box(1.0)
	var b := _box(2.0)
	var xf := _xforms(5)
	var buf := ChunkView.ChunkPrepJob.pack_buffer_gd(xf, [], false, false)
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = _mm()
	cv.add_child(mmi)
	var mm := mmi.multimesh
	cv._fill_buffer(mm, a, 5, false, false, buf, AABB(Vector3.ZERO, Vector3.ONE))
	mm.visible_instance_count = 3
	ChunkView.counters.clear()
	cv._fill_buffer(mm, b, 5, false, false, buf, AABB(Vector3.ZERO, Vector3.ONE))
	check(mm.visible_instance_count == 3 and _count("mm_visible_resends") == (1 if mode else 0),
		"thinned buffer-filled mesh swap: visible count sent again %d time(s) (%s)" % [_count("mm_visible_resends"), "new" if mode else "old"])
	var st := ChunkView.LodState.new()
	st.model = b
	st.buffer = buf
	st.xforms = xf
	cv._lods[mmi] = st
	cv.lod_snap = true
	ChunkView.counters.clear()
	cv._switch_level(mmi, st, 1, [[a, 0.1]])
	check(mm.visible_instance_count == 3 and _count("mm_visible_resends") == (1 if mode else 0),
		"thinned LOD switch: visible count sent again (%s)" % ("new" if mode else "old"))
	# Buffer -> instances flips to an empty buffer first (new way): the count goes with it.
	ChunkView.counters.clear()
	ChunkView._fill(mm, b, xf, [], false)
	check(mm.visible_instance_count == 3 and _count("mm_visible_resends") == (1 if mode else 0),
		"thinned buffer -> instances: visible count sent again (%s)" % ("new" if mode else "old"))
	# Unthinned (-1, all shown): nothing to send.
	mm.visible_instance_count = -1
	ChunkView.counters.clear()
	cv._fill_buffer(mm, a, 5, false, false, buf, AABB(Vector3.ZERO, Vector3.ONE))
	check(_count("mm_visible_resends") == 0, "unthinned re-allocation: no visible-count send")
	cv.free()


## R6: the robot swarm's MultiMeshes carry their own box (the node's), so a buffer upload doesn't make Godot
## work their bounds out over the whole capacity; `--mm-bounds=engine` leaves it unset.
func _test_own_bounds() -> void:
	var was := RobotSwarm.mm_own_bounds
	for own: bool in [true, false]:
		RobotSwarm.mm_own_bounds = own
		var swarm: Node3D = RobotSwarm.new()
		var mmi: MultiMeshInstance3D = swarm._instance(_box(1.0), null)
		var want: AABB = RobotSwarm.BOUNDS if own else AABB()
		check(mmi.multimesh.custom_aabb == want and mmi.custom_aabb == RobotSwarm.BOUNDS,
			"robot swarm MultiMesh box %s (%s)" % ["set to the node's" if own else "left to the engine", mmi.multimesh.custom_aabb])
		swarm.free()
	RobotSwarm.mm_own_bounds = was
