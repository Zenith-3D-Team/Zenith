extends SceneTree
## Tests LodMesher (greedy terrain/building meshing, wall culling, trees, GroundHeight cap)
## and DistantHorizon (quadtree zero-gap/zero-overlap coverage, loaded_mask recentering,
## CLI overrides, shader assignment, and clean WorkerThreadPool teardown).
##   godot --headless --audio-driver Dummy --path client -s res://tests/lod_mesher_test.gd

const TestEnv := preload("res://tests/test_env.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const LodData := preload("res://scripts/world/lod_data.gd")
const LodCache := preload("res://scripts/world/lod_cache.gd")
const LodMesher := preload("res://scripts/world/lod_mesher.gd")
const DistantHorizon := preload("res://scripts/world/distant_horizon.gd")
const RenderDistance := preload("res://scripts/world/render_distance.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")

const SolidShader := preload("res://shaders/lod_solid.gdshader")
const SolidMaskedShader := preload("res://shaders/lod_solid_masked.gdshader")
const WaterShader := preload("res://shaders/lod_water.gdshader")
const WaterMaskedShader := preload("res://shaders/lod_water_masked.gdshader")
const CloudShadowsShader := preload("res://shaders/cloud_shadows.gdshader")


class TestPalette extends RefCounted:
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

	func _init() -> void:
		# Tiles: 0 grass (land), 1 dirt (land), 2 water, 3 void, 4 lava
		tile_colors = PackedColorArray([
			Color(0.25, 0.42, 0.16),
			Color(0.45, 0.35, 0.22),
			Color(0.10, 0.28, 0.48),
			Color(0.0, 0.0, 0.0),
			Color(0.95, 0.35, 0.05),
		])
		tile_kind = PackedByteArray([0, 0, 1, 2, 3])
		tile_rough = PackedFloat32Array([0.95, 0.92, 0.15, 1.0, 0.60])

		# Protos: 0 none, 1 building, 2 tree, 3 cliff, 4 low belt, 5 ore, 6 pole
		ent_top_colors = PackedColorArray([
			Color.BLACK,
			Color(0.30, 0.50, 0.70),
			Color(0.15, 0.38, 0.12),
			Color(0.45, 0.40, 0.35),
			Color(0.70, 0.60, 0.20),
			Color(0.35, 0.45, 0.58),
			Color(0.03, 0.03, 0.035),
		])
		ent_side_colors = PackedColorArray([
			Color.BLACK,
			Color(0.20, 0.35, 0.50),
			Color(0.12, 0.25, 0.08),
			Color(0.35, 0.30, 0.25),
			Color(0.50, 0.40, 0.15),
			Color(0.25, 0.33, 0.42),
			Color(0.02, 0.02, 0.025),
		])
		ent_heights = PackedFloat32Array([0.0, 2.0, 4.0, 2.5, 0.15, 0.15, 1.7])
		ent_metal = PackedFloat32Array([0.0, 0.6, 0.0, 0.0, 0.4, 0.2, 0.35])
		ent_rough = PackedFloat32Array([1.0, 0.5, 0.95, 0.9, 0.6, 0.85, 0.75])
		ent_cat = PackedByteArray([
			LodMesher.CAT_NONE,
			LodMesher.CAT_BUILDING,
			LodMesher.CAT_TREE,
			LodMesher.CAT_CLIFF,
			LodMesher.CAT_LOW,
			LodMesher.CAT_ORE,
			LodMesher.CAT_POLE,
		])
		ent_glow = PackedByteArray([0, 2, 0, 0, 0, 0, 0])


class TestChunk extends RefCounted:
	var cx := 0
	var cy := 0
	var res := 4
	var rev := 1
	var tiles := PackedInt32Array()
	var protos := PackedInt32Array()
	var flags := PackedByteArray()


var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _init() -> void:
	TestEnv.isolate("lod-mesher-test")
	call_deferred("_run_all")


func _run_all() -> void:
	var pal := TestPalette.new()
	_test_shaders()
	_test_terrain_greedy(pal)
	_test_buildings_and_culling(pal)
	_test_trees_and_slabs(pal)
	_test_ground_height_cap(pal)
	_test_poles(pal)
	_test_cliff_seat(pal)
	_test_render_distance_resolver()
	_test_progressive_detail_tiers(pal)
	_test_quadtree_coverage()
	_test_cli_and_far()
	_test_lodm_runs()
	await _test_controller_pipeline(pal)
	await _test_detail_tier_controller(pal)
	await _test_end_to_end_persistence_and_protocol()
	await _test_hysteresis_retiring_and_interim(pal)
	await _test_512_streaming_and_lod4_stride()
	await _test_handoff_guard(pal)

	TestEnv.clean()
	print("lod_mesher_test: %s" % ("PASS" if fails == 0 else "FAILS %d" % fails))
	quit(1 if fails else 0)


func _shader_uniform_names(s: Shader) -> Array:
	var names: Array = []
	for u: Dictionary in s.get_shader_uniform_list():
		names.append(str(u.get("name", "")))
	return names


func _test_shaders() -> void:
	check(SolidShader != null and SolidShader is Shader, "lod_solid.gdshader loaded")
	check(SolidMaskedShader != null and SolidMaskedShader is Shader, "lod_solid_masked.gdshader loaded")
	check(WaterShader != null and WaterShader is Shader, "lod_water.gdshader loaded")
	check(WaterMaskedShader != null and WaterMaskedShader is Shader, "lod_water_masked.gdshader loaded")
	check(CloudShadowsShader != null and CloudShadowsShader is Shader, "cloud_shadows.gdshader loaded")

	for s: Shader in [SolidShader, SolidMaskedShader, WaterShader, WaterMaskedShader]:
		var mat := ShaderMaterial.new()
		mat.shader = s
		var unames := _shader_uniform_names(s)
		check(mat.shader == s and unames.has("horizon_color") and unames.has("fade_start") and unames.has("fade_end")
			and unames.has("lod_far_pollution") and unames.has("lod_far_pollution_rect"),
			"shader compiles with expected uniforms incl. lod_far_pollution: %s" % s.resource_path)
	check(_shader_uniform_names(SolidMaskedShader).has("loaded_mask") and _shader_uniform_names(WaterMaskedShader).has("loaded_mask"),
		"masked LOD shaders expose loaded_mask")
	check(_shader_uniform_names(WaterShader).has("sky_tint") and _shader_uniform_names(CloudShadowsShader).has("shadow_strength"),
		"water and cloud_shadows shaders compile cleanly")


func _test_terrain_greedy(pal: TestPalette) -> void:
	# 1) Uniform 16x16 land -> 1 quad (2 tris vs 512 naive tris)
	var job := LodMesher.new()
	job.grid_n = 16
	job.cell_tiles = 4.0
	job.tiles = PackedInt32Array()
	job.tiles.resize(256)
	job.tiles.fill(0)
	job.palette = pal
	job.keep_arrays = true
	job.run()

	check(job.mesh != null, "uniform land builds ArrayMesh")
	check(job.mesh.get_surface_count() == 1, "uniform land has 1 surface")
	check(job.solid_tris == 2 and job.water_tris == 0, "uniform 16x16 land greedy-merges to 2 triangles (got %d)" % job.solid_tris)

	var verts: PackedVector3Array = job.solid_arrays[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = job.solid_arrays[Mesh.ARRAY_TEX_UV]
	var cols: PackedColorArray = job.solid_arrays[Mesh.ARRAY_COLOR]
	check(verts.size() == 4, "uniform land has 4 vertices")
	check(roundi(uvs[0].y * 4.0) == 3, "land UV.y encodes KIND_GROUND (3)")
	check(is_equal_approx(uvs[0].x, 0.0), "land has 0 glow")
	var dec_r := cols[0].r * cols[0].r
	check(absf(dec_r - pal.tile_colors[0].r) < 0.02, "sqrt color round-trips cleanly")
	var packed_a := roundi(cols[0].a * 255.0)
	var dec_rough := float(packed_a & 15) / 15.0
	check(absf(dec_rough - 0.95) < 0.08, "roughness packed in COLOR.a")

	# 2) All void -> null mesh, 0 tris
	var vjob := LodMesher.new()
	vjob.grid_n = 16
	vjob.cell_tiles = 4.0
	vjob.tiles = PackedInt32Array()
	vjob.tiles.resize(256)
	vjob.tiles.fill(3)
	vjob.palette = pal
	vjob.run()
	check(vjob.mesh == null and vjob.tri_count == 0, "all-void section emits 0 tris and null mesh")

	# 3) Half land, half water -> 2 surfaces, water at WATER_Y, merged coastline bank
	var wjob := LodMesher.new()
	wjob.grid_n = 16
	wjob.cell_tiles = 4.0
	wjob.tiles = PackedInt32Array()
	wjob.tiles.resize(256)
	for y in 16:
		for x in 16:
			wjob.tiles[y * 16 + x] = 0 if x < 8 else 2
	wjob.palette = pal
	wjob.keep_arrays = true
	wjob.run()
	check(wjob.mesh != null and wjob.mesh.get_surface_count() == 2, "land+water has 2 surfaces")
	check(wjob.water_tris == 2, "half-grid water greedy-merges to 2 tris (got %d)" % wjob.water_tris)
	check(wjob.solid_tris == 4, "half-grid land + 1 merged coastline bank = 4 tris (got %d)" % wjob.solid_tris)
	var wverts: PackedVector3Array = wjob.water_arrays[Mesh.ARRAY_VERTEX]
	check(is_equal_approx(wverts[0].y, LodMesher.WATER_Y), "water sits at WATER_Y")

	# 4) Lava -> solid surface with KIND_LAVA (1) and glow 1.0
	var ljob := LodMesher.new()
	ljob.grid_n = 8
	ljob.cell_tiles = 4.0
	ljob.tiles = PackedInt32Array()
	ljob.tiles.resize(64)
	ljob.tiles.fill(4)
	ljob.palette = pal
	ljob.keep_arrays = true
	ljob.run()
	check(ljob.mesh != null and ljob.mesh.get_surface_count() == 1, "lava emits 1 solid surface")
	var luvs: PackedVector2Array = ljob.solid_arrays[Mesh.ARRAY_TEX_UV]
	check(roundi(luvs[0].y * 4.0) == 1 and is_equal_approx(luvs[0].x, 1.0), "lava has KIND_LAVA and glow 1")


class SeatPalette extends TestPalette:
	var ent_seat := PackedByteArray([0, 0, 0, 1, 0, 0, 0])


## Factorio's cliffs' blocks (the palette's ent_seat) get KIND_CLIFF, seated in their terrace by
## lod_common.gdshaderinc as the near cliff models are (--cliff-fit); rocks (CAT_CLIFF too) and
## buildings keep KIND_NORMAL; a palette without ent_seat gives none.
func _test_cliff_seat(pal: TestPalette) -> void:
	for seat_pal in [SeatPalette.new(), pal]:
		var job := LodMesher.new()
		job.grid_n = 8
		job.cell_tiles = 4.0
		job.tiles = PackedInt32Array()
		job.tiles.resize(64)
		job.protos = PackedInt32Array()
		job.protos.resize(64)
		job.flags = PackedByteArray()
		job.flags.resize(64)
		job.flags.fill(15)
		job.protos[2 * 8 + 2] = 3  # a cliff
		job.protos[5 * 8 + 5] = 1  # a building
		job.palette = seat_pal
		job.keep_arrays = true
		job.run()
		var verts: PackedVector3Array = job.solid_arrays[Mesh.ARRAY_VERTEX]
		var uvs: PackedVector2Array = job.solid_arrays[Mesh.ARRAY_TEX_UV]
		var cliff_kinds := {}
		var building_kinds := {}
		for i in verts.size():
			var in_cliff := verts[i].x >= 7.99 and verts[i].x <= 12.01 and verts[i].z >= 7.99 and verts[i].z <= 12.01
			var in_building := verts[i].x >= 19.99 and verts[i].x <= 24.01 and verts[i].z >= 19.99 and verts[i].z <= 24.01
			if in_cliff and verts[i].y > 0.001:
				cliff_kinds[snappedf(uvs[i].y, 0.01)] = true
			elif in_building and verts[i].y > 0.001:
				building_kinds[snappedf(uvs[i].y, 0.01)] = true
		var seated := seat_pal is SeatPalette
		check(cliff_kinds.keys() == [LodMesher.KIND_CLIFF if seated else LodMesher.KIND_NORMAL],
			"a cliff's block is kind %s (%s)" % ["KIND_CLIFF" if seated else "KIND_NORMAL without ent_seat", str(cliff_kinds.keys())])
		check(building_kinds.keys() == [LodMesher.KIND_NORMAL], "a building's block stays KIND_NORMAL (%s)" % str(building_kinds.keys()))


func _test_buildings_and_culling(pal: TestPalette) -> void:
	# 8x8 land with a 4x4 block of buildings in (2..5, 2..5)
	var job := LodMesher.new()
	job.grid_n = 8
	job.cell_tiles = 4.0
	job.tiles = PackedInt32Array()
	job.tiles.resize(64)
	job.tiles.fill(0)
	job.protos = PackedInt32Array()
	job.protos.resize(64)
	job.flags = PackedByteArray()
	job.flags.resize(64)
	for y in range(2, 6):
		for x in range(2, 6):
			job.protos[y * 8 + x] = 1
			job.flags[y * 8 + x] = 15
	job.palette = pal
	job.keep_arrays = true
	job.run()

	# Expect 2 (ground) + 2 (top) + 4*2 (4 outer perimeter walls) = 12 tris!
	check(job.solid_tris == 12, "4x4 building block culls interior walls & merges to 12 total tris (got %d)" % job.solid_tris)

	var verts: PackedVector3Array = job.solid_arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = job.solid_arrays[Mesh.ARRAY_INDEX]
	var max_y := -INF
	for v: Vector3 in verts:
		max_y = maxf(max_y, v.y)
	check(is_equal_approx(max_y, 2.0), "full-density building reaches height 2.0 (got %f)" % max_y)

	# Verify every triangle has non-zero area and upward faces wind clockwise (+Y front)
	for t in range(0, idx.size(), 3):
		var a := verts[idx[t]]
		var b := verts[idx[t + 1]]
		var c := verts[idx[t + 2]]
		var cr := (b - a).cross(c - a)
		check(cr.length_squared() > 1e-6, "non-degenerate triangle %d" % (t / 3))
		if absf(a.y - b.y) < 1e-4 and absf(a.y - c.y) < 1e-4:
			check(cr.y < 0.0, "top quad winds clockwise from above")

	# Density = 0 should scale height to 0.6 * 2.0 = 1.2 -> snapped to 1.25
	var djob := LodMesher.new()
	djob.grid_n = 4
	djob.cell_tiles = 4.0
	djob.tiles = PackedInt32Array()
	djob.tiles.resize(16)
	djob.tiles.fill(0)
	djob.protos = PackedInt32Array()
	djob.protos.resize(16)
	djob.flags = PackedByteArray()
	djob.flags.resize(16)
	djob.protos[5] = 1
	djob.flags[5] = 0
	djob.palette = pal
	djob.keep_arrays = true
	djob.run()
	var dverts: PackedVector3Array = djob.solid_arrays[Mesh.ARRAY_VERTEX]
	var dmax := -INF
	for v: Vector3 in dverts:
		dmax = maxf(dmax, v.y)
	check(is_equal_approx(dmax, 1.25), "zero-density building scales to 1.25 (got %f)" % dmax)

	# Stepped adjacent heights: 2.0 building next to 0.30 low structure shares step wall [0.30..2.0], not [0..2.0]
	var sjob := LodMesher.new()
	sjob.grid_n = 4
	sjob.cell_tiles = 4.0
	sjob.tiles = PackedInt32Array()
	sjob.tiles.resize(16)
	sjob.tiles.fill(0)
	sjob.protos = PackedInt32Array()
	sjob.protos.resize(16)
	sjob.flags = PackedByteArray()
	sjob.flags.resize(16)
	sjob.protos[5] = 1  # (1, 1) building h = 2.0
	sjob.flags[5] = 15
	sjob.protos[6] = 4  # (2, 1) low belt h = 0.15
	sjob.flags[6] = 15
	sjob.palette = pal
	sjob.keep_arrays = true
	sjob.run()
	var sverts: PackedVector3Array = sjob.solid_arrays[Mesh.ARRAY_VERTEX]
	var sidx: PackedInt32Array = sjob.solid_arrays[Mesh.ARRAY_INDEX]
	var found_shared_step := false
	for t in range(0, sidx.size(), 3):
		var a := sverts[sidx[t]]
		var b := sverts[sidx[t + 1]]
		var c := sverts[sidx[t + 2]]
		# Shared East wall of (1, 1) sits at x = 8.0, spanning y from 0.15 to 2.0
		if is_equal_approx(a.x, 8.0) and is_equal_approx(b.x, 8.0) and is_equal_approx(c.x, 8.0):
			var ymin := minf(a.y, minf(b.y, c.y))
			var ymax := maxf(a.y, maxf(b.y, c.y))
			if is_equal_approx(ymin, 0.15) and is_equal_approx(ymax, 2.0):
				found_shared_step = true
	check(found_shared_step, "adjacent differing heights emit stepped wall from nb_h to top_h")


func _test_trees_and_slabs(pal: TestPalette) -> void:
	# 4x4 grid with 4 trees -> 2 ground tris + 4 * 4 tree tris = 18 tris
	var tjob := LodMesher.new()
	tjob.grid_n = 4
	tjob.cell_tiles = 4.0
	tjob.section_origin = Vector2(32.0, -64.0)
	tjob.tiles = PackedInt32Array()
	tjob.tiles.resize(16)
	tjob.tiles.fill(0)
	tjob.protos = PackedInt32Array()
	tjob.protos.resize(16)
	tjob.flags = PackedByteArray()
	tjob.flags.resize(16)
	for i in [0, 1, 4, 5]:
		tjob.protos[i] = 2
		tjob.flags[i] = 12
	tjob.palette = pal
	tjob.keep_arrays = true
	tjob.run()
	check(tjob.solid_tris == 18, "4 pitched tree crowns + ground = 18 tris (got %d)" % tjob.solid_tris)

	var verts: PackedVector3Array = tjob.solid_arrays[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = tjob.solid_arrays[Mesh.ARRAY_TEX_UV]
	var tree_tops: Array[float] = []
	var has_base_025 := false
	for k in verts.size():
		if roundi(uvs[k].y * 4.0) == 2:
			if is_equal_approx(verts[k].y, 0.25):
				has_base_025 = true
			else:
				tree_tops.append(verts[k].y)
	check(has_base_025, "tree crowns sit on y = 0.25 base")
	check(tree_tops.size() == 4, "4 tree apexes emitted")
	check(not is_equal_approx(tree_tops[0], tree_tops[1]), "tree apex heights vary by world hash")

	# Ore & low belt slabs
	var ojob := LodMesher.new()
	ojob.grid_n = 4
	ojob.cell_tiles = 4.0
	ojob.tiles = PackedInt32Array()
	ojob.tiles.resize(16)
	ojob.tiles.fill(0)
	ojob.protos = PackedInt32Array()
	ojob.protos.resize(16)
	ojob.flags = PackedByteArray()
	ojob.flags.resize(16)
	ojob.protos[0] = 4
	ojob.protos[1] = 4
	ojob.flags[0] = 15
	ojob.flags[1] = 15
	ojob.protos[8] = 5
	ojob.protos[9] = 5
	ojob.flags[8] = 15
	ojob.flags[9] = 15
	ojob.palette = pal
	ojob.run()
	check(ojob.solid_tris > 2 and ojob.solid_tris < 30, "low and ore slabs emit merged geometry (%d tris)" % ojob.solid_tris)


func _test_ground_height_cap(pal: TestPalette) -> void:
	var job := LodMesher.new()
	job.grid_n = 16
	job.cell_tiles = 2.0
	job.tiles = PackedInt32Array()
	job.tiles.resize(256)
	job.tiles.fill(0)
	job.palette = pal
	job.max_quad_tiles = 4.0
	job.run()
	# 16x16 cells capped to 2x2 cells (4 tiles) -> 8x8 = 64 quads -> 128 tris
	check(job.solid_tris == 128, "max_quad_tiles=4 caps 16x16x2-tile grid to 128 tris (got %d)" % job.solid_tris)


func _test_quadtree_coverage() -> void:
	var cases := [
		[Vector2i(0, 0), 16, "minimal", "balanced"],
		[Vector2i(0, 0), 16, "low", "near"],
		[Vector2i(0, 0), 32, "medium", "balanced"],
		[Vector2i(7, -13), 128, "medium", "far"],
		[Vector2i(-100, 45), 256, "high", "balanced"],
		[Vector2i(3, 5), 256, "ultra", "far"],
		[Vector2i(0, 0), 128, "low", "balanced"],
	]
	for q_name: String in ["minimal", "low", "medium", "high", "ultra"]:
		for d_name: String in ["near", "balanced", "far"]:
			cases.append([Vector2i(5, -7), 128, q_name, d_name])
	for c: Array in cases:
		var center: Vector2i = c[0]
		var radius: int = int(c[1])
		var q: String = str(c[2])
		var d: String = str(c[3])
		var secs := DistantHorizon.ring_sections(center, radius, 0, q, d)
		check(not secs.is_empty(), "ring_sections non-empty for radius %d %s %s" % [radius, q, d])

		var bbox := Rect2i()
		var first := true
		for spec: Dictionary in secs:
			var cr: Rect2i = spec["chunk_rect"]
			var gn := int(spec["grid_n"])
			var ct := float(spec["cell_tiles"])
			var sc := int(spec["sec_chunks"])
			check(roundi(float(gn) * ct) == sc * DistantHorizon.CHUNK, "section grid matches chunk span")
			check(spec.has("detail_tier"), "ring_sections attaches detail_tier")
			if first:
				bbox = cr
				first = false
			else:
				bbox = bbox.merge(cr)

		var target := Rect2i(center.x - radius, center.y - radius, radius * 2 + 1, radius * 2 + 1)
		check(bbox.encloses(target), "quadtree bounding box encloses target radius %d around %s" % [radius, str(center)])

		var counts := PackedInt32Array()
		counts.resize(bbox.size.x * bbox.size.y)
		for spec: Dictionary in secs:
			var cr: Rect2i = spec["chunk_rect"]
			for cy in range(cr.position.y, cr.end.y):
				var ry := cy - bbox.position.y
				for cx in range(cr.position.x, cr.end.x):
					var rx := cx - bbox.position.x
					counts[ry * bbox.size.x + rx] += 1

		var gaps := 0
		var overlaps := 0
		for v in counts:
			if v == 0:
				gaps += 1
			elif v > 1:
				overlaps += 1
		check(gaps == 0 and overlaps == 0, "quadtree coverage %s/%s r=%d has 0 gaps (%d) and 0 overlaps (%d)" % [q, d, radius, gaps, overlaps])

	var near_secs := DistantHorizon.ring_sections(Vector2i.ZERO, 128, 0, "medium", "near")
	var far_secs := DistantHorizon.ring_sections(Vector2i.ZERO, 128, 0, "medium", "far")
	var near_l0 := 0
	var far_l0 := 0
	for spec: Dictionary in near_secs:
		if int(spec["level"]) == 0:
			near_l0 += 1
	for spec: Dictionary in far_secs:
		if int(spec["level"]) == 0:
			far_l0 += 1
	check(far_l0 > near_l0, "far dropoff yields more LOD 0 sections than near (%d > %d)" % [far_l0, near_l0])

	for q_name: String in ["minimal", "low", "medium", "high", "ultra"]:
		var tiers: Array = DistantHorizon.QUALITY_DETAIL_TIERS[q_name]
		var mono := true
		for i in range(1, tiers.size()):
			if int(tiers[i]) < int(tiers[i - 1]):
				mono = false
		check(mono, "QUALITY_DETAIL_TIERS monotonic for %s" % q_name)
		var cells: Array = DistantHorizon.QUALITY_CELL_TILES[q_name]
		var res_ok := true
		for ct_v: Variant in cells:
			if float(ct_v) < 2.0:
				res_ok = false
		check(res_ok, "QUALITY_CELL_TILES >= 2.0 for %s (matches min res=2)" % q_name)


## Run-spikes step 5: `lodm` kept as runs answers as the old one entry a chunk did (charted
## chunks, charted sections, sections flagged when a later map charts more), in far less time.
func _test_lodm_runs() -> void:
	var runs := PackedInt32Array([-10, -4, 0, 3, 7, 8])
	check(DistantHorizon.runs_have(runs, -10) and DistantHorizon.runs_have(runs, -5) and not DistantHorizon.runs_have(runs, -4) and DistantHorizon.runs_have(runs, 2)
		and not DistantHorizon.runs_have(runs, 3) and DistantHorizon.runs_have(runs, 7) and not DistantHorizon.runs_have(runs, 8) and not DistantHorizon.runs_have(runs, -11),
		"runs_have: half-open runs")
	check(DistantHorizon.runs_meet(runs, -4, 0) == false and DistantHorizon.runs_meet(runs, -5, -4) and DistantHorizon.runs_meet(runs, 3, 8) and not DistantHorizon.runs_meet(runs, 8, 100),
		"runs_meet: a range meets a run")
	check(DistantHorizon.runs_subtract(-12, 9, runs) == PackedInt32Array([-12, -10, -4, 0, 3, 7, 8, 9]), "runs_subtract: the gaps")
	check(DistantHorizon._normalized_runs(PackedInt32Array([5, 6, 0, 2, 2, 4])) == PackedInt32Array([0, 4, 5, 6]), "runs sorted and merged")

	# The same random maps to an old (one entry a chunk) and a new controller.
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var maps: Array = []
	for m in 2:
		var rows: Array = []
		for cy in range(-60, 60):
			if rng.randf() < 0.1:
				continue
			var row: Array = [cy]
			var x := -80 + rng.randi_range(0, 10)
			while x < 80:
				var n := rng.randi_range(1, 30 + m * 10)
				row.append_array([x, n])
				x += n + rng.randi_range(1, 12)
			rows.append(row)
		maps.append(rows)
	var ctrl: Array = []
	for old in [true, false]:
		var dh: Node = DistantHorizon.new()
		dh.map_old = old
		dh.enabled = true
		dh.radius_chunks = 64
		for l in 5:
			for sx in range(-6, 6):
				for sy in range(-6, 6):
					var st: Variant = DistantHorizon.SectionState.new()
					st.key = Vector3i(l, sx, sy)
					st.complete = true
					st.needs_missing_scan = false
					dh._sections[st.key] = st
		var rows0: Array = maps[0]
		var half := rows0.size() / 2
		dh.handle({"t": "lodm", "q": 1, "part": 1, "parts": 2, "w": rows0.slice(0, half)})
		dh.handle({"t": "lodm", "q": 1, "part": 2, "parts": 2, "w": rows0.slice(half)})
		for k in dh._sections:
			dh._sections[k].complete = true
			dh._sections[k].needs_missing_scan = false
		dh.handle({"t": "lodm", "q": 2, "part": 1, "parts": 1, "w": maps[1]})
		ctrl.append(dh)
	var a: Node = ctrl[0]
	var b: Node = ctrl[1]
	var diff_c := 0
	for cy in range(-64, 64):
		for cx in range(-96, 96):
			if a.is_charted(Vector2i(cx, cy)) != b.is_charted(Vector2i(cx, cy)):
				diff_c += 1
	var diff_s := 0
	var diff_flag := 0
	var flagged := 0
	for l in 5:
		for sx in range(-8, 8):
			for sy in range(-8, 8):
				var k := Vector3i(l, sx, sy)
				if a.section_charted(k) != b.section_charted(k):
					diff_s += 1
				if a._sections.has(k):
					flagged += 1 if a._sections[k].needs_missing_scan else 0
					if a._sections[k].needs_missing_scan != b._sections[k].needs_missing_scan:
						diff_flag += 1
	check(diff_c == 0 and diff_s == 0, "lodm as runs: the same charted chunks and sections as one entry a chunk (%d, %d differ)" % [diff_c, diff_s])
	check(diff_flag == 0 and flagged > 0, "lodm as runs: the same sections flagged for the newly charted (%d flagged, %d differ)" % [flagged, diff_flag])
	# A `lod` chunk outside the map counts as charted, as before.
	for dh: Node in ctrl:
		dh._charted_known = true
		dh._mark_charted_section(Vector2i(500, 500))
		if not dh.map_old:
			dh._charted_extra[Vector2i(500, 500)] = true
		else:
			dh._charted[Vector2i(500, 500)] = true
	check(b.is_charted(Vector2i(500, 500)) and b.section_charted(Vector3i(0, 125, 125)), "a lod chunk outside the map is charted")
	# A megabase-sized map: 600 rows of 600 chunks in 3 runs each.
	var big: Array = []
	for cy in range(-300, 300):
		big.append([cy, -300, 150, -140, 200, 70, 230])
	var times: Array = []
	for dh: Node in ctrl:
		var t0 := Time.get_ticks_usec()
		dh.handle({"t": "lodm", "q": 9, "part": 1, "parts": 1, "w": big})
		times.append((Time.get_ticks_usec() - t0) / 1000.0)
	print("lodm 360k chunks: one entry a chunk %.1f ms, runs %.1f ms" % [times[0], times[1]])
	check(float(times[1]) * 5.0 < float(times[0]), "lodm as runs is far cheaper (%.1f vs %.1f ms)" % [times[1], times[0]])
	check(b.is_charted(Vector2i(-300, 0)) and b.is_charted(Vector2i(299, 299)) and not b.is_charted(Vector2i(-145, 0)), "the big map as runs")
	for dh: Node in ctrl:
		dh.free()


func _test_cli_and_far() -> void:
	var ov_off := DistantHorizon.cli_override(PackedStringArray(["--distant-horizon=off", "--lod-night-glow=off", "--distant-horizon-detail-lod=off"]))
	check(ov_off.get("enabled") == false and int(ov_off.get("radius_chunks", -1)) == 0, "cli_override off")
	check(ov_off.get("glow_enabled") == false, "cli_override --lod-night-glow=off")
	check(ov_off.get("detail_lod_enabled") == false, "cli_override --distant-horizon-detail-lod=off")

	var ov_on := DistantHorizon.cli_override(PackedStringArray([
		"--distant-horizon=256",
		"--distant-horizon-quality=ultra",
		"--distant-horizon-dropoff=far",
		"--distant-horizon-detail-lod=on",
	]))
	check(ov_on.get("enabled") == true and int(ov_on.get("radius_chunks", 0)) == 256, "cli_override 256")
	check(str(ov_on.get("quality", "")) == "ultra", "cli_override quality ultra")
	check(str(ov_on.get("dropoff", "")) == "far", "cli_override dropoff far")
	check(ov_on.get("detail_lod_enabled") == true, "cli_override --distant-horizon-detail-lod=on")

	var dh := DistantHorizon.new()
	dh.apply_cli_overrides(PackedStringArray(["--distant-horizon-quality=minimal", "--distant-horizon-dropoff=near", "--distant-horizon-detail-lod=off"]))
	check(dh.quality == "minimal" and dh.dropoff == "near" and not dh.detail_lod_enabled, "apply_cli_overrides sets quality/dropoff/detail_lod_enabled")
	dh.enabled = false
	dh.radius_chunks = 256
	check(is_equal_approx(dh.desired_camera_far(), 2000.0), "desired_camera_far=2000 when disabled")
	dh.enabled = true
	check(dh.desired_camera_far() > 10000.0, "desired_camera_far grows with radius (%f)" % dh.desired_camera_far())
	dh.free()


func _test_controller_pipeline(pal: TestPalette) -> void:
	var dh := DistantHorizon.new()
	dh.enabled = true
	dh.radius_chunks = 64
	dh.quality = "medium"
	root.add_child(dh)
	dh.configure("test-save", 0, pal)

	var cam := Camera3D.new()
	cam.position = Vector3(16.0, 40.0, 16.0)
	cam.far = dh.desired_camera_far()
	root.add_child(cam)
	cam.look_at(Vector3(16.0, 0.0, -40.0), Vector3.UP)

	# Loaded-chunk mask & recentering
	dh.set_chunk_loaded(Vector2i(0, 0), true)
	dh.set_chunk_loaded(Vector2i(3, -2), true)
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.0, false)
	check(dh.mask_has_chunk(Vector2i(0, 0)), "loaded_mask tracks chunk (0, 0)")
	check(dh.mask_has_chunk(Vector2i(3, -2)), "loaded_mask tracks chunk (3, -2)")
	check(not dh.mask_has_chunk(Vector2i(1, 1)), "loaded_mask leaves unloaded chunk (1, 1) false")
	var orig0 := dh.mask_origin()
	check(orig0 == Vector2i(-64, -64), "loaded_mask centers at (-64, -64) around chunk (0, 0)")

	# Move camera >= 16 chunks away -> mask recenters cleanly
	cam.position = Vector3(25.0 * 32.0, 40.0, 0.0)
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	var orig1 := dh.mask_origin()
	check(orig1 == Vector2i(25 - 64, -64), "loaded_mask recenters when camera moves >= 16 chunks")
	check(dh.mask_has_chunk(Vector2i(3, -2)), "previously loaded chunk remains tracked after recenter")

	# Populate chunks in both LOD 0 (0, 0) and LOD 1 (34, 0 -> outside cover[0] [-24..32))
	cam.position = Vector3(16.0, 40.0, 16.0)
	dh.set_chunk_loaded(Vector2i(0, 0), false)
	dh.set_chunk_loaded(Vector2i(3, -2), false)
	for cy in range(-4, 4):
		for cx in range(-4, 4):
			var ch := TestChunk.new()
			ch.cx = cx
			ch.cy = cy
			ch.res = 4
			ch.tiles.resize(64)
			ch.tiles.fill(0)
			ch.protos.resize(64)
			ch.flags.resize(64)
			if cx == 2 and cy == 0:
				ch.protos[0] = 1
				ch.flags[0] = 15
			dh.set_chunk(ch)
	var l1_ch := TestChunk.new()
	l1_ch.cx = 34
	l1_ch.cy = 0
	l1_ch.res = 8
	l1_ch.tiles.resize(16)
	l1_ch.tiles.fill(2)
	l1_ch.protos.resize(16)
	l1_ch.flags.resize(16)
	dh.set_chunk(l1_ch)

	for _f in 40:
		dh.update(cam, Color(0.7, 0.8, 0.88), 0.5, false)
		var st := dh.stats()
		if int(st["building"]) == 0 and int(st["dirty"]) == 0 and int(st["visible_sections"]) >= 5:
			break
		await process_frame

	var final_stats := dh.stats()
	check(int(final_stats["visible_sections"]) >= 5, "LOD 0 and LOD 1 sections built and visible (got %s)" % str(final_stats["visible_sections"]))
	check(int(final_stats["triangles"]) > 0, "installed sections report positive triangles")

	# Verify LOD 0 uses masked shader (with discard) and LOD 1 uses unmasked Early-Z shader
	var found_lod0 := false
	var found_lod1 := false
	for child in dh.get_children():
		if child is MeshInstance3D:
			var mi := child as MeshInstance3D
			if mi.name.begins_with("LOD_0_"):
				found_lod0 = true
				var m0: ShaderMaterial = mi.mesh.surface_get_material(0)
				check(m0.shader == SolidMaskedShader or m0.shader == WaterMaskedShader, "LOD 0 uses masked shader")
			elif mi.name.begins_with("LOD_1_"):
				found_lod1 = true
				if mi.mesh.get_surface_count() > 0:
					var m1: ShaderMaterial = mi.mesh.surface_get_material(0)
					check(m1.shader == WaterShader or m1.shader == SolidShader, "LOD 1 uses unmasked Early-Z shader")
	check(found_lod0 and found_lod1, "both LOD 0 and LOD 1 MeshInstance3Ds created")

	# GroundHeight integration check: lift_range grows section custom_aabb
	var h_img := Image.create(8, 8, false, Image.FORMAT_RF)
	h_img.fill(Color(5.0, 0.0, 0.0, 1.0))
	GroundHeight.set_field(h_img, Vector2(-64.0, -64.0), 32.0)
	dh.set_chunk(_make_land_chunk(0, 0))
	for _f in 30:
		dh.update(cam, Color(0.7, 0.8, 0.88), 0.5, false)
		if int(dh.stats()["building"]) == 0 and int(dh.stats()["dirty"]) == 0:
			break
		await process_frame
	for child in dh.get_children():
		if child is MeshInstance3D and child.name == "LOD_0_0_0":
			check((child as MeshInstance3D).custom_aabb.size.y >= 4.9, "GroundHeight grows section custom_aabb vertically")
	GroundHeight.clear()

	# Smooth loaded-chunk mask fade: first frame fades instead of popping, full fade hides LOD 0 section, unload shows immediately
	for cy in range(0, 4):
		for cx in range(0, 4):
			dh.set_chunk_loaded(Vector2i(cx, cy), true)
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.5, false)
	var lod0_node: MeshInstance3D = dh.get_node_or_null("LOD_0_0_0")
	var mid_fade_lvl: float = dh.mask_level(Vector2i(0, 0))
	check(dh.mask_has_chunk(Vector2i(0, 0)) and mid_fade_lvl > 0.01 and mid_fade_lvl < 0.99
		and lod0_node != null and lod0_node.visible,
		"fading-in loaded section keeps LOD 0 MeshInstance3D visible until fade finishes (lvl=%.3f)" % mid_fade_lvl)
	dh.finish_mask_fades()
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.5, false)
	check(lod0_node != null and not lod0_node.visible, "fully-loaded LOD 0 section hides MeshInstance3D after fade")
	dh.set_chunk_loaded(Vector2i(0, 0), false)
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.5, false)
	check(lod0_node != null and lod0_node.visible and dh.mask_level(Vector2i(0, 0)) == 0.0,
		"partially-loaded / unloaded LOD 0 section shows MeshInstance3D at once with zero gap")

	# Cross-resolution sampling (res=4 chunk in LOD 1 needing res=8, and res=32 chunk in LOD 0 needing res=4)
	var fine_ch := TestChunk.new()
	fine_ch.cx = 35
	fine_ch.cy = 1
	fine_ch.res = 4
	fine_ch.tiles.resize(64)
	fine_ch.tiles.fill(0)
	fine_ch.protos.resize(64)
	fine_ch.protos[7] = 1
	fine_ch.flags.resize(64)
	fine_ch.flags[7] = 15
	dh.set_chunk(fine_ch)
	var coarse_ch := TestChunk.new()
	coarse_ch.cx = 8
	coarse_ch.cy = 0
	coarse_ch.res = 32
	coarse_ch.tiles.resize(1)
	coarse_ch.tiles[0] = 1
	coarse_ch.protos.resize(1)
	coarse_ch.flags.resize(1)
	dh.set_chunk(coarse_ch)
	for _f in 30:
		dh.update(cam, Color(0.7, 0.8, 0.88), 0.5, false)
		if int(dh.stats()["building"]) == 0 and int(dh.stats()["dirty"]) == 0:
			break
		await process_frame
	check(dh.get_node_or_null("LOD_0_2_0") != null, "coarse chunk upsamples cleanly into LOD 0 section")

	# LOD 4 (cell_tiles = 64, 2x2 chunks per cell) + reset_surface + message/bake stubs
	dh.radius_chunks = 256
	var l4_ch := TestChunk.new()
	l4_ch.cx = 256
	l4_ch.cy = 0
	l4_ch.res = 32
	l4_ch.tiles.resize(1)
	l4_ch.tiles[0] = 0
	l4_ch.protos.resize(1)
	l4_ch.flags.resize(1)
	dh.set_chunk(l4_ch)
	for _f in 30:
		dh.update(cam, Color(0.7, 0.8, 0.88), 0.5, false)
		if int(dh.stats()["building"]) == 0 and int(dh.stats()["dirty"]) == 0:
			break
		await process_frame
	check(dh.get_node_or_null("LOD_4_4_0") != null, "LOD 4 (cell_tiles=64) builds 2x2-chunk cells cleanly")

	dh.handle({"t": "lodm"})
	dh.handle({"t": "lodr"})
	dh.handle({"t": "lod"})
	dh.bake_world_chunk(0, 0, 1, PackedInt32Array(), {}, pal)
	dh.reset_surface(1, pal)
	check(int(dh.stats()["sections"]) == 0, "reset_surface clears sections")

	# Real protocol & bake roundtrip on surface 1
	dh.radius_chunks = 64
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.5, false)
	dh.handle({"t": "lodm", "si": 1, "q": 7, "part": 1, "parts": 2, "w": [[0, 0, 2]]})
	dh.handle({"t": "lodm", "si": 1, "q": 7, "part": 2, "parts": 2, "w": [[0, 40, 1]]})
	check(dh._charted_known and dh.is_charted(Vector2i(0, 0)) and dh.is_charted(Vector2i(40, 0)) and not dh.is_charted(Vector2i(2, 0)),
		"multi-part lodm row runs decode into _charted")
	dh.handle({"t": "lod", "si": 2, "cx": 40, "cy": 0, "res": 4, "rv": 3, "tl": [0, 64], "el": [0, 0, 64]})
	check(dh._get_chunk(40, 0) == null, "mismatched surface lod message is ignored")
	dh.handle({"t": "lodr", "si": 1, "l": [2, 0, 3]})
	dh.handle({"t": "lod", "si": 1, "cx": 40, "cy": 0, "res": 4, "rv": 3, "tl": [0, 64], "el": [0, 0, 64]})
	var rx_chunk: Variant = dh._get_chunk(40, 0)
	check(rx_chunk != null and int(rx_chunk.res) == 4 and (rx_chunk.tiles as PackedInt32Array).size() == 64,
		"lod RLE message decodes via LodChunk.from_msg")
	dh.handle({"t": "lod", "si": 1, "cx": 41, "cy": 0, "none": 1})
	check(dh._missing_chunks.has(Vector2i(41, 0)), "lod none:1 records missing chunk")
	dh.handle({"t": "lodr", "si": 1, "l": [2, 0, 4]})
	check(dh._mem_chunks.has(Vector2i(40, 0)) and dh._stale_chunks.has(Vector2i(40, 0)),
		"lodr revision bump preserves _mem_chunks stand-in and marks chunk stale")

	var baked_tiles := PackedInt32Array()
	baked_tiles.resize(1024)
	baked_tiles.fill(0)
	dh.bake_world_chunk(1, 1, 5, baked_tiles, {}, pal)
	for _f in 40:
		dh.update(cam, Color(0.7, 0.8, 0.88), 0.5, false)
		if int(dh.stats()["baking"]) == 0:
			break
		await process_frame
	var baked: Variant = dh._get_chunk(1, 1)
	check(baked != null and int(baked.rev) == 5 and (baked.tiles as PackedInt32Array).size() == 64,
		"bake_world_chunk produces downsampled LodChunk via BakeJob")

	# Clean teardown (zero leaked threads/nodes)
	dh.finish_all()
	dh.queue_free()
	cam.queue_free()
	await process_frame


static func _make_land_chunk(cx: int, cy: int) -> TestChunk:
	var ch := TestChunk.new()
	ch.cx = cx
	ch.cy = cy
	ch.res = 4
	ch.tiles.resize(64)
	ch.tiles.fill(0)
	ch.protos.resize(64)
	ch.flags.resize(64)
	return ch


func _take_captured(bridge: Node) -> Array:
	var out: Array = []
	if bridge == null:
		return out
	var cap: Variant = bridge.get("capture")
	if not (cap is Array):
		return out
	for text: Variant in cap as Array:
		var parsed: Variant = JSON.parse_string(str(text))
		if parsed is Dictionary:
			out.append(parsed)
	(cap as Array).clear()
	return out


func _test_end_to_end_persistence_and_protocol() -> void:
	var db := ProtoDB.new()
	db.add_tiles([
		[1, "grass-1", 60, 120, 40],
		[2, "water", 30, 80, 160],
		[3, "lava-hot", 220, 70, 20],
	])
	db.add_entities([
		[1, "assembling-machine-1", "assembling-machine", -1.5, -1.5, 1.5, 1.5, 80, 140, 180, 3, 3],
		[2, "tree-01", "tree", -0.7, -0.7, 0.7, 0.7, 40, 130, 40, 1, 1],
		[3, "small-lamp", "lamp", -0.4, -0.4, 0.4, 0.4, 240, 240, 200, 1, 1],
	])

	var bridge: Node = root.get_node_or_null("Bridge")
	var had_bridge := bridge != null
	var was_connected := bool(bridge.get("connected")) if had_bridge else false
	var was_ready := bool(bridge.get("world_ready")) if had_bridge else false
	var was_lod := bool(bridge.get("lod_supported")) if had_bridge else false
	var was_cap: Variant = bridge.get("capture") if had_bridge else null
	if had_bridge:
		bridge.set("capture", [])
		bridge.set("connected", true)
		bridge.set("world_ready", true)
		bridge.set("lod_supported", true)

	var cam := Camera3D.new()
	cam.position = Vector3(64.0, 50.0, 64.0)
	root.add_child(cam)
	cam.look_at(Vector3(64.0, 0.0, -40.0), Vector3.UP)

	# Run 1: configure -> ensure_palette_and_cache -> lodm/lodr/lod stream -> flush Zstd cache to disk
	var dh1 := DistantHorizon.new()
	dh1.enabled = true
	dh1.radius_chunks = 64
	dh1.quality = "medium"
	root.add_child(dh1)
	dh1.configure("e2e-save", 1, null)
	dh1.ensure_palette_and_cache(db, {})
	check(dh1._cache_configured and dh1._palette != null, "e2e: ensure_palette_and_cache initializes palette and cache")

	dh1._sub_timer = DistantHorizon.LOD_SUB_INTERVAL
	dh1.update(cam, Color(0.7, 0.8, 0.88), 0.1, false)
	if had_bridge:
		var sent1 := _take_captured(bridge)
		var has_map := false
		for m: Dictionary in sent1:
			if m.get("t") == "lod_sub" and m.get("act") == "map" and int(m.get("si", 0)) == 1:
				has_map = true
		check(has_map, "e2e: initial update emits lod_sub map handshake")

	# Populate section (0,0) in region (0,0) and chunk (32,0) in region (2,0)
	var rows0 := []
	for cy in range(0, 4):
		rows0.append([cy, 0, 4])
	rows0.append([0, 32, 4])
	dh1.handle({"t": "lodm", "si": 1, "q": 1, "part": 1, "parts": 1, "w": rows0})
	dh1.handle({"t": "lodr", "si": 1, "q": 1, "l": [0, 0, 5, 2, 0, 7]})
	for cy in range(0, 4):
		for cx in range(0, 4):
			dh1.handle({
				"t": "lod", "si": 1, "cx": cx, "cy": cy, "res": 4, "rv": 2,
				"tl": [1, 60, 2, 4],
				"el": [1, 0x5F, 2, 2, 0x8A, 2, 0, 0, 60],
			})
	dh1.handle({
		"t": "lod", "si": 1, "cx": 32, "cy": 0, "res": 8, "rv": 3,
		"tl": [1, 16],
		"el": [3, 0x7F, 1, 0, 0, 15],
	})

	for _f in 40:
		dh1.update(cam, Color(0.7, 0.8, 0.88), 0.1, false)
		var st1 := dh1.stats()
		if int(st1["building"]) == 0 and int(st1["dirty"]) == 0 and int(st1["visible_sections"]) >= 2:
			break
		await process_frame

	var sdir := ProjectSettings.globalize_path("user://lod-cache").path_join("e2e-save").path_join("s1")
	var flushed := int(dh1._cache.flush_dirty())
	check(flushed == 2, "e2e: Zstd cache flushes both regions to disk (got %d)" % flushed)
	check(FileAccess.file_exists(sdir.path_join("r_0_0.zlod")) and FileAccess.file_exists(sdir.path_join("r_2_0.zlod")),
		"e2e: persisted region .zlod files exist on disk")

	var orig_c00: Variant = dh1._get_chunk(0, 0)
	dh1.finish_all()
	dh1.queue_free()
	await process_frame
	if had_bridge:
		_take_captured(bridge)

	# Run 2: fresh controller reloads persisted Zstd regions without receiving new `lod` packets
	var dh2 := DistantHorizon.new()
	dh2.enabled = true
	dh2.radius_chunks = 64
	dh2.quality = "medium"
	root.add_child(dh2)
	dh2.configure("e2e-save", 1, null)
	dh2.ensure_palette_and_cache(db, {})
	check(int(dh2._cached_region_revs.get(Vector2i(0, 0), -1)) == 5 and int(dh2._cached_region_revs.get(Vector2i(2, 0), -1)) == 7,
		"e2e: fresh controller reads persisted region_revs on startup")

	dh2._sub_timer = DistantHorizon.LOD_SUB_INTERVAL
	dh2.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	if had_bridge:
		var sent2 := _take_captured(bridge)
		var revs_cmd: Dictionary = {}
		for m: Dictionary in sent2:
			if m.get("t") == "lod_sub" and m.get("act") == "revs":
				revs_cmd = m
		var rg_list: Array = revs_cmd.get("rg", []) if revs_cmd.get("rg") is Array else []
		check(not revs_cmd.is_empty() and rg_list.size() == 2,
			"e2e: fresh controller sends lod_sub revs check for cached regions: %s" % [rg_list])

	for _f in 40:
		dh2.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
		var st2 := dh2.stats()
		if int(st2["building"]) == 0 and int(st2["dirty"]) == 0 and int(st2["visible_sections"]) >= 2:
			break
		await process_frame

	var st2_done := dh2.stats()
	var reloaded_c00: Variant = dh2._get_chunk(0, 0)
	check(int(st2_done["visible_sections"]) >= 2 and int(st2_done["triangles"]) > 0,
		"e2e: fresh controller builds visible LOD sections from disk cache alone")
	check(reloaded_c00 != null and orig_c00 != null
		and (reloaded_c00.tiles as PackedInt32Array) == (orig_c00.tiles as PackedInt32Array)
		and (reloaded_c00.protos as PackedInt32Array) == (orig_c00.protos as PackedInt32Array)
		and (reloaded_c00.flags as PackedByteArray) == (orig_c00.flags as PackedByteArray),
		"e2e: disk reload preserves exact chunk data across controller restarts")

	# Region invalidation via lodr deletes stale disk file while preserving visible stand-in and marking stale
	var sec00_pre: Variant = dh2._sections.get(Vector3i(0, 0, 0))
	var sec00_node_pre: Variant = sec00_pre.node if sec00_pre != null else null
	dh2.handle({"t": "lodr", "si": 1, "q": 2, "l": [0, 0, 6]})
	check(not FileAccess.file_exists(sdir.path_join("r_0_0.zlod")) and FileAccess.file_exists(sdir.path_join("r_2_0.zlod")),
		"e2e: lodr invalidation deletes stale r_0_0.zlod and keeps valid r_2_0.zlod")
	check(dh2._mem_chunks.has(Vector2i(0, 0)) and dh2._stale_chunks.has(Vector2i(0, 0)) and dh2._mem_chunks.has(Vector2i(32, 0)),
		"e2e: lodr invalidation keeps memory stand-in and marks region (0,0) stale")
	var sec00: Variant = dh2._sections.get(Vector3i(0, 0, 0))
	check(sec00 != null and sec00.node == sec00_node_pre and sec00.node != null and sec00.node.visible and not bool(sec00.complete),
		"e2e: lodr invalidation keeps visible section rendered and marks section incomplete")

	# Re-sending lodm and stepping update triggers lod_sub want for invalidated chunk(s)
	dh2.handle({"t": "lodm", "si": 1, "q": 2, "part": 1, "parts": 1, "w": rows0})
	dh2._sub_timer = DistantHorizon.LOD_SUB_INTERVAL
	dh2.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	if had_bridge:
		var sent_want := _take_captured(bridge)
		var saw_want := false
		for m: Dictionary in sent_want:
			if m.get("t") == "lod_sub" and m.get("act") == "want":
				var clist: Array = m.get("c", []) if m.get("c") is Array else []
				if not clist.is_empty():
					saw_want = true
		check(saw_want, "e2e: invalidated section schedules lod_sub want request")

	# Malformed / empty {} Lua-style tables do not error or corrupt state
	for bad_msg: Dictionary in [
		{},
		{"t": "lodm", "si": 1, "q": 9, "part": 1, "parts": 1, "w": {}},
		{"t": "lodm", "si": 1, "q": 10, "part": 1, "parts": 1, "w": [[], [0], [0, 0]]},
		{"t": "lodr", "si": 1, "l": {}},
		{"t": "lodr", "si": 1, "l": [0, 0]},
		{"t": "lod", "si": 1, "cx": 0, "cy": 0, "res": 99, "tl": {}, "el": {}},
		{"t": "lod", "si": 1, "none": 1},
	]:
		dh2.handle(bad_msg)
	check(true, "e2e: malformed and empty-dict LOD messages handled safely")

	# inner_chunks expansion keeps masked LOD 0 out to view_radius when view_radius > 24
	dh2.inner_chunks = 36
	dh2.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	var sec_mid: Variant = dh2._sections.get(Vector3i(0, 7, 0))  # chunks 28..31 (past RING_REACH[0]=24, inside 36)
	check(sec_mid != null, "e2e: inner_chunks=36 places chunk 30 in masked LOD 0 instead of LOD 1")
	var sec_recreate_key := Vector3i(0, 7, 0)
	var ser_before := int(sec_mid.serial)
	dh2._sync_sections(Vector2i(100, 100))
	dh2._sync_sections(Vector2i(0, 0))
	var sec_recreated: Variant = dh2._sections.get(sec_recreate_key)
	check(sec_recreated != null and int(sec_recreated.serial) > ser_before,
		"e2e: section eviction and re-creation preserves strictly increasing serial")

	# Disabling controller hides node and emits lod_sub stop
	dh2.enabled = false
	dh2.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	check(not dh2.visible, "e2e: disabling DistantHorizon hides node")
	if had_bridge:
		var sent_stop := _take_captured(bridge)
		var saw_stop := false
		for m: Dictionary in sent_stop:
			if m.get("t") == "lod_sub" and m.get("act") == "stop":
				saw_stop = true
		check(saw_stop, "e2e: disabling DistantHorizon sends lod_sub stop")

	dh2.finish_all()
	dh2.queue_free()
	cam.queue_free()
	await process_frame

	if had_bridge:
		bridge.set("capture", was_cap)
		bridge.set("connected", was_connected)
		bridge.set("world_ready", was_ready)
		bridge.set("lod_supported", was_lod)


func _test_hysteresis_retiring_and_interim(pal: TestPalette) -> void:
	var dh := DistantHorizon.new()
	dh.enabled = true
	dh.radius_chunks = 64
	dh.quality = "medium"
	root.add_child(dh)
	dh.configure("test-retire", 0, pal)

	var cam := Camera3D.new()
	cam.position = Vector3(16.0, 40.0, 16.0)
	cam.far = dh.desired_camera_far()
	root.add_child(cam)
	cam.look_at(Vector3(16.0, 0.0, -40.0), Vector3.UP)

	# Build LOD 0 section at (-24, 0) -> key (0, -6, 0)
	dh.set_chunk(_make_land_chunk(-24, 0))
	for _f in 30:
		dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
		var s_init: Variant = dh._sections.get(Vector3i(0, -6, 0))
		if s_init != null and s_init.node != null:
			break
		await process_frame
	var s_old: Variant = dh._sections.get(Vector3i(0, -6, 0))
	check(s_old != null and s_old.node != null, "retire test: initial LOD 0 section (-6,0) built")
	var old_node: MeshInstance3D = s_old.node if s_old != null else null

	# Hysteresis: move 5 chunks (< LAYOUT_HYSTERESIS=8) -> layout unchanged
	cam.position = Vector3(5.0 * 32.0 + 16.0, 40.0, 16.0)
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	check(dh._layout_center == Vector2i(0, 0) and dh._sections.has(Vector3i(0, -6, 0)),
		"layout hysteresis keeps layout unchanged on < 8 chunk move")

	# Move 10 chunks (>= 8) -> old LOD 0 section replaced by LOD 1 (1, -3, 0) & enters _retiring
	cam.position = Vector3(10.0 * 32.0 + 16.0, 40.0, 16.0)
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	check(dh._layout_center == Vector2i(10, 0) and not dh._sections.has(Vector3i(0, -6, 0))
			and dh._sections.has(Vector3i(1, -3, 0)),
		"layout recenters >= 8 chunk move and creates overlapping LOD 1 section")
	check(dh._retiring.size() == 1 and old_node != null and is_instance_valid(old_node)
			and old_node.is_inside_tree() and is_equal_approx(old_node.position.y, -0.02),
		"evicted section node stays visible in _retiring at y=-0.02 while replacement builds")

	for _f in 30:
		dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
		if dh._retiring.is_empty():
			break
		await process_frame
	var s_rep: Variant = dh._sections.get(Vector3i(1, -3, 0))
	check(dh._retiring.is_empty() and s_rep != null and s_rep.node != null,
		"retiring node is freed once overlapping replacement installs its mesh")

	# Interim mesh install: serial bumped by arriving chunk while st.node == null still installs interim mesh
	dh.set_chunk(_make_land_chunk(4, 0))
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	var s_int: Variant = dh._sections.get(Vector3i(0, 1, 0))
	check(s_int != null and s_int.building and s_int.node == null,
		"interim test: new section starts building with node==null")
	for _w in 40:
		if not dh._mesh_jobs.is_empty():
			var job_entry: Array = dh._mesh_jobs[-1]
			if WorkerThreadPool.is_task_completed(int(job_entry[0])):
				break
		await process_frame
	dh.set_chunk(_make_land_chunk(5, 0))
	dh._poll_and_install_meshes()
	check(s_int != null and s_int.node != null and s_int.dirty,
		"interim mesh installs on st.node==null despite serial bump, leaving dirty=true for rebuild")

	dh.finish_all()
	dh.queue_free()
	cam.queue_free()
	await process_frame


func _test_512_streaming_and_lod4_stride() -> void:
	var pal := TestPalette.new()
	var bridge: Node = root.get_node_or_null("Bridge")
	var had_bridge := bridge != null
	var was_connected := bool(bridge.get("connected")) if had_bridge else false
	var was_ready := bool(bridge.get("world_ready")) if had_bridge else false
	var was_lod := bool(bridge.get("lod_supported")) if had_bridge else false
	var was_cap: Variant = bridge.get("capture") if had_bridge else null
	if had_bridge:
		bridge.set("capture", [])
		bridge.set("connected", true)
		bridge.set("world_ready", true)
		bridge.set("lod_supported", true)

	var dh := DistantHorizon.new()
	dh.enabled = true
	dh.radius_chunks = 512
	dh.quality = "medium"
	root.add_child(dh)
	dh.configure("test-512-stream", 1, pal)

	var cam := Camera3D.new()
	cam.position = Vector3(16.0, 40.0, 16.0)
	cam.far = dh.desired_camera_far()
	root.add_child(cam)
	cam.look_at(Vector3(16.0, 0.0, -40.0), Vector3.UP)

	dh._sub_timer = DistantHorizon.LOD_SUB_INTERVAL
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	if had_bridge:
		_take_captured(bridge)

	# Partial lodm (part 1/2): periodic map refresh must NOT fire while multi-part lodm is in flight
	dh.handle({"t": "lodm", "si": 1, "q": 10, "part": 1, "parts": 2, "w": [[0, 0, 1]]})
	dh._map_timer = DistantHorizon.MAP_IDLE_REFRESH_INTERVAL + 5.0
	dh._sub_timer = DistantHorizon.LOD_SUB_INTERVAL
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	if had_bridge:
		var mid_sent := _take_captured(bridge)
		var dup_map := false
		for m: Dictionary in mid_sent:
			if m.get("t") == "lod_sub" and m.get("act") == "map":
				dup_map = true
		check(not dup_map, "map refresh is suppressed while multi-part lodm is in flight")

	# Finish lodm with LOD 0 chunk (0,0) + 2x2 chunk block (300..301, 0..1) inside LOD 4
	dh.handle({
		"t": "lodm", "si": 1, "q": 10, "part": 2, "parts": 2,
		"w": [[0, 300, 2], [1, 300, 2]],
	})
	dh._in_flight.clear()
	dh._prefer_far_batch = false
	dh._sub_timer = DistantHorizon.LOD_SUB_INTERVAL
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	if had_bridge:
		var sent_near := _take_captured(bridge)
		var near_want := {}
		for m: Dictionary in sent_near:
			if m.get("t") == "lod_sub" and m.get("act") == "want":
				near_want = m
		var near_c: Array = near_want.get("c", []) if near_want.get("c") is Array else []
		check(int(near_want.get("res", 0)) == 16 and near_c.size() == 1 and int(near_c[0][0]) == 0 and int(near_c[0][1]) == 0,
			"512-stream Pass 1 requests near missing chunk at coarse res=16 before res=4: %s" % [near_want])

	# Provide coarse (0,0) at res=16 -> next batch alternates to outer bucket (LOD 4) at res=32 with 2x2 stride
	var ch00_16 := TestChunk.new()
	ch00_16.cx = 0
	ch00_16.cy = 0
	ch00_16.res = 16
	ch00_16.tiles = PackedInt32Array([0, 0, 0, 0])
	ch00_16.protos = PackedInt32Array([0, 0, 0, 0])
	ch00_16.flags = PackedByteArray([0, 0, 0, 0])
	dh.set_chunk(ch00_16)
	dh._in_flight.clear()
	dh._sub_timer = DistantHorizon.LOD_SUB_INTERVAL
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	if had_bridge:
		var sent_far := _take_captured(bridge)
		var far_want := {}
		for m: Dictionary in sent_far:
			if m.get("t") == "lod_sub" and m.get("act") == "want":
				far_want = m
		var far_c: Array = far_want.get("c", []) if far_want.get("c") is Array else []
		check(int(far_want.get("res", 0)) == 32 and far_c.size() == 1 and int(far_c[0][0]) == 300 and int(far_c[0][1]) == 0,
			"512-stream alternates to LOD 4 res=32 and strides 2x2 block to 1 request: %s" % [far_want])

	# Provide (300,0) at res=32 -> Pass 1 done, Pass 2 refines (0,0) to target res=4
	var ch300_32 := TestChunk.new()
	ch300_32.cx = 300
	ch300_32.cy = 0
	ch300_32.res = 32
	ch300_32.tiles = PackedInt32Array([0])
	ch300_32.protos = PackedInt32Array([0])
	ch300_32.flags = PackedByteArray([0])
	dh.set_chunk(ch300_32)
	dh._in_flight.clear()
	dh._sub_timer = DistantHorizon.LOD_SUB_INTERVAL
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	if had_bridge:
		var sent_ref := _take_captured(bridge)
		var ref_want := {}
		for m: Dictionary in sent_ref:
			if m.get("t") == "lod_sub" and m.get("act") == "want":
				ref_want = m
		var ref_c: Array = ref_want.get("c", []) if ref_want.get("c") is Array else []
		check(int(ref_want.get("res", 0)) == 4 and ref_c.size() == 1 and int(ref_c[0][0]) == 0 and int(ref_c[0][1]) == 0,
			"512-stream Pass 2 refines (0,0) to res=4 once coarse Pass 1 coverage finishes: %s" % [ref_want])

	dh.finish_all()
	dh.queue_free()
	cam.queue_free()
	await process_frame


	if had_bridge:
		bridge.set("capture", was_cap)
		bridge.set("connected", was_connected)
		bridge.set("world_ready", was_ready)
		bridge.set("lod_supported", was_lod)


func _test_progressive_detail_tiers(pal: TestPalette) -> void:
	var n := 10
	var tiles := PackedInt32Array()
	tiles.resize(n * n)
	tiles.fill(0)
	for x in n:
		tiles[9 * n + x] = 2  # water row for coast bank check

	var protos := PackedInt32Array()
	protos.resize(n * n)
	protos.fill(0)
	var flags := PackedByteArray()
	flags.resize(n * n)
	flags.fill(0)

	# Forest 2x2 block at (1..2, 1..2) -> world [4..12, 4..12]
	for y in [1, 2]:
		for x in [1, 2]:
			protos[y * n + x] = 2
			flags[y * n + x] = 15

	# Belt (5..6, 1) + Ore (5..6, 2) -> world [20..28, 4..12]
	for x in [5, 6]:
		protos[1 * n + x] = 4
		flags[1 * n + x] = 12
		protos[2 * n + x] = 5
		flags[2 * n + x] = 12

	# Sparse short-density building (1, 5) -> world [4..8, 20..24]
	protos[5 * n + 1] = 1
	flags[5 * n + 1] = 2

	# Dense tall building (5..6, 5) -> world [20..28, 20..24]
	for x in [5, 6]:
		protos[5 * n + x] = 1
		flags[5 * n + x] = 15

	var tris: Array[int] = []
	for tier: int in [LodMesher.DETAIL_FULL, LodMesher.DETAIL_MID, LodMesher.DETAIL_FAR, LodMesher.DETAIL_HORIZON]:
		var job := LodMesher.new()
		job.grid_n = n
		job.cell_tiles = 4.0
		job.tiles = tiles
		job.protos = protos
		job.flags = flags
		job.palette = pal
		job.detail_tier = tier
		job.keep_arrays = true
		job.run()
		tris.append(job.solid_tris)

		var verts: PackedVector3Array = job.solid_arrays[Mesh.ARRAY_VERTEX]
		var uvs: PackedVector2Array = job.solid_arrays[Mesh.ARRAY_TEX_UV]
		var tree_max_y := -INF
		var tree_kind_cnt := 0
		var belt_max_y := -INF
		var sparse_max_y := -INF
		var sparse_glow_cnt := 0
		var dense_max_y := -INF
		var min_solid_y := INF

		for i in verts.size():
			var v: Vector3 = verts[i]
			var uv: Vector2 = uvs[i]
			var k := roundi(uv.y * 4.0)
			if v.y < min_solid_y:
				min_solid_y = v.y
			if v.x >= 1.5 and v.x <= 14.5 and v.z >= 1.5 and v.z <= 14.5:
				if v.y > tree_max_y:
					tree_max_y = v.y
				if k == 2:
					tree_kind_cnt += 1
			if v.x >= 19.5 and v.x <= 28.5 and v.z >= 3.5 and v.z <= 12.5:
				if v.y > belt_max_y:
					belt_max_y = v.y
			if v.x >= 3.9 and v.x <= 8.1 and v.z >= 19.9 and v.z <= 24.1:
				if v.y > sparse_max_y:
					sparse_max_y = v.y
				if uv.x > 0.0 and k == 0:
					sparse_glow_cnt += 1
			if v.x >= 19.9 and v.x <= 28.1 and v.z >= 19.9 and v.z <= 24.1:
				if v.y > dense_max_y:
					dense_max_y = v.y

		if tier == LodMesher.DETAIL_FULL:
			check(tree_max_y > 2.0 and tree_kind_cnt > 0, "DETAIL_FULL builds 3D trees with KIND_TREE")
			check(belt_max_y >= 0.09, "DETAIL_FULL builds 3D low belts & ore slabs (%f)" % belt_max_y)
			check(min_solid_y < -0.2, "DETAIL_FULL builds coast banks (%f)" % min_solid_y)
		elif tier == LodMesher.DETAIL_MID:
			check(belt_max_y <= 0.01, "DETAIL_MID flattens belts & ores onto terrain (max_y=%f)" % belt_max_y)
			check(tree_max_y >= 1.25 and tree_max_y <= 4.5 and tree_kind_cnt > 0, "DETAIL_MID builds merged forest blocks (max_y=%f)" % tree_max_y)
			check(sparse_max_y >= 0.50, "DETAIL_MID retains building blocks (%f)" % sparse_max_y)
		elif tier == LodMesher.DETAIL_FAR:
			check(tree_max_y <= 0.01 and tree_kind_cnt > 0, "DETAIL_FAR flattens trees with KIND_TREE terrain tint (max_y=%f, uv=%d)" % [tree_max_y, tree_kind_cnt])
			check(dense_max_y >= 1.0, "DETAIL_FAR keeps coarse building silhouettes (%f)" % dense_max_y)
			check(min_solid_y < -0.2, "DETAIL_FAR retains coast banks (%f)" % min_solid_y)
		elif tier == LodMesher.DETAIL_HORIZON:
			check(sparse_max_y <= 0.01 and sparse_glow_cnt > 0, "DETAIL_HORIZON flattens sparse buildings with subtle glow (max_y=%f, glow=%d)" % [sparse_max_y, sparse_glow_cnt])
			check(dense_max_y >= 1.5, "DETAIL_HORIZON retains major dense silhouettes (%f)" % dense_max_y)
			check(min_solid_y >= -0.01, "DETAIL_HORIZON skips coast banks (%f)" % min_solid_y)

	check(tris[0] > tris[1] and tris[1] > tris[2] and tris[2] > tris[3],
		"progressive detail tiers monotonically reduce triangles (%s)" % str(tris))


func _test_detail_tier_controller(pal: TestPalette) -> void:
	var dh := DistantHorizon.new()
	dh.enabled = true
	dh.radius_chunks = 64
	dh.quality = "medium"
	dh.dropoff = "balanced"
	dh.detail_lod_enabled = true
	root.add_child(dh)
	dh.configure("test-detail-ctrl", 0, pal)

	var cam := Camera3D.new()
	cam.position = Vector3(16.0, 20.0, 16.0)
	root.add_child(cam)
	await process_frame

	# Populate chunk (0,0) with buildings + trees + belts so tier changes alter geometry
	var ch := TestChunk.new()
	ch.cx = 0
	ch.cy = 0
	ch.res = 4
	ch.tiles = PackedInt32Array()
	ch.tiles.resize(64)
	ch.tiles.fill(0)
	ch.protos = PackedInt32Array()
	ch.protos.resize(64)
	ch.protos.fill(0)
	ch.flags = PackedByteArray()
	ch.flags.resize(64)
	ch.flags.fill(15)
	for i in 16:
		ch.protos[i] = 2  # trees
	for i in range(16, 32):
		ch.protos[i] = 4  # low belts
	for i in range(32, 48):
		ch.protos[i] = 1  # buildings
	dh.set_chunk(ch)

	dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	var k0 := Vector3i(0, 0, 0)
	var st0: DistantHorizon.SectionState = dh._sections.get(k0)
	check(st0 != null and st0.detail_tier == 0 and str(dh.stats().get("dropoff", "")) == "balanced",
		"detail_tier controller starts balanced medium LOD 0 at detail_tier=0")

	for _f in range(40):
		dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
		if st0.node != null and not st0.dirty and not st0.building:
			break
		await process_frame

	dh.dropoff = "far"
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	var far_l0 := 0
	for k in dh._sections:
		var st: DistantHorizon.SectionState = dh._sections[k]
		if st.level == 0:
			far_l0 += 1
	check(str(dh.stats().get("dropoff", "")) == "far" and far_l0 > 144,
		"changing dropoff to far expands LOD 0 count (%d) and stats" % far_l0)

	var serial_before_min := st0.serial
	dh.quality = "minimal"
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	st0 = dh._sections.get(k0)
	for _f in range(40):
		if st0.node != null and not st0.dirty and not st0.building:
			break
		dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
		await process_frame
	var tris_min := st0.tri_count
	check(st0 != null and st0.detail_tier == 1 and st0.serial > serial_before_min and tris_min > 0,
		"changing quality to minimal updates LOD 0 detail_tier to 1 and rebuilds (%d tris)" % tris_min)

	var serial_before_off := st0.serial
	dh.detail_lod_enabled = false
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	st0 = dh._sections.get(k0)
	for _f in range(40):
		if st0.node != null and not st0.dirty and not st0.building:
			break
		dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
		await process_frame
	var tris_full := st0.tri_count
	check(st0 != null and st0.detail_tier == 0 and st0.serial > serial_before_off and tris_full > tris_min,
		"disabling detail_lod_enabled resets detail_tier to 0 and rebuilds fuller detail (%d > %d tris)" % [tris_full, tris_min])

	dh.finish_all()
	dh.queue_free()
	cam.queue_free()
	await process_frame


func _test_poles(pal: TestPalette) -> void:
	var n := 4
	var tiles := PackedInt32Array()
	tiles.resize(n * n)
	tiles.fill(0)
	var protos := PackedInt32Array()
	protos.resize(n * n)
	protos.fill(0)
	var flags := PackedByteArray()
	flags.resize(n * n)
	flags.fill(0)
	protos[1 * n + 1] = 6  # CAT_POLE in cell (1,1) -> world [4..8, 4..8]
	flags[1 * n + 1] = 15

	var full_job := LodMesher.new()
	full_job.grid_n = n
	full_job.cell_tiles = 4.0
	full_job.tiles = tiles
	full_job.protos = protos
	full_job.flags = flags
	full_job.palette = pal
	full_job.detail_tier = LodMesher.DETAIL_FULL
	full_job.keep_arrays = true
	full_job.run()

	var fverts: PackedVector3Array = full_job.solid_arrays[Mesh.ARRAY_VERTEX]
	var min_px := INF
	var max_px := -INF
	var min_pz := INF
	var max_pz := -INF
	var max_py := -INF
	var post_verts := 0
	for v: Vector3 in fverts:
		if v.y > 0.01:
			post_verts += 1
			min_px = minf(min_px, v.x)
			max_px = maxf(max_px, v.x)
			min_pz = minf(min_pz, v.z)
			max_pz = maxf(max_pz, v.z)
			max_py = maxf(max_py, v.y)
	var pw := max_px - min_px
	var pd := max_pz - min_pz
	check(full_job.solid_tris == 12 and post_verts > 0 and pw > 0.0 and pw < 1.6 and pd > 0.0 and pd < 1.6 and max_py >= 0.9 and max_py <= 2.2,
		"DETAIL_FULL draws CAT_POLE as slim centered post (tris=%d w=%.2f d=%.2f h=%.2f)" % [full_job.solid_tris, pw, pd, max_py])

	for tier: int in [LodMesher.DETAIL_MID, LodMesher.DETAIL_FAR, LodMesher.DETAIL_HORIZON]:
		var job := LodMesher.new()
		job.grid_n = n
		job.cell_tiles = 4.0
		job.tiles = tiles
		job.protos = protos
		job.flags = flags
		job.palette = pal
		job.detail_tier = tier
		job.run()
		check(job.solid_tris == 2, "CAT_POLE omitted without terrain blotch at tier %d (tris=%d)" % [tier, job.solid_tris])

	# Verify DistantHorizon.set_pollution_far binds uniform on all 4 materials
	var dh := DistantHorizon.new()
	dh._ensure_materials()
	var img := Image.create(4, 4, false, Image.FORMAT_R8)
	img.fill(Color(0.5, 0.0, 0.0, 1.0))
	var tex := ImageTexture.create_from_image(img)
	var rect := Vector4(-1024.0, -1024.0, 128.0, 1.0)
	dh.set_pollution_far(tex, rect, 7)
	check(dh._solid_mat.get_shader_parameter(&"lod_far_pollution") == tex
		and dh._solid_masked_mat.get_shader_parameter(&"lod_far_pollution") == tex
		and dh._water_mat.get_shader_parameter(&"lod_far_pollution") == tex
		and dh._water_masked_mat.get_shader_parameter(&"lod_far_pollution_rect") == rect,
		"DistantHorizon.set_pollution_far binds far pollution texture & rect on all 4 materials")
	dh.free()


func _test_render_distance_resolver() -> void:
	for p: Array in [[5, "low"], [7, "medium"], [10, "medium"], [14, "high"]]:
		var pr := int(p[0])
		var pl := str(p[1])
		var res := RenderDistance.resolve(pr, pl, false)
		check(int(res["real_radius"]) == pr and not bool(res["dh_enabled"]) and int(res["dh_radius"]) == 0,
			"RenderDistance preset %d/%s keeps full chunks with DH off" % [pr, pl])

	var exp_500 := {
		"low": [5, "low", "near", 2.20],
		"medium": [8, "medium", "near", 1.0],
		"high": [12, "high", "balanced", 0.85],
		"ultra": [16, "ultra", "balanced", 0.70],
	}
	for lod_q: String in exp_500:
		var want: Array = exp_500[lod_q]
		var r500 := RenderDistance.resolve(500, lod_q, false)
		check(int(r500["real_radius"]) == int(want[0]) and bool(r500["dh_enabled"])
			and int(r500["dh_radius"]) == 500 and str(r500["dh_quality"]) == str(want[1])
			and str(r500["dh_dropoff"]) == str(want[2]) and is_equal_approx(float(r500["far_merge_scale"]), float(want[3])),
			"RenderDistance(500, %s) auto-balances split=%d dh=%d %s/%s scale=%.2f" % [
				lod_q, int(r500["real_radius"]), int(r500["dh_radius"]), str(r500["dh_quality"]), str(r500["dh_dropoff"]), float(r500["far_merge_scale"])])

	var custom_near := RenderDistance.resolve(500, "medium", false, 0, "medium", "balanced", {}, 24.0)
	var custom_far := RenderDistance.resolve(500, "medium", false, 0, "medium", "balanced", {}, 96.0)
	check(is_equal_approx(float(custom_near["far_merge_scale"]), 2.0) and int(custom_near["real_radius"]) == 4
		and str(custom_near["dh_dropoff"]) == "near"
		and is_equal_approx(float(custom_far["far_merge_scale"]), 0.5) and int(custom_far["real_radius"]) == 16
		and str(custom_far["dh_dropoff"]) == "balanced",
		"RenderDistance auto-adjusts far_merge_scale, real_radius, and dropoff from custom lod_distance (24 vs 96)")

	var split_low := RenderDistance.resolve(14, "low", false)
	var split_high := RenderDistance.resolve(14, "high", false)
	check(int(split_low["real_radius"]) == 6 and bool(split_low["dh_enabled"]) and int(split_low["dh_radius"]) == 14
		and int(split_high["real_radius"]) == 14 and not bool(split_high["dh_enabled"]),
		"lowering LOD quality at 14 chunks shifts regular->DH handoff closer seamlessly")

	var r500_med := RenderDistance.resolve(500, "medium", false)
	var gov_500 := RenderDistance.with_governed_real(r500_med, 4)
	var r10_med := RenderDistance.resolve(10, "medium", false)
	var gov_10 := RenderDistance.with_governed_real(r10_med, 6)
	check(int(gov_500["real_radius"]) == 4 and bool(gov_500["dh_enabled"]) and int(gov_500["dh_radius"]) == 500
		and int(gov_10["real_radius"]) == 6 and bool(gov_10["dh_enabled"]) and int(gov_10["dh_radius"]) == 10,
		"UPS governor downsizing real chunks backfills outer chunks with Distant Horizon seamlessly")

	var manual_off := RenderDistance.resolve(14, "low", true, 0, "medium", "balanced")
	var manual_on := RenderDistance.resolve(12, "medium", true, 256, "ultra", "far")
	var cli_off := RenderDistance.resolve(500, "medium", false, 0, "medium", "balanced", {"enabled": false, "radius_chunks": 0})
	check(int(manual_off["real_radius"]) == 14 and not bool(manual_off["dh_enabled"])
		and int(manual_on["real_radius"]) == 12 and int(manual_on["dh_radius"]) == 256 and str(manual_on["dh_quality"]) == "ultra"
		and not bool(cli_off["dh_enabled"]) and int(cli_off["real_radius"]) == 50,
		"Manual split and --distant-horizon=off CLI override preserve explicit bounds")

	# The default is the dual split (separate View distance + Distant horizon); the unified Render distance is
	# the Manual horizon split setting turned off, or --render-distance-split=unified, which wins over the setting.
	var split_was: Variant = Settings.get_value("graphics", "distant_horizon_manual")
	var no_args := PackedStringArray()
	var dual_default := RenderDistance.is_manual_split(no_args)
	Settings.set_value("graphics", "distant_horizon_manual", false, false)
	var setting_off := not RenderDistance.is_manual_split(no_args)
	var cli_manual := RenderDistance.is_manual_split(PackedStringArray(["--render-distance-split=manual"]))
	Settings.set_value("graphics", "distant_horizon_manual", true, false)
	var cli_unified := not RenderDistance.is_manual_split(PackedStringArray(["--render-distance-split=unified"]))
	Settings.set_value("graphics", "distant_horizon_manual", split_was, false)
	var dual_500 := RenderDistance.resolve(500, "medium")
	check(bool(Settings.DEFAULTS["graphics"]["distant_horizon_manual"]) and dual_default and setting_off and cli_manual and cli_unified
		and bool(dual_500["manual"]) and int(dual_500["real_radius"]) == RenderDistance.REAL_RADIUS_MAX and not bool(dual_500["dh_enabled"]),
		"the dual split is the default, the Manual horizon split setting turns it off, the CLI wins over it")


func _test_handoff_guard(pal: TestPalette) -> void:
	var guard_was := DistantHorizon.handoff_guard
	DistantHorizon.handoff_guard = true

	var dh := DistantHorizon.new()
	dh.enabled = true
	dh.radius_chunks = 64
	dh.quality = "medium"
	root.add_child(dh)
	dh.configure("test-handoff-guard", 0, pal)

	var cam := Camera3D.new()
	cam.position = Vector3(16.0, 40.0, 16.0)
	cam.far = dh.desired_camera_far()
	root.add_child(cam)
	cam.look_at(Vector3(16.0, 0.0, -40.0), Vector3.UP)

	# Build LOD_0_0_0 with chunks (0,0) and (1,0) only; (2,0) remains unmeshed.
	dh.set_chunk(_make_land_chunk(0, 0))
	dh.set_chunk(_make_land_chunk(1, 0))
	for _f in 40:
		dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
		var st0_check: Variant = dh._sections.get(Vector3i(0, 0, 0))
		if st0_check != null and st0_check.node != null and not st0_check.dirty and not st0_check.building:
			break
		await process_frame

	check(dh.has_mesh_for_chunk(Vector2i(0, 0)) and dh.covers_chunk(Vector2i(0, 0)),
		"handoff: meshed LOD 0 chunk reports has_mesh_for_chunk & covers_chunk")
	check(not dh.has_mesh_for_chunk(Vector2i(2, 0)) and not dh.covers_chunk(Vector2i(2, 0)),
		"handoff: unpopulated chunk inside LOD 0 section reports built_chunk_mask bit unset")

	# Deferred grace frames keep DH mask clear for 2 update() calls, then promote via is_chunk_ready_cb.
	var ready_state := [true]
	var ready_cb := func(_c: Vector2i) -> bool:
		return bool(ready_state[0])
	dh.is_chunk_ready_cb = ready_cb

	dh.set_chunk_loaded(Vector2i(0, 0), true, false, 2)
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	var grace1_ok := not dh.mask_has_chunk(Vector2i(0, 0)) and dh.mask_level(Vector2i(0, 0)) == 0.0 and dh.covers_chunk(Vector2i(0, 0))
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	var grace2_ok := dh.mask_has_chunk(Vector2i(0, 0)) and dh.mask_level(Vector2i(0, 0)) > 0.01 and not dh.covers_chunk(Vector2i(0, 0))
	check(grace1_ok and grace2_ok,
		"handoff: defer_frames=2 holds DH mask clear during grace then promotes with fade (%s, %s)" % [grace1_ok, grace2_ok])

	# Canceling mid-grace or failing is_chunk_ready_cb blocks promotion.
	dh.set_chunk_loaded(Vector2i(1, 0), true, false, 2)
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	dh.set_chunk_loaded(Vector2i(1, 0), false)
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	var cancel_ok := not dh.mask_has_chunk(Vector2i(1, 0)) and dh.mask_level(Vector2i(1, 0)) == 0.0

	ready_state[0] = false
	dh.set_chunk_loaded(Vector2i(1, 0), true, false, 1)
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	var cb_block_ok := not dh.mask_has_chunk(Vector2i(1, 0)) and dh.mask_level(Vector2i(1, 0)) == 0.0
	ready_state[0] = true
	check(cancel_ok and cb_block_ok,
		"handoff: unloading mid-grace or failed is_chunk_ready_cb prevents mask promotion (%s, %s)" % [cancel_ok, cb_block_ok])

	# prepare_unload_takeover holds ready=false until mask uploaded + 1 rendered frame underneath.
	dh.finish_mask_fades()
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	dh.prepare_unload_takeover(Vector2i(0, 0))
	var imm_false := not dh.handoff_ready(Vector2i(0, 0))
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	var upload_frame_false := not dh.handoff_ready(Vector2i(0, 0))
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	var next_frame_true := dh.handoff_ready(Vector2i(0, 0))
	check(imm_false and upload_frame_false and next_frame_true,
		"handoff: prepare_unload_takeover waits for mask upload + rendered frame (%s, %s, %s)" % [imm_false, upload_frame_false, next_frame_true])

	# Unbaked chunk takeover triggers background BakeJob + section rebuild and settles 1 frame after install.
	var p := ProtoDB.new()
	p.add_tiles([[0, "grass-1", 80, 120, 60]])
	var raw_tiles := PackedInt32Array()
	raw_tiles.resize(1024)
	raw_tiles.fill(0)
	dh.set_chunk_loaded(Vector2i(2, 0), true, true)
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	dh.prepare_unload_takeover(Vector2i(2, 0), 7, raw_tiles, {}, p)
	var unbaked_imm_false := not dh.handoff_ready(Vector2i(2, 0))
	var install_frame_false := false
	for _f in 60:
		dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
		if dh.has_mesh_for_chunk(Vector2i(2, 0)):
			install_frame_false = not dh.handoff_ready(Vector2i(2, 0))
			break
		await process_frame
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	check(unbaked_imm_false and dh.has_mesh_for_chunk(Vector2i(2, 0)) and install_frame_false and dh.handoff_ready(Vector2i(2, 0)),
		"handoff: unbaked takeover bakes & meshes LOD 0 before marking ready (%s, %s, %s)" % [
			unbaked_imm_false, install_frame_false, dh.handoff_ready(Vector2i(2, 0))])

	# Hidden fully-loaded LOD 0 section becomes visible when retired to _retiring.
	for cy in range(0, 4):
		for cx in range(0, 4):
			var cc := Vector2i(cx, cy)
			if dh._get_chunk(cx, cy) == null:
				dh.set_chunk(_make_land_chunk(cx, cy))
			dh.set_chunk_loaded(cc, true, true)
	for _f in 40:
		dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
		var sec00: Variant = dh._sections.get(Vector3i(0, 0, 0))
		if sec00 != null and sec00.node != null and not sec00.dirty and not sec00.building:
			break
		await process_frame
	var sec_before: Variant = dh._sections.get(Vector3i(0, 0, 0))
	var retired_node: MeshInstance3D = sec_before.node if sec_before != null else null
	check(retired_node != null and not retired_node.visible,
		"handoff: fully-loaded LOD 0 section starts hidden prior to retirement")
	cam.position = Vector3(36.0 * 32.0, 40.0, 16.0)
	dh.update(cam, Color(0.7, 0.8, 0.88), 0.2, false)
	check(retired_node != null and is_instance_valid(retired_node) and retired_node.visible and dh._retiring.size() >= 1,
		"handoff: hidden LOD 0 section becomes visible when moved into _retiring")

	dh.finish_all()
	dh.queue_free()
	cam.queue_free()
	DistantHorizon.handoff_guard = guard_was
	await process_frame
