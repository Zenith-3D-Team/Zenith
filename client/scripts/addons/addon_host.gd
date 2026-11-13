extends Node
## Zenith's add-ons (docs/ADDONS.md): finds them (addon_loader.gd), starts the ones switched on,
## each with its API object (addon_api.gd), and stands between them and the game: which add-on has
## the camera, keeping its camera keys from Zenith meanwhile, the interface hidden for a clean
## shot, the mouse, frames saved, the time of day held, lighter updates. main.gd makes one at
## start-up, after Zenith's own controls are defined (add-ons' keys must be in Settings â†’ Controls
## before any game), and tells it when a game starts and ends.
##
## An add-on's entry script extends Node; it is added under this node, and its
## addon_start(api) is called (then addon_stop() when it is switched off). Its _process and input
## callbacks run as any node's; it gets input before Zenith's game controls and menus do.

const AddonLoader := preload("res://scripts/addons/addon_loader.gd")
const AddonApi := preload("res://scripts/addons/addon_api.gd")
const AddonEvents := preload("res://scripts/addons/addon_events.gd")
const AddonWorld := preload("res://scripts/addons/addon_world.gd")
const MenuKit := preload("res://scripts/menu/menu_kit.gd")
const InterfaceState := preload("res://scripts/ui/interface_state.gd")
const FullDetail := preload("res://scripts/world/full_detail.gd")
const Kit := preload("res://scripts/ui/factorio/kit.gd")
const ShotPause := preload("res://scripts/addons/shot_pause.gd")
const MomentHold := preload("res://scripts/world/moment_hold.gd")
const FrameBudget := preload("res://scripts/world/frame_budget.gd")
const BeltBlur := preload("res://scripts/world/belt_blur.gd")

## The list changed, or an add-on started or stopped (the Mods window redraws).
signal addons_changed
## A screenshot (api.view.screenshot) was written to `path`, or couldn't be (`ok` false).
signal screenshot_saved(path: String, ok: bool)
## A screenshot was cancelled (api.view.screenshot_cancel, or Esc while it was taken): nothing written.
signal screenshot_cancelled(path: String)

## main.gd (or a stand-in in tests): its game nodes (rig, avatar, input, hud, movers, world, ride,
## rockets, ups_governor, front_end) are read from it.
var main: Node = null
## Every add-on found: addon_loader.read()'s manifest, plus "node" and "object" (its API) while it runs and
## "error" when it failed to start.
var addons: Array = []
var events := AddonEvents.new()
var world := AddonWorld.new(self)
## The add-on whose hills (api.terrain) are drawn now, "" for flat ground.
var _terrain_owner := ""
## Add-ons' windows: over the HUD, under Zenith's menus.
var layer := CanvasLayer.new()
var ui_root := Control.new()
## Look for add-ons when added (off in tests, which call load_all with their own folders).
var autoload := true

var _game_on := false
var _holder = null  # the AddonApi that has the camera
var _holder_input := true
var _input_locked := false
var _mouse_managed := false
var _hidden_by := {}  # add-on id -> true while it wants the interface hidden
var _hidden_nodes: Array = []  # [CanvasLayer, visible before]
var _daytime_by := ""  # the add-on holding the time of day
var _daytime_before := -1.0
var _frame_tasks: Array[int] = []
var _frame_done: Array = []  # parallel to _frame_tasks: [path, Callable, [save_png's result]]
var _hold_by := {}  # add-on id -> true while it holds chunks (api.world.hold_chunks)
var _detail_by := {}  # add-on id -> true while it asks for full detail (api.view.full_detail)
var _shooting := false  # a screenshot is being taken
var _shot_cancel := false  # asked to stop (screenshot_cancel, Esc)
var _shot_cam := {}  # the camera and its framing when the shot began: held there until it is taken
var _shot_froze_input := false  # the player's controls were turned off for the shot
var _progress: CanvasLayer  # the shot's progress: never in the picture (_capture)
var _progress_label: Label
var _progress_bar: ProgressBar
var _shot_layers: Array = []  # CanvasLayers hidden for the screenshot only (add-ons' overlays, the debug menu)
var _shot_pause := ShotPause.new()  # the game paused while a screenshot is taken (its `pause` option)
var _toast: PanelContainer
var _toast_left := 0.0
## Tests without a renderer (headless draws nothing): makes a screenshot's picture instead, given its size.
var test_capture := Callable()
## The interface-hidden state's reason for a screenshot.
const SHOT_REASON := "#screenshot"


func _ready() -> void:
	name = "Addons"
	events.name = "Events"
	add_child(events)
	layer.name = "AddonWindows"
	layer.layer = 15
	add_child(layer)
	_shot_pause.name = "ShotPause"
	add_child(_shot_pause)
	ui_root.name = "Root"
	ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_root.theme = MenuKit.theme()
	layer.add_child(ui_root)
	if autoload:
		load_all()


## Finds the add-ons and starts those switched on.
func load_all(where: Array = []) -> void:
	addons = AddonLoader.scan(where)
	for m: Dictionary in addons:
		if not m["ok"]:
			print("addons: %s not loaded: %s" % [m["id"], m["problem"]])
		elif AddonLoader.enabled(m):
			start(m)
	addons_changed.emit()


func find(id: String) -> Dictionary:
	for m: Dictionary in addons:
		if m["id"] == id:
			return m
	return {}


## Starts an add-on (switched on in the Mods window). False, with m["error"], when it can't.
func start(m: Dictionary) -> bool:
	if m.has("node"):
		return true
	if not m["ok"]:
		m["error"] = str(m["problem"])
		return false
	m.erase("error")
	var unpacked := AddonLoader.unpack(m)  # a zipped add-on, into user://addons-cache/<id>
	if unpacked != "":
		m["error"] = unpacked
		print("addons: %s: %s" % [m["id"], m["error"]])
		return false
	var path := str(m["dir"]).path_join(str(m["entry"]))
	var script = load(path)
	if not script is Script or not (script as Script).can_instantiate():
		m["error"] = "its entry script %s has an error (see the log)" % m["entry"]
		print("addons: %s: %s" % [m["id"], m["error"]])
		return false
	var base := str((script as Script).get_instance_base_type())
	if base != "Node" and not ClassDB.is_parent_class(base, "Node"):
		m["error"] = "its entry script must extend Node"
		print("addons: %s: %s" % [m["id"], m["error"]])
		return false
	var node: Node = (script as Script).new()
	var api := AddonApi.new()
	api._setup(self, m)
	m["object"] = api
	m["node"] = node
	node.name = "Addon_" + str(m["id"]).replace("-", "_")
	add_child(node)
	if node.has_method("addon_start"):
		node.addon_start(api)
	print("addons: %s %s started (%s)" % [m["name"], m["version"], m["dir"]])
	if _game_on:
		api.game_started.emit()
	addons_changed.emit()
	return true


## Stops a running add-on: its addon_stop(), then everything it set up through its API goes.
func stop(m: Dictionary) -> void:
	if not m.has("node"):
		return
	var node: Node = m["node"]
	var api = m["object"]
	if is_instance_valid(node) and node.has_method("addon_stop"):
		node.addon_stop()
	api._teardown()
	_hidden_by.erase(api.id)
	_apply_hidden()
	hold_chunks(api, false)
	full_detail(api, false)
	if is_instance_valid(node):
		node.queue_free()
	m.erase("node")
	m.erase("object")
	addons_changed.emit()


## The Mods window's switch: remembered, and the add-on started or stopped at once.
func set_enabled(id: String, on: bool) -> void:
	var m := find(id)
	if m.is_empty():
		return
	AddonLoader.set_enabled(id, on)
	if on:
		start(m)
	else:
		stop(m)


func running() -> Array:
	return addons.filter(func(m: Dictionary) -> bool: return m.has("object"))


# --- the game ----------------------------------------------------------------------------------

## main.gd built the game's nodes. Add-ons hear of it a moment later, once the menu has said
## which save or address it is (api.storage keys its data by that).
func game_started() -> void:
	_game_on = true
	events.attach(main)
	_tell_started.call_deferred()


func _tell_started() -> void:
	if not _game_on:
		return
	_apply_hold()  # an add-on holding chunks from before this game
	_apply_hidden()  # an add-on that hid the interface before the game's nodes were there
	for m in running():
		m["object"].game_started.emit()


## Called before the game's nodes are freed: add-ons hear of it while they can still save.
func game_ended() -> void:
	if not _game_on:
		return
	if _holder != null:
		var api = _holder
		release_camera(api)
		api.camera._lost()
	for m in running():
		m["object"].game_ended.emit()
	_restore_mouse()
	_hidden_by.clear()  # a new game starts with its interface
	_apply_hidden()
	for m in running():
		m["object"].view._hiding = false
	_daytime_by = ""
	_detail_by.clear()
	FullDetail.clear(main)
	FullDetail.shot_aspect = 0.0
	MomentHold.end()
	FrameBudget.boost = false
	_shot_restore()
	_freeze_shot(false)
	_hide_progress()
	_shot_pause.end()  # a game held for a screenshot is let go before the server is left
	events.detach()
	_game_on = false
	# The next game starts flat until an add-on gives it hills again.
	if _terrain_owner != "":
		preload("res://scripts/world/ground_height.gd").clear()
		_terrain_owner = ""


func in_game() -> bool:
	return _game_on


## One of main.gd's game nodes by its name ("rig", "avatar", "movers"...), or null.
func game_node(field: String):
	if main == null or not _game_on:
		return null
	var n = main.get(field)
	return n if n is Object and is_instance_valid(n) else null


func rig():
	return game_node("rig")


func ui_model():
	var hud = game_node("hud")
	return hud.ui.model if hud != null and hud.get("ui") != null else null


# --- the camera ----------------------------------------------------------------------------------

func camera_holder():
	return _holder


func take_camera(api, with_input: bool) -> bool:
	var r = rig()
	if r == null or (_holder != null and _holder != api):
		return false
	var ride = game_node("ride")
	if ride != null and (ride.riding() or ride.in_hub()):
		return false  # Zenith's own film of the ride, and the hub's view, need the camera
	if r.get("vr_view") != null:
		return false  # in VR the headset is the camera
	if _holder == null:
		r.take_over()
	_holder = api
	_holder_input = with_input
	if not with_input:
		_unlock_input()
	_lock_input()
	return true


func release_camera(api) -> void:
	if _holder != api or api == null:
		return
	_holder = null
	_unlock_input()
	var r = rig()
	if r != null:
		r.hand_back()
	_mouse_managed = false
	_apply_mouse()


## Zenith needs the camera back (a ride started): the add-on is told with `lost`.
func _take_back() -> void:
	var api = _holder
	release_camera(api)
	api.camera._lost()


func _lock_input() -> void:
	if _holder == null or not _holder_input:
		return
	var input = game_node("input")
	if input != null and input.is_processing():
		input.set_process(false)
		input.set_process_unhandled_input(false)
		Bridge.send({"t": "walk", "d": -1})
	_input_locked = true


func _unlock_input() -> void:
	if not _input_locked:
		return
	_input_locked = false
	var input = game_node("input")
	var ride = game_node("ride")
	var fe = game_node("front_end")
	# Under a menu main.gd turns the controls back on when it closes; during a ride, ride.gd does.
	if input != null and not (ride != null and ride.riding()) and not (fe != null and fe.covers_game()):
		input.set_process(true)
		input.set_process_unhandled_input(true)


func _process(delta: float) -> void:
	_finish_frames()
	_tick_toast(delta)
	if not _game_on:
		return
	if _holder != null:
		var r = rig()
		var ride = game_node("ride")
		if r == null or (ride != null and ride.riding()):
			_take_back()
		else:
			# main.gd and ride.gd turn the player's controls back on when their own reasons end.
			_lock_input()
			r.taken_focus = _holder.camera._focus_point()
	_apply_mouse()


## While an add-on has the camera and the player's controls, the events of its camera keys are
## kept from Zenith (E flies up instead of opening the inventory). Esc closes add-ons' windows
## first. The add-ons themselves get every event before this.
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if key.pressed and not key.echo and key.physical_keycode == KEY_ESCAPE and not menu_open() and not debug_menu_open():
		for m in running():
			var open: Array = m["object"].ui._open_windows()
			if not open.is_empty():
				m["object"].ui.show(open[-1], false)
				get_viewport().set_input_as_handled()
				return
	# Kept from Zenith while the debug menu is open too (they don't fly the camera then either).
	if _holder == null or not _holder_input or (keys_blocked() and not debug_menu_open()):
		return
	for action in _holder.keys._camera_actions():
		if event.is_action(action):
			get_viewport().set_input_as_handled()
			return


## Add-ons' keys are off while the player types or Zenith's menus are over the game.
func keys_blocked() -> bool:
	var focus := get_viewport().gui_get_focus_owner()
	return focus is LineEdit or focus is TextEdit or menu_open()


## Zenith's debug menu (Ctrl+F12, debug_menu.gd) is open: the mouse shows over an add-on's camera
## and a hidden interface, and add-ons' camera keys (addon_keys.gd) rest, so typing in its boxes or
## using it doesn't fly the camera. Its global keys (F8, F11) still work.
func debug_menu_open() -> bool:
	var hud = game_node("hud")
	var ui = hud.get("ui") if hud != null else null
	var dm = ui.get("debug_menu") if ui != null else null
	return dm != null and is_instance_valid(dm) and dm.is_open()


func menu_open() -> bool:
	var fe = main.get("front_end") if main != null else null
	return fe != null and is_instance_valid(fe) and fe.has_method("covers_game") and fe.covers_game()


func windows_open() -> bool:
	var hud = game_node("hud")
	if hud != null and hud.get("ui") != null and (hud.ui.is_open() or hud.ui.map_open()):
		return true
	if debug_menu_open():
		return true
	for m in running():
		if not m["object"].ui._open_windows().is_empty():
			return true
	return false


## The mouse: captured for an add-on's mouse look, hidden with the interface, and visible
## whenever a menu or a window wants it. Left alone (first person keeps its own) otherwise.
func _apply_mouse() -> void:
	var want := ""
	if _holder != null and _holder.camera.mouse_captured():
		want = "captured"
	elif interface_hidden():
		want = "hidden"
	if want == "":
		_restore_mouse()
		return
	_mouse_managed = true
	var mode := Input.MOUSE_MODE_VISIBLE
	if not (menu_open() or windows_open()):
		mode = Input.MOUSE_MODE_CAPTURED if want == "captured" else Input.MOUSE_MODE_HIDDEN
	if Input.mouse_mode != mode:
		Input.mouse_mode = mode


func _restore_mouse() -> void:
	if not _mouse_managed:
		return
	_mouse_managed = false
	var r = rig()
	var fp: bool = r != null and r.first_person and not r.taken() and not menu_open()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if fp else Input.MOUSE_MODE_VISIBLE


# --- the interface, frames, the time of day ------------------------------------------------------

func request_hidden(api, on: bool) -> void:
	if on:
		_hidden_by[api.id] = true
	else:
		_hidden_by.erase(api.id)
	_apply_hidden()


func interface_hidden() -> bool:
	return not _hidden_by.is_empty()


## Nodes in the 3D world that are part of the interface and hide with it, as Factorio's do with its
## GUI hidden: the alert icons over entities (alert_icons.gd) and the no-power icons (fluids_power.gd).
## They follow InterfaceState's one flag themselves, every frame, so ones made after the interface hid
## stay hidden too (the B-roll filmed alert triangles over Aquilo's and Gleba's machines).
const HIDE_WITH_INTERFACE := InterfaceState.GROUP
## CanvasLayers that stay as they are when the interface hides (factorio_ui.gd's debug menu layer).
const SHOWN_WITH_INTERFACE_HIDDEN := &"f3d_shown_with_interface_hidden"


## Hides every CanvasLayer of the game (the HUD and its windows, hover lines, the crosshair) but
## the ride's fade, the debug menu's layer (SHOWN_WITH_INTERFACE_HIDDEN), the world's interface icons (HIDE_WITH_INTERFACE) and the hover outline; brings
## them back as they were.
func _apply_hidden() -> void:
	var hiding := interface_hidden() and _game_on
	var game = main.get("_game") if main != null and _game_on else null
	if hiding and _hidden_nodes.is_empty() and game is Node:
		var ride = game_node("ride")
		for n: Node in (game as Node).find_children("*", "CanvasLayer", true, false):
			var layer_node := n as CanvasLayer
			if ride != null and ride.is_ancestor_of(layer_node):
				continue
			if layer_node.is_in_group(SHOWN_WITH_INTERFACE_HIDDEN):
				continue  # the debug menu's layer: it opens over a hidden interface too
			_hidden_nodes.append([layer_node, layer_node.visible])
			layer_node.visible = false
		var input = game_node("input")
		if input != null and input.get("_clean_shot") != null:
			input.set("_clean_shot", true)  # no hover outline or selection
	elif not hiding and not _hidden_nodes.is_empty():
		for pair in _hidden_nodes:
			if is_instance_valid(pair[0]):
				(pair[0] as Node).set("visible", bool(pair[1]))
		_hidden_nodes.clear()
		var input = game_node("input")
		if input != null and input.get("_clean_shot") != null:
			input.set("_clean_shot", OS.get_cmdline_user_args().has("--clean-shot"))
	InterfaceState.set_hidden(&"addons", hiding, get_tree() if is_inside_tree() else null)
	for m in running():
		m["object"].ui._interface_hidden(hiding)
	if hiding and _toast != null:
		_toast.visible = false
	_apply_mouse()


func windows_changed() -> void:
	_apply_mouse()


func save_frame(path: String, viewport: Viewport) -> bool:
	var vp := viewport if viewport != null else get_viewport()
	var tex := vp.get_texture()
	if tex == null:
		return false
	return _save_image(tex.get_image(), path)


## Writes an image as a PNG on a worker thread; `done` (if valid) is called with (path, ok) on the
## main thread once it is written.
func _save_image(image: Image, path: String, done := Callable()) -> bool:
	if image == null or image.is_empty():
		return false
	var target := path
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(target.get_base_dir()))
	var result := [ERR_BUSY]
	_frame_tasks.append(WorkerThreadPool.add_task(func() -> void: result[0] = image.save_png(target), false, "add-on frame"))
	_frame_done.append([target, done, result])
	return true


func frames_pending() -> int:
	return _frame_tasks.size()


func _finish_frames() -> void:
	for i in range(_frame_tasks.size() - 1, -1, -1):
		if WorkerThreadPool.is_task_completed(_frame_tasks[i]):
			WorkerThreadPool.wait_for_task_completion(_frame_tasks[i])
			_frame_tasks.remove_at(i)
			var entry: Array = _frame_done[i]
			_frame_done.remove_at(i)
			var done: Callable = entry[1]
			if done.is_valid():
				done.call(str(entry[0]), int(entry[2][0]) == OK)


func _exit_tree() -> void:
	for t in _frame_tasks:
		WorkerThreadPool.wait_for_task_completion(t)
	_frame_tasks.clear()
	_frame_done.clear()
	FullDetail.clear(main)
	MomentHold.end()


func world_3d() -> World3D:
	return get_viewport().find_world_3d() if _game_on else null


func hold_daytime(api, daytime: float) -> void:
	var sky = main.get("_planet_sky") if main != null and _game_on else null
	if sky == null:
		return
	if daytime >= 0.0:
		if _daytime_by == "":
			_daytime_before = float(sky.forced_daytime)
		_daytime_by = api.id
		sky.forced_daytime = fposmod(daytime, 1.0)
	elif _daytime_by == api.id:
		_daytime_by = ""
		sky.forced_daytime = _daytime_before


# --- held chunks, full detail, screenshots (API 1.6) ---------------------------------------------

func hold_chunks(api, on: bool) -> void:
	var key := str(api.id) if api != null else "#host"
	if on:
		_hold_by[key] = true
	else:
		_hold_by.erase(key)
	_apply_hold()


func holding_chunks() -> bool:
	return not _hold_by.is_empty()


func _apply_hold() -> void:
	var w = game_node("world")
	if w != null and w.has_method("set_hold"):
		w.set_hold(holding_chunks())


func full_detail(api, on: bool) -> void:
	if on and not _game_on:
		return
	if on:
		_detail_by[api.id] = true
	else:
		_detail_by.erase(api.id)
	FullDetail.request(StringName("addon:" + str(api.id)), on, main)


func full_detail_on() -> bool:
	return FullDetail.is_on()


func full_detail_settled() -> bool:
	return FullDetail.settled(main)


func screenshot_busy() -> bool:
	return _shooting


## Stops the screenshot being taken: the game let go, full detail and the interface back, no file.
## False when none is being taken.
func screenshot_cancel() -> bool:
	if not _shooting:
		return false
	_shot_cancel = true
	return true


## Where a screenshot goes: `path` (a .png file, or a folder), else `options.folder`, else
## default_screenshot_folder(); in a folder, the next free zenith-<n>.png.
static func screenshot_path(path: Variant, options: Dictionary) -> String:
	var p := str(path) if path != null else ""
	if p.get_extension().to_lower() == "png":
		return p
	var folder := p if p != "" else str(options.get("folder", ""))
	if folder == "":
		folder = default_screenshot_folder()
	var n := 1
	var dir := DirAccess.open(folder)
	if dir != null:
		for f in dir.get_files():
			if f.begins_with("zenith-") and f.get_extension().to_lower() == "png":
				var num := f.get_basename().trim_prefix("zenith-")
				if num.is_valid_int():
					n = maxi(n, int(num) + 1)
	return folder.path_join("zenith-%d.png" % n)


## Screenshots go to the player's Pictures folder, in Zenith (Windows: %USERPROFILE%\Pictures\Zenith),
## where people look for them: user:// is a hidden folder, and inside a packaged app (the Claude app,
## the Microsoft Store) it is redirected to the package's own, which Explorer can't open ("Location is
## not available"). user://screenshots where the system has no Pictures folder.
static func default_screenshot_folder() -> String:
	var pictures := OS.get_system_dir(OS.SYSTEM_DIR_PICTURES)
	if pictures == "":
		return "user://screenshots"
	return pictures.path_join("Zenith")


## Takes a screenshot (api.view.screenshot): the interface hidden, everything drawn at full detail
## and settled, the picture taken and the interface back, then written on a worker thread. Returns
## the path at once ("" while another is being taken, or without a game); screenshot_saved says when
## it is written.
func screenshot(path: Variant, options: Dictionary) -> String:
	if _shooting or not _game_on:
		return ""
	var target := screenshot_path(path, options)
	_shooting = true
	_shoot(target, options)
	return target


## The largest a screenshot is each way (Godot's largest texture).
const SHOT_MAX := 16384
## A shot drawn off screen with MSAA steps it down while its samples would take more video memory
## than this: colour (RGBA16F), depth, normal-roughness and velocity, about SHOT_SAMPLE_BYTES a
## sample. An 8K picture at 4x would be about 2.7 GB; at 2x it is 1.3.
const SHOT_MSAA_BYTES := 1536 << 20
const SHOT_SAMPLE_BYTES := 20
## Frames an off-screen shot is drawn before it is taken: TAA (and FSR 2's) starts with no history
## in a new viewport and needs a few frames to settle; without it two (the first frame of a new
## viewport can come out before its shadows are ready).
const SHOT_FRAMES_TAA := 16
const SHOT_FRAMES := 2


## The size a screenshot is drawn at: `size` (a Vector2i, or [width, height]) when it has one, else
## the window's times `scale` (1-4); within SHOT_MAX each way, the shape kept.
static func shot_size(options: Dictionary, window: Vector2i) -> Vector2i:
	var want := Vector2i.ZERO
	var v = options.get("size")
	if v is Vector2i or v is Vector2:
		want = Vector2i(v)
	elif v is Array and (v as Array).size() >= 2:
		want = Vector2i(int(v[0]), int(v[1]))
	if want.x <= 0 or want.y <= 0:
		want = window * clampi(int(options.get("scale", 1)), 1, 4)
	want = Vector2i(maxi(want.x, 16), maxi(want.y, 16))
	var over := maxf(want.x, want.y) / float(SHOT_MAX)
	if over > 1.0:
		want = Vector2i(mini(floori(want.x / over), SHOT_MAX), mini(floori(want.y / over), SHOT_MAX))
	return want


## The MSAA a shot of `size` is drawn with: the window's, stepped down past SHOT_MSAA_BYTES.
static func shot_msaa(msaa: int, size: Vector2i) -> int:
	var pixels := float(size.x) * float(size.y)
	while msaa > Viewport.MSAA_DISABLED and pixels * SHOT_SAMPLE_BYTES * (1 << msaa) > SHOT_MSAA_BYTES:
		msaa -= 1
	return msaa


## Without a `timeout` a screenshot waits while what it waits for still comes: it is taken as it is
## once nothing new has come for SHOT_STALL seconds (no chunk arrived, nothing fewer to draw), or
## after SHOT_MOST. A view zoomed far out may need thousands of chunks; a fixed 20 s took such
## pictures with the far half missing. The progress shows the chunks to come of the shot's fixed set
## (world.gd set_cover), a bar that only moves forward and, once it can tell, about how long is left.
const SHOT_STALL := 20.0
const SHOT_MOST := 300.0
## The estimate (ShotEta) shows when more than this many seconds are left.
const SHOT_ETA_FROM := 8.0


## About how long a screenshot's chunks still take, from how fast they came over the last WINDOW_MSEC
## (the far ones come at another pace than the near ones). -1 until AFTER_MSEC and CHUNKS came.
class ShotEta:
	const WINDOW_MSEC := 20000
	const AFTER_MSEC := 3000
	const CHUNKS := 20
	var _samples: Array = []  # [msec, chunks come], about one a second

	func seconds_left(done: int, left: int, now: int) -> float:
		if _samples.is_empty() or now - int(_samples[-1][0]) >= 1000:
			_samples.append([now, done])
		while _samples.size() > 2 and now - int(_samples[1][0]) >= WINDOW_MSEC:
			_samples.pop_front()
		var first: Array = _samples[0]
		var msec := now - int(first[0])
		var came := done - int(first[1])
		if msec < AFTER_MSEC or came < CHUNKS:
			return -1.0
		return left * (msec / 1000.0) / came

	## "40 s", "3 min".
	static func words(seconds: float) -> String:
		if seconds < 90.0:
			return "%d s" % (maxi(roundi(seconds / 5.0), 1) * 5)
		return "%d min" % roundi(seconds / 60.0)


func _shoot(target: String, options: Dictionary) -> void:
	var detail := bool(options.get("full_detail", true))
	# A `timeout` given is a time limit; none waits while things still come (SHOT_STALL, SHOT_MOST).
	var fixed := options.has("timeout")
	var timeout := clampf(float(options.get("timeout", SHOT_MOST)), 0.0, 300.0)
	var size := shot_size(options, _window_size())
	_shot_cancel = false
	FullDetail.shot_aspect = float(size.x) / float(size.y)
	_show_toast(false)
	_freeze_shot(true)
	# The picture is of this moment: Zenith's view of time stands still until it is taken, however
	# long the view takes to come (the game runs on meanwhile, held only for the last frames).
	MomentHold.begin()
	if bool(options.get("pause", true)):
		_shot_pause.main = main
		_shot_pause.begin(ui_model())
	if bool(options.get("hide_interface", true)):
		# The shared hidden state (the HUD, its windows, icons over entities, the cursor), then every
		# other layer still shown: add-ons' overlays (a recording mark), windows, the debug menu.
		_hidden_by[SHOT_REASON] = true
		_apply_hidden()
		if not bool(options.get("overlays", false)):
			for n: Node in get_tree().root.find_children("*", "CanvasLayer", true, false):
				var l := n as CanvasLayer
				if l.visible and l != _progress:
					_shot_layers.append(l)
					l.visible = false
	_show_progress("Holding the moment, loading the view", 0.0)
	if detail:
		FullDetail.request(&"screenshot", true, main)
		# Everything the camera sees is asked for, not only the view distance round the focus.
		FullDetail.cover(main, true)
		# Nobody plays while it settles: the main thread's sliced work may take longer frames.
		FrameBudget.boost = true
	var t0 := Time.get_ticks_msec()
	var calm := 0
	var frames := 0
	var pausing := true
	var progress_at := t0  # when something last came (no `timeout`)
	var least := -1  # the fewest things left to draw so far
	var arrived := _world_arrival()
	var shown := 0.0  # the bar: it only moves forward
	var eta := ShotEta.new()
	var why_late := ""
	while _game_on and not _shot_cancel and (frames < 3 or (detail and calm < FullDetail.CALM_FRAMES) or pausing):
		await get_tree().process_frame
		frames += 1
		var now := Time.get_ticks_msec()
		var left: Dictionary = FullDetail.pending(main) if detail else {}
		if not fixed:
			var count := 0
			for v in left.values():
				count += int(v) if (v is int or v is float) else 1
			var came := _world_arrival()
			if came != arrived or least < 0 or count < least:
				progress_at = now
				arrived = came
				least = count if least < 0 else mini(least, count)
		if now - t0 > timeout * 1000.0:
			why_late = ("in its timeout of %.0f s" if fixed else "at the longest wait, %.0f s") % timeout
		elif not fixed and now - progress_at > SHOT_STALL * 1000.0:
			why_late = "nothing new for %.0f s, after %.0f s" % [SHOT_STALL, (now - t0) / 1000.0]
		var late := why_late != ""
		var waited := Time.get_ticks_msec() - t0 >= FullDetail.MIN_SECONDS * 1000.0
		if detail:
			calm = calm + 1 if waited and left.is_empty() else 0
		# The game is held once the bridge has sent the view's chunks (held, it sends hardly any): the
		# shot's set only goes down, so this comes once, when it is all there.
		var sent: bool = not detail or (waited and not left.has("chunks") and not left.has("chunks_starting"))
		pausing = _shot_pause.holds_shot(sent, timeout + 15.0) and not late
		var shot := FullDetail.shot_progress(main) if detail else {}
		var total := int(shot.get("total", 0))
		var chunks_left := int(left.get("chunks", 0))
		if chunks_left > 0 and total > 0:
			var done := total - chunks_left - int(shot.get("dropped", 0))
			shown = maxf(shown, 0.7 * clampf(float(total - chunks_left) / total, 0.0, 1.0))
			var text := "Holding the moment, loading the view: %d of %d chunks to come" % [chunks_left, total]
			var seconds := eta.seconds_left(done, chunks_left, now)
			if seconds > SHOT_ETA_FROM:
				text += ", about %s" % ShotEta.words(seconds)
			_show_progress(text, shown)
		elif left.has("chunks_starting") or chunks_left > 0:
			_show_progress("Holding the moment, loading the view", shown)
		elif not left.is_empty():
			shown = maxf(shown, 0.75)
			_show_progress("Holding the moment, drawing everything in view", shown)
		else:
			shown = maxf(shown, 0.8)
			_show_progress("Holding the game" if pausing else "Settling", shown)
		if detail and late:
			var chunks_note := ""
			if total > 0:
				chunks_note = "; %d of the view's %d chunks drawn, %d never sent" % [
					total - chunks_left - int(shot.get("dropped", 0)), total, int(shot.get("dropped", 0))]
			print("addons: the screenshot didn't settle (%s%s; still drawing in view %s): taken as it is" % [why_late, chunks_note, str(left)])
			break
	FrameBudget.boost = false
	var image: Image = null
	if _game_on and not _shot_cancel:
		_show_progress("Taking the picture (%d × %d)" % [size.x, size.y], 0.85)
		image = await _capture(size)
	var cancelled := _shot_cancel
	FullDetail.shot_aspect = 0.0
	_shot_pause.end()
	MomentHold.end()  # from the live state again: what the bridge sent meanwhile is handled now
	if detail:
		FullDetail.cover(main, false)
		FullDetail.request(&"screenshot", false, main)
	_shot_restore()
	_freeze_shot(false)
	_shooting = false
	_shot_cancel = false
	if cancelled:
		print("addons: screenshot %s cancelled" % target)
		_hide_progress()
		screenshot_cancelled.emit(target)
	elif not _save_image(image, target, _screenshot_written):
		print("addons: screenshot %s not taken (nothing drawn)" % target)
		_hide_progress()
		screenshot_saved.emit(target, false)
	else:
		_show_progress("Saving %s" % target.get_file(), 0.95)


## When the world last had a new chunk (world.gd last_arrival_msec), for a screenshot's progress.
func _world_arrival() -> int:
	var w = game_node("world")
	var at = w.get("last_arrival_msec") if w != null else null
	return int(at) if at is int else 0


## The shot's framing held while it is taken: the camera as it was when it began (whoever moves it:
## the player's view, an add-on's camera; re-set just before each frame is drawn), the player's
## controls off (walking would move the view) and the mouse kept from Zenith's camera and menus.
func _freeze_shot(on: bool) -> void:
	var cam := get_viewport().get_camera_3d() if on else null
	if on and cam != null:
		_shot_cam = {"cam": cam, "xform": cam.global_transform, "fov": cam.fov, "size": cam.size}
		if not RenderingServer.frame_pre_draw.is_connected(_hold_shot_camera):
			RenderingServer.frame_pre_draw.connect(_hold_shot_camera)
	elif not on:
		_shot_cam = {}
		if RenderingServer.frame_pre_draw.is_connected(_hold_shot_camera):
			RenderingServer.frame_pre_draw.disconnect(_hold_shot_camera)
	var input = game_node("input")
	if on and input != null and input.is_processing():
		input.set_process(false)
		input.set_process_unhandled_input(false)
		Bridge.send({"t": "walk", "d": -1})
		_shot_froze_input = true
	elif not on and _shot_froze_input:
		_shot_froze_input = false
		if _input_locked:
			return  # an add-on still has the camera and the controls: they stay off
		var ride = game_node("ride")
		var fe = game_node("front_end")
		if input != null and not (ride != null and ride.riding()) and not (fe != null and fe.covers_game()):
			input.set_process(true)
			input.set_process_unhandled_input(true)


func _hold_shot_camera() -> void:
	var cam: Camera3D = _shot_cam.get("cam")
	if cam == null or not is_instance_valid(cam):
		return
	if cam.global_transform != _shot_cam["xform"]:
		cam.global_transform = _shot_cam["xform"]
	cam.fov = float(_shot_cam["fov"])
	cam.size = float(_shot_cam["size"])


## While a screenshot is taken the mouse moves nothing (add-ons get it first and leave it alone too:
## api.view.screenshot_busy), and Esc cancels it.
func _input(event: InputEvent) -> void:
	if not _shooting:
		return
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo \
			and (event as InputEventKey).physical_keycode == KEY_ESCAPE:
		screenshot_cancel()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouse or event is InputEventGesture or event is InputEventScreenDrag or event is InputEventScreenTouch:
		get_viewport().set_input_as_handled()


## The shot's progress, at the bottom middle of the screen in Factorio's frame, on a layer of its own
## that _capture keeps out of the picture.
func _show_progress(text: String, fraction: float) -> void:
	if _progress == null:
		_progress = CanvasLayer.new()
		_progress.name = "ScreenshotProgress"
		_progress.layer = 120
		add_child(_progress)
		var box := PanelContainer.new()
		box.name = "Box"
		box.theme = MenuKit.theme()
		box.theme_type_variation = "FFrame"
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", Kit.px(6))
		_progress_label = Kit.label("", "FHeading")
		_progress_label.name = "Text"
		col.add_child(_progress_label)
		_progress_bar = Kit.progress_bar(Kit.BAR_GREEN)
		_progress_bar.max_value = 1.0
		_progress_bar.step = 0.001
		_progress_bar.custom_minimum_size = Kit.pxv(360, 12)
		col.add_child(_progress_bar)
		var hint := Kit.label("Esc cancels")
		hint.name = "Hint"
		col.add_child(hint)
		box.add_child(col)
		_progress.add_child(box)
	_progress.visible = true
	_progress_label.text = text
	_progress_bar.value = clampf(fraction, 0.0, 1.0)
	var box := _progress.get_node("Box") as PanelContainer
	box.reset_size()
	var screen := get_viewport().get_visible_rect().size
	box.position = Vector2((screen.x - box.size.x) * 0.5, screen.y - box.size.y - Kit.px(48))


func _hide_progress() -> void:
	if _progress != null:
		_progress.visible = false


## The window's size in pixels (the root viewport's).
func _window_size() -> Vector2i:
	var vp := get_viewport()
	if vp is Window:
		return (vp as Window).size
	return Vector2i(vp.get_visible_rect().size)


## The picture: the window as drawn when `size` is the window's, else drawn again at `size` through
## a SubViewport of the same world (_shot_view). If that can't be drawn (too big for the graphics
## card), again without MSAA, and then the window as it is.
func _capture(size: Vector2i) -> Image:
	# Belts sharp in the picture: no motion smear for every frame it may be drawn over (TAA's settle,
	# a retry without MSAA, the window).
	BeltBlur.sharp_frames(SHOT_FRAMES_TAA * 2 + 4)
	if test_capture.is_valid():
		return test_capture.call(size)
	var vp := get_viewport()
	var cam := vp.get_camera_3d()
	if cam != null and size != _window_size():
		var msaa := shot_msaa(vp.msaa_3d, size)
		if msaa != vp.msaa_3d:
			print("addons: the %dx%d screenshot is drawn with less MSAA than the window (video memory)" % [size.x, size.y])
		var big := await _shot_view(vp, cam, size, msaa)
		if _shot_cancel:
			return null
		if big == null and msaa != Viewport.MSAA_DISABLED:
			print("addons: the %dx%d screenshot couldn't be drawn with MSAA: drawn again without it" % [size.x, size.y])
			big = await _shot_view(vp, cam, size, Viewport.MSAA_DISABLED)
		if big != null:
			return big
		print("addons: the %dx%d screenshot couldn't be drawn (too big for the graphics card?): the window taken instead" % [size.x, size.y])
	# The window's picture: the progress hidden for the frame it is taken from.
	var showing := _progress != null and _progress.visible
	if showing:
		_progress.visible = false
	await RenderingServer.frame_post_draw
	var tex := vp.get_texture()
	var image := tex.get_image() if tex != null else null
	if showing and _shooting:
		_progress.visible = true
	return image


## The world drawn again at `size` by a copy of the camera in a SubViewport set up as the window is:
## the environment, sky, look passes and compositor are the world's and the camera's; anti-aliasing,
## TAA, level of detail, shadows and texture filtering copied from the window; at the shot's own
## size whatever the window's render scale, the window's height framed (KEEP_HEIGHT: another shape
## shows more or less at the sides, as games do at a fixed resolution). Null if it couldn't be drawn.
func _shot_view(vp: Viewport, cam: Camera3D, size: Vector2i, msaa: int) -> Image:
	var sub := SubViewport.new()
	sub.name = "ScreenshotView"
	sub.size = size
	sub.world_3d = vp.find_world_3d()
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sub.msaa_3d = msaa as Viewport.MSAA
	sub.screen_space_aa = vp.screen_space_aa
	sub.use_taa = vp.use_taa
	sub.use_debanding = vp.use_debanding
	sub.use_occlusion_culling = vp.use_occlusion_culling
	sub.mesh_lod_threshold = vp.mesh_lod_threshold
	sub.anisotropic_filtering_level = vp.anisotropic_filtering_level
	sub.texture_mipmap_bias = vp.texture_mipmap_bias
	sub.positional_shadow_atlas_size = vp.positional_shadow_atlas_size
	sub.positional_shadow_atlas_16_bits = vp.positional_shadow_atlas_16_bits
	for q in 4:
		sub.set_positional_shadow_atlas_quadrant_subdiv(q, vp.get_positional_shadow_atlas_quadrant_subdiv(q))
	# FSR 2 is the window's anti-aliasing too: kept, at full size. Otherwise plain, at full size.
	var fsr2 := vp.scaling_3d_mode == Viewport.SCALING_3D_MODE_FSR2
	sub.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2 if fsr2 else Viewport.SCALING_3D_MODE_BILINEAR
	sub.scaling_3d_scale = 1.0
	sub.fsr_sharpness = vp.fsr_sharpness if fsr2 else 0.0
	var c := Camera3D.new()
	for prop in ["projection", "near", "far", "cull_mask", "environment", "attributes", "compositor", "h_offset", "v_offset", "frustum_offset", "doppler_tracking"]:
		c.set(prop, cam.get(prop))
	var frame := FullDetail.vertical_frame(cam, Vector2(_window_size()))
	c.keep_aspect = Camera3D.KEEP_HEIGHT
	c.fov = frame.x
	c.size = frame.y
	sub.add_child(c)
	add_child(sub)
	c.global_transform = cam.global_transform
	c.current = true
	var sky_view := main != null and is_instance_valid(main) and "shot_camera" in main
	if sky_view:
		main.set("shot_camera", c)
		main.set("shot_size", Vector2(size))
	var frames := SHOT_FRAMES_TAA if sub.use_taa or fsr2 else SHOT_FRAMES
	for i in frames:
		await RenderingServer.frame_post_draw
		if _shot_cancel:
			break
		if _progress_bar != null:
			_progress_bar.value = 0.85 + 0.1 * float(i + 1) / frames
	var image: Image = null
	if is_instance_valid(sub):
		var tex := sub.get_texture()
		if tex != null:
			image = tex.get_image()
		sub.queue_free()
	if sky_view and is_instance_valid(main):
		main.set("shot_camera", null)
	if _shot_cancel:
		return null
	return image if image != null and not image.is_empty() and image.get_size() == size else null


func _screenshot_written(path: String, ok: bool) -> void:
	print("addons: screenshot %s %s" % [path, "saved" if ok else "couldn't be written"])
	if not _shooting:
		_hide_progress()
	_show_toast(ok, path)
	screenshot_saved.emit(path, ok)


## The interface back after a screenshot, as it was.
func _shot_restore() -> void:
	for l in _shot_layers:
		if is_instance_valid(l):
			(l as CanvasLayer).visible = true
	_shot_layers.clear()
	if _hidden_by.has(SHOT_REASON):
		_hidden_by.erase(SHOT_REASON)
		_apply_hidden()


## "Screenshot saved" for a few seconds at the bottom right, with Open folder, in Factorio's frame.
func _show_toast(on: bool, path := "") -> void:
	if not on:
		if _toast != null:
			_toast.visible = false
		return
	if _toast == null:
		_toast = PanelContainer.new()
		_toast.name = "ScreenshotToast"
		_toast.theme_type_variation = "FFrame"
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", Kit.px(10))
		var text := Kit.label("Screenshot saved", "FHeading")
		text.name = "Text"
		text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(text)
		var open := MenuKit.button("Open folder")
		open.name = "OpenFolder"
		open.pressed.connect(_open_shot_folder)
		row.add_child(open)
		_toast.add_child(row)
		ui_root.add_child(_toast)
	_toast.set_meta("path", path)
	_toast.tooltip_text = ProjectSettings.globalize_path(path)
	_toast.visible = not interface_hidden()
	_toast.reset_size()
	var screen := get_viewport().get_visible_rect().size
	_toast.position = Vector2(screen.x - _toast.size.x - Kit.px(16), screen.y - _toast.size.y - Kit.px(120))
	_toast_left = 5.0


func _open_shot_folder() -> void:
	var file := ProjectSettings.globalize_path(str(_toast.get_meta("path", "")))
	if FileAccess.file_exists(file):
		OS.shell_show_in_file_manager(file)
	else:
		OS.shell_open(file.get_base_dir())


func _tick_toast(delta: float) -> void:
	if _toast == null or not _toast.visible:
		return
	if _toast.get_global_rect().has_point(get_viewport().get_mouse_position()):
		_toast_left = maxf(_toast_left, 1.0)  # stays while the mouse is over it
		return
	_toast_left -= delta
	if _toast_left <= 0.0:
		_toast.visible = false


func requests_changed() -> void:
	var g = game_node("ups_governor")
	if g != null:
		g.changed.emit()  # main.gd applies the settings again, through the governor and the requests


## The save the game was loaded from (its name), or the bridge's address; "" outside a game.
func save_key() -> String:
	if not _game_on or main == null:
		return ""
	var fe = main.get("front_end")
	if fe == null:
		return "game"
	var launcher = fe.get("launcher")
	if str(fe.get("session")) == "launched" and launcher != null and str(launcher.save_path) != "":
		return str(launcher.save_path).get_file().get_basename()
	var address := str(fe.get("session_address"))
	return "address " + address.replace(":", "-") if address != "" else "game"
