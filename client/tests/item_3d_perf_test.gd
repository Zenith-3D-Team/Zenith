extends Node
## Verifies all 3D item rendering optimizations (feat/item-3d-perf):
## - Step 1: BeltLanes far 3D cutoff, single-variant default, Early-Z opaque/cut shaders, light far PBR.
## - Step 2: 3x lattice variant gating, BELT_IGNORE_VARIANTS, contact box only on variant 0.
## - Step 3: Auto geometric LOD1 on real Placeholders GLBs, lod_material_for, ItemCards.set_lod_tier, tile_pixels.
## - Step 4: 12-tri AABB shadow proxy twins (v=0 on lattice, all variants on sim belts), item_shadow.gdshader.
## - Step 5: Precomputed MikkTSpace tangents on normal-mapped items and --item-tangents=off.
## - BeltItems integration and shader compilation/uniform checks.
##   godot --headless --audio-driver Dummy --path client res://tests/item_3d_perf_test.tscn

const BeltItems := preload("res://scripts/world/belt_items.gd")
const BeltLanes := preload("res://scripts/world/belt_lanes.gd")
const ItemCards := preload("res://scripts/world/item_cards.gd")
const ItemIcons := preload("res://scripts/world/item_icons.gd")
const ItemModels := preload("res://scripts/world/item_models.gd")
const Looks := preload("res://scripts/world/looks.gd")
const ModelPacks := preload("res://scripts/world/model_packs.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const TestEnv := preload("res://tests/test_env.gd")

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _ready() -> void:
	TestEnv.isolate("item-3d-perf-test")
	_run.call_deferred()


func _run() -> void:
	# Snapshot static switches so we restore everything cleanly at the end.
	var was_far_3d := BeltLanes.far_3d_dist
	var was_far_var := BeltLanes.far_belt_variants
	var was_far_pbr := BeltLanes.far_item_pbr_full
	var was_vcull := BeltLanes.belt_lane_vcull
	var was_geom_lod := ItemModels.item_geom_lod
	var was_item_lod := ItemModels.item_lod
	var was_lod2_mode := ItemModels.lod2_mode
	var was_tangents := ItemModels.item_tangents
	var was_glass := ItemModels.glass_blend
	var was_variants_on := ItemModels.variants_on
	# Kinds are dressed and checked in the same frame here: models read at once (--item-models-later is spikes_b_test's).
	var was_later := ItemModels.later
	ItemModels.later = false
	var was_lat_mode := ItemCards.lattice_variants_mode
	var was_lod_mode := ItemCards.lod_mode
	var was_lod_blend := ItemCards.lod_blend
	var was_proxy := ItemCards.shadow_proxy_enabled
	var was_use_models := ItemCards.use_models
	var was_model_cap := ItemCards.model_cap
	var was_lod_split := ItemCards.lod_split
	var was_cap_near := BeltItems.BeltLattice.model_cap_near
	var was_exhausted := BeltLanes.near_3d_exhausted
	var was_shadows_within := BeltItems.shadows_within

	await _test_shaders()
	var var_dir := _setup_variant_pack()
	await _test_step1_far_belts(var_dir)
	await _test_step2_lattice_variants(var_dir)
	await _test_step3_geom_lod()
	await _test_step4_shadow_proxy(var_dir)
	_test_step5_tangents()
	await _test_belt_items_integration(var_dir)
	await _test_step6_seamless_lods()
	await _test_step7_lod_split_and_caps(var_dir)

	# Restore global flags & packs.
	BeltLanes.far_3d_dist = was_far_3d
	BeltLanes.far_belt_variants = was_far_var
	BeltLanes.far_item_pbr_full = was_far_pbr
	BeltLanes.belt_lane_vcull = was_vcull
	ItemModels.item_geom_lod = was_geom_lod
	ItemModels.item_lod = was_item_lod
	ItemModels.lod2_mode = was_lod2_mode
	ItemModels.item_tangents = was_tangents
	ItemModels.glass_blend = was_glass
	ItemModels.variants_on = was_variants_on
	ItemModels.later = was_later
	ItemCards.lattice_variants_mode = was_lat_mode
	ItemCards.lod_mode = was_lod_mode
	ItemCards.lod_blend = was_lod_blend
	ItemCards.lod_split = was_lod_split
	BeltItems.BeltLattice.model_cap_near = was_cap_near
	BeltLanes.near_3d_exhausted = was_exhausted
	ItemCards.shadow_proxy_enabled = was_proxy
	ItemCards.use_models = was_use_models
	ItemCards.model_cap = was_model_cap
	BeltItems.shadows_within = was_shadows_within
	ModelPacks.configure("", [], [])
	ModelPacks.wait()

	print("item_3d_perf_test: %s" % ("PASS" if fails == 0 else "%d FAILED" % fails))
	TestEnv.clean()
	get_tree().quit(1 if fails > 0 else 0)


func _setup_variant_pack() -> String:
	var dir := ProjectSettings.globalize_path("user://perf-packs")
	var items_dir := dir.path_join("Vars/items")
	var icons_dir := dir.path_join("Vars/icons")
	DirAccess.make_dir_recursive_absolute(items_dir)
	DirAccess.make_dir_recursive_absolute(icons_dir)
	var stone_bytes := FileAccess.get_file_as_bytes(ProjectSettings.globalize_path(ItemModels.DIR + "stone.glb"))
	var coal_bytes := FileAccess.get_file_as_bytes(ProjectSettings.globalize_path(ItemModels.DIR + "coal.glb"))
	for i in [1, 2, 3]:
		var fs := FileAccess.open(items_dir.path_join("stone-%d.glb" % i), FileAccess.WRITE)
		fs.store_buffer(stone_bytes)
		fs.close()
		var fc := FileAccess.open(items_dir.path_join("coal-%d.glb" % i), FileAccess.WRITE)
		fc.store_buffer(coal_bytes)
		fc.close()
	# Add tiny deterministic PNG icons so LOD2 icon fallback works even without a Factorio install (CI).
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.8, 0.5, 0.2, 1.0))
	for icon_name: String in ["copper-cable", "iron-gear-wheel", "stone", "coal"]:
		img.save_png(icons_dir.path_join("%s.png" % icon_name))
	return dir


func _make_protos() -> ProtoDB:
	var p := ProtoDB.new()
	p.item_names = {1: "stone", 2: "coal", 3: "copper-cable", 4: "iron-plate", 5: "iron-gear-wheel"}
	p.item_ids = {"stone": 1, "coal": 2, "copper-cable": 3, "iron-plate": 4, "iron-gear-wheel": 5}
	return p


func _shader_uniforms(shader: Shader) -> PackedStringArray:
	var out := PackedStringArray()
	if shader == null:
		return out
	for u: Dictionary in shader.get_shader_uniform_list():
		out.append(str(u["name"]))
	return out


func _only_guarded_discards(shader_path: String, inc_path: String, guards: Array) -> bool:
	var sh_src := FileAccess.get_file_as_string(shader_path)
	var inc_src := FileAccess.get_file_as_string(inc_path)
	if sh_src == "" or inc_src == "":
		return false
	for g in guards:
		if sh_src.contains("#define " + str(g)):
			return false
	var stack: Array[String] = []
	for raw_line in inc_src.split("\n"):
		var line := raw_line.get_slice("//", 0).strip_edges()
		if line.begins_with("#ifdef "):
			stack.append(line.substr(7).strip_edges())
			continue
		elif line.begins_with("#ifndef "):
			stack.append("!" + line.substr(8).strip_edges())
			continue
		elif line.begins_with("#if "):
			stack.append(line.substr(4).strip_edges())
			continue
		elif line.begins_with("#elif "):
			if not stack.is_empty():
				stack[stack.size() - 1] = line.substr(6).strip_edges()
			continue
		elif line.begins_with("#else"):
			if not stack.is_empty():
				stack[stack.size() - 1] = "ELSE:" + stack[stack.size() - 1]
			continue
		elif line.begins_with("#endif"):
			if not stack.is_empty():
				stack.pop_back()
			continue
		if line.contains("discard"):
			var ok := false
			for cond in stack:
				for g in guards:
					if cond == str(g) or cond == "defined(" + str(g) + ")":
						ok = true
			if not ok:
				return false
	return true


func _tri_count(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var total := 0
	for i in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(i)
		var idx: Variant = arrays[Mesh.ARRAY_INDEX]
		if idx is PackedInt32Array and not (idx as PackedInt32Array).is_empty():
			total += (idx as PackedInt32Array).size() / 3
		else:
			var verts: Variant = arrays[Mesh.ARRAY_VERTEX]
			if verts is PackedVector3Array:
				total += (verts as PackedVector3Array).size() / 3
	return total


func _vert_count(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var total := 0
	for i in mesh.get_surface_count():
		var verts: Variant = mesh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX]
		if verts is PackedVector3Array:
			total += (verts as PackedVector3Array).size()
	return total


func _write_pbr_glb(path: String, with_tangents := false) -> bool:
	var albedo_img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	albedo_img.fill(Color(0.6, 0.3, 0.2, 1.0))
	var norm_img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	norm_img.fill(Color(0.5, 0.5, 1.0, 1.0))
	var orm_img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	orm_img.fill(Color(1.0, 0.6, 0.4, 1.0))

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = ImageTexture.create_from_image(albedo_img)
	mat.normal_enabled = true
	mat.normal_texture = ImageTexture.create_from_image(norm_img)
	mat.normal_scale = 0.9
	mat.metallic = 0.4
	mat.roughness = 0.6
	mat.metallic_texture = ImageTexture.create_from_image(orm_img)
	mat.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
	mat.roughness_texture = mat.metallic_texture
	mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN

	var box := BoxMesh.new()
	box.size = Vector3(0.25, 0.15, 0.25)
	var arrays := box.get_mesh_arrays()
	if not with_tangents:
		arrays[Mesh.ARRAY_TANGENT] = null
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, 0)
	mesh.surface_set_material(0, mat)

	var root_n := Node3D.new()
	root_n.name = "Root"
	var mi := MeshInstance3D.new()
	mi.name = "Item"
	mi.mesh = mesh
	root_n.add_child(mi)
	mi.owner = root_n

	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var ok := doc.append_from_scene(root_n, state) == OK and doc.write_to_filesystem(state, path) == OK
	root_n.free()
	if ok and not with_tangents:
		ok = _strip_glb_tangents(path)
	return ok


func _strip_glb_tangents(path: String) -> bool:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() < 20:
		return false
	var chunk_len := bytes.decode_u32(12)
	var chunk_type := bytes.decode_u32(16)
	if chunk_type != 0x4E4F534A or 20 + chunk_len > bytes.size():
		return false
	var parsed: Variant = JSON.parse_string(bytes.slice(20, 20 + chunk_len).get_string_from_utf8())
	if not (parsed is Dictionary):
		return false
	var d := parsed as Dictionary
	var meshes_v: Variant = d.get("meshes", [])
	if meshes_v is Array:
		for m in (meshes_v as Array):
			if not (m is Dictionary):
				continue
			var prims: Variant = (m as Dictionary).get("primitives", [])
			if not (prims is Array):
				continue
			for p in (prims as Array):
				if p is Dictionary:
					var attrs: Variant = (p as Dictionary).get("attributes")
					if attrs is Dictionary:
						(attrs as Dictionary).erase("TANGENT")
	var json_bytes := JSON.stringify(d).to_utf8_buffer()
	while json_bytes.size() % 4 != 0:
		json_bytes.append(0x20)
	var tail := bytes.slice(20 + chunk_len)
	var out := PackedByteArray()
	out.resize(20 + json_bytes.size() + tail.size())
	out.encode_u32(0, 0x46546C67)
	out.encode_u32(4, 2)
	out.encode_u32(8, out.size())
	out.encode_u32(12, json_bytes.size())
	out.encode_u32(16, 0x4E4F534A)
	for i in json_bytes.size():
		out[20 + i] = json_bytes[i]
	var base := 20 + json_bytes.size()
	for i in tail.size():
		out[base + i] = tail[i]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(out)
	f.close()
	return true


func _glb_has_tangent_attr(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() < 20:
		return false
	var magic := f.get_32()
	if magic != 0x46546C67:
		return false
	f.get_32()  # version
	f.get_32()  # length
	var chunk_len := f.get_32()
	var chunk_type := f.get_32()
	if chunk_type != 0x4E4F534A:
		return false
	var json_str := f.get_buffer(chunk_len).get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(json_str)
	if not (parsed is Dictionary):
		return false
	var meshes_v: Variant = (parsed as Dictionary).get("meshes", [])
	if not (meshes_v is Array):
		return false
	for m in (meshes_v as Array):
		if not (m is Dictionary):
			continue
		var prims: Variant = (m as Dictionary).get("primitives", [])
		if not (prims is Array):
			continue
		for p in (prims as Array):
			if p is Dictionary:
				var attrs: Variant = (p as Dictionary).get("attributes", {})
				if attrs is Dictionary and (attrs as Dictionary).has("TANGENT"):
					return true
	return false


func _test_shaders() -> void:
	var shader_paths := [
		"res://shaders/item.gdshader",
		"res://shaders/item_own.gdshader",
		"res://shaders/item_own_cut.gdshader",
		"res://shaders/item_own_blend.gdshader",
		"res://shaders/belt_lane_model.gdshader",
		"res://shaders/belt_lane_model_cut.gdshader",
		"res://shaders/belt_lane_model_blend.gdshader",
		"res://shaders/item_contact.gdshader",
		"res://shaders/item_shadow.gdshader",
	]
	for sp: String in shader_paths:
		var sh := load(sp) as Shader
		var unis := _shader_uniforms(sh)
		check(sh != null and not sh.code.is_empty() and not unis.is_empty(),
			"shader parses cleanly: %s (%d uniforms)" % [sp.get_file(), unis.size()])
	var lane_u := _shader_uniforms(ItemModels.LaneModelShader)
	var lane_cut_u := _shader_uniforms(ItemModels.LaneModelCutShader)
	for u: String in ["vcull", "pbr", "use_tangent", "focus", "near", "far", "use_normal", "use_orm",
			"use_own_rm", "lod_fade_start", "lod_fade_end", "lod_fade_albedo", "lod_albedo_mean"]:
		check(lane_u.has(u) and lane_cut_u.has(u),
			"belt_lane_model & cut shaders expose uniform '%s'" % u)
	var item_u := _shader_uniforms(ItemModels.ItemShader)
	var own_u := _shader_uniforms(ItemModels.ItemOwnShader)
	var own_cut_u := _shader_uniforms(ItemModels.ItemOwnCutShader)
	for u: String in ["pbr", "use_tangent", "alpha_mode", "emission_picture", "picture",
			"lod_jitter", "lod_fade_start", "lod_fade_end", "lod_roughness", "lod_metallic",
			"lod_fade_albedo", "lod_albedo_mean", "use_own_rm"]:
		check(item_u.has(u) and own_u.has(u) and own_cut_u.has(u),
			"item, item_own & cut shaders expose uniform '%s'" % u)
	var card_u := _shader_uniforms(ItemCards.CardShader)
	check(card_u.has("lod_jitter"), "item_card.gdshader exposes uniform 'lod_jitter'")
	var shadow_u := _shader_uniforms(ItemModels.ItemShadowShader)
	for u: String in ["shadow_cam", "shadow_max_sq", "belt_paths"]:
		check(shadow_u.has(u), "item_shadow.gdshader exposes uniform '%s'" % u)
	var bp_u_src := FileAccess.get_file_as_string("res://shaders/belt_path.gdshaderinc")
	check(bp_u_src.contains("instance uniform int belt_base") and bp_u_src.contains("instance uniform int belt_tex"),
		"belt_path.gdshaderinc declares instance uniforms belt_base & belt_tex for item_shadow.gdshader")
	check(_only_guarded_discards("res://shaders/item_own.gdshader", "res://shaders/item_body.gdshaderinc", ["ITEM_CUT"]),
		"item_own.gdshader opaque path has zero unguarded discard;")
	check(_only_guarded_discards("res://shaders/belt_lane_model.gdshader", "res://shaders/belt_lane_model.gdshaderinc",
		["LANE_FRAG_CULL", "ITEM_CUT", "ITEM_BLEND"]),
		"belt_lane_model.gdshader opaque path only discards inside LANE_FRAG_CULL / ITEM_CUT / ITEM_BLEND")
	await get_tree().process_frame


func _test_step1_far_belts(var_dir: String) -> void:
	ModelPacks.configure(var_dir, ["dir:Vars", "builtin:placeholders"], [])
	ModelPacks.wait()
	ItemModels.variants_on = true
	ItemCards.use_models = true
	ItemCards.model_cap = -1

	check(is_equal_approx(BeltLanes.far_3d_dist, 48.0) and is_equal_approx(BeltLanes.FAR_3D_HYSTERESIS, 8.0),
		"Step 1: default far_3d_dist=48.0 and FAR_3D_HYSTERESIS=8.0")
	check(not BeltLanes.far_belt_variants, "Step 1: far_belt_variants defaults to false")
	check(not BeltLanes.far_item_pbr_full, "Step 1: far_item_pbr_full defaults to false")
	check(BeltLanes.belt_lane_vcull, "Step 1: belt_lane_vcull defaults to true")

	var bl := BeltLanes.new()
	bl.sync = true
	bl.protos = _make_protos()
	add_child(bl)
	bl._follow_models()

	# _want_chunk_3d cutoff + hysteresis + "all" mode.
	bl.covered = Vector3(44.0, 16.0, 10.0)
	check(bl._want_chunk_3d(Vector2i(0, 0)), "Step 1: near chunk (0,0) wants 3D")
	check(bl._want_chunk_3d(Vector2i(2, 0)), "Step 1: chunk (2,0) dx=20 <= 48 wants 3D")
	check(not bl._want_chunk_3d(Vector2i(3, 0)), "Step 1: chunk (3,0) dx=52 > 48 skips LOD1 initially")
	bl._chunk_3d[Vector2i(3, 0)] = true
	check(bl._want_chunk_3d(Vector2i(3, 0)), "Step 1: chunk (3,0) dx=52 <= 48+8 keeps 3D inside hysteresis band")
	bl.covered = Vector3(39.0, 16.0, 10.0)  # dx = 96 - 39 = 57 > 56
	check(not bl._want_chunk_3d(Vector2i(3, 0)), "Step 1: chunk (3,0) dx=57 > 56 drops 3D past hysteresis")
	bl._chunk_3d.clear()
	BeltLanes.far_3d_dist = -1.0
	check(bl._want_chunk_3d(Vector2i(50, 50)), "Step 1: far_3d_dist < 0 ('all' mode) keeps distant chunks 3D")
	BeltLanes.far_3d_dist = 0.0
	check(not bl._want_chunk_3d(Vector2i(0, 0)), "Step 1: far_3d_dist == 0 disables far 3D models")
	BeltLanes.far_3d_dist = 48.0
	bl.covered = Vector3(16.0, 16.0, 10.0)

	# Job.run() with use_3d=true vs use_3d=false, and far_belt_variants false vs true.
	var l: Array = []
	var c_arr: Array = []
	for b in 20:
		l.append_array([(b * 2 + 1) * 128, 128, 4, 1, 1])
		c_arr.append_array([4, 4])
	for fv in [false, true]:
		BeltLanes.far_belt_variants = fv
		var job := BeltLanes.Job.new()
		job.variants = {1: 3}
		job.steps = {1: 0.09}
		job.msgs = [
			[Vector2i(0, 0), l, c_arr, [], true],
			[Vector2i(4, 0), l, c_arr, [], false],
		]
		job.run()
		var near_built: Dictionary = job.results[0][1]
		var far_built: Dictionary = job.results[1][1]
		var near_total := BeltLanes.Job.icon_count(near_built)
		var far_total := BeltLanes.Job.icon_count(far_built)
		if not fv:
			check(near_built.size() == 1 and near_built.has(1) and near_total == 160,
				"Step 1: far_belt_variants=false collapses 3D chunk into 1 key (keys=%s, total=%d)" % [near_built.keys(), near_total])
		else:
			check(near_built.size() == 3 and near_total == 160,
				"Step 1: far_belt_variants=true splits 3D chunk into 3 variant keys (keys=%s, total=%d)" % [near_built.keys(), near_total])
		check(far_built.size() == 1 and far_built.has(1) and far_total == 160
			and job.results[1][2] == null and bool(job.results[1][3]) == false,
			"Step 1: past-cutoff chunk (use_3d=false, fv=%s) always emits 1 key and omits steps" % str(fv))
	BeltLanes.far_belt_variants = false

	# _make(..., false) draws 10-tri LOD2 proxy under lod2_mode='proxy', or 2-tri _quad under 'icon'.
	var built_icon: Dictionary = BeltLanes.Job.build(l, c_arr, 0.2)
	ItemModels.lod2_mode = "proxy"
	bl._make(Vector2i(4, 0), built_icon, false)
	var proxy_node: Node3D = bl._chunks.get(Vector2i(4, 0))
	var proxy_inst := proxy_node.get_child(0) as MultiMeshInstance3D if proxy_node != null and proxy_node.get_child_count() > 0 else null
	check(proxy_inst != null and ItemModels.is_lod2(proxy_inst.multimesh.mesh) and _tri_count(proxy_inst.multimesh.mesh) == 10
		and proxy_inst.material_override is ShaderMaterial
		and (proxy_inst.material_override as ShaderMaterial).shader == Looks.shader_for(BeltLanes.LaneModelShader),
		"Step 1: _make(false) draws 10-tri LOD2 proxy with LaneModelShader by default")

	ItemModels.lod2_mode = "icon"
	bl._make(Vector2i(4, 0), built_icon, false)
	var far_node: Node3D = bl._chunks.get(Vector2i(4, 0))
	var far_inst := far_node.get_child(0) as MultiMeshInstance3D if far_node != null and far_node.get_child_count() > 0 else null
	check(far_inst != null and far_inst.multimesh.mesh == bl._quad and _tri_count(far_inst.multimesh.mesh) == 2
		and far_inst.material_override == bl._material(1)
		and (far_inst.material_override as ShaderMaterial).shader == BeltLanes.LaneShader,
		"Step 1: _make(false) draws 2-tri _quad with LaneShader under --item-lod2=icon")
	ItemModels.lod2_mode = "proxy"

	var built_3d: Dictionary = BeltLanes.Job.build(l, c_arr, 0.2, [], {1: 0.09})
	bl._make(Vector2i(0, 0), built_3d, true)
	var near_node: Node3D = bl._chunks.get(Vector2i(0, 0))
	var near_inst := near_node.get_child(0) as MultiMeshInstance3D if near_node != null and near_node.get_child_count() > 0 else null
	check(near_inst != null and near_inst.multimesh.mesh != bl._quad
		and near_inst.material_override is ShaderMaterial
		and (near_inst.material_override as ShaderMaterial).shader == Looks.shader_for(BeltLanes.LaneModelShader),
		"Step 1: _make(true) draws 3D mesh with LaneModelShader")

	# _model_material(): Early-Z shader swap on vcull + light far PBR vs full far PBR + cache identity.
	var pbr_dir := ProjectSettings.globalize_path("user://perf-pbr-pack")
	DirAccess.make_dir_recursive_absolute(pbr_dir.path_join("PbrPack/items"))
	var pj := FileAccess.open(pbr_dir.path_join("PbrPack/pack.json"), FileAccess.WRITE)
	pj.store_string(JSON.stringify({"name": "PerfPbr", "shading": "pbr"}))
	pj.close()
	var pbr_glb := pbr_dir.path_join("PbrPack/items/test-pbr.glb")
	check(_write_pbr_glb(pbr_glb, false), "Step 1: wrote PBR test GLB")
	ModelPacks.configure(pbr_dir, ["dir:PbrPack", "builtin:placeholders"], [])
	ModelPacks.wait()
	var pbr_mesh := ItemModels.read(pbr_glb)
	check(pbr_mesh != null and ItemModels.pbr_material(pbr_mesh) != null, "Step 1: read PBR item mesh with PBR_META")

	BeltLanes.far_item_pbr_full = false
	BeltLanes.belt_lane_vcull = true
	var mat_light := bl._model_material(77, pbr_mesh, pbr_mesh)
	check(mat_light.shader == Looks.shader_for(BeltLanes.LaneModelShader)
		and bool(mat_light.get_shader_parameter("vcull")) == true
		and bool(mat_light.get_shader_parameter("pbr")) == true
		and is_equal_approx(float(mat_light.get_shader_parameter("pbr_roughness")), 0.36)
		and is_equal_approx(float(mat_light.get_shader_parameter("pbr_metallic")), 0.16)
		and mat_light.get_shader_parameter("use_normal") != true
		and mat_light.get_shader_parameter("use_orm") != true,
		"Step 1: default far PBR uses LaneModelShader, folds ORM into scalar roughness/metallic (0.36/0.16), skips normal/orm fetches")

	BeltLanes.belt_lane_vcull = false
	bl._set_params()
	check(mat_light.shader == Looks.shader_for(ItemModels.LaneModelCutShader)
		and bool(mat_light.get_shader_parameter("vcull")) == false,
		"Step 1: belt_lane_vcull=false switches _model_material to LaneModelCutShader and vcull=false")
	BeltLanes.belt_lane_vcull = true
	bl._set_params()
	check(mat_light.shader == Looks.shader_for(BeltLanes.LaneModelShader)
		and bool(mat_light.get_shader_parameter("vcull")) == true,
		"Step 1: belt_lane_vcull=true restores LaneModelShader and vcull=true")

	# Verify cache invalidates when src_mesh changes for the same item key, even if both lack pictures/PBR.
	var stone_m := ItemModels.read(ItemModels.DIR + "stone.glb")
	var coal_m := ItemModels.read(ItemModels.DIR + "coal.glb")
	var mat_s := bl._model_material(88, stone_m, stone_m)
	var mat_c := bl._model_material(88, coal_m, coal_m)
	check(mat_s != mat_c, "Step 1: _model_material invalidates cache when src_mesh changes")

	# Verify --belt-lane-vcull=off keeps LaneModelBlendShader on see-through own-look glass surfaces + fragment cull.
	var glass_glb := pbr_dir.path_join("glass-item.glb")
	var glass_mat := StandardMaterial3D.new()
	glass_mat.albedo_color = Color(0.7, 0.9, 1.0, 0.5)
	glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var box_g := BoxMesh.new()
	box_g.size = Vector3(0.2, 0.2, 0.2)
	var g_arr := box_g.get_mesh_arrays()
	var g_mesh := ArrayMesh.new()
	g_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, g_arr)
	g_mesh.surface_set_material(0, glass_mat)
	var g_root := Node3D.new()
	g_root.name = "G"
	var g_mi := MeshInstance3D.new()
	g_mi.name = "M"
	g_mi.mesh = g_mesh
	g_root.add_child(g_mi)
	g_mi.owner = g_root
	var g_doc := GLTFDocument.new()
	var g_state := GLTFState.new()
	g_doc.append_from_scene(g_root, g_state)
	g_doc.write_to_filesystem(g_state, glass_glb)
	g_root.free()
	var own_glass := ItemModels.read(glass_glb)
	var dressed_cut := ItemModels.dressed(own_glass, ItemModels.LaneModelCutShader)
	var g_smat := dressed_cut.surface_get_material(0) as ShaderMaterial if dressed_cut != null else null
	var blend_inc_src := FileAccess.get_file_as_string("res://shaders/belt_lane_model.gdshaderinc")
	check(g_smat != null and g_smat.shader == Looks.shader_for(ItemModels.LaneModelBlendShader)
		and blend_inc_src.contains("#elif defined(ITEM_BLEND)") and blend_inc_src.contains("if (!vcull)"),
		"Step 1: --belt-lane-vcull=off keeps LaneModelBlendShader on see-through glass and culls in fragment when !vcull")

	BeltLanes.far_item_pbr_full = true
	var mat_full := bl._model_material(77, pbr_mesh, pbr_mesh)
	check(mat_full.get_shader_parameter("use_normal") == true
		and mat_full.get_shader_parameter("use_orm") == true,
		"Step 1: far_item_pbr_full=true binds normal and ORM textures via set_pbr()")
	BeltLanes.far_item_pbr_full = false

	bl.queue_free()
	await get_tree().process_frame


func _test_step2_lattice_variants(var_dir: String) -> void:
	# Shader source checks: BELT_IGNORE_VARIANTS and variant gating before belt_lattice_turn.
	var contact_src := FileAccess.get_file_as_string("res://shaders/item_contact.gdshader")
	check(contact_src.contains("#define BELT_IGNORE_VARIANTS"),
		"Step 2: item_contact.gdshader defines #define BELT_IGNORE_VARIANTS")
	var bp_src := FileAccess.get_file_as_string("res://shaders/belt_path.gdshaderinc")
	var ifndef_at := bp_src.find("#ifndef BELT_IGNORE_VARIANTS")
	var bvar_at := bp_src.find("belt_variants > 1")
	var endif_at := bp_src.find("#endif", ifndef_at)
	var turn_at := bp_src.find("belt_lattice_turn(", endif_at)
	check(ifndef_at >= 0 and bvar_at > ifndef_at and endif_at > bvar_at and turn_at > endif_at,
		"Step 2: belt_path.gdshaderinc wraps belt_variants > 1 in #ifndef BELT_IGNORE_VARIANTS before belt_lattice_turn()")

	ModelPacks.configure(var_dir, ["dir:Vars", "builtin:placeholders"], [])
	ModelPacks.wait()
	ItemModels.variants_on = true
	ItemCards.use_models = true
	ItemCards.model_cap = -1
	ItemCards.lattice_variants_mode = "close"

	var protos := _make_protos()
	check(ItemModels.variant_count("stone") == 3 and ItemModels.variant_count("coal") == 3,
		"Step 2: stone and coal have 3 variants configured")

	var cards := ItemCards.new()
	cards.contact = true
	cards.record_tex = 1
	cards.protos = protos
	add_child(cards)
	var bounds := AABB(Vector3(-16, -1, -16), Vector3(32, 4, 32))
	cards.put_records(1, 0, 12, 16, bounds)
	cards.put_records(2, 16, 12, 16, bounds)

	var step := ItemCards.VARIANT_STEP
	for item_id in [1, 2]:
		var mmi0: MultiMeshInstance3D = cards._kinds.get(item_id)
		var mmi1: MultiMeshInstance3D = cards._kinds.get(item_id + step)
		var mmi2: MultiMeshInstance3D = cards._kinds.get(item_id + 2 * step)
		check(mmi0 != null and mmi1 != null and mmi2 != null,
			"Step 2: item %d creates v=0,1,2 MultiMeshes" % item_id)
		if mmi0 != null and mmi1 != null and mmi2 != null:
			var sc0 := mmi0.multimesh.mesh.get_surface_count()
			var sc1 := mmi1.multimesh.mesh.get_surface_count()
			var sc2 := mmi2.multimesh.mesh.get_surface_count()
			var cmat0 := mmi0.multimesh.mesh.surface_get_material(sc0 - 1) as ShaderMaterial
			check(cmat0 != null and cmat0.shader == ItemCards.ContactShader,
				"Step 2: item %d v=0 has contact box surface (%d surfaces)" % [item_id, sc0])
			var v1_has_contact := false
			for s in sc1:
				var sm := mmi1.multimesh.mesh.surface_get_material(s) as ShaderMaterial
				if sm != null and sm.shader == ItemCards.ContactShader:
					v1_has_contact = true
			var v2_has_contact := false
			for s in sc2:
				var sm := mmi2.multimesh.mesh.surface_get_material(s) as ShaderMaterial
				if sm != null and sm.shader == ItemCards.ContactShader:
					v2_has_contact = true
			check(not v1_has_contact and not v2_has_contact and sc0 == sc1 + 1 and sc0 == sc2 + 1,
				"Step 2: item %d v=1,2 have NO contact box surface (%d vs %d, %d)" % [item_id, sc0, sc1, sc2])
			check(int(mmi0.get_instance_shader_parameter("belt_variants")) == 3
				and int(mmi0.get_instance_shader_parameter("belt_variant")) == 0
				and int(mmi1.get_instance_shader_parameter("belt_variants")) == 3
				and int(mmi1.get_instance_shader_parameter("belt_variant")) == 1 and mmi1.visible
				and int(mmi2.get_instance_shader_parameter("belt_variants")) == 3
				and int(mmi2.get_instance_shader_parameter("belt_variant")) == 2 and mmi2.visible,
				"Step 2: item %d initial belt_variants=3 and v=1,2 visible=true" % item_id)

	cards.set_lattice_variants_active(false)
	var s0: MultiMeshInstance3D = cards._kinds[1]
	var s1: MultiMeshInstance3D = cards._kinds[1 + step]
	var s2: MultiMeshInstance3D = cards._kinds[1 + 2 * step]
	check(int(s0.get_instance_shader_parameter("belt_variants")) == 0
		and not s1.visible and not s2.visible,
		"Step 2: set_lattice_variants_active(false) sets belt_variants=0 on v=0 and hides v=1,2")

	cards.set_lattice_variants_active(true)
	check(int(s0.get_instance_shader_parameter("belt_variants")) == 3
		and s1.visible and s2.visible,
		"Step 2: set_lattice_variants_active(true) restores belt_variants=3 and v=1,2 visible")

	ItemCards.lattice_variants_mode = "all"
	cards.set_lattice_variants_active(false)
	check(cards.lattice_variants_active and s1.visible and s2.visible,
		"Step 2: lattice_variants_mode='all' ignores set_lattice_variants_active(false)")

	ItemCards.lattice_variants_mode = "off"
	var off_cards := ItemCards.new()
	off_cards.contact = true
	off_cards.record_tex = 1
	off_cards.protos = protos
	add_child(off_cards)
	off_cards.put_records(1, 0, 12, 16, bounds)
	check(off_cards._kinds.has(1) and not off_cards._kinds.has(1 + step) and not off_cards._kinds.has(1 + 2 * step),
		"Step 2: lattice_variants_mode='off' skips spawning v=1,2")
	ItemCards.lattice_variants_mode = "close"

	cards.queue_free()
	off_cards.queue_free()
	await get_tree().process_frame


func _test_step3_geom_lod() -> void:
	ModelPacks.configure("", [], [])
	ModelPacks.wait()
	ItemModels.item_geom_lod = true

	var dense_items := ["copper-cable", "iron-gear-wheel", "advanced-circuit", "electronic-circuit", "coal"]
	for name: String in dense_items:
		var m := ItemModels.read(ItemModels.DIR + name + ".glb")
		check(m != null, "Step 3: loaded real Placeholders %s.glb" % name)
		if m == null:
			continue
		var orig_tris := _tri_count(m)
		var orig_verts := _vert_count(m)
		var orig_surfs := m.get_surface_count()
		var lod := ItemModels.lod_mesh(m)
		var lod_tris := _tri_count(lod)
		var lod_verts := _vert_count(lod)
		var lod_surfs := lod.get_surface_count()
		print("LOD1_MEASURE %s: tris %d -> %d (%.1f%%), verts %d -> %d, surfs %d -> %d" % [
			name, orig_tris, lod_tris, 100.0 * float(lod_tris) / maxf(1.0, float(orig_tris)),
			orig_verts, lod_verts, orig_surfs, lod_surfs])
		var arrays := lod.surface_get_arrays(0)
		check(lod_tris <= int(orig_tris * 0.70) and lod_tris <= maxi(64, int(orig_tris * 0.50)),
			"Step 3: %s reduces tris >= 30%% and <= max(64, 50%%) (%d -> %d)" % [name, orig_tris, lod_tris])
		check(lod_verts < orig_verts,
			"Step 3: %s compacts vertex arrays (%d -> %d)" % [name, orig_verts, lod_verts])
		check(lod_surfs == 1 and not ItemModels.has_tangents(lod),
			"Step 3: %s LOD1 is 1 surface and drops tangents metadata" % name)

	var plate := ItemModels.read(ItemModels.DIR + "iron-plate.glb")
	check(plate != null, "Step 3: loaded Placeholders iron-plate.glb")
	if plate != null:
		var pt := _tri_count(plate)
		var pv := _vert_count(plate)
		var plate_lod := ItemModels.lod_mesh(plate)
		print("LOD1_MEASURE iron-plate: tris %d -> %d, verts %d -> %d, same=%s" % [
			pt, _tri_count(plate_lod), pv, _vert_count(plate_lod), str(plate_lod == plate)])
		check(pt <= ItemModels.LOD1_MIN_TRIS and plate_lod == plate,
			"Step 3: iron-plate (%d tris <= %d) stays intact at LOD1" % [pt, ItemModels.LOD1_MIN_TRIS])

	# lod_material_for: uses ItemShader and drops normal/orm/tangent even on PBR items.
	var cable := ItemModels.read(ItemModels.DIR + "copper-cable.glb")
	var lmat := ItemModels.lod_material_for(cable)
	check(lmat != null and lmat.shader == Looks.shader_for(ItemModels.ItemShader)
		and lmat.get_shader_parameter("use_normal") != true
		and lmat.get_shader_parameter("use_orm") != true
		and lmat.get_shader_parameter("use_tangent") != true,
		"Step 3: lod_material_for(copper-cable) uses ItemShader without normal/orm/tangent")

	var pbr_dir := ProjectSettings.globalize_path("user://perf-pbr-lod")
	DirAccess.make_dir_recursive_absolute(pbr_dir.path_join("PbrLod/items"))
	var pj := FileAccess.open(pbr_dir.path_join("PbrLod/pack.json"), FileAccess.WRITE)
	pj.store_string(JSON.stringify({"name": "PbrLod", "shading": "pbr"}))
	pj.close()
	var pbr_path := pbr_dir.path_join("PbrLod/items/pbr-lod.glb")
	_write_pbr_glb(pbr_path, false)
	ModelPacks.configure(pbr_dir, ["dir:PbrLod", "builtin:placeholders"], [])
	ModelPacks.wait()
	var pbr_item := ItemModels.read(pbr_path)
	var pbr_lmat := ItemModels.lod_material_for(pbr_item)
	check(pbr_lmat != null and pbr_lmat.shader == Looks.shader_for(ItemModels.ItemShader)
		and pbr_lmat.get_shader_parameter("pbr") == true
		and is_equal_approx(float(pbr_lmat.get_shader_parameter("pbr_roughness")), 0.36)
		and is_equal_approx(float(pbr_lmat.get_shader_parameter("pbr_metallic")), 0.16)
		and pbr_lmat.get_shader_parameter("use_normal") != true
		and pbr_lmat.get_shader_parameter("use_orm") != true
		and pbr_lmat.get_shader_parameter("use_tangent") != true,
		"Step 3: lod_material_for on PBR mesh folds ORM into scalar roughness/metallic (0.36/0.16) and skips normal/orm/tangent")

	# --item-geom-lod=off switch restores un-decimated mesh.
	ItemModels.item_geom_lod = false
	check(ItemModels.lod_mesh(cable) == cable, "Step 3: --item-geom-lod=off returns original mesh")
	ItemModels.item_geom_lod = true

	# ItemCards in global LOD mode with allow_lod = true: set_lod_tier(1), (2), (0) swaps mesh without reallocating buffer.
	var prev_lod_mode := ItemCards.lod_mode
	ItemCards.lod_mode = "global"
	ModelPacks.configure("", [], [])
	ModelPacks.wait()
	var icon_img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	icon_img.fill(Color(0.9, 0.5, 0.2, 1.0))
	ItemIcons.is_cached("copper-cable")
	ItemIcons.store("copper-cable", ImageTexture.create_from_image(icon_img))

	var cards := ItemCards.new()
	cards.allow_lod = true
	cards.contact = false
	cards.protos = _make_protos()
	add_child(cards)
	var buf := cards.take(3, 4)
	for i in 4:
		ItemCards.write(buf, i * ItemCards.STRIDE, Vector3(float(i), 0.2, 0.0), 1.0, 0.0, Vector3.ZERO)
	cards.commit(3, buf, 4)
	var mmi: MultiMeshInstance3D = cards._kinds[3]
	var mesh0 := mmi.multimesh.mesh
	var mat0 := mmi.material_override
	var cap0 := mmi.multimesh.instance_count
	var vis0 := mmi.multimesh.visible_instance_count
	var buf_snap := mmi.multimesh.buffer.duplicate()

	cards.set_lod_tier(1)
	var mesh1 := mmi.multimesh.mesh
	check(cards.lod_tier == 1 and mesh1 != mesh0 and _tri_count(mesh1) < _tri_count(mesh0)
		and mmi.multimesh.instance_count == cap0 and mmi.multimesh.visible_instance_count == vis0
		and mmi.multimesh.buffer == buf_snap,
		"Step 3: set_lod_tier(1) swaps to LOD1 (%d -> %d tris) without touching instance buffer" % [_tri_count(mesh0), _tri_count(mesh1)])

	ItemModels.lod2_mode = "proxy"
	cards.set_lod_tier(2)
	var mesh2_proxy := mmi.multimesh.mesh
	check(cards.lod_tier == 2 and ItemModels.is_lod2(mesh2_proxy) and _tri_count(mesh2_proxy) == 10
		and mmi.multimesh.instance_count == cap0 and mmi.multimesh.visible_instance_count == vis0
		and mmi.multimesh.buffer == buf_snap,
		"Step 3: set_lod_tier(2) swaps to 10-tri LOD2 proxy without touching instance buffer")

	cards.set_lod_tier(0)
	check(cards.lod_tier == 0 and mmi.multimesh.mesh == mesh0 and mmi.material_override == mat0
		and mmi.multimesh.buffer == buf_snap,
		"Step 3: set_lod_tier(0) restores LOD0 mesh, material, and instance buffer")

	ItemModels.lod2_mode = "icon"
	cards.reset()
	buf = cards.take(3, 4)
	for i in 4:
		ItemCards.write(buf, i * ItemCards.STRIDE, Vector3(float(i), 0.2, 0.0), 1.0, 0.0, Vector3.ZERO)
	cards.commit(3, buf, 4)
	mmi = cards._kinds[3]
	cards.set_lod_tier(2)
	var mesh2_icon := mmi.multimesh.mesh
	check(cards.lod_tier == 2 and mesh2_icon == ItemCards._card() and _tri_count(mesh2_icon) == 2,
		"Step 3: --item-lod2=icon restores 2-tri icon card at LOD2")
	ItemModels.lod2_mode = "proxy"

	var no_lod := ItemCards.new()
	no_lod.allow_lod = false
	no_lod.protos = _make_protos()
	add_child(no_lod)
	no_lod.prepare(3)
	no_lod.set_lod_tier(1)
	check(no_lod.lod_tier == 0 and no_lod._kinds[3].multimesh.mesh != mesh1,
		"Step 3: allow_lod=false keeps lod_tier at 0")
	ItemCards.lod_mode = prev_lod_mode

	# ItemCards.tile_pixels() math for perspective, orthogonal, and 1080p MAX_LOD_LINES clamp.
	var cam := Camera3D.new()
	add_child(cam)
	cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	cam.fov = 50.0
	cam.global_position = Vector3(0.0, 20.0, 0.0)
	var expect_persp := 1080.0 / (2.0 * 20.0 * tan(deg_to_rad(25.0)))
	var px_1080 := ItemCards.tile_pixels(cam, Vector3.ZERO, 1080.0)
	var px_4k := ItemCards.tile_pixels(cam, Vector3.ZERO, 2160.0)
	var px_720 := ItemCards.tile_pixels(cam, Vector3.ZERO, 720.0)
	check(is_equal_approx(px_1080, expect_persp) and is_equal_approx(px_4k, expect_persp)
		and is_equal_approx(px_720, expect_persp * (720.0 / 1080.0)),
		"Step 3: tile_pixels perspective & MAX_LOD_LINES 1080p clamp (1080=%.2f, 4K=%.2f, 720=%.2f)" % [px_1080, px_4k, px_720])
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 30.0
	check(is_equal_approx(ItemCards.tile_pixels(cam, Vector3.ZERO, 1080.0), 36.0)
		and is_equal_approx(ItemCards.tile_pixels(cam, Vector3.ZERO, 2160.0), 36.0),
		"Step 3: tile_pixels orthogonal & 1080p clamp (36.0 px/tile)")

	cam.queue_free()
	cards.queue_free()
	no_lod.queue_free()
	await get_tree().process_frame


func _test_step4_shadow_proxy(var_dir: String) -> void:
	# 1. shadow_box_mesh geometry, outward clockwise winding, and >= 0.02 min thickness clamp.
	var cable := ItemModels.read(ItemModels.DIR + "copper-cable.glb")
	var sbox := ItemModels.shadow_box_mesh(cable)
	check(sbox != null and sbox is ArrayMesh and sbox.get_surface_count() == 1,
		"Step 4: shadow_box_mesh returns 1-surface ArrayMesh")
	if sbox != null and sbox.get_surface_count() == 1:
		var sa := sbox.surface_get_arrays(0)
		var sv: PackedVector3Array = sa[Mesh.ARRAY_VERTEX]
		var si: PackedInt32Array = sa[Mesh.ARRAY_INDEX]
		var box := cable.get_aabb()
		var sbox_aabb := sbox.get_aabb()
		var mid := sbox_aabb.get_center()
		var outward := 0
		for t in range(0, si.size(), 3):
			var v0 := sv[si[t]]
			var v1 := sv[si[t + 1]]
			var v2 := sv[si[t + 2]]
			if (v2 - v0).cross(v1 - v0).dot((v0 + v1 + v2) / 3.0 - mid) > 0.0:
				outward += 1
		check(sv.size() == 8 and si.size() == 36 and outward == 12,
			"Step 4: shadow_box_mesh has 8 verts, 36 indices, 12 outward clockwise tris (%d/%d/%d)" % [sv.size(), si.size(), outward])
		var box_ok := sbox_aabb.get_center().is_equal_approx(box.get_center()) \
			and sbox_aabb.size.x >= 0.01999 and sbox_aabb.size.y >= 0.01999 and sbox_aabb.size.z >= 0.01999 \
			and is_equal_approx(sbox_aabb.size.x, maxf(box.size.x, 0.02)) \
			and is_equal_approx(sbox_aabb.size.y, maxf(box.size.y, 0.02)) \
			and is_equal_approx(sbox_aabb.size.z, maxf(box.size.z, 0.02))
		check(box_ok,
			"Step 4: shadow_box_mesh matches AABB with >= 0.02 min extent")

	var flat := ArrayMesh.new()
	var fa := []
	fa.resize(Mesh.ARRAY_MAX)
	fa[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-0.15, 0.0, -0.1), Vector3(0.15, 0.0, -0.1), Vector3(0.0, 0.0, 0.1)])
	fa[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	flat.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, fa)
	var flat_box := ItemModels.shadow_box_mesh(flat)
	check(flat_box != null and is_equal_approx(flat_box.get_aabb().size.y, 0.02),
		"Step 4: flat mesh shadow box clamps zero Y thickness to 0.02")

	# 2. ItemCards with use_shadow_proxy=true, record_tex=1, 3-variant stone.
	ModelPacks.configure(var_dir, ["dir:Vars", "builtin:placeholders"], [])
	ModelPacks.wait()
	ItemCards.shadow_proxy_enabled = true
	ItemCards.lattice_variants_mode = "close"
	ItemModels.variants_on = true

	var cards := ItemCards.new()
	cards.use_shadow_proxy = true
	cards.record_tex = 1
	cards.contact = true
	cards.casts_shadow = true
	cards.render_layers = ItemCards.BELT_LAYER
	cards.protos = _make_protos()
	add_child(cards)

	var bounds := AABB(Vector3(-8, -1, -8), Vector3(16, 4, 16))
	cards.put_records(1, 42, 6, 12, bounds)
	var step := ItemCards.VARIANT_STEP
	var mmi0: MultiMeshInstance3D = cards._kinds.get(1)
	var mmi1: MultiMeshInstance3D = cards._kinds.get(1 + step)
	var mmi2: MultiMeshInstance3D = cards._kinds.get(1 + 2 * step)
	var smmi0: MultiMeshInstance3D = cards._shadow_kinds.get(1)
	check(smmi0 != null and not cards._shadow_kinds.has(1 + step) and not cards._shadow_kinds.has(1 + 2 * step),
		"Step 4: shadow proxy twin created ONLY for v=0 (not v=1,2)")
	if smmi0 != null:
		check(smmi0.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
			and smmi0.layers == ItemCards.BELT_LAYER
			and smmi0.visible == true
			and smmi0.multimesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX].size() == 36
			and int(smmi0.get_instance_shader_parameter("belt_base")) == 42
			and int(smmi0.get_instance_shader_parameter("belt_tex")) == 1
			and smmi0.multimesh.visible_instance_count == 6
			and smmi0.multimesh.instance_count == 12
			and smmi0.multimesh.custom_aabb.is_equal_approx(bounds),
			"Step 4: shadow proxy mirrors SHADOWS_ONLY, belt_base, belt_tex, visible_instance_count, and custom_aabb")
		check(mmi0.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			and mmi1.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			and mmi2.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
			"Step 4: proxied visible MMIs (v=0,1,2) have SHADOW_CASTING_SETTING_OFF")

		cards.casts_shadow = false
		check(not smmi0.visible and mmi0.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
			"Step 4: casts_shadow=false hides shadow proxy while keeping visible MMI cast_shadow OFF")
		cards.casts_shadow = true
		check(smmi0.visible and mmi0.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
			"Step 4: casts_shadow=true restores shadow proxy visibility")

		var bounds2 := AABB(Vector3(-20, -2, -20), Vector3(40, 8, 40))
		cards.set_bounds(bounds2)
		check(smmi0.multimesh.custom_aabb.is_equal_approx(bounds2),
			"Step 4: set_bounds updates shadow proxy custom_aabb")

		cards.update_shadow_cam(Vector3(10.0, 20.0, 30.0), 25.0)
		var smat := smmi0.material_override as ShaderMaterial
		check(smat != null and smat.shader == Looks.shader_for(ItemModels.ItemShadowShader)
			and (smat.get_shader_parameter("shadow_cam") as Vector3).is_equal_approx(Vector3(10.0, 20.0, 30.0))
			and is_equal_approx(float(smat.get_shader_parameter("shadow_max_sq")), 625.0),
			"Step 4: update_shadow_cam pushes shadow_cam and shadow_max_sq to ItemShadowShader")

	var shadow_src := FileAccess.get_file_as_string("res://shaders/item_shadow.gdshader")
	check(shadow_src.contains("#define BELT_IGNORE_VARIANTS"),
		"Step 4: item_shadow.gdshader defines BELT_IGNORE_VARIANTS")

	cards.reset()
	check(cards._shadow_kinds.is_empty() and cards._shadow_proxied.is_empty()
		and cards._record_params.is_empty() and cards._shadow_material == null
		and (smmi0 == null or smmi0.is_queued_for_deletion()),
		"Step 4: reset() frees shadow twins and clears proxy state")

	# --item-shadow-proxy=off switch restores full-mesh shadow casting.
	ItemCards.shadow_proxy_enabled = false
	cards.casts_shadow = true
	cards.put_records(1, 0, 4, 8, bounds)
	check(cards._shadow_kinds.is_empty()
		and cards._kinds[1].cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
		"Step 4: --item-shadow-proxy=off skips shadow proxy and restores SHADOW_CASTING_SETTING_ON")
	ItemCards.shadow_proxy_enabled = true

	# Simulated belts (record_tex == 0): every variant gets its own record range & shadow proxy twin.
	var sim_cards := ItemCards.new()
	sim_cards.use_shadow_proxy = true
	sim_cards.record_tex = 0
	sim_cards.contact = true
	sim_cards.casts_shadow = true
	sim_cards.render_layers = ItemCards.BELT_LAYER
	sim_cards.protos = _make_protos()
	add_child(sim_cards)
	sim_cards.put_records(1, 0, 4, 8, bounds)
	sim_cards.put_records(1 + step, 10, 5, 8, bounds)
	sim_cards.put_records(1 + 2 * step, 20, 6, 8, bounds)
	var sv0: MultiMeshInstance3D = sim_cards._shadow_kinds.get(1)
	var sv1: MultiMeshInstance3D = sim_cards._shadow_kinds.get(1 + step)
	var sv2: MultiMeshInstance3D = sim_cards._shadow_kinds.get(1 + 2 * step)
	check(sv0 != null and sv1 != null and sv2 != null
		and int(sv0.get_instance_shader_parameter("belt_base")) == 0 and sv0.multimesh.visible_instance_count == 4
		and int(sv1.get_instance_shader_parameter("belt_base")) == 10 and sv1.multimesh.visible_instance_count == 5
		and int(sv2.get_instance_shader_parameter("belt_base")) == 20 and sv2.multimesh.visible_instance_count == 6
		and sim_cards._kinds[1].cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		and sim_cards._kinds[1 + step].cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		and sim_cards._kinds[1 + 2 * step].cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"Step 4: simulated belts (record_tex=0) create shadow proxy twins for EVERY variant with independent belt_base/count")

	cards.queue_free()
	sim_cards.queue_free()
	await get_tree().process_frame


func _test_step5_tangents() -> void:
	# 1. Own-look GLB with normal map and UVs, WITHOUT glTF tangents.
	var own_dir := ProjectSettings.globalize_path("user://perf-tan-own")
	DirAccess.make_dir_recursive_absolute(own_dir)
	var own_glb := own_dir.path_join("norm-own.glb")
	check(_write_pbr_glb(own_glb, false), "Step 5: wrote normal-mapped GLB without tangents")
	check(not _glb_has_tangent_attr(own_glb), "Step 5: verified fixture GLB has NO glTF TANGENT attribute")

	ItemModels.item_tangents = true
	var mesh_own := ItemModels.read(own_glb)
	check(mesh_own != null and ItemModels.has_tangents(mesh_own),
		"Step 5: ItemModels.read() generates tangents when missing (has_tangents=true)")
	var arr_own := mesh_own.surface_get_arrays(0)
	check(arr_own[Mesh.ARRAY_TANGENT] != null and (arr_own[Mesh.ARRAY_TANGENT] as PackedFloat32Array).size() > 0,
		"Step 5: ARRAY_TANGENT populated on surface 0")
	var dressed_own := ItemModels.dressed(mesh_own, ItemModels.ItemOwnShader)
	var dmat := dressed_own.surface_get_material(0) as ShaderMaterial
	check(dmat != null and dmat.get_shader_parameter("use_tangent") == true,
		"Step 5: own_material / dressed() sets use_tangent=true")

	# 2. PBR pack GLB -> set_pbr() sets use_tangent=true.
	var pbr_dir := ProjectSettings.globalize_path("user://perf-tan-pbr")
	DirAccess.make_dir_recursive_absolute(pbr_dir.path_join("TanPbr/items"))
	var pj := FileAccess.open(pbr_dir.path_join("TanPbr/pack.json"), FileAccess.WRITE)
	pj.store_string(JSON.stringify({"name": "TanPbr", "shading": "pbr"}))
	pj.close()
	var pbr_glb := pbr_dir.path_join("TanPbr/items/norm-pbr.glb")
	check(_write_pbr_glb(pbr_glb, false) and not _glb_has_tangent_attr(pbr_glb),
		"Step 5: wrote PBR pack GLB without glTF tangents")
	ModelPacks.configure(pbr_dir, ["dir:TanPbr", "builtin:placeholders"], [])
	ModelPacks.wait()
	var mesh_pbr := ItemModels.read(pbr_glb)
	check(mesh_pbr != null and ItemModels.has_tangents(mesh_pbr) and not ItemModels.has_own(mesh_pbr),
		"Step 5: PBR item has_tangents=true and uses shared-picture PBR path")
	var pmat := ItemModels.material_for(mesh_pbr)
	check(pmat != null and pmat.get_shader_parameter("use_tangent") == true,
		"Step 5: set_pbr() / material_for() sets use_tangent=true")

	# 3. --item-tangents=off disables precomputed tangents.
	ItemModels.item_tangents = false
	check(not ItemModels.has_tangents(mesh_pbr),
		"Step 5: --item-tangents=off makes has_tangents() false even on pre-read mesh")
	var mesh_off := ItemModels.read(pbr_glb)
	var pmat_off := ItemModels.material_for(mesh_off)
	var dressed_off := ItemModels.dressed(ItemModels.read(own_glb), ItemModels.ItemOwnShader)
	var dmat_off := dressed_off.surface_get_material(0) as ShaderMaterial
	check(mesh_off != null and not ItemModels.has_tangents(mesh_off)
		and pmat_off.get_shader_parameter("use_tangent") != true
		and dmat_off != null and dmat_off.get_shader_parameter("use_tangent") != true,
		"Step 5: --item-tangents=off skips tangent generation and keeps use_tangent=false on set_pbr & own_material")
	ItemModels.item_tangents = true


func _test_belt_items_integration(var_dir: String) -> void:
	ModelPacks.configure(var_dir, ["dir:Vars", "builtin:placeholders"], [])
	ModelPacks.wait()
	var prev_lod_mode := ItemCards.lod_mode
	ItemCards.lod_mode = "global"
	ItemCards.lattice_variants_mode = "close"
	ItemCards.shadow_proxy_enabled = true
	ItemModels.item_geom_lod = true

	var standalone := ItemCards.new()
	check(not standalone.allow_lod and not standalone.use_shadow_proxy,
		"BeltItems: standalone ItemCards defaults to allow_lod=false, use_shadow_proxy=false")
	standalone.free()

	var vp := SubViewport.new()
	vp.size = Vector2i(1920, 1080)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child_compat(vp)
	var cam := Camera3D.new()
	cam.fov = 50.0
	vp.add_child(cam)
	cam.current = true
	var bi := BeltItems.new()
	bi.protos = _make_protos()
	vp.add_child(bi)
	await get_tree().process_frame

	check(bi._cards.allow_lod and bi._cards.use_shadow_proxy,
		"BeltItems: _cards enables allow_lod=true and use_shadow_proxy=true")
	check(bi._lat_cards.allow_lod and bi._lat_cards.use_shadow_proxy and bi._lat_cards.record_tex == 1,
		"BeltItems: _lat_cards enables allow_lod=true, use_shadow_proxy=true, record_tex=1")
	check(not bi._drop_cards.allow_lod and not bi._drop_cards.use_shadow_proxy,
		"BeltItems: _drop_cards leaves allow_lod=false and use_shadow_proxy=false")

	# Exercise _update_item_lods() across close (LOD0), mid (LOD1), far (LOD2), and back in.
	bi._square = Vector3(0.0, 0.0, 16.0)
	cam.global_position = Vector3(0.0, 15.0, 0.0)  # ~77 px/tile -> LOD0, dist 15 <= 24 -> lattice variants ON
	bi._update_item_lods()
	check(bi._cards.lod_tier == 0 and bi._lat_cards.lod_tier == 0 and bi._lat_cards.lattice_variants_active,
		"BeltItems: close camera sets lod_tier=0 and lattice_variants_active=true")

	cam.global_position = Vector3(0.0, 40.0, 0.0)  # ~29 px/tile (< 36, >= 18) -> LOD1, lattice variants OFF
	bi._update_item_lods()
	check(bi._cards.lod_tier == 1 and bi._lat_cards.lod_tier == 1 and not bi._lat_cards.lattice_variants_active,
		"BeltItems: mid camera sets lod_tier=1 and lattice_variants_active=false")

	cam.global_position = Vector3(0.0, 80.0, 0.0)  # ~14 px/tile (< 18) -> LOD2, lattice variants OFF
	bi._update_item_lods()
	check(bi._cards.lod_tier == 2 and bi._lat_cards.lod_tier == 2 and not bi._lat_cards.lattice_variants_active,
		"BeltItems: far camera sets lod_tier=2 and lattice_variants_active=false")

	cam.global_position = Vector3(0.0, 15.0, 0.0)  # back close -> LOD0, lattice variants ON
	bi._update_item_lods()
	check(bi._cards.lod_tier == 0 and bi._lat_cards.lod_tier == 0 and bi._lat_cards.lattice_variants_active,
		"BeltItems: zooming back in restores lod_tier=0 and lattice_variants_active=true")

	ItemCards.lod_mode = prev_lod_mode
	vp.queue_free()
	await get_tree().process_frame


func _write_glb_mesh(path: String, mesh: Mesh) -> bool:
	var root_n := Node3D.new()
	root_n.name = "Root"
	var mi := MeshInstance3D.new()
	mi.name = "Item"
	mi.mesh = mesh
	root_n.add_child(mi)
	mi.owner = root_n
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var ok := doc.append_from_scene(root_n, state) == OK and doc.write_to_filesystem(state, path) == OK
	root_n.free()
	return ok


func _test_step6_seamless_lods() -> void:
	# 1. ORM folding regression: glTF default roughness=1, metallic=1 + ORM=(1.0, 0.25, 0.0).
	var seam_dir := ProjectSettings.globalize_path("user://perf-seamless")
	DirAccess.make_dir_recursive_absolute(seam_dir.path_join("SeamPbr/items"))
	var pj := FileAccess.open(seam_dir.path_join("SeamPbr/pack.json"), FileAccess.WRITE)
	pj.store_string(JSON.stringify({"name": "SeamPbr", "shading": "pbr"}))
	pj.close()
	var alb_img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	alb_img.fill(Color(0.2, 0.7, 0.3, 1.0))
	var orm_img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	orm_img.fill(Color(1.0, 0.25, 0.0, 1.0))
	var pbr_mat := StandardMaterial3D.new()
	pbr_mat.albedo_texture = ImageTexture.create_from_image(alb_img)
	pbr_mat.roughness = 1.0
	pbr_mat.metallic = 1.0
	pbr_mat.metallic_texture = ImageTexture.create_from_image(orm_img)
	pbr_mat.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
	pbr_mat.roughness_texture = pbr_mat.metallic_texture
	pbr_mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	var box := BoxMesh.new()
	box.size = Vector3(0.28, 0.08, 0.28)
	var b_arr := box.get_mesh_arrays()
	var b_mesh := ArrayMesh.new()
	b_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, b_arr)
	b_mesh.surface_set_material(0, pbr_mat)
	var orm_glb := seam_dir.path_join("SeamPbr/items/orm-dielectric.glb")
	check(_write_glb_mesh(orm_glb, b_mesh), "Step 6: wrote glTF ORM dielectric fixture")
	ModelPacks.configure(seam_dir, ["dir:SeamPbr", "builtin:placeholders"], [])
	ModelPacks.wait()
	var orm_mesh := ItemModels.read(orm_glb)
	var orm_l1 := ItemModels.lod_material_for(orm_mesh)
	var orm_l2 := ItemModels.lod2_material_for(orm_mesh)
	var bl := BeltLanes.new()
	add_child(bl)
	var orm_far1 := bl._model_material(91, ItemModels.lod_mesh(orm_mesh), orm_mesh)
	var orm_far2 := bl._model_material(91, ItemModels.lod2_mesh(orm_mesh), orm_mesh)
	check(absf(float(orm_l1.get_shader_parameter("pbr_roughness")) - 0.25) < 0.01
		and absf(float(orm_l1.get_shader_parameter("pbr_metallic"))) < 0.01
		and absf(float(orm_l2.get_shader_parameter("pbr_roughness")) - 0.25) < 0.01
		and absf(float(orm_l2.get_shader_parameter("pbr_metallic"))) < 0.01
		and absf(float(orm_far1.get_shader_parameter("pbr_roughness")) - 0.25) < 0.01
		and absf(float(orm_far1.get_shader_parameter("pbr_metallic"))) < 0.01
		and absf(float(orm_far2.get_shader_parameter("pbr_roughness")) - 0.25) < 0.01
		and absf(float(orm_far2.get_shader_parameter("pbr_metallic"))) < 0.01
		and orm_far1 != orm_far2,
		"Step 6: ORM (1.0, 0.25, 0.0) folds to ~0.25 roughness and ~0.0 metallic across LOD1/LOD2/BeltLanes dual caches")

	# 2. Non-PBR own_look roughness, metallic & emission parity.
	var own_mat := StandardMaterial3D.new()
	own_mat.albedo_texture = ImageTexture.create_from_image(alb_img)
	own_mat.roughness = 0.22
	own_mat.metallic = 0.85
	own_mat.emission_enabled = true
	own_mat.emission = Color(1.0, 0.4, 0.1)
	own_mat.emission_energy_multiplier = 1.5
	var own_src := ArrayMesh.new()
	own_src.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, b_arr)
	own_src.surface_set_material(0, own_mat)
	var own_glb := seam_dir.path_join("own-item.glb")
	check(_write_glb_mesh(own_glb, own_src), "Step 6: wrote non-PBR own_look fixture")
	var own_mesh := ItemModels.read(own_glb)
	var own_l1 := ItemModels.lod_material_for(own_mesh)
	var own_l2 := ItemModels.lod2_material_for(own_mesh)
	var own_far2 := bl._model_material(92, ItemModels.lod2_mesh(own_mesh), own_mesh)
	check(ItemModels.has_own(own_mesh)
		and own_l1.get_shader_parameter("use_own_rm") == true
		and is_equal_approx(float(own_l1.get_shader_parameter("pbr_roughness")), 0.22)
		and is_equal_approx(float(own_l1.get_shader_parameter("pbr_metallic")), 0.85)
		and float(own_l1.get_shader_parameter("emission_energy")) > 1.0
		and own_l2.get_shader_parameter("use_own_rm") == true
		and own_far2.get_shader_parameter("use_own_rm") == true
		and float(own_far2.get_shader_parameter("emission_energy")) > 1.0,
		"Step 6: non-PBR own_look sets use_own_rm, roughness/metallic, and emission on LOD1/LOD2/BeltLanes")

	# 3. Flat normals & top vs side vertex colors on _lod_box_mesh and lod2_mesh.
	var top_green := Color(0.1, 0.9, 0.1, 1.0)
	var side_orange := Color(0.95, 0.45, 0.05, 1.0)
	var two_tone := ItemModels._build_colored_box_mesh(
		AABB(Vector3(-0.15, 0.0, -0.15), Vector3(0.30, 0.04, 0.30)),
		top_green.srgb_to_linear(), side_orange.srgb_to_linear(), side_orange.srgb_to_linear(), true, 0.04)
	var l2 := ItemModels.lod2_mesh(two_tone)
	var l2_arr := l2.surface_get_arrays(0)
	var l2_v: PackedVector3Array = l2_arr[Mesh.ARRAY_VERTEX]
	var l2_n: PackedVector3Array = l2_arr[Mesh.ARRAY_NORMAL]
	var l2_c: PackedColorArray = l2_arr[Mesh.ARRAY_COLOR]
	var l2_i: PackedInt32Array = l2_arr[Mesh.ARRAY_INDEX]
	var l2_mid := l2.get_aabb().get_center()
	var l2_outward := 0
	for t in range(0, l2_i.size(), 3):
		var v0 := l2_v[l2_i[t]]
		var v1 := l2_v[l2_i[t + 1]]
		var v2 := l2_v[l2_i[t + 2]]
		if (v2 - v0).cross(v1 - v0).dot((v0 + v1 + v2) / 3.0 - l2_mid) > 0.0:
			l2_outward += 1
	var top_vert_n := l2_n[0]
	var top_vert_c := l2_c[0]
	var side_vert_c := l2_c[4]
	check(l2_v.size() == 20 and l2_i.size() == 30 and l2_outward == 10
		and top_vert_n.distance_to(Vector3.UP) < 0.001
		and top_vert_c.g > top_vert_c.r * 2.0 and side_vert_c.r > side_vert_c.g * 1.5,
		"Step 6: lod2_mesh has 20 verts, 10 outward tris, flat Vector3.UP top normal, and distinct top/side colors")
	var l1_box := ItemModels._lod_box_mesh(two_tone, two_tone)
	var l1b_n: PackedVector3Array = l1_box.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
	check(l1b_n.size() == 24 and l1b_n[0].distance_to(Vector3.UP) < 0.001,
		"Step 6: _lod_box_mesh uses 24 split-edge verts with exact Vector3.UP top normal")

	# 4. _weld_for_lod preserves top Vector3.UP normals across 90-degree edges.
	var welded := ItemModels._weld_for_lod(two_tone.surface_get_arrays(0), PackedColorArray(), true)
	var wn: PackedVector3Array = welded[Mesh.ARRAY_NORMAL]
	var wv: PackedVector3Array = welded[Mesh.ARRAY_VERTEX]
	var wc: PackedColorArray = welded[Mesh.ARRAY_COLOR]
	var top_count := 0
	var top_kept := true
	for k in wv.size():
		if wc[k].g > wc[k].r * 2.0:
			top_count += 1
			if wn[k].distance_to(Vector3.UP) >= 0.001:
				top_kept = false
	check(top_kept and top_count == 4 and wv.size() >= 8,
		"Step 6: _weld_for_lod(split_normals=true) preserves flat Vector3.UP top normals")

	# 5. Distance-LOD gradual transitions & matching boundary jitter in ItemCards.
	ModelPacks.configure("", [], [])
	ModelPacks.wait()
	ItemCards.lod_mode = "distance"
	ItemCards.lod_blend = true
	ItemModels.lod2_mode = "proxy"
	var cards := ItemCards.new()
	cards.allow_lod = true
	cards.contact = false
	cards.protos = _make_protos()
	add_child(cards)
	var bounds := AABB(Vector3(-40.0, -1.0, -40.0), Vector3(80.0, 4.0, 80.0))
	cards.put_records(3, 0, 4, 8, bounds)
	var cam := Camera3D.new()
	cam.fov = 50.0
	add_child(cam)
	cam.global_position = Vector3(0.0, 20.0, 0.0)
	cards.update_distance_lod(cam, 1080.0, bounds, Vector3.ZERO, true)
	var entry: Dictionary = cards._dist_lods.get(3, {})
	var b0_mats: Array = entry.get("b0_mats", [])
	var b1_mats: Array = entry.get("b1_mats", [])
	var b2_mats: Array = entry.get("b2_mats", [])
	var m0 := b0_mats[0] as ShaderMaterial if not b0_mats.is_empty() else null
	var m1 := b1_mats[0] as ShaderMaterial if not b1_mats.is_empty() else null
	var m2 := b2_mats[0] as ShaderMaterial if not b2_mats.is_empty() else null
	var j0: Vector2 = m0.get_shader_parameter("lod_jitter") if m0 != null else Vector2.ZERO
	var j1: Vector2 = m1.get_shader_parameter("lod_jitter") if m1 != null else Vector2.ZERO
	var j2: Vector2 = m2.get_shader_parameter("lod_jitter") if m2 != null else Vector2.ZERO
	check(m0 != null and m1 != null and m2 != null
		and j0.y > 0.0 and is_equal_approx(j0.y, j1.x)
		and j1.y > 0.0 and is_equal_approx(j1.y, j2.x)
		and float(m0.get_shader_parameter("lod_fade_end")) > float(m0.get_shader_parameter("lod_fade_start"))
		and bool(entry.get("b2_is_proxy", false)),
		"Step 6: ItemCards distance LOD sets matching boundary jitters (%.2f/%.2f), fade ramps, and 10-tri LOD2 proxy" % [j0.y, j1.y])

	ItemCards.lod_blend = false
	cards.update_distance_lod(cam, 1080.0, bounds, Vector3.ZERO, true)
	var j0_off: Vector2 = m0.get_shader_parameter("lod_jitter")
	check(j0_off.is_equal_approx(Vector2.ZERO) and is_zero_approx(float(m0.get_shader_parameter("lod_fade_end"))),
		"Step 6: --item-lod-blend=off zeroes lod_jitter and lod_fade_end")
	ItemCards.lod_blend = true

	# 6. BeltLanes textured LOD1 fade uniforms.
	var fade_mat := bl._model_material(93, ItemModels.lod_mesh(orm_mesh), orm_mesh)
	check(bool(fade_mat.get_shader_parameter("lod_fade_albedo")) == true
		and float(fade_mat.get_shader_parameter("lod_fade_end")) > float(fade_mat.get_shader_parameter("lod_fade_start")),
		"Step 6: BeltLanes sets lod_fade_albedo and fade ramp on textured LOD1 far belt items")

	# 7. Two-surface glass enclosing glowing liquid preserves emission in lod_stats / lod2_material_for.
	var outer_box := BoxMesh.new()
	outer_box.size = Vector3(0.28, 0.28, 0.28)
	var inner_box := BoxMesh.new()
	inner_box.size = Vector3(0.18, 0.18, 0.18)
	var glass_mat := StandardMaterial3D.new()
	glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass_mat.albedo_color = Color(0.9, 0.95, 1.0, 0.35)
	var liq_mat := StandardMaterial3D.new()
	liq_mat.albedo_color = Color(0.2, 0.9, 0.4, 1.0)
	liq_mat.emission_enabled = true
	liq_mat.emission = Color(0.2, 1.0, 0.4)
	liq_mat.emission_energy_multiplier = 2.0
	var flask := ArrayMesh.new()
	flask.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, outer_box.get_mesh_arrays())
	flask.surface_set_material(0, glass_mat)
	flask.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, inner_box.get_mesh_arrays())
	flask.surface_set_material(1, liq_mat)
	flask.set_meta(ItemModels.SURFACES_META, [[glass_mat, false], [liq_mat, false]])
	var flask_stats := ItemModels.lod_stats(flask)
	var flask_l2 := ItemModels.lod2_material_for(flask)
	check(bool(flask_stats["has_emission"]) == true
		and float(flask_l2.get_shader_parameter("emission_energy")) > 0.1,
		"Step 6: enclosed emissive liquid under transparent glass preserves emission on LOD2 proxy")

	cam.queue_free()
	cards.queue_free()
	bl.queue_free()
	await get_tree().process_frame


func _step7_lane(key: int, ex: float, ey: float, nx: float, ny: float) -> Array:
	var cx := (ex + nx) * 0.5
	var cy := (ey + ny) * 0.5
	return [key, 1, 512, 0, roundi(ex * 256.0), roundi(ey * 256.0), roundi(cx * 256.0), roundi(cy * 256.0),
		roundi(nx * 256.0), roundi(ny * 256.0), 0, 0]


func _step7_feed(bi: Node, k: int, lm: Array, sl: Array, fr := 95) -> void:
	bi.handle({"t": "bs", "k": k, "p": 6, "w": 100, "fx": 0, "fy": 0, "fr": fr, "lm": lm, "sl": sl})
	bi._process(1.0 / 60.0)


func _test_step7_lod_split_and_caps(var_dir: String) -> void:
	ModelPacks.configure(var_dir, ["dir:Vars", "builtin:placeholders"], [])
	ModelPacks.wait()
	ItemCards.use_models = true
	ItemCards.model_cap = -1
	ItemCards.lod_mode = "distance"
	ItemCards.lod_split = true
	ItemCards.lod_blend = true
	ItemCards.lod_quality = "medium"
	ItemCards.apply_lod_quality("medium")
	ItemCards.lattice_variants_mode = "close"
	ItemModels.item_geom_lod = true
	ItemModels.lod2_mode = "proxy"
	BeltItems.BeltLattice.model_cap_near = true
	BeltLanes.near_3d_exhausted = false
	var was_view_cull := BeltItems.Job.view_cull
	BeltItems.Job.view_cull = false

	# Ensure item "stone" (id=1) model is already synchronously cached before stepping.
	var stone_mesh := ItemModels.mesh_for("stone", 0)
	check(stone_mesh != null, "Step 7: stone model available for split-band tests")

	var vp := SubViewport.new()
	vp.size = Vector2i(1920, 1080)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child_compat(vp)
	var cam := Camera3D.new()
	cam.fov = 50.0
	vp.add_child(cam)
	cam.current = true
	cam.global_position = Vector3(0.0, 15.0, 0.5)
	cam.look_at(Vector3(45.0, 0.0, 0.5), Vector3.UP)

	var bl := BeltLanes.new()
	bl.sync = true
	vp.add_child(bl)
	var bi := BeltItems.new()
	bi.protos = _make_protos()
	bi._sync = true
	bi.lanes = bl
	bi.view_led = true
	vp.add_child(bi)
	await get_tree().process_frame

	check(bi._cards.split_bands and bi._lat_cards.split_bands,
		"Step 7: BeltItems._ready enables split_bands on _cards and _lat_cards")

	# 1. Distance-band bucketing: feed packed lanes in near (x=3), mid (x=42), and far (x=76) bands.
	var lm_bands: Array = []
	var sl_bands: Array = []
	var uid := 100
	var configs := [[101, 2.0, 0.5], [102, 42.0, 0.5], [103, 76.0, 0.5]]
	for cfg: Array in configs:
		var lkey := int(cfg[0]) * 8 + 1
		var x0 := float(cfg[1])
		var y0 := float(cfg[2])
		lm_bands.append_array(_step7_lane(lkey, x0 + 2.0, y0, x0, y0))
		sl_bands.append_array([lkey, 1000, 8])
		for j in 8:
			uid += 1
			sl_bands.append_array([uid, 1, 32 + j * 64, 1])

	bi._square = Vector3(0.0, 0.0, 95.0)
	bi._update_item_lods()
	_step7_feed(bi, 1000, lm_bands, sl_bands)
	for f in 24:
		_step7_feed(bi, 1001 + f, [], [])
	bi._update_item_lods()

	var mmi_b0: MultiMeshInstance3D = bi._lat_cards._kinds.get(1)
	var mmi_b1: MultiMeshInstance3D = bi._lat_cards._kinds.get(1 + ItemCards.BAND_STEP)
	var mmi_b2: MultiMeshInstance3D = bi._lat_cards._kinds.get(1 + 2 * ItemCards.BAND_STEP)
	var b0_cnt := mmi_b0.multimesh.visible_instance_count if mmi_b0 != null else -1
	var b1_cnt := mmi_b1.multimesh.visible_instance_count if mmi_b1 != null else -1
	var b2_cnt := mmi_b2.multimesh.visible_instance_count if mmi_b2 != null else -1
	check(b0_cnt == 8 and b1_cnt == 8 and b2_cnt == 8,
		"Step 7: split distance bands separate near/mid/far into distinct MultiMeshes (%d, %d, %d; far NOT in LOD0)" % [b0_cnt, b1_cnt, b2_cnt])
	check(mmi_b1 != null and mmi_b2 != null and bi._lat_cards._split_lods.has(1 + ItemCards.BAND_STEP)
		and bi._lat_cards._split_lods.has(1 + 2 * ItemCards.BAND_STEP)
		and mmi_b2.multimesh.mesh.get_surface_count() == 1
		and not bi._lat_cards._kinds.has(1 + ItemCards.VARIANT_STEP + 2 * ItemCards.BAND_STEP),
		"Step 7: Band 1 & 2 build single-band meshes without contact box or far lattice variants")

	# 2. Global shader parameter f3d_item_lod_cam updates on camera movement > 0.25 tiles.
	cam.global_position = Vector3(50.0, 20.0, 15.0)
	bi._update_item_lods()
	var gcam_raw: Variant = RenderingServer.global_shader_parameter_get("f3d_item_lod_cam")
	var gcam: Vector3 = gcam_raw if gcam_raw is Vector3 else ItemCards._global_lod_cam_sent
	check(gcam.distance_to(Vector3(50.0, 20.0, 15.0)) < 0.01,
		"Step 7: f3d_item_lod_cam updates globally on camera movement (%s)" % str(gcam))

	# 3. Switch --item-lod-split=off via read_flags restores legacy single-MultiMesh _dist_lods path.
	BeltItems.read_flags(["--item-lod-split=off"])
	check(not ItemCards.lod_split, "Step 7: --item-lod-split=off toggles ItemCards.lod_split=false")
	cam.global_position = Vector3(0.0, 15.0, 0.5)
	cam.look_at(Vector3(45.0, 0.0, 0.5), Vector3.UP)
	bi.reset()
	bi._square = Vector3(0.0, 0.0, 95.0)
	bi._update_item_lods()
	_step7_feed(bi, 1000, lm_bands, sl_bands)
	for f in 24:
		_step7_feed(bi, 1001 + f, [], [])
	var off_mmi: MultiMeshInstance3D = bi._lat_cards._kinds.get(1)
	check(off_mmi != null and off_mmi.multimesh.visible_instance_count == 24
		and bi._lat_cards._dist_lods.has(1),
		"Step 7: --item-lod-split=off restores single-MultiMesh _dist_lods with all %d items in band 0" % [
			off_mmi.multimesh.visible_instance_count if off_mmi != null else -1])
	BeltItems.read_flags(["--item-lod-split=on"])

	# 4. Intermediate model_cap (0, 500, 2000, -1) across 800 packed items + BeltLanes.models() coordination.
	bi.reset()
	cam.global_position = Vector3(0.0, 25.0, 2.0)
	cam.look_at(Vector3(45.0, 0.0, 2.0), Vector3.UP)
	bi.view_led = false
	var lm_cap: Array = []
	var sl_cap: Array = []
	var uid_cap := 5000
	# 100 lanes * 8 slots = 800 packed slots ordered across distances x = 1..85.
	for n in 100:
		var lkey := (500 + n) * 8 + 1
		var x0 := 1.0 + float(n) * 0.85
		lm_cap.append_array(_step7_lane(lkey, x0 + 2.0, float(n % 4) * 1.5, x0, float(n % 4) * 1.5))
		sl_cap.append_array([lkey, 3000, 8])
		for j in 8:
			uid_cap += 1
			sl_cap.append_array([uid_cap, 1, 32 + j * 64, 1])

	ItemCards.model_cap = 500
	_step7_feed(bi, 3000, lm_cap, sl_cap, 95)
	for f in 24:
		_step7_feed(bi, 3001 + f, [], [], 95)
	var lat_3d_500 := int(bi._state.lattice.cap_3d_slots if bi._state.lattice is BeltItems.BeltLattice else bi._state.lattice.get_cap_3d_slots())
	var icon_500_mmi: MultiMeshInstance3D = bi._lat_cards._kinds.get(-2)
	check(lat_3d_500 > 0 and lat_3d_500 <= 508 and icon_500_mmi != null and icon_500_mmi.multimesh.visible_instance_count > 0,
		"Step 7: model_cap=500 renders nearest %d packed slots in 3D and remainder as 2D icons" % lat_3d_500)
	check(BeltLanes.near_3d_exhausted and not BeltLanes.models(),
		"Step 7: 800 eligible >= model_cap 500 marks near_3d_exhausted=true and disables extra far 3D")

	ItemCards.model_cap = 2000
	for f in 3:
		_step7_feed(bi, 3030 + f, [], [], 95)
	var lat_3d_2000 := int(bi._state.lattice.cap_3d_slots if bi._state.lattice is BeltItems.BeltLattice else bi._state.lattice.get_cap_3d_slots())
	check(lat_3d_2000 == 800 and not BeltLanes.near_3d_exhausted and BeltLanes.models(),
		"Step 7: model_cap=2000 puts all %d packed slots in 3D and allows far 3D within range" % lat_3d_2000)

	ItemCards.model_cap = 0
	for f in 3:
		_step7_feed(bi, 3040 + f, [], [], 95)
	var lat_3d_0 := int(bi._state.lattice.cap_3d_slots if bi._state.lattice is BeltItems.BeltLattice else bi._state.lattice.get_cap_3d_slots())
	check(lat_3d_0 == 0 and not BeltLanes.models(),
		"Step 7: model_cap=0 flips all %d packed slots to 2D icons" % lat_3d_0)

	# Switch --lattice-model-cap=off restores binary behavior (500 -> 0 3D slots on packed lanes).
	BeltItems.read_flags(["--lattice-model-cap=off"])
	ItemCards.model_cap = 500
	for f in 3:
		_step7_feed(bi, 3050 + f, [], [], 95)
	var lat_3d_off := int(bi._state.lattice.cap_3d_slots if bi._state.lattice is BeltItems.BeltLattice else bi._state.lattice.get_cap_3d_slots())
	check(lat_3d_off == 0,
		"Step 7: --lattice-model-cap=off restores binary all-icon fallback at model_cap=500 (%d)" % lat_3d_off)

	BeltItems.read_flags(["--lattice-model-cap=on"])
	BeltItems.Job.view_cull = was_view_cull
	vp.queue_free()
	await get_tree().process_frame


func add_child_compat(node: Node) -> void:
	add_child(node)
