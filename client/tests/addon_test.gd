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
const Visuals := preload("res://scripts/world/visuals.gd")
const PlanetSky := preload("res://scripts/world/sky.gd")
const SunShadows := preload("res://scripts/world/sun_shadows.gd")
const LampLights := preload("res://scripts/world/lamp_lights.gd")
const WorkingGlow := preload("res://scripts/world/working_glow.gd")
const WorldMirror := preload("res://scripts/world/world.gd")
const ChunkView := preload("res://scripts/world/chunk_view.gd")
const ItemCards := preload("res://scripts/world/item_cards.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const BeltLods := preload("res://scripts/world/belt_lods.gd")
const FullDetail := preload("res://scripts/world/full_detail.gd")
const FrameBudget := preload("res://scripts/world/frame_budget.gd")
const Sfx := preload("res://scripts/fx/sfx.gd")
const SoundBank := preload("res://scripts/fx/sound_bank.gd")
const FxSettings := preload("res://scripts/fx/fx_settings.gd")
const ItemIcons := preload("res://scripts/world/item_icons.gd")
const Tones := preload("res://tests/sound_fixtures.gd")
const StepSounds := preload("res://scripts/fx/step_sounds.gd")

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


## The HUD as api.character reads it (1.7): the UI's model, the death screen, the surface shown.
class FakeDeath extends RefCounted:
	var left := -1.0
	var died_at = null


class FakeCharUi extends FakeUi:
	var model
	var death_screen := FakeDeath.new()
	var viewing_si := 0


## player_input.gd's hand as api.character.held() reads it.
class FakeHand extends Node:
	var cursor_item := ""
	var cursor_quality := "normal"


## Every signal of an add-on's api.character, heard in order: [name, args...].
class Recorder extends RefCounted:
	var got: Array = []

	func hear(part: Object, names: Array) -> void:
		var by_args := [_r0, _r1, _r2, _r3]
		for s: Dictionary in part.get_signal_list():
			var n := str(s["name"])
			var f := (by_args[(s["args"] as Array).size()] as Callable)
			if names.has(n):
				part.connect(n, f.bind(n))
			elif n.begins_with("_") and names.has(n.substr(1)):
				(part.get(n.substr(1)) as Signal).connect(f.bind(n.substr(1)))  # read through its property, as an add-on does

	func named(n: String) -> Array:
		return got.filter(func(e: Array) -> bool: return e[0] == n)

	func _r0(n: String) -> void:
		got.append([n])

	func _r1(a, n: String) -> void:
		got.append([n, a])

	func _r2(a, b, n: String) -> void:
		got.append([n, a, b])

	func _r3(a, b, c, n: String) -> void:
		got.append([n, a, b, c])


class FakeLauncher extends RefCounted:
	var save_path := "C:/somewhere/saves/My base.zip"


class FakeRide extends Node:
	var on := false
	var hub := false

	func riding() -> bool:
		return on

	func in_hub() -> bool:
		return hub


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
	var content_rev := 0


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
	_write(DISK + "/level17-addon/addon.json", JSON.stringify({"id": "level17-addon", "name": "Needs 1.7", "version": "1", "api": 1.7, "entry": "main.gd"}))
	_write(DISK + "/level17-addon/main.gd", "extends Node\n")
	_write(DISK + "/level18-addon/addon.json", JSON.stringify({"id": "level18-addon", "name": "Needs 1.8", "version": "1", "api": 1.8, "entry": "main.gd"}))
	_write(DISK + "/level18-addon/main.gd", "extends Node\n")
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
	check(str(by_id.get("level18-addon", {}).get("problem", "")).contains("needs a newer Zenith (add-on API 1.8; this Zenith has 1.7)"),
		"shadow_edge's level: 1.8 is refused with the newer-Zenith message: " + str(by_id.get("level18-addon", {}).get("problem", "")))
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
	check(by_id.has("level17-addon") and by_id["level17-addon"]["ok"] and by_id.has("level18-addon") and not by_id["level18-addon"]["ok"],
		"1.7: an add-on asking for API 1.7 loads, one asking for 1.8 is refused")
	check(by_id.has("later-addon") and not by_id["later-addon"]["ok"] and str(by_id["later-addon"]["problem"]).contains("1.9"), "one asking for 1.9 is refused: " + str(by_id.get("later-addon", {}).get("problem", "")))

	_trust(where, by_id)
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
	check(api != null and is_equal_approx(api.level, 1.7), "and its level, 1.7")
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

	await _character_api(api, node, host, fake, rig)
	await _character_lift(api, host, fake, rig)
	await _belt_step(api, host, fake, rig)
	await _char_extra(api, node, host, fake, rig)
	await _camera_modifiers(api, host, fake, rig)
	await _character_attach(api, host, fake, rig)
	await _cam_group_extra(api, host, fake, rig)
	await _api_leak(host)

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

	_terrain(api, host)
	await _sound(api, host)
	await _shaders(api)
	_sun_model()
	await _sunset_look(api)
	await _screenshot_mode(api, host, fake, hud_layer)
	_game_link(api, host)

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
	await _cinematic_shaders(fake)
	await _reload_and_errors(fake)
	await _dependencies(fake, where)
	await _fix2_checks(fake)
	await _author_checks(fake)
	_finish()


## API 1.7: api.character and api.camera.mode(). Nothing is watched until an add-on reads them; the
## state from a fed `me`; each event once; the camera's modes; switched off and a new game.
func _character_api(api, node: Node, host, fake, rig) -> void:
	const AvatarScript := preload("res://scripts/player/avatar.gd")
	const UiModel := preload("res://scripts/ui/factorio/ui_model.gd")
	const AddonCharacter := preload("res://scripts/addons/addon_character.gd")
	var watch = host.watch
	var disk: Dictionary = host.find("disk-addon")
	var other = disk["object"]
	var hears_bridge := func() -> bool: return Bridge.message_received.is_connected(watch._on_message) or Bridge.welcomed.is_connected(watch._on_welcome)

	# Nothing before use: add-ons running in a game, the camera taken and handed back above, and still
	# nothing watches.
	check(api._character == null and not watch.is_on() and not watch.is_processing() and not hears_bridge.call(),
		"1.7: add-ons running, api.character and mode_changed never read: nothing processes, nothing on the bridge")
	check(api.camera.mode() == "angled" and api.camera.player_mode() == "angled" and not watch.is_on(),
		"1.7: mode() reads without watching: %s" % api.camera.mode())

	# The game's nodes as api.character reads them: a real avatar, a real UiModel, the hand, the HUD.
	var plain = fake.avatar
	var input_before = fake.input
	var world_before = fake.world
	var me := AvatarScript.new()
	add_child(me)
	me.set_process(false)  # the test moves it
	fake.avatar = me
	var model := UiModel.new()
	var hud := FakeHud.new()
	var ui := FakeCharUi.new()
	ui.model = model
	hud.ui = ui
	add_child(hud)
	fake.hud = hud
	var hand := FakeHand.new()
	add_child(hand)
	fake.input = hand
	var world := FakeWorld.new()
	world.protos.by_id = {12: {"name": "iron-ore"}}
	add_child(world)
	fake.world = world
	me.snap_to(Vector2(10, 5))
	var feed := func(msg: Dictionary) -> void:
		if str(msg["t"]) == "me":
			me.update_from(msg)  # main.gd's handler first, as in the game
		Bridge.message_received.emit(msg)

	# The mode alone: watching each frame, not the bridge.
	var modes := Recorder.new()
	other.camera.mode_changed.connect(func(m: String, b: String) -> void: modes.got.append([m, b]))
	check(watch.is_on() and watch.is_processing() and not hears_bridge.call(),
		"1.7: mode_changed read: the watch runs, but isn't on the bridge (nobody wants the character)")

	# First touch of api.character, by the other add-on alone: a read (or set_lift) starts nothing; a
	# handler connected through it does, by the frame's end; stopped, all off again.
	var gone_part = other.character
	other.character.set_lift(0.0)
	await get_tree().process_frame
	check(not hears_bridge.call() and not watch._char_apis.has(other), "1.7: api.character read and set_lift called, no handler: the watch stays off the bridge")
	other.character.respawned.connect(func() -> void: pass)
	await get_tree().process_frame
	check(hears_bridge.call(), "1.7: a handler connected through api.character: the watch hears the bridge")
	var other_cam = other.camera
	host.stop(disk)
	check(not watch.is_on() and not watch.is_processing() and not hears_bridge.call() and not model.inventory_changed.is_connected(watch._on_inventory),
		"1.7: its only add-on switched off: the watch stops and leaves the bridge and the model")
	check(other_cam._mode_changed.get_connections().is_empty() and not other_cam._mode_wanted,
		"1.7: and the add-on's mode_changed has no handlers left")
	gone_part.respawned.connect(func() -> void: pass)
	check(not watch._char_apis.has(other) and not watch.is_on(), "1.7: a stopped add-on's kept api.character: reading a signal starts nothing")
	host.start(disk)
	other = disk["object"]
	check(gone_part is AddonCharacter and other != null and other._character == null and not watch.is_on(), "1.7: started again: a new api, unwatched")

	# The fixture add-on reads both (watch()), the other add-on records everything.
	node.watch()
	var heard := Recorder.new()
	heard.hear(other.character, AddonCharacter.SIGNALS)
	other.camera.mode_changed.connect(func(m: String, b: String) -> void: modes.got.append([m, b]))
	await get_tree().process_frame
	check(watch.is_on() and hears_bridge.call() and model.inventory_changed.is_connected(watch._on_inventory) and model.guns_changed.is_connected(watch._on_guns),
		"1.7: read by two add-ons: on the bridge and the model's inventory and guns")

	# No character yet.
	check(not api.character.exists() and api.character.state().is_empty() and api.character.weapons().is_empty() and api.character.armor() == "" and api.character.held().is_empty(),
		"1.7: before any `me`: no character, {} and empty gear")

	# State from a fed `me`.
	feed.call({"t": "me", "u": 5, "x": 2560, "y": 1280, "k": 100, "w": 1, "hp": 250, "mhp": 250, "sd": 30, "msd": 50,
		"m": 40, "mx": 2816, "my": 1280, "sh": 1, "v": 0, "vs": 0, "q": 0})
	await get_tree().process_frame
	var st: Dictionary = api.character.state()
	check(api.character.exists() and int(st.get("unit", 0)) == 5 and st.get("position") == Vector3(10, 0, 5) and st.get("walking") == true
		and int(st.get("health", 0)) == 250 and int(st.get("max_health", 0)) == 250 and int(st.get("shield", 0)) == 30 and int(st.get("max_shield", 0)) == 50,
		"1.7: state(): unit, position (tiles, y 0), walking, health and shield from a `me`: %s" % [st])
	check(st.get("mining") == true and is_equal_approx(float(st.get("mining_progress", 0.0)), 0.4) and st.get("mining_at") == Vector3(11, 0, 5)
		and st.get("repairing") == false and st.get("repairing_at") == null and st.get("firing") == true and int(st.get("vehicle", -1)) == 0
		and st.get("dead") == false and st.get("in_hub") == false and st.get("riding") == false and st.get("body_visible") == true and st.get("on_shown_surface") == true,
		"1.7: mining, its progress and place, firing, alive, on foot, shown")
	check(st.keys().size() == 26 and heard.got.is_empty() and node.hurt == Vector2i.ZERO, "1.7: 26 keys; the first `me` fires nothing: %s" % [heard.got])
	# speed: 0.75 tiles in 5 ticks is 0.15 a tick (Factorio's running speed), against the facing negative.
	feed.call({"t": "me", "u": 5, "x": 2560 + 192, "y": 1280, "k": 105, "w": 1, "hp": 250, "mhp": 250, "sd": 30, "msd": 50, "v": 0})
	me._clock.tick = 102.5 + me._clock.gap * 2.0
	var ahead: float = api.character.state()["speed"]
	me.rotation.y = PI / 2.0  # facing west, moving east
	var back: float = api.character.state()["speed"]
	check(is_equal_approx(ahead, 0.15) and is_equal_approx(back, -0.15) and (api.character.state()["forward"] as Vector3).is_equal_approx(Vector3(-1, 0, 0)),
		"1.7: speed in tiles a tick, 0.15 running, negative backwards; forward as the body faces: %.3f %.3f" % [ahead, back])
	me.rotation.y = 0.0
	feed.call({"t": "me", "u": 5, "x": 2752, "y": 1280, "k": 106, "w": 0, "hp": 250, "mhp": 250, "sd": 30, "msd": 50, "rp": 1, "rx": 2816, "ry": 1536, "v": 0})
	st = api.character.state()
	check(st["repairing"] == true and st["repairing_at"] == Vector3(11, 0, 6) and st["mining"] == false and st["mining_at"] == null and st["walking"] == false and st["firing"] == false,
		"1.7: repairing and where; mining and firing over")

	# Gear: weapons, armour, the hand.
	model.set_guns(1, [["pistol", "firearm-magazine", 10, 7, 10], ["submachine-gun", "", 0, 0, 0], ["", "", 0]])
	var w: Dictionary = api.character.weapons()
	check(int(w.get("selected", 0)) == 1 and int(w.get("vehicle", -1)) == 0 and (w.get("slots", []) as Array).size() == 3
		and w["slots"][0] == {"gun": "pistol", "ammo": "firearm-magazine", "magazines": 10, "rounds": 7, "magazine_size": 10}
		and int(w["slots"][2]["rounds"]) == -1, "1.7: weapons(): the slots as the tool bar shows them: %s" % [w])
	model.handle({"t": "slots", "l": {"armor": [["heavy-armor", 1]]}})
	hand.cursor_item = "iron-plate"
	hand.cursor_quality = "rare"
	check(api.character.armor() == "heavy-armor" and api.character.held() == {"item": "iron-plate", "quality": "rare"},
		"1.7: armor() and held(): %s %s" % [api.character.armor(), api.character.held()])
	hand.cursor_item = ""
	check(api.character.held().is_empty() and heard.named("armor_changed").is_empty() and heard.named("gun_selected").is_empty(),
		"1.7: an empty hand {}; the first armour and guns fire nothing")
	model.handle({"t": "slots", "l": {"armor": [["modular-armor", 1]]}})
	model.handle({"t": "slots", "l": {"armor": [["modular-armor", 1]]}})
	check(heard.named("armor_changed") == [["armor_changed", "modular-armor"]], "1.7: armor_changed once for new armour, not for the same again: %s" % [heard.named("armor_changed")])
	model.set_guns(1, [["pistol", "firearm-magazine", 10, 6, 10], ["submachine-gun", "", 0, 0, 0], ["", "", 0]])
	model.set_guns(2, [["pistol", "firearm-magazine", 10, 6, 10], ["submachine-gun", "", 0, 0, 0], ["", "", 0]])
	check(heard.named("gun_selected") == [["gun_selected", 2, "submachine-gun"]], "1.7: gun_selected once when the slot changes, not on ammo counts: %s" % [heard.named("gun_selected")])
	model.set_guns(1, [["vehicle-machine-gun", "firearm-magazine", 5, 10, 10]], 7)
	check(heard.named("gun_selected").size() == 2 and heard.named("gun_selected")[1] == ["gun_selected", 1, "vehicle-machine-gun"] and int(api.character.weapons()["vehicle"]) == 7,
		"1.7: and when the list becomes a vehicle's, weapons() saying whose")

	# Shots and mining: message time.
	feed.call({"t": "shot", "u": 5, "g": "submachine-gun", "a": "firearm-magazine", "x": 2560, "y": 2560})
	feed.call({"t": "shot", "u": 9, "g": "pistol", "a": "firearm-magazine", "x": 0, "y": 0})
	check(heard.named("shot_fired") == [["shot_fired", "submachine-gun", "firearm-magazine", Vector3(10, 0, 10)]], "1.7: shot_fired for the character's own round only: %s" % [heard.named("shot_fired")])
	feed.call({"t": "mnd", "u": 0, "p": 12, "x": 2560, "y": 1792, "g": 0, "l": []})
	feed.call({"t": "mnd", "u": 0, "p": 0, "gi": 1, "x": 2816, "y": 1792, "g": 1, "l": []})
	check(heard.named("mined") == [["mined", "iron-ore", Vector3(10, 0, 7), false], ["mined", "item-on-ground", Vector3(11, 0, 7), true]],
		"1.7: mined, with the prototype or item-on-ground, and gone: %s" % [heard.named("mined")])

	# Damage: summed over a frame, none for health rising.
	feed.call({"t": "me", "u": 5, "x": 2752, "y": 1280, "k": 107, "hp": 240, "mhp": 250, "sd": 30, "msd": 50, "v": 0})
	await get_tree().process_frame
	feed.call({"t": "me", "u": 5, "x": 2752, "y": 1280, "k": 108, "hp": 240, "mhp": 250, "sd": 20, "msd": 50, "v": 0})
	await get_tree().process_frame
	feed.call({"t": "me", "u": 5, "x": 2752, "y": 1280, "k": 109, "hp": 245, "mhp": 250, "sd": 20, "msd": 50, "v": 0})
	await get_tree().process_frame
	for hp in [240, 235, 230]:
		feed.call({"t": "me", "u": 5, "x": 2752, "y": 1280, "k": 500 - hp, "hp": hp, "mhp": 250, "sd": 20, "msd": 50, "v": 0})
	await get_tree().process_frame
	check(heard.named("damaged") == [["damaged", 10, 0], ["damaged", 0, 10], ["damaged", 15, 0]] and node.hurt == Vector2i(25, 10),
		"1.7: damaged (10, 0), a shield's (0, 10), none healing, three `me`s in a frame one (15, 0): %s" % [heard.named("damaged")])

	# Vehicles: 0, 7, 7, 0.
	var in_car: Dictionary = {}
	for i in 3:
		var v: int = [7, 7, 0][i]
		feed.call({"t": "me", "u": 5, "x": 2752, "y": 1280, "k": 600 + i, "hp": 230, "mhp": 250, "sd": 20, "msd": 50, "v": v, "vs": 150})
		if v == 7:
			st = api.character.state()
			in_car = api.world.character()
	check(heard.named("vehicle_entered") == [["vehicle_entered", 7]] and heard.named("vehicle_left") == [["vehicle_left", 7]],
		"1.7: vehicle_entered and vehicle_left once each")
	check(int(st["vehicle"]) == 7 and is_equal_approx(float(st["vehicle_speed"]), 0.15) and st["body_visible"] == false and is_equal_approx(float(st["speed"]), 0.0),
		"1.7: in a vehicle: its unit and speed in tiles a tick, the body not shown, speed 0: %s" % [st])
	check(in_car.keys() == ["unit", "position", "forward", "vehicle", "visible"] and int(in_car["unit"]) == 5 and int(in_car["vehicle"]) == 7
		and in_car["position"] == st["position"] and in_car["forward"] == st["forward"] and in_car["visible"] == true,
		"1.7: api.world.character() unchanged: its five keys, the same values, `visible` the node's own flag (true in a vehicle): %s" % [in_car])

	# Hub, pod, first person, another surface, the remote view.
	fake.ride.hub = true
	check(api.character.state()["in_hub"] == true and api.character.state()["body_visible"] == false and api.character.exists(), "1.7: in a hub: in_hub, not shown, still there")
	fake.ride.hub = false
	fake.ride.on = true
	check(api.character.state()["riding"] == true and api.character.state()["body_visible"] == false, "1.7: riding a pod")
	fake.ride.on = false
	me.set_first_person(true)
	check(api.character.state()["body_visible"] == false, "1.7: first person: the body not shown")
	me.set_first_person(false)
	ui.viewing_si = 3
	check(api.character.state()["on_shown_surface"] == false, "1.7: another surface shown")
	ui.viewing_si = 0
	var before_remote: Dictionary = api.character.state()
	rig.in_remote = true
	check(api.character.state() == before_remote and api.camera.mode() == "remote", "1.7: the remote view leaves the state alone; mode() says remote")
	rig.in_remote = false
	await get_tree().process_frame

	# Steps: one run loop each way gives right then left; none between, none in a vehicle.
	if me._rig == null:
		check(false, "1.7: the character's rig loads for the footfall checks")
	else:
		var anim = me._anim
		var dt := 1.0 / 60.0
		for way: float in [1.0, -1.0]:
			anim._run_phase = TAU * (0.75 if way > 0.0 else 0.25)  # a quarter loop before the right foot's touch-down
			var start: int = anim.footfalls
			var frames := 0
			heard.got.clear()
			node.steps.clear()
			var guard := 0
			while anim.footfalls < start + 2 and guard < 3000:
				anim.running = true
				anim.step(me._pose, dt, way * 0.05)
				guard += 1
				if guard % 4 == 0:
					await get_tree().process_frame
					frames += 1
			await get_tree().process_frame
			await get_tree().process_frame
			var feet: Array = heard.named("footfall").map(func(e: Array) -> String: return e[1])
			check(feet == ["right", "left"] and node.steps == feet and (heard.named("footfall")[0][2] as Vector3) == me.global_position,
				"1.7: a run loop %s: two footfalls, right then left, where the body is: %s over %d frames" % ["forwards" if way > 0.0 else "backwards", feet, frames])
		check(is_equal_approx(float(api.character.state()["stride"]), anim._run_phase / TAU), "1.7: stride is the run loop's place")
		heard.got.clear()
		me.vehicle = 7
		var start2: int = anim.footfalls
		while anim.footfalls < start2 + 2:
			anim.step(me._pose, dt, 0.05)
		await get_tree().process_frame
		me.vehicle = 0
		check(heard.named("footfall").is_empty(), "1.7: no footfall in a vehicle")
		anim.running = false
		# Flight: one took_off, one landed.
		anim.flying = true
		anim.descending = false
		anim.flight_height = 1.0
		for i in 60:
			anim.step(me._pose, 0.05, 0.0)
		await get_tree().process_frame
		var up: Dictionary = api.character.state()
		anim.flying = false
		for i in 60:
			anim.step(me._pose, 0.05, 0.0)
		await get_tree().process_frame
		await get_tree().process_frame
		check(heard.named("took_off").size() == 1 and heard.named("landed").size() == 1 and up["flying"] == true and float(up["height"]) > 0.5
			and api.character.state()["flying"] == false, "1.7: took_off and landed once each, flying and height while up: %s" % [heard.got])

	# Death and respawn.
	heard.got.clear()
	ui.death_screen.left = 5.0
	ui.death_screen.died_at = Vector2(12, 6)
	feed.call({"t": "died", "u": 5, "p": 0, "x": 3072, "y": 1536})
	feed.call({"t": "dead", "left": 300, "x": 3072, "y": 1536})
	feed.call({"t": "dead", "left": 270, "x": 3072, "y": 1536})
	st = api.character.state()
	check(heard.named("died") == [["died", Vector3(12, 0, 6)]] and not api.character.exists() and st["dead"] == true and int(st["health"]) == 0
		and st["position"] == Vector3(12, 0, 6) and st["walking"] == false, "1.7: died once for a `died` and two `dead`s; dead: no character, health 0, where it died")
	me.heard_me = false  # main.gd's _on_welcome: the respawned character is a new one
	Bridge.welcomed.emit({"t": "welcome", "u": 6})
	ui.death_screen.left = -1.0
	ui.death_screen.died_at = null
	feed.call({"t": "me", "u": 6, "x": 0, "y": 0, "k": 900, "hp": 250, "mhp": 250, "v": 0})
	await get_tree().process_frame
	check(heard.named("respawned").size() == 1 and heard.named("damaged").is_empty() and api.character.exists() and int(api.character.state()["unit"]) == 6,
		"1.7: respawned on the new character's first `me`, nothing else: %s" % [heard.got])

	# Modes.
	modes.got.clear()
	node.modes.clear()
	rig.toggle_first_person()
	await get_tree().process_frame
	await get_tree().process_frame
	check(api.camera.mode() == "first_person" and modes.got == [["first_person", "angled"]] and node.modes == modes.got, "1.7: first person, mode_changed once to each add-on: %s" % [modes.got])
	rig.in_remote = true
	await get_tree().process_frame
	check(api.camera.mode() == "remote", "1.7: the remote view over first person is remote")
	rig.in_remote = false
	rig.toggle_first_person()
	await get_tree().process_frame
	rig.toggle_factorio_view()
	await get_tree().process_frame
	await get_tree().process_frame
	var in_f6: String = api.camera.mode()
	rig.zoom(1.5)
	await get_tree().process_frame
	check(in_f6 == "factorio" and api.camera.mode() == "angled", "1.7: Factorio's view, zoomed out of it angled again: %s %s" % [in_f6, api.camera.mode()])
	var count := modes.got.size()
	rig.toggle_projection()
	await get_tree().process_frame
	rig.toggle_projection()
	await get_tree().process_frame
	check(modes.got.size() == count and api.camera.mode() == "angled", "1.7: F7 changes no mode: %s" % [modes.got.slice(count)])
	rig.cinematic(30.0, 40.0)
	await get_tree().process_frame
	check(api.camera.mode() == "ride" and modes.got.back() == ["ride", "angled"], "1.7: a ride's film is ride")
	rig.cinematic_end()
	await get_tree().process_frame
	rig.toggle_first_person()
	await get_tree().process_frame
	check(other.camera.take(), "1.7: the other add-on takes the camera")
	await get_tree().process_frame
	check(api.camera.mode() == "addon" and other.camera.mode() == "addon" and api.camera.player_mode() == "first_person" and modes.got.back() == ["addon", "first_person"]
		and node.modes.back() == ["addon", "first_person"], "1.7: taken: addon for both, player_mode() the view under it, both told")
	other.camera.release()
	await get_tree().process_frame
	check(api.camera.mode() == "first_person" and modes.got.back() == ["first_person", "addon"], "1.7: released: back to first person")
	rig.vr_view = Node3D.new()
	check(api.camera.mode() == "vr" and api.camera.player_mode() == "vr", "1.7: a headset: vr")
	rig.vr_view.free()
	rig.vr_view = null
	rig.toggle_first_person()
	await get_tree().process_frame

	# Switched off with another add-on still listening.
	var still: int = node.steps.size()
	var stopped_cam = other.camera
	var stopped_part = other._character
	host.stop(disk)
	check(stopped_cam._mode_changed.get_connections().is_empty() and stopped_part._footfall.get_connections().is_empty()
		and stopped_part._damaged.get_connections().is_empty(), "1.7: switched off: the add-on's handlers are gone")
	check(watch.is_on() and hears_bridge.call(), "1.7: the other add-on still listening keeps the watch on")
	feed.call({"t": "me", "u": 6, "x": 0, "y": 0, "k": 901, "hp": 200, "mhp": 250, "v": 0})
	await get_tree().process_frame
	check(node.hurt == Vector2i(75, 10) and node.steps.size() == still, "1.7: and still hears its events: %s" % [node.hurt])
	host.start(disk)

	# A new game: no event for its first values, handlers still there.
	node.modes.clear()
	host.game_ended()
	check(not watch.is_on() and not hears_bridge.call(), "1.7: game over: the watch off the game")
	host.game_started()
	await get_tree().process_frame
	feed.call({"t": "me", "u": 6, "x": 0, "y": 0, "k": 902, "hp": 100, "mhp": 250, "v": 3})
	await get_tree().process_frame
	await get_tree().process_frame
	check(watch.is_on() and hears_bridge.call() and node.hurt == Vector2i(75, 10) and node.modes.is_empty() and api.character.exists()
		and not api.character._footfall.get_connections().is_empty(), "1.7: a new game: watched again, its first values fire nothing, handlers kept")

	# Back as the rest of the test had it.
	fake.avatar = plain
	fake.input = input_before
	fake.world = world_before
	fake.hud = null
	for n: Node in [me, hud, hand, world]:
		n.queue_free()
	await get_tree().process_frame


## API 1.7, step 3: api.character.set_lift, the drawn-only lift. The body, lantern, old flashlight, eye,
## view's centre, bar and fallback muzzle rise; the new flashlight only moves across; the game's place,
## reach and what the crosshair can pick don't move, and nothing is sent. Caps, two add-ons summed, undone
## on stop and at the game's end, suspended in a vehicle and dead, api.world.stand_height_at, the hills.
func _character_lift(api, host, fake, rig) -> void:
	const AvatarScript := preload("res://scripts/player/avatar.gd")
	const CombatLayer := preload("res://scripts/world/combat.gd")
	const PlayerInput := preload("res://scripts/player/player_input.gd")
	const GroundHeight := preload("res://scripts/world/ground_height.gd")
	const AimPick := preload("res://scripts/world/aim_pick.gd")
	const Visuals := preload("res://scripts/world/visuals.gd")
	var disk: Dictionary = host.find("disk-addon")
	var other = disk["object"]
	var plain = fake.avatar
	var world_before = fake.world
	var target_before = rig.target
	var capture_before = Bridge.capture
	Bridge.capture = []
	var me := AvatarScript.new()
	add_child(me)
	me.set_process(false)  # the test moves it: _process(0.0) draws a frame without moving or animating on
	fake.avatar = me
	rig.target = me
	host._push_lift()  # main.gd's avatar is there at game_started; this one came after
	me.snap_to(Vector2(10, 5))
	me.update_from({"t": "me", "u": 5, "x": 2560, "y": 1280, "k": 1, "hp": 250, "mhp": 250, "v": 0})
	var combat := CombatLayer.new()
	combat.avatar = me
	var draw := func() -> void:
		me._process(0.0)
		rig._process(0.0)
	var eye := func() -> Vector3:
		if not rig.first_person:
			rig.toggle_first_person()
		rig._process(0.0)
		var at: Vector3 = rig.camera.global_position
		rig.toggle_first_person()
		return at
	var has_rig: bool = me._rig != null
	check(has_rig, "lift: the character's rig loads (the pose checks need it)")
	draw.call()
	var root0: Vector3 = me._pose.root_offset if has_rig else Vector3.ZERO
	var pos0 := me.position
	var ground0 := me.ground_position()
	var lantern0 := me._lantern.global_position
	var beam0 := me._flashlight.global_position
	var focus0: Vector3 = rig._focus_goal()
	var eye0: Vector3 = eye.call()
	var bar0: Vector3 = combat._bar_position(5)
	me.set_first_person(true)
	var muzzle0 := me.muzzle_position()
	me.set_first_person(false)
	var world0: Dictionary = api.world.character()
	var state0: Dictionary = api.character.state()

	# Body and state: one tile up.
	api.character.set_lift(1.0)
	draw.call()
	var st: Dictionary = api.character.state()
	check(is_equal_approx(me.drawn_lift(), 1.0) and (not has_rig or me._pose.root_offset.is_equal_approx(root0 + Vector3(0, 1, 0)))
		and me.position == pos0 and me.ground_position() == ground0,
		"lift: set_lift(1): drawn_lift 1, the pose's root up 1, position and ground_position unchanged to the bit: %s" % [me._pose.root_offset if has_rig else "no rig"])
	check(is_equal_approx(float(st["height"]), 1.0) and st["lift"] == Vector3(0, 1, 0) and (st["position"] as Vector3).y == 0.0 and st["position"] == state0["position"]
		and api.world.character() == world0 and api.character.lift() == Vector3(0, 1, 0) and st.keys().size() == 26,
		"lift: state() height 1, lift (0, 1, 0), position the game's; api.world.character() unchanged: %s" % [st])

	# Lights: the lantern rises; the new flashlight (Factorio's picture from above) doesn't; the old one does.
	check(me._lantern.global_position.is_equal_approx(lantern0 + Vector3(0, 1, 0)) and me._flashlight.global_position.is_equal_approx(beam0),
		"lift: the lantern 1 up, the new flashlight where it was: %s %s" % [me._lantern.global_position, me._flashlight.global_position])
	var mode_before: String = AvatarScript.flashlight_mode
	AvatarScript.flashlight_mode = "old"
	draw.call()
	var old_beam := me._flashlight.global_position
	AvatarScript.flashlight_mode = mode_before
	check(is_equal_approx(old_beam.y, AvatarScript.FLASHLIGHT_HEIGHT + 1.0), "lift: the old flashlight (--flashlight=old) 1 up: %s" % [old_beam])

	# Eye and view's centre: still without `camera` (the default), up with it.
	var eye_still: Vector3 = eye.call()
	var focus_still: Vector3 = rig._focus_goal()
	check(eye_still.is_equal_approx(eye0) and focus_still.is_equal_approx(focus0) and me.camera_lift() == Vector3.ZERO,
		"lift: set_lift(1) without camera: the first-person eye and the angled view's centre stay: %s %s" % [eye_still, focus_still])
	api.character.set_lift(1.0, Vector3.ZERO, true)
	draw.call()
	var eye1: Vector3 = eye.call()
	check(eye1.is_equal_approx(eye0 + Vector3(0, 1, 0)) and is_equal_approx(eye0.y, CameraRig.EYE_HEIGHT),
		"lift: first person's eye at 1.55 + 1: %s" % [eye1])
	var focus1: Vector3 = rig._focus_goal()
	check(focus1.is_equal_approx(focus0 + Vector3(0, 1, 0)) and is_equal_approx(focus0.y, CameraRig.BODY_MID),
		"lift: the angled view's centre at 0.85 + 1: %s" % [focus1])
	me.set_first_person(true)
	var muzzle1 := me.muzzle_position()
	me.set_first_person(false)
	var bar1: Vector3 = combat._bar_position(5)
	check(bar1.is_equal_approx(bar0 + Vector3(0, 1, 0)) and muzzle1.is_equal_approx(muzzle0 + Vector3(0, 1, 0)),
		"lift: the health bar and the fallback muzzle (body hidden) 1 up: %s %s" % [bar1, muzzle1])

	# Across: half a tile east with the body facing west. Everything that follows moves east in the world.
	me.rotation.y = PI / 2.0
	api.character.set_lift(1.0, Vector3(0.5, 0, 0), true)
	draw.call()
	var east := Vector3(0.5, 1, 0)
	var lantern_off := me._lantern.global_position - me.global_position
	var beam_off := me._flashlight.global_position - me.global_position
	var root_world: Vector3 = me.global_transform.basis * (me._pose.root_offset - root0) if has_rig else east
	check(lantern_off.is_equal_approx(Vector3(0.5, AvatarScript.LANTERN_HEIGHT + 1.0, 0)) and beam_off.is_equal_approx(Vector3(0.5, AvatarScript.BEAM_HEIGHT, 0))
		and root_world.is_equal_approx(east) and rig._focus_goal().is_equal_approx(focus0 + east),
		"lift: an offset (0.5, 0, 0) facing west: lantern, new flashlight (across only), body and view's centre half a tile east: %s %s %s" % [lantern_off, beam_off, root_world])
	me.rotation.y = 0.0

	# Caps.
	api.character.set_lift(100.0)
	var caps := [api.character.state()["lift"]]
	api.character.set_lift(1.0, Vector3(5, 0, 0))
	caps.append(api.character.state()["lift"])
	api.character.set_lift(-3.0)
	caps.append(api.character.state()["lift"])
	api.character.set_lift(NAN, Vector3(NAN, 0, INF))
	caps.append(api.character.state()["lift"])
	api.character.set_lift(1.0, Vector3(0, 7, 0))
	caps.append(api.character.lift())
	check(caps[0] == Vector3(0, 16, 0) and (caps[1] as Vector3).is_equal_approx(Vector3(1, 1, 0)) and caps[2] == Vector3.ZERO
		and caps[3] == Vector3(0, 0, 1) and caps[4] == Vector3(0, 1, 0) and me.lifted() == Vector3(0, 1, 0),
		"lift: capped at 16 up and 1 across; a negative or NAN height 0, an infinite offset 1; the offset's y ignored: %s" % [caps])

	# Two add-ons add up; each reads its own; the watch isn't started by set_lift alone.
	api.character.set_lift(0.2)
	other.character.set_lift(0.8)
	await get_tree().process_frame
	check(is_equal_approx(me.drawn_lift(), 1.0) and api.character.lift() == Vector3(0, 0.2, 0) and other.character.lift() == Vector3(0, 0.8, 0)
		and not host.watch._char_apis.has(other) and other.character._respawned.get_connections().is_empty(),
		"lift: 0.2 and 0.8 from two add-ons draw 1.0, each reads its own; set_lift alone left the watch off for that add-on")
	host.stop(disk)
	check(is_equal_approx(me.drawn_lift(), 0.2) and api.character.lift() == Vector3(0, 0.2, 0), "lift: one stopped, the other's stays: %.2f" % [me.drawn_lift()])

	# Stop puts everything back.
	api.character.clear_lift()
	draw.call()
	check(me.drawn_lift() == 0.0 and api.character.state()["lift"] == Vector3.ZERO and me._lantern.global_position.is_equal_approx(lantern0),
		"lift: clear_lift: nothing lifted")
	host.start(disk)
	other = disk["object"]
	other.character.set_lift(2.0, Vector3(0, 0, 0.5), true)
	draw.call()
	var up_lantern := me._lantern.global_position
	var up_eye: Vector3 = eye.call()
	host.stop(disk)
	draw.call()
	check(up_eye.is_equal_approx(eye0 + Vector3(0, 2, 0.5)) and host.lift_sum(true) == Vector3.ZERO and me.camera_lift() == Vector3.ZERO,
		"lift: an add-on's camera lift moved the eye 2 up; stopping it takes its camera part away: %s" % [up_eye])
	check(up_lantern.is_equal_approx(lantern0 + Vector3(0, 2, 0.5)) and me._lantern.global_position.is_equal_approx(lantern0)
		and me._flashlight.global_position.is_equal_approx(beam0) and eye.call().is_equal_approx(eye0) and rig._focus_goal().is_equal_approx(focus0)
		and combat._bar_position(5).is_equal_approx(bar0) and api.character.state() == state0 and (not has_rig or me._pose.root_offset.is_equal_approx(root0)),
		"lift: an add-on stopped: body, lights, eye, centre, bar and state() back as they were")
	host.start(disk)
	other = disk["object"]

	# Suspended in a vehicle and dead, kept for after.
	api.character.set_lift(1.0)
	me.update_from({"t": "me", "u": 5, "x": 2560, "y": 1280, "k": 2, "hp": 250, "mhp": 250, "v": 7})
	draw.call()
	var in_car := [me.drawn_lift(), me._lantern.global_position, me.lifted()]
	me.update_from({"t": "me", "u": 5, "x": 2560, "y": 1280, "k": 3, "hp": 0, "mhp": 250, "v": 0})
	draw.call()
	var dead := [me.drawn_lift(), me._lantern.global_position, me.lifted()]
	me.update_from({"t": "me", "u": 5, "x": 2560, "y": 1280, "k": 4, "hp": 250, "mhp": 250, "v": 0})
	draw.call()
	check(in_car[0] == 0.0 and (in_car[1] as Vector3).is_equal_approx(lantern0) and in_car[2] == Vector3.ZERO and dead[0] == 0.0 and dead[2] == Vector3.ZERO
		and (dead[1] as Vector3).is_equal_approx(lantern0) and is_equal_approx(me.drawn_lift(), 1.0) and api.character.lift() == Vector3(0, 1, 0),
		"lift: not drawn in a vehicle or dead; drawn again on foot: %s %s" % [in_car, dead])

	# Reach and aim: from the game's place; a raised eye picks less far across the ground, never further.
	var input := PlayerInput.new()
	input.avatar = me
	var spots := [Vector2(19, 5), Vector2(21, 5), Vector2(10, 16.5)]
	var reach0 := spots.map(func(p: Vector2) -> Array: return [input._in_reach(p, Vector2i.ONE), input._bridge_reach(p)])
	api.character.set_lift(8.0)
	draw.call()
	var reach8 := spots.map(func(p: Vector2) -> Array: return [input._in_reach(p, Vector2i.ONE), input._bridge_reach(p)])
	check(reach0 == reach8 and reach0[0] == [true, true] and reach0[1][0] == false, "lift: reach answers the same lifted 8: %s" % [reach8])
	var aim_world := WorldMirror.new()
	aim_world.pick_build_usec = 1 << 40
	aim_world.protos.add_entities([[1, "lift-test-chest", "container", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[2, "lift-test-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[3, "lift-test-splitter", "splitter", -0.9, -0.5, 0.9, 0.5, 200, 180, 0, 2, 1],
		[4, "lift-test-pipe", "pipe", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1]])
	aim_world.chunks[Vector2i.ZERO] = ChunkView.new()
	input.world = aim_world
	input.rig = rig
	input.fp_pick_models = true
	me.snap_to(Vector2(-40.5, 16.5))
	rig.toggle_first_person()
	var picks := {}
	for d: float in [50.0, 64.0]:
		aim_world._add([700, 1, int((-40.5 + d) * 256), int(16.5 * 256), 0])
		for h: float in [0.0, 8.0]:
			api.character.set_lift(h, Vector3.ZERO, true)
			draw.call()
			var from: Vector3 = rig.camera.global_position
			var to := Vector3(-40.5 + d, 0.4, 16.5)
			rig._look_yaw = -90.0
			rig._look_pitch = rad_to_deg(atan2(from.y - to.y, to.x - from.x))
			rig._process(0.0)
			input._aim_from(rig.aim_position(), null)
			picks["%d@%d" % [d, h]] = not input._aim.is_empty()
		aim_world._remove(700)
	rig.toggle_first_person()
	check(picks == {"50@0": true, "50@8": true, "64@0": true, "64@8": false},
		"lift: the crosshair picks a chest 50 tiles off lifted or not, one 64 off only from the ground's eye (AIM_RANGE from the eye): %s" % [picks])
	check((Bridge.capture as Array).filter(func(t: String) -> bool: return not t.contains("\"hello\"")).is_empty(), "lift: nothing sent to the game: %s" % [Bridge.capture])

	# api.world.stand_height_at: the walk-on types' tops, 0 elsewhere.
	fake.world = aim_world
	aim_world._add([801, 2, 5 * 256 + 128, 5 * 256 + 128, 0])  # a belt
	aim_world._add([802, 3, 8 * 256 + 128, 6 * 256, 4])  # a splitter turned east: x 8 to 9, z 5 to 7
	aim_world._add([803, 1, 12 * 256 + 128, 5 * 256 + 128, 0])  # a chest
	aim_world._add([804, 4, 14 * 256 + 128, 5 * 256 + 128, 0])  # a pipe
	var belt_top := AimPick.height_of(aim_world, aim_world.entities[801])
	var split_top := AimPick.height_of(aim_world, aim_world.entities[802])
	var heights := [api.world.stand_height_at(Vector2(2.5, 2.5)), api.world.stand_height_at(Vector2(5.5, 5.5)), api.world.stand_height_at(Vector2(8.7, 5.3)),
		api.world.stand_height_at(Vector2(8.3, 6.7)), api.world.stand_height_at(Vector2(12.5, 5.5)), api.world.stand_height_at(Vector2(14.5, 5.5))]
	check(heights[0] == 0.0 and belt_top > 0.0 and is_equal_approx(heights[1], belt_top) and is_equal_approx(heights[2], split_top) and is_equal_approx(heights[3], split_top)
		and heights[4] == 0.0 and heights[5] == 0.0 and is_equal_approx(belt_top, Visuals.height_for(aim_world.protos.entity(2))),
		"stand_height_at: 0 on bare ground, a belt's top (the placeholder's before a model), a splitter's across its turned box, 0 on a chest and a pipe: %s" % [heights])
	fake.world = world_before
	check(api.world.stand_height_at(Vector2(5.5, 5.5)) == 0.0, "stand_height_at: 0 without the world's index")

	# Hills: the lights and eye over the hill, at the offset's place.
	var img := Image.create(4, 4, false, Image.FORMAT_RF)
	img.fill(Color(3, 0, 0))
	api.terrain.set_heights(img, Vector2(-8, -8), 4.0)
	me.snap_to(Vector2(0, 0))
	api.character.set_lift(1.0, Vector3.ZERO, true)
	draw.call()
	var hill := [me._lantern.global_position.y, eye.call().y]
	for y in 4:
		for x in 4:
			img.set_pixel(x, y, Color(float(x), 0, 0))
	api.terrain.set_heights(img, Vector2(-8, -8), 4.0)
	api.character.set_lift(1.0, Vector3(1, 0, 0), true)
	draw.call()
	var slope := [me._lantern.global_position, GroundHeight.at(1, 0), GroundHeight.at(0, 0)]
	api.terrain.clear()
	check(is_equal_approx(hill[0], AvatarScript.LANTERN_HEIGHT + 3.0 + 1.0) and is_equal_approx(hill[1], 3.0 + CameraRig.EYE_HEIGHT + 1.0)
		and is_equal_approx((slope[0] as Vector3).y, AvatarScript.LANTERN_HEIGHT + float(slope[1]) + 1.0) and float(slope[1]) != float(slope[2]),
		"lift: on a 3-tile hill the lantern at 2.5 + 3 + 1, the eye at 3 + 1.55 + 1; on a slope, the hill at the offset's place: %s %s" % [hill, slope])

	# The game's end drops every lift; the next game's avatar starts on the ground.
	api.character.set_lift(1.0)
	other.character.set_lift(1.0)
	host.game_ended()
	var after_end := [me.lifted(), api.character.lift(), other.character.lift()]
	host.game_started()
	await get_tree().process_frame
	check(after_end == [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO] and me.lifted() == Vector3.ZERO and host.lift_sum() == Vector3.ZERO,
		"lift: game over drops every lift, a new game starts on the ground: %s" % [after_end])

	# Back as the rest of the test had it.
	Bridge.capture = capture_before
	fake.avatar = plain
	rig.target = target_before
	# None was in the tree: their own parts made in their declarations (PlayerInput's tools) go too.
	var loose: Array = [combat._back, combat._fill]
	for cv in aim_world.chunks.values():
		if cv is Node:
			loose.append(cv)
	var keep := [me, rig, input, aim_world]
	var owners: Array = [input, aim_world]
	var i := 0
	while i < owners.size():  # their parts' own parts too
		for prop: Dictionary in (owners[i] as Node).get_property_list():
			var v = (owners[i] as Node).get(prop["name"])
			if v is Node and (v as Node).get_parent() == null and not loose.has(v) and not keep.has(v):
				loose.append(v)
				owners.append(v)
		i += 1
	loose.append_array([combat, input, aim_world])
	for n: Node in loose:
		n.free()
	me.queue_free()
	await get_tree().process_frame


## (1.7, step 6 pieces 3 and 4) api.character's attachments at the promised bones and points, the `view`
## anchor, frame() and rig(), the muzzle and tools, and the pose layer with its joint ranges: drawn only
## (nothing sent, `position` unmoved), nothing made or run before an add-on uses them.
func _character_attach(api, host, fake, rig) -> void:
	const AvatarScript := preload("res://scripts/player/avatar.gd")
	const CharacterPoints := preload("res://scripts/player/character_points.gd")
	var disk: Dictionary = host.find("disk-addon")
	var plain = fake.avatar
	var target_before = rig.target
	var capture_before = Bridge.capture
	Bridge.capture = []
	var me := AvatarScript.new()
	add_child(me)
	me.set_process(false)
	fake.avatar = me
	rig.target = me
	host._push_character()
	me.snap_to(Vector2(10, 5))
	me.update_from({"t": "me", "u": 5, "x": 2560, "y": 1280, "k": 1, "hp": 250, "mhp": 250, "v": 0})
	var draw := func() -> void:
		me._process(0.0)
		rig._process(0.0)
	draw.call()
	var has_rig: bool = me._rig != null
	check(has_rig, "attach: the character's rig loads")
	if not has_rig:
		fake.avatar = plain
		rig.target = target_before
		me.queue_free()
		return
	var pos0 := me.position

	# Nothing before use.
	check(me._attached.is_empty() and me._holder == null and me._anim.layer.is_empty() and me._addon_muzzle.is_empty()
		and not me.tools_hidden and rig._view_anchor == null and host._attached.is_empty() and host._poses.is_empty(),
		"attach: nothing made before an add-on uses it (no holder, no layer, no view anchor)")

	# Attach on right_hand: the forearm's tail, the gun's frame.
	var gun := Node3D.new()
	var part := MeshInstance3D.new()
	part.mesh = BoxMesh.new()
	gun.add_child(part)
	var stray := Node3D.new()
	check(not api.character.attach(stray, "left_ear") and not api.character.attach(null, "head"), "attach: an unknown name or no node gives false")
	stray.free()
	check(api.character.attach(gun, "right_hand"), "attach: right_hand takes a node")
	draw.call()
	var tail: Vector3 = me._pose.tail_of("forearm_r")
	var want: Transform3D = me.global_transform * me._pose.frame("forearm_r", Transform3D(Basis(Vector3.RIGHT, -PI / 2.0), tail))
	check(gun.global_transform.is_equal_approx(want) and (api.character.frame("right_hand") as Transform3D).is_equal_approx(want),
		"attach: right_hand at the forearm's tail in the gun's frame, frame() the same: %s %s" % [gun.global_position, want.origin])
	check(gun.get_parent() == me._holder and part.layers == AvatarScript.SELF_LAYER, "attach: on the avatar's holder, on SELF_LAYER (the lantern's shadows don't see it)")
	var at0 := gun.global_position
	api.character.set_lift(1.0)
	draw.call()
	check(gun.global_position.is_equal_approx(at0 + Vector3(0, 1, 0)), "attach: rides a lift of 1: %s" % [gun.global_position - at0])
	api.character.clear_lift()
	var img := Image.create(4, 4, false, Image.FORMAT_RF)
	img.fill(Color(3, 0, 0))
	api.terrain.set_heights(img, Vector2(-8, -8), 4.0)
	me.snap_to(Vector2(0, 0))
	draw.call()
	var on_hill := gun.global_position.y
	api.terrain.clear()
	draw.call()
	check(is_equal_approx(on_hill, gun.global_position.y + 3.0), "attach: on a 3-tile hill 3 up, as the body's shader draws it: %.3f %.3f" % [on_hill, gun.global_position.y])
	me.snap_to(Vector2(10, 5))
	draw.call()
	me.vehicle = 7
	me._update_body()
	var in_car := gun.is_visible_in_tree()
	me.vehicle = 0
	me._update_body()
	me.set_first_person(true)
	var in_fp := gun.is_visible_in_tree()
	me.set_first_person(false)
	check(not in_car and not in_fp and gun.is_visible_in_tree(), "attach: hidden in a vehicle and in first person, shown again after")
	me.set_armor("mech-armor")
	draw.call()
	var mech_tail: Vector3 = me.global_transform * me._pose.point("forearm_r", me._pose.tail_of("forearm_r"))
	var mech_info: Dictionary = api.character.rig()
	var mech_top: Transform3D = api.character.frame("head_top")
	check(gun.get_parent() == me._holder and gun.global_position.is_equal_approx(mech_tail) and bool(mech_info["mech"])
		and absf(mech_top.origin.y - me.global_position.y - 2.76) < 0.06,
		"attach: through a change to mech armour, at the mech's forearm's tail; rig().mech; head_top %.2f up" % [mech_top.origin.y - me.global_position.y])
	me.set_armor("")
	draw.call()

	# frame() and rig().
	var info: Dictionary = api.character.rig()
	var top: Transform3D = api.character.frame("head_top")
	var answered := 0
	for n in CharacterPoints.names():
		if api.character.frame(n) is Transform3D:
			answered += 1
	check(not bool(info["mech"]) and (info["bones"] as Array).size() == 11 and (info["points"] as Array).size() == 12
		and absf(float(info["height"]) - 1.72) < 0.05 and absf(top.origin.y - me.global_position.y - 1.72) < 0.06
		and answered == 23 and api.character.frame("nose") == null,
		"frame/rig: 11 bones, 12 points, all 23 answer, head_top %.2f up (1.72), height %.2f; an unknown name null" % [top.origin.y - me.global_position.y, float(info["height"])])

	# The points sit outside the body: a backpack behind the back, glasses in front of the eyes.
	var outside := _points_outside()
	check(outside.is_empty(), "points: back, chest and eyes outside the body's surface in every look: %s" % [outside])

	# view: on the camera, shown only in first person.
	var vm := Node3D.new()
	check(api.character.attach(vm, "view", Transform3D(Basis.IDENTITY, Vector3(0.2, -0.2, -0.4))), "view: attach takes a node")
	draw.call()
	var angled_shown := vm.is_visible_in_tree()
	rig.toggle_first_person()
	draw.call()
	var fp_shown := vm.is_visible_in_tree()
	var fp_at := vm.global_position
	var cam_at: Vector3 = rig.camera.global_transform * Vector3(0.2, -0.2, -0.4)
	var view_frame = api.character.frame("view")
	var cam_frame: Transform3D = rig.camera.global_transform
	rig.toggle_first_person()
	draw.call()
	check(vm.get_parent() == rig._view_anchor and rig._view_anchor.get_parent() == rig.camera and not angled_shown and fp_shown
		and fp_at.is_equal_approx(cam_at) and view_frame is Transform3D and (view_frame as Transform3D).is_equal_approx(cam_frame),
		"view: a child of the camera's anchor, shown only in first person, at the offset from the eye: %s %s %s" % [angled_shown, fp_shown, fp_at])

	# Across games: kept out of the freed nodes and put on the next game's avatar.
	host.game_ended()
	var kept := is_instance_valid(gun) and gun.get_parent() == null and is_instance_valid(vm) and vm.get_parent() == null
	host.game_started()
	await get_tree().process_frame
	check(kept and gun.get_parent() == me._holder and vm.get_parent() == rig._view_anchor, "attach: kept through the game's end, put on the next game's avatar")

	# detach hands it back, unfreed; stopping an add-on frees its nodes.
	api.character.detach(vm)
	check(is_instance_valid(vm) and vm.get_parent() == null, "detach: out of the tree, not freed")
	vm.free()
	var theirs := Node3D.new()
	var other = disk["object"]
	check(other.character.attach(theirs, "back"), "attach: a second add-on's backpack")
	host.stop(disk)
	await get_tree().process_frame
	check(not is_instance_valid(theirs) and is_instance_valid(gun), "attach: stopping an add-on frees its nodes, not another's")
	host.start(disk)
	other = disk["object"]

	# Muzzle and tools.
	me._anim._w["aim"] = 1.0
	me.firing = true
	draw.call()
	var muzzle0 := me.muzzle_position()
	var gun_shown: bool = me._gun.visible
	api.character.hide_tools(true)
	draw.call()
	var gun_hidden := not me._gun.visible
	api.character.hide_tools(false)
	draw.call()
	check(gun_shown and gun_hidden and me._gun.visible, "tools: hide_tools(true) hides Zenith's gun while aiming, false shows it")
	api.character.set_muzzle(gun, Vector3(0, 0, -0.5))
	var addon_muzzle := me.muzzle_position()
	api.character.clear_muzzle()
	check(addon_muzzle.is_equal_approx(gun.global_transform * Vector3(0, 0, -0.5)) and me.muzzle_position().is_equal_approx(muzzle0),
		"muzzle: set_muzzle moves muzzle_position() to the node's point, clear_muzzle() puts Zenith's back")
	me._anim._w["aim"] = 0.0
	me.firing = false
	draw.call()

	# The pose layer.
	var idx: Dictionary = me._pose.index
	var head: int = idx["head"]
	var skins0: Array = me._pose.skins.duplicate()
	var turns0: PackedVector3Array = me._pose.turns.duplicate()
	api.character.set_pose({"head": Vector3(0.3, 0, 0), "tail": Vector3(1, 0, 0), "spine": "not a turn"})
	draw.call()
	var others_same := true
	for i in me._pose.names.size():
		if i != head and not (me._pose.skins[i] as Transform3D).is_equal_approx(skins0[i]):
			others_same = false
	check(me._pose.turns[head].is_equal_approx(turns0[head] + Vector3(0.3, 0, 0)) and others_same
		and not (me._pose.skins[head] as Transform3D).is_equal_approx(skins0[head]) and api.character.pose().keys() == ["head"],
		"pose: 0.3 added to head turns the head's skin by it and no other bone's; unknown keys ignored")
	api.character.clear_pose()
	draw.call()
	check(me._pose.turns == turns0 and me._anim.layer.is_empty(), "pose: clear_pose() gives Zenith's own pose back")
	me._anim._w["run"] = 1.0
	me._anim._run_phase = 1.0
	draw.call()
	var ua: int = idx["upper_arm_r"]
	var running_turn: Vector3 = me._pose.turns[ua]
	api.character.set_pose({"right_upper_arm": Vector3(1.2, 0, 0)}, {"replace": ["right_upper_arm"]})
	draw.call()
	var replaced: Vector3 = me._pose.turns[ua]
	api.character.set_pose({"right_upper_arm": Vector3(1.2, 0, 0)}, {"replace": true, "weight": 0.5})
	draw.call()
	var half: Vector3 = me._pose.turns[ua]
	check(running_turn != Vector3.ZERO and replaced.is_equal_approx(Vector3(1.2, 0, 0)) and half.is_equal_approx(running_turn.lerp(Vector3(1.2, 0, 0), 0.5)),
		"pose: replace at weight 1 gives the add-on's turn while running, 0.5 half way: %s %s %s" % [running_turn, replaced, half])
	me._anim._w["run"] = 0.0
	api.character.set_pose({"right_lower_arm": Vector3(10, NAN, -10)})
	draw.call()
	var fa: Vector3 = me._pose.turns[idx["forearm_r"]]
	var r: Array = me._anim.JOINTS["forearm_r"]
	check(fa.is_equal_approx(Vector3((r[1] as Vector3).x, turns0[idx["forearm_r"]].y, (r[0] as Vector3).z)),
		"pose: a turn of (10, nan, -10) on right_lower_arm held to the joint's range, not-a-number as 0: %s" % [fa])
	me.health = 0
	me._anim._fall = 1.0
	draw.call()
	var dead_with: PackedVector3Array = me._pose.turns.duplicate()
	api.character.clear_pose()
	draw.call()
	var dead_without: PackedVector3Array = me._pose.turns.duplicate()
	me._anim._fall = 0.0
	me.health = 250
	draw.call()
	check(dead_with == dead_without, "pose: dead (the fall at its end), the layer has no effect")
	# Two add-ons, in start order: the later started one's replace is laid over the earlier's.
	var api_first: bool = int(host.find(api.id).get("start_n", 0)) < int(disk.get("start_n", 0))
	var first_api = api if api_first else other
	var second_api = other if api_first else api
	first_api.character.set_pose({"head": Vector3(0.2, 0, 0)}, {"replace": true})
	second_api.character.set_pose({"head": Vector3(0.4, 0, 0)}, {"replace": true})
	draw.call()
	var both: Vector3 = me._pose.turns[head]
	second_api.character.set_pose({"head": Vector3(0.1, 0, 0)})
	draw.call()
	var added: Vector3 = me._pose.turns[head]
	check(both.is_equal_approx(Vector3(0.4, 0, 0)) and added.is_equal_approx(Vector3(0.3, 0, 0)),
		"pose: two add-ons in start order: the later's replace wins, an added turn adds to the earlier's: %s %s" % [both, added])
	host.stop(disk)
	draw.call()
	var after_stop: Vector3 = me._pose.turns[head]
	check(after_stop.is_equal_approx(Vector3(0.2, 0, 0) if api_first else turns0[head]), "pose: a stopped add-on's layer goes, the other's stays: %s" % [after_stop])
	host.start(disk)
	api.character.clear_pose()
	draw.call()
	check(me._pose.turns == turns0, "pose: everything cleared, Zenith's own pose")

	# Zenith's own animations inside the joint table (both looks, every --anim-pose state, the widest aim twist).
	var outside_joints := _zenith_in_joints()
	check(outside_joints.is_empty(), "pose: Zenith's own animations stay inside the joint table: %s" % [outside_joints])

	# Bounds: drawn only.
	api.character.detach(gun)
	gun.free()
	check(me.position == pos0, "attach/pose: avatar.position unchanged to the bit")
	check((Bridge.capture as Array).filter(func(t: String) -> bool: return not t.contains("\"hello\"")).is_empty(), "attach/pose: nothing sent to the game: %s" % [Bridge.capture])
	Bridge.capture = capture_before
	fake.avatar = plain
	rig.target = target_before
	host._push_character()
	me.queue_free()
	await get_tree().process_frame


## Every pose of Zenith's own (each --anim-pose state, plain and mech, and the widest aim twist), stepped
## 3 s, against character_anim.gd JOINTS; the bones and axes outside it.
func _zenith_in_joints() -> Array:
	const AvatarScript := preload("res://scripts/player/avatar.gd")
	var out: Array = []
	for armor in ["", "mech-armor"]:
		for st in ["", "walk", "run", "exo", "back", "stop", "mine", "aim", "ready", "runaim", "runready", "hover", "fly", "flyloop", "twist"]:
			var a := AvatarScript.new()
			add_child(a)
			a.set_process(false)
			a.set_armor(armor)
			a._demo = "runaim" if st == "twist" else st
			for f in 180:
				if st == "twist":
					a._anim.aim_twist = 1.25 * (1.0 if f % 120 < 60 else -1.0)
				a._animate(1.0 / 60.0)
				if a._anim._fall > 0.0:
					continue
				for i in a._pose.names.size():
					var n: String = a._pose.names[i]
					var r: Array = a._anim.JOINTS[n]
					var t: Vector3 = a._pose.turns[i]
					if t != t.clamp(r[0], r[1]) and out.size() < 8:
						out.append("%s %s %s %s" % [armor, st, n, t])
			a.free()
	return out


## The named points that sit inside a look's surface (back behind, chest and eyes in front of every
## vertex near the centre line at that height), at rest.
func _points_outside() -> Array:
	const ModelLibrary := preload("res://scripts/world/model_library.gd")
	const CharacterPose := preload("res://scripts/player/character_pose.gd")
	const CharacterPoints := preload("res://scripts/player/character_points.gd")
	var bad: Array = []
	for look in ["character", "character-armor-2", "character-armor-3", "character-mech-armor"]:
		var mesh = ModelLibrary.mesh_for(look)
		var pose := CharacterPose.new()
		if not (mesh is ArrayMesh and pose.load_rig(look)):
			bad.append(look + ": no model")
			continue
		var verts := PackedVector3Array()
		for s in (mesh as ArrayMesh).get_surface_count():
			verts.append_array(ModelLibrary.ModelLods.arrays_of(mesh, s)[Mesh.ARRAY_VERTEX])
		for name in ["back", "chest", "eyes"]:
			var p: Vector3 = (CharacterPoints.rest(pose, look, name)[1] as Transform3D).origin
			var front := INF
			var behind := -INF
			for v in verts:
				if absf(v.x - p.x) < 0.1 and absf(v.y - p.y) < 0.05:
					front = minf(front, v.z)
					behind = maxf(behind, v.z)
			if (name == "back" and p.z < behind) or (name != "back" and p.z > front):
				bad.append("%s %s at z %.3f, the surface %.3f" % [look, name, p.z, behind if name == "back" else front])
	return bad


## The owner's belt step-up (core, drawn only: "doesn't move camera or actual player position"): on a
## belt the body eases up onto its top and down again off it; the game's place, the first-person eye and
## the angled view's centre stay; state()'s height and lift include it; an add-on's lift adds to it;
## Settings > Graphics > Step onto belts off and --belt-step=off give no rise; api.world.stand_height_at
## is the core's answer; the stand height is looked up only when the drawn place moves.
func _belt_step(api, host, fake, rig) -> void:
	const AvatarScript := preload("res://scripts/player/avatar.gd")
	const StandHeight := preload("res://scripts/world/stand_height.gd")
	const AimPick := preload("res://scripts/world/aim_pick.gd")
	var plain = fake.avatar
	var world_before = fake.world
	var target_before = rig.target
	var me := AvatarScript.new()
	add_child(me)
	me.set_process(false)  # stepped by hand: _process(dt) is one frame
	fake.avatar = me
	rig.target = me
	host._push_lift()
	var w := WorldMirror.new()
	w.pick_build_usec = 1 << 40
	w.protos.add_entities([[1, "step-test-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[2, "step-test-chest", "container", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[3, "step-test-pipe-to-ground", "pipe-to-ground", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[4, "step-test-heat-pipe", "heat-pipe", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1]])
	w.chunks[Vector2i.ZERO] = ChunkView.new()
	w._add([901, 1, 5 * 256 + 128, 5 * 256 + 128, 0])  # a belt on (5.5, 5.5)
	w._add([902, 2, 8 * 256 + 128, 5 * 256 + 128, 0])  # a chest on (8.5, 5.5)
	w._add([903, 3, 11 * 256 + 128, 5 * 256 + 128, 0])  # a pipe-to-ground on (11.5, 5.5)
	w._add([904, 4, 14 * 256 + 128, 5 * 256 + 128, 0])  # a heat pipe on (14.5, 5.5)
	me.world = w
	fake.world = w
	var top := AimPick.height_of(w, w.entities[901])
	me.update_from({"t": "me", "u": 5, "x": 640, "y": 1408, "k": 1, "hp": 250, "mhp": 250, "v": 0})
	me.snap_to(Vector2(2.5, 5.5))
	const DT := 1.0 / 60.0
	var frames := func(n: int) -> void:
		for i in n:
			me._process(DT)
			rig._process(DT)
	var eye := func() -> Vector3:
		if not rig.first_person:
			rig.toggle_first_person()
		rig._process(0.0)
		var at: Vector3 = rig.camera.global_position
		rig.toggle_first_person()
		return at
	var has_rig: bool = me._rig != null
	frames.call(2)
	var lantern0 := me._lantern.position
	var eye_ground: Vector3 = eye.call()
	var focus_ground: Vector3 = rig._focus_goal()
	check(AvatarScript.belt_step() and me.stand_lift() == 0.0 and top > 0.0, "belt step: on by default, nothing under bare ground; the belt's top %.3f" % top)
	check(api.world.stand_height_at(Vector2(5.5, 5.5)) == StandHeight.at(w, Vector2(5.5, 5.5)) and is_equal_approx(StandHeight.at(w, Vector2(5.5, 5.5)), top)
		and StandHeight.at(w, Vector2(8.5, 5.5)) == 0.0 and top <= AvatarScript.STAND_MAX,
		"belt step: api.world.stand_height_at gives the belt's top, 0 on a chest; a belt's under the core's cap %.2f" % AvatarScript.STAND_MAX)
	var pipe_top := AimPick.height_of(w, w.entities[903])
	check(pipe_top > 0.0 and is_equal_approx(api.world.stand_height_at(Vector2(11.5, 5.5)), pipe_top) and api.world.stand_height_at(Vector2(14.5, 5.5)) > 0.0
		and StandHeight.at(w, Vector2(11.5, 5.5), StandHeight.BELTS) == 0.0 and StandHeight.at(w, Vector2(14.5, 5.5), StandHeight.BELTS) == 0.0,
		"belt step: stand_height_at keeps the whole answer for add-ons (a pipe-to-ground's top %.3f, a heat pipe's); the belt family alone has neither" % pipe_top)
	var box0: AABB = me._rig.custom_aabb if has_rig else AABB()

	# Onto the belt: eased up, not popped.
	me.snap_to(Vector2(5.5, 5.5))
	frames.call(1)
	var first := me.stand_lift()
	var up_share := first / top
	frames.call(5)
	var at_tenth := me.stand_lift()
	frames.call(30)
	var pos_on := me.position
	var eye_on: Vector3 = eye.call()
	var focus_on: Vector3 = rig._focus_goal()
	var st: Dictionary = api.character.state()
	check(first > 0.0 and first < top * 0.6 and at_tenth > top * 0.9 and is_equal_approx(me.stand_lift(), top),
		"belt step: eased onto the belt's top, part way after a frame, most of the way in 0.1 s: %.3f %.3f %.3f of %.3f" % [first, at_tenth, me.stand_lift(), top])
	check(is_equal_approx(me.drawn_lift(), top) and is_equal_approx(me.lifted().y, top) and (not has_rig or me._anim.extra_offset.is_equal_approx(Vector3(0, top, 0)))
		and is_equal_approx(me._lantern.position.y - lantern0.y, top),
		"belt step: the body (the pose's root offset) and the lantern drawn on the belt: %s" % [me._anim.extra_offset])
	check(pos_on == Vector3(5.5, 0, 5.5) and me.ground_position() == Vector2(5.5, 5.5) and me.camera_lift() == Vector3.ZERO,
		"belt step: the game's place untouched: %s" % [pos_on])
	check(is_equal_approx(eye_on.y, eye_ground.y) and is_equal_approx(focus_on.y, focus_ground.y) and is_equal_approx(eye_on.y, CameraRig.EYE_HEIGHT)
		and is_equal_approx(focus_on.y, CameraRig.BODY_MID),
		"belt step: the first-person eye and the angled view's centre don't rise: %s %s" % [eye_on, focus_on])
	check(is_equal_approx(float(st["height"]), top) and (st["lift"] as Vector3).is_equal_approx(Vector3(0, top, 0)),
		"belt step: state()'s height and lift include it: %s %s" % [st["height"], st["lift"]])

	# An add-on's lift adds to it; without camera the eye still stays.
	api.character.set_lift(1.0)
	frames.call(1)
	check(is_equal_approx(me.drawn_lift(), top + 1.0) and is_equal_approx(eye.call().y, eye_ground.y) and is_equal_approx(rig._focus_goal().y, focus_ground.y)
		and (api.character.state()["lift"] as Vector3).is_equal_approx(Vector3(0, top + 1.0, 0)),
		"belt step: an add-on's lift adds to it; neither moves the camera: %.3f" % me.drawn_lift())
	api.character.set_lift(1.0, Vector3.ZERO, true)
	frames.call(1)
	check(is_equal_approx(eye.call().y, eye_ground.y + 1.0) and is_equal_approx(rig._focus_goal().y, focus_ground.y + 1.0),
		"belt step: an add-on's camera lift moves the eye and centre by its own 1, not the belt's step: %s" % [eye.call()])
	api.character.clear_lift()

	# Cost: standing still, no look-ups; a move, one.
	var looks0: int = me.stand_lookups
	frames.call(20)
	var still_looks: int = me.stand_lookups - looks0
	me.snap_to(Vector2(5.6, 5.5))
	frames.call(20)
	check(still_looks == 0 and me.stand_lookups - looks0 == 1, "belt step: no look-up in 20 frames standing still, one for a move: %d, %d" % [still_looks, me.stand_lookups - looks0])

	# Off it: eased down, a touch slower than up.
	me.snap_to(Vector2(2.5, 5.5))
	frames.call(1)
	var down_share := 1.0 - me.stand_lift() / top
	frames.call(30)
	check(down_share > 0.0 and down_share < up_share and me.stand_lift() == 0.0 and me.drawn_lift() == 0.0,
		"belt step: off the belt it eases back to 0, a touch slower than up (%.2f of the way after a frame, up %.2f)" % [down_share, up_share])
	me.snap_to(Vector2(8.5, 5.5))
	frames.call(30)
	check(me.stand_lift() == 0.0, "belt step: a chest isn't stood on")
	me.snap_to(Vector2(11.5, 5.5))
	frames.call(30)
	var on_pipe := me.stand_lift()
	me.snap_to(Vector2(14.5, 5.5))
	frames.call(30)
	check(on_pipe == 0.0 and me.stand_lift() == 0.0, "belt step: pipes-to-ground and heat pipes are walked past at ground level by the core: %.3f %.3f" % [on_pipe, me.stand_lift()])

	# A tall walk-on model: the core's step-up stops at STAND_MAX.
	w.protos.add_entities([[5, "step-test-tall-loader", "loader", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1]])
	w._add([905, 5, 17 * 256 + 128, 5 * 256 + 128, 0])
	var tall_top := AimPick.height_of(w, w.entities[905])
	me.snap_to(Vector2(17.5, 5.5))
	frames.call(30)
	check(is_equal_approx(me.stand_lift(), minf(tall_top, AvatarScript.STAND_MAX)) and me.stand_lift() <= AvatarScript.STAND_MAX,
		"belt step: a loader stood on, no higher than STAND_MAX: %.3f (its top %.3f)" % [me.stand_lift(), tall_top])

	# The culling box: the old size on the ground, grown while a lift or the step-up is set, back after.
	if has_rig:
		var on_step: AABB = me._rig.custom_aabb
		api.character.set_lift(3.0, Vector3(1.0, 0, 0))
		var lifted_box: AABB = me._rig.custom_aabb
		api.character.clear_lift()
		me.snap_to(Vector2(2.5, 5.5))
		frames.call(60)
		var back: AABB = me._rig.custom_aabb
		check(box0 == AABB(Vector3(-2, -1, -2), Vector3(4, 8, 4)) and back == box0 and is_equal_approx(on_step.size.y, 8.0 + AvatarScript.STAND_MAX) and on_step.size.x == 4.0
			and is_equal_approx(lifted_box.size.y, 8.0 + 3.0 + AvatarScript.STAND_MAX) and is_equal_approx(lifted_box.size.x, 6.0) and is_equal_approx(lifted_box.position.x, -3.0),
			"belt step: the culling box is the old 4 x 8 x 4 on the ground, grown only while stepped up or lifted, back after: %s %s %s %s" % [box0, on_step, lifted_box, back])

	# Turned off: the setting, and --belt-step=off.
	Settings.set_value("graphics", "belt_step", false, false)
	me.snap_to(Vector2(5.5, 5.5))
	frames.call(30)
	var with_setting_off := me.stand_lift()
	Settings.reset_value("graphics", "belt_step")
	frames.call(30)
	var setting_back := me.stand_lift()
	AvatarScript.belt_step_switch = false
	me.snap_to(Vector2(2.5, 5.5))
	frames.call(2)
	me.snap_to(Vector2(5.5, 5.5))
	frames.call(30)
	var with_switch_off := me.stand_lift()
	AvatarScript.belt_step_switch = true
	check(with_setting_off == 0.0 and is_equal_approx(setting_back, top) and with_switch_off == 0.0 and not ("--belt-step=off" in OS.get_cmdline_user_args()),
		"belt step: Step onto belts off gives no rise, on again it steps up, --belt-step=off none: %.3f %.3f %.3f" % [with_setting_off, setting_back, with_switch_off])

	# Back as the rest of the test had it.
	fake.avatar = plain
	fake.world = world_before
	rig.target = target_before
	host._push_lift()
	me.world = null
	# Not in the tree: the world's chunks and its own parts made in its declarations go too.
	var loose: Array = []
	for cv in w.chunks.values():
		if cv is Node:
			loose.append(cv)
	var owners: Array = [w]
	var i := 0
	while i < owners.size():
		for prop: Dictionary in (owners[i] as Node).get_property_list():
			var v = (owners[i] as Node).get(prop["name"])
			if v is Node and (v as Node).get_parent() == null and not loose.has(v) and v != me and v != rig and not owners.has(v):
				loose.append(v)
				owners.append(v)
		i += 1
	loose.append(w)
	for n: Node in loose:
		if is_instance_valid(n):
			n.free()
	me.queue_free()
	await get_tree().process_frame


## Step 6, pieces 1 and 2 (API 1.7): api.camera.set_modifier, drawn on the player's three views only,
## summed and capped by the host, gone on stop and at the game's end, kept out of take-over's saved FOV;
## take({"input": false, "aim": "center"}) and the one aims_center(). The bound pinned: walking reads the
## view from before the modifier, nothing is sent, the character and its reach don't move.
func _camera_modifiers(api, host, fake, rig) -> void:
	const AvatarScript := preload("res://scripts/player/avatar.gd")
	const PlayerInput := preload("res://scripts/player/player_input.gd")
	var disk: Dictionary = host.find("disk-addon")
	var other = disk["object"]
	var plain = fake.avatar
	var target_before = rig.target
	var capture_before = Bridge.capture
	Bridge.capture = []
	var me := AvatarScript.new()
	add_child(me)
	me.set_process(false)
	fake.avatar = me
	rig.target = me
	me.snap_to(Vector2(10, 5))
	me.update_from({"t": "me", "u": 5, "x": 2560, "y": 1280, "k": 1, "hp": 250, "mhp": 250, "v": 0})
	if rig.first_person:
		rig.toggle_first_person()
	var draw := func() -> void:
		me._process(0.0)
		rig._process(0.0)
	var cam := func() -> Transform3D: return rig.camera.global_transform

	# Nothing before use: no modifier on, the camera as the view puts it.
	draw.call()
	var t0: Transform3D = cam.call()
	var view0: Transform3D = api.camera.player_view()
	var fwd0: Vector3 = rig.ground_forward()
	var right0: Vector3 = rig.ground_right()
	check(not rig._mod_on and not rig._mod_shown and is_equal_approx(rig.camera.fov, 35.0) and api.camera.modifier() == {"offset": Vector3.ZERO, "turn": Vector3.ZERO, "fov": 0.0},
		"modifier: none before use, the FOV the view's own 35")

	# An offset in the camera's frame; the player's view and walking unmoved.
	api.camera.set_modifier(Vector3(0.1, 0, 0))
	draw.call()
	var t1: Transform3D = cam.call()
	check(t1.origin.is_equal_approx(t0.origin + t0.basis.x.normalized() * 0.1) and t1.basis.is_equal_approx(t0.basis) and api.camera.transform() == t1,
		"modifier: an offset of 0.1 moves the angled camera 0.1 along its right: %s" % [t1.origin - t0.origin])
	check(api.camera.player_view().is_equal_approx(view0) and api.camera.modifier()["offset"] == Vector3(0.1, 0, 0), "modifier: player_view() unchanged; modifier() gives it back")
	# A yaw: the picture turns, walking doesn't.
	api.camera.set_modifier(Vector3.ZERO, Vector3(0, 0.2, 0))
	draw.call()
	var turned: Transform3D = cam.call()
	check(absf((-turned.basis.z).angle_to(-t0.basis.z) - 0.2) < 0.001 and turned.origin.is_equal_approx(t0.origin), "modifier: a yaw of 0.2 turns the picture by 0.2 about the eye")
	check(rig.ground_forward() == fwd0 and rig.ground_right() == right0,
		"modifier: ground_forward() and ground_right() (the walk's directions) unchanged to the bit with a yaw on: %s %s" % [rig.ground_forward(), fwd0])
	# The FOV: the angled view's 35 and first person's 75, plus the change; back when cleared.
	api.camera.set_modifier(Vector3.ZERO, Vector3.ZERO, 10.0)
	draw.call()
	var fov_angled: float = rig.camera.fov
	rig.toggle_first_person()
	draw.call()
	var fov_fp: float = rig.camera.fov
	var eye_mod := func(o: Vector3) -> Vector3:
		api.camera.set_modifier(o)
		draw.call()
		return rig.camera.global_position
	var eye0: Vector3 = eye_mod.call(Vector3.ZERO)
	var fov_fp_clear: float = rig.camera.fov
	var eye_up: Vector3 = eye_mod.call(Vector3(0, 1, 0))
	var up_dir: Vector3 = rig.global_transform.basis * rig._base.basis.y
	api.camera.clear_modifier()
	rig.toggle_first_person()
	draw.call()
	check(is_equal_approx(fov_angled, 45.0) and is_equal_approx(fov_fp, 85.0) and is_equal_approx(fov_fp_clear, 75.0) and is_equal_approx(rig.camera.fov, 35.0),
		"modifier: FOV +10 gives 45 angled and 85 in first person; cleared, 75 and 35 again: %s %s %s %s" % [fov_angled, fov_fp, fov_fp_clear, rig.camera.fov])
	check(eye_up.is_equal_approx(eye0 + up_dir) and is_equal_approx(up_dir.length(), 1.0),
		"modifier: an offset of (0, 1, 0) moves first person's eye 1 tile along the camera's up: %s" % [eye_up - eye0])
	check(cam.call().is_equal_approx(t0) and not rig._mod_shown, "modifier: cleared, the camera exactly as before")
	# Orthographic views keep their FOV (it doesn't draw); the offset still applies.
	rig.orthographic = true
	api.camera.set_modifier(Vector3(0.1, 0, 0), Vector3.ZERO, 10.0)
	draw.call()
	var ortho_fov: float = rig.camera.fov
	api.camera.clear_modifier()
	rig.orthographic = false
	draw.call()
	check(is_equal_approx(ortho_fov, 35.0), "modifier: an orthographic view ignores fov: %s" % ortho_fov)

	# Modes: not in the remote view, a ride's film, VR or another add-on's take-over; applied again after.
	var mode_still := func(enter: Callable, leave: Callable) -> bool:
		enter.call()
		draw.call()
		var bare: Transform3D = cam.call()
		var bare_fov: float = rig.camera.fov
		api.camera.set_modifier(Vector3(0.5, 0, 0), Vector3(0.1, 0.1, 0.1), 20.0)
		draw.call()
		var same: bool = cam.call().is_equal_approx(bare) and is_equal_approx(rig.camera.fov, bare_fov)
		leave.call()
		draw.call()
		var modded: Transform3D = cam.call()
		var shown: bool = rig._mod_shown
		api.camera.clear_modifier()
		draw.call()
		return same and shown and not modded.is_equal_approx(cam.call())
	var vr_off := func() -> void:
		rig.vr_view.free()
		rig.vr_view = null
	var stills := [
		mode_still.call(func() -> void: rig.in_remote = true, func() -> void: rig.in_remote = false),
		mode_still.call(func() -> void: rig.cinematic(50.0, 30.0), func() -> void: rig.cinematic_end()),
		mode_still.call(func() -> void: rig.vr_view = Node3D.new(), vr_off),
		mode_still.call(func() -> void: other.camera.take({"input": false}), func() -> void: other.camera.release()),
	]
	check(stills == [true, true, true, true], "modifier: the camera unmoved in remote, ride, vr and an add-on's take-over, applied again after: %s" % [stills])
	draw.call()
	t0 = cam.call()  # the transitions move the view a little at delta 0 (a ride's glide): the reference again

	# Caps and sums.
	api.camera.set_modifier(Vector3(0.1, 0, 0))
	other.camera.set_modifier(Vector3(0, 0.2, 0))
	var two: Array = host.camera_modifier_sum()
	api.camera.set_modifier(Vector3(5, 0, 0), Vector3(2, -2, 2), 100.0)
	var capped: Array = host.camera_modifier_sum()
	api.camera.set_modifier(Vector3(-5, 0, 0), Vector3(-2, 2, -2), -100.0)
	other.camera.clear_modifier()
	var capped_neg: Array = host.camera_modifier_sum()
	draw.call()
	var low_fov: float = rig.camera.fov
	api.camera.set_modifier(Vector3(NAN, 0.3, INF), Vector3(NAN, 0, 0), NAN)
	var nan_kept: Dictionary = api.camera.modifier()
	api.camera.set_modifier(Vector3(NAN, 0, 0), Vector3.ZERO, NAN)
	var nan_only: Dictionary = api.camera.modifier()
	check((two[0] as Vector3).is_equal_approx(Vector3(0.1, 0.2, 0)), "modifier: two add-ons' offsets add: %s" % [two[0]])
	check(is_equal_approx((capped[0] as Vector3).length(), 1.5) and (capped[1] as Vector3).is_equal_approx(Vector3(deg_to_rad(20), deg_to_rad(-20), deg_to_rad(45)))
		and is_equal_approx(float(capped[2]), 30.0) and is_equal_approx(float(capped_neg[2]), -30.0) and (capped_neg[1] as Vector3).is_equal_approx(Vector3(deg_to_rad(-20), deg_to_rad(20), deg_to_rad(-45))),
		"modifier: capped after the sum: an offset of 5 is 1.5 long, pitch and yaw 20 degrees, roll 45, the FOV 30 either way: %s %s" % [capped, capped_neg])
	check(is_equal_approx(low_fov, 10.0), "modifier: the FOV never below 10 (35 less 30): %s" % low_fov)
	check(nan_kept["offset"] == Vector3(0, 0.3, 0) and nan_kept["turn"] == Vector3.ZERO and nan_kept["fov"] == 0.0 and nan_only["offset"] == Vector3.ZERO,
		"modifier: not-a-number (and infinity) count as 0: %s" % [nan_kept])
	api.camera.set_modifier(Vector3(0.2, 0, 0))
	other.camera.set_modifier(Vector3(0, 0.3, 0))
	host.stop(disk)
	var after_stop: Array = host.camera_modifier_sum()
	host.start(disk)
	other = disk["object"]
	check((after_stop[0] as Vector3).is_equal_approx(Vector3(0.2, 0, 0)) and other.camera.modifier()["offset"] == Vector3.ZERO,
		"modifier: stopping one add-on takes its modifier away and leaves the other's: %s" % [after_stop[0]])

	# The switch: --camera-modifiers=off.
	CameraRig.modifiers_on = false
	host._push_camera_mod()
	draw.call()
	var off_still: bool = cam.call().is_equal_approx(t0)
	CameraRig.modifiers_on = true
	host._push_camera_mod()
	draw.call()
	check(off_still and not cam.call().is_equal_approx(t0), "modifier: --camera-modifiers=off: the camera as without one")
	api.camera.clear_modifier()
	draw.call()

	# The player's scale (Settings > Camera > Add-ons' camera motion): before the caps, at once; modifier()
	# gives what the add-on set; an add-on's aim at the centre isn't touched.
	api.camera.set_modifier(Vector3(1, 0, 0))
	Settings.set_value("camera", "addon_motion", 50, false)
	draw.call()
	var half: Transform3D = cam.call()
	var half_set: Dictionary = api.camera.modifier()
	api.camera.set_modifier(Vector3(3, 0, 0))
	var half_capped: Array = host.camera_modifier_sum()
	api.camera.set_modifier(Vector3(1, 0, 0), Vector3(0, 0.2, 0), 10.0)
	Settings.set_value("camera", "addon_motion", 0, false)
	draw.call()
	var none := [cam.call().is_equal_approx(t0), rig._mod_on, rig._mod_shown, is_equal_approx(rig.camera.fov, 35.0), host.camera_modifier_sum()[0] == Vector3.ZERO]
	var none_set: Dictionary = api.camera.modifier()
	api.camera.take({"input": false, "aim": "center"})
	var none_aim: bool = rig.aims_center()
	api.camera.release()
	Settings.set_value("camera", "addon_motion", 100, false)
	draw.call()
	var whole: Transform3D = cam.call()
	api.camera.clear_modifier()
	draw.call()
	check(half.origin.is_equal_approx(t0.origin + t0.basis.x.normalized() * 0.5) and half_set["offset"] == Vector3(1, 0, 0),
		"motion: at 50%% an offset of 1 draws 0.5; modifier() still gives 1: %s %s" % [half.origin - t0.origin, half_set])
	check(is_equal_approx((half_capped[0] as Vector3).length(), 1.5), "motion: scaled before the caps: 3 at 50%% is 1.5: %s" % [half_capped[0]])
	check(none == [true, false, false, true, true] and none_set["fov"] == 10.0 and none_aim,
		"motion: at 0%% nothing is drawn, modifier() keeps the add-on's, aim at the centre still works: %s %s %s" % [none, none_set, none_aim])
	check(not whole.is_equal_approx(t0) and cam.call().is_equal_approx(t0), "motion: back at 100% the modifier is drawn again")

	# Take-over: the player's FOV is saved without the modifier and given back with it.
	rig.toggle_first_person()
	api.camera.set_modifier(Vector3.ZERO, Vector3.ZERO, 10.0)
	draw.call()
	var before_take: float = rig.camera.fov
	api.camera.take({"input": false})
	var saved_fov: float = float(rig._taken.get("fov", -1.0))
	api.camera.release()
	var after_release: float = rig.camera.fov
	api.camera.clear_modifier()
	draw.call()
	check(is_equal_approx(before_take, 85.0) and is_equal_approx(saved_fov, 75.0) and is_equal_approx(after_release, 85.0) and is_equal_approx(rig.camera.fov, 75.0),
		"modifier: take() saves FOV 75, not 85; release() gives 75 plus the 10: %s %s %s" % [before_take, saved_fov, after_release])
	rig.toggle_first_person()
	draw.call()

	# Aim at the centre.
	var middle: Vector2 = rig.get_viewport().get_visible_rect().size * 0.5
	var dot := func() -> bool: return rig._crosshair != null and rig._crosshair.visible
	api.camera.take({"input": false, "aim": "center"})
	var centre := [rig.aims_center(), rig.aim_position() == middle, dot.call()]
	api.camera.release()
	var released := [rig.aims_center(), dot.call()]
	check(centre == [true, true, true] and released == [false, false], "aim: take({input: false, aim: center}): aims_center, the middle, the dot; release() puts both back: %s %s" % [centre, released])
	api.camera.take({"input": false})
	var plain_take: bool = rig.aims_center()
	api.camera.release()
	api.camera.take({"aim": "center"})
	var with_input: bool = rig.aims_center()
	api.camera.release()
	api.camera.take({"input": false, "aim": "center", "crosshair": false})
	var no_dot := [rig.aims_center(), dot.call()]
	api.camera.release()
	check(not plain_take and not with_input and no_dot == [true, false],
		"aim: without aim from the angled view no; with input (the default) no; crosshair false: no dot: %s %s %s" % [plain_take, with_input, no_dot])
	rig.toggle_first_person()
	api.camera.take({"input": false})
	var fp_take := [rig.aims_center(), dot.call()]
	api.camera.release()
	var fp_back := [rig.aims_center(), dot.call()]
	rig.toggle_first_person()
	check(fp_take == [true, false] and fp_back == [true, true], "aim: from first person a take aims at the centre (as before); released, first person's dot again: %s %s" % [fp_take, fp_back])

	# The bound: the character, its reach and what is sent don't follow a 1.5-tile modifier.
	var input := PlayerInput.new()
	input.avatar = me
	var spots := [Vector2(19, 5), Vector2(21, 5), Vector2(10, 16.5)]
	var pos0 := me.position
	var reach0 := spots.map(func(p: Vector2) -> Array: return [input._in_reach(p, Vector2i.ONE), input._bridge_reach(p)])
	api.camera.set_modifier(Vector3(1.5, 0, 0), Vector3(0.3, 0.3, 0.7), 30.0)
	for fp: bool in [false, true]:
		if rig.first_person != fp:
			rig.toggle_first_person()
		draw.call()
	var reach_mod := spots.map(func(p: Vector2) -> Array: return [input._in_reach(p, Vector2i.ONE), input._bridge_reach(p)])
	rig.toggle_first_person()
	api.camera.clear_modifier()
	draw.call()
	check(reach_mod == reach0 and me.position == pos0 and is_equal_approx(rig.modifier_reach(), 0.0),
		"modifier: the character's place and reach unchanged with a 1.5-tile modifier: %s" % [reach_mod])
	# The one message: the stop that take() with "input" (the default) sends as it turns the controls off.
	var sent: Array = (Bridge.capture as Array).filter(func(t: String) -> bool: return not t.contains("\"hello\""))
	check(sent.size() == 1 and str(sent[0]).contains("\"walk\""), "modifier and aim: nothing sent to the game but the one take with input's stop: %s" % [sent])

	# The game's end drops every modifier.
	api.camera.set_modifier(Vector3(0.2, 0, 0))
	host.game_ended()
	var ended := [api.camera.modifier()["offset"], rig._mod_on]
	host.game_started()
	await get_tree().process_frame
	check(ended == [Vector3.ZERO, false], "modifier: the game's end drops it: %s" % [ended])

	Bridge.capture = capture_before
	fake.avatar = plain
	rig.target = target_before
	var loose: Array = []
	var owners: Array = [input]
	var i := 0
	while i < owners.size():
		for prop: Dictionary in (owners[i] as Node).get_property_list():
			if str(prop["name"]).begins_with("global_"):
				continue  # read off the tree it only complains
			var v = (owners[i] as Node).get(prop["name"])
			if v is Node and (v as Node).get_parent() == null and not loose.has(v) and v != me and v != rig:
				loose.append(v)
				owners.append(v)
		i += 1
	loose.append(input)
	for n: Node in loose:
		n.free()
	me.queue_free()
	await get_tree().process_frame


## The testing pass over step 6 (mods-cam-test): the cases the coders' checks don't reach. Walking
## diagonally under the biggest sway two add-ons can give, in every view; sums that overflow; the reach
## cut by the capped, scaled offset; the strength on a turn; each of the 22 avatar names; two add-ons'
## muzzles; the view anchor under other modes; attachments through death; a pose's weight 0.
func _cam_group_extra(api, host, fake, rig) -> void:
	const AvatarScript := preload("res://scripts/player/avatar.gd")
	const CharacterPoints := preload("res://scripts/player/character_points.gd")
	var disk: Dictionary = host.find("disk-addon")
	var other = disk["object"]
	var plain = fake.avatar
	var target_before = rig.target
	var capture_before = Bridge.capture
	Bridge.capture = []
	var me := AvatarScript.new()
	add_child(me)
	me.set_process(false)
	fake.avatar = me
	rig.target = me
	host._push_character()
	me.snap_to(Vector2(10, 5))
	me.update_from({"t": "me", "u": 5, "x": 2560, "y": 1280, "k": 1, "hp": 250, "mhp": 250, "v": 0})
	if rig.first_person:
		rig.toggle_first_person()
	var draw := func() -> void:
		me._process(0.0)
		rig._process(0.0)
	draw.call()
	var pos0 := me.position

	# Walking diagonally under the largest sway (both add-ons past every cap, the FOV kicked both ways),
	# in the angled view turned off the axes, Factorio's view and first person looking off level: the
	# walk's directions, and the 1000-step turn the bridge gets, the same to the bit.
	var walk_turn := func(input: Vector2) -> int:
		var d: Vector3 = rig.ground_right() * input.x + rig.ground_forward() * input.y
		return posmod(int(round(atan2(d.x, -d.z) / TAU * 1000.0)), 1000)
	var inputs := [Vector2(0.7071, 0.7071), Vector2(-0.6, 0.8), Vector2(0.8, -0.6), Vector2(-0.7071, -0.7071)]
	var walk_of := func() -> Array:
		var out: Array = [rig.ground_forward(), rig.ground_right()]
		for i: Vector2 in inputs:
			out.append(walk_turn.call(i))
		return out
	rig.rotate_free(37.0)
	var walk_bad: Array = []
	for view in ["angled", "factorio", "first_person"]:
		if view == "factorio":
			rig.toggle_factorio_view()
		elif view == "first_person":
			if rig.in_factorio_view():
				rig.toggle_factorio_view()
			rig.toggle_first_person()
			rig.look(Vector2(150, -90))
		draw.call()
		draw.call()
		var bare: Array = walk_of.call()
		for fov in [30.0, -30.0]:
			api.camera.set_modifier(Vector3(1.0, -1.0, 1.0), Vector3(0.3, -0.3, 0.7), fov)
			other.camera.set_modifier(Vector3(1.0, 1.0, -1.0), Vector3(0.3, -0.3, 0.7), fov)
			draw.call()
			var swayed: Array = walk_of.call()
			if swayed != bare or not rig._mod_shown:
				walk_bad.append("%s fov %s: %s vs %s" % [view, fov, swayed, bare])
		api.camera.clear_modifier()
		other.camera.clear_modifier()
		draw.call()
	if rig.first_person:
		rig.toggle_first_person()
	rig.rotate_free(-37.0)
	draw.call()
	check(walk_bad.is_empty(), "extra: a diagonal walk under the capped sway and FOV kick of two add-ons, in all three views: the same turn to the bit: %s" % [walk_bad])

	# Sums past a float's range: two finite offsets of 3e38 add to infinity; the camera must stay a number.
	api.camera.set_modifier(Vector3(3e38, 0, 0), Vector3(3e38, 0, 0), 1e300)
	other.camera.set_modifier(Vector3(3e38, 0, 0), Vector3(3e38, 0, 0), 1e300)
	var huge: Array = host.camera_modifier_sum()
	draw.call()
	var huge_cam: Transform3D = rig.camera.global_transform
	var huge_ok: bool = huge_cam.origin.is_finite() and huge_cam.basis.is_finite() and is_finite(rig.camera.fov)
	api.camera.clear_modifier()
	other.camera.clear_modifier()
	draw.call()
	check(huge_ok and (huge[0] as Vector3).is_finite(), "extra: two add-ons' offsets of 3e38 sum past a float: the camera stays finite: sum %s, camera %s" % [huge, huge_cam.origin])
	# The same for turns and FOV: each capped before the sum, so two of 3e38 never add to infinity (times
	# 0% that was not-a-number), at the strength's ends.
	var turn_bad: Array = []
	for strength in [0, 100]:
		Settings.set_value("camera", "addon_motion", strength, false)
		api.camera.set_modifier(Vector3.ZERO, Vector3(3e38, 3e38, 3e38), 3e38)
		other.camera.set_modifier(Vector3.ZERO, Vector3(3e38, 3e38, 3e38), 3e38)
		var big: Array = host.camera_modifier_sum()
		draw.call()
		var big_cam: Transform3D = rig.camera.global_transform
		if not ((big[1] as Vector3).is_finite() and is_finite(float(big[2])) and big_cam.basis.is_finite()
				and big_cam.origin.is_finite() and is_finite(rig.camera.fov)):
			turn_bad.append("%d%%: sum %s, basis %s, fov %s" % [strength, big, big_cam.basis, rig.camera.fov])
	Settings.set_value("camera", "addon_motion", 100, false)
	api.camera.clear_modifier()
	other.camera.clear_modifier()
	draw.call()
	check(turn_bad.is_empty(), "extra: two add-ons' turns and FOV of 3e38 at 0%% and 100%%: a finite basis and FOV: %s" % [turn_bad])

	# The first-person reach: cut by the offset as drawn (summed, capped, scaled), 0 in the remote view.
	rig.toggle_first_person()
	api.camera.set_modifier(Vector3(1.0, 0, 0))
	other.camera.set_modifier(Vector3(1.0, 0, 0))
	draw.call()
	var reach_capped: float = rig.modifier_reach()
	Settings.set_value("camera", "addon_motion", 50, false)
	draw.call()
	var reach_half: float = rig.modifier_reach()
	Settings.set_value("camera", "addon_motion", 100, false)
	rig.in_remote = true
	draw.call()
	var reach_remote: float = rig.modifier_reach()
	rig.in_remote = false
	api.camera.clear_modifier()
	other.camera.clear_modifier()
	draw.call()
	rig.toggle_first_person()
	draw.call()
	check(is_equal_approx(reach_capped, 1.5) and is_equal_approx(reach_half, 1.0) and reach_remote == 0.0,
		"extra: the pick's reach cut by the drawn offset: 2 summed capped to 1.5, 50%% of 2 is 1, none in remote: %s %s %s" % [reach_capped, reach_half, reach_remote])

	# The strength on a turn, before the cap: a yaw of 0.6 is 0.3 at 50% (under 20 degrees), capped at 100%.
	Settings.set_value("camera", "addon_motion", 50, false)
	api.camera.set_modifier(Vector3.ZERO, Vector3(0, 0.6, 0), 20.0)
	var half_turn: Array = host.camera_modifier_sum()
	Settings.set_value("camera", "addon_motion", 100, false)
	var full_turn: Array = host.camera_modifier_sum()
	api.camera.clear_modifier()
	draw.call()
	check(is_equal_approx((half_turn[1] as Vector3).y, 0.3) and is_equal_approx(float(half_turn[2]), 10.0)
		and is_equal_approx((full_turn[1] as Vector3).y, deg_to_rad(20.0)) and is_equal_approx(float(full_turn[2]), 20.0),
		"extra: strength scales turn and FOV before the caps: %s %s" % [half_turn, full_turn])

	# Every avatar name (the 11 bones, the 12 points but view): attach() takes it and the node sits at frame().
	var names_bad: Array = []
	var nodes: Array = []
	for n: String in CharacterPoints.names():
		if n == "view":
			continue
		var node := Node3D.new()
		if not api.character.attach(node, n):
			names_bad.append(n + ": refused")
			node.free()
			continue
		nodes.append([node, n])
	draw.call()
	for e: Array in nodes:
		var f = api.character.frame(str(e[1]))
		if not (f is Transform3D and (e[0] as Node3D).global_transform.is_equal_approx(f)):
			names_bad.append("%s at %s, frame %s" % [e[1], (e[0] as Node3D).global_position, f])
	check(nodes.size() == 22 and names_bad.is_empty(), "extra: all 22 avatar names take a node at their frame(): %d %s" % [nodes.size(), names_bad])
	# Through death: the nodes stay on the holder and follow the fall.
	var head_node: Node3D = null
	for e: Array in nodes:
		if e[1] == "head_top":
			head_node = e[0]
	var head_alive := head_node.global_position
	me.health = 0
	me._anim._fall = 1.0
	draw.call()
	var head_dead := head_node.global_position
	var dead_parent := head_node.get_parent() == me._holder
	me._anim._fall = 0.0
	me.health = 250
	draw.call()
	check(dead_parent and head_dead.y < head_alive.y - 0.3 and head_node.global_position.is_equal_approx(head_alive),
		"extra: through death a node at head_top stays on and falls with the body, back up after: %s %s" % [head_alive, head_dead])
	for e: Array in nodes:
		api.character.detach(e[0])
		(e[0] as Node).free()

	# Two add-ons' muzzles: the newest set wins; cleared or stopped, the other's comes back.
	var mine := Node3D.new()
	var theirs := Node3D.new()
	api.character.attach(mine, "right_hand")
	other.character.attach(theirs, "left_hand")
	draw.call()
	api.character.set_muzzle(mine, Vector3(0, 0, -1))
	other.character.set_muzzle(theirs, Vector3(0, 0, -1))
	var m_theirs := me.muzzle_position()
	var m_theirs_want := theirs.global_transform * Vector3(0, 0, -1)
	other.character.clear_muzzle()
	var m_mine := me.muzzle_position()
	other.character.set_muzzle(theirs, Vector3(0, 0, -1))
	host.stop(disk)
	await get_tree().process_frame
	var m_after_stop := me.muzzle_position()
	host.start(disk)
	other = disk["object"]
	api.character.set_muzzle(mine, Vector3(0, 0, -1))
	mine.free()
	var m_freed := me.muzzle_position()
	api.character.clear_muzzle()
	var m_own := me.muzzle_position()
	check(m_theirs.is_equal_approx(m_theirs_want) and m_mine != m_theirs and m_after_stop.is_equal_approx(m_mine)
		and m_freed.is_equal_approx(m_own) and m_freed.is_finite(),
		"extra: two add-ons' muzzles: the newer's, the other's when it clears or stops, Zenith's when the node is freed: %s %s %s %s" % [m_theirs, m_mine, m_after_stop, m_freed])
	# A muzzle node freed without clear_muzzle(), then the game ends and starts again: the freed entry
	# dropped before the avatar is given the last one (a freed node to its typed argument is a script
	# error), Zenith's own muzzle back.
	var gone := Node3D.new()
	api.character.attach(gone, "right_hand")
	api.character.set_muzzle(gone, Vector3(0, 0, -1))
	gone.free()
	host.game_ended()
	host.game_started()
	await get_tree().process_frame
	draw.call()
	var m_restart := me.muzzle_position()
	check(not host._muzzles.has(api.character) and m_restart.is_equal_approx(m_own) and me._addon_muzzle.is_empty(),
		"extra: a freed muzzle node across a game's end and start: dropped, Zenith's muzzle back: %s %s %s" % [host._muzzles.keys(), m_restart, m_own])
	# attach and the muzzle given a freed node: refused, no script error.
	var freed := Node3D.new()
	freed.free()
	# (through the host: the API's own `node: Node3D` arguments refuse a freed instance before it)
	var attach_freed: bool = host.character_attach(api.character, freed, "right_hand", Transform3D.IDENTITY)
	host.character_muzzle(api.character, freed, Vector3.ZERO)
	check(not attach_freed and not host._muzzles.has(api.character), "extra: attach and the muzzle given a freed node: refused")

	# The view anchor: hidden in first person while the remote view, VR or an add-on has the camera.
	var vm := Node3D.new()
	api.character.attach(vm, "view")
	rig.toggle_first_person()
	draw.call()
	var vis := [vm.is_visible_in_tree()]
	rig.in_remote = true
	draw.call()
	vis.append(vm.is_visible_in_tree())
	rig.in_remote = false
	rig.vr_view = Node3D.new()
	draw.call()
	vis.append(vm.is_visible_in_tree())
	rig.vr_view.free()
	rig.vr_view = null
	other.camera.take({"input": false})
	draw.call()
	vis.append(vm.is_visible_in_tree())
	other.camera.release()
	draw.call()
	vis.append(vm.is_visible_in_tree())
	rig.toggle_first_person()
	draw.call()
	api.character.detach(vm)
	vm.free()
	check(vis == [true, false, false, false, true], "extra: view shown in first person only, not under remote, VR or a take-over: %s" % [vis])

	# A pose at weight 0 (replace or add) leaves Zenith's own; two adds at weight 0.5 add halves.
	var head: int = me._pose.index["head"]
	var turns0: PackedVector3Array = me._pose.turns.duplicate()
	api.character.set_pose({"head": Vector3(0.4, 0, 0)}, {"weight": 0.0, "replace": true})
	draw.call()
	var w0: PackedVector3Array = me._pose.turns.duplicate()
	api.character.set_pose({"head": Vector3(0.4, 0, 0)}, {"weight": 0.5})
	other.character.set_pose({"head": Vector3(0.2, 0, 0)}, {"weight": 0.5})
	draw.call()
	var halves: Vector3 = me._pose.turns[head]
	api.character.clear_pose()
	other.character.clear_pose()
	draw.call()
	check(w0 == turns0 and halves.is_equal_approx(turns0[head] + Vector3(0.3, 0, 0)) and me._pose.turns == turns0,
		"extra: weight 0 changes nothing; two adds at 0.5 give half of each: %s" % [halves - turns0[head]])
	# Infinity in a turn (the host turns only not-a-number to 0): held to the joint, never a NaN bone,
	# whether added or replaced and at any weight, 0 included.
	var inf_bad: Array = []
	for opts: Dictionary in [{}, {"replace": true}, {"weight": 0.0}, {"weight": 0.0, "replace": true}, {"weight": 0.5, "replace": true}]:
		api.character.set_pose({"head": Vector3(INF, -INF, 0)}, opts)
		draw.call()
		var t: Vector3 = me._pose.turns[head]
		if not t.is_finite():
			inf_bad.append("%s: %s" % [opts, t])
	api.character.clear_pose()
	draw.call()
	check(inf_bad.is_empty(), "extra: a turn of infinity never makes a NaN bone: %s" % [inf_bad])

	# The bound for all of it.
	host.stop(disk)
	host.start(disk)
	check(me.position == pos0, "extra: avatar.position unchanged to the bit")
	check((Bridge.capture as Array).filter(func(t: String) -> bool: return not t.contains("\"hello\"")).is_empty(),
		"extra: nothing sent to the game by modifiers, attachments, muzzles or poses: %s" % [Bridge.capture])
	Bridge.capture = capture_before
	fake.avatar = plain
	rig.target = target_before
	host._push_character()
	me.queue_free()
	await get_tree().process_frame


## Stopping an add-on frees its API object and the parts (addon_api.gd _let_go): each part holds the
## object and it them, so before about 12 objects were left for each start. Counted over 20 stops and
## starts of an add-on that ignores the API, and of one that connects a character signal and lifts.
func _api_leak(host) -> void:
	var disk: Dictionary = host.find("disk-addon")
	var cycle := func(touch: bool) -> void:
		host.stop(disk)
		host.start(disk)
		if touch:
			var a = disk["object"]
			a.character.footfall.connect(func(_f: String, _p: Vector3) -> void: pass)
			a.character.set_lift(0.1)
	for i in 3:
		cycle.call(true)
		await get_tree().process_frame
	var per_start := {}
	for touch: bool in [false, true]:
		for i in 3:
			await get_tree().process_frame
		var before := Performance.get_monitor(Performance.OBJECT_COUNT)
		for i in 20:
			cycle.call(touch)
			await get_tree().process_frame
		for i in 3:
			await get_tree().process_frame
		per_start[touch] = (Performance.get_monitor(Performance.OBJECT_COUNT) - before) / 20.0
	print("leak: objects left per add-on start: %.2f plain, %.2f with api.character used" % [per_start[false], per_start[true]])
	check(float(per_start[false]) < 1.0 and float(per_start[true]) < 1.0,
		"stop frees the add-on's API object and its parts: objects left per start %.2f plain, %.2f with api.character" % [per_start[false], per_start[true]])
	(disk["object"]).character.clear_lift()


## The character group as a player and an add-on meet it (testing, mods-char-test): a walk over a belt, a
## splitter turned east, an underground, a chest and bare ground in the angled view, Factorio's view and
## first person, with the camera still and nothing popping; the step-up's look-ups counted while walking
## and timed; a belt built under a standing character; reach and what is sent while stepped up; the
## camera's modes once each (the remote view over first person, an add-on's take-over), not on the frames
## between; a new game's first armour and guns; stopping one add-on leaving another's handlers and lift;
## footfalls named right and left for several loops each way.
func _char_extra(api, node: Node, host, fake, rig) -> void:
	const AvatarScript := preload("res://scripts/player/avatar.gd")
	const StandHeight := preload("res://scripts/world/stand_height.gd")
	const AimPick := preload("res://scripts/world/aim_pick.gd")
	const PlayerInput := preload("res://scripts/player/player_input.gd")
	const UiModel := preload("res://scripts/ui/factorio/ui_model.gd")
	const AddonCharacter := preload("res://scripts/addons/addon_character.gd")
	var plain = fake.avatar
	var world_before = fake.world
	var target_before = rig.target
	var hud_before = fake.hud
	var capture_before = Bridge.capture
	Bridge.capture = []
	var me := AvatarScript.new()
	add_child(me)
	me.set_process(false)  # stepped by hand: _process(dt) is one frame
	fake.avatar = me
	rig.target = me
	host._push_lift()
	var w := WorldMirror.new()
	w.pick_build_usec = 1 << 40
	w.protos.add_entities([[1, "x-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[2, "x-chest", "container", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[3, "x-splitter", "splitter", -0.9, -0.5, 0.9, 0.5, 200, 180, 0, 2, 1],
		[4, "x-underground", "underground-belt", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1]])
	w.chunks[Vector2i.ZERO] = ChunkView.new()
	for x in [5, 6, 7]:
		w._add([910 + x, 1, x * 256 + 128, 5 * 256 + 128, 4])  # belts x 5 to 8 on the row z 5.5, running east
	w._add([920, 3, 10 * 256 + 128, 6 * 256, 4])  # a splitter turned east: x 10 to 11, z 5 to 7
	w._add([921, 4, 13 * 256 + 128, 5 * 256 + 128, 4])  # an underground's entrance, x 13 to 14
	w._add([922, 2, 16 * 256 + 128, 5 * 256 + 128, 0])  # a chest, x 16 to 17
	me.world = w
	fake.world = w
	var tops := {"belt": AimPick.height_of(w, w.entities[915]), "splitter": AimPick.height_of(w, w.entities[920]),
		"underground": AimPick.height_of(w, w.entities[921])}
	check(float(tops["belt"]) > 0.0 and float(tops["splitter"]) > AvatarScript.STAND_MAX and float(tops["underground"]) > AvatarScript.STAND_MAX,
		"walk: the walk-on tops, the splitter's and underground's over the step-up's cap %.2f: %s" % [AvatarScript.STAND_MAX, tops])
	# The core stands the body at most STAND_MAX up (owner: "stepping onto belts"); add-ons get the whole top.
	for key: String in tops.keys():
		tops[key] = minf(float(tops[key]), AvatarScript.STAND_MAX)
	const DT := 1.0 / 60.0
	var k := [1000]
	var input := PlayerInput.new()
	input.avatar = me

	# One walk east along z 5.5 from x 1.5 to 20.5 at Factorio's running speed (0.15 a tick), a `me` a tick
	# and a frame a tick, as the game sends them; then 90 frames standing at the end.
	var walk := func() -> Dictionary:
		var out := {"frames": 0, "lookups": 0, "moved_frames": 0, "max_jump": 0.0, "cam_y": [], "rig_y": [], "goal_at": {},
			"pos_y_max": 0.0, "ground_off": 0.0, "reach_same": true, "still_frames_looking": 0, "still_lookups_late": 0}
		me.snap_to(Vector2(1.5, 5.5))
		me._stand = 0.0
		for i in 3:
			me._process(DT)
			rig._process(DT)
		var looks0: int = me.stand_lookups
		var last_pos := me.position
		var last_stand := me.stand_lift()
		var x := 1.5
		while x < 20.5:
			x += 0.15
			k[0] += 1
			me.update_from({"t": "me", "u": 5, "x": int(round(x * 256.0)), "y": 5 * 256 + 128, "k": k[0], "d": 4, "w": 1, "hp": 250, "mhp": 250, "v": 0})
			var before: int = me.stand_lookups
			me._process(DT)
			rig._process(DT)
			out["frames"] += 1
			if me.position != last_pos:
				out["moved_frames"] += 1
			last_pos = me.position
			out["max_jump"] = maxf(float(out["max_jump"]), absf(me.stand_lift() - last_stand))
			last_stand = me.stand_lift()
			(out["cam_y"] as Array).append(rig.camera.global_position.y)
			(out["rig_y"] as Array).append(rig.global_position.y)
			out["pos_y_max"] = maxf(float(out["pos_y_max"]), absf(me.position.y))
			out["ground_off"] = maxf(float(out["ground_off"]), me.ground_position().distance_to(Vector2(me.position.x, me.position.z)))
			if me.stand_lookups - before > 1:
				out["lookups_over_one"] = true
			# Where the drawn body stands, what it stands on (the goal, not the eased value).
			for spot: String in ["belt:6.5", "splitter:10.5", "underground:13.5", "chest:16.5", "ground:9.0", "ground:19.5"]:
				var sx := float(spot.get_slice(":", 1))
				if absf(me.position.x - sx) < 0.08 and not out["goal_at"].has(spot):
					out["goal_at"][spot] = me._stand_goal
			# Reach from the game's place: a tile just inside the build distance east of where the game has the
			# character is in reach, one a hair further isn't; the bridge's own reach the same way.
			var edge := Vector2(me.position.x, me.position.z)
			var r_in := edge + Vector2(input.build_reach() + 0.49, 0.0)
			var r_out := edge + Vector2(input.build_reach() + 0.51, 0.0)
			var b_in := edge + Vector2(input.build_reach() + PlayerInput.BRIDGE_REACH_SLACK - 0.01, 0.0)
			var b_out := edge + Vector2(input.build_reach() + PlayerInput.BRIDGE_REACH_SLACK + 0.01, 0.0)
			if not (input._in_reach(r_in, Vector2i.ONE) and not input._in_reach(r_out, Vector2i.ONE) and input._bridge_reach(b_in) and not input._bridge_reach(b_out)):
				out["reach_same"] = false
		out["lookups"] = me.stand_lookups - looks0
		# Standing: the drawn body settles; how many frames still look up, and none once settled.
		var settled := -1
		for i in 90:
			var before2: int = me.stand_lookups
			me._process(DT)
			rig._process(DT)
			if me.stand_lookups > before2:
				out["still_frames_looking"] += 1
				if i >= 60:
					out["still_lookups_late"] += 1
		k[0] += 120  # the game's clock went on while it stood
		return out

	# Angled view.
	check(rig.view_mode() == "angled", "walk: starts in the angled view")
	var angled: Dictionary = walk.call()
	# Factorio's view.
	rig.toggle_factorio_view()
	rig._process(DT)
	var f6_mode: String = rig.view_mode()
	var factorio: Dictionary = walk.call()
	var f6_after: String = rig.view_mode()
	rig.toggle_factorio_view()
	rig._process(DT)
	# First person.
	rig.toggle_first_person()
	var first: Dictionary = walk.call()
	rig.toggle_first_person()
	var spread := func(a: Array) -> float: return (a.max() - a.min()) if not a.is_empty() else -1.0
	var b_top: float = tops["belt"]
	check(f6_mode == "factorio" and f6_after == "factorio", "walk: Factorio's view held through the walk: %s %s" % [f6_mode, f6_after])
	for pair: Array in [["angled", angled], ["Factorio's view", factorio], ["first person", first]]:
		var r: Dictionary = pair[1]
		var ga: Dictionary = r["goal_at"]
		check(is_equal_approx(float(ga.get("belt:6.5", -1)), b_top) and is_equal_approx(float(ga.get("splitter:10.5", -1)), float(tops["splitter"]))
			and is_equal_approx(float(ga.get("underground:13.5", -1)), float(tops["underground"])) and float(ga.get("chest:16.5", -1)) == 0.0
			and float(ga.get("ground:9.0", -1)) == 0.0 and float(ga.get("ground:19.5", -1)) == 0.0,
			"walk (%s): stood on the belt, the splitter turned east and the underground (capped); not on the chest or bare ground: %s" % [pair[0], ga])
		check(float(r["max_jump"]) <= 0.45 * maxf(b_top, maxf(float(tops["splitter"]), float(tops["underground"]))),
			"walk (%s): no pop, the most the step-up moved in one frame %.4f (tops %s)" % [pair[0], r["max_jump"], tops])
		check(float(spread.call(r["cam_y"])) < 0.0005 and float(spread.call(r["rig_y"])) < 0.0005,
			"walk (%s): the camera's height didn't move over belts, splitter, underground and off: camera %.5f, rig %.5f" % [pair[0], spread.call(r["cam_y"]), spread.call(r["rig_y"])])
		check(float(r["pos_y_max"]) == 0.0 and float(r["ground_off"]) == 0.0 and bool(r["reach_same"]),
			"walk (%s): position on the ground, ground_position the game's, reach the same, every frame" % pair[0])
		check(not r.has("lookups_over_one") and int(r["lookups"]) <= int(r["frames"]) and int(r["lookups"]) == int(r["moved_frames"]) and int(r["still_lookups_late"]) == 0,
			"walk (%s): look-ups %d over %d frames (%d moved), at most one a frame; standing after: %d frames still looked up while it settled, none after 60 frames"
				% [pair[0], r["lookups"], r["frames"], r["moved_frames"], r["still_frames_looking"]])
	print("cost: step-up look-ups walking: %d in %d frames; standing after a walk: %d frames of look-ups while the drawn body settles"
		% [angled["lookups"], angled["frames"], angled["still_frames_looking"]])

	# One look-up timed, on this small world and on 400 belts round the point.
	var t0 := Time.get_ticks_usec()
	for i in 10000:
		StandHeight.at(w, Vector2(6.5, 5.5))
	var small_us := float(Time.get_ticks_usec() - t0) / 10000.0
	var id := 3000
	for y in 20:
		for x in 20:
			w._add([id, 1, (40 + x) * 256 + 128, (40 + y) * 256 + 128, 4])
			id += 1
	t0 = Time.get_ticks_usec()
	for i in 10000:
		StandHeight.at(w, Vector2(50.5, 50.5))
	var dense_us := float(Time.get_ticks_usec() - t0) / 10000.0
	t0 = Time.get_ticks_usec()
	for i in 10000:
		StandHeight.at(w, Vector2(30.5, 30.5))
	var bare_us := float(Time.get_ticks_usec() - t0) / 10000.0
	check(dense_us < 50.0, "cost: one step-up look-up %.2f us on a belt, %.2f us among 400 belts, %.2f us on bare ground" % [small_us, dense_us, bare_us])
	for i in 400:
		w._remove(3000 + i)

	# The known limit: a belt built under a character standing still isn't stood on until it moves.
	me.snap_to(Vector2(22.5, 5.5))
	for i in 5:
		me._process(DT)
	w._add([930, 1, 22 * 256 + 128, 5 * 256 + 128, 4])
	for i in 30:
		me._process(DT)
	var under_still := me.stand_lift()
	me.snap_to(Vector2(22.52, 5.5))
	for i in 30:
		me._process(DT)
	check(under_still == 0.0 and is_equal_approx(me.stand_lift(), b_top),
		"step-up's known limit: a belt built under a standing character isn't stood on (%.3f) until it moves (%.3f)" % [under_still, me.stand_lift()])

	# Nothing was sent to the game by the walks, the step-up or the lifts.
	check((Bridge.capture as Array).filter(func(t: String) -> bool: return not t.contains("\"hello\"")).is_empty(), "walk: nothing sent to the game: %s" % [Bridge.capture])

	# Modes: once each, not on the frames between; the remote view over first person; a camera lift never
	# moves the remote view.
	node.modes.clear()
	rig.toggle_first_person()
	for i in 10:
		await get_tree().process_frame
	api.character.set_lift(2.0, Vector3.ZERO, true)
	var anchor := Node3D.new()
	add_child(anchor)
	anchor.position = Vector3(40, 0, 40)
	rig.target = anchor  # factorio_ui.gd remote_view
	rig.in_remote = true
	for i in 10:
		await get_tree().process_frame
	rig._process(DT)
	var remote_eye: Vector3 = rig.camera.global_position
	var remote_mode: String = api.camera.mode()
	rig.target = me
	rig.in_remote = false
	for i in 10:
		await get_tree().process_frame
	rig._process(DT)
	var back_eye: Vector3 = rig.camera.global_position
	api.character.clear_lift()
	rig.toggle_first_person()
	for i in 10:
		await get_tree().process_frame
	check(node.modes == [["first_person", "angled"], ["remote", "first_person"], ["first_person", "remote"], ["angled", "first_person"]],
		"modes: first person, the remote view over it, back, angled: once each over 40 frames: %s" % [node.modes])
	check(remote_mode == "remote" and remote_eye.is_equal_approx(Vector3(40, CameraRig.EYE_HEIGHT, 40)) and back_eye.is_equal_approx(me.position + Vector3(0, CameraRig.EYE_HEIGHT + 2.0, 0)),
		"modes: the remote view with first person on sits at the remote point, the camera lift not added; back on the character it is: %s %s" % [remote_eye, back_eye])
	anchor.queue_free()
	var disk: Dictionary = host.find("disk-addon")
	var other = disk["object"]
	node.modes.clear()
	other.camera.take()
	for i in 5:
		await get_tree().process_frame
	var taken_mode: String = api.camera.mode()
	var taken_player: String = api.camera.player_mode()
	other.camera.release()
	for i in 5:
		await get_tree().process_frame
	check(taken_mode == "addon" and taken_player == "angled" and node.modes == [["addon", "angled"], ["angled", "addon"]],
		"modes: an add-on's take-over and release, once each: %s" % [node.modes])

	# Stopping one add-on removes exactly its handlers and its lift: the fixture's stay, counted.
	var counts := func(a) -> Array:
		var part = a._character
		var n := 0
		if part != null:
			for s in AddonCharacter.SIGNALS:
				n += (part as Object).get_signal_connection_list("_" + s).size()
		return [n, a.camera._mode_changed.get_connections().size()]
	var mine_before: Array = counts.call(api)
	other.character.footfall.connect(func(_f: String, _p: Vector3) -> void: pass)
	other.character.died.connect(func(_p: Vector3) -> void: pass)
	other.camera.mode_changed.connect(func(_m: String, _b: String) -> void: pass)
	api.character.set_lift(0.5, Vector3(0.25, 0, 0), true)
	other.character.set_lift(1.5, Vector3.ZERO, false)
	await get_tree().process_frame
	var both_lift: Vector3 = host.lift_sum()
	var other_part = other._character
	host.stop(disk)
	await get_tree().process_frame
	var mine_after: Array = counts.call(api)
	check(mine_before == mine_after and mine_after[0] > 0 and host.lift_sum() == Vector3(0.25, 0.5, 0) and host.lift_sum(true) == Vector3(0.25, 0.5, 0)
		and both_lift == Vector3(0.25, 2.0, 0) and host.watch._char_apis.has(api) and not host.watch._char_apis.has(other) and not host.watch._mode_apis.has(other)
		and not host._lifts.has(other_part) and other_part._footfall.get_connections().is_empty() and other_part._died.get_connections().is_empty(),
		"stop: the other add-on's handlers, lift and watch entries go; this one's %s handlers and lift stay: %s -> %s" % [mine_after, both_lift, host.lift_sum()])
	api.character.clear_lift()
	host.start(disk)
	# The review's case: an add-on keeps api.character at its start and connects to it only later (after
	# game_started, or when a setting is switched on). Nothing read a signal yet: unwatched.
	var late_api = disk["object"]
	var kept_part = late_api.character
	var late_hits: Array = []

	# A new game: its first armour and guns fire nothing, its later changes do.
	var model := UiModel.new()
	var hud := FakeHud.new()
	var ui := FakeCharUi.new()
	ui.model = model
	hud.ui = ui
	add_child(hud)
	fake.hud = hud
	var heard := Recorder.new()
	heard.hear(api.character, ["armor_changed", "gun_selected", "vehicle_entered", "damaged", "respawned", "died"])
	host.game_ended()
	host.game_started()
	await get_tree().process_frame
	me.update_from({"t": "me", "u": 8, "x": 0, "y": 0, "k": 1, "hp": 120, "mhp": 250, "sd": 5, "msd": 50, "v": 4})
	Bridge.message_received.emit({"t": "me", "u": 8, "x": 0, "y": 0, "k": 1, "hp": 120, "mhp": 250, "sd": 5, "msd": 50, "v": 4})
	model.handle({"t": "slots", "l": {"armor": [["power-armor", 1]]}})
	model.set_guns(2, [["pistol", "firearm-magazine", 1, 5, 10], ["submachine-gun", "", 0, 0, 0]])
	for i in 3:
		await get_tree().process_frame
	var first_values := heard.got.duplicate()
	model.handle({"t": "slots", "l": {"armor": [["heavy-armor", 1]]}})
	model.set_guns(1, [["pistol", "firearm-magazine", 1, 5, 10], ["submachine-gun", "", 0, 0, 0]])
	await get_tree().process_frame
	check(first_values.is_empty() and heard.named("armor_changed") == [["armor_changed", "heavy-armor"]] and heard.named("gun_selected") == [["gun_selected", 1, "pistol"]],
		"a new game: its first `me` (in a vehicle, hurt), armour and guns fire nothing; the next changes once each: %s then %s" % [first_values, heard.got])

	# The kept copy, connected now, after game_started: the watch starts for that add-on and its handler hears.
	var late_unwatched: bool = not host.watch._char_apis.has(late_api)
	kept_part.damaged.connect(func(h: int, sd: int) -> void: late_hits.append([h, sd]))
	check(late_unwatched and host.watch._char_apis.has(late_api),
		"a kept api.character connected after game_started: the watch starts for that add-on (unwatched before: %s)" % late_unwatched)

	# Shields: armour with shields swapped for plain armour (`sd` and `msd` stop coming), or for a smaller
	# shield, is no damage; a hit on the new, smaller shield is.
	heard.got.clear()
	var shield_me := func(k: int, sd: int, msd: int) -> void:
		var msg := {"t": "me", "u": 8, "x": 0, "y": 0, "k": k, "hp": 120, "mhp": 250, "v": 0}
		if msd > 0:
			msg["sd"] = sd
			msg["msd"] = msd
		me.update_from(msg)
		Bridge.message_received.emit(msg)
		await get_tree().process_frame
	await shield_me.call(10, 40, 50)  # shielded armour, full-ish
	await shield_me.call(11, 0, 0)  # swapped for plain armour: no `sd`
	var after_plain := heard.named("damaged").duplicate()
	await shield_me.call(12, 30, 50)  # shielded again (a rise: nothing)
	await shield_me.call(13, 20, 30)  # a smaller shield's armour: a lower maximum, a new baseline
	var after_smaller := heard.named("damaged").duplicate()
	await shield_me.call(14, 10, 30)  # a real hit on it
	await get_tree().process_frame
	check(after_plain.is_empty() and after_smaller.is_empty() and heard.named("damaged") == [["damaged", 0, 10]],
		"shields: taking shielded armour off, or swapping to a smaller shield, fires no damaged; a hit after does (0, 10): %s %s %s"
			% [after_plain, after_smaller, heard.named("damaged")])
	check(late_hits == [[0, 10]], "the kept api.character connected late hears that hit too: %s" % [late_hits])

	# Footfalls over several loops each way: right and left alternating, the right first.
	if me._rig != null:
		var anim = me._anim
		for way: float in [1.0, -1.0]:
			anim._run_phase = TAU * (0.75 if way > 0.0 else 0.25)
			anim.running = true
			var feet: Array = []
			var start: int = anim.footfalls
			var guard := 0
			while anim.footfalls < start + 8 and guard < 20000:
				var n: int = anim.footfalls
				anim.step(me._pose, DT, way * 0.05)
				if anim.footfalls > n:
					feet.append("right" if anim.right_foot else "left")
				guard += 1
			anim.running = false
			check(feet == ["right", "left", "right", "left", "right", "left", "right", "left"],
				"footfall %s over four loops: %s" % ["forwards" if way > 0.0 else "backwards", feet])

	# Back as the rest of the test had it.
	Bridge.capture = capture_before
	fake.avatar = plain
	fake.world = world_before
	fake.hud = hud_before
	rig.target = target_before
	host._push_lift()
	me.world = null
	var loose: Array = []
	for cv in w.chunks.values():
		if cv is Node:
			loose.append(cv)
	var owners: Array = [w, input]
	var i := 0
	while i < owners.size():
		for prop: Dictionary in (owners[i] as Node).get_property_list():
			var v = (owners[i] as Node).get(prop["name"])
			if v is Node and (v as Node).get_parent() == null and not loose.has(v) and v != me and v != rig and not owners.has(v):
				loose.append(v)
				owners.append(v)
		i += 1
	loose.append_array([w, input])
	for n: Node in loose:
		if is_instance_valid(n):
			n.free()
	me.queue_free()
	hud.queue_free()
	await get_tree().process_frame


## An add-on is a program, so one nobody switched is off (bundled ones as bundled.json says, --addons
## ones on); the once-only migration that keeps on what an earlier Zenith had on; --addons-default=on.
func _trust(where: Array, by_id: Dictionary) -> void:
	var fixture: Dictionary = by_id.get("test-addon", {})
	var disk: Dictionary = by_id.get("disk-addon", {})
	if fixture.is_empty() or disk.is_empty():
		check(false, "trust: the fixture add-ons are found")
		return
	check(Settings.has_value("meta", Settings.ADDONS_OFF_BY_DEFAULT), "trust: a fresh settings file is marked as having nothing to keep on")
	check(not AddonLoader.enabled(fixture) and not AddonLoader.enabled(disk) and AddonLoader.is_new(fixture)
		and not Settings.has_value("addons", "test-addon"), "trust: a new add-on is off until switched on, and nothing was saved for it")
	AddonLoader.default_on_override = 1
	check(AddonLoader.enabled(fixture), "trust: --addons-default=on puts new add-ons on, as before")
	AddonLoader.default_on_override = -1
	var given := fixture.duplicate()
	given["source"] = "command line"
	check(AddonLoader.enabled(given) and not AddonLoader.is_new(given), "trust: one given with --addons is always on")
	_write("user://trust-bundled.json", '{"test-addon": true, "disk-addon": false}')
	AddonLoader.bundled_file = "user://trust-bundled.json"
	check(AddonLoader.enabled(fixture) and not AddonLoader.enabled(disk) and not AddonLoader.is_new(fixture),
		"trust: bundled ones start as bundled.json says")
	Settings.set_value("addons", "test-addon", false)
	Settings.set_value("addons", "disk-addon", true)
	check(not AddonLoader.enabled(fixture) and AddonLoader.enabled(disk), "trust: a saved choice wins over bundled.json")
	Settings.reset_value("addons", "test-addon")
	Settings.reset_value("addons", "disk-addon")
	Settings.set_value("addons", "level-addon", true)
	check(AddonLoader.enabled(by_id["level-addon"]), "trust: a saved on stays on")
	Settings.reset_value("addons", "level-addon")

	# A settings file an earlier Zenith wrote (no mark): what it found then was on, and stays on, once.
	_write("user://trust-bundled.json", '{"disk-addon": false}')
	var old_file := "user://trust-earlier.cfg"
	_write(old_file, "[graphics]\nview_distance=10\n[addons]\nroot-zip=false\n")
	Settings.use_file(old_file)
	# A source build gives its add-ons with --addons (Terrain Elevation among them, with no bundled.json).
	_write("user://addon-test/cli/cli-addon/addon.json", JSON.stringify({"id": "cli-addon", "name": "Given", "version": "1", "api": 1, "entry": "main.gd"}))
	var with_cli := where.duplicate()
	with_cli.append([ProjectSettings.globalize_path("user://addon-test/cli/cli-addon"), "command line"])
	var found := AddonLoader.scan(with_cli)
	var ids := {}
	for m: Dictionary in found:
		ids[m["id"]] = m
	check(Settings.has_value("meta", Settings.ADDONS_OFF_BY_DEFAULT) and bool(Settings.get_value("addons", "test-addon"))
		and AddonLoader.enabled(ids["test-addon"]) and AddonLoader.enabled(ids["zip-addon"]),
		"trust: on the first start with the rule, add-ons an earlier Zenith had on are saved on")
	check(not AddonLoader.enabled(ids["root-zip"]) and not Settings.has_value("addons", "disk-addon") and not AddonLoader.enabled(ids["disk-addon"]),
		"trust: the migration leaves one switched off off, and a bundled one to bundled.json")
	check(ids.has("cli-addon") and AddonLoader.enabled(ids["cli-addon"]) and not Settings.has_value("addons", "cli-addon"),
		"trust: the migration doesn't save an --addons add-on (a download sharing the file keeps bundled.json's state)")
	# A second start, with an add-on dropped in since: not migrated, off.
	_write("user://addon-test/late/late-addon/addon.json", JSON.stringify({"id": "late-addon", "name": "Late", "version": "1", "api": 1, "entry": "main.gd"}))
	Settings.use_file(old_file)
	var later := where.duplicate()
	later.append([ProjectSettings.globalize_path("user://addon-test/late"), "test"])
	var late := {}
	for m: Dictionary in AddonLoader.scan(later):
		late[m["id"]] = m
	check(late.has("late-addon") and not AddonLoader.enabled(late["late-addon"]) and not Settings.has_value("addons", "late-addon")
		and AddonLoader.enabled(late["test-addon"]), "trust: a later start doesn't migrate an add-on dropped in since")

	# The first start under the rule given --addons (a developer's launcher): the command-line add-on is
	# on for that run only; the migration mustn't save it on, or a copy of it dropped into the add-ons
	# folder later would start without being switched on.
	_write("user://addon-test/cli/cli-trust/addon.json", JSON.stringify({"id": "cli-trust", "name": "Cli", "version": "1", "api": 1, "entry": "main.gd"}))
	var cli_file := "user://trust-earlier-cli.cfg"
	_write(cli_file, "[meta]\nmigrated=true\n")
	Settings.use_file(cli_file)
	var cli_where := [[ProjectSettings.globalize_path("user://addon-test/cli/cli-trust"), "command line"]]
	cli_where.append_array(where)
	var cli_found := {}
	for m: Dictionary in AddonLoader.scan(cli_where):
		cli_found[m["id"]] = m
	check(cli_found.has("cli-trust") and AddonLoader.enabled(cli_found["cli-trust"]) and not Settings.has_value("addons", "cli-trust")
		and Settings.has_value("addons", "test-addon") and bool(Settings.get_value("addons", "test-addon")),
		"trust: the migration saves the earlier add-ons on but not one given with --addons for this run")

	# A settings file there but unreadable (cut short, damaged) came from an earlier Zenith: migrated.
	var broken_file := "user://trust-broken.cfg"
	_write(broken_file, "[graphics\nview_distance=\"10\n[[[")
	check(ConfigFile.new().load(broken_file) != OK, "trust: the damaged settings file doesn't load")
	Settings.use_file(broken_file)
	for m: Dictionary in AddonLoader.scan(where):
		if m["id"] == "test-addon":
			check(Settings.has_value("meta", Settings.ADDONS_OFF_BY_DEFAULT) and AddonLoader.enabled(m) and bool(Settings.get_value("addons", "test-addon")),
				"trust: a settings file that can't be read isn't taken as fresh: its add-ons are kept on")

	# A fresh settings file: nothing migrated.
	Settings.use_file("user://trust-fresh.cfg")
	for m: Dictionary in AddonLoader.scan(where):
		if m["id"] == "test-addon":
			check(not AddonLoader.enabled(m) and not Settings.has_value("addons", "test-addon"), "trust: with a fresh settings file nothing is migrated")
	AddonLoader.bundled_file = ""
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://trust-bundled.json"))
	Settings.use_file(TEST_SETTINGS)


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
	await _shot_note_waits(api, host, folder)
	_shot_sizes()
	host.test_capture = Callable()
	fake.lamps = null
	fake.working_glow = null
	lamps.queue_free()
	glow.free()


## L15: a screenshot taken with the interface hidden (F11 is the Cinematic camera's api.view.hide_interface)
## keeps its "Screenshot saved" note until the interface comes back, then shows it for its 5 s with the newest
## shot's path; a note hidden by the interface waits again; --shot-note=old (shot_note_waits off) as before.
func _shot_note_waits(api, host, folder: String) -> void:
	var saved := []
	var heard := func(p: String, ok: bool) -> void: saved.append([p, ok])
	api.view.screenshot_saved.connect(heard)
	api.view.hide_interface(true)
	for i in 2:
		saved.clear()
		var path: String = api.view.screenshot(null, {"folder": folder, "timeout": 3.0})
		var t0 := Time.get_ticks_msec()
		while (api.view.screenshot_busy() or saved.is_empty()) and Time.get_ticks_msec() - t0 < 8000:
			await get_tree().process_frame
		check(not saved.is_empty() and bool(saved[0][1]) and host.interface_hidden() and host._toast != null
			and not host._toast.visible and host._toast_waiting and str(host._toast.get_meta("path", "")) == path,
			"L15: a shot taken with the interface hidden keeps its note waiting, not shown (%s)" % path)
	var newest := str(host._toast.get_meta("path", ""))
	host._toast_left = 0.0
	api.view.hide_interface(false)
	check(not host.interface_hidden() and host._toast.visible and not host._toast_waiting and host._toast_left == 5.0
		and newest.ends_with(".png") and str(host._toast.get_meta("path", "")) == newest,
		"and shows when the interface comes back, for its 5 s, the newest shot's (%s)" % newest)
	api.view.hide_interface(true)
	check(not host._toast.visible and host._toast_waiting, "a note on screen when the interface hides waits again")
	api.view.hide_interface(false)
	check(host._toast.visible and host._toast_left == 5.0, "and comes back with it")
	host._show_toast(false)
	host.shot_note_waits = false
	api.view.hide_interface(true)
	saved.clear()
	api.view.screenshot(null, {"folder": folder, "timeout": 3.0})
	var t1 := Time.get_ticks_msec()
	while (api.view.screenshot_busy() or saved.is_empty()) and Time.get_ticks_msec() - t1 < 8000:
		await get_tree().process_frame
	api.view.hide_interface(false)
	check(not saved.is_empty() and not host._toast.visible and not host._toast_waiting,
		"--shot-note=old: not shown, then or when the interface comes back")
	host.shot_note_waits = true
	api.view.screenshot_saved.disconnect(heard)


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
	# The sun's shadows as main.gd has them: the look's sun size and edge go to them.
	var shadows := SunShadows.new()
	shadows.sun = look_sun
	add_child(shadows)
	shadows.set_process(false)
	game_looks.shadows = shadows
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
		shadows.queue_free()
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
	# 0.5.1: the noon sun from the north-west (Factorio's side), not high behind the view where every side a model
	# shows the camera was lit; "Noon sun from the north-west" off gives the old one, the sun held drops it.
	var noon_new := game_looks.noon_yaw(PlanetSky.YAW_NOON)
	node.api.settings.set_value("sun_side", false, false)
	var noon_old := game_looks.noon_yaw(PlanetSky.YAW_NOON)
	node.api.settings.set_value("sun_side", true, false)
	node.api.settings.set_value("sun_moves", false, false)
	var noon_held: Dictionary = Looks.looks[node.LOOK]
	check(is_equal_approx(noon_new, node.NOON_YAW) and is_equal_approx(noon_old, PlanetSky.YAW_NOON) and not noon_held.has("sun_noon_yaw") and noon_held.has("sun_angle"),
		"cinematic shaders: the noon sun north-west by default, Zenith's with the switch off, none while held (%s, %s)" % [noon_new, noon_old])
	node.api.settings.set_value("sun_moves", true, false)
	# 0.5.2 / 0.5.3 (lighting review step 5 + tuned defaults): occlusion on indirect light by default, little on the
	# sun's (ssao_light_affect 0.15, models' and the ground's own share off through ao_direct), radius 1.7, intensity 2.45,
	# power 2.0, SSIL off; "Occlusion in sunlight too" enables direct-light occlusion with the same SSAO parameters.
	var ao_new := [game_looks.ao_direct_put, look_env.ssao_light_affect, look_env.ssao_radius, look_env.ssao_intensity, look_env.ssao_power, look_env.ssil_enabled]
	check(is_equal_approx(game_looks.ao_direct_put, 0.0) and is_equal_approx(look_env.ssao_light_affect, node.AO_SUNLIGHT)
		and is_equal_approx(look_env.ssao_radius, 1.7) and is_equal_approx(look_env.ssao_intensity, 2.45)
		and is_equal_approx(look_env.ssao_power, 2.0) and not look_env.ssil_enabled
		and _global_is(&"f3d_look_ao_direct", 0.0),
		"cinematic shaders: occlusion on indirect light by default (ao_direct, light affect, radius, intensity, power, ssil): %s" % [ao_new])
	node.api.settings.set_value("ao_sun", true, false)
	var ao_sun_vals := [game_looks.ao_direct_put, look_env.ssao_light_affect, look_env.ssao_radius, look_env.ssao_intensity, look_env.ssao_power]
	check(is_equal_approx(game_looks.ao_direct_put, 1.0) and not is_equal_approx(look_env.ssao_light_affect, node.AO_SUNLIGHT)
		and is_equal_approx(look_env.ssao_radius, 1.7) and is_equal_approx(look_env.ssao_intensity, 2.45)
		and is_equal_approx(look_env.ssao_power, 2.0),
		"cinematic shaders: Occlusion in sunlight too enables direct-light occlusion with the same SSAO parameters: %s" % [ao_sun_vals])
	node.api.settings.set_value("ao_sun", false, false)
	game_looks.use("factorio")
	check(is_equal_approx(game_looks.ao_direct_put, 1.0) and not is_equal_approx(look_env.ssao_light_affect, node.AO_SUNLIGHT),
		"cinematic shaders: the Factorio look keeps occlusion on direct light (ao_direct 1, its light affect)")
	game_looks.use(node.LOOK)
	# 0.5.0: Soft shadows are an even edge of 0.04 tiles, no sun size; shadows that soften with distance
	# (PCSS) an option, off, at a sun size of 0.5; the anti-aliasing as before (TAA off, SMAA).
	var soft_said := [shadows.sun_size, look_sun.light_angular_distance, shadows.edge]
	check(is_equal_approx(shadows.sun_size, 0.0) and is_equal_approx(look_sun.light_angular_distance, 0.0) and is_equal_approx(shadows.edge, 0.04)
		and not bool(Looks.looks[node.LOOK].get("taa", true)) and not vp.use_taa,
		"cinematic shaders: by default no sun size and an edge of 0.04 tiles, no TAA (size, angular, edge): %s" % [soft_said])
	node.api.settings.set_value("pcss", true, false)
	var pcss_said := [shadows.sun_size, look_sun.light_angular_distance, look_sun.shadow_blur, look_sun.directional_shadow_pancake_size]
	var pcss_ok := is_equal_approx(look_sun.light_angular_distance, 0.5) and is_equal_approx(look_sun.shadow_blur, 1.0) 		and is_equal_approx(look_sun.directional_shadow_pancake_size, SunShadows.pcss_pancake)
	node.api.settings.set_value("sun_size", 1.2, false)
	pcss_ok = pcss_ok and is_equal_approx(look_sun.light_angular_distance, 1.2)
	check(pcss_ok, "cinematic shaders: shadows that soften with distance give the sun its size (0.5, then 1.2), blur 1 and the short pancake: %s" % [pcss_said])
	node.api.settings.set_value("pcss", false, false)
	node.api.settings.set_value("sun_size", 0.5, false)
	node.api.settings.set_value("soft_shadows", false, false)
	check(is_equal_approx(look_sun.light_angular_distance, 0.0) and is_equal_approx(shadows.edge, SunShadows.EDGE)
		and is_equal_approx(look_sun.directional_shadow_pancake_size, SunShadows.PANCAKE),
		"cinematic shaders: Soft shadows off, Factorio's edge (0.02 tiles); the option off, no sun size")
	node.api.settings.set_value("soft_shadows", true, false)
	node.api.settings.set_value("taa", true, false)
	check(vp.use_taa, "cinematic shaders: TAA on while its look is in use, when asked for")
	game_looks.lift()
	game_looks.settle(str(Settings.get_value("graphics", "look")))
	check(vp.use_taa and not game_looks.own_clouds(), "cinematic shaders: changing a Graphics setting leaves the look's TAA and clouds as they are")
	check(Looks.looks.has(node.LOOK) and float(Looks.looks[node.LOOK].get("roughness_min", 0.0)) > 0.3,
		"cinematic shaders: its look asks for a roughness floor")
	_texture_metal(game_looks, node.LOOK)
	_pack_shading(game_looks, node.LOOK)
	_pbr_env(game_looks)
	_pbr_light(game_looks)
	_pbr_scene(game_looks)
	_model_fill(game_looks)
	_pbr_rough(game_looks, node.LOOK)
	await _light_env(node.LOOK)
	await _light_zero("factorio")
	await _light_zero(node.LOOK)
	_noon_rig()
	_fill_light()
	# 0.4.5: the clouds' pattern drawn once into a texture the grade reads, not noise on every pixel.
	var params: Dictionary = (Looks.looks[node.LOOK]["passes"][0] as Dictionary).get("params", {})
	var field: SubViewport = node.get_node_or_null("CloudField")
	var field_shader: Shader = null
	if field != null and field.get_child_count() > 0:
		field_shader = ((field.get_child(0) as ColorRect).material as ShaderMaterial).shader
	check(params.get("cloud_field") is Texture2D and is_equal_approx(float(params.get("cloud_period", 0.0)), float(node.FIELD_PERIOD))
		and field != null and field.size == Vector2i(node.FIELD_SIZE, node.FIELD_SIZE) and field.use_hdr_2d
		and field_shader != null and field_shader.get_mode() == Shader.MODE_CANVAS_ITEM,
		"cinematic shaders: its clouds read a pattern drawn once by a 16-bit viewport of its own (cloud_field.gdshader)")
	node.api.settings.set_value("clouds", 0.0, false)
	var cloudless: Dictionary = (Looks.looks[node.LOOK]["passes"][0] as Dictionary).get("params", {})
	check(not cloudless.has("cloud_field") and node.get_node_or_null("CloudField") == field,
		"cinematic shaders: with its clouds off the grade gets no pattern, and the one drawn is kept for later")
	node.api.settings.set_value("clouds", 1.0, false)
	host.set_enabled("cinematic-shaders", false)
	await get_tree().process_frame
	check(str(Settings.get_value("graphics", "look")) == "classic" and game_looks.current == "classic" and not vp.use_taa and game_looks.own_clouds(),
		"cinematic shaders: switched off, the look it replaced, the player's own TAA (off) and Zenith's clouds come back")
	check(is_equal_approx(look_sun.light_angular_distance, 0.0) and is_equal_approx(shadows.edge, SunShadows.EDGE),
		"cinematic shaders: switched off, Zenith's own shadow edge again")
	Settings.set_value("graphics", "look", look_before)
	Settings.reset_value("graphics", "look_before")
	Settings.reset_value("addons", "cinematic-shaders")
	host.queue_free()
	game_looks.queue_free()
	shadows.queue_free()
	look_sun.queue_free()


## sky.gd's sun as pure functions (add-on API 1.5): the path, the colour through the air, the swap to
## the moon with no light on, each planet's day.
## A shader global's value is `v`, where the renderer keeps them (the headless dummy one returns none).
func _global_is(param: StringName, v: float) -> bool:
	var now: Variant = RenderingServer.global_shader_parameter_get(param)
	return now == null or is_equal_approx(float(now), v)


## 0.2.2: a modeller's metallic-roughness picture's metal drawn at the share every other surface's is
## (looks.gd texture_metal): the look's key, its default, Settings' Full and the command line.
func _texture_metal(game_looks: Node, cinematic: String) -> void:
	var project_value = ProjectSettings.get_setting("shader_globals/f3d_look_texture_metal", {})
	check(project_value is Dictionary and is_equal_approx(float((project_value as Dictionary).get("value", -1.0)), 0.1),
		"texture metal: the menu and model preview draw a picture's metal at 0.1 (project.godot): %s" % [project_value])
	check(is_equal_approx(Looks.TEXTURE_METAL, 0.1) and str(Settings.DEFAULTS["graphics"].get("texture_metal")) == "paint",
		"texture metal: As paint and 0.1 by default")
	var was = Settings.get_value("graphics", "texture_metal")
	Settings.set_value("graphics", "texture_metal", "paint")
	game_looks.settle(str(Settings.get_value("graphics", "look")))
	check(is_equal_approx(game_looks.texture_metal(Looks.FACTORIO), 0.1) and is_equal_approx(game_looks.texture_metal(Looks.looks[cinematic]), 0.1),
		"texture metal: the Factorio and Cinematic looks draw a picture's metal as paint (0.1)")
	check(is_equal_approx(game_looks.texture_metal({"texture_metal": 0.4}), 0.4), "texture metal: a look's own key is used")
	game_looks.apply(0.0, 0.0, "nauvis", false)
	check(_global_is(&"f3d_look_texture_metal", 0.1),
		"texture metal: the look puts its share in the shader's global")
	Settings.set_value("graphics", "texture_metal", "full")
	game_looks.settle(str(Settings.get_value("graphics", "look")))
	check(is_equal_approx(game_looks.texture_metal({"texture_metal": 0.4}), 1.0), "texture metal: Settings' Full, as before, wins over the look's key")
	game_looks.apply(0.0, 0.0, "nauvis", false)
	check(_global_is(&"f3d_look_texture_metal", 1.0),
		"texture metal: Full puts 1 in the shader's global")
	check(is_equal_approx(Looks.texture_metal_arg(PackedStringArray(["--texture-metal=full"])), 1.0)
		and is_equal_approx(Looks.texture_metal_arg(PackedStringArray(["--x", "--texture-metal=0.3"])), 0.3)
		and is_equal_approx(Looks.texture_metal_arg(PackedStringArray(["--texture-metal=paint"])), 0.1)
		and Looks.texture_metal_arg(PackedStringArray(["--look=classic"])) < 0.0,
		"texture metal: --texture-metal=full, =paint and a number read; none without")
	game_looks._metal_arg = 0.3
	check(is_equal_approx(game_looks.texture_metal(Looks.FACTORIO), 0.3), "texture metal: the command line wins over Settings' Full")
	game_looks._metal_arg = -1.0
	Settings.set_value("graphics", "texture_metal", was)
	game_looks.settle(str(Settings.get_value("graphics", "look")))


## pbr-standard step 3: the neutral reflection of a "pbr" pack's surfaces (shaders/pbr_env.gdshaderinc) follows
## the light of the moment (ambient plus pbr_env of the sun, linear) and their metal is drawn in full; the menu and
## preview get the noon value; --pbr-env=off and --pbr-metal=0.1 give 0.2.2's drawing.
func _pbr_env(game_looks: Node) -> void:
	var project_env = ProjectSettings.get_setting("shader_globals/f3d_pbr_env", {})
	var project_metal = ProjectSettings.get_setting("shader_globals/f3d_look_pbr_metal", {})
	check(project_env is Dictionary and ((project_env as Dictionary).get("value") as Vector4).is_equal_approx(Looks.PBR_ENV_REST)
		and project_metal is Dictionary and is_equal_approx(float((project_metal as Dictionary).get("value", -1.0)), 1.0),
		"pbr env: the menu and preview reflect the noon value and draw metal in full (project.godot): %s, %s" % [project_env, project_metal])
	check(is_equal_approx(game_looks.pbr_env_k(Looks.FACTORIO), Looks.PBR_ENV) and is_equal_approx(game_looks.pbr_metal(Looks.FACTORIO), 1.0)
		and is_equal_approx(game_looks.pbr_env_k({"pbr_env": 0.2}), 0.2) and is_equal_approx(game_looks.pbr_metal({"pbr_metal": 0.5}), 0.5),
		"pbr env: k and metal share by default, a look's own keys used")
	# The command line is read once in _ready (apply() runs every frame): the cached values win over the look's.
	game_looks._pbr_env_arg = 0.7
	game_looks._pbr_metal_arg = 0.3
	check(is_equal_approx(game_looks.pbr_env_k(Looks.FACTORIO), 0.7) and is_equal_approx(game_looks.pbr_metal(Looks.FACTORIO), 0.3),
		"pbr env: --pbr-env's and --pbr-metal's values, read once at start, win over the look's")
	game_looks._pbr_env_arg = -1.0
	game_looks._pbr_metal_arg = -1.0
	game_looks.apply(0.0, 0.0, "nauvis", false)
	var got: Vector4 = game_looks.pbr_env_now(Looks.FACTORIO)
	var now: Variant = RenderingServer.global_shader_parameter_get(&"f3d_pbr_env")  # null headless
	var e: Environment = game_looks.env
	var s: DirectionalLight3D = game_looks.sun
	var want := e.ambient_light_color.srgb_to_linear() * e.ambient_light_energy + s.light_color.srgb_to_linear() * s.light_energy * Looks.PBR_ENV
	check(want.r > 0.0 and got.is_equal_approx(Vector4(want.r, want.g, want.b, 1.0)) and (now == null or now == got) and _global_is(&"f3d_look_pbr_metal", 1.0),
		"pbr env: the look puts this moment's ambient plus %.2f of the sun in the shader's global (%s, want %s)" % [Looks.PBR_ENV, got, want])
	check(Looks.pbr_env_switch(PackedStringArray()) and not Looks.pbr_env_switch(PackedStringArray(["--pbr-env=off"]))
		and Looks.pbr_env_switch(PackedStringArray(["--pbr-env=0.3"])) and is_equal_approx(Looks.pbr_env_arg(PackedStringArray(["--x", "--pbr-env=0.3"])), 0.3)
		and Looks.pbr_env_arg(PackedStringArray(["--pbr-env=off"])) < 0.0,
		"pbr env: --pbr-env=off turns it off, a number sets k")
	check(is_equal_approx(Looks.pbr_metal_arg(PackedStringArray(["--pbr-metal=0.1"])), 0.1) and is_equal_approx(Looks.pbr_metal_arg(PackedStringArray(["--pbr-metal=paint"])), 0.1)
		and is_equal_approx(Looks.pbr_metal_arg(PackedStringArray(["--pbr-metal=full"])), 1.0) and Looks.pbr_metal_arg(PackedStringArray()) < 0.0,
		"pbr env: --pbr-metal=0.1, =paint, =full read; none without")
	var shader_text := FileAccess.get_file_as_string("res://shaders/factorio_material.gdshaderinc")
	var items_text := FileAccess.get_file_as_string("res://shaders/item_body.gdshaderinc") + FileAccess.get_file_as_string("res://shaders/belt_lane_model.gdshaderinc")
	check(shader_text.contains("RADIANCE = pbr_env_radiance(") and shader_text.contains("metal = m_metal * f3d_look_pbr_metal;")
		and items_text.count("RADIANCE = pbr_env_radiance(") == 2,
		"pbr env: the model and item shaders write the neutral reflection and draw a pbr pack's metal at its own share")


## pbr-light-balance: a "pbr" pack lit by direction (shaders/pbr_env.gdshaderinc): its share of the look's fill and
## ambient (pbr_fill, pbr_ambient), the ambient and the sun's direction of the moment in the shader's globals, the
## ambient and reflection by direction; --pbr-light=flat and outside a game, flat (0.2.2's balance).
func _pbr_light(game_looks: Node) -> void:
	var project_light = ProjectSettings.get_setting("shader_globals/f3d_pbr_light", {})
	check(project_light is Dictionary and ((project_light as Dictionary).get("value") as Vector4).is_equal_approx(Looks.PBR_LIGHT_REST)
		and is_equal_approx(Looks.PBR_LIGHT_REST.x, 0.0) and ProjectSettings.has_setting("shader_globals/f3d_pbr_sky")
		and ProjectSettings.has_setting("shader_globals/f3d_pbr_sun"),
		"pbr light: the menu and preview are lit flat, as before (project.godot): %s" % [project_light])
	check(game_looks.pbr_light_shares(Looks.FACTORIO).is_equal_approx(Vector2(Looks.PBR_FILL, Looks.PBR_AMBIENT))
		and Looks.PBR_FILL < 1.0 and game_looks.pbr_light_shares({"pbr_fill": 0.5, "pbr_ambient": 0.7}).is_equal_approx(Vector2(0.5, 0.7))
		and game_looks.pbr_light_shares({"pbr_fill": 9.0, "pbr_ambient": -1.0}).is_equal_approx(Vector2(2.0, 0.0)),
		"pbr light: the fill share down by default (%.2f, ambient %.2f), a look's own keys used and held to 0-2" % [Looks.PBR_FILL, Looks.PBR_AMBIENT])
	check(Looks.pbr_light_switch(PackedStringArray()) and not Looks.pbr_light_switch(PackedStringArray(["--pbr-light=flat"]))
		and not Looks.pbr_light_switch(PackedStringArray(["--x", "--pbr-light=off"])) and Looks.pbr_light_switch(PackedStringArray(["--pbr-light=directional"])),
		"pbr light: by direction by default, --pbr-light=flat (or off) flat")
	game_looks.apply(0.0, 0.0, "nauvis", false)
	var e: Environment = game_looks.env
	var s: DirectionalLight3D = game_looks.sun
	var was_sun := s.rotation_degrees
	s.rotation_degrees = Vector3(-42.0, -112.0, 0.0)  # the Factorio look's sun
	var now: Dictionary = game_looks.pbr_light_now(Looks.FACTORIO)
	var amb := e.ambient_light_color.srgb_to_linear() * e.ambient_light_energy
	var to_sun := s.global_transform.basis.z.normalized()
	s.rotation_degrees = was_sun
	var sky: Vector4 = now[&"f3d_pbr_sky"]
	var sun_dir: Vector4 = now[&"f3d_pbr_sun"]
	check((now[&"f3d_pbr_light"] as Vector4).is_equal_approx(Vector4(1.0, Looks.PBR_FILL, Looks.PBR_AMBIENT, 1.0)) and amb.r > 0.0
		and sky.is_equal_approx(Vector4(amb.r, amb.g, amb.b, 0.0)) and Vector3(sun_dir.x, sun_dir.y, sun_dir.z).is_equal_approx(to_sun) and absf(to_sun.y - sin(deg_to_rad(42.0))) < 0.01,
		"pbr light: the look puts the shares, this moment's ambient and the way to its sun (up %.2f) in the shader's globals: %s" % [to_sun.y, now])
	game_looks._pbr_light_on = false
	var flat: Dictionary = game_looks.pbr_light_now(Looks.FACTORIO)
	game_looks._pbr_light_on = true
	check(is_equal_approx((flat[&"f3d_pbr_light"] as Vector4).x, 0.0), "pbr light: --pbr-light=flat puts flat in the global")
	# The shaders: a "pbr" surface's fill at its share, its ambient and reflection by direction; flat as before.
	var env_text := FileAccess.get_file_as_string("res://shaders/pbr_env.gdshaderinc")
	var shader_text := FileAccess.get_file_as_string("res://shaders/factorio_material.gdshaderinc")
	var items_text := FileAccess.get_file_as_string("res://shaders/item_body.gdshaderinc") + FileAccess.get_file_as_string("res://shaders/belt_lane_model.gdshaderinc")
	var fill_text := FileAccess.get_file_as_string("res://shaders/item_pbr.gdshaderinc")
	check(shader_text.contains("IRRADIANCE = pbr_irradiance(") and shader_text.contains("(mp ? pbr_fill_share() : 1.0)")
		and items_text.count("IRRADIANCE = pbr_irradiance(") == 2 and fill_text.contains("f3d_look_model_fill * pbr_fill_share()")
		and env_text.contains("return vec4(mix(up * 0.45, up, h), on);") and env_text.contains("pbr_directional() && f3d_light_env < 0.5 ? 1.0 : 0.0"),
		"pbr light: buildings, items and belt items take the fill share and the ambient by direction; flat draws as before")


## pbr-light-follows-scene: a "pbr" pack's extra light (the neutral reflection's sun and sky parts, the ambient by
## direction, the fill) follows the sun and ambient the debug menu's sliders put on the scene: at sun 0 and ambient 0
## the globals give no light; untouched, as before; --pbr-light-scene=off, the old order (the sliders didn't reach them).
func _pbr_scene(game_looks: Node) -> void:
	var e: Environment = game_looks.env
	var s: DirectionalLight3D = game_looks.sun
	var was_tune := Looks.light_tune.duplicate()
	var was_amb := e.ambient_light_energy
	var was_sun := s.light_energy
	# sky.gd lights the scene afresh each frame before apply(); nothing does here, so each apply starts from these.
	check(Looks.pbr_scene_switch(PackedStringArray()) and not Looks.pbr_scene_switch(PackedStringArray(["--x", "--pbr-light-scene=off"]))
		and Looks.pbr_scene_switch(PackedStringArray(["--pbr-light=flat"])) and Looks.pbr_light_switch(PackedStringArray(["--pbr-light-scene=off"])),
		"pbr scene: on by default, --pbr-light-scene=off turns it off (and --pbr-light is its own switch)")
	check(is_equal_approx(Looks.pbr_fill_scene(0.4, 0.4), 1.0) and is_equal_approx(Looks.pbr_fill_scene(0.4, 0.0), 0.0)
		and is_equal_approx(Looks.pbr_fill_scene(0.4, 0.2), 0.5) and is_equal_approx(Looks.pbr_fill_scene(0.4, 4.0), 2.0)
		and is_equal_approx(Looks.pbr_fill_scene(0.0, 0.3), 1.0) and is_equal_approx(Looks.pbr_fill_scene(0.0, 0.0), 1.0),
		"pbr scene: the fill's share is the ambient now over the game's (1 untouched, 0 at none, held to 2)")
	# Untouched: the fill whole and the globals the scene's light (the defaults as before).
	Looks.light_tune.clear()
	e.ambient_light_energy = was_amb
	s.light_energy = was_sun
	game_looks.apply(0.0, 0.0, "nauvis", false)
	var put: Dictionary = game_looks.pbr_put
	var light: Vector4 = put.get(&"f3d_pbr_light", Vector4.ZERO)
	var env0: Vector4 = put.get(&"f3d_pbr_env", Vector4.ZERO)
	check(is_equal_approx(light.w, 1.0) and env0.x > 0.0 and env0.is_equal_approx(game_looks.pbr_env_now(Looks.FACTORIO)),
		"pbr scene: without the sliders the fill is whole and the reflection the scene's (%s, %s)" % [light, env0])
	# Both sliders at 0: no sun lobe, no sky, no fill.
	Looks.light_tune = {"sun_energy": 0.0, "ambient_energy": 0.0}
	e.ambient_light_energy = was_amb
	s.light_energy = was_sun
	game_looks.apply(0.0, 0.0, "nauvis", false)
	put = game_looks.pbr_put
	light = put.get(&"f3d_pbr_light", Vector4.ONE)
	var env_zero: Vector4 = put.get(&"f3d_pbr_env", Vector4.ONE)
	var sky: Vector4 = put.get(&"f3d_pbr_sky", Vector4.ONE)
	check(is_zero_approx(env_zero.x) and is_zero_approx(env_zero.y) and is_zero_approx(env_zero.z) and is_equal_approx(env_zero.w, 1.0)
		and is_zero_approx(sky.x) and is_zero_approx(sky.y) and is_zero_approx(sky.z) and is_zero_approx(light.w),
		"pbr scene: sun 0 and ambient 0 put no light in the reflection, the sky or the fill (%s, %s, %s)" % [env_zero, sky, light])
	# Ambient only at 0: the reflection is the sun's lobe alone, the fill gone.
	Looks.light_tune = {"ambient_energy": 0.0}
	e.ambient_light_energy = was_amb
	s.light_energy = was_sun
	game_looks.apply(0.0, 0.0, "nauvis", false)
	put = game_looks.pbr_put
	var lit := s.light_color.srgb_to_linear() * s.light_energy * Looks.PBR_ENV
	check((put[&"f3d_pbr_env"] as Vector4).is_equal_approx(Vector4(lit.r, lit.g, lit.b, 1.0)) and lit.r > 0.0 and is_zero_approx((put[&"f3d_pbr_light"] as Vector4).w),
		"pbr scene: ambient 0 leaves the sun's part of the reflection and no fill (%s)" % [put[&"f3d_pbr_env"]])
	# The switch off: the globals are read before the sliders, as before (the sun and ambient the game set).
	Looks.light_tune = {"sun_energy": 0.0, "ambient_energy": 0.0}
	game_looks._pbr_scene_on = false
	e.ambient_light_energy = was_amb
	s.light_energy = was_sun
	game_looks.apply(0.0, 0.0, "nauvis", false)
	put = game_looks.pbr_put
	game_looks._pbr_scene_on = true
	check((put[&"f3d_pbr_env"] as Vector4).x > 0.0 and is_equal_approx((put[&"f3d_pbr_light"] as Vector4).w, 1.0),
		"pbr scene: --pbr-light-scene=off reads the light before the sliders, as before (%s)" % [put[&"f3d_pbr_env"]])
	var env_text := FileAccess.get_file_as_string("res://shaders/pbr_env.gdshaderinc")
	check(not env_text.contains("* clamp(f3d_pbr_light.w, 0.0, 2.0);"),
		"pbr scene: the shaders' fill share leaves the scene's ambient to f3d_look_model_fill (counted once)")
	Looks.light_tune = was_tune
	e.ambient_light_energy = was_amb
	s.light_energy = was_sun


## light-remove-fill (owner: "remove that default light"): the camera fill on every model, tree, item and far chunk is
## off by default; --model-fill=on brings the look's back, the debug menu's Camera fill slider sets it live, and
## whatever fill there is follows the ambient the sliders set. The sky's own colour follows the sun and ambient sliders.
## lighting-fixes step 1: the lighting environment in the sky's cubemap. A game's looks node with a sky: Godot's ambient
## and reflections held on the sky (source SKY, contribution 1) while the look's own values come back when it goes;
## the cubemap's upper half the ambient, its lower half the ground's albedo times the sun on flat ground plus the
## ambient; a look's sky ambient (Cinematic at twilight) its share of the drawn sky; "pbr" packs' own terms off
## (f3d_light_env 1); --light-env=shader leaves all as before.
## lighting-fixes step 6: the menu's backdrop and the Model packs preview are lit by Looks.noon_rig, which is what a
## game puts at noon on Nauvis under the Factorio look (sky.gd, then looks.gd apply and put_light_env), and
## put_noon_rig lights an environment from it as put_light_env does; --preview-light=studio keeps the old lights.
func _noon_rig() -> void:
	check(Looks.preview_light_switch(PackedStringArray()) and not Looks.preview_light_switch(PackedStringArray(["--preview-light=studio"])),
		"noon rig: the game's light in the preview and menu by default, --preview-light=studio the old")
	var e := Environment.new()
	var sky_node := PlanetSky.new()
	add_child(sky_node)
	var sky := Sky.new()
	sky.sky_material = sky_node.sky_material
	e.sky = sky
	e.background_mode = Environment.BG_SKY
	var s := DirectionalLight3D.new()
	add_child(s)
	var was_active: Node = Looks.active
	var lk := Looks.new()
	add_child(lk)
	lk.attach(e, s)
	lk.use("factorio", true)
	sky_node.apply(e, s, 0.0, 0.0, 0.016, false)
	lk.apply(0.0, 0.0, "nauvis", false, sky_node.state)
	var rig := Looks.noon_rig()
	var put: Dictionary = lk.env_put
	var game := [s.light_energy, s.rotation_degrees, s.light_color, s.light_specular, e.ambient_light_color, e.ambient_light_energy,
		e.tonemap_mode, e.tonemap_exposure, put.get("sky"), put.get("ground")]
	check(is_equal_approx(s.light_energy, float(rig["sun_energy"])) and s.rotation_degrees.is_equal_approx(rig["sun_rotation"])
		and s.light_color.is_equal_approx(rig["sun_color"]) and is_equal_approx(s.light_specular, float(rig["sun_specular"]))
		and e.ambient_light_color.is_equal_approx(rig["ambient_color"]) and is_equal_approx(e.ambient_light_energy, float(rig["ambient_energy"]))
		and e.tonemap_mode == int(rig["tonemap"]) and is_equal_approx(e.tonemap_exposure, float(rig["exposure"]))
		and put.get("sky") is Vector3 and (put["sky"] as Vector3).is_equal_approx(rig["env_sky"])
		and (put["ground"] as Vector3).is_equal_approx(rig["env_ground"]),
		"noon rig: the preview's and menu's light is the game's at noon on Nauvis (game %s, rig %s)" % [game, rig])
	var e2 := Environment.new()
	e2.background_mode = Environment.BG_COLOR
	var s2 := DirectionalLight3D.new()
	Looks.put_noon_rig(e2, s2, rig)
	var m2 := e2.sky.sky_material as ShaderMaterial if e2.sky != null else null
	check(m2 != null and m2.shader == PlanetSky.SKY_SHADER and float(m2.get_shader_parameter("env_on")) > 0.5
		and (m2.get_shader_parameter("env_sky") as Vector3).is_equal_approx(rig["env_sky"])
		and (m2.get_shader_parameter("env_ground") as Vector3).is_equal_approx(rig["env_ground"])
		and e2.ambient_light_source == Environment.AMBIENT_SOURCE_SKY and is_equal_approx(e2.ambient_light_sky_contribution, 1.0)
		and e2.reflected_light_source == Environment.REFLECTION_SOURCE_SKY and e2.sky.radiance_size == Looks.LIGHT_ENV_RADIANCE
		and e2.background_mode == Environment.BG_COLOR and s2.rotation_degrees.is_equal_approx(rig["sun_rotation"])
		and is_equal_approx(s2.light_energy, float(rig["sun_energy"])) and e2.tonemap_mode == Environment.TONE_MAPPER_LINEAR,
		"noon rig: put on an environment outside a game, its sky's cubemap is the lighting environment (the background its own)")
	s2.free()
	lk.queue_free()
	Looks.active = was_active
	s.queue_free()
	sky_node.queue_free()


## lighting-fixes step 3: the Factorio look's fill light, a sun of its own with no shadow on everything but the ground
## (Visuals.GROUND_LAYER: terrain, far chunks, flat decoratives), faded out by night; none in a look without the key;
## --fill-light=off or a number.
func _fill_light() -> void:
	check(is_equal_approx(Looks.fill_light_arg(PackedStringArray()), -1.0) and is_equal_approx(Looks.fill_light_arg(PackedStringArray(["--fill-light=off"])), 0.0)
		and is_equal_approx(Looks.fill_light_arg(PackedStringArray(["--fill-light=0.2"])), 0.2),
		"fill light: the look's by default, --fill-light=off none, a number that energy")
	var e := Environment.new()
	var s := DirectionalLight3D.new()
	add_child(s)
	var was_active: Node = Looks.active
	var lk := Looks.new()
	add_child(lk)
	lk.attach(e, s)
	lk.use("factorio", true)
	s.light_energy = 1.1
	lk.apply(0.0, 0.0, "nauvis", false)
	var f: DirectionalLight3D = lk.fill_light
	var want := float(Looks.FACTORIO.get("fill_light", 0.0))
	check(f != null and f.visible and is_equal_approx(f.light_energy, want) and want > 0.0 and not f.shadow_enabled
		and (f.light_cull_mask & Visuals.GROUND_LAYER) == 0 and (f.light_cull_mask & 1) != 0
		and is_equal_approx(f.global_rotation_degrees.x, -Looks.FILL_PITCH),
		"fill light: the Factorio look's by day (%.2f), no shadow, everything but the ground, from %.0f degrees up" % [want, Looks.FILL_PITCH])
	lk.apply(0.0, 1.0, "nauvis", false)
	check(not f.visible and is_equal_approx(lk.fill_light_put, 0.0), "fill light: none at night")
	lk.apply(0.0, 0.0, "nauvis", true)
	check(not f.visible, "fill light: none in space")
	lk.use("classic", true)
	lk.apply(0.0, 0.0, "nauvis", false)
	check(not f.visible, "fill light: none in a look without one (Classic)")
	lk._fill_light_arg = 0.0
	lk.use("factorio", true)
	lk.apply(0.0, 0.0, "nauvis", false)
	check(not f.visible, "fill light: none with --fill-light=off")
	lk.queue_free()
	Looks.active = was_active
	s.queue_free()


## The debug menu's Sun energy 0 and Ambient energy 0 leave nothing lit but lamps and emission, by day, at dusk and
## at night with night vision on, under look `look_id`: no ambient or sun, no fill light, no environment in the sky's
## cubemap, no fog light, the drawn sky and the look's passes (Cinematic's clouds) dark; all back when let go.
func _light_zero(look_id: String) -> void:
	var e := Environment.new()
	var sky_node := PlanetSky.new()
	add_child(sky_node)
	var sky := Sky.new()
	sky.sky_material = sky_node.sky_material
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	e.sky = sky
	e.background_mode = Environment.BG_SKY
	var s := DirectionalLight3D.new()
	add_child(s)
	var was_active: Node = Looks.active
	var was_tune := Looks.light_tune
	var lk := Looks.new()
	add_child(lk)
	lk.attach(e, s)
	lk.use(look_id, true)
	var m := sky_node.sky_material
	var state := {"twilight": 0.0, "height": 0.8, "morning": false, "direction": Vector3(0.3, 0.8, 0.5),
		"color": Color(1, 0.95, 0.9), "fog": Color(0.7, 0.75, 0.85)}
	var tick := func(night: float, twilight: float) -> void:
		e.ambient_light_energy = 0.6
		e.ambient_light_color = Color(0.75, 0.78, 0.82)
		s.light_energy = 1.1
		s.light_color = Color(1, 0.95, 0.9)
		state["twilight"] = twilight
		lk.apply(0.0, night, "nauvis", false, state)
	tick.call(0.0, 0.0)
	var fog0 := e.fog_light_energy
	var fill0 := lk.fill_light_put
	for when: Array in [[0.0, 0.0, 0.0], [0.3, 1.0, 0.0], [1.0, 0.0, 1.0]]:
		Looks.light_tune = {"sun_energy": 0.0, "ambient_energy": 0.0}
		lk.night_vision = float(when[2])
		tick.call(float(when[0]), float(when[1]))
		var put: Dictionary = lk.env_put
		var dark := put.is_empty() or ((put["sky"] as Vector3).is_zero_approx() and (put["ground"] as Vector3).is_zero_approx()
			and (m.get_shader_parameter("env_glow") as Vector3).is_zero_approx())
		var passes_dark := true
		for n: MeshInstance3D in lk._pass_nodes:
			var v = (n.material_override as ShaderMaterial).get_shader_parameter("look_scene_light")
			passes_dark = passes_dark and v is Vector2 and (v as Vector2).is_zero_approx()
		check(is_zero_approx(e.ambient_light_energy) and is_zero_approx(s.light_energy) and is_zero_approx(lk.fill_light_put)
			and not lk.fill_light.visible and dark and is_zero_approx(e.fog_light_energy) and is_zero_approx(e.fog_sun_scatter)
			and lk.sky_put.is_zero_approx() and lk.scene_now.is_zero_approx() and passes_dark,
			"light zero (%s, night %.1f, twilight %.0f, night vision %.0f): sun 0 and ambient 0 light nothing (ambient %.2f, fill %.2f, env %s, fog %.2f, sky %s)"
			% [look_id, when[0], when[1], when[2], e.ambient_light_energy, lk.fill_light_put, put, e.fog_light_energy, lk.sky_put])
	Looks.light_tune = {}
	lk.night_vision = 0.0
	tick.call(0.0, 0.0)
	check(is_equal_approx(e.fog_light_energy, fog0) and is_equal_approx(lk.fill_light_put, fill0) and lk.scene_now == Vector2.ONE
		and lk.sky_put == Vector2.ONE, "light zero (%s): let go, the fog's light (%.2f) and the fill (%.2f) are the look's again" % [look_id, fog0, fill0])
	Looks.light_tune = was_tune
	lk.queue_free()
	Looks.active = was_active
	s.queue_free()
	sky_node.queue_free()
	await get_tree().process_frame


func _light_env(look_id: String) -> void:
	check(Looks.light_env_switch(PackedStringArray()) and not Looks.light_env_switch(PackedStringArray(["--light-env=shader"]))
		and Looks.light_env_switch(PackedStringArray(["--light-env=old", "--light-env=sky"])),
		"light env: the sky's cubemap by default, --light-env=shader the old way")
	var e := Environment.new()
	var sky_node := PlanetSky.new()
	add_child(sky_node)
	var sky := Sky.new()
	sky.sky_material = sky_node.sky_material
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	e.sky = sky
	e.background_mode = Environment.BG_SKY
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.75, 0.78, 0.82)
	var s := DirectionalLight3D.new()
	add_child(s)
	var was_active: Node = Looks.active
	var lk := Looks.new()
	add_child(lk)
	lk.attach(e, s)
	lk.use("factorio", true)
	var m := sky_node.sky_material
	var tick := func(night: float) -> void:
		e.ambient_light_energy = 0.6
		e.ambient_light_color = Color(0.75, 0.78, 0.82)
		s.light_energy = 1.1
		lk.apply(0.0, night, "nauvis", false)
	tick.call(0.0)
	var lit_amb := e.ambient_light_energy
	tick.call(1.0)
	var night_amb := e.ambient_light_energy
	tick.call(0.0)
	check(is_equal_approx(lit_amb, 0.6 * float(Looks.FACTORIO["ambient_energy_lit"])) and is_equal_approx(night_amb, 0.6 * float(Looks.FACTORIO["ambient_energy"]))
		and float(Looks.FACTORIO["ambient_energy_lit"]) > float(Looks.FACTORIO["ambient_energy"]) * 1.8,
		"light env: the Factorio look's daylight ambient raised for its sun-to-shade ratio (%.3f), nights as before (%.3f)" % [lit_amb, night_amb])
	var amb := e.ambient_light_color.srgb_to_linear() * e.ambient_light_energy
	var to_sun := s.global_transform.basis.z.normalized()
	var sun_flat := s.light_color.srgb_to_linear() * s.light_energy * to_sun.y
	var g := Looks.LIGHT_ENV_GROUND
	var want_ground := Vector3(g.r * (sun_flat.r + amb.r), g.g * (sun_flat.g + amb.g), g.b * (sun_flat.b + amb.b))
	var put: Dictionary = lk.env_put
	check(sky.radiance_size == Looks.LIGHT_ENV_RADIANCE and e.ambient_light_source == Environment.AMBIENT_SOURCE_SKY
		and is_equal_approx(e.ambient_light_sky_contribution, 1.0) and e.reflected_light_source == Environment.REFLECTION_SOURCE_SKY
		and float(m.get_shader_parameter("env_on")) > 0.5,
		"light env: in a game Godot's ambient and reflections come from the sky's cubemap (size %d), drawn as the environment" % sky.radiance_size)
	check(put.has("sky") and (put["sky"] as Vector3).is_equal_approx(Vector3(amb.r, amb.g, amb.b)) and (put["ground"] as Vector3).is_equal_approx(want_ground)
		and (put["ground"] as Vector3).x > (put["sky"] as Vector3).x and is_zero_approx(float(put["sky_mix"])),
		"light env: upper half the ambient, lower half the ground lit by the sun and the ambient, no drawn sky in the Factorio look: %s" % [put])
	# Night vision (main.gd's night_vision) lifts the ambient inside apply(), so every surface sees it; a second put in
	# a frame keeps the look's drawn-sky share.
	lk.night_vision = 1.0
	tick.call(0.0)
	lk.night_vision = 0.0
	check(((lk.env_put["sky"] as Vector3).x > (put["sky"] as Vector3).x * 2.0), "light env: night vision's lifted ambient in the environment")
	lk.put_light_env(false)
	check(is_zero_approx(float(lk.env_put["sky_mix"])) and is_zero_approx(float(m.get_shader_parameter("env_sky_mix"))),
		"light env: a second put in a frame (night vision) keeps the look's drawn-sky share (%s), not the forced one" % [lk.env_put["sky_mix"]])
	# The look's own sources come back when it goes, and when a look asks for sky ambient that is its drawn-sky share.
	lk.use(look_id, true)
	tick.call(0.0)
	var cin_mix := float(lk.env_put.get("sky_mix", -1.0))
	e.background_energy_multiplier = 0.5
	e.ambient_light_sky_contribution = 0.5  # as Cinematic's twilight blends it
	lk._env_held["ambient_light_source"] = Environment.AMBIENT_SOURCE_SKY
	lk._env_held["ambient_light_sky_contribution"] = 0.5
	lk.put_light_env(false)
	lk.put_light_env(false)  # twice, as with night vision: the share stays
	check(is_zero_approx(cin_mix) and is_equal_approx(float(lk.env_put["sky_mix"]), 0.5) and is_equal_approx(float(m.get_shader_parameter("env_gain")), 0.5)
		and (m.get_shader_parameter("env_sky") as Vector3).is_equal_approx((lk.env_put["sky"] as Vector3) * 2.0),
		"light env: %s's sky ambient at twilight is its share of the drawn sky (%.2f), the background's energy undone (%s)" % [look_id, float(lk.env_put["sky_mix"]), m.get_shader_parameter("env_gain")])
	e.background_energy_multiplier = 1.0
	lk.lift()
	check(e.ambient_light_source == Environment.AMBIENT_SOURCE_COLOR and lk._env_held.is_empty(),
		"light env: lifted, the environment's own ambient source is back (%d)" % e.ambient_light_source)
	lk.settle("factorio")
	lk.put_light_env(true)
	check(((lk.env_put["ground"] as Vector3) - (lk.env_put["sky"] as Vector3) * 0.5).length() < 1e-4,
		"light env: in space no ground, the lower half half the ambient")
	lk._light_env_sky = false
	lk._env_release()
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	tick.call(0.0)
	check(e.ambient_light_source == Environment.AMBIENT_SOURCE_COLOR and float(m.get_shader_parameter("env_on")) < 0.5 and lk.env_put.is_empty()
		and is_equal_approx(e.ambient_light_energy, 0.6 * float(Looks.FACTORIO["ambient_energy"])),
		"light env: --light-env=shader leaves the constant ambient, the drawn sky and the look's 0.2.2 ambient (%.3f)" % e.ambient_light_energy)
	remove_child(lk)
	lk.free()
	Looks.active = was_active
	s.queue_free()
	sky_node.queue_free()
	await get_tree().process_frame
	var env_text := FileAccess.get_file_as_string("res://shaders/pbr_env.gdshaderinc")
	var sky_text := FileAccess.get_file_as_string("res://shaders/planet_sky.gdshader")
	check(env_text.contains("step(f3d_light_env, 0.5)") and env_text.contains("f3d_light_env < 0.5") and sky_text.contains("AT_CUBEMAP_PASS && env_on > 0.5")
		and sky_text.contains("AT_CUBEMAP_PASS && env_on > 0.5 && env_sky_mix <= 0.0001")
		and Looks.LIGHT_ENV_RADIANCE == Sky.RADIANCE_SIZE_32
		and ProjectSettings.has_setting("shader_globals/f3d_light_env"),
		"light env: pbr packs' own RADIANCE and IRRADIANCE off while the sky lights them; the sky draws the environment in its cubemap pass (size 32 + daytime early-out)")
	# put_light_env skips redundant uniform writes when values are unchanged, and writes when they change.
	var e3 := Environment.new()
	var sky3 := Sky.new()
	var mat3 := ShaderMaterial.new()
	mat3.shader = PlanetSky.SKY_SHADER
	sky3.sky_material = mat3
	e3.sky = sky3
	e3.ambient_light_color = Color(0.75, 0.78, 0.82)
	e3.ambient_light_energy = 0.6
	var s3 := DirectionalLight3D.new()
	add_child(s3)
	var lk3 := Looks.new()
	add_child(lk3)
	lk3.attach(e3, s3)
	lk3.use("factorio", true)
	lk3.put_light_env(false)
	var sent_sky := Vector3(mat3.get_shader_parameter("env_sky"))
	var sentinel := Vector3(99.0, 99.0, 99.0)
	mat3.set_shader_parameter("env_sky", sentinel)
	lk3.put_light_env(false)  # unchanged inputs: dirty-check skips overwriting mat3
	var kept_sentinel := Vector3(mat3.get_shader_parameter("env_sky")).is_equal_approx(sentinel)
	e3.ambient_light_energy = 1.2
	lk3.put_light_env(false)  # changed input: dirty-check writes new env_sky
	var updated_sky := Vector3(mat3.get_shader_parameter("env_sky"))
	check(kept_sentinel and updated_sky.x > sent_sky.x * 1.5,
		"light env: dirty-check skips unchanged sky uniforms and updates changed ones (kept %s, was %s -> %s)" % [kept_sentinel, sent_sky, updated_sky])
	remove_child(lk3)
	lk3.free()
	s3.queue_free()
	Looks.active = was_active
	# Looks.shader_for returns the base shader by default, and compiles #define SHADER_LIGHT_ENV under --light-env=shader.
	var ModelLib := preload("res://scripts/world/model_library.gd")
	var base_sh: Shader = ModelLib.FactorioShader
	var def_sh: Shader = Looks.shader_for(base_sh)
	var was_sle := Looks._shader_light_env
	Looks._shader_light_env = true
	Looks._env_shaders.clear()
	var env_sh: Shader = Looks.shader_for(base_sh)
	var env_mat := ShaderMaterial.new()
	env_mat.shader = env_sh
	var inc_pos := env_sh.code.find("#include ")
	var def_pos := env_sh.code.find("#define SHADER_LIGHT_ENV")
	Looks._shader_light_env = was_sle
	Looks._env_shaders.clear()
	check(def_sh == base_sh and env_sh != base_sh and def_pos >= 0 and inc_pos > def_pos,
		"light env: shader_for compiles out SHADER_LIGHT_ENV by default and injects it before #include when enabled")


## lighting-fixes step 4: the look's roughness floor on built-in packs and icon items only ("pbr" packs and modellers'
## items keep their files' roughness; --pbr-rough=floor as 0.2.2), the sun's full highlight in Cinematic, half in the
## Factorio look (--sun-specular wins).
func _pbr_rough(game_looks: Node, look_id: String) -> void:
	check(not Looks.pbr_rough_floor_switch(PackedStringArray()) and Looks.pbr_rough_floor_switch(PackedStringArray(["--pbr-rough=floor"]))
		and not Looks.pbr_rough_floor_switch(PackedStringArray(["--pbr-rough=floor", "--pbr-rough=own"])),
		"pbr rough: pbr packs keep their roughness by default, --pbr-rough=floor the look's floor on them too")
	check(is_equal_approx(Looks.sun_specular_arg(PackedStringArray()), -1.0) and is_equal_approx(Looks.sun_specular_arg(PackedStringArray(["--sun-specular=0.25"])), 0.25),
		"pbr rough: --sun-specular=<n> read, none by default")
	var was_look: String = game_looks.current
	var was_floor: bool = game_looks._pbr_rough_floor
	var s: DirectionalLight3D = game_looks.sun
	game_looks.use(look_id, true)
	game_looks.apply(0.0, 0.0, "nauvis", false)
	var floor_min := float(Looks.looks[look_id].get("roughness_min", 0.0))
	check(floor_min > 0.3 and game_looks.rough_put.is_equal_approx(Vector2(floor_min, 0.0)) and is_equal_approx(s.light_specular, 1.0),
		"pbr rough: under %s the floor on built-in packs only (%s), the sun's full highlight (%.2f)" % [look_id, game_looks.rough_put, s.light_specular])
	game_looks._pbr_rough_floor = true
	game_looks.apply(0.0, 0.0, "nauvis", false)
	check(game_looks.rough_put.is_equal_approx(Vector2(floor_min, floor_min)), "pbr rough: --pbr-rough=floor puts it on pbr packs too (%s)" % [game_looks.rough_put])
	game_looks._pbr_rough_floor = was_floor
	game_looks.use("factorio", true)
	game_looks.apply(0.0, 0.0, "nauvis", false)
	check(is_equal_approx(s.light_specular, 0.5), "pbr rough: the Factorio look's sun highlight at half (%.2f)" % s.light_specular)
	game_looks._sun_specular_arg = 0.25
	game_looks.apply(0.0, 0.0, "nauvis", false)
	check(is_equal_approx(s.light_specular, 0.25), "pbr rough: --sun-specular wins over the look (%.2f)" % s.light_specular)
	game_looks._sun_specular_arg = -1.0
	game_looks.use(was_look, true)
	var mat := FileAccess.get_file_as_string("res://shaders/factorio_material.gdshaderinc")
	var items := FileAccess.get_file_as_string("res://shaders/item_pbr.gdshaderinc") + FileAccess.get_file_as_string("res://shaders/item_body.gdshaderinc")
	check(mat.contains("mp ? f3d_look_roughness_min_pbr : f3d_look_roughness_min") and items.contains("max(rm.x, f3d_look_roughness_min_pbr)")
		and items.contains("max(roughness, f3d_look_roughness_min)"),
		"pbr rough: buildings and items take the same floors (pbr's own, built-in's the look's)")


func _model_fill(game_looks: Node) -> void:
	var e: Environment = game_looks.env
	var s: DirectionalLight3D = game_looks.sun
	var was_tune := Looks.light_tune.duplicate()
	var was_pbr := Looks.pbr_tune.duplicate()
	var was_arg: float = game_looks._model_fill_arg
	var was_amb := e.ambient_light_energy
	var was_sun := s.light_energy
	var was_look: String = game_looks.current
	# Only L's model_fill is read here (apply() looks the look up by name): the Factorio look's 1.1.
	game_looks.current = "factorio"
	var look_fill := float(Looks.FACTORIO.get("model_fill", 0.0))
	check(is_zero_approx(Looks.model_fill_arg(PackedStringArray())) and is_equal_approx(Looks.model_fill_arg(PackedStringArray(["--model-fill=on"])), -1.0)
		and is_zero_approx(Looks.model_fill_arg(PackedStringArray(["--model-fill=on", "--model-fill=off"])))
		and is_equal_approx(Looks.model_fill_arg(PackedStringArray(["--model-fill=0.5"])), 0.5),
		"model fill: off by default, =on the look's (-1), =off none, a number that fill")
	var run := func(tune: Dictionary, fill_tune: Dictionary, arg: float, night: float) -> void:
		Looks.light_tune = tune
		Looks.pbr_tune = fill_tune
		game_looks._model_fill_arg = arg
		e.ambient_light_energy = was_amb
		s.light_energy = was_sun
		game_looks.apply(0.0, night, "nauvis", false)
	run.call({}, {}, 0.0, 0.0)
	var game_amb := e.ambient_light_energy
	check(is_zero_approx(game_looks.fill_put) and game_looks.sky_put.is_equal_approx(Vector2.ONE),
		"model fill: none by default, the sky untouched (%s, %s)" % [game_looks.fill_put, game_looks.sky_put])
	run.call({}, {}, -1.0, 0.0)
	var on_noon: float = game_looks.fill_put
	run.call({}, {}, -1.0, 0.5)
	check(look_fill > 0.0 and is_equal_approx(on_noon, look_fill) and is_equal_approx(game_looks.fill_put, look_fill * 0.5),
		"model fill: --model-fill=on the look's own %.2f, faded by night as before (%.3f, %.3f)" % [look_fill, on_noon, game_looks.fill_put])
	run.call({"sun_energy": 0.0, "ambient_energy": 0.0}, {}, -1.0, 0.0)
	check(is_zero_approx(game_looks.fill_put) and game_looks.sky_put.is_zero_approx(),
		"model fill: sun 0 and ambient 0 leave no fill even with =on, and a black sky (%s, %s)" % [game_looks.fill_put, game_looks.sky_put])
	run.call({}, {"model_fill": 0.7}, 0.0, 0.0)
	var slider: float = game_looks.fill_put
	run.call({"ambient_energy": game_amb * 0.5}, {"model_fill": 0.7}, 0.0, 0.0)
	check(is_equal_approx(slider, 0.7) and is_equal_approx(game_looks.fill_put, 0.35) and is_equal_approx(game_looks.sky_put.x, 0.5)
		and is_equal_approx(game_looks.sky_put.y, 1.0),
		"model fill: the Camera fill slider sets it from 0, halved with the ambient (%.3f, %.3f, %s)" % [slider, game_looks.fill_put, game_looks.sky_put])
	var sky_text := FileAccess.get_file_as_string("res://shaders/planet_sky.gdshader")
	check(sky_text.contains("col *= scene_light.x;") and sky_text.contains("sun_strength * scene_light.y"),
		"model fill: the sky's colour and sun follow the sliders (planet_sky scene_light)")
	var keys := []
	for l: Array in load("res://scripts/ui/factorio/debug_menu.gd").LIGHT:
		keys.append(l[0])
	check(keys.has("model_fill") and keys.has("pbr_fill"), "model fill: the Lighting tab has the Camera fill slider and keeps Fill share")
	Looks.light_tune = was_tune
	Looks.pbr_tune = was_pbr
	game_looks._model_fill_arg = was_arg
	game_looks.current = was_look
	e.ambient_light_energy = was_amb
	s.light_energy = was_sun
	game_looks.apply(0.0, 0.0, "nauvis", false)


## 0.2.2: packs' own shading (pack.json "shading": "pbr", model_packs.gd shading()): a "pbr" pack's
## pictures lit by the look's texture_light ((1, 1) by default, Cinematic too), on unless Settings > Graphics >
## Advanced > Packs' own shading says Factorio's everywhere or --pack-shading=factorio, which wins.
func _pack_shading(game_looks: Node, cinematic: String) -> void:
	var project_light = ProjectSettings.get_setting("shader_globals/f3d_look_texture_light", {})
	var project_on = ProjectSettings.get_setting("shader_globals/f3d_pack_shading", {})
	check(project_light is Dictionary and (project_light as Dictionary).get("value") == Vector2(1, 1)
		and project_on is Dictionary and is_equal_approx(float((project_on as Dictionary).get("value", -1.0)), 1.0),
		"pack shading: the menu and model preview draw a pbr pack as it says, tops and sides at 1 (project.godot): %s, %s" % [project_light, project_on])
	check(Looks.TEXTURE_LIGHT == Vector2(1, 1) and str(Settings.DEFAULTS["graphics"].get("pack_shading")) == "pack",
		"pack shading: as each pack says, and (1, 1), by default")
	var was = Settings.get_value("graphics", "pack_shading")
	Settings.set_value("graphics", "pack_shading", "pack")
	game_looks.settle(str(Settings.get_value("graphics", "look")))
	check(Looks.packs_shade and game_looks.texture_light(Looks.FACTORIO) == Vector2(1, 1)
		and game_looks.texture_light(Looks.looks[cinematic]) == Vector2(1, 1),
		"pack shading: on, and the Factorio and Cinematic looks light a pbr pack's tops as Godot does (1, 1)")
	check(game_looks.texture_light({"texture_light": Vector2(0.95, 0.8)}) == Vector2(0.95, 0.8)
		and game_looks.texture_light({"texture_light": "x"}) == Vector2(1, 1),
		"pack shading: a look's own texture_light is used (a wrong type left out)")
	game_looks.apply(0.0, 0.0, "nauvis", false)
	check(_global_is(&"f3d_pack_shading", 1.0) and Looks.light_now == Vector2(1, 1), "pack shading: on in the shader's global")
	Settings.set_value("graphics", "pack_shading", "factorio")
	game_looks.settle(str(Settings.get_value("graphics", "look")))
	check(not Looks.packs_shade and _global_is(&"f3d_pack_shading", 0.0),
		"pack shading: Settings' Factorio's everywhere turns it off through settle()")
	check(Looks.pack_shading_arg(PackedStringArray(["--pack-shading=factorio"])) == "factorio"
		and Looks.pack_shading_arg(PackedStringArray(["--x", "--pack-shading=pack"])) == "pack"
		and Looks.pack_shading_arg(PackedStringArray(["--look=classic"])) == "",
		"pack shading: --pack-shading=factorio and =pack read; none without")
	check(Settings.ssao_arg(PackedStringArray(["--ssao=off"])) == "off" and Settings.ssao_arg(PackedStringArray(["--x", "--ssao=on"])) == "on"
		and Settings.ssao_arg(PackedStringArray(["--look=classic"])) == "",
		"ssao: --ssao=off and =on read; none without")
	check(Looks.pack_shading(PackedStringArray(["--pack-shading=pack"])) and not Looks.pack_shading(PackedStringArray()),
		"pack shading: the command line wins over Settings' Factorio's")
	Settings.set_value("graphics", "pack_shading", "pack")
	check(not Looks.pack_shading(PackedStringArray(["--pack-shading=factorio"])) and Looks.pack_shading(PackedStringArray()),
		"pack shading: --pack-shading=factorio wins over Settings' default")
	# In the menu, before any game (no Looks node to settle it): main.gd's settings listener puts the setting
	# in the global, so the model preview follows it (it stayed at project.godot's 1 till the first game).
	var menu: Node = (load("res://scripts/main.gd") as GDScript).new()
	var heard := Callable(menu, "_on_setting_changed")
	Settings.listen(heard)
	Looks.packs_shade = true
	RenderingServer.global_shader_parameter_set(&"f3d_pack_shading", 1.0)
	Settings.set_value("graphics", "pack_shading", "factorio")
	check(menu.get("_game") == null and not Looks.packs_shade and _global_is(&"f3d_pack_shading", 0.0),
		"pack shading: Factorio's everywhere set in the menu (no game, no Looks) puts f3d_pack_shading at 0")
	Settings.set_value("graphics", "pack_shading", "pack")
	check(Looks.packs_shade and _global_is(&"f3d_pack_shading", 1.0), "pack shading: and back on in the menu")
	Settings.unlisten(heard)
	menu.free()
	Settings.set_value("graphics", "pack_shading", was)
	game_looks.settle(str(Settings.get_value("graphics", "look")))


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
	# A look's noon in the north-west (sun_noon_yaw, cinematic-pbr-flat): the same rise and set, each the short way
	# round, so the morning crosses the north, never the south behind the view.
	var nw := -135.0
	var rise_nw := PlanetSky._towards(0.0, PlanetSky.sun_yaw(0.0, true, nw))
	var set_nw := PlanetSky._towards(0.0, PlanetSky.sun_yaw(0.0, false, nw))
	var morning_nw := PlanetSky._towards(30.0, PlanetSky.sun_yaw(30.0, true, nw))
	var noon_nw := PlanetSky._towards(PlanetSky.E_NOON, PlanetSky.sun_yaw(PlanetSky.E_NOON, true, nw))
	check(rise_nw.is_equal_approx(east) and set_nw.is_equal_approx(west) and morning_nw.z < 0.0 and noon_nw.x < 0.0 and noon_nw.z < 0.0,
		"sun: a noon in the north-west rises and sets as before, crossing the north (rise %s, set %s, morning %s, noon %s)" % [rise_nw, set_nw, morning_nw, noon_nw])
	var m_nw := PlanetSky.sun_model(PlanetSky.PLANETS["nauvis"], 0.0, 0.0, nw)
	check(is_equal_approx(float(m_nw["light_yaw"]), nw) and is_equal_approx(float(PlanetSky.sun_model(PlanetSky.PLANETS["nauvis"], 0.0, 0.0)["light_yaw"]), PlanetSky.YAW_NOON),
		"sun: the sun model's noon where the look asks, Zenith's own without")
	# The sun that never sets (a look with no twilight, or Cinematic's sunset slider at 0) takes the noon side too.
	var nw_sky := PlanetSky.new()
	add_child(nw_sky)
	var nw_sun := DirectionalLight3D.new()
	add_child(nw_sun)
	var nw_env := Environment.new()
	nw_sky.twilight = 0.0
	nw_sky.apply(nw_env, nw_sun, 0.0, 0.0, 0.0, false)
	var old_yaw := nw_sun.rotation_degrees.y
	nw_sky.noon_yaw = nw
	nw_sky.apply(nw_env, nw_sun, 0.0, 0.0, 0.0, false)
	check(is_equal_approx(old_yaw, PlanetSky.YAW_NOON) and is_equal_approx(nw_sun.rotation_degrees.y, nw),
		"sun: the sun that never sets at noon where the look asks, Zenith's own without (%s, %s)" % [old_yaw, nw_sun.rotation_degrees.y])
	nw_sky.queue_free()
	nw_sun.queue_free()
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
	# Zenith's shadows own the sun's size: a look's light_angular_distance reaches the sun through them,
	# with Godot's contact-hardening shadows (PCSS) as it asked.
	var fitter := SunShadows.new()
	fitter.sun = sun
	add_child(fitter)
	fitter.set_process(false)
	looks.shadows = fitter
	looks.use("test-addon/grey")
	check(is_equal_approx(fitter.sun_size, 1.5) and is_equal_approx(sun.light_angular_distance, 1.5) and is_equal_approx(sun.shadow_blur, 1.0)
		and is_equal_approx(sun.directional_shadow_pancake_size, SunShadows.pcss_pancake),
		"shaders: a look's own sun size still gives soft shadows through Zenith's shadows (size, blur, pancake): %s %s %s" % [sun.light_angular_distance, sun.shadow_blur, sun.directional_shadow_pancake_size])
	looks.use("classic")
	check(is_equal_approx(sun.light_angular_distance, 0.0) and is_equal_approx(sun.directional_shadow_pancake_size, SunShadows.PANCAKE) and is_equal_approx(fitter.edge, SunShadows.EDGE),
		"shaders: another look takes the sun size off again")
	looks.shadows = null
	fitter.queue_free()
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
## api.sound (1.7): an add-on's own sounds on a bus (a file from its folder, numbered variations), Zenith's
## sounds by kind replaced and muted, two add-ons stacked, the stop putting the one before back, the
## played signal, --addon-sounds=off, each call site naming its kind, and nothing kept while no add-on
## uses it. Under the Dummy driver: sfx.gd's voices and tables, not what is heard. The files are the
## test's own tones (sound_fixtures.gd).
func _sound(api, host) -> void:
	var disk: Dictionary = host.find("disk-addon")
	var other = disk.get("object")
	if other == null:
		check(false, "sound: the disk add-on runs")
		return
	var mine = api.sound  # the fixture add-on's
	var theirs = other.sound  # the disk add-on's, with files of its own
	# A stand-in install: base's grass and sand steps and core's click, the short tone; the disk add-on's
	# own files, the long one.
	var install := ProjectSettings.globalize_path("user://addon-test/install")
	var short := Tones.bytes(Tones.SHORT)
	var long := Tones.bytes(Tones.LONG)
	for f in ["base/sound/walking/grass-1.ogg", "base/sound/walking/sand-1.ogg", "core/sound/gui-click.ogg"]:
		_write_bytes(install.path_join(f), short)
	for f in ["sounds/boing.ogg", "sounds/step-1.ogg", "sounds/step-2.ogg", "sounds/jingle.ogg"]:
		_write_bytes(DISK + "/disk-addon/" + f, long)
	var was_dir := ItemIcons.data_dir
	var was_searched := ItemIcons._searched
	ItemIcons.data_dir = install
	ItemIcons._searched = true
	var sfx := Sfx.new()
	add_child(sfx)
	await get_tree().process_frame
	var grass := "base/sound/walking/grass-1.ogg"
	var sand := "base/sound/walking/sand-1.ogg"
	var click := "core/sound/gui-click.ogg"
	var here := Vector3.ZERO
	var step := func(path: String, kind: String) -> Array:
		_sound_fresh(sfx)
		sfx.play_at(path, here, 0.5, 0.06, 1.0, "Walking", kind)
		return _sound_paths(sfx)

	# Nobody uses it: a sound with a kind is Zenith's, and nothing is kept for kinds.
	check(not Sfx.listeners.has(mine) and not Sfx.listeners.has(theirs) and mine.kinds().has("step") and mine.kinds().has("rustle")
		and mine.kinds().size() == 11, "sound: every add-on has api.sound, with the kinds, and none listens until it connects `played`: %s" % [mine.kinds()])
	# The first look-up indexes the packs' sounds, which drops what was decoded once: look first.
	SoundBank.locate(grass)
	SoundBank.stream(grass)
	SoundBank.stream(sand)
	var plain: Array = step.call(grass, "step/grass")
	check(plain == [grass] and Sfx.kind_stack.is_empty() and not Sfx._kinds_on and Sfx._hearing.is_empty(),
		"sound: unused, a step plays Zenith's own file and makes no entry: %s" % [plain])

	# play(): a file from the add-on's folder, on a bus; not positional on the windows' players.
	var boing := "addon:disk-addon/sounds/boing.ogg"
	theirs.preload_sounds("sounds/boing.ogg")
	var at := SoundBank.locate(boing)
	check(at.get("from") == "addon" and str(at.get("file")).ends_with("disk-addon/sounds/boing.ogg"),
		"sound: an add-on's own file is found through SoundBank: %s" % [at])
	SoundBank.stream(boing)
	_sound_fresh(sfx)
	var played: bool = theirs.play("sounds/boing.ogg", {"at": here, "bus": "weapons", "volume": 0.5})
	var shot = _sound_shot(sfx, boing)
	check(played and _sound_paths(sfx) == [boing] and shot != null and shot.bus == "Weapons" and shot.player.bus == "Weapons",
		"sound: play() puts it on the asked bus: %s" % [_sound_paths(sfx)])
	for p: AudioStreamPlayer in sfx._ui:
		p.stream = null
	check(theirs.play("sounds/boing", {"bus": "music"}) and sfx._ui.any(func(p: AudioStreamPlayer) -> bool: return p.stream != null and p.bus == "Music"),
		"sound: without `at` (and a name without .ogg) it plays as the windows' sounds do, on its bus")
	for p: AudioStreamPlayer in sfx._ui:
		p.stream = null
		p.bus = "UI"
	# Not positional and not decoded yet: false, decoded on a worker (not on the spot, a frame's stall
	# for a long file), then it plays.
	var jingle := "addon:disk-addon/sounds/jingle.ogg"
	var first: bool = theirs.play("sounds/jingle.ogg", {"bus": "music"})
	var on_ui := sfx._ui.any(func(p: AudioStreamPlayer) -> bool: return p.stream != null)
	var waited := 0
	while SoundBank.stream_soon(jingle) == null and waited < 300:
		await get_tree().process_frame
		waited += 1
	check(not first and not on_ui and theirs.play("sounds/jingle.ogg", {"bus": "music"})
		and sfx._ui.any(func(p: AudioStreamPlayer) -> bool: return p.stream != null and p.bus == "Music"),
		"sound: a first non-positional play of a file not decoded is false and decodes on a worker, then plays (%d frames)" % waited)
	for p: AudioStreamPlayer in sfx._ui:
		p.stream = null
		p.bus = "UI"
	_sound_fresh(sfx)
	shot = _sound_shot(sfx, boing) if theirs.play("sounds/boing.ogg", {"at": here, "bus": "master"}) else null
	check(shot != null and shot.bus == "Effects", "sound: no bus of its own: master isn't one, effects is used")
	check(not theirs.play("sounds/nothing.ogg", {"at": here}) and not theirs.play("../escape.ogg") and not mine.play("__base__/sound/none.ogg"),
		"sound: a missing file, one outside the folder, a Factorio file the install hasn't: not played")
	# Outside the folder, with a real file there to find: every way of writing the path is refused, nothing
	# registered (the test's own escape.ogg beside the add-ons and above the stand-in install's data).
	_write_bytes(DISK + "/escape.ogg", long)
	_write_bytes("user://addon-test/escape.ogg", long)
	var outside := ProjectSettings.globalize_path(DISK + "/escape.ogg")
	for path in ["../escape.ogg", "../escape", "sounds/../../escape.ogg", "..\\escape.ogg", "sounds\\..\\..\\escape.ogg",
			"./../escape.ogg", outside, outside.replace("/", "\\"), DISK + "/escape.ogg", "__base__/../../escape.ogg",
			"__base__/../../escape", "__core__/..\\..\\escape.ogg"]:
		var refused: bool = not theirs.play(path) and theirs._files(path).is_empty()
		check(refused, "sound: a path outside the folder refused: %s -> %s" % [path, theirs._files(path)])
	check(not SoundBank._addon_files.values().any(func(f: String) -> bool: return f.get_file() == "escape.ogg"),
		"sound: nothing outside the folder registered: %s" % [SoundBank._addon_files])
	check(is_equal_approx(mine.volume("walking"), float(FxSettings.volumes["walking"])) and mine.volume("nothing") == 0.0,
		"sound: volume(bus) reads the player's setting")

	# replace(): the disk add-on's two variations wherever Zenith plays a step; the played signal.
	var heard: Array = []
	var listen := func(kind: String, info: Dictionary) -> void: heard.append([kind, info])
	mine.played.connect(listen)
	Sfx.refresh_hearing()
	check(Sfx.listeners.has(mine) and not Sfx.listeners.has(theirs) and Sfx._hearing == [mine],
		"sound: an add-on joins the listeners on connecting `played`, the other not")
	check(theirs.replace("step", "sounds/step") and Sfx.kind_stack.has("step") and Sfx.kind_entry("step/grass").get("by") == "disk-addon"
		and Array(Sfx.kind_entry("step/grass")["files"]) == ["addon:disk-addon/sounds/step-1.ogg", "addon:disk-addon/sounds/step-2.ogg"],
		"sound: replace() takes a kind and its numbered variations: %s" % [Sfx.kind_stack])
	for f in Sfx.kind_entry("step")["files"]:
		SoundBank.stream(f)
	var swapped: Array = step.call(grass, "step/grass")
	shot = _sound_shot(sfx, swapped[0]) if swapped.size() == 1 else null
	check(shot != null and str(swapped[0]).begins_with("addon:disk-addon/sounds/step-") and shot.bus == "Walking" and is_equal_approx(shot.volume, 0.5),
		"sound: a step on grass plays the add-on's, on the walking bus at the step's volume: %s" % [swapped])
	check(heard.size() == 1 and heard[0][0] == "step/grass" and heard[0][1]["by"] == "disk-addon" and heard[0][1]["path"] == swapped[0] and heard[0][1]["at"] == here
		and heard[0][1]["bus"] == "walking" and mine.volume(heard[0][1]["bus"]) == FxSettings.volumes["walking"],
		"sound: played(kind, info) says what played and whose, the bus as volume() takes it: %s" % [heard])
	# A step on grass with plants: the step and the rustle on top, as fx.gd plays them. Replacing "step"
	# replaces the step only: the rustle is its own kind (else the add-on's sound twice a footfall).
	var step_def := SoundBank.SoundDef.single(grass, 0.5)
	var plant_def := SoundBank.SoundDef.single(sand, 0.4)
	SoundBank.stream(sand)
	_sound_fresh(sfx)
	heard.clear()
	sfx.play_def(step_def, here, "Walking", 1.0, "step/" + StepSounds.name_of(step_def))
	sfx.play_def(plant_def, here, "Walking", 1.0, StepSounds.rustle_kind(plant_def))
	var both := _sound_paths(sfx)
	check(StepSounds.rustle_kind(plant_def) == "rustle/sand" and both.size() == 2 and both.has(sand)
		and both.filter(func(p: String) -> bool: return p.begins_with("addon:disk-addon/sounds/step-")).size() == 1
		and heard.map(func(h: Array) -> String: return h[0]) == ["step/grass", "rustle/sand"],
		"sound: replace(\"step\") on grass with plants plays the add-on's once and the rustle as it was: %s, %s" % [both, heard])
	heard.clear()
	# Two add-ons: the fixture's grass over the disk add-on's every step; restoring it brings the other back.
	SoundBank.stream(click)
	check(mine.replace("step/grass", "__core__/sound/gui-click.ogg", {"volume": 0.3}), "sound: a second add-on replaces grass's steps")
	var top: Array = step.call(grass, "step/grass")
	shot = _sound_shot(sfx, click)
	check(top == [click] and shot != null and is_equal_approx(shot.volume, 0.3), "sound: the last to replace wins, at its volume: %s" % [top])
	var on_sand: Array = step.call(sand, "step/sand")
	check(on_sand.size() == 1 and str(on_sand[0]).begins_with("addon:disk-addon/"), "sound: and the first add-on's still plays on sand: %s" % [on_sand])
	mine.restore("step/grass")
	top = step.call(grass, "step/grass")
	check(top.size() == 1 and str(top[0]).begins_with("addon:disk-addon/"), "sound: restore() brings the one before back: %s" % [top])
	# mute(): nothing plays, nothing is said.
	heard.clear()
	check(mine.mute("step"), "sound: mute() takes a kind")
	check(step.call(grass, "step/grass").is_empty() and heard.is_empty(), "sound: a muted kind plays nothing and isn't reported")
	check(not mine.mute("moo") and not mine.replace("moo/x", "__core__/sound/gui-click.ogg") and not mine.replace("ui", "sounds/none"),
		"sound: an unknown kind or no file is refused")
	mine.restore()
	check(Sfx.kind_entry("step").get("by") == "disk-addon", "sound: restore() without a kind takes all of its own away")
	# --addon-sounds=off: replace and mute ignored.
	Sfx.addon_sounds = false
	check(not mine.mute("ui") and not mine.replace("shot", "__core__/sound/gui-click.ogg") and not Sfx.kind_stack.has("ui") and not Sfx.kind_stack.has("shot"),
		"sound: --addon-sounds=off ignores replace() and mute()")
	Sfx.addon_sounds = true
	# The windows' sounds by kind: ui/<name>.
	check(mine.replace("ui/gui-click", "__base__/sound/walking/sand-1.ogg"), "sound: a window's click replaced")
	for p: AudioStreamPlayer in sfx._ui:
		p.stream = null
	Sfx.play_ui("gui-click")
	# (By path: a worker's decode started by replace() may land after and cache another stream object.)
	check(sfx._ui.any(func(p: AudioStreamPlayer) -> bool: return p.stream != null)
		and not heard.is_empty() and heard.back()[0] == "ui/gui-click" and heard.back()[1]["at"] == null and heard.back()[1]["path"] == sand,
		"sound: Sfx.play_ui(\"gui-click\") is kind ui/gui-click: %s" % [heard.back() if not heard.is_empty() else null])
	mine.restore()
	mine.played.disconnect(listen)
	Sfx.refresh_hearing()

	# The disk add-on stops: its replace goes, its files are forgotten; Zenith's own plays again.
	host.set_enabled("disk-addon", false)
	SoundBank.stream(grass)  # its files forgotten, what was decoded is decoded again
	var back: Array = step.call(grass, "step/grass")
	check(Sfx.kind_stack.is_empty() and not Sfx._kinds_on and not Sfx.listeners.has(theirs) and SoundBank.locate(boing).is_empty() and back == [grass],
		"sound: an add-on stopped: its replaces and files go, Zenith's step again: %s" % [back])
	host.set_enabled("disk-addon", true)

	_sound_call_sites()

	remove_child(sfx)
	sfx.free()
	ItemIcons.data_dir = was_dir
	ItemIcons._searched = was_searched


## Each of Zenith's sounds an add-on can replace is played with its kind: every play in these
## functions names one with the right base.
func _sound_call_sites() -> void:
	var where := {
		"res://scripts/fx/fx.gd": {"_update_steps": "step/", "_update_mining": ["pickup", "mine/"], "_update_repair": "repair",
			"_on_shot": "shot/", "_update_shots": "shot/", "_on_add": "build/", "_on_upd": "rotate/", "_on_del": "kind", "_on_died": "kind"},
		"res://scripts/fx/weapon_fx.gd": {"explode": "explosion/"},
		"res://scripts/ui/factorio/factorio_ui.gd": {"picked": "pickup/"},
	}
	for file: String in where:
		var text := FileAccess.get_file_as_string(file)
		for fn: String in where[file]:
			var start := text.find("\nfunc %s(" % fn)
			var end := text.find("\nfunc ", start + 1)
			var body := text.substr(start, end - start) if start >= 0 else ""
			var calls := 0
			var named := 0
			var want = where[file][fn]
			var bases: Array = want if want is Array else [want]
			for line in body.split("\n"):
				if not ("sfx.play_at(" in line or "Sfx.play_ui(" in line):
					continue
				if "\"Enemies\"" in line:
					continue  # biters' deaths: not a kind
				calls += 1
				for b: String in bases:
					if ("\"%s" % b) in line or (b == "kind" and line.strip_edges().ends_with(", kind)")):
						named += 1
						break
			check(calls > 0 and named == calls, "sound: %s %s names its kind on every play (%d of %d)" % [file.get_file(), fn, named, calls])
	var fx_text := FileAccess.get_file_as_string("res://scripts/fx/fx.gd")
	check(fx_text.contains("sfx.play_def(rustle, at, \"Walking\", 1.0, StepSounds.rustle_kind(rustle))"),
		"sound: fx.gd's rustle plays as its own kind, rustle/<name>")
	check(fx_text.contains("\"mined/\" + proto.name") and fx_text.contains("\"explosion/\" + proto.name"),
		"sound: mined and explosion kinds carry the thing's name")


func _write_bytes(path: String, data: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(data)
	f.close()


## Clears the one-shot voices' record, so the next play's file is the only one listed.
func _sound_fresh(sfx) -> void:
	sfx._last_played.clear()
	for s in sfx._shots:
		s.player.stop()
		s.path = ""


func _sound_paths(sfx) -> Array:
	var out: Array = []
	for s in sfx._shots:
		if s.path != "":
			out.append(s.path)
	return out


func _sound_shot(sfx, path: String):
	for s in sfx._shots:
		if s.path == path:
			return s
	return null


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
	# A field that says its own range (Terrain Elevation 0.1.5) isn't measured: its word is taken, rounded out.
	var told := img.duplicate() as Image
	told.set_meta(&"lift_range", Vector2(-0.2, 7.3))
	t.set_heights(told, Vector2(-8, -8), 4.0)
	check(GroundHeight.lift_range() == Vector2(-0.5, 7.5) and not GroundHeight.measuring() and late.extra_cull_margin == 7.5,
		"terrain: a field's own lift_range is taken instead of measuring it: %s" % [GroundHeight.lift_range()])
	t.clear()
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
	cv.content_rev = 1
	world.entities_changed.emit(Vector2i(0, 0))
	world.entities_changed.emit(Vector2i(1, 0))
	world.entities_changed.emit(Vector2i(0, 0))
	var changed: Array = t.take_changed_chunks()
	changed.sort()
	check(changed == [Vector2i(0, 0), Vector2i(1, 0)] and t.take_changed_chunks().is_empty(), "terrain: changed chunks, each once, then none: %s" % [changed])
	# Visual-only rebuilds (FarChunks unmerging, model swaps) emit entities_changed without raising
	# content_rev: take_changed_chunks() skips them instead of triggering false terrain rebuilds.
	cv.content_rev = 3
	t.buildings_in_chunk(Vector2i(0, 0))
	world.entities_changed.emit(Vector2i(0, 0))
	var visual_only: Array = t.take_changed_chunks()
	cv.content_rev = 4
	world.entities_changed.emit(Vector2i(0, 0))
	var real_change: Array = t.take_changed_chunks()
	check(visual_only.is_empty() and real_change == [Vector2i(0, 0)],
		"terrain: ignores visual-only entities_changed when content_rev is unchanged (%s), reports real changes (%s)" % [visual_only, real_change])
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


## An add-on in development (docs/ADDONS.md, "Testing"): Reload reads its addon.json, its entry script and
## a script it preloads (a function and a constant) from disk again; off and on does too; a parse error is
## refused with its file, line and message, then runs once fixed; its keys and settings are there once; the
## reload key (addons_reload) only while --addons is given. Script errors: listed on the add-on's page by
## their path in its folder, counted on repeats, given to the right add-on (a zip's too), cleared on a
## reload. --addon-reload=off and --addon-errors=off (or no Logger) behave as before.
##
## Godot prints every error it gives a Logger (with printing off it gives none), and check.py and CI fail a
## run on any SCRIPT ERROR line. So by default the broken scripts run with printing off and the errors are
## handed to the logger as Godot 4.7.2 gives them (measured: the file as it was loaded, the line, the
## message in `code`, type 2 for a script's); `-- --real-errors` lets Godot raise them itself (SCRIPT ERROR
## lines then expected in the output: run it by hand, not through check.py).
func _reload_and_errors(fake) -> void:
	var real := OS.get_cmdline_user_args().has("--real-errors")
	var base := ProjectSettings.globalize_path("user://addon-test/reload")
	var a_dir := base.path_join("rl-addon")
	var b_dir := base.path_join("rl-other")
	var manifest := func(id: String, version: String) -> String:
		return JSON.stringify({"id": id, "name": id.capitalize(), "version": version, "api": 1, "entry": "main.gd"})
	var main_a := func(n: int) -> String:
		return "extends Node\nconst Dep := preload(\"lib/dep.gd\")\nvar api\nfunc addon_start(a) -> void:\n\tapi = a\n" \
			+ "\ta.keys.add(\"go\", \"Go\", [KEY_KP_7])\n\ta.settings.add(\"level\", \"number\", 1, \"Level\", {\"min\": 0, \"max\": 9, \"step\": 1})\n" \
			+ "func version() -> int:\n\treturn %d\nfunc dep_value() -> int:\n\treturn Dep.V\nfunc dep_f() -> int:\n\treturn Dep.f()\n" % n
	var dep := func(v: int) -> String:
		return "extends RefCounted\nconst V := %d\nstatic func f() -> int:\n\treturn %d\n" % [v, v * 10]
	var main_b := func(n: int) -> String:
		return "extends Node\nfunc version() -> int:\n\treturn %d\nfunc boom():\n\tvar d = {}\n\treturn d.missing\n" % n
	_write(a_dir.path_join("addon.json"), manifest.call("rl-addon", "1"))
	_write(a_dir.path_join("lib/dep.gd"), dep.call(1))
	_write(a_dir.path_join("main.gd"), main_a.call(1))
	_write(b_dir.path_join("addon.json"), manifest.call("rl-other", "1"))
	_write(b_dir.path_join("main.gd"), main_b.call(1))
	_zip(base.path_join("rl-zip_1.zip"), {"rl-zip/addon.json": manifest.call("rl-zip", "1"), "rl-zip/main.gd": main_b.call(1)})
	for id in ["rl-other", "rl-zip"]:
		Settings.set_value("addons", id, true)
	var where := [[a_dir, "command line"], [b_dir, "test"], [base.path_join("rl-zip_1.zip"), "test"]]
	var host := AddonHost.new()
	host.autoload = false
	host.main = fake
	add_child(host)
	host.reload_on = true
	host.addons_dev = false
	host.errors_on = true
	host.load_all(where)
	await get_tree().process_frame
	var a := host.find("rl-addon")
	var b := host.find("rl-other")
	check(a.has("node") and int(a["node"].version()) == 1 and int(a["node"].dep_value()) == 1 and int(a["node"].dep_f()) == 10,
		"reload: the add-on in development runs (its preloaded script's constant and function)")
	check(host.can_reload(a) and not host.can_reload(b), "reload: offered for an --addons add-on, not for another without --addons-dev")
	host.addons_dev = true
	check(host.can_reload(b), "reload: and for every add-on switched on with --addons-dev")
	host.addons_dev = false

	# Reload: both scripts new, the manifest read again, keys and settings there once.
	_write(a_dir.path_join("addon.json"), manifest.call("rl-addon", "1.1"))
	_write(a_dir.path_join("main.gd"), main_a.call(2))
	_write(a_dir.path_join("lib/dep.gd"), dep.call(2))
	var ok: bool = await host.reload(a)
	var node = a.get("node")
	check(ok and node != null and int(node.version()) == 2, "reload: the entry script's new code runs")
	check(node != null and int(node.dep_f()) == 20 and int(node.dep_value()) == 2, "reload: and the preloaded script's new function and constant")
	check(str(a["version"]) == "1.1", "reload: addon.json is read again (its version): " + str(a["version"]))
	var go: String = a["object"].keys.action_of("go") if a.has("object") else ""
	var go_rows := Settings.bindable_actions().filter(func(x: String) -> bool: return x == go).size()
	var extra_rows := ControlsInfo.extra.keys().filter(func(x: String) -> bool: return str(ControlsInfo.extra[x][0]) == str(a["name"])).size()
	check(go != "" and InputMap.has_action(go) and go_rows == 1 and extra_rows == 1 and a["object"].settings.list().size() == 1,
		"reload: its key and setting are there once (%d, %d, %d)" % [go_rows, extra_rows, a["object"].settings.list().size() if a.has("object") else -1])

	# Off and on reads again too.
	_write(b_dir.path_join("main.gd"), main_b.call(2))
	host.set_enabled("rl-other", false)
	await get_tree().process_frame
	host.set_enabled("rl-other", true)
	check(b.has("node") and int(b["node"].version()) == 2, "reload: switched off and on, the add-on's new code runs")

	# A parse error: refused with the file, line and message; on its page; then fixed, it runs.
	var logger := ClassDB.class_exists("Logger")
	_write(a_dir.path_join("main.gd"), "extends Node\nfunc addon_start(_a) -> void:\n\tvar x := 1 +\n")
	Engine.print_error_messages = real
	ok = await host.reload(a)
	Engine.print_error_messages = true
	check(not ok and not a.has("node"), "reload: an entry script that doesn't parse isn't started")
	if logger and not real:
		_fake_error(host, a_dir.path_join("main.gd"), 3, "Parse Error: Expected expression after \"+\" operator.")
		a["error"] = host._entry_error(a)
	var why := str(a.get("error", ""))
	if logger:
		check(why.contains("main.gd line 3") and why.contains("Parse Error"), "errors: the refusal says the file, line and message: " + why)
		var errs := host.script_errors("rl-addon")
		check(errs.size() >= 1 and str(errs[0]["file"]) == "main.gd" and int(errs[0]["line"]) == 3 and str(errs[0]["message"]).contains("Parse Error"),
			"errors: the parse error is kept for the add-on, by its path in its folder: %s" % [errs])
		var win := AddonsWindow.new()
		win.addons = host
		win.selected = "rl-addon"
		add_child(win)
		var shown := win.find_child("addon-errors-rl-addon", true, false) as Label
		var item := win.find_child("addon-item-rl-addon", true, false) as Button
		check(shown != null and shown.text.contains("main.gd line 3") and not shown.text.contains(base) and not host.script_errors_text("rl-addon").contains(base),
			"errors: the page lists it, with no folder of the PC's: " + (shown.text if shown != null else "none"))
		check(item != null and item.text.contains("script error") and win.find_child("addon-errors-copy-rl-addon", true, false) != null,
			"errors: the add-on's row is marked, the page has Copy")
		check(win.find_child("addon-reload-rl-addon", true, false) != null and win.find_child("addon-reload-rl-other", true, false) == null,
			"reload: the page of an --addons add-on has Reload")
		win.queue_free()
	else:
		check(why.contains("see the log"), "errors: without Logger the refusal points at the log")
	_write(a_dir.path_join("main.gd"), main_a.call(3))
	ok = await host.reload(a)
	check(ok and a.has("node") and int(a["node"].version()) == 3, "reload: fixed, it runs again")
	check(host.script_errors("rl-addon").is_empty(), "errors: cleared on a reload")

	# A run-time error: listed once, counted on repeats, given to the right add-on (a zip's to the zip's).
	if logger:
		var message := "Invalid access to property or key 'missing' on a base object of type 'Dictionary'."
		if real:
			for i in 3:
				b["node"].boom()
			host.find("rl-zip")["node"].boom()
			push_error("addon_test: an error outside every add-on's folder")
		else:
			for i in 3:
				_fake_error(host, b_dir.path_join("main.gd"), 6, message)
			_fake_error(host, "user://addon-test/cache/rl-zip/main.gd", 6, message)
			_fake_error(host, "core/variant/variant_utility.cpp", 1023, "addon_test: an error outside every add-on's folder")
		host._process(0.0)
		var eb := host.script_errors("rl-other")
		check(eb.size() == 1 and int(eb[0]["count"]) == 3 and str(eb[0]["file"]) == "main.gd" and int(eb[0]["line"]) == 6
			and str(eb[0]["message"]).contains("missing"), "errors: a run-time error is listed once, counted three times: %s" % [eb])
		check(host.script_errors("rl-addon").is_empty() and host.script_errors_text("rl-other").contains("×3"),
			"errors: given to the add-on whose file it is, not another")
		var ez := host.script_errors("rl-zip")
		check(ez.size() == 1 and str(ez[0]["file"]) == "main.gd", "errors: a zip's error maps back to it through its unpacked folder: %s" % [ez])
		var all := 0
		for id in host._errors:
			all += (host._errors[id] as Array).size()
		check(all == 2 and host._errors_told.has("rl-other"), "errors: one outside the add-ons' folders isn't kept; the first one is announced once")

	# The reload key: only while --addons is given, rebindable, reloads the --addons add-ons.
	check(not InputMap.has_action("addons_reload") and not Settings.bindable_actions().has("addons_reload"),
		"reload key: not in Settings → Controls without --addons")
	Controls.addon_author_override = 1
	Controls.define()
	Settings.apply_bindings()
	var code := KEY_F5 | KEY_MASK_CTRL | KEY_MASK_SHIFT
	check(Settings.bindable_actions().has("addons_reload") and Settings.keys_for("addons_reload") == [code, 0]
		and Settings.conflicts("addons_reload", code).is_empty() and ControlsInfo.group_of("addons_reload") == "Miscellaneous",
		"reload key: with --addons, Ctrl+Shift+F5 in Settings → Controls, clashing with nothing")
	_write(a_dir.path_join("main.gd"), main_a.call(4))
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_F5
	ev.ctrl_pressed = true
	ev.shift_pressed = true
	ev.pressed = true
	host._shortcut_input(ev)
	for i in 3:
		await get_tree().process_frame
	check(a.has("node") and int(a["node"].version()) == 4, "reload key: the --addons add-on is reloaded")
	Controls.addon_author_override = 0
	Settings.apply_bindings()
	Controls.addon_author_override = -1

	# --addon-reload=off: off and on keeps the old code, no Reload or key.
	host.reload_on = false
	_write(b_dir.path_join("main.gd"), main_b.call(5))
	host.set_enabled("rl-other", false)
	await get_tree().process_frame
	host.set_enabled("rl-other", true)
	var off_ok: bool = await host.reload(a)
	check(b.has("node") and int(b["node"].version()) == 2 and not host.can_reload(a) and not off_ok,
		"--addon-reload=off: off and on keeps the old code, nothing offers a reload")
	_write(a_dir.path_join("main.gd"), main_a.call(6))
	host._shortcut_input(ev)
	await get_tree().process_frame
	check(a.has("node") and int(a["node"].version()) == 4, "--addon-reload=off: the key does nothing")
	for m in host.running():
		host.stop(m)
	host.queue_free()
	await get_tree().process_frame

	# --addon-errors=off (and a Godot without Logger, which takes the same path): nothing collected,
	# the refusal points at the log, reloading still works.
	var quiet := AddonHost.new()
	quiet.autoload = false
	quiet.main = fake
	quiet.errors_on = false
	quiet.reload_on = true
	add_child(quiet)
	_write(b_dir.path_join("main.gd"), main_b.call(7))
	quiet.load_all(where)
	await get_tree().process_frame
	var qb := quiet.find("rl-other")
	Engine.print_error_messages = real
	if qb.has("node"):
		qb["node"].boom()
	quiet._process(0.0)
	var qa := quiet.find("rl-addon")
	_write(a_dir.path_join("main.gd"), "extends Node\nfunc addon_start(_a) -> void:\n\tvar x := 1 +\n")
	var refused: bool = not (await quiet.reload(qa))
	Engine.print_error_messages = true
	check(quiet._errors_logger == null and quiet.script_errors("rl-other").is_empty() and quiet.script_errors("rl-addon").is_empty(),
		"--addon-errors=off: no logger, nothing collected")
	check(refused and str(qa.get("error", "")).contains("see the log"), "--addon-errors=off: a refusal points at the log, as before")
	_write(a_dir.path_join("main.gd"), main_a.call(8))
	var fixed: bool = await quiet.reload(qa)
	check(fixed and int(qa["node"].version()) == 8, "--addon-errors=off: reloading still works")
	for m in quiet.running():
		quiet.stop(m)
	quiet.queue_free()
	await get_tree().process_frame
	Settings.reset_value("addons", "rl-other")
	Settings.reset_value("addons", "rl-zip")


## addon.json's dependencies in Factorio's form (API 1.7, docs/ADDONS.md): the syntax and each message,
## the start order by chain depth (today's without dependencies), every refusal, a circle, switching a
## dependency off and on, the duplicate id's winner, Factorio mods per game (a resync restarts nothing),
## optional and incompatible ones, api.addons.version, reload taking the dependents, the page's Needs:
## line and --addon-requires=off.
func _dependencies(fake, plain_where: Array) -> void:
	# The syntax: each problem's message, read through problem_of as the Add-ons menu shows it.
	var base := ProjectSettings.globalize_path("user://addon-test/deps")
	var made := {}  # id -> its folder
	var write := func(folder: String, id: String, version: String, deps: Variant) -> void:
		var j := {"id": id, "name": id, "version": version, "api": 1.7, "entry": "main.gd"}
		if deps != null:
			j["dependencies"] = deps
		_write(folder.path_join(id).path_join("addon.json"), JSON.stringify(j))
		_write(folder.path_join(id).path_join("main.gd"), "extends Node\nvar api\nfunc addon_start(a) -> void:\n\tapi = a\n"
			+ "\tvar seen: Array = Engine.get_meta(\"dep_log\", [])\n\tseen.append(a.id)\n\tEngine.set_meta(\"dep_log\", seen)\n")
		made[id] = folder.path_join(id)
	var syn := base.path_join("syntax")
	var bad := {
		"not-list": ["cinematic-camera", "must be a list of strings"],
		"not-string": [[1], "must be a list of strings (1"],
		"empty": [[""], "its dependency \"\" is empty"],
		"bad-op": [["b >> 1"], "its dependency \"b >> 1\" must be \"[prefix] <id or mod:name> [<op> <version>]\""],
		"bad-version": [["b >= x.y"], "its dependency \"b >= x.y\" must be"],
		"no-version": [["b >="], "its dependency \"b >=\" must be"],
		"bad-id": [["Big-Name"], "names \"Big-Name\": an add-on's id is lower case letters"],
		"spaced": [["two words"], "its dependency \"two words\" must be"],
		"no-name": [["? >= 1.0"], "its dependency \"? >= 1.0\" names nothing"],
		"bad-mod": [["mod:"], "must name a Factorio mod after mod:"],
		"self-dep": [["self_dep"], "its dependency \"self_dep\" names the add-on itself"],
		"twice": [["b", "? b >= 1"], "its dependencies name b twice"],
	}
	for id in bad:
		write.call(syn, id, "1.0", bad[id][0] if id != "not-list" else bad[id][0])
	for m: Dictionary in AddonLoader.scan([[syn, "test"]]):
		var want: String = bad[str(m["id"])][1]
		check(not bool(m["ok"]) and str(m["problem"]).contains(want), "dependencies: %s's message: %s" % [m["id"], m["problem"]])
	var ex := AddonLoader.parse_dependencies(["cinematic-camera >= 0.3.0", "? terrain-elevation", "mod:space-age >= 2.1.0", "! old-camera", "(?) hidden_one = 1", "~ quiet < 2", "+ nice > 0.1"])
	var got := []
	for d: Dictionary in ex["list"]:
		got.append([d["prefix"], d["name"], d["mod"], d["op"], d["version"]])
	check(str(ex["problem"]) == "" and got == [["", "cinematic-camera", false, ">=", "0.3.0"], ["?", "terrain-elevation", false, "", ""],
		["", "space-age", true, ">=", "2.1.0"], ["!", "old-camera", false, "", ""], ["(?)", "hidden_one", false, "=", "1"],
		["~", "quiet", false, "<", "2"], ["+", "nice", false, ">", "0.1"]], "dependencies: Factorio's prefixes, ops and mod: read: %s" % [got])
	var plain := AddonLoader.read(made["empty"])
	check(plain.has("dependencies"), "dependencies: kept on the manifest")

	# Today's order with no dependencies anywhere: exactly scan's.
	var found := AddonLoader.scan(plain_where)
	var ids := found.map(func(m: Dictionary) -> String: return str(m["id"]))
	var ordered := AddonLoader.order(found).map(func(m: Dictionary) -> String: return str(m["id"]))
	check(ids.size() > 5 and ordered == ids, "dependencies: without any, the order is exactly today's")

	# The add-ons for the host: a chain found a, b, c (needs b, needs c); each refusal; a circle; a
	# duplicate id; optional and incompatible ones; Factorio mods.
	var one := base.path_join("one")
	var two := base.path_join("two")
	write.call(one, "a-chain", "1.0.0", ["b-chain >= 1"])
	write.call(one, "b-chain", "1.0.0", ["c-chain"])
	write.call(one, "c-chain", "1.0.0", null)
	write.call(one, "needs-missing", "1", ["nope >= 0.2.0"])
	write.call(one, "needs-off", "1", ["off-one"])
	write.call(one, "off-one", "1", null)
	write.call(one, "needs-new", "1", ["c-chain >= 2.0"])
	write.call(one, "needs-broken", "1", ["broken-dep"])
	_write(one.path_join("broken-dep/addon.json"), JSON.stringify({"id": "broken-dep", "name": "Broken dep", "api": 1, "entry": "main.gd"}))
	write.call(one, "cyc-a", "1", ["cyc-b"])
	write.call(one, "cyc-b", "1", ["? cyc-a"])
	write.call(one, "dup-dep", "0.1", null)
	write.call(two, "dup-dep", "0.3", null)
	write.call(one, "needs-dup", "1", ["dup-dep >= 0.3"])
	write.call(one, "needs-dup-old", "1", ["dup-dep < 0.2"])
	write.call(one, "opt-target", "1.0", null)
	write.call(one, "opt-wrong", "1", ["? opt-target >= 5"])
	write.call(one, "opt-absent", "1", ["? nothing-here >= 1", "(?) nor-here", "+ nor-this"])
	write.call(one, "inc-target", "1", null)
	write.call(one, "incompat", "1", ["! inc-target"])
	write.call(one, "r1-hater", "1", ["! r2-target"])
	write.call(one, "r2-target", "1", null)
	write.call(one, "needs-mod", "1", ["mod:space-age >= 2.1.0"])
	write.call(one, "opt-mod", "1", ["? mod:jetpack >= 0.4"])
	write.call(one, "late-dep", "1", ["~ z-later"])
	write.call(one, "z-later", "1", null)
	write.call(one, "mu-a", "1", ["~ mu-b"])  # the fixer's: two that need each other through ~
	write.call(one, "mu-b", "1", ["mu-a"])
	write.call(one, "needs-base", "1", ["base >= 2.1"])  # Factorio's base written as an add-on
	for id in made:
		if made[id].begins_with(one) or made[id].begins_with(two):
			Settings.set_value("addons", id, id != "off-one")
	Settings.set_value("addons", "broken-dep", true)
	Engine.set_meta("dep_log", [])
	var where := [[one, "test"], [two, "test"]]
	var host := AddonHost.new()
	host.autoload = false
	host.main = fake
	add_child(host)
	host.game_mods_override = {"base": "2.1.24"}
	host.load_all(where)
	var seen: Array = Engine.get_meta("dep_log", [])
	var at := func(id: String) -> int:
		return seen.find(id)
	check(int(at.call("c-chain")) >= 0 and int(at.call("c-chain")) < int(at.call("b-chain")) and int(at.call("b-chain")) < int(at.call("a-chain")),
		"dependencies: a chain found a, b, c starts c, b, a: %s" % [seen])
	var err := func(id: String) -> String:
		return str(host.find(id).get("error", ""))
	var running := func(id: String) -> bool:
		return host.find(id).has("node")
	check(not running.call("needs-missing") and err.call("needs-missing") == "it needs the add-on nope 0.2.0 or newer, which isn't installed",
		"dependencies: refused when missing: " + err.call("needs-missing"))
	check(not running.call("needs-off") and err.call("needs-off") == "it needs the add-on off-one, which is switched off",
		"dependencies: refused when switched off: " + err.call("needs-off"))
	check(not running.call("needs-new") and err.call("needs-new") == "it needs the add-on c-chain 2.0 or newer (1.0.0 is installed)",
		"dependencies: refused when too old: " + err.call("needs-new"))
	check(not running.call("needs-broken") and err.call("needs-broken") == "it needs the add-on Broken dep, which couldn't load",
		"dependencies: refused when it couldn't load: " + err.call("needs-broken"))
	check(not running.call("cyc-a") and not running.call("cyc-b") and err.call("cyc-a").contains("it and cyc-b need each other")
		and err.call("cyc-b").contains("it and cyc-a need each other"), "dependencies: a circle refuses every add-on in it: " + err.call("cyc-a"))
	check(str(host.find("dup-dep")["version"]) == "0.3" and running.call("needs-dup")
		and err.call("needs-dup-old") == "it needs the add-on dup-dep older than 0.2 (0.3 is installed)",
		"dependencies: the duplicate id's winner (0.3) is the one checked: " + err.call("needs-dup-old"))
	check(not running.call("opt-wrong") and err.call("opt-wrong").begins_with("it works with the add-on opt-target only at 5 or newer (1.0 is installed)"),
		"dependencies: an optional one there at a wrong version refuses: " + err.call("opt-wrong"))
	check(running.call("opt-absent"), "dependencies: optional ones absent (?, (?), +) don't")
	check(not running.call("incompat") and err.call("incompat") == "it can't run with the add-on inc-target, which is on",
		"dependencies: an incompatible one running refuses the start: " + err.call("incompat"))
	check(running.call("r1-hater") and not running.call("r2-target") and err.call("r2-target") == "the add-on r1-hater, which is on, can't run with it",
		"dependencies: and one an add-on running can't run with is refused too: " + err.call("r2-target"))
	check(running.call("late-dep") and running.call("z-later"), "dependencies: ~ (no order) starts once its dependency has")
	check(running.call("needs-mod") and running.call("opt-mod"), "dependencies: Factorio mods aren't checked outside a game")
	check(running.call("mu-a") and running.call("mu-b") and err.call("mu-a") == "" and err.call("mu-b") == "",
		"dependencies: two that need each other through ~ both run: " + err.call("mu-a") + " / " + err.call("mu-b"))
	host.set_enabled("mu-b", false)
	check(not running.call("mu-a") and not running.call("mu-b") and err.call("mu-a") == "it needs the add-on mu-b, which is switched off",
		"dependencies: switching one of the ~ pair off stops both: " + err.call("mu-a"))
	host.set_enabled("mu-b", true)
	check(running.call("mu-a") and running.call("mu-b") and err.call("mu-a") == "", "dependencies: and switching it on again starts both")
	host.set_enabled("mu-a", false)
	check(not running.call("mu-a") and not running.call("mu-b"), "dependencies: the other one off stops both too")
	host.set_enabled("mu-a", true)
	check(running.call("mu-a") and running.call("mu-b"), "dependencies: and on again starts both")
	check(not running.call("needs-base") and err.call("needs-base") == "it needs the add-on base 2.1 or newer, which isn't installed (a Factorio mod is written mod:base)",
		"dependencies: a Factorio mod's name written as an add-on gets a hint: " + err.call("needs-base"))

	# api.addons.version.
	var api = host.find("a-chain").get("object")
	check(api != null and is_equal_approx(api.level, 1.7) and api.addons.version("c-chain") == "1.0.0" and api.addons.version("c_chain") == "1.0.0"
		and api.addons.version("needs-off") == "" and api.addons.version("off-one") == "" and api.addons.version("nope") == "",
		"dependencies: api.addons.version gives a running add-on's version, \"\" otherwise")

	# The page's Needs: line.
	var win := AddonsWindow.new()
	win.addons = host
	win.selected = "a-chain"
	add_child(win)
	var needs := win.find_child("addon-needs-a-chain", true, false) as Label
	check(needs != null and needs.text == "Needs: b-chain 1 or newer", "dependencies: the page says what it needs: " + (needs.text if needs else "none"))
	win.select("opt-absent")
	needs = win.find_child("addon-needs-opt-absent", true, false) as Label
	check(needs != null and needs.text == "Needs: works with nothing-here 1 or newer, nor-this if there", "dependencies: optional ones, the hidden one not named: " + (needs.text if needs else "none"))
	win.select("c-chain")
	check(win.find_child("addon-needs-c-chain", true, false) == null, "dependencies: no line without dependencies")
	win.queue_free()

	# Switching the chain's last one off stops those that need it first (last started first); on again
	# starts them, without being switched.
	host.set_enabled("c-chain", false)
	check(not running.call("c-chain") and not running.call("b-chain") and not running.call("a-chain"), "dependencies: C off stops B and A first")
	check(err.call("b-chain") == "it needs the add-on c-chain, which is switched off" and err.call("a-chain").contains("b-chain, which couldn't start")
		and AddonLoader.enabled(host.find("a-chain")), "dependencies: their pages say why, their switches stay on: " + err.call("b-chain"))
	await get_tree().process_frame
	Engine.set_meta("dep_log", [])
	host.set_enabled("c-chain", true)
	seen = Engine.get_meta("dep_log", [])
	check(seen == ["c-chain", "b-chain", "a-chain"] and err.call("a-chain") == "" and err.call("b-chain") == "",
		"dependencies: C on again starts B and A again: %s" % [seen])
	host.set_enabled("off-one", true)
	check(running.call("needs-off") and err.call("needs-off") == "", "dependencies: the switched-off one switched on lets its dependent start")
	host.set_enabled("off-one", false)
	host.set_enabled("inc-target", false)
	check(running.call("incompat"), "dependencies: the incompatible one switched off lets the other start")
	host.set_enabled("inc-target", true)
	check(not running.call("inc-target") and err.call("inc-target").contains("incompat, which is on, can't run with it"), "dependencies: and then it can't start itself")

	# A reload takes the add-ons that need it along.
	var c_node: int = host.find("c-chain")["node"].get_instance_id()
	var b_node: int = host.find("b-chain")["node"].get_instance_id()
	Engine.set_meta("dep_log", [])
	await host.reload(host.find("c-chain"))
	seen = Engine.get_meta("dep_log", [])
	check(seen == ["c-chain", "b-chain", "a-chain"] and running.call("a-chain") and host.find("b-chain")["node"].get_instance_id() != b_node,
		"dependencies: reloading C reloads B and A after it: %s" % [seen])
	check(c_node != host.find("c-chain")["node"].get_instance_id(), "dependencies: C itself is new")

	# Factorio mods: per game, from the welcome's list.
	Engine.set_meta("dep_log", [])
	host.game_mods_override = {"base": "2.1.24", "jetpack": "0.4.2"}
	host.game_started()
	check(not running.call("needs-mod") and err.call("needs-mod") == "this game doesn't have the Factorio mod space-age (2.1.0 or newer)",
		"dependencies: a game without the Factorio mod stops it: " + err.call("needs-mod"))
	check(running.call("opt-mod") and AddonLoader.enabled(host.find("needs-mod")), "dependencies: an optional mod there at a fitting version doesn't; the switch stays on")
	host.game_started()  # the welcome again (a resync)
	check((Engine.get_meta("dep_log", []) as Array).is_empty() and not running.call("needs-mod"), "dependencies: a second welcome restarts nothing")
	host.game_ended()
	check(running.call("needs-mod") and err.call("needs-mod") == "", "dependencies: it starts again when the game ends")
	host.game_mods_override = {"base": "2.1.24", "space-age": "2.1.24", "jetpack": "0.3.0"}
	Engine.set_meta("dep_log", [])
	host.game_started()
	check(running.call("needs-mod") and not running.call("opt-mod") and err.call("opt-mod") == "this game has the Factorio mod jetpack 0.3.0, and it works with it only at 0.4 or newer"
		and Engine.get_meta("dep_log", []) == [], "dependencies: met, it runs on untouched; an optional mod at a wrong version stops: " + err.call("opt-mod"))
	host.game_mods_override = {"base": "2.1.24", "space-age": "2.0.0"}
	host.game_started()  # another game's welcome
	check(not running.call("needs-mod") and err.call("needs-mod") == "this game has the Factorio mod space-age 2.0.0, and it needs 2.1.0 or newer"
		and running.call("opt-mod"), "dependencies: too old a mod stops it; another game lets the optional one back: " + err.call("needs-mod"))
	host.game_ended()
	for m in host.running():
		host.stop(m)
	host.queue_free()
	await get_tree().process_frame

	# --addon-requires=off: no checks, the order found.
	AddonLoader.requires_on = false
	var off := AddonHost.new()
	off.autoload = false
	off.main = fake
	add_child(off)
	Engine.set_meta("dep_log", [])
	off.load_all(where)
	seen = Engine.get_meta("dep_log", [])
	check(off.find("needs-missing").has("node") and off.find("cyc-a").has("node") and off.find("incompat").has("node") and off.find("r2-target").has("node"),
		"--addon-requires=off: dependencies aren't checked")
	check(seen.find("a-chain") < seen.find("c-chain"), "--addon-requires=off: the order found: %s" % [seen])
	check(AddonLoader.read(made["bad-op"]).get("ok", false), "--addon-requires=off: a dependency that can't be read doesn't stop it either")
	for m in off.running():
		off.stop(m)
	off.queue_free()
	AddonLoader.requires_on = true
	await get_tree().process_frame
	for id in made:
		Settings.reset_value("addons", id)
	Settings.reset_value("addons", "broken-dep")


## The review's fixes (mods-docs-fix2): an add-on started at the game's welcome because another stopped
## for the game's Factorio mods hears game_started once, after the menu has named the save; a Reload
## pressed twice at once reloads once.
func _fix2_checks(fake) -> void:
	var base := ProjectSettings.globalize_path("user://addon-test/fix2")
	_write(base.path_join("fa-modded/addon.json"), JSON.stringify({"id": "fa-modded", "name": "fa-modded", "version": "1", "api": 1.7,
		"entry": "main.gd", "dependencies": ["mod:space-age"]}))
	_write(base.path_join("fa-modded/main.gd"), "extends Node\nfunc addon_start(_a) -> void:\n\tpass\n")
	_write(base.path_join("fx-hater/addon.json"), JSON.stringify({"id": "fx-hater", "name": "fx-hater", "version": "1", "api": 1.7,
		"entry": "main.gd", "dependencies": ["! fa-modded"]}))
	_write(base.path_join("fx-hater/main.gd"), "extends Node\nvar api\nvar heard: Array = []\nfunc addon_start(a) -> void:\n\tapi = a\n"
		+ "\ta.game_started.connect(func() -> void: heard.append(api.storage.save_key()))\n")
	for id in ["fa-modded", "fx-hater"]:
		Settings.set_value("addons", id, true)
	var host := AddonHost.new()
	host.autoload = false
	host.main = fake
	add_child(host)
	host.game_mods_override = {"base": "2.1.24"}
	host.load_all([[base, "test"]])
	check(host.find("fa-modded").has("node") and not host.find("fx-hater").has("node"), "game_started once: the add-on held by one running")
	var path_before: String = fake.front_end.launcher.save_path
	fake.front_end.launcher.save_path = ""  # the menu names the save after main.gd's game_started
	host.game_started()
	fake.front_end.launcher.save_path = "C:/somewhere/saves/fix2.zip"
	await get_tree().process_frame
	var hater := host.find("fx-hater")
	var heard: Array = hater["node"].heard if hater.has("node") else []
	check(not host.find("fa-modded").has("node") and heard == ["fix2"],
		"game_started once: one started at the welcome hears it once, after the save is named: %s" % [heard])
	host.game_ended()
	fake.front_end.launcher.save_path = path_before
	# Reload pressed twice in one frame: one reload.
	host.reload_on = true
	var m := host.find("fx-hater")
	var first_node: int = m["node"].get_instance_id() if m.has("node") else 0
	host.reload(m)
	var second: bool = await host.reload(m)
	await get_tree().process_frame
	await get_tree().process_frame
	check(not second and m.has("node") and m["node"].get_instance_id() != first_node and not host._reloading.has("fx-hater"),
		"reload: a second press while one runs does nothing; the first reloads")
	for r in host.running():
		host.stop(r)
	for id in ["fa-modded", "fx-hater"]:
		Settings.reset_value("addons", id)
	host.queue_free()
	await get_tree().process_frame
	_rmtree(base)


## An error given to the host's logger as Godot gives it (_reload_and_errors), without printing it. The
## backtrace array is typed by name: ScriptBacktrace exists only from Godot 4.5, as Logger does.
func _fake_error(host, file: String, line: int, message: String) -> void:
	if host._errors_logger != null:
		host._errors_logger._log_error("f", file, line, message, "", false, 2, Array([], TYPE_OBJECT, &"ScriptBacktrace", null))
## API 1.7, api.game: messages between an add-on and its own Factorio mod (`ext`, addon_game.gd). The
## bridge is played by Bridge's signals and _handle, what is sent read from Bridge.capture.
func _game_link(api, host) -> void:
	var other = host.find("disk-addon")["node"].api
	var ch := "zenith-link-test"
	var heard: Array = []
	var other_heard: Array = []
	var changed: Array = []
	var to_world: Array = []
	var on_message := func(c: String, d: Variant) -> void: heard.append([c, d])
	var on_other := func(c: String, d: Variant) -> void: other_heard.append([c, d])
	var on_changed := func(on: bool) -> void: changed.append(on)
	var on_world := func(msg: Dictionary) -> void: to_world.append(msg)
	api.game.message.connect(on_message)
	other.game.message.connect(on_other)
	api.game.link_changed.connect(on_changed)
	Bridge.message_received.connect(on_world)
	var was_connected: bool = Bridge.connected
	var was_link: int = Bridge.link_version
	var errors: Array = []
	var on_error := func(c: String, t: String) -> void: errors.append([c, t])
	api.game.mod_error.connect(on_error)
	Bridge.capture = []

	check(not api.game.available() and not api.game.send(ch, {"on": true}) and api.game.mod(ch) == "",
		"api.game: no game's bridge, no link: nothing sent, no mods")
	check(api.game.open(ch) and api.game.open(ch), "api.game: an add-on opens a channel (twice is fine)")
	check(not other.game.open(ch), "api.game: another add-on can't open it")
	check(not api.game.open("bad channel") and not api.game.open("") and not api.game.open("/" + ch)
		and not api.game.open(ch + "/a\nb") and not api.game.open(ch + "/" + "x".repeat(130)),
		"api.game: names that aren't channels are refused")
	check(not api.game.open("factorio-3d-bridge") and not api.game.open("factorio-3d-bridge/x"),
		"api.game: the bridge's own name isn't a channel")
	check(not api.game.send(ch, {"on": true}) and Bridge.capture.is_empty(), "api.game: before a welcome, nothing is sent (nothing queued)")
	# A welcome from a bridge without the link: still nothing. (Bridge sets link_version from the
	# welcome before it emits welcomed.)
	Bridge.connected = true
	Bridge.link_version = 0
	Bridge.welcomed.emit({"t": "welcome", "mods": {"base": "2.1.24", ch: "1.0.0"}})
	check(not api.game.available() and api.game.mod(ch) == "1.0.0" and not api.game.send(ch, {"on": true}) and changed.is_empty(),
		"api.game: a bridge whose welcome lacks ext: the mods are known, nothing is sent")
	Bridge.link_version = 1
	Bridge.welcomed.emit({"t": "welcome", "ext": 1, "mods": {"base": "2.1.24", ch: "1.0.0"}})
	check(api.game.available() and changed == [true], "api.game: a welcome with ext: the link is on, link_changed(true)")
	check(api.game.send(ch, {"on": true}), "api.game: send on an open channel")
	var sent: Array = Bridge.capture.map(func(s: String) -> Variant: return JSON.parse_string(s))
	check(sent.size() == 1 and sent[0] is Dictionary and sent[0].get("t") == "ext" and sent[0].get("ch") == ch
		and sent[0].get("d") == {"on": true} and sent[0].size() == 3,
		"api.game: it goes out as {t: ext, ch, d}: %s" % [Bridge.capture])
	Bridge.capture.clear()
	check(api.game.open("not-in-game") and not api.game.send("not-in-game", 1), "api.game: a channel whose mod isn't in the game sends nothing")
	check(not api.game.send(ch + "/never-opened", 1) and not api.game.send(ch, null) and not api.game.send(ch, "x".repeat(4100)),
		"api.game: an unopened channel, null and over 4 KB send nothing")
	check(Bridge.capture.is_empty(), "api.game: (nothing went out)")
	api.game.open(ch + "/rate")
	var ok := 0
	for i in 25:
		if api.game.send(ch + "/rate", i):
			ok += 1
	check(ok == 20 and Bridge.capture.size() == 20, "api.game: a channel sends 20 at once, then waits (%d of 25)" % ok)
	Bridge.capture.clear()
	# From the mod: only the add-on that opened the channel hears it, and the rest of Zenith never does.
	check(other.game.open(ch + "/b"), "api.game: the other add-on opens a channel of its own")
	Bridge._handle({"t": "ext", "k": 5, "ch": ch, "d": {"x": 1}})
	Bridge._handle({"t": "ext", "k": 5, "ch": ch + "/b", "d": [1, 2]})
	Bridge._handle({"t": "ext", "k": 5, "ch": ch + "/nobody", "d": 3})
	check(heard == [[ch, {"x": 1}]] and other_heard == [[ch + "/b", [1, 2]]],
		"api.game: each add-on hears only its own channels: %s / %s" % [heard, other_heard])
	check(to_world.is_empty(), "api.game: `ext` never reaches message_received")
	# The mod's handler failed (the bridge's `err`): mod_error on the add-on holding the channel, not message.
	heard.clear()
	other_heard.clear()
	Bridge._handle({"t": "ext", "k": 6, "ch": ch, "err": "control.lua:42: boom"})
	Bridge._handle({"t": "ext", "k": 6, "ch": ch + "/nobody", "err": "nobody holds it"})
	Bridge._handle({"t": "ext", "k": 6, "ch": ch, "err": "closed after repeated errors (10 within 60 s)"})
	check(errors == [[ch, "control.lua:42: boom"], [ch, "closed after repeated errors (10 within 60 s)"]] and heard.is_empty()
		and other_heard.is_empty() and to_world.is_empty(),
		"api.game: the mod's error reaches the add-on holding the channel as mod_error, not message: %s" % [errors])
	# Factorio's own report (as the live recheck saw it) says "non-recoverable" and "Custom event (ID n)",
	# yet the game went on: the log and the page get a short line, mod_error and Copy the whole text.
	errors.clear()
	host._errors.erase(str(api.id))
	var report := "The mod Zenith link test (0.1.0) caused a non-recoverable error.\nPlease report this error to the mod author.\n\nError while running event zenith-link-test::Custom event (ID 242)\n__zenith-link-test__/control.lua:42: linktest: boom, as asked\nstack traceback:\n\t[C]: in function 'error'\n\t__zenith-link-test__/control.lua:42: in function <__zenith-link-test__/control.lua:40>"
	var closed := "closed after repeated errors (10 within 60 s)"
	var addon_name: String = host.name_of(str(api.id))
	var short := "The Factorio mod Zenith link test failed on a message from %s (the game went on): __zenith-link-test__/control.lua:42: linktest: boom, as asked" % addon_name
	check(host.mod_error_line(ch, report, addon_name) == short, "api.game: Factorio's report becomes a short line: " + host.mod_error_line(ch, report, addon_name))
	check(host.mod_error_line(ch, closed, addon_name) == "the channel %s to the Factorio mod %s: %s" % [ch, ch, closed],
		"api.game: the bridge's closing text is shown as it is, with the mod: " + host.mod_error_line(ch, closed, addon_name))
	check(host.mod_error_line(ch + "/x", "control.lua:42: boom\nstack traceback:", "") == "The Factorio mod %s failed on a message on %s/x (the game went on): control.lua:42: boom" % [ch, ch],
		"api.game: a text not in Factorio's shape gives its first line, the channel's mod part as the name")
	Bridge._handle({"t": "ext", "k": 7, "ch": ch, "err": report})
	Bridge._handle({"t": "ext", "k": 7, "ch": ch, "err": report})
	Bridge._handle({"t": "ext", "k": 7, "ch": ch, "err": closed})
	check(errors == [[ch, report], [ch, report], [ch, closed]], "api.game: mod_error keeps the whole text (channel, text): %s" % [errors.size()])
	var kept: Array = host.script_errors(str(api.id))
	check(kept.size() == 2 and kept[0].get("mod") == "Zenith link test" and kept[0]["message"] == short and kept[0]["full"] == report
		and int(kept[0]["count"]) == 2 and kept[1].get("mod") == ch and str(kept[1]["message"]).ends_with(closed),
		"api.game: on the add-on's page, marked as the Factorio mod's, the same report counted: %s" % [kept])
	var page_text: String = host.script_errors_text(str(api.id))
	var copied: String = host.script_errors_text(str(api.id), true)
	check(page_text.contains(short + "  ×2") and not page_text.contains("non-recoverable") and not page_text.contains("Custom event"),
		"api.game: the page shows the short line: " + page_text.replace("\n", " | "))
	check(copied.contains("non-recoverable error") and copied.contains("stack traceback:") and copied.contains(closed),
		"api.game: Copy gives Factorio's whole report")
	check(not host._entry_error(host.find(str(api.id))).contains("Factorio mod"), "api.game: a mod's error is never taken for the entry script's")
	host._errors.erase(str(api.id))
	# Stopped: its channels are free; started again it has none.
	var disk: Dictionary = host.find("disk-addon")
	host.stop(disk)
	check(api.game.open(ch + "/b"), "api.game: a stopped add-on's channels are free again")
	host.start(disk)
	other = disk["node"].api
	check(other.game.channels().is_empty() and not other.game.open(ch + "/b"), "api.game: started again it holds none")
	api.game.close(ch + "/b")
	check(other.game.open(ch + "/b"), "api.game: close frees a channel")
	# The game lost: the link goes.
	Bridge.connection_lost.emit()
	check(not api.game.available() and changed == [true, false] and not api.game.send(ch, 1) and api.game.mod(ch) == "",
		"api.game: the connection lost: link_changed(false), nothing sent")
	check(Bridge.capture.is_empty(), "api.game: (nothing went out)")

	api.game.message.disconnect(on_message)
	api.game.mod_error.disconnect(on_error)
	api.game.link_changed.disconnect(on_changed)
	Bridge.message_received.disconnect(on_world)
	for c in api.game.channels():
		api.game.close(c)
	other.game.close(ch + "/b")
	Bridge.capture = null
	Bridge.connected = was_connected
	Bridge.link_version = was_link
	# The sprint pair's add-on (addons-src/sprint): its addon.json is good, its script loads.
	var sprint: Array = AddonLoader.scan([[ProjectSettings.globalize_path("res://").path_join("../addons-src"), "test"]]).filter(
		func(s: Dictionary) -> bool: return s["id"] == "sprint")
	var sprint_script = load(str(sprint[0]["dir"]).path_join("main.gd")) if not sprint.is_empty() and sprint[0]["ok"] else null
	check(sprint_script is Script and (sprint_script as Script).can_instantiate(),
		"api.game: the sprint add-on (addons-src/sprint) is found, asks for 1.7 and its script loads: %s" % [sprint[0].get("problem", "") if not sprint.is_empty() else "not found"])
	# The sprint add-on's key (addons-src/sprint): a bare Shift can be a global control's default.
	var probe: String = api.keys.add("shift_probe", "Shift alone", ["Shift"])
	check(api.keys.text("shift_probe") == "Shift", "api.keys: a bare Shift can be a default (the sprint add-on's): %s" % api.keys.text("shift_probe"))
	Settings.remove_action(probe)
	ControlsInfo.extra.erase(probe)


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


# --- step 7a as an author and a player meet it (the testing agent's checks) -----------------------

## Reloading as an add-on author meets it: a function, a preloaded script's constant, a shader and
## addon.json's version all new after the Reload button and the key, nothing doubled (keys, settings,
## windows, nodes), a zip changed on disk, the camera handed back and taken again, in a game. Then the
## errors (a parse error in one add-on of two, no PC folder in a message that names one, Zenith's own
## not kept, the logger's cost) and dependencies (Factorio's own info.json strings, ~ through a chain,
## Factorio mods through a chain, an add-on off by default never switched on, nothing sent to the game).
func _author_checks(fake) -> void:
	var real := OS.get_cmdline_user_args().has("--real-errors")
	var base := ProjectSettings.globalize_path("user://addon-test/author")
	var a_dir := base.path_join("au-addon")
	var b_dir := base.path_join("au-addon-b")
	var zip_path := base.path_join("au-zip_1.zip")
	var manifest := func(id: String, version: String) -> String:
		return JSON.stringify({"id": id, "name": id.capitalize(), "version": version, "api": 1, "entry": "main.gd"})
	var main_a := func(n: int) -> String:
		return ("extends Node\nconst Dep := preload(\"lib/dep.gd\")\nconst Fx := preload(\"fx.gdshader\")\nvar api\nvar mat := ShaderMaterial.new()\n"
			+ "func addon_start(a) -> void:\n\tapi = a\n\ta.keys.add(\"au_go\", \"Go\", [KEY_KP_9])\n"
			+ "\ta.settings.add(\"lvl\", \"number\", 1, \"Level\", {\"min\": 0, \"max\": 9, \"step\": 1})\n"
			+ "\ta.ui.window(\"Author\")\n\tvar kid := Node.new()\n\tkid.name = \"Kid\"\n\tadd_child(kid)\n\tmat.shader = Fx\n"
			+ "\ta.game_started.connect(_on_game)\nfunc _on_game() -> void:\n\tapi.camera.take()\n"
			+ "func version() -> int:\n\treturn %d\nfunc dep_value() -> int:\n\treturn Dep.V\nfunc shader_code() -> String:\n\treturn mat.shader.code\n") % n
	var dep := func(v: int) -> String:
		return "extends RefCounted\nconst V := %d\n" % v
	var shader := func(v: int) -> String:
		return "shader_type spatial;\n// v%d\nvoid fragment() {\n\tALBEDO = vec3(0.%d);\n}\n" % [v, v]
	var main_z := func(n: int) -> String:
		return "extends Node\nfunc version() -> int:\n\treturn %d\n" % n
	_write(a_dir.path_join("addon.json"), manifest.call("au-addon", "1.0"))
	_write(a_dir.path_join("main.gd"), main_a.call(1))
	_write(a_dir.path_join("lib/dep.gd"), dep.call(1))
	_write(a_dir.path_join("fx.gdshader"), shader.call(1))
	_write(b_dir.path_join("addon.json"), manifest.call("au-addon-b", "1"))
	_write(b_dir.path_join("main.gd"), main_z.call(1))
	_zip(zip_path, {"au-zip/addon.json": manifest.call("au-zip", "1.0"), "au-zip/main.gd": main_z.call(1)})
	var where := [[a_dir, "command line"], [b_dir, "command line"], [zip_path, "command line"]]
	var host := AddonHost.new()
	host.autoload = false
	host.main = fake
	add_child(host)
	host.reload_on = true
	host.errors_on = true
	host.load_all(where)
	host.game_started()
	for i in 2:
		await get_tree().process_frame
	var a := host.find("au-addon")
	var rig = fake.rig
	check(a.has("node") and host.camera_holder() == a.get("object") and rig.taken(), "author: the add-on runs in a game and holds the camera")
	var counts := func() -> Array:
		var api = a.get("object")
		var go: String = api.keys.action_of("au_go") if api != null else ""
		var windows := host.ui_root.get_children().filter(func(n: Node) -> bool: return str(n.name).begins_with("au-addon_")).size()
		var nodes := host.get_children().filter(func(n: Node) -> bool: return str(n.name) == "Addon_au_addon" and not n.is_queued_for_deletion()).size()
		var kids: int = a["node"].get_child_count() if a.has("node") else -1
		var rows := Settings.bindable_actions().filter(func(x: String) -> bool: return x == go).size()
		return [rows, api.settings.list().size() if api != null else -1, windows, nodes, kids]
	var first: Array = counts.call()
	check(first == [1, 1, 1, 1, 1], "author: one key, setting, window, node and child to start with: %s" % [first])

	# Edit a function, a preloaded script's constant, a shader and addon.json's version; press Reload.
	_write(a_dir.path_join("addon.json"), manifest.call("au-addon", "1.1"))
	_write(a_dir.path_join("main.gd"), main_a.call(2))
	_write(a_dir.path_join("lib/dep.gd"), dep.call(2))
	_write(a_dir.path_join("fx.gdshader"), shader.call(2))
	var old_node: Node = a["node"]
	var win := AddonsWindow.new()
	win.addons = host
	win.selected = "au-addon"
	add_child(win)
	var button := win.find_child("addon-reload-au-addon", true, false) as Button
	check(button != null, "author: the --addons add-on's page has Reload")
	if button != null:
		button.pressed.emit()
	for i in 4:
		await get_tree().process_frame
	var node = a.get("node")
	check(node != null and int(node.version()) == 2 and int(node.dep_value()) == 2 and str(a["version"]) == "1.1",
		"author, Reload: the function, the preloaded constant and addon.json's version are new")
	check(node != null and str(node.shader_code()).contains("// v2"), "author, Reload: the shader is read again: " + (str(node.shader_code()).get_slice("\n", 1) if node != null else "none"))
	check(not is_instance_valid(old_node), "author, Reload: the old node is gone")
	var second: Array = counts.call()
	check(second == first, "author, Reload: nothing doubled (key rows, settings, windows, nodes, children): %s" % [second])
	check(host.camera_holder() == a.get("object") and rig.taken(), "author, Reload in a game: the camera was handed back and taken again by the new add-on")

	# The key, with the add-on holding the camera again: version 3, still nothing doubled.
	_write(a_dir.path_join("main.gd"), main_a.call(3))
	_write(a_dir.path_join("fx.gdshader"), shader.call(3))
	Controls.addon_author_override = 1
	Controls.define()
	Settings.apply_bindings()
	host._shortcut_input(_reload_key())
	for i in 6:
		await get_tree().process_frame
	node = a.get("node")
	check(node != null and int(node.version()) == 3 and str(node.shader_code()).contains("// v3"), "author, the key: the new function and shader")
	var third: Array = counts.call()
	check(third == first and host.camera_holder() == a.get("object"), "author, the key: nothing doubled, the camera taken again: %s" % [third])
	Controls.addon_author_override = 0
	Settings.apply_bindings()
	Controls.addon_author_override = -1

	# A zip changed on disk: its new version and code after a reload.
	var z := host.find("au-zip")
	_zip(zip_path, {"au-zip/addon.json": manifest.call("au-zip", "1.1"), "au-zip/main.gd": main_z.call(2)})
	var zok: bool = await host.reload(z)
	check(zok and z.has("node") and int(z["node"].version()) == 2 and str(z["version"]) == "1.1",
		"author: a zip changed on disk is read again (its version and code): %s %s" % [z.get("version"), z.get("error", "")])

	# Errors: a parse error in a preloaded file of the second add-on, named for it, not the first.
	var told_paths := PackedStringArray([base, ProjectSettings.globalize_path("user://"), OS.get_environment("USERNAME")])
	_write(b_dir.path_join("lib/bad.gd"), "extends RefCounted\nfunc f() -> int:\n\treturn 1 +\n")
	_write(b_dir.path_join("main.gd"), "extends Node\nconst Bad := preload(\"lib/bad.gd\")\nfunc version() -> int:\n\treturn 2\n"
		+ "func missing() -> void:\n\tvar r = load(\"" + b_dir.path_join("nothere.tres") + "\")\n")
	var b := host.find("au-addon-b")
	Engine.print_error_messages = real
	var bok: bool = await host.reload(b)
	Engine.print_error_messages = true
	if not real:
		_fake_error(host, b_dir.path_join("lib/bad.gd"), 3, "Parse Error: Expected expression after \"+\" operator.")
		b["error"] = host._entry_error(b)
	host._process(0.0)
	var eb := host.script_errors("au-addon-b")
	var in_lib := eb.filter(func(e: Dictionary) -> bool: return str(e["file"]) == "lib/bad.gd" and int(e["line"]) == 3).size()
	check(not bok and in_lib == 1 and host.script_errors("au-addon").is_empty(),
		"errors: a parse error in the second add-on's preloaded file is its own, not the first's: %s" % [eb])
	print("addon_test: the refusal reads: ", b.get("error", ""))
	check(str(b.get("error", "")).contains("lib/bad.gd line 3"), "errors: the refusal names the cause (the first error since the reload), not a follow-on: " + str(b.get("error", "")))
	# A message that names a file by its full path (Godot's "Resource file not found: C:/...").
	DirAccess.remove_absolute(b_dir.path_join("lib/bad.gd"))
	_write(b_dir.path_join("main.gd"), "extends Node\nfunc version() -> int:\n\treturn 3\nfunc missing() -> void:\n\tvar r = load(\"" + b_dir.path_join("nothere.tres") + "\")\n")
	await host.reload(b)
	Engine.print_error_messages = real
	if real and b.has("node"):
		b["node"].missing()
	elif not real:
		_fake_error(host, b_dir.path_join("main.gd"), 5, "Resource file not found: %s (expected type: unknown)" % b_dir.path_join("nothere.tres"))
	Engine.print_error_messages = true
	host._process(0.0)
	var text := host.script_errors_text("au-addon-b")
	print("addon_test: the page's text: ", text.replace("\n", " | "))
	var leaked := ""
	for p in told_paths:
		if p != "" and text.contains(p):
			leaked = p
	check(text != "" and leaked == "", "errors: no folder of the PC's in the page's or the copied text (a message naming a full path): " + text.replace("\n", " | "))
	# A path elsewhere in the user's folders (outside every add-on) becomes a placeholder.
	_fake_error(host, b_dir.path_join("main.gd"), 9, "Cannot open file '%s'." % ProjectSettings.globalize_path("user://elsewhere/x.tres"))
	_fake_error(host, b_dir.path_join("main.gd"), 10, "Cannot open file '%s'." % OS.get_environment("USERPROFILE").replace("\\", "/").path_join("x.tres"))
	host._process(0.0)
	text = host.script_errors_text("au-addon-b")
	leaked = ""
	for p in told_paths:
		if p != "" and text.contains(p):
			leaked = p
	check(leaked == "" and text.contains("'<user folder>/elsewhere/x.tres'") and (OS.get_environment("USERPROFILE") == "" or text.contains("'<user folder>/x.tres'")),
		"errors: another path in the user's folders becomes <user folder>: " + text.replace("\n", " | "))
	# The fixer's (mods-docs-fix2): on Windows a path in another case, and a short name (NAME~1), go too.
	if OS.get_name() == "Windows" and OS.get_environment("USERPROFILE") != "":
		var home := OS.get_environment("USERPROFILE").replace("\\", "/")
		_fake_error(host, b_dir.path_join("main.gd"), 11, "Cannot open file '%s'." % home.to_lower().path_join("dev/shared/x.tres"))
		_fake_error(host, b_dir.path_join("main.gd"), 12, "Cannot open file '%s'." % b_dir.to_upper().path_join("LIB/Y.TRES"))
		_fake_error(host, b_dir.path_join("main.gd"), 13, "Cannot open file 'C:\\Users\\ABCDEF~1\\AppData\\Local\\Temp\\z.tres'.")
		host._process(0.0)
		text = host.script_errors_text("au-addon-b")
		var low := text.to_lower()
		leaked = ""
		for p in told_paths:
			if p != "" and low.contains(p.to_lower()):
				leaked = p
		check(leaked == "" and text.contains("'<user folder>/dev/shared/x.tres'"), "errors: a user folder written in another case goes too: " + text.replace("\n", " | "))
		check(text.contains("'LIB/Y.TRES'"), "errors: and an add-on's folder in another case: " + text.replace("\n", " | "))
		check(not text.contains("ABCDEF~1") and text.contains("'<user folder>\\AppData\\Local\\Temp\\z.tres'"),
			"errors: a short-name user folder (NAME~1) goes too: " + text.replace("\n", " | "))
	# push_warning (type 1) isn't a script error: not kept, the row not marked.
	var count_before := host.script_errors("au-addon-b").size()
	if host._errors_logger != null:
		host._errors_logger._log_error("f", b_dir.path_join("main.gd"), 14, "addon_test: a warning", "", false, 1, Array([], TYPE_OBJECT, &"ScriptBacktrace", null))
	host._process(0.0)
	check(host.script_errors("au-addon-b").size() == count_before, "errors: a warning (push_warning) isn't listed as a script error")
	# Zenith's own scripts' errors (and the engine's from them) aren't kept.
	var kept_before := 0
	for id in host._errors:
		kept_before += (host._errors[id] as Array).size()
	_fake_error(host, "res://scripts/world/world.gd", 120, "addon_test: Zenith's own error")
	_fake_error(host, ProjectSettings.globalize_path("res://scripts/world/world.gd"), 120, "addon_test: Zenith's own error")
	host._process(0.0)
	var kept_after := 0
	for id in host._errors:
		kept_after += (host._errors[id] as Array).size()
	check(kept_after == kept_before, "errors: Zenith's own scripts' errors aren't kept")
	# The cost of an error from outside every add-on: microseconds a call, with these add-ons and with 40.
	var logger = host._errors_logger
	if logger != null:
		var empty_trace := Array([], TYPE_OBJECT, &"ScriptBacktrace", null)
		var per_call := func(n: int) -> float:
			var t := Time.get_ticks_usec()
			for i in n:
				logger._log_error("f", "res://scripts/world/world.gd", 1, "x", "", false, 0, empty_trace)
			return float(Time.get_ticks_usec() - t) / n
		var few: float = per_call.call(20000)
		var prefixes: int = logger._prefixes.size()
		var many := PackedStringArray()
		for i in 40:
			many.append(base.path_join("many-%d/" % i))
		logger.set_prefixes(many)
		var forty: float = per_call.call(20000)
		host._watch_errors()
		print("addon_test: _log_error for an error outside the add-ons: %.2f µs with %d prefixes, %.2f µs with 40" % [few, prefixes, forty])
		check(few < 20.0 and forty < 50.0, "errors: one outside the add-ons costs little (%.2f µs, %.2f µs with 40 folders)" % [few, forty])
	for m in host.running():
		host.stop(m)
	host.game_ended()
	win.queue_free()
	host.queue_free()
	await get_tree().process_frame
	await _author_dependencies(fake)


## A check for a bug the testing agent found and reported, not yet fixed: printed, not counted in
## FAILS, so the suite stays green until the fix; turn it into check() with the fix.
func known(cond: bool, what: String) -> void:
	print(("ok (a known bug, fixed now) " if cond else "KNOWN BUG, to fix: ") + what)


func _reload_key() -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_F5
	ev.ctrl_pressed = true
	ev.shift_pressed = true
	ev.pressed = true
	return ev


func _author_dependencies(fake) -> void:
	# Factorio's own dependency strings (the install's data/*/info.json) read as Factorio reads them:
	# as add-on ids and as mod:<name>, against a plain reading of the same grammar.
	var data := ItemIcons.factorio_data_dir()
	var strings := PackedStringArray(["? Krastorio2 >= 1.3.0", "(?) bobplates", "! Squeak_Through", "~ flib >= 0.12.0", "+ quality >= 2.0.0", "base>=2.0"])
	if data != "":
		for sub in DirAccess.get_directories_at(data):
			var f := FileAccess.open(data.path_join(sub).path_join("info.json"), FileAccess.READ)
			if f != null:
				var j = JSON.parse_string(f.get_as_text())
				if j is Dictionary and j.get("dependencies") is Array:
					for s in j["dependencies"]:
						strings.append(str(s))
	var plain := RegEx.create_from_string("^\\s*(\\(\\?\\)|\\?|!|~|\\+)?\\s*([^<>=\\s]+)\\s*(?:(<=|>=|<|>|=)\\s*([0-9.]+))?\\s*$")
	var differ: Array = []
	for s in strings:
		var r := plain.search(s)
		var want := [r.get_string(1), r.get_string(2), r.get_string(3), r.get_string(4)] if r != null else []
		var pfx: String = want[0] if r != null else ""
		var as_mod := (pfx + " " if pfx != "" else "") + "mod:" + (s.substr(s.find(want[1])) if r != null else s)
		var d := AddonLoader.parse_dependency(as_mod)
		var got := [d.get("prefix"), d.get("name"), d.get("op"), d.get("version")]
		if got != want or not d.get("mod", false):
			differ.append([as_mod, got, want])
		if r != null and r.get_string(2) == r.get_string(2).to_lower():
			var d2 := AddonLoader.parse_dependency(s)
			if [d2.get("prefix"), d2.get("name"), d2.get("op"), d2.get("version")] != want:
				differ.append([s, d2, want])
	check(differ.is_empty() and strings.size() >= 6, "dependencies: Factorio's own info.json strings (%d, the install's %s) read the same: %s" % [strings.size(), "found" if data != "" else "not found", differ])
	check(AddonLoader.parse_dependency("! mod:Squeak Through").has("problem"),
		"dependencies: a Factorio mod with a space in its name (Factorio allows it) can't be named after mod: (known gap)")

	var base := ProjectSettings.globalize_path("user://addon-test/author-deps")
	var write := func(id: String, deps: Variant) -> void:
		var j := {"id": id, "name": id, "version": "1.0", "api": 1.7, "entry": "main.gd"}
		if deps != null:
			j["dependencies"] = deps
		_write(base.path_join(id).path_join("addon.json"), JSON.stringify(j))
		_write(base.path_join(id).path_join("main.gd"), "extends Node\nvar api\nfunc addon_start(a) -> void:\n\tapi = a\n"
			+ "\tvar seen: Array = Engine.get_meta(\"dep_log\", [])\n\tseen.append(a.id)\n\tEngine.set_meta(\"dep_log\", seen)\n")
	# ~ through a chain: t1 needs ~ t3, t3 needs t2. Found t1, t2, t3; ~ doesn't order, so t1 comes first.
	write.call("t1-tilde", ["~ t3-mid"])
	write.call("t2-root", null)
	write.call("t3-mid", ["t2-root"])
	# A Factorio mod through a chain: md-a needs md-b, which needs the mod krastorio2.
	write.call("md-a", ["md-b"])
	write.call("md-b", ["mod:krastorio2 >= 1.0"])
	# Trust: one switched on needs one nobody has switched (new: off), another an --addons one needs.
	write.call("tr-needs", ["tr-new"])
	write.call("tr-new", null)
	for id in ["t1-tilde", "t2-root", "t3-mid", "md-a", "md-b", "tr-needs"]:
		Settings.set_value("addons", id, true)
	Settings.reset_value("addons", "tr-new")
	var cl_dir := ProjectSettings.globalize_path("user://addon-test/author-cl/tr-cl")
	_write(cl_dir.path_join("addon.json"), JSON.stringify({"id": "tr-cl", "name": "tr-cl", "version": "1", "api": 1.7, "entry": "main.gd", "dependencies": ["tr-new"]}))
	_write(cl_dir.path_join("main.gd"), "extends Node\n")
	var switches_before := {}
	for id in ["t1-tilde", "t2-root", "t3-mid", "md-a", "md-b", "tr-needs", "tr-new", "tr-cl"]:
		switches_before[id] = [Settings.has_value("addons", id), (Settings.get_value("addons", id) if Settings.has_value("addons", id) else null)]
	var host := AddonHost.new()
	host.autoload = false
	host.main = fake
	add_child(host)
	var sent_before = Bridge.capture
	Bridge.capture = []
	host.load_all([[base, "test"], [cl_dir, "command line"]])
	var running := func(id: String) -> bool:
		return host.find(id).has("node")
	var err := func(id: String) -> String:
		return str(host.find(id).get("error", ""))
	check(running.call("t1-tilde") and running.call("t3-mid") and running.call("t2-root"), "dependencies, ~ in a chain: all three start")
	host.set_enabled("t2-root", false)
	check(not running.call("t3-mid") and not running.call("t1-tilde"),
		"dependencies, ~ in a chain: switching the root off stops the one that needs it through ~ too (t1 %s, t3 %s)" % [running.call("t1-tilde"), running.call("t3-mid")])
	host.set_enabled("t2-root", true)
	check(running.call("t3-mid") and running.call("t1-tilde"), "dependencies, ~ in a chain: on again, both start again")

	# Trust: the new one stays off, and so unswitched, while two need it.
	check(not running.call("tr-new") and not running.call("tr-needs") and not running.call("tr-cl") and not AddonLoader.enabled(host.find("tr-new"))
		and err.call("tr-needs").contains("switched off") and err.call("tr-cl").contains("switched off"),
		"bounds: an add-on off by default stays off when others (one an --addons one) need it: " + err.call("tr-cl"))
	host.set_enabled("tr-needs", false)
	host.set_enabled("tr-needs", true)

	# A Factorio mod through a chain: a welcome without it stops both, a resync restarts nothing, the
	# game's end starts both, the needed one first.
	host.game_mods_override = {"base": "2.1.24"}
	Engine.set_meta("dep_log", [])
	host.game_started()
	check(not running.call("md-b") and not running.call("md-a") and err.call("md-b").contains("krastorio2") and err.call("md-a").contains("md-b"),
		"dependencies, a mod in a chain: a game without it stops both: %s / %s" % [err.call("md-b"), err.call("md-a")])
	host.game_started()
	host.set_enabled("md-a", false)
	host.set_enabled("md-a", true)
	check((Engine.get_meta("dep_log", []) as Array).is_empty() and not running.call("md-a"), "dependencies, a mod in a chain: a resync or switching it in the game starts nothing")
	host.game_ended()
	var seen: Array = Engine.get_meta("dep_log", [])
	check(seen.find("md-b") >= 0 and seen.find("md-b") < seen.find("md-a"), "dependencies, a mod in a chain: the game's end starts both, the needed one first: %s" % [seen])
	var sent: Array = Bridge.capture
	Bridge.capture = sent_before
	check(sent.is_empty(), "bounds: checking dependencies and Factorio mods sends nothing to the game: %s" % [sent])
	var changed: Array = []
	for id in switches_before:
		if [Settings.has_value("addons", id), (Settings.get_value("addons", id) if Settings.has_value("addons", id) else null)] != switches_before[id]:
			changed.append(id)
	check(changed.is_empty(), "bounds: Zenith switched no add-on itself (only the test's own switches came back as they were): %s" % [changed])
	for m in host.running():
		host.stop(m)
	host.queue_free()
	await get_tree().process_frame
	for id in switches_before:
		Settings.reset_value("addons", id)
