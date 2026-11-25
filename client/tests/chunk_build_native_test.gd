extends SceneTree
## ChunkBuildNative (client/native/belt_sim) against chunk_view.gd's GDScript ChunkPrepJob loops:
## pack_buffer and box_bounds on the same random inputs; prints the max difference and each one's time.
##   godot --headless --audio-driver Dummy --path client -s res://tests/chunk_build_native_test.gd
## Skips (exit 0) when the extension isn't loaded.

const ChunkView := preload("res://scripts/world/chunk_view.gd")
const NativeLibrary := preload("res://scripts/native_library.gd")


func _init() -> void:
	if not NativeLibrary.ensure() or not ClassDB.class_exists(&"ChunkBuildNative"):
		print("chunk_build_native_test: ChunkBuildNative not loaded, skipped")
		quit(0)
		return
	var nat: Object = ClassDB.instantiate(&"ChunkBuildNative")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var fails := 0
	for n in [1, 40, 500, 5000]:
		var xf: Array = []
		var cols: Array = []
		for i in n:
			var b := Basis(Vector3.UP, rng.randf() * TAU) * Basis.from_scale(Vector3(rng.randf_range(0.5, 2.0), rng.randf_range(0.5, 2.0), rng.randf_range(0.5, 2.0)))
			xf.append(Transform3D(b, Vector3(rng.randf_range(-500, 500), rng.randf_range(0, 4), rng.randf_range(-500, 500))))
			cols.append(Color(rng.randf(), rng.randf(), rng.randf(), rng.randf()))
		var box := AABB(Vector3(-1.5, 0, -1.0), Vector3(3.0, 2.5, 2.0))
		for combo in [[false, false, false], [true, false, false], [false, true, false], [true, true, false], [false, false, true], [true, true, true]]:
			var c: Array = cols if combo[0] else []
			var t0 := Time.get_ticks_usec()
			var g: PackedFloat32Array = ChunkView.ChunkPrepJob.pack_buffer_gd(xf, c, combo[1], combo[2])
			var t1 := Time.get_ticks_usec()
			var r: PackedFloat32Array = nat.pack_buffer(xf, c, combo[1], combo[2])
			var t2 := Time.get_ticks_usec()
			var d := 0.0
			if g.size() != r.size():
				d = INF
			else:
				for i in g.size():
					d = maxf(d, absf(g[i] - r[i]))
			if d != 0.0:
				fails += 1
			if combo == [true, true, false]:
				print("pack n=%d colors+custom: gd %d us, native %d us, max diff %s" % [n, t1 - t0, t2 - t1, d])
			elif d != 0.0:
				print("pack n=%d %s: max diff %s" % [n, combo, d])
		var t3 := Time.get_ticks_usec()
		var gb: AABB = ChunkView.ChunkPrepJob.box_bounds_gd(box, xf)
		var t4 := Time.get_ticks_usec()
		var nb: AABB = nat.box_bounds(box, xf)
		var t5 := Time.get_ticks_usec()
		var bd := maxf(absf(gb.position.x - nb.position.x), maxf(absf(gb.position.y - nb.position.y), absf(gb.position.z - nb.position.z)))
		bd = maxf(bd, maxf(absf(gb.size.x - nb.size.x), maxf(absf(gb.size.y - nb.size.y), absf(gb.size.z - nb.size.z))))
		print("bounds n=%d: gd %d us, native %d us, max diff %s" % [n, t4 - t3, t5 - t4, bd])
		if bd != 0.0:
			fails += 1
	# the empty case
	if nat.pack_buffer([], [], false, false).size() != 0:
		fails += 1
	print("chunk_build_native_test: %d fails" % fails)
	quit(1 if fails > 0 else 0)
