extends SceneTree
## Regression and unit tests for bulk MultiMesh upload helpers and render dispatch caching.

const InserterArmsScript := preload("res://scripts/world/inserter_arms.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")

var passes := 0
var fails := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		passes += 1
	else:
		fails += 1
		print("FAIL: %s" % msg)


func _unpack_xf(buf: PackedFloat32Array, offset: int) -> Transform3D:
	var o := offset
	var col_x := Vector3(buf[o], buf[o + 4], buf[o + 8])
	var col_y := Vector3(buf[o + 1], buf[o + 5], buf[o + 9])
	var col_z := Vector3(buf[o + 2], buf[o + 6], buf[o + 10])
	var origin := Vector3(buf[o + 3], buf[o + 7], buf[o + 11])
	return Transform3D(Basis(col_x, col_y, col_z), origin)


func _unpack_color(buf: PackedFloat32Array, offset: int) -> Color:
	var o := offset + 12
	return Color(buf[o], buf[o + 1], buf[o + 2], buf[o + 3])


func _initialize() -> void:
	print("--- Running inserter_buffer_test ---")
	_test_stride_12_upload()
	_test_stride_16_upload()
	_test_dispatch_caching_and_scratch()
	print("inserter_buffer_test: %d passed, %d failed" % [passes, fails])
	quit(0 if fails == 0 else 1)


func _test_stride_12_upload() -> void:
	var arms := InserterArmsScript.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = false
	mm.mesh = BoxMesh.new()

	var mm_fallback := MultiMesh.new()
	mm_fallback.transform_format = MultiMesh.TRANSFORM_3D
	mm_fallback.use_colors = false
	mm_fallback.mesh = BoxMesh.new()

	# 1. Empty upload
	arms.fast_upload = true
	arms._fill_xforms(mm, [])
	check(mm.instance_count == 0, "stride 12: empty upload leaves count 0")
	check(mm.visible_instance_count == 0, "stride 12: empty upload visible count 0")

	# 2. Initial upload of 5 transforms with non-identity rotations
	var xforms_5: Array = []
	for i in 5:
		var yaw: float = 0.3 * float(i + 1)
		var pitch: float = 0.15 * float(i)
		var basis := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)
		var origin := Vector3(float(i) * 2.5, float(i) * 0.75 + 1.0, float(i) * -1.5)
		xforms_5.append(Transform3D(basis, origin))

	arms.fast_upload = true
	arms._fill_xforms(mm, xforms_5)
	check(mm.instance_count == 16, "stride 12: initial 5 transforms grow to min 16 (got %d)" % mm.instance_count)
	check(mm.visible_instance_count == 5, "stride 12: visible count is 5")

	var buf: PackedFloat32Array = mm.buffer
	check(buf.size() == 16 * 12, "stride 12: buffer size == instance_count * 12 (192, got %d)" % buf.size())

	var match_5 := true
	for i in 5:
		var expected: Transform3D = xforms_5[i]
		var actual := _unpack_xf(buf, i * 12)
		if not actual.is_equal_approx(expected):
			match_5 = false
			print("Mismatch at %d: expected %s, got %s" % [i, expected, actual])
			break
	check(match_5, "stride 12: all 5 reconstructed transforms match exactly")

	# Fallback parity check
	arms.fast_upload = false
	arms._fill_xforms(mm_fallback, xforms_5)
	check(mm_fallback.instance_count == mm.instance_count, "stride 12: fallback capacity matches fast_upload (%d vs %d)" % [mm_fallback.instance_count, mm.instance_count])
	check(mm_fallback.visible_instance_count == mm.visible_instance_count, "stride 12: fallback visible count matches (%d vs %d)" % [mm_fallback.visible_instance_count, mm.visible_instance_count])

	# 3. Growth to 25 transforms
	var xforms_25: Array = []
	for i in 25:
		var basis := Basis(Vector3.UP, float(i) * 0.2)
		var origin := Vector3(float(i), float(i) * 0.5, float(-i))
		xforms_25.append(Transform3D(basis, origin))

	arms.fast_upload = true
	arms._fill_xforms(mm, xforms_25)
	check(mm.instance_count == 32, "stride 12: 25 transforms grow to 32 (got %d)" % mm.instance_count)
	check(mm.visible_instance_count == 25, "stride 12: visible count is 25")

	buf = mm.buffer
	check(buf.size() == 32 * 12, "stride 12: grown buffer size == 32 * 12 (384, got %d)" % buf.size())
	var match_25 := true
	for i in 25:
		var expected: Transform3D = xforms_25[i]
		var actual := _unpack_xf(buf, i * 12)
		if not actual.is_equal_approx(expected):
			match_25 = false
			break
	check(match_25, "stride 12: all 25 grown transforms match exactly")

	# 4. Shrinking to 0
	arms._fill_xforms(mm, [])
	check(mm.instance_count == 32, "stride 12: shrinking to 0 preserves capacity 32")
	check(mm.visible_instance_count == 0, "stride 12: shrinking to 0 sets visible count to 0")

	# 5. Re-growing to 8 transforms (partial visible_instance_count)
	var xforms_8: Array = []
	for i in 8:
		xforms_8.append(Transform3D(Basis(Vector3.FORWARD, float(i)), Vector3(float(i), 0.0, 0.0)))
	arms._fill_xforms(mm, xforms_8)
	check(mm.instance_count == 32, "stride 12: 8 transforms reuses capacity 32")
	check(mm.visible_instance_count == 8, "stride 12: partial visible count is 8")

	buf = mm.buffer
	var match_8 := true
	for i in 8:
		var expected: Transform3D = xforms_8[i]
		var actual := _unpack_xf(buf, i * 12)
		if not actual.is_equal_approx(expected):
			match_8 = false
			break
	check(match_8, "stride 12: all 8 transforms match after capacity reuse")

	arms._cards.free()
	arms.free()


func _test_stride_16_upload() -> void:
	var arms := InserterArmsScript.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = BoxMesh.new()

	var mm_fallback := MultiMesh.new()
	mm_fallback.transform_format = MultiMesh.TRANSFORM_3D
	mm_fallback.use_colors = true
	mm_fallback.mesh = BoxMesh.new()

	# 1. Empty upload
	arms.fast_upload = true
	arms._fill_xforms_colored(mm, [], [], 1)
	check(mm.instance_count == 0, "stride 16: empty upload count 0")
	check(mm.visible_instance_count == 0, "stride 16: empty upload visible 0")

	# 2. 4 transforms, per_arm = 1, part = Part.UPPER
	var xforms_4: Array = []
	var colors_4: Array[Color] = [
		Color(0.2, 0.4, 0.6, 1.0),
		Color(0.8, 0.1, 0.3, 1.0),
		Color(0.5, 0.5, 0.5, 1.0),
		Color(0.9, 0.8, 0.1, 1.0)
	]
	for i in 4:
		var basis := Basis(Vector3.UP, float(i) * 0.7)
		var origin := Vector3(float(i + 1) * 3.0, 1.0, float(i + 1) * 2.0)
		xforms_4.append(Transform3D(basis, origin))

	arms.fast_upload = true
	arms._fill_xforms_colored(mm, xforms_4, colors_4, 1, InserterArmsScript.Part.UPPER)
	check(mm.instance_count == 16, "stride 16: 4 instances allocate min 16 capacity (got %d)" % mm.instance_count)
	check(mm.visible_instance_count == 4, "stride 16: visible count is 4")

	var buf: PackedFloat32Array = mm.buffer
	check(buf.size() == 16 * 16, "stride 16: buffer size == 16 * 16 (256, got %d)" % buf.size())

	var match_4_xf := true
	var match_4_col := true
	for i in 4:
		var expected_xf: Transform3D = xforms_4[i]
		var actual_xf := _unpack_xf(buf, i * 16)
		if not actual_xf.is_equal_approx(expected_xf):
			match_4_xf = false
		var expected_col: Color = arms._part_color(InserterArmsScript.Part.UPPER, colors_4[i])
		var actual_col := _unpack_color(buf, i * 16)
		if not actual_col.is_equal_approx(expected_col):
			match_4_col = false
			print("Color mismatch at %d: expected %s, got %s" % [i, expected_col, actual_col])
	check(match_4_xf, "stride 16: all 4 transforms match")
	check(match_4_col, "stride 16: all 4 colors match _part_color (raw RGBA floats)")

	# Fallback parity
	arms.fast_upload = false
	arms._fill_xforms_colored(mm_fallback, xforms_4, colors_4, 1, InserterArmsScript.Part.UPPER)
	check(mm_fallback.instance_count == mm.instance_count, "stride 16: fallback capacity matches (%d vs %d)" % [mm_fallback.instance_count, mm.instance_count])
	check(mm_fallback.visible_instance_count == mm.visible_instance_count, "stride 16: fallback visible count matches (%d vs %d)" % [mm_fallback.visible_instance_count, mm.visible_instance_count])

	# 3. 6 transforms with per_arm = 2 (fingers: 3 arms x 2 fingers)
	var xforms_6: Array = []
	var colors_3: Array[Color] = [Color.RED, Color.GREEN, Color.BLUE]
	for i in 6:
		xforms_6.append(Transform3D(Basis.IDENTITY, Vector3(float(i), 0.0, 0.0)))

	arms.fast_upload = true
	arms._fill_xforms_colored(mm, xforms_6, colors_3, 2, InserterArmsScript.Part.FINGERS)
	check(mm.visible_instance_count == 6, "stride 16: 6 fingers visible")
	buf = mm.buffer
	var match_fingers := true
	for i in 6:
		var expected_col: Color = arms._part_color(InserterArmsScript.Part.FINGERS, colors_3[i >> 1])
		var actual_col := _unpack_color(buf, i * 16)
		if not actual_col.is_equal_approx(expected_col):
			match_fingers = false
			break
	check(match_fingers, "stride 16: per_arm = 2 indexes colors with i >> 1")

	# 4. Direct color without part tint (part = -1)
	arms._fill_xforms_colored(mm, xforms_4, colors_4, 1, -1)
	buf = mm.buffer
	var match_raw := true
	for i in 4:
		var actual_col := _unpack_color(buf, i * 16)
		if not actual_col.is_equal_approx(colors_4[i]):
			match_raw = false
			break
	check(match_raw, "stride 16: part = -1 uploads colors directly without tint")

	# 5. Shrinking to 0
	arms._fill_xforms_colored(mm, [], colors_4, 1)
	check(mm.visible_instance_count == 0, "stride 16: shrinking to 0 sets visible 0")

	arms._cards.free()
	arms.free()


func _test_dispatch_caching_and_scratch() -> void:
	# Ensure model is ready or polled
	for i in 200:
		ModelLibrary.poll()
		if ModelLibrary.ready("inserter"):
			break
		OS.delay_msec(10)

	var arms := InserterArmsScript.new()
	var arm := InserterArmsScript.Arm.new()
	arm.bound = true
	arm.proto_name = "inserter"
	arm.model_name = "inserter"
	arms._arms[101] = arm

	check(arm.mode == InserterArmsScript.Arm.Mode.NONE, "arm dispatch mode starts NONE")

	# Process frame 1
	arms._process(1.0 / 60.0)
	var cached_mode: int = arm.mode
	check(cached_mode != InserterArmsScript.Arm.Mode.NONE, "arm dispatch mode cached after frame 1 (mode %d)" % cached_mode)
	check(arm.mode_pack_ver == ModelLibrary.ModelPacks.version, "arm pack version cached")
	var current_gen: int = arms._model_ver()  # (--arm-model-watch: the layer's own stamp)
	check(arm.mode_model_ver == current_gen, "arm model version cached")

	# Process frame 2: mode stays identical
	arms._process(1.0 / 60.0)
	check(arm.mode == cached_mode, "arm dispatch mode remains cached on frame 2")

	# Test that an arm whose model is still loading (_rig_for returns null) is NOT cached
	var loading_arm := InserterArmsScript.Arm.new()
	loading_arm.bound = true
	loading_arm.proto_name = "test_loading_proto"
	loading_arm.model_name = "test_loading_proto"
	arms._arms[102] = loading_arm
	arms._rigs["test_loading_proto"] = null
	arms._process(1.0 / 60.0)
	check(loading_arm.mode == InserterArmsScript.Arm.Mode.NONE, "arm dispatch mode NOT cached while rig is null (loading)")
	arms._arms.erase(102)
	arms._rigs.erase("test_loading_proto")

	# Test scratch reuse and clearing
	arms._scratch_held[999] = [Vector3.ONE]
	arms._scratch_held_yaws[999] = [0.0]
	arms._scratch_live[999] = Vector2i.ZERO
	check(arms._scratch_held.has(999), "dummy key set in _scratch_held")

	arms._process(1.0 / 60.0)
	check(not arms._scratch_held.has(999), "_scratch_held cleared at start of _process()")
	check(not arms._scratch_held_yaws.has(999), "_scratch_held_yaws cleared at start of _process()")
	check(not arms._scratch_live.has(999), "_scratch_live cleared at start of _process()")

	# Test invalidation on model generation bump (--arm-model-watch: taken by the safety net here, nothing watched)
	ModelLibrary.generation += 1
	arms._watch_pending = true
	arms._watch_pend_msec = Time.get_ticks_msec() - InserterArmsScript.WATCH_NET_MSEC  # (unaccepted for 2 s)
	arms._ver_frame = -1  # (a new frame for the per-frame latch)
	arms._process(1.0 / 60.0)
	var new_gen: int = arms._model_ver()
	check(arm.mode_model_ver == new_gen and new_gen > current_gen, "arm dispatch re-evaluated on generation bump (arm %d, now %d, before %d)" % [arm.mode_model_ver, new_gen, current_gen])

	# Test reset()
	arms.reset()
	check(arms._upload_bufs.is_empty(), "reset() clears _upload_bufs")
	check(arms._arms.is_empty(), "reset() clears _arms")
	check(arms._scratch_held.is_empty(), "reset() clears _scratch_held")
	check(arms._scratch_model_lists.is_empty(), "reset() clears _scratch_model_lists")

	arms._cards.free()
	arms.free()
