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
const AddonWatch := preload("res://scripts/addons/addon_watch.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const Avatar := preload("res://scripts/player/avatar.gd")
const MenuKit := preload("res://scripts/menu/menu_kit.gd")
const InterfaceState := preload("res://scripts/ui/interface_state.gd")
const FullDetail := preload("res://scripts/world/full_detail.gd")
const Kit := preload("res://scripts/ui/factorio/kit.gd")
const ShotPause := preload("res://scripts/addons/shot_pause.gd")
const MomentHold := preload("res://scripts/world/moment_hold.gd")
const FrameBudget := preload("res://scripts/world/frame_budget.gd")
const BeltBlur := preload("res://scripts/world/belt_blur.gd")
const WeatherState := preload("res://scripts/world/weather_state.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const Switches := preload("res://scripts/switches.gd")

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
## (1.7) api.character's and api.camera.mode_changed's watcher: off until an add-on reads them.
var watch := AddonWatch.new(self)
## The add-on whose hills (api.terrain) are drawn now, "" for flat ground.
var _terrain_owner := ""
## The add-on whose weather overrides (api.weather) are active now, "" for none.
var _weather_owner := ""
## Add-ons' windows: over the HUD, under Zenith's menus.
var layer := CanvasLayer.new()
var ui_root := Control.new()
## Look for add-ons when added (off in tests, which call load_all with their own folders).
var autoload := true

var _game_on := false
var _tell_pending := false  # game_started until _tell_started: an add-on starting meanwhile hears it from there, once
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
## L15: "Screenshot saved" for a shot taken with the interface hidden (F11, the Cinematic camera's clean shot)
## waits, and shows when the interface comes back (it never showed at all). A note shown when the interface
## hides waits again. --shot-note=old leaves it hidden as before.
var _toast_waiting := false
var shot_note_waits := not Switches.has("--shot-note=old")
## Tests without a renderer (headless draws nothing): makes a screenshot's picture instead, given its size.
var test_capture := Callable()
## The interface-hidden state's reason for a screenshot.
const SHOT_REASON := "#screenshot"


func _ready() -> void:
	name = "Addons"
	_read_cam_mod_strength()
	Settings.listen(_on_cam_setting)
	events.name = "Events"
	add_child(events)
	add_child(watch)
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
	_connect_link()
	if autoload:
		load_all()


## Finds the add-ons and starts those switched on.
func load_all(where: Array = []) -> void:
	addons = AddonLoader.scan(where)
	_watch_errors()
	_loading = true  # a held reason is logged once _start_held has tried again: ~ may start it a moment later
	for m: Dictionary in _start_order():
		if not m["ok"]:
			print("addons: %s not loaded: %s" % [m["id"], m["problem"]])
		elif AddonLoader.enabled(m):
			start(m)
	_loading = false
	_start_held()  # one whose dependency starts after it (~ doesn't order)
	addons_changed.emit()


func find(id: String) -> Dictionary:
	for m: Dictionary in addons:
		if m["id"] == id:
			return m
	return {}


## Starts an add-on (switched on in the Mods window). False, with m["error"], when it can't.
func start(m: Dictionary) -> bool:
	_take_errors()
	var errors_from: int = m.get("errors_from", _error_seq)  # _read_again's mark, else now
	m.erase("errors_from")
	if m.has("node"):
		return true
	if not m["ok"]:
		m["error"] = str(m["problem"])
		return false
	m.erase("error")
	if not _dependencies_met(m):
		return false
	var unpacked := AddonLoader.unpack(m)  # a zipped add-on, into user://addons-cache/<id>
	if unpacked != "":
		m["error"] = unpacked
		print("addons: %s: %s" % [m["id"], m["error"]])
		return false
	var path := str(m["dir"]).path_join(str(m["entry"]))
	var script = load(path)
	if not script is Script or not (script as Script).can_instantiate():
		m["error"] = _entry_error(m, errors_from)
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
	_start_n += 1
	m["start_n"] = _start_n  # (1.7) the pose layers' order
	node.name = "Addon_" + str(m["id"]).replace("-", "_")
	add_child(node)
	if node.has_method("addon_start"):
		node.addon_start(api)
	print("addons: %s %s started (%s)" % [m["name"], m["version"], m["dir"]])
	if _game_on and not _tell_pending:
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
	api._let_go()
	addons_changed.emit()


## The Mods window's switch: remembered, and the add-on started or stopped at once.
func set_enabled(id: String, on: bool) -> void:
	var m := find(id)
	if m.is_empty():
		return
	AddonLoader.set_enabled(id, on)
	if on:
		_read_again_if_loaded(m)
		start(m)
	else:
		_stop_dependents(m)
		stop(m)
	_start_held()


func running() -> Array:
	return addons.filter(func(m: Dictionary) -> bool: return m.has("object"))


# --- the game ----------------------------------------------------------------------------------

## main.gd built the game's nodes. Add-ons hear of it a moment later, once the menu has said
## which save or address it is (api.storage keys its data by that).
func game_started() -> void:
	_game_on = true
	_tell_pending = true  # one started below (_check_game_mods' held ones) hears it with the rest, later
	_check_game_mods()
	events.attach(main)
	watch.attach(main)
	_attach_creatures()
	_push_lift()  # one set between games (game_ended dropped the rest)
	_push_camera_mod()
	_push_character()  # (1.7) add-ons' attachments and pose, kept across games
	_tell_started.call_deferred()


func _tell_started() -> void:
	if not _game_on:
		return
	_tell_pending = false
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
	_toast_waiting = false  # not shown over the menu
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
	watch.detach()
	_detach_creatures()
	_pull_character()
	_drop_lifts()
	_drop_camera_mods()
	_set_link(false)
	_game_on = false
	_tell_pending = false
	# The next game starts flat until an add-on gives it hills again.
	if _terrain_owner != "":
		preload("res://scripts/world/ground_height.gd").clear()
		_terrain_owner = ""
	if _weather_owner != "":
		WeatherState.clear()
		_weather_owner = ""
	_start_held()  # add-ons stopped for this game's Factorio mods start again


func in_game() -> bool:
	return _game_on


# --- api.creatures (1.9): damage/death hooks and live animation overrides ------------------------

func creatures_node():
	var movers = game_node("movers")
	if movers == null:
		return null
	var c = movers.get("creatures")
	return c if c is Object and is_instance_valid(c) else null


func _attach_creatures() -> void:
	var c = creatures_node()
	if c != null:
		c.on_died_hook = _on_creature_died
	var fx = game_node("fx")
	if fx != null and fx.get("on_damaged_hook") != null:
		fx.on_damaged_hook = _on_creature_damaged
	var weapons = fx.get("weapons") if fx != null else null
	if weapons is Object and is_instance_valid(weapons):
		if weapons.get("on_stream_hook") != null:
			weapons.on_stream_hook = _on_weapon_stream
		if weapons.get("on_ground_hook") != null:
			weapons.on_ground_hook = _on_weapon_ground
	_update_creatures_anim()


func _detach_creatures() -> void:
	var c = creatures_node()
	if c != null:
		c.on_died_hook = Callable()
		c.set_anim_enabled(false)
		c.clear_wounds()
	var fx = game_node("fx")
	if fx != null and fx.get("on_damaged_hook") != null:
		fx.on_damaged_hook = Callable()
	var weapons = fx.get("weapons") if fx != null else null
	if weapons is Object and is_instance_valid(weapons):
		if weapons.get("on_stream_hook") != null:
			weapons.on_stream_hook = Callable()
		if weapons.get("on_ground_hook") != null:
			weapons.on_ground_hook = Callable()
	for m in running():
		var api = m["object"]
		if api != null and api.creatures != null:
			api.creatures._anim_enabled = false
			api.creatures._wounded_units.clear()


func _on_creature_died(info: Dictionary) -> void:
	for m in running():
		var api = m["object"]
		if api != null and api.creatures != null:
			api.creatures.died.emit(info)


func _on_creature_damaged(info: Dictionary) -> void:
	for m in running():
		var api = m["object"]
		if api != null and api.creatures != null:
			api.creatures.damaged.emit(info)


func _on_weapon_stream(info: Dictionary) -> void:
	for m in running():
		var api = m["object"]
		if api != null and api.creatures != null:
			api.creatures.stream_event.emit(info)


func _on_weapon_ground(info: Dictionary) -> void:
	for m in running():
		var api = m["object"]
		if api != null and api.creatures != null:
			api.creatures.ground_fx.emit(info)


func _update_creatures_anim() -> void:
	var c = creatures_node()
	if c == null:
		return
	var on := false
	for m in running():
		var api = m["object"]
		if api != null and api.creatures != null and api.creatures._anim_enabled:
			on = true
			break
	c.set_anim_enabled(on)


func _sync_creature_pack_overrides(families: Array = []) -> void:
	var next := {}
	for m in running():
		var api = m["object"]
		if api != null and api.creatures != null:
			for fam: String in api.creatures._pack_overrides:
				next[fam] = api.creatures._pack_overrides[fam]
	var all_fams := {}
	for fam in ModelLibrary.addon_pack_overrides:
		all_fams[str(fam)] = true
	for fam in next:
		all_fams[str(fam)] = true
	for fam in families:
		all_fams[str(fam)] = true
	var changed: Array = []
	for fam: String in all_fams:
		if str(ModelLibrary.addon_pack_overrides.get(fam, "")) != str(next.get(fam, "")):
			changed.append(fam)
	ModelLibrary.addon_pack_overrides = next
	if not changed.is_empty():
		ModelLibrary.choices_changed(changed)


# --- api.game: add-ons' messages to their Factorio mods (addon_game.gd) ---------------------------

var _channels := {}  # channel -> the AddonApi that opened it
var _link_on := false
var _welcome_mods := {}  # the last welcome's mods, name -> version


func _connect_link() -> void:
	Bridge.ext_received.connect(_on_ext)
	Bridge.welcomed.connect(_on_link_welcome)
	Bridge.connection_lost.connect(_set_link.bind(false))
	Bridge.cue_changed.connect(_on_cue)


## (1.92) The game set a filmed scene's cue: every running add-on hears it.
func _on_cue(tick: int) -> void:
	for m in running():
		m["object"].cue_changed.emit(tick)


## The bridge of the game on carries add-ons' messages (its welcome said `ext`).
func link_on() -> bool:
	return _link_on and Bridge.connected


## The version of Factorio mod `name` in the game on, "" when it has none or no game is on.
func game_mod(name: String) -> String:
	return str(_welcome_mods.get(name, ""))


## Gives `channel` to `api`; false (with a line in the log) when another add-on holds it.
func claim_channel(channel: String, api) -> bool:
	var holder = _channels.get(channel)
	if holder != null and holder != api:
		api.note("api.game.open: the channel %s is %s's" % [channel, holder.id])
		return false
	_channels[channel] = api
	return true


func release_channel(channel: String, api) -> void:
	if _channels.get(channel) == api:
		_channels.erase(channel)


func _on_ext(msg: Dictionary) -> void:
	var channel := str(msg.get("ch", ""))
	var api = _channels.get(channel)
	if msg.has("err"):
		# The channel's mod's handler failed (link.lua), or the bridge closed the channel: a short line in
		# the log naming the mod, the whole text to the add-on (mod_error) and on its page.
		var text := str(msg["err"])
		var line := mod_error_line(channel, text, name_of(str(api.id)) if api != null else "")
		if api != null:
			api.note(line)
			if errors_on:
				_keep_mod_error(str(api.id), mod_error_title(channel, text), line, text)
			api.game._error(channel, text)
		else:
			print("addons: " + line)
		return
	if api != null:
		api.game._receive(channel, msg.get("d"))


## The bridge's text when it closes a channel (link.lua), shown as it is.
const LINK_CLOSED := "closed after repeated errors"


## The Factorio mod's name in a handler's error: Factorio's report starts "The mod <title> (<version>)
## caused a non-recoverable error."; else the channel's mod part.
static func mod_error_title(channel: String, text: String) -> String:
	var first := text.get_slice("\n", 0).strip_edges()
	if first.begins_with("The mod ") and first.contains(") caused"):
		var head := first.substr(8, first.find(") caused") - 8)
		var at := head.rfind(" (")
		if at > 0:
			return head.substr(0, at)
	return channel.get_slice("/", 0)


## The short line for the log and the page. Factorio's own report says "non-recoverable" and names the
## bridge's event "Custom event (ID n)", yet the game went on (the bridge caught it): the line names the
## mod and the add-on and keeps the error's own line (the one after "Error while running event"), else
## the text's first line. The bridge's closing text is shown as it is.
static func mod_error_line(channel: String, text: String, addon_name: String) -> String:
	var title := mod_error_title(channel, text)
	if text.begins_with(LINK_CLOSED):
		return "the channel %s to the Factorio mod %s: %s" % [channel, title, text]
	var lines := text.split("\n")
	var cause := ""
	for i in lines.size():
		if lines[i].strip_edges().begins_with("Error while running event"):
			for j in range(i + 1, lines.size()):
				if lines[j].strip_edges() != "":
					cause = lines[j].strip_edges()
					break
			break
	if cause == "":
		for l in lines:
			if l.strip_edges() != "":
				cause = l.strip_edges()
				break
	var from := ("a message from " + addon_name) if addon_name != "" else ("a message on " + channel)
	return "The Factorio mod %s failed on %s (the game went on): %s" % [title, from, cause]


func _on_link_welcome(msg: Dictionary) -> void:
	_set_link(Bridge.link_version >= 1)
	var mods = msg.get("mods")
	_welcome_mods = (mods as Dictionary).duplicate() if mods is Dictionary else {}


func _set_link(on: bool) -> void:
	if not on:
		_welcome_mods = {}
	if on == _link_on:
		return
	_link_on = on
	for m in running():
		m["object"].game.link_changed.emit(on)


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


## (1.7) `aim_center`, `crosshair`: take()'s "aim": "center" and "crosshair" (camera_rig.gd aims_center).
func take_camera(api, with_input: bool, aim_center := false, crosshair := true) -> bool:
	var r = rig()
	if r == null or (_holder != null and _holder != api):
		return false
	var ride = game_node("ride")
	if ride != null and (ride.riding() or ride.in_hub()):
		return false  # Zenith's own film of the ride, and the hub's view, need the camera
	if r.get("vr_view") != null:
		return false  # in VR the headset is the camera
	r.take_over(aim_center, crosshair)  # taken already by this add-on: only the aim's options change
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
	_take_errors()
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
			r.taken_cone = _holder.camera.has_method("_uses_cone") and bool(_holder.camera._uses_cone())
	_push_view_cone()
	_apply_mouse()


## Tells the world whether the add-on camera's view cone picks the chunks to stream (the rig's `use_view_cone()`;
## only acts with `--camera-cone=on`, see ViewPriority.cone_streaming). Off whenever no add-on holds the camera.
func _push_view_cone() -> void:
	var w = game_node("world")
	if w == null or not w.has_method("set_view_cone"):
		return
	var r = rig()
	w.set_view_cone(r != null and _holder != null and bool(r.use_view_cone()))


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
			input.set("_clean_shot", Switches.has("--clean-shot"))
	InterfaceState.set_hidden(&"addons", hiding, get_tree() if is_inside_tree() else null)
	for m in running():
		m["object"].ui._interface_hidden(hiding)
	if hiding and _toast != null:
		if _toast.visible and shot_note_waits:
			_toast_waiting = true  # back with the interface, its few seconds again
		_toast.visible = false
	elif not interface_hidden() and _toast_waiting and _game_on:
		_toast_waiting = false
		_place_toast()
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
	Settings.unlisten(_on_cam_setting)
	var had_pack_overrides := false
	for m in running():
		var api = m["object"]
		if api != null and api.creatures != null and not api.creatures._pack_overrides.is_empty():
			api.creatures._pack_overrides.clear()
			had_pack_overrides = true
	if had_pack_overrides:
		_sync_creature_pack_overrides()
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


## "Screenshot saved" for a few seconds at the bottom right, with Open folder, in Factorio's frame. With the
## interface hidden it waits for the interface to come back (L15), the newest shot's.
func _show_toast(on: bool, path := "") -> void:
	if not on:
		_toast_waiting = false
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
	if interface_hidden():
		_toast.visible = false
		_toast_waiting = shot_note_waits
		return
	_toast_waiting = false
	_place_toast()


## Shows the note at the bottom right (the window may have changed size while it waited) for its 5 s.
func _place_toast() -> void:
	_toast.visible = true
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


# --- the character's lift (1.7) ------------------------------------------------------------------

## Each add-on's lift (api.character.set_lift), by its AddonCharacter: [Vector3(across x, up, across z),
## whether it moves the camera].
var _lifts := {}


## An add-on's lift set (ZERO takes it away): stored with not-a-number and a negative height as 0,
## and the sum of all, capped (avatar.gd cap_lift), drawn from the next frame. Only lifts with `camera`
## move the eye and the view's centre (their own sum, capped the same).
func character_lift(part, v: Vector3, camera := false) -> void:
	var term := Vector3(0.0 if is_nan(v.x) else v.x, 0.0 if is_nan(v.y) else maxf(v.y, 0.0), 0.0 if is_nan(v.z) else v.z)
	if term == Vector3.ZERO:
		_lifts.erase(part)
	else:
		_lifts[part] = [term, camera]
	_push_lift()


## One add-on's own lift, as stored (ZERO for none).
func lift_of(part) -> Vector3:
	return _lifts[part][0] if _lifts.has(part) else Vector3.ZERO


## All add-ons' lifts together, after the caps; `camera_only`: those set with `camera`.
func lift_sum(camera_only := false) -> Vector3:
	var sum := Vector3.ZERO
	for v: Array in _lifts.values():
		if bool(v[1]) or not camera_only:
			sum += v[0]
	return Avatar.cap_lift(sum)


func _push_lift() -> void:
	var a = game_node("avatar")
	if a != null and a.has_method("set_lifted"):
		a.set_lifted(lift_sum(), lift_sum(true))


## The game's end drops every lift, as it drops the hills: the next game starts on the ground.
func _drop_lifts() -> void:
	_lifts.clear()
	_push_lift()

# --- camera modifiers (1.7) ----------------------------------------------------------------------

## The caps on all add-ons' modifiers together (docs/ADDONS.md): the 1.5 tiles let the mech's eye
## (its head about a tile over Zenith's) be reached; the turns stay small enough that the picture is
## still the player's view.
const MOD_OFFSET_MAX := 1.5
const MOD_PITCH_YAW_MAX := 20.0 * PI / 180.0
const MOD_ROLL_MAX := 45.0 * PI / 180.0
const MOD_FOV_MAX := 30.0

## Each add-on's camera modifier (api.camera.set_modifier), by its AddonCamera: [offset, turn, fov].
var _cam_mods := {}
## Settings > Camera > Add-ons' camera motion (0 to 1): the player's scale on the sum, before the caps,
## for players a bob or a shake makes ill. An add-on's own camera (take()) and its aim aren't scaled.
var cam_mod_strength := 1.0


func _read_cam_mod_strength() -> void:
	cam_mod_strength = clampf(float(Settings.get_value("camera", "addon_motion")) / 100.0, 0.0, 1.0)


func _on_cam_setting(section: String, key: String) -> void:
	if section == "camera" and key == "addon_motion":
		_read_cam_mod_strength()
		_push_camera_mod()


## An add-on's modifier set (all zero takes it away), not-a-number and infinities as 0; the sum of
## all, capped, goes to the rig and is drawn from its next frame.
func camera_modifier(part, offset: Vector3, turn: Vector3, fov: float) -> void:
	var o := _finite3(offset)
	var t := _finite3(turn)
	var f := fov if is_finite(fov) else 0.0
	if o == Vector3.ZERO and t == Vector3.ZERO and f == 0.0:
		_cam_mods.erase(part)
	else:
		_cam_mods[part] = [o, t, f]
	_push_camera_mod()


## One add-on's own modifier, as stored.
func camera_modifier_of(part) -> Dictionary:
	var v: Array = _cam_mods.get(part, [Vector3.ZERO, Vector3.ZERO, 0.0])
	return {"offset": v[0], "turn": v[1], "fov": v[2]}


## All add-ons' modifiers together, scaled by the player's setting, then capped: [offset, turn, fov].
func camera_modifier_sum() -> Array:
	var o := Vector3.ZERO
	var t := Vector3.ZERO
	var f := 0.0
	for v: Array in _cam_mods.values():
		# each scaled and capped first: two finite offsets near float's limit would sum to infinity,
		# and limit_length on that gives not-a-number
		o += ((v[0] as Vector3) * cam_mod_strength).limit_length(MOD_OFFSET_MAX)
		t += _clamp_turn((v[1] as Vector3) * cam_mod_strength)
		f += clampf(float(v[2]) * cam_mod_strength, -MOD_FOV_MAX, MOD_FOV_MAX)
	return [o.limit_length(MOD_OFFSET_MAX), _clamp_turn(t), clampf(f, -MOD_FOV_MAX, MOD_FOV_MAX)]


static func _clamp_turn(t: Vector3) -> Vector3:
	return Vector3(clampf(t.x, -MOD_PITCH_YAW_MAX, MOD_PITCH_YAW_MAX), clampf(t.y, -MOD_PITCH_YAW_MAX, MOD_PITCH_YAW_MAX),
		clampf(t.z, -MOD_ROLL_MAX, MOD_ROLL_MAX))


static func _finite3(v: Vector3) -> Vector3:
	return Vector3(v.x if is_finite(v.x) else 0.0, v.y if is_finite(v.y) else 0.0, v.z if is_finite(v.z) else 0.0)


func _push_camera_mod() -> void:
	var r = rig()
	if r != null and r.has_method("set_modifier"):
		var s := camera_modifier_sum()
		r.set_modifier(s[0], s[1], s[2])


## The game's end drops every modifier, as it drops the lifts.
func _drop_camera_mods() -> void:
	_cam_mods.clear()
	_push_camera_mod()


# --- the character's attachments, pose layer, muzzle and tools (1.7, api.character) -------------

const CharacterPoints := preload("res://scripts/player/character_points.gd")
## By AddonCharacter: its nodes [node, name, offset]; its pose [turns (API bone -> Vector3), weight,
## replace (true or an Array of names), start order]; its muzzle [node, at]; whether it hides the tools.
## Kept across games and put on the next game's avatar (game_started); freed when the add-on stops.
var _attached := {}
var _poses := {}
var _muzzles := {}
var _tools_hidden := {}
var _start_n := 0  # start order (m["start_n"]): several add-ons' pose layers apply in it


func character_attach(part, node, to: String, offset: Transform3D) -> bool:
	# validity first: `is` on a freed instance is an error
	if not is_instance_valid(node) or not (node is Node3D) or not CharacterPoints.is_name(to):
		return false
	var a = game_node("avatar")
	if a == null or not a.has_method("attach_node"):
		return false
	_unlist(node)
	if not _place_attached(node, to, offset):
		return false
	if not _attached.has(part):
		_attached[part] = []
	(_attached[part] as Array).append([node, to, offset])
	return true


## On the avatar's holder, or `view` on the camera's anchor; false without them.
func _place_attached(node: Node3D, to: String, offset: Transform3D) -> bool:
	var a = game_node("avatar")
	if a == null:
		return false
	if to != "view":
		return bool(a.attach_node(node, to, offset))
	var r = rig()
	if r == null or not r.has_method("view_anchor"):
		return false
	a.detach_node(node)
	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	r.view_anchor().add_child(node)
	node.transform = offset
	Avatar._own_layer(node)
	return true


## Out of the tree, not freed (detach, or the game's nodes about to go).
func _take_out(node) -> void:
	if not is_instance_valid(node):
		return
	var a = game_node("avatar")
	if a != null and a.has_method("detach_node"):
		a.detach_node(node)
	if (node as Node).get_parent() != null:
		(node as Node).get_parent().remove_child(node)


func _unlist(node) -> void:
	for part in _attached:
		var list: Array = _attached[part]
		for i in range(list.size() - 1, -1, -1):
			if list[i][0] == node:
				list.remove_at(i)


func character_detach(part, node) -> void:
	if not _attached.has(part):
		return
	for e: Array in _attached[part]:
		if e[0] == node:
			_unlist(node)
			_take_out(node)
			return


func character_frame(name: String):
	if name == "view":
		var r = rig()
		return r.view_anchor().global_transform if r != null and r.has_method("view_anchor") else null
	var a = game_node("avatar")
	return a.frame_of(name) if a != null and a.has_method("frame_of") else null


func character_rig() -> Dictionary:
	var a = game_node("avatar")
	return a.rig_info() if a != null and a.has_method("rig_info") else {}


## This add-on's pose layer (an empty `turns` takes it away): the promised bones only, turns with
## not-a-number and infinities as 0 (an infinite turn would make the bone not-a-number at any
## weight), the weight 0 to 1.
func character_pose(part, turns: Dictionary, options := {}) -> void:
	var clean := {}
	for k in turns:
		var t = turns[k]
		if CharacterPoints.BONES.has(str(k)) and t is Vector3:
			var v: Vector3 = t
			clean[str(k)] = _finite3(v)
	if clean.is_empty():
		_poses.erase(part)
	else:
		var w := float(options.get("weight", 1.0))
		var rep = options.get("replace", false)
		var api = part._api.get_ref() if part._api != null else null
		var order := int(find(str(api.id)).get("start_n", 0)) if api != null else 0
		_poses[part] = [clean, 0.0 if is_nan(w) else clampf(w, 0.0, 1.0), rep if rep is Array else bool(rep), order]
	_push_pose()


func pose_of(part) -> Dictionary:
	return (_poses[part][0] as Dictionary).duplicate() if _poses.has(part) else {}


func _push_pose() -> void:
	var a = game_node("avatar")
	if a == null or not a.has_method("set_pose_layer"):
		return
	var layers: Array = _poses.values()
	layers.sort_custom(func(x: Array, y: Array) -> bool: return int(x[3]) < int(y[3]))
	var entries: Array = []
	for l: Array in layers:
		for bone in l[0]:
			var rep: bool = l[2] if l[2] is bool else (l[2] as Array).has(bone)
			entries.append([bone, l[0][bone], l[1], rep])
	a.set_pose_layer(entries)


func character_muzzle(part, node, at := Vector3.ZERO) -> void:
	_muzzles.erase(part)  # set again: the newest wins
	if is_instance_valid(node) and node is Node3D:
		_muzzles[part] = [node, at]
	_push_muzzle()


func _push_muzzle() -> void:
	var a = game_node("avatar")
	if a == null or not a.has_method("set_addon_muzzle"):
		return
	# an add-on may free its node without clear_muzzle(): those entries go, the one before takes over
	for part in _muzzles.keys():
		if not is_instance_valid((_muzzles[part] as Array)[0]):
			_muzzles.erase(part)
	var last: Array = _muzzles.values().back() if not _muzzles.is_empty() else [null, Vector3.ZERO]
	a.set_addon_muzzle(last[0], last[1])


func character_tools(part, hide: bool) -> void:
	if hide:
		_tools_hidden[part] = true
	else:
		_tools_hidden.erase(part)
	var a = game_node("avatar")
	if a != null and "tools_hidden" in a:
		a.tools_hidden = not _tools_hidden.is_empty()


## The add-on stopped: its nodes freed, its pose, muzzle and tools taken away.
func character_release(part) -> void:
	for e: Array in _attached.get(part, []):
		_take_out(e[0])
		if is_instance_valid(e[0]):
			(e[0] as Node).queue_free()
	_attached.erase(part)
	if _poses.has(part):
		_poses.erase(part)
		_push_pose()
	if _muzzles.has(part):
		_muzzles.erase(part)
		_push_muzzle()
	if _tools_hidden.has(part):
		character_tools(part, false)


## A new game's avatar: everything kept put on it.
func _push_character() -> void:
	for part in _attached:
		var list: Array = _attached[part]
		for i in range(list.size() - 1, -1, -1):
			var e: Array = list[i]
			if not is_instance_valid(e[0]):
				list.remove_at(i)
			else:
				_place_attached(e[0], str(e[1]), e[2])
	if not _poses.is_empty():
		_push_pose()
	if not _muzzles.is_empty():
		_push_muzzle()
	if not _tools_hidden.is_empty():
		var a = game_node("avatar")
		if a != null and "tools_hidden" in a:
			a.tools_hidden = true


## The game's nodes are about to go: the add-ons' nodes come out first, kept for the next game.
func _pull_character() -> void:
	for part in _attached:
		for e: Array in _attached[part]:
			_take_out(e[0])

# --- reloading an add-on in development, its script errors (docs/ADDONS.md, "Testing") -------------

## Reload: the Add-ons window's Reload button, the reload key (addons_reload) and switching an add-on off
## and on read its addon.json and scripts from disk again. --addon-reload=off: as before (a restart).
var reload_on := Switches.on("--addon-reload")
## --addons-dev: every add-on's page has Reload, not only those given with --addons.
var addons_dev := Switches.has("--addons-dev")
## Script errors in add-ons' files listed on their pages (addon_errors.gd). --addon-errors=off: only the log.
var errors_on := Switches.on("--addon-errors")
## Kept per add-on: the newest, repeats counted.
const ERRORS_KEPT := 20
const Controls := preload("res://scripts/player/controls.gd")

var _errors_logger = null  # addon_errors.gd, while errors_on and the engine has Logger (4.5)
var _errors := {}  # add-on id -> [{file (relative to its folder), line, message, count}]
var _errors_told := {}  # add-on id -> true once its first error was announced this run
var _error_dirs: Array = []  # [prefix, id], longest first
var _error_seq := 0  # counts errors kept (repeats too): an entry's "seq" is when it last happened
var _reloading := {}  # add-on id -> true while its reload runs: a second press meanwhile does nothing
var _private_forms := PackedStringArray()  # _private_dirs(), built once
var _user_dir_re: RegEx = null  # any Windows user folder (short names, other cases): _without_folders' last pass


## Stops the add-on, reads it again from disk (addon.json, a changed zip, its scripts and shaders) and
## starts it. Its keys and settings are declared again by its addon_start. False, with m["error"], when it
## can't start (a parse error: the file, line and message).
func reload(m: Dictionary) -> bool:
	if not reload_on or m.is_empty() or _reloading.has(str(m["id"])):
		return false
	var id := str(m["id"])
	_reloading[id] = true
	var needing := _dependents(m, true)  # read again with it: they may hold its old classes
	for i in range(needing.size() - 1, -1, -1):
		stop(needing[i])
	stop(m)
	# stop() only queues the node to be freed: the scripts are rewritten once it's gone.
	await get_tree().process_frame
	_read_again(m)
	var ok := start(m)
	for other: Dictionary in needing:
		_read_again(other)
		start(other)
	_start_held()
	_reloading.erase(id)
	addons_changed.emit()
	return ok


## The reload key: every add-on given with --addons, running or not (one that failed is tried again).
func reload_given() -> void:
	for m: Dictionary in addons.duplicate():
		if str(m.get("source", "")) == "command line":
			await reload(m)


## The add-on's page offers Reload: for --addons ones (their switch can't be clicked), any with --addons-dev.
func can_reload(m: Dictionary) -> bool:
	if not reload_on or m.is_empty():
		return false
	return str(m.get("source", "")) == "command line" or (addons_dev and AddonLoader.enabled(m))


func _shortcut_input(event: InputEvent) -> void:
	if reload_on and event is InputEventKey and Controls.pressed(event, "addons_reload"):
		get_viewport().set_input_as_handled()
		reload_given()


## Switched on again in this run (its entry script is in Godot's cache): read from disk, as a reload.
func _read_again_if_loaded(m: Dictionary) -> void:
	if reload_on and m.get("ok", false) and str(m.get("entry", "")) != "" \
			and ResourceLoader.has_cached(str(m["dir"]).path_join(str(m["entry"]))):
		_read_again(m)


func _read_again(m: Dictionary) -> void:
	var fresh := AddonLoader.read_zip(str(m["zip"]), str(m["source"])) if m.has("zip") else AddonLoader.read(str(m["dir"]), str(m["source"]))
	if str(fresh["id"]) != str(m["id"]):
		fresh["ok"] = false
		fresh["problem"] = "its addon.json now says id \"%s\": restart Zenith to load it under that id" % fresh["id"]
	for key in ["name", "version", "api", "entry", "description", "author", "inner", "ok", "problem", "dependency_strings", "dependencies"]:
		if fresh.has(key):
			m[key] = fresh[key]
	m.erase("error")
	_take_errors()
	_errors.erase(str(m["id"]))
	m["errors_from"] = _error_seq  # refresh_scripts' errors below count for the start that follows
	if m["ok"]:
		var unpacked := AddonLoader.unpack(m)
		if unpacked != "":
			m["ok"] = false
			m["problem"] = unpacked
			return
		AddonLoader.refresh_scripts(str(m["dir"]))


## Why an entry script didn't load: the first error in the add-on's files since `from` (_error_seq at the
## start or reload: the cause, not the errors that follow from it; "lib/bad.gd line 3: Parse Error: ..."),
## else the newest, else the log.
func _entry_error(m: Dictionary, from := -1) -> String:
	_take_errors()
	# A Factorio mod's errors (_keep_mod_error) are never the entry script's.
	var list: Array = (_errors.get(str(m["id"]), []) as Array).filter(func(k: Dictionary) -> bool: return not k.has("mod"))
	if not list.is_empty():
		var first := {}
		for k: Dictionary in list:
			if int(k["seq"]) > from and (first.is_empty() or int(k["seq"]) < int(first["seq"])):
				first = k
		var e: Dictionary = first if not first.is_empty() else list[-1]
		return "its entry script %s has an error: %s line %d: %s" % [m["entry"], e["file"], int(e["line"]), e["message"]]
	return "its entry script %s has an error (see the log)" % m["entry"]


## The errors kept for an add-on: [{file, line, message, count}], oldest first.
func script_errors(id: String) -> Array:
	return _errors.get(id, [])


## The add-on's errors as text, as the page shows and copies them (paths in its folder, none of the PC's).
## A Factorio mod's error (`mod` set) shows its short line; `full` (Copy) adds its whole report.
func script_errors_text(id: String, full := false) -> String:
	var lines: PackedStringArray = []
	for e: Dictionary in script_errors(id):
		var times := ("  ×%d" % int(e["count"])) if int(e["count"]) > 1 else ""
		if e.has("mod"):
			lines.append(str(e["message"]) + times + (("\n" + str(e["full"]).strip_edges()) if full else ""))
		else:
			lines.append("%s line %d: %s%s" % [e["file"], int(e["line"]), e["message"], times])
	return "\n".join(lines)


## A Factorio mod's error on one of the add-on's channels, listed with its script errors (marked `mod`,
## the mod's title; not announced in the game: the game went on, and the log has its line).
func _keep_mod_error(id: String, title: String, line: String, full: String) -> void:
	full = _without_folders(full)
	_error_seq += 1
	var list: Array = _errors.get(id, [])
	_errors[id] = list
	for e: Dictionary in list:
		if e.has("mod") and e["full"] == full:
			e["count"] = int(e["count"]) + 1
			e["seq"] = _error_seq
			addons_changed.emit()
			return
	list.append({"file": "", "line": 0, "message": line, "full": full, "mod": title, "count": 1, "seq": _error_seq})
	while list.size() > ERRORS_KEPT:
		list.pop_front()
	addons_changed.emit()


## The logger on, told the add-ons' folders (once Logger exists: Godot 4.5).
func _watch_errors() -> void:
	if not errors_on or not ClassDB.class_exists("Logger"):
		return
	_error_dirs.clear()
	var prefixes := PackedStringArray()
	for m: Dictionary in addons:
		var dir := str(m["dir"])
		for p in [dir, ProjectSettings.globalize_path(dir)]:
			var prefix: String = p.trim_suffix("/") + "/"
			if not prefixes.has(prefix):
				prefixes.append(prefix)
				_error_dirs.append([prefix, str(m["id"])])
	_error_dirs.sort_custom(func(a: Array, b: Array) -> bool: return str(a[0]).length() > str(b[0]).length())
	if _errors_logger == null:
		var script = load("res://scripts/addons/addon_errors.gd")
		if not script is Script:
			return
		_errors_logger = (script as Script).new()
		OS.add_logger(_errors_logger)
		tree_exiting.connect(func() -> void:
			if _errors_logger != null:
				OS.remove_logger(_errors_logger)
				_errors_logger = null)
	_errors_logger.set_prefixes(prefixes)


## The errors caught since the last frame, each given to the add-on whose folder holds its file.
func _take_errors() -> void:
	if _errors_logger == null:
		return
	var changed := false
	for e: Array in _errors_logger.take():
		var file := str(e[0])
		for pair: Array in _error_dirs:
			if file.begins_with(str(pair[0])):
				changed = _keep_error(str(pair[1]), file.substr(str(pair[0]).length()), int(e[1]), _without_folders(str(e[2]))) or changed
				break
	if changed:
		addons_changed.emit()


## A message as the page shows and copies it: Godot's text often names a file by its full path. Add-ons'
## folders (as loaded and absolute, a zip's cache folder) go, leaving paths in the add-on's folder; any
## other path in the user's folders becomes <user folder>.
func _without_folders(message: String) -> String:
	for pair: Array in _error_dirs:
		message = _cut(message, str(pair[0]), "")
	if _private_forms.is_empty():
		_private_forms = _private_dirs()
	for dir in _private_forms:
		message = _cut(message, dir, "<user folder>/")
	if _user_dir_re == null:
		_user_dir_re = RegEx.create_from_string("(?i)[a-z]:[\\\\/]users[\\\\/][^\\\\/'\"\\s]+")
	return _user_dir_re.sub(message, "<user folder>", true)


## Every `what` in `text` replaced by `put`; on Windows in any case (its paths are: c:/users/... is C:\Users\...).
static func _cut(text: String, what: String, put: String) -> String:
	if OS.get_name() != "Windows":
		return text.replace(what, put)
	var at := text.findn(what)
	while at >= 0:
		text = text.substr(0, at) + put + text.substr(at + what.length())
		at = text.findn(what, at + put.length())
	return text


func _private_dirs() -> PackedStringArray:
	var out := PackedStringArray()
	for d in [ProjectSettings.globalize_path("user://"), OS.get_environment("USERPROFILE"), OS.get_environment("HOME")]:
		var dir := str(d).replace("\\", "/").trim_suffix("/")
		if dir.length() > 3:  # never a drive or "/" alone
			for form in [dir + "/", dir.replace("/", "\\") + "\\"]:
				if not out.has(form):
					out.append(form)
	out.sort()
	out.reverse()  # a longer folder before one it is inside
	return out


## True when it is a new error (not a repeat).
func _keep_error(id: String, file: String, line: int, message: String) -> bool:
	_error_seq += 1
	var list: Array = _errors.get(id, [])
	_errors[id] = list
	for e: Dictionary in list:
		if e["file"] == file and int(e["line"]) == line and e["message"] == message:
			e["count"] = int(e["count"]) + 1
			e["seq"] = _error_seq
			return false
	list.append({"file": file, "line": line, "message": message, "count": 1, "seq": _error_seq})
	while list.size() > ERRORS_KEPT:
		list.pop_front()
	if not _errors_told.has(id):
		_errors_told[id] = true
		var m := find(id)
		var text := "%s has a script error: see its page in Add-ons" % str(m.get("name", id))
		print("addons: %s (%s line %d: %s)" % [text, file, line, message])
		var hud = game_node("hud")
		if hud != null and hud.has_method("show_message"):
			hud.show_message(text)
	return true


# --- dependencies (addon.json's "dependencies", in Factorio's form; docs/ADDONS.md) ----------------
# Checked when an add-on starts: other add-ons as they are now, the game's Factorio mods (the welcome's)
# only in a game. Zenith never switches an add-on on for another: switching one on is the player's
# consent. One refused for a dependency is "held" and tried again whenever another starts or stops and
# when the game ends. --addon-requires=off (AddonLoader.requires_on): no checks, the order found.

const ModFiles := preload("res://scripts/world/mod_files.gd")

## Tests stand in for the welcome's mods ({name: version}); null: ModFiles.active_mods().
var game_mods_override = null
var _loading := false  # load_all's first pass and _start_held's passes: held reasons not logged yet


func _start_order() -> Array:
	return AddonLoader.order(addons) if AddonLoader.requires_on else addons


## The add-on found with this id (- as _), or {}.
func find_dependency(id: String) -> Dictionary:
	for m: Dictionary in addons:
		if AddonLoader.same_id(str(m["id"]), id):
			return m
	return {}


## An add-on's name by its id, for messages and the page's Needs: line (the id when it isn't found).
func name_of(id: String) -> String:
	var m := find_dependency(id)
	return str(m["name"]) if not m.is_empty() else id


## api.addons.version(id): the running add-on's version, "" when it isn't running.
func running_version(id: String) -> String:
	var m := find_dependency(id)
	return str(m["version"]) if m.has("node") else ""


func _game_mods() -> Dictionary:
	if game_mods_override is Dictionary:
		return game_mods_override
	if not _welcome_mods.is_empty():  # the welcome's list, as api.game.mod reads it (one source)
		return _welcome_mods
	return ModFiles.active_mods()


## start()'s check: false, with m["error"] and m["held"], when a dependency isn't met.
func _dependencies_met(m: Dictionary) -> bool:
	m.erase("held")
	var why := dependency_refusal(m)
	if why == "":
		m.erase("held_why")
		return true
	m["error"] = why
	m["held"] = true
	if not _loading and str(m.get("held_why", "")) != why:  # tried again on every switch: logged once a reason
		m["held_why"] = why
		print("addons: %s not started: %s" % [m["id"], why])
	return false


## Why the add-on can't start now for its dependencies, or "". `assumed`: ids taken as running (a ~
## dependency asks whether the other would start with this one running).
func dependency_refusal(m: Dictionary, assumed := {}) -> String:
	if not AddonLoader.requires_on:
		return ""
	var id := str(m["id"])
	var circle: Dictionary = AddonLoader.cycles(addons)
	if circle.has(id):
		var names := PackedStringArray()
		for other in circle[id]:
			names.append(name_of(str(other)))
		return "it and %s need each other in a circle: none of them can start" % " and ".join(names)
	for d: Dictionary in m.get("dependencies", []):
		if d["mod"]:
			continue
		var other := find_dependency(str(d["name"]))
		var who := "the add-on " + (str(other["name"]) if not other.is_empty() else str(d["name"]))
		var wanted := AddonLoader.version_text(d)
		var installed := str(other.get("version", ""))
		var on := not other.is_empty() and bool(other["ok"]) and AddonLoader.enabled(other)
		if AddonLoader.is_required(d):
			if other.is_empty():
				var hint := ""
				if str(d["name"]) in ["base", "space-age", "quality", "elevated-rails"] \
						or (_game_on and _game_mods().has(str(d["name"]))):
					hint = " (a Factorio mod is written mod:%s)" % str(d["name"])
				return "it needs %s%s, which isn't installed%s" % [who, (" " + wanted) if wanted != "" else "", hint]
			if not bool(other["ok"]):
				return "it needs %s, which couldn't load" % who
			if not AddonLoader.enabled(other):
				return "it needs %s, which is switched off" % who
			if not AddonLoader.version_fits(d, installed):
				return "it needs %s %s (%s is installed)" % [who, wanted, installed]
			if other.has("node") or assumed.has(str(other["id"])):
				continue
			# ~ doesn't order the start, so two may need each other: enough that it would start with this
			# one running (it starts right after); a plain one must be running already.
			if str(d["prefix"]) == "~":
				var with_this := assumed.duplicate()
				with_this[id] = true
				if dependency_refusal(other, with_this) == "":
					continue
			return "it needs %s, which couldn't start (see its page)" % who
		elif AddonLoader.is_optional(d):
			if on and not AddonLoader.version_fits(d, installed):
				return "it works with %s only at %s (%s is installed): update one, or switch %s off" % [who, wanted, installed, str(other["name"])]
		elif other.has("node") and AddonLoader.version_fits(d, installed):
			return "it can't run with %s, which is on" % who
	# Factorio's incompatibility stops both sides: one already running that can't run with this one.
	for r: Dictionary in running():
		if is_same(r, m):
			continue
		for d: Dictionary in r.get("dependencies", []):
			if str(d["prefix"]) == "!" and not d["mod"] and AddonLoader.same_id(str(d["name"]), id) \
					and AddonLoader.version_fits(d, str(m["version"])):
				return "the add-on %s, which is on, can't run with it" % str(r["name"])
	if _game_on:
		return _mods_refusal(m)
	return ""


## Why the add-on can't run in this game for its Factorio mods (mod:<name>), or "". Only in a game: the
## mods are the welcome's.
func _mods_refusal(m: Dictionary) -> String:
	var mods := _game_mods()
	for d: Dictionary in m.get("dependencies", []):
		if not d["mod"]:
			continue
		var mod := str(d["name"])
		var has := mods.has(mod)
		var have := str(mods.get(mod, ""))
		var wanted := AddonLoader.version_text(d)
		if AddonLoader.is_required(d):
			if not has:
				return "this game doesn't have the Factorio mod %s%s" % [mod, (" (" + wanted + ")") if wanted != "" else ""]
			if not AddonLoader.version_fits(d, have):
				return "this game has the Factorio mod %s %s, and it needs %s" % [mod, have, wanted]
		elif AddonLoader.is_optional(d):
			if has and not AddonLoader.version_fits(d, have):
				return "this game has the Factorio mod %s %s, and it works with it only at %s" % [mod, have, wanted]
		elif has and AddonLoader.version_fits(d, have):
			return "it can't run with the Factorio mod %s, which this game has" % mod
	return ""


## Running add-ons that need `m`, directly or through others, in start order: required ones (none and
## ~), and optional ones too when `optional`.
func _dependents(m: Dictionary, optional: bool) -> Array:
	var out: Array = []
	var needed: Array = [m]
	var added := true
	while added:  # again until none joins: ~ doesn't order, so one may come before what it needs
		added = false
		for other: Dictionary in _start_order():
			if not other.has("node") or needed.has(other):
				continue
			for d: Dictionary in other.get("dependencies", []):
				if d["mod"] or not (AddonLoader.is_required(d) or (optional and AddonLoader.is_optional(d))):
					continue
				var hit := false
				for n: Dictionary in needed:
					if AddonLoader.same_id(str(n["id"]), str(d["name"])):
						hit = true
						break
				if hit:
					out.append(other)
					needed.append(other)
					added = true
					break
	return out


## Before `m` stops: the add-ons that need it stop first, last started first. Their own switches stay on,
## so they start again with it (held).
func _stop_dependents(m: Dictionary) -> void:
	if not AddonLoader.requires_on:
		return
	var needing := _dependents(m, false)
	for i in range(needing.size() - 1, -1, -1):
		stop(needing[i])
		needing[i]["held"] = true


## Add-ons held back by a dependency tried again, in start order: one switched back on, or another that
## stopped, or the game that ended, may let them start (or give them a new reason).
func _start_held() -> void:
	if not AddonLoader.requires_on:
		return
	var was_loading := _loading
	_loading = true  # reasons logged below, for those still held once all passes are done
	var started := true
	while started:  # again while one starts: ~ doesn't order, so one may come before what it needs
		started = false
		for m: Dictionary in _start_order():
			if m.get("held", false) and not m.has("node") and bool(m["ok"]) and AddonLoader.enabled(m):
				started = start(m) or started
			elif m.get("held", false) and not AddonLoader.enabled(m):
				m.erase("held")
				m.erase("error")
	_loading = was_loading
	for m: Dictionary in addons:
		if m.get("held", false) and not m.has("node"):
			_dependencies_met(m)


## A game's welcome (game_started): add-ons whose Factorio mods it doesn't meet stop for this game, with
## the reason on their page (and the add-ons that need them first). A welcome again (a resync, the same
## game) changes nothing that is met: nothing restarts.
func _check_game_mods() -> void:
	if not AddonLoader.requires_on:
		return
	var order := _start_order()
	for i in range(order.size() - 1, -1, -1):
		var m: Dictionary = order[i]
		if not m.has("node"):
			continue
		var why := _mods_refusal(m)
		if why == "":
			continue
		_stop_dependents(m)
		stop(m)
		m["error"] = why
		m["held"] = true
		m["held_why"] = why
		print("addons: %s stopped for this game: %s" % [m["id"], why])
	_start_held()
