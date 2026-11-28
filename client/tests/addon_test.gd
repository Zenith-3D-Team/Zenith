extends "res://tests/addon_test_base.gd"
## Zenith's add-on support (scripts/addons/) without a server: finding add-ons and reading their
## addon.json (the API version check, broken manifests, duplicate ids), loading entry scripts from
## folders outside the project (with a relative preload), each add-on's keys in Settings →
## Controls (a default Zenith already uses left unbound, camera keys sharing Zenith's), taking the
## camera and handing it back (the player's controls off and on, the focus, Zenith taking it back
## for a ride), camera keys kept from Zenith, the interface hidden and back, lighter updates through
## the UPS governor, per-save and global data, events from the bridge's messages, settings (API 1.1)
## and the Add-ons menu (settings changed, a key rebound, the switch), keeping Zenith drawing for a
## recorder, add-ons in zips (unpacked, relative preloads, a broken zip, a zip and a folder of one
## id: the newer wins), api.terrain (1.2: the height field, tile kinds, cliffs, buildings and changed
## chunks read from a fake world), api.shaders (1.3: looks and passes, put on a scene's environment and
## taken off again), and switching an add-on off. Exits with 1 if a check fails.
##
##   godot --headless --path client res://tests/addon_test.tscn


const AddonTestBase := preload("res://tests/addon_test_base.gd")
const AreaCharacter := preload("res://tests/addon_area_character.gd")
const AreaShaders := preload("res://tests/addon_area_shaders.gd")
const AreaApiAuthor := preload("res://tests/addon_area_api_author.gd")
const AreaWeatherEnemies := preload("res://tests/addon_area_weather_enemies.gd")

const NEEDS := {}
const POST_GAME_SECTIONS: PackedStringArray = ["_cinematic_shaders", "_immersive_weather", "_immersive_enemies", "_reload_and_errors", "_dependencies", "_fix2_checks", "_author_checks"]

var _section_owner: Dictionary = {}
var _section_args: Dictionary = {}


func _init_areas() -> Dictionary:
	var base_script: Script = AddonTestBase
	var base_methods := {}
	for m: Dictionary in base_script.get_script_method_list():
		base_methods[str(m["name"])] = true
	var by_name := {}
	var area_character: Node = AreaCharacter.new()
	area_character.name = "AreaCharacter"
	add_child(area_character)
	by_name["character"] = area_character
	var area_shaders: Node = AreaShaders.new()
	area_shaders.name = "AreaShaders"
	add_child(area_shaders)
	by_name["shaders"] = area_shaders
	var area_api_author: Node = AreaApiAuthor.new()
	area_api_author.name = "AreaApiAuthor"
	add_child(area_api_author)
	by_name["api_author"] = area_api_author
	var area_weather_enemies: Node = AreaWeatherEnemies.new()
	area_weather_enemies.name = "AreaWeatherEnemies"
	add_child(area_weather_enemies)
	by_name["weather_enemies"] = area_weather_enemies
	_section_owner.clear()
	_section_args.clear()
	for area_name: String in by_name:
		var node: Node = by_name[area_name]
		var scr: Script = node.get_script()
		for m: Dictionary in scr.get_script_method_list():
			var mname: String = str(m["name"])
			if base_methods.has(mname):
				continue
			check(not _section_owner.has(mname), "unique section/helper name across areas: %s" % mname)
			_section_owner[mname] = node
			var arg_names: Array = []
			for a: Dictionary in m["args"]:
				arg_names.append(str(a["name"]))
			_section_args[mname] = arg_names
	return by_name


func _exit_tree() -> void:
	for what in _failed:
		print("FAILED: " + what)
	TestEnv.clean()



func _finish() -> void:
	AddonLoader.cache_root = "user://addons-cache"
	AddonStorage.root = "user://addons-data"
	print("FAILS: %d" % fails)
	get_tree().quit(1 if fails > 0 else 0)


func _only_sections() -> PackedStringArray:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			return arg.get_slice("=", 1).split(",", false)
	return PackedStringArray()


func _run_only(names: PackedStringArray, values: Dictionary) -> void:
	var order: Array[String] = []
	for section: String in names:
		for needed: String in NEEDS.get(section, []):
			if not order.has(needed):
				order.append(needed)
		if not order.has(section):
			order.append(section)
	var ended := false
	for section: String in order:
		var owner_node: Node = _section_owner.get(section)
		var arg_names: Array = _section_args.get(section, [])
		var has_args := true
		for a: String in arg_names:
			if not values.has(a):
				has_args = false
				break
		var known_sec: bool = owner_node != null and has_args
		check(known_sec, "--only: %s is a section of this test" % section)
		if known_sec:
			if not ended and POST_GAME_SECTIONS.has(section):
				values["host"].game_ended()
				ended = true
			print("--- " + section)
			var call_args: Array = []
			for a: String in arg_names:
				call_args.append(values[a])
			await owner_node.callv(section, call_args)
	_finish()


func _ready() -> void:
	fails = 0
	passes = 0
	_failed.clear()
	var _areas := _init_areas()
	var area_character: Node = _areas["character"]
	var area_shaders: Node = _areas["shaders"]
	var area_api_author: Node = _areas["api_author"]
	var area_weather_enemies: Node = _areas["weather_enemies"]
	TestEnv.isolate("addon-test")
	Settings.legacy = {}
	Settings.use_file(TEST_SETTINGS)
	# The player's own Factorio controls (config.ini) mustn't change the keys the test presses.
	Settings.set_value("factorio", "use_factorio_keys", false)
	Controls.define()
	Settings.apply_bindings()
	_rmtree("user://addon-test")
	AddonStorage.root = "user://addon-test/data"

	# Add-ons on disk outside the project: one that loads, with a script beside its entry that it
	# preloads by a relative path; one for a newer Zenith; a broken addon.json; a duplicate id.
	_write(DISK + "/disk-addon/addon.json", JSON.stringify({"id": "disk-addon", "name": "Disk add-on", "version": "0.1", "api": 1, "entry": "main.gd"}))
	_write(DISK + "/disk-addon/helper.gd", "extends RefCounted\nstatic func answer() -> int:\n\treturn 42\n")
	_write(DISK + "/disk-addon/main.gd", "extends Node\nconst Helper := preload(\"helper.gd\")\nvar api\nvar answer := 0\nfunc addon_start(a) -> void:\n\tapi = a\n\tanswer = Helper.answer()\n")
	_write(DISK + "/future-addon/addon.json", JSON.stringify({"id": "future-addon", "name": "Future", "version": "9", "api": AddonLoader.API_VERSION + 1, "entry": "main.gd"}))
	_write(DISK + "/future-addon/main.gd", "extends Node\n")
	_write(DISK + "/broken/addon.json", "{ not json")
	_write(DISK + "/copy/addon.json", JSON.stringify({"id": "test-addon", "name": "Second copy", "version": "0.9", "api": 1, "entry": "main.gd"}))
	_write(DISK + "/copy/main.gd", "extends Node\n")
	_write(DISK + "/refcounted/addon.json", JSON.stringify({"id": "refcounted", "name": "Not a node", "version": "1", "api": 1, "entry": "main.gd"}))
	_write(DISK + "/refcounted/main.gd", "extends RefCounted\n")
	_write(DISK + "/level-addon/addon.json", JSON.stringify({"id": "level-addon", "name": "Needs 1.1", "version": "1", "api": 1.1, "entry": "main.gd"}))
	_write(DISK + "/level-addon/main.gd", "extends Node\n")
	_write(DISK + "/later-addon/addon.json", JSON.stringify({"id": "later-addon", "name": "Needs 1.96", "version": "1", "api": 1.96, "entry": "main.gd"}))
	_write(DISK + "/later-addon/main.gd", "extends Node\n")
	_write(DISK + "/level17-addon/addon.json", JSON.stringify({"id": "level17-addon", "name": "Needs 1.7", "version": "1", "api": 1.7, "entry": "main.gd"}))
	_write(DISK + "/level17-addon/main.gd", "extends Node\n")
	_write(DISK + "/level18-addon/addon.json", JSON.stringify({"id": "level18-addon", "name": "Needs 1.8", "version": "1", "api": 1.8, "entry": "main.gd"}))
	_write(DISK + "/level18-addon/main.gd", "extends Node\n")
	_write(DISK + "/level19-addon/addon.json", JSON.stringify({"id": "level19-addon", "name": "Needs 1.9", "version": "1", "api": 1.9, "entry": "main.gd"}))
	_write(DISK + "/level19-addon/main.gd", "extends Node\n")
	# Zipped add-ons: one in a folder inside the zip (Factorio's way) with a relative preload, one at
	# the zip's root, a broken zip, and two ids found both as a folder and a zip.
	AddonLoader.cache_root = "user://addon-test/cache"
	_zip(DISK + "/zip-addon_1.0.0.zip", {"zip-addon/addon.json": JSON.stringify({"id": "zip-addon", "name": "Zipped", "version": "1.0.0", "api": 1, "entry": "main.gd"}),
		"zip-addon/main.gd": "extends Node\nconst Helper := preload(\"lib/helper.gd\")\nvar answer := 0\nfunc addon_start(_a) -> void:\n\tanswer = Helper.answer()\n",
		"zip-addon/lib/helper.gd": "extends RefCounted\nstatic func answer() -> int:\n\treturn 7\n"})
	_zip(DISK + "/root-zip.zip", {"addon.json": JSON.stringify({"id": "root-zip", "name": "Root zip", "version": "1", "api": 1, "entry": "main.gd"}), "main.gd": "extends Node\n"})
	_zip(DISK + "/broken-zip.zip", {}, "not a zip at all".to_utf8_buffer())
	_write(DISK + "/dup-addon/addon.json", JSON.stringify({"id": "dup-addon", "name": "Dup (folder)", "version": "1.0.0", "api": 1, "entry": "main.gd"}))
	_write(DISK + "/dup-addon/main.gd", "extends Node\n")
	_zip(DISK + "/dup-addon_1.2.0.zip", {"dup-addon/addon.json": JSON.stringify({"id": "dup-addon", "name": "Dup (zip)", "version": "1.2.0", "api": 1, "entry": "main.gd"}), "dup-addon/main.gd": "extends Node\n"})
	_write(DISK + "/dup-two/addon.json", JSON.stringify({"id": "dup-two", "name": "Dup two (folder)", "version": "2.0", "api": 1, "entry": "main.gd"}))
	_write(DISK + "/dup-two/main.gd", "extends Node\n")
	_zip(DISK + "/dup-two_1.9.zip", {"dup-two/addon.json": JSON.stringify({"id": "dup-two", "name": "Dup two (zip)", "version": "1.9", "api": 1, "entry": "main.gd"}), "dup-two/main.gd": "extends Node\n"})
	var where := [[ProjectSettings.globalize_path("res://tests/addon_fixtures"), "test"], [ProjectSettings.globalize_path(DISK), "test"]]

	var found := AddonLoader.scan(where)
	var by_id := {}
	for m in found:
		by_id[m["id"]] = m
	check(by_id.has("test-addon") and by_id["test-addon"]["ok"] and by_id["test-addon"]["name"] == "Test add-on", "the fixture add-on is found and can load")
	check(by_id.has("disk-addon") and by_id["disk-addon"]["ok"], "an add-on in a folder outside the project is found")
	check(by_id.has("future-addon") and not by_id["future-addon"]["ok"] and str(by_id["future-addon"]["problem"]).contains("needs a newer Zenith"), "an add-on needing a newer API is refused: " + str(by_id.get("future-addon", {}).get("problem", "")))
	check(by_id.has("level18-addon") and by_id["level18-addon"]["ok"],
		"1.8: an add-on asking for API 1.8 is accepted: " + str(by_id.get("level18-addon", {}).get("problem", "")))
	check(by_id.has("broken") and not by_id["broken"]["ok"] and str(by_id["broken"]["problem"]).contains("JSON"), "a broken addon.json is refused")
	check(found.filter(func(m: Dictionary) -> bool: return m["id"] == "test-addon").size() == 1, "a duplicate id of an older version is left out")
	check(by_id.has("level-addon") and by_id["level-addon"]["ok"], "an add-on asking for API 1.1 loads")
	check(by_id.has("zip-addon") and by_id["zip-addon"]["ok"] and by_id["zip-addon"]["inner"] == "zip-addon/", "a zip with the add-on's folder inside is found: " + str(by_id.get("zip-addon", {}).get("problem", "")))
	check(by_id.has("root-zip") and by_id["root-zip"]["ok"] and by_id["root-zip"]["inner"] == "", "and one with addon.json at its root")
	check(by_id.has("broken-zip") and not by_id["broken-zip"]["ok"] and str(by_id["broken-zip"]["problem"]).contains("zip"), "a broken zip says so: " + str(by_id.get("broken-zip", {}).get("problem", "")))
	check(by_id.has("dup-addon") and by_id["dup-addon"].has("zip") and str(by_id["dup-addon"]["version"]) == "1.2.0" and str(by_id["dup-addon"].get("also", [])).contains("older"), "a zip newer than the folder of the same id wins, the folder named: %s" % [by_id.get("dup-addon", {}).get("also", [])])
	check(by_id.has("dup-two") and not by_id["dup-two"].has("zip") and str(by_id["dup-two"]["version"]) == "2.0", "a folder newer than the zip wins")
	check(found.filter(func(m: Dictionary) -> bool: return m["id"] == "dup-addon").size() == 1, "and each is listed once")
	check(AddonLoader.compare_versions("1.10.0", "1.9.2") == 1 and AddonLoader.compare_versions("2", "2.0.0") == 0, "versions compare by number")
	check(by_id.has("level17-addon") and by_id["level17-addon"]["ok"] and by_id.has("level18-addon") and by_id["level18-addon"]["ok"] and by_id.has("level19-addon") and by_id["level19-addon"]["ok"],
		"1.9: add-ons asking for API 1.7, 1.8 and 1.9 all load")
	check(by_id.has("later-addon") and not by_id["later-addon"]["ok"] and str(by_id["later-addon"]["problem"]).contains("needs a newer Zenith (add-on API 1.96; this Zenith has 1.95)"),
		"1.9: one asking for 1.96 is refused with the newer-Zenith message: " + str(by_id.get("later-addon", {}).get("problem", "")))

	area_api_author._trust(where, by_id)
	# The add-ons the rest of the test starts, switched on as a player would (new ones are off); dup-two
	# stays as found, a new add-on for the Add-ons menu's checks.
	for id in by_id:
		if id != "dup-two":
			Settings.set_value("addons", id, true)
	Settings.set_value("addons", "cinematic-shaders", true)

	# A game's stand-ins, Zenith's controls (the spy) and the host after them, as in main.gd.
	var spy := Spy.new()
	add_child(spy)
	var fake := FakeMain.new()
	add_child(fake)
	fake._game = Node.new()
	fake.add_child(fake._game)
	var hud_layer := CanvasLayer.new()
	fake._game.add_child(hud_layer)
	fake.front_end = FakeFrontEnd.new()
	add_child(fake.front_end)
	fake.ride = FakeRide.new()
	add_child(fake.ride)
	fake._planet_sky = FakeSky.new()
	add_child(fake._planet_sky)
	fake.input = Node.new()
	add_child(fake.input)
	fake.ups_governor = UpsGovernor.new()
	add_child(fake.ups_governor)
	var target := Node3D.new()
	add_child(target)
	target.position = Vector3(10, 0, 5)
	fake.avatar = target
	var rig := CameraRig.new()
	rig.target = target
	add_child(rig)
	fake.rig = rig
	var host := AddonHost.new()
	host.autoload = false
	host.main = fake
	add_child(host)
	host.load_all(where)
	await get_tree().process_frame

	var m := host.find("test-addon")
	var node: Node = m.get("node")
	check(node != null and node.started == 1 and node.api != null, "the entry script was started with its API")
	var api = node.api if node != null else null
	check(api != null and api.version == AddonLoader.API_VERSION and api.id == "test-addon", "the API says its version and the add-on's id")
	check(api != null and is_equal_approx(api.level, 1.95), "and its level, 1.95")
	if api != null:
		# 1.94: a viewpoint announced ahead of a cut, by this add-on's id, let go with release_view.
		var ViewAhead := preload("res://scripts/world/view_ahead.gd")
		api.world.prepare_view(Vector3(500, 30, 0), Vector3(520, 0, 0), 2.0)
		var announced := ViewAhead.active() == ViewAhead.on and (not ViewAhead.on or ViewAhead._points.has("test-addon"))
		api.world.release_view()
		check(announced and not ViewAhead.active(), "1.94: api.world.prepare_view announces a viewpoint ahead, release_view lets it go")
		# 1.95: the animated sub-parts' ragdoll nodes (Immersive Enemies 0.1.3's strafer and stomper legs).
		check(api.creatures != null and api.creatures.has_method("make_ragdoll_part_nodes")
			and (api.creatures.make_ragdoll_part_nodes("") as Array).is_empty(),
			"1.95: api.creatures.make_ragdoll_part_nodes is there ([] for no model)")
	var disk := host.find("disk-addon")
	check(disk.has("node") and int(disk["node"].answer) == 42, "a .gd loaded from user:// runs, with its relative preload")
	check(not host.find("future-addon").has("node") and not host.find("refcounted").has("node"), "refused add-ons aren't started")
	var zipped := host.find("zip-addon")
	check(zipped.has("node") and int(zipped["node"].answer) == 7, "a zipped add-on runs, with its relative preload from a subfolder")
	check(FileAccess.file_exists("user://addon-test/cache/zip-addon/lib/helper.gd"), "unpacked into Zenith's add-on cache")
	check(AddonLoader.unpack(zipped) == "" and FileAccess.file_exists("user://addon-test/cache/zip-addon/.zenith-unpacked"), "and not again while the zip is unchanged")
	check(host.find("dup-addon").has("node") and host.find("root-zip").has("node"), "the winning zip and a root zip start")
	check(str(host.find("refcounted").get("error", "")).contains("extend Node"), "an entry script that isn't a Node is refused")
	if api == null:
		_finish()
		return

	# Keys.
	var toggle: String = api.keys.action_of("toggle")
	var taken: String = api.keys.action_of("taken")
	var fly: String = api.keys.action_of("fly")
	var rise: String = api.keys.action_of("rise")
	check(Settings.keys_for(toggle) == [KEY_F8, 0], "a global key gets its default")
	check(Settings.keys_for(taken) == [KEY_F10, 0], "a default Zenith already uses (W) is left unbound, the other kept")
	check(Settings.keys_for(fly) == [KEY_W, KEY_UP], "a camera key may share Zenith's W")
	check(Settings.keys_for(rise) == [KEY_E | KEY_MASK_SHIFT, 0], "a key given by name with a modifier")
	check(Settings.conflicts(fly, KEY_W).is_empty() and Settings.conflicts("move_up", KEY_W).is_empty(), "camera keys don't clash with Zenith's")
	Settings.bind_slot(toggle, 1, KEY_W)
	check(Settings.conflicts(toggle, KEY_W).has("move_up") and Settings.conflicts(toggle, KEY_W).has(fly), "a global key rebound to W clashes with Zenith's and the camera key")
	Settings.bind(toggle, [])
	check(Settings.bindable_actions().has(fly) and ControlsInfo.group_of(fly) == "Test add-on" and ControlsInfo.name_of(fly) == "Fly forward", "listed in Settings → Controls under the add-on's name")
	check(ControlsInfo.groups().back() == "Test add-on", "the add-on's group comes after Zenith's")
	check(not api.keys.held("fly") and not api.keys.pressed(_event(KEY_W), "fly"), "camera keys are off while the add-on hasn't the camera")
	check(not api.keys.pressed(_event(KEY_F8), "toggle"), "no keys outside a game")

	# The camera.
	check(not api.camera.take(), "no camera outside a game")
	host.game_started()
	await get_tree().process_frame
	var only := _only_sections()
	if not only.is_empty():
		await _run_only(only, {"api": api, "node": node, "host": host, "fake": fake, "rig": rig, "hud_layer": hud_layer, "where": where, "plain_where": where, "by_id": by_id})
		return
	check(node.games == 1, "game_started reaches the add-on")
	check(api.keys.pressed(_event(KEY_F8), "toggle"), "a global key works in a game")
	fake.front_end.covered = true
	check(not api.keys.pressed(_event(KEY_F8), "toggle"), "and not under Zenith's menu")
	fake.front_end.covered = false
	rig._process(1.0)
	var player_view: Transform3D = rig.camera.global_transform
	check(api.camera.take(), "take() gets the camera")
	check(rig.taken() and api.camera.has() and api.camera.node() == rig.camera, "the rig hands its camera over")
	check(not fake.input.is_processing() and not fake.input.is_processing_unhandled_input(), "the player's controls are off")
	check(not disk["object"].camera.take(), "another add-on can't take it meanwhile")
	api.camera.look_from(Vector3(0, 50, 50), Vector3.ZERO)
	api.camera.node().fov = 70.0
	rig._process(0.5)
	check(rig.camera.global_position.is_equal_approx(Vector3(0, 50, 50)), "the rig leaves the camera where the add-on put it")
	host._process(0.0)
	rig._process(0.0)
	check(rig.focus_point().distance_to(Vector2.ZERO) < 0.01, "the world loads round where the camera looks: %s" % rig.focus_point())
	var cone_world_before = fake.world
	var cone_world := FakeWorld.new()
	fake.world = cone_world
	host._process(0.0)
	check(rig.use_view_cone(), "add-on camera uses view cone by default")
	check(cone_world.view_cone, "the host passes the rig's view cone on to the world (set_view_cone)")
	api.camera.set_focus(Vector2(100, 200))
	host._process(0.0)
	rig._process(0.0)
	check(rig.focus_point() == Vector2(100, 200), "or round a point the add-on names")
	check(not rig.use_view_cone(), "explicit set_focus(point) disables view cone")
	check(not cone_world.view_cone, "and the world's cone goes off with it")
	api.camera.set_focus(null)
	host._process(0.0)
	rig._process(0.0)
	check(rig.use_view_cone(), "set_focus(null) restores view cone")
	check(cone_world.view_cone, "and the world's cone comes back")
	var prev_f := Vector2.INF
	var max_jump := 0.0
	var cam_node: Camera3D = api.camera.node()
	for pitch_deg: float in [-5.0, -3.0, -2.5, 0.0, 5.0]:
		cam_node.global_transform = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(pitch_deg)), Vector3(100.0, 30.0, 100.0))
		host._process(0.0)
		rig._process(0.0)
		var fp := rig.focus_point()
		if prev_f != Vector2.INF:
			max_jump = maxf(max_jump, fp.distance_to(prev_f))
		prev_f = fp
	check(max_jump < 10.0 and prev_f.distance_to(Vector2(100.0, 100.0)) <= 72.1,
		"horizon pitch keeps live focus continuous: jump %.2f, end %s" % [max_jump, prev_f])
	check(api.keys.pressed(_event(KEY_W), "fly") and api.keys.pressed(_event(KEY_E, true), "rise"), "camera keys work while it has the camera")
	spy.keys.clear()
	_key(KEY_W)
	_key(KEY_K)
	check(node.presses == 1, "the add-on gets its camera key")
	check(not spy.keys.has(KEY_W) and spy.keys.has(KEY_K), "Zenith doesn't see a camera key (W), other keys pass")
	# Zenith's debug menu open over the add-on's camera: its camera keys rest (typing in the menu
	# doesn't fly it) and are still kept from Zenith; its global keys work; the mouse is wanted.
	fake.hud = FakeHud.new()
	add_child(fake.hud)
	fake.hud.ui.debug_menu.open = true
	check(host.debug_menu_open() and host.windows_open() and not api.keys.pressed(_event(KEY_W), "fly") and not api.keys.held("fly")
		and api.keys.pressed(_event(KEY_F8), "toggle"), "the debug menu open: camera keys rest, global keys work, the mouse shows")
	spy.keys.clear()
	_key(KEY_W)
	check(not spy.keys.has(KEY_W), "and W still doesn't reach Zenith's controls")
	fake.hud.ui.debug_menu.open = false
	check(not host.windows_open() and api.keys.pressed(_event(KEY_W), "fly"), "closed: the camera keys work again")
	fake.hud.queue_free()
	fake.hud = null
	fake.input.set_process(true)  # main.gd turns them on when its menu closes
	host._process(0.0)
	check(not fake.input.is_processing(), "the controls stay off while the add-on has the camera")
	api.camera.release()
	check(not rig.taken() and not rig.camera.top_level and is_equal_approx(rig.camera.fov, 35.0), "release() hands back the camera as it was")
	check(rig.camera.global_transform.is_equal_approx(player_view), "the player's view is exactly as before")
	check(fake.input.is_processing() and fake.input.is_processing_unhandled_input(), "the player's controls are back")
	check(rig.focus_point() == Vector2(10, 5), "the world loads round the character again")
	check(not rig.use_view_cone(), "release() turns view cone off")
	host._process(0.0)
	check(not cone_world.view_cone, "and the world's cone is off once the add-on lets go")
	fake.world = cone_world_before
	cone_world.free()
	check(api.camera.take({"focus": "character"}), "take with character focus succeeds")
	host._process(0.0)
	rig._process(0.0)
	check(not rig.use_view_cone(), "character focus mode disables view cone")
	api.camera.release()
	spy.keys.clear()
	_key(KEY_W)
	check(spy.keys.has(KEY_W), "W reaches Zenith again")
	check(api.camera.take({"input": false}), "the camera taken leaving the player's controls on")
	check(fake.input.is_processing(), "the player plays on (a timelapse)")
	fake.ride.on = true
	host._process(0.0)
	check(not rig.taken() and node.lost == 1, "a ride takes the camera back, with `lost`")
	check(not api.camera.take(), "and it can't be taken during the ride")
	fake.ride.on = false

	# The interface hidden, frames, the time of day.
	# The alert icons over entities are the interface too (Factorio hides them with its GUI).
	var alert_icons := Node3D.new()
	alert_icons.add_to_group(&"f3d_hide_with_interface")
	fake._game.add_child(alert_icons)
	var debug_layer := CanvasLayer.new()
	debug_layer.add_to_group(AddonHost.SHOWN_WITH_INTERFACE_HIDDEN)
	hud_layer.add_child(debug_layer)
	api.view.hide_interface(true)
	check(not hud_layer.visible and host.interface_hidden(), "hide_interface hides the HUD's layers")
	check(debug_layer.visible, "but not the debug menu's layer (it opens over a clean shot)")
	check(not alert_icons.visible, "and the alert icons over entities")
	var win: Dictionary = api.ui.window("Test window")
	api.ui.show(win["frame"])
	check(api.ui.is_open(win["frame"]) and not (win["frame"] as Control).visible, "an add-on's window stays out of sight while hidden")
	api.view.hide_interface(false)
	check(hud_layer.visible and (win["frame"] as Control).visible and alert_icons.visible, "and they all come back")
	# Its title bar drags it through Kit's drag handle alone: a second handler of its own moved the
	# window twice as far as the mouse.
	var bar: Control = (win["box"] as VBoxContainer).get_child(0)
	check(bar.has_meta("drag_handle") and Kit.drag_target(bar) == win["frame"] and bar.gui_input.get_connections().size() == 1,
		"the window's title bar drags it once, by Kit's handle: %d handlers" % bar.gui_input.get_connections().size())
	var at: Vector2 = (win["frame"] as Control).position
	var stray := InputEventMouseMotion.new()
	stray.relative = Vector2(30, 20)
	stray.button_mask = MOUSE_BUTTON_MASK_LEFT
	bar.gui_input.emit(stray)
	check((win["frame"] as Control).position == at, "and a motion that didn't start on the bar moves nothing")
	_key(KEY_ESCAPE)
	check(not api.ui.is_open(win["frame"]), "Esc closes the add-on's window")
	api.view.hold_daytime(0.0)
	check(is_equal_approx(fake._planet_sky.forced_daytime, 0.0), "hold_daytime holds the sky at noon")
	api.view.hold_daytime(-1.0)
	check(fake._planet_sky.forced_daytime < 0.0, "and lets it run again")

	# Moving things where they are drawn: a robot's node stays where it first appeared (the GPU
	# draws it from its record), so api.world reads movers.gd's position_of and yaw_of.
	var movers := FakeMovers.new()
	movers.protos.entities_by_name = {"logistic-robot": FakeProto.new("logistic-robot", Vector2.ONE)}
	add_child(movers)
	fake.movers = movers
	var robots: Array = api.world.movers(["logistic-robot"])
	check(robots.size() == 1 and robots[0]["position"] == Vector3(30, 2.2, 40) and (robots[0]["forward"] as Vector3).is_equal_approx(Vector3(-1, 0, 0)),
		"world: a robot where it is drawn, facing west, not where its node was left: %s" % [robots])
	var one: Dictionary = api.world.mover(7)
	check(one.get("type") == "logistic-robot" and one.get("name") == "logistic-robot" and one.get("position") == Vector3(30, 2.2, 40),
		"world: mover() the same: %s" % [one])
	check(api.world.mover(8).is_empty() and api.world.movers(["car"]).is_empty(), "world: nothing for a unit or type not there")
	fake.movers = null
	movers.queue_free()

	# Lighter updates, under the governor.
	api.updates.request({"rate": 2, "entity": 64, "near": 8})
	check(int(fake.ups_governor.limit("rate", 0.0)) == 2 and int(fake.ups_governor.limit("entity", 192.0)) == 64, "a request lowers the updates through the governor")
	check(int(fake.ups_governor.limit("entity", 32.0)) == 32, "and never raises the player's own setting")
	fake.ups_governor._caps = {"rate": 3}
	check(int(fake.ups_governor.limit("rate", 0.0)) == 3, "the governor still wins where it holds back more")
	fake.ups_governor._caps = {}
	# The fewest belt items moving is the smallest cap: 0 there means Unlimited (main.gd, cap_of).
	api.updates.request({"updates": 0})
	var fewest: float = fake.ups_governor.limit("updates", BeltLaneLayer.UNLIMITED)
	check(BeltLaneLayer.cap_of(fewest) == 500, "an updates request of 0 is the smallest cap, not Unlimited: %s -> %d" % [fewest, BeltLaneLayer.cap_of(fewest)])
	api.updates.clear()
	check(int(fake.ups_governor.limit("rate", 0.0)) == 0 and AddonRequests.requests.is_empty(), "clear() gives it back")

	# Data per save and for all saves.
	check(api.storage.save_key() == "My base", "the save key is the save's name: " + api.storage.save_key())
	check(api.storage.write({"paths": [[1.0, 2.0, 3.0]]}, "paths") and api.storage.read("paths").get("paths") == [[1.0, 2.0, 3.0]], "per-save data round trips")
	check(FileAccess.file_exists("user://addon-test/data/test-addon/saves/My base/paths.json"), "under user://, the add-on's folder, the save's")
	fake.front_end.launcher.save_path = "C:/somewhere/saves/Other.zip"
	check(api.storage.read("paths").is_empty(), "another save has its own")
	check(api.storage.write_global({"speed": 8}) and int(api.storage.read_global().get("speed", 0)) == 8, "global data round trips")

	# Events from the bridge's messages.
	var started: Array = []
	api.events.fight_started.connect(func(at: Vector3, _n: int) -> void: started.append(at))
	Bridge.message_received.emit({"t": "en", "l": [77, 2560, 1280]})
	Bridge.message_received.emit({"t": "tf", "u": 9, "x": 2570, "y": 1290})
	check(started.size() == 1 and started[0].is_equal_approx(Vector3(10, 0, 5)), "an attack starts one fight there, a turret's shot joins it")
	check(api.events.fights().size() == 1 and int(api.events.fights()[0]["size"]) == 2, "fights() lists it with its attackers and turrets")
	check(api.events.recent(5.0).size() == 1 and api.events.recent(5.0)[0]["kind"] == "fight_started", "recent() has it")

	await area_character._character_api(api, node, host, fake, rig)
	await area_character._character_lift(api, host, fake, rig)
	await area_character._belt_step(api, host, fake, rig)
	await area_character._char_extra(api, node, host, fake, rig)
	await area_character._camera_modifiers(api, host, fake, rig)
	await area_character._character_attach(api, host, fake, rig)
	await area_character._cam_group_extra(api, host, fake, rig)
	await area_character._api_leak(host)

	# The Mods window lists the add-ons with their switches.
	var mods := ModsWindow.new()
	mods.addons = host
	add_child(mods)
	await get_tree().process_frame
	var box := mods.find_child("addon-test-addon", true, false) as CheckBox
	check(box != null and box.button_pressed, "the Mods window lists the add-on, switched on")
	check(mods.find_child("addon-problem-future-addon", true, false) != null, "and why one wasn't loaded")
	check(mods.find_child("addon-options-test-addon", true, false) != null, "and its Options")
	mods.queue_free()

	# Settings (API 1.1).
	var section: String = api.settings.section()
	check(api.settings.value("speed") is int and int(api.settings.value("speed")) == 8 and api.settings.value("loud") == false and api.settings.value("look") == "down", "settings start at their defaults (a whole-number setting as an int)")
	node.changes.clear()
	api.settings.set_value("speed", 99)
	check(int(api.settings.value("speed")) == 40 and int(Settings.get_value(section, "speed")) == 40, "a number is kept within its range, in the settings file's section " + section)
	api.settings.set_value("blur", 0.33)
	check(is_equal_approx(float(api.settings.value("blur")), 0.35), "and on its step: %s" % api.settings.value("blur"))
	api.settings.set_value("look", "sideways")
	check(api.settings.value("look") == "down", "a choice that isn't one of its values is refused")
	check(node.changes.size() == 2 and node.changes[0] == ["speed", 40], "`changed` says which moved: %s" % [node.changes])
	api.settings.reset("speed")
	check(int(api.settings.value("speed")) == 8 and not Settings.has_value(section, "speed") and api.settings.is_default("speed"), "reset() goes back to the default")
	check(api.settings.add("speed", "number", 8, "Speed", {"min": 1, "max": 40}) == 8 and api.settings.list().size() == 5, "declaring again keeps one of each")

	# The Add-ons menu: the list, a page with the settings and keys.
	var win_a := AddonsWindow.new()
	win_a.addons = host
	win_a.selected = "test-addon"
	add_child(win_a)
	await get_tree().process_frame
	check(win_a.find_child("addon-item-test-addon", true, false) != null and win_a.find_child("addon-item-future-addon", true, false) != null, "the Add-ons menu lists every add-on found")
	var speed_row := win_a.find_child("addon-setting-test-addon-speed", true, false)
	var slider := speed_row.find_child("slider", true, false) as HSlider if speed_row != null else null
	check(slider != null and int(slider.value) == 8, "its page has a slider for a number setting")
	if slider != null:
		slider.value = 20
	check(int(api.settings.value("speed")) == 20, "moving it changes the setting")
	var loud := win_a.find_child("addon-setting-test-addon-loud", true, false) as CheckBox
	if loud != null:
		loud.button_pressed = true
	check(api.settings.value("loud") == true, "a check box for a bool")
	var look := win_a.find_child("addon-setting-test-addon-look", true, false) as OptionButton
	if look != null:
		look.select(1)
		look.item_selected.emit(1)
	check(api.settings.value("look") == "factorio", "a dropdown for a choice")
	var folder := win_a.find_child("addon-setting-test-addon-folder", true, false) as LineEdit
	if folder != null:
		folder.text_submitted.emit("C:/frames")
	check(api.settings.value("folder") == "C:/frames", "a text box for text")
	var key_button := win_a.find_child("addon-key-%s-1" % toggle, true, false) as Button
	check(key_button != null and win_a.find_child("addon-key-%s-0" % fly, true, false) != null, "its keys, global and camera, are on the page")
	if key_button != null:
		key_button.pressed.emit()
		_key(KEY_F9, true)
		await get_tree().process_frame
	check(Settings.keys_for(toggle) == [KEY_F8, KEY_F9 | KEY_MASK_SHIFT], "a key rebound there: %s" % [Settings.keys_for(toggle)])
	Settings.bind(toggle, [])
	var problem := win_a.find_child("addon-item-future-addon", true, false) as Button
	if problem != null:
		problem.pressed.emit()
	check(win_a.find_child("addon-problem-future-addon", true, false) != null, "an add-on that couldn't load says why on its page")
	check(win_a.find_child("addon-trust-note", true, false) != null and str((win_a.find_child("addon-trust-note", true, false) as Label).text).contains("your rights"),
		"every page says an add-on is a program running with your rights")
	win_a.select("dup-two")
	var new_note := win_a.find_child("addon-new-dup-two", true, false) as Label
	var new_switch := win_a.find_child("addon-switch-dup-two", true, false) as CheckBox
	var new_item := win_a.find_child("addon-item-dup-two", true, false) as Button
	check(new_note != null and new_note.text.contains("off until you switch it on") and new_note.text.contains("A folder")
		and new_switch != null and not new_switch.button_pressed and new_item != null and new_item.text.ends_with("(off)")
		and not host.find("dup-two").has("node"),
		"a new add-on is listed off, not started, its page saying so and where it came from")
	# The notes above it don't push the switch out of the page's view: it shows without scrolling.
	await get_tree().process_frame
	await get_tree().process_frame
	var page_view := win_a._scroll.get_global_rect()
	check(new_switch != null and is_instance_valid(new_switch) and page_view.encloses(new_switch.get_global_rect()) and win_a._scroll.scroll_vertical == 0,
		"a new add-on's switch is in view under the trust and new notes: %s in %s" % [new_switch.get_global_rect() if new_switch != null and is_instance_valid(new_switch) else null, page_view])
	# Switching it on there is the consent: started, saved on, the note gone; off again, saved off.
	if new_switch != null and is_instance_valid(new_switch):
		new_switch.button_pressed = true
		await get_tree().process_frame
	check(host.find("dup-two").has("node") and Settings.has_value("addons", "dup-two") and bool(Settings.get_value("addons", "dup-two"))
		and not AddonLoader.is_new(host.find("dup-two")) and win_a.find_child("addon-new-dup-two", true, false) == null,
		"switching a new add-on on starts it, saves it on and drops its note")
	var on_again := win_a.find_child("addon-switch-dup-two", true, false) as CheckBox
	if on_again != null:
		on_again.button_pressed = false
		await get_tree().process_frame
	check(not host.find("dup-two").has("node") and Settings.has_value("addons", "dup-two") and not bool(Settings.get_value("addons", "dup-two"))
		and win_a.find_child("addon-new-dup-two", true, false) == null, "switched off again it stays saved off, without the new note")
	Settings.reset_value("addons", "dup-two")
	win_a.select("test-addon")
	check(win_a.find_child("addon-new-test-addon", true, false) == null, "one switched on has no such note")
	win_a.select("dup-addon")
	check(win_a.find_child("addon-also-dup-addon", true, false) != null, "a page says when another copy of the add-on was left out")
	win_a.select("broken-zip")
	check(win_a.find_child("addon-problem-broken-zip", true, false) != null, "and a broken zip's page says why")
	win_a.select("test-addon")
	var sw := win_a.find_child("addon-switch-test-addon", true, false) as CheckBox
	check(sw != null and sw.button_pressed, "the page has the add-on's switch")
	win_a.queue_free()
	api.settings.reset("loud")
	api.settings.reset("look")
	api.settings.reset("folder")

	area_api_author._terrain(api, host)
	await area_api_author._sound(api, host)
	await area_shaders._shaders(api)
	area_shaders._sun_model()
	await area_shaders._sunset_look(api)
	await area_shaders._screenshot_mode(api, host, fake, hud_layer)
	area_api_author._game_link(api, host)
	area_weather_enemies._weather_api(api, host, fake)

	# Keeping Zenith drawing while recording (API 1.1).
	api.view.keep_drawing(50)
	fake.ups_governor._caps = {"fps": 45}
	check(AddonRequests.fps_floor() == 50 and int(fake.ups_governor.limit("fps", 0.0)) == 50, "the governor's frame cap stays at the recorder's rate")
	check(int(fake.ups_governor.limit("fps", 30.0)) == 30, "the player's own cap still stands")
	fake.ups_governor._caps = {}

	# Switched off: its keys, camera and windows go.
	check(api.camera.take(), "taken again")
	var settings_part = api.settings
	host.set_enabled("test-addon", false)
	check(node.stopped == 1 and not rig.taken() and not InputMap.has_action(fly) and not ControlsInfo.extra.has(fly), "switched off: stopped, the camera and its keys are gone")
	check(not AddonRequests.keeps_drawing() and settings_part.list().is_empty(), "and its hold on drawing, its settings' declarations")
	check(int(Settings.get_value(section, "speed")) == 20, "its settings' values are kept")
	check(Settings.has_value("addons", "test-addon") and not AddonLoader.enabled(host.find("test-addon")), "remembered as off")
	check(api.camera == null and api.settings == null and api.get("_character") == null and api.get("_host") == null,
		"switched off: the api lets its parts go (each holds it: the cycle broken)")
	host.set_enabled("test-addon", true)
	check(host.find("test-addon").has("node") and InputMap.has_action(fly), "and on again")
	host.game_ended()
	# A download's bundled add-ons start as package.py says (addons/bundled.json), until switched.
	_write("user://bundled-test.json", '{"cinematic-camera": true, "terrain-elevation": false}')
	var defaults := AddonLoader.bundled_defaults("user://bundled-test.json")
	check(defaults.get("cinematic-camera") == true and defaults.get("terrain-elevation") == false
		and AddonLoader.bundled_defaults("user://no-such-file.json").is_empty(),
		"bundled.json gives a download's add-ons their first state (the camera on, the hills off)")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://bundled-test.json"))
	await area_shaders._cinematic_shaders(fake)
	await area_weather_enemies._immersive_weather(fake)
	await area_weather_enemies._immersive_enemies(fake)
	await area_api_author._reload_and_errors(fake)
	await area_api_author._dependencies(fake, where)
	await area_api_author._fix2_checks(fake)
	await area_api_author._author_checks(fake)
	_finish()
