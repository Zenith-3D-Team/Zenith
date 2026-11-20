extends Control
## Zenith's debug menu, opened only by its key (Settings > Controls > Miscellaneous > Debug menu,
## Ctrl+F12): out of players' way, and only in dev builds (Settings.dev_tools(): development downloads and a checkout); a public download has no key for it and it never opens, so its
## overlays and probes can't be switched on there either. Three tabs in Factorio's style:
## - Time: the time of day (a slider and Dawn / Noon / Sunset / Night), freezing the day/night
##   cycle, the game's speed and pausing. They change the game, through the bridge's /f3d-debug
##   (console.lua), with the console's rule: in a multiplayer game only an admin's (or the server's
##   own machine's) commands run. The bridge says when it refuses (`cmdr` na), and the controls are
##   greyed with the reason instead of failing silently. A paused game runs no mod code, so Pause
##   is offered only where Zenith can resume over RCON (net/game_pause.gd, as a screenshot's pause),
##   and while it is paused the other controls wait. The slider reads as a clock, midnight to
##   midnight; Factorio's own daytime counts from noon (0 noon, 0.5 midnight).
## - Benchmarks: bench_runner.gd's standing, laps, flyover and zoom, each ending in a report window
##   (frame times, GPU, draw calls, triangles, UPS, the bridge's cost, what was running) to copy or
##   save, against the last run of the same benchmark.
## - Tests: one-click checks while developing: the bridge's self-test and status, overlays (UPS,
##   frame-time graph, counters, chunk borders), the debug probes run in the game (terrain, robots,
##   belt items' cost, flicker frames), the effects demo, redrawing chunks, and spots to move the
##   character to (a game change, under the same rule as Time).
## - Updates: where and when the bridge updates the world (update_overlay.gd): each kind of update
##   (chunk snapshots, entity changes, belt lanes read, checked and asked for, hands, movers, power,
##   alerts...) outlined on the ground as it arrives, fading over a second, each its own switch and
##   colour, a legend with its updates a second; and three states (the subscription, how each lane is
##   drawn, the lattice against the simulation). The overlay node exists only while a kind is on.
## - Simulation: the belt fixes (belt_items.gd's LIVE: early stop, the longer lead, rescue seen...) off and
##   on while playing, each from the command line's value, taken at the next belt job; nothing saved.
## - Lighting: the pbr light numbers (looks.gd), each a slider with its value and default, applied live and
##   not saved: the fill and ambient shares, the neutral reflection's k, the sun lobe, the downward-face ambient,
##   the metal share, a flat / directional toggle, a reset each and "Copy values" (prints them to the log). Under
##   them SSAO and SSIL on/off and their numbers, the contact shading's strength and widths, the sun's energy,
##   shadow softness and biases, and the ambient energy: each shows what the game has now and, once moved, is kept
##   over the look each frame (looks.gd light_tune) until its Reset.
## Esc cancels a running benchmark, then closes the report, then the menu.

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const MenuKit := preload("res://scripts/menu/menu_kit.gd")
const UiModel := preload("res://scripts/ui/factorio/ui_model.gd")
const GamePause := preload("res://scripts/net/game_pause.gd")
const BenchRunner := preload("res://scripts/debug/bench_runner.gd")
const DebugOverlay := preload("res://scripts/debug/debug_overlay.gd")
const ChunkGrid := preload("res://scripts/debug/chunk_grid.gd")
const UpdateOverlay := preload("res://scripts/debug/update_overlay.gd")
const RobotProbe := preload("res://scripts/debug/robot_probe.gd")
const FlickerProbe := preload("res://scripts/debug/flicker_probe.gd")
const BeltPathProbe := preload("res://scripts/debug/belt_path_probe.gd")
const TerrainProbe := preload("res://scripts/debug/terrain_probe.gd")
const FxDemo := preload("res://scripts/fx/fx_demo.gd")
const Sfx := preload("res://scripts/fx/sfx.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const ModelPacks := preload("res://scripts/world/model_packs.gd")
const PerfWarning := preload("res://scripts/ui/factorio/perf_warning.gd")
const BeltItems := preload("res://scripts/world/belt_items.gd")
const Looks := preload("res://scripts/world/looks.gd")
const ContactShade := preload("res://scripts/world/contact_shade.gd")
const ItemCards := preload("res://scripts/world/item_cards.gd")
const Visuals := preload("res://scripts/world/visuals.gd")

const TABS := ["Time", "Benchmarks", "Tests", "Updates", "Simulation", "Lighting"]
## Factorio's day: 0 is noon, dusk 0.25, evening (darkest from) 0.45, morning 0.55, dawn 0.75.
const DAY_PRESETS := [["Dawn", 0.65], ["Noon", 0.0], ["Sunset", 0.35], ["Night", 0.5]]
const SPEEDS := [0.25, 0.5, 1.0, 2.0, 4.0]
const ANSWER_MSEC := 5000
const REFRESH := 2.0  # seconds between asking the state while the Time tab shows
const SEND_EVERY := 0.15  # the slider sends at most this often while it is dragged
## Nothing read from the bridge for this long: it isn't running (a paused or stalled game).
const SILENT_MSEC := 2000
const QUIET_REASON := "debug menu"
const REPORT_DIR := "user://benchmarks"
const LAST_PATH := "user://benchmarks/last.json"
const DEBUG_DIR := "user://debug"
const NOT_ADMIN := "Console commands are for admins in a multiplayer game: an admin can /promote you, or use Factorio's own console"
## [id, name, what it does, toggle]
const TESTS := [
	["selftest", "Bridge self-test", "/f3d-selftest: the character API the bridge uses, checked in this game line by line", false],
	["status", "Bridge status", "/f3d-status: the client, the character, the work budget, profiling", false],
	["ups", "UPS overlay", "The game's UPS in big type at the top left (--ups-overlay)", true],
	["graph", "Frame-time graph", "The last 300 frames' times, with lines at 16.7 and 33.3 ms", true],
	["counters", "Counters", "FPS, draw calls, triangles, nodes, chunks, entities, movers, belt items, 3D grass (--grass-stats)", true],
	["chunks", "Chunk borders", "Lines on the 32-tile chunk edges round the view: yellow loaded, grey not yet", true],
	["terrain", "Terrain streaming", "Every 5 s: how long new chunks' ground took to come and be drawn, holes near the view (--terrain-probe)", true],
	["robots", "Robots in view", "Waits for the movers in view to settle (up to a minute), then measures 10 s of their cost (--robot-probe)", false],
	["belts", "Belt items' cost", "10 s of belt items' main-thread and worker time (--belt-path-probe, without positions)", false],
	["flicker", "Flicker frames", "Turns the camera 0.1 degrees a frame and saves 40 frames for tools/flicker_count.py (--flicker-probe)", false],
	["fx", "Effects demo", "The character walks, mines, builds a furnace and an inserter, shoots and mines them back, as a player would (--fx-demo). Hands off the keys", false],
	["redraw", "Redraw chunks", "Every loaded chunk's buildings built again from what the client has (models changed on disk need a restart)", false],
	["perfwarn", "Performance warnings", "The warning icon at the top left while settings are held back for UPS; its log fills either way. The same as Settings > Interface > Performance warnings, saved", true],
	["packs", "Model packs", "Which model pack each model in use comes from, and the packs off or left out (the Model packs window)", false],
]

## ui_model.gd: command() and its answers.
var model: UiModel
## main.gd, for the benchmarks and the tests that need the world (set by main.gd; null in the UI test).
var main

var _root: Control  # the window's holder (centred, dragged by the title)
var _frame: PanelContainer
var _tab := 0
var _tab_buttons: Array[Button] = []
var _pages: Array[Control] = []
var _state := {}
## Why the game controls are greyed, "" when the bridge runs them.
var _why := "Asking the bridge..."
var _asked := {}  # command id -> [msec sent, what for], until it is answered or ANSWER_MSEC passes
var _sent := {}  # command id -> what for, kept past ANSWER_MSEC: a late answer is still the game's state
var _game_controls: Array[Control] = []
var _note: Label
var _clock: Label
var _slider: HSlider
var _freeze: CheckBox
var _speed_label: Label
var _speed_box: LineEdit
var _pause: Button
var _pause_note: Label
var _last_line: Label
var _daytime_wanted := -1.0
var _daytime_wait := 0.0
var _dragging := false
var _refresh := 0.0
## Paused from this menu (net/game_pause.gd): the bridge is silent until it resumes over RCON.
var _paused_here := false
var _resuming := false
var _pause_id := -1
var _back := Vector2.INF  # where the character stood before the last move (tiles)

var _bench_rows := {}  # id -> [run button, last result label, report button]
var _bench_note: Label
var _banner: Label
var runner: Node = null
var _report_root: Control
var _report_title: Label
var _report_grid: GridContainer
var _report_setup: Label
var _report_saved: Label
var _report_text := ""
var _report := {}

var _results: Label
var _toggles := {}  # test id -> Button
var _test_buttons: Array[Button] = []
var _overlay: DebugOverlay
var _grid: ChunkGrid
var _terrain: Node
var _probe: Node
var _fx_demo: Node
## The update overlays (update_overlay.gd), made with the first kind switched on, freed with the last.
var _updates: UpdateOverlay = null
var _update_boxes := {}  # kind id -> CheckBox
var _updates_note: Label
## The Lighting tab's sliders: key -> [HSlider, value Label].
var _light_sliders := {}
var _light_flat: CheckBox
## The live-light sliders (LIVE): key -> [HSlider, value Label]; the toggles: key -> CheckBox.
var _live_sliders := {}
var _live_boxes := {}
## What each overridden number was before the first move (reset puts it back).
var _live_was := {}
## The environment, sun and sun shadows the live sliders move: the game's (main.gd), or a test's own.
var light_env: Environment
var light_sun: DirectionalLight3D
var light_shadows
var _sim_boxes := {}  # belt switch id -> CheckBox
var _sim_note: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = MenuKit.theme()  # the menus' text boxes, check boxes and sliders, in Factorio's look
	_root = CenterContainer.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	var w: Array = MenuKit.window("Debug", true)
	_frame = w[0]
	_frame.name = "DebugMenu"
	_root.add_child(_frame)
	(w[2] as Button).pressed.connect(func() -> void: open(false))
	var box: VBoxContainer = w[1]
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 0)
	box.add_child(tabs)
	for i in TABS.size():
		var b := Button.new()
		b.text = TABS[i]
		b.name = "Tab" + TABS[i]
		b.theme_type_variation = "FTab"
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Kit.pxv(110, 32)
		b.add_theme_font_override("font", Kit.font("bold"))
		var index := i
		b.pressed.connect(func() -> void:
			Sfx.play_ui("gui-tab")
			_open_tab(index))
		tabs.add_child(b)
		_tab_buttons.append(b)
	var pane := Kit.panel("FShallowFrame")
	pane.custom_minimum_size = Kit.pxv(700, 460)
	box.add_child(pane)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	pane.add_child(scroll)
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "top", "right", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, Kit.px(12))
	scroll.add_child(pad)
	var pages := VBoxContainer.new()
	pad.add_child(pages)
	for page in [_time_page(), _bench_page(), _tests_page(), _updates_page(), _sim_page(), _light_page()]:
		page.visible = false
		pages.add_child(page)
		_pages.append(page)
	_frame.visible = false
	_banner = Kit.label("", "FHeading")
	_banner.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_banner.offset_top = Kit.px(80)
	_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_banner.add_theme_constant_override("outline_size", Kit.px(6))
	_banner.visible = false
	add_child(_banner)
	_build_report()
	if model != null:
		model.command_reply.connect(_on_reply)
	_open_tab(0)
	_apply()


func is_open() -> bool:
	return _frame.visible


func toggle() -> void:
	open(not is_open())


func open(on: bool) -> void:
	if on and not Settings.dev_tools():
		return
	_frame.visible = on
	if on:
		_refresh = 0.0
		_ask("/f3d-debug", "state")
		_show_bench_lasts()
		_sync_updates()
		if _toggles.has("perfwarn"):  # the setting may have changed in Settings since
			var pw: Button = _toggles["perfwarn"]
			pw.set_pressed_no_signal(PerfWarning.enabled())
			pw.text = "Hide" if pw.button_pressed else "Show"


## Esc: a running benchmark stops, then the report closes, then the menu. False when none was open.
func escape() -> bool:
	if runner != null and is_instance_valid(runner):
		runner.cancel()
	elif _report_root.visible:
		_report_root.visible = false
	elif _frame.visible:
		open(false)
	else:
		return false
	return true


func current_tab() -> String:
	return TABS[_tab]


func _open_tab(index: int) -> void:
	_tab = index
	if TABS[index] == "Lighting":
		_sync_light()
	if TABS[index] == "Simulation":
		_sync_sim()
	for i in _pages.size():
		_pages[i].visible = i == index
		_tab_buttons[i].button_pressed = i == index


func _process(delta: float) -> void:
	if _paused_here and not _resuming and not (Bridge.connected and GamePause.can_resume(main)):
		# The game ended, or the server Zenith started stopped: nothing to resume, and the
		# connection's timeout says what happened.
		_paused_here = false
		Bridge.expect_quiet(QUIET_REASON, false)
		_apply()
	if not _frame.visible:
		return
	if TABS[_tab] == "Lighting":
		_sync_live()  # the numbers the game moves itself (the time of day, a look) follow
	var now := Time.get_ticks_msec()
	for id in _asked.keys():
		if now - int(_asked[id][0]) > ANSWER_MSEC:
			_asked.erase(id)
			_set_why(no_answer_why())
	if _daytime_wanted >= 0.0:
		_daytime_wait -= delta
		if _daytime_wait <= 0.0:
			_ask("/f3d-debug daytime %.3f" % _daytime_wanted, "daytime")
			_daytime_wanted = -1.0
			_daytime_wait = SEND_EVERY
	_refresh += delta
	if _refresh >= REFRESH and _tab == 0 and _asked.is_empty() and not _paused_here:
		_refresh = 0.0
		_ask("/f3d-debug", "state")


# --- Time ------------------------------------------------------------------------------------

func _time_page() -> Control:
	var page := VBoxContainer.new()
	page.name = "TimePage"
	page.add_theme_constant_override("separation", Kit.px(12))
	_note = Kit.label("")
	_note.name = "Why"
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.custom_minimum_size.x = Kit.px(660)
	_note.add_theme_color_override("font_color", Kit.RED_TEXT)
	page.add_child(_note)

	page.add_child(Kit.label("Time of day", "FHeading"))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Kit.px(12))
	_slider = MenuKit.slider(0.0, 1.0, 0.001, 0.0)
	_slider.name = "Daytime"
	_slider.custom_minimum_size.x = Kit.px(420)
	_slider.value_changed.connect(func(v: float) -> void:
		_daytime_wanted = daytime_of(v)
		_clock.text = clock_text(_daytime_wanted))
	# While it is dragged the bridge's answers mustn't pull it back to where the game was.
	_slider.drag_started.connect(func() -> void: _dragging = true)
	_slider.drag_ended.connect(func(_changed: bool) -> void: _dragging = false)
	row.add_child(_slider)
	_game_controls.append(_slider)
	_clock = Kit.label("12:00")
	_clock.name = "Clock"
	row.add_child(_clock)
	page.add_child(row)
	var ends := Kit.label("Midnight to midnight, as a clock (Factorio's daytime counts from noon: 0 noon, 0.5 midnight)")
	ends.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
	page.add_child(ends)
	var presets := HBoxContainer.new()
	presets.add_theme_constant_override("separation", Kit.px(8))
	for p in DAY_PRESETS:
		var b := MenuKit.button(str(p[0]))
		b.name = "Day" + str(p[0])
		var at := float(p[1])
		b.pressed.connect(func() -> void:
			_slider.set_value_no_signal(slider_of(at))
			_clock.text = clock_text(at)
			_ask("/f3d-debug daytime %.3f" % at, "daytime"))
		presets.add_child(b)
		_game_controls.append(b)
	page.add_child(presets)
	_freeze = MenuKit.checkbox("Freeze the day/night cycle", false)
	_freeze.name = "Freeze"
	_freeze.toggled.connect(func(on: bool) -> void: _ask("/f3d-debug freeze %s" % ("on" if on else "off"), "freeze"))
	page.add_child(_freeze)
	_game_controls.append(_freeze)

	page.add_child(Kit.label("Game speed", "FHeading"))
	var speeds := HBoxContainer.new()
	speeds.add_theme_constant_override("separation", Kit.px(8))
	for s in SPEEDS:
		var b := MenuKit.button("%sx" % _num(s))
		b.name = "Speed%s" % _num(s).replace(".", "_")
		b.custom_minimum_size.x = Kit.px(64)
		var speed: float = s
		b.pressed.connect(func() -> void: _ask("/f3d-debug speed %s" % _num(speed), "speed"))
		speeds.add_child(b)
		_game_controls.append(b)
	_speed_box = MenuKit.textbox("", "custom")
	_speed_box.name = "SpeedBox"
	_speed_box.custom_minimum_size.x = Kit.px(90)
	_speed_box.text_submitted.connect(func(_t: String) -> void: _custom_speed())
	speeds.add_child(_speed_box)
	_game_controls.append(_speed_box)
	var set_button := MenuKit.button("Set")
	set_button.name = "SpeedSet"
	set_button.custom_minimum_size.x = Kit.px(64)
	set_button.pressed.connect(_custom_speed)
	speeds.add_child(set_button)
	_game_controls.append(set_button)
	page.add_child(speeds)
	_speed_label = Kit.label("")
	page.add_child(_speed_label)

	_pause = MenuKit.button("Pause the game")
	_pause.name = "Pause"
	_pause.custom_minimum_size.x = Kit.px(200)
	_pause.pressed.connect(_toggle_pause)
	page.add_child(_pause)
	_game_controls.append(_pause)
	_pause_note = MenuKit.paragraph("", 660)
	_pause_note.name = "PauseNote"
	_pause_note.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
	_pause_note.visible = false
	page.add_child(_pause_note)
	var about := MenuKit.paragraph("These change the game itself (surface.daytime, freeze_daytime, game.speed, game.tick_paused on the character's surface), for everyone in it. In a multiplayer game only admins may.", 660)
	about.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
	page.add_child(about)
	_last_line = Kit.label("")
	_last_line.name = "LastLine"
	page.add_child(_last_line)
	return page


func _custom_speed() -> void:
	var t := _speed_box.text.strip_edges().trim_suffix("x")
	if not t.is_valid_float() or float(t) <= 0.0:
		_last_line.text = "Game speed: a number above 0, 1 is normal"
		return
	_ask("/f3d-debug speed %s" % _num(float(t)), "speed")


## Pauses through the bridge (its answer waits for the resume) or resumes over RCON, which still runs
## while the game is paused (net/game_pause.gd).
func _toggle_pause() -> void:
	if _resuming or model == null:
		return
	if _paused_here:
		_resume()
		return
	if not Bridge.world_ready or not GamePause.can_resume(main):
		_apply()
		return
	_paused_here = true
	_pause_id = GamePause.pause(model, QUIET_REASON)
	_remember(_pause_id, "pause")  # no timeout: a paused game answers once it resumes
	_state["pa"] = 1
	_last_line.text = "The game is paused"
	_apply()


func _resume() -> void:
	_resuming = true
	_apply()
	var ran: bool = await GamePause.resume(main, QUIET_REASON)
	_resuming = false
	_paused_here = false
	_state["pa"] = 0
	if ran:
		_last_line.text = "Resumed over RCON"
		_apply()
		_ask("/f3d-debug", "state")
	else:
		_set_why(GamePause.STAYS_PAUSED)


func paused_here() -> bool:
	return _paused_here


## "13:30" for a time of day (0 is noon).
static func clock_text(daytime: float) -> String:
	var minutes := int(round(fposmod(daytime * 24.0 + 12.0, 24.0) * 60.0)) % (24 * 60)
	return "%02d:%02d" % [minutes / 60, minutes % 60]


## The slider runs as a clock, 0 midnight to 1 the next midnight; Factorio's daytime from noon. The
## same half-day turn both ways.
static func slider_of(daytime: float) -> float:
	return fposmod(daytime + 0.5, 1.0)


static func daytime_of(slider: float) -> float:
	return fposmod(slider + 0.5, 1.0)


## Why no answer came in ANSWER_MSEC, from what the link shows. Answers are read as their datagram
## arrives (Bridge.answer_read), so a client behind on its messages isn't the reason.
func no_answer_why() -> String:
	if not Bridge.connected:
		return "Not connected to the bridge"
	var silent := Bridge.silent_msec()
	if silent > SILENT_MSEC:
		return "The bridge has sent nothing for %d s: the game is paused or stalled (a paused game runs no mod code). The menu shows the game's state when it answers" % int(silent / 1000.0)
	return "No answer in %d s, though the bridge is sending: the mod %s may be older than the client, or far behind sending the world (a long view distance on a big base). The menu shows the game's state when it answers" % [
		ANSWER_MSEC / 1000, Bridge.mod_version if Bridge.mod_version != "" else "(version unknown)"]


static func _num(v: float) -> String:
	return str(snappedf(v, 0.001)).trim_suffix(".0")


# --- talking to the bridge ---------------------------------------------------------------------

func _ask(text: String, what: String) -> void:
	if model == null or _paused_here:
		return  # (paused: the bridge reads nothing until the game resumes)
	if not Bridge.world_ready:
		_set_why("Not in a game")
		return
	var id := model.command(text)
	_asked[id] = [Time.get_ticks_msec(), what]
	_remember(id, what)


func _remember(id: int, what: String) -> void:
	_sent[id] = what
	while _sent.size() > 64:
		_sent.erase(_sent.keys()[0])


func _on_reply(id: int, msg: Dictionary) -> void:
	if not _sent.has(id):
		return
	var what := str(_sent[id])
	_sent.erase(id)
	_asked.erase(id)
	var lines: Array = msg.get("l") if msg.get("l") is Array else []
	if id == _pause_id:
		_pause_id = -1
		if not _paused_here or _resuming:
			return  # it came with or after the resume: the paused state it carries is over
		_paused_here = false
		Bridge.expect_quiet(QUIET_REASON, false)
		_state["pa"] = 0
		if not GamePause.refused(msg):
			# Its answer waits for the game to run again: someone resumed it outside Zenith.
			_last_line.text = "The game was resumed outside Zenith"
			_apply()
			_ask("/f3d-debug", "state")
			return
	if int(msg.get("na", 0)) == 1:
		_set_why(NOT_ADMIN)
		return
	if int(msg.get("ok", 1)) == 0:
		_set_why("This bridge has no /f3d-debug: the mod is older than the client (update it)")
		return
	if msg.get("dbg") is Dictionary:
		_state = msg["dbg"]
		_why = ""
		_apply()
	if what in ["selftest", "status"]:
		_show_result("\n".join(PackedStringArray(lines.map(func(l) -> String: return str(l)))))
	elif what != "state" and not lines.is_empty():
		_last_line.text = str(lines[-1])
		if what == "teleport":
			_show_result(str(lines[-1]))


func _set_why(why: String) -> void:
	_why = why
	_apply()


## The controls show the game's state, greyed with the reason when the bridge won't run them.
func _apply() -> void:
	if _note == null:
		return
	# Paused from here the bridge runs nothing, so only Resume works.
	var allowed := _why == "" and not _state.is_empty() and not _paused_here
	for c in _game_controls:
		if c is BaseButton:
			(c as BaseButton).disabled = not allowed
		elif c is Range:
			(c as Range).editable = allowed
		elif c is LineEdit:
			(c as LineEdit).editable = allowed
	var can_pause := GamePause.can_resume(main)
	_pause.disabled = _resuming or not (_paused_here or (allowed and can_pause))
	_pause_note.text = "Paused: the bridge reads nothing until the game resumes, so the other controls wait. Resume runs over RCON" if _paused_here \
		else (GamePause.NO_RCON if not can_pause else "")
	_pause_note.visible = _pause_note.text != ""
	_note.text = _why
	_note.visible = _why != ""
	if _state.is_empty():
		return
	var dt := float(_state.get("dt", 0.0))
	if _daytime_wanted < 0.0 and not _dragging:
		_slider.set_value_no_signal(slider_of(dt))
		_clock.text = clock_text(dt) + ("  (always day here)" if int(_state.get("ad", 0)) == 1 else "")
	_freeze.set_pressed_no_signal(int(_state.get("fz", 0)) == 1)
	var paused := int(_state.get("pa", 0)) == 1
	_speed_label.text = "Now %sx%s, on %s" % [_num(float(_state.get("sp", 1.0))), ", paused" if paused else "", str(_state.get("s", "?"))]
	_pause.text = "Resume the game" if paused or _paused_here else "Pause the game"


func state() -> Dictionary:
	return _state


func why() -> String:
	return _why


# --- Benchmarks --------------------------------------------------------------------------------

func _bench_page() -> Control:
	var page := VBoxContainer.new()
	page.name = "BenchPage"
	page.add_theme_constant_override("separation", Kit.px(14))
	_bench_note = Kit.label("")
	_bench_note.add_theme_color_override("font_color", Kit.RED_TEXT)
	page.add_child(_bench_note)
	for id in BenchRunner.BENCHES:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", Kit.px(12))
		var run := MenuKit.button("Run", "FGreenButton")
		run.name = "Run_" + str(id)
		var bench: String = id
		run.pressed.connect(func() -> void: start_bench(bench))
		row.add_child(run)
		var text := VBoxContainer.new()
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var title := Kit.label("%s (%d s)" % [BenchRunner.BENCHES[id][0], int(BenchRunner.seconds_of(id))])
		title.add_theme_font_override("font", Kit.font("bold"))
		text.add_child(title)
		text.add_child(MenuKit.paragraph(str(BenchRunner.BENCHES[id][1]), 440))
		var last := Kit.label("")
		last.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
		text.add_child(last)
		row.add_child(text)
		var report := MenuKit.button("Last report")
		report.name = "Report_" + str(id)
		report.pressed.connect(func() -> void:
			var prev: Dictionary = _lasts().get(bench, {})
			if not prev.is_empty():
				show_report(prev))
		row.add_child(report)
		page.add_child(row)
		_bench_rows[id] = [run, last, report]
	var about := MenuKit.paragraph("The menu closes while one runs; Esc stops it. Reports and the last run of each are kept in %s." % ProjectSettings.globalize_path(REPORT_DIR), 660)
	about.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
	page.add_child(about)
	return page


func _show_bench_lasts() -> void:
	var lasts := _lasts()
	var can := main != null and Bridge.world_ready and runner == null
	_bench_note.text = "" if can else ("A benchmark is running" if runner != null else "Benchmarks need a game: connect first")
	_bench_note.visible = _bench_note.text != ""
	for id in _bench_rows:
		var r: Dictionary = lasts.get(id, {})
		(_bench_rows[id][0] as Button).disabled = not can
		(_bench_rows[id][2] as Button).disabled = r.is_empty()
		(_bench_rows[id][1] as Label).text = "Last run: frame p50 %s ms, p99 %s ms, %s fps, %s UPS (%s)" % [r.get("p50"), r.get("p99"), r.get("fps"), r.get("ups"), r.get("when")] if not r.is_empty() else "Not run yet"


func start_bench(id: String) -> void:
	if runner != null or main == null or not Bridge.world_ready:
		return
	open(false)
	_report_root.visible = false
	runner = BenchRunner.new()
	runner.name = "Benchmark"
	runner.main = main
	runner.kind = id
	runner.progress.connect(func(t: String) -> void:
		_banner.text = t + "  (Esc stops)"
		_banner.visible = true)
	runner.finished.connect(_bench_done)
	main.add_child(runner)


func _bench_done(report: Dictionary) -> void:
	runner = null
	_banner.visible = false
	if report.is_empty():
		return
	var lasts := _lasts()
	var prev: Dictionary = lasts.get(str(report["bench"]), {})
	prev.erase("previous")
	if not prev.is_empty():
		report["previous"] = prev
	var kept := report.duplicate(true)
	kept.erase("previous")
	lasts[str(report["bench"])] = kept
	DirAccess.make_dir_recursive_absolute(REPORT_DIR)
	var f := FileAccess.open(LAST_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(lasts, "\t"))
		f.close()
	show_report(report)


func _lasts() -> Dictionary:
	if not FileAccess.file_exists(LAST_PATH):
		return {}
	var d = JSON.parse_string(FileAccess.get_file_as_string(LAST_PATH))
	return d if d is Dictionary else {}


# --- the report window -------------------------------------------------------------------------

## [key, label, lower is better]
const REPORT_ROWS := [
	["p50", "Frame time p50 (ms)", true], ["p99", "Frame time p99 (ms)", true], ["worst", "Worst frame (ms)", true],
	["over16", "Frames over 16.7 ms", true], ["over33", "Frames over 33 ms", true], ["fps", "FPS", false],
	["gpu_p50", "GPU time p50 (ms)", true], ["gpu_p99", "GPU time p99 (ms)", true], ["render_cpu_p50", "Render CPU p50 (ms)", true],
	["process_p50", "Scripts p50 (ms)", true], ["draw_calls_p50", "Draw calls p50", true], ["primitives_p50", "Triangles p50", true],
	["ups", "Game UPS", false], ["bridge_ms", "Bridge per tick (ms)", true], ["speed", "Character speed (tiles/s)", false],
]


func _build_report() -> void:
	_report_root = CenterContainer.new()
	_report_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_report_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_report_root.visible = false
	add_child(_report_root)
	var w: Array = MenuKit.window("Benchmark report", true)
	var frame: PanelContainer = w[0]
	frame.name = "BenchReport"
	_report_root.add_child(frame)
	(w[2] as Button).pressed.connect(func() -> void: _report_root.visible = false)
	var box: VBoxContainer = w[1]
	_report_title = Kit.label("", "FHeading")
	box.add_child(_report_title)
	var deep: Array = Kit.deep_scroll(Kit.pxv(640, 380))
	box.add_child(deep[0])
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "top", "right", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, Kit.px(10))
	deep[1].add_child(pad)
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", Kit.px(10))
	pad.add_child(inner)
	_report_grid = GridContainer.new()
	_report_grid.columns = 4
	_report_grid.add_theme_constant_override("h_separation", Kit.px(28))
	_report_grid.add_theme_constant_override("v_separation", Kit.px(3))
	inner.add_child(_report_grid)
	_report_setup = MenuKit.paragraph("", 600)
	inner.add_child(_report_setup)
	_report_saved = Kit.label("")
	_report_saved.add_theme_color_override("font_color", Kit.GREEN_TEXT)
	box.add_child(_report_saved)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Kit.px(8))
	var copy := MenuKit.button("Copy")
	copy.name = "CopyReport"
	copy.pressed.connect(func() -> void:
		DisplayServer.clipboard_set(_report_text)
		_report_saved.text = "Copied to the clipboard")
	row.add_child(copy)
	var save := MenuKit.button("Save to file")
	save.name = "SaveReport"
	save.custom_minimum_size.x = Kit.px(140)
	save.pressed.connect(func() -> void: _report_saved.text = "Saved to " + save_report())
	row.add_child(save)
	var folder := MenuKit.button("Open folder")
	folder.custom_minimum_size.x = Kit.px(140)
	folder.pressed.connect(func() -> void:
		DirAccess.make_dir_recursive_absolute(REPORT_DIR)
		OS.shell_open(ProjectSettings.globalize_path(REPORT_DIR)))
	row.add_child(folder)
	var space := Kit.panel("FDraggable")
	space.custom_minimum_size.y = Kit.px(28)
	space.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(space)
	var close := MenuKit.button("Close")
	close.pressed.connect(func() -> void: _report_root.visible = false)
	row.add_child(close)
	box.add_child(row)


func report_open() -> bool:
	return _report_root.visible


func show_report(report: Dictionary) -> void:
	_report = report
	_report_text = report_text(report)
	_report_title.text = "%s, %s s, %s" % [report.get("name", "?"), report.get("seconds", "?"), report.get("when", "")]
	_report_saved.text = ""
	for c in _report_grid.get_children():
		_report_grid.remove_child(c)
		c.queue_free()
	var prev: Dictionary = report.get("previous", {}) if report.get("previous") is Dictionary else {}
	for h in ["", "This run", "Previous" if not prev.is_empty() else "", "Change" if not prev.is_empty() else ""]:
		_report_grid.add_child(Kit.label(h, "FHeading"))
	for r in REPORT_ROWS:
		if not report.has(r[0]):
			continue
		_report_grid.add_child(Kit.label(str(r[1])))
		_report_grid.add_child(Kit.label(_value(report, str(r[0]))))
		_report_grid.add_child(Kit.label(_value(prev, str(r[0])) if not prev.is_empty() else ""))
		var change := Kit.label(_change(report, prev, str(r[0])) if not prev.is_empty() else "")
		var better := _better(report, prev, str(r[0]), bool(r[2]))
		if better != 0:
			change.add_theme_color_override("font_color", Kit.GREEN_TEXT if better > 0 else Kit.RED_TEXT)
		_report_grid.add_child(change)
	_report_setup.text = setup_text(report)
	_report_root.visible = true


static func _value(r: Dictionary, key: String) -> String:
	if not r.has(key):
		return "-"
	var v = r[key]
	if (v is float or v is int) and float(v) < 0.0:
		return "-"
	if key == "primitives_p50":
		return DebugOverlay._big(int(v))
	if v is float:
		# (Counts read back from the last run's JSON are floats: 12, not 12.0.)
		return str(int(v)) if v == floorf(v) and absf(v) < 1e9 else str(snappedf(v, 0.01))
	return str(v)


static func _change(r: Dictionary, prev: Dictionary, key: String) -> String:
	if not (r.get(key) is float or r.get(key) is int) or not (prev.get(key) is float or prev.get(key) is int):
		return ""
	var a := float(prev[key])
	var b := float(r[key])
	if a < 0.0 or b < 0.0:
		return ""
	if absf(a) < 0.0001:
		return "+%s" % str(snappedf(b - a, 0.01)) if b > a else ("%s" % str(snappedf(b - a, 0.01)) if b < a else "same")
	var pct := (b - a) / absf(a) * 100.0
	return "%+.1f%%" % pct if absf(pct) >= 0.05 else "same"


## 1 when this run is better than the previous by more than 2%, -1 worse, 0 about the same.
static func _better(r: Dictionary, prev: Dictionary, key: String, lower_better: bool) -> int:
	if prev.is_empty() or not (r.get(key) is float or r.get(key) is int) or not (prev.get(key) is float or prev.get(key) is int):
		return 0
	var a := float(prev[key])
	var b := float(r[key])
	if a < 0.0 or b < 0.0 or absf(b - a) <= maxf(absf(a) * 0.02, 0.0001):
		return 0
	return 1 if (b < a) == lower_better else -1


## What was running, in a line or two: the version, the preset and the settings that weigh most.
static func setup_text(report: Dictionary) -> String:
	var s: Dictionary = report.get("setup", {}) if report.get("setup") is Dictionary else {}
	var lines := ["Zenith %s, graphics preset %s, look %s, %s at render scale %s; shadows %s, level of detail %s, view %s chunks, entities %s tiles; vsync %s, fps cap %s, Hold 60 UPS %s" % [
		s.get("version", "?"), s.get("preset", "?"), s.get("look", "?"), s.get("resolution", "?"), s.get("render_scale", "?"),
		s.get("shadows", "?"), s.get("lod", "?"), s.get("view_radius", "?"), s.get("entity_radius", "?"),
		"on" if s.get("vsync", false) else "off", s.get("fps_cap", 0) if int(s.get("fps_cap", 0)) > 0 else "none",
		"on" if s.get("hold_60_ups", false) else "off"]]
	if bool(s.get("render_thread", false)):
		lines.append("GPU and render CPU times not measured: the renderer runs on a thread of its own")
	if report.get("bridge_modules") is Array:
		var parts: Array = []
		for m in report["bridge_modules"]:
			parts.append("%s %s" % [m[0], m[1]])
		lines.append("Bridge by module (ms a tick): " + ", ".join(PackedStringArray(parts)))
	if str(report.get("bridge_note", "")) != "":
		lines.append("Bridge per tick: " + str(report["bridge_note"]))
	if report.has("budget"):
		lines.append("Bridge " + str(report["budget"]))
	if report.has("walked"):
		lines.append("The character ran %s tiles" % report["walked"])
	if report.get("previous") is Dictionary:
		lines.append("Previous run: %s" % report["previous"].get("when", "?"))
	return "\n".join(PackedStringArray(lines))


## The report as text, for the clipboard and the file.
static func report_text(report: Dictionary) -> String:
	var prev: Dictionary = report.get("previous", {}) if report.get("previous") is Dictionary else {}
	var lines := ["Zenith benchmark: %s (%s s, %s)" % [report.get("name", "?"), report.get("seconds", "?"), report.get("when", "")], ""]
	for r in REPORT_ROWS:
		if not report.has(r[0]):
			continue
		var line := "%-28s %12s" % [r[1], _value(report, str(r[0]))]
		if not prev.is_empty():
			line += "   previous %10s  %s" % [_value(prev, str(r[0])), _change(report, prev, str(r[0]))]
		lines.append(line)
	lines.append("")
	lines.append(setup_text(report))
	return "\n".join(PackedStringArray(lines))


## Writes the report shown as text and JSON into REPORT_DIR; returns the text file's full path.
func save_report() -> String:
	DirAccess.make_dir_recursive_absolute(REPORT_DIR)
	var stamp := str(_report.get("when", Time.get_datetime_string_from_system(false, true))).replace(":", "").replace(" ", "-").replace("T", "-")
	var base := "%s/%s-%s" % [REPORT_DIR, str(_report.get("bench", "bench")), stamp]
	var f := FileAccess.open(base + ".txt", FileAccess.WRITE)
	if f != null:
		f.store_string(_report_text + "\n")
		f.close()
	var j := FileAccess.open(base + ".json", FileAccess.WRITE)
	if j != null:
		j.store_string(JSON.stringify(_report, "\t"))
		j.close()
	return ProjectSettings.globalize_path(base + ".txt")


# --- Tests ---------------------------------------------------------------------------------------

func _tests_page() -> Control:
	var page := VBoxContainer.new()
	page.name = "TestsPage"
	page.add_theme_constant_override("separation", Kit.px(8))
	for t in TESTS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", Kit.px(12))
		var b := MenuKit.button("Show" if t[3] else "Run")
		b.name = "Test_" + str(t[0])
		b.custom_minimum_size.x = Kit.px(80)
		var id: String = t[0]
		if t[3]:
			b.toggle_mode = true
			b.toggled.connect(func(on: bool) -> void:
				b.text = "Hide" if on else "Show"
				set_toggle(id, on))
			_toggles[id] = b
			if id == "perfwarn":  # a saved setting, not an overlay: the button shows it as it is (off under --perf-warning=off)
				b.set_pressed_no_signal(PerfWarning.enabled())
				b.text = "Hide" if b.button_pressed else "Show"
		else:
			b.pressed.connect(func() -> void: run_test(id))
		row.add_child(b)
		_test_buttons.append(b)
		var text := VBoxContainer.new()
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var title := Kit.label(str(t[1]))
		title.add_theme_font_override("font", Kit.font("bold"))
		text.add_child(title)
		var about := MenuKit.paragraph(str(t[2]), 540)
		about.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
		text.add_child(about)
		row.add_child(text)
		page.add_child(row)
	page.add_child(Kit.label("Move the character (changes the game: the same rule as Time)", "FHeading"))
	var spots := HBoxContainer.new()
	spots.add_theme_constant_override("separation", Kit.px(8))
	for s in [["Spawn", "spawn"], ["Map centre", "centre"], ["500 tiles east", "east"], ["Back", "back"]]:
		var b := MenuKit.button(str(s[0]))
		b.name = "Spot_" + str(s[1])
		b.custom_minimum_size.x = Kit.px(130)
		var spot: String = s[1]
		b.pressed.connect(func() -> void: teleport(spot))
		spots.add_child(b)
		_game_controls.append(b)
	page.add_child(spots)
	var head := HBoxContainer.new()
	head.add_child(Kit.label("Results", "FHeading"))
	var space := Control.new()
	space.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(space)
	var copy := MenuKit.button("Copy")
	copy.pressed.connect(func() -> void: DisplayServer.clipboard_set(_results.text))
	head.add_child(copy)
	page.add_child(head)
	var deep := Kit.panel("FDeepFrame")
	var pad := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, Kit.px(8))
	deep.add_child(pad)
	_results = Kit.label("Nothing run yet")
	_results.name = "Results"
	_results.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_results.custom_minimum_size = Kit.pxv(640, 80)
	pad.add_child(_results)
	page.add_child(deep)
	return page


func results_text() -> String:
	return _results.text


func _show_result(text: String) -> void:
	_results.text = text


## A test of TESTS that runs once.
func run_test(id: String) -> void:
	match id:
		"selftest":
			_show_result("Asking the bridge...")
			_ask("/f3d-selftest", "selftest")
			return
		"status":
			_show_result("Asking the bridge...")
			_ask("/f3d-status", "status")
			return
		"packs":
			_show_result(ModelPacks.report())
			return
	if main == null or not Bridge.world_ready:
		_show_result("This one needs a game: connect first")
		return
	if _probe != null and is_instance_valid(_probe) and id in ["robots", "belts", "flicker"]:
		_show_result("A probe is still running")
		return
	DirAccess.make_dir_recursive_absolute(DEBUG_DIR)
	match id:
		"robots":
			var p := RobotProbe.new()
			p.movers = main.movers
			p.out_path = DEBUG_DIR + "/robot-probe.json@10"
			_start_probe(p, "Robots in view: waiting for the movers to settle, then 10 s")
		"belts":
			var p := BeltPathProbe.new()
			p.main = main
			p.out_path = "-@10@2"
			_start_probe(p, "Belt items: 12 s")
		"flicker":
			var p := FlickerProbe.new()
			p.world = main.world
			p.out_dir = DEBUG_DIR + "/flicker"
			p.settle = 1.0
			open(false)
			_start_probe(p, "Flicker frames: turning the camera, 40 frames")
		"fx":
			if _fx_demo != null and is_instance_valid(_fx_demo):
				_fx_demo.queue_free()
			_fx_demo = FxDemo.new()
			_fx_demo.fx = main.fx
			main.fx.add_child(_fx_demo)
			open(false)
			_show_result("Effects demo running: about 15 s")
		"redraw":
			var n := 0
			for c in main.world.chunks:
				main.world.redraw(c)
				n += 1
			_show_result("Redrawing %d chunks" % n)


func _start_probe(p: Node, what: String) -> void:
	p.set("quit_when_done", false)
	p.connect("reported", func(text: String) -> void:
		_show_result(text)
		Sfx.play_ui("gui-click"))
	_probe = p
	main.add_child(p)
	_show_result(what)


## An overlay or probe of TESTS that stays on until switched off.
func set_toggle(id: String, on: bool) -> void:
	match id:
		"perfwarn":
			Settings.set_value("interface", "perf_warning", on)
		"ups":
			if main != null:
				main.ups_overlay_on = on
		"graph", "counters":
			if _overlay == null:
				_overlay = DebugOverlay.new()
				_overlay.main = main
				add_child(_overlay)
			_overlay.set(id, on)
		"chunks":
			if on and main != null and main.world != null:
				if _grid == null:
					_grid = ChunkGrid.new()
					_grid.world = main.world
					main.world.add_child(_grid)
			elif _grid != null:
				_grid.queue_free()
				_grid = null
		"terrain":
			if on and main != null and main.world != null:
				if _terrain == null:
					_terrain = TerrainProbe.new()
					_terrain.world = main.world
					_terrain.connect("reported", func(text: String) -> void: _show_result(text))
					main.add_child(_terrain)
					_show_result("Terrain streaming: a line every 5 s")
			elif _terrain != null:
				_terrain.queue_free()
				_terrain = null


func toggled_on(id: String) -> bool:
	return _toggles.has(id) and (_toggles[id] as Button).button_pressed


## Moves the character to a spot (/f3d-debug teleport): the force's spawn, the map's centre, 500
## tiles east of it (fresh ground to stream), or back where it stood before the last move.
func teleport(spot: String) -> void:
	if _state.is_empty() or _why != "":
		return
	var here := Vector2(float(_state.get("x", 0)), float(_state.get("y", 0))) / 256.0
	var to := Vector2.INF
	match spot:
		"spawn":
			to = Vector2(float(_state.get("sx", 0)), float(_state.get("sy", 0))) / 256.0
		"centre":
			to = Vector2.ZERO
		"east":
			to = here + Vector2(500, 0)
		"back":
			to = _back
	if to == Vector2.INF:
		_show_result("Nowhere to go back to yet")
		return
	_back = here
	_ask("/f3d-debug teleport %.1f %.1f" % [to.x, to.y], "teleport")


# --- Updates -------------------------------------------------------------------------------------

func _updates_page() -> Control:
	var page := VBoxContainer.new()
	page.name = "UpdatesPage"
	page.add_theme_constant_override("separation", Kit.px(6))
	var about := MenuKit.paragraph("Where and when the bridge updates the world: each kind outlines, on the ground and over the buildings, what it touched as it arrives, fading over a second, in its own colour, with a legend of its updates a second at the left. The states show how things are now instead. Nothing runs with every kind off.", 660)
	about.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
	page.add_child(about)
	_updates_note = Kit.label("")
	_updates_note.name = "UpdatesNote"
	_updates_note.add_theme_color_override("font_color", Kit.RED_TEXT)
	_updates_note.visible = false
	page.add_child(_updates_note)
	var all := HBoxContainer.new()
	all.add_theme_constant_override("separation", Kit.px(8))
	for b in [["All on", true], ["All off", false]]:
		var button := MenuKit.button(str(b[0]))
		button.name = "Updates_" + ("on" if b[1] else "off")
		button.custom_minimum_size.x = Kit.px(110)
		var on: bool = b[1]
		button.pressed.connect(func() -> void:
			for id: String in UpdateOverlay.kind_ids():
				set_update_kind(id, on))
		all.add_child(button)
	page.add_child(all)
	for k in UpdateOverlay.KINDS:
		if k.size() <= 2:
			page.add_child(Kit.label(str(k[1]), "FHeading"))
			continue
		var id: String = k[0]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", Kit.px(10))
		var swatch := ColorRect.new()
		swatch.color = k[2]
		swatch.custom_minimum_size = Kit.pxv(14, 14)
		swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(swatch)
		var box := MenuKit.checkbox(str(k[1]), false)
		box.name = "Upd_" + id
		box.custom_minimum_size.x = Kit.px(250)
		box.toggled.connect(func(on: bool) -> void: set_update_kind(id, on))
		row.add_child(box)
		var what := MenuKit.paragraph(str(k[3]), 380)
		what.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
		row.add_child(what)
		page.add_child(row)
		_update_boxes[id] = box
	return page


## A kind of the update overlays on or off (update_overlay.gd). False when it can't be: a public build (no
## dev tools) or no game. The overlay is made for the first kind on and freed with the last, so with none
## on there is no node and nothing runs.
func set_update_kind(id: String, on: bool) -> bool:
	if on and (not Settings.dev_tools() or main == null or main.get("world") == null):
		_set_update_box(id, false)
		if _updates_note != null:
			_updates_note.text = "These need a game: connect first" if Settings.dev_tools() else "Dev builds only"
			_updates_note.visible = true
		return false
	if _updates_note != null:
		_updates_note.visible = false
	if on:
		if _updates == null or not is_instance_valid(_updates):
			_updates = UpdateOverlay.new()
			_updates.name = "UpdateOverlay"
			_updates.world = main.world
			_updates.belt_items = main.get("belt_items")
			_updates.belt_lanes = main.get("belt_lanes")
			main.world.add_child(_updates)
		_updates.set_kind(id, true)
	elif _updates != null and is_instance_valid(_updates):
		_updates.set_kind(id, false)
		if not _updates.any_on():
			_updates.queue_free()
			_updates = null
	_set_update_box(id, on)
	return true


func _set_update_box(id: String, on: bool) -> void:
	var box: CheckBox = _update_boxes.get(id)
	if box != null and box.button_pressed != on:
		box.set_pressed_no_signal(on)


## The kinds switched on (tests), from the overlay when it is there.
func update_kinds_on() -> Array:
	return _updates.kinds_on() if _updates != null and is_instance_valid(_updates) else []


func update_overlay() -> Node3D:
	return _updates if _updates != null and is_instance_valid(_updates) else null


## Opening the menu: an overlay gone with its game (the world freed) is made again in this one for the kinds
## still ticked, or they are unticked when there is no game.
func _sync_updates() -> void:
	if _updates != null and is_instance_valid(_updates):
		return
	_updates = null
	for id: String in _update_boxes:
		if (_update_boxes[id] as CheckBox).button_pressed:
			set_update_kind(id, true)


## The Simulation tab: the belt fixes (belt_items.gd's LIVE), each ticked as the jobs use it, with the
## command line's value beside it. A change waits for the next belt job (a running one never sees a switch
## change under it) and isn't saved.
func _sim_page() -> Control:
	var page := VBoxContainer.new()
	page.name = "SimulationPage"
	page.add_theme_constant_override("separation", Kit.px(6))
	var about := MenuKit.paragraph("The belt items' fixes, to switch off and compare while playing. A change takes effect at the next belt job (a fraction of a second) and isn't saved: the next start takes the command line's again. Not here, as they need a restart: take before read and take on the read's tick (the simulation queues takes and reads for them), the lattice and its creep (lanes keep their motion), the C++ twins (--belt-sim-native, --belt-draw-native).", 660)
	about.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
	page.add_child(about)
	_sim_note = Kit.label("")
	_sim_note.name = "SimulationNote"
	_sim_note.add_theme_color_override("font_color", Kit.RED_TEXT)
	_sim_note.visible = false
	page.add_child(_sim_note)
	page.add_child(Kit.label("Belts", "FHeading"))
	for l: Array in BeltItems.LIVE:
		var id: String = l[0]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", Kit.px(10))
		var box := MenuKit.checkbox(str(l[1]), BeltItems.live_on(id))
		box.name = "Sim_" + id
		box.tooltip_text = str(l[2])
		box.custom_minimum_size.x = Kit.px(220)
		box.toggled.connect(func(on: bool) -> void: set_sim_switch(id, on))
		row.add_child(box)
		var start := Kit.label("")
		start.name = "SimStart_" + id
		start.custom_minimum_size.x = Kit.px(130)
		start.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
		row.add_child(start)
		var what := MenuKit.paragraph(str(l[2]), 290)
		what.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
		row.add_child(what)
		page.add_child(row)
		_sim_boxes[id] = box
	_sync_sim()
	return page


## A belt switch on or off for the next belt job (belt_items.gd set_live). False in a public build (no dev
## tools): the box goes back.
func set_sim_switch(id: String, on: bool) -> bool:
	if not Settings.dev_tools():
		if _sim_note != null:
			_sim_note.text = "Dev builds only"
			_sim_note.visible = true
		_sync_sim()
		return false
	if _sim_note != null:
		_sim_note.visible = false
	BeltItems.set_live(id, on)
	_sync_sim()
	return true


## The boxes as the switches are (a test or the command line may have set them), each with its start value.
func _sync_sim() -> void:
	for id: String in _sim_boxes:
		var box: CheckBox = _sim_boxes[id]
		if box.button_pressed != BeltItems.live_on(id):
			box.set_pressed_no_signal(BeltItems.live_on(id))
		var start: Label = box.get_parent().find_child("SimStart_" + id, false, false)
		if start != null:
			var was := BeltItems.live_started(id)
			start.text = "started " + ("on" if was else "off") + ("" if was == BeltItems.live_on(id) else ", changed")


## The pbr light numbers the Lighting tab moves: [key, label, min, max, step, default, what it does].
const LIGHT := [
	["model_fill", "Camera fill", 0.0, 2.0, 0.01, 0.0, "Light from the camera's side on every model (off by default; --model-fill=on: the look's 1.1). Follows the ambient."],
	["pbr_fill", "Fill share", 0.0, 1.5, 0.01, Looks.PBR_FILL, "How much of the look's camera fill a pbr surface gets."],
	["pbr_ambient", "Ambient share", 0.0, 2.0, 0.01, Looks.PBR_AMBIENT, "How much of the scene's ambient a pbr surface gets."],
	["pbr_env", "Reflection k", 0.0, 1.0, 0.01, Looks.PBR_ENV, "The sun's share in the neutral reflection (metal)."],
	["pbr_sun_lobe", "Sun lobe", 0.0, 5.0, 0.05, Looks.PBR_SUN_LOBE, "The height of the sun's reflection lobe (directional only)."],
	["pbr_ground", "Down ambient", 0.0, 1.0, 0.01, Looks.PBR_GROUND, "The ambient on faces pointing down, as a share of the sky's (directional only)."],
	["pbr_metal", "Metal share", 0.0, 1.0, 0.01, Looks.PBR_METAL, "The share of a pbr pack's metal drawn."],
]


## The Lighting tab: sliders for the pbr light numbers, live, nothing saved.
func _light_page() -> Control:
	var page := VBoxContainer.new()
	page.name = "LightingPage"
	page.add_theme_constant_override("separation", Kit.px(6))
	var about := MenuKit.paragraph("The camera fill and the pbr packs' light numbers, applied live and not saved (the next start takes the look's and the command line's). Dragging a slider overrides that number; Reset puts the default back. Copy values prints them to the log.", 660)
	about.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
	page.add_child(about)
	_light_flat = MenuKit.checkbox("Lit by direction", true)
	_light_flat.name = "Light_directional"
	_light_flat.tooltip_text = "Off: the old flat balance (--pbr-light=flat)."
	_light_flat.toggled.connect(func(on: bool) -> void: set_light("pbr_directional", 1.0 if on else 0.0))
	page.add_child(_light_flat)
	for l: Array in LIGHT:
		var key: String = l[0]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", Kit.px(10))
		var name_label := Kit.label(str(l[1]))
		name_label.custom_minimum_size.x = Kit.px(120)
		name_label.tooltip_text = str(l[6])
		row.add_child(name_label)
		var sl := MenuKit.slider(float(l[2]), float(l[3]), float(l[4]), float(l[5]))
		sl.name = "Light_" + key
		sl.custom_minimum_size.x = Kit.px(300)
		sl.tooltip_text = str(l[6])
		sl.value_changed.connect(func(v: float) -> void: set_light(key, v))
		row.add_child(sl)
		var val := Kit.label("")
		val.name = "LightValue_" + key
		val.custom_minimum_size.x = Kit.px(110)
		row.add_child(val)
		var reset := Button.new()
		reset.text = "Reset"
		reset.name = "LightReset_" + key
		reset.focus_mode = Control.FOCUS_NONE
		reset.pressed.connect(func() -> void: reset_light(key))
		row.add_child(reset)
		page.add_child(row)
		_light_sliders[key] = [sl, val]
	var live_about := MenuKit.paragraph("Ambient occlusion, indirect light, contact shading, the sun and the ambient: the numbers the game sets now (a look or a quality change moves them), until a slider is dragged; Reset gives that number back.", 660)
	live_about.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
	page.add_child(live_about)
	for t: Array in LIVE_TOGGLES:
		var key: String = t[0]
		var box := MenuKit.checkbox(str(t[1]), false)
		box.name = "Live_" + key
		box.tooltip_text = str(t[2])
		box.toggled.connect(func(on: bool) -> void: set_live(key, 1.0 if on else 0.0))
		var trow := HBoxContainer.new()
		trow.add_theme_constant_override("separation", Kit.px(10))
		trow.add_child(box)
		var treset := Button.new()
		treset.text = "Reset"
		treset.name = "LiveReset_" + key
		treset.tooltip_text = "Gives the switch back to the game (Settings > Graphics)."
		treset.focus_mode = Control.FOCUS_NONE
		treset.pressed.connect(func() -> void: reset_live(key))
		trow.add_child(treset)
		page.add_child(trow)
		_live_boxes[key] = box
	for l: Array in LIVE:
		var key: String = l[0]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", Kit.px(10))
		var name_label := Kit.label(str(l[1]))
		name_label.custom_minimum_size.x = Kit.px(120)
		name_label.tooltip_text = str(l[5])
		row.add_child(name_label)
		var sl := MenuKit.slider(float(l[2]), float(l[3]), float(l[4]), float(l[2]))
		sl.name = "Live_" + key
		sl.custom_minimum_size.x = Kit.px(300)
		sl.tooltip_text = str(l[5])
		sl.value_changed.connect(func(v: float) -> void: set_live(key, v))
		row.add_child(sl)
		var val := Kit.label("")
		val.name = "LiveValue_" + key
		val.custom_minimum_size.x = Kit.px(130)
		row.add_child(val)
		var reset := Button.new()
		reset.text = "Reset"
		reset.name = "LiveReset_" + key
		reset.focus_mode = Control.FOCUS_NONE
		reset.pressed.connect(func() -> void: reset_live(key))
		row.add_child(reset)
		page.add_child(row)
		_live_sliders[key] = [sl, val]
	var copy := Button.new()
	copy.text = "Copy values"
	copy.name = "LightCopy"
	copy.focus_mode = Control.FOCUS_NONE
	copy.pressed.connect(copy_light)
	page.add_child(copy)
	_sync_light()
	return page


## One pbr light number set live (Looks.pbr_tune). False in a public build.
func set_light(key: String, v: float) -> bool:
	if not Settings.dev_tools():
		_sync_light()
		return false
	Looks.pbr_tune[key] = v
	_sync_light()
	return true


func reset_light(key: String) -> void:
	Looks.pbr_tune.erase(key)
	_sync_light()


## The tab's text: every number now (an override or its default), for the log.
func light_text() -> String:
	var parts: PackedStringArray = []
	for l: Array in LIGHT:
		parts.append("%s=%.3f" % [l[0], float(Looks.pbr_tune.get(l[0], l[5]))])
	parts.append("pbr_directional=%d" % (1 if float(Looks.pbr_tune.get("pbr_directional", 1.0)) > 0.5 else 0))
	for t: Array in LIVE_TOGGLES:
		parts.append("%s=%d" % [t[0], 1 if live_value(t[0]) > 0.5 else 0])
	for l: Array in LIVE:
		parts.append("%s=%.3f" % [l[0], live_value(l[0])])
	return "light: " + " ".join(parts)


func copy_light() -> String:
	var t := light_text()
	print(t)
	DisplayServer.clipboard_set(t)
	return t


func _sync_light() -> void:
	_sync_live()
	for l: Array in LIGHT:
		var key: String = l[0]
		var pair: Array = _light_sliders[key] if _light_sliders.has(key) else []
		if pair.is_empty():
			continue
		var v := float(Looks.pbr_tune.get(key, l[5]))
		(pair[0] as HSlider).set_value_no_signal(v)
		(pair[1] as Label).text = "%.2f (%s%.2f)" % [v, "default " if not Looks.pbr_tune.has(key) else "was ", float(l[5])]
	if _light_flat != null:
		_light_flat.set_pressed_no_signal(float(Looks.pbr_tune.get("pbr_directional", 1.0)) > 0.5)


## The live-light numbers: [key, label, min, max, step, what it does]. Their defaults are read from the game as it is.
const LIVE := [
	["ssao_radius", "AO radius", 0.0, 4.0, 0.05, "Ambient occlusion: how far (tiles) a surface looks for what shades it."],
	["ssao_intensity", "AO intensity", 0.0, 8.0, 0.05, "Ambient occlusion: how dark the occluded places get."],
	["ssao_power", "AO power", 0.1, 8.0, 0.05, "Ambient occlusion: the curve (higher: darker creases, lighter open faces)."],
	["ssao_detail", "AO detail", 0.0, 1.0, 0.01, "Ambient occlusion: the small-scale detail."],
	["ssao_light_affect", "AO light affect", 0.0, 1.0, 0.01, "Ambient occlusion: how far it darkens direct light too, not only the ambient."],
	["ssao_horizon", "AO horizon", 0.0, 1.0, 0.01, "Ambient occlusion: the angle below which a flat surface's own plane isn't counted."],
	["ssao_sharpness", "AO sharpness", 0.0, 1.0, 0.01, "Ambient occlusion: how much it keeps its edges against the depth."],
	["ssil_radius", "SSIL radius", 0.0, 16.0, 0.1, "Screen-space indirect light: how far (tiles) light bounces from."],
	["ssil_intensity", "SSIL intensity", 0.0, 4.0, 0.05, "Screen-space indirect light: how much bounced light is added."],
	["contact_strength", "Contact strength", 0.0, 1.0, 0.01, "Contact shading: the rim's darkness at the building's edge."],
	["contact_rim", "Contact rim width", 0.01, 0.2, 0.005, "Contact shading: how fast the rim fades out (tiles)."],
	["contact_patch", "Contact patch width", 0.0, 0.6, 0.01, "Contact shading: how far the big machines' patch reaches past their foot (tiles)."],
	["sun_energy", "Sun energy", 0.0, 6.0, 0.05, "The sun's brightness (the time of day sets it each frame until you move this)."],
	["shadow_blur", "Shadow softness", 0.0, 8.0, 0.05, "The sun's shadow blur (the soft-shadow fit sets it until you move this)."],
	["shadow_bias", "Shadow bias", 0.0, 1.0, 0.005, "The sun shadow's depth bias (low: thin shadows kept, high: no acne)."],
	["shadow_normal_bias", "Shadow normal bias", 0.0, 8.0, 0.05, "The sun shadow's normal bias."],
	["ambient_energy", "Ambient energy", 0.0, 4.0, 0.02, "The ambient light's strength (the time of day sets it each frame until you move this)."],
	["ground_rough", "Ground roughness", -0.5, 0.5, 0.01, "Added to every ground tile's own roughness (terrain_textures.gd SURFACES; 0: as drawn)."],
]
const LIVE_TOGGLES := [
	["ssao_enabled", "Ambient occlusion (SSAO)", "Screen-space ambient occlusion on or off."],
	["ssil_enabled", "Indirect light (SSIL)", "Screen-space indirect lighting on or off."],
]
## The contact shading's shader uniforms the sliders move (the rest it sets itself: the rim's end and reach follow the width).
const CONTACT_UNIFORMS := {"contact_strength": "rim_dark", "contact_rim": "rim_falloff", "contact_patch": "patch_reach"}
## The shader's own defaults (contact_shade.gdshader's; the engine gives none back while a uniform is unset).
const CONTACT_FALLBACK := {"rim_dark": 0.47, "rim_falloff": 0.06, "patch_reach": 0.1}
## Those the items' rims share (item_cards.gd contact_param).
const ITEM_CONTACT_UNIFORMS := {"rim_dark": true, "rim_falloff": true}


func _live_env() -> Environment:
	if light_env != null:
		return light_env
	return main._env if main != null and main.get("_env") != null else null


func _live_sun() -> DirectionalLight3D:
	if light_sun != null:
		return light_sun
	return main._sun if main != null and main.get("_sun") != null else null


func _live_shadows():
	if light_shadows != null:
		return light_shadows
	return main.get("sun_shadows") if main != null else null


## What the game has now for one live number (the override, or the game's own value; 0 without a target).
func live_value(key: String) -> float:
	if Looks.light_tune.has(key):
		return float(Looks.light_tune[key])
	return _live_read(key)


func _live_read(key: String) -> float:
	var e := _live_env()
	var s := _live_sun()
	if CONTACT_UNIFORMS.has(key):
		var u: String = CONTACT_UNIFORMS[key]
		var m := ContactShade.material()
		var v = m.get_shader_parameter(u)
		return float(v) if v != null else float(CONTACT_FALLBACK[u])
	if key == "ground_rough":
		var g = Visuals.terrain_material().get_shader_parameter("surface_roughness_add")
		return float(g) if g != null else 0.0
	if key == "ambient_energy":
		return e.ambient_light_energy if e != null else 0.0
	if key == "sun_energy":
		return s.light_energy if s != null else 0.0
	if key == "shadow_blur" or key == "shadow_bias" or key == "shadow_normal_bias":
		return float(s.get(key)) if s != null else 0.0
	if e != null:
		var v2 = e.get(key)
		if v2 is bool:
			return 1.0 if v2 else 0.0
		if v2 != null:
			return float(v2)
	return 0.0


## Puts one live number on its target now (and Looks.light_tune keeps it there each frame, where the game would set it).
func _live_put(key: String, v: float) -> void:
	var e := _live_env()
	var s := _live_sun()
	if CONTACT_UNIFORMS.has(key):
		_contact_put(key, v)
	elif key == "ground_rough":
		Visuals.terrain_material().set_shader_parameter("surface_roughness_add", v)
	elif key == "shadow_blur":
		var sh = _live_shadows()
		if sh != null:
			sh.blur_override = v
		if s != null:
			s.shadow_blur = v
	else:
		var one := Looks.light_tune
		Looks.light_tune = {key: v}
		Looks.apply_light_tune(e, s)
		Looks.light_tune = one


func _contact_put(key: String, v: float) -> void:
	var m := ContactShade.material()
	m.set_shader_parameter(CONTACT_UNIFORMS[key], v)
	if ITEM_CONTACT_UNIFORMS.has(CONTACT_UNIFORMS[key]):
		ItemCards.contact_param(CONTACT_UNIFORMS[key], v)  # the items' rims (item_contact.gdshader) follow
	if key == "contact_rim":
		var end := maxf(0.25, v * 4.2)
		m.set_shader_parameter("rim_end", end)
		m.set_shader_parameter("ring_reach", maxf(ContactShade.REACH, end + 0.02))
	elif key == "contact_patch":
		m.set_shader_parameter("ring_patch_reach", maxf(ContactShade.patch_ring_reach(), v + 0.05))


## One live number set (dev builds only; False in a public build).
func set_live(key: String, v: float) -> bool:
	if not Settings.dev_tools():
		_sync_live()
		return false
	if not _live_was.has(key):
		_live_was[key] = _live_read(key)
	Looks.light_tune[key] = v
	_live_put(key, v)
	_sync_live()
	return true


func reset_live(key: String) -> void:
	if Looks.light_tune.has(key) and _live_was.has(key):
		Looks.light_tune.erase(key)
		var was: float = _live_was[key]
		_live_was.erase(key)
		if CONTACT_UNIFORMS.has(key):
			var m := ContactShade.material()
			m.set_shader_parameter(CONTACT_UNIFORMS[key], null)
			if ITEM_CONTACT_UNIFORMS.has(CONTACT_UNIFORMS[key]):
				ItemCards.contact_param(CONTACT_UNIFORMS[key], null)
			if key == "contact_rim":
				m.set_shader_parameter("rim_end", null)
				m.set_shader_parameter("ring_reach", ContactShade.REACH)
			elif key == "contact_patch":
				m.set_shader_parameter("patch_reach", ContactShade.PATCH_REACH - 0.05 if ContactShade.wide_patch else ContactShade.PATCH_EDGE)
				m.set_shader_parameter("ring_patch_reach", ContactShade.patch_ring_reach())
		else:
			_live_put(key, was)
			if key == "shadow_blur" and _live_shadows() != null:
				_live_shadows().blur_override = 0.0
	Looks.light_tune.erase(key)
	_sync_live()


func _sync_live() -> void:
	for l: Array in LIVE:
		var key: String = l[0]
		if not _live_sliders.has(key):
			continue
		var pair: Array = _live_sliders[key]
		var v := live_value(key)
		(pair[0] as HSlider).set_value_no_signal(v)
		(pair[1] as Label).text = "%.2f (%s%.2f)" % [v, "was " if Looks.light_tune.has(key) else "now ", float(_live_was.get(key, v))]
	for key in _live_boxes:
		(_live_boxes[key] as CheckBox).set_pressed_no_signal(live_value(key) > 0.5)
