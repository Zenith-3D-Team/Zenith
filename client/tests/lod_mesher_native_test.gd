extends SceneTree
## Parity of LodMesher's C++ twin (LodMesherNative) with the GDScript path: the same random sections
## (terrain with water/lava/void, buildings, ore, trees, poles, cliffs, every detail tier) built both
## ways; the arrays must match (max difference printed) and the times of each are printed.
##   godot --headless --audio-driver Dummy --path client --log-file <abs>/godot.log -s res://tests/lod_mesher_native_test.gd

const NativeLibrary := preload("res://scripts/native_library.gd")
const LodMesher := preload("res://scripts/world/lod_mesher.gd")
const FarChunks := preload("res://scripts/world/far_chunks.gd")

class Pal extends RefCounted:
	var tile_colors := PackedColorArray()
	var tile_kind := PackedByteArray()
	var tile_rough := PackedFloat32Array()
	var ent_top_colors := PackedColorArray()
	var ent_side_colors := PackedColorArray()
	var ent_heights := PackedFloat32Array()
	var ent_metal := PackedFloat32Array()
	var ent_rough := PackedFloat32Array()
	var ent_cat := PackedByteArray()
	var ent_glow := PackedByteArray()
	var ent_seat := PackedByteArray()

var fails := 0


func _init() -> void:
	if not NativeLibrary.ensure() or not ClassDB.class_exists("LodMesherNative"):
		print("FAIL: LodMesherNative not loaded")
		quit(1)
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var pal := Pal.new()
	for i in 8:
		pal.tile_colors.append(Color(rng.randf(), rng.randf(), rng.randf()))
		pal.tile_rough.append(rng.randf())
	pal.tile_kind = PackedByteArray([0, 0, 0, 1, 2, 3, 0, 0])
	var np := 40
	for i in np:
		pal.ent_top_colors.append(Color(rng.randf(), rng.randf(), rng.randf()))
		pal.ent_side_colors.append(Color(rng.randf(), rng.randf(), rng.randf()))
		pal.ent_heights.append(rng.randf_range(0.3, 6.0))
		pal.ent_metal.append(rng.randf())
		pal.ent_rough.append(rng.randf())
		pal.ent_cat.append(i % 7 if i > 0 else 0)
		pal.ent_glow.append(rng.randi() % 4)
		pal.ent_seat.append(1 if i % 11 == 3 else 0)
	var total_gd := 0
	var total_nat := 0
	var maxdiff := 0.0
	var cases := 0
	for tier in 4:
		for trial in 3:
			var n: int = [24, 64, 128][trial]
			var m := LodMesher.new()
			m.palette = pal
			m.grid_n = n
			m.cell_tiles = [4.0, 8.0, 16.0][trial]
			m.section_origin = Vector2(rng.randf_range(-3000, 3000), rng.randf_range(-3000, 3000))
			m.detail_tier = tier
			m.max_quad_tiles = INF if trial != 1 else 5.0 * m.cell_tiles
			m.keep_arrays = true
			var tiles := PackedInt32Array()
			var protos := PackedInt32Array()
			var flags := PackedByteArray()
			tiles.resize(n * n)
			protos.resize(n * n)
			flags.resize(n * n)
			# blobby: runs of equal tiles/protos so the greedy merges do work
			for i in n * n:
				var t: int = (i / 5 + (i / n) / 3) % 9
				tiles[i] = -1 if t == 8 else t
				var r := rng.randf()
				protos[i] = 0 if r < 0.5 else (((i / 3 + (i / n) / 2) % (np - 1)) + 1 if r < 0.9 else rng.randi() % (np + 3))
				flags[i] = rng.randi() % 256
			m.tiles = tiles
			m.protos = protos
			m.flags = flags
			LodMesher._native_mode = 0
			m.run()
			var gd := m.solid_arrays.duplicate()
			var gdw := m.water_arrays.duplicate()
			var t_gd := m.usec
			var tri_gd := m.tri_count
			LodMesher._native_mode = 1
			m.run()
			if m.used_native != 1:
				print("FAIL: native not used")
				fails += 1
			var t_nat := m.usec
			total_gd += t_gd
			total_nat += t_nat
			cases += 1
			if m.tri_count != tri_gd:
				print("FAIL: tris %d vs %d (tier %d n %d)" % [m.tri_count, tri_gd, tier, n])
				fails += 1
			var d := _cmp(gd, m.solid_arrays) if gd.size() > 0 or m.solid_arrays.size() > 0 else 0.0
			var dw := _cmp(gdw, m.water_arrays) if gdw.size() > 0 or m.water_arrays.size() > 0 else 0.0
			maxdiff = maxf(maxdiff, maxf(d, dw))
			print("tier %d n %3d tris %6d  gd %7d us  native %6d us  maxdiff %s" % [tier, n, tri_gd, t_gd, t_nat, maxf(d, dw)])
	_far_merge(rng)
	print("TOTAL %d cases: gdscript %d us, native %d us (x%.1f), max diff %s" % [cases, total_gd, total_nat, float(total_gd) / maxf(1.0, total_nat), maxdiff])
	if maxdiff > 0.0:
		print("FAIL: arrays differ")
		fails += 1
	print("lod_mesher_native_test: %s" % ("OK" if fails == 0 else "%d FAILED" % fails))
	quit(1 if fails > 0 else 0)


## Largest absolute difference between two surfaces' arrays (inf if their sizes or indices differ).
func _cmp(a: Array, b: Array) -> float:
	var worst := 0.0
	for slot in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_COLOR, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_INDEX]:
		if a.size() <= slot or b.size() <= slot:
			continue
		var x: Variant = a[slot]
		var y: Variant = b[slot]
		if x == null and y == null:
			continue
		if x == null or y == null or x.size() != y.size():
			print("  slot %d size mismatch" % slot)
			return INF
		for i in x.size():
			var d := 0.0
			match slot:
				Mesh.ARRAY_VERTEX:
					d = maxf(maxf(absf(x[i].x - y[i].x), absf(x[i].y - y[i].y)), absf(x[i].z - y[i].z))
				Mesh.ARRAY_COLOR:
					d = maxf(maxf(absf(x[i].r - y[i].r), absf(x[i].g - y[i].g)), maxf(absf(x[i].b - y[i].b), absf(x[i].a - y[i].a)))
				Mesh.ARRAY_TEX_UV:
					d = maxf(absf(x[i].x - y[i].x), absf(x[i].y - y[i].y))
				_:
					d = absf(float(x[i] - y[i]))
			worst = maxf(worst, d)
	return worst


func _rand_bake(rng: RandomNumberGenerator, with_crown: bool, with_coarse: bool) -> Object:
	var b: Object = FarChunks.Bake.new()
	var nv := 30 + rng.randi() % 200
	for i in nv:
		b.verts.append(Vector3(rng.randf_range(-2, 2), rng.randf_range(0, 5), rng.randf_range(-2, 2)))
		b.colors.append(Color(rng.randf(), rng.randf(), rng.randf(), rng.randf()))
	for i in (nv / 3) * 3:
		b.indices.append(rng.randi() % nv)
	if with_coarse:
		var cn := nv / 2
		for i in cn:
			b.coarse_verts.append(Vector3(rng.randf_range(-2, 2), rng.randf_range(0, 5), rng.randf_range(-2, 2)))
			b.coarse_colors.append(Color(rng.randf(), rng.randf(), rng.randf(), 1.0))
		for i in (cn / 3) * 3:
			b.coarse_indices.append(rng.randi() % cn)
	if with_crown:
		var cn := 20 + rng.randi() % 60
		for i in cn:
			b.crown_verts.append(Vector3(rng.randf_range(-3, 3), rng.randf_range(2, 7), rng.randf_range(-3, 3)))
			b.crown_colors.append(Color(rng.randf(), rng.randf(), rng.randf(), rng.randf()))
		for i in (cn / 3) * 3:
			b.crown_indices.append(rng.randi() % cn)
		if rng.randf() < 0.7:
			for i in 4:
				b.leaf_tints.append(Vector3(rng.randf(), rng.randf(), rng.randf()))
	return b


## FarChunks.Merge (the far chunks' merged meshes): the same random groups built both ways.
func _far_merge(rng: RandomNumberGenerator) -> void:
	var worst := 0.0
	var gd_us := 0
	var nat_us := 0
	for trial in 6:
		var groups: Array = []
		for gi in 12:
			var bake := _rand_bake(rng, gi % 3 == 0, gi % 4 == 1)
			var xs: Array = []
			for k in 1 + rng.randi() % 40:
				var bas := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * rng.randf_range(0.5, 1.5))
				xs.append(Transform3D(bas, Vector3(rng.randf_range(-3000, 3000), rng.randf_range(0, 3), rng.randf_range(-3000, 3000))))
			groups.append([bake, xs, null, gi % 5 == 2, gi % 7 == 3])
		var tinted: Array = []
		for k in 5:
			tinted.append([_rand_bake(rng, false, k % 2 == 0), Transform3D(Basis(Vector3.UP, rng.randf()), Vector3(rng.randf() * 100, 0, rng.randf() * 100)),
				Color(rng.randf(), rng.randf(), rng.randf())])
		var res := []
		for mode in 2:
			var m: Object = FarChunks.Merge.new()
			m.coarse = trial % 2 == 1
			m.groups = groups.duplicate()
			m.tinted = tinted.duplicate()
			m.keep_arrays = true
			FarChunks.Merge.native_on = mode == 1
			m.run()
			if mode == 1 and m.used_native != 1:
				print("FAIL: far merge native not used")
				fails += 1
			res.append(m)
			if mode == 0:
				gd_us += m.usec
			else:
				nat_us += m.usec
		FarChunks.Merge.native_on = true
		var a: Array = res[0].arrays
		var c: Array = res[1].arrays
		var d := 0.0
		for s in a.size():
			var x: Variant = a[s]
			var y: Variant = c[s]
			if x.size() != y.size():
				print("  far merge slot %d size %d vs %d" % [s, x.size(), y.size()])
				d = INF
				continue
			for i in x.size():
				match typeof(x[i]):
					TYPE_VECTOR3:
						d = maxf(d, maxf(maxf(absf(x[i].x - y[i].x), absf(x[i].y - y[i].y)), absf(x[i].z - y[i].z)))
					TYPE_VECTOR2:
						d = maxf(d, maxf(absf(x[i].x - y[i].x), absf(x[i].y - y[i].y)))
					TYPE_COLOR:
						d = maxf(d, maxf(maxf(absf(x[i].r - y[i].r), absf(x[i].g - y[i].g)), maxf(absf(x[i].b - y[i].b), absf(x[i].a - y[i].a))))
					_:
						d = maxf(d, absf(float(x[i] - y[i])))
		worst = maxf(worst, d)
		print("far merge trial %d: tris %d, maxdiff %s" % [trial, res[0].triangles, d])
	print("FAR MERGE: gdscript %d us, native %d us (x%.1f), max diff %s" % [gd_us, nat_us, float(gd_us) / maxf(1.0, nat_us), worst])
	if worst > 0.0:
		print("FAIL: far merge arrays differ")
		fails += 1
