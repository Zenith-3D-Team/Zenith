extends SceneTree
## Verifies Forest GPU LOD & shadow stand-in optimizations (`--tree-impostor=off` rollback):
## - Tree shadow stand-ins replace alpha-tested/decimated leaf cards with compact solid
##   octahedron hulls (24-72 tris) on `shadow_stand_in_leaf.gdshader` (opaque, no `discard`,
##   preserving per-tree K4 pollution crown-hiding while keeping the trunk intact).
## - Tree view LODs add a 4th coarser far tier (~6-10% of leaf cards) while leaving LOD0
##   untouched and achieving >= 70% triangle reduction in both far view LOD and shadow stand-in.
## - `--tree-impostor=off` restores exact legacy 3-tier view LODs and decimated card shadows.
##
## Run headless:
##   godot --headless --audio-driver Dummy --path client -s res://tests/tree_lod_perf_test.gd

const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const Switches := preload("res://scripts/switches.gd")
const TestEnv := preload("res://tests/test_env.gd")

const TREE_NAMES := ["tree-01", "tree-02", "tree-03", "tree-04", "tree-05"]

var _fails := 0


func _check(ok: bool, what: String) -> void:
	if ok:
		print("ok   ", what)
	else:
		_fails += 1
		print("FAIL ", what)


func _tri_count(arrays: Array) -> int:
	var idx: Variant = arrays[Mesh.ARRAY_INDEX]
	if idx is PackedInt32Array:
		return (idx as PackedInt32Array).size() / 3
	return (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3


func _mesh_tris(mesh: ArrayMesh) -> int:
	var total := 0
	for i in mesh.get_surface_count():
		total += _tri_count(ModelLods.arrays_of(mesh, i))
	return total


func _level_tris(level: Array) -> int:
	var total := 0
	var per_surface: Array = level[1]
	for arr: Array in per_surface:
		total += _tri_count(arr)
	return total


func _card_tris_in_level(level: Array, crown: Dictionary) -> int:
	var total := 0
	var per_surface: Array = level[1]
	for si in per_surface.size():
		if not crown.has(si) or bool(crown[si]):
			continue
		var arr: Array = per_surface[si]
		var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		for t in range(0, idx.size() - 2, 3):
			if uvs[idx[t]].x >= -0.5:
				total += 1
	return total


func _load_placeholders_tree(name: String, combine: bool) -> ArrayMesh:
	var custom_dir := TestEnv.models_dir()
	var path := ""
	if custom_dir != "":
		var candidate := custom_dir.path_join("%s.glb" % name)
		if FileAccess.file_exists(candidate):
			path = candidate
	if path == "":
		var builtin := "res://assets/models/packs/placeholders/%s.glb" % name
		if FileAccess.file_exists(builtin):
			path = builtin
	if path == "":
		return null
	var loader := ModelLibrary.Load.new()
	loader.path = path
	loader.combine = combine
	loader.run()
	if not loader.ok:
		return null
	return ModelLibrary._commit_load(loader, []) as ArrayMesh


func _make_synthetic_tree() -> ArrayMesh:
	var bark_mat := ShaderMaterial.new()
	bark_mat.resource_name = "bark-synth"
	bark_mat.shader = load("res://shaders/factorio_material.gdshader") as Shader

	var leaf_mat := ShaderMaterial.new()
	leaf_mat.resource_name = "leafcard-synth"
	leaf_mat.shader = ModelLods.LeafShader

	# Trunk/branches: 240 triangles (120 quads around stacked rings)
	var bv := PackedVector3Array()
	var bn := PackedVector3Array()
	var bi := PackedInt32Array()
	var segs := 12
	var rings := 10
	for r in rings + 1:
		var y := float(r) * 0.45
		var rad := lerpf(0.35, 0.08, float(r) / float(rings))
		for s in segs:
			var ang := float(s) * TAU / float(segs)
			var dir := Vector3(cos(ang), 0.0, sin(ang))
			bv.append(Vector3(dir.x * rad, y, dir.z * rad))
			bn.append(dir)
	for r in rings:
		for s in segs:
			var s1 := (s + 1) % segs
			var a := r * segs + s
			var b := r * segs + s1
			var c := (r + 1) * segs + s1
			var d := (r + 1) * segs + s
			bi.append_array([a, b, c, a, c, d])

	var bark_arr: Array = []
	bark_arr.resize(Mesh.ARRAY_MAX)
	bark_arr[Mesh.ARRAY_VERTEX] = bv
	bark_arr[Mesh.ARRAY_NORMAL] = bn
	bark_arr[Mesh.ARRAY_INDEX] = bi

	# Crown: 256 leaf cards (512 tris) + 120 core tris
	var lv := PackedVector3Array()
	var ln := PackedVector3Array()
	var luv := PackedVector2Array()
	var luv2 := PackedVector2Array()
	var li := PackedInt32Array()
	for i in 256:
		var layer := float(i / 32)
		var ang := float(i % 32) * TAU / 32.0 + layer * 0.35
		var rad := 0.8 + 1.4 * sin((layer + 0.5) * PI / 8.0)
		var center := Vector3(cos(ang) * rad, 2.2 + layer * 0.42, sin(ang) * rad)
		var right := Vector3(-sin(ang), 0.1, cos(ang)).normalized() * 0.35
		var up := Vector3(0.0, 0.35, 0.0)
		var nrm := (center - Vector3(0.0, 2.5, 0.0)).normalized()
		var base := lv.size()
		lv.append_array([center - right - up, center + right - up, center + right + up, center - right + up])
		ln.append_array([nrm, nrm, nrm, nrm])
		luv.append_array([Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0)])
		var seed := Vector2(0.0, float((i * 37) % 97 + 1) / 100.0)
		luv2.append_array([seed, seed, seed, seed])
		li.append_array([base, base + 1, base + 2, base, base + 2, base + 3])

	for i in 120:
		var ang := float(i) * TAU / 120.0
		var base := lv.size()
		var p := Vector3(cos(ang) * 0.9, 3.0 + float(i % 5) * 0.3, sin(ang) * 0.9)
		lv.append_array([p, p + Vector3(0.25, 0.0, 0.0), p + Vector3(0.0, 0.25, 0.15)])
		ln.append_array([Vector3.UP, Vector3.UP, Vector3.UP])
		luv.append_array([Vector2(-1.0, -1.0), Vector2(-1.0, -1.0), Vector2(-1.0, -1.0)])
		luv2.append_array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
		li.append_array([base, base + 1, base + 2])

	var leaf_arr: Array = []
	leaf_arr.resize(Mesh.ARRAY_MAX)
	leaf_arr[Mesh.ARRAY_VERTEX] = lv
	leaf_arr[Mesh.ARRAY_NORMAL] = ln
	leaf_arr[Mesh.ARRAY_TEX_UV] = luv
	leaf_arr[Mesh.ARRAY_TEX_UV2] = luv2
	leaf_arr[Mesh.ARRAY_INDEX] = li

	var mesh := ArrayMesh.new()
	mesh.resource_name = "tree-synthetic"
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, bark_arr)
	mesh.surface_set_material(0, bark_mat)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, leaf_arr)
	mesh.surface_set_material(1, leaf_mat)
	mesh.set_meta(ModelLods.ARRAYS_META, [bark_arr, leaf_arr])
	return mesh


func _verify_tree(label: String, mesh: ArrayMesh) -> void:
	var lod0_tris := _mesh_tris(mesh)
	var lod0_copy := _mesh_tris(mesh)

	ModelLods.tree_impostor = true
	var job := ModelLods._job_for(mesh)
	_check(job != null and job.tree_cards and not job.crown.is_empty(), "%s: recognized as leaf-card tree job" % label)
	if job == null:
		return
	job.run()
	job.run_levels()

	_check(_mesh_tris(mesh) == lod0_copy, "%s: LOD0 source mesh remains untouched (%d tris)" % [label, lod0_tris])
	_check(job.levels.size() == ModelLods.TREE_LOD_TIERS.size() and job.levels.size() == 4,
		"%s: produces 4 view LOD tiers (%d)" % [label, job.levels.size()])

	var prev := lod0_tris
	var mono := true
	for lvl: Array in job.levels:
		var lt := _level_tris(lvl)
		if lt >= prev:
			mono = false
		prev = lt
	_check(mono, "%s: view LOD triangle counts strictly decrease (%d -> %d)" % [label, lod0_tris, prev])

	var far_level: Array = job.levels[-1]
	var far_tris := _level_tris(far_level)
	var far_cards := _card_tris_in_level(far_level, job.crown)
	var far_reduction := 1.0 - float(far_tris) / float(lod0_tris)
	_check(far_reduction >= 0.70,
		"%s: far view LOD >= 70%% tri reduction (%d -> %d tris, %.1f%%)" % [label, lod0_tris, far_tris, far_reduction * 100.0])
	_check(far_cards > 0 and far_cards <= 100,
		"%s: far view LOD crown reduces to tiny card set (%d card tris)" % [label, far_cards])

	var shadow_wood_tris := job.indices.size() / 3
	var shadow_crown_tris := job.crown_vertices.size() / 3
	var shadow_tris := shadow_wood_tris + shadow_crown_tris
	var shadow_reduction := 1.0 - float(shadow_tris) / float(lod0_tris)
	_check(shadow_wood_tris > 0, "%s: shadow stand-in keeps trunk geometry (%d wood tris)" % [label, shadow_wood_tris])
	_check(shadow_crown_tris >= 24 and shadow_crown_tris <= 72 and shadow_crown_tris % 8 == 0,
		"%s: shadow stand-in crown is compact solid octahedron hull (%d tris)" % [label, shadow_crown_tris])
	_check(shadow_reduction >= 0.70,
		"%s: shadow stand-in >= 70%% tri reduction vs LOD0 (%d -> %d tris, %.1f%%)" % [label, lod0_tris, shadow_tris, shadow_reduction * 100.0])

	var kinds := {}
	var card_seeds := {}
	for uv: Vector2 in job.crown_uvs:
		kinds[int(roundf(uv.y))] = true
		if int(roundf(uv.y)) == 0:
			card_seeds[snappedf(uv.x, 0.001)] = true
	_check(kinds.has(0) and kinds.has(1), "%s: shadow crown hull encodes card (0) and core (1) kinds for K4 pollution (%s)" % [label, str(kinds.keys())])
	_check(card_seeds.size() >= 2, "%s: shadow crown puffs carry distinct seeds (%d)" % [label, card_seeds.size()])

	# Verify --tree-impostor=off restores exact legacy 3-tier view LODs and decimated card shadows.
	ModelLods.tree_impostor = false
	var leg_job := ModelLods._job_for(mesh)
	_check(leg_job != null, "%s (--tree-impostor=off): creates legacy job" % label)
	if leg_job != null:
		leg_job.run()
		leg_job.run_levels()
		var leg_shadow_crown := leg_job.crown_vertices.size() / 3
		var leg_shadow_wood := leg_job.indices.size() / 3
		var expected_crown_v := PackedVector3Array()
		var expected_crown_uv := PackedVector2Array()
		for si in leg_job.surfaces.size():
			if leg_job.crown.has(si):
				ModelLods.Job.crown_arrays(leg_job.surfaces[si][4], bool(leg_job.crown[si]), expected_crown_v, expected_crown_uv)
		_check(leg_job.levels.size() == ModelLods.LEGACY_TREE_LOD_TIERS.size() and leg_job.levels.size() == 3,
			"%s (--tree-impostor=off): restores 3 legacy view LOD tiers (%d)" % [label, leg_job.levels.size()])
		_check(leg_shadow_crown == expected_crown_v.size() / 3 and leg_shadow_crown > shadow_crown_tris,
			"%s (--tree-impostor=off): restores legacy decimated card crown shadow (%d tris vs %d hull tris)" % [label, leg_shadow_crown, shadow_crown_tris])
		_check(leg_shadow_wood >= shadow_wood_tris,
			"%s (--tree-impostor=off): restores legacy full wood shadow (%d vs %d)" % [label, leg_shadow_wood, shadow_wood_tris])
	ModelLods.tree_impostor = true


func _verify_shader_and_proxy(mesh: ArrayMesh) -> void:
	var leaf_mat := ModelLods.leaf_material()
	var leaf_shader := leaf_mat.shader
	_check(leaf_shader != null, "shadow stand-in leaf material has a valid shader")
	if leaf_shader != null:
		var code := leaf_shader.code
		_check(not code.contains("discard"), "shadow_stand_in_leaf.gdshader has NO alpha-test discard")
		_check(code.contains("pollution_at(") and code.contains("dying >= 0.98") and code.contains("VERTEX = gone ? vec3(0.0)"),
			"shadow_stand_in_leaf.gdshader preserves K4 pollution crown-hiding in vertex shader")
	var proxy := ModelLods.proxy_for(mesh)
	_check(proxy != null, "proxy_for(tree) returns a proxy ArrayMesh")
	if proxy != null:
		var deadline := Time.get_ticks_msec() + 15000
		while not ModelLods.is_ready(proxy) and Time.get_ticks_msec() < deadline:
			ModelLods.poll()
			OS.delay_msec(10)
		_check(ModelLods.is_ready(proxy) and proxy.get_surface_count() == 2,
			"tree proxy finishes with 2 surfaces (trunk + solid crown)")
		if proxy.get_surface_count() == 2:
			_check(proxy.surface_get_material(0) == ModelLods.material_for(mesh),
				"proxy surface 0 uses opaque trunk stand-in material")
			_check(proxy.surface_get_material(1) == ModelLods.leaf_material(),
				"proxy surface 1 uses non-discard pollution-aware leaf stand-in material")


func _init() -> void:
	TestEnv.isolate("tree-lod-perf-test")
	var saved_impostor := ModelLods.tree_impostor
	if OS.get_cmdline_user_args().has("--tree-impostor=off"):
		_check(not saved_impostor, "ModelLods.tree_impostor reads --tree-impostor=off at startup")
	else:
		_check(saved_impostor, "ModelLods.tree_impostor defaults to true at startup")

	# CLI switch parsing check via Switches.set_test_args
	Switches.set_test_args(PackedStringArray(["--tree-impostor=off"]))
	_check(not Switches.on("--tree-impostor"), "Switches.on('--tree-impostor') returns false for --tree-impostor=off")
	Switches.set_test_args(PackedStringArray([]))
	_check(Switches.on("--tree-impostor"), "Switches.on('--tree-impostor') defaults to true")
	Switches.reset_cache()

	# Synthetic crown mesh (always runs even if models dir is missing)
	var synth := _make_synthetic_tree()
	_verify_tree("synthetic", synth)
	_verify_shader_and_proxy(synth)

	# Real Placeholders trees (tree-01..tree-05) in both unmerged and merged material modes
	var real_count := 0
	for name: String in TREE_NAMES:
		var plain := _load_placeholders_tree(name, false)
		var merged := _load_placeholders_tree(name, true)
		if plain == null or merged == null:
			continue
		real_count += 1
		_verify_tree("%s (plain)" % name, plain)
		_verify_tree("%s (merged)" % name, merged)
		if real_count == 1:
			_verify_shader_and_proxy(merged)
	if real_count == 0:
		print("tree_lod_perf_test: Placeholders models not present; verified on synthetic tree only")
	else:
		_check(real_count == TREE_NAMES.size(), "checked all %d real Placeholders trees (tree-01..tree-05)" % TREE_NAMES.size())

	ModelLods.tree_impostor = saved_impostor
	ModelLods.finish_all()
	TestEnv.clean()
	print("tree_lod_perf_test: %s" % ("PASS" if _fails == 0 else "FAILS %d" % _fails))
	quit(1 if _fails > 0 else 0)
