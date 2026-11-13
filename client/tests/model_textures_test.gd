extends SceneTree
## A model's .glb that asks for nearest filtering (Blender's Image Texture set to Closest) is drawn
## from the shader's crisp sampler; one that asks for linear stays as it was (model_textures.gd). A
## material set to Alpha Clip (glTF MASK) is drawn cut out at its cutoff, Alpha Blend see-through. A
## direction model's single file from a modeller's or FUE5's folder is turned to every direction.
##   godot --headless --path client -s res://tests/model_textures_test.gd

const ModelTextures := preload("res://scripts/world/model_textures.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const ModelSkin := preload("res://scripts/world/model_skin.gd")
## A skinned box with a one-second action (tools/models/make_baked_fixture.py).
const BAKED := "res://tests/fixtures/baked_box.glb"
const SOURCE := "res://assets/models/fue5/wooden-chest.glb"
## An inserter rigged as an arm (tools/models/make_rig_fixture.py); `-- --rig=<path.glb>` checks others too.
const RIG := "res://tests/fixtures/rig_inserter.glb"
const ModelRig := preload("res://scripts/world/model_rig.gd")
const InserterArms := preload("res://scripts/world/inserter_arms.gd")
const BeltLods := preload("res://scripts/world/belt_lods.gd")
const TestEnv := preload("res://tests/test_env.gd")
## A textured model with levels of detail (FUE5's, 19,000 triangles).
const LEVELS_MODEL := "res://assets/models/fue5/electric-mining-drill.glb"

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
	_single_models()
	_belt_wrap()
	_baked()
	_rig()
	_textured_levels()
	print("MODEL TEXTURES FAILS: %d" % fails)
	TestEnv.clean()
	quit(1 if fails > 0 else 0)


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


## A FACING_MODELS entity whose north model comes from FUE5's folder or a modeller's, with no east
## model beside it there, is drawn with that one model turned; with all four there, unturned.
func _single_models() -> void:
	var G := ModelLibrary.GLTF_SOURCE
	ModelLibrary._sources["boiler"] = G + "res://assets/models/fue5/boiler.glb"
	ModelLibrary._sources["boiler-east"] = G + "res://assets/models/boiler-east.glb"
	check(ModelLibrary.single_model("boiler") and ModelLibrary.model_name("boiler", "boiler", {}, 4) == "boiler"
		and ModelLibrary.turn_dir("boiler", 4, {}, "boiler") == 4, "FUE5's boiler: one model, turned east")
	var was := ModelLibrary.external_dir
	ModelLibrary.external_dir = "C:/modeller/models"
	ModelLibrary._sources["pumpjack"] = G + "C:/modeller/models/pumpjack.glb"
	ModelLibrary._sources["pumpjack-east"] = G + "res://assets/models/pumpjack-east.glb"
	check(ModelLibrary.model_name("pumpjack", "mining-drill", {}, 8) == "pumpjack"
		and ModelLibrary.turn_dir("mining-drill", 8, {}, "pumpjack") == 8, "a modeller's one pumpjack: turned south")
	ModelLibrary._sources["pumpjack-east"] = G + "C:/modeller/models/pumpjack-east.glb"
	check(not ModelLibrary.single_model("pumpjack") and ModelLibrary.model_name("pumpjack", "mining-drill", {}, 4) == "pumpjack-east",
		"a modeller's four pumpjacks: each drawn unturned")
	ModelLibrary._sources["inserter"] = G + "res://assets/models/inserter.glb"
	ModelLibrary._sources["inserter-east"] = G + "res://assets/models/inserter-east.glb"
	check(not ModelLibrary.single_model("inserter"), "Zenith's own inserters: still a model per direction")
	ModelLibrary.external_dir = was
	for n in ["boiler", "boiler-east", "pumpjack", "pumpjack-east", "inserter", "inserter-east"]:
		ModelLibrary._sources.erase(n)


## A modeller's baked (skeletal) animation: the bones' matrices per frame, the mesh split into the
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
				var tip := []
				for p in [ModelRig.Part.PINCER_A, ModelRig.Part.PINCER_B]:
					var verts: PackedVector3Array = load.rig["parts"][p][0][1][Mesh.ARRAY_VERTEX]
					var far := Vector3.ZERO
					for v in verts:
						if v.length() > far.length():
							far = v
					tip.append((lists[p][0] as Transform3D) * far)
				tips.append((tip[0] as Vector3).distance_to(tip[1]))
			check(tips[1] < tips[0] * 0.6, "rig: closed pincers' tips come together (%.3f open, %.3f closed)" % [tips[0], tips[1]])
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
	check(not levels.is_empty() and levels.size() <= ModelLods.TEXTURED_FLOORS.size(), "textured: 1 to %d levels (%d)" % [ModelLods.TEXTURED_FLOORS.size(), levels.size()])
	var full := _triangles(mesh)
	for k in levels.size():
		var lod: ArrayMesh = levels[k][0]
		var share := float(_triangles(lod)) / full
		check(share >= float(ModelLods.TEXTURED_FLOORS[k]), "level %d keeps %.0f%% of the triangles (at least %.0f%%)" % [k + 1, share * 100.0, float(ModelLods.TEXTURED_FLOORS[k]) * 100.0])
		check(ModelLods.switch_error(levels[k]) >= mesh.get_aabb().get_longest_axis_size() / float(ModelLods.TEXTURED_PIXELS[k]) * ModelLods.lod_threshold - 1e-4,
			"level %d is drawn only once the model is %d px or less" % [k + 1, int(ModelLods.TEXTURED_PIXELS[k])])
		for i in lod.get_surface_count():
			check(lod.surface_get_material(i) == mesh.surface_get_material(i), "level %d surface %d keeps its material" % [k + 1, i])
			var spread := _across_islands(ModelLods.arrays_of(mesh, i), lod.surface_get_arrays(i))
			check(spread >= 0.0 and spread < 0.001, "level %d surface %d: UVs kept, every face on one UV island (%.2f%% across)" % [k + 1, i, spread * 100.0])


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
