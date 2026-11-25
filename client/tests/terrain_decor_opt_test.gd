extends SceneTree
## The terrain/decorative GPU optimisation (branch perf/terrain-decor-opt): the ground's coast quads in their own
## surface (TerrainMesher.shore, --terrain-opt=old keeps one), the two ground materials kept in step by
## Visuals.set_terrain_param (with chunks' own copies, freed ones dropped), and a chunk's baked decorative sheet
## drawn by its ground (ChunkView.set_decor_sheet) without touching the shared, cached mesh.
##   godot --headless --audio-driver Dummy --path client -s res://tests/terrain_decor_opt_test.gd

const TerrainMesher := preload("res://scripts/world/terrain_mesher.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const ChunkView := preload("res://scripts/world/chunk_view.gd")
const DecorativeLayer := preload("res://scripts/world/decoratives.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const TestEnv := preload("res://tests/test_env.gd")

const SIZE := 32
const WATER_FROM := 16  # columns from here are water; the 8 surrounding chunks repeat this one, so there are two coasts (columns 15|16 and 31|0)

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _initialize() -> void:
	TestEnv.isolate("terrain-decor-opt-test")
	_test_shore_split()
	_test_terrain_params()
	_test_chunk_sheet()
	_test_flags_and_shaders()
	_test_fsr2_settings()
	print("TERRAIN DECOR OPT FAILS: %d" % fails)
	TestEnv.clean()
	quit(1 if fails > 0 else 0)


## A chunk of land (tile 0) in its west half and a lake (tile 1) in its east half.
func _job(textured: bool, coarse := false) -> TerrainMesher:
	var job := TerrainMesher.new()
	job.coarse = coarse
	job.textured = textured
	var ids := PackedInt32Array()
	ids.resize(SIZE * SIZE)
	for i in SIZE * SIZE:
		ids[i] = 1 if i % SIZE >= WATER_FROM else 0
	job.tile_ids = ids
	for i in 9:
		job.around.append(ids)
	job.colors = PackedColorArray([Color.DARK_GREEN, Color.DARK_BLUE])
	job.kind_of = PackedByteArray([0, 1])
	job.run()
	return job


func _test_shore_split() -> void:
	var was: bool = TerrainMesher.shore_split
	TerrainMesher.shore_split = true
	var job := _job(true)
	# Per coast row (two coasts): the land tile with water beside it, the shelf under it, the shelf over the water: 3 quads.
	check(job.shore.has_faces() and job.shore.verts.size() == 2 * SIZE * 3 * 4, "the coast has 3 quads a row in shore (%d verts)" % job.shore.verts.size())
	check(job.land.has_faces() and job.land.verts.size() == (WATER_FROM - 2) * SIZE * 4, "the interior land (columns 1-14) stays in land (%d verts)" % job.land.verts.size())
	check(job.water.has_faces(), "water is its own surface")
	var interior_ok := true
	for i in job.land.verts.size():
		# CUSTOM1.x is the wet mask, .y the shelf kind: nothing in land touches water or is a shelf.
		interior_ok = interior_ok and is_zero_approx(job.land.custom1[i * 4]) and is_zero_approx(job.land.custom1[i * 4 + 1])
	check(interior_ok, "no land vertex has water beside it or is a shelf")
	var under := 0
	var over := 0
	var top := 0
	var coast_ok := true
	for i in job.shore.verts.size():
		var wet: float = job.shore.custom1[i * 4]
		var kind: float = job.shore.custom1[i * 4 + 1]
		if is_equal_approx(kind, TerrainMesher.SHELF_UNDER_LAND):
			under += 1
		elif is_equal_approx(kind, TerrainMesher.SHELF_OVER_WATER):
			over += 1
		elif wet != 0.0 and is_zero_approx(kind):
			top += 1
		else:
			coast_ok = false
	check(coast_ok and under == 2 * SIZE * 4 and over == 2 * SIZE * 4 and top == 2 * SIZE * 4,
		"shore holds the wet land tile (%d), the shelf under land (%d) and over water (%d) verts" % [top, under, over])
	# Without the textures (the Factorio install) no tile is wet: no coast, banks only.
	var plain := _job(false)
	check(not plain.shore.has_faces() and plain.land.has_faces(), "untextured ground has no coast surface")
	# --terrain-opt=old: everything the coast has goes back in land, nothing in shore.
	TerrainMesher.shore_split = false
	var old := _job(true)
	check(not old.shore.has_faces(), "--terrain-opt=old: shore stays empty")
	check(old.land.verts.size() == job.land.verts.size() + job.shore.verts.size(),
		"--terrain-opt=old: land holds interior + coast (%d = %d + %d)" % [old.land.verts.size(), job.land.verts.size(), job.shore.verts.size()])
	TerrainMesher.shore_split = was


func _test_terrain_params() -> void:
	var land := Visuals.terrain_material()
	var shore := Visuals.terrain_shore_material()
	if Visuals.terrain_opt_old:
		check(shore == land, "--terrain-opt=old: the coast's material is the one ground material")
		return
	check(land != shore and land.shader != shore.shader, "two ground materials with two shaders")
	var param := &"surface_roughness_add"
	var was_land: Variant = land.get_shader_parameter(param)
	var was_shore: Variant = shore.get_shader_parameter(param)
	var copy := Visuals.make_chunk_terrain_material(land)
	var shore_copy := Visuals.make_chunk_terrain_material(shore)
	check(copy != land and copy.shader == land.shader and shore_copy.shader == shore.shader, "a chunk's copy keeps its base's shader")
	var before: int = Visuals._terrain_chunk_mats.size()
	Visuals.set_terrain_param(param, 0.37)
	check(is_equal_approx(float(land.get_shader_parameter(param)), 0.37) and is_equal_approx(float(shore.get_shader_parameter(param)), 0.37),
		"set_terrain_param sets both ground materials")
	check(is_equal_approx(float(copy.get_shader_parameter(param)), 0.37) and is_equal_approx(float(shore_copy.get_shader_parameter(param)), 0.37),
		"... and the chunks' live copies")
	# A copy that is gone (its chunk freed) drops out of the list on the next set, a live one stays.
	copy = null
	Visuals.set_terrain_param(param, 0.5)
	check(Visuals._terrain_chunk_mats.size() == before - 1, "a freed chunk copy is pruned (%d -> %d)" % [before, Visuals._terrain_chunk_mats.size()])
	check(is_equal_approx(float(shore_copy.get_shader_parameter(param)), 0.5), "a live chunk copy keeps following")
	shore_copy = null
	Visuals.set_terrain_param(param, was_land)
	check(Visuals._terrain_chunk_mats.size() == before - 2, "the list is back to where it was")
	land.set_shader_parameter(param, was_land)
	shore.set_shader_parameter(param, was_shore)


func _sheet() -> ImageTexture:
	return ImageTexture.create_from_image(Image.create(8, 8, false, Image.FORMAT_RGBA8))


func _test_chunk_sheet() -> void:
	if Visuals.terrain_opt_old:
		var old_cv := ChunkView.new()
		old_cv.apply_terrain(_job(true))
		check(not old_cv.can_composite_decor() and not old_cv.set_decor_sheet(_sheet(), 0.1, Vector2.ZERO), "--terrain-opt=old: the ground draws no sheet")
		old_cv.free()
		return
	var was: bool = TerrainMesher.shore_split
	TerrainMesher.shore_split = true
	var cv := ChunkView.new()
	cv.apply_terrain(_job(true))
	var mesh: ArrayMesh = cv.terrain_mesh()
	check(mesh != null and mesh.get_surface_count() == 3, "land, shore and water surfaces")
	check(cv.can_composite_decor() and not cv.has_decor_sheet(), "a full ground can take a sheet, none yet")
	var land_i := cv._land_surface_idx
	var shore_i := cv._shore_surface_idx
	check(land_i == 0 and shore_i == 1, "land and shore surface indices (%d, %d)" % [land_i, shore_i])
	var tex := _sheet()
	check(cv.set_decor_sheet(tex, 0.25, Vector2(64.0, -32.0)), "set_decor_sheet takes on a full ground")
	var lm := cv._terrain.get_surface_override_material(land_i) as ShaderMaterial
	var sm := cv._terrain.get_surface_override_material(shore_i) as ShaderMaterial
	check(lm != null and sm != null and lm != Visuals.terrain_material() and sm != Visuals.terrain_shore_material(), "the chunk's own material copies are set as overrides")
	check(lm != null and lm.shader == Visuals.terrain_material().shader and sm != null and sm.shader == Visuals.terrain_shore_material().shader, "each copy keeps its own shader")
	check(lm != null and lm.get_shader_parameter(&"decor_sheet") == tex and bool(lm.get_shader_parameter(&"has_decor_sheet"))
		and is_equal_approx(float(lm.get_shader_parameter(&"decor_raised_shade")), 0.25)
		and lm.get_shader_parameter(&"decor_chunk_origin") == Vector2(64.0, -32.0), "the sheet, its origin and shade are on the land copy")
	check(sm != null and sm.get_shader_parameter(&"decor_sheet") == tex and bool(sm.get_shader_parameter(&"has_decor_sheet")), "... and on the shore copy")
	check(cv._terrain.get_surface_override_material(2) == null, "water gets no override")
	# The mesh is shared with other builds (the terrain cache): its own surfaces keep the shared materials.
	check(mesh.surface_get_material(land_i) == Visuals.terrain_material() and mesh.surface_get_material(shore_i) == Visuals.terrain_shore_material(),
		"the cached mesh's own materials are untouched")
	# Another chunk on the same kept mesh has a material of its own.
	var cv2 := ChunkView.new()
	cv2.apply_kept_terrain(mesh, PackedInt32Array())
	check(cv2._land_surface_idx == land_i and cv2._shore_surface_idx == shore_i, "a kept mesh's surfaces are found by material")
	check(cv2._terrain.get_surface_override_material(land_i) == null, "the other chunk has no sheet yet")
	var tex2 := _sheet()
	check(cv2.set_decor_sheet(tex2, 0.0, Vector2.ZERO), "the other chunk takes its own sheet")
	var lm2 := cv2._terrain.get_surface_override_material(land_i) as ShaderMaterial
	check(lm2 != null and lm2 != lm and lm2.get_shader_parameter(&"decor_sheet") == tex2 and lm.get_shader_parameter(&"decor_sheet") == tex,
		"each chunk's sheet is its own on the shared mesh")
	# Out of range or behind the camera: the ground stops drawing the sheet, then draws it again.
	cv.set_decor_sheet_visible(false)
	check(not bool(lm.get_shader_parameter(&"has_decor_sheet")) and not bool(sm.get_shader_parameter(&"has_decor_sheet")) and bool(lm2.get_shader_parameter(&"has_decor_sheet")),
		"hiding the sheet is per chunk")
	cv.set_decor_sheet_visible(true)
	check(bool(lm.get_shader_parameter(&"has_decor_sheet")), "shown again")
	# A rebuilt ground (a new mesh) carries the sheet over to its new surfaces.
	cv.apply_terrain(_job(true))
	check(cv.has_decor_sheet() and cv._terrain.get_surface_override_material(cv._land_surface_idx) != null and cv._terrain.mesh != mesh,
		"a new ground mesh gets the sheet too")
	cv.clear_decor_sheet()
	check(not cv.has_decor_sheet() and cv._terrain.get_surface_override_material(0) == null and cv._terrain.get_surface_override_material(1) == null,
		"clear_decor_sheet drops the overrides")
	check(cv2._terrain.get_surface_override_material(land_i) == lm2 and mesh.surface_get_material(land_i) == Visuals.terrain_material(),
		"... and leaves the other chunk and the shared mesh alone")
	# A far (coarse) ground can't, and a set sheet is taken off there.
	var far := ChunkView.new()
	far.apply_terrain(_job(true, true))
	check(far.ground_coarse and not far.can_composite_decor() and not far.set_decor_sheet(tex, 0.0, Vector2.ZERO) and not far.has_decor_sheet(),
		"a coarse ground draws no sheet (a FlatSheet stays)")
	check(cv2.set_decor_sheet(tex2, 0.0, Vector2.ZERO), "(the other chunk takes again)")
	cv2.apply_terrain(_job(true, true))
	check(not cv2.has_decor_sheet() and cv2._terrain.get_surface_override_material(0) == null, "a ground turned coarse drops its sheet")
	var empty := ChunkView.new()
	check(not empty.can_composite_decor() and not empty.set_decor_sheet(null, 0.0, Vector2.ZERO), "no ground or no texture: false")
	for v in [cv, cv2, far, empty]:
		v.free()
	TerrainMesher.shore_split = was


func _test_flags_and_shaders() -> void:
	# No flags on this run: everything optimised.
	check(not DecorativeLayer.grass_opt_old and not DecorativeLayer.legacy_shaders and DecorativeLayer.decor_composite, "defaults: optimised shaders and composited sheets")
	check(TerrainMesher.shore_split and not Visuals.terrain_opt_old, "default: coast split from the interior")
	var interior: String = (load("res://shaders/terrain.gdshader") as Shader).code
	var coast: String = (load("res://shaders/terrain_shore.gdshader") as Shader).code
	var common := FileAccess.get_file_as_string("res://shaders/terrain_common.gdshaderinc")
	check(not interior.contains("TERRAIN_SHORE") and coast.contains("#define TERRAIN_SHORE") and common.contains("discard"), "only the coast's shader defines TERRAIN_SHORE, the code with the discards")
	var old: String = (load("res://shaders/terrain_old.gdshader") as Shader).code
	check(old.contains("discard") and not old.contains("has_decor_sheet"), "terrain_old.gdshader is the original (discards, no sheet)")
	for sp in ["decorative_grass", "decorative_carpet", "decorative_flat", "decorative_sheet"]:
		var sh := load("res://shaders/%s.gdshader" % sp) as Shader
		var oldsh := load("res://shaders/%s_old.gdshader" % sp) as Shader
		check(sh != null and oldsh != null and sh.code != oldsh.code, "%s has an optimised shader and an _old copy" % sp)
	var grass: String = (load("res://shaders/decorative_grass.gdshader") as Shader).code
	check(not grass.contains("blend_mix") and grass.contains("ALPHA_SCISSOR_THRESHOLD"), "optimised grass is alpha-scissored in the opaque pass")
	check((load("res://shaders/decorative_grass_old.gdshader") as Shader).code.contains("blend_mix"), "the old grass still blends")


func _test_fsr2_settings() -> void:
	check(str(Settings.DEFAULTS["graphics"]["upscaler"]) == "fsr2"
		and is_equal_approx(float(Settings.DEFAULTS["graphics"]["upscaler_sharpness"]), 0.575),
		"upscaler defaults stay fsr2 and 0.575 (= FSR_SHARPNESS 0.85)")

	# scaling_mode_for across bilinear, fsr1, fsr2 and scales 0.5 / 0.67 / 0.75 / 1.0 / 1.5.
	for s: float in [0.5, 0.67, 0.75, 1.0, 1.5]:
		check(Settings.scaling_mode_for(s, "bilinear") == Viewport.SCALING_3D_MODE_BILINEAR,
			"bilinear stays bilinear at %.2f" % s)
	for s: float in [0.5, 0.67, 0.75]:
		check(Settings.scaling_mode_for(s, "fsr1") == Viewport.SCALING_3D_MODE_FSR,
			"fsr1 uses SCALING_3D_MODE_FSR below native (%.2f)" % s)
	for s: float in [1.0, 1.5]:
		check(Settings.scaling_mode_for(s, "fsr1") == Viewport.SCALING_3D_MODE_BILINEAR,
			"fsr1 uses bilinear at/above native (%.2f)" % s)
	for s: float in [0.5, 0.67, 0.75, 1.0]:
		check(Settings.scaling_mode_for(s, "fsr2") == Viewport.SCALING_3D_MODE_FSR2,
			"fsr2 uses SCALING_3D_MODE_FSR2 at/below 1.0 (%.2f)" % s)
	check(Settings.scaling_mode_for(1.5, "fsr2") == Viewport.SCALING_3D_MODE_BILINEAR,
		"fsr2 falls back to bilinear above native (1.5)")

	# fsr_sharpness_value: 0.575 -> 0.85, 0.0 -> 2.0, 1.0 -> 0.0, clamped outside [0, 1].
	var sharp_had := Settings.has_value("graphics", "upscaler_sharpness")
	var sharp_was: Variant = Settings.get_value("graphics", "upscaler_sharpness")
	Settings.set_value("graphics", "upscaler_sharpness", 0.575, false)
	check(is_equal_approx(Settings.fsr_sharpness_value(), Settings.FSR_SHARPNESS),
		"upscaler_sharpness 0.575 maps to FSR_SHARPNESS (0.85)")
	Settings.set_value("graphics", "upscaler_sharpness", 0.0, false)
	check(is_equal_approx(Settings.fsr_sharpness_value(), 2.0), "upscaler_sharpness 0.0 -> 2.0 (softest)")
	Settings.set_value("graphics", "upscaler_sharpness", 1.0, false)
	check(is_equal_approx(Settings.fsr_sharpness_value(), 0.0), "upscaler_sharpness 1.0 -> 0.0 (sharpest)")
	Settings.set_value("graphics", "upscaler_sharpness", -0.5, false)
	var clamp_lo := Settings.fsr_sharpness_value()
	Settings.set_value("graphics", "upscaler_sharpness", 1.5, false)
	var clamp_hi := Settings.fsr_sharpness_value()
	check(is_equal_approx(clamp_lo, 2.0) and is_equal_approx(clamp_hi, 0.0),
		"fsr_sharpness_value clamps outside [0, 1]")
	if sharp_had:
		Settings.set_value("graphics", "upscaler_sharpness", sharp_was, false)
	else:
		Settings.reset_value("graphics", "upscaler_sharpness")

	# upscaler_in_effect and fsr2_wanted reflect settings.
	var up_had := Settings.has_value("graphics", "upscaler")
	var up_was: Variant = Settings.get_value("graphics", "upscaler")
	var rs_had := Settings.has_value("graphics", "render_scale")
	var rs_was: Variant = Settings.get_value("graphics", "render_scale")
	Settings.set_value("graphics", "upscaler", "fsr2", false)
	Settings.set_value("graphics", "render_scale", 1.0, false)
	check(Settings.upscaler_in_effect() == "fsr2" and Settings.fsr2_wanted(),
		"fsr2_wanted is true at upscaler=fsr2 and render_scale=1.0")
	Settings.set_value("graphics", "render_scale", 1.5, false)
	check(not Settings.fsr2_wanted(), "fsr2_wanted is false above 1.0")
	if up_had:
		Settings.set_value("graphics", "upscaler", up_was, false)
	else:
		Settings.reset_value("graphics", "upscaler")
	if rs_had:
		Settings.set_value("graphics", "render_scale", rs_was, false)
	else:
		Settings.reset_value("graphics", "render_scale")

	# look_pre_aa_for and follow_taa under SCALING_3D_MODE_FSR2.
	var vp := SubViewport.new()
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.use_taa = false
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_SMAA
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	check(is_equal_approx(Settings.look_pre_aa_for(vp), 0.75), "look_pre_aa_for returns 0.75 for SMAA without FSR2")
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
	check(is_zero_approx(Settings.look_pre_aa_for(vp)), "look_pre_aa_for returns 0.0 under SCALING_3D_MODE_FSR2 (SMAA)")
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	check(is_zero_approx(Settings.look_pre_aa_for(vp)), "look_pre_aa_for returns 0.0 under SCALING_3D_MODE_FSR2 (FXAA)")

	var taa_was: bool = Settings.look_taa
	var aa_had := Settings.has_value("graphics", "antialiasing")
	var aa_was: Variant = Settings.get_value("graphics", "antialiasing")
	var smaa_held_was: bool = Settings._smaa_held
	Settings.look_taa = true
	Settings.set_value("graphics", "antialiasing", "smaa", false)
	vp.use_taa = true
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_SMAA
	Settings.follow_taa(vp)
	check(not vp.use_taa and vp.screen_space_aa == Viewport.SCREEN_SPACE_AA_DISABLED,
		"follow_taa keeps TAA and SMAA off while SCALING_3D_MODE_FSR2 is active (look_taa=true)")
	Settings.look_taa = false
	Settings._smaa_held = true
	vp.use_taa = true
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_SMAA
	Settings.follow_taa(vp)
	check(not vp.use_taa and vp.screen_space_aa == Viewport.SCREEN_SPACE_AA_DISABLED,
		"follow_taa keeps TAA and SMAA off under SCALING_3D_MODE_FSR2 even when _smaa_held was set")
	Settings.look_taa = taa_was
	Settings._smaa_held = smaa_held_was
	if aa_had:
		Settings.set_value("graphics", "antialiasing", aa_was, false)
	else:
		Settings.reset_value("graphics", "antialiasing")
	vp.free()

	# Step 1-3 regression checks: reactive-mask clear shader, god_rays premul alpha,
	# look_fsr2 gating in look_pass/cinematic_grade, Looks reactive-clear quad, and ortho fallback.
	var clear_shader := load("res://shaders/look_reactive_clear.gdshader") as Shader
	check(clear_shader != null and clear_shader.code.contains("blend_mul")
		and clear_shader.code.contains("ALBEDO = vec3(1.0)") and clear_shader.code.contains("ALPHA = 0.0"),
		"look_reactive_clear.gdshader preserves RGB via blend_mul and clears alpha to 0.0")
	var rays_shader := load("res://shaders/god_rays.gdshader") as Shader
	check(rays_shader != null and rays_shader.code.contains("blend_premul_alpha")
		and not rays_shader.code.contains("blend_add") and rays_shader.code.contains("ALPHA = 0.0"),
		"god_rays.gdshader uses blend_premul_alpha with ALPHA = 0.0")
	var look_inc := FileAccess.get_file_as_string("res://shaders/look_pass.gdshaderinc")
	check(look_inc.contains("uniform float look_fsr2"), "look_pass.gdshaderinc declares uniform float look_fsr2")
	var cine_path := ProjectSettings.globalize_path("res://../addons-src/cinematic-shaders/shaders/cinematic_grade.gdshader")
	if FileAccess.file_exists(cine_path):
		var cine_code := FileAccess.get_file_as_string(cine_path)
		check(cine_code.contains("(1.0 - look_fsr2)") and cine_code.contains("look_fsr2 < 0.5"),
			"cinematic_grade.gdshader gates sharpen/aberration/grain with look_fsr2")

	# Orthographic projection fallback in Settings.
	var ortho_was: bool = Settings.camera_orthographic
	var up_had2 := Settings.has_value("graphics", "upscaler")
	var up_was2: Variant = Settings.get_value("graphics", "upscaler")
	var rs_had2 := Settings.has_value("graphics", "render_scale")
	var rs_was2: Variant = Settings.get_value("graphics", "render_scale")
	Settings.set_value("graphics", "upscaler", "fsr2", false)
	Settings.set_value("graphics", "render_scale", 0.67, false)
	Settings.camera_orthographic = true
	check(Settings.scaling_mode_for(0.67, "fsr2") == Viewport.SCALING_3D_MODE_FSR,
		"ortho fallback uses SCALING_3D_MODE_FSR below 1.0 under fsr2")
	check(Settings.scaling_mode_for(1.0, "fsr2") == Viewport.SCALING_3D_MODE_BILINEAR,
		"ortho fallback uses SCALING_3D_MODE_BILINEAR at 1.0 under fsr2")
	check(Settings.fsr2_wanted(), "fsr2_wanted stays true during temporary orthographic view")
	Settings.camera_orthographic = false
	check(Settings.scaling_mode_for(0.67, "fsr2") == Viewport.SCALING_3D_MODE_FSR2,
		"perspective restores SCALING_3D_MODE_FSR2")
	Settings.camera_orthographic = ortho_was
	if up_had2:
		Settings.set_value("graphics", "upscaler", up_was2, false)
	else:
		Settings.reset_value("graphics", "upscaler")
	if rs_had2:
		Settings.set_value("graphics", "render_scale", rs_was2, false)
	else:
		Settings.reset_value("graphics", "render_scale")

	# Looks _reactive_clear quad and look_fsr2 uniform syncing.
	var Looks := load("res://scripts/world/looks.gd")
	var vp2 := SubViewport.new()
	vp2.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	root.add_child(vp2)
	var looks_node: Node3D = Looks.new()
	vp2.add_child(looks_node)
	var env := Environment.new()
	var sun := DirectionalLight3D.new()
	vp2.add_child(sun)
	looks_node.attach(env, sun)
	var pass_shader := Shader.new()
	pass_shader.code = "shader_type spatial;\n#include \"res://shaders/look_pass.gdshaderinc\"\nvoid fragment() { ALBEDO = vec3(0.5); }\n"
	Looks.register("test_fsr2_pass/look", {
		"name": "Test FSR2 Pass",
		"passes": [{"shader": pass_shader}],
	}, "test_fsr2_pass")
	looks_node.use("test_fsr2_pass/look", true)
	check(looks_node._pass_nodes.size() == 1, "Looks created pass node for test look")
	var pass_mat: ShaderMaterial = (looks_node._pass_nodes[0] as MeshInstance3D).material_override as ShaderMaterial
	check(looks_node._reactive_clear == null or not looks_node._reactive_clear.visible,
		"_reactive_clear stays hidden when FSR2 is off")
	check(is_zero_approx(float(pass_mat.get_shader_parameter("look_fsr2"))),
		"look_fsr2 is 0.0 when FSR2 is off")
	vp2.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
	looks_node.sync_pre_aa(vp2)
	check(looks_node._reactive_clear != null and looks_node._reactive_clear.visible,
		"_reactive_clear appears under FSR2 when a look pass is active")
	if looks_node._reactive_clear != null:
		var clear_mat: ShaderMaterial = looks_node._reactive_clear.material_override as ShaderMaterial
		check(clear_mat.render_priority == -101, "_reactive_clear runs at render_priority -101")
	check(is_equal_approx(float(pass_mat.get_shader_parameter("look_fsr2")), 1.0),
		"look_fsr2 is 1.0 when FSR2 is active")
	looks_node.use("factorio", true)
	check(looks_node._reactive_clear == null or not looks_node._reactive_clear.visible,
		"_reactive_clear hides on pass-less factorio look even under FSR2")
	looks_node.use("test_fsr2_pass/look", true)
	pass_mat = (looks_node._pass_nodes[0] as MeshInstance3D).material_override as ShaderMaterial
	vp2.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	looks_node.sync_pre_aa(vp2)
	check(looks_node._reactive_clear == null or not looks_node._reactive_clear.visible,
		"_reactive_clear hides when FSR2 turns off")
	check(is_zero_approx(float(pass_mat.get_shader_parameter("look_fsr2"))),
		"look_fsr2 returns to 0.0 when FSR2 turns off")
	Looks.remove_owner("test_fsr2_pass")
	root.remove_child(vp2)
	vp2.free()
