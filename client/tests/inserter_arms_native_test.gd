extends SceneTree
## Parity and speed of InserterArmsNative (native/belt_sim/src/inserter_arms_native.cpp) against the GDScript arms
## (inserter_arms.gd's _draw_sprite_arm / _draw_model_arm / _draw_arm / _draw_rig_arm and the buffer fills): the
## same arms through both, the MultiMesh buffers compared (max difference), the time of each printed.
## Run: godot --headless --audio-driver Dummy --path client --log-file <abs> --script res://tests/inserter_arms_native_test.gd
## Needs the built native library (client/native/bin); skipped, with a note, without it.

const Arms := preload("res://scripts/world/inserter_arms.gd")
const NativeLibrary := preload("res://scripts/native_library.gd")
const ModelRig := preload("res://scripts/world/model_rig.gd")

const N := 2000
const TOL := 2e-4

var passes := 0
var fails := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		passes += 1
	else:
		fails += 1
		print("FAIL: %s" % msg)


func _initialize() -> void:
	print("--- Running inserter_arms_native_test ---")
	if not NativeLibrary.ensure() or not ClassDB.class_exists("InserterArmsNative"):
		print("inserter_arms_native_test: InserterArmsNative not built, skipped")
		quit(0)
		return
	for grip in [true, false]:
		Arms.held_grip = grip
		print("held_grip=%s" % grip)
		_test_sprite()
		_test_model()
		_test_basic()
		_test_rig()
	Arms.held_grip = true
	print("inserter_arms_native_test: %d passed, %d failed" % [passes, fails])
	quit(0 if fails == 0 else 1)


func _mm(colors := false) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = colors
	mm.mesh = BoxMesh.new()
	mm.instance_count = 16
	return mm


func _mmis(count: int, colors := false) -> Array:
	var out: Array = []
	for i in count:
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = _mm(colors)
		out.append(mmi)
	return out


func _arm_list(seed_value: int, reach_max: float) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var out: Array = []
	for i in N:
		var arm := Arms.Arm.new()
		arm.proto_name = "inserter"
		arm.base = Vector2(rng.randf_range(-200.0, 200.0), rng.randf_range(-200.0, 200.0))
		arm.angle = rng.randf_range(-PI, PI)
		arm.reach = rng.randf_range(0.2, reach_max)
		arm.item_id = rng.randi_range(0, 1)
		arm.close = rng.randf()
		arm.card_lift = rng.randf_range(0.0, 0.3)
		arm.color = Color(rng.randf(), rng.randf(), rng.randf())
		arm.placed = Transform3D(Basis(Vector3.UP, rng.randf_range(-3.0, 3.0)), Vector3(arm.base.x, 0.0, arm.base.y))
		out.append(arm)
	return out


## Max |difference| between the first `count` instances of two buffers.
func _diff(a: PackedFloat32Array, b: PackedFloat32Array, count: int, stride: int) -> float:
	var worst := 0.0
	if a.size() < count * stride or b.size() < count * stride:
		return INF
	for i in count * stride:
		worst = maxf(worst, absf(a[i] - b[i]))
	return worst


func _report(label: String, arms_old: Array, mms_old: Array, mms_new: Array, counts: Array, stride: int, t_old: int, t_new: int, wrist_diff: float) -> void:
	var worst := 0.0
	for p in mms_old.size():
		var mo: MultiMesh = mms_old[p]
		var mn: MultiMesh = mms_new[p]
		check(mo.visible_instance_count == mn.visible_instance_count, "%s piece %d count %d vs %d" % [label, p, mo.visible_instance_count, mn.visible_instance_count])
		worst = maxf(worst, _diff(mo.buffer, mn.buffer, mini(mo.visible_instance_count, mn.visible_instance_count), stride))
	check(worst < TOL, "%s transforms max diff %s" % [label, worst])
	check(wrist_diff < TOL, "%s wrists max diff %s" % [label, wrist_diff])
	print("%s: max diff %s (wrist %s), GDScript %.2f ms, native %.2f ms (%d arms), first value %s" % [label, worst, wrist_diff, t_old / 1000.0, t_new / 1000.0, N, (mms_new[0] as MultiMesh).buffer.slice(0, 4)])


func _native_run(arms: Arms, mode: int, key: String, list: Array, mmis_for_basic := false) -> int:
	for b: Arms.NBatch in (arms._nb[mode] as Dictionary).values():
		b.inp.clear()
		b.slots.clear()
		b.arms.clear()
	var t0 := Time.get_ticks_usec()
	for i in list.size():
		arms._nb_add(mode, key, list[i], i)
	arms._ord_arms.clear()
	arms._ord_arms.resize(list.size())
	arms._ord_wrist.resize(list.size())
	arms._ord_grip.resize(list.size())
	arms._ord_gripped.resize(list.size())
	arms._native_batches()
	arms._native_fill()
	return Time.get_ticks_usec() - t0


func _wrist_diff(arms: Arms, mode: int, key: String, wrists: Array) -> float:
	var r: Array = arms._nres[3] if mode == 3 else (arms._nres[mode] as Dictionary)[key]
	var wr: PackedFloat32Array = r[2]
	var worst := 0.0
	for i in wrists.size():
		var w: Vector3 = wrists[i]
		worst = maxf(worst, maxf(absf(wr[i * 3] - w.x), maxf(absf(wr[i * 3 + 1] - w.y), absf(wr[i * 3 + 2] - w.z))))
	return worst


func _new_arms() -> Arms:
	var arms := Arms.new()
	arms._native = ClassDB.instantiate("InserterArmsNative")
	arms._native_tried = true
	return arms


func _test_sprite() -> void:
	var arms := _new_arms()
	var pictures := {"widths": [0.55, 0.3, 0.34]}
	var list := _arm_list(1, 1.4)
	for a: Arms.Arm in list:
		a.mode_cards = pictures
	var old := _mmis(3)
	var nat := _mmis(3)
	arms._sprite_mmis["inserter"] = nat
	var t0 := Time.get_ticks_usec()
	var lists := [[], [], []]
	var wrists: Array = []
	for a: Arms.Arm in list:
		wrists.append(arms._draw_sprite_arm(a, pictures, lists))
	for p in 3:
		arms._fill_xforms((old[p] as MultiMeshInstance3D).multimesh, lists[p])
	var t_old := Time.get_ticks_usec() - t0
	var t_new := _native_run(arms, 0, "inserter", list)
	var mo: Array = []
	var mn: Array = []
	for p in 3:
		mo.append((old[p] as MultiMeshInstance3D).multimesh)
		mn.append((nat[p] as MultiMeshInstance3D).multimesh)
	_report("sprite arms", list, mo, mn, [], 12, t_old, t_new, _wrist_diff(arms, 0, "inserter", wrists))


func _test_model() -> void:
	var arms := _new_arms()
	var list := _arm_list(2, 1.4)
	for fam in ["inserter", "long-handed-inserter"]:
		for a: Arms.Arm in list:
			a.proto_name = fam
		var old := _mmis(3)
		var nat := _mmis(3)
		arms._model_parts[fam] = nat
		var t0 := Time.get_ticks_usec()
		var lists := [[], [], []]
		var wrists: Array = []
		for a: Arms.Arm in list:
			wrists.append(arms._draw_model_arm(a, lists))
		for p in 3:
			arms._fill_xforms((old[p] as MultiMeshInstance3D).multimesh, lists[p])
		var t_old := Time.get_ticks_usec() - t0
		var t_new := _native_run(arms, 2, fam, list)
		var mo: Array = []
		var mn: Array = []
		for p in 3:
			mo.append((old[p] as MultiMeshInstance3D).multimesh)
			mn.append((nat[p] as MultiMeshInstance3D).multimesh)
		_report("model arms (%s)" % fam, list, mo, mn, [], 12, t_old, t_new, _wrist_diff(arms, 2, fam, wrists))


func _test_basic() -> void:
	var arms := _new_arms()
	var list := _arm_list(3, 1.4)
	var old := _mmis(6, true)
	var nat := _mmis(6, true)
	arms._parts.clear()
	for m in nat:
		arms._parts.append(m)
	var t0 := Time.get_ticks_usec()
	var lists: Array = []
	for p in Arms.Part.size():
		lists.append([])
	var colors: Array[Color] = []
	var wrists: Array = []
	for a: Arms.Arm in list:
		wrists.append(arms._draw_arm(a, lists))
		colors.append(a.color)
	for p in 6:
		arms._fill_xforms_colored((old[p] as MultiMeshInstance3D).multimesh, lists[p], colors, 2 if p == Arms.Part.FINGERS else 1, p)
	var t_old := Time.get_ticks_usec() - t0
	var t_new := _native_run(arms, 3, "basic", list)
	var mo: Array = []
	var mn: Array = []
	for p in 6:
		mo.append((old[p] as MultiMeshInstance3D).multimesh)
		mn.append((nat[p] as MultiMeshInstance3D).multimesh)
	_report("basic arms", list, mo, mn, [], 16, t_old, t_new, _wrist_diff(arms, 3, "basic", wrists))


func _rig() -> Dictionary:
	return {"hinge": Vector3(1, 0, 0), "pivot": Vector3(0, 0.3, 0), "shoulder": Vector3(0.05, 0.42, 0.0),
		"elbow": Vector3(0.0, 0.55, -0.55), "grip": Vector3(0.02, 0.4, -1.1), "lengths": [0.56, 0.58],
		"heads": [Vector3(0, 0.3, 0), null, null, Vector3(0.05, 0.4, -1.0), Vector3(-0.05, 0.4, -1.0)],
		"axes": [null, null, null, Vector3(0, 1, 0), Vector3(0, 1, 0)],
		"angles": [null, null, null, 0.5, -0.5], "grip_angles": [null, null, null, 0.3, -0.3]}


func _test_rig() -> void:
	var arms := _new_arms()
	var list := _arm_list(4, 1.9)  # past the rig's reach: stretched
	var rig := _rig()
	for a: Arms.Arm in list:
		a.mode_rig = rig
	var old := _mmis(5)
	var nat := _mmis(5)
	arms._rigs["inserter"] = {"mmis": nat}
	var t0 := Time.get_ticks_usec()
	var lists := [[], [], [], [], []]
	var wrists: Array = []
	for a: Arms.Arm in list:
		wrists.append(arms._draw_rig_arm(a, rig, lists))
	for p in 5:
		arms._fill_xforms((old[p] as MultiMeshInstance3D).multimesh, lists[p])
	var t_old := Time.get_ticks_usec() - t0
	var t_new := _native_run(arms, 1, "inserter", list)
	var mo: Array = []
	var mn: Array = []
	for p in 5:
		mo.append((old[p] as MultiMeshInstance3D).multimesh)
		mn.append((nat[p] as MultiMeshInstance3D).multimesh)
	_report("rig arms", list, mo, mn, [], 12, t_old, t_new, _wrist_diff(arms, 1, "inserter", wrists))
