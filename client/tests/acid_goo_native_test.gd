extends SceneTree
## AcidGooNative (client/native/belt_sim/src/acid_goo_native.cpp) against the GDScript loops of the Immersive
## Enemies add-on's acid_goo.gd: the same particles put into both, stepped the same frames, every group's
## buffer compared (max difference), then both timed at the caps. The headless renderer keeps no MultiMesh data, so the
## script path's state (its own dictionaries, stepped by its own loops) is turned into the rows its draw code writes
## (the formulas copied from _step_*/_sync_*) and compared with the native buffers. Skips (exit 0) when the extension
## isn't loaded.
##
##   godot --headless --audio-driver Dummy --path client --log-file <abs> -s res://tests/acid_goo_native_test.gd

const NativeLibrary := preload("res://scripts/native_library.gd")

var fails := 0


class Creatures:
	extends RefCounted

	func ground_height(_x: float, _z: float) -> float:
		return 0.0

	func ground_normal(_x: float, _z: float) -> Vector3:
		return Vector3.UP


class Api:
	extends RefCounted
	var creatures := Creatures.new()


func _initialize() -> void:
	if not NativeLibrary.ensure() or not ClassDB.class_exists(&"AcidGooNative"):
		print("acid_goo_native_test: AcidGooNative not loaded, skipped")
		quit(0)
		return
	var AcidGoo: GDScript = load(ProjectSettings.globalize_path("res://").path_join("../addons-src/immersive-enemies/scripts/acid_goo.gd").simplify_path())
	var root := Node3D.new()
	get_root().add_child(root)
	var api := Api.new()
	var gd = AcidGoo.new(api, root)
	gd.use_native = false
	var nt = AcidGoo.new(api, root)
	nt.set_native(ClassDB.instantiate(&"AcidGooNative"))
	nt._native_on()  # switches the script over (clearing nothing yet)
	_fill(gd, nt, 40, 100, 6, 30, 20, false)
	for _f in 20:
		gd.step(0.016)
		nt.step(0.016)
	var names := ["globs", "drops", "rings", "mist", "pools"]
	var max_d := 0.0
	var counts_ok := true
	var native_counts: PackedInt32Array = nt._n.call("counts")
	for g in 5:
		var rows: Array = _expected(gd, g)
		if rows.size() != native_counts[g]:
			counts_ok = false
			print("  count differs in ", names[g], ": ", rows.size(), " vs ", native_counts[g])
			continue
		var d := _diff(rows, nt._n.call("buffer", g), g == 0)
		print("  ", names[g], ": ", rows.size(), " instances, max diff ", d)
		max_d = maxf(max_d, d)
	_check(counts_ok, "instance counts match")
	_check(max_d < 1e-4, "buffers match (max diff %s)" % max_d)

	# A pool ended, then removed after its fade out; a ring and a mist wisp dying, in both.
	for _f in 80:
		gd.step(0.016)
		nt.step(0.016)
	var sz2: PackedInt32Array = nt._n.call("sizes")
	var exp_sz := [gd._globs.size(), gd._drops.size(), gd._rings.size(), gd._mist.size(), gd._pools.size()]
	_check(sz2[0] == exp_sz[0] and sz2[1] == exp_sz[1] and sz2[2] == exp_sz[2] and sz2[3] == exp_sz[3] and sz2[4] == exp_sz[4],
		"particles die and pools fade out alike %s vs %s" % [sz2, exp_sz])

	# Landing and events: a glob that lands gives a splash (drops, a ring, mist) through the script.
	nt.clear()
	nt._n.call("add_glob", Vector3(0, 1, 0), Vector3(3, 0, 0), 0.2, 0.0, 1.0, 1.0, 1.0, true, 0.5, 0.01, Color(0.3, 0.8, 0.1, 1))
	for _f in 40:
		nt.step(0.016)
	var sz: PackedInt32Array = nt._n.call("sizes")
	_check(sz[0] == 0 and (sz[1] > 0 or sz[3] > 0 or sz[2] > 0), "a landed glob spawned its splash %s" % [sz])

	# Timing at the caps.
	gd.clear()
	nt.clear()
	_fill(gd, nt, 160, 320, 32, 96, 96, true)
	var t_gd := _time(gd)
	var t_nt := _time(nt)
	print("acid_goo step at caps: GDScript %.3f ms, native %.3f ms" % [t_gd, t_nt])
	_check(t_nt < t_gd, "native step is faster")

	print("acid_goo_native_test: %d fails" % fails)
	quit(1 if fails > 0 else 0)


func _time(o) -> float:
	for _i in 5:
		o.step(0.016)
	var t0 := Time.get_ticks_usec()
	for _i in 60:
		o.step(0.016)
	return float(Time.get_ticks_usec() - t0) / 60000.0


func _fill(gd, nt, n_g: int, n_d: int, n_r: int, n_m: int, n_p: int, long_lived: bool) -> void:
	var r := RandomNumberGenerator.new()
	r.seed = 11
	var hi := 100000.0 if long_lived else 0.0
	for i in n_g:
		var from := Vector3(r.randf_range(-20, 20), r.randf_range(0.5, 3), r.randf_range(-20, 20))
		var to := Vector3(r.randf_range(-20, 20), 0.0, r.randf_range(-20, 20))
		var dur := 3.0 + (1000.0 if long_lived else 0.0)
		var age := r.randf_range(-0.1, 0.5)
		var arc := r.randf_range(1.0, 3.0)
		var sc := r.randf_range(0.5, 1.6)
		var prim := i % 3 == 0
		var sd := r.randf_range(0.0, TAU)
		var col := Color(r.randf(), r.randf(), r.randf(), r.randf_range(0.6, 1.0))
		gd._globs.append({"from": from, "to": to, "dur": dur, "age": age, "arc_h": arc, "scale": sc, "tier_scale": 1.0,
			"primary": prim, "seed": sd, "trail_cd": 1000.0, "color": col})
		nt._n.call("add_glob", from, to, dur, age, arc, sc, 1.0, prim, sd, 1000.0, col)
	for i in n_d:
		var p := Vector3(r.randf_range(-20, 20), r.randf_range(4, 8) + hi, r.randf_range(-20, 20))
		var v := Vector3(r.randf_range(-3, 3), r.randf_range(-2, 6), r.randf_range(-3, 3))
		var s := r.randf_range(0.05, 0.2)
		var life := 2.0 + hi
		var col := Color(r.randf(), r.randf(), r.randf(), r.randf_range(0.6, 1.0))
		gd._drops.append({"pos": p, "vel": v, "size": s, "age": 0.0, "life": life, "color": col, "make_mist": false})
		nt._n.call("add_drop", p, v, s, life, col, false)
	for i in n_r:
		var p := Vector3(r.randf_range(-20, 20), 0.04, r.randf_range(-20, 20))
		var b: Basis = gd._pool_basis(Vector3.UP, r.randf_range(0, TAU), 1.0, 1.0)
		var s := r.randf_range(0.4, 1.1)
		var life := 0.6 + hi
		var col := Color(r.randf(), r.randf(), r.randf(), 1.0)
		gd._rings.append({"pos": p, "basis": b, "scale": s, "age": 0.0, "life": life, "color": col})
		nt._n.call("add_ring", p, b, s, life, col)
	for i in n_m:
		var p := Vector3(r.randf_range(-20, 20), r.randf_range(0, 2), r.randf_range(-20, 20))
		var v := Vector3(r.randf_range(-0.2, 0.2), r.randf_range(0.3, 0.7), r.randf_range(-0.2, 0.2))
		var s := r.randf_range(0.2, 0.8)
		var life := 1.0 + hi
		var col := Color(r.randf(), r.randf(), r.randf(), r.randf_range(0.2, 0.5))
		var yaw := r.randf_range(0, TAU)
		var spin := r.randf_range(-1.2, 1.2)
		gd._mist.append({"pos": p, "vel": v, "size": s, "age": 0.0, "life": life, "color": col, "base_alpha": col.a, "yaw": yaw, "spin": spin})
		nt._n.call("add_mist", p, v, s, life, col, yaw, spin)
	for i in n_p:
		var p := Vector3(r.randf_range(-20, 20), 0.03, r.randf_range(-20, 20))
		var b: Basis = gd._pool_basis(Vector3.UP, r.randf_range(0, TAU), 1.5, 1.2)
		var rad := r.randf_range(0.8, 2.5)
		var sd := r.randf_range(1, 97)
		var pulse := r.randf_range(0.85, 1.25)
		gd._pools[i + 1] = {"id": i + 1, "pos": p, "basis": b, "radius": rad, "age": 0.0, "fade_in": 0.25, "fade_out": 0.5,
			"gone": -1.0, "seed": sd, "pulse": pulse, "bubble_cd": 1000.0, "mist_cd": 1000.0}
		nt._n.call("set_pool", i + 1, p, b, rad, 0.25, 0.5, sd, pulse, 1000.0, 1000.0)
	if not long_lived and n_p > 2:
		gd._pools[1]["gone"] = 0.0
		nt._n.call("end_pool", 1)


func _row(basis: Basis, pos: Vector3, c: Array) -> PackedFloat32Array:
	return PackedFloat32Array([basis.x.x, basis.y.x, basis.z.x, pos.x, basis.x.y, basis.y.y, basis.z.y, pos.y,
		basis.x.z, basis.y.z, basis.z.z, pos.z, c[0], c[1], c[2], c[3]])


func _col(c: Color, a: float) -> Array:
	return [c.r, c.g, c.b, a]


## The rows the script's draw code writes for a group, from its state.
func _expected(gd, grp: int) -> Array:
	var out: Array = []
	if grp == 0:
		for g in gd._globs:
			var age: float = g["age"]
			if age < 0.0:
				continue
			var dur: float = maxf(float(g["dur"]), 0.05)
			var t: float = age / dur
			var from: Vector3 = g["from"]
			var to: Vector3 = g["to"]
			var arc_h: float = g["arc_h"]
			var pos: Vector3 = from.lerp(to, t)
			pos.y += arc_h * 4.0 * t * (1.0 - t)
			var vel: Vector3 = (to - from) / dur
			vel.y += arc_h * 4.0 * (1.0 - 2.0 * t) / dur
			var spd: float = vel.length()
			var fwd: Vector3 = vel / spd if spd > 0.05 else Vector3.FORWARD
			var up_ref: Vector3 = Vector3.UP if absf(fwd.y) < 0.94 else Vector3.RIGHT
			var right: Vector3 = up_ref.cross(fwd).normalized()
			var up: Vector3 = fwd.cross(right).normalized()
			var sc: float = g["scale"]
			var sd: float = g["seed"]
			var stretch: float = clampf(1.12 + spd * 0.018, 1.12, 1.38)
			var squash: float = 1.0 / sqrt(stretch)
			var wob_x: float = 1.0 + 0.14 * sin(age * 16.0 + sd)
			var wob_y: float = 1.0 + 0.14 * cos(age * 14.0 + sd * 1.7)
			var c: Color = g["color"]
			out.append(_row(Basis(right * (sc * squash * wob_x * 0.62), up * (sc * squash * wob_y * 0.62), fwd * (sc * stretch * 0.68)), pos, _col(c, c.a)))
	elif grp == 1:
		for d in gd._drops:
			var sz: float = d["size"]
			var life_t: float = clampf(float(d["age"]) / maxf(float(d["life"]), 0.05), 0.0, 1.0)
			sz *= (1.0 - life_t * 0.45)
			var vel: Vector3 = d["vel"]
			var spd: float = vel.length()
			var basis := Basis.IDENTITY.scaled(Vector3.ONE * sz)
			if spd > 0.25:
				var fwd: Vector3 = vel / spd
				var up_ref: Vector3 = Vector3.UP if absf(fwd.y) < 0.94 else Vector3.RIGHT
				var right: Vector3 = up_ref.cross(fwd).normalized()
				var up: Vector3 = fwd.cross(right).normalized()
				var stretch: float = clampf(1.0 + spd * 0.14, 1.0, 2.5)
				basis = Basis(right * sz, up * sz, fwd * (sz * stretch))
			var c: Color = d["color"]
			out.append(_row(basis, d["pos"], _col(c, c.a)))
	elif grp == 2:
		for r in gd._rings:
			var t: float = clampf(float(r["age"]) / maxf(float(r["life"]), 0.05), 0.0, 1.0)
			var sc: float = r["scale"]
			var xz_sc: float = sc * lerpf(0.32, 1.32, 1.0 - (1.0 - t) * (1.0 - t))
			var y_sc: float = sc * maxf(0.05, sin(clampf(t / 0.85, 0.0, 1.0) * PI)) * 0.85
			var b: Basis = r["basis"]
			var c: Color = r["color"]
			out.append(_row(Basis(b.x * xz_sc, b.y * y_sc, b.z * xz_sc), r["pos"], _col(c, clampf(0.78 * (1.0 - t * t), 0.0, 0.85))))
	elif grp == 3:
		for m in gd._mist:
			var t: float = clampf(float(m["age"]) / maxf(float(m["life"]), 0.05), 0.0, 1.0)
			var sz: float = float(m["size"]) * lerpf(0.60, 1.85, t)
			var fade: float = smoothstep(0.0, 0.16, t) * (1.0 - t) * (1.0 - t)
			var c: Color = m["color"]
			out.append(_row(Basis(Vector3.UP, float(m["yaw"])).scaled(Vector3(sz, sz * 0.72, sz)), m["pos"], _col(c, float(m["base_alpha"]) * fade)))
	else:
		for k in gd._pools:
			var p: Dictionary = gd._pools[k]
			var fade_in: float = maxf(float(p["fade_in"]), 0.18)
			var fi: float = clampf(float(p["age"]) / fade_in, 0.0, 1.0)
			var spread: float = lerpf(0.25, 1.0, 1.0 - (1.0 - fi) * (1.0 - fi))
			var alpha: float = clampf(fi / 0.35, 0.0, 1.0)
			var gone: float = p["gone"]
			if gone >= 0.0:
				var fo: float = clampf(1.0 - gone / maxf(float(p["fade_out"]), 0.05), 0.0, 1.0)
				alpha *= fo
				spread *= lerpf(0.72, 1.0, fo)
			var b: Basis = p["basis"]
			out.append(_row(Basis(b.x * spread, b.y, b.z * spread), p["pos"], [p["seed"], alpha, spread, p["pulse"]]))
	return out


func _diff(rows_a: Array, buf: PackedFloat32Array, sort_rows: bool) -> float:
	var rows_b: Array = []
	for i in rows_a.size():
		rows_b.append(buf.slice(i * 16, i * 16 + 16))
	if sort_rows:
		var f := func(x: PackedFloat32Array, y: PackedFloat32Array) -> bool: return x[3] < y[3]
		rows_a.sort_custom(f)
		rows_b.sort_custom(f)
	var m := 0.0
	for i in rows_a.size():
		for k in 16:
			m = maxf(m, absf(float(rows_a[i][k]) - float(rows_b[i][k])))
	return m


func _check(ok: bool, what: String) -> void:
	if ok:
		print("ok   ", what)
	else:
		print("FAIL ", what)
		fails += 1
