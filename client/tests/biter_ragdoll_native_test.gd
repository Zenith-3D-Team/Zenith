extends SceneTree
## Parity and speed of BiterRagdollNative (native/belt_sim/src/biter_ragdoll_native.cpp) against the
## Immersive Enemies add-on's GDScript (addons-src/immersive-enemies/scripts/biter_ragdoll.gd): the limb
## springs (_step_limbs) and the pairwise separation, stepped from the same seed, compared (max difference),
## the time of each printed.
## Run: godot --headless --audio-driver Dummy --path client --log-file <abs> --script res://tests/biter_ragdoll_native_test.gd
## Needs the built native library (client/native/bin); skipped, with a note, without it.

const NativeLibrary := preload("res://scripts/native_library.gd")
var Ragdoll: GDScript

const BODIES := 32
const STEPS := 240
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
	print("--- Running biter_ragdoll_native_test ---")
	if not NativeLibrary.ensure() or not ClassDB.class_exists("BiterRagdollNative"):
		print("biter_ragdoll_native_test: BiterRagdollNative not built, skipped")
		quit(0)
		return
	var src := FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://") + "../addons-src/immersive-enemies/scripts/biter_ragdoll.gd")
	Ragdoll = GDScript.new()
	Ragdoll.source_code = src
	check(Ragdoll.reload() == OK, "add-on script compiles")
	_test_limbs()
	_test_separate()
	print("biter_ragdoll_native_test: %d passed, %d failed" % [passes, fails])
	quit(1 if fails > 0 else 0)


func _body(rng: RandomNumberGenerator, limb_count: int) -> Dictionary:
	var b := {"limb_count": limb_count}
	for k in ["swing", "swing_v", "lift", "lift_v", "knee", "knee_v", "twists", "twists_v"]:
		var a := PackedFloat32Array()
		a.resize(limb_count)
		for i in limb_count:
			a[i] = rng.randf_range(-0.4, 0.4) * (6.0 if k.ends_with("_v") else 1.0)
		b[k] = a
	var sev := PackedByteArray()
	sev.resize(limb_count)
	for i in limb_count:
		sev[i] = 1 if rng.randf() < 0.15 else 0
		if sev[i] != 0:
			b["twists"][i] = 100.0  # the game sets the sentinel when a limb is severed
	b["severed"] = sev
	var limbs := PackedVector3Array()
	limbs.resize(limb_count)
	for i in limb_count:
		limbs[i] = Vector3(b["swing"][i], b["lift"][i], b["knee"][i])
	b["limbs"] = limbs
	return b


func _copy_body(b: Dictionary) -> Dictionary:
	return b.duplicate(true)


func _test_limbs() -> void:
	var nat: Object = ClassDB.instantiate("BiterRagdollNative")
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var ra = Ragdoll.new(null, Node3D.new())
	ra.use_native = false
	var rb = Ragdoll.new(null, Node3D.new())
	var script_bodies: Array = []
	var native_bodies: Array = []
	var inputs: Array = []
	for n in BODIES:
		var b := _body(rng, 6 if n % 2 == 0 else 12)
		script_bodies.append(_copy_body(b))
		native_bodies.append(_copy_body(b))
	for s in STEPS:
		var q := Quaternion(Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized(), rng.randf_range(0.0, 3.0))
		inputs.append([
			Vector3(rng.randf_range(-8, 8), rng.randf_range(-8, 8), rng.randf_range(-8, 8)),
			Vector3(rng.randf_range(-6, 6), rng.randf_range(-6, 6), rng.randf_range(-6, 6)),
			q,
			Vector3(rng.randf_range(-0.3, 0.3), 1.0, rng.randf_range(-0.3, 0.3)).normalized(),
			rng.randf() < 0.5,
			rng.randf_range(0.0, 6.0) if rng.randf() < 0.2 else 0.0,
		])
	var dt := 1.0 / 60.0
	var t0 := Time.get_ticks_usec()
	for s in STEPS:
		var inp: Array = inputs[s]
		for b in script_bodies:
			ra._step_limbs(b, dt, inp[0], inp[1], inp[2], inp[3], inp[4], inp[5])
	var t_script := Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	for s in STEPS:
		var inp: Array = inputs[s]
		for b in native_bodies:
			rb._step_limbs_native(nat, b, dt, inp[0], inp[1], inp[2], inp[3], inp[4], inp[5])
	var t_native := Time.get_ticks_usec() - t0
	var max_d := 0.0
	for n in BODIES:
		var sl: PackedVector3Array = script_bodies[n]["limbs"]
		var nl: PackedVector3Array = native_bodies[n]["limbs"]
		var st: PackedFloat32Array = script_bodies[n]["twists"]
		var nt: PackedFloat32Array = native_bodies[n]["twists"]
		check(sl.size() == nl.size() and st.size() == nt.size(), "sizes body %d" % n)
		for i in sl.size():
			max_d = maxf(max_d, (sl[i] - nl[i]).length())
			max_d = maxf(max_d, absf(st[i] - nt[i]))
	print("limbs: %d bodies x %d steps, max diff %.6f, script %.2f ms, native %.2f ms (%.1fx)" % [BODIES, STEPS, max_d, t_script / 1000.0, t_native / 1000.0, float(t_script) / maxf(t_native, 1.0)])
	check(max_d < TOL, "limb states match (max diff %.6f)" % max_d)


func _test_separate() -> void:
	var nat: Object = ClassDB.instantiate("BiterRagdollNative")
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var ra = Ragdoll.new(null, Node3D.new())
	ra.use_native = false
	var rb = Ragdoll.new(null, Node3D.new())
	var a_bodies: Array = []
	var b_bodies: Array = []
	for n in BODIES:
		var b := {
			"pos": Vector3(rng.randf_range(0, 6), rng.randf_range(0, 1), rng.randf_range(0, 6)),
			"vel": Vector3(rng.randf_range(-2, 2), rng.randf_range(-2, 2), rng.randf_range(-2, 2)),
			"radius": rng.randf_range(0.3, 1.0),
		}
		a_bodies.append(b)
		b_bodies.append(b.duplicate(true))
	ra._active = a_bodies
	rb._active = b_bodies
	var dt := 1.0 / 60.0
	var t0 := Time.get_ticks_usec()
	for s in 60:
		ra._separate_script(BODIES, dt)
	var t_script := Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	for s in 60:
		rb._separate_native(nat, BODIES, dt)
	var t_native := Time.get_ticks_usec() - t0
	var max_d := 0.0
	for n in BODIES:
		max_d = maxf(max_d, ((a_bodies[n]["pos"] as Vector3) - (b_bodies[n]["pos"] as Vector3)).length())
		max_d = maxf(max_d, ((a_bodies[n]["vel"] as Vector3) - (b_bodies[n]["vel"] as Vector3)).length())
	print("separate: %d bodies x 60 steps, max diff %.6f, script %.2f ms, native %.2f ms (%.1fx)" % [BODIES, max_d, t_script / 1000.0, t_native / 1000.0, float(t_script) / maxf(t_native, 1.0)])
	check(max_d < 1e-3, "separation matches (max diff %.6f)" % max_d)
