extends Node
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

const AddonHost := preload("res://scripts/addons/addon_host.gd")
const MomentHold := preload("res://scripts/world/moment_hold.gd")
const AddonLoader := preload("res://scripts/addons/addon_loader.gd")
const AddonRequests := preload("res://scripts/addons/addon_requests.gd")
const AddonStorage := preload("res://scripts/addons/addon_storage.gd")
const CameraRig := preload("res://scripts/player/camera_rig.gd")
const Controls := preload("res://scripts/player/controls.gd")
const ControlsInfo := preload("res://scripts/menu/controls_info.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const UpsGovernor := preload("res://scripts/world/ups_governor.gd")
const ModsWindow := preload("res://scripts/menu/mods_window.gd")
const AddonsWindow := preload("res://scripts/menu/addons_window.gd")
const Kit := preload("res://scripts/ui/factorio/kit.gd")
const BeltLaneLayer := preload("res://scripts/world/belt_lanes.gd")
const Looks := preload("res://scripts/world/looks.gd")
const PlanetSky := preload("res://scripts/world/sky.gd")
const LampLights := preload("res://scripts/world/lamp_lights.gd")
const WorkingGlow := preload("res://scripts/world/working_glow.gd")
const WorldMirror := preload("res://scripts/world/world.gd")
const ChunkView := preload("res://scripts/world/chunk_view.gd")
const ItemCards := preload("res://scripts/world/item_cards.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const BeltLods := preload("res://scripts/world/belt_lods.gd")
const FullDetail := preload("res://scripts/world/full_detail.gd")
const FrameBudget := preload("res://scripts/world/frame_budget.gd")

const TEST_SETTINGS := "user://addon-test-settings.cfg"
const DISK := "user://addon-test/addons"
const TestEnv := preload("res://tests/test_env.gd")

var fails := 0
## The checks that failed, listed again after FAILS.
var _failed: PackedStringArray = []


class FakeMain extends Node:
	var rig
	var avatar
	var input
	var hud
	var movers
	var world
	var ride
	var rockets
	var ups_governor
	var front_end
	var lamps
	var working_glow
	var _game: Node
	var _planet_sky
	var _daytime := 0.25
	var _darkness := 0.0
	var _space := false


class FakeFrontEnd extends Node:
	var session := "launched"
	var session_address := "127.0.0.1:36060"
	var launcher := FakeLauncher.new()
	var covered := false

	func covers_game() -> bool:
		return covered


## hud.gd as the host reads it: the UI's open windows and Zenith's debug menu (Ctrl+F12).
class FakeDebugMenu extends RefCounted:
	var open := false

	func is_open() -> bool:
		return open


class FakeUi extends RefCounted:
	var debug_menu := FakeDebugMenu.new()

	func is_open() -> bool:
		return false

	func map_open() -> bool:
		return false


class FakeHud extends Node:
	var ui := FakeUi.new()


class FakeLauncher extends RefCounted:
	var save_path := "C:/somewhere/saves/My base.zip"


class FakeRide extends Node:
	var on := false

	func riding() -> bool:
		return on

	func in_hub() -> bool:
		return false


class FakeSky extends Node:
	var forced_daytime := -1.0
	var planet := "nauvis"


## A world as api.terrain reads it (world.gd's chunks, records, prototypes and entities_changed).
class FakeProto extends RefCounted:
	var type := ""
	var _size := Vector2.ONE

	func _init(t: String, sz: Vector2) -> void:
		type = t
		_size = sz

	func size() -> Vector2:
		return _size


class FakeProtos extends RefCounted:
	var tile_is_water := PackedByteArray([0, 1, 2])
	var by_id := {}
	var entities_by_name := {}

	func entity(id: int):
		return by_id.get(id)


class FakeRec extends RefCounted:
	var proto_id := 0
	var pos := Vector2.ZERO
	var dir := 0
	var extra := {}


class FakeChunk extends RefCounted:
	var tile_ids := PackedInt32Array()
	var entities := {}


class FakeWorld extends Node:
	signal entities_changed(chunk: Vector2i)
	var chunks := {}
	var protos := FakeProtos.new()


## movers.gd as api.world reads it: one logistic robot (unit 7), drawn by the GPU from its record, so
## its node stays where it first appeared while position_of and yaw_of say where it is drawn now.
class FakeMovers extends Node:
	var protos := FakeProtos.new()
	var node := Node3D.new()

	func units_of_type(type: String) -> Array:
		return [[7, node]] if type == "logistic-robot" else []

	func node_of(unit: int) -> Node3D:
		return node if unit == 7 else null

	func position_of(unit: int) -> Variant:
		return Vector3(30, 2.2, 40) if unit == 7 else null

	func yaw_of(unit: int) -> float:
		return PI / 2.0 if unit == 7 else 0.0

	func proto_name_of(unit: int) -> String:
		return "logistic-robot" if unit == 7 else ""


## Zenith's controls further back in the tree than the add-ons: what reaches it, Zenith would see.
class Spy extends Node:
	var keys: Array = []

	func _unhandled_input(event: InputEvent) -> void:
		var k := event as InputEventKey
		if k != null and k.pressed:
			keys.append(k.physical_keycode)


func check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails += 1
		_failed.append(what)


func _exit_tree() -> void:
	for what in _failed:
		print("FAILED: " + what)
	TestEnv.clean()


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## A zip of these files ({path in the zip: text}); `raw` writes these bytes instead (a broken zip).
func _zip(path: String, files: Dictionary, raw := PackedByteArray()) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	if not raw.is_empty():
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(raw)
		f.close()
		return
	var z := ZIPPacker.new()
	z.open(path)
	for name in files:
		z.start_file(name)
		z.write_file(str(files[name]).to_utf8_buffer())
		z.close_file()
	z.close()


func _rmtree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for d in dir.get_directories():
		_rmtree(path.path_join(d))
	for f in dir.get_files():
		dir.remove(f)
	DirAccess.remove_absolute(path)


func _key(code: Key, shift := false) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.shift_pressed = shift
	ev.pressed = true
	get_viewport().push_input(ev)
	var up := ev.duplicate() as InputEventKey
	up.pressed = false
	get_viewport().push_input(up)


func _ready() -> void:
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
	_write(DISK + "/later-addon/addon.json", JSON.stringify({"id": "later-addon", "name": "Needs 1.9", "version": "1", "api": 1.9, "entry": "main.gd"}))
	_write(DISK + "/later-addon/main.gd", "extends Node\n")
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
	check(by_id.has("later-addon") and not by_id["later-addon"]["ok"] and str(by_id["later-addon"]["problem"]).contains("1.9"), "one asking for 1.9 is refused: " + str(by_id.get("later-addon", {}).get("problem", "")))

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
	check(api != null and is_equal_approx(api.level, 1.6), "and its level, 1.6")
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
	api.camera.set_focus(Vector2(100, 200))
	host._process(0.0)
	rig._process(0.0)
	check(rig.focus_point() == Vector2(100, 200), "or round a point the add-on names")
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

	_terrain(api, host)
	await _shaders(api)
	_sun_model()
	await _sunset_look(api)
	await _screenshot_mode(api, host, fake, hud_layer)

	# Keeping Zenith drawing while recording (API 1.1).
	api.view.keep_drawing(50)
	fake.ups_governor._caps = {"fps": 45}
	check(AddonRequests.fps_floor() == 50 and int(fake.ups_governor.limit("fps", 0.0)) == 50, "the governor's frame cap stays at the recorder's rate")
	check(int(fake.ups_governor.limit("fps", 30.0)) == 30, "the player's own cap still stands")
	fake.ups_governor._caps = {}

	# Switched off: its keys, camera and windows go.
	check(api.camera.take(), "taken again")
	host.set_enabled("test-addon", false)
	check(node.stopped == 1 and not rig.taken() and not InputMap.has_action(fly) and not ControlsInfo.extra.has(fly), "switched off: stopped, the camera and its keys are gone")
	check(not AddonRequests.keeps_drawing() and api.settings.list().is_empty(), "and its hold on drawing, its settings' declarations")
	check(int(Settings.get_value(section, "speed")) == 20, "its settings' values are kept")
	check(Settings.has_value("addons", "test-addon") and not AddonLoader.enabled(host.find("test-addon")), "remembered as off")
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
	await _cinematic_shaders(fake)
	_finish()


## API 1.6, for the Cinematic camera's screenshot mode: held chunks (the real world.gd's subscription
## steps), full detail (every distance and limit at its most, then the player's own back, nothing
## saved; every lamp lit) and a screenshot (the interface hidden, a file written, the interface back).
func _screenshot_mode(api, host, fake, hud_layer: CanvasLayer) -> void:
	# Held chunks: a chunk the view left stays while held (one that never arrived doesn't), and goes
	# when let go.
	var before_world = fake.world
	var w := WorldMirror.new()
	add_child(w)
	w.view_radius = 1
	w.hold_min_free = 0  # the PC's free memory doesn't decide the check
	fake.world = w
	w.set_focus(Vector2(16, 16))
	w._update_subscription(1.0)
	var kept := Vector2i(-1, -1)
	var came := w.chunks.has(kept) and w.chunks.has(Vector2i(1, 1))
	if came:
		(w.chunks[kept] as ChunkView).loaded = true
	api.world.hold_chunks(true)
	check(api.world.holding_chunks() and w.hold, "hold_chunks: the world holds its chunks")
	w.set_focus(Vector2(16 + 32 * 10, 16))
	w._update_subscription(1.0)
	check(came and w.chunks.has(kept) and not w.chunks.has(Vector2i(1, 1)) and api.world.held_chunks() == 1,
		"a chunk the camera left is kept while held, one that never arrived isn't: %d held" % api.world.held_chunks())
	check(w.chunks.has(Vector2i(10, 0)), "and the chunks round the new focus still come")
	api.world.hold_chunks(false)
	w._update_subscription(1.0)
	check(not w.chunks.has(kept) and api.world.held_chunks() == 0 and not w.hold, "let go: the held chunk is unloaded")
	_shot_settle(w)
	fake.world = before_world
	w.queue_free()

	# Full detail: the settings held at their tops without touching the file, lamps all lit, the
	# player's own back after.
	var lamps := LampLights.new()
	add_child(lamps)
	fake.lamps = lamps
	var glow := WorkingGlow.new()
	fake.working_glow = glow
	var radius_before: int = int(Settings.get_value("graphics", "view_radius"))
	var stored_before := Settings.has_value("graphics", "view_radius")
	var lod_before := str(Settings.get_value("graphics", "lod_quality"))
	var heard := []
	var listener := func(section: String, _key: String) -> void: heard.append(section)
	Settings.listen(listener)
	api.view.full_detail(true)
	check(api.view.full_detail_on() and int(Settings.get_value("graphics", "view_radius")) == 20
		and str(Settings.get_value("graphics", "lod_quality")) == "high" and int(Settings.get_value("graphics", "entity_radius")) == 256
		and int(Settings.get_value("graphics", "belt_distance")) == 640 and int(Settings.get_value("graphics", "decorative_distance")) == 320
		and str(Settings.get_value("graphics", "grass_3d")) == "far" and not bool(Settings.get_value("graphics", "merge_far")),
		"full_detail: every distance at its top (view, entity, belts, decoratives, grass), far chunks whole")
	check(ItemCards.model_cap < 0 and ModelLods.full_detail and not BeltLods.enabled and UpsGovernor.lifted,
		"Items in 3D uncapped, models at full level, no belt stand-ins, nothing held back for the UPS")
	check(lamps.max_lights == LampLights.FULL_LIGHTS and lamps._lights.size() >= LampLights.FULL_LIGHTS and glow.radius == WorkingGlow.FULL_RADIUS,
		"every lamp gets its light (%d), fires and glows far out" % lamps.max_lights)
	check(Settings.has_value("graphics", "view_radius") == stored_before and heard.size() == 1,
		"nothing written to the settings file, the listeners told once (%d)" % heard.size())
	api.view.full_detail(false)
	Settings.unlisten(listener)
	check(not api.view.full_detail_on() and int(Settings.get_value("graphics", "view_radius")) == radius_before
		and str(Settings.get_value("graphics", "lod_quality")) == lod_before and not ModelLods.full_detail and BeltLods.enabled
		and not UpsGovernor.lifted and lamps.max_lights == LampLights.MAX_LIGHTS and glow.radius == WorkingGlow.RADIUS,
		"and off: the player's own settings, levels, lamps and caps back")

	# A screenshot: the interface (and an add-on's overlay) hidden while it is taken, full detail on,
	# a file written on a worker thread, everything back.
	var sizes: Array = []
	host.test_capture = func(size: Vector2i) -> Image:
		sizes.append(size)
		return Image.create(8, 8, false, Image.FORMAT_RGB8)
	var saved := []
	api.view.screenshot_saved.connect(func(p: String, ok: bool) -> void: saved.append([p, ok]))
	var overlay: CanvasLayer = api.ui.layer()
	var folder := "user://addon-test/shots"
	var path: String = api.view.screenshot(null, {"folder": folder, "timeout": 3.0})
	check(path == folder.path_join("zenith-1.png") and api.view.screenshot_busy() and api.view.screenshot(null) == "",
		"screenshot: the next zenith-<n>.png in the folder, one at a time (%s)" % path)
	await get_tree().process_frame
	check(not hud_layer.visible and host.interface_hidden() and not overlay.visible and api.view.full_detail_on(),
		"while it is taken: the HUD and the add-on's overlay hidden, full detail on")
	check(MomentHold.on, "and the moment held: Zenith's view of time stands still")
	var t0 := Time.get_ticks_msec()
	while (api.view.screenshot_busy() or saved.is_empty()) and Time.get_ticks_msec() - t0 < 8000:
		await get_tree().process_frame
	check(not saved.is_empty() and saved[0][0] == path and bool(saved[0][1]) and FileAccess.file_exists(path),
		"the PNG is written and screenshot_saved says so: %s" % [saved])
	check(hud_layer.visible and overlay.visible and not host.interface_hidden() and not api.view.full_detail_on()
		and int(Settings.get_value("graphics", "view_radius")) == radius_before,
		"then the interface, the overlay and the player's settings are back")
	check(not MomentHold.on, "and time runs again")
	check(host._toast != null and host._toast.visible, "and \"Screenshot saved\" shows, with Open folder")
	check(AddonHost.screenshot_path(null, {"folder": folder}) == folder.path_join("zenith-2.png")
		and AddonHost.screenshot_path("user://x/y.png", {}) == "user://x/y.png", "the next one is zenith-2.png; a .png path is used as it is")
	check(sizes.size() == 1 and sizes[0] == host._window_size(), "without size or scale, the window's size (%s)" % [sizes])
	# An 8K one: the size option reaches the capture as it is.
	saved.clear()
	path = api.view.screenshot(null, {"folder": folder, "timeout": 3.0, "size": Vector2i(7680, 4320)})
	t0 = Time.get_ticks_msec()
	while (api.view.screenshot_busy() or saved.is_empty()) and Time.get_ticks_msec() - t0 < 8000:
		await get_tree().process_frame
	check(sizes.size() == 2 and sizes[1] == Vector2i(7680, 4320) and not saved.is_empty() and bool(saved[0][1]),
		"size: Vector2i(7680, 4320) is drawn at 8K (%s)" % [sizes])
	check(FullDetail.shot_aspect == 0.0 and not FrameBudget.boost, "after it the view's shape and the frame budget are back")
	check(host._progress != null and not host._progress.visible, "and its progress bar is gone")
	# Cancelled: nothing written, everything back.
	var cancelled := []
	api.view.screenshot_cancelled.connect(func(p: String) -> void: cancelled.append(p))
	saved.clear()
	path = api.view.screenshot(null, {"folder": folder, "timeout": 3.0})
	await get_tree().process_frame
	check(host._progress != null and host._progress.visible and not host._shot_layers.has(host._progress),
		"while it is taken its progress shows, on a layer the shot doesn't hide")
	check(api.view.screenshot_cancel(), "screenshot_cancel: one is being taken")
	t0 = Time.get_ticks_msec()
	while api.view.screenshot_busy() and Time.get_ticks_msec() - t0 < 8000:
		await get_tree().process_frame
	check(cancelled == [path] and saved.is_empty() and not FileAccess.file_exists(path) and sizes.size() == 2,
		"cancelled: screenshot_cancelled, no picture taken, no file (%s, %s)" % [cancelled, saved])
	check(hud_layer.visible and not host.interface_hidden() and not api.view.full_detail_on() and not host._progress.visible
		and not api.view.screenshot_cancel(), "and the interface, full detail and the progress are back as they were")
	_shot_sizes()
	host.test_capture = Callable()
	fake.lamps = null
	fake.working_glow = null
	lamps.queue_free()
	glow.free()


## The screenshot's size (API 1.6 `size`, `scale`), the MSAA it is drawn with at 8K, and its camera
## framing the window's height at another shape.
func _shot_sizes() -> void:
	var win := Vector2i(1600, 900)
	check(AddonHost.shot_size({"size": Vector2i(7680, 4320)}, win) == Vector2i(7680, 4320)
		and AddonHost.shot_size({"size": [3840, 2160]}, win) == Vector2i(3840, 2160)
		and AddonHost.shot_size({}, win) == win and AddonHost.shot_size({"scale": 2}, win) == Vector2i(3200, 1800)
		and AddonHost.shot_size({"size": Vector2i(0, 0), "scale": 4}, win) == Vector2i(6400, 3600),
		"shot_size: `size` as given (a Vector2i or [w, h]), else the window times `scale`")
	check(AddonHost.shot_size({"size": Vector2i(20000, 10000)}, win) == Vector2i(16384, 8192)
		and AddonHost.shot_size({"scale": 4}, Vector2i(5120, 2880)) == Vector2i(16384, 9216),
		"and never past Godot's 16384 a side, the shape kept")
	check(AddonHost.shot_msaa(Viewport.MSAA_4X, Vector2i(7680, 4320)) == Viewport.MSAA_2X
		and AddonHost.shot_msaa(Viewport.MSAA_8X, Vector2i(7680, 4320)) == Viewport.MSAA_2X
		and AddonHost.shot_msaa(Viewport.MSAA_4X, Vector2i(3840, 2160)) == Viewport.MSAA_4X
		and AddonHost.shot_msaa(Viewport.MSAA_DISABLED, Vector2i(7680, 4320)) == Viewport.MSAA_DISABLED,
		"8K steps 4x and 8x MSAA down to 2x (video memory); 4K keeps 4x")
	var cam := Camera3D.new()
	cam.fov = 60.0
	cam.size = 20.0
	check(FullDetail.vertical_frame(cam, Vector2(1600, 900)) == Vector2(60.0, 20.0), "a camera keeping its height is framed as it is")
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	var f := FullDetail.vertical_frame(cam, Vector2(1600, 900))
	var want := rad_to_deg(2.0 * atan(tan(deg_to_rad(30.0)) * 900.0 / 1600.0))
	check(absf(f.x - want) < 0.001 and absf(f.y - 20.0 * 900.0 / 1600.0) < 0.001,
		"one keeping its width: the window's vertical field of view and height (%s)" % f)
	cam.free()


## The screenshot's settle (full_detail.gd pending): chunks count only in the camera's view, and one
## that hasn't arrived stops counting once the bridge has sent nothing new for a while.
func _shot_settle(w) -> void:
	w.set_focus(Vector2(16, 16))
	w._update_subscription(1.0)
	var all := func(_c: Vector2i) -> bool: return true
	var one := func(c: Vector2i) -> bool: return c == Vector2i(0, 0)
	var wanted: int = w._wanted.size()
	check(wanted == 9 and w.unsettled_in(all, false) == 9 and w.unsettled_in(all, true) == 0,
		"unsettled_in: 9 wanted chunks on their way count, none once the bridge has given up (%d, %d)" % [wanted, w.unsettled_in(all, false)])
	check(w.unsettled_in(one, false) == 1, "only those in the view count")
	var before: int = w.last_arrival_msec
	w.handle({"t": "chunk", "cx": 0, "cy": 0, "none": true})
	check(w.unsettled_in(one, false) == 1 and w.last_arrival_msec >= before and w.last_arrival_msec > 0,
		"a chunk that came is noted as an arrival, and counts until it is drawn")
	check(not FullDetail.given_up(w), "the bridge has just sent one: not given up")
	w.last_arrival_msec = Time.get_ticks_msec() - FullDetail.QUIET_MSEC - 1
	FullDetail._since = w.last_arrival_msec  # full detail came on before that too
	check(FullDetail.given_up(w), "nothing new for %d ms: given up" % FullDetail.QUIET_MSEC)
	var report_before: Dictionary = Bridge.work_budget
	var report_at: int = Bridge.work_budget_msec
	Bridge.work_budget = {"q": {"chunks": 5}}
	Bridge.work_budget_msec = Time.get_ticks_msec()
	check(not FullDetail.given_up(w), "but not while the bridge's last report has chunks queued (it reads one a tick)")
	Bridge.work_budget_msec = Time.get_ticks_msec() - FullDetail.REPORT_MSEC - 1
	check(FullDetail.given_up(w), "a report that old isn't read")
	Bridge.work_budget = report_before
	Bridge.work_budget_msec = report_at
	# A screenshot's cover: the chunks its camera sees asked for besides the view's own square, in
	# one square fitted round both.
	var subs_before: int = Bridge.square_subs
	Bridge.square_subs = WorldMirror.MAX_VIEW_RADIUS
	w._update_subscription(1.0)
	var own_wanted: int = w._wanted.size()
	var east := func(c: Vector2i) -> bool: return c.x >= 5
	w.set_cover(Rect2i(Vector2i(5, -2), Vector2i(3, 5)), Vector2i(0, 0), east)
	w._update_subscription(1.0)
	var seen_in := 0
	for c: Vector2i in w._wanted:
		if c.x >= 5:
			seen_in += 1
	check(own_wanted == 9 and w._sq_center == Vector2i(3, 0) and w._sq_radius == 4 and w._wanted.size() == 9 + 27 and seen_in == 27,
		"cover: the square fitted round the view's and the camera's (%s r %d), its seen chunks asked for besides the view's 9 (%d)" % [w._sq_center, w._sq_radius, w._wanted.size()])
	w.clear_cover()
	w._update_subscription(1.0)
	check(w._wanted.size() == 9 and w._sq_center == Vector2i(0, 0) and w._sq_radius == 1, "and after it the view's own square again")
	Bridge.square_subs = subs_before
	var fit: Array = WorldMirror.fit_square(Rect2i(0, 0, 300, 5), Vector2i(290, 2), 50)
	check(fit[0] == Vector2i(249, 2) and fit[1] == 50, "a view wider than the bridge's square: its part nearest the camera (%s)" % [fit])
	var down := Camera3D.new()
	add_child(down)
	down.fov = 90.0
	down.position = Vector3(0, 100, 0)
	down.rotation_degrees = Vector3(-90, 0, 0)
	var foot := FullDetail.ground_footprint(down, Vector2(900, 900), 1.0, 3000.0)
	check(foot.position.distance_to(Vector2(-100, -100)) < 0.5 and foot.size.distance_to(Vector2(200, 200)) < 1.0,
		"ground_footprint: straight down, the square under the camera (%s)" % foot)
	down.rotation_degrees = Vector3(0, 0, 0)
	foot = FullDetail.ground_footprint(down, Vector2(900, 900), 1.0, 3000.0)
	check(foot.position.y < -2100.0 and foot.end.y <= 0.5 and absf(foot.position.x + 2121.3) < 1.0, "looking at the horizon: out to the reach along the top corners (%s)" % foot)
	down.free()
	# A screenshot's moment: the drawn clock stands still however much comes, and runs on after it.
	var clock = preload("res://scripts/world/game_clock.gd").new()
	clock.heard(100.0)
	clock.advance(0.1)
	MomentHold.begin()
	var at_hold: float = clock.advance(0.0)
	clock.advance(0.5)
	clock.heard(400.0)
	var held_at: float = clock.advance(0.5)
	var kinds_held: bool = Bridge._holding and Bridge._hold_kinds.has("mv")
	MomentHold.end()
	var after: float = clock.advance(0.1)
	check(at_hold == held_at and kinds_held and after > held_at and not Bridge._holding,
		"the moment: the clock held at %.1f through a jump to tick 400, movers' updates waiting; after it on to %.1f" % [held_at, after])
	var shots := AddonHost.default_screenshot_folder()
	check(shots == "user://screenshots" if OS.get_system_dir(OS.SYSTEM_DIR_PICTURES) == "" else (shots.get_file() == "Zenith" and not shots.begins_with("user://")),
		"screenshots go to the Pictures folder's Zenith (%s)" % shots)
	# The view: a camera at the origin looking north (-Z).
	var cam := Camera3D.new()
	add_child(cam)
	cam.fov = 70.0
	cam.far = 500.0
	var planes := FullDetail.view_planes(cam, Vector2(1600, 900), 16.0 / 9.0, 0.0)
	check(FullDetail.box_in_view(planes, Vector3(-5, -5, -105), Vector3(5, 5, -95))
		and not FullDetail.box_in_view(planes, Vector3(-5, -5, 95), Vector3(5, 5, 105))
		and not FullDetail.box_in_view(planes, Vector3(300, -5, -105), Vector3(310, 5, -95))
		and not FullDetail.box_in_view(planes, Vector3(-5, -5, -700), Vector3(5, 5, -690)),
		"view_planes: a box ahead is in view; behind, far to the side or past the far plane isn't")
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 20.0
	planes = FullDetail.view_planes(cam, Vector2(1600, 900), 16.0 / 9.0, 0.0)
	check(FullDetail.box_in_view(planes, Vector3(14, -1, -50), Vector3(16, 1, -48))
		and not FullDetail.box_in_view(planes, Vector3(20, -1, -50), Vector3(22, 1, -48))
		and FullDetail.box_in_view(FullDetail.view_planes(cam, Vector2(1600, 900), 16.0 / 9.0, 8.0), Vector3(20, -1, -50), Vector3(22, 1, -48)),
		"orthographic: within half its width (17.8 tiles) in view, past it not, but within the margin")
	planes = FullDetail.view_planes(cam, Vector2(1600, 900), 1.0, 0.0)
	check(not FullDetail.box_in_view(planes, Vector3(14, -1, -50), Vector3(16, 1, -48)), "a square shot is narrower")
	# Held chunks: never more than 1,600, nor past 3,281 loaded with the view's own.
	var wanted_before: Array = w._wanted
	w._wanted = []
	w._wanted.resize(441)
	var at_10: int = w._hold_limit()
	w._wanted.resize(3000)
	var at_27: int = w._hold_limit()
	w._wanted.resize(3721)
	var at_30: int = w._hold_limit()
	w._wanted = wanted_before
	check(at_10 == 1600 and at_27 == 281 and at_30 == 0,
		"hold_chunks' cap: 1,600 at view 10, fewer as the view grows, none at 30 (%d, %d, %d)" % [at_10, at_27, at_30])
	remove_child(cam)
	cam.free()


## The Cinematic shaders add-on (addons-src/): the add-on is the look, on while it is on, with TAA
## while its look is in use; switched off, the Factorio look and the player's own TAA come back.
func _cinematic_shaders(fake) -> void:
	var src := ProjectSettings.globalize_path("res://").path_join("../addons-src/cinematic-shaders").simplify_path()
	if not DirAccess.dir_exists_absolute(src):
		check(false, "cinematic shaders: the add-on's folder is at " + src)
		return
	var look_before = Settings.get_value("graphics", "look")
	var vp := get_viewport()
	vp.use_taa = false
	Settings.set_value("graphics", "look", "classic")
	var look_env := Environment.new()
	var look_sun := DirectionalLight3D.new()
	var game_looks := Looks.new()
	add_child(look_sun)
	add_child(game_looks)
	game_looks.attach(look_env, look_sun)
	var host := AddonHost.new()
	host.autoload = false
	host.main = fake
	add_child(host)
	host.load_all([[src.get_base_dir(), "test"]])
	await get_tree().process_frame
	var m := host.find("cinematic-shaders")
	var node: Node = m.get("node")
	check(node != null, "cinematic shaders: the add-on starts: " + str(m.get("problem", "")))
	if node == null:
		host.queue_free()
		game_looks.queue_free()
		look_sun.queue_free()
		return
	var ids: Array = node.api.settings.list().map(func(d: Dictionary) -> String: return str(d.get("id", "")))
	check(str(Settings.get_value("graphics", "look")) == node.LOOK and not ids.has("use"),
		"cinematic shaders: its look is put on when it starts, with no switch of its own: %s" % [ids])
	check(game_looks.current == node.LOOK and not vp.use_taa, "cinematic shaders: TAA off by default (moving parts flicker under it)")
	check(not game_looks.own_clouds(), "cinematic shaders: Zenith's own clouds are off under its look")
	check(is_equal_approx(game_looks.twilight(), 1.0) and Looks.looks[node.LOOK].has("at_twilight") and Looks.looks[node.LOOK].has("at_dawn"), "cinematic shaders: it has a sunrise and sunset")
	node.api.settings.set_value("sunset", 0.5, false)
	check(is_equal_approx(game_looks.twilight(), 0.5), "cinematic shaders: its slider scales the sunset")
	node.api.settings.set_value("sunset", 1.0, false)
	check(not node.has_method("_process"), "cinematic shaders: it no longer reaches into Zenith for the sun")
	node.api.settings.set_value("taa", true, false)
	check(vp.use_taa, "cinematic shaders: TAA on while its look is in use, when asked for")
	game_looks.lift()
	game_looks.settle(str(Settings.get_value("graphics", "look")))
	check(vp.use_taa and not game_looks.own_clouds(), "cinematic shaders: changing a Graphics setting leaves the look's TAA and clouds as they are")
	check(Looks.looks.has(node.LOOK) and float(Looks.looks[node.LOOK].get("roughness_min", 0.0)) > 0.3,
		"cinematic shaders: its look asks for a roughness floor")
	host.set_enabled("cinematic-shaders", false)
	await get_tree().process_frame
	check(str(Settings.get_value("graphics", "look")) == "classic" and game_looks.current == "classic" and not vp.use_taa and game_looks.own_clouds(),
		"cinematic shaders: switched off, the look it replaced, the player's own TAA (off) and Zenith's clouds come back")
	Settings.set_value("graphics", "look", look_before)
	Settings.reset_value("graphics", "look_before")
	Settings.reset_value("addons", "cinematic-shaders")
	host.queue_free()
	game_looks.queue_free()
	look_sun.queue_free()


## sky.gd's sun as pure functions (add-on API 1.5): the path, the colour through the air, the swap to
## the moon with no light on, each planet's day.
func _sun_model() -> void:
	check(PlanetSky.darkness_at(0.2) == 0.0 and PlanetSky.darkness_at(0.25) == 0.0 and is_equal_approx(PlanetSky.darkness_at(0.35), 0.425)
		and is_equal_approx(PlanetSky.darkness_at(0.45), 0.85) and is_equal_approx(PlanetSky.darkness_at(0.5), 0.85)
		and is_equal_approx(PlanetSky.darkness_at(0.65), 0.425) and PlanetSky.darkness_at(0.75) == 0.0,
		"sun: --sky=@daytime's darkness is Factorio's ramp")
	check(is_equal_approx(PlanetSky.sun_elevation(0.0, 0.0), PlanetSky.E_NOON) and is_equal_approx(PlanetSky.sun_elevation(0.25, 0.0), PlanetSky.E_DUSK)
		and is_equal_approx(PlanetSky.sun_elevation(0.5, 1.0), PlanetSky.E_SET), "sun: high at noon, low at dusk, under the horizon at night")
	check(PlanetSky.sun_elevation(0.38, 0.65) > 0.0 and PlanetSky.sun_elevation(0.4, 0.75) < 0.0, "sun: it crosses the horizon about 0.7 of the way into the night")
	var west := PlanetSky._towards(0.0, PlanetSky.sun_yaw(0.0, false))
	var east := PlanetSky._towards(0.0, PlanetSky.sun_yaw(0.0, true))
	check(west.x < -0.9 and west.z < 0.0 and east.x > 0.9, "sun: sets west with a little north, rises east: %s %s" % [west, east])
	check(is_equal_approx(PlanetSky.sun_yaw(PlanetSky.E_NOON, false), PlanetSky.sun_yaw(PlanetSky.E_NOON, true)), "sun: the same place at noon coming and going")
	var scatter: Color = PlanetSky.PLANETS["nauvis"]["twilight"]["scatter"]
	var noon := PlanetSky.sun_tint(scatter, PlanetSky.E_NOON)
	var gold := PlanetSky.sun_tint(scatter, 12.0)
	var red := PlanetSky.sun_tint(scatter, 0.0)
	check(noon.is_equal_approx(Color.WHITE), "sun: white at noon")
	check(gold.r > gold.g and gold.g > gold.b and gold.g > 0.55, "sun: gold 12 degrees up: %s" % gold)
	check(red.g < 0.2 and red.b < 0.05, "sun: deep red at the horizon: %s" % red)
	check(PlanetSky.twilight_at(PlanetSky.E_NOON) == 0.0 and PlanetSky.twilight_at(PlanetSky.E_SET) == 0.0 and PlanetSky.twilight_at(3.0) > 0.9, "sun: twilight peaks with the sun at the horizon")
	for planet: String in PlanetSky.PLANETS:
		var p: Dictionary = PlanetSky.PLANETS[planet]
		var at_noon := PlanetSky.sun_model(p, 0.0, 0.0)
		check((at_noon["light_color"] as Color).is_equal_approx(p["sun"][0]) and (at_noon["ambient"] as Color).is_equal_approx(p["ambient"][0])
			and is_equal_approx(float(at_noon["light_energy"]), float(p["sun_energy"][0])), "sun: %s at noon is the planet's day" % planet)
		var prev := {}
		var pops := 0
		var floors := 0
		for i in 2000:
			var d := float(i) / 2000.0
			var m := PlanetSky.sun_model(p, d, PlanetSky.darkness_at(d) / PlanetSky.FULL_DARKNESS)
			if float(m["elevation"]) >= -1.0 and float(m["light_pitch"]) < PlanetSky.LIGHT_FLOOR:
				floors += 1
			if not prev.is_empty():
				var moved := absf(wrapf(float(m["light_yaw"]) - float(prev["light_yaw"]), -180.0, 180.0))
				if moved > 15.0 and maxf(float(m["light_energy"]), float(prev["light_energy"])) > 0.001:
					pops += 1
				if absf(float(m["ambient_energy"]) - float(prev["ambient_energy"])) > 0.08:
					pops += 1
			prev = m
		check(pops == 0, "sun: %s through a whole day: no jump in the light while it shines (%d)" % [planet, pops])
		check(floors == 0, "sun: %s: the light never lower than its floor" % planet)
	var at := PlanetSky.sun_model(PlanetSky.PLANETS["gleba"], 0.34, 0.45)
	var dawn := PlanetSky.sun_model(PlanetSky.PLANETS["gleba"], 0.66, 0.45)
	check((at["sun_color"] as Color).r > (at["sun_color"] as Color).g and (dawn["sun_color"] as Color).g > (dawn["sun_color"] as Color).r,
		"sun: Gleba's dusk is rose and its dawn green: %s %s" % [at["sun_color"], dawn["sun_color"]])
	check(PlanetSky.water_tint(Color(0.7, 0.8, 0.88), Color(0.7, 0.8, 0.88)).is_equal_approx(PlanetSky.WATER_SKY), "water: by day its tint is as it was")
	var cold := PlanetSky.water_tint(Color(0.05, 0.07, 0.12), Color(0.7, 0.8, 0.88))
	check(cold.b > PlanetSky.WATER_SKY.b and absf(cold.get_luminance() - PlanetSky.WATER_SKY.get_luminance()) < 0.08, "water: at night it follows the sky's colour, not its darkness: %s" % cold)
	var points: Array = []
	for u in 500:
		points.append(LampLights.on_at(u + 1000))
	check(points.min() >= LampLights.ON_DARKNESS and points.max() <= LampLights.ALL_ON_DARKNESS and points.max() - points.min() > 0.18
		and LampLights.on_at(1234) == LampLights.on_at(1234), "lamps: each comes on at its own point between 0.3 and 0.5")


## A look's sunrise and sunset (1.5): twilight for sky.gd, at_twilight and at_dawn blended by the sun,
## the pass's sun uniforms, api.shaders.sun(), and the light left as it was without one.
func _sunset_look(api) -> void:
	var sh = api.shaders
	var env := Environment.new()
	var sun := DirectionalLight3D.new()
	var looks := Looks.new()
	var sky := PlanetSky.new()
	add_child(sun)
	add_child(looks)
	add_child(sky)
	looks.attach(env, sun)
	sky.set_planet("nauvis")
	check(looks.twilight() == 0.0 and looks.sky_twilight() > 0.0 and looks.sky_twilight() < 1.0, "sunset: the Factorio look has none on the ground and a restrained one in its sky")
	sky.twilight = 0.0
	sky.sky_twilight = 0.0
	sky.apply(env, sun, 0.35, 0.5, 0.016, false)
	var high := clampf(cos(TAU * 0.35) * 0.5 + 0.5, 0.0, 1.0)
	check(is_equal_approx(sun.rotation_degrees.x, -lerpf(20.0, 60.0, high)) and is_equal_approx(sun.light_energy, lerpf(1.1, 0.12, 0.5))
		and sun.light_color.is_equal_approx(Color(1.0, 0.97, 0.92).lerp(Color(0.6, 0.68, 0.95), 0.5)), "sunset: at twilight 0 the sun is the old one")
	var ok: bool = sh.add_look("test-addon/dusk", {"name": "Dusk", "twilight": 0.8, "exposure": 1.0,
		"environment": {"fog_density": 0.01},
		"sun": {"shadow_opacity": 1.0},
		"at_twilight": {"environment": {"tonemap_exposure": 2.0, "fog_density": 0.02}, "sun": {"shadow_opacity": 0.5}, "params": {"strength": 1.0}},
		"at_dawn": {"environment": {"fog_height": 3.0, "fog_density": 0.04}},
		"fog_from_sky": 1.0,
		"passes": [{"shader": "grey.gdshader", "params": {"strength": 0.2}}]})
	check(ok, "sunset: an add-on's look with a sunset")
	looks.use("test-addon/dusk")
	var pass_node: MeshInstance3D = looks.get_children().filter(func(n: Node) -> bool: return n is MeshInstance3D)[0]
	var m := pass_node.material_override as ShaderMaterial
	check(is_equal_approx(looks.twilight(), 0.8) and is_equal_approx(looks.sky_twilight(), 0.8), "sunset: sky_twilight follows twilight when not given")
	var fog_before := env.fog_light_color
	looks.apply(0.0, 0.0, "nauvis", false, {"elevation": 60.0, "height": 0.87, "twilight": 0.0, "morning": false, "direction": Vector3.UP, "color": Color.WHITE, "ambient": Color.GRAY, "fog": Color.RED})
	check(is_equal_approx(env.tonemap_exposure, 1.0) and is_equal_approx(env.fog_density, 0.01) and is_equal_approx(sun.shadow_opacity, 1.0)
		and is_equal_approx(float(m.get_shader_parameter("strength")), 0.2) and env.fog_light_color.is_equal_approx(fog_before), "sunset: at noon the look's own values")
	looks.apply(0.35, 0.5, "nauvis", false, {"elevation": 3.0, "height": 0.05, "twilight": 0.5, "morning": false, "direction": Vector3.LEFT, "color": Color.ORANGE, "ambient": Color.BLUE, "fog": Color.RED})
	check(is_equal_approx(env.tonemap_exposure, 1.5) and is_equal_approx(env.fog_density, 0.015) and is_equal_approx(sun.shadow_opacity, 0.75)
		and is_equal_approx(float(m.get_shader_parameter("strength")), 0.6), "sunset: at_twilight is blended by how low the sun is")
	check(env.fog_light_color.is_equal_approx(fog_before.lerp(Color.RED, 0.5)), "sunset: the fog takes the sky's colour")
	check(is_equal_approx(float(m.get_shader_parameter("look_twilight")), 0.5) and is_equal_approx(float(m.get_shader_parameter("look_sun_height")), 0.05)
		and (m.get_shader_parameter("look_sun_dir") as Vector3).is_equal_approx(Vector3.LEFT) and (m.get_shader_parameter("look_sun_color") as Color).is_equal_approx(Color.ORANGE)
		and float(m.get_shader_parameter("look_morning")) == 0.0, "sunset: passes are given the sun")
	looks.apply(0.35, 0.5, "", true, {"elevation": 3.0, "height": 0.05, "twilight": 0.5, "morning": false, "direction": Vector3.LEFT, "color": Color.ORANGE, "ambient": Color.BLUE, "fog": Color.RED})
	var in_space := float(m.get_shader_parameter("look_space"))
	looks.apply(0.35, 0.5, "nauvis", false, {"elevation": 3.0, "height": 0.05, "twilight": 0.5, "morning": false, "direction": Vector3.LEFT, "color": Color.ORANGE, "ambient": Color.BLUE, "fog": Color.RED})
	check(in_space == 1.0 and float(m.get_shader_parameter("look_space")) == 0.0,
		"passes are told when the view is on a space platform (look_space: the Cinematic clouds stay off there)")
	looks.apply(0.65, 0.5, "nauvis", false, {"elevation": 3.0, "height": 0.05, "twilight": 1.0, "morning": true, "direction": Vector3.RIGHT, "color": Color.ORANGE, "ambient": Color.BLUE, "fog": Color.RED})
	check(is_equal_approx(env.fog_density, 0.04) and is_equal_approx(env.fog_height, 3.0) and is_equal_approx(env.tonemap_exposure, 2.0) and float(m.get_shader_parameter("look_morning")) == 1.0,
		"sunset: at_dawn in the morning, over at_twilight's")
	looks.apply(0.45, 0.5, "nauvis", false, {"elevation": 3.0, "height": 0.05, "twilight": 1.0, "morning": false, "direction": Vector3.RIGHT, "color": Color.ORANGE, "ambient": Color.BLUE, "fog": Color.RED})
	check(is_equal_approx(env.fog_height, 0.0), "sunset: a dawn-only value has nothing to go to at dusk")
	var from_api: Dictionary = sh.sun()
	check(is_equal_approx(float(from_api.get("twilight", -1.0)), 1.0) and from_api.get("morning") == false, "sunset: api.shaders.sun() says where the sun is")
	sky.twilight = 1.0
	sky.sky_twilight = 1.0
	sky.apply(env, sun, 0.34, 0.45, 0.016, true)
	check(sky.state["twilight"] == 0.0, "sunset: no dusk on a space platform")
	sky.apply(env, sun, 0.34, 0.45, 0.016, false)
	check(sky.state["twilight"] > 0.5 and sun.light_color.r > sun.light_color.b * 1.5 and is_equal_approx(sun.rotation_degrees.x, -PlanetSky.LIGHT_FLOOR),
		"sunset: at dusk the light is warm and held at its floor: %s %s" % [sun.light_color, sun.rotation_degrees])
	looks.use("classic")
	check(is_equal_approx(env.fog_density, Environment.new().fog_density) and is_equal_approx(env.tonemap_exposure, 1.0) and is_equal_approx(env.fog_height, 0.0),
		"sunset: another look puts everything the sunset moved back")
	sh.remove_look("test-addon/dusk")
	sky.queue_free()
	looks.queue_free()
	sun.queue_free()
	await get_tree().process_frame


## api.shaders (1.3): an add-on's look in the Look setting's list, put on a scene's environment and
## sun (tonemapping, the light's multipliers, the held sun, environment and sun properties, its pass
## from the add-on's folder), a pass over every look, and all of it gone again with the add-on.
func _shaders(api) -> void:
	var sh = api.shaders
	var ids: Array = sh.looks().map(func(c: Array) -> String: return str(c[1]))
	check(ids.has("factorio") and ids.has("classic"), "shaders: Zenith's Factorio and Classic looks are listed: %s" % [ids])
	var env := Environment.new()
	var sun := DirectionalLight3D.new()
	var looks := Looks.new()
	add_child(sun)
	add_child(looks)
	looks.attach(env, sun)
	check(looks.current == "factorio" and env.tonemap_mode == Environment.TONE_MAPPER_LINEAR, "shaders: the Factorio look is on by default, linear tonemapping")
	looks.apply(0.0, 0.0, "nauvis", false)
	var held := sun.rotation_degrees
	check(is_equal_approx(held.x, Looks.FACTORIO["sun_angle"].x) and is_equal_approx(held.y, Looks.FACTORIO["sun_angle"].y), "shaders: Factorio's look holds the sun where Factorio's shadows fall: %s" % [held])
	var ok: bool = sh.add_look("test-addon/grey", {"name": "Grey", "tonemap": Environment.TONE_MAPPER_AGX, "exposure": 1.3,
		"sun_energy": 2.0, "environment": {"glow_enabled": true, "ssao_enabled": true}, "sun": {"light_angular_distance": 1.5, "light_energy": 9.0},
		"passes": [{"shader": "grey.gdshader", "params": {"strength": 0.25}}]})
	check(ok and sh.looks().any(func(c: Array) -> bool: return c[1] == "test-addon/grey"), "shaders: an add-on's look joins the list")
	check(not Looks.register("test-addon/grey", {}, "someone-else") and not sh.add_look("classic", {}), "shaders: nobody else's look can be replaced, nor Zenith's")
	looks.use("test-addon/grey")
	sun.light_energy = 1.0
	looks.apply(0.0, 0.0, "nauvis", false)
	var passes := looks.get_children().filter(func(n: Node) -> bool: return n is MeshInstance3D)
	check(env.tonemap_mode == Environment.TONE_MAPPER_AGX and is_equal_approx(env.tonemap_exposure, 1.3) and env.glow_enabled and env.ssao_enabled,
		"shaders: the look's tonemapping and environment are on")
	check(is_equal_approx(sun.light_energy, 2.0) and is_equal_approx(sun.light_angular_distance, 1.5), "shaders: its sun: the light doubled, soft shadows: %s %s" % [sun.light_energy, sun.light_angular_distance])
	check(passes.size() == 1 and is_equal_approx(float((passes[0].material_override as ShaderMaterial).get_shader_parameter("strength")), 0.25),
		"shaders: its pass from the add-on's folder, with its uniform: %d" % passes.size())
	sh.set_parameter(0, "strength", 0.75)
	check(passes.size() == 1 and is_equal_approx(float((passes[0].material_override as ShaderMaterial).get_shader_parameter("strength")), 0.75), "shaders: set_parameter(0) reaches the look's pass")
	var pid: int = sh.add_pass("grey.gdshader", {"strength": 0.5})
	check(pid > 0 and looks.get_children().filter(func(n: Node) -> bool: return n is MeshInstance3D).size() == 2, "shaders: a pass over every look is drawn too")
	check(sh.add_pass("res://shaders/no-such.gdshader") == 0, "shaders: a missing shader isn't a pass")
	looks.use("classic")
	await get_tree().process_frame
	check(not env.glow_enabled and not env.ssao_enabled and env.tonemap_mode == Environment.TONE_MAPPER_FILMIC and is_equal_approx(sun.light_angular_distance, 0.0),
		"shaders: another look puts the environment and sun back")
	check(looks.get_children().filter(func(n: Node) -> bool: return n is MeshInstance3D and not n.is_queued_for_deletion()).size() == 1, "shaders: only the pass over every look is left")
	# A setting changed while the look is on is what comes back when the look goes.
	looks.use("test-addon/grey")
	looks.lift()
	check(not env.ssao_enabled, "shaders: lifted, the look's own values are off while Settings writes")
	env.ssao_enabled = true
	looks.settle("test-addon/grey")
	looks.use("classic")
	check(env.ssao_enabled, "shaders: a setting changed under a look comes back when the look goes")
	env.ssao_enabled = false
	looks.use("test-addon/grey")
	sh.clear()
	await get_tree().process_frame
	check(not Looks.looks.has("test-addon/grey") and looks.current == "factorio" and Looks.extras.is_empty()
		and looks.get_children().filter(func(n: Node) -> bool: return n is MeshInstance3D and not n.is_queued_for_deletion()).is_empty(),
		"shaders: switched off, the add-on's look and passes go and the Factorio look comes back")
	looks.queue_free()
	sun.queue_free()


## api.terrain (1.2): the height field (set, read between texels, its square, cleared, and only by
## the add-on that set it), and what the Terrain Elevation add-on reads of the world: tile kinds,
## cliffs, buildings (turned, without trees or units) and the chunks whose buildings changed.
func _terrain(api, host) -> void:
	var world := FakeWorld.new()
	add_child(world)
	(host.main as FakeMain).world = world
	var t = api.terrain
	check(not t.is_on() and t.area() == Rect2() and t.height_at(5, 5) == 0.0, "terrain: flat until a field is set")
	var GroundHeight = load("res://scripts/world/ground_height.gd")
	var early := MeshInstance3D.new()
	var quad := MeshInstance3D.new()
	quad.extra_cull_margin = 16384.0
	add_child(early)
	add_child(quad)
	var img := Image.create(4, 4, false, Image.FORMAT_RF)
	for y in 4:
		for x in 4:
			img.set_pixel(x, y, Color(float(x), 0, 0))
	t.set_heights(img, Vector2(-8, -8), 4.0)
	check(t.is_on() and t.area() == Rect2(-8, -8, 16, 16), "terrain: a 4 x 4 field of 4-tile texels covers 16 x 16 tiles: %s" % [t.area()])
	var late := MeshInstance3D.new()
	add_child(late)
	# The field rises to 3 tiles: that much room in culling (ground_height.gd), not more.
	check(GroundHeight.lift_range() == Vector2(0.0, 3.0) and early.extra_cull_margin == 3.0 and late.extra_cull_margin == 3.0
		and quad.extra_cull_margin == 16384.0,
		"terrain: with hills, nodes made before and after have room for their height, a bigger margin stays: %.1f %.1f" % [early.extra_cull_margin, late.extra_cull_margin])
	check(is_equal_approx(t.height_at(-6, -6), 0.0) and is_equal_approx(t.height_at(-2, 0), 1.0) and is_equal_approx(t.height_at(0, 0), 1.5),
		"terrain: heights at texel centres and between them: %s %s %s" % [t.height_at(-6, -6), t.height_at(-2, 0), t.height_at(0, 0)])
	check(t.height_at(100, 100) == 0.0, "terrain: 0 outside the field")
	var other = load("res://scripts/addons/addon_terrain.gd").new(host, {"id": "someone-else"})
	other.clear()
	check(t.is_on(), "terrain: another add-on's clear leaves this one's field")
	t.clear()
	check(not t.is_on() and t.height_at(0, 0) == 0.0, "terrain: cleared")
	check(early.extra_cull_margin == 0.0 and late.extra_cull_margin == 0.0 and quad.extra_cull_margin == 16384.0, "terrain: flat again, the margins go")
	early.queue_free()
	late.queue_free()
	quad.queue_free()
	t.set_heights(img, Vector2(-8, -8), 4.0)
	host.game_ended()
	check(not t.is_on(), "terrain: the game's end clears the field")
	host.game_started()

	check(t.chunk_kinds(Vector2i(0, 0)).is_empty() and t.buildings_in_chunk(Vector2i(0, 0)).is_empty() and t.cliffs_in_chunk(Vector2i(0, 0)).is_empty(),
		"terrain: nothing for a chunk that isn't loaded")
	world.protos.by_id = {1: FakeProto.new("assembling-machine", Vector2(3, 3)), 2: FakeProto.new("tree", Vector2(1, 1)),
		3: FakeProto.new("splitter", Vector2(2, 1)), 4: FakeProto.new("cliff", Vector2(4, 4)), 5: FakeProto.new("unit", Vector2(1, 1))}
	var cv := FakeChunk.new()
	cv.tile_ids.resize(32 * 32)
	cv.tile_ids[0] = 1
	cv.tile_ids[1] = 2
	cv.tile_ids[2] = 99  # an id the prototypes don't know: land
	var recs := [[1, Vector2(5.5, 5.5), 0, {}], [2, Vector2(9, 9), 0, {}], [3, Vector2(12, 3.5), 4, {}],
		[4, Vector2(16, 16), 0, {"co": "west-to-east"}], [5, Vector2(20, 20), 0, {}]]
	for i in recs.size():
		var r := FakeRec.new()
		r.proto_id = recs[i][0]
		r.pos = recs[i][1]
		r.dir = recs[i][2]
		r.extra = recs[i][3]
		cv.entities[i] = r
	world.chunks[Vector2i(0, 0)] = cv
	var kinds: PackedByteArray = t.chunk_kinds(Vector2i(0, 0))
	check(kinds.size() == 1024 and kinds[0] == 1 and kinds[1] == 2 and kinds[2] == 0 and kinds[3] == 0, "terrain: tile kinds (land, water, empty space): %s" % [kinds.slice(0, 4)])
	var cliffs: Array = t.cliffs_in_chunk(Vector2i(0, 0))
	check(cliffs.size() == 1 and cliffs[0].position == Vector2(16, 16) and cliffs[0].orientation == "west-to-east", "terrain: the chunk's cliffs: %s" % [cliffs])
	var builds: Array = t.buildings_in_chunk(Vector2i(0, 0))
	check(builds.size() == 2 and builds[0] == [Vector2(5.5, 5.5), Vector2(1.5, 1.5)] and builds[1] == [Vector2(12, 3.5), Vector2(0.5, 1.0)],
		"terrain: buildings with half sizes, a splitter facing east turned, no trees, cliffs or units: %s" % [builds])
	check(t.take_changed_chunks().is_empty(), "terrain: the first call starts the watch")
	world.entities_changed.emit(Vector2i(0, 0))
	world.entities_changed.emit(Vector2i(1, 0))
	world.entities_changed.emit(Vector2i(0, 0))
	var changed: Array = t.take_changed_chunks()
	changed.sort()
	check(changed == [Vector2i(0, 0), Vector2i(1, 0)] and t.take_changed_chunks().is_empty(), "terrain: changed chunks, each once, then none: %s" % [changed])
	# The next game has a world of its own (main.gd makes one per game): watched afresh, and nothing
	# from the last one.
	var world2 := FakeWorld.new()
	add_child(world2)
	(host.main as FakeMain).world = world2
	world.entities_changed.emit(Vector2i(5, 5))
	var first: Array = t.take_changed_chunks()
	check(first.is_empty(), "terrain: a new game's first call starts its watch, nothing from the last game: %s" % [first])
	world2.entities_changed.emit(Vector2i(2, 2))
	var next_game: Array = t.take_changed_chunks()
	check(next_game == [Vector2i(2, 2)], "terrain: the next game's changed chunks are heard: %s" % [next_game])
	(host.main as FakeMain).world = null
	world2.queue_free()
	world.queue_free()


func _event(code: Key, shift := false) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.shift_pressed = shift
	ev.pressed = true
	return ev


func _finish() -> void:
	AddonLoader.cache_root = "user://addons-cache"
	AddonStorage.root = "user://addons-data"
	print("FAILS: %d" % fails)
	get_tree().quit(1 if fails > 0 else 0)
