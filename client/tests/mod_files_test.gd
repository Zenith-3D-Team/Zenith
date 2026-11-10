extends SceneTree
## mod_files.gd against the fixture mod (tools/mod_tests/fixtures/zenith-gfx-test): read as a zip
## (files under a top folder of another name) and as a folder of another version, picked by the
## version the game runs; Factorio's paths split; pictures read on worker threads; the built-in
## mods from the install when there is one. Run headless:
##   godot --headless --path client -s res://tests/mod_files_test.gd
## Prints "MOD FILES FAILS: 0" when all pass; quits with 1 otherwise.

const ModFiles := preload("res://scripts/world/mod_files.gd")
const ItemIcons := preload("res://scripts/world/item_icons.gd")
const ModGraphics := preload("res://scripts/world/mod_graphics.gd")
const TerrainTextures := preload("res://scripts/world/terrain_textures.gd")
const Decoratives := preload("res://scripts/world/decoratives.gd")
const LocaleNames := preload("res://scripts/world/locale_names.gd")
const SpriteStandins := preload("res://scripts/world/sprite_standins.gd")
const Movers := preload("res://scripts/world/movers.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")

const MOD := "zenith-gfx-test"
var _fails := 0


func _check(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("FAIL: ", what)


func _initialize() -> void:
	var fixture := ProjectSettings.globalize_path("res://").path_join("../tools/mod_tests/fixtures").path_join(MOD).simplify_path()
	var dir := ProjectSettings.globalize_path("user://mod_files_test")
	_wipe(dir)
	DirAccess.make_dir_recursive_absolute(dir)
	# 1.0.0 as a zip whose top folder isn't the mod's name; 0.9.0 as a folder with another gizmo.
	var zip := ZIPPacker.new()
	_check(zip.open(dir.path_join(MOD + "_1.0.0.zip")) == OK, "zip written")
	_pack(zip, fixture, "renamed-top/")
	zip.close()
	var old := dir.path_join(MOD + "_0.9.0")
	DirAccess.make_dir_recursive_absolute(old.path_join("graphics/icons"))
	var info := FileAccess.open(old.path_join("info.json"), FileAccess.WRITE)
	info.store_string('{"name": "%s", "version": "0.9.0"}' % MOD)
	info.close()
	var small := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	small.fill(Color.RED)
	small.save_png(old.path_join("graphics/icons/gizmo.png"))
	# Something that isn't a mod, and another mod's zip the game doesn't run.
	DirAccess.make_dir_recursive_absolute(dir.path_join("not-a-mod"))
	var junk := FileAccess.open(dir.path_join("broken_1.0.0.zip"), FileAccess.WRITE)
	junk.store_string("not a zip")
	junk.close()
	ModFiles.extra_dirs = [dir]

	_check(ModFiles.split("__base__/graphics/x.png") == PackedStringArray(["base", "graphics/x.png"]), "split __base__/")
	_check(ModFiles.split("space-age/graphics/x.png") == PackedStringArray(["space-age", "graphics/x.png"]), "split icons.json's form")
	_check(ModFiles.split("__my_mod-2__/a/b.png") == PackedStringArray(["my_mod-2", "a/b.png"]), "split a name with _ and -")

	ModFiles.set_mods({MOD: "1.0.0", "base": "2.1.24"})
	_check(not ModFiles.is_ready() or ModFiles.locate(MOD).has("zip"), "the scan runs on a worker (or is already done)")
	_set_mods({MOD: "1.0.0", "base": "2.1.24"})
	var at := ModFiles.locate(MOD)
	_check(at.has("zip") and str(at.version) == "1.0.0" and str(at.root) == "renamed-top/", "the running version's zip: %s" % [at.get("zip", at)])
	var gizmo := "__%s__/graphics/icons/gizmo.png" % MOD
	_check(ModFiles.exists(gizmo), "a file in the zip exists")
	_check(not ModFiles.exists("__%s__/graphics/icons/nope.png" % MOD), "a missing one doesn't")
	_check(ModFiles.read("__%s__/graphics/icons/nope.png" % MOD).is_empty(), "a missing file reads empty")
	_check(ModFiles.load_image("__nobody__/x.png") == null, "an unknown mod's picture is null")
	var image := ModFiles.load_image(gizmo)
	_check(image != null and image.get_width() == 64, "the zip's gizmo is 64 px")
	var locale := ModFiles.files_in(MOD, "locale/en")
	_check(locale.size() == 1 and locale[0] == "__%s__/locale/en/%s.cfg" % [MOD, MOD], "locale files listed: %s" % [locale])
	_check(ModFiles.read(locale[0] if not locale.is_empty() else "").get_string_from_utf8().contains("Zenith test gizmo"), "a locale file read")

	_set_mods({MOD: "0.9.0"})
	at = ModFiles.locate(MOD)
	_check(at.has("dir") and str(at.version) == "0.9.0", "the folder when 0.9.0 runs")
	image = ModFiles.load_image(gizmo)
	_check(image != null and image.get_width() == 16, "the folder's gizmo is 16 px")

	_set_mods({})
	at = ModFiles.locate(MOD)
	_check(str(at.get("version", "")) == "1.0.0", "the newest without the game's list")

	# Worker threads, each with its own zip reader.
	_set_mods({MOD: "1.0.0"})
	_check(LocaleNames.item("zenith-test-gizmo") == "Zenith test gizmo" and LocaleNames.entity("zenith-test-crate") == "Zenith test crate",
		"names from the mod's locale in its zip: %s, %s" % [LocaleNames.item("zenith-test-gizmo"), LocaleNames.entity("zenith-test-crate")])
	if ItemIcons.factorio_data_dir() != "":
		_check(LocaleNames.item("iron-plate") == "Iron plate", "the game's own names stay")
	ModFiles.prepare()
	var results := []
	results.resize(32)
	var mutex := Mutex.new()
	var read := func(i: int) -> void:
		var img := ModFiles.load_image(gizmo if i % 2 == 0 else "__%s__/graphics/entity/crate.png" % MOD)
		mutex.lock()
		results[i] = img.get_size() if img != null else Vector2i.ZERO
		mutex.unlock()
	var group := WorkerThreadPool.add_group_task(read, 32)
	WorkerThreadPool.wait_for_group_task_completion(group)
	var good := 0
	for i in 32:
		if results[i] == (Vector2i(64, 64) if i % 2 == 0 else Vector2i(128, 160)):
			good += 1
	_check(good == 32, "32 reads on worker threads: %d right" % good)

	# Timing: every file of the zip, read once.
	var t0 := Time.get_ticks_usec()
	var n := 0
	for f: String in (ModFiles.locate(MOD).files as Dictionary):
		if f.ends_with(".png"):
			n += 1 if ModFiles.load_image("__%s__/%s" % [MOD, f.substr(str(ModFiles.locate(MOD).root).length())]) != null else 0
	print("read %d pictures from the zip in %.2f ms" % [n, (Time.get_ticks_usec() - t0) / 1000.0])

	_graphics_list()

	if ItemIcons.factorio_data_dir() != "":
		_check(ModFiles.locate("base").has("dir"), "base from the install")
		var plate := ModFiles.load_image("__base__/graphics/icons/iron-plate.png")
		_check(plate != null, "base's iron plate from the install")
		_check(ModFiles.load_image("base/graphics/icons/iron-plate.png") != null, "the same in icons.json's form")
	else:
		print("no Factorio install: built-in mods not checked")
	ModFiles.close_all()
	ModFiles.extra_dirs = []
	# The test's lambda, kept in a static: freed after this script it would crash Godot on quit.
	ModGraphics._send = Callable()
	_wipe(dir)
	print("MOD FILES FAILS: %d" % _fails)
	quit(1 if _fails > 0 else 0)


## The bridge's list through mod_graphics.gd: asked for, its parts kept, cached, and its icons
## drawn from the fixture's zip.
func _graphics_list() -> void:
	var p := "__%s__/graphics/" % MOD
	var parts := [
		{"icons": {"item": {"zenith-test-gizmo": [[p + "icons/gizmo.png", 64, null, null, null]],
			"zenith-test-tinted": [[p + "icons/tinted-base.png", 64, null, null, null], [p + "icons/tinted-mask.png", 64, [0, 1, 0, 1], null, null]]}}},
		{"icons": {"item-group": {"zenith": [[p + "icons/crate.png", 64, null, null, null]]}},
			"tiles": {"zenith-test-floor": {"mat": [p + "terrain/floor.png", 4, 0.5], "layer": 60, "group": "ground-artificial", "water": 0},
				"zenith-test-lowres": {"main": [[p + "terrain/floor.png", 4, 1, 0, 0, 4, 1, null, 1]], "layer": 20, "group": "ground-natural", "water": 0},
				"zenith-test-pond": {"mat": [p + "terrain/floor.png", 4, 0.5], "layer": 2, "group": "water", "water": 1}},
			"ents": {"zenith-test-spinner": {"n": [[p + "entity/spinner.png", 0, 0, 128, 128, 0.5, 0, 0, null,
					{"f": 4, "l": 4, "s": 0.25, "x": 0, "y": 0}]],
				"kn": [[p + "entity/spinner-lamp.png", 0, 0, 32, 32, 0.5, 0.5, -0.5, null, {"f": 2, "l": 0, "s": 1, "x": 0, "y": 0}]]},
				"zenith-test-crate": {"n": [[p + "entity/crate.png", 0, 0, 128, 160, 0.5, 0, -0.25, null],
				[p + "icons/gizmo.png", 0, 0, 64, 64, 0.5, 0.5, 0.5, [1, 0, 0, 1]]]},
				# A mod's car: its rotated sprite's north and east pictures differ.
				"zenith-test-car": {"n": [[p + "entity/crate.png", 0, 0, 128, 160, 0.5, 0, -0.25, null]],
				"e": [[p + "icons/gizmo.png", 0, 0, 64, 64, 0.5, 0, 0, null]]}},
			"decor": {"zenith-test-pebbles": {"layer": "decorative", "box": [-0.5, -0.5, 0.5, 0.5],
				"pics": [[p + "decorative/pebbles.png", 64, 0, 64, 64, 0.5, 0, 0], [p + "decorative/pebbles.png", 192, 0, 64, 64, 0.5, 0, 0]]}}},
	]
	var fp := "test%d" % Time.get_ticks_usec()
	var sent: Array = []
	var send := func(cmd: Dictionary) -> void: sent.append(cmd)
	ModGraphics.clear()
	_check(ItemIcons.texture_for("zenith-test-gizmo") == null, "no gizmo icon before the list")
	ModGraphics.on_welcome({"mods": {MOD: "1.0.0"}, "gf": fp, "gn": 2}, send)
	_check(sent.size() == 1 and sent[0].get("fp") == fp and not sent[0].has("need"), "asks for the whole list: %s" % [sent])
	ModGraphics.on_part({"t": "gfx", "fp": fp, "part": 2, "parts": 2, "d": parts[1]})
	_check(ModGraphics.progress() == Vector2i(1, 2), "one part of two")
	ModGraphics._asked_msec = 1
	OS.delay_msec(maxi(0, ModGraphics.RETRY_MSEC + 2 - Time.get_ticks_msec()))
	ModGraphics.poll()
	_check(sent.size() == 2 and Array(sent[1].get("need", [])) == [1], "asks again for the missing part: %s" % [sent])
	ModGraphics.on_part({"t": "gfx", "fp": "other", "part": 1, "parts": 2, "d": parts[0]})
	_check(ModGraphics.fingerprint != fp, "a part of another list is ignored")
	ModGraphics.on_part({"t": "gfx", "fp": fp, "part": 1, "parts": 2, "d": parts[0]})
	var wait := Time.get_ticks_msec() + 3000
	while ModGraphics.fingerprint != fp and Time.get_ticks_msec() < wait:
		ModGraphics.poll()  # applied once the mods' scan (started by the welcome) is done
		OS.delay_msec(2)
	_check(ModGraphics.fingerprint == fp, "applied once whole")
	_check(FileAccess.file_exists(ModGraphics._cache_path(fp)), "kept in user://mod-graphics")
	# Every handshake starts with a welcome (a full resync, a lost welcome): the list in use stays,
	# nothing is asked again, and a part arriving late changes nothing.
	var gen := ModGraphics.generation
	sent.clear()
	ModGraphics.on_welcome({"mods": {MOD: "1.0.0"}, "gf": fp, "gn": 2}, send)
	ModGraphics.on_part({"t": "gfx", "fp": fp, "part": 1, "parts": 2, "d": parts[0]})
	ModGraphics._asked_msec = 1
	ModGraphics.poll()
	_check(sent.is_empty() and ModGraphics.generation == gen and ModGraphics.fingerprint == fp,
		"the same list again: kept, nothing asked: %s" % [sent])
	var gizmo := ItemIcons.texture_for("zenith-test-gizmo")
	_check(gizmo != null and gizmo.get_width() == 64, "the gizmo's icon from the mod's zip")
	var tinted := ItemIcons.texture_for("zenith-test-tinted")
	var img := tinted.get_image() if tinted != null else null
	if img != null:
		img.decompress()
		var mask := img.get_pixel(32, 46)
		var top := img.get_pixel(32, 14)
		_check(mask.g > 0.8 and mask.r < 0.3 and top.r > 0.8 and top.g > 0.8, "the tinted layer composed green over white: %s %s" % [mask, top])
	else:
		_check(false, "the tinted icon")
	_check(ItemIcons.texture_for_kind("item-group", "zenith") != null, "an item group's icon")
	_tiles_and_decoratives()
	# Another game with the same mods: from the cache, nothing asked.
	ModGraphics.clear()
	sent.clear()
	ModGraphics.on_welcome({"mods": {MOD: "1.0.0"}, "gf": fp, "gn": 2}, send)
	var until := Time.get_ticks_msec() + 3000
	while ModGraphics.fingerprint != fp and Time.get_ticks_msec() < until:
		ModGraphics.poll()
		OS.delay_msec(5)
	_check(ModGraphics.fingerprint == fp and sent.is_empty(), "the second time from the cache, nothing asked: %s" % [sent])
	_check(ItemIcons.texture_for("zenith-test-gizmo") != null, "and the icon again")
	# An old bridge (no gf): nothing asked, and the last game's list goes (the own indexes again).
	sent.clear()
	ModGraphics.on_welcome({"mods": {MOD: "1.0.0"}}, send)
	_check(sent.is_empty() and ModGraphics.progress() == Vector2i.ZERO, "no list without gf")
	_check(ModGraphics.fingerprint == "" and ModGraphics.ents.is_empty() and not SpriteStandins.in_use(),
		"a game without a list doesn't keep the last game's")
	# All parts in but not applied yet (the mods' scan still running): the retry asks for nothing,
	# where an empty `need` would have the bridge send every part again.
	ModGraphics._want = "parts-in"
	ModGraphics._total = 1
	ModGraphics._parts = {1: {}}
	ModGraphics._send = send
	ModGraphics._ask(false)
	_check(sent.is_empty(), "no empty need: %s" % [sent])
	ModGraphics.clear()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(ModGraphics._cache_path(fp)))


## A mod's tiles (a material background, 32-pixel variants brought to 64, water by its mask) and a
## decorative from the list, read from the fixture's zip.
func _tiles_and_decoratives() -> void:
	_check(TerrainTextures.is_water_tile("zenith-test-pond") and not TerrainTextures.is_water_tile("zenith-test-floor"),
		"water by the record's collision mask")
	for name in ["zenith-test-floor", "zenith-test-lowres"]:
		TerrainTextures.lookup(name)
	var until := Time.get_ticks_msec() + 5000
	while (TerrainTextures.peek("zenith-test-floor") == null or TerrainTextures.peek("zenith-test-lowres") == null) and Time.get_ticks_msec() < until:
		TerrainTextures.poll()
		OS.delay_msec(5)
	var floor_gfx: TerrainTextures.TileGfx = TerrainTextures.peek("zenith-test-floor")
	_check(floor_gfx != null and floor_gfx.layer >= 0 and floor_gfx.material_count == 4 and floor_gfx.material == Vector2i(1, 1)
		and floor_gfx.priority == 3060, "the mod's floor: 4 material variants, artificial layer 60")
	var low: TerrainTextures.TileGfx = TerrainTextures.peek("zenith-test-lowres")
	# At scale 1 a tile is 32 px: the sheet is doubled, and its four 1x1 variants are read at 64.
	_check(low != null and low.layer >= 0 and low.sizes.size() == 1 and int(low.sizes[0][3]) == 4,
		"a scale-1 tile's variants resized to 64 px a tile: %s" % [low.sizes if low != null else null])
	_check(SpriteStandins.card("zenith-test-crate", 0) == null and SpriteStandins.coming("zenith-test-crate", 4),
		"a stand-in's picture is composed on a worker (every direction uses north's)")
	var card: QuadMesh = null
	var until2 := Time.get_ticks_msec() + 5000
	while card == null and Time.get_ticks_msec() < until2:
		SpriteStandins.poll()
		card = SpriteStandins.card("zenith-test-crate", 0) as QuadMesh
		OS.delay_msec(5)
	var squash := sin(deg_to_rad(SpriteStandins.FACTORIO_PITCH))
	# The crate (2 x 2.5 tiles at 64 px, its centre 0.25 above the entity's) with a red gizmo layer
	# inside it, from the entity's centre to a tile south-east.
	_check(card != null and card.size.is_equal_approx(Vector2(2.0, 2.5 * squash)), "the card's size: %s" % [card.size if card else null])
	if card != null:
		_check(is_zero_approx(card.center_offset.x) and is_equal_approx(card.center_offset.y, 0.25 * squash) and card.center_offset.z > 0.0, "the card's centre and lift: %s" % [card.center_offset])
		var mat := card.material as ShaderMaterial
		_check(mat != null and mat.shader.code.contains("ground_h("), "the card's shader lifts it onto an add-on's hills")
		var img := (mat.get_shader_parameter("picture") as Texture2D).get_image()
		img.decompress()
		var red := img.get_pixel(64 + 16, 96 + 48)  # the entity's centre is at (64, 96) in the picture
		_check(red.r > 0.8 and red.g < 0.2 and red.a > 0.9, "the tinted layer drawn red: %s" % [red])
		var lowest := card.center_offset.y - card.size.y * 0.5
		var pitch := deg_to_rad(SpriteStandins.FACTORIO_PITCH)
		_check(lowest * cos(pitch) + card.center_offset.z * sin(pitch) >= 0.0, "no part of the card under the ground")
		# Its ghost and build preview: the same picture in the ghost's tint, one material per tint.
		var tint := Color(0.58, 0.68, 1.0, 0.42)
		var ghost := SpriteStandins.ghost_material(card, tint)
		_check(ghost.get_shader_parameter("picture") == mat.get_shader_parameter("picture") and ghost.get_shader_parameter("tint") == tint
			and SpriteStandins.ghost_material(card, tint) == ghost and SpriteStandins.ghost_material(card, Color.RED) != ghost
			and ghost.shader.code.contains("ground_h("), "a modded building's ghost is its picture card in the ghost's tint")
	_animated_card()
	_check(SpriteStandins.card("nothing-like-it", 0) == null and not SpriteStandins.coming("nothing-like-it", 0), "no card without a picture or an icon")
	# No picture in the list but an icon: the icon stands on the footprint, 0.9 of its smaller side.
	var icon_card := SpriteStandins.card("zenith-test-gizmo", 0, Vector2(3, 2)) as QuadMesh
	_check(icon_card != null and is_equal_approx(icon_card.size.x, roundi(2 * 0.9 * 64) / 64.0) and not SpriteStandins.coming("zenith-test-gizmo", 0),
		"a modded entity without a picture shows its icon at once: %s" % [icon_card.size if icon_card else null])
	_check(SpriteStandins.in_use(), "with a list in use chunks draw no boxes or cones")
	_mover_cards()
	_card_cases()
	var data = Decoratives._kind_data_for("zenith-test-pebbles", ItemIcons.factorio_data_dir())
	_check(data != null and data.uvs.size() == 2, "the mod's decorative, its two pictures")


## The spinner: its blades turn through 4 frames (red, green, blue, yellow) on a still base, with a
## light it shows only while working. Its card keeps the still picture once and the 4 frames, light
## included, in an atlas; loop 4 frames at 0.25 a tick: 0.267 s.
func _animated_card() -> void:
	var before := SpriteStandins.atlas_bytes
	SpriteStandins.card("zenith-test-spinner", 0)
	var card: QuadMesh = null
	var until := Time.get_ticks_msec() + 5000
	while card == null and Time.get_ticks_msec() < until:
		SpriteStandins.poll()
		card = SpriteStandins.card("zenith-test-spinner", 0) as QuadMesh
		OS.delay_msec(5)
	_check(card != null and SpriteStandins.is_animated(card), "the spinner's card animates")
	if card == null:
		return
	var mat := card.material as ShaderMaterial
	var grid: Vector3 = mat.get_shader_parameter("frames_grid")
	_check(grid == Vector3(2, 2, 4) and is_equal_approx(float(mat.get_shader_parameter("frames_loop")), 4.0 / 15.0),
		"4 frames in a 2 x 2 atlas, Factorio's loop: %s, %s" % [grid, mat.get_shader_parameter("frames_loop")])
	var atlas := (mat.get_shader_parameter("frames") as Texture2D).get_image()
	var base := (mat.get_shader_parameter("picture") as Texture2D).get_image()
	atlas.decompress()
	base.decompress()
	_check(atlas.get_size() == Vector2i(256, 256) and SpriteStandins.atlas_bytes > before, "the atlas at full size (small): %s" % [atlas.get_size()])
	var want := [Color(0.9, 0, 0), Color(0, 0.78, 0), Color(0, 0.24, 1), Color(1, 0.86, 0)]
	var right := 0
	for f in 4:
		var ang := deg_to_rad(f * 90 + 60)
		var at := Vector2i((f % 2) * 128 + 64 + roundi(25 * cos(ang)), (f / 2) * 128 + 64 + roundi(25 * sin(ang)))
		var c := atlas.get_pixel(at.x, at.y)
		if absf(c.r - want[f].r) < 0.15 and absf(c.g - want[f].g) < 0.15 and absf(c.b - want[f].b) < 0.15:
			right += 1
	_check(right == 4, "each frame shows its own blade colour: %d of 4" % right)
	var lamp_in_frame := atlas.get_pixel(96, 32)
	var lamp_in_base := base.get_pixel(96, 32)
	_check(lamp_in_frame.r > 0.9 and lamp_in_frame.g > 0.9 and lamp_in_base.r < 0.6,
		"the working light is in the frames, not in the still picture: %s / %s" % [lamp_in_frame, lamp_in_base])
	_check(SpriteStandins.instance_color(true, Vector2(3, 4)).r == 1.0 and SpriteStandins.instance_color(false, Vector2(3, 4)).r == 0.0,
		"an instance says whether it runs")
	SpriteStandins.animate = false
	SpriteStandins.clear()
	SpriteStandins.card("zenith-test-spinner", 0)
	var still: QuadMesh = null
	until = Time.get_ticks_msec() + 5000
	while still == null and Time.get_ticks_msec() < until:
		SpriteStandins.poll()
		still = SpriteStandins.card("zenith-test-spinner", 0) as QuadMesh
		OS.delay_msec(5)
	_check(still != null and not SpriteStandins.is_animated(still), "with Animate modded buildings off, a still card")
	SpriteStandins.animate = true
	SpriteStandins.clear()


## A mod's mover without a model (a car, a unit) wears its picture on a card as a mod's building
## does, not a box: its nearest direction's picture, facing Factorio's camera however it turns, its
## frames stepping only while it moves; with neither a picture nor an icon nothing is drawn; and
## without a list (an older bridge) the box as before.
func _mover_cards() -> void:
	var protos := ProtoDB.new()
	protos.add_entities([[1, "zenith-test-car", "car", -0.7, -1.0, 0.7, 1.0, 1, 1, 1, 1, 1],
		[2, "nothing-like-it", "unit", -0.4, -0.4, 0.4, 0.4, 1, 1, 1, 1, 1]])
	var layer := Movers.new()
	layer.protos = protos
	root.add_child(layer)
	var facing := SpriteStandins.transform(Vector2.ZERO).basis
	var frame := [0]
	var step := func(car_x: float, orientation: int) -> void:
		frame[0] += 1
		layer.handle({"t": "mv", "k": frame[0], "l": [[10, 1, roundi(car_x * 256), 0, orientation], [11, 2, 5 * 256, 0]]})
		SpriteStandins.poll()
		layer._process(1.0 / 60.0)
	var north: Mesh = null
	var until := Time.get_ticks_msec() + 5000
	while north == null and Time.get_ticks_msec() < until:
		step.call(0.0, 0)
		north = SpriteStandins.card("zenith-test-car", 0)
		OS.delay_msec(5)
	step.call(0.0, 0)
	var car: Movers.Mover = layer._movers.get(10)
	_check(car != null and car.card != null and car.card.mesh == north and north != null, "a mod's car wears its north picture on a card")
	var boxes := 0
	for m: Movers.Mover in layer._movers.values():
		for mi in m.node.find_children("*", "MeshInstance3D", true, false):
			boxes += 1 if (mi as MeshInstance3D).mesh is BoxMesh else 0
	_check(boxes == 0, "no boxes for a mod's movers: %d" % boxes)
	var stray: Movers.Mover = layer._movers.get(11)
	_check(stray != null and stray.card != null and stray.card.mesh == null, "with neither picture nor icon, nothing drawn")
	if car == null or car.card == null:
		layer.free()
		return
	_check(car.card_run == 0, "standing, its frames hold still")
	# Turned east: the east picture, the card still facing Factorio's camera.
	var east: Mesh = null
	until = Time.get_ticks_msec() + 5000
	while (east == null or car.card.mesh != east) and Time.get_ticks_msec() < until:
		step.call(0.0, 250)
		east = SpriteStandins.card("zenith-test-car", 4)
		OS.delay_msec(5)
	_check(east != null and east != north and car.card.mesh == east, "turned east, the east picture")
	_check((car.node.basis * car.card.basis).is_equal_approx(facing), "the card faces Factorio's camera whichever way the car turns")
	for i in 20:
		step.call(i * 0.1, 250)
	_check(car.card_run == 1, "driving, its frames step")
	for i in 30:
		step.call(2.0, 250)
	_check(car.card_run == 0, "stopped, they hold again")
	# An older bridge sends no list: the box as before.
	var fp := ModGraphics.fingerprint
	ModGraphics.fingerprint = ""
	layer.handle({"t": "mv", "k": frame[0] + 1, "l": [[12, 1, 0, 0, 0]]})
	var plain: Movers.Mover = layer._movers.get(12)
	var box := false
	if plain != null:
		for mi in plain.node.find_children("*", "MeshInstance3D", true, false):
			box = box or (mi as MeshInstance3D).mesh is BoxMesh
	_check(plain != null and plain.card == null and box, "without a list, the box")
	ModGraphics.fingerprint = fp
	layer.free()


## A picture bigger than MAX_PX is scaled to fit, not cropped; a direction that differs only in what
## it adds while working gets its own card; a card being made when a new list arrives is made again
## from the new one.
func _card_cases() -> void:
	var p := "__%s__/graphics/" % MOD
	ModGraphics.ents["zenith-test-huge"] = {"n": [[p + "entity/crate.png", 0, 0, 128, 160, 20, 0, 0, null]]}
	var huge := _wait_card("zenith-test-huge", 0) as QuadMesh
	var squash := sin(deg_to_rad(SpriteStandins.FACTORIO_PITCH))
	_check(huge != null and absf(huge.size.x - 80.0) < 0.2 and absf(huge.size.y - 100.0 * squash) < 0.2,
		"a picture 80 x 100 tiles is scaled to fit, its card that size: %s" % [huge.size if huge else null])
	var crate: Array = ModGraphics.ents["zenith-test-crate"]["n"]
	var lamp := [[p + "entity/spinner-lamp.png", 0, 0, 32, 32, 0.5, 0, 0, null]]
	var rec := {"n": crate, "kn": lamp, "ke": [[p + "entity/spinner-lamp.png", 0, 0, 32, 32, 0.5, 1, 0, null]]}
	ModGraphics.ents["zenith-test-worker"] = rec
	_check(SpriteStandins._dir_key(rec, 4) == "e" and SpriteStandins._dir_key(rec, 8) == "n",
		"east has its own card when only its working layers differ")
	var east := _wait_card("zenith-test-worker", 4)
	_check(east != null and east != _wait_card("zenith-test-worker", 0), "and it is made, from north's picture")
	# A new list while a card is being made: that card is dropped, then made from the new list.
	SpriteStandins.card("zenith-test-spinner", 4)
	_check(SpriteStandins.coming("zenith-test-spinner", 4), "a card on its way")
	ModGraphics.generation += 1
	var until := Time.get_ticks_msec() + 5000
	while SpriteStandins.coming("zenith-test-spinner", 4) and Time.get_ticks_msec() < until:
		SpriteStandins.poll()
		OS.delay_msec(5)
	_check(not SpriteStandins._cards.has("zenith-test-spinner|n"), "the old list's card isn't kept")
	_check(_wait_card("zenith-test-spinner", 4) != null, "it is made again from the new one")


func _wait_card(name: String, direction: int) -> Mesh:
	var card := SpriteStandins.card(name, direction)
	var until := Time.get_ticks_msec() + 10000
	while card == null and SpriteStandins.coming(name, direction) and Time.get_ticks_msec() < until:
		OS.delay_msec(5)
		SpriteStandins.poll()
		card = SpriteStandins.card(name, direction)
	return card


## As the welcome does, then waits for the scan on its worker; until then only built-in mods are found.
func _set_mods(mods: Dictionary) -> void:
	ModFiles.set_mods(mods)
	var until := Time.get_ticks_msec() + 5000
	while not ModFiles.is_ready() and Time.get_ticks_msec() < until:
		OS.delay_msec(2)


func _pack(zip: ZIPPacker, from: String, prefix: String) -> void:
	for f in DirAccess.get_files_at(from):
		zip.start_file(prefix + f)
		zip.write_file(FileAccess.get_file_as_bytes(from.path_join(f)))
		zip.close_file()
	for d in DirAccess.get_directories_at(from):
		_pack(zip, from.path_join(d), prefix + d + "/")


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(d))
	DirAccess.remove_absolute(dir)
