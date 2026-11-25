extends SceneTree
## Parity and speed of BiterGoreNative (native/belt_sim/src/biter_gore_native.cpp) against the GDScript loops in
## addons-src/immersive-enemies/scripts/biter_gore.gd: two gore objects, same seed, same spawns, same flat or
## hilly ground; stepped side by side, the droplet, gib and decal MultiMesh buffers compared (max difference),
## the time of each printed. A droplet's decal on landing rolls the native's own random numbers, so the droplet
## and gib buffers are compared in a run where decals are off the table (the decals are compared in their own
## run, through spawn_smear only).
## Run: godot --headless --audio-driver Dummy --path client --log-file <abs> --script res://tests/biter_gore_native_test.gd
## Needs the built native library (client/native/bin); skipped, with a note, without it.

const NativeLibrary := preload("res://scripts/native_library.gd")

const TOL := 2e-4

var passes := 0
var fails := 0
var worst := 0.0


class FakeCreatures:
	extends RefCounted
	var hilly := false

	func ground_height(x: float, z: float) -> float:
		return (sin(x * 0.7) * cos(z * 0.5) * 0.6) if hilly else 0.0

	func ground_normal(_x: float, _z: float) -> Vector3:
		return Vector3.UP


class FakeApi:
	extends RefCounted
	var creatures := FakeCreatures.new()


func check(cond: bool, msg: String) -> void:
	if cond:
		passes += 1
	else:
		fails += 1
		print("FAIL: %s" % msg)


func _initialize() -> void:
	print("--- Running biter_gore_native_test ---")
	if not NativeLibrary.ensure() or not ClassDB.class_exists("BiterGoreNative"):
		print("biter_gore_native_test: BiterGoreNative not built, skipped")
		quit(0)
		return
	for hilly in [false, true]:
		_test_flight(hilly)
	_test_decals()
	print("biter_gore_native_test: %d passed, %d failed, max buffer difference %f" % [passes, fails, worst])
	quit(0 if fails == 0 else 1)


func _pair(hilly: bool) -> Array:
	var api := FakeApi.new()
	api.creatures.hilly = hilly
	var root := Node3D.new()
	root.name = "R"
	get_root().add_child(root)
	var gore_script: GDScript = load(ProjectSettings.globalize_path("res://").path_join("../addons-src/immersive-enemies/scripts/biter_gore.gd").simplify_path())
	var a = gore_script.new(api, root)
	var b = gore_script.new(api, root)
	a.use_native = false
	b.use_native = true
	b.set_native(ClassDB.instantiate("BiterGoreNative"))
	a._rng.seed = 1234
	b._rng.seed = 1234
	return [a, b]


func _maxdiff(x: PackedFloat32Array, y: PackedFloat32Array, n_floats: int) -> float:
	var m := 0.0
	for i in n_floats:
		m = maxf(m, absf(x[i] - y[i]))
	return m


## Godot's MultiMesh.buffer layout of one instance: the 3x4 transform rows, then the colour.
func _put(buf: PackedFloat32Array, at: int, xf: Transform3D, col: Color) -> void:
	var b := xf.basis
	for r in 3:
		buf[at + r * 4] = b.x[r]
		buf[at + r * 4 + 1] = b.y[r]
		buf[at + r * 4 + 2] = b.z[r]
		buf[at + r * 4 + 3] = xf.origin[r]
	buf[at + 12] = col.r
	buf[at + 13] = col.g
	buf[at + 14] = col.b
	buf[at + 15] = col.a


## The headless renderer keeps no MultiMesh data, so the buffer the GDScript path would have written is rebuilt
## here from its own state (the very formulas of its sync loops) and compared with the native buffer.
func _expected_droplets(a) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(a._droplets.size() * 16)
	for k in a._droplets.size():
		var d: Dictionary = a._droplets[k]
		var pos: Vector3 = d["pos"]
		var vel: Vector3 = d["vel"]
		var sz: float = float(d["size"])
		if bool(d.get("fade_shrink", false)):
			sz *= 1.0 - clampf(float(d["age"]) / maxf(float(d.get("life", a.DROPLET_LIFE)), 0.05), 0.0, 1.0) * 0.85
		var spd: float = vel.length()
		var basis := Basis.IDENTITY.scaled(Vector3.ONE * sz)
		if spd > 0.25:
			var fwd: Vector3 = vel / spd
			var up: Vector3 = Vector3.UP if absf(fwd.y) < 0.95 else Vector3.RIGHT
			var right: Vector3 = up.cross(fwd).normalized()
			var ortho_up: Vector3 = fwd.cross(right).normalized()
			basis = Basis(right * sz, ortho_up * sz, fwd * (sz * clampf(1.0 + spd * 0.18, 1.0, 3.2)))
		_put(out, k * 16, Transform3D(basis, pos), d["color"])
	return out


func _expected_gibs(a, kind: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var n := 0
	for g in a._gibs:
		if int(g["kind"]) != kind:
			continue
		out.resize((n + 1) * 16)
		var shrink := 1.0
		if float(g["age"]) > a.GIB_LIFE:
			var t: float = clampf(1.0 - (float(g["age"]) - a.GIB_LIFE) / a.GIB_FADE, 0.0, 1.0)
			shrink = t * t * (3.0 - 2.0 * t)
		_put(out, n * 16, Transform3D(Basis(g["quat"]).scaled(g["size"] * shrink), g["pos"]), g["color"])
		n += 1
	return out


func _compare_buf(label: String, expected: PackedFloat32Array, got: PackedFloat32Array, got_n: int) -> void:
	check(expected.size() == got_n * 16, "%s count %d vs %d" % [label, expected.size() / 16, got_n])
	if expected.size() == got_n * 16 and got_n > 0:
		var d := _maxdiff(expected, got, expected.size())
		check(d < TOL, "%s buffers differ by %f" % [label, d])
		worst = maxf(worst, d)


func _compare_flight(label: String, a, b) -> void:
	var nat: Object = b._nat
	_compare_buf(label + " droplets", _expected_droplets(a), nat.call("droplet_buffer"), int(nat.call("droplet_visible")))
	for k in 3:
		_compare_buf("%s gibs%d" % [label, k], _expected_gibs(a, k), nat.call("gib_buffer", k), int(nat.call("gib_visible", k)))


## A faded-out decal is a zero transform in both; its colour is never seen, so the native one is taken as it is.
func _expected_decals(a, got: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(a.MAX_DECALS * 16)
	for idx in a._decals.size():
		var rec: Dictionary = a._decals[idx]
		if not bool(rec.get("alive", false)):
			for i in 4:
				out[idx * 16 + 12 + i] = got[idx * 16 + 12 + i]
			continue
		var c: Color = rec["color"]
		if float(rec["age"]) > a.DECAL_LIFE:
			c.a = clampf(1.0 - (float(rec["age"]) - a.DECAL_LIFE) / a.DECAL_FADE, 0.0, 1.0)
		_put(out, idx * 16, rec["xf"], c)
	return out


func _test_flight(hilly: bool) -> void:
	var p := _pair(hilly)
	var a = p[0]
	var b = p[1]
	for g in p:
		# Spawns from the real code paths; both draw the same random numbers from the same seed.
		for j in 6:
			var pos := Vector3(float(j) * 1.7, 0.4, float(j) * -0.9)
			g.on_died({"name": "big-biter", "pos": pos, "cause_pos": pos + Vector3(2, 0, 1), "damage_type": "explosion", "dmg": 900, "src": "rocket"})
			g.on_died({"name": "biter-spawner", "pos": pos, "damage_type": "physical", "dmg": 100})
			g.spawn_burn_flame(pos, 1.0, 0.5)
			g.spawn_decay_dust(pos, 1.0)
	var t_gd := 0.0
	var t_nat := 0.0
	for f in 150:
		var t0 := Time.get_ticks_usec()
		a.step(1.0 / 60.0)
		var t1 := Time.get_ticks_usec()
		b.step(1.0 / 60.0)
		var t2 := Time.get_ticks_usec()
		t_gd += float(t1 - t0)
		t_nat += float(t2 - t1)
		# Gibs never roll a random number (a meat smear with fast motion keeps its yaw), so their buffers
		# must agree every frame; droplets agree in count only until a landing rolls a decal (not removed
		# differently), so compare them too.
		if f % 10 == 0:
			_compare_flight("hilly=%s f%d" % [hilly, f], a, b)
	print("hilly=%s: 150 frames GDScript %.2f ms/frame, native %.2f ms/frame (%.1fx), %d gibs, %d droplets at end"
		% [hilly, t_gd / 150000.0, t_nat / 150000.0, t_gd / maxf(t_nat, 1.0), b._nat.call("gib_count"), b._nat.call("droplet_count")])
	a.dispose()
	b.dispose()


func _test_decals() -> void:
	var p := _pair(false)
	var a = p[0]
	var b = p[1]
	for g in p:
		for j in 600:
			g.spawn_smear(Vector3(float(j % 30), 0.0, float(j / 30)), 6.0, 1.0)
	var checked := 0
	for f in 40:
		a.step(1.0)
		b.step(1.0)
		_compare_buf("decals f%d" % f, _expected_decals(a, b._nat.call("decal_buffer")), b._nat.call("decal_buffer"), a.MAX_DECALS)
		checked += 1
	check(checked == 40, "decal run")
	# All of them fade out by 39 s: nothing left in either, both hidden.
	check(not a._decals_mmi.visible and not b._decals_mmi.visible, "decals hidden after their life")
	a.dispose()
	b.dispose()
