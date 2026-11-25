extends SceneTree
## A model's .glb that asks for nearest filtering (Blender's Image Texture set to Closest) is drawn
## from the shader's crisp sampler; one that asks for linear stays as it was (model_textures.gd). A
## material set to Alpha Clip (glTF MASK) is drawn cut out at its cutoff, Alpha Blend see-through. A
## direction model's single file from a modeller's pack or FUE5's is turned to every direction.
##   godot --headless --path client -s res://tests/model_textures_test.gd

const ModelTextures := preload("res://scripts/world/model_textures.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const ModelSkin := preload("res://scripts/world/model_skin.gd")
## A skinned box with a one-second action (tools/models/make_baked_fixture.py).
const BAKED := "res://tests/fixtures/baked_box.glb"
const SOURCE := "res://assets/models/packs/fue5/wooden-chest.glb"
## An inserter rigged as an arm (tools/models/make_rig_fixture.py); `-- --rig=<path.glb>` checks others too.
const RIG := "res://tests/fixtures/rig_inserter.glb"
const ModelRig := preload("res://scripts/world/model_rig.gd")
const InserterArms := preload("res://scripts/world/inserter_arms.gd")
const BeltLods := preload("res://scripts/world/belt_lods.gd")
const BeltReturn := preload("res://scripts/world/belt_return.gd")
const TestEnv := preload("res://tests/test_env.gd")
## A textured model with levels of detail (FUE5's, 19,000 triangles).
const LEVELS_MODEL := "res://assets/models/packs/fue5/electric-mining-drill.glb"

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _init() -> void:
	TestEnv.isolate("model-textures-test")
	for mag in [9729, 9728]:
		var path := "user://model_textures_test_%d.glb" % mag
		check(_rewrite(ProjectSettings.globalize_path(SOURCE), ProjectSettings.globalize_path(path), mag), "rewrote %s" % SOURCE)
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		check(doc.append_from_file(ProjectSettings.globalize_path(path), state) == OK, "read the rewritten .glb")
		ModelTextures.prepare(ProjectSettings.globalize_path(path), state)
		var crisp := 0
		var textured := 0
		for m in state.get_materials():
			var base := m as BaseMaterial3D
			if base != null and base.albedo_texture != null:
				textured += 1
				if base.albedo_texture.has_meta(ModelTextures.NEAREST_META):
					crisp += 1
		check(textured > 0, "the chest has a base colour texture")
		if mag == 9728:
			check(crisp == textured, "NEAREST: every base colour texture marked crisp (%d of %d)" % [crisp, textured])
		else:
			check(crisp == 0, "LINEAR: no texture marked crisp (%d)" % crisp)
	_alpha_modes()
	_opaque_blend()
	_shared_pictures()
	_single_models()
	_belt_wrap()
	_belt_return()
	_belt_clip()
	_emission_strict()
	_idle_glow()
	_blend_clip()
	_baked()
	_fue5_pumpjack()
	_baked_own_look()
	_bake_rates()
	_rig()
	_wube_claw()
	_textured_levels()
	_texture_metal()
	_pack_pbr()
	_far_pbr()
	_pbr_reference()
	print("MODEL TEXTURES FAILS: %d" % fails)
	TestEnv.clean()
	quit(1 if fails > 0 else 0)


## 0.2.2: a modeller's metallic-roughness picture's metal is drawn at the share every other surface's
## is (looks.gd texture_metal, the shader's f3d_look_texture_metal). No built-in pack has such a
## picture, so while that holds the change can't touch them; the fixtures' metal box takes the picture
## path the global scales.
func _texture_metal() -> void:
	var files := 0
	var unexpected_metal: Array = []
	var unexpected_extra: Array = []
	var missing_pbr: Array = []
	for pack in ["placeholders", "wube3dp", "fue5"]:
		for path: String in _glbs("res://assets/models/packs/" + pack):
			files += 1
			var doc: Variant = _glb_json(path)
			var has_metal := false
			var has_norm := false
			var has_occ := false
			for m in (doc.get("materials", []) if doc is Dictionary else []):
				var md := m as Dictionary
				if (md.get("pbrMetallicRoughness", {}) as Dictionary).has("metallicRoughnessTexture"):
					has_metal = true
				if md.has("normalTexture"):
					has_norm = true
				if md.has("occlusionTexture"):
					has_occ = true
			if ModelLibrary.ModelPacks.pbr(path):
				if not (has_metal and has_norm and has_occ):
					missing_pbr.append(pack + "/" + path.get_file())
			else:
				if has_metal:
					unexpected_metal.append(pack + "/" + path.get_file())
				if has_norm or has_occ:
					unexpected_extra.append(pack + "/" + path.get_file())
	check(files > 500 and unexpected_metal.is_empty(),
		"texture metal: only PBR built-in .glbs have a metallic-roughness picture (%d files): %s" % [files, unexpected_metal])
	check(unexpected_extra.is_empty() and missing_pbr.is_empty(),
		"pack shading: non-PBR built-ins have no normal/occlusion pictures (%s), and every PBR built-in has all three (%s)" % [unexpected_extra, missing_pbr])
	var shader_text := FileAccess.get_file_as_string("res://shaders/factorio_material.gdshaderinc")
	check(shader_text.contains("global uniform float f3d_look_texture_metal;")
		and shader_text.contains("metal = metallic * orm.b * (mp ? f3d_look_pbr_metal : f3d_look_texture_metal);"),
		"texture metal: a picture's metal is scaled by the look's share in the model shader")
	for fixture in ["res://tests/fixtures/metal_box_metal.glb", "res://tests/fixtures/metal_box_paint.glb"]:
		var path := ProjectSettings.globalize_path(fixture)
		var state := GLTFState.new()
		check(GLTFDocument.new().append_from_file(path, state) == OK, "texture metal: read " + path.get_file())
		ModelTextures.prepare(path, state, true)
		var base := state.get_materials()[0] as BaseMaterial3D
		var m := ModelLibrary._factorio(base, false, false, false) as ShaderMaterial
		check(m != null and m.get_shader_parameter("use_orm_tex") == true and m.get_shader_parameter("use_albedo_tex") == true,
			"texture metal: %s is drawn with its own metallic-roughness picture" % path.get_file())


## 0.2.2: a pack whose pack.json says "shading": "pbr" (model_packs.gd shading()) has its textured materials
## drawn as their files say: Load marks them (PACK_PBR_META) and _factorio sets the shader's modeller_tex.
## A modeller's pack without the key, and Zenith's own, keep Factorio's balance; so does an untextured one.
func _pack_pbr() -> void:
	var path := ProjectSettings.globalize_path("res://tests/fixtures/metal_box_paint.glb")
	for c in [[true, true], [true, false], [false, false]]:
		var ld := ModelLibrary.Load.new()
		ld.path = path
		ld.modeller = c[0]
		ld.pbr = c[1]
		ld.run()
		var textured: Array = []
		for g in ld.groups:
			for key: Array in g[0]:
				var m: Material = key[0]
				if m is BaseMaterial3D and (m as BaseMaterial3D).albedo_texture != null and not textured.has(m):
					textured.append(m)
		var marked := 0
		var tex_on := 0
		for m: Material in textured:
			if m.has_meta(ModelLibrary.PACK_PBR_META):
				marked += 1
			if (ModelLibrary._factorio(m, false, false, false) as ShaderMaterial).get_shader_parameter("modeller_tex") == true:
				tex_on += 1
		var want := 1 if c[1] else 0
		check(ld.ok and textured.size() == 1 and marked == want and tex_on == want,
			"pack shading: modeller %s, pbr pack %s: %d of %d textured material(s) drawn as the file says" % [c[0], c[1], tex_on, textured.size()])
	var plain := StandardMaterial3D.new()
	plain.set_meta(ModelLibrary.PACK_PBR_META, true)  # marked, but with no OWN_LOOK_META (not a picture of a modeller's)
	check((ModelLibrary._factorio(plain, false, false, false) as ShaderMaterial).get_shader_parameter("modeller_tex") != true,
		"pack shading: a material without a modeller's picture never takes the path")
	var fue5 := load(SOURCE) as PackedScene
	var any_on := false
	if fue5 != null:
		var root := fue5.instantiate()
		for node in root.find_children("*", "MeshInstance3D", true, false):
			var mesh := (node as MeshInstance3D).mesh
			for i in mesh.get_surface_count():
				var m := mesh.surface_get_material(i)
				if m != null and (ModelLibrary._factorio(m, false, false, false) as ShaderMaterial).get_shader_parameter("modeller_tex") == true:
					any_on = true
		root.free()
	check(fue5 != null and not any_on, "pack shading: unmarked scene materials stay off modeller_tex")
	var fue5_ld := ModelLibrary.Load.new()
	fue5_ld.path = SOURCE
	fue5_ld.pbr = ModelLibrary.ModelPacks.pbr(SOURCE)
	fue5_ld.run()
	var fue5_mesh := ModelLibrary._commit_load(fue5_ld, []) if fue5_ld.ok else null
	var fue5_sm := fue5_mesh.surface_get_material(0) as ShaderMaterial if fue5_mesh != null and fue5_mesh.get_surface_count() > 0 else null
	var wube_ld := ModelLibrary.Load.new()
	wube_ld.path = "res://assets/models/packs/wube3dp/wooden-chest.glb"
	wube_ld.pbr = ModelLibrary.ModelPacks.pbr(wube_ld.path)
	wube_ld.run()
	var wube_mesh := ModelLibrary._commit_load(wube_ld, []) if wube_ld.ok else null
	var wube_sm := wube_mesh.surface_get_material(0) as ShaderMaterial if wube_mesh != null and wube_mesh.get_surface_count() > 0 else null
	var wube_belt_ld := ModelLibrary.Load.new()
	wube_belt_ld.path = "res://assets/models/packs/wube3dp/transport-belt.glb"
	wube_belt_ld.pbr = ModelLibrary.ModelPacks.pbr(wube_belt_ld.path)
	wube_belt_ld.run()
	var wube_belt_mesh := ModelLibrary._commit_load(wube_belt_ld, []) if wube_belt_ld.ok else null
	var wube_belt_on := false
	for i in (wube_belt_mesh.get_surface_count() if wube_belt_mesh != null else 0):
		var bsm := wube_belt_mesh.surface_get_material(i) as ShaderMaterial
		wube_belt_on = wube_belt_on or (bsm != null and bsm.get_shader_parameter("modeller_tex") == true)
	check(fue5_sm != null and fue5_sm.get_shader_parameter("modeller_tex") == fue5_ld.pbr
		and fue5_sm.get_shader_parameter("use_orm_tex") == true
		and fue5_sm.get_shader_parameter("use_normal_tex") == true
		and fue5_sm.get_shader_parameter("occlusion_mode") == 1,
		"pack shading: FUE5's textured chest takes PBR maps when ModelPacks.pbr() is on")
	check(wube_sm != null and wube_sm.get_shader_parameter("modeller_tex") == wube_ld.pbr
		and wube_sm.get_shader_parameter("use_orm_tex") == true
		and wube_sm.get_shader_parameter("use_normal_tex") == true
		and wube_sm.get_shader_parameter("occlusion_mode") == 1,
		"pack shading: Wube3DP's baked wooden chest takes PBR maps when ModelPacks.pbr() is on")
	check(wube_belt_mesh != null and not wube_belt_on,
		"pack shading: Wube3DP's excluded belt stays on Factorio's balance")
	var shader_text := FileAccess.get_file_as_string("res://shaders/factorio_material.gdshaderinc")
	check(shader_text.contains("uniform bool modeller_tex = false;") and shader_text.contains("global uniform float f3d_pack_shading;")
		and shader_text.contains("bool mp = m_modeller_tex && f3d_pack_shading > 0.5;")
		and shader_text.contains("float occluded = ((use_albedo_tex && !merged) || mp) ? 0.0 : 1.0 - ao;")
		and shader_text.contains("vec2 balance = mp ? f3d_look_texture_light"),
		"pack shading: the model shader's pbr path (and its untextured materials' grime) is keyed by the material and the global switch")


## 0.2.2: far chunks draw a "pbr" pack's textured model as near ones do: its vertices carry no part
## colour share (the far shader's balance off) and the look's texture_light baked in; with packs' own
## shading off, the old values (far_chunks.gd).
func _far_pbr() -> void:
	const FarChunks := preload("res://scripts/world/far_chunks.gd")
	const Looks := preload("res://scripts/world/looks.gd")
	var sm := ShaderMaterial.new()
	sm.set_shader_parameter("use_albedo_tex", true)
	sm.set_shader_parameter("modeller_tex", true)
	var was := Looks.packs_shade
	Looks.packs_shade = true
	var on := FarChunks._surface_params(sm)
	Looks.packs_shade = false
	var off := FarChunks._surface_params(sm)
	Looks.packs_shade = was
	sm.set_shader_parameter("modeller_tex", false)
	var not_pbr := FarChunks._surface_params(sm)
	check(bool(on.get("pbr")) and not bool(off.get("pbr")) and not bool(not_pbr.get("pbr")),
		"far pbr: a pbr pack's surface is read as one while packs' own shading is on, and only then")
	var box := BoxMesh.new().get_mesh_arrays()
	var pic := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	pic.fill(Color(0.6, 0.6, 0.6))
	var results := {}
	for c in [["pbr", true, Vector2(1, 1)], ["dim", true, Vector2(0.25, 0.25)], ["old", false, Vector2(1, 1)]]:
		var p := {"albedo": Color.WHITE, "tint": Color.WHITE, "part_data": 0.0, "part_colors": true, "vertex_data": 0.0,
			"desaturate": 0.0, "value": 1.0, "ao_strength": 1.0, "light": 1.0, "metallic": 0.0, "tex": pic,
			"pbr": c[1], "pbr_light": c[2]}
		var bake := FarChunks.Bake.new()
		bake.surfaces.append([box[Mesh.ARRAY_VERTEX], box[Mesh.ARRAY_NORMAL], null, null, box[Mesh.ARRAY_INDEX], [p], null, box[Mesh.ARRAY_TEX_UV]])
		bake.run()
		var share := 0
		var red := 0.0
		for col in bake.colors:
			share = maxi(share, roundi(col.a * 255.0) % 16)
			red += col.r
		results[c[0]] = [share, red / maxf(1.0, bake.colors.size()), bake.colors.size()]
	# pbr-standard step 2: a pbr pack's material without a picture: its factor, no part colour share, metal at the
	# paint share the textured ones get (the near shader's 0.1 before step 3's metal in full).
	var metals := {}
	for c in [["flat_pbr", true], ["flat_old", false]]:
		var p := {"albedo": Color.WHITE, "tint": Color.WHITE, "part_data": 1.0, "part_colors": true, "vertex_data": 0.0,
			"desaturate": 0.5, "value": 0.8, "ao_strength": 1.0, "light": 1.0, "metallic": 1.0, "pbr": c[1], "pbr_light": Vector2(1, 1)}
		var bake := FarChunks.Bake.new()
		bake.surfaces.append([box[Mesh.ARRAY_VERTEX], box[Mesh.ARRAY_NORMAL], null, null, box[Mesh.ARRAY_INDEX], [p], null, box[Mesh.ARRAY_TEX_UV]])
		bake.run()
		var col: Color = bake.colors[0] if bake.colors.size() > 0 else Color()
		metals[c[0]] = [roundi(col.a * 255.0) % 16, roundi(col.a * 255.0) / 16, col.r]
	check(int(metals["flat_pbr"][0]) == 0 and int(metals["flat_pbr"][1]) in [1, 2] and int(metals["flat_old"][1]) == 15
		and is_equal_approx(snappedf(float(metals["flat_pbr"][2]), 0.01), 1.0),
		"far pbr: an untextured pbr material bakes its factor (no desaturate or value), metal at 0.1; the old one in full (%s)" % [metals])
	var pbr: Array = results["pbr"]
	var dim: Array = results["dim"]
	var old: Array = results["old"]
	check(int(pbr[2]) > 0 and int(pbr[0]) == 0 and int(old[0]) == 15,
		"far pbr: a pbr pack's vertices carry no part colour share (%d), the old way's full (%d)" % [pbr[0], old[0]])
	check(float(pbr[1]) > 0.0 and is_equal_approx(snappedf(float(dim[1]) / float(pbr[1]), 0.02), 0.5) and is_equal_approx(float(pbr[1]), float(old[1])),
		"far pbr: the look's texture_light baked in (a quarter's light: %.3f of the colour's square root), the colour as before (%.3f, %.3f)"
		% [float(dim[1]) / maxf(0.0001, float(pbr[1])), pbr[1], old[1]])


## The standard PBR reference set (tools/models/make_pbr_reference.py, tests/fixtures/pbr_ref/): every file loads
## as a "pbr" pack's model and its material sets the shader parameters its glTF input asks for. Godot's own reader,
## which Zenith's path starts from, is pinned where the plan leans on it: occlusion strength is not read (no
## field), a texture transform is read for the base colour only (uv1_scale). Rows Zenith doesn't follow yet are
## checked as they are today, each marked "expected difference" so fixing one means flipping its line. (Godot keeps
## glTF's linear colour factors as sRGB colours: compared in linear.)
const PBR_REF := "res://tests/fixtures/pbr_ref/"


func _pbr_ref_material(name: String) -> Array:
	var ld := ModelLibrary.Load.new()
	ld.path = ProjectSettings.globalize_path(PBR_REF + name + ".glb")
	ld.combine = false
	ld.modeller = true
	ld.pbr = true
	ld.run()
	var mesh: Mesh = ModelLibrary._commit_load(ld, []) if ld.ok else null
	var sm: ShaderMaterial = null
	if mesh != null and mesh.get_surface_count() > 0:
		sm = mesh.surface_get_material(0) as ShaderMaterial
	var base: BaseMaterial3D = null
	for key in ModelLibrary._factorio_cache:
		if sm != null and ModelLibrary._factorio_cache[key] == sm and key is Array:
			base = (key as Array)[0] as BaseMaterial3D
	return [sm, base]


## pbr-standard step 2: a "pbr" pack's untextured material merges into MaterialRows via FLAG_MODELLER_TEX,
## and stays off the path with packs' own shading off when it loads or with --pbr-untextured=off
## (ModelLibrary.Load.pbr_all); a built-in model's materials never take it.
func _pbr_untextured() -> void:
	const Looks := preload("res://scripts/world/looks.gd")
	var path := ProjectSettings.globalize_path(PBR_REF + "factor_m1_r050.glb")
	var on_path := func(combine: bool, pbr: bool) -> Array:
		var ld := ModelLibrary.Load.new()
		ld.path = path
		ld.combine = combine
		ld.modeller = true
		ld.pbr = pbr
		ld.run()
		var mesh: Mesh = ModelLibrary._commit_load(ld, []) if ld.ok else null
		var sm: ShaderMaterial = mesh.surface_get_material(0) as ShaderMaterial if mesh != null else null
		return [sm != null and sm.get_shader_parameter("modeller_tex") == true, sm != null and sm.get_shader_parameter("material_table") != null]
	var merged_on: Array = on_path.call(true, true)
	var plain := StandardMaterial3D.new()
	var marked := StandardMaterial3D.new()
	marked.set_meta(ModelLibrary.PACK_PBR_META, true)
	var with_tex := StandardMaterial3D.new()
	with_tex.albedo_texture = ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGBA8))
	check(bool(merged_on[0]) and not bool(merged_on[1])
		and not ModelLibrary.Load.textured(marked) and not ModelLibrary.Load.textured(plain)
		and ModelLibrary.Load.textured(with_tex),
		"pbr untextured: on the path, untextured pbr materials merge into rows (%s)" % [merged_on])
	marked.set_meta(ModelLibrary.OWN_LOOK_META, true)
	var pbr_sm := ModelLibrary._factorio(marked, false, false, false) as ShaderMaterial
	var plain_sm := ModelLibrary._factorio(plain, false, false, false) as ShaderMaterial
	var row_merged := ModelLibrary.MaterialRows.make([pbr_sm, plain_sm])
	var pbr_flags := int(ModelLibrary.MaterialRows.row_vectors(pbr_sm)[1].w)
	var plain_flags := int(ModelLibrary.MaterialRows.row_vectors(plain_sm)[1].w)
	check((pbr_flags & ModelLibrary.MaterialRows.FLAG_MODELLER_TEX) != 0
		and (plain_flags & ModelLibrary.MaterialRows.FLAG_MODELLER_TEX) == 0
		and row_merged.get_shader_parameter("modeller_tex") == true
		and row_merged.get_shader_parameter("material_rows") == 2,
		"pbr untextured: merged row keeps FLAG_MODELLER_TEX for pbr row only (%d vs %d)" % [pbr_flags, plain_flags])
	var was := Looks.packs_shade
	Looks.packs_shade = false
	check(not bool(on_path.call(false, true)[0]), "pbr untextured: off the path when it loads with packs' own shading off")
	Looks.packs_shade = was
	ModelLibrary.Load.pbr_all = false
	check(not bool(on_path.call(false, true)[0]), "pbr untextured: off the path with --pbr-untextured=off")
	ModelLibrary.Load.pbr_all = true
	check(not bool(on_path.call(false, false)[0]), "pbr untextured: a modeller's pack without \"shading\": \"pbr\" stays off it")
	var non_pbr_on := false
	for f in ["res://assets/models/packs/wube3dp/transport-belt.glb", "res://assets/models/packs/placeholders/burner-mining-drill.glb"]:
		var ld := ModelLibrary.Load.new()
		ld.path = f
		ld.pbr = ModelLibrary.ModelPacks.pbr(f)
		ld.run()
		var mesh: Mesh = ModelLibrary._commit_load(ld, []) if ld.ok else null
		for i in (mesh.get_surface_count() if mesh != null else 0):
			var sm := mesh.surface_get_material(i) as ShaderMaterial
			non_pbr_on = non_pbr_on or (sm != null and sm.get_shader_parameter("modeller_tex") == true)
	var sf_ld := ModelLibrary.Load.new()
	sf_ld.path = "res://assets/models/packs/placeholders/electric-furnace.glb"
	sf_ld.pbr = ModelLibrary.ModelPacks.pbr(sf_ld.path)
	sf_ld.run()
	var sf_mesh: Mesh = ModelLibrary._commit_load(sf_ld, []) if sf_ld.ok else null
	var sf_on := false
	for i in (sf_mesh.get_surface_count() if sf_mesh != null else 0):
		var sm := sf_mesh.surface_get_material(i) as ShaderMaterial
		sf_on = sf_on or (sm != null and sm.get_shader_parameter("modeller_tex") == true)
	check(not non_pbr_on and sf_mesh != null and sf_on == ModelLibrary.ModelPacks.pbr(sf_ld.path),
		"pbr untextured: non-PBR built-ins stay off modeller_tex while baked Placeholders take it")
	var c1_leaked := ""
	for f in ["res://assets/models/packs/wube3dp/big-biter.glb", "res://assets/models/packs/placeholders/big-worm-turret.glb"]:
		for combine in [false, true]:
			var ld := ModelLibrary.Load.new()
			ld.path = f
			ld.combine = combine
			ld.pbr = true
			ld.run()
			var mesh: Mesh = ModelLibrary._commit_load(ld, []) if ld.ok else null
			if mesh == null:
				c1_leaked = "%s failed to load (combine=%s)" % [f.get_file(), combine]
				break
			for i in mesh.get_surface_count():
				var sm := mesh.surface_get_material(i) as ShaderMaterial
				var list: Array = ModelLibrary.MaterialRows.rows(sm)
				for r in (list if not list.is_empty() else [sm]):
					var row := r as ShaderMaterial
					if row != null and (row.get_shader_parameter("modeller_tex") == true \
							or (int(ModelLibrary.MaterialRows.row_vectors(row)[1].w) & ModelLibrary.MaterialRows.FLAG_MODELLER_TEX) != 0):
						c1_leaked = "%s/%s (combine=%s)" % [f.get_file(), row.resource_name, combine]
						break
				if c1_leaked != "":
					break
			if c1_leaked != "":
				break
		if c1_leaked != "":
			break
	var ls_ld := ModelLibrary.Load.new()
	ls_ld.path = "res://assets/models/packs/placeholders/lane-splitter.glb"
	ls_ld.combine = false
	ls_ld.pbr = true
	ls_ld.run()
	var ls_mesh: Mesh = ModelLibrary._commit_load(ls_ld, []) if ls_ld.ok else null
	var ls_body_pbr := false
	var ls_belt_c1_off := true
	for i in (ls_mesh.get_surface_count() if ls_mesh != null else 0):
		var sm := ls_mesh.surface_get_material(i) as ShaderMaterial
		if sm == null:
			continue
		if sm.resource_name == "pbr_body" and sm.get_shader_parameter("modeller_tex") == true:
			ls_body_pbr = true
		if sm.resource_name == "belt_surface" and sm.get_shader_parameter("modeller_tex") == true:
			ls_belt_c1_off = false
	ModelLibrary.ModelPacks.wait()
	var invalidated := ModelLibrary.mesh_for("behemoth-biter") != null and ModelLibrary.choices_changed(["big-biter"]) \
		and not ModelLibrary._cache.has("behemoth-biter")
	check(c1_leaked == "" and ls_body_pbr and ls_belt_c1_off and invalidated,
		"pbr untextured: CUSTOM1 surfaces stay off modeller_tex while textured lane-splitter surfaces keep it (%s, body=%s, belt_off=%s, alias=%s)"
		% [c1_leaked, ls_body_pbr, ls_belt_c1_off, invalidated])


func _pbr_reference() -> void:
	var files := _glbs(PBR_REF)
	check(files.size() >= 39 and FileAccess.file_exists(PBR_REF + ".gdignore"),
		"pbr reference: the set is there, kept out of Godot's import (%d files)" % files.size())
	for path: String in files:
		var got := _pbr_ref_material(path.get_file().get_basename())
		check(got[0] != null and got[1] != null, "pbr reference: %s loads with one material of the file's" % path.get_file())
	var p := func(sm: ShaderMaterial, key: String) -> Variant:
		return sm.get_shader_parameter(key) if sm != null else null
	# 1, 2: factors alone, and the same numbers as pictures (factors 1).
	for metal in [0, 1]:
		for r in [0.1, 0.3, 0.5, 0.7, 1.0]:
			var tag := "m%d_r%03d" % [metal, roundi(r * 100.0)]
			var fac: ShaderMaterial = _pbr_ref_material("factor_" + tag)[0]
			var pic: ShaderMaterial = _pbr_ref_material("picture_" + tag)[0]
			check(fac != null and is_equal_approx(float(p.call(fac, "roughness")), r) and is_equal_approx(float(p.call(fac, "metallic")), metal)
				and (p.call(fac, "albedo") as Color).srgb_to_linear().is_equal_approx(Color(0.5, 0.5, 0.5)),
				"pbr reference: factor_%s's factors as the file says" % tag)
			check(pic != null and p.call(pic, "use_albedo_tex") == true and p.call(pic, "use_orm_tex") == true
				and p.call(pic, "modeller_tex") == true and is_equal_approx(float(p.call(pic, "roughness")), 1.0),
				"pbr reference: picture_%s on the pbr path with its pictures" % tag)
			# pbr-standard step 2: a pbr pack's material without a picture is on the pbr path too.
			check(fac != null and p.call(fac, "modeller_tex") == true and p.call(fac, "use_albedo_tex") != true
				and is_equal_approx(float(p.call(fac, "rust")), 0.0) and is_equal_approx(float(p.call(fac, "grain")), 0.0),
				"pbr reference: factor_%s (no picture) on the pbr path, unweathered" % tag)
	_pbr_untextured()
	var tint: ShaderMaterial = _pbr_ref_material("base_tint")[0]
	check((p.call(tint, "albedo") as Color).srgb_to_linear().is_equal_approx(Color(0.5, 1.0, 1.0)) and p.call(tint, "use_albedo_tex") == true,
		"pbr reference: the base colour picture times its factor")
	for c in [["normal_east", 1.0], ["normal_east_half", 0.5], ["normal_mirrored", 1.0]]:
		var sm: ShaderMaterial = _pbr_ref_material(c[0])[0]
		check(p.call(sm, "use_normal_tex") == true and is_equal_approx(float(p.call(sm, "normal_scale")), float(c[1])),
			"pbr reference: %s's normal map at scale %.1f" % c)
	# Occlusion: packed (mode 1) or separate (2), red. Godot keeps no strength: the 0.5 files load the same.
	for packed in [true, false]:
		var both: Array = []
		for s in ["s10", "s05"]:
			var got := _pbr_ref_material("occ_%s_%s" % ["packed" if packed else "separate", s])
			both.append(got)
			check(p.call(got[0], "occlusion_mode") == (1 if packed else 2) and (p.call(got[0], "occlusion_channel") as Vector4).is_equal_approx(Vector4(1, 0, 0, 0)),
				"pbr reference: occlusion %s %s read from the red" % ["packed" if packed else "separate", s])
		var a := both[0][1] as BaseMaterial3D
		var b := both[1][1] as BaseMaterial3D
		check(a != null and b != null and a.ao_light_affect == b.ao_light_affect and a.ao_texture_channel == b.ao_texture_channel,
			"pbr reference: Godot's reader keeps no occlusion strength (expected difference: strength 0.5 drawn as 1)")
	var ef: ShaderMaterial = _pbr_ref_material("emit_factor")[0]
	var eh: ShaderMaterial = _pbr_ref_material("emit_half_black")[0]
	var e2: ShaderMaterial = _pbr_ref_material("emit_strength2")[0]
	check((p.call(ef, "emission") as Color).srgb_to_linear().is_equal_approx(Color(1.0, 0.5, 0.0)) and p.call(ef, "activity_glow") == true,
		"pbr reference: an emissive factor glows (while the machine works, by design)")
	check(p.call(eh, "use_emission_tex") == true, "pbr reference: an emissive picture is used")
	check(is_equal_approx(float(p.call(e2, "emission_energy")), 2.0) and is_equal_approx(float(p.call(ef, "emission_energy")), 1.0),
		"pbr reference: KHR_materials_emissive_strength 2 (%s)" % p.call(e2, "emission_energy"))
	var mask: ShaderMaterial = _pbr_ref_material("alpha_mask")[0]
	var blend: ShaderMaterial = _pbr_ref_material("alpha_blend")[0]
	var tube: ShaderMaterial = _pbr_ref_material("tube_double")[0]
	check(mask != null and mask.shader == ModelLibrary.FactorioClipShader and is_equal_approx(float(p.call(mask, "alpha_clip")), 0.5),
		"pbr reference: MASK cut out at its cutoff")
	# pbr-window-fix: a single-sided MASK (doubleSided false, Godot's CULL_BACK) drops its back faces on a "pbr"
	# pack's material, as Godot's own does (the window pass saw its dark inside through the cut); a double-sided
	# one, and any other pack's cut-out, draw both sides as before.
	var mask_base: BaseMaterial3D = _pbr_ref_material("alpha_mask")[1]
	check(mask_base != null and mask_base.cull_mode == BaseMaterial3D.CULL_BACK and p.call(mask, "clip_one_side") == true,
		"pbr reference: a single-sided MASK drops its back faces (clip_one_side)")
	if mask_base != null:
		var two := mask_base.duplicate() as BaseMaterial3D
		two.cull_mode = BaseMaterial3D.CULL_DISABLED
		var other := mask_base.duplicate() as BaseMaterial3D
		other.remove_meta(ModelLibrary.PACK_PBR_META)
		var two_sm := ModelLibrary._factorio(two, false, false, false) as ShaderMaterial
		var other_sm := ModelLibrary._factorio(other, false, false, false) as ShaderMaterial
		check(two.has_meta(ModelLibrary.PACK_PBR_META) and two_sm.shader == ModelLibrary.FactorioClipShader
			and two_sm.get_shader_parameter("clip_one_side") != true,
			"pbr reference: a double-sided MASK keeps both sides (%s)" % two_sm.get_shader_parameter("clip_one_side"))
		check(other_sm.shader == ModelLibrary.FactorioClipShader and other_sm.get_shader_parameter("clip_one_side") != true,
			"pbr reference: another pack's single-sided cut-out keeps both sides (%s)" % other_sm.get_shader_parameter("clip_one_side"))
	var uniforms := func(sh: Shader) -> Array:
		return sh.get_shader_uniform_list().map(func(u: Dictionary) -> String: return str(u["name"]))
	check(uniforms.call(ModelLibrary.FactorioClipShader).has("clip_one_side") and not uniforms.call(ModelLibrary.FactorioShader).has("clip_one_side"),
		"pbr reference: clip_one_side is the cut-out shader's alone (it compiles)")
	var clip_code := FileAccess.get_file_as_string("res://shaders/factorio_material.gdshaderinc")
	check(clip_code.contains("if (clip_one_side && modeller_tex && f3d_pack_shading > 0.5 && !FRONT_FACING) {"),
		"pbr reference: the clip shader drops a pbr single-sided cut-out's back faces only while packs' own shading is on")
	check(blend != null and blend.shader == ModelLibrary.FactorioAlphaShader, "pbr reference: BLEND see-through")
	check(tube != null and tube.shader == ModelLibrary.FactorioShader,
		"pbr reference: doubleSided ignored on an opaque material (expected difference: back faces culled)")
	check(p.call(_pbr_ref_material("nearest_checker")[0], "albedo_nearest") == true, "pbr reference: NEAREST honoured on the base colour")
	# Texture transform: Godot reads it into uv1_scale for the base colour only; Zenith's shader has no uv1_scale.
	var tt_base: BaseMaterial3D = _pbr_ref_material("uv_transform")[1]
	var tt_normal: BaseMaterial3D = _pbr_ref_material("uv_transform_normal")[1]
	check(tt_base != null and tt_base.uv1_scale.is_equal_approx(Vector3(2, 2, 1)) and tt_normal != null and tt_normal.uv1_scale.is_equal_approx(Vector3.ONE),
		"pbr reference: Godot reads a texture transform for the base colour only (%s, normal map's %s)"
		% [tt_base.uv1_scale if tt_base != null else null, tt_normal.uv1_scale if tt_normal != null else null])
	var occ1: BaseMaterial3D = _pbr_ref_material("occ_uv1")[1]
	check(occ1 != null and occ1.get_flag(BaseMaterial3D.FLAG_AO_ON_UV2),
		"pbr reference: Godot puts an occlusion picture on a second UV set (expected difference: Zenith reads set 0)")


## Every .glb under `dir`, its folders too.
func _glbs(dir: String) -> Array:
	var out: Array = []
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".glb"):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		out.append_array(_glbs(dir.path_join(d)))
	return out


## A .glb's glTF JSON, or null.
func _glb_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_32() != 0x46546C67:
		return null
	f.get_32()
	f.get_32()
	var length := f.get_32()
	if f.get_32() != 0x4E4F534A:
		return null
	return JSON.parse_string(f.get_buffer(length).get_string_from_utf8())


## The .glb at `src` with every sampler's magFilter and minFilter set to `mag`, written to `dst`.
func _rewrite(src: String, dst: String, mag: int, material := {}) -> bool:
	var f := FileAccess.open(src, FileAccess.READ)
	if f == null or f.get_32() != 0x46546C67:
		return false
	var version := f.get_32()
	f.get_32()
	var json_len := f.get_32()
	f.get_32()
	var doc = JSON.parse_string(f.get_buffer(json_len).get_string_from_utf8())
	var rest := f.get_buffer(f.get_length() - f.get_position())
	if not doc is Dictionary:
		return false
	var samplers: Array = doc.get("samplers", [])
	if samplers.is_empty():
		samplers.append({})
		doc["samplers"] = samplers
		for t in doc.get("textures", []):
			t["sampler"] = 0
	for s in samplers:
		s["magFilter"] = mag
		s["minFilter"] = 9984 if mag == 9728 else 9987
	for m in doc.get("materials", []):
		m.merge(material, true)
	var text := JSON.stringify(doc).to_utf8_buffer()
	while text.size() % 4 != 0:
		text.append(0x20)
	var out := FileAccess.open(dst, FileAccess.WRITE)
	out.store_32(0x46546C67)
	out.store_32(version)
	out.store_32(12 + 8 + text.size() + rest.size())
	out.store_32(text.size())
	out.store_32(0x4E4F534A)
	out.store_buffer(text)
	out.store_buffer(rest)
	out.close()
	return true


## Blender's Alpha Clip (glTF MASK with alphaCutoff) and Alpha Blend (BLEND) reach their shaders.
func _alpha_modes() -> void:
	var cases := [[{"alphaMode": "MASK", "alphaCutoff": 0.3}, ModelLibrary.FactorioClipShader, "MASK"],
		[{"alphaMode": "BLEND"}, ModelLibrary.FactorioAlphaShader, "BLEND"],
		[{"alphaMode": "OPAQUE"}, ModelLibrary.FactorioShader, "OPAQUE"]]
	for c in cases:
		var path := ProjectSettings.globalize_path("user://model_textures_test_alpha.glb")
		check(_rewrite(ProjectSettings.globalize_path(SOURCE), path, 9729, c[0]), "rewrote for " + c[2])
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		check(doc.append_from_file(path, state) == OK, "read the %s .glb" % c[2])
		var base := state.get_materials()[0] as BaseMaterial3D
		var out := ModelLibrary._factorio(base, false, false, false) as ShaderMaterial
		check(out != null and out.shader == c[1], "%s: drawn with %s" % [c[2], (c[1] as Shader).resource_path])
		if c[2] == "MASK":
			check(absf(float(out.get_shader_parameter("alpha_clip")) - 0.3) < 0.001,
				"MASK: the cutoff 0.3 reaches the shader (%s)" % out.get_shader_parameter("alpha_clip"))
			check(ModelLibrary.Load.variant(base) == 3, "MASK: a cut-out material is never merged with solid ones")


## An Alpha Blend material whose base colour is opaque, colour and picture alike, loads as a solid one
## (Vasillo's belt surface: BLEND with a picture without alpha); see-through colour, a glowing material
## and --opaque-blend=off stay see-through.
func _opaque_blend() -> void:
	var cases := [[{"alphaMode": "BLEND"}, true, ModelLibrary.FactorioShader, "BLEND, a JPEG picture"],
		[{"alphaMode": "BLEND", "pbrMetallicRoughness": {"baseColorFactor": [1, 1, 1, 0.5], "baseColorTexture": {"index": 0}}}, true,
			ModelLibrary.FactorioAlphaShader, "BLEND, half see-through colour"],
		[{"alphaMode": "BLEND", "emissiveFactor": [1, 0.5, 0]}, true, ModelLibrary.FactorioAlphaShader, "BLEND, glowing"],
		[{"alphaMode": "BLEND"}, false, ModelLibrary.FactorioAlphaShader, "BLEND with --opaque-blend=off"]]
	var was: bool = ModelTextures.opaque_blend
	for c in cases:
		ModelTextures.opaque_blend = c[1]
		var path := ProjectSettings.globalize_path("user://model_textures_test_blend.glb")
		check(_rewrite(ProjectSettings.globalize_path(SOURCE), path, 9729, c[0]), "rewrote for " + c[3])
		var state := GLTFState.new()
		check(GLTFDocument.new().append_from_file(path, state) == OK, "read the %s .glb" % c[3])
		ModelTextures.prepare(path, state)
		var base := state.get_materials()[0] as BaseMaterial3D
		check(base.albedo_texture != null and bool(base.albedo_texture.get_meta(ModelTextures.OPAQUE_META, false)),
			"%s: the picture is known to be opaque" % c[3])
		var out := ModelLibrary._factorio(base, false, false, false) as ShaderMaterial
		check(out != null and out.shader == c[2], "%s: drawn with %s" % [c[3], (c[2] as Shader).resource_path])
	ModelTextures.opaque_blend = was
	# A picture with see-through pixels keeps the material see-through.
	var glass := StandardMaterial3D.new()
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 0.5))
	glass.albedo_texture = ImageTexture.create_from_image(img)
	glass.albedo_texture.set_meta(ModelTextures.OPAQUE_META, img.detect_alpha() == Image.ALPHA_NONE)
	check(not ModelTextures.solid_blend(glass), "BLEND with a half see-through picture stays see-through")


## Models carrying the same picture share one texture (by a hash of its bytes): Vasillo's 39 models
## bring 188 textures of 48 pictures. Its crisp (NEAREST) and smooth uses stay apart.
func _shared_pictures() -> void:
	var path := ProjectSettings.globalize_path("user://model_textures_test_shared.glb")
	check(_rewrite(ProjectSettings.globalize_path(SOURCE), path, 9729), "rewrote for sharing")
	var textures: Array = []
	for i in 2:
		var state := GLTFState.new()
		check(GLTFDocument.new().append_from_file(path, state) == OK, "read the .glb again (%d)" % i)
		ModelTextures.prepare(path, state)
		textures.append((state.get_materials()[0] as BaseMaterial3D).albedo_texture)
	check(textures[0] != null and textures[0] == textures[1] and ModelTextures.shared_count > 0,
		"the same picture in two models is one texture (%d made, %d shared)" % [ModelTextures.made_count, ModelTextures.shared_count])
	var crisp_path := ProjectSettings.globalize_path("user://model_textures_test_shared_crisp.glb")
	check(_rewrite(ProjectSettings.globalize_path(SOURCE), crisp_path, 9728), "rewrote for sharing, crisp")
	var crisp_state := GLTFState.new()
	GLTFDocument.new().append_from_file(crisp_path, crisp_state)
	ModelTextures.prepare(crisp_path, crisp_state)
	var crisp: Texture2D = (crisp_state.get_materials()[0] as BaseMaterial3D).albedo_texture
	check(crisp != textures[0] and crisp.has_meta(ModelTextures.NEAREST_META) and not (textures[0] as Texture2D).has_meta(ModelTextures.NEAREST_META),
		"drawn crisp it is a texture of its own")
	var was: bool = ModelTextures.share
	ModelTextures.share = false
	var own_state := GLTFState.new()
	GLTFDocument.new().append_from_file(path, own_state)
	ModelTextures.prepare(path, own_state)
	check((own_state.get_materials()[0] as BaseMaterial3D).albedo_texture != textures[0], "--share-textures=off: every model its own")
	ModelTextures.share = was


## A FACING_MODELS entity whose north model comes from FUE5's pack or a modeller's, with no east
## model in that pack, is drawn with that one model turned; with all four there, unturned.
func _single_models() -> void:
	var G := ModelLibrary.GLTF_SOURCE
	ModelLibrary._sources["boiler"] = G + "res://assets/models/packs/fue5/boiler.glb"
	ModelLibrary._sources["boiler-east"] = G + "res://assets/models/packs/placeholders/boiler-east.glb"
	check(ModelLibrary.single_model("boiler") and ModelLibrary.model_name("boiler", "boiler", {}, 4) == "boiler"
		and ModelLibrary.turn_dir("boiler", 4, {}, "boiler") == 4, "FUE5's boiler: one model, turned east")
	var was := ModelLibrary.ModelPacks.packs
	ModelLibrary.ModelPacks.use([ModelLibrary.ModelPacks.folder_pack("C:/modeller/models", true)])
	ModelLibrary._sources["pumpjack"] = G + "C:/modeller/models/pumpjack.glb"
	ModelLibrary._sources["pumpjack-east"] = G + "res://assets/models/packs/placeholders/pumpjack-east.glb"
	check(ModelLibrary.model_name("pumpjack", "mining-drill", {}, 8) == "pumpjack"
		and ModelLibrary.turn_dir("mining-drill", 8, {}, "pumpjack") == 8, "a modeller's one pumpjack: turned south")
	ModelLibrary._sources["pumpjack-east"] = G + "C:/modeller/models/pumpjack-east.glb"
	check(not ModelLibrary.single_model("pumpjack") and ModelLibrary.model_name("pumpjack", "mining-drill", {}, 4) == "pumpjack-east",
		"a modeller's four pumpjacks: each drawn unturned")
	ModelLibrary._sources["inserter"] = G + "res://assets/models/packs/wube3dp/inserter.glb"
	ModelLibrary._sources["inserter-east"] = G + "res://assets/models/packs/wube3dp/inserter-east.glb"
	check(not ModelLibrary.single_model("inserter"), "Zenith's own inserters: still a model per direction")
	ModelLibrary.ModelPacks.use(was)
	for n in ["boiler", "boiler-east", "pumpjack", "pumpjack-east", "inserter", "inserter-east"]:
		ModelLibrary._sources.erase(n)


## A belt's return run (belt_return.gd): a textured belt surface with a return of its own (Vasillo's
## layout: a strip just above the ground facing down, its UVs mirrored) gets that strip's inner side drawn,
## facing up under the top run, its texture running the other way at the same speed; one with only its
## top run gets it mirrored down to FLOOR. Drawn in the surface's own draw, left out of the CPU arrays
## the scroll's fit, levels, shadow stand-ins and far chunks read; carried by a tier's copy. None on the
## end pieces, an untextured (Zenith's own) belt, a model without a belt surface, or with
## --belt-return=off. `-- --models-dir=<folder>` (or ZENITH_TEST_MODELS) loads a modeller's belts and reports each one's return.
func _belt_return() -> void:
	check(BeltReturn.shape_for("transport-belt") == 0 and BeltReturn.shape_for("fast-transport-belt-curve-left") == 1
		and BeltReturn.shape_for("transport-belt-curve-right") == 2 and BeltReturn.shape_for("transport-belt-start") == -1
		and BeltReturn.shape_for("express-transport-belt-end") == -1, "return: straights and curves get one, a line's end pieces none")
	# The model's own return: its inner side.
	var own := _belt_arrays(true)
	var ret: Variant = BeltReturn.build(own, 0)
	check(ret != null, "return: a surface with a return of its own gets its inner side")
	if ret != null:
		_check_return(ret, own, 0.006, 0.006, "own")
		check((ret[Mesh.ARRAY_INDEX] as PackedInt32Array).size() == 6, "return (own): its two faces, no more (%d indices)" % (ret[Mesh.ARRAY_INDEX] as PackedInt32Array).size())
	# A top run alone: mirrored down to FLOOR.
	var top := _belt_arrays(false)
	var mirrored: Variant = BeltReturn.build(top, 0)
	check(mirrored != null, "return: a surface with only its top run gets it mirrored under it")
	if mirrored != null:
		_check_return(mirrored, top, BeltReturn.FLOOR, BeltReturn.FLOOR, "mirrored")
	# Through the loader: a belt written as a .glb (a base and a textured Belt_Surface), read as a modeller's is.
	var path := ProjectSettings.globalize_path("user://model_textures_test_belt.glb")
	check(_belt_glb(path), "return: wrote a test belt .glb")
	var G := ModelLibrary.GLTF_SOURCE
	for name in ["f3d-test-belt", "f3d-test-belt-end", "f3d-test-belt-off"]:
		ModelLibrary._sources[name] = G + path
	var mesh := ModelLibrary.mesh_for("f3d-test-belt") as ArrayMesh
	var surface := _belt_surface_index(mesh)
	check(surface >= 0, "return: the test belt loads with its belt surface")
	if surface >= 0:
		var kept: Array = ModelLods.arrays_of(mesh, surface)
		var kept_tris := (kept[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		var drawn_tris := mesh.surface_get_array_index_len(surface) / 3
		check(kept_tris == 4 and drawn_tris == 6,
			"return: drawn in the surface's own draw (%d triangles), the CPU arrays (levels, shadow stand-ins, far chunks) without it (%d)" % [drawn_tris, kept_tris])
		var rets: Array = mesh.get_meta(BeltReturn.META, [])
		check(surface < rets.size() and rets[surface] != null, "return: kept with the model for its copies")
		var scroll: Vector2 = (mesh.surface_get_material(surface) as ShaderMaterial).get_shader_parameter("belt_uv_scroll")
		check(scroll.distance_to(Vector2(1.0, 0.0)) < 0.01, "return: the scroll is still fitted on the top run alone (%s)" % scroll)
		if surface < rets.size() and rets[surface] != null:
			var got: Array = BeltReturn.describe(rets[surface], 0)
			check(got[2].distance_to(-scroll) < 0.01 and float(got[1]) < 0.25 - BeltReturn.GAP,
				"return: under the top run (y %.3f-%.3f), its texture running the other way (%s against %s)" % [got[0], got[1], got[2], scroll])
		var copy := ModelLibrary._copy(mesh)
		check(copy.surface_get_array_index_len(surface) == mesh.surface_get_array_index_len(surface) and copy.has_meta(BeltReturn.META),
			"return: a tier's copy of the model draws it too")
		for i in mesh.get_surface_count():
			if i != surface:
				check(mesh.surface_get_array_index_len(i) == (ModelLods.arrays_of(mesh, i)[Mesh.ARRAY_INDEX] as PackedInt32Array).size(),
					"return: the belt's other surfaces get none (surface %d)" % i)
	var end_piece := ModelLibrary.mesh_for("f3d-test-belt-end") as ArrayMesh
	check(end_piece != null and not end_piece.has_meta(BeltReturn.META), "return: none on a line's end piece (its surface is the wrap)")
	var was := BeltReturn.enabled
	BeltReturn.enabled = false
	var off := ModelLibrary.mesh_for("f3d-test-belt-off") as ArrayMesh
	BeltReturn.enabled = was
	check(off != null and not off.has_meta(BeltReturn.META), "return: none with --belt-return=off")
	for name in ["f3d-test-belt", "f3d-test-belt-end", "f3d-test-belt-off"]:
		ModelLibrary._sources.erase(name)
	var zenith := ModelLibrary.mesh_for("transport-belt@builtin:wube3dp") as ArrayMesh
	check(zenith != null and not zenith.has_meta(BeltReturn.META), "return: none on Zenith's own belt (drawn slats on a closed frame)")
	# FUE5's belts: the top a textured surface of its own, scrolled along the belt one repeat a tile on
	# straights and curves alike, at the tier's speed.
	for name in ["transport-belt", "transport-belt-curve-left", "transport-belt-curve-right", "turbo-transport-belt-curve-left"]:
		var fue5 := ModelLibrary.mesh_for(name + "@builtin:fue5") as ArrayMesh
		var surf: ShaderMaterial = null
		for i in (fue5.get_surface_count() if fue5 != null else 0):
			var m := fue5.surface_get_material(i) as ShaderMaterial
			if m != null and m.resource_name.to_lower().contains(ModelLibrary.BELT_MATERIAL):
				surf = m
		var speed := 7.5 if name.begins_with("turbo-") else 1.875
		check(surf != null and surf.get_shader_parameter("use_albedo_tex") == true
			and surf.get_shader_parameter("belt_uv_scroll") == Vector2(1, 0)
			and is_equal_approx(float(surf.get_shader_parameter("belt_speed")), speed),
			"FUE5's %s: a textured surface scrolling one repeat a tile (%s, speed %s)" % [name,
				surf.get_shader_parameter("belt_uv_scroll") if surf else null, surf.get_shader_parameter("belt_speed") if surf else null])
	var chest := ModelLibrary.Load.new()
	chest.path = ProjectSettings.globalize_path(SOURCE)
	chest.belt_shape = 0
	chest.run()
	check(chest.ok and chest.returns.is_empty(), "return: none on a model without a belt surface")
	var belt_dir := TestEnv.models_dir(["--belt-dir="])
	if belt_dir == "":
		print("SKIP: a modeller's belts: no folder given (-- --models-dir=<folder> or ZENITH_TEST_MODELS)")
	elif not DirAccess.dir_exists_absolute(belt_dir):
		print("SKIP: a modeller's belts: no folder at %s" % belt_dir)
	else:
		_belt_dir(belt_dir)
		_clip_dir(belt_dir)


## A belt surface set to Alpha Blend with a picture that has see-through pixels (Vasillo's new belts)
## loads cut out at 0.5, not blended: blended, its return run (drawn in the same draw) painted its
## backward chevrons over the top. Its scroll is unchanged, the belt's other (blended) material stays
## blended, and --belt-surface-blend=on keeps the old see-through material. The return's triangles
## come first in the draw (BeltReturn.joined), after with --belt-return-first=off.
func _belt_clip() -> void:
	var path := ProjectSettings.globalize_path("user://model_textures_test_belt_clip.glb")
	check(_belt_glb(path, true), "clip: wrote a test belt .glb with a see-through picture")
	var G := ModelLibrary.GLTF_SOURCE
	var was: bool = ModelTextures.belt_clip
	for clip in [true, false]:
		ModelTextures.belt_clip = clip
		var name := "f3d-test-belt-clip-%s" % clip
		ModelLibrary._sources[name] = G + path
		var mesh := ModelLibrary.mesh_for(name) as ArrayMesh
		ModelLibrary._sources.erase(name)
		var surface := _belt_surface_index(mesh)
		check(surface >= 0, "clip (%s): the belt loads with its belt surface" % clip)
		if surface < 0:
			continue
		var m := mesh.surface_get_material(surface) as ShaderMaterial
		var scroll: Vector2 = m.get_shader_parameter("belt_uv_scroll")
		check(scroll.distance_to(Vector2(1.0, 0.0)) < 0.01, "clip (%s): the belt still scrolls one repeat a tile (%s)" % [clip, scroll])
		if clip:
			check(m.shader == ModelLibrary.FactorioClipShader and absf(float(m.get_shader_parameter("alpha_clip")) - 0.5) < 0.001,
				"clip: a blended belt surface with a see-through picture is drawn cut out at 0.5 (%s, %s)" % [m.shader.resource_path, m.get_shader_parameter("alpha_clip")])
		else:
			check(m.shader == ModelLibrary.FactorioAlphaShader,
				"--belt-surface-blend=on: the belt surface stays see-through (%s)" % m.shader.resource_path)
		for i in mesh.get_surface_count():
			var other := mesh.surface_get_material(i) as ShaderMaterial
			if i != surface and other != null:
				check(other.shader == ModelLibrary.FactorioAlphaShader,
					"clip (%s): the belt's other blended material stays see-through (%s)" % [clip, other.shader.resource_path])
		var rets: Array = mesh.get_meta(BeltReturn.META, [])
		check(surface < rets.size() and rets[surface] != null, "clip (%s): the belt keeps its return" % clip)
	ModelTextures.belt_clip = was
	# The material rule alone: only a belt surface, only a see-through picture, only an opaque colour.
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	img.set_pixel(0, 0, Color(1, 1, 1, 0))
	var notched := ImageTexture.create_from_image(img)
	notched.set_meta(ModelTextures.OPAQUE_META, false)
	var made := func(n: String, alpha: float, tex: Texture2D) -> StandardMaterial3D:
		var b := StandardMaterial3D.new()
		b.resource_name = n
		b.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		b.albedo_color = Color(1, 1, 1, alpha)
		b.albedo_texture = tex
		return b
	check(ModelTextures.clip_belt(made.call("Belt_Surface", 1.0, notched)), "clip: a blended Belt_Surface with a notched picture")
	check(not ModelTextures.clip_belt(made.call("Glass", 1.0, notched)), "clip: not another material")
	check(not ModelTextures.clip_belt(made.call("Belt_Surface", 0.5, notched)), "clip: not a half see-through colour")
	var solid := ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGB8))
	solid.set_meta(ModelTextures.OPAQUE_META, true)
	check(not ModelTextures.clip_belt(made.call("Belt_Surface", 1.0, solid)), "clip: not an opaque picture (that one is drawn solid)")
	# Option B: the return's triangles first in the joined draw.
	var top := _belt_arrays(false)
	var ret: Array = BeltReturn.build(top, 0)
	var base := (top[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var count := (ret[Mesh.ARRAY_INDEX] as PackedInt32Array).size()
	var first_was := BeltReturn.first
	for first in [true, false]:
		BeltReturn.first = first
		var idx: PackedInt32Array = BeltReturn.joined(top, ret)[Mesh.ARRAY_INDEX]
		var head := idx.slice(0, count)
		var tail := idx.slice(idx.size() - count)
		var ret_at_head := Array(head).all(func(k: int) -> bool: return k >= base)
		var ret_at_tail := Array(tail).all(func(k: int) -> bool: return k >= base)
		check(idx.size() == (top[Mesh.ARRAY_INDEX] as PackedInt32Array).size() + count, "joined (%s): every triangle drawn once" % first)
		if first:
			check(ret_at_head and not ret_at_tail, "joined: the return's triangles come first, the top run's last")
		else:
			check(ret_at_tail and not ret_at_head, "--belt-return-first=off: the return's triangles after the top run's")
	BeltReturn.first = first_was


## Emission as glTF says (model_textures.gd emission_strict): a material glows only by its emissiveFactor.
## An emission picture with no factor (Vasillo's export: a black one in 30 see-through materials), a factor
## of 0, or a black picture is no glow: the material isn't drawn as lighting up at work nor, see-through,
## as a plume that vanishes at rest. A real plume still fades; the glow drawn is picture x factor x strength.
## --emission-strict=off reads them as before (Godot's reading: any emission picture glows).
func _emission_strict() -> void:
	var black := _picture(Color.BLACK, 1.0, 0)
	var lit := _picture(Color(1.0, 0.5, 0.1), 1.0, 0)
	var opaque := _picture(Color(0.4, 0.4, 0.4), 1.0, 0)
	var some_alpha := _picture(Color(0.4, 0.4, 0.4), 0.5, 0)
	var was: bool = ModelTextures.emission_strict
	for strict in [true, false]:
		ModelTextures.emission_strict = strict
		var tag := "" if strict else " (--emission-strict=off)"
		# 1. BLEND, a black emission picture, no factor, the picture opaque: solid, no glow.
		var m := _mat_material({"alphaMode": "BLEND"}, opaque, black)
		var p := _params(m)
		if strict:
			check(p["shader"] == ModelLibrary.FactorioShader and not p["glow"],
				"emission 1: BLEND, black emission picture, no factor, opaque picture: the solid shader, no activity_glow (%s, %s)" % [p["file"], p["glow"]])
		else:
			check(p["shader"] == ModelLibrary.FactorioAlphaShader and p["glow"] and p["fades"],
				"emission 1%s: see-through and fading, as before (%s, %s, %s)" % [tag, p["file"], p["glow"], p["fades"]])
		# 2. The same with a see-through picture: still blended (glass), not a plume.
		p = _params(_mat_material({"alphaMode": "BLEND"}, some_alpha, black))
		if strict:
			check(p["shader"] == ModelLibrary.FactorioAlphaShader and not p["fades"] and not p["glow"],
				"emission 2: BLEND, black emission picture, no factor, see-through picture: blended, no glow_fades (%s, %s)" % [p["file"], p["fades"]])
		else:
			check(p["fades"], "emission 2%s: a fading plume, as before" % tag)
		# 3. A real plume: BLEND, factor 1, a lit picture.
		p = _params(_mat_material({"alphaMode": "BLEND", "emissiveFactor": [1, 1, 1]}, some_alpha, lit))
		check(p["shader"] == ModelLibrary.FactorioAlphaShader and p["glow"] and p["fades"] and p["tex"],
			"emission 3%s: a real plume (factor 1, a lit picture) still glows and fades at rest (%s, %s, %s)" % [tag, p["file"], p["glow"], p["fades"]])
		# 4. A picture with factor 0: no glow; a factor of 0.5 and strength 2: the glow is picture x 0.5 x 2.
		p = _params(_mat_material({"emissiveFactor": [0, 0, 0]}, opaque, lit))
		if strict:
			check(not p["glow"], "emission 4: an emission picture with factor 0 doesn't glow")
		var strong := {"emissiveFactor": [0.5, 0.5, 0.5], "extensions": {"KHR_materials_emissive_strength": {"emissiveStrength": 2.0}}}
		p = _params(_mat_material(strong, opaque, lit))
		var colour: Color = p["emission"]
		check(p["glow"] and p["tex"] and absf(colour.srgb_to_linear().r - 0.5) < 0.01 and absf(float(p["energy"]) - 2.0) < 0.001,
			"emission 4%s: factor 0.5, strength 2, with its picture: the shader's emission %.3f (linear) x energy %.2f x the picture" % [
				tag, colour.srgb_to_linear().r, p["energy"]])
		# A black picture with a factor of 1 (belt and braces): no glow.
		p = _params(_mat_material({"emissiveFactor": [1, 1, 1]}, opaque, black))
		if strict:
			check(not p["glow"], "emission: a black emission picture with factor 1 doesn't glow")
		else:
			check(p["glow"], "emission%s: a black emission picture with factor 1 glows as before" % tag)
	ModelTextures.emission_strict = was
	# The shader draws the glow as the emission colour x strength x the picture (not the picture alone).
	var code := FileAccess.get_file_as_string("res://shaders/factorio_material.gdshaderinc")
	check(code.contains("vec3 m_emission = emission * emission_energy;") and code.contains("m_emission *= texture(emission_tex, UV).rgb;"),
		"emission: the shader multiplies the picture by the colour (the factor) and the strength")


## A modeller's glowing material without an emission picture (Vasillo's drill's Light: a factor, no picture)
## goes dark at rest by its glow alone: its base colour is the same idle and working. Zenith's own (a
## built-in pack's) still dims its base colour to 30% at rest, as fire boxes and lamps do; so does a
## modeller's with --idle-dims-glow-paint=on.
func _idle_glow() -> void:
	var code := FileAccess.get_file_as_string("res://shaders/factorio_material.gdshaderinc")
	check(code.contains("if (m_glow && !(use_emission_tex && !merged) && !m_keep_albedo) {") and code.contains("m_keep_albedo = row_flag(e.w, 128.0);"),
		"idle: the shader's dim of the base colour skips glow_keeps_albedo (uniform and row flag 128)")
	var was: bool = ModelLibrary.glow_keeps_albedo
	for c in [[true, true, true, "a modeller's"], [false, true, false, "Zenith's own"], [true, false, false, "a modeller's with --idle-dims-glow-paint=on"]]:
		ModelLibrary.glow_keeps_albedo = c[1]
		var base := _mat_material({"emissiveFactor": [1, 1, 1], "pbrMetallicRoughness": {"baseColorFactor": [0.2, 0.3, 0.4, 1]}}, null, null, c[0])
		var m := ModelLibrary._factorio(base, false, false, false) as ShaderMaterial
		var idle := _shader_look(m, 0.0)
		var working := _shader_look(m, 1.0)
		var keeps: bool = c[2]
		var flagged := (int(ModelLibrary.MaterialRows.row_vectors(m)[1].w) & ModelLibrary.MaterialRows.FLAG_KEEP_ALBEDO) != 0
		print("[idle] %s Light: albedo idle %s working %s, emission idle %s working %s" % [c[3], idle[0], working[0], idle[1], working[1]])
		check((idle[1] as Color).r == 0.0 and (working[1] as Color).r > 0.9, "idle (%s): the glow is out at rest and lit at work" % c[3])
		if keeps:
			check(idle[0] == working[0] and flagged, "idle (%s): the base colour is the same idle and working (row flag %s)" % [c[3], flagged])
		else:
			check((idle[0] as Color).r < (working[0] as Color).r * 0.5 and not flagged, "idle (%s): the base colour dims at rest" % c[3])
	ModelLibrary.glow_keeps_albedo = was


## A modeller's Alpha Blend material whose picture is opaque on CLIP_SHARE (95%) or more of its pixels is
## drawn cut out at 0.5 (Vasillo's drill: 0.1-0.3% see-through); glass (40% opaque, or 0.6 alpha everywhere)
## stays blended; so does a built-in pack's; --blend-clip=off keeps the old blend.
func _blend_clip() -> void:
	var nearly := _picture(Color(0.5, 0.5, 0.5), 0.5, 98)
	var glass := _picture(Color(0.5, 0.5, 0.5), 0.5, 40)
	var even := _picture(Color(0.5, 0.5, 0.5), 0.596, 0)
	var was: bool = ModelTextures.blend_clip
	for on in [true, false]:
		ModelTextures.blend_clip = on
		var base := _mat_material({"alphaMode": "BLEND"}, nearly, null)
		var share := ModelTextures.opaque_share(base.albedo_texture)
		var p := _params(base)
		if on:
			check(absf(share - 0.98) < 0.001, "blend clip: the picture's opaque share counted (%.3f)" % share)
			check(p["shader"] == ModelLibrary.FactorioClipShader and absf(float(p["clip"]) - 0.5) < 0.001,
				"blend clip: a 98%% opaque BLEND picture is cut out at 0.5 (%s, %s)" % [p["file"], p["clip"]])
		else:
			check(p["shader"] == ModelLibrary.FactorioAlphaShader, "--blend-clip=off: the 98%% opaque one stays blended (%s)" % p["file"])
		p = _params(_mat_material({"alphaMode": "BLEND"}, glass, null))
		check(p["shader"] == ModelLibrary.FactorioAlphaShader, "blend clip (%s): 40%% opaque glass stays blended (%s)" % [on, p["file"]])
		p = _params(_mat_material({"alphaMode": "BLEND"}, even, null))
		check(p["shader"] == ModelLibrary.FactorioAlphaShader, "blend clip (%s): alpha 0.596 everywhere stays blended (%s)" % [on, p["file"]])
		p = _params(_mat_material({"alphaMode": "BLEND"}, nearly, null, false))
		check(p["shader"] == ModelLibrary.FactorioAlphaShader, "blend clip (%s): a built-in pack's 98%% one stays blended (%s)" % [on, p["file"]])
	ModelTextures.blend_clip = was
	# The belt surface stays the special case: cut out at any share (94% here), other materials not.
	var notched := _picture(Color(0.3, 0.3, 0.3), 0.0, 94)
	var made := func(n: String) -> StandardMaterial3D:
		var b := StandardMaterial3D.new()
		b.resource_name = n
		b.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		b.albedo_texture = _texture_of(notched)
		return b
	check(ModelTextures.clip_belt(made.call("Belt_Surface")) and not ModelTextures.clip_blend(made.call("Belt_Base")),
		"blend clip: a belt surface 94%% opaque is cut out (clip_belt), another material that opaque is not (clip_blend)")


## A 10 x 10 picture of `colour`, its first `opaque` pixels alpha 1 and the rest `alpha` (all of them when
## `opaque` is 0 and alpha is 1).
func _picture(colour: Color, alpha: float, opaque: int) -> Image:
	var img := Image.create(10, 10, false, Image.FORMAT_RGBA8)
	for i in 100:
		var a := 1.0 if i < opaque or (opaque == 0 and alpha >= 1.0) else alpha
		img.set_pixel(i % 10, i / 10, Color(colour.r, colour.g, colour.b, a))
	return img


## `img` made a texture as prepare() makes one (its counts in meta).
func _texture_of(img: Image) -> Texture2D:
	var tex := ImageTexture.create_from_image(img)
	var counts := ModelTextures._pixel_counts(img)
	tex.set_meta(ModelTextures.OPAQUE_META, counts[0] >= 1.0)
	tex.set_meta(ModelTextures.OPAQUE_SHARE_META, counts[0])
	tex.set_meta(ModelTextures.BLACK_META, counts[1])
	return tex


## The material of a one-quad .glb written with `material` (glTF material JSON), `base_pic` as its base
## colour picture and `emission_pic` as its emissiveTexture (either null: none), read by Godot and
## prepare()d as a modeller's (`modeller`) or a built-in pack's.
var _mat_n := 0
func _mat_material(material: Dictionary, base_pic: Image, emission_pic: Image, modeller := true) -> BaseMaterial3D:
	_mat_n += 1
	var path := ProjectSettings.globalize_path("user://model_textures_test_mat_%d.glb" % _mat_n)
	var bin: Array = [PackedByteArray()]
	var views: Array = []
	var accessors: Array = []
	var floats := func(values: Array) -> PackedByteArray: return PackedFloat32Array(values).to_byte_array()
	var attrs := {
		"POSITION": _glb_view(bin, views, accessors, floats.call([0, 0, 0, 1, 0, 0, 0, 0, 1, 1, 0, 1]), "VEC3", 5126, 4, [0, 0, 0], [1, 0, 1]),
		"NORMAL": _glb_view(bin, views, accessors, floats.call([0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0]), "VEC3", 5126, 4),
		"TEXCOORD_0": _glb_view(bin, views, accessors, floats.call([0, 0, 1, 0, 0, 1, 1, 1]), "VEC2", 5126, 4)}
	var indices := _glb_view(bin, views, accessors, PackedInt32Array([0, 2, 1, 1, 2, 3]).to_byte_array(), "SCALAR", 5125, 6)
	var mat := material.duplicate(true)
	var images: Array = []
	var textures: Array = []
	for pic: Image in [base_pic, emission_pic]:
		if pic == null:
			continue
		images.append({"bufferView": _glb_view(bin, views, [], pic.save_png_to_buffer(), "", 0, 0), "mimeType": "image/png"})
		textures.append({"source": images.size() - 1})
		if pic == base_pic:
			var pbr: Dictionary = mat.get("pbrMetallicRoughness", {})
			pbr["baseColorTexture"] = {"index": textures.size() - 1}
			mat["pbrMetallicRoughness"] = pbr
		else:
			mat["emissiveTexture"] = {"index": textures.size() - 1}
	mat["name"] = "Fixture_%d" % _mat_n
	var doc := {"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}],
		"nodes": [{"name": "body", "mesh": 0}], "meshes": [{"primitives": [{"attributes": attrs, "indices": indices, "material": 0}]}],
		"materials": [mat], "buffers": [{"byteLength": (bin[0] as PackedByteArray).size()}], "bufferViews": views, "accessors": accessors}
	if not images.is_empty():
		doc["images"] = images
		doc["textures"] = textures
	if (mat as Dictionary).has("extensions"):
		doc["extensionsUsed"] = (mat["extensions"] as Dictionary).keys()
	var text := JSON.stringify(doc).to_utf8_buffer()
	while text.size() % 4 != 0:
		text.append(0x20)
	var data: PackedByteArray = bin[0]
	var out := FileAccess.open(path, FileAccess.WRITE)
	out.store_32(0x46546C67)
	out.store_32(2)
	out.store_32(12 + 8 + text.size() + 8 + data.size())
	out.store_32(text.size())
	out.store_32(0x4E4F534A)
	out.store_buffer(text)
	out.store_32(data.size())
	out.store_32(0x004E4942)
	out.store_buffer(data)
	out.close()
	var state := GLTFState.new()
	check(GLTFDocument.new().append_from_file(path, state) == OK, "read the fixture %s" % path.get_file())
	ModelTextures.prepare(path, state, modeller)
	return state.get_materials()[0] as BaseMaterial3D


## What _factorio makes of `base`: its shader (and file name), whether it glows at work and fades at rest,
## its emission colour, strength and picture, its cutoff.
func _params(base: BaseMaterial3D) -> Dictionary:
	var m := ModelLibrary._factorio(base, false, false, false) as ShaderMaterial
	return {"shader": m.shader, "file": m.shader.resource_path.get_file(), "glow": m.get_shader_parameter("activity_glow") == true,
		"fades": m.get_shader_parameter("glow_fades") == true, "emission": m.get_shader_parameter("emission"),
		"energy": m.get_shader_parameter("emission_energy"), "tex": m.get_shader_parameter("use_emission_tex") == true,
		"clip": m.get_shader_parameter("alpha_clip")}


## [albedo, emission] an untextured material's fragment comes to at `activity`, by the shader's rule
## (factorio_material.gdshaderinc: EMISSION = emission x energy x act^2; the albedo dimmed to 30% at rest
## when it glows, has no emission picture and isn't glow_keeps_albedo). Linear colours.
func _shader_look(m: ShaderMaterial, activity: float) -> Array:
	var albedo: Color = m.get_shader_parameter("albedo")
	albedo = albedo.srgb_to_linear()
	var emission: Variant = m.get_shader_parameter("emission")
	var e: Color = (emission as Color).srgb_to_linear() if emission is Color else Color.BLACK
	var energy: Variant = m.get_shader_parameter("emission_energy")
	var glows: bool = m.get_shader_parameter("activity_glow") == true
	var act := activity if glows else 1.0
	var glow := e * (float(energy) if energy != null else 0.0) * act * act
	if glows and m.get_shader_parameter("use_emission_tex") != true and m.get_shader_parameter("glow_keeps_albedo") != true:
		albedo = albedo * lerpf(0.3, 1.0, act)
	return [Color(albedo.r, albedo.g, albedo.b), Color(glow.r, glow.g, glow.b)]


## Every model in a modeller's folder read with --belt-surface-blend=on and without: only belt surfaces
## change how they're drawn (each material's shader as _factorio picks it).
func _clip_dir(dir: String) -> void:
	var files := DirAccess.get_files_at(dir)
	files.sort()
	var was: bool = ModelTextures.belt_clip
	var clipped := 0
	var others := 0
	for file in files:
		if not file.ends_with(".glb"):
			continue
		var shaders: Array = []
		var names: Array = []
		for clip in [false, true]:
			ModelTextures.belt_clip = clip
			var state := GLTFState.new()
			if GLTFDocument.new().append_from_file(dir.path_join(file), state) != OK:
				check(false, "clip dir: %s reads" % file)
				break
			ModelTextures.prepare(dir.path_join(file), state)
			var got := {}
			for m in state.get_materials():
				var base := m as BaseMaterial3D
				var out := ModelLibrary._factorio(base, false, false, false) as ShaderMaterial
				got[m.resource_name] = out.shader.resource_path.get_file() if out != null else ""
				if not clip:
					names.append(m.resource_name)
			shaders.append(got)
		if shaders.size() < 2:
			continue
		for n in names:
			if shaders[0][n] == shaders[1][n]:
				others += 1
				continue
			var belt := (n as String).to_lower().contains("belt_surface")
			print("[clip dir] %s: %s %s -> %s" % [file, n, shaders[0][n], shaders[1][n]])
			check(belt and shaders[1][n] == "factorio_material_clip.gdshader", "clip dir: only belt surfaces change, to cut out (%s %s)" % [file, n])
			if belt:
				clipped += 1
	ModelTextures.belt_clip = was
	print("[clip dir] %d belt surface materials now cut out, %d other materials unchanged" % [clipped, others])


## Checks a return built from `src` (a belt surface's arrays): under the top run between `low` and `high`
## (tiles), facing up, its triangles facing as their normals, its texture running against the top's at the
## same speed, shaded as BeltReturn.SHADE.
func _check_return(ret: Array, src: Array, low: float, high: float, what: String) -> void:
	var got: Array = BeltReturn.describe(ret, 0)
	check(absf(float(got[0]) - low) < 0.002 and absf(float(got[1]) - high) < 0.002,
		"return (%s): at %.3f-%.3f, under the top run (%.3f-%.3f)" % [what, got[0], got[1], low, high])
	var top_fit := BeltReturn.uv_fit(src, 0)
	check(top_fit.length() > 0.1 and (got[2] as Vector2).distance_to(-top_fit) < 0.01,
		"return (%s): its texture runs the other way at the same speed (%s against the top's %s)" % [what, got[2], top_fit])
	var verts: PackedVector3Array = ret[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = ret[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = ret[Mesh.ARRAY_INDEX]
	var up := true
	for nm in normals:
		up = up and nm.y > 0.5
	check(up, "return (%s): faces up, at the rollers" % what)
	# Faces as the top run does: Godot's front faces wind against their normals (ModelLods winding -1).
	var src_v: PackedVector3Array = src[Mesh.ARRAY_VERTEX]
	var src_n: PackedVector3Array = src[Mesh.ARRAY_NORMAL]
	var src_i: PackedInt32Array = src[Mesh.ARRAY_INDEX]
	var top_side := signf((src_v[src_i[1]] - src_v[src_i[0]]).cross(src_v[src_i[2]] - src_v[src_i[0]]).dot(src_n[src_i[0]]))
	var same := true
	for t in range(0, idx.size() - 2, 3):
		var side := signf((verts[idx[t + 1]] - verts[idx[t]]).cross(verts[idx[t + 2]] - verts[idx[t]]).dot(normals[idx[t]]))
		same = same and side == top_side
	check(same, "return (%s): its faces' front is the side its normals look to, as the top run's" % what)
	var colors: PackedColorArray = ret[Mesh.ARRAY_COLOR]
	var shaded := true
	for c in colors:
		shaded = shaded and absf(c.a - BeltReturn.SHADE) < 0.001
	check(shaded, "return (%s): shaded as under the belt (COLOR.a %.2f)" % [what, BeltReturn.SHADE])


## A belt surface as Vasillo lays his out: its top run at 0.25 (UV U from 0 to 1 going north) and, with
## `own_return`, its return at 0.006 facing down (U from 0 to 1 going south), Godot's winding.
func _belt_arrays(own_return: bool) -> Array:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var colors := PackedColorArray()
	var idx := PackedInt32Array()
	for run in (2 if own_return else 1):
		var y := 0.25 if run == 0 else 0.006
		for z in [0.5, -0.5]:
			for x in [-0.35, 0.35]:
				verts.append(Vector3(x, y, z))
				normals.append(Vector3(0.0, 1.0 if run == 0 else -1.0, 0.0))
				uvs.append(Vector2(0.5 - float(z) if run == 0 else float(z) + 0.5, float(x) + 0.5))
				uv2s.append(Vector2(0.0, 0.5))
				colors.append(Color(1, 1, 1, 1.0 if run == 0 else 0.0))
		var b := run * 4
		# Front faces wind against their normals: the top's cross product points down, the return's up.
		idx.append_array([b, b + 2, b + 1, b + 1, b + 2, b + 3] if run == 0 else [b, b + 1, b + 2, b + 1, b + 3, b + 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = idx
	return arrays


## A small belt model written as a .glb by hand (no exporter): a side rail (Belt_Base) and a textured
## Belt_Surface with its own return, both wearing a 4 x 4 grey picture, as a modeller's file has them.
func _belt_glb(path: String, see_through := false) -> bool:
	var rail := []
	rail.resize(Mesh.ARRAY_MAX)
	rail[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0.42, 0.0, 0.5), Vector3(0.42, 0.0, -0.5), Vector3(0.42, 0.24, 0.5), Vector3(0.42, 0.24, -0.5)])
	rail[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.RIGHT, Vector3.RIGHT, Vector3.RIGHT, Vector3.RIGHT])
	rail[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)])
	rail[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([Vector2(0, 0.5), Vector2(0, 0.5), Vector2(0, 0.5), Vector2(0, 0.5)])
	rail[Mesh.ARRAY_COLOR] = PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE])
	rail[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 1, 3, 2])
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.3, 0.3, 0.3))
	if see_through:
		img.set_pixel(0, 0, Color(0.3, 0.3, 0.3, 0.0))  # a notch, as Vasillo's plate corners
	var bin: Array = [PackedByteArray()]  # in an Array: changed by _glb_view
	var views: Array = []
	var accessors: Array = []
	var primitives: Array = []
	var surfaces := [rail, _belt_arrays(true)]
	var floats := func(values: Array) -> PackedByteArray: return PackedFloat32Array(values).to_byte_array()
	for i in 2:
		var a: Array = surfaces[i]
		var pos: Array = []
		var lo := Vector3(INF, INF, INF)
		var hi := -lo
		for v: Vector3 in a[Mesh.ARRAY_VERTEX]:
			pos.append_array([v.x, v.y, v.z])
			lo = lo.min(v)
			hi = hi.max(v)
		var nrm: Array = []
		for v: Vector3 in a[Mesh.ARRAY_NORMAL]:
			nrm.append_array([v.x, v.y, v.z])
		var uv: Array = []
		for v: Vector2 in a[Mesh.ARRAY_TEX_UV]:
			uv.append_array([v.x, v.y])
		var uv2: Array = []
		for v: Vector2 in a[Mesh.ARRAY_TEX_UV2]:
			uv2.append_array([v.x, v.y])
		var col: Array = []
		for c: Color in a[Mesh.ARRAY_COLOR]:
			col.append_array([c.r, c.g, c.b, c.a])
		# glTF's front faces wind counter-clockwise, Godot's clockwise: each triangle turned over.
		var tri := PackedInt32Array()
		var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
		for t in range(0, idx.size(), 3):
			tri.append_array([idx[t], idx[t + 2], idx[t + 1]])
		var n := (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		var attrs := {
			"POSITION": _glb_view(bin, views, accessors, floats.call(pos), "VEC3", 5126, n, [lo.x, lo.y, lo.z], [hi.x, hi.y, hi.z]),
			"NORMAL": _glb_view(bin, views, accessors, floats.call(nrm), "VEC3", 5126, n),
			"TEXCOORD_0": _glb_view(bin, views, accessors, floats.call(uv), "VEC2", 5126, n),
			"TEXCOORD_1": _glb_view(bin, views, accessors, floats.call(uv2), "VEC2", 5126, n),
			"COLOR_0": _glb_view(bin, views, accessors, floats.call(col), "VEC4", 5126, n)}
		primitives.append({"attributes": attrs, "material": i,
			"indices": _glb_view(bin, views, accessors, tri.to_byte_array(), "SCALAR", 5125, tri.size())})
	var image_view := views.size()
	_glb_view(bin, views, [], img.save_png_to_buffer(), "", 0, 0)
	var texture := {"baseColorTexture": {"index": 0}}
	var doc := {"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}],
		"nodes": [{"name": "body", "mesh": 0}], "meshes": [{"primitives": primitives}],
		"materials": [{"name": "Belt_Base", "pbrMetallicRoughness": texture}, {"name": "Belt_Surface", "pbrMetallicRoughness": texture}],
		"textures": [{"source": 0}], "images": [{"bufferView": image_view, "mimeType": "image/png"}],
		"buffers": [{"byteLength": (bin[0] as PackedByteArray).size()}], "bufferViews": views, "accessors": accessors}
	if see_through:
		for m: Dictionary in doc["materials"]:
			m["alphaMode"] = "BLEND"
	var text := JSON.stringify(doc).to_utf8_buffer()
	while text.size() % 4 != 0:
		text.append(0x20)
	var data: PackedByteArray = bin[0]
	var out := FileAccess.open(path, FileAccess.WRITE)
	if out == null:
		return false
	out.store_32(0x46546C67)
	out.store_32(2)
	out.store_32(12 + 8 + text.size() + 8 + data.size())
	out.store_32(text.size())
	out.store_32(0x4E4F534A)
	out.store_buffer(text)
	out.store_32(data.size())
	out.store_32(0x004E4942)
	out.store_buffer(data)
	out.close()
	return true


## `bytes` appended to the .glb's binary chunk (4-byte aligned) as a buffer view, and an accessor of it
## when `type` is given: returns the accessor's index (or the view's, without one).
func _glb_view(bin: Array, views: Array, accessors: Array, bytes: PackedByteArray, type: String, component: int, count: int,
		lo: Array = [], hi: Array = []) -> int:
	var data: PackedByteArray = bin[0]
	views.append({"buffer": 0, "byteOffset": data.size(), "byteLength": bytes.size()})
	data.append_array(bytes)
	while data.size() % 4 != 0:
		data.append(0)
	bin[0] = data
	if type == "":
		return views.size() - 1
	var accessor := {"bufferView": views.size() - 1, "componentType": component, "count": count, "type": type}
	if not lo.is_empty():
		accessor["min"] = lo
		accessor["max"] = hi
	accessors.append(accessor)
	return accessors.size() - 1


## The surface of `mesh` drawn with a textured belt surface material, or -1.
func _belt_surface_index(mesh: ArrayMesh) -> int:
	if mesh == null:
		return -1
	for i in mesh.get_surface_count():
		var m := mesh.surface_get_material(i) as ShaderMaterial
		if m != null and m.resource_name.to_lower().contains("belt_surface") and m.get_shader_parameter("use_albedo_tex") == true:
			return i
	return -1


## Every belt, splitter and underground in a modeller's folder (Vasillo's, from --models-dir), read as
## Zenith reads them: each one's return, where it lies, which way it runs and what it costs in triangles.
func _belt_dir(dir: String) -> void:
	var files := DirAccess.get_files_at(dir)
	files.sort()
	for file in files:
		if not file.ends_with(".glb") or not (file.contains("belt") or file.contains("splitter")):
			continue
		var model := file.get_basename()
		var name := "f3d-dir-" + model
		ModelLibrary._sources[name] = ModelLibrary.GLTF_SOURCE + dir.path_join(file)
		var mesh := ModelLibrary.mesh_for(name) as ArrayMesh
		ModelLibrary._sources.erase(name)
		if mesh == null:
			check(false, "belt dir: %s loads" % file)
			continue
		var drawn := _triangles(mesh)
		var kept := 0
		for i in mesh.get_surface_count():
			kept += (ModelLods.arrays_of(mesh, i)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		var parts := 0
		for p in ModelLibrary.parts_for(name):
			parts += _triangles(p.mesh)
		var surface := _belt_surface_index(mesh)
		var rets: Array = mesh.get_meta(BeltReturn.META, [])
		var shape := BeltReturn.shape_for(name)
		if surface < 0 or surface >= rets.size() or rets[surface] == null:
			print("[belt dir] %s: no return (%s), %d triangles + %d in moving parts" % [model,
				"an end piece" if shape < 0 else "no textured belt surface" if surface < 0 else "none built", drawn, parts])
			check(shape < 0, "belt dir: %s gets a return" % model)
			continue
		var own := (ModelLods.arrays_of(mesh, surface)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		var got: Array = BeltReturn.describe(rets[surface], shape)
		var scroll: Vector2 = (mesh.surface_get_material(surface) as ShaderMaterial).get_shader_parameter("belt_uv_scroll")
		var back := (got[2] as Vector2).dot(scroll) < 0.0 and absf((got[2] as Vector2).length() - BeltReturn.uv_fit(ModelLods.arrays_of(mesh, surface), shape).length()) < 0.05
		print("[belt dir] %s: surface %d + return %d triangles; model %d -> %d (+%.1f%%), %d in moving parts; return at y %.3f-%.3f, runs %s (scroll %s)" % [
			model, own, drawn - kept, kept, drawn, 100.0 * (drawn - kept) / maxf(kept + parts, 1.0), parts, got[0], got[1], got[2], scroll])
		check(back and float(got[1]) < 0.2, "belt dir: %s's return lies under the belt and runs the other way" % model)
## still body and the moving "baked" part, each vertex's bones in CUSTOM3.
func _baked() -> void:
	var path := ProjectSettings.globalize_path(BAKED)
	var bake := ModelSkin.bake(path)
	check(int(bake.get("frames", 0)) == 31 and absf(float(bake.get("duration", 0.0)) - 1.0) < 0.001,
		"baked: 31 frames over the action's second (%s)" % [bake.get("frames")])
	check(Array(bake.get("moving", PackedByteArray())) == [0, 1], "baked: the spinning bone moves, the base doesn't")
	var image: Image = bake.get("image")
	var row := func(f: int, r: int) -> Color: return image.get_pixel(1 * 3 + r, f)
	# Half way (frame 15), the top box has turned half a turn about Y: (0.5, 0.75, 0.5) -> (-0.5, 0.75, -0.5).
	var r0: Color = row.call(15, 0)
	var r1: Color = row.call(15, 1)
	var r2: Color = row.call(15, 2)
	var m := Transform3D(Basis(Vector3(r0.r, r1.r, r2.r), Vector3(r0.g, r1.g, r2.g), Vector3(r0.b, r1.b, r2.b)), Vector3(r0.a, r1.a, r2.a))
	check((m * Vector3(0.5, 0.75, 0.5)).distance_to(Vector3(-0.5, 0.75, -0.5)) < 0.01,
		"baked: the spinning bone's matrix half way turns a corner half a turn (%s)" % [m * Vector3(0.5, 0.75, 0.5)])
	var packed := ModelSkin.pack(PackedInt32Array([1, 0, 0, 0]), PackedFloat32Array([1.0, 0.0, 0.0, 0.0]), 1)
	check(int(floor(packed[0])) == 1 and absf(fposmod(packed[0], 1.0) / 0.999 - 1.0) < 0.01 and packed[1] == 0.0,
		"baked: CUSTOM3 packs bone 1 at weight 1 as %s" % [packed])
	var load := ModelLibrary.Load.new()
	load.path = path
	load.run()
	var body := 0
	for g in load.groups:
		body += (g[1][Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	var part_tris := 0
	var has_custom3 := false
	for p in load.parts:
		if p[0] == ModelLibrary.BAKED_NODE:
			for g in p[2]:
				part_tris += (g[1][Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
				has_custom3 = has_custom3 or g[1][Mesh.ARRAY_CUSTOM3] != null
	check(body == 12 and part_tris == 12 and has_custom3,
		"baked: the still box stays the body (%d triangles), the spinning one is the baked part (%d, CUSTOM3 %s)" % [body, part_tris, has_custom3])
	var parts: Array = []
	ModelLibrary._commit_load(load, parts)
	check(parts.size() == 1 and parts[0].kind == "baked" and not parts[0].bake.is_empty(),
		"baked: committed as one part of kind baked, with its bake")
	var none := ModelSkin.bake(ProjectSettings.globalize_path(SOURCE))
	check(none.is_empty(), "a model without a skin has nothing to bake")


static func _bone_xform(image: Image, j: int, f: int) -> Transform3D:
	var r0: Color = image.get_pixel(j * 3, f)
	var r1: Color = image.get_pixel(j * 3 + 1, f)
	var r2: Color = image.get_pixel(j * 3 + 2, f)
	return Transform3D(
		Basis(Vector3(r0.r, r1.r, r2.r), Vector3(r0.g, r1.g, r2.g), Vector3(r0.b, r1.b, r2.b)),
		Vector3(r0.a, r1.a, r2.a)
	)


func _fue5_pumpjack() -> void:
	var path := ProjectSettings.globalize_path("res://assets/models/packs/fue5/pumpjack.glb")
	var bake := ModelSkin.bake(path)
	check(bool(bake.get("animated", false)) and int(bake.get("frames", 0)) == 81
			and absf(float(bake.get("duration", 0.0)) - 4.0 / 3.0) < 0.01,
		"fue5 pumpjack: animated 81 frames over 4/3 s (animated=%s frames=%s dur=%s)" % [
			bake.get("animated"), bake.get("frames"), bake.get("duration")])
	check(Array(bake.get("moving", PackedByteArray())) == [0, 1, 1, 1, 1, 1, 1],
		"fue5 pumpjack: Base static and 6 bones moving (%s)" % [bake.get("moving")])
	var image: Image = bake.get("image")
	check(image != null, "fue5 pumpjack: baked texture image present")
	if image != null:
		var rest_ok := true
		var loop_ok := true
		for j in 7:
			var m0 := _bone_xform(image, j, 0)
			var m80 := _bone_xform(image, j, 80)
			if not m0.is_equal_approx(Transform3D.IDENTITY):
				rest_ok = false
			if not m80.is_equal_approx(Transform3D.IDENTITY):
				loop_ok = false
		check(rest_ok and loop_ok, "fue5 pumpjack: frame 0 and frame 80 are Identity (%s, %s)" % [rest_ok, loop_ok])
		var m_beam := _bone_xform(image, 1, 40)
		var m_crank := _bone_xform(image, 2, 40)
		var m_pit := _bone_xform(image, 3, 40)
		var m_rod := _bone_xform(image, 4, 40)
		var hh_tdc := m_beam * Vector3(0.0, 3.0, -1.3)
		var eq_pt := Vector3(0.0, 2.1519, 1.0469)
		var pin_pt := Vector3(0.0, 0.5396, 1.0456)
		var eq_b := m_beam * eq_pt
		var eq_p := m_pit * eq_pt
		var pin_c := m_crank * pin_pt
		var pin_p := m_pit * pin_pt
		var rod_pt := Vector3(0.0, 2.0, -1.3323)
		var rod_tdc := m_rod * rod_pt
		check(hh_tdc.y < 2.5 and eq_b.y > 2.5,
			"fue5 pumpjack TDC: horsehead lowers (%.3f) and tail rises (%.3f)" % [hh_tdc.y, eq_b.y])
		check(eq_b.distance_to(eq_p) < 0.005 and pin_c.distance_to(pin_p) < 0.005,
			"fue5 pumpjack TDC: pitman pins stay locked (eq=%.4f, crank=%.4f)" % [eq_b.distance_to(eq_p), pin_c.distance_to(pin_p)])
		check(absf(rod_tdc.x - rod_pt.x) < 0.001 and absf(rod_tdc.z - rod_pt.z) < 0.001 and rod_pt.y - rod_tdc.y > 0.6,
			"fue5 pumpjack TDC: polished rod drops purely vertically (%s)" % [rod_tdc])
	var load := ModelLibrary.Load.new()
	load.path = path
	load.pbr = true
	load.run()
	check(load.ok and load.groups.size() == 1 and load.parts.size() == 1,
		"fue5 pumpjack Load(pbr=true): 1 static group, 1 baked part (%d, %d)" % [load.groups.size(), load.parts.size()])
	var parts: Array = []
	var body := ModelLibrary._commit_load(load, parts)
	var body_mat := body.surface_get_material(0) as ShaderMaterial if body != null and body.get_surface_count() > 0 else null
	var body_arr: Array = body.surface_get_arrays(0) if body != null and body.get_surface_count() > 0 else []
	var part_ok := parts.size() == 1 and (parts[0] as ModelLibrary.AnimPart).kind == "baked"
	var pmesh: Mesh = (parts[0] as ModelLibrary.AnimPart).mesh if part_ok else null
	var part_mat := pmesh.surface_get_material(0) as ShaderMaterial if pmesh != null and pmesh.get_surface_count() > 0 else null
	var part_arr: Array = pmesh.surface_get_arrays(0) if pmesh != null and pmesh.get_surface_count() > 0 else []
	check(part_ok and body_mat != null and part_mat != null
			and body_mat.get_shader_parameter("modeller_tex") == true
			and part_mat.get_shader_parameter("modeller_tex") == true
			and not body_arr.is_empty() and body_arr[Mesh.ARRAY_COLOR] != null
			and not part_arr.is_empty() and part_arr[Mesh.ARRAY_COLOR] != null and part_arr[Mesh.ARRAY_CUSTOM3] != null,
		"fue5 pumpjack PBR: static body and baked part keep modeller_tex, COLOR_0, and CUSTOM3")


## A modeller's textured material whose every triangle moves (Vasillo's drill's Electric_Drill_Moving) keeps
## its own look as the still ones do: Zenith's weathering off (vas-round3-code). The baked box with its
## spinning half given a textured material of its own, so that material goes wholly into the baked part.
func _baked_own_look() -> void:
	var f := FileAccess.open(ProjectSettings.globalize_path(BAKED), FileAccess.READ)
	f.get_32()
	f.get_32()
	f.get_32()
	var json_len := f.get_32()
	f.get_32()
	var doc: Dictionary = JSON.parse_string(f.get_buffer(json_len).get_string_from_utf8())
	var bin_len := f.get_32()
	f.get_32()
	var bin := f.get_buffer(bin_len)
	f.close()
	var prim: Dictionary = doc["meshes"][0]["primitives"][0]
	var count := int(doc["accessors"][int(prim["attributes"]["POSITION"])]["count"])
	var views: Array = doc["bufferViews"]
	var accessors: Array = doc["accessors"]
	var put := func(bytes: PackedByteArray) -> int:
		while bin.size() % 4 != 0:
			bin.append(0)
		views.append({"buffer": 0, "byteOffset": bin.size(), "byteLength": bytes.size()})
		bin.append_array(bytes)
		return views.size() - 1
	var uvs := PackedFloat32Array()
	for v in count:
		uvs.append_array([0.5, 0.5])
	accessors.append({"bufferView": put.call(uvs.to_byte_array()), "componentType": 5126, "count": count, "type": "VEC2"})
	var uv := accessors.size() - 1
	var pic := _picture(Color(0.6, 0.5, 0.3), 1.0, 0)
	doc["images"] = [{"bufferView": put.call(pic.save_png_to_buffer()), "mimeType": "image/png"}]
	doc["textures"] = [{"source": 0}]
	# The indices' two halves: the still box's 36, then the spinning one's 36 (2 bytes each).
	var indices: Dictionary = accessors[int(prim["indices"])]
	var halves: Array = []
	for h in 2:
		var half := indices.duplicate()
		half["count"] = 36
		half["byteOffset"] = int(indices.get("byteOffset", 0)) + h * 72
		accessors.append(half)
		halves.append(accessors.size() - 1)
	var attrs: Dictionary = prim["attributes"].duplicate()
	attrs["TEXCOORD_0"] = uv
	doc["meshes"][0]["primitives"] = [{"attributes": attrs, "indices": halves[0], "material": 0},
		{"attributes": attrs, "indices": halves[1], "material": 1}]
	doc["materials"].append({"name": "Drill_Moving", "pbrMetallicRoughness": {"baseColorTexture": {"index": 0}}})
	while bin.size() % 4 != 0:
		bin.append(0)
	doc["buffers"][0]["byteLength"] = bin.size()
	var text := JSON.stringify(doc).to_utf8_buffer()
	while text.size() % 4 != 0:
		text.append(0x20)
	var path := ProjectSettings.globalize_path("user://model_textures_test_moving.glb")
	var out := FileAccess.open(path, FileAccess.WRITE)
	out.store_32(0x46546C67)
	out.store_32(2)
	out.store_32(12 + 8 + text.size() + 8 + bin.size())
	out.store_32(text.size())
	out.store_32(0x4E4F534A)
	out.store_buffer(text)
	out.store_32(bin.size())
	out.store_32(0x004E4942)
	out.store_buffer(bin)
	out.close()
	for modeller in [true, false]:
		var load := ModelLibrary.Load.new()
		load.path = path
		load.modeller = modeller
		load.run()
		var still := 0
		for g in load.groups:
			for key: Array in g[0]:
				var m: Material = key[0]
				if m != null and m.resource_name == "Drill_Moving":
					still += 1
		var moving: Material = null
		for p in load.parts:
			if p[0] == ModelLibrary.BAKED_NODE:
				for g in p[2]:
					for key: Array in g[0]:  # a group's keys, one per material merged into it (combined())
						var m: Material = key[0]
						if m != null and m.resource_name == "Drill_Moving":
							moving = m
		check(load.ok and moving != null and still == 0,
			"baked own look: the textured material is wholly in the baked part (modeller %s, %d still groups)" % [modeller, still])
		if moving == null:
			continue
		var look := ModelLibrary._factorio(moving, false, false, false, "", true) as ShaderMaterial
		var grime := float(look.get_shader_parameter("grime"))
		var value := float(look.get_shader_parameter("value"))
		if modeller:
			check(moving.has_meta(ModelLibrary.OWN_LOOK_META) and grime == 0.0 and value == 1.0,
				"baked own look: a modeller's textured material whose every triangle moves keeps its own look (grime %.2f, value %.2f)" % [grime, value])
		else:
			check(grime > 0.0 and value < 1.0,
				"baked own look: the same material in Zenith's own pack is weathered (grime %.2f, value %.2f)" % [grime, value])


## Baked animation played as the file says (vas-anim-code; Vasillo's drills): a .glb written here with a
## bone stretched unevenly and turned (Blender's counterweight arm) and a bone spinning 115 degrees a
## key at 60 keys a second for 35 s (his electric drill's fans).
func _bake_rates() -> void:
	var keys := 2101  # 35 s at 60 a second, both ends
	var step := deg_to_rad(115.0)
	var times := PackedFloat32Array()
	var rots := PackedFloat32Array()
	for k in keys:
		times.append(float(k) / 60.0)
		var q := Quaternion(Vector3.UP, step * k)
		rots.append_array([q.x, q.y, q.z, q.w])
	var arm_rot := Quaternion(Vector3.BACK, deg_to_rad(40.0))
	var arm_scale := Vector3(0.917, 1.189, 0.917)
	var ident := PackedFloat32Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
	var binds := PackedFloat32Array()
	binds.append_array(ident)
	binds.append_array(ident)
	var bin := PackedByteArray()
	var views: Array = []
	var accs: Array = []
	for data: Array in [[times, "SCALAR", keys], [rots, "VEC4", keys], [binds, "MAT4", 2]]:
		var bytes := (data[0] as PackedFloat32Array).to_byte_array()
		views.append({"buffer": 0, "byteOffset": bin.size(), "byteLength": bytes.size()})
		accs.append({"bufferView": views.size() - 1, "componentType": 5126, "count": data[2], "type": data[1]})
		bin.append_array(bytes)
	var doc := {
		"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}],
		"nodes": [{"name": "Root", "children": [1, 2]},
			{"name": "Arm", "rotation": [arm_rot.x, arm_rot.y, arm_rot.z, arm_rot.w], "scale": [arm_scale.x, arm_scale.y, arm_scale.z]},
			{"name": "Fan"}],
		"skins": [{"joints": [1, 2], "inverseBindMatrices": 2}],
		"animations": [{"samplers": [{"input": 0, "output": 1, "interpolation": "LINEAR"}],
			"channels": [{"sampler": 0, "target": {"node": 2, "path": "rotation"}}]}],
		"buffers": [{"byteLength": bin.size()}], "bufferViews": views, "accessors": accs}
	var path := ProjectSettings.globalize_path("user://bake_rates.glb")
	var js := JSON.stringify(doc).to_utf8_buffer()
	while js.size() % 4 != 0:
		js.append(0x20)
	var f := FileAccess.open(path, FileAccess.WRITE)
	for v in [0x46546C67, 2, 12 + 8 + js.size() + 8 + bin.size(), js.size(), 0x4E4F534A]:
		f.store_32(v)
	f.store_buffer(js)
	f.store_32(bin.size())
	f.store_32(0x004E4942)
	f.store_buffer(bin)
	f.close()

	var bake := ModelSkin.bake(path)
	var frames := int(bake.get("frames", 0))
	print("[bake rates] %d frames at %s a second over %.2f s, snap %s" % [frames, bake.get("fps"), float(bake.get("duration", 0.0)), bake.get("snap")])
	check(frames == keys and is_equal_approx(float(bake.get("fps", 0.0)), 60.0),
		"bake rates: a 35 s action keyed 60 a second baked at its key rate, %d frames (not 512 at 30 a second): %d" % [keys, frames])
	var at := func(b: Dictionary, j: int, fr: int) -> Transform3D:
		var image: Image = b["image"]
		var r0 := image.get_pixel(j * 3, fr)
		var r1 := image.get_pixel(j * 3 + 1, fr)
		var r2 := image.get_pixel(j * 3 + 2, fr)
		return Transform3D(Basis(Vector3(r0.r, r1.r, r2.r), Vector3(r0.g, r1.g, r2.g), Vector3(r0.b, r1.b, r2.b)), Vector3(r0.a, r1.a, r2.a))
	# The stretched arm: glTF's rotate x scale (the scale in the bone's own axes), not scale after turning.
	var want := Basis(arm_rot) * Basis.from_scale(arm_scale)
	var arm: Transform3D = at.call(bake, 0, 0)
	var arm_err := maxf((arm.basis.x - want.x).length(), maxf((arm.basis.y - want.y).length(), (arm.basis.z - want.z).length()))
	check(arm_err < 1e-4, "bake rates: a bone stretched (0.917, 1.189, 0.917) and turned 40 degrees is rotate x scale (off by %.5f)" % arm_err)
	# The fan on its keys: frame 1000 is key 1000.
	var fan: Transform3D = at.call(bake, 1, 1000)
	var key := Basis(Quaternion(Vector3.UP, step * 1000))
	check(frames == keys and (fan.basis.x - key.x).length() < 1e-3 and (fan.basis.z - key.z).length() < 1e-3,
		"bake rates: the fan's frame 1000 is its key 1000 (%s, want %s)" % [fan.basis, key])
	# As the shader draws it between two frames (ModelSkin.shown, the shader's anim_baked): a bone turning
	# 115 degrees a frame keeps its size; mixed straight it shrank to cos(57.5) = 54%.
	var shortest := INF
	for fr in [0, 1, 999, frames - 2]:
		for u in [0.25, 0.5, 0.75]:
			var m := ModelSkin.shown(at.call(bake, 1, fr), at.call(bake, 1, fr + 1), u, float(bake.get("snap", -2.0)))
			shortest = minf(shortest, minf(m.basis.x.length(), m.basis.z.length()))
	check(shortest >= 0.99, "bake rates: a bone spinning 115 degrees a frame keeps 99%% of its axes' length between frames: %.3f" % shortest)
	# A slow bone is still mixed smoothly: 10 degrees between frames, shown half way.
	var slow := ModelSkin.shown(Transform3D.IDENTITY, Transform3D(Basis(Vector3.UP, deg_to_rad(10.0)), Vector3.ZERO), 0.5, ModelSkin.SNAP)
	check(absf(slow.basis.x.angle_to(Vector3.RIGHT) - deg_to_rad(5.0)) < 0.01, "bake rates: a bone turning 10 degrees a frame is mixed, half way at 5 degrees")
	# --baked-anim=old: 30 a second, 512 frames, always mixed.
	ModelSkin.old_anim = true
	var old := ModelSkin.bake(path)
	ModelSkin.old_anim = false
	var mixed := ModelSkin.shown(at.call(old, 1, 0), at.call(old, 1, 1), 0.5, float(old.get("snap", 0.0)))
	check(int(old.get("frames", 0)) == 512 and float(old.get("snap", 0.0)) < -1.0 and mixed.basis.x.length() < 0.99,
		"bake rates: --baked-anim=old bakes 512 frames and always mixes (%s frames, snap %s, half way %.3f long)" % [old.get("frames"), old.get("snap"), mixed.basis.x.length()])
	# The shader's side (anim_baked, bake_turned): the model shaders still compile, with bake_snap.
	var inc := FileAccess.get_file_as_string("res://shaders/factorio_material.gdshaderinc")
	for name in ["factorio_material", "factorio_material_alpha", "factorio_material_clip"]:
		var shader := Shader.new()
		shader.code = FileAccess.get_file_as_string("res://shaders/%s.gdshader" % name).replace('#include "res://shaders/factorio_material.gdshaderinc"', inc)
		var names: Array = shader.get_shader_uniform_list().map(func(u: Dictionary) -> String: return str(u["name"]))
		check(names.has("bake_snap") and names.has("bake_tex"), "bake rates: %s compiles with bake_snap (%d uniforms)" % [name, names.size()])


## A textured belt surface that wraps under the belt (Vasillo's: one strip over the top and back
## underneath, its UVs running on round the loop) scrolls by its top: fitting the bottom too, which
## runs the other way, cancelled to nothing and the belt stood still.
func _belt_wrap() -> void:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	for side in [1.0, -1.0]:  # top (UV 0..0.5 going north), bottom (0.5..1 going south)
		for z in [0.5, -0.5]:
			for x in [-0.35, 0.35]:
				verts.append(Vector3(x, 0.25 if side > 0 else 0.0, z))
				var along: float = 0.5 - float(z)  # 0..1 going north
				uvs.append(Vector2(along * 0.5 if side > 0 else 1.0 - along * 0.5, x + 0.5))
				normals.append(Vector3(0, side, 0))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 2, 1, 3, 4, 6, 5, 5, 6, 7])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var m := ShaderMaterial.new()
	m.resource_name = "Belt_Surface"
	m.set_shader_parameter("use_albedo_tex", true)
	mesh.surface_set_material(0, m)
	mesh.set_meta(ModelLods.ARRAYS_META, [arrays])
	var scroll := ModelLibrary._belt_uv_scroll(mesh, 0)
	check(absf(scroll.x - 0.5) < 0.01 and absf(scroll.y) < 0.01,
		"a belt surface wrapping under the belt scrolls by its top: 0.5 a tile, got %s" % scroll)
	# A curve's fit, and an end piece's: straight along one axis, at the same speed as the line's straights.
	check(ModelLibrary._clean_scroll(Vector2(0.9993, 0.00298)) == Vector2(1.0, 0.0), "a curve's sideways noise is dropped: it would creep the rows off the belt")
	check(ModelLibrary._clean_scroll(Vector2(1.0231, 0.0)) == Vector2(1.0, 0.0), "an end piece scrolls at the line's speed")
	check(ModelLibrary._clean_scroll(Vector2(0.0, -0.5)) == Vector2(0.0, -0.5), "a texture along V keeps its V")
	check(ModelLibrary._clean_scroll(Vector2(0.5, 0.25)) == Vector2(0.5, 0.25), "a diagonal layout keeps both axes")
	check(ModelLibrary._clean_scroll(Vector2(0.04, 0.0)) == Vector2(0.04, 0.0), "a slow texture isn't snapped to a stop")
	# A colour picture wired to the normal input isn't a normal map (the same part glared by direction).
	var picture := ImageTexture.create_from_image(Image.create_empty(4, 4, false, Image.FORMAT_RGBA8))
	var other := ImageTexture.create_from_image(Image.create_empty(4, 4, false, Image.FORMAT_RGBA8))
	var wired := StandardMaterial3D.new()
	wired.albedo_texture = picture
	wired.normal_enabled = true
	wired.normal_texture = picture
	check((ModelLibrary._factorio(wired, false, false, false) as ShaderMaterial).get_shader_parameter("use_normal_tex") != true,
		"a normal texture that is the base colour's own picture is left out")
	var proper := StandardMaterial3D.new()
	proper.albedo_texture = picture
	proper.normal_enabled = true
	proper.normal_texture = other
	check((ModelLibrary._factorio(proper, false, false, false) as ShaderMaterial).get_shader_parameter("use_normal_tex") == true,
		"a real normal map is used")


## An inserter rigged as an arm is cut into its parts by bone, its joints and lengths read from the
## skin (the fixture's known ones), its platform turned to face north, and the arm's IK puts the
## grip between the pincers on the hand, the elbow joining both arms; closed pincers come together.
func _rig() -> void:
	var paths := [ProjectSettings.globalize_path(RIG)]
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--rig="):
			paths.append(arg.get_slice("=", 1))
	for path: String in paths:
		var fixture: bool = path == paths[0]
		var load := ModelLibrary.Load.new()
		load.path = path
		load.rig_wanted = true
		load.run()
		check(load.ok and (not load.rig.is_empty() or not fixture), "rig: %s is read as an arm rig" % path.get_file())
		if load.rig.is_empty():
			print("rig %s: no arm rig (drawn whole, with Wube's arm)" % path.get_file())
			continue
		var rig := ModelLibrary._commit_rig(load.rig, path.get_file().get_basename())
		var base_tris := 0
		var lowest := INF
		for g in load.groups:
			base_tris += (g[1][Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
			for v in (g[1][Mesh.ARRAY_VERTEX] as PackedVector3Array):
				lowest = minf(lowest, v.z)
		var part_tris: Array = []
		for groups: Array in load.rig["parts"]:
			var n := 0
			for g in groups:
				n += (g[1][Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
			part_tris.append(n)
		print("rig %s: base %d triangles, parts %s, shoulder %s elbow %s wrist %s grip %s, lengths %s, hinge %s, turned %.1f deg, pincers close %s rad" % [
			path.get_file(), base_tris, part_tris, rig["shoulder"], rig["elbow"], rig["wrist"], rig["grip"], rig["lengths"],
			rig["hinge"], rad_to_deg(float(rig["turn"])), rig["angles"]])
		check(base_tris > 0 and not part_tris.has(0), "rig: every part has triangles (base %d, parts %s)" % [base_tris, part_tris])
		if fixture:
			var near := func(a: Vector3, b: Vector3) -> bool: return a.distance_to(b) < 0.001
			check(base_tris == 12 and part_tris == [12, 12, 12, 24, 24], "rig: the fixture's boxes by bone (%d, %s)" % [base_tris, part_tris])
			check(near.call(rig["shoulder"], Vector3(0, 0.3, 0)) and near.call(rig["elbow"], Vector3(0, 1.0, 0))
				and near.call(rig["wrist"], Vector3(0, 1.8, 0)) and near.call(rig["grip"], Vector3(0, 1.95, 0)),
				"rig: joints from the inverse bind matrices, grip half way along the pincers")
			check(absf(float(rig["turn"]) + PI / 2.0) < 0.001 and absf(lowest + 0.6) < 0.001,
				"rig: the platform's long leg turned from west to north (turn %s, northmost %s)" % [rig["turn"], lowest])
			check(near.call(rig["hinge"], Vector3(-1, 0, 0)), "rig: the hinge runs from pincer 1 to pincer 2, turned (%s)" % [rig["hinge"]])
			check(absf(float(rig["lengths"][0]) - 0.7) < 0.001 and absf(float(rig["lengths"][1]) - 0.95) < 0.001, "rig: arm lengths %s" % [rig["lengths"]])
			var a := float(rig["angles"][ModelRig.Part.PINCER_A])
			var b := float(rig["angles"][ModelRig.Part.PINCER_B])
			check(absf(a - 0.46) < 0.015 and absf(b - 0.46) < 0.015, "rig: the fingers meet at 26.6 degrees (%s, %s)" % [a, b])
		var arms: Node3D = InserterArms.new()
		for case: Array in [[0.0, 1.2], [PI * 0.5, 1.0], [2.5, 0.8], [-1.0, 2.2]]:
			var tips := []
			var gaps := []
			for closed in [0.0, 1.0]:
				var arm = InserterArms.Arm.new()
				arm.base = Vector2(10, 20)
				arm.angle = case[0]
				arm.reach = case[1]
				arm.placed = Transform3D(Basis.IDENTITY, Vector3(10, 0, 20))
				arm.close = closed
				arm.proto_name = "test-inserter"
				var lists := [[], [], [], [], []]
				var held: Vector3 = arms._draw_rig_arm(arm, rig, lists)
				var target := Vector3(10, InserterArms.GRIP_HEIGHT, 20) + Basis(Vector3.UP, -float(case[0])) * Vector3.RIGHT * float(case[1])
				var upper: Transform3D = lists[ModelRig.Part.UPPER][0]
				var lower: Transform3D = lists[ModelRig.Part.LOWER][0]
				var grip: Vector3 = upper * ((rig["grip"] as Vector3) - (rig["elbow"] as Vector3))
				check(grip.distance_to(target) < 0.01, "rig IK: angle %.2f reach %.1f puts the grip on the hand (%s, wanted %s)" % [case[0], case[1], grip, target])
				check((lower * ((rig["elbow"] as Vector3) - (rig["shoulder"] as Vector3))).distance_to(upper.origin) < 0.01, "rig IK: the arms meet at the elbow")
				check(held.distance_to(target + Vector3(0, InserterArms.ITEM_DROP, 0)) < 0.001, "rig IK: the held item hangs at the grip")
				# K8: a held item's middle at the grip (--inserter-grip), its base there before.
				var mid: Vector3 = arms.held_at(arm, held) + Vector3(0, arms._cards.pile_step(arm.item_id) * 0.5, 0)
				check(arms._gripped and mid.distance_to(target) < 0.001, "rig: a held item's middle is drawn at the grip (%s, the grip %s)" % [mid, target])
				InserterArms.held_grip = false
				var old_lists := [[], [], [], [], []]
				var old_held: Vector3 = arms._draw_rig_arm(arm, rig, old_lists)
				check(arms.held_at(arm, old_held).distance_to(target) < 0.001, "rig, --inserter-grip=off: the held item's base at the grip, as before")
				InserterArms.held_grip = true
				gaps.append(_pincers_off_middle(load.rig, lists, case[0], target))
				var tip := []
				for p in [ModelRig.Part.PINCER_A, ModelRig.Part.PINCER_B]:
					var verts: PackedVector3Array = load.rig["parts"][p][0][1][Mesh.ARRAY_VERTEX]
					var far := Vector3.ZERO
					for v in verts:
						if v.length() > far.length():
							far = v
					tip.append((old_lists[p][0] as Transform3D) * far)
				tips.append((tip[0] as Vector3).distance_to(tip[1]))
			check(tips[1] < tips[0] * 0.6, "rig, --inserter-grip=off: closed pincers' tips come together (%.3f open, %.3f closed)" % [tips[0], tips[1]])
			# K8: holding, the pincers close onto the item's sides (HELD_HALF either side of the plane between them),
			# not through it: all the way closed they met there and hid the item.
			check(gaps[1] < gaps[0] - 0.01 and gaps[1] >= ModelRig.HELD_HALF - 0.015,
				"rig: holding, the pincers close onto the held item's sides, %.3f off the middle (%.3f open, at least %.3f)" % [gaps[1], gaps[0], ModelRig.HELD_HALF - 0.015])
		arms._cards.free()
		arms.free()


## How near (tiles) the outer halves of a posed rig's pincers (`lists`, _draw_rig_arm's) come to the plane
## between them through the grip, the arm at `angle`: where a held item's sides are.
func _pincers_off_middle(load_rig: Dictionary, lists: Array, angle: float, grip: Vector3) -> float:
	var across := Basis(Vector3.UP, -angle) * Vector3.BACK
	var near := INF
	for p in [ModelRig.Part.PINCER_A, ModelRig.Part.PINCER_B]:
		var verts: PackedVector3Array = load_rig["parts"][p][0][1][Mesh.ARRAY_VERTEX]
		var far := 0.0
		for v in verts:
			far = maxf(far, v.length())
		for v in verts:
			if v.length() >= far * 0.5:
				near = minf(near, absf(((lists[p][0] as Transform3D) * v - grip).dot(across)))
	return near


## K8: Wube's arm pieces (Zenith's own inserters): the claw's middle reaches the hand's place, where the held
## item's middle is drawn, between its fingers (inside the closed claw's box), the claw above the ground; with
## --inserter-grip=off the wrist there and the item ITEM_DROP below it, as before.
func _wube_claw() -> void:
	var arms: Node3D = InserterArms.new()
	for proto: String in ["inserter", "long-handed-inserter", "bulk-inserter", "stack-inserter"]:
		var family: String = InserterArms.ARM_FAMILIES.get(proto, "basic")
		for piece in ["upper", "hand-open", "hand-closed"]:
			ModelLibrary.mesh_for("inserter-arm-%s-%s" % [family, piece])
		if arms._pieces_for(proto) == null:
			check(false, "Wube's arm pieces for %s are read" % proto)
			continue
		var closed_mesh: Mesh = ModelLibrary.mesh_for("inserter-arm-%s-hand-closed" % family)
		var hand_length: float = (InserterArms.ARM_LENGTHS[family] as Array)[1]
		var reaches: Array = [2.0, 2.2] if family == "long" else [1.0, 1.2]
		for case: Array in [[-PI * 0.5, reaches[0]], [PI * 0.5, reaches[1]], [0.3, reaches[0]]]:
			var arm = InserterArms.Arm.new()
			arm.base = Vector2(10, 20)
			arm.angle = case[0]
			arm.reach = case[1]
			arm.item_id = 1
			arm.proto_name = proto
			var lists := [[], [], []]
			var wrist: Vector3 = arms._draw_model_arm(arm, lists)
			var target := Vector3(10, InserterArms.GRIP_HEIGHT, 20) + Basis(Vector3.UP, -float(case[0])) * Vector3.RIGHT * float(case[1])
			var mid: Vector3 = arms.held_at(arm, wrist) + Vector3(0, arms._cards.pile_step(1) * 0.5, 0)
			var xf: Transform3D = lists[InserterArms.ArmPiece.CLOSED][0]
			var box := AABB()
			var first := true
			for s in closed_mesh.get_surface_count():
				for v in (closed_mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array):
					if v.z > -hand_length:
						continue  # (the hand up to the wrist; the claw is past it)
					var w := xf * v
					if first:
						box = AABB(w, Vector3.ZERO)
						first = false
					else:
						box = box.expand(w)
			var what := "%s at %.2f, reach %.1f" % [proto, case[0], case[1]]
			check(float(arms._claw.get(proto, 1.0)) > 1.0 and mid.distance_to(target) < 0.001 and box.grow(0.01).has_point(mid) and box.position.y > 0.0,
				"Wube's claw (%s): the held item's middle at the hand's place %s, inside the closed claw %s, the claw above the ground" % [what, mid, box])
			InserterArms.held_grip = false
			var old_wrist: Vector3 = arms._draw_model_arm(arm, [[], [], []])
			InserterArms.held_grip = true
			check(arms.held_at(arm, old_wrist).distance_to(target) < 0.001 and not arms._gripped,
				"Wube's claw (%s), --inserter-grip=off: the wrist at the hand, the item ITEM_DROP below it, as before" % what)
	for c in arms.get_children():
		c.free()
	arms._cards.free()
	arms.free()


## A textured model's levels (model_lods.gd textured_lods): simplified with its UVs, so every face of
## a level lies on one UV island of the model (welding positions alone had joined islands across
## seams and smeared the texture), with its materials, above TEXTURED_FLOORS, switched only once small
## on screen; and no flat belt stand-in for a textured model (belt_lods.gd).
func _textured_levels() -> void:
	ModelLibrary._sources["f3d-test-textured"] = ModelLibrary.GLTF_SOURCE + LEVELS_MODEL
	var mesh := ModelLibrary.mesh_for("f3d-test-textured") as ArrayMesh
	ModelLibrary._sources.erase("f3d-test-textured")
	check(mesh != null and ModelLods.textured(mesh), "the drill is a textured model")
	if mesh == null:
		return
	check(BeltLods._job_for(mesh, "s") == null, "a textured model gets no flat belt stand-in")
	var job: Variant = ModelLods._job_for(mesh)
	check(job != null and job.textured, "its LOD job simplifies with UVs")
	if job == null:
		return
	job.run()
	job.run_levels()
	ModelLods._make_levels(mesh, job.levels)
	var levels := ModelLods.levels(mesh)
	var full := _triangles(mesh)
	var dense: bool = bool(job.density_lod) and full >= ModelLods.TEXTURED_DENSE_TRIS
	var floors: Array = ModelLods.TEXTURED_DENSE_FLOORS if dense else ModelLods.TEXTURED_FLOORS
	var pixels: Array = ModelLods.TEXTURED_DENSE_PIXELS if dense else ModelLods.TEXTURED_PIXELS
	check(not levels.is_empty() and levels.size() <= floors.size(), "textured: 1 to %d levels (%d)" % [floors.size(), levels.size()])
	var prev_tris := full
	var longest := mesh.get_aabb().get_longest_axis_size()
	for k in levels.size():
		var lod: ArrayMesh = levels[k][0]
		var tris := _triangles(lod)
		var share := float(tris) / full
		check(share >= float(floors[k]), "level %d keeps %.0f%% of the triangles (at least %.0f%%)" % [k + 1, share * 100.0, float(floors[k]) * 100.0])
		var base_px := float(pixels[k])
		var max_px := clampf(maxf(base_px, sqrt(float(prev_tris) * ModelLods.TEXTURED_PX_PER_TRI)), base_px, ModelLods.TEXTURED_MAX_PIXELS) if dense else base_px
		check(ModelLods.switch_error(levels[k]) >= longest / max_px * ModelLods.lod_threshold - 1e-4,
			"level %d is drawn only once the model is %d px or less" % [k + 1, int(round(max_px))])
		for i in lod.get_surface_count():
			check(lod.surface_get_material(i) == mesh.surface_get_material(i), "level %d surface %d keeps its material" % [k + 1, i])
			var spread := _across_islands(ModelLods.arrays_of(mesh, i), lod.surface_get_arrays(i))
			check(spread >= 0.0 and spread < 0.001, "level %d surface %d: UVs kept, every face on one UV island (%.2f%% across)" % [k + 1, i, spread * 100.0])
		prev_tris = tris
	# Legacy mode (--textured-lod=legacy): fixed [64, 32] px thresholds and [0.3, 0.15] floors.
	var legacy_job: Variant = ModelLods._job_for(mesh)
	if legacy_job != null:
		legacy_job.density_lod = false
		legacy_job.run()
		legacy_job.run_levels()
		var l_levels: Array = legacy_job.levels
		check(not l_levels.is_empty() and l_levels.size() <= ModelLods.TEXTURED_FLOORS.size(),
			"legacy textured: 1 to %d levels (%d)" % [ModelLods.TEXTURED_FLOORS.size(), l_levels.size()])
		for k in l_levels.size():
			var l_err := ModelLods.switch_error([null, l_levels[k][0], l_levels[k][2]])
			check(l_err >= longest / float(ModelLods.TEXTURED_PIXELS[k]) * ModelLods.lod_threshold - 1e-4,
				"legacy level %d is drawn only once the model is %d px or less" % [k + 1, int(ModelLods.TEXTURED_PIXELS[k])])
	# Hard-edged Wube3DP models baked with PBR textures also get view LODs with intact UV islands.
	for wube_path: String in [
		"res://assets/models/packs/wube3dp/assembling-machine-1.glb",
		"res://assets/models/packs/wube3dp/electric-mining-drill.glb",
		"res://assets/models/packs/wube3dp/steel-furnace.glb",
	]:
		ModelLibrary._sources["f3d-test-wube-lod"] = ModelLibrary.GLTF_SOURCE + wube_path
		var w_mesh := ModelLibrary.mesh_for("f3d-test-wube-lod") as ArrayMesh
		ModelLibrary._sources.erase("f3d-test-wube-lod")
		var w_name: String = wube_path.get_file()
		check(w_mesh != null and ModelLods.textured(w_mesh), "%s loads as a textured PBR model" % w_name)
		if w_mesh == null:
			continue
		var w_job: Variant = ModelLods._job_for(w_mesh)
		check(w_job != null and w_job.textured, "%s gets a textured LOD job" % w_name)
		if w_job == null:
			continue
		w_job.run()
		w_job.run_levels()
		ModelLods._make_levels(w_mesh, w_job.levels)
		var w_levels := ModelLods.levels(w_mesh)
		check(not w_levels.is_empty(), "%s produces at least one textured view LOD (%d)" % [w_name, w_levels.size()])
		for k in w_levels.size():
			var lod: ArrayMesh = w_levels[k][0]
			for i in lod.get_surface_count():
				var spread := _across_islands(ModelLods.arrays_of(w_mesh, i), lod.surface_get_arrays(i))
				check(spread >= 0.0 and spread < 0.001, "%s level %d surface %d keeps UV islands (%.2f%% across)" % [w_name, k + 1, i, spread * 100.0])


func _triangles(mesh: Mesh) -> int:
	var n := 0
	for i in mesh.get_surface_count():
		n += mesh.surface_get_array_index_len(i) / 3
	return n


## The share of `lod`'s face area whose corners lie on different UV islands of `src` (vertices joined
## by faces or by the same place and UV); -1 when it has no UVs or uses a vertex `src` hasn't.
func _across_islands(src: Array, lod: Array) -> float:
	var v: PackedVector3Array = src[Mesh.ARRAY_VERTEX]
	if src[Mesh.ARRAY_TEX_UV] == null or lod[Mesh.ARRAY_TEX_UV] == null:
		return -1.0
	var uv: PackedVector2Array = src[Mesh.ARRAY_TEX_UV]
	var idx: PackedInt32Array = src[Mesh.ARRAY_INDEX]
	# Islands joined in this function (packed arrays are copied into lambdas and calls).
	var up := PackedInt32Array(range(v.size()))
	var pairs: Array[Vector2i] = []
	for t in range(0, idx.size() - 2, 3):
		pairs.append(Vector2i(idx[t], idx[t + 1]))
		pairs.append(Vector2i(idx[t + 1], idx[t + 2]))
	var of := {}
	for k in v.size():
		var key := [Vector3i((v[k] * 4096.0).round()), Vector2i((uv[k] * 4096.0).round())]
		if of.has(key):
			pairs.append(Vector2i(k, of[key]))
		else:
			of[key] = k
	for pair in pairs:
		var x := _root(up, pair.x)
		var y := _root(up, pair.y)
		if x != y:
			up[maxi(x, y)] = mini(x, y)
	var lv: PackedVector3Array = lod[Mesh.ARRAY_VERTEX]
	var luv: PackedVector2Array = lod[Mesh.ARRAY_TEX_UV]
	var li: PackedInt32Array = lod[Mesh.ARRAY_INDEX]
	var across := 0.0
	var total := 0.0
	for t in range(0, li.size() - 2, 3):
		var islands := []
		for k in 3:
			var q := li[t + k]
			var at: int = of.get([Vector3i((lv[q] * 4096.0).round()), Vector2i((luv[q] * 4096.0).round())], -1)
			if at < 0:
				return -1.0
			islands.append(_root(up, at))
		var area := (lv[li[t + 1]] - lv[li[t]]).cross(lv[li[t + 2]] - lv[li[t]]).length()
		total += area
		if islands[0] != islands[1] or islands[1] != islands[2]:
			across += area
	return across / maxf(total, 1e-9)


static func _root(up: PackedInt32Array, k: int) -> int:
	while up[k] != k:
		up[k] = up[up[k]]
		k = up[k]
	return k
