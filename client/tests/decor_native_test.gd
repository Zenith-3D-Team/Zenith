extends SceneTree
## DecorNative (client/native/belt_sim/src/decor_native.cpp) against the GDScript loops of
## decoratives.gd's _run_job: the same synthetic chunks built both ways, every group's buffer, rising
## count, model buckets, tufts kept flat and edge groups compared (max difference), plus Godot's hash()
## against the native one and the time of each path. Skips (exit 0) when the extension isn't loaded.
##
##   godot --headless --audio-driver Dummy --path client --log-file <abs> -s res://tests/decor_native_test.gd

const Decoratives := preload("res://scripts/world/decoratives.gd")
const NativeLibrary := preload("res://scripts/native_library.gd")

var fails := 0


func _initialize() -> void:
	if not NativeLibrary.ensure() or not ClassDB.class_exists(&"DecorNative"):
		print("decor_native_test: DecorNative not loaded, skipped")
		quit(0)
		return
	var nat: Object = ClassDB.instantiate(&"DecorNative")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	# hash parity
	var bad := 0
	for i in 20000:
		var x := rng.randi_range(-100000, 100000)
		var y := rng.randi_range(-100000, 100000)
		var z := rng.randi_range(0, 40)
		if hash(Vector2i(x, y)) != int(nat.call("hash2", x, y)) or hash(Vector3i(x, y, z)) != int(nat.call("hash3", x, y, z)):
			bad += 1
	_check(bad == 0, "hash() parity (%d of 20000 differ)" % bad)

	Decoratives._sync_packs()
	Decoratives.index()
	var kinds := {}
	kinds["tuft"] = _kind(rng, 3, false, 0.6, false, 0)
	kinds["carpet"] = _kind(rng, 2, false, 0.3, true, 0)
	kinds["flat"] = _kind(rng, 4, false, 0.0, false, 0, 6.0)
	kinds["upright"] = _kind(rng, 2, true, 0.0, false, 0)
	kinds["modelled"] = _kind(rng, 3, false, 0.8, false, 3)
	kinds["modelup"] = _kind(rng, 1, true, 0.0, false, 2)
	var names := {}
	var n := 1
	for k in kinds:
		Decoratives._kind_data[k] = kinds[k]
		names[n] = k
		n += 1
	var max_diff := 0.0
	var gd_us := 0
	var nat_us := 0
	var instances := 0
	for chunk_i in 24:
		var c := Vector2i(rng.randi_range(-30, 30), rng.randi_range(-30, 30))
		var list := []
		for _i in rng.randi_range(500, 4000):
			list.append_array([rng.randi_range(1, 6), rng.randi_range(0, 31), rng.randi_range(0, 31), 0])
		var density := 1.0 if chunk_i % 3 == 0 else 0.7
		var near_masks := chunk_i % 2 == 0
		var job_a := _job(rng, c, list, names, density, near_masks)
		var job_b := _job(rng, c, list, names, density, near_masks)
		rng.seed = 100 + chunk_i  # both jobs got the same masks above? (see _job)
		Decoratives._decor_native = null
		var t0 := Time.get_ticks_usec()
		Decoratives._run_job(job_a)
		gd_us += Time.get_ticks_usec() - t0
		Decoratives._decor_native = nat
		t0 = Time.get_ticks_usec()
		Decoratives._run_job(job_b)
		nat_us += Time.get_ticks_usec() - t0
		Decoratives._decor_native = null
		var d := _compare(job_a, job_b)
		max_diff = maxf(max_diff, d)
		for g: Array in job_a.groups:
			instances += int(g[2])
	print("decor_native_test: %d instances over 24 chunks, GDScript %.2f ms, native %.2f ms, max difference %f" % [instances, gd_us / 1000.0, nat_us / 1000.0, max_diff])
	_check(max_diff == 0.0, "native and GDScript agree (max difference %f)" % max_diff)
	quit(1 if fails > 0 else 0)


func _check(ok: bool, what: String) -> void:
	if ok:
		print("PASS ", what)
	else:
		fails += 1
		print("FAIL ", what)


func _kind(rng: RandomNumberGenerator, variants: int, upright: bool, grass: float, carpet: bool, models: int, big := 1.0) -> Object:
	var d := Decoratives.KindData.new()
	d.upright = upright
	d.lift = 0.016
	d.grass_height = grass
	d.grass_carpet = carpet
	for _v in variants:
		d.uvs.append(Vector4(rng.randf(), rng.randf(), rng.randf(), rng.randf()))
		d.sizes.append(Vector2(rng.randf_range(0.5, 2.0) * big, rng.randf_range(0.5, 2.0) * big))
		d.shifts.append(Vector2(rng.randf_range(-0.5, 0.5), rng.randf_range(-0.5, 0.5)))
	for m in models:
		d.model_paths.append("m%d" % m)
	d.model_scale = 1.3
	d.model_height_scale = 0.9
	d.model_shift = Vector2(0.1, -0.2)
	d.grass_triangles = 40
	return d


func _job(rng: RandomNumberGenerator, c: Vector2i, list: Array, names: Dictionary, density: float, near_masks: bool) -> Object:
	var job := Decoratives.BuildJob.new()
	job.chunk = c
	job.list = list
	job.density = density
	job.names = names
	var s := rng.state
	var r2 := RandomNumberGenerator.new()
	r2.seed = hash(c)
	job.spill_in = PackedInt32Array([c.x * 32 + 2, c.y * 32 + 3, c.x * 32 + 9, c.y * 32 + 6])
	if near_masks:
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var m := PackedInt32Array()
				m.resize(32)
				for i in 32:
					m[i] = r2.randi() & r2.randi() & r2.randi()
				job.near[Vector2i(dx, dy)] = m
	rng.state = s
	return job


## Largest absolute difference over everything a job made; INF for a different shape.
func _compare(a: Object, b: Object) -> float:
	var worst := 0.0
	if a.groups.size() != b.groups.size() or a.edge_groups.size() != b.edge_groups.size() or a.edge != b.edge or a.edge_dirs != b.edge_dirs or a.mask != b.mask:
		print("shape differs: groups %d/%d edge_groups %d/%d edge %d/%d dirs %d/%d" % [a.groups.size(), b.groups.size(), a.edge_groups.size(), b.edge_groups.size(), a.edge.size(), b.edge.size(), a.edge_dirs, b.edge_dirs])
		return INF
	for i in a.groups.size():
		var ga: Array = a.groups[i]
		var gb: Array = b.groups[i]
		if ga[0] != gb[0] or ga[2] != gb[2] or ga[4] != gb[4] or ga.size() != gb.size():
			print("group %d header differs: %s %d %d / %s %d %d" % [i, ga[0], ga[2], ga[4], gb[0], gb[2], gb[4]])
			return INF
		worst = maxf(worst, _arr_diff(ga[1], gb[1]))
		if ga.size() >= 6:
			for k in (ga[5] as Array).size():
				var ba: Array = ga[5][k]
				var bb: Array = gb[5][k]
				if ba[1] != bb[1]:
					return INF
				worst = maxf(worst, _arr_diff(ba[0], bb[0]))
	for i in a.edge_groups.size():
		var ea: Array = a.edge_groups[i]
		var eb: Array = b.edge_groups[i]
		if ea[0] != eb[0] or ea[2] != eb[2]:
			return INF
		worst = maxf(worst, _arr_diff(ea[1], eb[1]))
	return worst


func _arr_diff(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	if a.size() != b.size():
		return INF
	var w := 0.0
	for i in a.size():
		w = maxf(w, absf(a[i] - b[i]))
	return w
