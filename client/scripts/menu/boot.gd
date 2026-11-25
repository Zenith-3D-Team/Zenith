extends Node3D
## Lightweight startup loading screen (`scenes/boot.tscn`, entry point in `project.godot`).
## Runs `ShaderRefresh.restart_if_new_build()` before any 3D shaders or `main.tscn` load, then
## loads `main.tscn` on worker threads while driving staged `ShaderWarmup` and `RenderWarm`
## inside a Factorio-styled dark UI so the window stays responsive and shows progress.
## `--boot-screen=off` (and `--headless` runs) bypass directly to `res://scenes/main.tscn`.
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

enum State { LOAD_MAIN, APPLY_WINDOW, WARM_SHADERS, WARM_RENDER, PRE_HANDOFF, HANDOFF, FINISH, DONE }

var _state := State.LOAD_MAIN
var _start_msec := 0
var _handed_off := false
var _cold_compile := false
var _warmup_ran := false
var _shader_warm_started := false
var _render_warm_started := false
var _apply_window_frames := 0
var _pre_handoff_frames := 0
var _finish_frames := 0

var _boot_cam: Camera3D = null
var _boot_sun: DirectionalLight3D = null
var _warm_holder: Node3D = null

var _overlay: CanvasLayer = null
var _ui_root: Control = null
var _status_label: Label = null
var _progress_bar: ProgressBar = null
var _bar_fill_style: StyleBoxFlat = null
var _detail_label: Label = null
var _cancel_btn: Button = null

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


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and not _handed_off and ShaderRefresh.child_pid == 0:
		_quit_requested()


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
	_setup_3d_rig()
	_build_ui()
	var err := ResourceLoader.load_threaded_request(MAIN_SCENE, "PackedScene", true)
	if err != OK:
		_fallback_to_main()


func _process(_delta: float) -> void:
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

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	vbox.add_child(btn_row)

	_cancel_btn = Button.new()
	_cancel_btn.name = "CancelButton"
	_cancel_btn.text = "Cancel"
	_cancel_btn.custom_minimum_size = Vector2(96, 32)
	_cancel_btn.add_theme_stylebox_override("normal", _button_style(BTN_NORMAL))
	_cancel_btn.add_theme_stylebox_override("hover", _button_style(BTN_HOVER))
	_cancel_btn.add_theme_stylebox_override("pressed", _button_style(BTN_PRESSED))
	_cancel_btn.add_theme_stylebox_override("disabled", _button_style(BTN_DISABLED))
	_cancel_btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		_cancel_btn.add_theme_color_override(c, BTN_TEXT)
	_cancel_btn.pressed.connect(_quit_requested)
	btn_row.add_child(_cancel_btn)


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


func _set_progress(fraction: float, status_text: String, detail_text: String = "") -> void:
	if _progress_bar != null:
		_progress_bar.value = clampf(maxf(_progress_bar.value, fraction), 0.0, 1.0)
	if _status_label != null:
		_status_label.text = status_text
	if _detail_label != null:
		_detail_label.text = detail_text


func _step_load_main() -> void:
	var prog := []
	var status := ResourceLoader.load_threaded_get_status(MAIN_SCENE, prog)
	match status:
		ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			var p: float = float(prog[0]) if not prog.is_empty() else 0.0
			_set_progress(p * 0.25, "Loading Zenith…", "%.1fs" % _elapsed_sec())
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
				# Let staged warm-up hold frames advance without waiting on display VSync; Main._ready restores VSync.
				if DisplayServer.get_name() != "headless":
					DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
			_apply_window_frames = 0
			_set_progress(0.25, "Preparing display…", "%.1fs" % _elapsed_sec())
			_state = State.APPLY_WINDOW
		ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			_fallback_to_main()


func _step_apply_window() -> void:
	_apply_window_frames += 1
	_set_progress(0.25 + 0.05 * minf(1.0, float(_apply_window_frames) / 2.0), "Preparing display…", "%.1fs" % _elapsed_sec())
	StallWatchdog.mark("boot: apply_window")
	if _apply_window_frames >= 2:
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
		var budget: int = 35 if warm_all else 50
		if _shader_warmup_script != null and _shader_warmup_script.has_method(&"begin_staged"):
			_shader_warm = _shader_warmup_script.call(&"begin_staged", _warm_holder, warm_all, addon_dirs, budget) as Node3D
		if _shader_warm == null:
			_state = State.WARM_RENDER
			return
		_warmup_ran = true

	if _shader_warm == null or not is_instance_valid(_shader_warm):
		_state = State.WARM_RENDER
		return

	var done_c: int = int(_shader_warm.get(&"done_count"))
	var raw_total: int = int(_shader_warm.get(&"total_count"))
	var total_c: int = maxi(1, raw_total)
	var cur_label: String = str(_shader_warm.get(&"current_label"))
	var pipes: int = int(_shader_warm.call(&"pipelines_compiled")) if _shader_warm.has_method(&"pipelines_compiled") else 0
	var frac: float = 0.30 + 0.50 * (float(done_c) / float(total_c))
	var verb: String = "Compiling shaders…" if _cold_compile else "Warming shader cache…"
	var status_txt := "%s (%d / %d)" % [verb, done_c, raw_total]
	var label_shown := cur_label if cur_label != "" else "Preparing…"
	var sub_txt := "%s  •  %d pipelines  •  %.1fs" % [label_shown, pipes, _elapsed_sec()]
	_set_progress(frac, status_txt, sub_txt)
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
	_set_progress(frac, "Preparing renderer…", "%s  •  %.1fs" % [label_shown, _elapsed_sec()])
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
		_set_progress(1.0, "Starting Zenith…", "%.1fs" % _elapsed_sec())
		StallWatchdog.mark("boot: starting main")
		_pre_handoff_frames = 1
		return
	_state = State.HANDOFF
	_handoff()


func _handoff() -> void:
	_handed_off = true
	StallWatchdog.mark("boot: handoff")
	if _warmup_ran:
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
	_set_progress(1.0, "Starting Zenith…", "%.1fs" % _elapsed_sec())

	if _main_packed == null:
		_fallback_to_main()
		return

	var main_node: Node = _main_packed.instantiate()
	var main_script := main_node.get_script() as Script
	if main_script != null:
		main_script.set(&"booted_from_screen", true)
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
	StallWatchdog.stop()
	get_tree().quit(0)
