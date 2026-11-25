extends SceneTree
## A modeller's item model is drawn with its file's own materials (item_models.gd own_look, dressed,
## preview_mesh): a .glb of two materials, one with a base-colour picture and one glowing and
## see-through, read as an item from a models folder without pack.json, keeps its picture, its glow and
## its alpha on the loose items' material, the far belts' and the Model packs preview's. Before, an
## item whose surfaces didn't share one picture was drawn by its colours alone (Vasillo's science pack,
## plain grey). `--item-materials=old` still draws it so. The see-through glass, and a liquid inside it, are
## drawn by the blended twin shaders (transparent pass), the liquid first; the body stays opaque.
## `--item-glass=dither` dithers them in the opaque pass instead.
##   godot --headless --audio-driver Dummy --path client -s res://tests/item_materials_test.gd

const ItemModels := preload("res://scripts/world/item_models.gd")
const ModelPacks := preload("res://scripts/world/model_packs.gd")
const LaneModelShader := preload("res://shaders/belt_lane_model.gdshader")
const TestEnv := preload("res://tests/test_env.gd")

const GLOW := Color(1.0, 0.5, 0.0)
const GLOW_ENERGY := 2.0

var fails := 0
var checked := 0  # _check_world runs that got to the end (a script error stops one short)


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _init() -> void:
	TestEnv.isolate("item-materials-test")
	var dir := OS.get_user_data_dir().path_join("models").path_join("items")
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("test-pack.glb")
	check(_write_fixture(path), "wrote the fixture .glb")
	check(not FileAccess.file_exists(dir.get_base_dir().path_join(ModelPacks.INFO_FILE)), "no pack.json")

	var mesh := ItemModels.read(path)
	check(mesh != null and mesh.get_surface_count() == 3, "the item model read, three surfaces")
	if mesh != null:
		check(ItemModels.has_own(mesh), "drawn with its own materials")
		_check_world(ItemModels.dressed(mesh, ItemModels.ItemOwnShader), "loose items")
		_check_world(ItemModels.dressed(mesh, LaneModelShader), "far belts")
		_check_blend(ItemModels.dressed(mesh, ItemModels.ItemOwnShader), ItemModels.ItemOwnShader,
			ItemModels.ItemOwnBlendShader, "loose items")
		_check_blend(ItemModels.dressed(mesh, LaneModelShader), LaneModelShader, ItemModels.LaneModelBlendShader,
			"far belts")
		check(ItemModels.dressed(mesh, ItemModels.ItemOwnShader) == ItemModels.dressed(mesh, ItemModels.ItemOwnShader),
			"one dressed copy per shader, shared")
		check(ItemModels.plain_material(mesh) == null, "the preview needs no override")
		var shown := ItemModels.preview_mesh(mesh)
		var body := shown.surface_get_material(0) as BaseMaterial3D
		var glass := shown.surface_get_material(1) as BaseMaterial3D
		check(body != null and body.albedo_texture != null, "preview: the body keeps its picture")
		check(glass != null and glass.emission_enabled and glass.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED,
			"preview: the glass keeps its glow and alpha")

	# The shaders parse (headless, Godot's own shader front end): each has the own materials' uniforms.
	for shader: Shader in [ItemModels.ItemShader, ItemModels.ItemOwnShader, ItemModels.ItemOwnCutShader, LaneModelShader,
			ItemModels.LaneModelCutShader, ItemModels.ItemOwnBlendShader, ItemModels.LaneModelBlendShader]:
		var names := shader.get_shader_uniform_list().map(func(u: Dictionary) -> String: return str(u["name"]))
		check(names.has("alpha_mode") and names.has("emission_picture") and names.has("picture"),
			"%s parses, with the own materials' uniforms" % shader.resource_path)
	for shader: Shader in [ItemModels.ItemShader, ItemModels.ItemOwnShader, ItemModels.ItemOwnCutShader, ItemModels.ItemOwnBlendShader]:
		var names := shader.get_shader_uniform_list().map(func(u: Dictionary) -> String: return str(u["name"]))
		check(names.has("lod_cam") and names.has("lod_min_sq") and names.has("lod_max_sq"),
			"%s parses with item LOD uniforms" % shader.resource_path)
	check(_only_guarded_discards("res://shaders/item_own.gdshader", "res://shaders/item_body.gdshaderinc", ["ITEM_CUT"]),
		"item_own.gdshader opaque path has no unguarded discard (Early-Z intact)")
	check(_only_guarded_discards("res://shaders/belt_lane_model.gdshader", "res://shaders/belt_lane_model.gdshaderinc",
		["LANE_FRAG_CULL", "ITEM_CUT", "ITEM_BLEND"]),
		"belt_lane_model.gdshader opaque path only discards inside LANE_FRAG_CULL / ITEM_CUT / ITEM_BLEND")

	# Phase 2: single-surface opaque LOD for multi-surface / see-through own-look items.
	if mesh != null:
		check(ItemModels.needs_lod(mesh), "multi-surface see-through item needs LOD")
		var simple := ItemModels.simple_mesh(mesh)
		check(simple != null and simple != mesh and simple.get_surface_count() == 1 and ItemModels.is_simple(simple),
			"simple_mesh merges own-look item into 1 opaque surface (%d)" % (simple.get_surface_count() if simple != null else -1))
		if simple != null and simple.get_surface_count() == 1:
			var full_tris := 0
			for si in mesh.get_surface_count():
				full_tris += (mesh.surface_get_arrays(si)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
			var simple_tris := (simple.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
			check(simple_tris < full_tris,
				"simple_mesh drops occluded inner liquid inside outer glass (%d -> %d tris)" % [full_tris, simple_tris])
		var lod := ItemModels.dressed_lod(mesh, ItemModels.ItemOwnShader, 36.0)
		check(lod != null and lod.get_surface_count() == 4,
			"dressed_lod has 3 detailed surfaces + 1 merged opaque LOD surface (%d)" % (lod.get_surface_count() if lod != null else -1))
		if lod != null and lod.get_surface_count() == 4:
			var m0 := lod.surface_get_material(0) as ShaderMaterial
			var m3 := lod.surface_get_material(3) as ShaderMaterial
			check(m0 != null and is_equal_approx(float(m0.get_shader_parameter("lod_max_sq")), 36.0 * 36.0)
				and m3 != null and m3.shader == ItemModels.ItemShader
				and is_equal_approx(float(m3.get_shader_parameter("lod_min_sq")), 36.0 * 36.0)
				and is_equal_approx(float(m3.get_shader_parameter("exposure")), 1.0),
				"dressed_lod sets lod_max_sq on detailed surfaces and opaque lod_min_sq + exposure 1.0 on simple surface")
		ItemModels.item_lod = false
		check(ItemModels.dressed_lod(mesh, ItemModels.ItemOwnShader, 36.0) == ItemModels.dressed(mesh, ItemModels.ItemOwnShader),
			"--item-lod=off falls back to plain dressed()")
		ItemModels.item_lod = true

	# Blended twins: they write ALPHA (the transparent pass); the opaque ones don't.
	for src in ["res://shaders/item_own_blend.gdshader", "res://shaders/belt_lane_model_blend.gdshader"]:
		var text := FileAccess.get_file_as_string(src)
		check(text.contains("#define ITEM_BLEND") and text.contains("blend_mix") and text.contains("depth_prepass_alpha"),
			"%s: blended, its opaque pixels in the depth pre-pass" % src.get_file())
	for src in ["res://shaders/item_body.gdshaderinc", "res://shaders/belt_lane_model.gdshaderinc"]:
		var text := FileAccess.get_file_as_string(src)
		check(text.contains("#ifdef ITEM_BLEND") and text.contains("ALPHA = own_a;") and text.contains("item_own_cut(own_a"),
			"%s: ALPHA only with ITEM_BLEND, dithered otherwise" % src.get_file())

	# --item-glass=dither: body stays on opaque Early-Z shader; glass & liquid use cut twin (ITEM_CUT / discard).
	ItemModels.glass_blend = false
	var dithered := ItemModels.read(path)
	if dithered != null:
		var d := ItemModels.dressed(dithered, ItemModels.ItemOwnShader)
		var body_d := d.surface_get_material(0) as ShaderMaterial
		var glass_d := d.surface_get_material(1) as ShaderMaterial
		var liquid_d := d.surface_get_material(2) as ShaderMaterial
		check(body_d != null and body_d.shader == ItemModels.ItemOwnShader and body_d.render_priority == 0,
			"--item-glass=dither: body stays on opaque ItemOwnShader, render_priority 0")
		check(glass_d != null and glass_d.shader == ItemModels.ItemOwnCutShader and glass_d.render_priority == 0
			and glass_d.get_shader_parameter("alpha_mode") == 2,
			"--item-glass=dither: glass uses ItemOwnCutShader, render_priority 0, alpha_mode 2")
		check(liquid_d != null and liquid_d.shader == ItemModels.ItemOwnCutShader and liquid_d.render_priority == 0
			and liquid_d.get_shader_parameter("alpha_mode") == 2,
			"--item-glass=dither: liquid uses ItemOwnCutShader, render_priority 0, alpha_mode 2")
		var dl := ItemModels.dressed(dithered, LaneModelShader)
		var l_body := dl.surface_get_material(0) as ShaderMaterial
		var l_glass := dl.surface_get_material(1) as ShaderMaterial
		var l_liquid := dl.surface_get_material(2) as ShaderMaterial
		check(l_body != null and l_body.shader == LaneModelShader and l_body.render_priority == 0
			and l_glass != null and l_glass.shader == ItemModels.LaneModelCutShader and l_glass.render_priority == 0
			and l_glass.get_shader_parameter("alpha_mode") == 2
			and l_liquid != null and l_liquid.shader == ItemModels.LaneModelCutShader and l_liquid.render_priority == 0,
			"--item-glass=dither: far belt model body uses LaneModelShader, glass/liquid use LaneModelCutShader")
	ItemModels.glass_blend = true

	# The old way: no picture shared by both surfaces, so plain colours and one shared material.
	ItemModels.own_materials = false
	var old := ItemModels.read(path)
	check(old != null and not ItemModels.has_own(old), "--item-materials=old: no own materials")
	check(old != null and ItemModels.material_for(old) == ItemModels.material(), "--item-materials=old: the shared material")
	ItemModels.own_materials = true

	check(checked == 4, "every material checked through (%d of 4)" % checked)
	print("item_materials_test: %s" % ("PASS" if fails == 0 else "%d FAILED" % fails))
	TestEnv.clean()
	quit(1 if fails > 0 else 0)


## The see-through glass and liquid are drawn by `blend` (the transparent pass), the liquid inside before
## the glass around it; the body by `opaque`.
func _check_blend(dressed: Mesh, opaque: Shader, blend: Shader, what: String) -> void:
	var body := dressed.surface_get_material(0) as ShaderMaterial
	var glass := dressed.surface_get_material(1) as ShaderMaterial
	var liquid := dressed.surface_get_material(2) as ShaderMaterial
	if body == null or glass == null or liquid == null:
		check(false, "%s: three materials" % what)
		return
	check(body.shader == opaque, "%s: the body stays opaque" % what)
	check(glass.shader == blend and liquid.shader == blend, "%s: the glass and liquid blended" % what)
	check(glass.render_priority == 0 and liquid.render_priority < 0,
		"%s: the liquid blends before the glass around it (%d, %d)" % [what, liquid.render_priority, glass.render_priority])
	checked += 1


## The dressed mesh's first two surface materials carry the body's picture, the glass's glow and alpha.
func _check_world(dressed: Mesh, what: String) -> void:
	var body := dressed.surface_get_material(0) as ShaderMaterial
	var glass := dressed.surface_get_material(1) as ShaderMaterial
	check(body != null and glass != null, "%s: a material per surface" % what)
	if body == null or glass == null:
		return
	check(body.get_shader_parameter("picture") is Texture2D and body.get_shader_parameter("use_picture") == true,
		"%s: the body's picture" % what)
	check(glass.get_shader_parameter("use_emission_picture") != true, "%s: no emission picture" % what)
	var e: Variant = glass.get_shader_parameter("emission")
	# (Its exact value as glTF's reader gives it back: orange, red up and no blue.)
	check(e is Color and (e as Color).r > 0.9 and (e as Color).b < 0.1, "%s: the glass's glow colour (%s)" % [what, e])
	var energy: Variant = glass.get_shader_parameter("emission_energy")
	check(energy != null and float(energy) > 0.0, "%s: the glow's strength (%s)" % [what, energy])
	check(glass.get_shader_parameter("alpha_mode") == 2, "%s: the glass see-through" % what)
	# Drawn at the material's alpha times the vertices' (item_body.gdshaderinc): the file's 0.5, once.
	var c: Variant = glass.get_shader_parameter("color")
	var colours: Variant = dressed.surface_get_arrays(1)[Mesh.ARRAY_COLOR]
	var a := (c as Color).a if c is Color else 1.0
	if colours is PackedColorArray and not (colours as PackedColorArray).is_empty():
		a *= (colours as PackedColorArray)[0].a
	check(absf(a - 0.5) < 0.01, "%s: the glass's alpha 0.5 (%.2f)" % [what, a])
	check(body.get_shader_parameter("emission") == null, "%s: the body doesn't glow" % what)
	checked += 1


## A box (the body: a 4x4 picture, red and green), a smaller box above it (glass: orange glow, half
## see-through) and a smaller one inside that (a liquid, see-through too), one mesh of three surfaces,
## written as .glb.
func _write_fixture(path: String) -> bool:
	var image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	for y in 4:
		for x in 4:
			image.set_pixel(x, y, Color.RED if (x + y) % 2 == 0 else Color.GREEN)
	var body := StandardMaterial3D.new()
	body.resource_name = "body"
	body.albedo_texture = ImageTexture.create_from_image(image)
	var glass := StandardMaterial3D.new()
	glass.resource_name = "glass"
	glass.albedo_color = Color(0.8, 0.9, 1.0, 0.5)
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.emission_enabled = true
	glass.emission = GLOW
	glass.emission_energy_multiplier = GLOW_ENERGY
	var mesh := ArrayMesh.new()
	_add_box(mesh, Vector3(0.0, 0.05, 0.0), Vector3(0.2, 0.1, 0.2), body)
	_add_box(mesh, Vector3(0.0, 0.15, 0.0), Vector3(0.1, 0.1, 0.1), glass)
	var liquid := StandardMaterial3D.new()
	liquid.resource_name = "liquid"
	liquid.albedo_color = Color(0.9, 0.1, 0.1, 0.8)
	liquid.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_add_box(mesh, Vector3(0.0, 0.14, 0.0), Vector3(0.06, 0.06, 0.06), liquid)
	var root := Node3D.new()
	root.name = "Root"
	var mi := MeshInstance3D.new()
	mi.name = "Pack"
	mi.mesh = mesh
	root.add_child(mi)
	mi.owner = root
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var ok := doc.append_from_scene(root, state) == OK and doc.write_to_filesystem(state, path) == OK
	root.free()
	return ok


func _add_box(mesh: ArrayMesh, centre: Vector3, size: Vector3, material: Material) -> void:
	var box := BoxMesh.new()
	box.size = size
	var arrays := box.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for i in verts.size():
		verts[i] += centre
	arrays[Mesh.ARRAY_VERTEX] = verts
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(mesh.get_surface_count() - 1, material)


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
