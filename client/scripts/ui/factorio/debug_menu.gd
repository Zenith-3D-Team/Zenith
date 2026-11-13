extends Control
## Zenith's debug menu, opened only by its key (Settings > Controls > Miscellaneous > Debug menu,
## Ctrl+F12): out of players' way, and only in dev builds (Settings.dev_tools(): development
## downloads and a checkout); a public download has no key for it and it never opens, so its
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
## Esc cancels a running benchmark, then closes the report, then the menu.

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const MenuKit := preload("res://scripts/menu/menu_kit.gd")
const UiModel := preload("res://scripts/ui/factorio/ui_model.gd")
const GamePause := preload("res://scripts/net/game_pause.gd")
const BenchRunner := preload("res://scripts/debug/bench_runner.gd")
const DebugOverlay := preload("res://scripts/debug/debug_overlay.gd")
const ChunkGrid := preload("res://scripts/debug/chunk_grid.gd")
const RobotProbe := preload("res://scripts/debug/robot_probe.gd")
const FlickerProbe := preload("res://scripts/debug/flicker_probe.gd")
const BeltPathProbe := preload("res://scripts/debug/belt_path_probe.gd")
const TerrainProbe := preload("res://scripts/debug/terrain_probe.gd")
const FxDemo := preload("res://scripts/fx/fx_demo.gd")
const Sfx := preload("res://scripts/fx/sfx.gd")
const Settings := preload("res://scripts/menu/settings.gd")

const TABS := ["Time", "Benchmarks", "Tests"]
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
	for page in [_time_page(), _bench_page(), _tests_page()]:
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
