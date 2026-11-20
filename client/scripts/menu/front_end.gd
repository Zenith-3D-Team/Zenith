extends CanvasLayer
## The game's front end, like Factorio's: the main menu over a live 3D scene (Continue, Single
## player → New game / Load game, Multiplayer → Host new game / Host saved game / Connect to
## address, Settings, Mods, Add-ons, Model packs, About, Exit), the saves (date, preview; Load, Delete), the map
## generator (map_generator_window.gd), starting the headless server (server_launcher.gd) with
## Factorio-style progress, connecting the bridge, the in-game Esc menu (Resume, Save game, Save
## as, Load game, Settings, Add-ons, Model packs, Exit to menu, Quit game), the settings window, the mods list
## (mods_window.gd), the add-ons (addons_window.gd) and the credits.
##
## main.gd creates it. With --factorio-port / --port (or other options that only make sense in a
## game) the menu is skipped and main.gd connects straight away, as before; Esc still opens the
## in-game menu.
##
## Debug options (after `--`), for screenshots and tests:
##   --menu=worlds|new[:tab]|host|connect|hybrid|single|multi|mods|addons[:id]|about|settings[:tab]|progress
##     opens that page at start; esc opens the in-game menu once a game (launched, or direct) is
##     running, save-as its Save as window, settings[:tab] (in a game) its Settings window
##   --menu-launch=<save name or path>   start that save as Load would
##   --menu-new=<name>[:<preset>[:<seed>]]   create a map and start it, as New game would (the
##     map generator's remembered settings when the preset is "last")
##   --menu-connect=<host:port>   connect as Connect to address would (the mock server, a running bridge)
##   --menu-host=<save name>[:<port>]   host that save on the network, as Multiplayer → Host would
##   --menu-preview   the map generator (--menu=new) asks Factorio for its preview at once
##   --menu-esc-after=<s>   once in the game that long, open the Esc menu (screenshots)
##   --menu-save-after=<s>   once in the game that long, save as the Esc menu's Save game does
##   --menu-save-as=<name>   ... with Save as under that name instead
##   --menu-exit-after=<s>   once in the game that long, exit to the menu (saving)
##   --menu-quit-after-exit   then quit (end-to-end tests)
##   --perf-test[=quick|default|extensive]   the performance test (perf_test.gd): without a mode its
##     choice opens; with one it runs at once and Zenith quits when it ends (exit code 0, 2 when a
##     test gave no numbers, 1 when it stopped), printing where the results file is. Dev builds only
##     (Settings.dev_tools()): a public download says so and quits with exit code 3

const ExitGuard := preload("res://scripts/menu/exit_guard.gd")
const Kit := preload("res://scripts/ui/factorio/kit.gd")
const MenuKit := preload("res://scripts/menu/menu_kit.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const SettingsWindow := preload("res://scripts/menu/settings_window.gd")
const Saves := preload("res://scripts/menu/saves.gd")
const Paths := preload("res://scripts/menu/paths.gd")
const BugReport := preload("res://scripts/menu/bug_report.gd")
const ServerLauncher := preload("res://scripts/menu/server_launcher.gd")
const MenuBackground := preload("res://scripts/menu/menu_background.gd")
const Sfx := preload("res://scripts/fx/sfx.gd")
const ColorFilter := preload("res://scripts/menu/color_filter.gd")
const MapGen := preload("res://scripts/menu/map_gen.gd")
const MapGeneratorWindow := preload("res://scripts/menu/map_generator_window.gd")
const ModsWindow := preload("res://scripts/menu/mods_window.gd")
const ModChoices := preload("res://scripts/menu/mod_choices.gd")
const AddonsWindow := preload("res://scripts/menu/addons_window.gd")
const ModelPacksWindow := preload("res://scripts/menu/model_packs_window.gd")
const ModelPacks := preload("res://scripts/world/model_packs.gd")
const BackdropRecorder := preload("res://scripts/menu/backdrop_recorder.gd")
const BackdropList := preload("res://scripts/menu/backdrop_list.gd")
const BACKDROP_TIP := "What the main menu shows behind it: Zenith's own factory, or one of the views you recorded in your games"
const BACKDROP_RECORD_TIP := "Record this spot as it is now (the camera's view and a few seconds of what moves) and show it behind the main menu"
const MODEL_PACKS_TIP := "Which 3D models Zenith draws: the packs in use and their order, and a pack for any one model"
const AddonRequests := preload("res://scripts/addons/addon_requests.gd")
const GameSwap := preload("res://scripts/menu/game_swap.gd")
const Rcon := preload("res://scripts/menu/rcon.gd")
const Controls := preload("res://scripts/player/controls.gd")
const PerfTest := preload("res://scripts/menu/perf_test.gd")

## Zenith's version, from the project settings (application/config/version, the same as the mod's
## info.json: tools/release/package.py checks the two agree).
static var VERSION := "Zenith %s" % str(ProjectSettings.get_setting("application/config/version", "(development build)"))
## Zenith's logo, made by David (Vasillo); assets/branding/ has the other versions. Not under the
## GPL: a fork may delete the folder, and the menu then shows the name instead.
const LOGO_PATH := "res://assets/branding/logo.png"
const CREDITS := "Factorio © Wube Software. Its graphics, sounds and fonts are read from your own Factorio install, not shipped with Zenith."
const CONNECT_TIMEOUT_MSEC := 30000
## The world counts as loaded once this many chunks are drawn (or a few seconds after "ready").
const READY_CHUNKS := 9
const READY_GRACE_MSEC := 6000
## Then the screen stays while the chunks round the character are built with every model and the
## models' pipelines compiled (world.gd join_left, pipeline_warm.gd): a first draw of a model froze
## a frame for 0.2-0.9 s in play. At most this long after "ready"; `--join-warm=off` skips it.
const WARM_GRACE_MSEC := 25000

enum State { MENU, BUSY, CONNECTING, PLAYING }

## main.gd: start_game(), end_game(), set_game_input(on), loaded_chunks(), hud.
var main: Node
var launcher := ServerLauncher.new()
var state := State.MENU
## How the current game was reached: "launched" (our server), "address" or "direct".
var session := ""
var session_address := ""
## RCON of a server on another PC, through its relay (server/relay.py --rcon-port), when the Connect
## dialog was given its password: what pausing needs there (main.gd _has_rcon). Closed with the game.
var remote_rcon: Rcon = null

var _root := Control.new()
var _page: Control = null
var _overlays: Array[Control] = []
var _background: Node3D = null
var _sfx: Node = null
var _progress: Dictionary = {}  # "root", "label", "bar", "cancel" while a progress window shows
var _esc_menu: Control = null
## A backdrop recording from the Esc menu is under way (backdrop_recorder.gd).
var _recording_backdrop := false
## The recording's entry in the list once it is done: {"id", "name", "taken"} (backdrop_list.gd).
var _backdrop_entry := {}
## Seconds till the open Esc menu's backdrop button is checked again (greyed while the join loads).
var _backdrop_button_check := 0.0
var _settings: Control = null
var _connect_started := 0
var _ready_since := 0
var _saves: Array = []
## The folder the load screen shows: {} for the top (every root), else {"source", "dir", "root"}.
var _worlds_dir := {}
var _selected := -1
var _exit_after := -1.0
var _save_after := -1.0
var _esc_after := -1.0
var _quit_after_exit := false
var _played_seconds := 0.0
## The saves page's purpose: "load" (play it here) or "host" (open it to the network).
var _worlds_mode := "load"
## Load game's "Sync mods with save" (Factorio's words): the save with exactly its own mods, without
## those turned on in the Mods window. Off each time the page opens.
var _sync_with_save := false
## The performance test while it runs (perf_test.gd), and what this program's own frames were
## before it (kept low meanwhile, so the window behind the test's Zenith costs next to nothing).
var _perf: Node = null
var _perf_before := {}
## A stand-in for perf_game.gd (the UI test's), used by the next performance test instead.
var perf_runner: Node = null


func _ready() -> void:
	GameSwap.write_launch_info()
	layer = 20
	name = "FrontEnd"
	launcher.name = "ServerLauncher"
	add_child(launcher)
	launcher.progress.connect(_on_launch_progress)
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = MenuKit.theme()
	_root.texture_filter = Kit.FILTER
	add_child(_root)
	add_child(ColorFilter.new())
	get_tree().root.theme = MenuKit.theme()  # dropdown lists and tooltips are windows of their own
	get_tree().auto_accept_quit = false
	var exit_after := Settings.arg_value("--menu-exit-after=")
	if exit_after != "":
		_exit_after = float(exit_after)
	_quit_after_exit = Settings.has_arg("--menu-quit-after-exit")
	if Settings.arg_value("--menu-esc-after=") != "":
		_esc_after = float(Settings.arg_value("--menu-esc-after="))
	if Settings.arg_value("--menu-save-after=") != "":
		_save_after = float(Settings.arg_value("--menu-save-after="))


## Startup without a game: the main menu, then any --menu debug page or launch.
func open_menu() -> void:
	state = State.MENU
	_show_background(true)
	_show_main_menu()
	var page := Settings.arg_value("--menu=")
	match page.get_slice(":", 0):
		"worlds":
			_show_worlds()
		"new":
			_show_worlds()
			_show_new_game({}, page.get_slice(":", 1) if page.contains(":") else "")
		"host":
			_show_host({})
		"single", "multi":
			_show_main_menu(page)
		"mods":
			_show_mods()
		"addons":
			_show_addons(page.get_slice(":", 1) if page.contains(":") else "")
		"about":
			_show_about()
		"connect":
			_show_worlds()
			_show_connect()
		"hybrid":
			_show_worlds()
			_show_hybrid()
		"settings":
			_show_settings(page.get_slice(":", 1) if page.contains(":") else "")
		"progress":
			_show_progress("Starting world", "Loading map…", 0.45, false)
	var launch := Settings.arg_value("--menu-launch=")
	if launch != "":
		var path := launch if launch.contains("/") or launch.contains("\\") else Paths.saves_dir().path_join(launch.trim_suffix(".zip") + ".zip")
		_launch.call_deferred(path)
	var hosted := Settings.arg_value("--menu-host=")
	if hosted != "":
		var host_path := Paths.saves_dir().path_join(hosted.get_slice(":", 0).trim_suffix(".zip") + ".zip")
		var host_port := int(hosted.get_slice(":", 1)) if hosted.contains(":") else 34197
		_launch.call_deferred(host_path, {"name": "Zenith test", "port": host_port, "lan": true, "max_players": 2})
	var address := Settings.arg_value("--menu-connect=")
	if address != "":
		_connect_address.call_deferred(address.get_slice(":", 0), int(address.get_slice(":", 1)))
	var create := Settings.arg_value("--menu-new=")
	if create != "":
		var parts := create.split(":")
		var preset := parts[1] if parts.size() > 1 else "default"
		var map_settings: Variant = preset
		if preset == "last":
			map_settings = MapGen.from_stored(str(Settings.get_value("new_game", "settings")) if Settings.has_value("new_game", "settings") else "")
		_create_and_launch.call_deferred(parts[0], map_settings, parts[2] if parts.size() > 2 else "")
	if Settings.has_arg("--perf-test") and not Settings.dev_tools():
		printerr("--perf-test is in Zenith's development builds only; this is a public download")
		get_tree().quit.call_deferred(PERF_NOT_IN_BUILD)
	elif Settings.has_arg("--perf-test"):
		var perf_mode := Settings.arg_value("--perf-test=").to_lower()
		if PerfTest.MODES.has(perf_mode):
			_start_perf_test.call_deferred(perf_mode, true)
		else:
			_show_perf_test.call_deferred()


## Started straight into a game (--factorio-port): no menu until Esc → Exit to menu.
func open_direct(address: String) -> void:
	state = State.PLAYING
	session = "direct"
	session_address = address
	get_tree().root.theme = MenuKit.theme()
	var page := Settings.arg_value("--menu=")
	if page == "esc" or page.begins_with("settings"):
		_toggle_esc_menu.call_deferred()
	if page.begins_with("settings"):
		_show_settings.call_deferred(page.get_slice(":", 1))  # as the Esc menu's Settings button


## Something of the menus is over the game (the game menu, a dialog, the settings, connecting):
## add-ons leave the keys and the mouse alone meanwhile (scripts/addons/addon_host.gd).
func covers_game() -> bool:
	return state != State.PLAYING or _esc_menu != null or _settings != null or not _overlays.is_empty()


func _process(delta: float) -> void:
	var swapped := GameSwap.poll()
	if swapped != "" and main != null and main.hud != null:
		main.hud.show_message(swapped)
	match state:
		State.CONNECTING:
			_update_connecting()
		State.PLAYING:
			if session == "launched" and not launcher.is_running():
				_server_died()
				return
			_played_seconds += delta
			_check_backdrop_recording()
			_refresh_backdrop_button(delta)
			if main != null and main.hud != null and not main.hud.ui.show_factorio.is_valid():
				main.hud.ui.show_factorio = _show_factorio
			if main != null and main.hud != null and not main.hud.ui.show_model_packs.is_valid():
				main.hud.ui.show_model_packs = open_model_packs
			if _esc_after >= 0.0 and _played_seconds >= _esc_after:
				_esc_after = -1.0
				_toggle_esc_menu()
			if _save_after >= 0.0 and _played_seconds >= _save_after:
				_save_after = -1.0
				print("menu: --menu-save-after reached, saving")
				if Settings.arg_value("--menu-save-as=") != "":
					_save_game_as(Settings.arg_value("--menu-save-as="))
				else:
					_save_game()
			if _exit_after >= 0.0 and _played_seconds >= _exit_after:
				_exit_after = -1.0
				print("menu: --menu-exit-after reached, exiting to the menu")
				_exit_to_menu(true)


## Ctrl+F9 ("Show in Factorio"), or the Factorio button at the HUD's top left: the same game in
## Factorio's own window, started joined to the menu's server if it isn't open.
func _show_factorio() -> void:
	var said := GameSwap.show_factorio(launcher.game_port if session == "launched" and launcher.is_running() else 0,
		"" if Bridge.server_on_this_pc() else Bridge.factorio_host)
	if said != "" and main != null and main.hud != null:
		main.hud.show_message(said)


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and state == State.PLAYING and Controls.pressed(event, "show_factorio"):
		_show_factorio()
		get_viewport().set_input_as_handled()
		return
	if key == null or not key.pressed or key.echo or key.physical_keycode != KEY_ESCAPE:
		return
	if _settings != null:
		return  # the settings window handles its own Esc (a key being rebound, or close)
	if _perf != null:
		_perf.cancel()  # Esc stops the performance test; it cleans up and comes back to the menu
	elif not _overlays.is_empty():
		_pop_overlay()
	elif state == State.PLAYING:
		# Esc closes what the HUD has open first (windows, the map, choosers, the remote view); this
		# node gets Esc before the HUD does, so it asks.
		if _esc_menu != null or main == null or main.hud == null or not main.hud.ui.escape():
			_toggle_esc_menu()
	elif state == State.MENU and _page != null and (_page.name != "MainMenu" or _page.has_meta("sub")):
		_show_main_menu()
	else:
		return
	get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_quit(true)
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT and bool(Settings.get_value("graphics", "minimize_on_focus_loss")) 			and not AddonRequests.keeps_drawing():  # an add-on recording: a minimised window draws nothing
		# Factorio's "Minimize on focus loss", for full screen only (a window can just stay behind).
		var mode := DisplayServer.window_get_mode()
		if mode in [DisplayServer.WINDOW_MODE_FULLSCREEN, DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN]:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN and DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MINIMIZED and bool(Settings.get_value("graphics", "minimize_on_focus_loss")):
		Settings.apply_window(get_tree().root)


# --- pages -----------------------------------------------------------------------------------

func _set_page(page: Control) -> void:
	if _page != null:
		_page.queue_free()
	_page = page
	_root.add_child(page)
	_root.move_child(page, 0)


func _push_overlay(o: Control) -> void:
	_overlays.append(o)
	_root.add_child(o)


func _pop_overlay() -> void:
	if _overlays.is_empty():
		return
	var o: Control = _overlays.pop_back()
	o.queue_free()


func _clear_overlays() -> void:
	while not _overlays.is_empty():
		_pop_overlay()


func _show_background(on: bool) -> void:
	if on and _background == null and main != null:
		_background = MenuBackground.new()
		_background.name = "MenuBackground"
		main.add_child(_background)
		_sfx = Sfx.new()
		_sfx.name = "MenuSfx"
		_background.add_child(_sfx)
	elif not on and _background != null:
		_background.queue_free()
		_background = null
		_sfx = null


## The menu's background made again: the backdrop chosen, or the models changed (a swapped model
## pack shows at once, for a modeller trying their models).
func _rebuild_background() -> void:
	if _background == null:
		return
	_background.get_parent().remove_child(_background)  # (its name free for the new one at once)
	_show_background(false)
	_show_background(true)


## Factorio's main menu, or one of its submenus ("single", "multi") in the same window.
func _show_main_menu(sub := "") -> void:
	var page := Control.new()
	page.name = "MainMenu"
	if sub != "":
		page.set_meta("sub", sub)
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	page.add_child(center)
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", Kit.px(18))
	center.add_child(column)
	if ResourceLoader.exists(LOGO_PATH):
		var logo := TextureRect.new()
		logo.name = "Logo"
		logo.texture = load(LOGO_PATH)
		logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		logo.custom_minimum_size = Kit.pxv(560, 100)
		logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
		column.add_child(logo)
	else:
		var name_label := Label.new()
		name_label.name = "Logo"
		name_label.text = "ZENITH"
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.add_theme_font_size_override("font_size", Kit.px(64))
		column.add_child(name_label)
	var title := {"": "Main menu", "single": "Single player", "multi": "Multiplayer"}
	var parts := MenuKit.window(str(title.get(sub, "Main menu")))
	parts[0].size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	column.add_child(parts[0])
	var box: VBoxContainer = parts[1]
	var inner := Kit.panel("FShallowFrame")
	var buttons := VBoxContainer.new()
	buttons.name = "Buttons"
	buttons.add_theme_constant_override("separation", Kit.px(4))
	var pad := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, Kit.px(8))
	pad.add_child(buttons)
	inner.add_child(pad)
	box.add_child(inner)
	var add := func(text: String, f: Callable, tip := "", green := false, sound := "gui-click") -> Button:
		var b := MenuKit.menu_button(text, green)
		b.name = text.replace(" ", "")
		b.tooltip_text = tip
		_on(b, f, sound)
		buttons.add_child(b)
		return b
	match sub:
		"single":
			add.call("New game", func() -> void: _show_new_game({}), "The map generator, then play the new map")
			add.call("Load game", func() -> void: _show_worlds("load"), "The server's saves and your own Factorio saves")
			add.call("Single-player (hybrid)", _show_hybrid, "Play your own single-player Factorio game through the 3D client")
			add.call("Back", func() -> void: _show_main_menu(), "", false, "gui-back")
		"multi":
			add.call("Host new game", func() -> void: _show_host({}), "A new map that normal Factorio players on your network can join")
			add.call("Host saved game", func() -> void: _show_worlds("host"), "Open a save to normal Factorio players on your network")
			add.call("Connect to address", _show_connect, "Join a bridge that is already running on this computer: a server started by hand, or the mock server")
			add.call("Back", func() -> void: _show_main_menu(), "", false, "gui-back")
		_:
			var latest := _latest_server_save()
			if latest != "":
				add.call("Continue", func() -> void: _launch(latest), "Load %s, the save played last" % latest.get_file().get_basename(), true, "gui-green-confirm")
			add.call("Single player", func() -> void: _show_main_menu("single"))
			add.call("Multiplayer", func() -> void: _show_main_menu("multi"))
			add.call("Settings", func() -> void: _show_settings(""))
			add.call("Mods", _show_mods, "The mods the server plays with")
			add.call("Add-ons", func() -> void: _show_addons(""), "Zenith's add-ons: switch them on and off, their settings and keys")
			add.call("Model packs", _show_model_packs, MODEL_PACKS_TIP)
			add.call("Menu backdrop", _show_backdrop_window, BACKDROP_TIP)
			if Settings.dev_tools():
				add.call("Performance test", _show_perf_test, PERF_TIP)
			add.call("Report a bug", _report_bug, BUG_TIP)
			add.call("About", _show_about)
			add.call("Exit", func() -> void: _quit(true))

	var version := Label.new()
	version.theme_type_variation = "FVersionLabel"
	var exe := Paths.factorio_exe()
	var fver := Paths.factorio_version(exe) if exe != "" else ""
	version.text = VERSION + ("  ·  Factorio %s" % fver if fver != "" else "  ·  Factorio not found (Settings → Factorio)")
	# The install's graphics and sounds are found once, at start-up: a path set since needs a restart.
	if fver != "" and Paths.ItemIcons.factorio_data_dir() == "":
		version.text += "  ·  restart Zenith to load Factorio's graphics"
	version.anchor_top = 1.0
	version.anchor_bottom = 1.0
	version.offset_left = Kit.px(12)
	version.offset_top = -Kit.px(34)
	version.offset_bottom = -Kit.px(8)
	version.mouse_filter = Control.MOUSE_FILTER_IGNORE
	page.add_child(version)
	var credits := Label.new()
	credits.theme_type_variation = "FVersionLabel"
	credits.add_theme_font_size_override("font_size", Kit.px(13))
	credits.text = CREDITS
	credits.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	credits.anchor_left = 1.0
	credits.anchor_right = 1.0
	credits.anchor_top = 1.0
	credits.anchor_bottom = 1.0
	credits.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	credits.offset_right = -Kit.px(12)
	credits.offset_top = -Kit.px(30)
	credits.offset_bottom = -Kit.px(8)
	credits.mouse_filter = Control.MOUSE_FILTER_IGNORE
	page.add_child(credits)
	_set_page(page)


## Factorio's "Load game": the saves on the left, the selected one's preview and details on the
## right; New game, Delete and the other ways in below; Back and Load at the bottom.
func _show_worlds(mode := "load") -> void:
	_worlds_mode = mode
	_worlds_dir = {}
	_sync_with_save = false
	_list_worlds()
	var page := MenuKit.overlay(0.0)
	page.name = "Worlds"
	page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var parts := MenuKit.window("Host saved game" if mode == "host" else "Load game")
	MenuKit.overlay_center(page).add_child(parts[0])
	var box: VBoxContainer = parts[1]
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", Kit.px(12))
	box.add_child(columns)

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", Kit.px(4))
	columns.add_child(left)
	left.add_child(Kit.label("Saves", "FHeading"))
	var deep: Array = Kit.deep_scroll(Kit.pxv(440, 420))
	left.add_child(deep[0])
	var list := VBoxContainer.new()
	list.name = "List"
	list.add_theme_constant_override("separation", 0)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	deep[1].add_child(list)

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", Kit.px(4))
	columns.add_child(right)
	right.add_child(Kit.label("Details", "FHeading"))
	var details := Kit.panel("FShallowFrame")
	details.custom_minimum_size = Kit.pxv(360, 420)
	right.add_child(details)
	var dbox := VBoxContainer.new()
	dbox.name = "Details"
	dbox.add_theme_constant_override("separation", Kit.px(6))
	var dpad := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		dpad.add_theme_constant_override("margin_" + side, Kit.px(8))
	dpad.add_child(dbox)
	details.add_child(dpad)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", Kit.px(8))
	box.add_child(actions)
	var new_game := MenuKit.button("New game", "FGreenButton")
	_on(new_game, func() -> void:
		if _worlds_mode == "host":
			_show_host({})
		else:
			_show_new_game({}))
	actions.add_child(new_game)
	var delete := MenuKit.button("Delete", "FRedButton")
	delete.name = "Delete"
	_on(delete, _confirm_delete)
	actions.add_child(delete)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(spacer)
	var connect := MenuKit.button("Connect to address")
	connect.tooltip_text = "Join a bridge that is already running: a server started by hand, or the mock server"
	_on(connect, _show_connect)
	actions.add_child(connect)
	var hybrid := MenuKit.button("Single-player (hybrid)")
	hybrid.tooltip_text = "Play your own single-player Factorio game through the 3D client"
	_on(hybrid, _show_hybrid)
	actions.add_child(hybrid)

	var row: Array = MenuKit.dialog_buttons("Back", "Host" if mode == "host" else "Load")
	box.add_child(row[0])
	_on(row[1], func() -> void: _show_main_menu("multi" if mode == "host" else "single"), "gui-back")
	var load: Button = row[2]
	load.name = "Load"
	_on(load, _load_selected, "gui-green-confirm")
	_set_page(page)
	_fill_worlds()


## The entries of the folder the load screen shows (_worlds_dir): at the top every root's folders and
## saves, inside a folder "[..]" and that folder's; the first save selected.
func _list_worlds() -> void:
	_saves = []
	if _worlds_dir.is_empty():
		for root: Array in Saves.roots():
			_saves.append_array(Saves.entries(str(root[0]), str(root[1])))
	else:
		_saves.append({"up": true, "folder": true, "name": "..", "source": _worlds_dir["source"], "path": str(_worlds_dir["dir"]).get_base_dir()})
		_saves.append_array(Saves.entries(str(_worlds_dir["source"]), str(_worlds_dir["dir"])))
	_selected = -1
	for i in _saves.size():
		if not _saves[i].get("folder", false):
			_selected = i
			break


## Into a folder of saves, or back up one ("[..]"; from a root's own folders, back to the top).
func _open_worlds_folder(entry: Dictionary) -> void:
	var source := str(entry["source"])
	var root := ""
	for r: Array in Saves.roots():
		if str(r[0]) == source:
			root = str(r[1])
	var dir := str(entry["path"])
	if entry.get("up", false) and dir.simplify_path().length() <= root.simplify_path().length():
		_worlds_dir = {}
	else:
		_worlds_dir = {"source": source, "dir": dir, "root": root}
	_list_worlds()
	_fill_worlds()


func _fill_worlds() -> void:
	if _page == null or _page.name != "Worlds":
		return
	var list: VBoxContainer = _page.find_child("List", true, false)
	for c in list.get_children():
		c.queue_free()
	var last_source := ""
	for i in _saves.size():
		var s: Dictionary = _saves[i]
		if s["source"] != last_source:
			last_source = s["source"]
			var where := "  " + _source_heading(last_source)
			if not _worlds_dir.is_empty():
				where += "  ›  " + str(_worlds_dir["dir"]).trim_prefix(str(_worlds_dir["root"])).trim_prefix("/")
			var head := Kit.label(where, "FHeading")
			head.custom_minimum_size.y = Kit.px(28)
			head.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			head.clip_text = true
			list.add_child(head)
		if s.get("folder", false):
			# Folders as Factorio's load screen writes them, in brackets; a click goes in.
			var f := Button.new()
			f.name = "Folder-" + str(s["name"]).validate_node_name()
			f.theme_type_variation = "FListItem"
			f.focus_mode = Control.FOCUS_NONE
			f.custom_minimum_size.y = Kit.px(28)
			f.alignment = HORIZONTAL_ALIGNMENT_LEFT
			f.clip_text = true
			f.text = "  [%s]" % s["name"]
			var entry := s
			_on(f, func() -> void: _open_worlds_folder(entry))
			list.add_child(f)
			continue
		var b := Button.new()
		b.theme_type_variation = "FListItemSelected" if i == _selected else "FListItem"
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size.y = Kit.px(28)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.clip_text = true
		var row := HBoxContainer.new()
		row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		row.offset_left = Kit.px(8)
		row.offset_right = -Kit.px(8)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var name_label := Kit.label(str(s["name"]))
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.clip_text = true
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		var date := Kit.label(Saves.when(int(s["modified"])))
		date.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		if i == _selected:
			name_label.add_theme_color_override("font_color", Kit.BLACK)
			date.add_theme_color_override("font_color", Kit.BLACK)
		row.add_child(name_label)
		row.add_child(date)
		b.add_child(row)
		var index := i
		b.pressed.connect(func() -> void:
			_selected = index
			_fill_worlds())
		b.gui_input.connect(func(ev: InputEvent) -> void:
			var mb := ev as InputEventMouseButton
			if mb != null and mb.double_click and mb.button_index == MOUSE_BUTTON_LEFT:
				_selected = index
				_load_selected())
		list.add_child(b)
	if _saves.is_empty():
		var none := MenuKit.paragraph("No saves yet. Start a new game.", 400)
		none.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
		list.add_child(none)
	_fill_details()


## The load screen's heading over a root's saves.
static func _source_heading(source: String) -> String:
	match source:
		"server":
			return "Server saves (server/saves)"
		"zenith":
			return "Zenith downloads' saves (loaded as a copy)"
	return "Factorio's saves (loaded as a copy)"


func _fill_details() -> void:
	var dbox: VBoxContainer = _page.find_child("Details", true, false)
	for c in dbox.get_children():
		dbox.remove_child(c)  # at once, so the new SyncMods and ModsNote keep their names
		c.queue_free()
	var load: Button = _page.find_child("Load", true, false)
	var delete: Button = _page.find_child("Delete", true, false)
	load.disabled = _selected < 0
	delete.disabled = _selected < 0 or _saves[_selected]["source"] != "server"
	if _selected < 0 or _saves[_selected].get("folder", false):
		return
	var s: Dictionary = _saves[_selected]
	var preview := TextureRect.new()
	preview.custom_minimum_size = Kit.pxv(344, 194)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	preview.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	preview.texture = Saves.preview(str(s["path"]))
	var frame := Kit.panel("FDeepFrame")
	if preview.texture == null:
		var none := Kit.label("No preview (headless saves have none)")
		none.custom_minimum_size = Kit.pxv(344, 194)
		none.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		none.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		none.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
		frame.add_child(none)
	else:
		frame.add_child(preview)
	dbox.add_child(frame)
	var title := Kit.label(str(s["name"]), "FCaption")
	title.clip_text = true
	title.custom_minimum_size.x = Kit.px(344)
	dbox.add_child(title)
	dbox.add_child(Kit.label("Last played: %s" % Saves.when(int(s["modified"]))))
	dbox.add_child(Kit.label("Size: %.1f MB" % (int(s["size"]) / 1048576.0)))
	var where := "The 3D server's saves"
	if s["source"] == "zenith":
		where = "Saved by a downloaded Zenith (your user folder). Load makes a copy in the server's saves; the original isn't touched."
	elif s["source"] == "factorio":
		where = "Your Factorio saves. Load makes a copy in the server's saves; the original isn't touched."
	var note := MenuKit.paragraph(where, 344)
	note.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
	dbox.add_child(note)
	# The save's mods, with the Mods window's added, as Factorio adds the mods turned on to a save it
	# loads; Sync mods with save loads exactly the save's (server_launcher.gd).
	var sync := MenuKit.checkbox("Sync mods with save", _sync_with_save)
	sync.name = "SyncMods"
	sync.tooltip_text = "Load with exactly the mods the save was made with, at its versions"
	sync.toggled.connect(func(on: bool) -> void:
		Sfx.play_ui("gui-checkbox-click")
		_sync_with_save = on
		_fill_details.call_deferred())  # not inside the box's own signal: it is taken out
	dbox.add_child(sync)
	var chosen := ModChoices.added(ModChoices.states())
	var mods_text := "Loads with the save's own mods."
	if _sync_with_save:
		mods_text = "Loads with exactly the save's mods, at its versions."
	elif not chosen.is_empty():
		var names := ", ".join(chosen.slice(0, 6)) + (" and %d more" % (chosen.size() - 6) if chosen.size() > 6 else "")
		mods_text = "Loads with the save's own mods and those turned on in the Mods window: %s." % names
	var mods_note := MenuKit.paragraph(mods_text, 344)
	mods_note.name = "ModsNote"
	mods_note.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
	dbox.add_child(mods_note)


func _latest_server_save() -> String:
	var newest := ""
	var newest_time := 0
	for s in Saves.list():
		if s["source"] == "server" and int(s["modified"]) > newest_time:
			newest = str(s["path"])
			newest_time = int(s["modified"])
	return newest


func _load_selected() -> void:
	if _selected < 0 or _selected >= _saves.size() or _saves[_selected].get("folder", false):
		return
	var s: Dictionary = _saves[_selected]
	var path := str(s["path"])
	if s["source"] != "server":
		path = Saves.copy_to_server(path)
		if path == "":
			_show_message("Error", "Couldn't copy %s into %s." % [s["path"], Paths.saves_dir()])
			return
	if _worlds_mode == "host":
		_show_host({"save": path, "sync": _sync_with_save})
	else:
		_launch(path, {}, _sync_with_save)


func _confirm_delete() -> void:
	if _selected < 0 or _saves[_selected]["source"] != "server":
		return
	var s: Dictionary = _saves[_selected]
	_show_confirm("Delete save", "Delete \"%s\"? It goes to the recycle bin." % s["name"], "Delete", func() -> void:
		if not Saves.delete(str(s["path"])):
			_show_message("Error", "Couldn't delete %s." % s["path"])
		_list_worlds()
		_fill_worlds(), true)


## Factorio's map generator; Play creates the map and starts it (hosted when `host` is set).
func _show_new_game(host: Dictionary, tab := "") -> void:
	var o := MenuKit.overlay(0.35)
	o.name = "MapGenerator"
	var window := MapGeneratorWindow.new()
	window.launcher = launcher
	MenuKit.overlay_center(o).add_child(window)
	window.closed.connect(_pop_overlay)
	window.play.connect(func(save_name: String, map_settings: Dictionary, seed_text: String, exchange: String) -> void:
		if save_name == "":
			_show_message("Error", "Give the new game a name.")
			return
		if FileAccess.file_exists(Paths.saves_dir().path_join(save_name + ".zip")):
			_show_message("Error", "There is already a save called \"%s\"." % save_name)
			return
		_clear_overlays()
		_create_and_launch(save_name, map_settings, seed_text, exchange, host))
	_push_overlay(o)
	if tab != "":
		window.open_tab.call_deferred(tab.capitalize())
	if Settings.has_arg("--menu-preview"):
		window.make_preview.call_deferred()


## Multiplayer → Host: the server's name, password, port and player limit, like Factorio's
## "Host game" panel. `host.save` set: host that save; otherwise the map generator follows.
func _show_host(host: Dictionary) -> void:
	var o := MenuKit.overlay(0.35)
	o.name = "Host"
	var parts := MenuKit.window("Host saved game" if host.has("save") else "Host new game")
	MenuKit.overlay_center(o).add_child(parts[0])
	var box: VBoxContainer = parts[1]
	var inner := Kit.panel("FShallowFrame")
	box.add_child(inner)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", Kit.px(16))
	grid.add_theme_constant_override("v_separation", Kit.px(8))
	var pad := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, Kit.px(12))
	pad.add_child(grid)
	inner.add_child(pad)
	var last := {}
	if Settings.has_value("new_game", "host"):
		var parsed = JSON.parse_string(str(Settings.get_value("new_game", "host")))
		if parsed is Dictionary:
			last = parsed
	var name_edit := MenuKit.textbox(str(last.get("name", "Zenith game")))
	name_edit.name = "HostName"
	var desc_edit := MenuKit.textbox(str(last.get("description", "")))
	var port := SpinBox.new()
	port.name = "HostPort"
	port.min_value = 1024
	port.max_value = 65535
	port.value = int(last.get("port", 34197))
	port.custom_minimum_size = Kit.pxv(160, 28)
	var password := MenuKit.textbox("", "No password")
	password.secret = true
	var players := SpinBox.new()
	players.min_value = 0
	players.max_value = 255
	players.value = int(last.get("max_players", 0))
	players.custom_minimum_size = Kit.pxv(160, 28)
	var lan := MenuKit.checkbox("", bool(last.get("lan", true)))
	for row in [["Name", name_edit], ["Description", desc_edit], ["Port", port], ["Password", password],
			["Max players (0: no limit)", players], ["Visible on LAN", lan]]:
		grid.add_child(Kit.label(row[0]))
		grid.add_child(row[1])
	var note := MenuKit.paragraph("Players join with normal Factorio (Multiplayer → Connect to address, this computer's address and the port). The 3D client plays as the bridge's character. Allow the port through the firewall for other computers.", 460)
	note.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
	box.add_child(note)
	var row: Array = MenuKit.dialog_buttons("Back", "Host" if host.has("save") else "Next")
	box.add_child(row[0])
	_on(row[1], _pop_overlay, "gui-back")
	(row[2] as Button).name = "HostConfirm"
	_on(row[2], func() -> void:
		var spec := {"name": name_edit.text.strip_edges(), "description": desc_edit.text.strip_edges(),
			"port": int(port.value), "max_players": int(players.value), "lan": lan.button_pressed}
		Settings.set_value("new_game", "host", JSON.stringify(spec))
		spec["password"] = password.text
		if host.has("save"):
			_clear_overlays()
			_launch(str(host["save"]), spec, bool(host.get("sync", false)))
		else:
			_pop_overlay()
			_show_new_game(spec), "gui-green-confirm")
	_push_overlay(o)


## The Add-ons menu (addons_window.gd): every add-on, its settings and keys; `select` opens one's
## page. From the main menu and the Esc menu (N7: not in Settings).
func _show_addons(select := "") -> void:
	var o := MenuKit.overlay(0.35)
	o.name = "Addons"
	var window := AddonsWindow.new()
	window.addons = main.get("addons") if main != null else null
	window.selected = select
	MenuKit.overlay_center(o).add_child(window)
	window.closed.connect(func() -> void:
		_overlays.erase(o)
		o.queue_free())
	_push_overlay(o)


## The Model packs window (model_packs_window.gd, M7): the packs, their order, a pack for any one
## model. From the main menu and the Esc menu (N7: not in Settings); in a game its changes are drawn at once.
func _show_model_packs() -> void:
	open_model_packs("", "")


## The Model packs window on `pack`'s models with family `fam` shown ("" both: as it opens from the
## menus): the entity info's pack symbol (N8, factorio_ui.gd show_model_packs).
func open_model_packs(pack: String, fam: String) -> void:
	var o := MenuKit.overlay(0.35)
	o.name = "ModelPacks"
	var window := ModelPacksWindow.new()
	window.world = main.get("world") if main != null and state == State.PLAYING else null
	if pack != "":
		window.start_on(pack, fam)
	MenuKit.overlay_center(o).add_child(window)
	var packs_were := ModelPacks.version
	window.closed.connect(func() -> void:
		_overlays.erase(o)
		o.queue_free()
		# The menu's world isn't drawn again when the packs change (world.gd's chunks keep their models).
		if ModelPacks.version != packs_were and state == State.MENU:
			_rebuild_background())
	_push_overlay(o)


## The main menu's Menu backdrop: what the menu shows behind it; the saved backdrops (backdrop_list.gd),
## newest first under Default (Zenith's own), each with its name (edited in place), Use and Delete, the
## one in use marked; Open folder; and how to record another.
func _show_backdrop_window() -> void:
	var o := MenuKit.overlay(0.35)
	o.name = "MenuBackdrop"
	var parts := MenuKit.window("Menu backdrop")
	MenuKit.overlay_center(o).add_child(parts[0])
	var box: VBoxContainer = parts[1]
	var entries := BackdropList.entries()
	var using := BackdropList.in_use()
	var chosen := MenuBackground.chosen_path()
	var shown := "Zenith's own factory (the default)."
	# (A missing or broken file: Default is what shows, so Default is marked.)
	var readable := false
	if chosen != "":
		var snap := BackdropRecorder.read(chosen)
		readable = not snap.is_empty()
		var called := _backdrop_name(entries, using, snap)
		shown = ("\"%s\"." % called) if not snap.is_empty() else "Zenith's own factory: \"%s\" can't be read." % called
	if MenuBackground.force_default:
		shown += " (--menu-backdrop=default: the default this time.)"
	var text := "Shown now: " + shown
	text += "\n\nIn a game: Esc > Use this view as the menu backdrop adds the view to this list. The camera stays where you left it, and what moves there moves behind the menu too."
	var label := MenuKit.paragraph(text, 560)
	label.name = "Shown"
	box.add_child(label)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", Kit.px(8))
	box.add_child(head)
	var title := Kit.label("Backdrops", "FHeading")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(title)
	var open := MenuKit.button("Open folder")
	open.name = "OpenFolder"
	open.tooltip_text = "The folder your backdrops are saved in"
	_on(open, func() -> void: BackdropList.open_folder())
	head.add_child(open)
	var deep: Array = Kit.deep_scroll(Kit.pxv(560, 300))
	box.add_child(deep[0])
	var list := VBoxContainer.new()
	list.name = "Buttons"
	list.add_theme_constant_override("separation", Kit.px(4))
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	deep[1].add_child(list)
	_backdrop_row(list, BackdropList.DEFAULT, "Default: Zenith's own factory", not readable)
	for e: Dictionary in entries:
		_backdrop_row(list, str(e["id"]), str(e["name"]), readable and str(e["id"]) == using)
	var from_world := MenuKit.menu_button("Choose from a world…")
	from_world.name = "ChooseFromAWorld"
	from_world.tooltip_text = "Load a save, go to the spot you want, then Esc > Use this view as the menu backdrop (your own Factorio saves are copied first, never changed)"
	_on(from_world, func() -> void:
		_clear_overlays()
		_show_worlds("load"))
	box.add_child(from_world)
	var row: Array = MenuKit.dialog_buttons("Back", "")
	box.add_child(row[0])
	_on(row[1], _pop_overlay, "gui-back")
	_push_overlay(o)


## One backdrop in the window's list: its name (a text box for a saved one: Enter or leaving it renames
## it), Use (greyed "In use" for the one shown) and Delete (asks first).
func _backdrop_row(list: Container, id: String, called: String, in_use: bool) -> void:
	var row := HBoxContainer.new()
	row.name = "Default" if id == BackdropList.DEFAULT else id
	row.add_theme_constant_override("separation", Kit.px(8))
	row.set_meta("in_use", in_use)
	list.add_child(row)
	if id == BackdropList.DEFAULT:
		var label := Kit.label(called)
		label.name = "Name"
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(label)
	else:
		var edit := MenuKit.textbox(called)
		edit.name = "Name"
		edit.max_length = BackdropList.NAME_MAX
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		edit.tooltip_text = "Its name: click to change it"
		var renamed := func() -> void:
			if is_instance_valid(edit) and edit.text.strip_edges() != called:
				BackdropList.rename(id, edit.text)
		var submitted := func(_t: String) -> void:
			renamed.call()
			edit.release_focus()
		edit.text_submitted.connect(submitted)
		edit.focus_exited.connect(renamed)
		row.add_child(edit)
	var use := MenuKit.button("In use" if in_use else "Use", "FGreenButton" if not in_use else "")
	use.name = "Use"
	use.disabled = in_use
	use.tooltip_text = "Shown behind the main menu now" if in_use else "Show this behind the main menu"
	_on(use, _choose_backdrop.bind(id))
	row.add_child(use)
	if id != BackdropList.DEFAULT:
		var delete := MenuKit.button("Delete", "FRedButton")
		delete.name = "Delete"
		delete.tooltip_text = "Delete this backdrop's file"
		_on(delete, func() -> void:
			var shown := BackdropList.name_of(id)
			_show_confirm("Delete backdrop", "Delete \"%s\"? Its file is deleted for good." % (shown if shown != "" else called), "Delete", func() -> void:
				var was_shown := MenuBackground.chosen_path() == BackdropList.path_of(id)
				if not BackdropList.delete(id):
					_show_message("Error", "Couldn't delete %s." % BackdropList.path_of(id).get_file())
				if was_shown:
					_rebuild_background()
				_pop_overlay()
				_show_backdrop_window(), true))
		row.add_child(delete)
	else:
		# (Default can't be deleted: a gap the width of Delete keeps the Use buttons in one column.)
		var gap := Control.new()
		gap.custom_minimum_size = Kit.pxv(108, 28)
		row.add_child(gap)


func _choose_backdrop(id: String) -> void:
	BackdropList.use(id)
	_rebuild_background()
	_pop_overlay()
	_show_backdrop_window()


## The name the window gives the one in use: from the list, or for the old setting's file its save.
static func _backdrop_name(entries: Array, id: String, snap: Dictionary) -> String:
	for e: Dictionary in entries:
		if str(e["id"]) == id:
			return str(e["name"])
	return BackdropList.default_name(str(snap.get("save", "")), int(snap.get("taken", 0)))


## The Esc menu's "Use this view as the menu backdrop": records the spot the camera shows
## (backdrop_recorder.gd) behind a short progress box; the game's input is off meanwhile.
func _record_backdrop() -> void:
	var rec = main.get("backdrop_recorder") if main != null else null
	var rig = main.get("rig") if main != null else null
	if rec == null or rig == null or _recording_backdrop or rec.recording():
		return  # (one at a time: a second press while one records does nothing)
	var save := launcher.save_path.get_file().get_basename() if session == "launched" and launcher.save_path != "" else session_address
	var avatar = main.get("avatar")
	var now := int(Time.get_unix_time_from_system())
	# A new file each time (--menu-backdrop-save=overwrite: the one in use replaced, as before 0.2.2).
	var using := BackdropList.in_use()
	var id := using if BackdropList.overwrite and BackdropList.valid_id(using) else BackdropList.new_id(now)
	var called := BackdropList.default_name(save, now)
	var info := {"save": save, "name": called, "puppet": int(avatar.unit) if avatar != null else 0}
	if not rec.done.is_connected(_on_backdrop_done):
		rec.done.connect(_on_backdrop_done)
		rec.failed.connect(_on_backdrop_failed)
		rec.progress.connect(_on_backdrop_progress)
	_close_esc_menu()
	if _join_loading():
		_show_message("Menu backdrop", "The view can't be recorded yet: the game is still loading.")
		return
	DirAccess.make_dir_recursive_absolute(BackdropList.dir)
	rec.path = BackdropList.path_of(id)
	if not rec.record(rig.focus_point(), BackdropRecorder.camera_dict(rig.camera), info):
		_show_message("Menu backdrop", "The view can't be recorded yet: the game is still loading.")
		return
	_backdrop_entry = {"id": id, "name": called, "taken": now}
	_recording_backdrop = true
	main.set_game_input(false)
	var cancel := func() -> void:
		rec.cancel()
		_end_backdrop_recording()
	_show_progress("Menu backdrop", "Recording the view…", 0.0, false, cancel)


## A recording that stopped without saying so (a script error in its end, or record() called from
## elsewhere): the progress box goes and the game's input comes back, never left waiting.
func _check_backdrop_recording() -> void:
	if not _recording_backdrop:
		return
	var rec = main.get("backdrop_recorder") if main != null else null
	if rec == null or not rec.recording():
		print("backdrop: the recording stopped without a word: the game's input is back")
		_end_backdrop_recording()


func _on_backdrop_progress(fraction: float) -> void:
	if _recording_backdrop:
		_set_progress("Recording the view…", fraction)
		# 1.0: the file is being written on the worker, and a cancel now would only drop the signal
		# while the file is still replaced, so Cancel goes grey rather than seem to work.
		if fraction >= 1.0 and _progress.get("cancel") is Button:
			(_progress["cancel"] as Button).disabled = true
			(_progress["cancel"] as Button).tooltip_text = "The recording is being saved: a moment"


func _end_backdrop_recording() -> void:
	_recording_backdrop = false
	_hide_progress()
	if state == State.PLAYING and main != null and _esc_menu == null:
		main.set_game_input(true)


## (The recorder's advance(), on the main thread, once a recording: a log line after each step, so a
## hang here shows where it stopped. The owner's second recording in one session froze after "recorded".)
func _on_backdrop_done(_path: String) -> void:
	if not _recording_backdrop:
		print("backdrop: done heard with no recording under way: ignored")
		return
	if OS.get_thread_caller_id() != OS.get_main_thread_id():
		push_error("backdrop: done heard off the main thread")
		_on_backdrop_done.call_deferred(_path)
		return
	_end_backdrop_recording()
	print("backdrop: done 1/3: the progress box gone, the game's input back")
	# (Only the menu reads it: main.gd's listener leaves interface/backdrop alone, where it used to
	# apply every game setting again over every chunk while the world still streamed in.)
	var entry := _backdrop_entry
	_backdrop_entry = {}
	var id := str(entry.get("id", _path.get_file().trim_suffix(BackdropList.EXT)))
	BackdropList.add(id, str(entry.get("name", BackdropList.OLD_NAME)), int(entry.get("taken", Time.get_unix_time_from_system())))
	BackdropList.use(id)
	print("backdrop: done 2/3: listed and the setting saved (interface/backdrop = %s)" % id)
	_show_message("Menu backdrop", "Saved. It shows at the main menu.")
	print("backdrop: done 3/3")


const JOIN_STREAM_SECONDS := 20.0


## The join still loading: the loading screen up, or the chunks round the view not all drawn yet
## (the first stream after it, world.gd square_drawn). A recording waits till it is over.
func _join_loading() -> bool:
	if state != State.PLAYING or main == null:
		return true
	if _played_seconds >= JOIN_STREAM_SECONDS or Settings.arg_value("--backdrop-wait=") == "off":
		return false  # (a view at the map's edge, whose square never fills, can still be recorded)
	var world = main.get("world")
	return world != null and world.has_method("square_drawn") and not world.square_drawn(BackdropRecorder.RADIUS)


## The Esc menu's backdrop button: greyed (with why) while it can't record, else its normal tooltip.
func _set_backdrop_button(button: Button) -> void:
	button.tooltip_text = BACKDROP_RECORD_TIP
	button.disabled = main.get("backdrop_recorder") == null or main.get("rig") == null or _recording_backdrop \
		or main.backdrop_recorder.recording()
	if _recording_backdrop:
		button.tooltip_text = "Recording the view: a moment"
	elif _join_loading():
		button.disabled = true
		button.tooltip_text = "The game is still loading: a moment"


## While the Esc menu stays open with the backdrop button greyed, it is checked again about 4 times
## a second (the join's square drawn, or its 20 s over): enabled without closing and reopening.
func _refresh_backdrop_button(delta: float) -> void:
	_backdrop_button_check -= delta
	if _esc_menu == null or _backdrop_button_check > 0.0 or main == null:
		return
	_backdrop_button_check = 0.25
	var button := _esc_menu.find_child("UseAsBackdrop", true, false) as Button
	if button != null and button.disabled:
		_set_backdrop_button(button)


func _on_backdrop_failed(reason: String) -> void:
	if not _recording_backdrop:
		return
	_end_backdrop_recording()
	_show_message("Menu backdrop", "The view wasn't recorded: %s. Try again in a moment." % reason)


func _show_mods() -> void:
	var o := MenuKit.overlay(0.35)
	o.name = "Mods"
	var window := ModsWindow.new()
	window.read_only = state != State.MENU
	window.addons = main.get("addons") if main != null else null
	MenuKit.overlay_center(o).add_child(window)
	window.closed.connect(func() -> void:
		_overlays.erase(o)
		o.queue_free())
	_push_overlay(o)


## Factorio's About: versions, credits, and Wube's own credits from the install.
func _show_about() -> void:
	var o := MenuKit.overlay(0.35)
	o.name = "About"
	var parts := MenuKit.window("About")
	MenuKit.overlay_center(o).add_child(parts[0])
	var box: VBoxContainer = parts[1]
	var exe := Paths.factorio_exe()
	var fver := Paths.factorio_version(exe) if exe != "" else ""
	var lines := [
		VERSION,
		"Factorio %s (%s)" % [fver, exe] if fver != "" else "Factorio: not found (Settings → Factorio)",
		"Godot %s" % Engine.get_version_info().get("string", ""),
		"",
		CREDITS,
		"Zenith is free software under the GPL-3.0 (LICENSING.md); Wube's printable models, FUE5's models and the logo keep their own licences (CREDITS.md).",
		"Logo and icon by David (Vasillo).",
	]
	box.add_child(MenuKit.paragraph("\n".join(lines), 620))
	var credits_file := Paths.read_data_dir(exe).path_join("credits.txt") if exe != "" else ""
	if credits_file != "" and FileAccess.file_exists(credits_file):
		box.add_child(Kit.label("Factorio's credits (from your install)", "FHeading"))
		var deep: Array = Kit.deep_scroll(Kit.pxv(620, 320))
		box.add_child(deep[0])
		var text := MenuKit.paragraph(FileAccess.get_file_as_string(credits_file), 590)
		deep[1].add_child(text)
	var row: Array = MenuKit.dialog_buttons("Back", "")
	box.add_child(row[0])
	_on(row[1], _pop_overlay, "gui-back")
	_push_overlay(o)


func _show_connect() -> void:
	var o := MenuKit.overlay(0.35)
	var parts := MenuKit.window("Connect to address")
	MenuKit.overlay_center(o).add_child(parts[0])
	var box: VBoxContainer = parts[1]
	box.add_child(MenuKit.paragraph("The address of a running bridge. On this PC: Factorio started with --enable-lua-udp <port> and the factorio-3d-bridge mod (server/run-server.ps1 uses 34200), or the mock server (python tools/mock_server.py). On another PC: that PC's address and the port of the relay running beside its server (python3 server/relay.py, TCP 34200), like 192.168.1.20:34200.", 460))
	var last := str(Settings.get_value("factorio", "last_address"))
	var edit := MenuKit.textbox(last if last != "" else "127.0.0.1:34200")
	edit.custom_minimum_size.x = Kit.px(460)
	box.add_child(edit)
	box.add_child(MenuKit.paragraph("RCON password, for a server on another PC whose relay carries RCON (optional: lets Zenith pause the game there; it is in the server's server/data/rcon-password.txt):", 460))
	var password := MenuKit.textbox("", "none")
	password.secret = true
	password.custom_minimum_size.x = Kit.px(460)
	box.add_child(password)
	var row: Array = MenuKit.dialog_buttons("Back", "Connect")
	box.add_child(row[0])
	_on(row[1], _pop_overlay, "gui-back")
	var go := func() -> void:
		var text := edit.text.strip_edges()
		var address := parse_address(text)
		if address.is_empty():
			_show_message("Error", "\"%s\" isn't an address. Write it as host:port, like 127.0.0.1:34200 or 192.168.1.20:34200." % text)
			return
		Settings.set_value("factorio", "last_address", text)
		_clear_overlays()
		_connect_address(str(address[0]), int(address[1]), password.text)
	_on(row[2], go, "gui-green-confirm")
	edit.text_submitted.connect(func(_t: String) -> void: go.call())
	password.text_submitted.connect(func(_t: String) -> void: go.call())
	_push_overlay(o)
	edit.grab_focus.call_deferred()


## "host:port", "host" (port 34200), "port" (this PC), "[v6 address]:port" -> [host, port]; [] when it
## isn't one. "localhost" is 127.0.0.1.
static func parse_address(text: String) -> Array:
	text = text.strip_edges()
	var host := "127.0.0.1"
	var port_text := ""
	if text.begins_with("["):
		host = text.get_slice("]", 0).trim_prefix("[")
		port_text = text.get_slice("]", 1).trim_prefix(":")
		if port_text == "":
			port_text = "34200"
	elif text.count(":") == 1:
		host = text.get_slice(":", 0)
		port_text = text.get_slice(":", 1)
	elif text.count(":") > 1:
		host = text  # an IPv6 address alone
		port_text = "34200"
	elif text.is_valid_int():
		port_text = text
	else:
		host = text
		port_text = "34200"
	if not port_text.is_valid_int() or host.contains(" "):
		return []
	var port := int(port_text)
	if port <= 0 or port > 65535:
		return []
	if host == "" or host.to_lower() == "localhost":
		host = "127.0.0.1"
	return [host, port]


func _show_hybrid() -> void:
	var o := MenuKit.overlay(0.35)
	var parts := MenuKit.window("Single-player (hybrid)")
	MenuKit.overlay_center(o).add_child(parts[0])
	var box: VBoxContainer = parts[1]
	var steps := [
		"The 3D client can drive your own character in a normal single-player Factorio game:",
		"1.  Link or copy the mod folder into Factorio's mods (%APPDATA%\\Factorio\\mods):\n      " + Paths.mod_dir().replace("/", "\\"),
		"2.  Add --enable-lua-udp 34200 to Factorio's launch options (Steam: Properties → Launch Options).",
		"3.  Start Factorio, load a save, then press Connect below (127.0.0.1:34200).",
		"Inventory, crafting and machine windows work in the Factorio window as usual. Type /f3d-selftest in Factorio's console (~) to check the bridge.",
	]
	for s in steps:
		box.add_child(MenuKit.paragraph(s, 560))
	var row: Array = MenuKit.dialog_buttons("Back", "Connect")
	box.add_child(row[0])
	_on(row[1], _pop_overlay, "gui-back")
	_on(row[2], func() -> void:
		_clear_overlays()
		_connect_address("127.0.0.1", 34200), "gui-green-confirm")
	_push_overlay(o)


## Factorio's Settings: a list of its pages (Graphics, Controls, Sounds, Interface, Other, Mod
## settings; then the client's own Camera and Factorio) with Back; each page opens alone ("Graphics
## settings") with Back to the list and Confirm. `tab` opens that page straight away.
const SETTINGS_PAGES := [["Graphics", "Graphics"], ["Controls", "Controls"], ["Sounds", "Sound"], ["Interface", "Interface"],
	["Other", "Other"], ["Mod settings", "Mod settings"], ["Camera", "Camera"], ["Factorio install", "Factorio"]]


func _show_settings(tab: String) -> void:
	if _settings != null:
		return
	var o := MenuKit.overlay(0.35)
	o.name = "SettingsList"
	var parts := MenuKit.window("Settings")
	MenuKit.overlay_center(o).add_child(parts[0])
	var box: VBoxContainer = parts[1]
	var inner := Kit.panel("FShallowFrame")
	var buttons := VBoxContainer.new()
	buttons.add_theme_constant_override("separation", Kit.px(4))
	var pad := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, Kit.px(4))
	pad.add_child(buttons)
	inner.add_child(pad)
	box.add_child(inner)
	var close_all := func() -> void:
		_settings = null
		o.queue_free()
	for page in SETTINGS_PAGES:
		var b := MenuKit.menu_button(str(page[0]))
		b.name = "Page" + str(page[1]).replace(" ", "")
		var which := str(page[1])
		_on(b, func() -> void: _show_settings_page(which, o, close_all))
		buttons.add_child(b)
	var row: Array = MenuKit.dialog_buttons("Back", "")
	box.add_child(row[0])
	_on(row[1], close_all, "gui-back")
	_root.add_child(o)
	_settings = o
	if tab != "":
		_show_settings_page(tab, o, close_all)


## One page of the settings over the list (hidden meanwhile): Back shows the list again.
func _show_settings_page(tab: String, list: Control, close_all: Callable) -> void:
	var o := MenuKit.overlay(0.0)
	o.name = "SettingsPage"
	var window := SettingsWindow.new()
	window.in_game = state == State.PLAYING
	window.start_tab = tab
	window.page_mode = true
	if state == State.PLAYING and session == "launched":
		window.rcon = launcher.rcon
	MenuKit.overlay_center(o).add_child(window)
	list.visible = false
	window.closed.connect(func() -> void:
		o.queue_free()
		if is_instance_valid(list):
			list.visible = true)
	window.confirmed.connect(func() -> void:
		o.queue_free()
		close_all.call())
	_root.add_child(o)


func _show_message(title: String, text: String) -> void:
	var parts: Array = MenuKit.message(title, text)
	_on(parts[1], _pop_overlay)
	_push_overlay(parts[0])
	print("menu: %s: %s" % [title, text.replace("\n", " | ")])


const BUG_TIP := "Opens GitHub's bug report page and a zip of Zenith's recent logs to add to it"


## Report a bug: what it will open first, then the logs' zip, GitHub's page and the zip's folder
## (bug_report.gd).
func _report_bug() -> void:
	_show_confirm("Report a bug",
		"Zenith packs its recent logs (and the server's) into one zip, then opens GitHub's bug report page in your browser and the folder with the zip. Drag the zip into the report. A GitHub account is needed to post it. The logs may show your user name in file paths.",
		"Open", func() -> void: BugReport.open())


func _show_confirm(title: String, text: String, confirm_text: String, on_confirm: Callable, danger := false) -> void:
	var o := MenuKit.overlay(0.35)
	var parts := MenuKit.window(title)
	MenuKit.overlay_center(o).add_child(parts[0])
	var box: VBoxContainer = parts[1]
	box.add_child(MenuKit.paragraph(text, 420))
	var row: Array = MenuKit.dialog_buttons("Cancel", "" if danger else confirm_text)
	if danger:
		var red := MenuKit.button(confirm_text, "FRedButton")
		row[0].add_child(red)
		row[2] = red
	box.add_child(row[0])
	_on(row[1], _pop_overlay, "gui-back")
	_on(row[2], func() -> void:
		_pop_overlay()
		on_confirm.call())
	_push_overlay(o)


# --- the performance test --------------------------------------------------------------------

## --perf-test's exit code in a public download, which has no performance test.
const PERF_NOT_IN_BUILD := 3
const PERF_TIP := "Measures how smoothly Zenith runs on this PC: Factorio in the background on a test map of its own, Zenith full screen for each test, then one text file to send"


## The performance test (perf_test.gd, docs/PERFORMANCE-TEST.md): what it does, and its three modes.
func _show_perf_test() -> void:
	if state != State.MENU or _perf != null or not Settings.dev_tools():
		return
	var o := MenuKit.overlay(0.35)
	o.name = "PerfTestChoice"
	var parts := MenuKit.window("Performance test")
	MenuKit.overlay_center(o).add_child(parts[0])
	var box: VBoxContainer = parts[1]
	box.add_child(MenuKit.paragraph("This measures how smoothly Zenith runs on this PC. It starts Factorio in the background on a test map of its own, builds the same small factory every time and lets Zenith look at it standing still and running laps round it, full screen, a few times. Your own saves, mods and settings are not touched. At the end it writes one text file to send back.\n\nClose other games first. While it runs, please leave the mouse and keyboard alone and don't run anything heavy; Esc stops it.", 540))
	var inner := Kit.panel("FShallowFrame")
	var pad := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, Kit.px(8))
	var buttons := VBoxContainer.new()
	buttons.name = "Modes"
	buttons.add_theme_constant_override("separation", Kit.px(4))
	pad.add_child(buttons)
	inner.add_child(pad)
	box.add_child(inner)
	for id in PerfTest.MODE_ORDER:
		var m: Array = PerfTest.MODES[id]
		var b := MenuKit.menu_button("%s, %s" % [m[0], m[1]], id == "default")
		b.name = "Perf" + str(m[0])
		b.tooltip_text = str(m[2])
		var mode_id: String = id
		_on(b, func() -> void: _start_perf_test(mode_id), "gui-green-confirm" if id == "default" else "gui-click")
		buttons.add_child(b)
		var what := Kit.label("    " + str(m[2]))
		what.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
		buttons.add_child(what)
	var row: Array = MenuKit.dialog_buttons("Cancel", "")
	box.add_child(row[0])
	_on(row[1], _pop_overlay, "gui-back")
	_push_overlay(o)


## Runs the test in `mode_id`, then shows its results (or quits, for --perf-test=<mode>).
func _start_perf_test(mode_id: String, quit_after := false) -> void:
	if state != State.MENU or _perf != null or not PerfTest.MODES.has(mode_id) or not Settings.dev_tools():
		return
	state = State.BUSY
	_clear_overlays()
	var test := PerfTest.new()
	test.name = "PerfTest"
	test.mode = mode_id
	if perf_runner != null:
		test.runner = perf_runner
		perf_runner = null
	_perf = test
	add_child(test)
	_show_progress("Performance test: " + str(PerfTest.MODES[mode_id][0]), "Getting ready…", 0.0, false, func() -> void: test.cancel())
	test.progress.connect(_set_progress)
	# This window stays behind the test's Zenith: it draws as little as it can meanwhile.
	_perf_before = {"fps": Engine.max_fps, "low": OS.low_processor_usage_mode}
	_show_background(false)
	Engine.max_fps = 10
	OS.low_processor_usage_mode = true
	print("perf test: %s mode" % mode_id)
	var outcome: Dictionary = await test.run()
	Engine.max_fps = int(_perf_before["fps"])
	OS.low_processor_usage_mode = bool(_perf_before["low"])
	var quit_asked := test.has_meta("quit")
	_perf = null
	test.queue_free()
	_hide_progress()
	state = State.MENU
	print("perf test: " + ("results in %s" % outcome["file"] if bool(outcome["ok"]) else "stopped: %s" % str(outcome["error"]).replace("\n", " | ")))
	if quit_after:
		Bridge.disconnect_from()
		ExitGuard.arm()
		get_tree().quit(int(outcome["exit_code"]))
		return
	if quit_asked:
		_quit(true)
		return
	_show_background(true)
	_show_main_menu()
	if bool(outcome["ok"]):
		_show_perf_results(outcome)
	elif str(outcome["error"]) != "cancelled":
		_show_message("The performance test stopped", "%s\n\nIts files are in %s" % [outcome["error"], ProjectSettings.globalize_path("user://perf-tests/work")])


## The results: a line per test, each test's full report in the debug menu's report window
## (against the last run of this mode), and the file to send.
func _show_perf_results(outcome: Dictionary) -> void:
	var o := MenuKit.overlay(0.35)
	o.name = "PerfResults"
	var parts := MenuKit.window("Performance test results")
	MenuKit.overlay_center(o).add_child(parts[0])
	var box: VBoxContainer = parts[1]
	var inner := Kit.panel("FShallowFrame")
	var pad := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, Kit.px(12))
	inner.add_child(pad)
	box.add_child(inner)
	var grid := GridContainer.new()
	grid.name = "Tests"
	grid.columns = 6
	grid.add_theme_constant_override("h_separation", Kit.px(20))
	grid.add_theme_constant_override("v_separation", Kit.px(4))
	pad.add_child(grid)
	for h in ["Test", "Middle frame", "Slowest 1%", "FPS", "UPS", ""]:
		grid.add_child(Kit.label(h, "FHeading"))
	var details: Control = load("res://scripts/ui/factorio/debug_menu.gd").new()
	details.name = "PerfReport"
	for report: Dictionary in outcome["reports"]:
		grid.add_child(Kit.label(str(report.get("name", "?"))))
		grid.add_child(Kit.label(PerfTest.fmt(report.get("p50")) + " ms"))
		grid.add_child(Kit.label(PerfTest.fmt(report.get("p99")) + " ms"))
		var fps: Variant = null
		if float(report.get("p50", 0.0)) > 0.0:
			fps = 1000.0 / float(report["p50"])
		grid.add_child(Kit.label(PerfTest.fmt(fps, 0)))
		grid.add_child(Kit.label(PerfTest.fmt(report.get("ups"))))
		var more := MenuKit.button("Details")
		var shown := report
		more.pressed.connect(func() -> void: details.show_report(shown))
		grid.add_child(more)
	var file := str(outcome["file"])
	box.add_child(MenuKit.paragraph("Saved as %s\nPlease send that file. It holds this PC's processor, graphics card, memory, screen and system, and the test's numbers; nothing else (no names, no files of yours)." % file, 600))
	var row: Array = MenuKit.dialog_buttons("Close", "")
	var folder := MenuKit.button("Open folder")
	folder.name = "OpenFolder"
	_on(folder, func() -> void: OS.shell_show_in_file_manager(file))
	row[0].add_child(folder)
	var copy := MenuKit.button("Copy")
	_on(copy, func() -> void: DisplayServer.clipboard_set(str(outcome["text"])))
	row[0].add_child(copy)
	box.add_child(row[0])
	_on(row[1], _pop_overlay, "gui-back")
	o.add_child(details)
	_push_overlay(o)


# --- progress --------------------------------------------------------------------------------

## A window with a progress bar, like Factorio's "Connecting to server"; over the menu (or a dark
## screen while the game world loads behind it). Cancel stops the launch.
func _show_progress(title: String, text: String, fraction: float, opaque: bool, on_cancel := Callable()) -> void:
	_hide_progress()
	var o := MenuKit.overlay(0.35)
	if opaque:
		(o as ColorRect).color = Color8(26, 25, 26)
	var parts := MenuKit.window(title)
	MenuKit.overlay_center(o).add_child(parts[0])
	var box: VBoxContainer = parts[1]
	var inner := Kit.panel("FShallowFrame")
	var pad := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, Kit.px(12))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", Kit.px(8))
	pad.add_child(col)
	inner.add_child(pad)
	box.add_child(inner)
	var label := Kit.label(text)
	label.custom_minimum_size.x = Kit.px(420)
	col.add_child(label)
	var bar := Kit.progress_bar(Kit.BAR_GREEN)
	bar.max_value = 1.0
	bar.step = 0.001
	bar.value = fraction
	bar.custom_minimum_size = Kit.pxv(420, 12)
	col.add_child(bar)
	var row: Array = MenuKit.dialog_buttons("Cancel", "")
	box.add_child(row[0])
	_on(row[1], on_cancel if on_cancel.is_valid() else _cancel_launch, "gui-back")
	_root.add_child(o)
	_progress = {"root": o, "label": label, "bar": bar, "cancel": row[1]}
	if _page != null:
		_page.visible = false


func _set_progress(text: String, fraction: float) -> void:
	if _progress.is_empty():
		return
	(_progress["label"] as Label).text = text
	(_progress["bar"] as ProgressBar).value = maxf((_progress["bar"] as ProgressBar).value, fraction)


func _hide_progress() -> void:
	if not _progress.is_empty():
		(_progress["root"] as Control).queue_free()
		_progress = {}
	if _page != null:
		_page.visible = true


func _on_launch_progress(text: String, fraction: float) -> void:
	_set_progress(text, fraction)


# --- launching and connecting ----------------------------------------------------------------

## `map_settings`: map_gen.gd settings, or a preset's name. `host` set: hosted on the network.
func _create_and_launch(save_name: String, map_settings: Variant, seed_text: String, exchange := "", host := {}) -> void:
	if state != State.MENU:
		return
	state = State.BUSY
	_clear_overlays()
	var path := Paths.saves_dir().path_join(save_name + ".zip")
	_show_progress("New game: " + save_name, "Creating map…", 0.02, false)
	var ok: bool = await launcher.create_map(path, map_settings, seed_text, exchange)
	if state != State.BUSY:
		return  # cancelled meanwhile
	if not ok:
		_hide_progress()
		state = State.MENU
		_show_message("Map creation failed", launcher.error)
		return
	state = State.MENU
	_launch(path, host)


## `exact_mods`: Load game's Sync mods with save (the save's mods only, none of the Mods window's).
func _launch(path: String, host := {}, exact_mods := false) -> void:
	if state != State.MENU:
		return
	state = State.BUSY
	_clear_overlays()
	if _progress.is_empty():
		_show_progress(("Hosting " if not host.is_empty() else "Loading ") + path.get_file().get_basename(), "Starting server…", 0.05, false)
	else:
		_set_progress("Starting server…", 0.3)
	var ok: bool = await launcher.start(path, host, exact_mods)
	if state != State.BUSY:
		return  # cancelled meanwhile
	if not ok:
		_hide_progress()
		state = State.MENU
		_show_message("Couldn't start the server", launcher.error)
		return
	session = "launched"
	session_address = "127.0.0.1:%d" % launcher.udp_port
	_enter_game("127.0.0.1", launcher.udp_port, launcher.client_port, "Loading " + path.get_file().get_basename())


func _connect_address(host: String, port: int, rcon_password := "") -> void:
	if state != State.MENU:
		return
	session = "address"
	session_address = ("[%s]:%d" if host.contains(":") else "%s:%d") % [host, port]
	# A server on another PC goes through its relay (TCP): no UDP port of ours to pick.
	var remote: bool = Bridge.through_relay(host)
	var listen := 0 if remote else ServerLauncher.free_udp_port(34201 if port == 34200 else port + 1)
	_enter_game(host, port, listen, "Connecting to " + session_address)
	if remote and rcon_password != "":
		_open_remote_rcon(host, port, rcon_password)


## RCON through the relay at host:port (server/relay.py --rcon-port), for pausing on a server on
## another PC. Said on the HUD when it can't be had: the game plays on without it.
func _open_remote_rcon(host: String, port: int, password: String) -> void:
	var rcon := Rcon.new()
	remote_rcon = rcon
	var ok: bool = await rcon.open(get_tree(), port, password, host, true)
	if remote_rcon != rcon:
		rcon.close()  # left the game meanwhile
		return
	if not ok:
		remote_rcon = null
		print("menu: no RCON through the relay: " + rcon.error)
		if main != null and main.hud != null:
			main.hud.show_message("No RCON on the server: " + rcon.error)
		return
	print("menu: RCON through the relay at %s:%d" % [host, port])


## Builds the game world, points the bridge at the server and waits for the world (Cancel goes
## back to the menu).
func _enter_game(host: String, port: int, listen: int, title: String) -> void:
	_show_background(false)
	_clear_overlays()
	if _page != null:
		_page.queue_free()
		_page = null
	main.start_game()
	get_tree().root.theme = MenuKit.theme()  # the HUD set Kit's; this one has it all and the menus' too
	main.set_game_input(false)
	Bridge.connect_to(host, port, listen)
	_show_progress(title, ("Connecting to the relay at %s…" if Bridge.via_relay else "Connecting to the bridge at %s…") % session_address, 0.8, true)
	state = State.CONNECTING
	_connect_started = Time.get_ticks_msec()
	_ready_since = 0
	if Bridge.via_relay:
		print("menu: connecting to %s through its relay (TCP)" % session_address)
	else:
		print("menu: connecting to %s from UDP %d" % [session_address, listen])


func _update_connecting() -> void:
	if Bridge.bind_error != OK:
		_fail_connect("Can't open UDP port %d for the client. Is another client running?" % Bridge.listen_port)
		return
	if session == "launched" and not launcher.is_running():
		_fail_connect("The server stopped while the client was connecting.\n" + launcher._log_errors(0))
		return
	if not Bridge.connected:
		var relay := Bridge.relay_status() if Bridge.via_relay else ""
		if relay.begins_with("refused"):
			_fail_connect("The relay at %s %s." % [session_address, relay])
			return
		if relay == "connected":
			_set_progress("Connected to the relay, waiting for the bridge…", 0.8)
		if Time.get_ticks_msec() - _connect_started > CONNECT_TIMEOUT_MSEC:
			if relay == "connected":
				_fail_connect("The relay at %s answers, but no bridge behind it.\nIs Factorio running on that PC with --enable-lua-udp and the factorio-3d-bridge mod, and the relay's --bridge-port the same port?" % session_address)
			elif Bridge.via_relay:
				_fail_connect("No relay answers at %s (%s).\nIs python3 server/relay.py running on that PC, its TCP port open in the firewall, and this PC's address allowed (--allow; the default is the local network)?" % [session_address, relay])
			else:
				_fail_connect("No answer from the bridge at %s.\nIs Factorio running with --enable-lua-udp %d and the factorio-3d-bridge mod enabled?" % [session_address, Bridge.factorio_port])
		return
	if not Bridge.world_ready:
		_set_progress("Receiving prototypes…", 0.85)
		return
	if _ready_since == 0:
		_ready_since = Time.get_ticks_msec()
		if main.has_method("set_joining"):
			main.set_joining(true)
	var chunks: int = main.loaded_chunks()
	var waited := Time.get_ticks_msec() - _ready_since
	if chunks < READY_CHUNKS and waited <= READY_GRACE_MSEC:
		_set_progress("Loading world… (%d chunks)" % chunks, 0.88 + 0.08 * minf(1.0, chunks / float(READY_CHUNKS)))
		return
	var left: int = main.join_left() if main.has_method("join_left") and Settings.arg_value("--join-warm=") != "off" else 0
	if left > 0 and waited <= WARM_GRACE_MSEC:
		_set_progress("Preparing models and shaders… (%d left)" % left, 0.96 + 0.04 * minf(1.0, float(waited) / WARM_GRACE_MSEC))
		return
	if main.has_method("set_joining"):
		main.set_joining(false)
	_hide_progress()
	state = State.PLAYING
	_played_seconds = 0.0
	main.set_game_input(true)
	print("menu: in the game (%s, %d chunks, %d s after ready%s)" % [session_address, chunks, waited / 1000,
		", %d still preparing" % left if left > 0 else ""])
	if session == "launched" and main.get("hud") != null:
		if not launcher.added_mods.is_empty():
			main.hud.show_message("Mods from the Mods window added to this game: " + ", ".join(launcher.added_mods))
		if not launcher.left_out_mods.is_empty():
			main.hud.show_message("Left out from the Mods window: " + "; ".join(launcher.left_out_mods))
	if Settings.arg_value("--menu=").get_slice(":", 0) in ["esc", "save-as", "settings"]:
		_toggle_esc_menu()
		if Settings.arg_value("--menu=") == "save-as":
			_show_save_as()
		elif Settings.arg_value("--menu=").begins_with("settings"):
			_show_settings(Settings.arg_value("--menu=").get_slice(":", 1))  # as the Esc menu's Settings button


func _fail_connect(text: String) -> void:
	var was := session
	await _leave_game(false)
	_show_message("Couldn't connect" if was != "launched" else "Couldn't start the game", text)


func _cancel_launch() -> void:
	match state:
		State.BUSY:
			state = State.MENU  # _launch sees this when start() returns
			_hide_progress()
			_show_progress("Cancelling", "Stopping the server…", 0.5, false)
			await launcher.stop(false)
			_hide_progress()
			_show_main_menu()
		State.CONNECTING:
			await _leave_game(false)


func _server_died() -> void:
	await _leave_game(false)
	_show_message("The server stopped", "The Factorio server has stopped.\n" + launcher._log_errors(0))


## Back to the main menu: closes the game, stops our server (saving first if asked).
func _leave_game(save: bool) -> void:
	state = State.BUSY
	_close_esc_menu()
	_clear_overlays()
	_recording_backdrop = false  # (main.gd end_game stops the recording)
	if main != null:
		main.end_game()
	if remote_rcon != null:
		remote_rcon.close()
		remote_rcon = null
	if session == "launched" and launcher.is_running():
		_show_progress("Exit to menu", "Saving and stopping the server…" if save else "Stopping the server…", 0.3, true)
		await launcher.stop(save)
	_hide_progress()
	session = ""
	state = State.MENU
	_show_background(true)
	_show_main_menu()


func _exit_to_menu(save: bool) -> void:
	await _leave_game(save)
	if _quit_after_exit:
		print("menu: --menu-quit-after-exit")
		_quit(false)


## Quits the program; our server is stopped first (saved when `save`).
func _quit(save: bool) -> void:
	if state == State.BUSY and launcher._stopping:
		return
	if _perf != null:
		# The test's Zenith and server stop first; its own clean-up then quits (_start_perf_test).
		_perf.set_meta("quit", true)
		_perf.cancel()
		return
	_close_esc_menu()
	if main != null and state in [State.PLAYING, State.CONNECTING]:
		main.end_game()
	if launcher.is_running():
		state = State.BUSY
		_show_progress("Quit", "Saving and stopping the server…" if save else "Stopping the server…", 0.5, true)
		await launcher.stop(save)
	Bridge.disconnect_from()
	ExitGuard.arm()
	get_tree().quit()


# --- the in-game menu ------------------------------------------------------------------------

func _toggle_esc_menu() -> void:
	if _esc_menu != null:
		_close_esc_menu()
		return
	# Factorio 2.1's "Game menu": Resume (green), Restart, Load game, Save game, Settings, then the
	# red Exit at the bottom left. The client adds Save as (Factorio's Save game asks for the name),
	# Players in a game with other players, and Exit asks where to: the menu or the desktop.
	var o := MenuKit.overlay(0.35)
	o.name = "EscMenu"
	var parts := MenuKit.window("Game menu")
	MenuKit.overlay_center(o).add_child(parts[0])
	var box: VBoxContainer = parts[1]
	var inner := Kit.panel("FShallowFrame")
	var buttons := VBoxContainer.new()
	buttons.add_theme_constant_override("separation", Kit.px(4))
	var pad := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, Kit.px(4))
	pad.add_child(buttons)
	inner.add_child(pad)
	box.add_child(inner)
	var cont := MenuKit.menu_button("Resume", true)
	cont.name = "Resume"
	_on(cont, _close_esc_menu, "gui-green-confirm")
	buttons.add_child(cont)
	var can_save := session == "launched" and launcher.rcon.is_open()
	var why := "Only a server started from this menu can be saved from here (use /server-save on the server's console)"
	var load := MenuKit.menu_button("Load game")
	load.name = "LoadGame"
	load.tooltip_text = "Leave this game (asking to save it) and pick a save to load"
	_on(load, _ask_load_game)
	buttons.add_child(load)
	var save := MenuKit.menu_button("Save game")
	save.name = "SaveGame"
	save.disabled = not can_save
	save.tooltip_text = "Save %s now (/server-save)" % launcher.save_path.get_file().get_basename() if can_save else why
	_on(save, _save_game)
	buttons.add_child(save)
	var save_as := MenuKit.menu_button("Save as")
	save_as.name = "SaveAs"
	save_as.disabled = not can_save
	save_as.tooltip_text = "Save a copy under another name; the game goes on in this one" if can_save else why
	_on(save_as, _show_save_as)
	buttons.add_child(save_as)
	var settings := MenuKit.menu_button("Settings")
	settings.name = "Settings"
	_on(settings, func() -> void: _show_settings(""))
	buttons.add_child(settings)
	var addon_button := MenuKit.menu_button("Add-ons")
	addon_button.name = "Addons"
	addon_button.tooltip_text = "Zenith's add-ons: their settings and keys"
	_on(addon_button, func() -> void: _show_addons(""))
	buttons.add_child(addon_button)
	var packs_button := MenuKit.menu_button("Model packs")
	packs_button.name = "ModelPacks"
	packs_button.tooltip_text = MODEL_PACKS_TIP
	_on(packs_button, _show_model_packs)
	buttons.add_child(packs_button)
	var backdrop_button := MenuKit.menu_button("Use this view as the menu backdrop")
	backdrop_button.name = "UseAsBackdrop"
	_set_backdrop_button(backdrop_button)
	_on(backdrop_button, _record_backdrop)
	buttons.add_child(backdrop_button)
	var bug := MenuKit.menu_button("Report a bug")
	bug.name = "ReportABug"
	bug.tooltip_text = BUG_TIP
	_on(bug, _report_bug)
	buttons.add_child(bug)
	var players := MenuKit.menu_button("Players")
	players.name = "Players"
	var show_players := func() -> void:
		_close_esc_menu()
		if main != null and main.hud != null:
			main.hud.ui.players_window.toggle()
	_on(players, show_players)
	# Factorio's single-player menu has no players; the client shows it when others play too.
	players.visible = main != null and main.hud != null and main.hud.ui.model.players.size() > 1
	buttons.add_child(players)
	var where_text := ("Server: " if session == "launched" else "Bridge: ") + session_address
	if Bridge.via_relay:
		where_text += " (another PC, through its relay%s)" % (", RCON" if remote_rcon != null and remote_rcon.is_open() else "")
	if session == "launched" and not launcher.hosting.is_empty():
		where_text += "  ·  hosting \"%s\" on port %d" % [launcher.hosting.get("name", ""), launcher.game_port]
	var row: Array = MenuKit.dialog_buttons("Exit", "", true)
	(row[1] as Button).name = "Exit"
	(row[1] as Button).tooltip_text = "Exit to the main menu or quit the game. " + where_text
	_on(row[1], _ask_exit, "gui-back")
	box.add_child(row[0])
	_root.add_child(o)
	_esc_menu = o
	main.set_game_input(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## The Esc menu's Exit: to the main menu or out of the game (each asks to save a launched server).
func _ask_exit() -> void:
	var o := MenuKit.overlay(0.35)
	o.name = "ExitChoice"
	var parts := MenuKit.window("Exit")
	MenuKit.overlay_center(o).add_child(parts[0])
	var box: VBoxContainer = parts[1]
	var inner := Kit.panel("FShallowFrame")
	var buttons := VBoxContainer.new()
	buttons.add_theme_constant_override("separation", Kit.px(4))
	inner.add_child(buttons)
	box.add_child(inner)
	var to_menu := MenuKit.menu_button("Exit to menu")
	to_menu.name = "ExitToMenu"
	_on(to_menu, func() -> void:
		_pop_overlay()
		_ask_exit_to_menu())
	buttons.add_child(to_menu)
	var quit := MenuKit.menu_button("Quit game")
	quit.name = "QuitGame"
	_on(quit, func() -> void:
		_pop_overlay()
		_ask_quit())
	buttons.add_child(quit)
	var row: Array = MenuKit.dialog_buttons("Back", "")
	box.add_child(row[0])
	_on(row[1], _pop_overlay, "gui-back")
	_push_overlay(o)


func _close_esc_menu() -> void:
	if _esc_menu == null:
		return
	_esc_menu.queue_free()
	_esc_menu = null
	if state == State.PLAYING and main != null:
		main.set_game_input(true)


func _save_game() -> void:
	_show_progress("Save game", "Saving…", 0.3, false)
	var ok: bool = await launcher.save()
	_hide_progress()
	print("menu: save game: %s" % ("saved " + launcher.save_path if ok else launcher.error))
	if ok:
		_close_esc_menu()
		main.hud.show_message("Saved " + launcher.save_path.get_file().get_basename())
	else:
		_show_message("Save game", launcher.error)


## Factorio's "Save as": a name (or an existing save to overwrite), saved with RCON
## /server-save <name> and copied into the saves folder. The game goes on in the save it was
## loaded from, as on a Factorio server.
func _show_save_as() -> void:
	if not (session == "launched" and launcher.rcon.is_open()):
		return
	var o := MenuKit.overlay(0.35)
	o.name = "SaveAs"
	var parts := MenuKit.window("Save game")
	MenuKit.overlay_center(o).add_child(parts[0])
	var box: VBoxContainer = parts[1]
	var deep: Array = Kit.deep_scroll(Kit.pxv(440, 260))
	box.add_child(deep[0])
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 0)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	deep[1].add_child(list)
	var name_edit := MenuKit.textbox(launcher.save_path.get_file().get_basename() + " copy")
	name_edit.name = "SaveName"
	name_edit.custom_minimum_size.x = Kit.px(440)
	for s in Saves.list():
		if s["source"] != "server":
			continue
		var b := Button.new()
		b.theme_type_variation = "FListItem"
		b.focus_mode = Control.FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size.y = Kit.px(28)
		b.text = "  %s    %s" % [s["name"], Saves.when(int(s["modified"]))]
		var save_name := str(s["name"])
		b.pressed.connect(func() -> void: name_edit.text = save_name)
		list.add_child(b)
	box.add_child(Kit.label("Save as"))
	box.add_child(name_edit)
	var row: Array = MenuKit.dialog_buttons("Cancel", "Save")
	box.add_child(row[0])
	_on(row[1], _pop_overlay, "gui-back")
	var go := func() -> void:
		var save_name := Saves.clean_name(name_edit.text)
		if save_name == "":
			_show_message("Save game", "Give the save a name.")
			return
		var target := Paths.saves_dir().path_join(save_name + ".zip")
		if target == launcher.save_path:
			_pop_overlay()
			_save_game()
			return
		var save_now := func() -> void:
			_pop_overlay()
			_save_game_as(save_name)
		if FileAccess.file_exists(target):
			_show_confirm("Save game", "Are you sure you want to overwrite %s?" % save_name, "Overwrite", save_now, true)
		else:
			save_now.call()
	(row[2] as Button).name = "SaveAsConfirm"
	_on(row[2], go, "gui-green-confirm")
	name_edit.text_submitted.connect(func(_t: String) -> void: go.call())
	_push_overlay(o)
	name_edit.grab_focus.call_deferred()


func _save_game_as(save_name: String) -> void:
	_show_progress("Save game", "Saving %s…" % save_name, 0.3, false)
	var ok: bool = await launcher.save_as(save_name)
	_hide_progress()
	print("menu: save as %s: %s" % [save_name, "saved" if ok else launcher.error])
	if ok:
		_close_esc_menu()
		main.hud.show_message("Saved " + save_name)
	else:
		_show_message("Save game", launcher.error)


## In the game, Load game: leave this one (our server asks to save first), then the saves.
func _ask_load_game() -> void:
	var then := func(save: bool) -> void:
		await _leave_game(save)
		_show_worlds("load")
	if session != "launched":
		_show_confirm("Load game", "Disconnect from %s? Factorio keeps running." % session_address, "Load game", func() -> void: then.call(false))
		return
	_ask_save("Load game", then)


## Like Factorio's: our server is asked whether to save; a bridge we only connected to keeps
## running.
func _ask_exit_to_menu() -> void:
	if session != "launched":
		_show_confirm("Exit to menu", "Disconnect from %s? Factorio keeps running." % session_address, "Exit to menu", func() -> void: _exit_to_menu(false))
		return
	_ask_save("Exit to menu", func(save: bool) -> void: _exit_to_menu(save))


func _ask_quit() -> void:
	if session != "launched":
		_quit(false)
		return
	_ask_save("Quit game", func(save: bool) -> void: _quit(save))


func _ask_save(title: String, then: Callable) -> void:
	var o := MenuKit.overlay(0.35)
	var parts := MenuKit.window(title)
	MenuKit.overlay_center(o).add_child(parts[0])
	var box: VBoxContainer = parts[1]
	box.add_child(MenuKit.paragraph("Save %s before the server stops?" % launcher.save_path.get_file().get_basename(), 420))
	var row: Array = MenuKit.dialog_buttons("Cancel", "Save and exit")
	var discard := MenuKit.button("Don't save", "FRedButton")
	discard.custom_minimum_size.y = Kit.px(32)
	row[0].add_child(discard)
	row[0].move_child(discard, 1)
	box.add_child(row[0])
	_on(row[1], _pop_overlay, "gui-back")
	_on(discard, func() -> void:
		_pop_overlay()
		then.call(false))
	_on(row[2], func() -> void:
		_pop_overlay()
		then.call(true), "gui-green-confirm")
	_push_overlay(o)


# --- helpers ---------------------------------------------------------------------------------

func _on(button: BaseButton, f: Callable, sound := "gui-click") -> void:
	button.pressed.connect(func() -> void:
		Sfx.play_ui(sound)
		f.call())
