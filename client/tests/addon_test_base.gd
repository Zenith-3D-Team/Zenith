extends Node
## Shared preloads, fake classes, counters, and helpers for addon_test.gd and addon_area_*.gd.

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
const AddonWorld := preload("res://scripts/addons/addon_world.gd")
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
const WeatherState := preload("res://scripts/world/weather_state.gd")
const GodRays := preload("res://scripts/world/god_rays.gd")
const TestEnv := preload("res://tests/test_env.gd")
const TEST_SETTINGS := "user://addon-test-settings.cfg"
const DISK := "user://addon-test/addons"

static var fails: int = 0
static var passes: int = 0
static var _failed: PackedStringArray = []

class FakeMain extends Node:
	var rig
	var avatar
	var input
	var hud
	var movers
	var world
	var fx
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
	var view_cone := false

	func set_view_cone(on: bool) -> void:
		view_cone = on


## movers.gd as api.world reads it: one logistic robot (unit 7), drawn by the GPU from its record, so
## its node stays where it first appeared while position_of and yaw_of say where it is drawn now.


class FakeMovers extends Node:
	var protos := FakeProtos.new()
	var creatures = null
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


func known(cond: bool, what: String) -> void:
	print(("ok (a known bug, fixed now) " if cond else "KNOWN BUG, to fix: ") + what)


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


func _event(code: Key, shift := false) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.shift_pressed = shift
	ev.pressed = true
	return ev
