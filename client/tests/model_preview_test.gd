extends SceneTree
## The Model packs window's preview (model_preview.gd) draws a model of every pack and kind the way
## the game does and frames it: its mesh is the library's, each surface the game's own material (the
## factorio_material shaders, a modeller's textures kept, no override), the camera looks at the middle
## of the model's box (projected onto the picture's middle) with the whole box in view and in front of
## the near plane at every turn, and the world's hills and pollution reach nothing there (the model
## stood at the origin, lifted by the hills under the spawn: a dark shape at the top of the picture).
## Metal reflects a sky. A modeller's pack (Vasillo's, read only) is checked from `--models-dir=<folder>`
## (or `--models=`, or the ZENITH_TEST_MODELS environment variable), skipped when none is given or it isn't there.
##   godot --headless --path client -s res://tests/model_preview_test.gd [-- --models-dir=<folder>]

const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ModelPreview := preload("res://scripts/ui/factorio/model_preview.gd")
const Looks := preload("res://scripts/world/looks.gd")
const PlanetSky := preload("res://scripts/world/sky.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const InserterArms := preload("res://scripts/world/inserter_arms.gd")
const ModelRig := preload("res://scripts/world/model_rig.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const TestEnv := preload("res://tests/test_env.gd")
const ItemIcons := preload("res://scripts/world/item_icons.gd")
const SpriteStandins := preload("res://scripts/world/sprite_standins.gd")
const ModFiles := preload("res://scripts/world/mod_files.gd")
const BeltBlur := preload("res://scripts/world/belt_blur.gd")
const Anim := preload("res://scripts/world/anim.gd")
const SoundBank := preload("res://scripts/fx/sound_bank.gd")
const BurnerFx := preload("res://scripts/fx/burner_fx.gd")
const PreviewAnim := preload("res://scripts/ui/factorio/preview_anim.gd")
const Turrets := preload("res://scripts/world/turrets.gd")
## Every turret family the built-in packs have, each pack's version.
const TURRET_MODELS := ["gun-turret@builtin:placeholders", "gun-turret@builtin:fue5", "laser-turret@builtin:placeholders",
	"flamethrower-turret@builtin:placeholders", "artillery-turret@builtin:placeholders", "rocket-turret@builtin:placeholders",
	"railgun-turret@builtin:placeholders", "tesla-turret@builtin:placeholders"]
## A modeller's models looked at (those in the folder): belts, an underground, a splitter, an inserter, a drill.
const MODELLER_MODELS := ["express-underground-belt-input", "transport-belt", "splitter", "inserter", "burner-mining-drill",
	"electric-mining-drill", "transport-belt-curve-left", "express-transport-belt-curve-right", "underground-belt-input", "burner-inserter", "fast-inserter", "long-handed-inserter", "bulk-inserter", "stack-inserter"]
## Every inserter tier: drawn with its arm at rest (Wube3DP's pieces, a modeller's rig).
const INSERTERS := ["burner-inserter", "inserter", "fast-inserter", "long-handed-inserter", "bulk-inserter", "stack-inserter"]
## Zenith's own, by pack: FUE5's textured, Wube's printable, the placeholders' resources, cliffs and rocks.
const OWN_MODELS := ["beacon@builtin:fue5", "wooden-chest@builtin:wube3dp", "copper-ore@builtin:placeholders",
	"cliff-entrance@builtin:placeholders", "huge-rock@builtin:placeholders", "beacon@builtin:placeholders",
	"splitter@builtin:placeholders", "transport-belt@builtin:wube3dp",
	# Inserter arm parts: their origin is the shoulder or wrist, far from the mesh's middle.
	"inserter-arm-basic-upper@builtin:wube3dp", "inserter-arm-basic-hand-open@builtin:wube3dp",
	"inserter-arm-basic-hand-closed@builtin:wube3dp", "inserter-arm-long-upper@builtin:wube3dp"]

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _initialize() -> void:
	TestEnv.isolate("model-preview-test")
	_run.call_deferred()


func _run() -> void:
	var MP = ModelLibrary.ModelPacks
	var folder := TestEnv.models_dir(["--models="])
	var names: Array = []
	if folder != "" and DirAccess.dir_exists_absolute(folder):
		MP.configure(OS.get_user_data_dir().path_join("no-packs"), [], [], folder, true)
		MP.wait()
		for n: String in MODELLER_MODELS:
			if FileAccess.file_exists(folder.path_join(n + ".glb")):
				names.append(n + "@arg")
	else:
		print("SKIP: a modeller's models: %s (-- --models-dir=<folder> or ZENITH_TEST_MODELS)" % (
			"no folder given" if folder == "" else "none at " + folder))
		MP.configure(OS.get_user_data_dir().path_join("no-packs"), [], [])
		MP.wait()
	ModelLibrary.choices_changed([])
	names.append_array(OWN_MODELS)
	for n: String in INSERTERS:
		names.append(n + "@builtin:wube3dp")
	# FUE5's: a rig in each file (tools/models/fue5.py's inserter group), drawn by the client's arm.
	for n: String in INSERTERS:
		names.append(n + "@builtin:fue5")
	# Placeholders has no inserter: its base and arm are the usual ones, as the world falls back.
	names.append("inserter@builtin:placeholders")
	var pv: ModelPreview = ModelPreview.new()
	pv.size = Vector2(400, 300)
	root.add_child(pv)
	await process_frame
	var env: Environment = (pv.viewport.find_children("*", "WorldEnvironment", true, false)[0] as WorldEnvironment).environment
	check(env.sky != null and env.reflected_light_source == Environment.REFLECTION_SOURCE_SKY,
		"the preview's metal reflects a sky, not the dark background")
	if folder != "" and DirAccess.dir_exists_absolute(folder):
		_rest_visible_dir(folder)
	for name: String in names:
		await _show(pv, name)
		_check_drawn(pv, name)
		if INSERTERS.has(ModelLibrary.file_of(name)):
			_check_arm(pv, name)
			if name.ends_with("@builtin:fue5"):
				var rig := ModelLibrary.rig_for(name)
				check(not rig.is_empty() and rig["meshes"][ModelRig.Part.PINCER_A] != null
					and rig["meshes"][ModelRig.Part.PINCER_B] != null, "%s: its own arm rig, with two pincers" % name)
		_check_parts(pv, name)
		if ModelLibrary.file_of(name).contains("-curve-"):
			# Factorio has no lone curve (its entry is always fed from the side): the curve alone, as inside a line.
			check(pv._holder.find_children("BeltEnd*", "", true, false).is_empty(), "%s: no end piece on a curve" % name)
		elif ModelLibrary.file_of(name) in ["transport-belt", "splitter", "underground-belt-input", "express-underground-belt-input"] and name.ends_with("@arg"):
			check(not pv._holder.find_children("BeltEnd*", "", true, false).is_empty(), "%s: its end pieces drawn" % name)
		if name.ends_with("@arg"):
			_check_whole(pv, name)
	await _steady_light(pv, names[0])
	await _static_thumbnail_cache(pv)
	await _backdrop(pv)
	await _no_flicker(pv, "cliff-entrance@builtin:placeholders")
	await _mouse(pv, names[0])
	await _play(pv)
	await _play_wheels(pv)
	await _burner(pv, names)
	await _signals(pv)
	await _pipe_stubs(pv)
	await _turrets(pv)
	await _pictures(pv)
	await _factorio_pictures(pv)
	await _factorio_arms(pv)
	if folder != "" and DirAccess.dir_exists_absolute(folder):
		await _modeller_items_ores(pv, folder)
	var arm_names: Array = ["inserter@builtin:fue5", "long-handed-inserter@builtin:fue5",
		"inserter@builtin:wube3dp", "long-handed-inserter@builtin:wube3dp"]
	if names.has("inserter@arg") and names.has("long-handed-inserter@arg"):
		arm_names.append_array(["inserter@arg", "long-handed-inserter@arg"])
	var reaches := {}
	for n: String in arm_names:
		reaches[n] = await _play_arm(pv, n)
	for n: String in arm_names:
		if n.begins_with("long-handed-inserter"):
			var basic: String = "inserter" + n.substr(n.find("@"))
			check(float(reaches[n]) > float(reaches[basic]) + 0.5, "%s reaches further than %s: %.2f against %.2f"
				% [n, basic, reaches[n], reaches[basic]])
	# Hills under the spawn and the main camera (Terrain Elevation's field): nothing in the preview is
	# lifted, and it stays put while the field doesn't change.
	var hills := Image.create(64, 64, false, Image.FORMAT_RF)
	hills.fill(Color(6.0, 0.0, 0.0))
	var main_camera := Camera3D.new()
	root.add_child(main_camera)
	main_camera.current = true
	main_camera.global_position = Vector3(40.0, 20.0, -30.0)
	GroundHeight.set_field(hills, Vector2(-256.0, -256.0), 8.0)
	for name: String in ["copper-ore@builtin:placeholders", names[0]]:
		pv.show_model("")
		await _show(pv, name)
		_check_drawn(pv, name + " (on hills)")
	GroundHeight.clear()
	pv.queue_free()
	main_camera.queue_free()
	await process_frame
	print("model_preview_test: %d models, %s" % [names.size(), "PASS" if fails == 0 else "%d FAILED" % fails])
	quit(0 if fails == 0 else 1)


## The Factorio pack's pictures (with an install): an entity's card with its picture, held still and
## seen face on from Factorio's pitch (its normal towards the camera), framed whole and large, nothing to
## play; a picture with directions shows each; an item's icon card lies face up, framed; a drag still
## turns the card.
func _pictures(pv: ModelPreview) -> void:
	if ItemIcons.factorio_data_dir() == "":
		print("SKIP: Factorio's pictures (no Factorio install)")
		return
	pv.show_sprite("assembling-machine-1")
	for i in 3000:
		if pv.settled():
			break
		await process_frame
	await process_frame
	var card := pv.shown_mesh as QuadMesh
	var tex: Texture2D = (card.material as ShaderMaterial).get_shader_parameter("picture") if card != null else null
	var body := pv._holder.get_child(0) as Node3D if pv._holder.get_child_count() > 0 else null
	var facing := 0.0
	if body != null:
		var normal: Vector3 = (body.global_transform.basis * Vector3(0, 0, 1)).normalized()
		facing = normal.dot((pv._camera.global_position - body.global_position).normalized())
	var box := pv.box_on_screen(0.0)
	var view := Vector2(pv.viewport.size)
	check(pv.is_picture() and tex != null and facing > 0.95 and pv.box_in_view(0.0) and maxf(box.size.x / view.x, box.size.y / view.y) > 0.6,
		"assembling-machine-1's picture on a card facing the camera (%.3f), framed (%s of %s)" % [facing, box.size, view])
	var spin_was: Vector3 = pv._spin.rotation
	for i in 20:
		await process_frame
	check(pv._spin.rotation == spin_was and not pv.can_play() and pv.shown_sprite() == ["assembling-machine-1", 0],
		"a picture holds still and has nothing to play")
	check(pv.sound_reason() == "" or pv.sound_reason().begins_with("A picture, not a model"),
		"its speaker plays its working sound or says why not: %s" % pv.sound_reason())
	pv.orbit(Vector2(40, 0))
	check(pv._spin.rotation != spin_was, "a drag still turns the card")
	var dirs: Array = SpriteStandins.directions("electric-mining-drill")
	check(dirs == [0, 4, 8, 12], "the electric drill's picture has four directions: %s" % [dirs])
	var textures := {}
	for d: int in dirs:
		pv.show_sprite("electric-mining-drill", d)
		for i in 3000:
			if pv.settled():
				break
			await process_frame
		var m := pv.shown_mesh as QuadMesh
		if m != null:
			textures[(m.material as ShaderMaterial).get_shader_parameter("picture")] = true
		check(m != null and pv.box_in_view(0.0), "the drill facing %d drawn and framed" % d)
	check(textures.size() == 4, "each direction its own picture: %d" % textures.size())
	pv.show_item_card("iron-plate")
	for i in 3000:
		if pv.settled():
			break
		await process_frame
	await process_frame
	var plate := pv.shown_mesh as PlaneMesh
	var fits := plate != null
	for k in 8:
		fits = fits and pv.box_in_view(k * TAU / 8.0)
	check(fits and (plate.material as StandardMaterial3D).albedo_texture != null and not pv.can_play(),
		"iron plate's icon card lying face up, framed whole as it turns")
	pv.show_sprite("zz-no-such-entity")
	for i in 30:
		if pv.settled():
			break
		await process_frame
	check(pv.settled() and pv.shown_mesh == null, "an entity without a picture says so")
	pv.show_model("")


## The Factorio pack's pictures composed as Factorio draws them: every layer at rest (its size covers the
## layers' union at their shifts and scales), full resolution (an inserter's platform: its file's frame, pixel
## for pixel) with mipmaps, the picture's own alpha (edges between 0 and 1), sRGB, drawn unshaded and blended
## through linear tone mapping.
func _factorio_pictures(pv: ModelPreview) -> void:
	if ItemIcons.factorio_data_dir() == "":
		print("SKIP: Factorio's pictures composed (no Factorio install)")
		return
	var include := FileAccess.get_file_as_string("res://shaders/sprite_card.gdshaderinc")
	check(include.contains("sampler2D picture : source_color"), "the card's picture is read as sRGB")
	for name: String in ["burner-mining-drill", "stone-furnace", "assembling-machine-1", "electric-mining-drill", "gun-turret", "bulk-inserter"]:
		pv.show_sprite(name)
		for i in 3000:
			if pv.settled():
				break
			await process_frame
		var card := pv.shown_mesh as QuadMesh
		var tex: Texture2D = (card.material as ShaderMaterial).get_shader_parameter("picture") if card != null else null
		check(tex != null, "%s: a picture" % name)
		if tex == null:
			continue
		var rec: Dictionary = SpriteStandins._rec(name)
		var layers: Array = rec.get("n", [])
		var px := SpriteStandins.density(layers)
		var lo := Vector2(INF, INF)
		var hi := -Vector2(INF, INF)
		var files: Array = []
		for l: Array in layers:
			var k := float(l[5]) * px / 32.0
			var sz := Vector2(roundi(float(l[3]) * k), roundi(float(l[4]) * k))
			var at := Vector2(float(l[6]), float(l[7])) * px - sz * 0.5
			lo = lo.min(at)
			hi = hi.max(at + sz)
			files.append(str(l[0]).get_file())
		var want := hi - lo
		var got := Vector2(tex.get_width(), tex.get_height())
		var least := 2 if name in ["assembling-machine-1", "electric-mining-drill", "gun-turret"] else 1
		check(layers.size() >= least and absf(got.x - want.x) <= 2.0 and absf(got.y - want.y) <= 2.0,
			"%s: every layer at rest composed (%s), the picture %s covers their union %s" % [name, files, got, want])
		var img := tex.get_image()
		var soft := 0
		if img != null:
			var data := img.get_data()
			var n := img.get_width() * img.get_height()
			for i in n:
				var a := data[i * 4 + 3]
				if a > 12 and a < 243:
					soft += 1
		check(img != null and img.has_mipmaps() and soft > 0, "%s: mipmapped, its own soft alpha (%d edge pixels between 0 and 1)" % [name, soft])
		var body := pv._holder.find_child("Body", false, false) as MeshInstance3D
		var mat := body.material_override as ShaderMaterial if body != null else null
		check(mat != null and mat.shader == SpriteStandins.CARD_UNLIT_SHADER and mat.shader.code.contains("unshaded")
			and mat.shader.code.contains("blend_mix") and mat.get_shader_parameter("picture") == tex
			and pv._env.tonemap_mode == Environment.TONE_MAPPER_LINEAR,
			"%s: drawn unshaded and blended, its own picture, linear tone mapping" % name)
		if name == "bulk-inserter":
			var frame := ModFiles.load_image("__base__/graphics/entity/bulk-inserter/bulk-inserter-platform.png")
			check(frame != null and got == Vector2(frame.get_width() / 4, frame.get_height()),
				"the platform's picture is its file's frame at full size: %s of the %s sheet" % [got, frame.get_size() if frame != null else Vector2i.ZERO])
	pv.show_model("transport-belt@builtin:wube3dp")
	var rig := Looks.noon_rig()
	check(pv._env.tonemap_mode == int(rig["tonemap"]) and is_equal_approx(pv._env.tonemap_exposure, float(rig["exposure"])),
		"a model takes the game's look's tone mapping and exposure")
	pv.set_studio(true)
	check(pv._env.tonemap_mode == Environment.TONE_MAPPER_FILMIC and is_equal_approx(pv._env.tonemap_exposure, 1.0),
		"a model under the studio light keeps filmic tone mapping")
	pv.set_studio(false)
	pv.show_model("")


## A Factorio-pack inserter's picture has Factorio's arm in front of it, at rest as the world's resting arm
## (sprite_arm_pose for the hand over the pickup, open), framed with it; Play swings the hand card from the
## pickup to the drop and back, posed by posed_pieces, the closed hand while it holds; every tier, facing east too.
func _factorio_arms(pv: ModelPreview) -> void:
	if ItemIcons.factorio_data_dir() == "":
		print("SKIP: Factorio's inserter arms (no Factorio install)")
		return
	for name: String in INSERTERS:
		for dir: int in [0, 4]:
			pv.show_sprite(name, dir)
			for i in 3000:
				if pv.settled():
					break
				await process_frame
			await process_frame
			var model := name + "@" + ModelLibrary.ModelPacks.FACTORIO_ID
			var pick := InserterArms._turn(InserterArms.cycle_of(name)["pick"], dir)
			var want: Dictionary = InserterArms.sprite_arm_pose(model, pick, false, dir)
			var nodes: Array = []
			for c in pv._holder.get_children():
				if c.has_meta("arm_piece"):
					nodes.append(c)
			var pieces: Array = want.get("pieces", [])
			var rest_ok := pieces.size() == 2 and nodes.size() == 2
			if rest_ok:
				for n: MeshInstance3D in nodes:
					var w: Array = pieces[int(n.get_meta("arm_piece"))]
					var pic: Variant = ((w[0] as QuadMesh).material as ShaderMaterial).get_shader_parameter("picture")
					rest_ok = rest_ok and n.mesh == w[0] and n.transform.is_equal_approx(w[1]) \
						and (n.material_override as ShaderMaterial).get_shader_parameter("picture") == pic
			check(rest_ok, "%s facing %d: the platform and Factorio's arm at rest (%d cards) where sprite_arm_pose has it" % [name, dir, nodes.size()])
			check(pv.box_in_view(0.0), "%s facing %d: framed with its arm" % [name, dir])
			if dir != 0 or not rest_ok:
				continue
			# The arm's cards are inside the framed box (it was fitted with them).
			var box := pv.model_box()
			var arm_box: AABB = (nodes[1] as MeshInstance3D).transform * (nodes[1] as MeshInstance3D).mesh.get_aabb()
			check(box.grow(0.001).encloses(arm_box), "%s: the framing's box holds the hand card: %s in %s" % [name, arm_box, box])
			check(pv.can_play(), "%s: its picture's arm can play" % name)
			pv.set_playing(true)
			var state := pv.play_state()
			var posing = InserterArms.new_posing()
			var phase := 0
			var posed_ok := true
			var closed_seen := false
			for i in 600:
				state.process(pv._holder, 1.0 / 60.0)
				var posed: Dictionary = posing.posed_pieces(model, state.hand, state.close, state.holding, 0)
				for n: MeshInstance3D in nodes:
					var w: Array = (posed["pieces"] as Array)[int(n.get_meta("arm_piece"))]
					if n.mesh != w[0] or not n.transform.is_equal_approx(w[1]):
						posed_ok = false
				if state.holding and (nodes[1] as MeshInstance3D).mesh == (pieces[1] as Array)[0]:
					posed_ok = false  # (the open hand while holding)
				closed_seen = closed_seen or state.holding
				if phase == 0 and state.hand.y > 0.5:
					phase = 1
				elif phase == 1 and state.hand.y < -0.5:
					phase = 2
			InserterArms._free_scratch(posing)
			check(posed_ok and closed_seen, "%s: every frame the arm's cards where posed_pieces has them, the closed hand while it holds" % name)
			check(phase == 2, "%s: the hand card from the pickup to the drop and back (%d)" % [name, phase])
			pv.set_playing(false)
			var back := true
			for n: MeshInstance3D in nodes:
				var w: Array = pieces[int(n.get_meta("arm_piece"))]
				back = back and n.mesh == w[0] and n.transform.is_equal_approx(w[1])
			check(back, "%s: stopped, the arm back at rest" % name)
	pv.show_model("")


## A pipe shape shown alone has its connected ends closed by the pack's ending pieces one tile over
## (ModelLibrary.lone_pipe_pieces), as a short line in the world: a straight two, a corner two, a T
## three, a cross four, each the ending that faces back, and the framing holds them. A wall and a belt
## get none.
func _pipe_stubs(pv: ModelPreview) -> void:
	var cases := {"straight-horizontal": {Vector3(1, 0, 0): "ending-left", Vector3(-1, 0, 0): "ending-right"},
		"corner-up-right": {Vector3(0, 0, -1): "ending-down", Vector3(1, 0, 0): "ending-left"},
		"t-up": {Vector3(0, 0, -1): "ending-down", Vector3(1, 0, 0): "ending-left", Vector3(-1, 0, 0): "ending-right"},
		"cross": {Vector3(0, 0, -1): "ending-down", Vector3(1, 0, 0): "ending-left", Vector3(0, 0, 1): "ending-up", Vector3(-1, 0, 0): "ending-right"}}
	for pack: String in ["builtin:fue5", "builtin:placeholders"]:
		for fam: String in ["pipe", "heat-pipe"]:
			for shape: String in cases:
				var name := "%s-%s@%s" % [fam, shape, pack]
				await _show(pv, name)
				_check_drawn(pv, name)
				var stubs := pv._holder.find_children("PipeStub*", "", false, false)
				var want: Dictionary = cases[shape]
				var right := stubs.size() == want.size()
				for s: Node in stubs:
					var at := (s as Node3D).position.snapped(Vector3.ONE * 0.001)
					right = right and want.has(at) and (s as MeshInstance3D).mesh == ModelLibrary.mesh_for("%s-%s@%s" % [fam, want.get(at, ""), pack])
				var box := pv.model_box()
				var inside := true
				for s: Node in stubs:
					inside = inside and box.grow(0.001).encloses((s as Node3D).transform * (s as MeshInstance3D).mesh.get_aabb())
				check(right and inside, "%s: an ending closing each connected end (%d), inside the framed box: %s" % [name, want.size(),
					stubs.map(func(s: Node3D) -> Vector3: return s.position)])
		# The family's own model: its stubs where its mesh reaches the tile's edge (FUE5's is a straight).
		await _show(pv, "pipe@" + pack)
		var main_box := ModelLibrary.mesh_for("pipe@" + pack).get_aabb()
		var reaches := int(main_box.position.z <= -0.45) + int(main_box.end.x >= 0.45) + int(main_box.end.z >= 0.45) + int(main_box.position.x <= -0.45)
		check(pv._holder.find_children("PipeStub*", "", false, false).size() == reaches,
			"pipe@%s: an ending on each side it reaches (%d, box %s)" % [pack, reaches, main_box])
	for name: String in ["stone-wall-ew@builtin:fue5", "stone-wall-nesw@builtin:wube3dp", "transport-belt@builtin:wube3dp", "pipe-to-ground@builtin:fue5"]:
		await _show(pv, name)
		check(pv.shown_mesh != null and pv._holder.find_children("PipeStub*", "", false, false).is_empty(), "%s: no pipe ending added" % name)


func _show(pv: ModelPreview, name: String) -> void:
	pv.show_model(name)
	for i in 3000:
		if pv.settled():
			break
		await process_frame
	await process_frame


func _check_drawn(pv: ModelPreview, name: String) -> void:
	var mesh := pv.shown_mesh
	# The library's mesh (made again since, when its cache was emptied: the same model).
	var library := ModelLibrary.mesh_for(name)
	check(mesh != null and library != null and (mesh == library or (mesh.get_aabb() == library.get_aabb()
		and mesh.get_surface_count() == library.get_surface_count())),
		"%s: the preview shows the library's mesh: %s %s, %s" % [name, mesh, library, pv._note.text])
	if mesh == null:
		return
	var body := pv.find_child("Body", true, false) as MeshInstance3D
	check(body != null and body.mesh == mesh and body.material_override == null, "%s: the body drawn as it is, no override" % name)
	for i in mesh.get_surface_count():
		var m := mesh.surface_get_material(i) as ShaderMaterial
		var game_shader := m != null and m.shader != null and m.shader.resource_path.begins_with("res://shaders/factorio_material")
		check(game_shader, "%s: surface %d drawn with the game's model shader: %s" % [name, i, mesh.surface_get_material(i)])
		if game_shader and m.get_shader_parameter("use_albedo_tex") == true:
			check(m.get_shader_parameter("albedo_tex") is Texture2D, "%s: surface %d keeps its own picture" % [name, i])
	_check_rest_visible(mesh, name)
	var size := Vector2(pv.viewport.size)
	var box := pv.model_box()
	var camera := pv.viewport.get_camera_3d()
	var to_world: Transform3D = pv._spin.global_transform * Transform3D(Basis.IDENTITY, pv._holder.position)
	var mid := camera.unproject_position(to_world * box.get_center())
	check(mid.distance_to(size * 0.5) < 1.0, "%s: the box's middle at the picture's middle: %s of %s" % [name, mid, size])
	var nearest := INF
	var furthest := 0.0
	var widest := 0.0
	for k in 8:
		var angle := k * TAU / 8.0
		check(pv.box_in_view(angle), "%s: the whole box in view at turn %d: %s in %s" % [name, k, pv.box_on_screen(angle), size])
		var r := pv.box_on_screen(angle)
		widest = maxf(widest, maxf(r.size.x / size.x, r.size.y / size.y))
		var turn := pv._world.global_transform * Transform3D(Basis(Vector3.UP, angle), Vector3.ZERO) * Transform3D(Basis.IDENTITY, pv._holder.position)
		for c in 8:
			var depth := -(camera.global_transform.affine_inverse() * (turn * box.get_endpoint(c))).z
			nearest = minf(nearest, depth)
			furthest = maxf(furthest, depth)
			var w := turn * box.get_endpoint(c)
			check(GroundHeight.at(w.x, w.z) == 0.0, "%s: no hills under the model's corner %s" % [name, w])
	check(nearest > camera.near and furthest < camera.far, "%s: the box between the near and far planes: %.2f-%.2f in %.2f-%.2f"
		% [name, nearest, furthest, camera.near, camera.far])
	check(widest > 0.6, "%s: the model fills the picture: %.0f%%" % [name, widest * 100.0])
	var area := GroundHeight.area()
	check(not area.has_area() or not area.has_point(Vector2(pv.model_origin().x, pv.model_origin().z)),
		"%s: the preview's world outside the hills' field: %s, field %s" % [name, pv.model_origin(), area])


## A model isn't invisible at rest: a see-through surface that fades with its glow (glow_fades: a plume)
## is gone while its machine is idle, and in the preview, which has no activity, always. So most of the
## body's triangles must be on surfaces that stay drawn: opaque, cut out, or see-through without
## glow_fades (a merged surface fades only when every one of its rows does). Vasillo's 30 materials with
## a black emission picture and no factor faded this way, his drill all but its two Light specks.
func _check_rest_visible(mesh: Mesh, name: String) -> void:
	var total := 0
	var fading := 0
	for i in mesh.get_surface_count():
		var tris: int = mesh.surface_get_array_index_len(i) / 3
		if tris == 0:
			tris = mesh.surface_get_array_len(i) / 3
		total += tris
		if _fades_at_rest(mesh.surface_get_material(i)):
			fading += tris
	if fading > 0:
		print("[rest] %s: %d of %d triangles fade out at rest" % [name, fading, total])
	check(total > 0 and fading * 2 <= total, "%s: drawn at rest, not faded out with its glow (%d of %d triangles fade)" % [name, fading, total])


## True for a material drawn see-through that fades out at rest (glow_fades), every row of it when merged.
func _fades_at_rest(material: Material) -> bool:
	var m := material as ShaderMaterial
	if m == null or m.shader != ModelLibrary.FactorioAlphaShader:
		return false
	var rows: Array = ModelLibrary.MaterialRows.rows(m)
	if rows.is_empty():
		return m.get_shader_parameter("glow_fades") == true
	for r in rows:
		if (r as ShaderMaterial).get_shader_parameter("glow_fades") != true:
			return false
	return true


## Every model in a modeller's folder (its pipes, ores and plates too) drawn at rest (_check_rest_visible).
## A modeller's folder's items (`items/*.glb`, Vasillo's plates and bricks with base-colour pictures):
## each the folder's item model, read with its picture (item_models.gd), drawn with it in the game's
## MultiMeshes and the preview; its numbered ores (`iron-ore-1`...) make it a provider of the ore
## (ModelPacks.provides: the Model packs window's cards, the order, a choice).
func _modeller_items_ores(pv: ModelPreview, folder: String) -> void:
	const ItemModels := preload("res://scripts/world/item_models.gd")
	var MP = ModelLibrary.ModelPacks
	var items := 0
	for f: String in DirAccess.get_files_at(folder.path_join("items")):
		if f.get_extension().to_lower() != "glb":
			continue
		var item := f.get_basename()
		var path := folder.path_join("items").path_join(f)
		var mesh := ItemModels.mesh_for(item)
		var tex := ItemModels.picture(mesh)
		check(str(MP.item_model_path(item)).replace("\\", "/") == path.replace("\\", "/") and tex != null
			and ItemModels.material_for(mesh).get_shader_parameter("picture") == tex,
			"%s: the folder's item model, drawn with its picture (%s)" % [item, MP.item_model_path(item)])
		pv.show_item(item, path)
		for i in 600:
			if pv.settled():
				break
			await process_frame
		var body := pv._holder.find_child("Body", true, false) as MeshInstance3D
		var shown_tex: Texture2D = (body.material_override as StandardMaterial3D).albedo_texture if body != null and body.material_override is StandardMaterial3D else null
		check(shown_tex != null, "%s: the preview shows its picture" % item)
		items += 1
	var ores: Array = []
	for ore: String in MP.NUMBERED_FAMILIES:
		if FileAccess.file_exists(folder.path_join(ore + "-1.glb")):
			ores.append(ore)
			check(MP.provides_in(MP.ARG_ID, ore), "%s: the folder's numbered rocks make it a provider of %s" % [ore, ore])
	pv.show_item("")
	print("  a modeller's folder: %d item(s) with pictures, %d ore(s) provided: %s" % [items, ores.size(), ores])
	ItemModels._cache.clear()
	ItemModels._paths.clear()


func _rest_visible_dir(folder: String) -> void:
	var files := DirAccess.get_files_at(folder)
	files.sort()
	var seen := 0
	for file in files:
		if not file.ends_with(".glb"):
			continue
		var mesh := ModelLibrary.mesh_for(file.get_basename() + "@arg")
		check(mesh != null, "%s: loads from the modeller's folder" % file)
		if mesh != null:
			_check_rest_visible(mesh, file.get_basename() + "@arg")
			seen += 1
	print("[rest] %d models of the modeller's folder checked for being drawn at rest" % seen)


## The whole model drawn, as the world draws it: the library's body and every moving part that isn't a
## lit_ one (a baked part at its rest box), together covered by the preview's drawn pieces, box and
## surfaces. A piece counts only when it can show: a MultiMesh's one instance needs a whole transform
## (a new instance's is zeros, which drew Vasillo's burner drill's vibrating body and a belt's base and
## rollers collapsed to a point: only the drill's legs and chimney, the belt's surface, showed). A
## hidden piece counts when Play animation's copy stands in for it.
func _check_whole(pv: ModelPreview, name: String) -> void:
	var mesh := ModelLibrary.mesh_for(name)
	if mesh == null:
		return
	var want := mesh.get_aabb()
	var want_surfaces := mesh.get_surface_count()
	var baked_parts := 0
	for part: ModelLibrary.AnimPart in ModelLibrary.parts_for(name):
		if part.mesh == null or part.lit:
			continue
		want = want.merge(ModelPreview.baked_rest_box(part) if part.kind == "baked" else part.mesh.get_aabb())
		want_surfaces += part.mesh.get_surface_count()
		if part.kind == "baked":
			baked_parts += 1
	var drawn := AABB()
	var first := true
	var surfaces := 0
	var baked_drawn := 0
	for c: Node in pv._holder.get_children():
		var g := c as GeometryInstance3D
		if g == null or not g.visible:
			continue
		var b: AABB
		var count := 0
		if g is MeshInstance3D:
			b = g.transform * (g as MeshInstance3D).mesh.get_aabb()
			count = (g as MeshInstance3D).mesh.get_surface_count()
		else:
			var mm := (g as MultiMeshInstance3D).multimesh
			var xf: Variant = g.get_meta("instance_xf") if g.has_meta("instance_xf") else null
			var whole := xf is Transform3D and absf((xf as Transform3D).basis.determinant()) > 0.5
			if g.has_meta("anim_part"):
				check(whole, "%s: %s a baked part whose instance has a whole transform (zeros draw it as a point): %s" % [name, g.name, xf])
			elif not whole:
				whole = str(g.name).begins_with("Playing")  # Play animation's copies set theirs (preview_anim.gd)
			if not whole:
				continue
			b = g.transform * ((g.get_meta("rest_box") as AABB) if g.has_meta("rest_box") else mm.mesh.get_aabb())
			count = mm.mesh.get_surface_count()
			if g.has_meta("anim_part"):
				baked_drawn += 1
		drawn = b if first else drawn.merge(b)
		first = false
		surfaces += count
	check(not first and drawn.grow(0.02).encloses(want), "%s: the drawn pieces cover the model's box: %s against %s" % [name, drawn, want])
	check(surfaces >= want_surfaces, "%s: the drawn pieces hold the model's %d surfaces: %d" % [name, want_surfaces, surfaces])
	check(baked_drawn >= baked_parts, "%s: every baked part drawn: %d of %d" % [name, baked_drawn, baked_parts])
	if ModelLibrary.file_of(name) == "burner-mining-drill":
		# The body vibrates (its bone Vibrate): nearly all of it is the baked part, the box with the head and burner.
		var body_part := false
		for part: ModelLibrary.AnimPart in ModelLibrary.parts_for(name):
			if part.kind == "baked" and ModelPreview.baked_rest_box(part).size.y > 2.0:
				body_part = true
		check(body_part and baked_drawn >= 1, "%s: the drill's vibrating body drawn as its baked part" % name)


## An inserter's preview holds its base and its arm at rest (InserterArms.resting_pieces), the arm's grip where the
## world's resting arm puts it (InserterArms._rest_arm: over the pickup, at the grip's height), drawn by the model's
## rig when it has one, else Wube's pieces; the framing (_check_drawn) includes the arm.
func _check_arm(pv: ModelPreview, name: String) -> void:
	var proto_name := ModelLibrary.file_of(name)
	var want: Array = InserterArms.resting_pieces(name)
	check(want.size() >= 2, "%s: an arm at rest: %d pieces" % [name, want.size()])
	if want.size() < 2:
		return
	var drawn: Array = []
	for c in pv._holder.get_children():
		var mi := c as MeshInstance3D
		if mi != null and mi.name != "Body":
			drawn.append(mi)
	for w: Array in want:
		var found := false
		for mi: MeshInstance3D in drawn:
			if mi.transform.is_equal_approx(w[1]) and mi.mesh.get_aabb().is_equal_approx((w[0] as Mesh).get_aabb()):
				found = true
		check(found, "%s: the arm's piece drawn in the preview at %s" % [name, w[1]])
	# The world's resting arm for the same inserter at the origin facing north.
	var arms = InserterArms.new()
	var proto := ProtoDB.EntityProto.new()
	proto.name = proto_name
	proto.type = "inserter"
	var rec := {"proto_id": 1, "pos": Vector2.ZERO, "dir": 0, "extra": {}}
	var rig := ModelLibrary.rig_for(name)
	var buf := PackedFloat32Array()
	arms._rest_arm(buf, rec, proto, rig)
	var claw: float = 1.0
	if rig.is_empty():
		arms._arm_meshes(proto_name, name.substr(name.find("@")))
		claw = arms._claw.get(proto_name, 1.0)
	InserterArms._free_scratch(arms)
	check(buf.size() == 48, "%s: the world's resting arm worked out" % name)
	if buf.size() < 48:
		return
	var placed := ModelLibrary.placed(proto_name, "inserter", 0, {}, Vector3.ZERO)
	# (the hand box's middle, 16 floats an instance: the origin is x, y, z at 3, 7, 11)
	var world_grip := Vector3(buf[35], buf[39], buf[43]) - Vector3(0.0, InserterArms.REST_HAND.y * 0.5, 0.0)
	var grip: Vector3
	if not rig.is_empty():
		var upper := Transform3D.IDENTITY
		for w: Array in want:
			if w[0] == (rig["meshes"] as Array)[ModelLibrary.ModelRig.Part.UPPER]:
				upper = placed * (w[1] as Transform3D)
		grip = upper.origin + upper.basis * ((rig["grip"] as Vector3) - (rig["elbow"] as Vector3))
	else:
		var lengths: Array = InserterArms.ARM_LENGTHS[InserterArms.ARM_FAMILIES.get(proto_name, "basic")]
		var up: Transform3D = placed * (want[0][1] as Transform3D)
		var hand: Transform3D = placed * (want[1][1] as Transform3D)
		var elbow := up.origin + up.basis.y.normalized() * 0.05 - up.basis.z * float(lengths[0])
		var wrist := hand.origin + hand.basis.y.normalized() * 0.05 - hand.basis.z * float(lengths[1])
		grip = elbow + (wrist - elbow) * claw
	check(grip.distance_to(world_grip) < 0.02, "%s: the hand over the pickup where the world's resting arm has it: %s against %s"
		% [name, grip, world_grip])

## Play animation on an inserter: its arm swings from the pickup (north) round to the drop (south) and back,
## each frame posed as inserter_arms.gd poses an arm for that hand and grip (posed_pieces: the world's _draw_*
## calls), the hand where the world's grip goes; the item taken at the pickup and let go at the drop, a rig's
## pincers closing and opening; the hand moving (arm_moving) while it plays. Stopped, back at rest. Returns the
## hand's furthest reach.
func _play_arm(pv: ModelPreview, name: String) -> float:
	pv.interactive = false
	await _show(pv, name)
	await process_frame
	var rig := ModelLibrary.rig_for(name)
	print("%s: arm by %s" % [name, "its rig" if not rig.is_empty() else "Wube's pieces"])
	check(pv.can_play(), "%s: an inserter can play (its arm swings)" % name)
	pv.set_playing(true)
	var state := pv.play_state()
	var nodes: Array = []
	for c in pv._holder.get_children():
		if c.has_meta("arm_piece"):
			nodes.append(c)
	check(state.playing and nodes.size() >= 2, "%s: playing, %d arm pieces" % [name, nodes.size()])
	var posing = InserterArms.new_posing()
	var placed := ModelLibrary.placed(ModelLibrary.file_of(name), "inserter", 0, {}, Vector3.ZERO)
	var posed_ok := true
	var grip_ok := true
	var furthest := 0.0
	var phase := 0  # 0 at the pickup side, 1 reached the drop side, 2 back at the pickup side
	var took_at_pick := false
	var let_go_at_drop := false
	var was_holding := false
	var closed := 0.0
	var opened_after := false
	var moving := false
	for i in 600:
		state.process(pv._holder, 1.0 / 60.0)
		var posed: Dictionary = posing.posed_pieces(name, state.hand, state.close, state.holding)
		var pieces: Array = posed["pieces"]
		for n: Node3D in nodes:
			var w: Transform3D = (pieces[int(n.get_meta("arm_piece"))] as Array)[1]
			if n.transform.origin.distance_to(w.origin) > 1e-4 or not n.transform.basis.is_equal_approx(w.basis):
				posed_ok = false
		if posed["gripped"]:
			var g: Vector3 = placed * (posed["grip"] as Vector3)
			if Vector2(g.x, g.z).distance_to(state.hand) > 0.01:
				grip_ok = false
		furthest = maxf(furthest, state.hand.length())
		if phase == 0 and state.hand.y > 0.5:
			phase = 1
		elif phase == 1 and state.hand.y < -0.5:
			phase = 2
		if state.holding and not was_holding and state.hand.y < -0.5 and absf(state.hand.x) < 0.05:
			took_at_pick = true
		if was_holding and not state.holding and state.hand.y > 0.5 and absf(state.hand.x) < 0.05:
			let_go_at_drop = true
		was_holding = state.holding
		closed = maxf(closed, state.close)
		if closed > 0.99 and state.close < 0.01:
			opened_after = true
		moving = moving or state.arm_moving
	InserterArms._free_scratch(posing)
	check(posed_ok, "%s: every frame the arm's pieces where inserter_arms.gd poses them for that hand and grip" % name)
	check(grip_ok, "%s: the grip at the hand's place" % name)
	check(phase == 2, "%s: the hand from the pickup to the drop and back (%d)" % [name, phase])
	check(took_at_pick and let_go_at_drop, "%s: the item taken at the pickup (%s) and let go at the drop (%s)"
		% [name, took_at_pick, let_go_at_drop])
	check(opened_after, "%s: the grip closes and opens (most %.2f)" % [name, closed])
	check(moving, "%s: the hand said moving while it swings" % name)
	pv.set_playing(false)
	var rest: Array = InserterArms.resting_pieces(name)
	var rest_ok := not state.arm_moving and rest.size() == nodes.size()
	for n: Node3D in nodes:
		var w: Transform3D = (rest[int(n.get_meta("arm_piece"))] as Array)[1]
		rest_ok = rest_ok and n.transform.origin.distance_to(w.origin) < 0.02 \
			and (n.transform.basis.x - w.basis.x).length() < 0.02 and (n.transform.basis.z - w.basis.z).length() < 0.02
	check(rest_ok, "%s: stopped, the arm back at rest" % name)
	return furthest


## Every moving part and end piece drawn as the world draws it at rest: each surface the game's model
## shader, a modeller's baked part (model_skin.gd) as a MultiMesh whose instance the shader skins
## (anim_mode 8, its bones, a timed instance's custom data), which put as stored lay turned a quarter
## (Vasillo's splitter: its gears and belts a strip down its middle, lavender caps over them). A
## splitter's baked parts stand inside its body, its belts across both halves; its end pieces on
## each half's back and front, outside the body's middle.
func _check_parts(pv: ModelPreview, name: String) -> void:
	var body := pv.find_child("Body", true, false) as MeshInstance3D
	if body == null:
		return
	var body_box := body.mesh.get_aabb()
	var baked := 0
	var widest := AABB()
	for c: Node in pv._holder.get_children():
		var mesh: Mesh = (c as MeshInstance3D).mesh if c is MeshInstance3D else (c as MultiMeshInstance3D).multimesh.mesh
		for i in mesh.get_surface_count():
			var m := mesh.surface_get_material(i) as ShaderMaterial
			check(m != null and m.shader != null and m.shader.resource_path.begins_with("res://shaders/factorio_material"),
				"%s: %s surface %d drawn with the game's model shader: %s" % [name, c.name, i, mesh.surface_get_material(i)])
		if not (c is MultiMeshInstance3D):
			continue
		if not c.has_meta("rest_box"):
			# A plain mesh's belt surface drawn by Play animation's copy at rest, standing still.
			check(str(c.name).begins_with("Playing") and pv.play_state().custom_of(c) == Anim.BELT_STOPPED,
				"%s: %s a belt surface's copy, standing still at rest" % [name, c.name])
			continue
		baked += 1
		var mm := (c as MultiMeshInstance3D).multimesh
		# (Headless, the dummy renderer keeps no instance data to read back: the value written is checked.)
		var custom := ModelPreview.PART_AT_REST if DisplayServer.get_name() == "headless" else mm.get_instance_custom_data(0)
		check(mm.use_custom_data and mm.instance_count == 1 and custom.b < -0.5,
			"%s: %s a timed instance the shader skins: %s" % [name, c.name, custom])
		for i in mesh.get_surface_count():
			var m := mesh.surface_get_material(i) as ShaderMaterial
			check(m != null and m.get_shader_parameter("anim_mode") == 8 and m.get_shader_parameter("bake_tex") is Texture2D,
				"%s: %s surface %d set up for its bones (anim_mode 8, bake_tex)" % [name, c.name, i])
		if not str(c.name).begins_with("BeltEnd"):
			var rest: AABB = c.get_meta("rest_box")
			check(body_box.grow(0.15).encloses(rest), "%s: %s at rest inside the body %s: %s" % [name, c.name, body_box, rest])
			var part: ModelLibrary.AnimPart = c.get_meta("anim_part", null)
			if name == "splitter@arg" and part != null and part.roller:
				# Its axle across the belt, as it stands in the file: Vasillo's rollers' keys left out that
				# turn and lay them along the belt (fix_pack.py keep_rest_turn puts it back).
				check(rest.size.x > 2.0 * rest.size.z, "%s: %s a roller across its belt at rest: %s" % [name, c.name, rest])
			if rest.size.x > widest.size.x:
				widest = rest
	if baked > 0:
		_play_baked(pv, name, baked)
	if name == "splitter@arg":  # the modeller's, with its baked parts and end pieces
		check(baked >= 2, "%s: its baked parts drawn skinned: %d" % [name, baked])
		check(widest.position.x < -0.9 and widest.end.x > 0.9 and widest.size.z < 1.2,
			"%s: its belts and gears across both halves, not turned a quarter: %s" % [name, widest])
		var box := pv.model_box()
		check(box.size.z < 1.3, "%s: the framed box the splitter's own depth: %s" % [name, box])
		var ends := 0
		for c: Node in pv._holder.get_children():
			if not (str(c.name).begins_with("BeltEnd") and c is MeshInstance3D):
				continue
			ends += 1
			var at := (c as Node3D).transform
			var b := at * (c as MeshInstance3D).mesh.get_aabb()
			check(absf(absf(at.origin.x) - 0.5) < 0.001 and absf(b.get_center().z) > 0.4,
				"%s: %s on a half's back or front, outside the body's middle: %s" % [name, c.name, b])
		check(ends == 4, "%s: a start and an end piece on each half: %d" % [name, ends])


## Play animation on a model with baked parts (Vasillo's rollers, a splitter's gears and belts): each is
## timed where it is, working on the animator's clock (not copied, so its bones' setup stays), every
## node Play makes has the pinned seed, and stopping puts each back at rest.
func _play_baked(pv: ModelPreview, name: String, baked: int) -> void:
	check(pv.can_play(), "%s: its baked parts can play" % name)
	var state := pv.play_state()
	pv.set_playing(true)
	var working := 0
	for mmi in state.in_place:
		var c: Color = state.custom_of(mmi)
		if c.b < -0.5 and int(floor(-c.b - 1.0)) & 1 == 1:
			working += 1
	check(state.in_place.size() == baked and working == baked,
		"%s: playing, its %d baked parts timed in place and working: %d, %d" % [name, baked, state.in_place.size(), working])
	var pin: Variant = (pv.find_child("Body", true, false) as GeometryInstance3D).get_instance_shader_parameter(&"f3d_seed_at")
	for c: Node in pv._holder.get_children():
		if c is MultiMeshInstance3D and not c.has_meta("rest_box"):
			var mesh := (c as MultiMeshInstance3D).multimesh.mesh
			for i in mesh.get_surface_count():
				var m := mesh.surface_get_material(i) as ShaderMaterial
				check(m == null or m.get_shader_parameter("anim_mode") != 8,
					"%s: %s a copy of a plain mesh only, the baked parts drawn in place" % [name, c.name])
		if c is GeometryInstance3D and (c as Node3D).visible:
			check((c as GeometryInstance3D).get_instance_shader_parameter(&"f3d_seed_at") == pin,
				"%s: %s reads its seed at the turning point while playing" % [name, c.name])
	pv.set_playing(false)
	var at_rest := 0
	for c: Node in pv._holder.get_children():
		if c.has_meta("rest_box") and state.custom_of(c) == ModelPreview.PART_AT_REST:
			at_rest += 1
	check(state.in_place.is_empty() and at_rest == baked, "%s: stopped, its baked parts back at rest: %d of %d" % [name, at_rest, baked])


## The light and the environment hold still while the model turns: the key light, the fill, the shadow
## map's mode and reach, the exposure, no TAA, SSAO or SSIL, no automatic levels of detail.
func _steady_light(pv: ModelPreview, name: String) -> void:
	await _show(pv, name)
	var env: Environment = (pv.viewport.find_children("*", "WorldEnvironment", true, false)[0] as WorldEnvironment).environment
	var state := func() -> Array:
		var lights: Array = []
		for l: DirectionalLight3D in pv.viewport.find_children("*", "DirectionalLight3D", true, false):
			lights.append([l.global_transform, l.light_energy, l.shadow_enabled, l.directional_shadow_mode,
				l.directional_shadow_max_distance, l.shadow_bias, l.shadow_blur])
		return [lights, env.tonemap_mode, env.tonemap_exposure, env.ssao_enabled, env.ssil_enabled, env.sdfgi_enabled,
			env.glow_enabled, pv.viewport.use_taa, pv.viewport.mesh_lod_threshold, pv.camera_position()]
	var first: Array = state.call()
	var turn_was: float = pv._spin.rotation.y
	var same := true
	for i in 30:
		await process_frame
		same = same and state.call() == first
	check(pv._spin.rotation.y != turn_was, "%s: the model turns meanwhile" % name)
	check(same, "the preview's lights, shadow, exposure and camera stay the same while the model turns")
	var key := pv.key_light()
	check(key.directional_shadow_mode == DirectionalLight3D.SHADOW_ORTHOGONAL and key.directional_shadow_max_distance < 60.0
		and pv.viewport.find_children("*", "DirectionalLight3D", true, false).size() == 2 and not pv._fill.shadow_enabled,
		"one orthogonal shadow map fitted to the model (%.1f tiles) and a fill light without one" % key.directional_shadow_max_distance)
	_game_light(pv, env)
	check(not pv.viewport.use_taa and pv.viewport.mesh_lod_threshold == 0.0 and not env.ssao_enabled and not env.ssil_enabled,
		"no TAA, automatic levels of detail, SSAO or SSIL in the preview")


## lighting-fixes step 6: the preview is lit as a game is, the Factorio look at noon on Nauvis (Looks.noon_rig: its
## held sun, ambient, the lighting environment in the sky's cubemap, its tonemapping), and the studio light before it
## comes back with set_studio (the window's button) and goes again.
func _game_light(pv: ModelPreview, env: Environment) -> void:
	var rig := Looks.noon_rig()
	var key := pv.key_light()
	var mat := env.sky.sky_material as ShaderMaterial if env.sky != null else null
	var game := [key.rotation_degrees, key.light_energy, key.light_specular, env.ambient_light_source, env.tonemap_mode, env.tonemap_exposure]
	check(not pv.studio and key.rotation_degrees.is_equal_approx(rig["sun_rotation"]) and is_equal_approx(key.light_energy, float(rig["sun_energy"]))
		and is_equal_approx(key.light_specular, float(rig["sun_specular"])) and env.ambient_light_source == Environment.AMBIENT_SOURCE_SKY
		and env.reflected_light_source == Environment.REFLECTION_SOURCE_SKY and mat != null and mat.shader == PlanetSky.SKY_SHADER
		and float(mat.get_shader_parameter("env_on")) > 0.5 and (mat.get_shader_parameter("env_sky") as Vector3).is_equal_approx(rig["env_sky"])
		and env.tonemap_mode == int(rig["tonemap"]) and is_equal_approx(env.tonemap_exposure, float(rig["exposure"]))
		and env.background_mode == Environment.BG_COLOR and env.background_color == ModelPreview.BACKDROP
		and pv._fill.visible == (float(rig["fill_light"]) > 0.0) and is_equal_approx(pv._fill.light_energy, float(rig["fill_light"]))
		and is_equal_approx(pv._fill.rotation_degrees.x, -Looks.FILL_PITCH),
		"the preview is lit as the game at noon (the Factorio look's sun, fill light, ambient, sky cubemap, tonemap): %s" % [game])
	pv.set_studio(true)
	var old := [key.rotation_degrees, key.light_energy, env.ambient_light_source, env.tonemap_mode]
	check(key.rotation_degrees.is_equal_approx(Vector3(-50, -40, 0)) and is_equal_approx(key.light_energy, 1.4) and pv._fill.visible
		and pv._fill.rotation_degrees.is_equal_approx(Vector3(-30, 140, 0)) and is_equal_approx(pv._fill.light_energy, 0.35)
		and env.ambient_light_source == Environment.AMBIENT_SOURCE_COLOR and env.sky.sky_material is ProceduralSkyMaterial
		and env.tonemap_mode == Environment.TONE_MAPPER_FILMIC,
		"the studio light comes back with its switch (key, fill, grey sky, filmic): %s" % [old])
	pv.set_studio(false)
	check(key.rotation_degrees.is_equal_approx(rig["sun_rotation"]) and is_equal_approx(pv._fill.light_energy, float(rig["fill_light"]))
		and env.ambient_light_source == Environment.AMBIENT_SOURCE_SKY,
		"and goes again: the game's light")


## One even backdrop at every tilt: the floor is the background's own colour (no ambient, sky or
## specular on it, only the key light's shadow, faded out round the model), lit by the key light
## alone, casting nothing. Pixels of an empty preview at tilts 5, 45 and 85 when the renderer makes
## them (headless makes none).
func _backdrop(pv: ModelPreview) -> void:
	await _show(pv, "copper-ore@builtin:placeholders")
	var env: Environment = (pv.viewport.find_children("*", "WorldEnvironment", true, false)[0] as WorldEnvironment).environment
	var ground: MeshInstance3D = pv._ground
	var mat := ground.material_override as ShaderMaterial
	check(mat != null and mat.get_shader_parameter("backdrop") == env.background_color
		and env.background_mode == Environment.BG_COLOR,
		"the floor is the backdrop's colour: %s against %s" % [mat.get_shader_parameter("backdrop") if mat else null, env.background_color])
	var code := mat.shader.code if mat != null else ""
	check(code.contains("ambient_light_disabled") and code.contains("specular_disabled") and code.contains("ATTENUATION"),
		"the floor takes no ambient, sky or specular light, only the key light's shadow")
	var fade_from: float = mat.get_shader_parameter("fade_from")
	var fade_to: float = mat.get_shader_parameter("fade_to")
	var half: float = (ground.mesh as PlaneMesh).size.x * 0.5
	check(fade_from > 0.0 and fade_to > fade_from and fade_to < half * 0.5,
		"the shadow fades out (%.1f-%.1f tiles) well inside the floor (%.0f)" % [fade_from, fade_to, half])
	var fill: DirectionalLight3D = pv._fill
	check((fill.light_cull_mask & ground.layers) == 0 and (pv.key_light().light_cull_mask & ground.layers) != 0
		and ground.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"the floor lit by the key light alone and casting nothing")
	if DisplayServer.get_name() == "headless":
		print("SKIP: no pixels headless: the backdrop at tilts 5, 45, 85 not sampled")
		return
	pv.show_model("")
	var means: Array = []
	for t: float in [5.0, 45.0, 85.0]:
		pv.tilt = t
		pv._place(pv._fit_centre, pv._fit_dist, pv._fit_radius)
		for i in 3:
			await process_frame
		var img := pv.viewport.get_texture().get_image()
		if img == null or img.is_empty():
			print("SKIP: the preview's picture couldn't be read")
			return
		var sum := Color(0, 0, 0)
		for y in 9:
			for x in 9:
				sum += img.get_pixel(int(img.get_width() * (x + 0.5) / 9.0), int(img.get_height() * (y + 0.5) / 9.0))
		means.append(sum / 81.0)
	for m: Color in means:
		check(absf(m.get_luminance() - (means[0] as Color).get_luminance()) < 0.02, "the backdrop even at every tilt: %s" % [means])


## What flickered as the model turned held still: each piece's seed at the turning point (an
## off-centre model's origin circles it), supersampled with MSAA, belts' smear given in the menu.
func _no_flicker(pv: ModelPreview, name: String) -> void:
	pv.show_model("")
	await _show(pv, name)
	check(pv.viewport.scaling_3d_scale >= 2.0 and pv.viewport.scaling_3d_mode == Viewport.SCALING_3D_MODE_BILINEAR
		and pv.viewport.msaa_3d == Viewport.MSAA_4X, "the preview supersampled 2x with MSAA 4x")
	var body := pv.find_child("Body", true, false) as MeshInstance3D
	var origin_was := body.global_position
	var seeds_was: Array = []
	for g: GeometryInstance3D in pv._holder.find_children("*", "GeometryInstance3D", true, false):
		seeds_was.append(g.get_instance_shader_parameter(&"f3d_seed_at"))
	var steady := not seeds_was.is_empty()
	for s: Variant in seeds_was:
		steady = steady and s is Vector3 and (s as Vector3).y == 1.0
	var moved := 0.0
	for i in 30:
		await process_frame
		moved = maxf(moved, body.global_position.distance_to(origin_was))
		var k := 0
		for g: GeometryInstance3D in pv._holder.find_children("*", "GeometryInstance3D", true, false):
			steady = steady and k < seeds_was.size() and g.get_instance_shader_parameter(&"f3d_seed_at") == seeds_was[k]
			k += 1
	check(moved > 0.01, "%s: its origin circles the turning point (%.3f tiles)" % [name, moved])
	check(steady, "%s: every piece's seed held at the turning point while it turns: %s" % [name, seeds_was])
	check(BeltBlur.frame_dt > 0.0 or BeltBlur.sharp_now(), "with no world, the preview gives belts their frame's smear")


## The mouse: a left drag turns and tilts, the wheel zooms within its limits, the model stays put once
## moved, a double click puts the view back and it turns again; a thumbnail takes no mouse.
func _mouse(pv: ModelPreview, name: String) -> void:
	await _show(pv, name)
	pv.interactive = true
	check(pv.mouse_filter == Control.MOUSE_FILTER_STOP, "the big preview takes the mouse")
	var mid := pv.get_global_rect().get_center()
	var fitted := pv.camera_position()
	var tilt_was := pv.tilt
	var press := func(at: Vector2, down: bool, which := MOUSE_BUTTON_LEFT, double := false) -> void:
		var e := InputEventMouseButton.new()
		e.button_index = which
		e.pressed = down
		e.double_click = double
		e.position = at
		e.global_position = at
		e.button_mask = MOUSE_BUTTON_MASK_LEFT if down and which == MOUSE_BUTTON_LEFT else 0
		e.factor = 1.0
		root.push_input(e)
	var drag := func(from: Vector2, by: Vector2) -> void:
		var e := InputEventMouseMotion.new()
		e.position = from + by
		e.global_position = from + by
		e.relative = by
		e.button_mask = MOUSE_BUTTON_MASK_LEFT
		root.push_input(e)
	press.call(mid, true)
	var spin_was: float = pv._spin.rotation.y
	drag.call(mid, Vector2(50, 0))
	drag.call(mid + Vector2(50, 0), Vector2(0, 30))
	press.call(mid + Vector2(50, 30), false)
	var turned := absf(angle_difference(pv._spin.rotation.y, spin_was))
	check(turned > deg_to_rad(15.0) and pv.tilt > tilt_was + 10.0 and pv.user_moved,
		"a drag turns the model %.0f degrees and tilts the camera %.0f -> %.0f" % [rad_to_deg(turned), tilt_was, pv.tilt])
	check((pv.camera_position() - pv._fit_centre).normalized().distance_to((fitted - pv._fit_centre).normalized()) > 0.1,
		"the camera's angle changed: %s from %s" % [pv.camera_position(), fitted])
	var after_drag: float = pv._spin.rotation.y
	for i in 20:
		await process_frame
	check(pv._spin.rotation.y == after_drag, "once dragged the model stays where it was put")
	var dist_was := (pv.camera_position() - pv._fit_centre).length()
	press.call(mid, true, MOUSE_BUTTON_WHEEL_UP)
	var nearer := (pv.camera_position() - pv._fit_centre).length()
	check(nearer < dist_was * 0.95, "the wheel zooms in: %.2f -> %.2f" % [dist_was, nearer])
	for i in 40:
		press.call(mid, true, MOUSE_BUTTON_WHEEL_DOWN)
	check(is_equal_approx(pv.zoom, ModelPreview.ZOOM_MAX), "and out, no further than its limit: %.2f" % pv.zoom)
	press.call(mid, true)
	for i in 40:
		drag.call(mid, Vector2(0, 40))
	press.call(mid, false)
	check(pv.tilt == ModelPreview.TILT_MAX, "the tilt keeps within its range: %.0f" % pv.tilt)
	press.call(mid, true, MOUSE_BUTTON_LEFT, true)
	press.call(mid, false)
	check(not pv.user_moved and pv.zoom == 1.0 and pv.tilt == ModelPreview.TILT and pv.camera_position().distance_to(fitted) < 0.001,
		"a double click puts the view back: %s against %s" % [pv.camera_position(), fitted])
	var spin_reset: float = pv._spin.rotation.y
	for i in 5:
		await process_frame
	check(pv._spin.rotation.y != spin_reset, "and it turns by itself again")
	await _pan(pv, press, mid, fitted)
	pv.interactive = false
	check(pv.mouse_filter == Control.MOUSE_FILTER_IGNORE, "a thumbnail takes no mouse")


## A right (or middle) drag pans: the model's middle follows the cursor on screen, no further than the
## picture's middle 90%; orbit and the wheel still work panned; a double click and a new model undo it.
func _pan(pv: ModelPreview, press: Callable, mid: Vector2, fitted: Vector3) -> void:
	var on_screen := func() -> Vector2:
		var vs := Vector2(pv.viewport.size)
		var at := pv._camera.unproject_position(pv._world.global_transform * (pv._spin.position + pv._fit_centre))
		return at * pv.size / vs
	var drag := func(from: Vector2, by: Vector2, mask: int) -> void:
		var e := InputEventMouseMotion.new()
		e.position = from + by
		e.global_position = from + by
		e.relative = by
		e.button_mask = mask
		root.push_input(e)
	var right := func(at: Vector2, down: bool, which: int) -> void:
		var e := InputEventMouseButton.new()
		e.button_index = which
		e.pressed = down
		e.position = at
		e.global_position = at
		e.button_mask = (MOUSE_BUTTON_MASK_RIGHT if which == MOUSE_BUTTON_RIGHT else MOUSE_BUTTON_MASK_MIDDLE) if down else 0
		root.push_input(e)
	var was: Vector2 = on_screen.call()
	var spin_was: float = pv._spin.rotation.y
	var tilt_was := pv.tilt
	right.call(mid, true, MOUSE_BUTTON_RIGHT)
	drag.call(mid, Vector2(30, -20), MOUSE_BUTTON_MASK_RIGHT)
	right.call(mid + Vector2(30, -20), false, MOUSE_BUTTON_RIGHT)
	var moved: Vector2 = on_screen.call() - was
	check(moved.distance_to(Vector2(30, -20)) < 1.0 and pv.pan != Vector2.ZERO and pv.user_moved,
		"a right drag of (30, -20) moves the model's middle on screen with the cursor: %s" % moved)
	check(pv._spin.rotation.y == spin_was and pv.tilt == tilt_was, "and doesn't turn or tilt it")
	var pan_was := pv.pan
	right.call(mid, true, MOUSE_BUTTON_MIDDLE)
	drag.call(mid, Vector2(-10, 0), MOUSE_BUTTON_MASK_MIDDLE)
	right.call(mid, false, MOUSE_BUTTON_MIDDLE)
	check(pv.pan.x > pan_was.x, "a middle drag pans too: %s -> %s" % [pan_was, pv.pan])
	right.call(mid, true, MOUSE_BUTTON_RIGHT)
	for i in 20:
		drag.call(mid, Vector2(400, 300), MOUSE_BUTTON_MASK_RIGHT)
	right.call(mid, false, MOUSE_BUTTON_RIGHT)
	var far: Vector2 = on_screen.call()
	var inner := Rect2(pv.size * 0.05, pv.size * 0.9).grow(1.0)
	check(inner.has_point(far) and (far.x > pv.size.x * 0.94 or far.y > pv.size.y * 0.94),
		"a pan past the limit stops with the middle at the picture's middle 90%%: %s in %s" % [far, pv.size])
	var spin_at := pv._spin.rotation.y
	press.call(mid, true)
	var e := InputEventMouseMotion.new()
	e.position = mid + Vector2(40, 0)
	e.global_position = e.position
	e.relative = Vector2(40, 0)
	e.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(e)
	press.call(mid, false)
	check(absf(angle_difference(pv._spin.rotation.y, spin_at)) > deg_to_rad(10.0), "panned, a left drag still turns it")
	var zoom_was := pv.zoom
	press.call(mid, true, MOUSE_BUTTON_WHEEL_UP)
	check(pv.zoom < zoom_was, "panned, the wheel still zooms: %.2f -> %.2f" % [zoom_was, pv.zoom])
	press.call(mid, true, MOUSE_BUTTON_LEFT, true)
	press.call(mid, false)
	check(pv.pan == Vector2.ZERO and pv.zoom == 1.0 and pv.tilt == ModelPreview.TILT and pv.camera_position().distance_to(fitted) < 0.001,
		"a double click puts back the pan, orbit and zoom: %s, %s against %s" % [pv.pan, pv.camera_position(), fitted])
	right.call(mid, true, MOUSE_BUTTON_RIGHT)
	drag.call(mid, Vector2(25, 15), MOUSE_BUTTON_MASK_RIGHT)
	right.call(mid, false, MOUSE_BUTTON_RIGHT)
	var name := pv.model
	await _show(pv, "cliff-entrance@builtin:placeholders")
	check(pv.pan == Vector2.ZERO and not pv.user_moved, "a new model starts unpanned: %s" % pv.pan)
	await _show(pv, name)


## Play animation: a model with moving parts plays them from the world's animator's state (working, on
## its clock, advancing), and stops back at rest; a belt's surface stands still at rest and scrolls while
## Rail and chain signals of every pack with one (FUE5's, the placeholders'): they can play; at rest lit
## green alone (a signal with no train, as the world shows one); playing, the state anim.gd reads (the
## bridge's `st`) goes through each colour the model has a lamp for, in order, each lit alone, and back;
## stopped, green again.
func _signals(pv: ModelPreview) -> void:
	pv.interactive = false
	var colours := {1: "lit_green", 2: "lit_yellow", 3: "lit_red", 4: "lit_blue"}
	var seen := 0
	for pack in ["fue5", "placeholders"]:
		for proto: String in PreviewAnim.SIGNAL_CYCLES:
			var name := "%s@builtin:%s" % [proto, pack]
			await _show(pv, name)
			await process_frame
			var state := pv.play_state()
			var kinds := {}
			for g: Anim.Group in state.groups:
				if g.part != null and g.part.lit:
					kinds[g.part.kind] = true
			if kinds.is_empty():
				check(false, "%s: no lit lamps drawn" % name)
				continue
			seen += 1
			check(pv.can_play(), "%s can play" % name)
			var idle: Array = ["lit_green"] if kinds.has("lit_green") else []
			check(state.signal_state() == PreviewAnim.SIGNAL_IDLE and _lit(state) == idle,
				"%s at rest: green alone (%s, state %d)" % [name, _lit(state), state.signal_state()])
			pv.set_playing(true)
			var order: Array = []
			for st: int in PreviewAnim.SIGNAL_CYCLES[proto]:
				if kinds.has(colours[st]):
					order.append(colours[st])
			var got: Array = []
			for step in (PreviewAnim.SIGNAL_CYCLES[proto] as Array).size() + 1:
				var lit := _lit(state)
				var want: String = colours[state.signal_state()]
				var alone: Array = [want] if kinds.has(want) else []
				check(lit == alone, "%s state %d: %s lit alone (%s)" % [name, state.signal_state(), want, lit])
				if kinds.has(want) and (got.is_empty() or got[-1] != want):
					got.append(want)
				state.process(pv._holder, PreviewAnim.SIGNAL_HOLD)
			check(got.size() == order.size() + 1 and got.slice(0, order.size()) == order and got[-1] == order[0],
				"%s cycles %s and back: %s" % [name, order, got])
			pv.set_playing(false)
			check(state.signal_state() == PreviewAnim.SIGNAL_IDLE and _lit(state) == idle,
				"%s stopped: idle again (%s)" % [name, _lit(state)])
			print("%s: lamps %s, cycle %s" % [name, kinds.keys(), got])
	check(seen == 4, "signals with lamps checked: %d of 4" % seen)


## The lit parts' kinds shown now (their custom data's shown flag, as anim.gd writes KIND_LIT), sorted.
func _lit(state) -> Array:
	var out: Array = []
	for g: Anim.Group in state.groups:
		if g.part == null or not g.part.lit:
			continue
		var flags := int(floor(-(g.customs[0] as Color).b - 1.0))
		if flags & 1 == 1 and not out.has(g.part.kind):
			out.append(g.part.kind)
	out.sort()
	return out


## playing; a chest has nothing to play. The speaker: a machine's working sound starts and stops, another
## model stops it, a chest has none (all greyed without an install).
## Rolling stock's wheels playing (the owner: FUE5's wagon wheels spun about the vertical): each
## turns about its axle (X), its top towards the front (-Z), working on the animator's clock.
func _play_wheels(pv: ModelPreview) -> void:
	pv.interactive = false
	for name: String in ["cargo-wagon@builtin:fue5", "locomotive@builtin:fue5", "cargo-wagon@builtin:placeholders"]:
		await _show(pv, name)
		await process_frame
		check(pv.can_play(), "%s: its wheels can play" % name)
		var state := pv.play_state()
		pv.set_playing(true)
		var wheels := 0
		for g: Anim.Group in state.groups:
			if g.part == null or not g.part.kind.begins_with("wheel"):
				continue
			var c: Color = g.customs[0]
			var top: Vector3 = g.part.turned(-0.1) * (g.part.pivot.origin + Vector3.UP * g.part.wheel_radius()) - g.part.pivot.origin
			if c.b < -0.5 and int(floor(-c.b - 1.0)) & 1 == 1 and g.part.motion == Anim.MOTION_SPIN 					and g.part.axis.is_equal_approx(Vector3.RIGHT) and g.part.rate < 0.0 and top.z < 0.0:
				wheels += 1
		check(wheels >= 4, "%s: playing, its wheels roll forward about their axles: %d" % [name, wheels])
		pv.set_playing(false)


func _play(pv: ModelPreview) -> void:
	pv.interactive = false
	await _show(pv, "pumpjack@builtin:placeholders")
	await process_frame
	check(pv.can_play(), "the pumpjack has moving parts to play")
	var state := pv.play_state()
	pv.set_playing(true)
	check(pv.is_playing() and not state.groups.is_empty(), "playing: its parts drawn by the animator (%d groups)" % state.groups.size())
	var moving := 0
	for g: Anim.Group in state.groups:
		var c: Color = g.customs[0]
		var code := -c.b - 1.0
		var flags := int(floor(code))
		# Timed (b < 0), working (flag 1), as the world's anim.gd writes an entity seen working.
		if c.b < -0.5 and flags & 1 == 1 and g.part != null and g.part.motion > Anim.MOTION_NONE:
			moving += 1
	check(moving > 0, "a moving part's instance says working on the animator's clock: %d of %d" % [moving, state.groups.size()])
	var hidden := 0
	for c in pv._holder.get_children():
		if c is MeshInstance3D and not (c as MeshInstance3D).visible:
			hidden += 1
	check(hidden > 0 and state.copies.size() >= hidden, "the moving meshes drawn by their copies: %d hidden, %d copies" % [hidden, state.copies.size()])
	var t0 := state.time()
	for i in 10:
		await process_frame
	check(state.time() > t0, "the clock advances while playing: %.3f -> %.3f" % [t0, state.time()])
	pv.set_playing(false)
	var shown := 0
	for c in pv._holder.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).visible:
			shown += 1
	check(not pv.is_playing() and state.groups.is_empty() and state.time() == 0.0 and shown > 0, "stopped: back at rest, the originals drawn")
	# A belt: standing still at rest, scrolling while playing.
	await _show(pv, "transport-belt@builtin:wube3dp")
	await process_frame
	var rest_ok := state.copies.size() > 0
	for mmi in state.copies:
		rest_ok = rest_ok and state.custom_of(mmi) == Anim.BELT_STOPPED
	check(pv.can_play() and rest_ok, "a belt at rest: its surface stands still (%d copies)" % state.copies.size())
	pv.set_playing(true)
	var scrolling := state.copies.size() > 0
	for mmi in state.copies:
		var c: Color = state.custom_of(mmi)
		var flags := int(floor(-c.b - 1.0))
		scrolling = scrolling and c.b < -0.5 and flags & 1 == 1 and flags & 8 == 0
	check(scrolling, "and playing its surface runs (timed, working, not switched off)")
	pv.set_playing(false)
	# Nothing to play on a chest.
	await _show(pv, "wooden-chest@builtin:wube3dp")
	await process_frame
	pv.set_playing(true)
	check(not pv.can_play() and not pv.is_playing(), "a chest has nothing to play")
	# The speaker.
	if not SoundBank.available():
		check(pv.sound_reason() != "", "without an install the speaker is greyed: %s" % pv.sound_reason())
		print("SKIP: sounds (no Factorio install)")
		return
	SoundBank.prepare()
	for i in 3000:
		if SoundBank.ready():
			break
		await process_frame
	check(pv.sound_reason() != "", "a chest has no working sound: %s" % pv.sound_reason())
	pv.entity = "assembling-machine-1"
	await _show(pv, "assembling-machine-1@builtin:wube3dp")
	await process_frame
	check(pv.sound_reason() == "", "an assembler can sound: %s" % pv.sound_reason())
	pv.set_playing(true)
	# The preview alone stays silent (the building chooser's small cards); the Model packs window
	# turns its speaker on by default (ui_test's _model_packs_window).
	for i in 10:
		await process_frame
	check(not pv.sounding_on() and not pv.sound_playing(), "a preview alone is silent until its speaker is on")
	pv.set_sounding(true)
	for i in 600:
		if pv.sound_playing():
			break
		await process_frame
	check(pv.sound_playing(), "the speaker on: its working sound plays (%s)" % pv._sound.path)
	pv.set_sounding(false)
	await process_frame
	check(not pv.sound_playing(), "the speaker off: it stops")
	pv.set_sounding(true)
	for i in 600:
		if pv.sound_playing():
			break
		await process_frame
	pv.entity = ""
	await _show(pv, "wooden-chest@builtin:wube3dp")
	check(not pv.sound_playing() and not pv.sounding_on(), "another model shown: the sound stops")


## The owner's burner effects in the preview (burner_fx.gd): a modeller's burner inserter (its glowing
## burner) playing breathes, smokes from its grille and, with the speaker on, crackles; at rest none of it.
## Wube3DP's burner inserter has no glowing part: no smoke, no crackle.
func _burner(pv: ModelPreview, names: Array) -> void:
	await _show(pv, "burner-inserter@builtin:wube3dp")
	pv.set_playing(true)
	for i in 30:
		await process_frame
	check(not BurnerFx.burns(pv.shown_mesh) and not pv.burner_smoking() and pv.burner_wisps() == 0,
		"Wube3DP's burner inserter has no burner to smoke")
	pv.set_playing(false)
	if not names.has("burner-inserter@arg"):
		print("SKIP: the burner's effects (no modeller's burner inserter)")
		return
	await _show(pv, "burner-inserter@arg")
	var heats := 0
	for i in pv.shown_mesh.get_surface_count():
		var m := pv.shown_mesh.surface_get_material(i) as ShaderMaterial
		if m != null and m.get_shader_parameter("glow_heat") != null and float(m.get_shader_parameter("glow_heat")) > 0.0:
			heats += 1
	check(BurnerFx.burns(pv.shown_mesh) and heats > 0 and pv.can_play(), "a modeller's burner inserter: its burner's material breathes (%d)" % heats)
	for i in 20:
		await process_frame
	check(not pv.burner_smoking() and pv.burner_wisps() == 0, "at rest its burner doesn't smoke")
	pv.set_playing(true)
	var t0 := Time.get_ticks_msec()
	while pv.burner_wisps() < 2 and Time.get_ticks_msec() - t0 < 8000:
		await process_frame
	var smoke := pv.viewport.find_child("Smoke", true, false)
	check(pv.burner_smoking() and pv.burner_wisps() >= 2 and smoke != null,
		"playing, its burner smokes: %d wisps in %.1f s" % [pv.burner_wisps(), (Time.get_ticks_msec() - t0) / 1000.0])
	if SoundBank.available():
		check(pv.sound_reason() == "", "its speaker can sound (its crackle): %s" % pv.sound_reason())
		pv.set_sounding(true)
		for i in 600:
			if pv.sound_playing():
				break
			await process_frame
		check(pv.sound_playing() and pv._sound.path == BurnerFx.SOUND, "the speaker on: the crackle plays (%s)" % pv._sound.path)
		pv.set_sounding(false)
		await process_frame
		check(not pv.sound_playing(), "the speaker off: the crackle stops")
	pv.set_playing(false)
	await process_frame
	var wisps := pv.burner_wisps()
	for i in 30:
		await process_frame
	check(not pv.burner_smoking() and pv.burner_wisps() == wisps, "stopped: no more smoke")
	pv.show_model("")

## Play animation on a turret (preview_turret.gd): at rest its head stands as an idle turret's; playing,
## it raises, turns towards the target in front of it and fires at its weapon's cooldown, its flash,
## beam, stream or projectile drawn (the world's turrets.gd and weapon_fx.gd), the target in the
## picture; with the speaker on its sounds play; stopped, or another model shown, nothing is left.
func _turrets(pv: ModelPreview) -> void:
	var sounds := SoundBank.available()
	if sounds:
		SoundBank.prepare()
		for i in 3000:
			if SoundBank.ready():
				break
			await process_frame
	var dt := 1.0 / 60.0
	for name: String in TURRET_MODELS:
		await _show(pv, name)
		await process_frame
		var drv = pv.turret_state()
		var part = drv.head_of(name)
		var cfg: Dictionary = Turrets.TURRETS[ModelLibrary.file_of(name)]
		var kind := str(cfg["kind"])
		check(pv.can_play() and part != null, "%s: a turret can play" % name)
		if part == null:
			continue
		var idle_layer := Turrets.new()
		var idle: Transform3D = idle_layer.head_transform(0, part, Transform3D.IDENTITY, 0.0)
		idle_layer.free()
		var head: Node3D = null
		for c in pv._holder.get_children():
			if c is MeshInstance3D and (c as MeshInstance3D).mesh == part.mesh:
				head = c
		check(head != null and head.transform.is_equal_approx(idle), "%s: at rest its head stands as an idle turret's" % name)
		if sounds:
			check(pv.sound_reason() == "", "%s: its speaker can sound: %s" % [name, pv.sound_reason()])
			pv.set_sounding(true)
		pv.set_playing(true)
		pv.set_process(false)  # stepped by hand below, at 60 a second
		var fx: Node3D = drv.effects()
		check(drv.playing and fx != null and fx.is_inside_tree(), "%s: playing, its effects in the preview's world" % name)
		if fx == null:
			continue
		var cam: Camera3D = pv._camera
		var on_screen := cam.unproject_position(drv._target)
		check(not cam.is_position_behind(drv._target) and Rect2(Vector2.ZERO, Vector2(pv.viewport.size)).has_point(on_screen),
			"%s: the target in the picture (%s)" % [name, on_screen])
		var times: Array = []
		var effect := false
		var raised := false
		var err0 := -1.0
		var err := 1.0
		for i in int(14.0 / dt):
			drv.process(dt)
			var st = drv.state()
			if st == null:
				continue
			if st.target_seen > -100.0:
				err = absf(wrapf(st.goal - st.yaw, -0.5, 0.5))
				if err0 < 0.0:
					err0 = err
			raised = raised or st.fold >= 1.0
			while times.size() < st.fired:
				times.append(drv._clock)
			match kind:
				"laser", "tesla", "railgun":
					effect = effect or (st.beam_kind == kind and st.beam_left > 0.0)
				"rocket", "artillery":
					effect = effect or drv.weapons.flying_count() > 0
				_:
					effect = effect or drv.sprites.count() > 0
		var st = drv.state()
		check(raised, "%s: raised to fire" % name)
		check(err0 >= 0.0 and err < 0.03 and (err0 < 0.03 or err < err0),
			"%s: its head turned towards the target (%.3f -> %.3f turns off)" % [name, err0, err])
		var cooldown := float(cfg["cooldown"]) / 60.0
		var spacing := 100.0
		for k in range(1, times.size()):
			spacing = minf(spacing, float(times[k]) - float(times[k - 1]))
		var mean := (float(times[-1]) - float(times[0])) / (times.size() - 1) if times.size() > 1 else 100.0
		check(times.size() >= 2 and spacing >= cooldown - 1.5 / 60.0 and mean <= cooldown * 1.6,
			"%s: fires at its cooldown (%.2f s): %d shots, %.3f s apart at least, %.3f on average" % [name, cooldown, times.size(), spacing, mean])
		check(effect and st.light != null, "%s: its shot drawn (%s) with its flash" % [name, kind])
		var aim: Vector3 = drv._aim - pv._holder.global_position
		aim.y = 0.0
		var front: Vector3 = st.forward
		front.y = 0.0
		var out: Vector3 = drv._aim - st.muzzle
		out.y = 0.0
		check(front.angle_to(aim) < 0.25 and front.angle_to(out) < 0.5, "%s: its head points at the target (%.2f rad off)" % [name, front.angle_to(aim)])
		if sounds:
			for i in 300:
				if drv.speaker.started > 0:
					break
				drv.process(dt)
				await process_frame
			check(drv.speaker.started > 0, "%s: with the speaker on its sounds play (%s)" % [name, drv.speaker.last])
		pv.set_playing(false)
		check(not drv.playing and drv.effects() == null and not fx.is_inside_tree() and pv.viewport.find_child("TurretFx", true, false) == null,
			"%s: stopped, no effects left" % name)
		check(head.transform.is_equal_approx(idle), "%s: stopped, its head idle again" % name)
		pv.set_sounding(false)
		pv.set_process(true)
	# Another model shown while one fires: its effects go with it.
	await _show(pv, "gun-turret@builtin:placeholders")
	pv.set_playing(true)
	for i in 60:
		await process_frame
	var drv = pv.turret_state()
	var fx: Node3D = drv.effects()
	pv.show_model("wooden-chest@builtin:wube3dp")
	check(fx != null and not fx.is_inside_tree() and drv.effects() == null and not drv.playing,
		"another model shown: the turret's effects freed")
	await _show(pv, "wooden-chest@builtin:wube3dp")
	check(not pv.can_play(), "a chest is no turret")


## Static thumbnails (`turning = false`) share the cached floor Shader and freeze their SubViewport
## (UPDATE_DISABLED) after settling rather than re-rendering every frame, waking only on change.
func _static_thumbnail_cache(pv: ModelPreview) -> void:
	var thumb: ModelPreview = ModelPreview.new()
	thumb.turning = false
	thumb.size = Vector2(36, 36)
	root.add_child(thumb)
	var shared_floor := is_same((pv._ground.material_override as ShaderMaterial).shader,
		(thumb._ground.material_override as ShaderMaterial).shader)
	check(shared_floor, "two ModelPreviews share one compiled floor Shader")
	thumb.show_model("wooden-chest@builtin:placeholders")
	for i in 3000:
		if thumb.settled() and not thumb.is_processing():
			break
		await process_frame
	check(thumb.settled() and thumb.viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED
		and not thumb.is_processing(),
		"a static thumbnail freezes at UPDATE_DISABLED after settling (mode %d, proc %s)"
		% [thumb.viewport.render_target_update_mode, thumb.is_processing()])
	thumb.show_model("wooden-chest@builtin:wube3dp")
	var woke := thumb.viewport.render_target_update_mode == SubViewport.UPDATE_WHEN_VISIBLE
	for i in 3000:
		if thumb.settled() and not thumb.is_processing():
			break
		await process_frame
	check(woke and thumb.settled() and thumb.viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED
		and not thumb.is_processing(),
		"changing the static thumbnail's model wakes it to UPDATE_WHEN_VISIBLE, then freezes it again (woke %s, mode %d)"
		% [woke, thumb.viewport.render_target_update_mode])
	thumb.queue_free()
	await process_frame
