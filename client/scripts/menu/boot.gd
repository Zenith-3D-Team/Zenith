extends Node3D
## Lightweight startup loading screen (`scenes/boot.tscn`, entry point in `project.godot`).
## Runs `ShaderRefresh.restart_if_new_build()` before any 3D shaders or `main.tscn` load, then
## loads `main.tscn` on worker threads while driving staged `ShaderWarmup` and `RenderWarm`
## inside a Factorio-styled dark UI so the window stays responsive and shows progress.
## `--boot-screen=off` (and `--headless` runs) bypass directly to `res://scenes/main.tscn`.
## Skip (beside Cancel, while shaders/renderer warm) first warns about stutters with Wait (ETA) / Skip;
## the second Skip ends the warm-up and starts the game without recording it as warmed
## (`--boot-skip=off` hides the button).
##
## Top-level `preload()` is strictly limited to `ShaderRefresh` and `StallWatchdog` so the boot
## window paints on frame 1 without loading `main.gd`, `Kit`, `MenuKit`, `Settings`, or shaders.

const ShaderRefresh := preload("res://scripts/menu/shader_refresh.gd")
const StallWatchdog := preload("res://scripts/debug/stall_watchdog.gd")

const MAIN_SCENE := "res://scenes/main.tscn"
const SETTINGS_PATH := "res://scripts/menu/settings.gd"
const SHADER_WARMUP_PATH := "res://scripts/world/shader_warmup.gd"
const RENDER_WARM_PATH := "res://scripts/world/render_warm.gd"
const LOGO_PATH := "res://assets/branding/logo.png"

const BG_COLOR := Color8(26, 25, 26)
const PANEL_BG := Color8(45, 44, 45)
const PANEL_BORDER := Color8(25, 22, 21)
const CAPTION_GOLD := Color(1.0, 0.902, 0.753)
const SUB_TEXT := Color8(190, 188, 185)
const TIME_TEXT := Color8(224, 220, 214)
const HINT_TEXT := Color8(148, 146, 142)
const BAR_BG := Color8(60, 58, 60)
const BAR_BORDER := Color8(20, 20, 20)
const BAR_FILL_ORANGE := Color(0.98, 0.66, 0.22)
const BAR_FILL_GREEN := Color8(94, 182, 99)
const BTN_NORMAL := Color8(143, 143, 143)
const BTN_HOVER := Color8(255, 175, 0)
const BTN_PRESSED := Color8(230, 140, 0)
const BTN_DISABLED := Color8(100, 100, 100)
const BTN_BORDER := Color8(40, 40, 40)
const BTN_TEXT := Color8(28, 28, 28)

const BOOT_COLD_FPS := 30
const BOOT_UNFOCUSED_FPS := 15
const BOOT_WARM_FPS := 60
const PRIORITY_WAIT_MSEC := 1000
const PRIORITY_TIMEOUT_MSEC := 10000
const SKIP_WARNING_TEXT := ("Skipping now means the remaining shaders compile while you play: expect stutters "
	+ "(a short freeze the first time each building, effect or view appears) until they're done.")

static var priority_runner_override: Callable = Callable()

enum State { LOAD_MAIN, APPLY_WINDOW, WARM_SHADERS, WARM_RENDER, PRE_HANDOFF, HANDOFF, FINISH, DONE }

var _state := State.LOAD_MAIN
var _start_msec := 0
var _warm_start_msec := 0
var _handed_off := false
var _cold_compile := false
var _will_cold_compile := false
var _safe_compile := true
var _window_focused := true
var _warmup_ran := false
var _shader_warm_started := false
var _render_warm_started := false
var _apply_window_frames := 0
var _pre_handoff_frames := 0
var _finish_frames := 0

var _priority_requested := false
var _priority_lowered := false
var _priority_was := ""
var _priority_start_msec := 0
var _priority_job := {}
var _priority_out := ""

var _eta_sec := -1.0
var _eta_ewma_rate := 0.0
var _eta_last_weight := 0.0
var _eta_last_sample_msec := 0
var _eta_last_tick_msec := 0

var _boot_cam: Camera3D = null
var _boot_sun: DirectionalLight3D = null
var _warm_holder: Node3D = null

var _overlay: CanvasLayer = null
var _ui_root: Control = null
var _status_label: Label = null
var _progress_bar: ProgressBar = null
var _bar_fill_style: StyleBoxFlat = null
var _detail_label: Label = null
var _time_label: Label = null
var _safety_label: Label = null
var _cancel_btn: Button = null
var _skip_btn: Button = null
var _skip_warning: VBoxContainer = null
var _skip_wait_btn: Button = null
var _skip_confirm_btn: Button = null
var _skip_allowed := true
var _skipped := false
var _shader_done_seen := 0
var _shader_total_seen := 0

var _main_packed: PackedScene = null
var _shader_warmup_script: Script = null
var _render_warm_script: Script = null
var _shader_warm: Node3D = null
var _render_warm: Node = null


## True when the startup boot screen should be skipped straight to `main.tscn`.
static func should_bypass() -> bool:
	return should_bypass_for(DisplayServer.get_name(), OS.get_cmdline_user_args())


## Pure predicate for `should_bypass()`, split out for unit tests.
static func should_bypass_for(display_name: String, user_args: PackedStringArray) -> bool:
	return display_name == "headless" or "--boot-screen=off" in user_args


## False when `--boot-skip=off` hides the Skip button (read like `should_bypass_for`, not via Switches).
static func skip_allowed_for(user_args: PackedStringArray) -> bool:
	return not ("--boot-skip=off" in user_args)


static func compile_mode_for(user_args: PackedStringArray) -> String:
	for a in user_args:
		if a.begins_with("--shader-compile="):
			var v := a.substr(17).to_lower()
			if v == "fast" or v == "old":
				return "fast"
	return "safe"


static func is_safe_compile_for(user_args: PackedStringArray) -> bool:
	return compile_mode_for(user_args) == "safe"


static func format_duration(seconds: float, is_eta: bool = false) -> String:
	if is_eta:
		if seconds < 0.0:
			return "estimating…"
		if seconds < 1.0:
			return "< 1s"
		var s := int(round(seconds))
		if s < 60:
			return "~%ds" % s
		if s < 3600:
			return "~%dm %02ds" % [s / 60, s % 60]
		return "~%dh %02dm" % [s / 3600, (s % 3600) / 60]
	var e := maxi(0, int(floor(seconds)))
	if e < 60:
		return "%ds" % e
	if e < 3600:
		return "%dm %02ds" % [e / 60, e % 60]
	return "%dh %02dm" % [e / 3600, (e % 3600) / 60]


static func format_total_duration(seconds: float) -> String:
	if seconds < 10.0:
		return "%.1fs" % maxf(0.0, seconds)
	return format_duration(seconds, false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and not _handed_off and ShaderRefresh.child_pid == 0:
		_quit_requested()
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT and not _handed_off:
		_window_focused = false
		_on_focus_changed()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN and not _handed_off:
		_window_focused = true
		_on_focus_changed()


func _ready() -> void:
	if should_bypass():
		set_process(false)
		get_tree().change_scene_to_file.call_deferred(MAIN_SCENE)
		return
	if ShaderRefresh.restart_if_new_build():
		ShaderRefresh.wait_for_child(self)
		return
	StallWatchdog.start()
	StallWatchdog.mark("boot: ready")
	_start_msec = Time.get_ticks_msec()
	var user_args := OS.get_cmdline_user_args()
	_safe_compile = is_safe_compile_for(user_args)
	_skip_allowed = skip_allowed_for(user_args)
	_will_cold_compile = not ("--warm-shaders=off" in user_args) and (ShaderRefresh.needs_compile() or ("--warm-shaders=all" in user_args))
	_apply_boot_fps_cap()
	if _safe_compile and _will_cold_compile and (DisplayServer.get_name() != "headless" or priority_runner_override.is_valid()):
		_begin_lower_priority()
	_setup_3d_rig()
	_build_ui()
	_update_safety_label()
	var err := ResourceLoader.load_threaded_request(MAIN_SCENE, "PackedScene", true)
	if err != OK:
		_fallback_to_main()


func _process(_delta: float) -> void:
	_poll_priority_job()
	_update_skip_ui()
	match _state:
		State.LOAD_MAIN:
			_step_load_main()
		State.APPLY_WINDOW:
			_step_apply_window()
		State.WARM_SHADERS:
			_step_warm_shaders()
		State.WARM_RENDER:
			_step_warm_render()
		State.PRE_HANDOFF:
			_step_pre_handoff()
		State.HANDOFF:
			_handoff()
		State.FINISH:
			_finish_frames += 1
			if _finish_frames >= 2:
				_state = State.DONE
				queue_free()
		State.DONE:
			pass


func _setup_3d_rig() -> void:
	_boot_cam = Camera3D.new()
	_boot_cam.name = "BootCamera"
	_boot_cam.current = true
	add_child(_boot_cam)
	_boot_cam.look_at_from_position(Vector3(0, 0, 2), Vector3.ZERO, Vector3.UP)

	_boot_sun = DirectionalLight3D.new()
	_boot_sun.name = "BootSun"
	_boot_sun.rotation_degrees = Vector3(-45, 30, 0)
	add_child(_boot_sun)

	_warm_holder = Node3D.new()
	_warm_holder.name = "WarmHolder"
	add_child(_warm_holder)


func _build_ui() -> void:
	_overlay = CanvasLayer.new()
	_overlay.name = "BootOverlay"
	_overlay.layer = 100
	add_child(_overlay)

	_ui_root = Control.new()
	_ui_root.name = "BootRoot"
	_ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ui_root.theme = Theme.new()
	_overlay.add_child(_ui_root)

	var bg := ColorRect.new()
	bg.name = "Backdrop"
	bg.color = BG_COLOR
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ui_root.add_child(bg)

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ui_root.add_child(center)

	var panel := PanelContainer.new()
	panel.name = "BootPanel"
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = PANEL_BG
	panel_style.border_color = PANEL_BORDER
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(2)
	panel.add_theme_stylebox_override("panel", panel_style)
	center.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	margin.add_child(vbox)

	if ResourceLoader.exists(LOGO_PATH):
		var logo_tex := ResourceLoader.load(LOGO_PATH) as Texture2D
		if logo_tex != null:
			var logo := TextureRect.new()
			logo.name = "Logo"
			logo.texture = logo_tex
			logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			logo.custom_minimum_size = Vector2(480, 86)
			logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
			vbox.add_child(logo)
		else:
			vbox.add_child(_make_title_label())
	else:
		vbox.add_child(_make_title_label())

	_status_label = Label.new()
	_status_label.name = "StatusLabel"
	_status_label.text = "Loading Zenith…"
	_status_label.add_theme_color_override("font_color", CAPTION_GOLD)
	_status_label.add_theme_font_size_override("font_size", 18)
	_status_label.custom_minimum_size = Vector2(520, 0)
	vbox.add_child(_status_label)

	_progress_bar = ProgressBar.new()
	_progress_bar.name = "ProgressBar"
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = 1.0
	_progress_bar.step = 0.001
	_progress_bar.value = 0.0
	_progress_bar.show_percentage = false
	_progress_bar.custom_minimum_size = Vector2(520, 18)
	_progress_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = BAR_BG
	bar_bg.border_color = BAR_BORDER
	bar_bg.set_border_width_all(1)
	bar_bg.set_corner_radius_all(2)
	_progress_bar.add_theme_stylebox_override("background", bar_bg)

	_bar_fill_style = StyleBoxFlat.new()
	_bar_fill_style.bg_color = BAR_FILL_ORANGE
	_bar_fill_style.set_corner_radius_all(2)
	_progress_bar.add_theme_stylebox_override("fill", _bar_fill_style)
	vbox.add_child(_progress_bar)

	_detail_label = Label.new()
	_detail_label.name = "DetailLabel"
	_detail_label.text = ""
	_detail_label.add_theme_color_override("font_color", SUB_TEXT)
	_detail_label.add_theme_font_size_override("font_size", 13)
	_detail_label.custom_minimum_size = Vector2(520, 0)
	_detail_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	vbox.add_child(_detail_label)

	_time_label = Label.new()
	_time_label.name = "TimeLabel"
	_time_label.text = "Time: 0s"
	_time_label.add_theme_color_override("font_color", TIME_TEXT)
	_time_label.add_theme_font_size_override("font_size", 14)
	_time_label.custom_minimum_size = Vector2(520, 0)
	vbox.add_child(_time_label)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	vbox.add_child(btn_row)

	_safety_label = Label.new()
	_safety_label.name = "SafetyLabel"
	_safety_label.text = ""
	_safety_label.visible = false
	_safety_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_safety_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_safety_label.add_theme_color_override("font_color", HINT_TEXT)
	_safety_label.add_theme_font_size_override("font_size", 12)
	btn_row.add_child(_safety_label)

	_skip_btn = _make_button("SkipButton", "Skip")
	_skip_btn.tooltip_text = "Start without waiting for the shader warm-up"
	_skip_btn.pressed.connect(_on_skip_pressed)
	_skip_btn.visible = _skip_allowed
	_skip_btn.disabled = true
	btn_row.add_child(_skip_btn)

	_cancel_btn = _make_button("CancelButton", "Cancel")
	_cancel_btn.pressed.connect(_quit_requested)
	btn_row.add_child(_cancel_btn)

	# The stutter warning the first Skip opens, between the time line and the buttons.
	_skip_warning = VBoxContainer.new()
	_skip_warning.name = "SkipWarning"
	_skip_warning.add_theme_constant_override("separation", 8)
	_skip_warning.visible = false
	vbox.add_child(_skip_warning)
	vbox.move_child(_skip_warning, btn_row.get_index())
	var warn_label := Label.new()
	warn_label.name = "SkipWarningLabel"
	warn_label.text = SKIP_WARNING_TEXT
	warn_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	warn_label.custom_minimum_size = Vector2(520, 0)
	warn_label.add_theme_color_override("font_color", CAPTION_GOLD)
	warn_label.add_theme_font_size_override("font_size", 14)
	_skip_warning.add_child(warn_label)
	var warn_row := HBoxContainer.new()
	warn_row.name = "SkipWarningButtons"
	warn_row.alignment = BoxContainer.ALIGNMENT_END
	_skip_warning.add_child(warn_row)
	_skip_wait_btn = _make_button("SkipWaitButton", "Wait")
	_skip_wait_btn.custom_minimum_size = Vector2(150, 32)
	_skip_wait_btn.pressed.connect(_on_skip_wait)
	warn_row.add_child(_skip_wait_btn)
	_skip_confirm_btn = _make_button("SkipConfirmButton", "Skip")
	_skip_confirm_btn.pressed.connect(_on_skip_confirm)
	warn_row.add_child(_skip_confirm_btn)


func _make_button(node_name: String, text: String) -> Button:
	var btn := Button.new()
	btn.name = node_name
	btn.text = text
	btn.custom_minimum_size = Vector2(96, 32)
	btn.add_theme_stylebox_override("normal", _button_style(BTN_NORMAL))
	btn.add_theme_stylebox_override("hover", _button_style(BTN_HOVER))
	btn.add_theme_stylebox_override("pressed", _button_style(BTN_PRESSED))
	btn.add_theme_stylebox_override("disabled", _button_style(BTN_DISABLED))
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		btn.add_theme_color_override(c, BTN_TEXT)
	return btn


func _make_title_label() -> Label:
	var title := Label.new()
	title.name = "Logo"
	title.text = "ZENITH"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", CAPTION_GOLD)
	title.add_theme_font_size_override("font_size", 48)
	return title


func _button_style(bg_color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg_color
	style.border_color = BTN_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	return style


func _elapsed_sec() -> float:
	if _start_msec <= 0:
		return 0.0
	return float(Time.get_ticks_msec() - _start_msec) / 1000.0


func _set_progress(fraction: float, status_text: String, detail_text: String = "", time_text: String = "") -> void:
	if _progress_bar != null:
		_progress_bar.value = clampf(maxf(_progress_bar.value, fraction), 0.0, 1.0)
	if _status_label != null:
		_status_label.text = status_text
	if _detail_label != null:
		_detail_label.text = detail_text
	if _time_label != null and time_text != "":
		_time_label.text = time_text


func _on_focus_changed() -> void:
	_apply_boot_fps_cap()
	if _shader_warm != null and is_instance_valid(_shader_warm) and _shader_warm.get(&"background_throttle") != null:
		_shader_warm.set(&"background_throttle", not _window_focused)
	_update_safety_label()


func _apply_boot_fps_cap() -> void:
	if DisplayServer.get_name() == "headless" or not _safe_compile:
		return
	var want_fps := BOOT_UNFOCUSED_FPS if not _window_focused else (BOOT_COLD_FPS if (_cold_compile or _will_cold_compile) else BOOT_WARM_FPS)
	Engine.max_fps = want_fps


func _update_safety_label() -> void:
	if _safety_label == null:
		return
	if _safe_compile and (_cold_compile or _will_cold_compile):
		_safety_label.visible = true
		_safety_label.text = "Background priority (reduced pace while unfocused)" if not _window_focused else "Background priority — safe to use other apps"
	else:
		_safety_label.visible = false


func _begin_lower_priority() -> void:
	_priority_requested = true
	_priority_start_msec = Time.get_ticks_msec()
	_priority_out = ""
	if priority_runner_override.is_valid():
		var res: Variant = priority_runner_override.call("BelowNormal")
		if res is Dictionary:
			var d: Dictionary = res
			if bool(d.get("done", false)):
				_priority_was = str(d.get("was", ""))
				_priority_lowered = true
			elif int(d.get("pid", -1)) > 0:
				_priority_job = d
		return
	if DisplayServer.get_name() == "headless":
		return
	if OS.get_name() == "Windows":
		var script := ("try { $p = Get-Process -Id %d -ErrorAction Stop; $was = $p.PriorityClass; $p.PriorityClass = 'BelowNormal'; "
			+ "$p.Refresh(); 'ok {0} {1}' -f $was, $p.PriorityClass } catch { 'error ' + $_.Exception.Message }") \
			% OS.get_process_id()
		var job := OS.execute_with_pipe("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script], false)
		if not job.is_empty():
			_priority_job = job
	else:
		var pid := OS.create_process("renice", ["-n", "10", "-p", str(OS.get_process_id())], false)
		if pid != -1:
			_priority_lowered = true


func _poll_priority_job() -> void:
	if _priority_job.is_empty():
		return
	var pid := int(_priority_job.get("pid", -1))
	var io: FileAccess = _priority_job.get("stdio")
	for _i in 16:
		var line := io.get_line() if io != null else ""
		if line == "":
			break
		_priority_out += line
	if pid > 0 and OS.is_process_running(pid):
		if Time.get_ticks_msec() - _priority_start_msec > PRIORITY_TIMEOUT_MSEC:
			OS.kill(pid)
			_priority_job = {}
		return
	_priority_job = {}
	var parts := _priority_out.strip_edges().split(" ", false)
	if parts.size() >= 3 and parts[0] == "ok":
		if _priority_was == "":
			_priority_was = parts[1]
		_priority_lowered = true


func _cancel_priority_job() -> void:
	if _priority_job.is_empty():
		return
	var pid := int(_priority_job.get("pid", -1))
	if pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)
	_priority_job = {}


func _update_shader_eta(now_msec: int, done_c: int, completed_w: float, total_w: float) -> float:
	if _warm_start_msec <= 0:
		_warm_start_msec = now_msec
	var warm_elapsed := maxf(0.0, float(now_msec - _warm_start_msec) / 1000.0)
	if total_w <= 0.0 or completed_w <= 0.0:
		return -1.0
	var min_ready := (done_c >= 2 and warm_elapsed >= 0.8 and (completed_w / total_w) >= 0.02) or warm_elapsed >= 2.5
	if not min_ready:
		return -1.0
	if completed_w > _eta_last_weight:
		var dw := completed_w - _eta_last_weight
		var prev_sample := _eta_last_sample_msec if _eta_last_sample_msec > 0 else _warm_start_msec
		var dt := maxf(0.016, float(now_msec - prev_sample) / 1000.0)
		var cum_rate := warm_elapsed / completed_w
		var inst_rate := clampf(dt / dw, cum_rate * 0.2, cum_rate * 4.0)
		if _eta_ewma_rate <= 0.0:
			_eta_ewma_rate = inst_rate
		else:
			_eta_ewma_rate = lerpf(_eta_ewma_rate, inst_rate, 0.25)
		var blended_rate := 0.65 * cum_rate + 0.35 * _eta_ewma_rate
		var rem_w := maxf(0.0, total_w - completed_w)
		var render_tail := clampf(total_w * blended_rate * 0.05, 0.3, 3.0) if _cold_compile else 0.2
		var target_eta := rem_w * blended_rate + render_tail
		if _eta_sec < 0.0:
			_eta_sec = target_eta
		else:
			_eta_sec = lerpf(_eta_sec, target_eta, 0.35)
		_eta_last_weight = completed_w
		_eta_last_sample_msec = now_msec
		_eta_last_tick_msec = now_msec
	elif _eta_sec >= 0.0:
		var prev_tick := _eta_last_tick_msec if _eta_last_tick_msec > 0 else now_msec
		var tick_dt := clampf(float(now_msec - prev_tick) / 1000.0, 0.0, 2.0)
		_eta_last_tick_msec = now_msec
		var prev_sample := _eta_last_sample_msec if _eta_last_sample_msec > 0 else _warm_start_msec
		var stall_sec := float(now_msec - prev_sample) / 1000.0
		if stall_sec > 3.0:
			var cum_rate := warm_elapsed / completed_w
			var rem_w := maxf(0.0, total_w - completed_w)
			var render_tail := clampf(total_w * cum_rate * 0.05, 0.3, 3.0) if _cold_compile else 0.2
			var overtime_eta := rem_w * cum_rate + stall_sec * 0.5 + render_tail
			_eta_sec = lerpf(_eta_sec, maxf(_eta_sec, overtime_eta), 0.15)
		else:
			var floor_sec := 1.0 if completed_w < total_w else 0.0
			_eta_sec = maxf(floor_sec, _eta_sec - tick_dt)
	return _eta_sec


func _step_load_main() -> void:
	var prog := []
	var status := ResourceLoader.load_threaded_get_status(MAIN_SCENE, prog)
	match status:
		ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			var p: float = float(prog[0]) if not prog.is_empty() else 0.0
			_set_progress(p * 0.25, "Loading Zenith…", "Scene & assets", "Time: %s" % format_duration(_elapsed_sec()))
			StallWatchdog.mark("boot: load_main %.0f%%" % (p * 100.0))
		ResourceLoader.THREAD_LOAD_LOADED:
			_main_packed = ResourceLoader.load_threaded_get(MAIN_SCENE) as PackedScene
			if _main_packed == null:
				_fallback_to_main()
				return
			_shader_warmup_script = ResourceLoader.load(SHADER_WARMUP_PATH) as Script
			_render_warm_script = ResourceLoader.load(RENDER_WARM_PATH) as Script
			var settings_script := ResourceLoader.load(SETTINGS_PATH) as Script
			if settings_script != null and is_inside_tree():
				settings_script.call(&"load_settings")
				settings_script.call(&"apply_window", get_tree().root)
				if DisplayServer.get_name() != "headless":
					if _safe_compile:
						DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
						_apply_boot_fps_cap()
					else:
						# Legacy --shader-compile=fast|old: uncap VSync during warm-up; Main._ready restores VSync.
						DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
			_apply_window_frames = 0
			_set_progress(0.25, "Preparing display…", "Window & graphics", "Time: %s" % format_duration(_elapsed_sec()))
			_state = State.APPLY_WINDOW
		ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			_fallback_to_main()


func _step_apply_window() -> void:
	_apply_window_frames += 1
	_set_progress(0.25 + 0.05 * minf(1.0, float(_apply_window_frames) / 2.0), "Preparing display…", "Window & graphics", "Time: %s" % format_duration(_elapsed_sec()))
	StallWatchdog.mark("boot: apply_window")
	if _apply_window_frames >= 2:
		if not _priority_job.is_empty() and Time.get_ticks_msec() - _priority_start_msec < PRIORITY_WAIT_MSEC:
			return
		_state = State.WARM_SHADERS


func _step_warm_shaders() -> void:
	if not _shader_warm_started:
		_shader_warm_started = true
		var mode_val: Variant = _shader_warmup_script.get(&"mode") if _shader_warmup_script != null else "loaded"
		var warmup_mode: String = str(mode_val) if mode_val != null else "loaded"
		_cold_compile = ShaderRefresh.needs_compile()
		if warmup_mode == "off" or (warmup_mode == "cold" and not _cold_compile):
			_state = State.WARM_RENDER
			return
		var addon_dirs: Array[String] = ShaderRefresh.addon_shader_dirs()
		var warm_all: bool = _cold_compile or warmup_mode == "all"
		if warm_all and _safe_compile and not _priority_requested and (DisplayServer.get_name() != "headless" or priority_runner_override.is_valid()):
			_begin_lower_priority()
		_apply_boot_fps_cap()
		_update_safety_label()
		var budget: int = 16 if (warm_all and _safe_compile) else (35 if warm_all else 50)
		if _shader_warmup_script != null and _shader_warmup_script.has_method(&"begin_staged"):
			_shader_warm = _shader_warmup_script.call(&"begin_staged", _warm_holder, warm_all, addon_dirs, budget) as Node3D
		if _shader_warm == null:
			_state = State.WARM_RENDER
			return
		if not _window_focused and _shader_warm.get(&"background_throttle") != null:
			_shader_warm.set(&"background_throttle", true)
		_warm_start_msec = Time.get_ticks_msec()
		_eta_sec = -1.0
		_eta_ewma_rate = 0.0
		_eta_last_weight = 0.0
		_eta_last_sample_msec = _warm_start_msec
		_eta_last_tick_msec = _warm_start_msec
		_warmup_ran = true

	if _shader_warm == null or not is_instance_valid(_shader_warm):
		_state = State.WARM_RENDER
		return

	var done_c: int = int(_shader_warm.get(&"done_count"))
	var raw_total: int = int(_shader_warm.get(&"total_count"))
	_shader_done_seen = done_c
	_shader_total_seen = raw_total
	var total_c: int = maxi(1, raw_total)
	var cur_label: String = str(_shader_warm.get(&"current_label"))
	var pipes: int = int(_shader_warm.call(&"pipelines_compiled")) if _shader_warm.has_method(&"pipelines_compiled") else 0
	var has_weighted := _shader_warm.has_method(&"progress_fraction")
	var warm_frac: float = float(_shader_warm.call(&"progress_fraction")) if has_weighted else (float(done_c) / float(total_c))
	var completed_w: float = float(_shader_warm.get(&"completed_weight")) if has_weighted else float(done_c)
	var total_w: float = float(_shader_warm.get(&"total_weight")) if has_weighted else float(total_c)
	var frac: float = 0.30 + 0.50 * clampf(warm_frac, 0.0, 1.0)
	var verb: String = "Compiling shaders…" if _cold_compile else "Warming shader cache…"
	var status_txt := "%s (%d / %d)" % [verb, done_c, raw_total]
	var label_shown := cur_label if cur_label != "" else "Preparing…"
	var sub_txt := "%s  •  %d pipelines" % [label_shown, pipes]
	var eta := _update_shader_eta(Time.get_ticks_msec(), done_c, completed_w, total_w)
	var time_txt := "Time: %s  •  ETA: %s" % [format_duration(_elapsed_sec()), format_duration(eta, true)]
	_set_progress(frac, status_txt, sub_txt, time_txt)
	StallWatchdog.mark("boot: shader " + (cur_label if cur_label != "" else "init"))
	if bool(_shader_warm.call(&"is_done")):
		_state = State.WARM_RENDER


func _step_warm_render() -> void:
	if not _render_warm_started:
		_render_warm_started = true
		if _render_warm_script != null and _render_warm_script.has_method(&"begin_staged"):
			_render_warm = _render_warm_script.call(&"begin_staged", self) as Node
		if _render_warm == null:
			_pre_handoff_frames = 0
			_state = State.PRE_HANDOFF
			return

	if _render_warm == null or not is_instance_valid(_render_warm):
		_pre_handoff_frames = 0
		_state = State.PRE_HANDOFF
		return

	var done_c: int = int(_render_warm.get(&"done_count"))
	var total_c: int = maxi(1, int(_render_warm.get(&"total_count")))
	var cur_label: String = str(_render_warm.get(&"current_label"))
	var frac: float = 0.80 + 0.15 * (float(done_c) / float(total_c))
	var label_shown := cur_label if cur_label != "" else "Post-processing"
	var now_msec := Time.get_ticks_msec()
	if _eta_sec >= 0.0:
		var prev_tick := _eta_last_tick_msec if _eta_last_tick_msec > 0 else now_msec
		var tick_dt := clampf(float(now_msec - prev_tick) / 1000.0, 0.0, 2.0)
		_eta_last_tick_msec = now_msec
		_eta_sec = maxf(0.5, _eta_sec - tick_dt)
	var eta_txt := format_duration(_eta_sec, true) if _eta_sec >= 0.0 else "finishing…"
	_set_progress(frac, "Preparing renderer…", label_shown, "Time: %s  •  ETA: %s" % [format_duration(_elapsed_sec()), eta_txt])
	StallWatchdog.mark("boot: render " + label_shown)
	if bool(_render_warm.call(&"is_done")):
		_pre_handoff_frames = 0
		_state = State.PRE_HANDOFF


func _step_pre_handoff() -> void:
	if _pre_handoff_frames == 0:
		if _bar_fill_style != null:
			_bar_fill_style.bg_color = BAR_FILL_GREEN
		if _cancel_btn != null:
			_cancel_btn.disabled = true
		_update_skip_ui()
		_set_progress(1.0, "Starting Zenith…", "Ready", "Total time: %s" % format_total_duration(_elapsed_sec()))
		StallWatchdog.mark("boot: starting main")
		_pre_handoff_frames = 1
		return
	_state = State.HANDOFF
	_handoff()


func _handoff() -> void:
	_handed_off = true
	_cancel_priority_job()
	StallWatchdog.mark("boot: handoff")
	if _warmup_ran and not _skipped:
		ShaderRefresh.mark_warmed()
	if _shader_warmup_script != null:
		_shader_warmup_script.set(&"handled_by_boot", true)
	if _render_warm_script != null:
		_render_warm_script.set(&"done", true)

	_drop_node(_shader_warm)
	_shader_warm = null
	_drop_node(_render_warm)
	_render_warm = null
	_drop_node(_warm_holder)
	_warm_holder = null
	_drop_node(_boot_cam)
	_boot_cam = null
	_drop_node(_boot_sun)
	_boot_sun = null

	if _bar_fill_style != null:
		_bar_fill_style.bg_color = BAR_FILL_GREEN
	if _cancel_btn != null:
		_cancel_btn.disabled = true
	_set_progress(1.0, "Starting Zenith…", "Ready", "Total time: %s" % format_total_duration(_elapsed_sec()))

	if _main_packed == null:
		_fallback_to_main()
		return

	var main_node: Node = _main_packed.instantiate()
	var main_script := main_node.get_script() as Script
	if main_script != null:
		main_script.set(&"booted_from_screen", true)
		if (_priority_lowered or _priority_requested) and main_script.get(&"boot_priority_lowered") != null:
			main_script.set(&"boot_priority_lowered", true)
			main_script.set(&"boot_priority_was", _priority_was)
	var tree := get_tree()
	tree.root.add_child(main_node)
	tree.current_scene = main_node
	_finish_frames = 0
	_state = State.FINISH


func _drop_node(node: Node) -> void:
	if node == null or not is_instance_valid(node):
		return
	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	node.queue_free()


func _fallback_to_main() -> void:
	_state = State.DONE
	set_process(false)
	_cancel_priority_job()
	_drop_node(_shader_warm)
	_drop_node(_render_warm)
	_drop_node(_warm_holder)
	_drop_node(_boot_cam)
	_drop_node(_boot_sun)
	get_tree().change_scene_to_file.call_deferred(MAIN_SCENE)


func _quit_requested() -> void:
	if _handed_off:
		return
	_state = State.DONE
	set_process(false)
	_cancel_priority_job()
	StallWatchdog.stop()
	get_tree().quit(0)


func _in_warm_state() -> bool:
	return _state == State.WARM_SHADERS or _state == State.WARM_RENDER


## Keeps Skip usable only while shaders or the renderer warm, and the warning's Wait showing the live ETA.
func _update_skip_ui() -> void:
	var can_skip := _skip_allowed and _in_warm_state() and not _skipped and not _handed_off
	if _skip_warning != null and _skip_warning.visible and not can_skip:
		_skip_warning.visible = false
	if _skip_btn != null:
		_skip_btn.visible = _skip_allowed
		_skip_btn.disabled = not can_skip or (_skip_warning != null and _skip_warning.visible)
	if _skip_wait_btn != null and _skip_warning != null and _skip_warning.visible:
		_skip_wait_btn.text = skip_wait_text(_eta_sec)


## "Wait (ETA ~2m 10s)", or "Wait" alone while there's no estimate yet.
static func skip_wait_text(eta_sec: float) -> String:
	if eta_sec < 0.0:
		return "Wait"
	return "Wait (ETA %s)" % format_duration(eta_sec, true)


## First Skip: warn about stutters; the warm-up keeps running underneath.
func _on_skip_pressed() -> void:
	if not _skip_allowed or not _in_warm_state() or _skipped or _handed_off or _skip_warning == null:
		return
	_skip_warning.visible = true
	_update_skip_ui()
	if _skip_wait_btn != null and _skip_wait_btn.is_inside_tree():
		_skip_wait_btn.grab_focus()
	StallWatchdog.mark("boot: skip warning")


## Wait (or Esc): close the warning and carry on warming.
func _on_skip_wait() -> void:
	if _skip_warning != null:
		_skip_warning.visible = false
	_update_skip_ui()


## Second Skip: really skip.
func _on_skip_confirm() -> void:
	if _skip_warning == null or not _skip_warning.visible:
		return
	_skip_warmup()


func _unhandled_input(event: InputEvent) -> void:
	if _handle_skip_key(event) and is_inside_tree():
		get_viewport().set_input_as_handled()


## Esc while the stutter warning shows = Wait. True when the key was used.
func _handle_skip_key(event: InputEvent) -> bool:
	if _skip_warning == null or not _skip_warning.visible:
		return false
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or key.keycode != KEY_ESCAPE:
		return false
	_on_skip_wait()
	return true


## Ends the shader and render warm-up early and goes on to PRE_HANDOFF/HANDOFF as a finished warm-up
## would, but without `mark_warmed()`: the next start warms what's left (Godot's cache keeps what compiled).
func _skip_warmup() -> void:
	if not _in_warm_state() or _skipped or _handed_off:
		return
	_skipped = true
	var stage := "shaders" if _state == State.WARM_SHADERS else "renderer"
	print("[boot] shader warm-up skipped by the player at %d / %d (ETA was %s, during %s)" % [
		_shader_done_seen, _shader_total_seen,
		("%.0fs" % _eta_sec) if _eta_sec >= 0.0 else "unknown", stage])
	StallWatchdog.mark("boot: warm-up skipped (%s)" % stage)
	if _shader_warm != null and is_instance_valid(_shader_warm) and _shader_warm.has_method(&"stop_staged"):
		_shader_warm.call(&"stop_staged")
	_drop_node(_shader_warm)
	_shader_warm = null
	_drop_node(_render_warm)
	_render_warm = null
	_shader_warm_started = true
	_render_warm_started = true
	if _skip_warning != null:
		_skip_warning.visible = false
	if _safety_label != null:
		_safety_label.visible = false
	_pre_handoff_frames = 0
	_state = State.PRE_HANDOFF
	_update_skip_ui()
