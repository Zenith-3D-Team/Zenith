extends "res://tests/ui_test_base.gd"
## UI test sections: pbr_looks.

func _antialiasing_look() -> void:
	check(Settings.DEFAULTS["graphics"]["antialiasing"] == "smaa", "SMAA is the default anti-aliasing")
	var upscaler_was: Variant = Settings.get_value("graphics", "upscaler")
	Settings.set_value("graphics", "upscaler", "fsr1")
	var aa_was: Variant = Settings.get_value("graphics", "antialiasing")
	var look_was: Variant = Settings.get_value("graphics", "look")
	var started_was := Settings._addons_started
	var active_was: Node = LooksScript.active
	var taa_was := Settings.look_taa
	LooksScript.active = null
	var id := "ui-test/passes"
	LooksScript.register(id, {"name": "With a pass", "passes": [{"shader": "res://shaders/ui_test_none.gdshader"}]}, "ui-test")
	Settings.set_value("graphics", "antialiasing", "msaa4")
	Settings.set_value("graphics", "look", "factorio")
	Settings._addons_started = true
	Settings.settle_antialiasing(null)
	check(not Settings.look_draws_passes() and str(Settings.get_value("graphics", "antialiasing")) == "msaa4"
		and Settings.antialiasing_in_effect() == "msaa4", "under Zenith's Factorio look MSAA 4x stays as picked")
	# Before the add-ons start an add-on's look isn't registered yet: it is taken to have passes.
	Settings._addons_started = false
	Settings.set_value("graphics", "look", "some-addon/unregistered")
	check(Settings.look_draws_passes(), "an add-on's look not registered yet counts as drawing passes until the add-ons have started")
	Settings._addons_started = true
	check(not Settings.look_draws_passes(), "after they start, a look nobody registered is Factorio's: no passes")
	# Started under the look (the owner's case): the saved MSAA becomes SMAA, in the file too.
	Settings.set_value("graphics", "look", id)
	Settings.settle_antialiasing(null)
	var saved := ConfigFile.new()
	saved.load(Settings.path)
	check(str(Settings.get_value("graphics", "antialiasing")) == "smaa" and str(saved.get_value("graphics", "antialiasing", "")) == "smaa"
		and Settings.antialiasing_in_effect() == "smaa" and Settings.antialiasing_look_note().contains("MSAA"),
		"started under a look with passes a saved MSAA 4x is switched to SMAA and saved: %s" % Settings.get_value("graphics", "antialiasing"))
	# Turned on mid-run: the same switch (main.gd _note_look_antialiasing).
	Settings.set_value("graphics", "look", "factorio")
	Settings.set_value("graphics", "antialiasing", "msaa8")
	check(not Settings.switch_msaa_for_look() and str(Settings.get_value("graphics", "antialiasing")) == "msaa8",
		"under Zenith's own look nothing is switched")
	Settings.set_value("graphics", "look", id)
	check(Settings.switch_msaa_for_look() and str(Settings.get_value("graphics", "antialiasing")) == "smaa",
		"a look with passes turned on mid-run switches the saved MSAA to SMAA")
	check(not Settings.switch_msaa_for_look(), "and only once")
	# TAA from a look over the setting's SMAA: the choice stays SMAA, drawn without it while TAA is on.
	Settings.look_taa = true
	check(Settings.taa_on() and Settings.antialiasing_in_effect() == "smaa", "a look's TAA is on; the choice in effect stays SMAA")
	check(Settings.screen_space_aa_for("smaa", true) == Viewport.SCREEN_SPACE_AA_DISABLED
		and Settings.screen_space_aa_for("smaa", false) == Viewport.SCREEN_SPACE_AA_SMAA
		and Settings.screen_space_aa_for("fxaa", true) == Viewport.SCREEN_SPACE_AA_FXAA
		and Settings.screen_space_aa_for("taa", true) == Viewport.SCREEN_SPACE_AA_DISABLED,
		"no SMAA under TAA (TAA resolves the edges; SMAA's passes over it cost GPU for nothing); FXAA stays")
	# A look's TAA turned on and off in a running game: SMAA goes and comes back with it, and only SMAA.
	var vp := SubViewport.new()
	add_child(vp)
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_SMAA
	Settings.follow_taa(vp)
	var with_taa := vp.use_taa and vp.screen_space_aa == Viewport.SCREEN_SPACE_AA_DISABLED
	Settings.look_taa = false
	Settings.follow_taa(vp)
	var after := not vp.use_taa and vp.screen_space_aa == Viewport.SCREEN_SPACE_AA_SMAA
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	Settings.look_taa = true
	Settings.follow_taa(vp)
	var fxaa_kept := vp.use_taa and vp.screen_space_aa == Viewport.SCREEN_SPACE_AA_FXAA
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	Settings.look_taa = false
	Settings.follow_taa(vp)
	var none_kept := not vp.use_taa and vp.screen_space_aa == Viewport.SCREEN_SPACE_AA_DISABLED
	check(with_taa and after and fxaa_kept and none_kept,
		"a look's TAA drops SMAA while it is on and gives it back after; FXAA and no anti-aliasing are left as they are (%s %s %s %s)" % [with_taa, after, fxaa_kept, none_kept])
	vp.queue_free()
	Settings.look_taa = taa_was
	# A saved MSAA the start didn't switch (an add-on's look put on later) shows as SMAA when Settings opens.
	Settings._cfg.set_value("graphics", "antialiasing", "msaa4")
	# The settings window greys the MSAA choices out under the look, each with its reason.
	var w: Node = SettingsWindow.new()
	add_child(w)
	await get_tree().process_frame
	var box := w.find_child("graphics-antialiasing", true, false) as OptionButton
	var greyed: Array = []
	var open: Array = []
	for i in box.item_count:
		if Settings.MSAA.has(str(box.get_item_metadata(i))):
			if box.is_item_disabled(i) and box.get_item_tooltip(i).contains("SMAA"):
				greyed.append(box.get_item_metadata(i))
		elif not box.is_item_disabled(i):
			open.append(box.get_item_metadata(i))
	check(greyed.size() == 3 and open.size() == 4, "under the look the three MSAA choices are greyed out with a reason, the rest open: %s %s" % [greyed, open])
	check(str(box.get_item_metadata(box.selected)) == "smaa" and str(Settings.get_value("graphics", "antialiasing")) == "smaa",
		"the dropdown shows SMAA, not the greyed MSAA 4x: %s" % box.get_item_metadata(box.selected))
	w.queue_free()
	Settings.set_value("graphics", "look", "factorio")
	w = SettingsWindow.new()
	add_child(w)
	await get_tree().process_frame
	box = w.find_child("graphics-antialiasing", true, false) as OptionButton
	var any_grey := false
	for i in box.item_count:
		any_grey = any_grey or box.is_item_disabled(i)
	check(not any_grey, "under Zenith's own look every choice is open")
	w.queue_free()
	LooksScript.looks.erase(id)
	LooksScript.order.erase(id)
	LooksScript.active = active_was
	Settings.set_value("graphics", "antialiasing", aa_was)
	Settings.set_value("graphics", "upscaler", upscaler_was)
	Settings.set_value("graphics", "look", look_was)
	Settings._addons_started = started_was


## True when the control or its row's parent has a tooltip containing `word` (the card rows keep their notes as tooltips).


func _texture_metal_look() -> void:
	if DisplayServer.get_name() == "headless":
		print("texture metal look: needs a window, skipped")
		return
	var SkyScript := preload("res://scripts/world/sky.gd")
	var stage := Node3D.new()
	add_child(stage)
	var env := Environment.new()
	var planet_sky: Node = SkyScript.new()
	stage.add_child(planet_sky)
	planet_sky.set_clouds(false)
	var sky_res := Sky.new()
	sky_res.sky_material = planet_sky.sky_material
	sky_res.radiance_size = Sky.RADIANCE_SIZE_32
	sky_res.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	env.background_mode = Environment.BG_SKY
	env.sky = sky_res
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	stage.add_child(world_env)
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	stage.add_child(sun)
	var looks: Node = LooksScript.new()
	stage.add_child(looks)
	looks.attach(env, sun)
	looks.use("factorio", true)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40, 40)
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.36, 0.27, 0.12)
	ground_mat.roughness = 1.0
	plane.material = ground_mat
	ground.mesh = plane
	stage.add_child(ground)
	var models := {"paint": ["res://tests/fixtures/metal_box_paint.glb", true, -3.0],
		"metal": ["res://tests/fixtures/metal_box_metal.glb", true, 0.0],
		"builtin": ["res://assets/models/packs/wube3dp/steel-chest.glb", false, 3.0]}
	var boxes := {}
	for key in models:
		var load := ModelLibrary.Load.new()
		load.path = models[key][0]
		load.combine = false
		load.modeller = models[key][1]
		load.run()
		var mesh: Mesh = ModelLibrary._commit_load(load, []) if load.ok else null
		check(mesh != null, "texture metal look: %s loads" % models[key][0])
		if mesh == null:
			stage.queue_free()
			return
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.position = Vector3(float(models[key][2]), 0.0, 0.0)
		stage.add_child(mi)
		boxes[key] = mi
	# Factorio's view: from the south, 48 degrees down, orthographic.
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 7.0
	stage.add_child(cam)
	cam.rotation_degrees = Vector3(-48.0, 0.0, 0.0)
	cam.position = Vector3(0.0, 0.5, 0.0) + cam.basis.z * 20.0
	cam.make_current()
	var shots := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--texture-metal-shots="):
			shots = arg.get_slice("=", 1)
	var measured := {}
	for share in ["paint", "full"]:
		looks._metal_arg = 1.0 if share == "full" else -1.0
		for i in 90:
			planet_sky.apply(env, sun, 0.0, 0.0, 1.0 / 60.0, false)
			looks.apply(0.0, 0.0, "nauvis", false, planet_sky.state)
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		if shots != "":
			DirAccess.make_dir_recursive_absolute(shots)
			img.save_png(shots.path_join("texture_metal_%s.png" % share))
		var means := {}
		for key in boxes:
			means[key] = _screen_mean(img, cam, _screen_rect(cam, boxes[key].get_aabb(), boxes[key].position))
		# Open ground north of the boxes, out of their shadows.
		means["ground"] = _screen_mean(img, cam, _screen_rect(cam, AABB(Vector3(-4.0, 0.0, -4.0), Vector3(8.0, 0.0, 1.5)), Vector3.ZERO))
		measured[share] = means
		print("texture metal look (%s): %s" % [share, means])
	looks._metal_arg = -1.0
	var paint: Dictionary = measured["paint"]
	var full: Dictionary = measured["full"]
	var ratio := float(paint["metal"][3]) / maxf(float(paint["paint"][3]), 1e-6)
	check(absf(ratio - 1.0) <= 0.1, "texture metal look: as paint, the metal box draws within 10%% of the paint box (%.3f)" % ratio)
	var ratio_full := float(full["metal"][3]) / maxf(float(full["paint"][3]), 1e-6)
	check(ratio_full <= 0.8, "texture metal look: in full (as before), the metal box draws at most 0.8 of the paint box (%.3f)" % ratio_full)
	for key in ["builtin", "ground", "paint"]:
		var a: Array = paint[key]
		var b: Array = full[key]
		check(absf(a[0] - b[0]) <= 1.0 and absf(a[1] - b[1]) <= 1.0 and absf(a[2] - b[2]) <= 1.0,
			"texture metal look: the %s draws the same either way within a level (%s, %s)" % [key, a, b])
	for key in boxes:
		boxes[key].visible = false
	await _texture_metal_models(stage, looks, planet_sky, env, sun, cam, shots)
	stage.queue_free()
	await get_tree().process_frame


## `-- --texture-metal-models=<folder>`: a modeller's drill, pipes and ore (Vasillo's file names) measured
## alone in the same scene, as paint and in full: each one's screen mean over its own pixels (those that
## change when it is shown), printed and saved beside the boxes' pictures. The ore twice, the second in a
## tall box's shadow. For reading by eye: no check.


func _texture_metal_models(stage: Node3D, looks: Node, planet_sky: Node, env: Environment, sun: DirectionalLight3D,
		cam: Camera3D, shots: String) -> void:
	var dir := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--texture-metal-models="):
			dir = arg.get_slice("=", 1)
	if dir == "":
		return
	var caster := MeshInstance3D.new()
	var tall := BoxMesh.new()
	tall.size = Vector3(0.6, 3.0, 2.0)
	caster.mesh = tall
	caster.position = Vector3(-1.0, 1.5, -0.3)
	caster.visible = false
	stage.add_child(caster)
	var step := func(frames: int) -> void:
		for i in frames:
			planet_sky.apply(env, sun, 0.0, 0.0, 1.0 / 60.0, false)
			looks.apply(0.0, 0.0, "nauvis", false, planet_sky.state)
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
	for shot in [["electric-mining-drill", false], ["pipe-corner-up-right", false], ["pipe-straight-horizontal", false],
			["iron-ore-1", false], ["iron-ore-1", true]]:
		var load := ModelLibrary.Load.new()
		load.path = dir.path_join(str(shot[0]) + ".glb")
		load.combine = false
		load.modeller = true
		load.run()
		var mesh: Mesh = ModelLibrary._commit_load(load, []) if load.ok else null
		if mesh == null:
			print("texture metal model %s: didn't load" % load.path)
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		stage.add_child(mi)
		caster.visible = bool(shot[1])
		var label := str(shot[0]) + ("-shade" if shot[1] else "")
		for share in ["paint", "full"]:
			looks._metal_arg = 1.0 if share == "full" else -1.0
			mi.visible = false
			await step.call(20)
			var bg := get_viewport().get_texture().get_image()
			# Its own pixels: where it changes the picture while casting no shadow (its shadow on the
			# ground left out); measured with its shadows, on itself too.
			mi.visible = true
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			await step.call(20)
			var shape := get_viewport().get_texture().get_image()
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			await step.call(20)
			var img := get_viewport().get_texture().get_image()
			var r := _screen_rect(cam, mi.get_aabb().grow(0.5), Vector3.ZERO)
			var m := _masked_mean(img, bg, r, shape)
			print("texture metal model %s (%s): mean %s over %d pixels" % [label, share, m.slice(0, 4), int(m[4])])
			if shots != "":
				img.get_region(Rect2i(r.position, r.size).intersection(Rect2i(Vector2i.ZERO, img.get_size()))).save_png(
					shots.path_join("%s_%s.png" % [label, share]))
		mi.queue_free()
	looks._metal_arg = -1.0
	caster.queue_free()


## 0.2.2, in a window only: packs' own shading (pack.json "shading": "pbr", factorio_material's modeller_tex).
## `-- --pack-shading-models=<folder>` (a pbr pack: Vasillo's fixed copy) runs it, `--pack-shading-shots=<dir>`
## saves the pictures. A: each textured material of his drill, a pipe corner and two ores, drawn by Zenith as a
## pbr pack's and by the file's own StandardMaterial3D on the same mesh, with the look's fill 0, metal in full and
## normal maps off on both (both plain PBR): within 5% with packs' own shading, and the old ratio with it off; a
## built-in model and the ground the same either way within a level. B: a quad whose normal map leans one way,
## lit from either side, by Zenith and by Godot's own scene (real tangents): which side is lit agrees. C: the drill,
## the pipe corner, coal and his copper and iron plates in the Factorio look as the game draws them, both ways.


func _pack_shading_look() -> void:
	var dir := ""
	var shots := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--pack-shading-models="):
			dir = arg.get_slice("=", 1)
		elif arg.begins_with("--pack-shading-shots="):
			shots = arg.get_slice("=", 1)
	if DisplayServer.get_name() == "headless" or dir == "":
		print("pack shading look: needs a window and --pack-shading-models=<folder>, skipped")
		return
	if shots != "":
		DirAccess.make_dir_recursive_absolute(shots)
	var SkyScript := preload("res://scripts/world/sky.gd")
	var ItemModels := preload("res://scripts/world/item_models.gd")
	var stage := Node3D.new()
	add_child(stage)
	var env := Environment.new()
	var planet_sky: Node = SkyScript.new()
	stage.add_child(planet_sky)
	planet_sky.set_clouds(false)
	var sky_res := Sky.new()
	sky_res.sky_material = planet_sky.sky_material
	sky_res.radiance_size = Sky.RADIANCE_SIZE_32
	sky_res.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	env.background_mode = Environment.BG_SKY
	env.sky = sky_res
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	stage.add_child(world_env)
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	stage.add_child(sun)
	var looks: Node = LooksScript.new()
	stage.add_child(looks)
	looks.attach(env, sun)
	looks.use("factorio", true)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40, 40)
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.36, 0.27, 0.12)
	ground_mat.roughness = 1.0
	plane.material = ground_mat
	ground.mesh = plane
	stage.add_child(ground)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 7.0
	stage.add_child(cam)
	cam.rotation_degrees = Vector3(-48.0, 0.0, 0.0)
	cam.position = Vector3(0.0, 0.5, 0.0) + cam.basis.z * 20.0
	cam.make_current()
	# What is put over the look each frame: shader globals, and the sun's turn (B). Changed in place, never
	# replaced: the step lambda keeps the dictionary it was made with.
	var over := {}
	var step := func(frames: int) -> void:
		for i in frames:
			planet_sky.apply(env, sun, 0.0, 0.0, 1.0 / 60.0, false)
			looks.apply(0.0, 0.0, "nauvis", false, planet_sky.state)
			for k in over:
				if k == "sun":
					sun.rotation_degrees = over[k]
				else:
					RenderingServer.global_shader_parameter_set(k, over[k])
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
	var hide := ShaderMaterial.new()
	var hide_shader := Shader.new()
	hide_shader.code = "shader_type spatial;\nvoid fragment() {\n\tdiscard;\n}\n"
	hide.shader = hide_shader
	var load_model := func(path: String, modeller: bool, pbr: bool) -> Mesh:
		var ld := ModelLibrary.Load.new()
		ld.path = path
		ld.combine = false
		ld.modeller = modeller
		ld.pbr = pbr
		ld.run()
		return ModelLibrary._commit_load(ld, []) if ld.ok else null
	var base_of := func(sm: Material) -> Material:
		for key in ModelLibrary._factorio_cache:
			if ModelLibrary._factorio_cache[key] == sm and key is Array:
				return (key as Array)[0]
		return null

	# --- A: Zenith's pbr path against Godot's own material, both plain PBR.
	over.clear()
	over.merge({&"f3d_look_model_fill": 0.0, &"f3d_look_texture_metal": 1.0})
	var rows: Array = []
	for name in ["electric-mining-drill", "pipe-corner-up-right", "iron-ore-1", "coal-1"]:
		var mesh: Mesh = load_model.call(dir.path_join(name + ".glb"), true, true)
		if mesh == null:
			print("pack shading look: %s didn't load" % name)
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		stage.add_child(mi)
		for k in mesh.get_surface_count():
			var sm := mesh.surface_get_material(k) as ShaderMaterial
			if sm == null or sm.get_shader_parameter("modeller_tex") != true:
				continue
			var base := base_of.call(sm) as BaseMaterial3D
			if base == null:
				print("pack shading look: %s surface %d: no file material found" % [name, k])
				continue
			var zen := sm.duplicate() as ShaderMaterial
			zen.set_shader_parameter("use_normal_tex", false)
			var std := base.duplicate() as BaseMaterial3D
			std.normal_enabled = false
			std.vertex_color_use_as_albedo = false
			var label := "%s/%s" % [name, base.resource_name if base.resource_name != "" else str(k)]
			var got := {}
			for side in [["pbr", zen, 1.0], ["old", zen, 0.0], ["std", std, 1.0]]:
				over[&"f3d_pack_shading"] = side[2]
				for j in mesh.get_surface_count():
					mi.set_surface_override_material(j, side[1] if j == k else hide)
				got[side[0]] = await _ps_measure(mi, cam, step)
			over[&"f3d_pack_shading"] = 1.0
			var std_l := maxf(float(got["std"][3]), 1e-6)
			var row := [label, float(got["pbr"][3]) / std_l, float(got["old"][3]) / std_l, got["pbr"], got["old"], got["std"]]
			rows.append(row)
			print("pack shading A %s: pbr/std %.3f, old/std %.3f; pbr %s, old %s, std %s" % [label, row[1], row[2],
				got["pbr"].slice(0, 4), got["old"].slice(0, 4), got["std"].slice(0, 4)])
			# Near black (his coal: sRGB 4-8) a level is over 5%: there, within a level per channel.
			var levels := maxf(absf(got["pbr"][0] - got["std"][0]), maxf(absf(got["pbr"][1] - got["std"][1]), absf(got["pbr"][2] - got["std"][2])))
			check(absf(float(row[1]) - 1.0) <= 0.05 or levels <= 1.0,
				"pack shading look: %s drawn as Godot's material draws it, within 5%% or a level (%.3f, %.1f levels)" % [label, row[1], levels])
		mi.queue_free()
		await get_tree().process_frame
	check(not rows.is_empty(), "pack shading look: his models were measured")
	# The built-in model and the ground, either way.
	var chest: Mesh = load_model.call("res://assets/models/packs/wube3dp/steel-chest.glb", false, false)
	var chest_mi := MeshInstance3D.new()
	chest_mi.mesh = chest
	stage.add_child(chest_mi)
	var same := {}
	for on in [1.0, 0.0]:
		over[&"f3d_pack_shading"] = on
		await step.call(20)
		var img := get_viewport().get_texture().get_image()
		same[on] = [_screen_mean(img, cam, _screen_rect(cam, chest_mi.get_aabb(), Vector3.ZERO)),
			_screen_mean(img, cam, _screen_rect(cam, AABB(Vector3(-4.0, 0.0, -4.0), Vector3(8.0, 0.0, 1.5)), Vector3.ZERO))]
	for i in 2:
		var a: Array = same[1.0][i]
		var b: Array = same[0.0][i]
		check(absf(a[0] - b[0]) <= 1.0 and absf(a[1] - b[1]) <= 1.0 and absf(a[2] - b[2]) <= 1.0,
			"pack shading look: the %s draws the same either way within a level (%s, %s)" % [["built-in chest", "ground"][i], a, b])
	chest_mi.queue_free()
	over.clear()

	# --- B: the normal map's direction: a flat quad whose map leans every texel towards +U (east), lit low
	# from the east and from the west; Zenith's frame against Godot's own scene (its real tangents).
	var quad_path := _ps_normal_quad()
	var lit := {}
	for who in ["zen-pbr", "zen-old", "godot"]:
		var node: Node3D
		if who == "godot":
			var doc := GLTFDocument.new()
			var state := GLTFState.new()
			doc.append_from_file(quad_path, state)
			node = doc.generate_scene(state) as Node3D
		else:
			var qm := MeshInstance3D.new()
			qm.mesh = load_model.call(quad_path, true, true)
			node = qm
		stage.add_child(node)
		over.clear()
		over.merge({&"f3d_look_model_fill": 0.0, &"f3d_pack_shading": 0.0 if who == "zen-old" else 1.0})
		var sides := {}
		for from in [["east", Vector3(-25.0, 90.0, 0.0)], ["west", Vector3(-25.0, -90.0, 0.0)]]:
			over["sun"] = from[1]
			await step.call(20)
			var img := get_viewport().get_texture().get_image()
			sides[from[0]] = _screen_mean(img, cam, _screen_rect(cam, AABB(Vector3(-0.8, 0.0, -0.8), Vector3(1.6, 0.0, 1.6)), Vector3(0.0, 0.05, 0.0)))
			if shots != "":
				img.save_png(shots.path_join("normal_%s_%s.png" % [who, from[0]]))
		lit[who] = float(sides["east"][3]) / maxf(float(sides["west"][3]), 1e-6)
		print("pack shading B %s: east/west %.3f (east %s, west %s)" % [who, lit[who], sides["east"], sides["west"]])
		node.queue_free()
		await get_tree().process_frame
	over.clear()
	check((float(lit["godot"]) > 1.0) == (float(lit["zen-pbr"]) > 1.0) and absf(float(lit["zen-pbr"]) / float(lit["godot"]) - 1.0) <= 0.1,
		"pack shading look: the normal map leans the way Godot's own frame leans it (east/west %.3f, Godot's %.3f; old %.3f)"
		% [lit["zen-pbr"], lit["godot"], lit["zen-old"]])

	# --- C: as the game draws them (fill, metal share 0.1), both ways, for the eye. His folder a pack of its own
	# for this, as --models= makes it (pack.json's "shading" read): items look up their pack by their file.
	ModelPacksScript.configure("", [], [], dir, true)
	ModelPacksScript.wait()
	for shot in [["electric-mining-drill", 7.0], ["pipe-corner-up-right", 3.0], ["coal-1", 2.0], ["items/copper-plate", 0.8], ["items/iron-plate", 0.8]]:
		var path := dir.path_join(str(shot[0]) + ".glb")
		var mi := MeshInstance3D.new()
		var std_mi: MeshInstance3D = null
		if str(shot[0]).begins_with("items/"):
			var item := ItemModels.read(path)
			mi.mesh = item
			mi.material_override = ItemModels.material_for(item)
			std_mi = MeshInstance3D.new()
			std_mi.mesh = item
			std_mi.material_override = ItemModels.pbr_material(item)
			std_mi.position = Vector3(0.35, 0.0, 0.0)
			mi.position = Vector3(-0.35, 0.0, 0.0)
			stage.add_child(std_mi)
		else:
			mi.mesh = load_model.call(path, true, true)
		stage.add_child(mi)
		cam.size = float(shot[1])
		var label := str(shot[0]).get_file()
		for mode in [["pbr", 1.0], ["factorio", 0.0]]:
			over.clear()
			over.merge({&"f3d_pack_shading": mode[1]})
			var m := await _ps_measure(mi, cam, step)
			var img := get_viewport().get_texture().get_image()
			var extra := ""
			if std_mi != null:
				extra = ", the file's own material beside it %s" % [_screen_mean(img, cam, _screen_rect(cam, std_mi.get_aabb(), std_mi.position)).slice(0, 4)]
			print("pack shading C %s (%s): %s over %d pixels%s" % [label, mode[0], m.slice(0, 4), int(m[4]), extra])
			if shots != "":
				img.save_png(shots.path_join("%s_%s.png" % [label, mode[0]]))
		mi.queue_free()
		if std_mi != null:
			std_mi.queue_free()
		await get_tree().process_frame
	over.clear()
	cam.size = 7.0
	ModelPacksScript.configure("", [], [])
	looks.apply_pack_shading()
	stage.queue_free()
	await get_tree().process_frame


## Standard PBR, step 1 and on: the reference set (tools/models/make_pbr_reference.py, tests/fixtures/pbr_ref/),
## in two sections, both in a window only, the look pass first so a short window still gives k.
## _pbr_look (the Factorio look as the game has it): a rough metal sphere (roughness 0.7, 1) between 0.9 and 1.1
## of a paint one's brightness, metal's red over blue within 3% of paint's (no sky tint), the k where they meet
## printed ("parity k"), 0.2.2's drawing beside; a built-in chest and the ground the same with the reflection on
## and off. _pbr_reference (strict): each file drawn by Zenith as a "pbr" pack's and by Godot's own import (its
## StandardMaterial3D, with the MikkTSpace tangents glTF asks for) at the same place, the look's fill 0, metal in
## full, the neutral reflection off and lit flat (--pbr-light=flat): the mean within 2% and no block of the picture more than 5% apart, except the
## rows in PBR_REF_DIFFERS. `--pbr-ref-rows=a,b` draws only those rows; `--pbr-ref-shots=<dir>` saves the pictures.
## `--pbr-ref-env=sky`: the strict pass under the lighting environment in the sky's cubemap (lighting-fixes step 1), both
## sides then lit by it; without, as 0.2.2 (--light-env=shader).


const PBR_REF_DIR := "res://tests/fixtures/pbr_ref/"
## Rows known to differ from Godot's own drawing, and why; fixing one means taking its line out.


const PBR_REF_DIFFERS := {
	"occ_packed_s05": "occlusion strength not read (Godot neither)",
	"occ_separate_s05": "occlusion strength not read (Godot neither)",
	"occ_uv1": "occlusion on a second UV set read from the first",
	"uv_transform": "texture transform not passed on",
	"tube_double": "doubleSided ignored (back faces culled)",
	"vertex_colors": "COLOR_0 ignored on buildings",
	"emit_": "glow only while the machine works",
	"clamp": "always repeat",
}


func _pbr_ref_differs(name: String) -> String:
	for k: String in PBR_REF_DIFFERS:
		if name == k or (k.ends_with("_") and name.begins_with(k)):
			return PBR_REF_DIFFERS[k]
	return ""


## The value of `--<key>=` among the test's arguments, or "".


func _pbr_arg(key: String) -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--%s=" % key):
			return arg.get_slice("=", 1)
	return ""


## A reference file as Godot's own import draws it: its first mesh, with its StandardMaterial3D. Godot's
## runtime glTF reader gives a file without TANGENT no real tangents (every vertex gets the same fallback,
## -X on an upward face), so a normal map leant the same way whichever way its UVs ran: the strict pass's
## normal_east was Godot's drawing wrong, not Zenith's. glTF asks for MikkTSpace tangents then, as Godot's
## editor import makes them: SurfaceTool.generate_tangents.


func _pbr_godot_mesh(name: String) -> Mesh:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	doc.append_from_file(ProjectSettings.globalize_path(PBR_REF_DIR + name + ".glb"), state)
	var root := doc.generate_scene(state)
	var found := root.find_children("*", "MeshInstance3D", true, false)
	var src: Mesh = (found[0] as MeshInstance3D).mesh if not found.is_empty() else null
	root.free()
	if src == null:
		return null
	var out := ArrayMesh.new()
	for i in src.get_surface_count():
		var st := SurfaceTool.new()
		st.create_from(src, i)
		st.generate_tangents()
		st.commit(out)
		out.surface_set_material(i, src.surface_get_material(i))
	return out


## A reference file as a "pbr" pack's model.


func _pbr_zenith_mesh(name: String) -> Mesh:
	var ld := ModelLibrary.Load.new()
	ld.path = ProjectSettings.globalize_path(PBR_REF_DIR + name + ".glb")
	ld.combine = false
	ld.modeller = true
	ld.pbr = true
	ld.run()
	return ModelLibrary._commit_load(ld, []) if ld.ok else null


## The reference stage: the planet's sky (no clouds), the Factorio look at Nauvis noon, a ground plane and the
## game's camera angle, after PR_WARM frames (the sky's radiance, the shadows). {stage, env, sun, cam, over (globals
## set after the look each frame), step (frames), t0 (ms), f0 (frames drawn)}.
## The stage under look `look_id` at `daytime` (0 noon). A look other than Factorio's gets its sun as main.gd gives it
## (its twilight and noon sun: sky.gd's sun model). {..., looks, sky} too. Lit as 0.2.2 (--light-env=shader:
## these sections measure the "pbr" packs' own terms) unless `sky_env`.


func _pbr_stage(look_id := "factorio", sky_env := false, daytime := 0.0) -> Dictionary:
	var SkyScript := preload("res://scripts/world/sky.gd")
	var stage := Node3D.new()
	add_child(stage)
	var env := Environment.new()
	var planet_sky: Node = SkyScript.new()
	stage.add_child(planet_sky)
	planet_sky.set_clouds(false)
	var sky_res := Sky.new()
	sky_res.sky_material = planet_sky.sky_material
	sky_res.radiance_size = Sky.RADIANCE_SIZE_32
	sky_res.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	env.background_mode = Environment.BG_SKY
	env.sky = sky_res
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	stage.add_child(world_env)
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	stage.add_child(sun)
	var looks: Node = LooksScript.new()
	stage.add_child(looks)
	looks._light_env_sky = sky_env
	looks.attach(env, sun)
	looks.use(look_id, true)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40, 40)
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.36, 0.27, 0.12)
	ground_mat.roughness = 1.0
	plane.material = ground_mat
	ground.mesh = plane
	ground.layers = Visuals.GROUND_LAYER  # as the game's ground: the look's fill light leaves it
	stage.add_child(ground)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 1.4
	stage.add_child(cam)
	cam.rotation_degrees = Vector3(-48.0, 0.0, 0.0)
	cam.position = Vector3(0.0, 0.4, 0.0) + cam.basis.z * 20.0
	cam.make_current()
	var over := {}
	var step := func(frames: int) -> void:
		for i in frames:
			if look_id != "factorio":
				planet_sky.twilight = looks.twilight()
				planet_sky.sky_twilight = looks.sky_twilight()
				planet_sky.noon_yaw = looks.noon_yaw(SkyScript.YAW_NOON)
			planet_sky.apply(env, sun, daytime, 0.0, 1.0 / 60.0, false)
			looks.apply(daytime, 0.0, "nauvis", false, planet_sky.state)
			for k in over:
				RenderingServer.global_shader_parameter_set(k, over[k])
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
	await step.call(PR_WARM)
	return {"stage": stage, "env": env, "sun": sun, "cam": cam, "over": over, "step": step,
		"t0": Time.get_ticks_msec(), "f0": Engine.get_frames_drawn(), "looks": looks, "sky": planet_sky}


## How long the pass took, and its frame rate (the first window pass ran about 4.5 frames a second).


func _pbr_took(s: Dictionary) -> String:
	var secs := (Time.get_ticks_msec() - int(s["t0"])) / 1000.0
	return "%.0f s, %.1f frames a second" % [secs, (Engine.get_frames_drawn() - int(s["f0"])) / maxf(secs, 0.001)]


func _pbr_stage_end(s: Dictionary) -> void:
	(s["over"] as Dictionary).clear()
	(s["stage"] as Node).queue_free()
	await get_tree().process_frame


func _pbr_shots() -> String:
	var shots := _pbr_arg("pbr-ref-shots")
	if shots != "":
		DirAccess.make_dir_recursive_absolute(shots)
	return shots


## Strict pass. Headless it checks only that Godot's side has its tangents (the frame normal_east is read in).


func _pbr_reference() -> void:
	var east := _pbr_godot_mesh("normal_east")
	var mirrored := _pbr_godot_mesh("normal_mirrored")
	var te: PackedFloat32Array = east.surface_get_arrays(0)[Mesh.ARRAY_TANGENT] if east != null else PackedFloat32Array()
	var tm: PackedFloat32Array = mirrored.surface_get_arrays(0)[Mesh.ARRAY_TANGENT] if mirrored != null else PackedFloat32Array()
	check(te.size() >= 4 and te[0] > 0.99 and tm.size() >= 4 and tm[0] < -0.99 and tm[3] < 0.0,
		"pbr reference: Godot's side has MikkTSpace tangents, +U east on normal_east, west (mirrored) on normal_mirrored (%s, %s)"
		% [te.slice(0, 4), tm.slice(0, 4)])
	# The measure on made-up pictures: a 40 x 40 square (sRGB 188, 94, 47) over a black ground, its top-left
	# quarter of the rectangle the square alone; the rest of the rectangle ground (left out, no difference).
	var bg := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	bg.fill(Color.BLACK)
	var shape := bg.duplicate() as Image
	shape.fill_rect(Rect2i(0, 0, 40, 40), Color.WHITE)
	var img := bg.duplicate() as Image
	img.fill_rect(Rect2i(0, 0, 40, 40), Color8(188, 94, 47))
	var m := _pr_blocks(img, bg, shape, Rect2(0, 0, 64, 64))
	var lin := Color8(188, 94, 47).srgb_to_linear()
	var want := 0.2126 * lin.r + 0.7152 * lin.g + 0.0722 * lin.b
	var bl: Array = m[1]
	check(m[0][0] == 188.0 and m[0][1] == 94.0 and m[0][2] == 47.0 and absf(float(m[0][3]) - want) < 0.0002
		and int(m[0][4]) == 400 and absf(float(bl[0]) - want) < 0.0002 and float(bl[3]) == -1.0 and float(bl[15]) == -1.0,
		"pbr reference: the measure reads a made-up picture (%s, blocks %s; luminance %.4f)" % [m[0], bl.slice(0, 4), want])
	if DisplayServer.get_name() == "headless":
		print("pbr reference: needs a window, skipped")
		return
	var shots := _pbr_shots()
	var s: Dictionary = await _pbr_stage("factorio", _pbr_arg("pbr-ref-env") == "sky")
	var stage: Node3D = s["stage"]
	var cam: Camera3D = s["cam"]
	var over: Dictionary = s["over"]
	var step: Callable = s["step"]
	# Metal in full and the fill off on Zenith's side, the neutral reflection off (the sky reflected, as Godot's).
	var strict := {&"f3d_look_model_fill": 0.0, &"f3d_look_texture_metal": 1.0, &"f3d_look_pbr_metal": 1.0,
		&"f3d_pbr_env": Vector4(0.0, 0.0, 0.0, 0.0), &"f3d_pbr_light": PBR_LIGHT_FLAT}
	var rows := _pbr_arg("pbr-ref-rows").split(",", false)
	var names: Array = []
	for f in DirAccess.get_files_at(PBR_REF_DIR):
		if f.ends_with(".glb") and (rows.is_empty() or rows.has(f.get_basename())):
			names.append(f.get_basename())
	names.sort()
	check(rows.is_empty() or names.size() == rows.size(), "pbr reference: every row asked for is a file (%s)" % [rows])
	var passed := 0
	var known := 0
	print("pbr reference strict: name, zenith/godot mean, worst block, zenith, godot")
	for name: String in names:
		var got := {}
		for side in [["zenith", _pbr_zenith_mesh(name)], ["godot", _pbr_godot_mesh(name)]]:
			var mi := MeshInstance3D.new()
			mi.mesh = side[1]
			stage.add_child(mi)
			over.clear()
			over.merge(strict)
			got[side[0]] = await _pr_measure(mi, cam, step)
			if shots != "":
				get_viewport().get_texture().get_image().save_png(shots.path_join("strict_%s_%s.png" % [name, side[0]]))
			mi.queue_free()
			await get_tree().process_frame
		var z: Array = got["zenith"]
		var g: Array = got["godot"]
		var ratio := float(z[0][3]) / maxf(float(g[0][3]), 1e-6)
		var worst := 0.0
		for i in mini((z[1] as Array).size(), (g[1] as Array).size()):
			var a := float(z[1][i])
			var b := float(g[1][i])
			if a >= 0.0 and b >= 0.0:
				worst = maxf(worst, absf(a / maxf(b, 1e-6) - 1.0))
		var ok := absf(ratio - 1.0) <= 0.02 and worst <= 0.05
		var why := _pbr_ref_differs(name)
		print("pbr reference strict %s: %.3f, %.3f%s; %s, %s" % [name, ratio, worst,
			("" if why == "" else " (expected difference: %s, %s)" % [why, "still differs" if not ok else "now matches"]),
			(z[0] as Array).slice(0, 5), (g[0] as Array).slice(0, 5)])
		if why == "":
			check(ok, "pbr reference: %s drawn as Godot's own material draws it (mean %.3f, worst block %.3f)" % [name, ratio, worst])
			passed += 1 if ok else 0
		else:
			known += 1
	print("pbr reference strict: %d of %d as Godot draws them, %d expected differences, %s"
		% [passed, names.size() - known, known, _pbr_took(s)])
	await _pbr_stage_end(s)


## Look pass: the Factorio look as the game draws it, then as 0.2.2 drew it (--pbr-env=off --pbr-metal=0.1
## --pbr-light=flat), then the metal sphere at other k (the sun's share in the reflection) to find where metal meets paint.


func _pbr_look() -> void:
	if DisplayServer.get_name() == "headless":
		print("pbr look: needs a window, skipped")
		return
	var shots := _pbr_shots()
	var s: Dictionary = await _pbr_stage()
	# The parity k was fitted with 0.2.2's sun highlight (0.25; 0.5 since lighting-fixes step 4): pinned for this fallback.
	s["looks"]._sun_specular_arg = 0.25
	var stage: Node3D = s["stage"]
	var cam: Camera3D = s["cam"]
	var env: Environment = s["env"]
	var sun: DirectionalLight3D = s["sun"]
	var over: Dictionary = s["over"]
	var step: Callable = s["step"]
	var amb := env.ambient_light_color.srgb_to_linear() * env.ambient_light_energy
	var sun_lin := sun.light_color.srgb_to_linear() * sun.light_energy
	var env_at := func(k: float) -> Vector4:
		return Vector4(amb.r + sun_lin.r * k, amb.g + sun_lin.g * k, amb.b + sun_lin.b * k, 1.0)
	var parity := {}
	for r in ["070", "100", "050", "030", "010"]:
		var look := {}
		for c in [["m0", {}], ["m1", {}], ["m1old", {&"f3d_pbr_env": Vector4(0.0, 0.0, 0.0, 0.0), &"f3d_look_pbr_metal": 0.1, &"f3d_pbr_light": PBR_LIGHT_FLAT}],
				["m1sky", {&"f3d_pbr_env": Vector4(0.0, 0.0, 0.0, 0.0)}]]:
			var mi := MeshInstance3D.new()
			mi.mesh = _pbr_zenith_mesh("picture_%s_r%s" % [str(c[0]).substr(0, 2), r])
			stage.add_child(mi)
			over.clear()
			over.merge(c[1])
			look[c[0]] = await _pr_measure(mi, cam, step)
			if shots != "":
				get_viewport().get_texture().get_image().save_png(shots.path_join("look_%s_r%s.png" % [c[0], r]))
			if c[0] == "m1" and (r == "070" or r == "100"):
				# Metal over paint at k 0 to 1: the k where they meet.
				var paint_l := maxf(float(look["m0"][0][3]), 1e-6)
				var sweep: Array = []
				for k in [0.0, 0.25, 0.5, 0.75, 1.0]:
					over.clear()
					over[&"f3d_pbr_env"] = env_at.call(k)
					sweep.append([k, float((await _pr_measure(mi, cam, step))[0][3]) / paint_l])
				var meet := -1.0
				for i in sweep.size() - 1:
					var a: Array = sweep[i]
					var b: Array = sweep[i + 1]
					if float(a[1]) <= 1.0 and float(b[1]) >= 1.0:
						meet = lerpf(float(a[0]), float(b[0]), (1.0 - float(a[1])) / maxf(float(b[1]) - float(a[1]), 1e-6))
				parity[r] = meet
				print("pbr reference look r%s: metal/paint by k %s, parity at k %.3f (default %.2f)" % [r, sweep, meet, LooksScript.PBR_ENV])
			mi.queue_free()
			await get_tree().process_frame
		var paint: Array = look["m0"][0]
		var metal: Array = look["m1"][0]
		var old: Array = look["m1old"][0]
		var sky: Array = look["m1sky"][0]
		var ratio := float(metal[3]) / maxf(float(paint[3]), 1e-6)
		var tint := (float(metal[0]) / maxf(float(metal[2]), 1e-6)) / maxf(float(paint[0]) / maxf(float(paint[2]), 1e-6), 1e-6)
		print("pbr reference look r%s: metal/paint %.3f (0.2.2's %.3f, in full reflecting the sky %.3f), metal's red/blue over paint's %.3f; metal %s, 0.2.2's %s, the sky's %s, paint %s"
			% [r, ratio, float(old[3]) / maxf(float(paint[3]), 1e-6), float(sky[3]) / maxf(float(paint[3]), 1e-6), tint,
			metal.slice(0, 4), old.slice(0, 4), sky.slice(0, 4), paint.slice(0, 4)])
		if r == "100":
			# The two rough rows are done: k is known even if the window closes now.
			print("pbr reference look: parity k %s (default %.2f)" % [parity, LooksScript.PBR_ENV])
		if r == "070" or r == "100":
			check(ratio >= 0.9 and ratio <= 1.1, "pbr reference look: rough metal (r %s) about as bright as paint (%.3f)" % [r, ratio])
		check(absf(tint - 1.0) <= 0.03, "pbr reference look: grey metal (r %s) reflects no colour paint doesn't get (red/blue %.3f of paint's)" % [r, tint])
	# A built-in model and the ground, the neutral reflection on and off: the same (built-in packs never write it).
	var chest := MeshInstance3D.new()
	var chest_ld := ModelLibrary.Load.new()
	chest_ld.path = "res://assets/models/packs/wube3dp/steel-chest.glb"
	chest_ld.combine = false
	chest_ld.run()
	chest.mesh = ModelLibrary._commit_load(chest_ld, []) if chest_ld.ok else null
	stage.add_child(chest)
	cam.size = 3.0
	var same := {}
	for on in [1.0, 0.0]:
		over.clear()
		over[&"f3d_pbr_env"] = env_at.call(LooksScript.PBR_ENV) * Vector4(1, 1, 1, on)
		await step.call(PR_FRAMES)
		var img := get_viewport().get_texture().get_image()
		same[on] = [_screen_mean(img, cam, _screen_rect(cam, chest.get_aabb(), Vector3.ZERO)),
			_screen_mean(img, cam, _screen_rect(cam, AABB(Vector3(-1.4, 0.0, 0.6), Vector3(2.8, 0.0, 0.6)), Vector3.ZERO))]
	for i in 2:
		var a: Array = same[1.0][i]
		var b: Array = same[0.0][i]
		check(absf(a[0] - b[0]) <= 1.0 and absf(a[1] - b[1]) <= 1.0 and absf(a[2] - b[2]) <= 1.0,
			"pbr reference look: the %s draws the same with the neutral reflection on and off within a level (%s, %s)" % [["built-in chest", "ground"][i], a, b])
	chest.queue_free()
	print("pbr reference look: parity k %s (default %.2f), %s" % [parity, LooksScript.PBR_ENV, _pbr_took(s)])
	await _pbr_stage_end(s)


## pbr-light-balance: a "pbr" pack lit by direction (looks.gd pbr_fill / pbr_ambient, shaders/pbr_env.gdshaderinc),
## in a window only. Each model's lit and shaded pixels are told apart by a picture with the sun's light alone (lit:
## at least half the sun of the model's 90th percentile; shade: under 3% of it), then its lit-to-shaded ratio
## (linear luminance as the screen shows it) is read flat (--pbr-light=flat, 0.2.2's), by direction at the defaults
## and at other shares. Matte and rough metal reference spheres always; the modeller's rock and drill from
## `--pbr-light-models=<folder>` (iron-ore-1, electric-mining-drill); `--pbr-light-shots=<dir>` saves the pictures
## (and a field of his rocks). Checked: the matte sphere's ratio by direction within PBR_LIGHT_RATIO (flat about 2.4),
## a built-in chest and the ground the same flat and by direction.


const PBR_LIGHT_RATIO := Vector2(3.0, 6.0)


const PBR_LIGHT_FLAT := Vector4(0.0, 1.0, 1.0, 1.0)


func _pbr_light() -> void:
	if DisplayServer.get_name() == "headless":
		print("pbr light: needs a window, skipped")
		return
	await _pbr_light_under("factorio", "")
	if _pbr_arg("pbr-light-look") == "cinematic":
		await _pbr_light_cinematic()


## cinematic-pbr-flat: the same measures under the Cinematic shaders add-on's look (addons-src), its noon sun from the
## north-west (0.5.1) and, "before", high behind the view (sun_side off), at `--pbr-light-daytime=<d>` (default 0,
## noon). Its clouds and grain are off for the measure (they move about the picture); the rest as it draws.
## Checked: the matte sphere's lit-to-shaded ratio under it at least PBR_LIGHT_CINEMATIC, and above before's.


const PBR_LIGHT_CINEMATIC := 2.5


func _pbr_light_cinematic() -> void:
	var src := ProjectSettings.globalize_path("res://").path_join("../addons-src/cinematic-shaders").simplify_path()
	var holder := Node.new()
	add_child(holder)
	var look_before = Settings.get_value("graphics", "look")
	var on_before = Settings.get_value("addons", "cinematic-shaders")
	Settings.set_value("addons", "cinematic-shaders", true)
	var host := AddonHostScript.new()
	host.autoload = false
	host.main = holder
	holder.add_child(host)
	host.load_all([[src.get_base_dir(), "test"]])
	await get_tree().process_frame
	var node: Node = host.find("cinematic-shaders").get("node")
	if node == null:
		check(false, "pbr light cinematic: the add-on starts from " + src)
		holder.queue_free()
		return
	var keep := {}
	for k in ["clouds", "grain", "sun_side"]:
		keep[k] = node.api.settings.value(k)
	node.api.settings.set_value("clouds", 0.0, false)
	node.api.settings.set_value("grain", 0.0, false)
	var day := _pbr_arg("pbr-light-daytime")
	var daytime := day.to_float() if day.is_valid_float() else 0.0
	var got := {}
	for side in [true, false]:
		node.api.settings.set_value("sun_side", side, false)
		got[side] = await _pbr_light_under(str(node.LOOK), "cinematic" if side else "cinematic before", daytime)
	var now: Dictionary = got[true].get("sphere matte", {})
	var before: Dictionary = got[false].get("sphere matte", {})
	if not now.is_empty() and not before.is_empty():
		var a := float(now["look"][0])
		var b := float(before["look"][0])
		check(a >= PBR_LIGHT_CINEMATIC and a > b, "pbr light cinematic: a matte sphere's sun side and shade %.2f:1 at daytime %.2f (wanted %.1f or more), %.2f:1 before"
			% [a, daytime, PBR_LIGHT_CINEMATIC, b])
	for k in keep:
		node.api.settings.set_value(k, keep[k], false)
	host.stop(host.find("cinematic-shaders"))
	Settings.set_value("addons", "cinematic-shaders", on_before)
	Settings.set_value("graphics", "look", look_before)
	holder.queue_free()
	await get_tree().process_frame


## _pbr_light's measures under look `look_id` (`tag` names it in the lines and shots; "" the Factorio look, which
## alone is checked here): each model's ratios by config, by model name.


func _pbr_light_under(look_id: String, tag: String, daytime := 0.0) -> Dictionary:
	var shots := _pbr_arg("pbr-light-shots")
	if shots != "":
		DirAccess.make_dir_recursive_absolute(shots)
	var say := "" if tag == "" else " " + tag
	var pre := "" if tag == "" else tag.replace(" ", "_") + "_"
	var s: Dictionary = await _pbr_stage(look_id, false, daytime)
	var stage: Node3D = s["stage"]
	var cam: Camera3D = s["cam"]
	var over: Dictionary = s["over"]
	var step: Callable = s["step"]
	var dir_default := Vector4(1.0, LooksScript.PBR_FILL, LooksScript.PBR_AMBIENT, 1.0)
	var configs := [["flat", {&"f3d_pbr_light": PBR_LIGHT_FLAT}], ["directional", {&"f3d_pbr_light": dir_default}], ["look", {}]]
	for f in [0.15, 0.3, 0.45]:
		for a in [0.7, 1.0, 1.5]:
			configs.append(["fill %.2f ambient %.2f" % [f, a], {&"f3d_pbr_light": Vector4(1.0, f, a, 1.0)}])
	var models: Array = [["sphere matte", PBR_REF_DIR + "picture_m0_r070.glb", 1.4], ["sphere metal", PBR_REF_DIR + "picture_m1_r070.glb", 1.4]]
	var dir := _pbr_arg("pbr-light-models")
	if dir != "":
		models.append(["iron-ore-1", dir.path_join("iron-ore-1.glb"), 1.6])
		models.append(["stone-1", dir.path_join("stone-1.glb"), 1.6])
		models.append(["electric-mining-drill", dir.path_join("electric-mining-drill.glb"), 4.2])
	var ratios := {}
	for m: Array in models:
		var node := _pbr_light_model(str(m[1]))
		if node == null:
			check(false, "pbr light: %s loads" % m[1])
			continue
		stage.add_child(node)
		cam.size = float(m[2])
		var got := await _pbr_light_measure(node, cam, step, over, configs, shots, pre + str(m[0]).replace(" ", "_"))
		ratios[m[0]] = got
		for c: Array in configs:
			var r: Array = got[c[0]]
			print("pbr light%s %s %s: lit/shaded %.2f (lit %.4f, shaded %.4f, all %.4f; %d lit, %d shaded pixels)"
				% [say, m[0], c[0], r[0], r[1], r[2], r[3], r[4], r[5]])
		node.queue_free()
		await get_tree().process_frame
	var matte: Dictionary = ratios.get("sphere matte", {})
	if tag != "":
		if dir != "" and shots != "":
			await _pbr_light_field(dir, stage, cam, step, over, shots, pre)
		print("pbr light%s: %s" % [say, _pbr_took(s)])
		await _pbr_stage_end(s)
		return ratios
	if not matte.is_empty():
		var flat := float(matte["flat"][0])
		var lit := float(matte["directional"][0])
		check(lit >= PBR_LIGHT_RATIO.x and lit <= PBR_LIGHT_RATIO.y and lit > flat * 1.3,
			"pbr light: a matte sphere's sun side and shade %.2f:1 by direction (wanted %.1f-%.1f), %.2f:1 flat" % [lit, PBR_LIGHT_RATIO.x, PBR_LIGHT_RATIO.y, flat])
	if dir != "" and shots != "":
		await _pbr_light_field(dir, stage, cam, step, over, shots)
	# A built-in model and the ground: the same flat and by direction (only "pbr" packs' surfaces take it).
	var chest := _pbr_light_model("res://assets/models/packs/wube3dp/steel-chest.glb", false)
	stage.add_child(chest)
	cam.size = 3.0
	var same := {}
	for c in [PBR_LIGHT_FLAT, dir_default]:
		over.clear()
		over[&"f3d_pbr_light"] = c
		await step.call(PR_FRAMES)
		var img := get_viewport().get_texture().get_image()
		same[c.x] = [_screen_mean(img, cam, _screen_rect(cam, AABB(Vector3(-0.5, 0.0, -0.5), Vector3(1.0, 1.0, 1.0)), Vector3.ZERO)),
			_screen_mean(img, cam, _screen_rect(cam, AABB(Vector3(-1.4, 0.0, 0.6), Vector3(2.8, 0.0, 0.6)), Vector3.ZERO))]
	for i in 2:
		var a: Array = same[0.0][i]
		var b: Array = same[1.0][i]
		check(absf(a[0] - b[0]) <= 1.0 and absf(a[1] - b[1]) <= 1.0 and absf(a[2] - b[2]) <= 1.0,
			"pbr light: the %s draws the same flat and by direction within a level (%s, %s)" % [["built-in chest", "ground"][i], a, b])
	chest.queue_free()
	print("pbr light: %s" % _pbr_took(s))
	await _pbr_stage_end(s)
	return ratios


## lighting-fixes (steps 4, 1, 2), in a window only: under the Factorio look and Cinematic (the add-on, from addons-src;
## its clouds and grain off), "before" (0.2.2: --light-env=shader, its ambient, the roughness floor on "pbr" packs, the
## sun's highlight 0.25 / 0.6) and "after" (the lighting environment in the sky's cubemap, the look's lit ambient, the
## packs' own roughness, the highlight 0.5 / 1.0), at noon: flat ground's lit-to-shadow ratio (a box casting only its
## shadow on the stage's ground) and its lit colour; lit-to-shaded on the matte and metal spheres, a built-in assembler and,
## from `--light-env-models=<folder>`, the modeller's rock and drill; rough metal over paint (r 0.7, 1.0); the GPU's
## time a frame before and after (the cubemap 32 then 64). `--light-env-shots=<dir>` saves his ore field, his drill, the
## assembler and trees under each. Checked: the Factorio look's flat ground LIGHT_ENV_RATIO after, and Cinematic's
## sun-to-ambient on flat ground (scene light) LIGHT_ENV_CINEMATIC.


const LIGHT_ENV_RATIO := Vector2(3.8, 5.5)


const LIGHT_ENV_CINEMATIC := Vector2(5.0, 7.0)


func _light_env_window() -> void:
	if DisplayServer.get_name() == "headless":
		print("light env: needs a window, skipped")
		return
	var shots := _pbr_arg("light-env-shots")
	if shots != "":
		DirAccess.make_dir_recursive_absolute(shots)
	var dir := _pbr_arg("light-env-models")
	var looks_to := [["factorio", "factorio"]]
	var src := ProjectSettings.globalize_path("res://").path_join("../addons-src/cinematic-shaders").simplify_path()
	var holder := Node.new()
	add_child(holder)
	var host: Node = null
	var cin: Node = null
	var on_before = Settings.get_value("addons", "cinematic-shaders")
	var look_before = Settings.get_value("graphics", "look")
	if DirAccess.dir_exists_absolute(src):
		Settings.set_value("addons", "cinematic-shaders", true)
		host = AddonHostScript.new()
		host.autoload = false
		host.main = holder
		holder.add_child(host)
		host.load_all([[src.get_base_dir(), "test"]])
		await get_tree().process_frame
		cin = host.find("cinematic-shaders").get("node")
	if cin != null:
		cin.api.settings.set_value("clouds", 0.0, false)
		cin.api.settings.set_value("grain", 0.0, false)
		looks_to.append([str(cin.LOOK), "cinematic"])
	else:
		check(false, "light env: the Cinematic add-on starts from " + src)
	for lt: Array in looks_to:
		await _light_env_look(str(lt[0]), str(lt[1]), dir, shots)
	if host != null:
		host.stop(host.find("cinematic-shaders"))
	Settings.set_value("addons", "cinematic-shaders", on_before)
	Settings.set_value("graphics", "look", look_before)
	holder.queue_free()
	await get_tree().process_frame


## _light_env_window's measures under one look, before and after.


func _light_env_look(look_id: String, tag: String, dir: String, shots: String) -> void:
	var s: Dictionary = await _pbr_stage(look_id, true)
	var stage: Node3D = s["stage"]
	var cam: Camera3D = s["cam"]
	var env: Environment = s["env"]
	var sun: DirectionalLight3D = s["sun"]
	var over: Dictionary = s["over"]
	var step: Callable = s["step"]
	var looks: Node = s["looks"]
	var old_spec := 0.25 if look_id == "factorio" else 0.6
	var models: Array = [["sphere matte", PBR_REF_DIR + "picture_m0_r070.glb", 1.4, true],
		["sphere metal", PBR_REF_DIR + "picture_m1_r070.glb", 1.4, true],
		["assembler (built-in)", "res://assets/models/packs/wube3dp/assembling-machine-1.glb", 4.2, false]]
	if dir != "":
		models.append(["iron-ore-1", dir.path_join("iron-ore-1.glb"), 1.6, true])
		models.append(["electric-mining-drill", dir.path_join("electric-mining-drill.glb"), 4.2, true])
	var got := {}
	# lighting-fixes step 3: the Factorio look also without its fill light (nofill) and with a stronger one (fill0.5).
	var modes := ["before", "nofill", "after", "fill0.5"] if look_id == "factorio" else ["before", "after"]
	for mode: String in modes:
		var after := mode != "before"
		looks._fill_light_arg = 0.0 if mode == "before" or mode == "nofill" else (0.5 if mode == "fill0.5" else -1.0)
		looks._light_env_sky = after
		looks._pbr_rough_floor = not after
		looks._sun_specular_arg = -1.0 if after else old_spec
		env.sky.radiance_size = LooksScript.LIGHT_ENV_RADIANCE if after else Sky.RADIANCE_SIZE_32
		# The look put on again: its own sun highlight back once --sun-specular's stand-in is cleared.
		looks.use(look_id, true)
		over.clear()
		await step.call(PR_WARM)
		var row := {}
		# Flat ground in and out of a box's shadow (the box itself not drawn).
		var box := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.6, 2.5, 0.6)
		box.mesh = bm
		box.position = Vector3(0.0, 1.25, 0.0)
		box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		stage.add_child(box)
		cam.size = 4.0
		var g: Array = await _light_env_ratio(null, AABB(Vector3(-2.0, 0.0, -1.2), Vector3(4.0, 0.01, 2.4)), cam, step, looks, over)
		row["ground"] = g
		box.queue_free()
		var amb := env.ambient_light_color.srgb_to_linear() * env.ambient_light_energy
		var to_sun := sun.global_transform.basis.z.normalized()
		var sun_flat := sun.light_color.srgb_to_linear() * sun.light_energy * maxf(to_sun.y, 0.0)
		var scene_ratio := (sun_flat.get_luminance() + amb.get_luminance()) / maxf(amb.get_luminance(), 1e-6)
		row["scene"] = scene_ratio
		print("light env %s %s: flat ground lit/shadow %.2f on screen (lit %.4f, shadow %.4f; lit colour %s; %d, %d pixels), scene light %.2f (sun %.3f on flat ground, ambient %.3f), sun highlight %.2f, env %s"
			% [tag, mode, g[0], g[1], g[2], g[6], g[4], g[5], scene_ratio, sun_flat.get_luminance(), amb.get_luminance(), sun.light_specular, looks.env_put])
		for m: Array in models:
			var node := _pbr_light_model(str(m[1]), bool(m[3]))
			if node == null:
				check(false, "light env: %s loads" % m[1])
				continue
			stage.add_child(node)
			cam.size = float(m[2])
			var r: Array = await _light_env_ratio(node, AABB(), cam, step, looks, over)
			row[m[0]] = r
			print("light env %s %s %s: lit/shaded %.2f (lit %.4f, shaded %.4f, all %.4f; %d lit, %d shaded pixels)" % [tag, mode, m[0], r[0], r[1], r[2], r[3], r[4], r[5]])
			if shots != "" and (str(m[0]).begins_with("assembler") or str(m[0]) == "electric-mining-drill"):
				await step.call(PR_FRAMES)
				get_viewport().get_texture().get_image().save_png(shots.path_join("%s_%s_%s.png" % [tag, mode, str(m[0]).get_slice(" ", 0)]))
			node.queue_free()
			await get_tree().process_frame
		# Rough metal over paint.
		for rr in ["070", "100"]:
			var lum := {}
			for c in ["m0", "m1"]:
				var mi := MeshInstance3D.new()
				mi.mesh = _pbr_zenith_mesh("picture_%s_r%s" % [c, rr])
				stage.add_child(mi)
				cam.size = 1.4
				lum[c] = float((await _pr_measure(mi, cam, step))[0][3])
				mi.queue_free()
				await get_tree().process_frame
			row["metal/paint r" + rr] = float(lum["m1"]) / maxf(float(lum["m0"]), 1e-6)
			print("light env %s %s: rough metal (r %s) over paint %.3f" % [tag, mode, rr, row["metal/paint r" + rr]])
		if shots != "":
			await _light_env_shots(dir, stage, cam, step, shots, "%s_%s" % [tag, mode])
		# The GPU's time a frame on this stage (the sky's cubemap updated a little each frame, as in the game).
		var vp := get_viewport().get_viewport_rid()
		RenderingServer.viewport_set_measure_render_time(vp, true)
		cam.size = 4.0
		await step.call(PR_FRAMES * 2)
		var gpu := 0.0
		for i in 60:
			await get_tree().process_frame
			gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		row["gpu"] = gpu / 60.0
		print("light env %s %s: GPU %.3f ms a frame (cubemap %d), fill light %.2f" % [tag, mode, row["gpu"], [32, 64, 128, 256, 512, 1024, 2048][env.sky.radiance_size], looks.fill_light_put])
		got[mode] = row
	var a: Dictionary = got["after"]
	var b: Dictionary = got["before"]
	if got.has("nofill"):
		var nf: Dictionary = got["nofill"]
		var f5: Dictionary = got["fill0.5"]
		check(absf(float(a["ground"][1]) / maxf(float(nf["ground"][1]), 1e-6) - 1.0) < 0.03
			and absf(float(a["ground"][2]) / maxf(float(nf["ground"][2]), 1e-6) - 1.0) < 0.03,
			"light env %s: the fill light leaves the ground (lit %.4f / %.4f, shadow %.4f / %.4f with and without)"
			% [tag, a["ground"][1], nf["ground"][1], a["ground"][2], nf["ground"][2]])
		for k in ["assembler (built-in)", "electric-mining-drill", "iron-ore-1", "sphere matte", "sphere metal"]:
			if a.has(k) and nf.has(k) and f5.has(k):
				print("light env %s %s: lit/shaded %.2f without the fill, %.2f with (shaded %.4f -> %.4f), %.2f with 0.5; ground %.2f"
					% [tag, k, nf[k][0], a[k][0], nf[k][2], a[k][2], f5[k][0], a["ground"][0]])
	if look_id == "factorio":
		check(float(a["ground"][0]) >= LIGHT_ENV_RATIO.x and float(a["ground"][0]) <= LIGHT_ENV_RATIO.y,
			"light env %s: flat ground lit/shadow %.2f:1 (wanted %.1f-%.1f; before %.2f)" % [tag, a["ground"][0], LIGHT_ENV_RATIO.x, LIGHT_ENV_RATIO.y, b["ground"][0]])
	else:
		check(float(a["scene"]) >= LIGHT_ENV_CINEMATIC.x and float(a["scene"]) <= LIGHT_ENV_CINEMATIC.y,
			"light env %s: sun to ambient on flat ground %.2f:1 in scene light (wanted %.1f-%.1f; before %.2f), %.2f on screen"
			% [tag, a["scene"], LIGHT_ENV_CINEMATIC.x, LIGHT_ENV_CINEMATIC.y, b["scene"], a["ground"][0]])
	if a.has("assembler (built-in)") and b.has("assembler (built-in)"):
		print("light env %s: built-in assembler all %.4f after, %.4f before" % [tag, a["assembler (built-in)"][3], b["assembler (built-in)"][3]])
	print("light env %s: GPU %.3f -> %.3f ms a frame; %s" % [tag, b["gpu"], a["gpu"], _pbr_took(s)])
	looks._light_env_sky = true
	looks._pbr_rough_floor = false
	looks._sun_specular_arg = -1.0
	looks._fill_light_arg = -1.0
	LooksScript.light_env_tune = {}
	LooksScript.light_tune = {}
	await _pbr_stage_end(s)


## Lit-to-shaded for `node` (or, null, the ground inside `box`): its pixels told apart by a picture with the sun alone
## (the lighting environment black, no ambient; "pbr" packs' own terms off), lit at least half the sun of their 90th
## percentile, shaded under 3% of it. [lit/shaded, lit mean, shaded mean, all mean, lit pixels, shaded pixels, lit sRGB].


func _light_env_ratio(node: Node3D, box: AABB, cam: Camera3D, step: Callable, looks: Node, over: Dictionary) -> Array:
	over.clear()
	var rect: Rect2
	var idx := PackedInt32Array()
	var bg := PackedByteArray()
	var shape := PackedByteArray()
	if node != null:
		_pbr_light_show(node, false, true)
		await step.call(PR_FRAMES)
		bg = _pbr_light_bytes(get_viewport().get_texture().get_image())
		_pbr_light_show(node, true, false)
		await step.call(PR_FRAMES)
		shape = _pbr_light_bytes(get_viewport().get_texture().get_image())
		_pbr_light_show(node, true, true)
		rect = _screen_rect(cam, node.get_aabb().merge(AABB(Vector3.ZERO, Vector3.ONE * 0.01)).grow(0.6), node.position)
	else:
		rect = _screen_rect(cam, box, Vector3.ZERO)
	LooksScript.light_env_tune = {"sky": 0.0, "ground": 0.0}
	LooksScript.light_tune = {"ambient_energy": 0.0}
	over[&"f3d_pbr_light"] = Vector4(1.0, 0.0, 0.0, 0.0)
	over[&"f3d_pbr_env"] = Vector4(0.0, 0.0, 0.0, 1.0)
	# The sun alone: the fill light (lighting-fixes step 3) off too.
	var fill_was: float = looks._fill_light_arg
	looks._fill_light_arg = 0.0
	await step.call(PR_FRAMES * 3)
	looks._fill_light_arg = fill_was
	var sun_img := get_viewport().get_texture().get_image()
	var w := sun_img.get_width()
	var sun_px := _pbr_light_bytes(sun_img)
	if _pr_linear.is_empty():
		_pr_blocks(sun_img, sun_img, sun_img, Rect2(0, 0, 1, 1))
	var x0 := clampi(int(rect.position.x), 0, w - 1)
	var x1 := clampi(int(rect.end.x), 0, w - 1)
	var y0 := clampi(int(rect.position.y), 0, sun_img.get_height() - 1)
	var y1 := clampi(int(rect.end.y), 0, sun_img.get_height() - 1)
	var sun_l := PackedFloat32Array()
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var i := (y * w + x) * 4
			if node != null and absi(shape[i] - bg[i]) + absi(shape[i + 1] - bg[i + 1]) + absi(shape[i + 2] - bg[i + 2]) < 6:
				continue
			idx.append(i)
			sun_l.append(_pbr_light_lum(sun_px, i))
	LooksScript.light_env_tune = {}
	LooksScript.light_tune = {}
	over.clear()
	await step.call(PR_FRAMES * 3)
	var sorted := sun_l.duplicate()
	sorted.sort()
	var p90 := sorted[int(sorted.size() * 0.9)] if not sorted.is_empty() else 0.0
	var px := _pbr_light_bytes(get_viewport().get_texture().get_image())
	var lit := 0.0
	var shade := 0.0
	var all := 0.0
	var nl := 0
	var ns := 0
	var rgb := Vector3.ZERO
	for k in idx.size():
		var l := _pbr_light_lum(px, idx[k])
		all += l
		if sun_l[k] >= 0.5 * p90:
			lit += l
			nl += 1
			rgb += Vector3(px[idx[k]], px[idx[k] + 1], px[idx[k] + 2])
		elif sun_l[k] <= 0.03 * p90:
			shade += l
			ns += 1
	lit /= maxf(nl, 1.0)
	shade /= maxf(ns, 1.0)
	return [lit / maxf(shade, 1e-6), lit, shade, all / maxf(idx.size(), 1.0), nl, ns, (rgb / maxf(nl, 1.0)).round()]


## The shots under one look and mode (`pre`): the modeller's ore field (from `dir`) and a few trees.


func _light_env_shots(dir: String, stage: Node3D, cam: Camera3D, step: Callable, shots: String, pre: String) -> void:
	var field := Node3D.new()
	stage.add_child(field)
	if dir != "":
		for x in range(-3, 4):
			for z in range(-2, 3):
				var n := _pbr_light_model(dir.path_join("iron-ore-%d.glb" % (1 + absi(x * 7 + z * 3) % 3)))
				if n != null:
					n.position = Vector3(x, 0.0, z)
					n.rotation.y = float(absi(x * 5 + z * 11) % 4) * PI * 0.5
					field.add_child(n)
		cam.size = 6.0
		await step.call(PR_FRAMES * 2)
		get_viewport().get_texture().get_image().save_png(shots.path_join("%s_ore_field.png" % pre))
		for c in field.get_children():
			c.queue_free()
	for i in 3:
		var t := _pbr_light_model("res://assets/models/packs/placeholders/tree-0%d.glb" % (i + 1), false)
		if t != null:
			t.position = Vector3(-2.0 + 2.0 * i, 0.0, float(i % 2))
			field.add_child(t)
	cam.size = 6.0
	await step.call(PR_FRAMES * 2)
	get_viewport().get_texture().get_image().save_png(shots.path_join("%s_trees.png" % pre))
	field.queue_free()
	await get_tree().process_frame


## A model file as a "pbr" pack's (or, `pbr` false, a built-in's) with its moving parts where they rest.


func _pbr_light_model(path: String, pbr := true) -> Node3D:
	var ld := ModelLibrary.Load.new()
	ld.path = ProjectSettings.globalize_path(path) if path.begins_with("res://") and pbr else path
	ld.combine = false
	ld.modeller = pbr
	ld.pbr = pbr
	ld.run()
	if not ld.ok:
		return null
	var parts: Array = []
	var root := MeshInstance3D.new()
	root.mesh = ModelLibrary._commit_load(ld, parts)
	for p in parts:
		var mi := MeshInstance3D.new()
		mi.mesh = p.mesh
		mi.transform = p.pivot
		root.add_child(mi)
	return root


## `node` (its parts too) shown or hidden, casting shadows or not.


func _pbr_light_show(node: Node3D, shown: bool, shadow: bool) -> void:
	node.visible = shown
	for mi: MeshInstance3D in [node] + node.find_children("*", "MeshInstance3D", true, false):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Each config's [lit/shaded, lit's mean luminance, shaded's, the model's, lit pixels, shaded pixels] for `node`, by
## config name; the pictures saved to `shots` (flat and directional) as <tag>_<config>.png.


func _pbr_light_measure(node: Node3D, cam: Camera3D, step: Callable, over: Dictionary, configs: Array, shots: String, tag: String) -> Dictionary:
	over.clear()
	_pbr_light_show(node, false, true)
	await step.call(PR_FRAMES)
	var bg := _pbr_light_bytes(get_viewport().get_texture().get_image())
	_pbr_light_show(node, true, false)
	await step.call(PR_FRAMES)
	var shape := _pbr_light_bytes(get_viewport().get_texture().get_image())
	_pbr_light_show(node, true, true)
	# The sun's light alone: no fill, ambient or reflection on the model.
	over[&"f3d_pbr_light"] = Vector4(1.0, 0.0, 0.0, 0.0)
	over[&"f3d_pbr_env"] = Vector4(0.0, 0.0, 0.0, 1.0)
	await step.call(PR_FRAMES)
	var sun_img := get_viewport().get_texture().get_image()
	var w := sun_img.get_width()
	var sun_px := _pbr_light_bytes(sun_img)
	if _pr_linear.is_empty():
		_pr_blocks(sun_img, sun_img, sun_img, Rect2(0, 0, 1, 1))  # fills the table
	var rect := _screen_rect(cam, node.get_aabb().merge(AABB(Vector3.ZERO, Vector3.ONE * 0.01)).grow(0.6), node.position)
	var x0 := clampi(int(rect.position.x), 0, w - 1)
	var x1 := clampi(int(rect.end.x), 0, w - 1)
	var y0 := clampi(int(rect.position.y), 0, sun_img.get_height() - 1)
	var y1 := clampi(int(rect.end.y), 0, sun_img.get_height() - 1)
	var idx := PackedInt32Array()
	var sun_l := PackedFloat32Array()
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var i := (y * w + x) * 4
			if absi(shape[i] - bg[i]) + absi(shape[i + 1] - bg[i + 1]) + absi(shape[i + 2] - bg[i + 2]) < 6:
				continue
			idx.append(i)
			sun_l.append(_pbr_light_lum(sun_px, i))
	var sorted := sun_l.duplicate()
	sorted.sort()
	var p90 := sorted[int(sorted.size() * 0.9)] if not sorted.is_empty() else 0.0
	var out := {}
	for c: Array in configs:
		over.clear()
		over.merge(c[1])
		await step.call(PR_FRAMES)
		var img := get_viewport().get_texture().get_image()
		if shots != "" and (c[0] == "flat" or c[0] == "directional" or c[0] == "look"):
			img.save_png(shots.path_join("%s_%s.png" % [tag, c[0]]))
		var px := _pbr_light_bytes(img)
		var lit := 0.0
		var shade := 0.0
		var all := 0.0
		var nl := 0
		var ns := 0
		for k in idx.size():
			var l := _pbr_light_lum(px, idx[k])
			all += l
			if sun_l[k] >= 0.5 * p90:
				lit += l
				nl += 1
			elif sun_l[k] <= 0.03 * p90:
				shade += l
				ns += 1
		lit /= maxf(nl, 1.0)
		shade /= maxf(ns, 1.0)
		out[c[0]] = [lit / maxf(shade, 1e-6), lit, shade, all / maxf(idx.size(), 1.0), nl, ns]
	over.clear()
	return out


## A picture's bytes as RGBA8 (a window's picture may come without alpha).


func _pbr_light_bytes(img: Image) -> PackedByteArray:
	if img.get_format() == Image.FORMAT_RGBA8:
		return img.get_data()
	var q := img.duplicate() as Image
	q.convert(Image.FORMAT_RGBA8)
	return q.get_data()


func _pbr_light_lum(px: PackedByteArray, i: int) -> float:
	return 0.2126 * _pr_linear[px[i]] + 0.7152 * _pr_linear[px[i + 1]] + 0.0722 * _pr_linear[px[i + 2]]


## A field of the modeller's rocks (iron-ore-1 to 3, then stone-1 to 3), flat, by direction and as the look has it,
## saved to `shots` (names after `pre`).


func _pbr_light_field(dir: String, stage: Node3D, cam: Camera3D, step: Callable, over: Dictionary, shots: String, pre := "") -> void:
	for ore in ["iron-ore", "stone"]:
		await _pbr_light_field_of(ore, dir, stage, cam, step, over, shots, pre)


func _pbr_light_field_of(ore: String, dir: String, stage: Node3D, cam: Camera3D, step: Callable, over: Dictionary, shots: String, pre: String) -> void:
	var field := Node3D.new()
	stage.add_child(field)
	for x in range(-3, 4):
		for z in range(-2, 3):
			var n := _pbr_light_model(dir.path_join("%s-%d.glb" % [ore, 1 + absi(x * 7 + z * 3) % 3]))
			if n != null:
				n.position = Vector3(x, 0.0, z)
				n.rotation.y = float(absi(x * 5 + z * 11) % 4) * PI * 0.5
				field.add_child(n)
	cam.size = 6.0
	for c: Array in [["flat", PBR_LIGHT_FLAT], ["directional", Vector4(1.0, LooksScript.PBR_FILL, LooksScript.PBR_AMBIENT, 0.0)], ["look", null]]:
		over.clear()
		if c[1] != null:
			over[&"f3d_pbr_light"] = c[1]
		await step.call(PR_FRAMES * 2)
		get_viewport().get_texture().get_image().save_png(shots.path_join("%s%s_field_%s.png" % [pre, ore.replace("-", "_"), c[0]]))
	over.clear()
	field.queue_free()
	await get_tree().process_frame

## Frames before each of _pr_measure's three pictures (20 each before: 60 a measure, which at the window's 4.5
## frames a second ran the strict pass past its 600 s), and the stage's once at its start.


const PR_FRAMES := 6


const PR_WARM := 30
## sRGB level (0-255) to linear, for _pr_measure.


func _pr_measure(mi: MeshInstance3D, cam: Camera3D, step: Callable) -> Array:
	mi.visible = false
	await step.call(PR_FRAMES)
	var bg := get_viewport().get_texture().get_image()
	mi.visible = true
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	await step.call(PR_FRAMES)
	var shape := get_viewport().get_texture().get_image()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	await step.call(PR_FRAMES)
	var img := get_viewport().get_texture().get_image()
	return _pr_blocks(img, bg, shape, _screen_rect(cam, mi.get_aabb().grow(0.5), mi.position))


## _pr_measure's numbers from its three pictures, over `rect`.


func _pr_blocks(img: Image, bg: Image, shape: Image, rect: Rect2) -> Array:
	if _pr_linear.is_empty():
		_pr_linear.resize(256)
		for i in 256:
			_pr_linear[i] = Color(i / 255.0, 0.0, 0.0).srgb_to_linear().r
	var pics: Array = []
	for p: Image in [img, bg, shape]:
		var q := p
		if q.get_format() != Image.FORMAT_RGBA8:
			q = p.duplicate()
			q.convert(Image.FORMAT_RGBA8)
		pics.append(q.get_data())
	var d: PackedByteArray = pics[0]
	var db: PackedByteArray = pics[1]
	var ds: PackedByteArray = pics[2]
	var w := img.get_width()
	var x0 := clampi(int(rect.position.x), 0, w - 1)
	var x1 := clampi(int(rect.end.x), 0, w - 1)
	var y0 := clampi(int(rect.position.y), 0, img.get_height() - 1)
	var y1 := clampi(int(rect.end.y), 0, img.get_height() - 1)
	var bl := PackedFloat64Array()
	bl.resize(16)
	var bn := PackedInt32Array()
	bn.resize(16)
	var sr := 0
	var sg := 0
	var sb := 0
	var lum := 0.0
	var n := 0
	var bw := maxf(rect.size.x, 1.0) / 4.0
	var bh := maxf(rect.size.y, 1.0) / 4.0
	for y in range(y0, y1 + 1, 2):
		var row := y * w * 4
		var by := clampi(int((y - rect.position.y) / bh), 0, 3) * 4
		for x in range(x0, x1 + 1, 2):
			var i := row + x * 4
			if absi(ds[i] - db[i]) + absi(ds[i + 1] - db[i + 1]) + absi(ds[i + 2] - db[i + 2]) < 6:
				continue
			var r := d[i]
			var g := d[i + 1]
			var b := d[i + 2]
			sr += r
			sg += g
			sb += b
			var l := 0.2126 * _pr_linear[r] + 0.7152 * _pr_linear[g] + 0.0722 * _pr_linear[b]
			lum += l
			n += 1
			var k := by + clampi(int((x - rect.position.x) / bw), 0, 3)
			bl[k] += l
			bn[k] += 1
	var blocks: Array = []
	for k in 16:
		blocks.append(bl[k] / bn[k] if bn[k] >= 12 else -1.0)
	if n == 0:
		return [[0.0, 0.0, 0.0, 0.0, 0], blocks]
	return [[snappedf(float(sr) / n, 0.1), snappedf(float(sg) / n, 0.1), snappedf(float(sb) / n, 0.1), snappedf(lum / n, 0.0001), n], blocks]


## `mi`'s masked mean (_masked_mean): the scene without it, with it casting no shadow (its own pixels), and with
## its shadows, each after `step` frames.


func _ps_measure(mi: MeshInstance3D, cam: Camera3D, step: Callable) -> Array:
	mi.visible = false
	await step.call(20)
	var bg := get_viewport().get_texture().get_image()
	mi.visible = true
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	await step.call(20)
	var shape := get_viewport().get_texture().get_image()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	await step.call(20)
	var img := get_viewport().get_texture().get_image()
	return _masked_mean(img, bg, _screen_rect(cam, mi.get_aabb().grow(0.5), mi.position), shape)


## A .glb of a flat 1.6-tile quad, grey, whose normal map leans every texel towards +U (east, +X): written
## from Godot's own PlaneMesh (real tangents) and material; returns its path.


func _ps_normal_quad() -> String:
	var nm := Image.create(8, 8, false, Image.FORMAT_RGB8)
	nm.fill(Color(0.85, 0.5, 0.86))  # (0.7, 0, 0.72) in tangent space: towards +U
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.5, 0.5, 0.5)
	var grey := Image.create(8, 8, false, Image.FORMAT_RGB8)
	grey.fill(Color(1, 1, 1))
	mat.albedo_texture = ImageTexture.create_from_image(grey)
	mat.normal_enabled = true
	mat.normal_texture = ImageTexture.create_from_image(nm)
	mat.roughness = 0.8
	var plane := PlaneMesh.new()
	plane.size = Vector2(1.6, 1.6)
	plane.material = mat
	var root := Node3D.new()
	root.name = "Quad"
	var mi := MeshInstance3D.new()
	mi.name = "quad"
	mi.mesh = plane
	mi.position = Vector3(0.0, 0.05, 0.0)
	root.add_child(mi)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	doc.append_from_scene(root, state)
	var path := ProjectSettings.globalize_path("user://pack_shading_quad.glb")
	doc.write_to_filesystem(state, path)
	root.free()
	return path

## [mean red, green, blue (sRGB levels), mean linear luminance, pixels] of `img` where `shape` differs
## from `bg` (the scene without the model) inside `rect`.


func _masked_mean(img: Image, bg: Image, rect: Rect2, shape: Image) -> Array:
	var sum := Vector3.ZERO
	var lum := 0.0
	var n := 0
	var x0 := clampi(int(rect.position.x), 0, img.get_width() - 1)
	var x1 := clampi(int(rect.end.x), 0, img.get_width() - 1)
	var y0 := clampi(int(rect.position.y), 0, img.get_height() - 1)
	var y1 := clampi(int(rect.end.y), 0, img.get_height() - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var c := img.get_pixel(x, y)
			var b := bg.get_pixel(x, y)
			var o := shape.get_pixel(x, y)
			if absf(o.r - b.r) + absf(o.g - b.g) + absf(o.b - b.b) < 6.0 / 255.0:
				continue
			sum += Vector3(c.r, c.g, c.b)
			var l := c.srgb_to_linear()
			lum += 0.2126 * l.r + 0.7152 * l.g + 0.0722 * l.b
			n += 1
	if n == 0:
		return [0.0, 0.0, 0.0, 0.0, 0]
	sum *= 255.0 / n
	return [snappedf(sum.x, 0.1), snappedf(sum.y, 0.1), snappedf(sum.z, 0.1), snappedf(lum / n, 0.0001), n]


## The screen rectangle of `box` placed at `at`, its middle 70% (the edges' anti-aliasing left out).


func _screen_rect(cam: Camera3D, box: AABB, at: Vector3) -> Rect2:
	var r := Rect2(cam.unproject_position(at + box.position), Vector2.ZERO)
	for i in 8:
		r = r.expand(cam.unproject_position(at + box.get_endpoint(i)))
	return r.grow_individual(-r.size.x * 0.15, -r.size.y * 0.15, -r.size.x * 0.15, -r.size.y * 0.15)


## [mean red, green, blue (sRGB levels 0-255), mean linear luminance] of `img` in `rect`.


func _screen_mean(img: Image, _cam: Camera3D, rect: Rect2) -> Array:
	var sum := Vector3.ZERO
	var lum := 0.0
	var n := 0
	var x0 := clampi(int(rect.position.x), 0, img.get_width() - 1)
	var x1 := clampi(int(rect.end.x), 0, img.get_width() - 1)
	var y0 := clampi(int(rect.position.y), 0, img.get_height() - 1)
	var y1 := clampi(int(rect.end.y), 0, img.get_height() - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var c := img.get_pixel(x, y)
			sum += Vector3(c.r, c.g, c.b)
			var l := c.srgb_to_linear()
			lum += 0.2126 * l.r + 0.7152 * l.g + 0.0722 * l.b
			n += 1
	if n == 0:
		return [0.0, 0.0, 0.0, 0.0]
	sum *= 255.0 / n
	return [snappedf(sum.x, 0.1), snappedf(sum.y, 0.1), snappedf(sum.z, 0.1), snappedf(lum / n, 0.0001)]


## L7 (the owner's playtest, 13:23: "I can't see how many big electric poles I have through my hand"):
## holding a building over the world showed its ghost and nothing at the cursor. Factorio draws the
## hand's count by the pointer there (count-font, default-bold 13, bordered), the ghost showing what it
## is; the icon with its count over windows and where no ghost shows, as before; an empty hand (a ghost
## cursor) no count. --cursor-count=old: none over the ghost, the bug.
